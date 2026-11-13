#!/usr/bin/env bash
# Shared helpers for the Agent37-backed Amp orb provider (a37-orb).
# Sourced by dispatch.sh / disk-grow.sh / template-refresh.sh; never run directly.
#
# All scripts here are original code written against two public contracts:
#   - Amp self-hosted orb dispatch:  https://ampcode.com/docs/orbs/self-hosted
#   - Agent37 Sandbox REST API:      https://www.agent37.com/docs/agents-api
set -euo pipefail

A37_CONF_DIR="${A37_CONF_DIR:-$HOME/.config/a37-orb}"
A37_ENV_FILE="$A37_CONF_DIR/env"
A37_CONFIG_FILE="${A37_CONFIG_FILE:-$A37_CONF_DIR/config.json}"
A37_STATE_DIR="${A37_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/a37-orb}"

a37_log() { printf '%s\n' "$*"; }
# Same as a37_log but on stderr: use inside functions whose stdout is
# captured by the caller (command substitution).
a37_note() { printf '%s\n' "$*" >&2; }
a37_err() { printf 'error: %s\n' "$*" >&2; }

a37_have_secrets() { [ -f "$A37_ENV_FILE" ] && [ -f "$A37_CONFIG_FILE" ]; }

# Loads env (secrets) + config scalars into globals. Exits the caller on failure.
a37_load() {
	if [ ! -f "$A37_ENV_FILE" ]; then
		a37_err "missing $A37_ENV_FILE — run ~/.config/a37-orb/enter-keys.sh"
		exit 1
	fi
	# shellcheck source=/dev/null
	set -a
	. "$A37_ENV_FILE"
	set +a
	: "${AGENT37_API_KEY:?AGENT37_API_KEY not set in env file}"
	if [ ! -f "$A37_CONFIG_FILE" ]; then
		a37_err "missing $A37_CONFIG_FILE"
		exit 1
	fi
	A37_T0="${A37_T0:-$(date +%s)}"
	A37_BUDGET="${A37_BUDGET:-$(a37_cfg budget_seconds 270)}"
	A37_API_BASE=$(a37_cfg api_base https://api.agent37.com)
	A37_EXEC_BASE=$(a37_cfg exec_base https://sandbox.agent37.app)
	A37_API_TIMEOUT="${A37_API_TIMEOUT:-$(a37_cfg api_timeout_seconds 120)}"
	A37_API_BASE=${A37_API_BASE%/}
	A37_EXEC_BASE=${A37_EXEC_BASE%/}
}

# a37_cfg KEY DEFAULT — one config.json value by dotted path.
a37_cfg() {
	jq -rn --slurpfile c "$A37_CONFIG_FILE" --arg p "$1" --arg d "$2" \
		'$c[0] | getpath($p | split(".")) // $d'
}

# a37_upstream_digest REF -> the linux/amd64 manifest digest of an image ref,
# or nothing when it cannot be resolved.
#
# `podman manifest inspect` prints the OCI index itself, which has no top-level
# .digest field: the per-platform entries are the only digests in there. amd64
# is the right entry because that is the manifest this host pulls, and the
# digest form we pin a template to has to name a manifest, not an index.
# Resolving this wrong is silent — an empty digest reads as "upstream
# unavailable" and every refresh skips — so it is verified against real podman
# output in test/ instead of being trusted.
a37_upstream_digest() {
	podman manifest inspect "$1" 2>/dev/null |
		jq -r '[.manifests[]?
			| select(.platform.os == "linux" and .platform.architecture == "amd64")
			| .digest][0] // empty' 2>/dev/null || true
}

a37_budget_left() { echo $((A37_BUDGET - ($(date +%s) - A37_T0))); }

# Prints a timeout of at most `want` seconds, clamped to the remaining budget.
# Exits the caller when the budget is spent.
a37_clamp_timeout() {
	local want=$1 left
	left=$(a37_budget_left)
	if [ "$left" -lt 2 ]; then
		a37_err "time budget (${A37_BUDGET}s) ran out"
		exit 1
	fi
	if [ "$want" -lt "$left" ]; then echo "$want"; else echo "$left"; fi
}

a37_sleep() { local s=$1 c; c=$(a37_clamp_timeout "$s"); sleep "$c"; }

# Error code inside an Agent37 error body, in either shape:
# {"error":{"code":"try_again"}} or {"error":"not_found"}.
a37_body_code() {
	jq -rn 'if (.error | type) == "object" then .error.code
	        elif (.error | type) == "string" then .error
	        else empty end' <<<"$1" 2>/dev/null || true
}

# a37_request METHOD PATH [JSON-BODY] [TIMEOUT]
# Control-plane call (Bearer auth). On return: A37_HTTP holds the status code,
# A37_BODY the response body; return 0 means a definitive HTTP answer (caller
# checks A37_HTTP), 1 that retries were exhausted or the budget ran out.
# Transient failures are retried with backoff: 429, 5xx, transport errors,
# and 409 try_again / capacity_unavailable.
a37_request() {
	local method=$1 path=$2 body=${3:-} want=${4:-$A37_API_TIMEOUT}
	local code ec delay=2 try=0 max_try=8
	while :; do
		local args=(
			-sS -o "$A37_TMP_OUT" -w '%{http_code}' -X "$method" "$A37_API_BASE$path"
			-H "Authorization: Bearer $AGENT37_API_KEY"
			--connect-timeout 10
			--max-time "$(a37_clamp_timeout "$want")"
		)
		[ -n "$body" ] && args+=(-H 'Content-Type: application/json' --data "$body")
		if code=$(curl "${args[@]}" 2>"$A37_TMP_ERR"); then
			ec=$(a37_body_code "$(cat "$A37_TMP_OUT")")
			case $code in
			200 | 201 | 202 | 204 | 400 | 401 | 402 | 403 | 404)
				A37_HTTP=$code
				A37_BODY=$(cat "$A37_TMP_OUT")
				return 0
				;;
			409)
				# try_again / capacity_unavailable are transient; other 409s are definitive.
				if [ "$ec" != try_again ] && [ "$ec" != capacity_unavailable ]; then
					A37_HTTP=$code
					A37_BODY=$(cat "$A37_TMP_OUT")
					return 0
				fi
				;;
			esac
		else
			code=000
		fi
		# Transient (429, 5xx, transport error, 409 try_again/capacity): retry below.
		try=$((try + 1))
		[ "$try" -ge "$max_try" ] && break
		a37_note "http $code on $method $path, retry $try/$((max_try - 1))"
		a37_sleep "$delay"
		delay=$((delay * 2))
		[ "$delay" -gt 10 ] && delay=10
	done
	A37_HTTP=$code
	A37_BODY=$(cat "$A37_TMP_OUT" 2>/dev/null || true)
	a37_err "$method $path failed after retries (http $code): $(head -c 400 "$A37_TMP_ERR")"
	return 1
}

