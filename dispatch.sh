#!/usr/bin/env bash
# Amp self-hosted orb provider dispatch — orbs run as Agent37 cloud instances.
#
# Implements the Amp dispatch contract (https://ampcode.com/docs/orbs/self-hosted):
# jobs arrive as env vars (ORB_OPERATION spawn|pause|delete, ORB_ID, ORB_TOKEN,
# ...), every operation is re-entrant and must finish within 5 minutes. Output
# goes to the provider log; spawn output also lands in the thread's setup log.
#
# Divergences from the contract worth knowing:
# - ORB_IMAGE is ignored: Agent37 instances must come from a registered
#   workspace template (direct image refs are rejected), so the image is chosen
#   by config.json's template / orb_type_map.
# - ORB_SNAPSHOT_ID is ignored: Agent37 has no container commit, so project
#   snapshots are not supported and every new thread runs .agents/setup.
set -euo pipefail
. "${A37_LIB_DIR:-${A37_CONF_DIR:-$HOME/.config/a37-orb}}/common.sh"

a37_load

# One dispatch job at a time per orb: duplicate jobs for the same ORB_ID would
# race on instance create/start. The lock fd is only inherited by short-lived
# curl children, never by anything remote, so it dies with this script.
A37_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/a37-orb"
mkdir -p "$A37_RUNTIME_DIR"
exec 9>"$A37_RUNTIME_DIR/${ORB_ID:-job}.lock"
flock -w 60 9 || { a37_err "could not acquire the per-orb lock"; exit 1; }

MOUNT_PATH=$(a37_cfg mount_path /home/user/workspace)
BOOT_LOG=$(a37_cfg bootstrap_log /home/user/.amp-bootstrap.log)
BOOTSTRAP_TIMEOUT=$(a37_cfg bootstrap_timeout_seconds 60)

a37_job_log "op=${ORB_OPERATION-} id=${ORB_ID-} type=${ORB_TYPE-} snap=${ORB_SNAPSHOT_ID-}"

# Single-quote a value for safe inclusion in an sh -c command string.
shq() { printf "%s" "$1" | sed "s/'/'\\\\''/g"; }

# ---------------------------------------------------------------- spawn ----

a37_create_instance() {
	local shape id
	shape=$(a37_shape "${ORB_TYPE:-}")
	a37_note "creating instance: $(jq -c . <<<"$shape") region=$(a37_cfg region us)"
	local body
	body=$(jq -n --argjson s "$shape" --arg orb "$ORB_ID" --arg region "$(a37_cfg region us)" \
		--arg mount "$MOUNT_PATH" '$s + {region: $region, mount_path: $mount,
		name: $orb, metadata: {amp_orb_id: $orb}}
		| {template, type, region, mount_path, name, metadata,
		   resources: {cpu, memory, disk}}')
	a37_request POST /v1/instances "$body" "$A37_API_TIMEOUT" || return 1
	case $A37_HTTP in
	201) ;;
	402)
		a37_err "Agent37 workspace balance too low (insufficient_balance); top up at agent37.com"
		return 1
		;;
	409)
		a37_err "create rejected ($(a37_error_code)): $A37_BODY"
		return 1
		;;
	*)
		a37_err "create failed (http $A37_HTTP): $(head -c 300 <<<"$A37_BODY")"
		return 1
		;;
	esac
	# 201 already means status running; keep the id.
	id=$(jq -r .id <<<"$A37_BODY")
	a37_note "created instance $id"
	printf '%s' "$id"
}

