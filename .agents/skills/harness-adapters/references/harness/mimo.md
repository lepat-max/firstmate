# MiMoCode (mimo)

Verified on 2026-10-12 with mimo 0.1.15 (a fork of OpenCode) unless a fact gives a newer version.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | Unknown until a semantic source is live-verified. MiMoCode drops OpenCode's plugin event surface (no `session.status` or `session.idle` events on 0.1.15), so nothing arms the semantic busy contract; the delivery guard falls back to the shared signature path. |
| Exit command | `/exit` (documented by MiMoCode's own command reference; `/quit` and `/q` are aliases). |
| Interrupt | Not verified. The control plane refuses an interrupt for a mimo worker until the key is proven against a live pane; use `../../../bin/fm-control.sh <task-id> relaunch` for a wedged pane. |
| Skill invocation | Not verified beyond ordinary slash-command behavior; use natural language when the exact command is uncertain. |
| Resume | Not verified. Relaunch uses the brief on disk as its durable instruction, not a mimo session reference. |
| Model flag | `-m, --model <provider/model>`. |
| Effort flag | None for Firstmate's interactive `mimo --prompt` launch; `mimo run --variant` is a different, non-interactive mode. The effort is recorded in task metadata and omitted from the launch (record-and-omit, as codex and grok do). |
| Model discovery | Run `mimo models [provider]` to list available provider/model identifiers. |
| Trust dialog | Present on 0.1.17: a first `mimo --prompt` in a never-opened directory renders the workspace-trust prompt before anything runs (observed live 2026-11-14); `--trust` skips it, and the shipped launch template passes `--trust` because every firstmate crewmate/scout launch is unattended. `--dangerously-skip-permissions` stays unused; permission handling is the env allow-all below. |
| Permission env | `MIMOCODE_PERMISSION='{"*":"allow","external_directory":{"*":"allow"}}'` (object form; the shipped template adds the `external_directory` allow so an outside-worktree read succeeds with no ask). Regression on 0.1.16: the bare string `'"allow"'` is destroyed by a recursive deep-merge into junk character keys, so the allow-all never applies and every outside-worktree touch raises the standard picker. The object form merges correctly (live-verified 2026-11-08; re-verified on 0.1.17 2026-11-14 via `mimo run`, see docs/verification/runtime-backends.md). Companion launch env: `MIMOCODE_AUTO_APPROVE_DELETE=1` (clears the `bash_delete` forced-ask, which prompts even under the allow-all) and `MIMOCODE_SKIP_ALL_FORCED_ASK_TIMEOUT_MS=60000` (any still-unanswered ask auto-rejects after 60s instead of parking the pane). Re-verify on any mimo version bump. |
| Marker | `MIMOCODE=1` on the mimo process and every child/tool process (verified live). The agent binary is `.mimocode`; the launcher is a node script named `mimo`, identified from ancestry at comm strength. |

## Primary integration

Detection, the fleet lock, and the session-start digest work on a live mimo
session (verified 2026-10-12 on mimo 0.1.15: `bin/fm-harness.sh` reports
`mimo` from the marker and `comm mimo` from the agent binary's ancestry).

No turn-end supervision adapter is verified: MiMoCode publishes neither
OpenCode's plugin events nor a Claude-compatible hook surface of its own on
0.1.15, so `docs/supervision-protocols/` carries no mimo wake protocol and the
primary runs the generic supervision fallback (a bounded foreground wait over
`../../../bin/fm-watch.sh`, never shell `&`). Promotion to a named snippet
needs live verification evidence of a hook surface first.

## Worker dispatch

The launch template mirrors OpenCode's: `MIMOCODE_PERMISSION='{"*":"allow","external_directory":{"*":"allow"}}'` (the
env allow-all with the external-directory allow, injected under the worker's
config so explicit rules still win) carries `--model` and `--prompt`, with
foreign markers cleared at the launch
boundary. The bare-string form `'"allow"'` documented on 0.1.15 is broken on
0.1.16 (deep-merge regression; see the Permission env row above) — use only the
object form. The launch template passes `--trust` so the workspace-trust prompt never
renders for an unattended worker (dialog and flag live-verified on 0.1.17,
2026-11-14).
