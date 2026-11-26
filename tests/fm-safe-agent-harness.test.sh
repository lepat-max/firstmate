#!/usr/bin/env bash
# Behavior tests for the verified safe-agent (OpenShell sandbox) crewmate/scout
# adapter.
#
# The facts pinned here are the ones a stack release could silently change and
# the ones a wrong guess would make dangerous:
#   1. The launch driver is the only crew dispatch path: it verifies the
#      install (openshell CLI present, version >= 0.1.10, gateway connected
#      and NAMED) with an actionable refusal for every missing requirement,
#      and the spawn preflight runs the same verify, so the spawn and the
#      pane launch can never disagree about what a usable install is.
#   2. The brief travels as the exchange boot record (timestamp line 1, the
#      brief below it), never as a CLI argument; fm-spawn writes it before
#      the launch and the sandboxed-worker role overlay is already in it.
#   3. The create binds the task worktree, the exchange and scratch roots,
#      and the owning repository's git dir (/sandbox/gitcommon) - a policy
#      that omits a bind target is the common create refusal.
#   4. A persisted sandbox reattaches on relaunch (no second create); stop is
#      an idempotent sandbox delete because the exec session survives its
#      pane's death.
#   5. Busy is exchange-driven: the append-only status record's LAST line is
#      authoritative, output.log newer than status is busy whatever the line
#      says, and unreadable inputs are unknown, never idle.
#   6. safe-agent is a crewmate/scout adapter only: a secondmate is refused,
#      no busy generation is armed, and interrupt/exit are refused because
#      the exchange record plane has no composer and no interrupt or exit
#      key.
#   7. The in-sandbox identity marker FM_SAFE_AGENT_HARNESS plus the task env
#      claims safe-agent BEFORE the delegate runtime's MIMOCODE marker would
#      rename it to mimo.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Drop ambient harness markers so the detection cases do not depend on which
# harness launched the suite (the mimo shape).
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI GEMINI_CLI AGENT FM_OMP_HARNESS MIMOCODE \
  FM_SAFE_AGENT_HARNESS SAFE_AGENT_CREW_TASK

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
DRIVER="$ROOT/bin/fm-safe-agent-crew.sh"
TMP_ROOT=$(fm_test_tmproot fm-safe-agent-harness)

NODE_BIN=$(command -v node) || fail "test needs node"
NODE_BIN_DIR=$(dirname "$NODE_BIN")
FM_TEST_BASE_PATH=${FM_TEST_BASE_PATH:-$NODE_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}

test_version_comparison() {
  # shellcheck source=/dev/null
  . "$DRIVER"
  fm_safe_agent_version_at_least 0.1.10 0.1.10 || fail "0.1.10 must satisfy the 0.1.10 floor"
  fm_safe_agent_version_at_least 0.1.11 0.1.10 || fail "0.1.11 must satisfy the 0.1.10 floor"
  fm_safe_agent_version_at_least 0.2.0 0.1.10 || fail "0.2.0 must satisfy the 0.1.10 floor"
  fm_safe_agent_version_at_least 0.1.9 0.1.10 && fail "0.1.9 must not satisfy the 0.1.10 floor" || true
  fm_safe_agent_version_at_least 1.0 0.1.10 || fail "1.0 must satisfy the 0.1.10 floor"
  fm_safe_agent_version_at_least '' 0.1.10 2>/dev/null \
    && fail "an empty version must be unparseable, not a pass" || true
  fm_safe_agent_version_at_least 0.1.10-rc1 0.1.10 || fail "a release suffix must not drop below the floor"
  pass "fm-safe-agent-crew.sh: the version floor comparison is exact and suffix-tolerant"
}

test_scoped_title_stays_within_the_name_cap() {
  # shellcheck source=/dev/null
  . "$DRIVER"
  local short long out len
  short=$(fm_safe_agent_scoped_title 'fm-abc123')
  case "$short" in
    fm????-fm-abc123) ;;
    *) fail "a short label keeps its full name under the home scope, got '$short'" ;;
  esac
  long=$(fm_safe_agent_scoped_title 'fm-a-very-long-task-label-that-exceeds-the-name-cap')
  len=${#long}
  [ "$len" -le 19 ] || fail "a long label must truncate to the 19-character cap, got $len chars: '$long'"
  local long2
  long2=$(fm_safe_agent_scoped_title 'fm-a-very-long-task-label-that-exceeds-the-name-caps')
  [ "$long" != "$long2" ] || fail "same-prefix long labels must stay distinguishable after truncation"
  pass "fm-safe-agent-crew.sh: sandbox names are home-scoped and truncated with a distinguishing hash"
}

