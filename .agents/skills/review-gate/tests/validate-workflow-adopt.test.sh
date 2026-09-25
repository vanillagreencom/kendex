#!/usr/bin/env bash
# Re-adoption: `validate-workflow.sh --adopt` after a template bump, and the
# plain run's refusal naming the shipped version and the command.
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
VENDORED_TEMPLATE='.agents/skills/review-gate/templates/review-gate-writer.yml'

# The catalog side of a release: one code line of the vendored template
# changes, as `kendex refresh` writes it. COMMIT=1 also commits the render,
# the state a render PR is in once its first commit is pushed.
template_bump() { # DIR TEMPLATE_PATH OLD NEW COMMIT
  local t="$1/$2" rc=0
  grep -qxF -- "$3" "$t" || { printf 'fixture-error=bump-unmatched value=%q\n' "$3" >&2; exit 2; }
  awk -v old="$3" -v new="$4" '$0 == old { print new; next } { print }' "$t" >"$t.new"
  cmp -s "$t" "$t.new" || rc=$?
  [ "$rc" -eq 1 ] || { printf 'fixture-error=bump-unchanged value=%q\n' "$rc" >&2; exit 2; }
  mv "$t.new" "$t"
  [ "$5" -eq 0 ] || commit "$1"
}
CRON_OLD='    - cron: "*/15 * * * *"'
CRON_NEW='    - cron: "*/10 * * * *"'
TIMEOUT_OLD='    timeout-minutes: 15'
TIMEOUT_NEW='    timeout-minutes: 16'

OPT_IN='s|^  #   check_run:$|  check_run:|; s|^  #     types: \[created, completed\]$|    types: [created, completed]|'

# Each row: the copy's state before the bump, the bump, and what --adopt
# must print and leave. `readopted` rows then pass the plain run; `edited`
# rows leave the copy byte-identical to what it was.
rows=0; before=$((PASS + FAIL))
while IFS='|' read -r shape verdict; do
  [ -n "$shape" ] || continue
  rows=$((rows + 1))
  sandbox
  template="$VENDORED_TEMPLATE"
  note_check=''
  case "$shape" in
    catalog)
      mkdir "$DIR/skills"
      mv "$DIR/.agents/skills/review-gate" "$DIR/skills/review-gate"
      workflow_edit "$DIR" 8 '\.agents/skills/review-gate/' 's#\.agents/skills/review-gate/#skills/review-gate/#g'
      template='skills/review-gate/templates/review-gate-writer.yml'
      DRIVER_REL='skills/review-gate/scripts/validate-workflow.sh' ;;
    opt-in)
      workflow_edit "$DIR" 2 '^  # +(check_run:|types: \[created, completed\])$' "$OPT_IN"
      note_check=workflow-check-name ;;
    hand-edited) workflow_edit "$DIR" 1 '^        timeout-minutes: 12$' 's/^        timeout-minutes: 12$/        timeout-minutes: 11/' ;;
  esac
  case "$shape" in
    unchanged) ;;
    two-bumps)
      template_bump "$DIR" "$template" "$CRON_OLD" "$CRON_NEW" 1
      template_bump "$DIR" "$template" "$TIMEOUT_OLD" "$TIMEOUT_NEW" 1 ;;
    committed) template_bump "$DIR" "$template" "$CRON_OLD" "$CRON_NEW" 1 ;;
    *) template_bump "$DIR" "$template" "$CRON_OLD" "$CRON_NEW" 0 ;;
  esac
  cp "$DIR/$WF" "$TMP/before.yml"
  RC=0
  OUT="$(cd "$DIR" && "./$DRIVER_REL" --adopt 2>&1)" || RC=$?
  printf -v line '%s check=%s value=%q' "$( [ "$verdict" = workflow-edited ] && printf FAIL || printf ok )" "$verdict" "$WF"
  want_rc=0
  [ "$verdict" != workflow-edited ] || want_rc=1
  if [ "$RC" -ne "$want_rc" ] || ! grep -qxF -- "$line" <<<"$OUT"; then
    bad "$shape --adopt (rc=$RC, expected $line)" "$OUT"
  elif [ "$verdict" = workflow-edited ]; then
    printf -v note 'note check=workflow-template value=%q' "$(git -C "$DIR" hash-object -- "$template")"
    if cmp -s "$TMP/before.yml" "$DIR/$WF" && grep -qxF -- "$note" <<<"$OUT"; then
      ok "$shape --adopt"
    else
      bad "$shape --adopt (copy rewritten or no $note)" "$OUT"
    fi
  elif [ "$verdict" = workflow-equality ] && ! cmp -s "$TMP/before.yml" "$DIR/$WF"; then
    bad "$shape --adopt (an equal copy was rewritten)" "$OUT"
  else
    expect_clean "$shape --adopt" "$DIR" "$note_check" "${note_check:+REVIEW_GATE_CHECK_RUN_NAME}"
  fi
  DRIVER_REL="$WORKFLOW_REL"
done <<'ROWS'
unchanged|workflow-equality
uncommitted|workflow-readopted
committed|workflow-readopted
two-bumps|workflow-readopted
opt-in|workflow-readopted
catalog|workflow-readopted
hand-edited|workflow-edited
ROWS
[ "$rows" -gt 0 ] && [ "$((PASS + FAIL - before))" -eq "$rows" ] || { printf 'fixture-error=adopt-table value=%q\n' "$rows" >&2; exit 2; }

# The plain run's refusal after a bump names the template blob it compared
# against; the command it names is the --adopt the rows above drive.
sandbox
template_bump "$DIR" "$VENDORED_TEMPLATE" "$CRON_OLD" "$CRON_NEW" 0
expect_fail "bumped template, plain run" "$DIR" workflow-equality "$WF" \
  workflow-template "$(git -C "$DIR" hash-object -- "$VENDORED_TEMPLATE")"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