ensure_bootstrap() {
	local id=$1 tok amp_url="" cmd
	# Already running from an earlier spawn? Then the orb is connected.
	# The [a]mp bracket is load-bearing: this runs via `sh -c`, whose own
	# command line contains the pattern text, and pgrep -f would match that
	# shell itself — reporting "already running" on a fresh container.
	a37_exec "$id" "pgrep -f '[a]mp orb bootstrap' >/dev/null" 30
	if [ "$A37_HTTP" = 200 ] && [ "$(jq -r .exit_code <<<"$A37_BODY")" = 0 ]; then
		a37_log "bootstrap already running in $id"
		return 0
	fi
	tok=$(shq "$ORB_TOKEN")
	[ -z "${AMP_URL:-}" ] || amp_url=" AMP_URL='$(shq "$AMP_URL")'"
	cmd="export PATH=\"\$HOME/.local/bin:\$HOME/.amp/bin:\$PATH\"; export ORB_TOKEN='$tok'$amp_url; nohup amp orb bootstrap >'$(shq "$BOOT_LOG")' 2>&1 &"
	a37_log "starting amp orb bootstrap in $id"
	a37_exec "$id" "$cmd" 30 || { a37_err "could not start bootstrap (http $A37_HTTP)"; return 1; }
	[ "$A37_HTTP" = 200 ] || { a37_err "bootstrap exec failed (http $A37_HTTP): $(head -c 300 <<<"$A37_BODY")"; return 1; }
	# Wait until the process shows up in the process table.
	local waited=0
	while [ "$waited" -lt "$BOOTSTRAP_TIMEOUT" ]; do
		a37_exec "$id" "pgrep -f '[a]mp orb bootstrap' >/dev/null" 30
		if [ "$A37_HTTP" = 200 ] && [ "$(jq -r .exit_code <<<"$A37_BODY")" = 0 ]; then
			a37_log "bootstrap is running"
			return 0
		fi
		a37_sleep 3
		waited=$((waited + 3))
	done
	a37_exec "$id" "tail -n 50 '$(shq "$BOOT_LOG")'" 30 || true
	if [ "$A37_HTTP" = 200 ]; then
		jq -r .stdout <<<"$A37_BODY" | head -50 >&2
	fi
	a37_err "amp orb bootstrap did not appear within ${BOOTSTRAP_TIMEOUT}s (log above)"
	return 1
}

do_spawn() {
	local id="" status="" cold_storage=0 try=0
	while :; do
		try=$((try + 1))
		[ "$try" -gt 40 ] && { a37_err "spawn: too many state transitions"; return 1; }
		id=$(a37_find_instance "$ORB_ID") || { a37_err "could not list instances"; return 1; }
		if [ -z "$id" ]; then
			id=$(a37_create_instance) || return 1
			status=running # 201 is returned once the instance is running
		else
			a37_get_instance "$id" || { a37_sleep 3; continue; }
			status=$A37_STATUS
		fi
		case $status in
		running) ;;
		provisioning | starting | waking | updating)
			a37_log "instance $id is $status, waiting"
			a37_wait_status "$id" running || return 1
			;;
		stopping)
			a37_log "instance $id is stopping, waiting"
			a37_wait_status "$id" stopped sleeping || return 1
			continue
			;;
		stopped)
			a37_log "starting stopped instance $id"
			a37_request POST "/v1/instances/$id/start" '' 60 || return 1
			[ "$A37_HTTP" = 200 ] || { a37_log "start http $A37_HTTP ($(a37_error_code)), re-checking"; a37_sleep 3; continue; }
			a37_wait_status "$id" running || return 1
			;;
		sleeping)
			# A sleeping instance holds a memory checkpoint with a stale
			# bootstrap process: stop discards the checkpoint (disk kept),
			# then start boots a clean container. Cold-storage sleepers
			# cannot be stopped (400) — start them directly.
			if [ "$cold_storage" = 0 ]; then
				a37_log "sleeping instance $id: discarding checkpoint"
				a37_request POST "/v1/instances/$id/stop" '' 60 || return 1
				case $A37_HTTP in
				200)
					a37_wait_status "$id" stopped sleeping || return 1
					# Still sleeping means the checkpoint could not be
					# discarded (cold storage): start directly next round.
					[ "$A37_STATUS" = sleeping ] && cold_storage=1
					;;
				400) cold_storage=1 ;;
				*)
					a37_log "stop http $A37_HTTP ($(a37_error_code)), re-checking"
					a37_sleep 3
					;;
				esac
				continue
			fi
			a37_log "cold-storage sleeper $id: starting directly"
			a37_request POST "/v1/instances/$id/start" '' 60 || return 1
			[ "$A37_HTTP" = 200 ] || { a37_sleep 3; continue; }
			a37_wait_status "$id" running || return 1
			;;
		failed)
			a37_log "instance $id failed: replacing it"
			a37_request DELETE "/v1/instances/$id" '' 60 || true
			a37_wait_gone "$id" || return 1
			continue
			;;
		deleting | deleted)
			a37_log "instance $id is $status, waiting for it to vanish"
			a37_wait_gone "$id" || return 1
			continue
			;;
		*)
			a37_err "unexpected status '$status'"
			return 1
			;;
		esac
		break
	done
	ensure_bootstrap "$id" || return 1
	a37_job_log "spawn ok instance=$id status=running"
}

