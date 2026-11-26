#!/bin/sh
# fm-safe-agent-crew-boot.sh - the in-sandbox crew boot wrapper for the
# safe-agent harness (crewmate/scout adapter).
#
# bin/fm-safe-agent-crew.sh uploads this script into the sandbox at
# /sandbox/scratch/safe-agent-crew-boot and launches it as the FOREGROUND
# command of `sandbox exec --tty` (the runtime allocates the pty outside the
# sandbox and keeps the session alive across client disconnects, so the task
# pane carries the streamed crew session while it works). The task brief is
# the boot input (uploaded by the driver as /sandbox/scratch/<label>-boot.md -
# the prompt never travels as an --env value: the CLI refuses any --env value
# over 8,192 characters or containing a newline), the crew runtime is the
# headless delegate form `mimo run --format <fmt> "<prompt>"`, and steering
# arrives through the durable exchange inbox - never keystrokes.
#
# Sequence:
#   1. cd into the task worktree (/sandbox/worktree/<label>, the per-task
#      bind of the task worktree - the image's /sandbox/worktree itself is
#      the OpenShell workspace root and refuses a mount).
#   2. Reattach git (SAFE_AGENT_CREW_GIT_* set at create by the driver):
#      a linked worktree's host gitdir lives in the bound common dir, so the
#      wrapper exports GIT_DIR/GIT_COMMON_DIR/GIT_WORK_TREE and marks the
#      bound paths safe, making the crew's commits the host worktree's own.
#   3. Write status=running, then run the boot prompt through `mimo run`.
#      With a tty stdout (the `exec --tty` launch) the run streams to the
#      pane; otherwise it lands in the exchange output record.
#   4. Drain the steering inbox: every record found by the fixed-interval
#      drain poll becomes one follow-up `mimo run` with the record's text
#      (the doorbell is only a delivery confirmation, never a wake-up
#      signal). firstmate's fm-task-inbox.v1 .msg records are acknowledged
#      by moving them to inbox/handled/ (the worker's acknowledgement
#      contract, which firstmate's sequence allocation scans; never
#      executed/); legacy timestamp-first-line .md records are archived to
#      executed/. A record moves only after its run succeeds, so a failed
#      steer stays in the inbox for the relaunch path; a record that
#      vanishes mid-drain was acknowledged by the worker, which consumes
#      records mid-run (this wrapper only re-drains on relaunch).
#   5. After the drain wait elapses with no new steering, append status=done
#      (or failed, when a run exited nonzero - a failed run exits
#      immediately, leaving its record and the undrained steering in the
#      inbox for the relaunch path) and exit. The status record is
#      append-only: the worker appends its own status history, and the
#      host-side mirror reads the last line.
#
# Resume (argv 2 = 1, passed by the driver when the sandbox already exists):
# the boot prompt already ran in the persisted session, so the wrapper skips
# it and goes straight to the drain - pending steering is executed, and the
# crew continues its task.
#
# The sandbox persists after this process exits: the persisted scratch and
# worktree survive for the relaunch path, which reattaches to them instead
# of losing the crew session's home.

set -eu

# The pane's typed doorbell (the standard inbox ring) lands in the exec pty's
# input queue, never in a consumer: the boot process reads no stdin, so a
# typed line is discarded harmlessly (it may echo into the pane and be read
# by the pane's shell after the exec ends, the ring's documented residual
# race). The exchange drain is the only steering transport.
exec 0</dev/null

prog=safe-agent-crew-boot
label=${1:-}
resume=${2:-0}
[ -n "$label" ] || { printf '%s: task label required\n' "$prog" >&2; exit 2; }

task_root=${SAFE_AGENT_CREW_TASK_ROOT:-/sandbox/exchange}
task_dir="$task_root/$label"
fmt=${SAFE_AGENT_CREW_FORMAT:-json}
drain_wait=${SAFE_AGENT_CREW_DRAIN_WAIT:-300}
poll_interval=${SAFE_AGENT_CREW_POLL_INTERVAL:-5}
case $resume in
  0|1) ;;
  *) printf '%s: unknown resume flag %s (0 or 1)\n' "$prog" "$resume" >&2; exit 2 ;;
