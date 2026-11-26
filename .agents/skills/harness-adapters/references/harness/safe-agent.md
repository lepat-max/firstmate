# safe-agent (OpenShell sandbox)

Verified on 2026-11-26 with OpenShell 0.1.10 (CLI and gateway) under colima on the safe local coding agent stack, unless a fact gives a newer version. The adapter is a standard harness launcher in the mimo shape: `bin/fm-spawn.sh` types `bin/fm-safe-agent-crew.sh` into the task pane as the launch command, and the driver dispatches the crew into an OpenShell sandbox whose streamed exec session is the pane content. Crewmates and scouts only.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | Semantic source live: the exchange records the boot wrapper and worker write. The status record is append-only and its last line is authoritative (`running`/`working`/`blocked`/`needs-decision`/`paused` busy; `done`/`failed` idle); output growth after the last status write is busy whatever the line says. `bin/fm-busy-lib.sh` reads it keyed on `harness=safe-agent` in the task meta and mirrors appended lines into the host status log. |
| Exit command | None typed into the pane. The exec session survives a pane close, so `bin/fm-control.sh <task-id> exit` runs the driver's `stop` primitive (an idempotent sandbox delete) and waits for the crew to die; an interrupt is refused - there is no verified interrupt key for the headless run loop - and `relaunch` is the recovery for a wedged crew. |
| Skill invocation | Not applicable in the TUI sense: the delegate runtime is headless (`mimo run`, one run per record). Steering is the standard typed doorbell plus the exchange inbox, never a slash command. |
| Resume | Supported and verified: a relaunch reattaches to the persisted sandbox (no second create), skips the boot run, and drains pending steering. The boot record is written host-side into the exchange before launch and runs only on first create. |
| Model flag | None; the crew runtime is the pinned delegate (`mimo run` inside the sandbox), so per-task `--model` and `--effort` are refused at spawn with the pinned-delegate reason. |
| Trust dialog | None: the sandbox create, uploads, and exec are all driver-owned with no interactive gate. The launch-then-confirm gate is semantic - the spawn waits for the exchange status record to grow past its pre-launch size with a new last line naming `running` or `failed`. |
| Marker | `FM_SAFE_AGENT_HARNESS=safe-agent` plus `SAFE_AGENT_CREW_TASK` (both Firstmate-owned: the boot wrapper exports the first inside the sandbox, the driver passes both as create env). The corroborated pair outranks the delegate runtime's `MIMOCODE=1`, which would otherwise rename the sandbox worker to mimo. |
| Install check | `fm-safe-agent-crew.sh verify`: openshell CLI on PATH, version >= 0.1.10, gateway connected - and the gateway must be the launcher's own, not a foreign one. Refusals name the concrete remediation; `bin/fm-spawn.sh` runs verify at preflight and the launch re-runs it. |

## Configuration

The launcher bootstrap owns the values: `config/safe-agent-sandbox-env` (written by `safe-agent firstmate`; IMAGE, POLICY, EXCHANGE_ROOT, SCRATCH_ROOT are required for launch) and `config/safe-agent-crew-mimocode.json`, the delegate runtime's zero-prompt permission profile. Missing values refuse with that remediation. Every value can be overridden by the environment (`FM_BACKEND_SANDBOX_<KEY>`) for testing. The task's exchange lives at `<EXCHANGE_ROOT>/<task-label>/` (`boot.md`, `status`, `output.log`, `inbox/`).

## Worker dispatch

`bin/fm-spawn.sh` writes the boot record (line 1 the UTC timestamp, lines 2+ the launch brief with the sandboxed-worker role overlay that maps host paths to `/sandbox/*`) into the exchange before launch, then the pane launch runs the driver: sandbox create, wrapper and brief upload, the four binds (worktree, exchange, scratch, and the owning repository's git dir at `/sandbox/gitcommon`), the task env, and a foreground `sandbox exec --tty` boot. Git inside the sandbox works through the gitcommon bind plus the `GIT_DIR`/`GIT_COMMON_DIR`/`GIT_WORK_TREE` exports the wrapper derives from create-time env.

Documented v1 limits: forge credential injection and worker-side push are out of scope - commits land in the task worktree and publication happens host-side - and the boot wrapper is headless-only (no TUI boot mode).

## Primary integration

Never a primary: safe-agent is verified only for crewmate and scout dispatch. The primary's own harness detection is unaffected.
