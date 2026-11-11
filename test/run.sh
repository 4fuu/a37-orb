#!/usr/bin/env bash
# Regression suite for the a37-orb provider scripts, run against mock.py.
# Usage: bash ~/.config/a37-orb/test/run.sh
set -uo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
LIB=$(cd "$DIR/.." && pwd)
PORT=8232
STATE=/tmp/a37-orb-test-state.json
T=/tmp/a37-orb-test-conf
PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2' want '$3')"; fi; }

# --- fresh mock ---------------------------------------------------------------
for p in $(pgrep -f "$DIR/mock.py" || true); do kill "$p" 2>/dev/null || true; done
sleep 0.5
A37_MOCK_STATE=$STATE setsid python3 "$DIR/mock.py" >/dev/null 2>&1 </dev/null &
sleep 0.8
pgrep -f "$DIR/mock.py" >/dev/null || { echo "mock failed to start"; exit 1; }

mkdir -p "$T/state" "$T/bin"
jq --argjson p "$PORT" '.api_base = "http://127.0.0.1:\($p)"
    | .exec_base = "http://127.0.0.1:\($p)"
    | .budget_seconds = 90
    | .bootstrap_timeout_seconds = 9' "$LIB/config.json" >"$T/config.json"
printf 'AMP_ORB_PROVIDER_TOKEN=aop_live_TESTTOKEN\nAGENT37_API_KEY=sk_live_TESTKEY\n' >"$T/env"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" \x27{"name":"amp-orb","digest":"sha256:NEWUPSTREAM"}\x27\n' >"$T/bin/podman"
chmod +x "$T/bin/podman"

run_dispatch() {
	A37_LIB_DIR="$LIB" A37_CONF_DIR="$T" A37_STATE_DIR="$T/state" "$@" \
		bash "$LIB/dispatch.sh"
}
state() { jq -r "$1" "$STATE"; }

# --- 1. spawn fresh: bootstrap MUST actually start (pgrep self-match guard) ---
out=$(run_dispatch env ORB_OPERATION=spawn ORB_ID=amp-T-one ORB_TOKEN=tok-AAA ORB_TYPE=m 2>&1)
check "spawn fresh exits 0" "$?" 0
grep -q "created instance" <<<"$out" && ok "spawn fresh creates" || bad "spawn fresh creates"
check "create count" "$(state .create_count)" 1
check "bootstrap actually started (no pgrep self-match)" \
	"$(state '.exec_log | map(select(.[1] | contains("nohup amp orb bootstrap"))) | length')" 1
grep -q "bootstrap is running" <<<"$out" && ok "bootstrap confirmed running" || bad "bootstrap confirmed running"
inst=$(curl -s -H "X-Agent37-Key: sk_live_TESTKEY" "http://127.0.0.1:$PORT/v1/instances" |
	jq -c '[.data[] | select(.metadata.amp_orb_id == "amp-T-one")][0]')
check "metadata orb id" "$(jq -r .metadata.amp_orb_id <<<"$inst")" amp-T-one
check "shape from type m (cpu)" "$(jq -r .resources.cpu <<<"$inst")" 4
check "shape from type m (mem)" "$(jq -r .resources.memory <<<"$inst")" 8
check "shape from type m (disk)" "$(jq -r .resources.disk <<<"$inst")" 5
check "mount_path forced" "$(jq -r .mount_path <<<"$inst")" /home/user/workspace
check "name is orb id" "$(jq -r .name <<<"$inst")" amp-T-one
check "bootstrap exec carried the token" \
	"$(state '.exec_log | map(select(.[1] | contains("tok-AAA"))) | length')" 1

# --- 2. spawn again while running (no duplicate create/bootstrap) -------------
out=$(run_dispatch env ORB_OPERATION=spawn ORB_ID=amp-T-one ORB_TOKEN=tok-BBB ORB_TYPE=m 2>&1)
check "spawn running exits 0" "$?" 0
check "no duplicate create" "$(state .create_count)" 1
grep -q "bootstrap already running" <<<"$out" && ok "bootstrap idempotent" || bad "bootstrap idempotent"
check "no second bootstrap" \
	"$(state '.exec_log | map(select(.[1] | contains("nohup amp orb bootstrap"))) | length')" 1

