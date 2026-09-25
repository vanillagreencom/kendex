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
# A comment outside any block scalar: equality compares it out.
HEADER_NOTE=('^# SCAFFOLD from the kendex' 's|^# SCAFFOLD from the kendex|# local note. SCAFFOLD from the kendex|')

OPT_IN='s|^  #   check_run:$|  check_run:|; s|^  #     types: \[created, completed\]$|    types: [created, completed]|'

# MUTANT_ANCHOR / MUTANT_LINES: when set, the sandbox's validate-workflow.sh
# has that one exact line replaced before --adopt runs.
MUTANT_ANCHOR=''
MUTANT_LINES=''
plant_mutant() { # DIR
  local script="$1/$WORKFLOW_REL" count
  count="$(awk -v a="$MUTANT_ANCHOR" '$0 == a { n++ } END { print n + 0 }' "$script")" || exit 2
  [ "$count" = 1 ] || { printf 'fixture-error=mutant-anchor value=%q\n' "$count:$MUTANT_ANCHOR" >&2; exit 2; }
  awk -v a="$MUTANT_ANCHOR" -v r="$MUTANT_LINES" '$0 == a { print r; next } { print }' "$script" >"$script.new" || exit 2
  ! cmp -s "$script" "$script.new" || { printf 'fixture-error=mutant-unchanged value=%q\n' "$MUTANT_ANCHOR" >&2; exit 2; }
  mv "$script.new" "$script"
  chmod +x "$script"
}

# One row: the copy's state before the bump, the bump, and what --adopt must
# print and leave. `readopted` rows then pass the plain run, and a copy with
# neither delta is the template's bytes; `edited` rows, and the equal copy,
# leave the copy byte-identical to what it was. Sets ROW_ERR to the failure,
# empty on a pass, so the must-fail controls below can read the same verdict.
ROW_ERR=''
adopt_row() { # SHAPE VERDICT
  local shape="$1" verdict="$2" template="$VENDORED_TEMPLATE" note_line='' line note want_rc=0 status=ok
  ROW_ERR=''
  sandbox
  case "$shape" in
    unchanged|commented) workflow_edit "$DIR" 1 "${HEADER_NOTE[@]}" ;;
    catalog)
      mkdir "$DIR/skills"
      mv "$DIR/.agents/skills/review-gate" "$DIR/skills/review-gate"
      workflow_edit "$DIR" 8 '\.agents/skills/review-gate/' 's#\.agents/skills/review-gate/#skills/review-gate/#g'
      template='skills/review-gate/templates/review-gate-writer.yml'
      DRIVER_REL='skills/review-gate/scripts/validate-workflow.sh' ;;
    opt-in)
      workflow_edit "$DIR" 2 '^  # +(check_run:|types: \[created, completed\])$' "$OPT_IN"
      printf -v note_line 'note check=workflow-check-name value=%q' REVIEW_GATE_CHECK_RUN_NAME ;;
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
  [ -z "$MUTANT_ANCHOR" ] || plant_mutant "$DIR"
  cp "$DIR/$WF" "$TMP/before.yml"
  RC=0
  OUT="$(cd "$DIR" && "./$DRIVER_REL" --adopt 2>&1)" || RC=$?
  if [ "$verdict" = workflow-edited ]; then
    status=FAIL
    want_rc=1
  fi
  printf -v line '%s check=%s value=%q' "$status" "$verdict" "$WF"
  if [ "$RC" -ne "$want_rc" ] || ! grep -qxF -- "$line" <<<"$OUT"; then
    ROW_ERR="rc=$RC, expected $line"
  elif [ "$verdict" = workflow-edited ]; then
    printf -v note 'note check=workflow-template value=%q' "$(git -C "$DIR" hash-object -- "$template")"
    cmp -s "$TMP/before.yml" "$DIR/$WF" || ROW_ERR="an edited copy was rewritten"
    grep -qxF -- "$note" <<<"$OUT" || ROW_ERR="${ROW_ERR:-no $note}"
  elif [ "$verdict" = workflow-equality ]; then
    cmp -s "$TMP/before.yml" "$DIR/$WF" || ROW_ERR="an equal copy was rewritten"
  else
    case "$shape" in
      opt-in|catalog) ;;
      *) cmp -s "$DIR/$template" "$DIR/$WF" || ROW_ERR="the re-installed copy is not the template's bytes" ;;
    esac
  fi
  if [ -z "$ROW_ERR" ] && [ "$verdict" != workflow-edited ]; then
    run_validate "$DIR"
    if [ "$RC" -ne 0 ] || grep -q '^FAIL check=' <<<"$OUT" ||
        { [ -n "$note_line" ] && ! grep -qxF -- "$note_line" <<<"$OUT"; }; then
      ROW_ERR="plain run after --adopt is not clean (rc=$RC)"
    fi
  fi
  DRIVER_REL="$WORKFLOW_REL"
}

