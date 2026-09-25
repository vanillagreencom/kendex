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
# changes, as `kendex refresh` writes it.
CRON_BUMP=('^    - cron: "\*/15 \* \* \* \*"$' 's|^    - cron: "\*/15 \* \* \* \*"$|    - cron: "*/10 * * * *"|')
TIMEOUT_BUMP=('^    timeout-minutes: 15$' 's/^    timeout-minutes: 15$/    timeout-minutes: 16/')

OPT_IN='s|^  #   check_run:$|  check_run:|; s|^  #     types: \[created, completed\]$|    types: [created, completed]|'

# Each row: the copy's state before the bump, the bump, and what --adopt
# must print and leave. `readopted` rows then pass the plain run; `edited`
# rows, and the equal copy, leave the copy byte-identical to what it was.
rows=0; before=$((PASS + FAIL))
while IFS='|' read -r shape verdict; do
  [ -n "$shape" ] || continue
  rows=$((rows + 1))
  sandbox
  template="$VENDORED_TEMPLATE"
  note_check=''
  case "$shape" in
    unchanged)
      # Code-equal, byte-different: a rewrite of an equal copy shows here.
      workflow_edit "$DIR" 1 '^# SCAFFOLD from the kendex' 's|^# SCAFFOLD from the kendex|# local note. SCAFFOLD from the kendex|' ;;
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
      file_edit "$DIR" "$template" 1 "${CRON_BUMP[@]}"
      commit "$DIR"
      file_edit "$DIR" "$template" 1 "${TIMEOUT_BUMP[@]}"
      commit "$DIR" ;;
    committed)
      file_edit "$DIR" "$template" 1 "${CRON_BUMP[@]}"
      commit "$DIR" ;;
    deleted-readded)
      # A removed and re-added skill: the deletion commit holds no version.
      file_edit "$DIR" "$template" 1 "${CRON_BUMP[@]}"
      commit "$DIR"
      cp "$DIR/$template" "$TMP/readd.yml"
      rm "$DIR/$template"
      commit "$DIR"
      cp "$TMP/readd.yml" "$DIR/$template"
      commit "$DIR" ;;
    *) file_edit "$DIR" "$template" 1 "${CRON_BUMP[@]}" ;;
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
deleted-readded|workflow-readopted
opt-in|workflow-readopted
catalog|workflow-readopted
hand-edited|workflow-edited
ROWS
[ "$rows" -gt 0 ] && [ "$((PASS + FAIL - before))" -eq "$rows" ] || { printf 'fixture-error=adopt-table value=%q\n' "$rows" >&2; exit 2; }

# The plain run's refusal after a bump names the template blob it compared
# against and the --adopt command the rows above drive.
sandbox
file_edit "$DIR" "$VENDORED_TEMPLATE" 1 "${CRON_BUMP[@]}"
expect_fail "bumped template, plain run" "$DIR" workflow-equality "$WF" \
  workflow-template "$(git -C "$DIR" hash-object -- "$VENDORED_TEMPLATE")"
if grep -qF -- '.agents/skills/review-gate/scripts/validate-workflow.sh --adopt' <<<"$OUT"; then
  ok "bumped template, plain run names --adopt"
else
  bad "bumped template, plain run names --adopt" "$OUT"
fi

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
