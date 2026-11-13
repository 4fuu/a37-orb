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
    | .bootstrap_timeout_seconds = 9
    | .reap.delay_seconds = 0
    | .reap.max_deletes_per_run = 1' "$LIB/config.json" >"$T/config.json"
printf 'AMP_ORB_PROVIDER_TOKEN=aop_live_TESTTOKEN\nAGENT37_API_KEY=sk_live_TESTKEY\n' >"$T/env"
# Fake podman printing what `podman manifest inspect` really prints for a
# multi-arch tag: the OCI index itself, with no top-level digest. The amd64
# entry is the manifest this host pulls, so that is the one to pin; the foreign
# arch comes first and an attestation entry (unknown platform) sits before it,
# so taking the first manifest, or a top-level .digest that does not exist,
# both fail the refresh assertions below.
cat >"$T/bin/podman" <<'FAKE'
#!/usr/bin/env bash
if [ -n "${A37_TEST_NO_AMD64:-}" ]; then
	printf '%s\n' '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[
		{"digest":"sha256:ARMONLY","platform":{"architecture":"arm64","os":"linux"}}]}'
else
	printf '%s\n' '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[
		{"digest":"sha256:ARMOTHER","platform":{"architecture":"arm64","os":"linux"}},
		{"digest":"sha256:ATTESTATION","platform":{"architecture":"unknown","os":"unknown"}},
		{"digest":"sha256:NEWUPSTREAM","platform":{"architecture":"amd64","os":"linux"}}]}'
fi
FAKE
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
check "template pinned to the amd64 manifest digest" \
	"$(state '.templates["amp-orb"].image_ref')" \
	"us-central1-docker.pkg.dev/amp-prod-0/amp-orb/amp-orb@sha256:NEWUPSTREAM"
check "stopped instance updated to rev 2" "$(state '.instances | to_entries[0].value.template_revision')" 2
check "update called once" "$(state .update_count)" 1
out=$(PATH="$T/bin:$PATH" A37_LIB_DIR="$LIB" A37_CONF_DIR="$T" A37_STATE_DIR="$T/state" \
	bash "$LIB/template-refresh.sh" 2>&1)
check "second run: no extra patch" "$(state .patch_count)" 1
check "second run: no extra update" "$(state .update_count)" 1
grep -q "up to date" <<<"$out" && ok "second run reports up to date" || bad "second run reports up to date"
check "sent_ref recorded in the state file" \
	"$(jq -r '.["amp-orb"].sent_ref' "$T/state/templates.json" 2>/dev/null)" \
	"us-central1-docker.pkg.dev/amp-prod-0/amp-orb/amp-orb@sha256:NEWUPSTREAM"

# --- 9. an index with no amd64 entry is skipped, not pinned to another arch ---
out=$(PATH="$T/bin:$PATH" A37_TEST_NO_AMD64=1 A37_LIB_DIR="$LIB" A37_CONF_DIR="$T" \
	A37_STATE_DIR="$T/state" bash "$LIB/template-refresh.sh" 2>&1)
check "no-amd64 index exits 0" "$?" 0
grep -q "cannot resolve upstream digest" <<<"$out" && ok "no-amd64 index skips" || bad "no-amd64 index skips"
check "no-amd64 index: no patch" "$(state .patch_count)" 1
check "no-amd64 index: ref untouched" \
	"$(state '.templates["amp-orb"].image_ref')" \
	"us-central1-docker.pkg.dev/amp-prod-0/amp-orb/amp-orb@sha256:NEWUPSTREAM"

# --- 10. reaper: deletes only instances stopped for over 72 h -----------------
has_orb() { state "[.instances[] | select((.metadata.amp_orb_id // \"\") == \"$1\")] | length"; }
inst_of() { state ".instances | to_entries | map(select((.value.metadata.amp_orb_id // \"\") == \"$1\"))[0].key"; }
backdate() { # INSTANCE_ID SECONDS
	curl -s -o /dev/null -X POST -H "X-Agent37-Key: sk_live_TESTKEY" \
		--data "{\"id\":\"$1\",\"seconds\":$2}" "http://127.0.0.1:$PORT/v1/_test/backdate"
}
add_event() { # INSTANCE_ID TYPE
	curl -s -o /dev/null -X POST -H "X-Agent37-Key: sk_live_TESTKEY" \
		--data "{\"id\":\"$1\",\"type\":\"$2\"}" "http://127.0.0.1:$PORT/v1/_test/event"
}
reap() { A37_LIB_DIR="$LIB" A37_CONF_DIR="$T" A37_STATE_DIR="$T/state" \
	bash "$LIB/reap.sh" "$@"; }

