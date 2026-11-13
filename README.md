# a37-orb

A self-hosted [Amp](https://ampcode.com/) orb provider whose orbs run as
[Agent37](https://www.agent37.com/) cloud instances. The provider host is
only the controller: `dispatch.sh` receives Amp's spawn/pause/delete
jobs and maps them onto Agent37's Sandbox REST API, so threads get real cloud
sandboxes without any local compute.

Original clean-room implementation against the two public contracts — Amp's
[dispatch contract](https://ampcode.com/docs/orbs/self-hosted) and the
[Agent37 Sandbox API](https://www.agent37.com/docs/agents-api). No upstream
auto-update: this repo is the source of truth and changes are made by hand.

## Layout

| File | Purpose |
| --- | --- |
| `common.sh` | Shared Agent37 API client: budget clamps, retry/backoff for 429/5xx/409 `try_again`, exec plane, config getters |
| `dispatch.sh` | Amp dispatch contract: full instance state machine (create/start/stop/delete by `metadata.amp_orb_id`, sleeping → discard checkpoint, cold storage → direct start, failed → replace) and detached `amp orb bootstrap` with `ORB_TOKEN` |
| `disk-grow.sh` | Timer sweep (~1 min): grows a running orb's disk by 5 GB at ≥90 % use or <1 GB free, capped per shape |
| `template-refresh.sh` | Daily 04:00: repins the `amp-orb` Agent37 template to the newest upstream digest (PATCH → new revision) and rolls it out to stopped orbs only |
| `enter-keys.sh` | Interactive secret entry (`read -s`): validates keys, registers the template, enables the units |
| `config.json` | Region/template defaults, orb type map (`s m l xl vm-m vm-l vm-xl`), disk_grow knobs, `upstream_refs`/`entrypoints` |
| `test/` | 45-assertion regression suite against `mock.py`, a local mock of both API planes |

## Deployment

The live copies run from `~/.config/a37-orb/` (same files; plus `env`, the
0600 secrets file that is never committed). After editing here:

```bash
cp *.sh config.json ~/.config/a37-orb/ && cp test/* ~/.config/a37-orb/test/
bash test/run.sh                      # 45 assertions must pass
systemctl --user restart a37-orb-provider   # dispatch is re-read per job; this is only for the daemon
```

First-time setup on a new host: copy the files, then run
`bash ~/.config/a37-orb/enter-keys.sh` with an Amp provider token
(`aop_live_...`, Settings → Orbs) and an Agent37 API key (`sk_live_...`).
Orb type names must match the provider's Edit dialog in Amp exactly.

## Design notes

- Agent37 pins a registered template to the image digest at registration and
  ignores later `:latest` pushes; that is why `template-refresh.sh` exists and
  why its idempotence baseline is the local `sent_ref` state, not the server's
  digest field.
- The upstream digest is the `linux/amd64` entry of the image's OCI index,
  because `podman manifest inspect` prints the index itself and it carries no
  top-level digest. Failing to resolve it is silent — an empty digest reads as
  "upstream unreachable", so the refresh logs a skip and returns 0 — which is
  how the provider sat on one image for two days. The test fixture therefore
  prints a real index rather than a `{digest}` object.
- `mount_path` is forced to `/home/user/workspace` at create: Agent37's
  default (the image user's home) would mask the image's `amp` binary.
- Project snapshots (`ORB_SNAPSHOT_ID`) are ignored — no container commit on
  Agent37 — so every new thread runs `.agents/setup`.
- `pgrep -f` inside `sh -c` self-matches the wrapper shell's command line;
  the bootstrap probe brackets the pattern (`'[a]mp orb bootstrap'`). The mock
  in `test/` enforces this and caught the original bug's class.
- Bash 5.3 RETURN traps set inside a function re-fire on outer returns and
  break under `set -u`; cleanup uses EXIT traps on process-scoped temp files.

## Acknowledgements

The Agent37 integration pattern — template pinning and refresh, the
entrypoint override for the official orb image, metadata-based orb tracking —
was informed by [XYenon/agent37-orb-provider](https://github.com/XYenon/agent37-orb-provider).
No code was taken from it.

## License

MIT — see [LICENSE](LICENSE).
