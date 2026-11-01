#!/usr/bin/env bash
# Behavior tests for the verified MiMoCode (mimo) crewmate/scout adapter.
#
# The facts pinned here are the ones a mimo release could silently change and
# the ones a wrong guess would make dangerous:
#   1. mimo sets MIMOCODE=1 on its own process and every child/tool process
#      (verified live on mimo 0.1.15: the bash tool of a live session reported
#      MIMOCODE=1 and no CLAUDECODE), so the marker is the primary identity
#      evidence and is checked before the CLAUDECODE line. MiMoCode imports
#      Claude-compatible settings and does not scrub an inherited CLAUDECODE,
#      so a structural mimo ancestor must still outrank the retained marker.
#   2. The agent binary is `.mimocode` and the launcher is a node script named
#      `mimo` (verified live, mimo 0.1.15: the agent process reports comm
#      `.mimocode` and the launcher `node .../bin/mimo`). Anchored matches
#      only; unrelated commands containing the fragment must never claim the
#      identity at detection strength.
#   3. The launch carries the brief via --prompt with MIMOCODE_PERMISSION as
#      the env allow-all and clears foreign markers at the boundary. mimo has
#      no effort flag on this path, so an effort is recorded and omitted.
#   4. mimo is a crewmate/scout adapter only: a secondmate launch is refused,
#      and nothing is armed as busy wiring because no writer could clear it.
#      With no record, the pane runtime's native verdict is the only
#      classification evidence on the backends that provide one, and native
#      idle is trusted for mimo alone (verified live, herdr).
#   5. The documented exit command is /exit; the interrupt key is not
#      verified, so the control plane refuses an interrupt until it is.
#   6. The fleet-lock ancestry walk recognizes the `.mimocode` agent binary
#      and the `node .../mimo` launcher, so a firstmate session inside a live
#      mimo primary can acquire the lock (verified live, mimo 0.1.15).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. A suite run
# from inside another harness inherits those markers, which outrank the fake
# ancestry the detection cases set up. Drop the ambient markers so the asserted
# verdict does not depend on which harness launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI GEMINI_CLI AGENT FM_OMP_HARNESS MIMOCODE

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-session-lock-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-mimo-harness)

# --- Detection --------------------------------------------------------------

test_mimo_marker_detects_the_live_session() {
  local fakebin out
  # The real ancestry walk from inside another harness (e.g. a pi session) finds
  # a nearer comm ancestor of a different family, and detect_own lets comm
  # strength outrank the marker. A fake ps reporting no harness ancestors
  # isolates the marker half of the verdict.
  fakebin=$(fm_fakebin "$TMP_ROOT/marker-no-ancestry")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(unset MIMOCODE; MIMOCODE=1 PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = mimo ] \
    || fail "MIMOCODE=1 must claim the mimo identity, got '$out'"
  pass "fm-harness.sh: the MIMOCODE marker claims the mimo identity"
}

test_mimo_ancestry_detects_the_agent_binary() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-agent")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/nvm/node-modules/@mimo-ai/cli/bin/.mimocode'; exit 0 ;;
  *"args="*) printf '%s\n' '/nvm/node-modules/@mimo-ai/cli/bin/.mimocode --prompt hi'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = mimo ] \
    || fail "the .mimocode agent binary must be detected by ancestry, got '$out'"
  pass "fm-harness.sh: ancestry detects the .mimocode agent binary"
}

test_mimo_ancestry_detects_the_node_launcher() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-launcher")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' node; exit 0 ;;
  *"args="*) printf '%s\n' 'node /nvm/bin/mimo --prompt hello'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = mimo ] \
    || fail "the node launcher script path must be detected by ancestry, got '$out'"
  pass "fm-harness.sh: ancestry detects the node mimo launcher"
}

