#!/usr/bin/env bash
# Disk autogrow for a37-orb: every run (systemd timer, ~1 min) checks each
# running orb's persistent volume and grows it by disk_grow.step_gb before it
# fills, capped at the shape's disk_max. Resizing re-creates the container
# (in-memory state is lost; mount_path data survives).
set -euo pipefail
. "${A37_LIB_DIR:-${A37_CONF_DIR:-$HOME/.config/a37-orb}}/common.sh"

# No Amp job budget here; keep a sane wall clock for one timer run.
A37_BUDGET=240
a37_have_secrets || exit 0
a37_load

ENABLED=$(a37_cfg disk_grow.enabled true)
[ "$ENABLED" = true ] || exit 0
STEP=$(a37_cfg disk_grow.step_gb 5)
THRESHOLD=$(a37_cfg disk_grow.threshold_percent 90)
MIN_FREE_GB=$(a37_cfg disk_grow.min_free_gb 1)
MAX_DEFAULT=$(a37_cfg disk_grow.max_disk_default 50)
MOUNT_PATH=$(a37_cfg mount_path /home/user/workspace)

# disk cap for an instance: first orb_type_map entry on the same template+type.
disk_cap() {
	local t=$1 ty=$2 cap
	cap=$(jq -rn --slurpfile c "$A37_CONFIG_FILE" --arg t "$t" --arg ty "$ty" '
		[$c[0].orb_type_map | to_entries[]
			| select(.value.template == $t and .value.type == $ty)
			| .value.disk_max][0] // empty')
	echo "${cap:-$MAX_DEFAULT}"
}

a37_request GET /v1/instances '' 60 || exit 1
[ "$A37_HTTP" = 200 ] || { a37_err "list instances http $A37_HTTP"; exit 1; }

jq -c --arg mount "$MOUNT_PATH" '
	.data[]
	| select((.metadata.amp_orb_id // "") != "" and .status == "running")
	| {id, template: (.template | split("@")[0]), type,
	   disk: .resources.disk, mount: $mount}' <<<"$A37_BODY" |
	while IFS= read -r orb; do
		id=$(jq -r .id <<<"$orb")
		disk=$(jq -r .disk <<<"$orb")
		mount=$(jq -r .mount <<<"$orb")
		cap=$(disk_cap "$(jq -r .template <<<"$orb")" "$(jq -r .type <<<"$orb")")

		df_out=$(a37_exec_run "$id" "df -Pk '$(printf '%s' "$mount" | sed "s/'/'\\\\''/g")' | tail -1") || {
			a37_log "$id: df probe failed, skipping this round"
			continue
		}
		use_pct=$(awk '{gsub(/%/, "", $5); print $5}' <<<"$df_out")
		avail_kb=$(awk '{print $4}' <<<"$df_out")
		min_free_kb=$((MIN_FREE_GB * 1024 * 1024))

		if [ "$use_pct" -lt "$THRESHOLD" ] && [ "$avail_kb" -ge "$min_free_kb" ]; then
			continue
		fi
		new=$((disk + STEP))
		[ "$new" -gt "$cap" ] && new=$cap
		if [ "$new" -le "$disk" ]; then
			a37_log "$id: disk full-ish (${use_pct}%) but at cap ${cap}G, cannot grow"
			continue
		fi
		a37_log "$id: ${use_pct}% used, ${avail_kb}kB free — growing disk ${disk}G → ${new}G (cap ${cap}G)"
		body=$(jq -n --argjson d "$new" '{resources: {disk: $d}}')
		a37_request POST "/v1/instances/$id/resize" "$body" 120 || continue
		case $A37_HTTP in
		200) a37_log "$id: resize accepted" ;;
		202)
			# Live migration to a bigger host: wait for it to settle, then
			# carry on with whatever budget remains for the other orbs.
			a37_log "$id: resize triggered a live migration, waiting"
			A37_T0=$(date +%s)
			A37_BUDGET=120
			a37_wait_status "$id" running || true
			;;
		*)
			a37_log "$id: resize http $A37_HTTP ($(a37_error_code)), retrying next round"
			;;
		esac
	done || true

exit 0
