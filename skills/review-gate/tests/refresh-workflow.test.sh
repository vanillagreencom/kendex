#!/usr/bin/env bash
# Surface: the refresh workflow trigger declarations.
# Inputs: skills/review-gate/templates/kendex-refresh.yml, refresh/kendex-refresh.yml,
# skills/harness-ci/tests/lib/workflow.sh.
# GitHub Actions reads these declarations; this suite checks their source shape.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)" || { echo 'refresh-workflow: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "refresh-workflow: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'refresh-workflow: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
. "$TEST_DIR/../../harness-ci/tests/lib/workflow.sh"

TEMPLATE="$REPO_ROOT/skills/review-gate/templates/kendex-refresh.yml"
CALLER="$REPO_ROOT/refresh/kendex-refresh.yml"

# Read only schedule entries under the top-level event mapping. Other cron
# strings, such as comments or step bodies, cannot satisfy the schedule row.
schedule_cron() { # WORKFLOW
  awk '
    { sub(/\r$/, "") }
    /^("on"|on):/ { in_events = 1; next }
    in_events && /^[^ ]/ { in_events = 0; in_schedule = 0 }
    in_events && /^  [a-z_]+:/ { in_schedule = ($0 ~ /^  schedule:/); next }
    in_schedule && /^    - cron: / {
      sub(/^    - cron: /, "")
      gsub(/^"|"$/, "")
      print
    }
  ' "$1"
}

check_cadence() { # TEMPLATE CALLER -> structured failures, exit 0 or 1
  local caller_events cron file event index=0 failed=0
  for file in "$@"; do
    index=$((index + 1))
    caller_events="$(triggers "$file")" || return 2
    for event in repository_dispatch workflow_dispatch schedule; do
      case $'\n'"$caller_events"$'\n' in
        *$'\n'"$event"$'\n'*) ;;
        *) printf 'caller=%s trigger-missing=%s\n' "$index" "$event"; failed=1 ;;
      esac
    done
    cron="$(schedule_cron "$file")" || return 2
    if [ "$cron" != '17 */6 * * *' ]; then
      printf 'caller=%s cron=%s\n' "$index" "$cron"
      failed=1
    fi
  done
  return "$failed"
}

for file in "$TEMPLATE" "$CALLER"; do
  [ -f "$file" ] && [ ! -L "$file" ] || { printf 'refresh-workflow: input=not-a-regular-file value=%q\n' "$file" >&2; exit 1; }
done

# Each control uses the same assertions as the shipped callers.
plant "$TEMPLATE" '    - cron: "17 */6 * * *"' '    - cron: "*/30 * * * *"' "$TMP_ROOT/template.yml"
plant "$CALLER" '    - cron: "17 */6 * * *"' '    - cron: "*/30 * * * *"' "$TMP_ROOT/caller.yml"

while IFS='|' read -r shape expected_exit; do
  case "$shape" in
    current) set -- "$TEMPLATE" "$CALLER" ;;
    unfixed) set -- "$TMP_ROOT/template.yml" "$TMP_ROOT/caller.yml" ;;
  esac
  status=0
  result="$(check_cadence "$@")" || status=$?
  expected=''
  if [ "$shape" = unfixed ]; then
    expected=$'caller=1 cron=*/30 * * * *\ncaller=2 cron=*/30 * * * *'
  fi
  if [ "$status" != "$expected_exit" ] || [ "$result" != "$expected" ]; then
    printf 'refresh-workflow: case=%s exit=%s result=[%s]\n' "$shape" "$status" "$result" >&2
    exit 1
  fi
  printf 'refresh-workflow: case=%s observed-exit=%s pass\n' "$shape" "$status"
done <<'CASES'
current|0
unfixed|1
CASES

# A missing dispatch receiver, manual entry or schedule must fail in either
# caller. Change the event key so unrelated YAML still cannot satisfy it.
for source in template caller; do
  case "$source" in
    template) file="$TEMPLATE"; index=1 ;;
    caller) file="$CALLER"; index=2 ;;
  esac
  for event in repository_dispatch workflow_dispatch schedule; do
    mutant="$TMP_ROOT/$source-$event.yml"
    plant "$file" "  $event:" "  ignored_$event:" "$mutant"
    case "$source" in
      template) set -- "$mutant" "$CALLER" ;;
      caller) set -- "$TEMPLATE" "$mutant" ;;
    esac
    status=0
    result="$(check_cadence "$@")" || status=$?
    expected="caller=$index trigger-missing=$event"
    [ "$event" != schedule ] || expected+=$'\n'"caller=$index cron="
    if [ "$status" != 1 ] || [ "$result" != "$expected" ]; then
      printf 'refresh-workflow: control=%s-%s exit=%s result=[%s]\n' "$source" "$event" "$status" "$result" >&2
      exit 1
    fi
    printf 'refresh-workflow: control=%s-%s observed-exit=%s pass\n' "$source" "$event" "$status"
  done
done
