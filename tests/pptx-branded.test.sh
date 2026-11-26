#!/usr/bin/env bash
# Behavior tests for the pptx-branded skill scripts (.agents/skills/pptx-branded).
#
# The failure classes pinned here, on real synthetic pptx files (no corporate
# template needed): slide cloning keeps media relationships and reopens clean;
# zone replacement preserves paragraph geometry (count kept, extra paragraphs
# blanked); the update diff classifies keep/regen/pin_keep/add/delete correctly;
# and an applied update regenerates only non-pinned changed slides while pinned
# and identical slides stay byte-identical in content.
#
# Needs a Python with python-pptx (and Pillow). Set PPTX_SKILL_PYTHON to point
# at one; the suite skips when neither that nor python3 has the dependency.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPTS="$ROOT/.agents/skills/pptx-branded/scripts"

resolve_python() {
  if [ -n "${PPTX_SKILL_PYTHON:-}" ]; then
    printf '%s\n' "$PPTX_SKILL_PYTHON"
    return 0
  fi
  if python3 -c 'import pptx, PIL' >/dev/null 2>&1; then
    printf '%s\n' python3
    return 0
  fi
  return 1
}

PY=$(resolve_python) || { echo "skip: python-pptx unavailable (set PPTX_SKILL_PYTHON)"; exit 0; }
command -v "$PY" >/dev/null 2>&1 || { echo "skip: PPTX_SKILL_PYTHON does not resolve"; exit 0; }

TMP_ROOT=$(fm_test_tmproot pptx-branded)

run_py() {  # <scenario> <workdir>
  "$PY" "$ROOT/tests/pptx-branded-driver.py" "$1" "$2" "$SCRIPTS"
}

test_clone_keeps_media_and_reopens() {
  run_py clone "$TMP_ROOT"
  pass "clone keeps media rels and reopens"
}

test_zone_replacement_geometry() {
  run_py zones "$TMP_ROOT"
  pass "zone replacement preserves paragraph geometry"
}

test_plan_update_classification() {
  run_py plan "$TMP_ROOT"
  pass "update diff classifies keep/regen/pin_keep/add/delete"
}

test_update_applies_diff_with_pinned() {
  run_py apply "$TMP_ROOT"
  pass "update regenerates changed slides, spares pinned and identical ones"
}

test_update_drop_and_add() {
  run_py adddelete "$TMP_ROOT"
  pass "update drops removed slides and adds same-motif slides"
}

fm_test_run \
  test_clone_keeps_media_and_reopens \
  test_zone_replacement_geometry \
  test_plan_update_classification \
  test_update_applies_diff_with_pinned \
  test_update_drop_and_add