test_mimo_ancestry_rejects_unrelated_mentions() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-negatives")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' "${FAKE_PS_COMM:?}"; exit 0 ;;
  *"args="*) printf '%s\n' "${FAKE_PS_ARGS:?}"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"

  out=$(FAKE_PS_COMM=mimosa FAKE_PS_ARGS='mimosa --serve' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != mimo ] \
    || fail "an unrelated mimosa command must not detect mimo, got '$out'"

  out=$(FAKE_PS_COMM=bash FAKE_PS_ARGS='bash -c "echo mimo --help"' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != mimo ] \
    || fail "a later shell argument naming mimo must not detect mimo, got '$out'"
  pass "fm-harness.sh: ancestry rejects unrelated mimo mentions"
}

test_mimo_comm_ancestor_outranks_a_retained_foreign_marker() {
  local fakebin out
  # mimo does not scrub an inherited CLAUDECODE, so a structural mimo ancestor
  # must still outrank the retained marker rather than being renamed away from
  # it. Pin both halves so neither can rot silently.
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-claude")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' .mimocode; exit 0 ;;
  *"args="*) printf '%s\n' '.mimocode --prompt hi'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(CLAUDECODE=1 PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = mimo ] \
    || fail "a structural mimo ancestor must outrank an inherited CLAUDECODE, got '$out'"
  pass "fm-harness.sh: a comm mimo ancestor outranks a retained foreign marker"
}

test_mimo_args_ancestor_yields_to_a_publishing_marker() {
  local fakebin out
  # The node launcher is only args strength: the weakest inference in the
  # detector. A harness that publishes its own marker must win over it, the
  # documented marker-vs-args boundary. Pin the divergence so the two cases
  # above and this one cannot all rot the same way.
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-args-claude")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' node; exit 0 ;;
  *"args="*) printf '%s\n' 'node /nvm/bin/mimo --prompt hello'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(CLAUDECODE=1 PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = claude ] \
    || fail "an args-strength mimo ancestor must yield to a publishing marker, got '$out'"
  pass "fm-harness.sh: an args mimo ancestor yields to a publishing marker"
}

# --- Control mechanics ------------------------------------------------------

test_mimo_control_mechanics_are_the_verified_ones() {
  fm_control_harness_supported mimo || fail "mimo must be a supported control harness"
  [ "$(fm_control_harness_family mimo)" = mimo ] || fail "mimo must map to its own family"
  fm_control_harness_supports_kind mimo scout || fail "mimo must run scouts"
  fm_control_harness_supports_kind mimo ship || fail "mimo must run ships"
  fm_control_harness_supports_kind mimo secondmate \
    && fail "mimo must refuse secondmates" || true
  [ "$(fm_control_exit_command mimo)" = /exit ] || fail "mimo must exit on /exit"
  fm_control_interrupt_key mimo \
    && fail "the mimo interrupt key is not verified; the control plane must refuse" || true
  fm_control_interrupt_transport mimo \
    && fail "the mimo interrupt transport is not verified; the control plane must refuse" || true
  pass "fm-control-lib.sh: mimo exits on /exit and refuses an unverified interrupt"
}

# --- Busy classification ----------------------------------------------------

test_mimo_trusts_no_stored_busy_source() {
  fm_busy_source_trusted mimo fm-spawn \
    && fail "mimo must not trust the fm-spawn seed: no writer could advance or clear it" || true
  fm_busy_source_trusted mimo mimo-hook \
    && fail "mimo must not trust a hook source it does not publish" || true
  pass "fm-busy-lib: mimo trusts no stored busy source"
}

