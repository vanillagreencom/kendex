#!/usr/bin/env bash
# Template equality at each edited position.
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

# Match counts prove that each edit reaches the intended template lines.
rows=0; before=$((PASS + FAIL))
while IFS='~' read -r label check count position pattern expression; do
  [ -n "$label" ] || continue
  rows=$((rows + 1))
  sandbox
  workflow_edit "$DIR" "$count" "$pattern" "$expression" "$position"
  if [ "$check" = clean ]; then
    expect_clean "$label" "$DIR"
  elif [ "$check" = opt-in-clean ]; then
    expect_clean "$label" "$DIR" workflow-check-name REVIEW_GATE_CHECK_RUN_NAME
  else
    expect_fail "$label" "$DIR" "$check" "$WF"
  fi
done <<'ROWS'
flipped relay conjunction position 1~workflow-equality~1~1~ && github.event_name != 'schedule'~s/ && github.event_name != 'schedule'/ || github.event_name != 'schedule'/
appended true on writer condition position 1~workflow-equality~1~1~^    if: github.event_name == 'workflow_dispatch' \|\| github.event_name == 'schedule'$~s/^    if: github.event_name == 'workflow_dispatch' || github.event_name == 'schedule'$/& || true/
writer condition conjunction position 1~workflow-equality~1~1~^    if: github.event_name == 'workflow_dispatch' \|\| github.event_name == 'schedule'$~s/^    if: github.event_name == 'workflow_dispatch' || github.event_name == 'schedule'$/    if: github.event_name == 'workflow_dispatch' \&\& github.event_name == 'schedule'/
foreign checkout repository position 1~workflow-equality~2~1~^          persist-credentials: false$~s|^          persist-credentials: false$|          repository: attacker/public-repo\n          persist-credentials: false|
foreign checkout repository position 2~workflow-equality~2~2~^          persist-credentials: false$~s|^          persist-credentials: false$|          repository: attacker/public-repo\n          persist-credentials: false|
missing opened activity position 1~workflow-equality~1~1~^    types: \[opened, synchronize, reopened\]$~s/^    types: \[opened, synchronize, reopened\]$/    types: [synchronize, reopened]/
inline status trigger position 1~workflow-equality~1~1~^  status: \{\}$~s/^  status: {}$/  status: { types: [success] }/
reduced status permission position 1~workflow-equality~2~1~^      statuses: write$~s/^      statuses: write$/      statuses: read/
reduced status permission position 2~workflow-equality~2~2~^      statuses: write$~s/^      statuses: write$/      statuses: read/
extra relay permission position 1~workflow-equality~1~1~^      actions: write$~s/^      actions: write$/      actions: write\n      packages: read/
removed dispatch trigger position 1~workflow-equality~1~1~^  workflow_dispatch: \{\}$~s/^  workflow_dispatch: {}$//
removed schedule position 1~workflow-equality~1~1~^  schedule:$~/^  schedule:$/,/^    - cron:/d
removed guard exits position 1~workflow-equality~4~1~^            exit 1$~/^            exit 1$/d
removed guard exits position 2~workflow-equality~4~2~^            exit 1$~/^            exit 1$/d
removed guard exits position 3~workflow-equality~4~3~^            exit 1$~/^            exit 1$/d
removed guard exits position 4~workflow-equality~4~4~^            exit 1$~/^            exit 1$/d
hardcoded checkout branch position 1~workflow-equality~2~1~ref: \$\{\{ github.event.repository.default_branch \}\}~s|ref: ${{ github.event.repository.default_branch }}|ref: main|
hardcoded checkout branch position 2~workflow-equality~2~2~ref: \$\{\{ github.event.repository.default_branch \}\}~s|ref: ${{ github.event.repository.default_branch }}|ref: main|
checkout keeps credentials position 1~workflow-equality~2~1~^          persist-credentials: false$~/^          persist-credentials: false$/d
checkout keeps credentials position 2~workflow-equality~2~2~^          persist-credentials: false$~/^          persist-credentials: false$/d
missing relay binding position 1~workflow-equality~1~1~^      DISPATCH_REF: ~/^      DISPATCH_REF: /d
consumer uses catalog path position 1~clean~7~1~\.agents/skills/review-gate/~s#\.agents/skills/review-gate/#skills/review-gate/#g
consumer uses catalog path position 2~workflow-equality~7~2~\.agents/skills/review-gate/~s#\.agents/skills/review-gate/#skills/review-gate/#g
consumer uses catalog path position 3~workflow-equality~7~3~\.agents/skills/review-gate/~s#\.agents/skills/review-gate/#skills/review-gate/#g
consumer uses catalog path position 4~workflow-equality~7~4~\.agents/skills/review-gate/~s#\.agents/skills/review-gate/#skills/review-gate/#g
consumer uses catalog path position 5~workflow-equality~7~5~\.agents/skills/review-gate/~s#\.agents/skills/review-gate/#skills/review-gate/#g
consumer uses catalog path position 6~workflow-equality~7~6~\.agents/skills/review-gate/~s#\.agents/skills/review-gate/#skills/review-gate/#g
consumer uses catalog path position 7~workflow-equality~7~7~\.agents/skills/review-gate/~s#\.agents/skills/review-gate/#skills/review-gate/#g
opt-in trigger alone position 1~workflow-opt-in~1~1~^  #   check_run:$~s|^  #   check_run:$|  check_run:|
opt-in types alone position 1~workflow-opt-in~1~1~^  #     types: \[created, completed\]$~s|^  #     types: \[created, completed\]$|    types: [created, completed]|
opt-in lines separated position 1~workflow-opt-in~1~1~^  workflow_dispatch: \{\}$~s|^  workflow_dispatch: {}$|  check_run:\n  workflow_dispatch: {}\n    types: [created, completed]|
blank payload line position 1~workflow-equality~6~1~^          set -u$~/^          set -u$/G
blank payload line position 2~workflow-equality~6~2~^          set -u$~/^          set -u$/G
blank payload line position 3~workflow-equality~6~3~^          set -u$~/^          set -u$/G
blank payload line position 4~workflow-equality~6~4~^          set -u$~/^          set -u$/G
blank payload line position 5~workflow-equality~6~5~^          set -u$~/^          set -u$/G
blank payload line position 6~workflow-equality~6~6~^          set -u$~/^          set -u$/G
comment inside payload position 1~workflow-equality~6~1~^          set -u$~s@^          set -u$@&\n          # a shell comment inside the payload@
comment inside payload position 2~workflow-equality~6~2~^          set -u$~s@^          set -u$@&\n          # a shell comment inside the payload@
comment inside payload position 3~workflow-equality~6~3~^          set -u$~s@^          set -u$@&\n          # a shell comment inside the payload@
comment inside payload position 4~workflow-equality~6~4~^          set -u$~s@^          set -u$@&\n          # a shell comment inside the payload@
comment inside payload position 5~workflow-equality~6~5~^          set -u$~s@^          set -u$@&\n          # a shell comment inside the payload@
comment inside payload position 6~workflow-equality~6~6~^          set -u$~s@^          set -u$@&\n          # a shell comment inside the payload@
reworded YAML comment position 1~clean~1~1~^# SCAFFOLD from~s|^# SCAFFOLD from.*|# this repo reworded the header|
complete opt-in~opt-in-clean~2~~^  # +(check_run:|types: \[created, completed\])$~s|^  #   check_run:$|  check_run:|; s|^  #     types: \[created, completed\]$|    types: [created, completed]|
ROWS
[ "$rows" -gt 0 ] && [ "$((PASS + FAIL - before))" -eq "$rows" ] || { printf 'fixture-error=equality-table value=%q\n' "$rows" >&2; exit 2; }

