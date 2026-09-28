#!/usr/bin/env bash
# Workflow discovery and standalone command boundaries.
# Verdict records are the complete protocol consumed by validate.sh.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT
. "$TEST_DIR/lib/sandbox.sh"
. "$TEST_DIR/lib/workflow-edit.sh"
DRIVER_REL="$WORKFLOW_REL"
WF='.github/workflows/review-gate-writer.yml'

# GitHub runs tracked direct children. Vary the candidate's location and
# engine-reference form while keeping the rest of the repository sound.
rows=0; before=$((PASS + FAIL))
while IFS='|' read -r shape check value note_check note_value; do
  [ -n "$shape" ] || continue
  rows=$((rows + 1))
  sandbox
  case "$shape" in
    sound) ;;
    missing) rm "$DIR/$WF"; commit "$DIR" ;;
    duplicate|non-ascii)
      copy='second-writer.yml'
      [ "$shape" != non-ascii ] || copy='rêview-writer.yml'
      cp "$DIR/$WF" "$DIR/.github/workflows/$copy"
      commit "$DIR" ;;
    bash-reference)
      printf '%s\n' 'name: Another writer' '"on":' '  workflow_dispatch: {}' 'jobs:' \
        '  write:' '    runs-on: ubuntu-latest' '    steps:' \
        '      - run: bash .agents/skills/review-gate/scripts/review-writer.sh' \
        >"$DIR/.github/workflows/other-writer.yml"
      commit "$DIR" ;;
    comment-reference)
      printf '%s\n' 'name: Mentions the writer in prose' '"on":' '  workflow_dispatch: {}' \
        'jobs:' '  talk:' '    runs-on: ubuntu-latest' '    steps:' \
        '      # review-writer.sh is named here and run nowhere' '      - run: echo hi' \
        >"$DIR/.github/workflows/mentions.yml"
      commit "$DIR" ;;
    symlink)
      (cd "$DIR/.github/workflows" && mv review-gate-writer.yml real-writer.yml && ln -s real-writer.yml review-gate-writer.yml)
      commit "$DIR" ;;
    nested-only|nested-copy)
      mkdir -p "$DIR/.github/workflows/archive"
      if [ "$shape" = nested-only ]; then
        mv "$DIR/$WF" "$DIR/.github/workflows/archive/review-gate-writer.yml"
      else
        cp "$DIR/$WF" "$DIR/.github/workflows/archive/old-writer.yml"
      fi
      commit "$DIR" ;;
    untracked-copy) cp "$DIR/$WF" "$DIR/.github/workflows/scratch.yml" ;;
    *) printf 'fixture-error=unknown-shape value=%q\n' "$shape" >&2; exit 2 ;;
  esac
  if [ "$check" = clean ]; then
    expect_clean "$shape" "$DIR" "$note_check" "$note_value"
  else
    expect_fail "$shape" "$DIR" "$check" "$value" "$note_check" "$note_value"
  fi
done <<'ROWS'
sound|clean|||
missing|workflow-count|0||
duplicate|workflow-count|2||
bash-reference|workflow-reference-count|2||
comment-reference|clean|||
symlink|workflow-symlink|.github/workflows/review-gate-writer.yml||
non-ascii|workflow-count|2||
nested-only|workflow-count|0|workflow-nested|.github/workflows/archive/review-gate-writer.yml
nested-copy|clean|||
untracked-copy|clean|||
ROWS
[ "$rows" -gt 0 ] && [ "$((PASS + FAIL - before))" -eq "$rows" ] || { printf 'fixture-error=discovery-table value=%q\n' "$rows" >&2; exit 2; }

# A writer may be absent only in a repository that runs no review gate, and a
# present writer is checked in full whatever the writer setting says. An empty
# setting column leaves the key unassigned.
writer_case() { # WRITER MODE WRITER_SHAPE
  sandbox
  [ -z "$1" ] || settings "$DIR" REVIEW_GATE_WRITER "$1"
  [ -z "$2" ] || settings "$DIR" REVIEW_GATE_MODE "$2"
  case "$3" in
    absent) rm "$DIR/$WF" ;;
    edited) file_edit "$DIR" "$WF" 1 '^    timeout-minutes: 15$' 's/^    timeout-minutes: 15$/    timeout-minutes: 16/' ;;
    *) printf 'fixture-error=writer-shape value=%q\n' "$3" >&2; exit 2 ;;
  esac
  commit "$DIR"
  run_validate "$DIR"
}
rows=0; before=$((PASS + FAIL))
while IFS='|' read -r name writer mode shape want_rc record; do
  rows=$((rows + 1))
  writer_case "$writer" "$mode" "$shape"
  if [ "$RC" -eq "$want_rc" ] && grep -qxF -- "$record" <<<"$OUT"; then ok "$name"; else bad "$name (rc=$RC, expected $record)" "$OUT"; fi