# a37_exec INSTANCE_ID "shell command" [TIMEOUT]
# Exec call on the exec base (X-Agent37-Key header). Same return conventions as
# a37_request; on 200 the body is {exit_code, stdout, stderr, truncated}.
# Retries 429, 5xx, transport errors, and 409/503 try_again.
a37_exec() {
	local id=$1 command=$2 want=${3:-60}
	local code ec='' delay=2 try=0 max_try=6
	local payload
	payload=$(jq -cn --arg c "$command" '{command: $c}')
	while :; do
		if code=$(curl -sS -o "$A37_TMP_OUT" -w '%{http_code}' -X POST \
			"$A37_EXEC_BASE/v1/instances/$id/exec" \
			-H "X-Agent37-Key: $AGENT37_API_KEY" \
			-H 'Content-Type: application/json' --data "$payload" \
			--connect-timeout 10 --max-time "$(a37_clamp_timeout "$want")" 2>"$A37_TMP_ERR"); then
			ec=$(a37_body_code "$(cat "$A37_TMP_OUT")")
			case $code in
			200 | 400 | 401 | 402 | 404)
				A37_HTTP=$code
				A37_BODY=$(cat "$A37_TMP_OUT")
				return 0
				;;
			409)
				# Only try_again is transient; instance_limit_reached etc. are definitive.
				if [ "$ec" != try_again ]; then
					A37_HTTP=$code
					A37_BODY=$(cat "$A37_TMP_OUT")
					return 0
				fi
				;;
			esac
		else
			code=000
		fi
		# Transient (429, 5xx incl. wake_failed/wake_timeout, transport, 409
		# try_again): retry below.
		try=$((try + 1))
		[ "$try" -ge "$max_try" ] && break
		a37_note "exec http $code ($ec), retry $try/$((max_try - 1))"
		a37_sleep "$delay"
		delay=$((delay * 2))
		[ "$delay" -gt 8 ] && delay=8
	done
	A37_HTTP=$code
	A37_BODY=$(cat "$A37_TMP_OUT" 2>/dev/null || true)
	a37_err "exec on $id failed after retries (http $code)"
	return 1
}