test_mimo_native_verdict_is_the_only_evidence_without_a_record() {
  local state id verdict
  state="$TMP_ROOT/busy-native"
  mkdir -p "$state"
  id=mimo-busy-1
  # A live backend function stands in for the pane runtime: herdr reports the
  # agent state natively, and mimo has no semantic source of its own.
  fm_backend_busy_state() { printf '%s\n' "$FAKE_NATIVE_STATE"; }

  FAKE_NATIVE_STATE=busy
  verdict=$(fm_busy_classify herdr fake:pane mimo "$id" "$state")
  [ "$verdict" = "busy herdr-native" ] \
    || fail "a native busy verdict must classify busy for mimo with no record, got '$verdict'"

  FAKE_NATIVE_STATE=idle
  verdict=$(fm_busy_classify herdr fake:pane mimo "$id" "$state")
  [ "$verdict" = "idle mimo-native" ] \
    || fail "native idle must be trusted for mimo alone with no record, got '$verdict'"

  # The same native idle stays unknown for a harness that has its own semantic
  # sources: the trust is scoped to mimo, never a general idle shortcut.
  FAKE_NATIVE_STATE=idle
  verdict=$(fm_busy_classify herdr fake:pane kiro "$id" "$state")
  [ "$verdict" = "unknown missing" ] \
    || fail "native idle must stay unknown for a harness with semantic sources, got '$verdict'"

  # An unknown native verdict must not invent evidence either way.
  FAKE_NATIVE_STATE=unknown
  verdict=$(fm_busy_classify herdr fake:pane mimo "$id" "$state")
  [ "$verdict" = "unknown missing" ] \
    || fail "a native unknown verdict must not classify mimo, got '$verdict'"
  pass "fm-busy-lib: mimo's native pane verdict is its only evidence without a record"
}

# --- Fleet lock -------------------------------------------------------------

test_mimo_sessions_are_recognized_by_the_fleet_lock_walk() {
  # The lock walk matches the basename against the unanchored harness regex,
  # the exact path components, and a bare interpreter's script path, so both
  # live mimo shapes must match and an unrelated command must not.
  fm_harness_process_matches ".mimocode" ".mimocode --prompt hi" \
    || fail "the .mimocode agent binary must be recognized by the fleet-lock walk"
  fm_harness_process_matches "node" "node /nvm/bin/mimo --prompt hello" \
    || fail "the node mimo launcher must be recognized by the fleet-lock walk"
  [ "${FM_HARNESS_IS_CLAUDE:-0}" = 0 ] || fail "a mimo match must never set the claude flag"
  fm_harness_process_matches "bash" "bash -c 'echo hello'" \
    && fail "an unrelated bash command must not be recognized as a harness" || true
  pass "fm-session-lock-lib.sh: the fleet-lock walk recognizes live mimo shapes"
}

# --- Spawn ------------------------------------------------------------------

make_mimo_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) printf '1\n'; exit 0 ;;
esac
# The window this spawn created, so exact tmux target membership checks see it
# while it lives and lose it once it is closed.
window_file="$(dirname "$0")/.spawn-window"
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    [ ! -s "$window_file" ] || cat "$window_file"
    exit 0
    ;;
  new-window)
    name=
    previous=
    for arg in "$@"; do
      [ "$previous" = -n ] && name=$arg
      previous=$arg
    done
    printf '%s\n' "$name" > "$window_file"
    exit 0
    ;;
  kill-window)
    : > "$window_file"
    exit 0
    ;;
  has-session|new-session) exit 0 ;;
  send-keys)
    literal=; prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    # A spawn types a short line sourcing its staged launch file rather than the
    # launch itself, so read that file back and log what the pane will run.
    case "$literal" in
      ". '"*"'")
        staged=${literal#". '"}
        staged=${staged%"'"}
        [ ! -f "$staged" ] || literal=$(cat "$staged")
        ;;
    esac
    case "$literal" in
      *--prompt*) printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG" ;;
    esac
    exit 0
    ;;
  capture-pane)
    # A settled, idle composer so any readiness read sees a ready pane.
    printf 'shell starting\n$ \n'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/mimo" <<'SH'
#!/usr/bin/env bash
echo "fake mimo must never run a turn" >&2
exit 9
SH
  chmod +x "$fakebin/mimo"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_mimo_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_mimo_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise mimo dispatch.

## Firstmate spec
Verify launch and delivery behavior.
EOF
  printf 'mimo\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/tmux-calls.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_mimo_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