done <<'ROWS'
optional writer absent with the gate off|optional|off|absent|0|ok check=workflow-absent value=optional
required writer absent with the gate off|required|off|absent|1|FAIL check=workflow-count value=0
unassigned writer setting absent with the gate off||off|absent|1|FAIL check=workflow-count value=0
optional writer absent with the gate enforced|optional|enforce|absent|1|FAIL check=workflow-absent-mode value=enforce
optional writer absent with the mode unassigned|optional||absent|1|FAIL check=workflow-absent-mode value=enforce
optional writer present and edited|optional|off|edited|1|FAIL check=workflow-equality value=.github/workflows/review-gate-writer.yml
invalid writer setting|absent|off|absent|2|review-gate-error=writer-setting value=absent
invalid mode setting|optional|of|absent|2|review-gate-error=mode-setting value=of
ROWS
[ "$rows" -gt 0 ] && [ "$((PASS + FAIL - before))" -eq "$rows" ] || { printf 'fixture-error=writer-table value=%q\n' "$rows" >&2; exit 2; }

# One control per rule, each on the sandbox copy: absence needs the optional
# setting, and optional absence needs the gate off.
writer_case required off absent
file_edit "$DIR" "$WORKFLOW_REL" 1 '^  if \[ "\$WRITER_SETTING" = optional \]; then$' \
  's/^  if \[ "\$WRITER_SETTING" = optional \]; then$/  if [ "$WRITER_SETTING" = optional ] || true; then/'
chmod +x "$DIR/$WORKFLOW_REL"
run_validate "$DIR"
if [ "$RC" -eq 0 ] && grep -qxF 'ok check=workflow-absent value=required' <<<"$OUT"; then
  ok 'control: an unconditional absence branch passes a required writer'
else bad "control: absence rule (rc=$RC)" "$OUT"; fi
writer_case optional enforce absent
file_edit "$DIR" "$WORKFLOW_REL" 1 '^    gate_mode="\$\(rg_setting REVIEW_GATE_MODE enforce\)" \|\| exit 2$' \
  's/^    gate_mode="\$(rg_setting REVIEW_GATE_MODE enforce)" || exit 2$/&; gate_mode=off/'
chmod +x "$DIR/$WORKFLOW_REL"
run_validate "$DIR"
if [ "$RC" -eq 0 ] && grep -qxF 'ok check=workflow-absent value=optional' <<<"$OUT"; then
  ok 'control: ignoring the mode passes optional absence under an enforced gate'
else bad "control: mode rule (rc=$RC)" "$OUT"; fi


rows=0; before=$((PASS + FAIL))
while IFS='|' read -r shape want_rc code; do
  rows=$((rows + 1))
  sandbox
  args=()
  value=''
  case "$shape" in
    help) args=(--help) ;;
    extra) args=(extra); value=1 ;;
    missing-template)
      value="$DIR/.agents/skills/review-gate/templates/review-gate-writer.yml"
      rm "$value" ;;
  esac
  RC=0
  OUT="$(cd "$DIR" && "./$WORKFLOW_REL" ${args[@]+"${args[@]}"} 2>&1)" || RC=$?
  expected=''
  [ -z "$code" ] || printf -v expected 'review-gate-error=%s value=%q' "$code" "$value"
  if [ "$RC" -eq "$want_rc" ] && { [ -z "$expected" ] || grep -qxF -- "$expected" <<<"$OUT"; }; then
    ok "$shape"
  else
    bad "$shape (rc=$RC, expected $expected)" "$OUT"
  fi
done <<'ROWS'
help|0|
extra|2|unknown-arguments
missing-template|2|template-missing
ROWS
[ "$rows" -gt 0 ] && [ "$((PASS + FAIL - before))" -eq "$rows" ] || { printf 'fixture-error=command-table value=%q\n' "$rows" >&2; exit 2; }

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