# Error code inside $A37_BODY, if any (see a37_body_code for the shapes).
a37_error_code() { a37_body_code "$A37_BODY"; }

# a37_exec_run INSTANCE_ID "command" — exec that must succeed; echoes stdout,
# fails on a nonzero in-container exit code.
a37_exec_run() {
	a37_exec "$1" "$2" || return 1
	[ "$A37_HTTP" = 200 ] || { a37_err "exec http $A37_HTTP: $(head -c 300 <<<"$A37_BODY")"; return 1; }
	local ec
	ec=$(jq -r .exit_code <<<"$A37_BODY")
	if [ "$ec" != 0 ]; then
		a37_err "command exited $ec: $(jq -r .stderr <<<"$A37_BODY" | head -c 300)"
		return 1
	fi
	jq -r .stdout <<<"$A37_BODY"
}

# a37_find_instance ORB_ID — echoes the Agent37 instance id whose metadata
# carries amp_orb_id == ORB_ID, or nothing. Sets A37_INST to the object JSON.
a37_find_instance() {
	a37_request GET /v1/instances '' 60 || return 1
	[ "$A37_HTTP" = 200 ] || { a37_err "list instances http $A37_HTTP"; return 1; }
	A37_INST=$(jq -c --arg id "$1" '[.data[] | select((.metadata.amp_orb_id // "") == $id)][0] // empty' <<<"$A37_BODY")
	jq -r '.id // empty' <<<"$A37_INST"
}

a37_inst_status() { jq -r '.status // empty' <<<"$A37_INST"; }

# a37_get_instance ID — refreshes A37_INST/A37_STATUS. Returns 0 when the
# instance exists, 1 on 404 (gone) or another definitive failure.
a37_get_instance() {
	a37_request GET "/v1/instances/$1" '' 30 || return 1
	if [ "$A37_HTTP" = 404 ]; then return 1; fi
	[ "$A37_HTTP" = 200 ] || { a37_err "get instance http $A37_HTTP: $(head -c 300 <<<"$A37_BODY")"; return 1; }
	A37_INST=$A37_BODY
	A37_STATUS=$(a37_inst_status)
	return 0
}

# a37_wait_status ID GOOD... — polls until the status is one of GOOD.
# Fails on failed/deleted (unless expected) or when the budget ends.
a37_wait_status() {
	local id=$1
	shift
	while :; do
		a37_get_instance "$id" || { A37_STATUS=gone; return 1; }
		local g
		for g in "$@"; do
			[ "$A37_STATUS" = "$g" ] && return 0
		done
		case $A37_STATUS in
		failed | deleted)
			a37_err "instance $id reached status $A37_STATUS"
			return 1
			;;
		esac
		a37_sleep 3
	done
}

a37_job_log() {
	mkdir -p "$A37_STATE_DIR"
	printf '%s %s\n' "$(date -Is)" "$*" >>"$A37_STATE_DIR/dispatch.log"
}

# a37_shape ORB_TYPE — resolves the create shape for a type name:
# echoes JSON {template, type, cpu, memory, disk}. Falls back to defaults.
a37_shape() {
	jq -cn --slurpfile c "$A37_CONFIG_FILE" --arg t "${1:-}" '
		($c[0].orb_type_map[$t] //
			{template: ($c[0].template // "amp-orb"),
			 type: ($c[0].type // "default"),
			 cpu: (($c[0].resources // {}).cpu // 2),
			 memory: (($c[0].resources // {}).memory // 4),
			 disk: (($c[0].resources // {}).disk // 5)})
		| {template, type, cpu, memory, disk}'
}

# Scratch files shared by a37_request/a37_exec. One pair per process, reused
# across sequential calls, removed on exit. (A RETURN trap is not usable for
# this: it re-fires when outer functions return and breaks under set -u.)
A37_TMP_OUT=$(mktemp "${TMPDIR:-/tmp}/a37-orb.XXXXXX")
A37_TMP_ERR=$(mktemp "${TMPDIR:-/tmp}/a37-orb.XXXXXX")
trap 'rm -f "$A37_TMP_OUT" "$A37_TMP_ERR"' EXIT
