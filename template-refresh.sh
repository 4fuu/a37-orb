#!/usr/bin/env bash
# Template refresh for a37-orb: keeps the Agent37 workspace templates pinned to
# the newest upstream orb image, then rolls the new revision out to stopped
# orbs. Runs daily at 04:00 from a systemd timer (no Amp job budget, but a
# template PATCH copies the image server-side and can take minutes).
#
# Why this exists: Agent37 copies the image once at template registration and
# pins it by digest; re-pushing :latest upstream changes nothing until the
# template's image_ref changes. PATCHing a *changed* image_ref (we use the
# digest form repo@sha256:...) publishes a new revision; POST
# /v1/instances/{id}/update then re-resolves a stopped instance onto it while
# keeping its disk.
#
# Idempotence: the server may normalize image_ref/digest differently than
# podman's manifest-list digest, so "what we last asked for" is tracked in
# ~/.local/state/a37-orb/templates.json and a PATCH only happens when the
# upstream digest differs from what we last sent (or the entrypoint is wrong).
set -euo pipefail
. "${A37_LIB_DIR:-${A37_CONF_DIR:-$HOME/.config/a37-orb}}/common.sh"

A37_BUDGET=900
a37_have_secrets || exit 0
a37_load

STATE_FILE="$A37_STATE_DIR/templates.json"
state_get() { # TEMPLATE KEY -> value or empty
	[ -f "$STATE_FILE" ] || return 0
	jq -rn --arg t "$1" --arg k "$2" \
		'try (input | .[$t][$k] // empty) catch empty' "$STATE_FILE" 2>/dev/null || true
}
state_set() { # TEMPLATE KEY VALUE
	mkdir -p "$A37_STATE_DIR"
	touch "$STATE_FILE"
	local tmp
	tmp=$(jq --arg t "$1" --arg k "$2" --arg v "$3" \
		'.[$t][$k] = $v' "$STATE_FILE" 2>/dev/null ||
		jq -cn --arg t "$1" --arg k "$2" --arg v "$3" '{($t): {($k): $v}}')
	printf '%s\n' "$tmp" >"$STATE_FILE"
}