a37_wait_gone() {
	local id=$1
	while :; do
		a37_request GET "/v1/instances/$id" '' 30 || return 1
		[ "$A37_HTTP" = 404 ] && return 0
		case $(jq -r '.status // empty' <<<"$A37_BODY") in
		'' | deleted) return 0 ;;
		esac
		a37_sleep 3
	done
}

# ---------------------------------------------------------------- pause ----

do_pause() {
	local id status try=0
	id=$(a37_find_instance "$ORB_ID") || { a37_err "could not list instances"; return 1; }
	if [ -z "$id" ]; then
		a37_log "pause: instance already gone, treated as ok"
		return 0
	fi
	while :; do
		try=$((try + 1))
		[ "$try" -gt 40 ] && { a37_err "pause: too many state transitions"; return 1; }
		a37_get_instance "$id" || { a37_log "pause: instance gone mid-flight, treated as ok"; return 0; }
		status=$A37_STATUS
		case $status in
		running)
			a37_log "stopping $id"
			a37_request POST "/v1/instances/$id/stop" '' 60 || return 1
			case $A37_HTTP in
			200) ;;
			400 | 409)
				# Mid-transition or checkpoint write in progress: wait and retry.
				a37_log "stop http $A37_HTTP ($(a37_error_code)), waiting"
				a37_sleep 5
				;;
			*)
				a37_err "stop failed (http $A37_HTTP): $(head -c 300 <<<"$A37_BODY")"
				return 1
				;;
			esac
			;;
		stopping)
			a37_wait_status "$id" stopped sleeping || return 1
			break
			;;
		stopped | sleeping | failed)
			# stopped: done. sleeping: compute already released, disk kept.
			# failed: nothing billable to stop.
			a37_log "pause: $id is $status"
			break
			;;
		provisioning | starting | waking | updating)
			a37_log "$id is $status, waiting before stop"
			a37_sleep 5
			;;
		*)
			a37_err "unexpected status '$status'"
			return 1
			;;
		esac
	done
	[ -z "${ORB_SNAPSHOT_ID:-}" ] ||
		a37_log "note: project snapshots are not supported on Agent37; ignoring ORB_SNAPSHOT_ID"
	a37_job_log "pause ok instance=$id"
}

# --------------------------------------------------------------- delete ----

do_delete() {
	local id
	id=$(a37_find_instance "$ORB_ID") || { a37_err "could not list instances"; return 1; }
	if [ -z "$id" ]; then
		a37_log "delete: instance already gone, treated as ok"
		return 0
	fi
	a37_log "deleting $id"
	a37_request DELETE "/v1/instances/$id" '' 60 || return 1
	case $A37_HTTP in
	200 | 404) ;;
	*)
		a37_err "delete failed (http $A37_HTTP): $(head -c 300 <<<"$A37_BODY")"
		return 1
		;;
	esac
	a37_wait_gone "$id" || return 1
	a37_job_log "delete ok instance=$id"
}

# ------------------------------------------------------------------ main ---

case "${ORB_OPERATION:-}" in
spawn)
	: "${ORB_ID:?ORB_ID not set}"
	: "${ORB_TOKEN:?ORB_TOKEN not set}"
	do_spawn
	;;
pause)
	: "${ORB_ID:?ORB_ID not set}"
	do_pause
	;;
delete)
	: "${ORB_ID:?ORB_ID not set}"
	do_delete
	;;
*)
	a37_err "unknown ORB_OPERATION '${ORB_OPERATION:-}'"
	exit 1
	;;
esac