rows=0; before=$((PASS + FAIL))
while IFS='|' read -r shape verdict; do
  [ -n "$shape" ] || continue
  rows=$((rows + 1))
  adopt_row "$shape" "$verdict"
  if [ -z "$ROW_ERR" ]; then ok "$shape --adopt"; else bad "$shape --adopt ($ROW_ERR)" "$OUT"; fi
done <<'ROWS'
unchanged|workflow-equality
uncommitted|workflow-readopted
commented|workflow-readopted
committed|workflow-readopted
two-bumps|workflow-readopted
deleted-readded|workflow-readopted
opt-in|workflow-readopted
catalog|workflow-readopted
hand-edited|workflow-edited
ROWS
[ "$rows" -gt 0 ] && [ "$((PASS + FAIL - before))" -eq "$rows" ] || { printf 'fixture-error=adopt-table value=%q\n' "$rows" >&2; exit 2; }

# Must-fail controls, one per --adopt rule: each mutant breaks one rule, and
# the row that rule protects must go red against it.
rows=0; before=$((PASS + FAIL))
while IFS='~' read -r rule shape verdict anchor replacement; do
  [ -n "$rule" ] || continue
  rows=$((rows + 1))
  MUTANT_ANCHOR="$anchor"
  MUTANT_LINES="$replacement"
  adopt_row "$shape" "$verdict"
  MUTANT_ANCHOR=''
  if [ -n "$ROW_ERR" ]; then ok "control $rule: $shape goes red"; else bad "control $rule: $shape stayed green" "$OUT"; fi
done <<'ROWS'
always-match~hand-edited~workflow-edited~    if [ "$cmp_rc" -eq 0 ]; then~    if [ "$cmp_rc" -le 1 ]; then
equal-copy-rewrite~unchanged~workflow-equality~  ok workflow-equality "$adopted" "the adopted workflow is the shipped template, line for line"~  ok workflow-equality "$adopted" "equal"\n  [ "$ADOPT" -eq 0 ] || cat "$TMP/template.raw" >"$adopted"
head-only-history~two-bumps~workflow-readopted~  git log --format=%H -- "$TEMPLATE_REL" >"$TMP/history" ||~  git log -1 --format=%H -- "$TEMPLATE_REL" >"$TMP/history" ||
deleted-version-continue~deleted-readded~workflow-readopted~    blob="$(git rev-parse --verify --quiet "$commit:$TEMPLATE_REL")" || continue~    blob="$(git rev-parse --verify --quiet "$commit:$TEMPLATE_REL")" || true
raw-byte-compare~commented~workflow-readopted~    cmp -s "$TMP/shipped.code" "$TMP/adopted.code" || cmp_rc=$?~    cmp -s "$TMP/shipped.raw" "$adopted" || cmp_rc=$?
ROWS
[ "$rows" -gt 0 ] && [ "$((PASS + FAIL - before))" -eq "$rows" ] || { printf 'fixture-error=control-table value=%q\n' "$rows" >&2; exit 2; }

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