esac

# The boot prompt transport: the driver uploads the dispatch's boot record
# into the scratch mount and places it at /sandbox/scratch/<label>-boot.md
# (an exec step proves the file before the launch). The prompt is the
# record's line 2+ - line 1 is the record's UTC timestamp. On resume the
# boot record already ran, so it is not required.
boot_file=${SAFE_AGENT_CREW_BOOT_FILE:-/sandbox/scratch/$label-boot.md}
prompt=
if [ "$resume" = 0 ]; then
  if [ -f "$boot_file" ]; then
    prompt=$(sed -n '2,$p' "$boot_file")
  fi
  [ -n "$prompt" ] \
    || { printf '%s: no boot prompt (%s missing or carries no prompt below its timestamp line)\n' "$prog" "$boot_file" >&2; exit 2; }
fi

# TMPDIR: the driver sets it to the scratch mount at create (the runtime's
# tmp-only delete exemption then covers /sandbox/scratch and /tmp for
# resolvable literal delete paths). The fallback keeps the same posture for
# a sandbox created without the env: scratch is the image's declared
# writable scratch mount.
: "${TMPDIR:=/sandbox/scratch}"
export TMPDIR

# MIMOCODE_HOME: the driver sets it to the scratch home at create, where the
# crew runtime permission profile is uploaded (config/mimocode.json). The
# exec session's env is synthesized (the image's Dockerfile ENV is not
# inherited), so the fallback keeps the same posture for a sandbox created
# without the env.
: "${MIMOCODE_HOME:=/sandbox/scratch/mimocode-home}"
export MIMOCODE_HOME

# The Firstmate-owned harness identity marker (bin/fm-harness.sh's safe-agent
# arm): processes inside the sandbox detect as safe-agent rather than as the
# delegate runtime (mimo), whose own MIMOCODE marker this outranks. The task
# env the driver passes at create corroborates it.
FM_SAFE_AGENT_HARNESS=safe-agent
export FM_SAFE_AGENT_HARNESS

# The permission backstops (the driver passes both at create; the fallback
# keeps the same posture for a sandbox created without the env).
# MIMOCODE_AUTO_APPROVE_DELETE=1 covers the bash_delete forced-ask class (a
# config allow cannot satisfy a forced-ask: rules there can only deny), and
# MIMOCODE_SKIP_ALL_FORCED_ASK_TIMEOUT_MS=60000 auto-rejects any
# still-unanswered ask after 60s instead of parking the session forever.
: "${MIMOCODE_AUTO_APPROVE_DELETE:=1}"
export MIMOCODE_AUTO_APPROVE_DELETE
: "${MIMOCODE_SKIP_ALL_FORCED_ASK_TIMEOUT_MS:=60000}"
export MIMOCODE_SKIP_ALL_FORCED_ASK_TIMEOUT_MS

command -v mimo >/dev/null 2>&1 \
  || { printf '%s: required command not found: mimo\n' "$prog" >&2; exit 1; }
command -v tee >/dev/null 2>&1 \
  || { printf '%s: required command not found: tee\n' "$prog" >&2; exit 1; }

# Git reattachment (see header step 2): export the GIT_* trio only when the
# driver's create env provided it, and mark every bound path safe - the
# bind remaps the repository's host path, which git would otherwise refuse
# as a dubious ownership. Without a provided trio (no git, or a layout the
# driver refused at launch) nothing is exported.
if [ -n "${SAFE_AGENT_CREW_GIT_DIR:-}" ]; then
  GIT_DIR=$SAFE_AGENT_CREW_GIT_DIR
  GIT_COMMON_DIR=$SAFE_AGENT_CREW_GIT_COMMON_DIR
  GIT_WORK_TREE=$SAFE_AGENT_CREW_GIT_WORK_TREE
  export GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE
  GIT_CONFIG_COUNT=${GIT_CONFIG_COUNT:-0}
  for gi_path in "$GIT_DIR" "$GIT_COMMON_DIR" "$GIT_WORK_TREE"; do
    GIT_CONFIG_COUNT=$((GIT_CONFIG_COUNT + 1))
    eval "GIT_CONFIG_KEY_$GIT_CONFIG_COUNT=safe.directory"
    eval "GIT_CONFIG_VALUE_$GIT_CONFIG_COUNT=$gi_path"
  done
  export GIT_CONFIG_COUNT
  eval "export $(for gi_i in $(seq 1 "$GIT_CONFIG_COUNT"); do printf 'GIT_CONFIG_KEY_%s GIT_CONFIG_VALUE_%s ' "$gi_i" "$gi_i"; done)"
