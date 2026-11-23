#!/usr/bin/env bash
# Surface: the refresh workflow trigger declarations.
# Inputs: refresh/kendex-refresh.yml, skills/harness-ci/tests/lib/workflow.sh, skills/harness-ci/tests/lib/gh-eval.py,
# .github/workflows/refresh-release.yml.
# GitHub Actions reads these declarations; this suite checks their source shape.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)" || { echo 'refresh-workflow: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "refresh-workflow: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'refresh-workflow: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
. "$TEST_DIR/../../harness-ci/tests/lib/workflow.sh"

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

check_cadence() { # CALLER... -> structured failures, exit 0 or 1
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
    if [ "$cron" != '43 8 * * *' ]; then
      printf 'caller=%s cron=%s\n' "$index" "$cron"
      failed=1
    fi
  done
  return "$failed"
}

PASS=0
[ -f "$CALLER" ] && [ ! -L "$CALLER" ] || { printf 'refresh-workflow: input=not-a-regular-file value=%q\n' "$CALLER" >&2; exit 1; }

# Each control uses the same assertions as the shipped caller.
plant "$CALLER" '    - cron: "43 8 * * *"' '    - cron: "17 */6 * * *"' "$TMP_ROOT/caller.yml"

while IFS='|' read -r shape expected_exit; do
  case "$shape" in
    current) set -- "$CALLER" ;;
    unfixed) set -- "$TMP_ROOT/caller.yml" ;;
  esac
  status=0
  result="$(check_cadence "$@")" || status=$?
  expected=''
  if [ "$shape" = unfixed ]; then
    expected='caller=1 cron=17 */6 * * *'
  fi
  if [ "$status" != "$expected_exit" ] || [ "$result" != "$expected" ]; then
    printf 'refresh-workflow: case=%s exit=%s result=[%s]\n' "$shape" "$status" "$result" >&2
    exit 1
  fi
  printf 'refresh-workflow: case=%s observed-exit=%s pass\n' "$shape" "$status"
  PASS=$((PASS + 1))
done <<'CASES'
current|0
unfixed|1
CASES

# A missing dispatch receiver, manual entry or schedule must fail. Change the
# event key so unrelated YAML still cannot satisfy it.
for event in repository_dispatch workflow_dispatch schedule; do
  mutant="$TMP_ROOT/caller-$event.yml"
  plant "$CALLER" "  $event:" "  ignored_$event:" "$mutant"
  status=0
  result="$(check_cadence "$mutant")" || status=$?
  expected="caller=1 trigger-missing=$event"
  [ "$event" != schedule ] || expected+=$'\n'"caller=1 cron="
  if [ "$status" != 1 ] || [ "$result" != "$expected" ]; then
    printf 'refresh-workflow: control=caller-%s exit=%s result=[%s]\n' "$event" "$status" "$result" >&2
    exit 1
  fi
  printf 'refresh-workflow: control=caller-%s observed-exit=%s pass\n' "$event" "$status"
  PASS=$((PASS + 1))
done
printf 'pass: %s   fail: 0\n' "$PASS"

# GitHub evaluates this job condition before allocating its runner. Execute
# the declared expression for each route; a missing output must refresh.
python3 - "$CALLER" "$GH_EVAL" <<'PY'
from pathlib import Path
import json, re, subprocess, sys

def check(text):
    release, refresh = text.split('  release:\n', 1)[1].split('  refresh:\n', 1)
    assert 'runs-on:' not in release and 'concurrency:' not in release and 'environment:' not in release
    assert 'uses: vanillagreencom/kendex/.github/workflows/refresh-release.yml@v1' in release
    conditions = [re.search(r'^    if: \$\{\{ (.+) \}\}$', job, re.M).group(1) for job in (release, refresh)]
    assert conditions[1].startswith('!cancelled() && ')
    fleet = 'vanillagreen-fleet-lanes[bot]'
    for event, actor, attempt, clear, outcome, route, wanted in (
        ('repository_dispatch', fleet, 1, True, 'skipped', '', 'refresh'),
        ('repository_dispatch', fleet, 1, False, 'success', 'full', 'release\nrefresh'),
        ('repository_dispatch', fleet, 1, None, 'success', '', 'release\nrefresh'),
        ('repository_dispatch', fleet, 2, True, 'success', 'reviews', 'release\nrefresh'),
        ('repository_dispatch', 'another[bot]', 1, True, 'success', 'skip', 'release'),
        ('repository_dispatch', fleet, 1, False, 'failure', 'full', 'release'),
        ('schedule', fleet, 1, True, 'success', 'skip', 'release'),
        ('workflow_dispatch', fleet, 1, True, 'cancelled', 'full', 'release'),
    ):
        context = dict(github=dict(repository='acme/widgets', ref='refs/heads/main', event_name=event,
                                   run_attempt=attempt, event=dict(repository=dict(default_branch='main'),
                                   sender=dict(login=actor, type='Bot'), client_payload=dict(gate_clear=clear))),
                       needs=dict(release=dict(result=outcome, outputs=dict(route=route))))
        result = subprocess.run([sys.executable, sys.argv[2], 'jobs', json.dumps(context)],
                                input='release\t\t' + conditions[0] + '\nrefresh\trelease\t' + conditions[1] + '\n',
                                text=True, capture_output=True, check=True, timeout=10)
        assert result.stdout == wanted + '\n', (event, actor, attempt, route, result.stdout)
for path in sys.argv[1:2]:
    text = Path(path).read_text()
    check(text)
    for old, new in ((" && needs.release.outputs.route != 'skip'", ''),
                     (" && github.run_attempt == 1", ''),
                     (" && github.event.sender.login == 'vanillagreen-fleet-lanes[bot]'", ''),
                     ("needs.release.result == 'success'", "needs.release.result != 'skipped'")):
        assert text.count(old) == 1
        try: check(text.replace(old, new))
        except AssertionError: pass
        else: raise AssertionError('must-fail: changed job route passed ' + old)
PY