for o in amp-T-run amp-T-fresh amp-T-old amp-T-old2 amp-T-odd; do
	run_dispatch env ORB_OPERATION=spawn ORB_ID="$o" ORB_TOKEN="tok-$o" ORB_TYPE=s >/dev/null 2>&1
done
# run stays running; the rest are stopped by a pause job, like a real idle orb.
for o in amp-T-fresh amp-T-old amp-T-old2 amp-T-odd; do
	run_dispatch env ORB_OPERATION=pause ORB_ID="$o" >/dev/null 2>&1
done
# odd: history ends with a start, so it must be kept even though it is old.
add_event "$(inst_of amp-T-odd)" instance.started
backdate "$(inst_of amp-T-odd)" $((80 * 3600))
backdate "$(inst_of amp-T-old)" $((80 * 3600))
backdate "$(inst_of amp-T-old2)" $((90 * 3600))
backdate "$(inst_of amp-T-fresh)" $((10 * 3600))
# an instance the provider did not create (no amp_orb_id) must never be reaped
foreign=$(curl -s -X POST -H "X-Agent37-Key: sk_live_TESTKEY" -H 'Content-Type: application/json' \
	--data '{"template":"amp-orb","resources":{"cpu":2,"memory":4,"disk":5}}' \
	"http://127.0.0.1:$PORT/v1/instances" | jq -r .id)
curl -s -o /dev/null -X POST -H "X-Agent37-Key: sk_live_TESTKEY" \
	"http://127.0.0.1:$PORT/v1/instances/$foreign/stop"
backdate "$foreign" $((80 * 3600))

out=$(reap 2>&1)
check "reap exits 0" "$?" 0
check "reap deletes the oldest stopped orb" "$(has_orb amp-T-old)" 0
grep -q "deletion cap" <<<"$out" && ok "reap honours the per-run cap" || bad "reap honours the per-run cap"
check "cap leaves the other eligible orb" "$(has_orb amp-T-old2)" 1
check "reap keeps an orb stopped 10 h" "$(has_orb amp-T-fresh)" 1
check "reap keeps a running orb" "$(has_orb amp-T-run)" 1
check "reap keeps a history ending in start" "$(has_orb amp-T-odd)" 1
check "reap never touches a non-provider instance" \
	"$(state "[.instances[] | select(.id == \"$foreign\")] | length")" 1

jq '.reap.max_deletes_per_run = 10' "$T/config.json" >"$T/config.next" && mv "$T/config.next" "$T/config.json"
out=$(reap 2>&1)
check "second reap clears the backlog" "$(has_orb amp-T-old2)" 0
check "second reap still keeps 10 h orb" "$(has_orb amp-T-fresh)" 1
check "second reap still keeps start-last orb" "$(has_orb amp-T-odd)" 1
check "second reap still skips the non-provider instance" \
	"$(state "[.instances[] | select(.id == \"$foreign\")] | length")" 1

run_dispatch env ORB_OPERATION=spawn ORB_ID=amp-T-dry ORB_TOKEN=tok-DRY ORB_TYPE=s >/dev/null 2>&1
run_dispatch env ORB_OPERATION=pause ORB_ID=amp-T-dry >/dev/null 2>&1
backdate "$(inst_of amp-T-dry)" $((80 * 3600))
out=$(reap --dry-run 2>&1)
grep -q "would delete" <<<"$out" && ok "dry run reports the candidate" || bad "dry run reports the candidate"
check "dry run deletes nothing" "$(has_orb amp-T-dry)" 1

# --- cleanup ---------------------------------------------------------------------
for p in $(pgrep -f "$DIR/mock.py" || true); do kill "$p" 2>/dev/null || true; done
rm -rf "$T" /tmp/a37-orb-test-flaky
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
