# MiMoCode (mimo)

mimo is a crewmate/scout adapter using a TUI pane and no semantic event surface.
The router owns the crewmate/scout-only boundary; primary and secondmate integration is unsupported.
[Verification evidence](../../../../../docs/verification/mimo.md) owns the live facts below.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | No semantic source. MiMoCode drops OpenCode's plugin event surface (no `session.status` or `session.idle` events on 0.1.15) and publishes no hook surface of its own, so nothing arms the busy contract and `../../../bin/fm-busy-lib.sh` trusts no stored source for this adapter. On the herdr, rex, and tern backends the pane runtime's native busy verdict is trusted as busy, and - for this adapter alone - its native idle verdict is trusted as idle, because no other evidence exists. |
| Exit command | `/exit` (documented by MiMoCode's own command reference; `/quit` and `/q` are aliases). |
| Interrupt | Not verified. The control plane refuses an interrupt for a mimo worker until the key is proven against a live pane; use `../../../bin/fm-control.sh <task-id> relaunch` for a wedged pane. |
| Skill invocation | Not verified beyond ordinary slash-command behavior; use natural language when the exact command is uncertain. |
| Resume | Not verified. Relaunch uses the brief on disk as its durable instruction, not a mimo session reference. |
| Model flag | `-m, --model <provider/model>`. |
| Effort flag | None for Firstmate's interactive `mimo --prompt` launch; `mimo run --variant` is a different, non-interactive mode. The effort is recorded in task metadata and omitted from the launch (record-and-omit, as codex and grok do). |
| Model discovery | Run `mimo models [provider]` to list available provider/model identifiers. |
| Trust dialog | None documented. Not yet proven against a live spawned pane; the first live spawn on this adapter is the check. |
| Marker | `MIMOCODE=1` on the mimo process and every child/tool process (verified live). The agent binary is `.mimocode`; the launcher is a node script named `mimo`, identified from ancestry at comm strength. |
| Imported config | MiMoCode imports Claude-compatible settings and does not scrub an inherited `CLAUDECODE`, so the marker is checked before the claude line in `../../../bin/fm-harness.sh` and the launch clears every foreign marker at the boundary. |

## Primary integration

No primary Stop guard, watcher protocol, pre-tool protection, or session-start hook surface is verified for MiMoCode.
Do not launch a primary or secondmate with this adapter.
Detection, the fleet lock, and the session-start digest do work on a live mimo primary session ([verification evidence](../../../../../docs/verification/mimo.md)); the digest arrives through the nudge because no tracked session-open hook exists.

## Worker dispatch

The launch template mirrors OpenCode's: `MIMOCODE_PERMISSION='"allow"'` (the
env allow-all, injected under the worker's config so explicit rules still win)
carries `--model` and `--prompt`, with foreign markers cleared at the launch
boundary and the resolved `mimo` binary named by absolute path.
`../../../bin/fm-spawn.sh` owns the launch, the effort record-and-omit, the secondmate refusal, and the missing-executable refusal.
`../../../bin/fm-control-lib.sh` owns the `/exit` exit command, the family mapping, and the kind restriction; it refuses the interrupt key until one is verified.