test_json_string_escapes_and_refuses() {
  # shellcheck source=/dev/null
  . "$DRIVER"
  [ "$(fm_safe_agent_json_string '/tmp/a"b')" = '/tmp/a\"b' ] \
    || fail "a double quote must be escaped, not mangled"
  [ "$(fm_safe_agent_json_string '/tmp/a\b')" = '/tmp/a\\b' ] \
    || fail "a backslash must be escaped, not mangled"
  fm_safe_agent_json_string "$(printf '/tmp/a\nb')" \
    && fail "a path with a newline must be refused, not mangled into the mount JSON" || true
  pass "fm-safe-agent-crew.sh: mount-JSON values are escaped and control characters refused"
}

make_safe_agent_fakebin() {
  local dir=$1 fakebin version gw fake_status
  fakebin=$(fm_fakebin "$dir")
  version=${FAKE_OPENSHELL_VERSION:-0.1.10}
  gw=${FAKE_OPENSHELL_GATEWAY:-safe-agent}
  # The status output is baked at generation time: the fake runs under set -u,
  # so a runtime $gw would crash it into an unreadable verdict instead of the
  # gateway state this case is testing.
  case $gw in
    none) fake_status="printf 'Status: disconnected\\n'" ;;
    *) fake_status="printf 'Status: connected\\nGateway: $gw\\n'" ;;
  esac
  : > "${dir}/window"
  cat > "$fakebin/openshell" <<SH
#!/usr/bin/env bash
set -u
log=\${FM_FAKE_OPENSHELL_LOG:-}
[ -z "\$log" ] || printf '%s\n' "\$*" >> "\$log"
state=\$(cat "\$FM_FAKE_SANDBOX_STATE" 2>/dev/null || true)
case "\$1" in
  --version) printf 'openshell %s\n' "$version"; exit 0 ;;
  status)
    $fake_status
    exit 0
    ;;
  provider)
    printf 'Credential keys: FAKE_PROVIDER_KEY\n'
    exit 0
    ;;
  sandbox)
    case "\$2" in
      get)
        [ "\$state" = exists ] && exit 0
        printf 'sandbox not found\n' >&2
        exit 1
        ;;
      create) printf 'exists\n' > "\$FM_FAKE_SANDBOX_STATE"; exit 0 ;;
      upload) exit 0 ;;
      exec)
        case "\$*" in
          *safe-agent-crew-boot*)
            [ -z "\${FM_FAKE_CREW_STATUS:-}" ] || printf 'running %s\n' "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "\$FM_FAKE_CREW_STATUS"
            ;;
        esac
        exit 0
        ;;
      delete) : > "\$FM_FAKE_SANDBOX_STATE"; exit 0 ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/openshell"
  : > "${dir}/window"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) printf '1\n'; exit 0 ;;
esac
window_file="$(dirname "$0")/../window"
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
    printf '%s\n' "$name" >> "$window_file"
    printf '@%s\n' "$(wc -l < "$window_file" | tr -d ' ')"
    exit 0
    ;;
  kill-window)
    : > "$window_file"
    exit 0
    ;;
  set-window-option) exit 0 ;;
  has-session|new-session) exit 0 ;;
  send-keys)
    literal=
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        ". '"*"'") staged=${literal#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || literal=$(cat "$staged") ;;
      esac
      printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
      # The pane "ran" the launch: the boot wrapper's first status append is
      # what the spawn's launch-then-confirm gate waits for.
      case "$literal" in
        *"launch fm-"*)
          [ -z "${FM_FAKE_CREW_STATUS:-}" ] || printf 'running %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$FM_FAKE_CREW_STATUS"
          ;;
      esac
      exit 0
    fi
    exit 0
    ;;
  capture-pane) printf 'shell starting\n$ \n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_safe_agent_case() {
  local name=$1 id=$2 case_dir home
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'safe-agent\n' > "$home/config/crew-harness"
  printf 'manual\n' > "$home/config/backlog-backend"
  mkdir -p "$case_dir/exchange" "$case_dir/scratch"
  cat > "$home/config/safe-agent-sandbox-env" <<EOF
FM_BACKEND_SANDBOX_OPENSHELL=openshell
FM_BACKEND_SANDBOX_IMAGE=safe-agent-delegate:dev
FM_BACKEND_SANDBOX_POLICY=$case_dir/policy.json
FM_BACKEND_SANDBOX_EXCHANGE_ROOT=$case_dir/exchange
FM_BACKEND_SANDBOX_SCRATCH_ROOT=$case_dir/scratch
EOF
  printf '{}\n' > "$home/config/safe-agent-crew-mimocode.json"
  printf '%s\n' "$case_dir|$home"
}