fi

# The pane stream capability: with a tty stdout (the `exec --tty` launch)
# the run's session streams to the pane. The runtime pty is saved as fd 3
# because the exchange drain reads its result through a command substitution
# (`drained=$(drain_inbox)`), which captures fd 1 - the steering runs'
# sessions must stream to the pane, never into that variable. A plain exec
# (a relaunch against a live sandbox, a manual exec) answers no and keeps
# the plain run into the output record. SAFE_AGENT_CREW_PTY_CAPTURE=1
# forces the capture path for tests (a test host has no runtime pty; the
# run's stdout is then the test's capture pipe).
tui_stream=${TMPDIR%/}/$label/tui-stream
pty_capture=0
case ${SAFE_AGENT_CREW_PTY_CAPTURE:-} in
  1) pty_capture=1 ;;
  *)
    # set -e-safe: the tty test lives in an if condition, never as a
    # bare failing command.
    if [ -t 1 ]; then
      pty_capture=1
    fi ;;
esac
if [ "$pty_capture" -eq 1 ] && ! mkdir -p "${tui_stream%/*}" 2>/dev/null; then
  # An unwritable staging dir silently keeps the plain run - the pane
  # stream is display-only, never a run precondition.
  pty_capture=0
fi
if [ "$pty_capture" -eq 1 ]; then
  exec 3>&1
fi

mkdir -p "$task_dir/inbox" || { printf '%s: cannot create %s\n' "$prog" "$task_dir" >&2; exit 1; }
executed_dir="$task_dir/executed"
mkdir -p "$executed_dir" || { printf '%s: cannot create %s\n' "$prog" "$executed_dir" >&2; exit 1; }
handled_dir="$task_dir/inbox/handled"
mkdir -p "$handled_dir" || { printf '%s: cannot create %s\n' "$prog" "$handled_dir" >&2; exit 1; }
output="$task_dir/output.log"
status_file="$task_dir/status"

set_status() {
  # Append, never overwrite: the worker appends its own status history to
  # the same record, and the host-side mirror reads the last line - the
  # append keeps both the worker's history and this wrapper's terminal
  # state.
  printf '%s %s\n' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$status_file"
}

run_prompt() {  # <prompt>
  printf '=== %s run start ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$output"
  if [ "$pty_capture" -eq 1 ]; then
    # The pane stream: the run's stdout IS the runtime pty (fd 3, the saved
    # original stdout - the drain's command substitutions capture fd 1), so
    # its output streams live to the pane. The run markers are appended to
    # the stream directly so the pane shows the run boundaries too. The
    # run's exit code travels directly - there is no script layer to
    # swallow it.
    printf '=== %s run start ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$tui_stream"
    rc=0
    mimo run --format "$fmt" "$1" >&3 || rc=$?
    printf '=== %s run end ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$tui_stream"
    return "$rc"
  fi
  mimo run --format "$fmt" "$1" >>"$output" 2>&1
}

cd_worktree() {
  wt_root=${SAFE_AGENT_CREW_WORKTREE_ROOT:-/sandbox/worktree}
  if [ -d "$wt_root/$label" ]; then
    cd "$wt_root/$label"
  elif [ -d "$wt_root" ]; then
    cd "$wt_root"
  else
    printf '%s: no %s in the sandbox; the declared read-write mount is missing\n' "$prog" "$wt_root" >&2
    exit 1
  fi
}

