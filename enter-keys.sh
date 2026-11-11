#!/usr/bin/env bash
# One-time (and re-runnable) secret entry for the a37-orb provider.
#
# Prompts for the two credentials with the terminal echo off, so the values
# never appear in shell history, process output, or any agent transcript:
#
#   1. Amp self-hosted provider token (aop_live_...) — Amp Settings -> Orbs
#      -> Add Provider. Shown once when the provider is created.
#   2. Agent37 workspace API key (sk_live_...) — Agent37 Dashboard -> API Keys.
#
# Then it validates the Agent37 key against the live API, registers the
# amp-orb template if needed (entrypoint override included), enables user
# lingering, and starts the provider service and timers.
set -euo pipefail

CONF_DIR="${A37_CONF_DIR:-$HOME/.config/a37-orb}"
ENV_FILE="$CONF_DIR/env"

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -t 0 ] || die "run this in a terminal; it prompts for secrets"

read_secret() { # PROMPT -> value on stdout
	local value=''
	while [ -z "$value" ]; do
		printf '%s [input hidden]: ' "$1" >&2
		IFS= read -rs value </dev/tty || die "aborted"
		printf '\n' >&2
		[ -n "$value" ] || printf 'Value cannot be empty.\n' >&2
	done
	printf '%s' "$value"
}

token=$(read_secret "Amp provider token (aop_live_...)")
case $token in
aop_live_*) ;;
*) die "the Amp provider token should start with aop_live_ (got '${token:0:8}...')" ;;
esac

api_key=$(read_secret "Agent37 API key (sk_live_...)")
case $api_key in
sk_live_*) ;;
*) die "the Agent37 API key should start with sk_live_ (got '${api_key:0:8}...')" ;;
esac

say "checking the Agent37 key against the live API"
code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 30 \
	-H "Authorization: Bearer $api_key" https://api.agent37.com/v1/templates)
case $code in
200) say "key accepted" ;;
401 | 403) die "Agent37 rejected the key (http $code)" ;;
*) die "could not reach api.agent37.com (http $code) — try again later" ;;
esac

say "writing $ENV_FILE (mode 0600)"
umask 077
{
	printf 'AMP_ORB_PROVIDER_TOKEN=%s\n' "$token"
	printf 'AGENT37_API_KEY=%s\n' "$api_key"
} >"$ENV_FILE"
chmod 600 "$ENV_FILE"

# Register the amp-orb template if missing, pinned to the current upstream
# digest when we can resolve it (avoids a second image copy on first refresh).
say "ensuring the Agent37 template is registered (first registration can take minutes)"
ref=$(jq -r '.upstream_refs["amp-orb"] // "us-central1-docker.pkg.dev/amp-prod-0/amp-orb/amp-orb:latest"' "$CONF_DIR/config.json")
entry=$(jq -c '.entrypoints["amp-orb"] // null' "$CONF_DIR/config.json")
digest=$(podman manifest inspect "$ref" 2>/dev/null | jq -r '.digest // empty')
if [ -n "$digest" ]; then
	ref="${ref%:*}@$digest"
fi
tpl_path=$(jq -rn '@uri "amp-orb"')
code=$(curl -sS -o /tmp/a37-tpl-check.json -w '%{http_code}' --max-time 60 \
	-H "Authorization: Bearer $api_key" "https://api.agent37.com/v1/templates/$tpl_path")
if [ "$code" = 404 ]; then
	say "registering template amp-orb from $ref"
	body=$(jq -n --arg r "$ref" --argjson e "$entry" \
		'{name: "amp-orb", image_ref: $r} + (if $e == null then {} else {entrypoint: $e} end)')
	code=$(curl -sS -o /tmp/a37-tpl-check.json -w '%{http_code}' --max-time 600 -X POST \
		-H "Authorization: Bearer $api_key" -H 'Content-Type: application/json' \
		--data "$body" https://api.agent37.com/v1/templates)
	[ "$code" = 201 ] || die "template registration failed (http $code): $(head -c 300 /tmp/a37-tpl-check.json)"
	mkdir -p "${XDG_STATE_HOME:-$HOME/.local/state}/a37-orb"
	say "template registered (revision $(jq -r '.revision // 1' /tmp/a37-tpl-check.json))"
elif [ "$code" != 200 ]; then
	die "could not check the template (http $code)"
else
	say "template already registered (revision $(jq -r '.revision // 1' /tmp/a37-tpl-check.json))"
fi
rm -f /tmp/a37-tpl-check.json

if [ -n "$digest" ]; then
	mkdir -p "${XDG_STATE_HOME:-$HOME/.local/state}/a37-orb"
	touch "${XDG_STATE_HOME:-$HOME/.local/state}/a37-orb/templates.json"
	printf '%s\n' "$(jq --arg r "$ref" '.["amp-orb"].sent_ref = $r' \
		"${XDG_STATE_HOME:-$HOME/.local/state}/a37-orb/templates.json" 2>/dev/null ||
		jq -cn --arg r "$ref" '{"amp-orb": {sent_ref: $r}}')" \
		>"${XDG_STATE_HOME:-$HOME/.local/state}/a37-orb/templates.json"
fi

say "enabling systemd units"
systemctl --user daemon-reload
systemctl --user enable --now a37-orb-provider.service
systemctl --user enable --now a37-orb-disk-grow.timer a37-orb-template-refresh.timer

if [ "$(loginctl show-user "$USER" -p Linger --value)" != yes ]; then
	if loginctl enable-linger "$USER" 2>/dev/null; then
		say "enabled user lingering"
	else
		printf 'warning: could not enable linger without authorization; run:\n' >&2
		printf '  sudo loginctl enable-linger %s\n' "$USER" >&2
	fi
else
	say "user lingering already on"
fi

say "done. Check with:   systemctl --user status a37-orb-provider"
printf '%s\n' \
	"Next in Amp (https://ampcode.com/settings/orbs): open this provider's Edit dialog," \
	"add orb types s / m / l / xl / vm-m / vm-l / vm-xl (they must match the names in" \
	"config.json's orb_type_map), and pick a default. Then start a thread on it to test."