NODE_BIN=$(command -v node) || fail "test needs node"
NODE_BIN_DIR=$(dirname "$NODE_BIN")
BASE_PATH=${FM_TEST_BASE_PATH:-$NODE_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}

run_mimo_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  local base_path=${FM_TEST_MIMO_BASE_PATH:-$BASE_PATH}
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    PATH="$fakebin:$base_path" \
    "$SPAWN" "$id" "$proj" --harness mimo --mode no-mistakes --yolo off "$@" 2>&1
}

test_mimo_launch_carries_the_brief_with_the_permission_grant() {
  local id rec out rc launch meta
  id="mimo-launch-z1-$$"
  rec=$(make_mimo_spawn_case launch "$id")
  read_mimo_spawn_record "$rec"
  out=$(run_mimo_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model xiaomi/mimo-v2.5)
  rc=$?
  expect_code 0 "$rc" "mimo spawn should succeed: $out"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "$FAKEBIN_DIR/mimo" "mimo launch did not pin the resolved absolute binary"
  assert_contains "$launch" "MIMOCODE_PERMISSION=" "mimo launch omitted the env allow-all permission grant"
  assert_contains "$launch" "env -u CLAUDECODE" "mimo launch did not clear the inherited launcher marker"
  assert_contains "$launch" "-u ROVODEV_CLI" "mimo launch did not clear the rovo marker set"
  assert_contains "$launch" "--prompt " "mimo launch did not carry the brief via --prompt"
  assert_contains "$launch" "--model 'xiaomi/mimo-v2.5'" "mimo launch did not carry the requested model"
  assert_not_contains "$launch" "__MIMOBIN__" "mimo launch left its binary placeholder unsubstituted"
  assert_not_contains "$launch" "__MODELFLAG__" "mimo launch left its model placeholder unsubstituted"
  assert_not_contains "$launch" "__BRIEF__" "mimo launch left its brief placeholder unsubstituted"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'harness=mimo' "$meta" "mimo meta did not record its harness"
  assert_grep 'model=xiaomi/mimo-v2.5' "$meta" "mimo meta did not record its model"
  pass "fm-spawn: mimo launch carries brief, model, and the permission grant with cleared markers"
}

test_mimo_effort_is_recorded_but_omitted() {
  local id rec out rc launch meta
  id="mimo-effort-z2-$$"
  rec=$(make_mimo_spawn_case effort "$id")
  read_mimo_spawn_record "$rec"
  out=$(run_mimo_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --effort high)
  rc=$?
  expect_code 0 "$rc" "mimo spawn with an effort should still succeed: $out"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_not_contains "$launch" "--effort" "mimo launch passed an effort value its path has no flag for"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'effort=high' "$meta" "mimo meta did not retain the effort axis"
  pass "fm-spawn: mimo omits the effort from the launch but records it in task metadata"
}

