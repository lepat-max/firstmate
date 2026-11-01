# MiMoCode (mimo) adapter verification

Maintainer-verification record for the `mimo` crewmate/scout adapter.
It records the active empirical facts the adapter depends on and the exact commands that establish them.
The portable regression `tests/fm-mimo-harness.test.sh` is what CI enforces.
There is no live drift guard for this adapter, deliberately: firstmate depends on no vendor-rendered mimo surface (no busy footer token, no interrupt key, no composer signature), so nothing here can drift silently into a wrong runtime verdict.
A live guard becomes necessary together with the first verified vendor-rendered signal, such as an interrupt key or a busy footer.

Scope: crewmate and scout launches only.
A mimo secondmate is refused because MiMoCode has no verified primary supervision protocol, and no primary turn-end hook surface exists on the verified version.

## Environment

- Date: 2026-10-12.
- Host: macOS.
- Tool: `mimo 0.1.15`, an OpenCode fork shipped as a Bun-compiled agent binary plus a node launcher script.
- Session: a live MiMoCode primary session whose cwd is the firstmate home.
- Later additions: the fleet-lock recognition was verified live on 2026-10-15, and the native-idle busy classification was verified in production use on 2026-10-31.

## Detection precedence

The tool subprocess environment carried `MIMOCODE=1` and no `CLAUDECODE`, and the parent chain was the agent binary at comm `.mimocode` above a node launcher whose args end with `/mimo`:

```sh
bin/fm-harness.sh; bin/fm-harness.sh crew; bin/fm-harness.sh ancestry
```

Observed output:

```text
mimo
mimo
comm mimo
```

The marker and the comm-strength ancestry agree, so both halves are live-verified.
The branch pin resolves for `mimo`: `FM_SUPERVISION_ACTOR=branch FM_SUPERVISION_PRIMARY_HARNESS=mimo bin/fm-harness.sh` reports `mimo`.
MiMoCode imports Claude-compatible settings and does not scrub an inherited `CLAUDECODE`, so the marker is checked before the claude line and a structural mimo ancestor outranks a retained marker through comm strength; an args-strength launcher match alone yields to a publishing marker.
The portable regression pins the marker, both ancestry shapes, the fragment negatives, the comm-strength precedence over a retained `CLAUDECODE`, and the args-strength boundary.

## Launch contract

The launch carries the brief through `--prompt`, grants the env allow-all through `MIMOCODE_PERMISSION='"allow"'` (injected under the worker's config, the same permission-only shape as OpenCode's `OPENCODE_CONFIG_CONTENT` grant), pins the resolved absolute `mimo` binary, and clears every foreign harness marker at the boundary.
`mimo models [provider]` lists provider/model identifiers; no model catalog validation runs at spawn, so an unavailable model surfaces as a pane-visible launcher error rather than a spawn refusal.
The interactive `mimo --prompt` launch has no effort flag (`mimo run --variant` is a different, non-interactive mode), so every effort level is recorded in task metadata and omitted from the launch.
The launch-template shapes are pinned by the portable regression behind a fake tmux, not by a live spawned pane.

Not verified on this adapter: a live spawned pane (trust dialog, ready signal, submit shape, and typed-send delivery confirmation, whose delivery guard is silent for this adapter), the interrupt key, a resume form, and any semantic busy source.
The adapter reference records those as pending.

## Control mechanics

`fm-control.sh` recognizes a recorded `mimo` harness through the shared family table.
The verified exit command is `/exit`, documented by MiMoCode's own command reference (`/quit` and `/q` are aliases).
No interrupt key, transport, or repeat count is verified, so the control plane refuses an interrupt for a mimo worker instead of guessing; relaunch from the brief on disk is the recovery path for a wedged pane.

## Busy classification

MiMoCode drops OpenCode's plugin event surface (no `session.status` or `session.idle` events on 0.1.15) and publishes no hook surface of its own, so nothing arms the busy contract and no stored source is trusted for this adapter.
On the herdr, rex, and tern backends a native busy verdict from the pane runtime classifies busy, and - for this adapter alone - a native idle verdict classifies idle, because no other evidence exists and the fallback would otherwise stay unknown forever.
The native-idle trust is scoped to mimo: a harness with its own semantic sources keeps unknown for a native idle verdict.
Verified in production use on 2026-10-31, where a mimo worker on herdr settled to a trusted idle verdict from the pane runtime alone.

## Fleet lock

The fleet-lock ancestry walk recognizes the `.mimocode` agent binary comm and the `node .../mimo` launcher, unanchored like opencode because both live shapes carry the fragment inside a larger name.
Live-verified on 2026-10-15: the ancestry walk resolved a live mimo session's own pid and `bin/fm-session-start.sh` acquired the lock inside that session.

## Refresh commands

```sh
mimo --version
bash bin/fm-test-run.sh tests/fm-mimo-harness.test.sh
```
