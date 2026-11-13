#!/usr/bin/env bash
# Stopped-orb reaper for a37-orb: deletes Agent37 instances whose last lifecycle
# event is `instance.stopped` and that stopped more than reap.max_age_hours ago
# (72 h by default). Runs daily from a systemd timer.
#
# Why this is needed: Agent37 keeps an instance billed for its disk until it is
# deleted, and Amp only sends `delete` when the thread is deleted — archiving
# pauses and never deletes. So a stopped instance is permanent unless the
# controller removes it.
#
# What it costs the user: the instance's disk. The thread survives; its next
# spawn creates a fresh instance from the template and runs .agents/setup again,
# so uncommitted work in that workspace is gone.
#
# The age signal is the instance's own event history (`instance.started` /
# `instance.stopped`), not a local timestamp: it is authoritative, it survives a
# controller restart, and it resets by itself when a thread is resumed.
#
# Pacing: one request per instance per run, spaced by reap.delay_seconds, capped
# at reap.max_deletes_per_run deletions; a37_request already backs off on 429/5xx.
set -euo pipefail
. "${A37_LIB_DIR:-${A37_CONF_DIR:-$HOME/.config/a37-orb}}/common.sh"

# No Amp job budget here; keep a sane wall clock for one timer run.
A37_BUDGET=900
DRY_RUN=0
for arg in "$@"; do
	case $arg in
	--dry-run) DRY_RUN=1 ;;
	*) a37_err "unknown argument: $arg"; exit 2 ;;
	esac
done

a37_have_secrets || exit 0
a37_load

ENABLED=$(a37_cfg reap.enabled true)
[ "$ENABLED" = true ] || exit 0
MAX_AGE_H=$(a37_cfg reap.max_age_hours 72)
DELAY=$(a37_cfg reap.delay_seconds 1)
MAX_DELETES=$(a37_cfg reap.max_deletes_per_run 20)
MAX_AGE=$((MAX_AGE_H * 3600))

a37_request GET /v1/instances '' 60 || exit 1
[ "$A37_HTTP" = 200 ] || { a37_err "list instances http $A37_HTTP"; exit 1; }

now=$(date +%s)
checked=0 kept=0 deleted=0 gone=0 failed=0 capped=0

# One instance per delay_seconds: a large backlog must not become a burst.
pace() { [ "${DELAY:-0}" -gt 0 ] && sleep "$DELAY" || true; }

# Process substitution, not a pipe: the counters must survive the loop.
while IFS= read -r inst; do
	id=$(jq -r .id <<<"$inst")
	orb=$(jq -r .metadata.amp_orb_id <<<"$inst")
	disk=$(jq -r .resources.disk <<<"$inst")
	checked=$((checked + 1))
	pace

	if [ "$(a37_budget_left)" -lt 3 ]; then
		a37_log "reap: time budget spent after $checked instances; the rest waits for the next run"
		break
	fi
	if [ "$deleted" -ge "$MAX_DELETES" ]; then
		capped=1
		a37_log "reap: reached the $MAX_DELETES-deletion cap; the rest waits for the next run"
		break
	fi

	a37_request GET "/v1/instances/$id/events" '' 30 || { failed=$((failed + 1)); continue; }
	if [ "$A37_HTTP" != 200 ]; then
		a37_log "$id: events http $A37_HTTP ($(a37_error_code)), skipping"
		failed=$((failed + 1))
		continue
	fi
	# The default window is the last 30 days, so an empty list on a stopped
	# instance means no lifecycle change in a month: far past any threshold.
	last=$(jq -c '.events[-1] // empty' <<<"$A37_BODY")
	if [ -n "$last" ]; then
		kind=$(jq -r '.type // ""' <<<"$last")
		# epoch seconds are integers on the real API; floor keeps a float
		# (as a fixture or a future API change might emit) out of the shell
		# arithmetic, which aborts the whole sweep on "1.5".
		at=$(jq -r '(.at // 0) | floor' <<<"$last")
		if [ "$kind" != instance.stopped ]; then
			a37_log "$id ($orb): last event is $kind, not stopped — keeping"
			kept=$((kept + 1))
			continue
		fi
		age=$((now - at))
	else
		age=$MAX_AGE
	fi
	if [ "$age" -lt "$MAX_AGE" ]; then
		a37_log "$id ($orb): stopped $((age / 3600))h ago, under $MAX_AGE_H h — keeping"
		kept=$((kept + 1))
		continue
	fi

	if [ "$DRY_RUN" = 1 ]; then
		a37_log "$id ($orb): would delete — stopped $((age / 3600))h ago, ${disk}G disk (dry run)"
		deleted=$((deleted + 1))
		continue
	fi

	a37_log "$id ($orb): deleting — stopped $((age / 3600))h ago, reclaiming ${disk}G"
	a37_request DELETE "/v1/instances/$id" '' 60 || { failed=$((failed + 1)); continue; }
	case $A37_HTTP in
	200 | 202 | 204)
		deleted=$((deleted + 1))
		;;
	404)
		# Already gone: the outcome we wanted, just not by us.
		a37_log "$id: already gone"
		gone=$((gone + 1))
		;;
	*)
		a37_log "$id: delete http $A37_HTTP ($(a37_error_code)), will retry next run"
		failed=$((failed + 1))
		;;
	esac
done < <(jq -c '
	.data[]
	| select(.status == "stopped" and (.metadata.amp_orb_id // "") != "")
	| {id, metadata, resources}' <<<"$A37_BODY")

note=''
if [ "$capped" = 1 ]; then note=", capped"; fi
if [ "$DRY_RUN" = 1 ]; then note="$note (dry run)"; fi
a37_log "reap: checked $checked stopped, deleted $deleted, already gone $gone, kept $kept, failed $failed$note"
exit 0