# Appended structures and byte changes reach the same equality boundary.
rows=0; before=$((PASS + FAIL))
for shape in appended-job misplaced-opt-in crlf-payload padded-continuation opt-in-with-edit-1 opt-in-with-edit-2; do
  rows=$((rows + 1))
  sandbox
  wf="$DIR/$WF"
  case "$shape" in
    appended-job)
      printf '%s\n' '  second-relay:' '    runs-on: ubuntu-latest' '    permissions:' \
        '      actions: write' '    steps:' '      - run: echo dispatch' >>"$wf" ;;
    misplaced-opt-in) printf '%s\n' '  check_run:' '    types: [created, completed]' >>"$wf" ;;
    crlf-payload)
      awk 'changed == 0 && /^          set -u$/ { printf "%s\r\n", $0; changed++; next } { print } END { if (changed != 1) exit 2 }' "$wf" >"$wf.new"
      mv "$wf.new" "$wf" ;;
    padded-continuation)
      awk 'changed == 0 && /\\$/ { print $0 " "; changed++; next } { print } END { if (changed != 1) exit 2 }' "$wf" >"$wf.new"
      mv "$wf.new" "$wf" ;;
    opt-in-with-edit-*)
      workflow_edit "$DIR" 2 '^  # +(check_run:|types: \[created, completed\])$' 's|^  #   check_run:$|  check_run:|; s|^  #     types: \[created, completed\]$|    types: [created, completed]|'
      workflow_edit "$DIR" 2 '^      statuses: write$' 's/^      statuses: write$/      statuses: read/' "${shape##*-}" ;;
  esac
  commit "$DIR"
  expect_fail "$shape" "$DIR" workflow-equality "$WF"
done
[ "$rows" -gt 0 ] && [ "$((PASS + FAIL - before))" -eq "$rows" ] || { printf 'fixture-error=payload-table value=%q\n' "$rows" >&2; exit 2; }

# Each repository kind keeps its own script path.
rows=0; before=$((PASS + FAIL))
for spelling in tracked vendored-1 vendored-2 vendored-3 vendored-4 vendored-5 vendored-6 vendored-7; do
  rows=$((rows + 1))
  sandbox
  mkdir "$DIR/skills"
  mv "$DIR/.agents/skills/review-gate" "$DIR/skills/review-gate"
  workflow_edit "$DIR" 7 '\.agents/skills/review-gate/' 's#\.agents/skills/review-gate/#skills/review-gate/#g'
  DRIVER_REL='skills/review-gate/scripts/validate-workflow.sh'
  if [ "$spelling" != tracked ]; then
    workflow_edit "$DIR" 7 'skills/review-gate/' 's#skills/review-gate/#.agents/skills/review-gate/#g' "${spelling#vendored-}"
    if [ "$spelling" = vendored-1 ]; then
      expect_clean "catalog path in a YAML comment" "$DIR"
    else
      expect_fail "catalog $spelling spelling" "$DIR" workflow-equality "$WF"
    fi
  else
    expect_clean "catalog $spelling spelling" "$DIR"
  fi
done
[ "$rows" -gt 0 ] && [ "$((PASS + FAIL - before))" -eq "$rows" ] || { printf 'fixture-error=catalog-table value=%q\n' "$rows" >&2; exit 2; }
DRIVER_REL="$WORKFLOW_REL"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