# --- 3. pause -------------------------------------------------------------------
out=$(run_dispatch env ORB_OPERATION=pause ORB_ID=amp-T-one 2>&1)
check "pause exits 0" "$?" 0
check "instance stopped" "$(state '.instances | to_entries[0].value.status')" stopped

# --- 4. spawn on stopped: start + fresh bootstrap -------------------------------
out=$(run_dispatch env ORB_OPERATION=spawn ORB_ID=amp-T-one ORB_TOKEN=tok-CCC ORB_TYPE=m 2>&1)
check "spawn stopped exits 0" "$?" 0
check "still one instance" "$(state '.instances | length')" 1
check "running again" "$(state '.instances | to_entries[0].value.status')" running
check "bootstrap re-run after start" \
	"$(state '.exec_log | map(select(.[1] | contains("tok-CCC"))) | length')" 1

# --- 5. flaky list (503 try_again) is retried -----------------------------------
touch /tmp/a37-orb-test-flaky
out=$(run_dispatch env ORB_OPERATION=spawn ORB_ID=amp-T-one ORB_TOKEN=tok-DDD 2>&1)
check "flaky spawn exits 0" "$?" 0
grep -q "retry 1/" <<<"$out" && ok "retry on 503 try_again" || bad "retry on 503 try_again"

# --- 6. delete (+ idempotent), pause unknown ------------------------------------
run_dispatch env ORB_OPERATION=delete ORB_ID=amp-T-one >/dev/null 2>&1
check "delete exits 0" "$?" 0
check "instance gone" "$(state '.instances | length')" 0
run_dispatch env ORB_OPERATION=delete ORB_ID=amp-T-one >/dev/null 2>&1
check "delete again exits 0" "$?" 0
run_dispatch env ORB_OPERATION=pause ORB_ID=amp-T-nobody >/dev/null 2>&1
check "pause unknown ok" "$?" 0

# --- 7. disk-grow within per-shape caps ------------------------------------------
run_dispatch env ORB_OPERATION=spawn ORB_ID=amp-T-disk ORB_TOKEN=tok-EEE ORB_TYPE=s >/dev/null 2>&1
A37_LIB_DIR="$LIB" A37_CONF_DIR="$T" A37_STATE_DIR="$T/state" bash "$LIB/disk-grow.sh" >/dev/null 2>&1
check "disk-grow resize called once" "$(state '.resize_log | length')" 1
check "disk grew 5 -> 10 (cap 12 for s)" "$(state '.resize_log[0][1]')" 10
A37_LIB_DIR="$LIB" A37_CONF_DIR="$T" A37_STATE_DIR="$T/state" bash "$LIB/disk-grow.sh" >/dev/null 2>&1
check "df now 55% -> no further resize" "$(state '.resize_log | length')" 1

# --- 8. template refresh + rollout, idempotent second run ------------------------
run_dispatch env ORB_OPERATION=pause ORB_ID=amp-T-disk >/dev/null 2>&1
out=$(PATH="$T/bin:$PATH" A37_LIB_DIR="$LIB" A37_CONF_DIR="$T" A37_STATE_DIR="$T/state" \
	bash "$LIB/template-refresh.sh" 2>&1)
grep -q "refreshing" <<<"$out" && ok "refresh detects stale image" || bad "refresh detects stale image"
check "patch count" "$(state .patch_count)" 1
check "template revision" "$(state '.templates["amp-orb"].revision')" 2
check "template digest updated" "$(state '.templates["amp-orb"].image_digest')" sha256:NEWUPSTREAM
check "stopped instance updated to rev 2" "$(state '.instances | to_entries[0].value.template_revision')" 2
check "update called once" "$(state .update_count)" 1
out=$(PATH="$T/bin:$PATH" A37_LIB_DIR="$LIB" A37_CONF_DIR="$T" A37_STATE_DIR="$T/state" \
	bash "$LIB/template-refresh.sh" 2>&1)
check "second run: no extra patch" "$(state .patch_count)" 1
check "second run: no extra update" "$(state .update_count)" 1
grep -q "up to date" <<<"$out" && ok "second run reports up to date" || bad "second run reports up to date"

# --- cleanup ---------------------------------------------------------------------
for p in $(pgrep -f "$DIR/mock.py" || true); do kill "$p" 2>/dev/null || true; done
rm -rf "$T" /tmp/a37-orb-test-flaky
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