drain_next_record() {
  # The first record candidate in the inbox, in sort order: a regular
  # file, never the handled/ acknowledgement directory (or any other
  # directory). The caller re-checks existence: the worker may
  # acknowledge a record between this listing and the drain's read.
  bi_name=
  # deliberate `ls | sort`: the records are firstmate's seq-named ASCII
  # files and the sandbox offers no guarantee of GNU find's -printf.
  # shellcheck disable=SC2012
  for bi_name in $(ls "$task_dir/inbox" 2>/dev/null | sort); do
    if [ -f "$task_dir/inbox/$bi_name" ]; then
      break
    fi
    bi_name=
  done
  printf '%s' "$bi_name"
}

drain_inbox() {
  # POSIX sh has no `local`; the bi_ prefix keeps these off the caller's
  # namespace (the caller's `drained` is assigned from this function's
  # stdout, not shared).
  bi_drained=0
  bi_record=$(drain_next_record)
  while [ -n "$bi_record" ]; do
    bi_path="$task_dir/inbox/$bi_record"
    if [ ! -f "$bi_path" ]; then
      bi_record=$(drain_next_record)
      continue
    fi
    case $(sed -n '1p' "$bi_path") in
      'schema=fm-task-inbox.v1')
        # firstmate's fm-task-inbox.v1 record (bin/fm-task-inbox-lib.sh
        # owns the format): the steering text is the body below the `--`
        # separator - the header (schema/at/body-terminator) is metadata,
        # never a stamp. The body-terminator mark only records a synthetic
        # final newline; command substitution drops it with the rest. The
        # record is acknowledged into inbox/handled/ - the worker's
        # acknowledgement contract, which firstmate's sequence allocation
        # scans (it does not scan executed/, so an executed/ ack could let
        # a sequence be reissued).
        bi_text=$(awk 'bi_body { print } $0 == "--" { bi_body = 1 }' "$bi_path")
        bi_stamp=$(sed -n 's/^at=//p' "$bi_path")
        bi_stamp=${bi_stamp:-"$bi_record"}
        bi_archive="$handled_dir"
        ;;
      *)
        # Legacy record: line 1 the UTC stamp, line 2+ the text.
        bi_stamp=$(sed -n '1p' "$bi_path")
        bi_text=$(sed -n '2,$p' "$bi_path")
        bi_archive="$executed_dir"
        ;;
    esac
    printf '=== %s steering (%s) ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$bi_stamp" >>"$output"
    if ! run_prompt "$bi_text"; then
      set_status failed
      printf '%s: steering run failed; the record stays in the inbox for the relaunch path\n' "$prog" >&2
      exit 1
    fi
    mkdir -p "$bi_archive" || { printf '%s: cannot create %s\n' "$prog" "$bi_archive" >&2; exit 1; }
    # Race-tolerant acknowledgement: the worker consumes records mid-run
    # and moves its own handled/ acknowledgement; if the record vanished
    # while its run was executing, the worker's move won - that is
    # success, not an error. A move that failed with the record still in
    # place is a real error, named loudly.
    if ! mv "$bi_path" "$bi_archive/$bi_record" 2>/dev/null && [ -e "$bi_path" ]; then
      printf '%s: cannot archive the steering record %s\n' "$prog" "$bi_path" >&2
      exit 1
    fi
    bi_drained=1
    bi_record=$(drain_next_record)
  done
  printf '%s\n' "$bi_drained"
}

cd_worktree
set_status running

if [ "$resume" = 1 ]; then
  printf '=== %s resume (boot prompt skipped) ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$output"
elif ! run_prompt "$prompt"; then
  set_status failed
  printf '%s: boot run failed\n' "$prog" >&2
  exit 1
fi

while :; do
  drained=$(drain_inbox)
  [ "$drained" = 1 ] && continue
  waited=0
  while [ "$waited" -lt "$drain_wait" ]; do
    sleep "$poll_interval"
    waited=$((waited + poll_interval))
    drained=$(drain_inbox)
    [ "$drained" = 1 ] && break
  done
  [ "$drained" = 1 ] && continue
  break
done

set_status "done"
