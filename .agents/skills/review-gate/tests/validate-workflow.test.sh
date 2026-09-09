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