test_mimo_secondmate_is_refused() {
  local id rec out rc
  id="mimo-secondmate-z3-$$"
  rec=$(make_mimo_spawn_case secondmate-refuse "$id")
  read_mimo_spawn_record "$rec"
  rc=0
  out=$(HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$SPAWN" "$id" --secondmate mimo 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a mimo secondmate spawn should be refused"
  assert_contains "$out" "mimo is a verified crewmate/scout adapter only" \
    "mimo secondmate refusal lacked its concrete reason"
  pass "fm-spawn: mimo cannot be launched as a secondmate"
}

test_mimo_spawn_arms_no_busy_wiring() {
  local id rec out rc statedir
  id="mimo-nowiring-z4-$$"
  rec=$(make_mimo_spawn_case nowiring "$id")
  read_mimo_spawn_record "$rec"
  out=$(run_mimo_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "mimo spawn should succeed: $out"
  statedir="$HOME_DIR/state"
  [ -e "$statedir/$id.busy-gen" ] && fail "mimo spawn armed a busy generation nothing could clear" || true
  for sidecar in "$statedir/$id.mimo-"*; do
    [ -e "$sidecar" ] || continue
    fail "mimo spawn left an adapter sidecar behind: $sidecar"
  done
  pass "fm-spawn: mimo arms no busy wiring and writes no sidecar"
}

test_mimo_missing_executable_refuses_before_the_pane() {
  local id rec out rc case_dir home proj wt fakebin
  id="mimo-nobin-z5-$$"
  case_dir="$TMP_ROOT/nobin"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  # The shared fakebin has the tmux stubs the spawn flow polls; removing its
  # mimo executable leaves the resolution nothing to find, so it must refuse
  # before any pane is created.
  fakebin=$(make_mimo_fakebin "$case_dir/fake")
  rm "$fakebin/mimo"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise mimo dispatch.

## Firstmate spec
Verify the missing-executable refusal.
EOF
  printf 'mimo\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-nobin"
  # The host resolves node from the same bin dir a live mimo install occupies,
  # so a bare PATH would find the real mimo. A symlink farm carrying node alone
  # keeps the spawn's node use working while the mimo resolution stays missing.
  local node_only="$case_dir/node-only"
  mkdir -p "$node_only"
  ln -sf "$NODE_BIN" "$node_only/node"
  touch "$home/state/.last-watcher-beat"
  rc=0
  out=$(FM_TEST_MIMO_BASE_PATH="$node_only:/usr/bin:/bin:/usr/sbin:/sbin" \
    run_mimo_spawn "$CASE_DIR" "$home" "$proj" "$wt" "$fakebin" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a spawn naming an unresolvable mimo must be refused"
  assert_contains "$out" "mimo executable not found on PATH" \
    "the missing-executable refusal lacked its concrete reason"
  out=$(cat "$case_dir/tmux-calls.log" 2>/dev/null || true)
  assert_not_contains "$out" "new-window" "the refusal created a pane before resolving the binary"
  pass "fm-spawn: a missing mimo executable refuses before the pane is created"
}

# --- Liveness vocabulary ----------------------------------------------------

test_mimo_pane_processes_classify_as_agents() {
  local verdict
  # The pane foreground is the node launcher or the Bun-compiled agent binary;
  # both live names must classify agent so a mimo worker pane never reads as an
  # agent-free pane, and an unrelated fragment command must stay other.
  . "$ROOT/bin/fm-agent-process-lib.sh"
  verdict=$(fm_agent_process_classify_name "mimo" "/nvm/bin/mimo")
  [ "$verdict" = agent ] || fail "the mimo launcher must classify agent, got '$verdict'"
  verdict=$(fm_agent_process_classify_name ".mimocode" "")
  [ "$verdict" = agent ] || fail "the .mimocode agent binary must classify agent, got '$verdict'"
  verdict=$(fm_agent_process_classify_name "mimosa" "/usr/bin/mimosa")
  [ "$verdict" = other ] || fail "an unrelated mimosa command must classify other, got '$verdict'"
  pass "fm-agent-process-lib.sh: live mimo pane process names classify agent"
}

# --- Run --------------------------------------------------------------------

test_mimo_marker_detects_the_live_session
test_mimo_ancestry_detects_the_agent_binary
test_mimo_ancestry_detects_the_node_launcher
test_mimo_ancestry_rejects_unrelated_mentions
test_mimo_comm_ancestor_outranks_a_retained_foreign_marker
test_mimo_args_ancestor_yields_to_a_publishing_marker
test_mimo_control_mechanics_are_the_verified_ones
test_mimo_trusts_no_stored_busy_source
test_mimo_native_verdict_is_the_only_evidence_without_a_record
test_mimo_sessions_are_recognized_by_the_fleet_lock_walk
test_mimo_pane_processes_classify_as_agents
test_mimo_launch_carries_the_brief_with_the_permission_grant
test_mimo_effort_is_recorded_but_omitted
test_mimo_secondmate_is_refused
test_mimo_spawn_arms_no_busy_wiring
test_mimo_missing_executable_refuses_before_the_pane