# Every template this provider uses that we know an upstream ref for.
# (Template names may contain dots, e.g. amp-orb, so upstream_refs is read
# with a real key lookup rather than a37_cfg's dotted paths.)
active_templates() {
	jq -rn --slurpfile c "$A37_CONFIG_FILE" '
		([$c[0].template] + [$c[0].orb_type_map[]?.template] | unique)[] as $t
		| select(($c[0].upstream_refs[$t] // "") != "")
		| $t'
}

encoded() { jq -rn --arg v "$1" '$v | @uri'; }

refresh_template() {
	local name=$1 ref want_entry digest up_ref body
	ref=$(jq -rn --slurpfile c "$A37_CONFIG_FILE" --arg n "$name" '$c[0].upstream_refs[$n] // empty')
	want_entry=$(jq -c --slurpfile c "$A37_CONFIG_FILE" --arg n "$name" '$c[0].entrypoints[$n] // empty')
	digest=$(a37_upstream_digest "$ref")
	if [ -z "$digest" ]; then
		a37_log "$name: cannot resolve upstream digest for $ref, skipping"
		return 0
	fi
	if [[ $ref == *@sha256:* ]]; then
		up_ref=$ref
	else
		# strip the tag (after the last ':'; our refs' hosts carry no port)
		up_ref="${ref%:*}@$digest"
	fi

	a37_request GET "/v1/templates/$(encoded "$name")" '' 60 || return 0
	if [ "$A37_HTTP" = 404 ]; then
		a37_log "$name: not registered yet, registering from $up_ref (this can take minutes)"
		body=$(jq -n --arg n "$name" --arg r "$up_ref" --argjson e "${want_entry:-null}" \
			'{name: $n, image_ref: $r} + (if $e == null then {} else {entrypoint: $e} end)')
		a37_request POST /v1/templates "$body" 600 || { a37_log "$name: register http $A37_HTTP"; return 0; }
		[ "$A37_HTTP" = 201 ] || { a37_log "$name: register failed: $(head -c 300 <<<"$A37_BODY")"; return 0; }
	elif [ "$A37_HTTP" != 200 ]; then
		a37_log "$name: get template http $A37_HTTP, skipping"
		return 0
	fi

	local entry_ok
	entry_ok=$(jq -rn --argjson have "$(jq -c '.entrypoint // null' <<<"$A37_BODY")" \
		--argjson want "${want_entry:-null}" \
		'if $want == null then true else $have == $want end')

	local sent_ref
	sent_ref=$(state_get "$name" sent_ref)
	if { [ "$sent_ref" = "$up_ref" ] ||
		[ "$(jq -r '.image_digest // empty' <<<"$A37_BODY")" = "$digest" ] ||
		[ "$(jq -r '.image_ref // empty' <<<"$A37_BODY")" = "$up_ref" ]; } && [ "$entry_ok" = true ]; then
		state_set "$name" sent_ref "$up_ref"
		a37_log "$name: up to date ($digest)"
	else
		local why=()
		[ "$sent_ref" = "$up_ref" ] || why+=("image -> $digest")
		[ "$entry_ok" = true ] || why+=("entrypoint")
		a37_log "$name: refreshing (${why[*]})"
		body=$(jq -n --arg r "$up_ref" --argjson e "${want_entry:-null}" \
			'{image_ref: $r} + (if $e == null then {} else {entrypoint: $e} end)')
		a37_request PATCH "/v1/templates/$(encoded "$name")" "$body" 600 || return 0
		case $A37_HTTP in
		200)
			a37_log "$name: now at revision $(jq -r '.revision // "?"' <<<"$A37_BODY")"
			state_set "$name" sent_ref "$up_ref"
			;;
		*)
			a37_log "$name: PATCH http $A37_HTTP: $(head -c 300 <<<"$A37_BODY") — leaving as is"
			return 0
			;;
		esac
	fi

	# Roll out: re-resolve stopped orbs onto the current revision. Running and
	# sleeping instances are skipped on purpose (an update rebuilds the
	# container; waking sleepers costs compute). A37_BODY still holds the
	# template object with the current revision.
	local rev
	rev=$(jq -r '.revision // 1' <<<"$A37_BODY")
	a37_request GET /v1/instances '' 60 || return 0
	[ "$A37_HTTP" = 200 ] || return 0
	local skipped=0 updated=0 row iid istatus irev
	while IFS= read -r row; do
		iid=$(jq -r .id <<<"$row")
		istatus=$(jq -r .status <<<"$row")
		irev=$(jq -r '.template_revision // 1' <<<"$row")
		[ "$irev" = "$rev" ] && continue
		if [ "$istatus" != stopped ]; then
			skipped=$((skipped + 1))
			continue
		fi
		a37_request POST "/v1/instances/$iid/update" '' 300 || { skipped=$((skipped + 1)); continue; }
		if [ "$A37_HTTP" = 200 ]; then
			# A stopped instance should stay stopped; if the update woke it,
			# put it back so it keeps billing disk only.
			if [ "$(jq -r '.status // ""' <<<"$A37_BODY")" != stopped ]; then
				a37_request POST "/v1/instances/$iid/stop" '' 60 || true
			fi
			updated=$((updated + 1))
			a37_log "$iid: updated to revision $rev"
		else
			a37_log "$iid: update http $A37_HTTP ($(a37_error_code))"
			skipped=$((skipped + 1))
		fi
	done < <(jq -c --arg t "$name" \
		'.data[] | select(((.template // "") | split("@")[0]) == $t)' <<<"$A37_BODY")
	a37_log "$name: rollout of revision $rev — updated $updated, left $skipped (running/sleeping/failed)"
}

while IFS= read -r t; do
	refresh_template "$t"
done < <(active_templates)

exit 0