read_safe_agent_case() {
  IFS='|' read -r CASE_DIR HOME_DIR <<EOF
$1
EOF
}

test_verify_refuses_a_missing_cli_with_remediation() {
  local rec out rc
  rec=$(make_safe_agent_case verify-nocli "verify-nocli-$$")
  read_safe_agent_case "$rec"
  rc=0
  out=$(FM_HOME="$HOME_DIR" PATH="$FM_TEST_BASE_PATH" "$DRIVER" verify 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a missing openshell CLI must refuse the verify"
  assert_contains "$out" "openshell" "the missing-CLI refusal must name the missing binary"
  assert_contains "$out" "remediation" "the missing-CLI refusal must be actionable"
  pass "fm-safe-agent-crew.sh: verify refuses a missing openshell CLI with its remediation"
}

test_verify_refuses_an_older_cli() {
  local rec out rc fakebin
  rec=$(make_safe_agent_case verify-old "verify-old-$$")
  read_safe_agent_case "$rec"
  fakebin=$(FAKE_OPENSHELL_VERSION=0.1.7 make_safe_agent_fakebin "$TMP_ROOT/verify-old-bin")
  rc=0
  out=$(FM_HOME="$HOME_DIR" PATH="$fakebin:$FM_TEST_BASE_PATH" "$DRIVER" verify 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an older openshell must refuse the verify"
  assert_contains "$out" ">= 0.1.10" "the old-CLI refusal must name the version floor"
  pass "fm-safe-agent-crew.sh: verify refuses an older-than-floor openshell"
}

test_verify_refuses_a_missing_gateway() {
  local rec out rc fakebin
  rec=$(make_safe_agent_case verify-gw "verify-gw-$$")
  read_safe_agent_case "$rec"
  fakebin=$(FAKE_OPENSHELL_GATEWAY=none make_safe_agent_fakebin "$TMP_ROOT/verify-gw-bin")
  rc=0
  out=$(FM_HOME="$HOME_DIR" PATH="$fakebin:$FM_TEST_BASE_PATH" "$DRIVER" verify 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a disconnected gateway must refuse the verify"
  assert_contains "$out" "gateway" "the disconnected-gateway refusal must name the gateway"
  assert_contains "$out" "safe-agent up" "the disconnected-gateway refusal must name the remediation"
  pass "fm-safe-agent-crew.sh: verify refuses a disconnected gateway with its remediation"
}

test_verify_refuses_a_foreign_gateway() {
  local rec out rc fakebin
  rec=$(make_safe_agent_case verify-foreign "verify-foreign-$$")
  read_safe_agent_case "$rec"
  fakebin=$(FAKE_OPENSHELL_GATEWAY=other-gateway make_safe_agent_fakebin "$TMP_ROOT/verify-foreign-bin")
  rc=0
  out=$(FM_HOME="$HOME_DIR" PATH="$fakebin:$FM_TEST_BASE_PATH" "$DRIVER" verify 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a foreign connected gateway must refuse the verify"
  assert_contains "$out" "other-gateway" "the foreign-gateway refusal must name what it found"
  pass "fm-safe-agent-crew.sh: verify refuses a foreign gateway instead of launching on it"
}

test_verify_accepts_the_validated_stack() {
  local rec out rc fakebin
  rec=$(make_safe_agent_case verify-ok "verify-ok-$$")
  read_safe_agent_case "$rec"
  fakebin=$(make_safe_agent_fakebin "$TMP_ROOT/verify-ok-bin")
  rc=0
  out=$(FM_HOME="$HOME_DIR" PATH="$fakebin:$FM_TEST_BASE_PATH" "$DRIVER" verify 2>&1) || rc=$?
  expect_code 0 "$rc" "the validated stack must pass verify"
  assert_contains "$out" "0.1.10" "the verify summary must name the verified version"
  assert_contains "$out" "gateway connected" "the verify summary must name the gateway state"
  pass "fm-safe-agent-crew.sh: verify accepts openshell 0.1.10 with the launcher's gateway"
}

test_launch_creates_uploads_and_boots_once() {
  local rec id wt out rc fakebin log exchange
  id="sa-launch-$$"
  rec=$(make_safe_agent_case launch "$id")
  read_safe_agent_case "$rec"
  fakebin=$(make_safe_agent_fakebin "$CASE_DIR/fake")
  log="$CASE_DIR/openshell.log"
  wt="$CASE_DIR/repo"
  git init -q "$wt"
  ( cd "$wt" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
  exchange="$CASE_DIR/exchange/fm-$id"
  mkdir -p "$exchange"
  { date -u '+%Y-%m-%dT%H:%M:%SZ'; printf 'Fix the thing.\n'; } >"$exchange/boot.md"
  rc=0
  out=$(FM_HOME="$HOME_DIR" FM_FAKE_OPENSHELL_LOG="$log" \
    FM_FAKE_SANDBOX_STATE="$CASE_DIR/sandbox.state" \
    PATH="$fakebin:$FM_TEST_BASE_PATH" \
    "$DRIVER" launch "fm-$id" "$wt" 2>&1) || rc=$?
  expect_code 0 "$rc" "a valid launch must succeed"
  # The create carries the scoped name, the pinned image and policy, the task
  # env, the git reattachment env, and the four bind mounts.
  assert_contains "$(cat "$log")" "create --name fm" "the create must use the home-scoped name"
  assert_contains "$(cat "$log")" "--from safe-agent-delegate:dev" "the create must use the configured image"
  assert_contains "$(cat "$log")" "--policy $CASE_DIR/policy.json" "the create must use the configured policy"
  assert_contains "$(cat "$log")" "SAFE_AGENT_CREW_TASK=fm-$id" "the create must carry the task env"
  assert_contains "$(cat "$log")" "SAFE_AGENT_CREW_GIT_COMMON_DIR=/sandbox/gitcommon" "the create must reattach the bound git common dir"
  assert_contains "$(cat "$log")" "SAFE_AGENT_CREW_GIT_WORK_TREE=/sandbox/worktree/fm-$id" "the create must reattach the bound work tree"
  assert_contains "$(cat "$log")" "--driver-config-json" "the create must carry the driver config"
  assert_contains "$(cat "$log")" "/sandbox/worktree/fm-$id" "the driver config must bind the task worktree"
  assert_contains "$(cat "$log")" "/sandbox/gitcommon" "the driver config must bind the owning git dir"
  assert_contains "$(cat "$log")" "/sandbox/exchange" "the driver config must bind the exchange root"
  assert_contains "$(cat "$log")" "/sandbox/scratch" "the driver config must bind the scratch root"
  assert_contains "$(cat "$log")" "fm-safe-agent-crew-boot.sh" "the launch must upload the boot wrapper"
  assert_contains "$(cat "$log")" "boot.md" "the launch must upload the boot record"
  assert_contains "$(cat "$log")" "safe-agent-crew-boot" "the launch must exec the boot wrapper"
  [ -s "$exchange/sandbox-name" ] || fail "the launch must record the sandbox name for the stop primitive"
  pass "fm-safe-agent-crew.sh: launch creates, uploads, and boots the crew with the four binds and the task env"
}

test_launch_refuses_a_missing_boot_record() {
  local rec id wt out rc fakebin
  id="sa-noboot-$$"
  rec=$(make_safe_agent_case noboot "$id")
  read_safe_agent_case "$rec"
  fakebin=$(make_safe_agent_fakebin "$CASE_DIR/fake")
  wt="$CASE_DIR/repo"
  git init -q "$wt"
  ( cd "$wt" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
  rc=0
  out=$(FM_HOME="$HOME_DIR" PATH="$fakebin:$FM_TEST_BASE_PATH" \
    "$DRIVER" launch "fm-$id" "$wt" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a launch without its boot record must refuse"
  assert_contains "$out" "boot.md" "the missing-boot-record refusal must name the boot record"
  assert_contains "$out" "re-run the spawn" "the missing-boot-record refusal must name its remediation"
  pass "fm-safe-agent-crew.sh: launch refuses a missing boot record with its remediation"
}

test_launch_reattaches_to_a_persisted_sandbox() {
  local rec id wt out rc fakebin log exchange
  id="sa-resume-$$"
  rec=$(make_safe_agent_case resume "$id")
  read_safe_agent_case "$rec"
  fakebin=$(make_safe_agent_fakebin "$CASE_DIR/fake")
  log="$CASE_DIR/openshell.log"
  wt="$CASE_DIR/repo"
  git init -q "$wt"
  ( cd "$wt" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
  exchange="$CASE_DIR/exchange/fm-$id"
  mkdir -p "$exchange"
  { date -u '+%Y-%m-%dT%H:%M:%SZ'; printf 'Fix the thing.\n'; } >"$exchange/boot.md"
  printf 'exists\n' > "$CASE_DIR/sandbox.state"
  rc=0
  out=$(FM_HOME="$HOME_DIR" FM_FAKE_OPENSHELL_LOG="$log" \
    FM_FAKE_SANDBOX_STATE="$CASE_DIR/sandbox.state" \
    PATH="$fakebin:$FM_TEST_BASE_PATH" \
    "$DRIVER" launch "fm-$id" "$wt" 2>&1) || rc=$?
  expect_code 0 "$rc" "a resume launch must succeed"
  assert_contains "$out" "reattaching" "a resume launch must say it reattached"
  if grep -q "create --name" "$log"; then
    fail "a resume launch must not create a second sandbox"
  fi
  assert_contains "$(cat "$log")" "safe-agent-crew-boot" "a resume launch must still exec the boot wrapper"
  pass "fm-safe-agent-crew.sh: a persisted sandbox reattaches without a second create"
}

test_stop_is_an_idempotent_sandbox_delete() {
  local rec id out rc fakebin log
  id="sa-stop-$$"
  rec=$(make_safe_agent_case stop "$id")
  read_safe_agent_case "$rec"
  fakebin=$(make_safe_agent_fakebin "$CASE_DIR/fake")
  log="$CASE_DIR/openshell.log"
  printf 'exists\n' > "$CASE_DIR/sandbox.state"
  rc=0
  out=$(FM_HOME="$HOME_DIR" FM_FAKE_OPENSHELL_LOG="$log" \
    FM_FAKE_SANDBOX_STATE="$CASE_DIR/sandbox.state" \
    PATH="$fakebin:$FM_TEST_BASE_PATH" \
    "$DRIVER" stop "fm-$id" 2>&1) || rc=$?
  expect_code 0 "$rc" "a stop of an existing sandbox must succeed"
  assert_contains "$(cat "$log")" "delete" "the stop must run sandbox delete"
  # Now the sandbox is gone: the second stop is silent success, never an error.
  rc=0
  out=$(FM_HOME="$HOME_DIR" FM_FAKE_OPENSHELL_LOG="$log" \
    FM_FAKE_SANDBOX_STATE="$CASE_DIR/sandbox.state" \
    PATH="$fakebin:$FM_TEST_BASE_PATH" \
    "$DRIVER" stop "fm-$id" 2>&1) || rc=$?
  expect_code 0 "$rc" "a stop of an already-deleted sandbox must succeed silently"
  pass "fm-safe-agent-crew.sh: stop is an idempotent sandbox delete"
}

test_state_reports_missing_without_guessing() {
  local rec id out rc fakebin
  id="sa-state-$$"
  rec=$(make_safe_agent_case state "$id")
  read_safe_agent_case "$rec"
  fakebin=$(make_safe_agent_fakebin "$CASE_DIR/fake")
  rc=0
  out=$(FM_HOME="$HOME_DIR" FM_FAKE_SANDBOX_STATE="$CASE_DIR/sandbox.state" \
    PATH="$fakebin:$FM_TEST_BASE_PATH" \
    "$DRIVER" state "fm-$id" 2>&1) || rc=$?
  expect_code 0 "$rc" "the state verb must not fail"
  [ "$out" = missing ] || fail "a sandbox the gateway cannot find must read missing, got '$out'"
  pass "fm-safe-agent-crew.sh: state reports missing for a sandbox the gateway cannot find"
}

make_safe_agent_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'safe-agent\n' > "$home/config/crew-harness"
  printf 'manual\n' > "$home/config/backlog-backend"
  mkdir -p "$case_dir/exchange" "$case_dir/scratch"
  cat > "$home/config/safe-agent-sandbox-env" <<EOF
FM_BACKEND_SANDBOX_OPENSHELL=openshell
FM_BACKEND_SANDBOX_IMAGE=safe-agent-delegate:dev
FM_BACKEND_SANDBOX_POLICY=$case_dir/policy.json
FM_BACKEND_SANDBOX_EXCHANGE_ROOT=$case_dir/exchange
FM_BACKEND_SANDBOX_SCRATCH_ROOT=$case_dir/scratch
EOF
  printf '{}\n' > "$home/config/safe-agent-crew-mimocode.json"
  fakebin=$(make_safe_agent_fakebin "$case_dir/fake")
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise safe-agent dispatch.

## Firstmate spec
Verify launch and delivery behavior.
EOF
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/tmux-calls.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_safe_agent_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_safe_agent_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_CREW_STATUS="$case_dir/exchange/fm-$id/status" \
    FM_FAKE_SANDBOX_STATE="$case_dir/sandbox.state" \
    FM_SAFE_AGENT_READY_POLLS=40 FM_SAFE_AGENT_POLL_INTERVAL=0.1 \
    PATH="$fakebin:$FM_TEST_BASE_PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off "$@" 2>&1
}

test_spawn_writes_the_boot_record_and_launches_the_driver() {
  local id rec out rc launch boot brief
  id="sa-spawn-z1-$$"
  rec=$(make_safe_agent_spawn_case spawn "$id")
  read_safe_agent_spawn_record "$rec"
  out=$(run_safe_agent_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "safe-agent spawn should succeed"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "launch fm-$id" "the pane launch did not dispatch the driver with the task label"
  assert_contains "$launch" "$WT_DIR" "the pane launch did not carry the task worktree"
  assert_contains "$launch" "fm-safe-agent-crew.sh" "the pane launch did not name the launch driver"
  assert_not_contains "$launch" "__SABIN__" "the launch left its driver placeholder unsubstituted"
  assert_not_contains "$launch" "__TASKLABEL__" "the launch left its label placeholder unsubstituted"
  assert_not_contains "$launch" "__BRIEF__" "the launch left a brief placeholder unsubstituted"
  # The brief travels as the exchange boot record: timestamp line 1, the
  # launch brief (with the sandboxed-worker role overlay) below it.
  boot="$CASE_DIR/exchange/fm-$id/boot.md"
  [ -s "$boot" ] || fail "the spawn did not write the exchange boot record"
  boot_head=$(sed -n '1p' "$boot")
  printf '%s\n' "$boot_head" | grep -qE '^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    || fail "the boot record's line 1 must be the UTC timestamp, got '$boot_head'"
  assert_contains "$(cat "$boot")" "Exercise safe-agent dispatch" "the boot record must carry the brief"
  assert_contains "$(cat "$boot")" "Sandboxed crew role overlay" "the boot record's brief must carry the sandboxed-worker role overlay"
  # The launch brief on disk carries the overlay too (the boot record is
  # written from it).
  brief="$HOME_DIR/data/$id/launch-brief.md"
  assert_contains "$(cat "$brief")" "Sandboxed crew role overlay" "the launch brief must carry the sandboxed-worker role overlay"
  assert_grep 'harness=safe-agent' "$HOME_DIR/state/$id.meta" "safe-agent meta did not record its harness"
  pass "fm-spawn: safe-agent writes the boot record, appends the overlay, and dispatches the driver"
}

test_spawn_refuses_a_model_axis() {
  local id rec out rc
  id="sa-model-z2-$$"
  rec=$(make_safe_agent_spawn_case model "$id")
  read_safe_agent_spawn_record "$rec"
  rc=0
  out=$(run_safe_agent_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model some/model) || rc=$?
  [ "$rc" -ne 0 ] || fail "a safe-agent spawn with --model must be refused"
  assert_contains "$out" "pinned delegate runtime" "the model refusal must name the pinned delegate runtime"
  pass "fm-spawn: safe-agent refuses a per-task model axis"
}

test_spawn_refuses_an_effort_axis() {
  local id rec out rc
  id="sa-effort-z3-$$"
  rec=$(make_safe_agent_spawn_case effort "$id")
  read_safe_agent_spawn_record "$rec"
  rc=0
  out=$(run_safe_agent_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --effort high) || rc=$?
  [ "$rc" -ne 0 ] || fail "a safe-agent spawn with --effort must be refused"
  assert_contains "$out" "no per-task effort axis" "the effort refusal must name the missing axis"
  pass "fm-spawn: safe-agent refuses a per-task effort axis"
}

test_spawn_refuses_a_secondmate() {
  local id rec out rc
  id="sa-secondmate-z4-$$"
  rec=$(make_safe_agent_spawn_case secondmate "$id")
  read_safe_agent_spawn_record "$rec"
  rc=0
  out=$(HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN_DIR:$FM_TEST_BASE_PATH" \
    "$SPAWN" "$id" --secondmate safe-agent 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a safe-agent secondmate spawn should be refused"
  assert_contains "$out" "safe-agent is a verified crewmate/scout adapter only" \
    "safe-agent secondmate refusal lacked its concrete reason"
  pass "fm-spawn: safe-agent cannot be launched as a secondmate"
}

test_spawn_fails_loudly_when_the_install_is_unusable() {
  local id rec out rc
  id="sa-preflight-z5-$$"
  rec=$(make_safe_agent_spawn_case preflight "$id")
  read_safe_agent_spawn_record "$rec"
  # No openshell anywhere on PATH: the spawn preflight must refuse through the
  # driver's own verify, not stage a pane that dies with command-not-found.
  rc=0
  out=$(HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" \
    PATH="$FM_TEST_BASE_PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a spawn on a missing openshell must be refused at preflight"
  assert_contains "$out" "safe-agent preflight failed" "the preflight refusal must name the failed preflight"
  pass "fm-spawn: safe-agent refuses the spawn at preflight when the install is unusable"
}

test_busy_source_reads_the_exchange_records() {
  local rec id state_dir exchange out
  id="sa-busy-z6-$$"
  rec=$(make_safe_agent_case busy "$id")
  read_safe_agent_case "$rec"
  state_dir="$HOME_DIR/state"
  # The busy source resolves the exchange root through the driver's config,
  # which reads the case home.
  # shellcheck disable=SC2034 # FM_HOME is read by the sourced lib's dynamic scope
  FM_HOME=$HOME_DIR
  mkdir -p "$state_dir"
  printf 'harness=safe-agent\n' > "$state_dir/$id.meta"
  exchange="$CASE_DIR/exchange/fm-$id"
  mkdir -p "$exchange"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-busy-lib.sh"
  # No status record yet: unknown, never idle.
  fm_busy_safe_agent_exchange "$id" "$state_dir" \
    && fail "a missing exchange status must read unknown" || true
  printf 'running 2026-11-26T10:00:00Z\n' > "$exchange/status"
  out=$(fm_busy_safe_agent_exchange "$id" "$state_dir")
  [ "$out" = busy ] || fail "a running status must read busy, got '$out'"
  printf 'working [at=1795674085]: on it\n' >> "$exchange/status"
  out=$(fm_busy_safe_agent_exchange "$id" "$state_dir")
  [ "$out" = busy ] || fail "a working status must read busy, got '$out'"
  printf 'done 2026-11-26T10:05:00Z\n' >> "$exchange/status"
  out=$(fm_busy_safe_agent_exchange "$id" "$state_dir")
  [ "$out" = idle ] || fail "a done status must read idle, got '$out'"
  # Output growth after the last status write is positive proof of work in
  # flight, whatever the last line says.
  printf '=== later run start ===\n' > "$exchange/output.log"
  touch "$exchange/output.log"
  sleep 1
  touch "$exchange/status"
  out=$(fm_busy_safe_agent_exchange "$id" "$state_dir")
  [ "$out" = idle ] || fail "a status newer than output must keep the last-line verdict, got '$out'"
  sleep 1
  touch "$exchange/output.log"
  out=$(fm_busy_safe_agent_exchange "$id" "$state_dir")
  [ "$out" = busy ] || fail "output newer than status must read busy, got '$out'"
  # A task whose meta does not name this harness never reads through the
  # exchange source.
  printf 'harness=mimo\n' > "$state_dir/$id.meta"
  fm_busy_safe_agent_exchange "$id" "$state_dir" \
    && fail "a non-safe-agent task must not classify through the exchange source" || true
  pass "fm-busy-lib.sh: the safe-agent busy source reads the exchange records with last-line authority"
}

test_status_mirror_folds_the_exchange_record() {
  local rec id state_dir exchange
  id="sa-mirror-z7-$$"
  rec=$(make_safe_agent_case mirror "$id")
  read_safe_agent_case "$rec"
  state_dir="$HOME_DIR/state"
  # Same driver-config resolution as the busy source above.
  FM_HOME=$HOME_DIR
  mkdir -p "$state_dir"
  printf 'harness=safe-agent\n' > "$state_dir/$id.meta"
  exchange="$CASE_DIR/exchange/fm-$id"
  mkdir -p "$exchange"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-busy-lib.sh"
  printf 'running 2026-11-26T10:00:00Z\n' > "$exchange/status"
  fm_busy_safe_agent_status_mirror "$id" "$state_dir"
  assert_contains "$(cat "$state_dir/$id.status")" "running 2026-11-26T10:00:00Z" \
    "the mirror must fold the exchange status into the host status log"
  printf 'done 2026-11-26T10:05:00Z\n' >> "$exchange/status"
  fm_busy_safe_agent_status_mirror "$id" "$state_dir"
  assert_contains "$(cat "$state_dir/$id.status")" "done 2026-11-26T10:05:00Z" \
    "the mirror must fold only the newly appended bytes"
  # A task whose meta does not name this harness is a quiet no-op.
  printf 'harness=mimo\n' > "$state_dir/$id.meta"
  : > "$state_dir/$id.status"
  fm_busy_safe_agent_status_mirror "$id" "$state_dir"
  [ -s "$state_dir/$id.status" ] && fail "the mirror must not touch a non-safe-agent task" || true
  pass "fm-busy-lib.sh: the status mirror folds appended exchange bytes into the host status log"
}

test_inbox_redirects_to_the_exchange() {
  local rec id state_dir exchange dir
  id="sa-inbox-z8-$$"
  rec=$(make_safe_agent_case inbox "$id")
  read_safe_agent_case "$rec"
  state_dir="$HOME_DIR/state"
  mkdir -p "$state_dir"
  exchange="$CASE_DIR/exchange"
  FM_BACKEND_SANDBOX_EXCHANGE_ROOT=$exchange
  export FM_BACKEND_SANDBOX_EXCHANGE_ROOT
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-task-inbox-lib.sh"
  # Without the harness meta line the classic shape holds.
  dir=$(fm_task_inbox_dir "$state_dir" "$id")
  [ "$dir" = "$state_dir/$id.inbox" ] || fail "a non-safe-agent task keeps the classic inbox shape, got '$dir'"
  printf 'harness=safe-agent\n' > "$state_dir/$id.meta"
  dir=$(fm_task_inbox_dir "$state_dir" "$id")
  [ "$dir" = "$exchange/fm-$id/inbox" ] || fail "a safe-agent task's inbox must live in its exchange dir, got '$dir'"
  unset FM_BACKEND_SANDBOX_EXCHANGE_ROOT
  pass "fm-task-inbox-lib.sh: the safe-agent inbox redirects into the task's exchange dir"
}

test_control_mechanics_are_the_verified_ones() {
  fm_control_harness_supported safe-agent || fail "safe-agent must be a supported control harness"
  [ "$(fm_control_harness_family safe-agent)" = safe-agent ] || fail "safe-agent must map to its own family"
  fm_control_harness_supports_kind safe-agent scout || fail "safe-agent must run scouts"
  fm_control_harness_supports_kind safe-agent ship || fail "safe-agent must run ships"
  fm_control_harness_supports_kind safe-agent secondmate \
    && fail "safe-agent must refuse secondmates" || true
  fm_control_exit_command safe-agent \
    && fail "safe-agent has no composer exit key; the control plane must refuse an exit" || true
  fm_control_interrupt_key safe-agent \
    && fail "safe-agent has no interrupt key; the control plane must refuse an interrupt" || true
  pass "fm-control-lib.sh: safe-agent refuses unverified exit and interrupt verbs"
}

test_marker_claims_the_identity_over_the_delegate_runtime() {
  local out
  out=$(FM_SAFE_AGENT_HARNESS=safe-agent SAFE_AGENT_CREW_TASK=fm-x "$HARNESS")
  [ "$out" = safe-agent ] \
    || fail "the launch marker plus the task env must claim the safe-agent identity, got '$out'"
  # The delegate runtime inside the sandbox is mimo: with both markers set the
  # safe-agent identity must win, because the sandbox worker would otherwise
  # be renamed to mimo.
  out=$(FM_SAFE_AGENT_HARNESS=safe-agent SAFE_AGENT_CREW_TASK=fm-x MIMOCODE=1 "$HARNESS")
  [ "$out" = safe-agent ] \
    || fail "the safe-agent marker must outrank the delegate runtime's MIMOCODE marker, got '$out'"
  # The marker alone, without the task env corroborating it, is not enough.
  unset SAFE_AGENT_CREW_TASK
  out=$(FM_SAFE_AGENT_HARNESS=safe-agent "$HARNESS")
  [ "$out" != safe-agent ] \
    || fail "the marker without the task env must not claim the safe-agent identity, got '$out'"
  pass "fm-harness.sh: the safe-agent marker claims the identity and outranks the delegate runtime's marker"
}

test_version_comparison
test_scoped_title_stays_within_the_name_cap
test_json_string_escapes_and_refuses
test_verify_refuses_a_missing_cli_with_remediation
test_verify_refuses_an_older_cli
test_verify_refuses_a_missing_gateway
test_verify_refuses_a_foreign_gateway
test_verify_accepts_the_validated_stack
test_launch_creates_uploads_and_boots_once
test_launch_refuses_a_missing_boot_record
test_launch_reattaches_to_a_persisted_sandbox
test_stop_is_an_idempotent_sandbox_delete
test_state_reports_missing_without_guessing
test_spawn_writes_the_boot_record_and_launches_the_driver
test_spawn_refuses_a_model_axis
test_spawn_refuses_an_effort_axis
test_spawn_refuses_a_secondmate
test_spawn_fails_loudly_when_the_install_is_unusable
test_busy_source_reads_the_exchange_records
test_status_mirror_folds_the_exchange_record
test_inbox_redirects_to_the_exchange
test_control_mechanics_are_the_verified_ones
test_marker_claims_the_identity_over_the_delegate_runtime
