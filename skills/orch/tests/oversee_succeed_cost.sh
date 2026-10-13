#!/usr/bin/env bash
# Surface: oversee-succeed --check-marks caller identity and loaded settings.
# Inputs: scripts/oversee-succeed, scripts/orch-env, scripts/overseer-host*, scripts/workflow-state,
# scripts/git-context, scripts/lib/*.sh, ../mailbox/scripts/lib/*.sh, tests/lib/process-count.py.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/lib/git-env.sh"
TEST_DIR="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)"
source "$TEST_DIR/lib/assertions.sh"
mkdir -p "$TEST_DIR/../../../tmp"
TMP_ROOT="$(mktemp -d "$TEST_DIR/../../../tmp/oversee-cost.XXXXXX")" || { echo 'oversee-succeed-cost: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'oversee-succeed-cost: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'oversee-succeed-cost: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
if [[ -z "${BASHPID:-}" ]]; then
  printf 'process counting requires BASHPID; behavior runs in the succession suites\npass: 0   fail: 0\n'
  exit 0
fi
python3 - "$TEST_DIR" "$TMP_ROOT" "$BASH" "${1:-}" <<'PY' > "$TMP_ROOT/results"
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

tests, root, bash, baseline = sys.argv[1:]
tests, root = Path(tests), Path(root)
source = Path(os.environ.get('SUCCEED_SCRIPTS_UNDER_TEST', str(tests.parent / 'scripts')))
spec = importlib.util.spec_from_file_location('counter', tests / 'lib/process-count.py')
counter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(counter)
BOUND = 80

def result(name, got, want):
    print('assert', str(got), str(want), name, sep='\t')

for skill in ('orch', 'mailbox', 'github'):
    shutil.copytree(source.parent.parent / skill / 'scripts', root / 'candidate' / skill / 'scripts')
scripts = root / 'candidate/orch/scripts'
stub = '#!' + bash + '''
set -euo pipefail
[[ "$1" == pick && "$2" == --lane && "$3" == "$FIXTURE_ACCOUNT" ]] || exit 2
[[ -z "${FIXTURE_MODEL:-}" || " $* " == *" --model $FIXTURE_MODEL "* ]] || exit 2
printf '%s\\n' "$FIXTURE_RECORD"
'''
(scripts / 'lanes').write_text(stub)
(scripts / 'lanes').chmod(0o755)
if baseline:
    baseline = Path(baseline)
    for skill in ('orch', 'mailbox', 'github'):
        shutil.copytree(baseline.parent.parent / skill / 'scripts', root / 'base' / skill / 'scripts')
    (root / 'base/orch/scripts/lanes').write_text(stub)
    (root / 'base/orch/scripts/lanes').chmod(0o755)
(root / 'work').mkdir()
for args in (['init', '-q'], ['config', 'gc.auto', '0'], ['config', 'maintenance.auto', 'false']):
    subprocess.run(['git', '-C', str(root / 'work'), *args], check=True)
(root / 'work/tmp/lane-mail/overseer').mkdir(parents=True)
(root / 'bin').mkdir()
(root / 'bin/tmux').write_text('#!' + bash + '''
set -euo pipefail
if [[ "${FAIL_READ:-}" == "$1" || "${FAIL_READ:-}" == "${*: -1}" ]]; then
  printf 'fixture-read-failed\\n' >&2; exit 1
fi
case "$1" in
 list-panes) [[ "${PANE_GONE:-}" == yes ]] || printf '%%1\\n' ;;
 capture-pane) printf '> ready\\n' ;;
 display-message)
  case "${*: -1}" in
   '#{window_id}') printf '@1\\n' ;;
   '#{pid}') printf '123\\n' ;;
   '#{pid} #{start_time}') printf '123 456\\n' ;;
   '#{pane_current_path}') printf '%s\\n' "$FIXTURE_WORK" ;;
   '#{pane_pid} #{pane_current_command}') printf '789 claude\\n' ;;
   *) exit 2 ;;
  esac ;;
 *) exit 2 ;;
esac
''')
(root / 'bin/tmux').chmod(0o755)
count_dir = root / 'counter'
counter.install(count_dir, str(root / 'bin') + os.pathsep + os.environ['PATH'], bash)
record_file = root / 'work/tmp/workflow-state-oversee.json'
context_file = root / 'work/tmp/lane-mail/overseer/context.json'
row_file = root / 'work/tmp/lane-mail/overseer/session-123-1.jsonl'
account = str(root / 'home/.claude')
identity = {'runtime': 'tmux', 'pane': '%1', 'server': '123', 'server_start': 456,
            'harness': 'claude', 'account': account, 'model': 'fable', 'cwd': str(root / 'work')}
pick = json.dumps({'wall': 10, 'alias': 'caller', 'usage_rate_state': 'one-sample'})
env = {'PATH': str(count_dir / 'bin'), 'HOME': str(root / 'home'), 'TMUX': '/fixture,123,0', 'TMUX_PANE': '%1',
       'FIXTURE_WORK': str(root / 'work'), 'FIXTURE_ACCOUNT': account, 'FIXTURE_RECORD': pick,
       'ORCH_OVERSEER_SUCCESSOR_ACCOUNTS': '0', 'CLAUDE_CONFIG_DIR': account,
       'BASH_ENV': str(count_dir / 'bash-env'), 'TMPDIR': str(root), 'GIT_CEILING_DIRECTORIES': str(root)}

def run(script, name, extra=None, args=()):
    counter.reset(count_dir)
    with (root / (name + '.out')).open('wb') as out, (root / (name + '.err')).open('wb') as err:
        proc = subprocess.Popen([bash, str(script), '--check-marks', *args], cwd=root / 'work',
                                env={**env, **(extra or {})}, stdout=out, stderr=err)
        try:
            status = proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
            raise
    # One PID can exec more than one wrapped command. Count each PID once.
    external = {}
    for line in (count_dir / 'external').read_text().splitlines():
        pid = line.split()[1]
        if pid != str(proc.pid):
            external.setdefault(pid, line)
    trace = (count_dir / 'trace').read_text(errors='surrogateescape').splitlines()
    count = counter.total(trace, list(external.values()), {str(proc.pid)})
    return status, (root / (name + '.out')).read_bytes(), (root / (name + '.err')).read_bytes(), count

rows = [
    ('complete', identity, {}, (), 0, b'mark-unmeasured'),
    ('bootstrap', None, {}, (), 0, b'mark-unmeasured'),
    ('partial', {**identity, 'model': None}, {'FIXTURE_MODEL': 'fable'}, (), 0,
     b'mark-unmeasured kind=rate reason=one-sample'),
    ('bad-record', 'invalid', {}, (), 0, b'mark-unmeasured'),
    ('capture-error', identity, {'FAIL_READ': 'capture-pane'}, (), 1, None),
    ('window-error', identity, {'FAIL_READ': '#{window_id}'}, (), 1, None),
    ('path-error', identity, {'FAIL_READ': '#{pane_current_path}'}, (), 1, None),
    ('shape-error', identity, {'FAIL_READ': '#{pane_pid} #{pane_current_command}'}, (), 1, None),
    ('gone', identity, {'PANE_GONE': 'yes'}, (), 1, None),
    ('context-due', identity, {}, ('--context', '950:1000'), 0, b'mark-reached'),
    ('numeric-fallback', identity, {'ORCH_HANDOFF_CONTEXT_PCT': 'invalid'}, (), 0, b'mark-unmeasured'),
    ('retired-setting', identity, {'ORCH_CONSUMER_REPOS': ''}, (), 1, None),
]
for name, record, extra, args, status, key in rows:
    record_file.unlink(missing_ok=True)
    context_file.unlink(missing_ok=True)
    row_file.unlink(missing_ok=True)
    if record == 'invalid':
        record_file.write_text('{ invalid\n')
    elif record is not None:
        record_file.write_text(json.dumps({'overseer': record}) + '\n')
    if name == 'partial':
        # The row writer emits compact JSON; the event reader searches that spelling.
        row_file.write_text(json.dumps({'event': 'SessionStart', 'harness': 'claude', 'account': account,
                                        'model': 'fable', 'cwd': str(root / 'work')}, separators=(',', ':')) + '\n')
        context_file.write_text(json.dumps({'harness': 'claude', 'model': 'other', 'pane_key': '123 %1'}) + '\n')
    actual = run(scripts / 'oversee-succeed', name, extra, args)
    result(name + ': exit', actual[0], status)
    if key:
        # oversee-watch consumes the first keyed line. Prose stays outside the assertion.
        result(name + ': keyed result', b' '.join(actual[1].split()[1:1 + len(key.split())]).decode(), key.decode())
    if name == 'complete':
        print('metric', 'candidate-own-processes', actual[3], sep='\t')
        if BOUND is not None:
            result('complete: own process bound', int(actual[3] < BOUND), 1)
        complete = actual
    if baseline:
        before = run(root / 'base/orch/scripts/oversee-succeed', name + '-base', extra, args)
        for i, field in enumerate(('exit', 'stdout bytes', 'stderr bytes')):
            result(name + ': base ' + field, int(actual[i] == before[i]), 1)
        if name == 'complete':
            print('metric', 'base-own-processes', before[3], sep='\t')
            if BOUND is not None:
                result('base control: rejects process bound', int(before[3] >= BOUND), 1)

# Restore the redundant source initialization on a private tree. This puts the
# removed cost back without changing the named account workload or its result.
shutil.copytree(root / 'candidate', root / 'mutant')
path = root / 'mutant/orch/scripts/lib/lane-launch.sh'
text = path.read_text()
for name in ('lane-claims.sh', 'toml.sh', 'lane-home.sh', 'adapters/claude.sh'):
    old = 'source "${BASH_SOURCE[0]%/*}/' + name + '"'
    new = 'source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/' + name + '"'
    assert text.count(old) == 1, (path, old)
    text = text.replace(old, new)
path.write_text(text)
record_file.write_text(json.dumps({'overseer': identity}) + '\n')
control = run(root / 'mutant/orch/scripts/oversee-succeed', 'control')
result('cost control: same workload exit', control[0], complete[0])
result('cost control: same stdout bytes', int(control[1] == complete[1]), 1)
result('cost control: same stderr bytes', int(control[2] == complete[2]), 1)
if BOUND is not None:
    result('cost control: rejects redundant initialization', int(control[3] >= BOUND), 1)
PY
while IFS=$'\t' read -r kind got want name; do
  case "$kind" in
    assert) assert_eq "$got" "$want" "$name" ;;
    metric) printf 'cost: %s=%s\n' "$got" "$want" ;;
    *) fail 'unknown result record' "$kind" ;;
  esac
done < "$TMP_ROOT/results"
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
