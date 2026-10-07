#!/usr/bin/env bash
# This suite checks the permission inputs consumed by the GitHub token action.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFRESH_DIR="$(cd "$TEST_DIR/.." && pwd)"
SKILL_DIR="$REFRESH_DIR/../skills/review-gate"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT
. "$TEST_DIR/lib/sandbox.sh"
if cmp -s "$REFRESH_DIR/kendex-refresh.yml" "$SKILL_DIR/templates/kendex-refresh.yml"; then
  ok 'the compatibility template equals the shared caller byte for byte'
else bad 'caller template equality'; fi
# A run stuck on the kendex environment gate must not hold the refresh group:
# the release job takes no group and runs before the refresh asks for it, and
# its own shell body force-cancels only a run waiting past the 30-minute bound.
if python3 - "$SKILL_DIR/templates/kendex-refresh.yml" "$TMP" "$BASH" <<'PY'
from datetime import datetime, timedelta, timezone
from pathlib import Path
import json, os, re, subprocess, sys, textwrap

template = Path(sys.argv[1]).read_text()
cond = "github.repository != 'vanillagreencom/kendex' && github.ref == format('refs/heads/{0}', github.event.repository.default_branch)"

def check_shape(text):
    jobs = dict(re.findall(r'^  ([a-z]+):\n(.*?)(?=^  [a-z]+:\n|\Z)', text.split('\njobs:\n', 1)[1], re.M | re.S))
    release, refresh = jobs['release'], jobs['refresh']
    assert not re.search(r'^concurrency:', text, re.M), 'a workflow-level group queues the release behind a stuck run'
    assert 'concurrency:' not in release and 'environment:' not in release
    assert re.search(r'^    permissions:\n      actions: write\n    steps:', release, re.M)
    assert re.search(r'^    if: ' + re.escape(cond) + '$', release, re.M)
    assert re.search(r'^    needs: release$', refresh, re.M)
    assert re.search(r'^    uses: vanillagreencom/kendex/\.github/workflows/refresh-consumer\.yml@v1$', refresh, re.M)
    assert re.search(r'^    if: \$\{\{ success\(\) && ' + re.escape(cond) + r' \}\}$', refresh, re.M)
    assert re.search(r'^    concurrency:\n      group: kendex-refresh\n      cancel-in-progress: false\n', refresh, re.M)
    return release

release = check_shape(template)
for name, old, new in (
    ('workflow-group', '\njobs:\n', '\nconcurrency:\n  group: kendex-refresh\n  cancel-in-progress: false\n\njobs:\n'),
    ('cancel-in-progress', '      cancel-in-progress: false\n', '      cancel-in-progress: true\n'),
    ('no-needs', '    needs: release\n', ''),
    ('failed-release-enters-group', '${{ success() && ', '${{ !cancelled() && '),
):
    assert template.count(old) == 1, name
    try: check_shape(template.replace(old, new))
    except (AssertionError, KeyError): pass
    else: raise AssertionError('must-fail control missed ' + name)

body = textwrap.dedent(release.split('        run: |\n', 1)[1])
root = Path(sys.argv[2]) / 'release-stuck'
bin_dir = root / 'bin'
bin_dir.mkdir(parents=True)
shim = bin_dir / 'gh'
shim.write_text('#!/usr/bin/env bash\nset -euo pipefail\n[ "$1" = api ] || exit 90\nshift\n'
                'if [ "$1" = --method ]; then printf \'%s %s\\n\' "$2" "$3" >>"$WRITES"; exit 0; fi\n'
                '[ "${FAIL_READ:-no}" != yes ] || exit 42\n'
                'printf \'%s\\n\' "$1" >>"$READS"\n[ "$2" = --jq ] || exit 91\n'
                'case "$1" in */actions/runs/*) jq -r "$3" "$RUNS.${1##*/}" ;; *) jq -r "$3" "$RUNS" ;; esac\n')
shim.chmod(0o755)
now = datetime.now(timezone.utc)
def ago(minutes): return (now - timedelta(minutes=minutes)).strftime('%Y-%m-%dT%H:%M:%SZ')
# The real list honours ?status=waiting; the fixture does not, so the
# in-progress row proves the body's own status filter. Run 104 leaves
# waiting between the list and the re-read before its cancel.
runs = [
    {'id': 101, 'status': 'waiting', 'updated_at': ago(31)},
    {'id': 102, 'status': 'waiting', 'updated_at': ago(10)},
    {'id': 103, 'status': 'in_progress', 'updated_at': ago(90)},
    {'id': 104, 'status': 'waiting', 'updated_at': ago(40)},
]
(root / 'runs.json').write_text(json.dumps({'workflow_runs': runs}))
for listed in runs:
    reread = dict(listed, status='in_progress') if listed['id'] == 104 else listed
    (root / f"runs.json.{listed['id']}").write_text(json.dumps(reread))

def run(script, expected_exit=0, **extra):
    for name in ('writes', 'reads'): (root / name).write_text('')
    env = {'PATH': str(bin_dir) + os.pathsep + os.environ['PATH'], 'HOME': str(root),
           'GH_TOKEN': 'workflow-token', 'GH_REPO': 'acme/widgets',
           'RUNS': str(root / 'runs.json'), 'WRITES': str(root / 'writes'), 'READS': str(root / 'reads')}
    env.update(extra)
    result = subprocess.run([sys.argv[3], '-c', script], cwd=root, env=env, text=True, capture_output=True)
    assert result.returncode == expected_exit, (result.returncode, result.stderr)
    return (root / 'writes').read_text().splitlines(), result.stdout.splitlines()

# A real Actions API read can fail. The shell must report failure, and the
# caller's success() gate above then keeps refresh outside its group.
assert run(body, 42, FAIL_READ='yes') == ([], [])
assert body.count('set -euo pipefail') == 1
try: run(body.replace('set -euo pipefail', 'set -uo pipefail'), 42, FAIL_READ='yes')
except AssertionError: pass
else: raise AssertionError('must-fail: a swallowed cleanup API error passes')

def cancels(*ids): return [f'POST repos/acme/widgets/actions/runs/{i}/force-cancel' for i in ids]
writes, out = run(body)
assert writes == cancels(101), writes
assert out == ['refresh-released=101', 'refresh-release-skipped=104 status=in_progress'], out
assert (root / 'reads').read_text().splitlines() == [
    'repos/acme/widgets/actions/workflows/kendex-refresh.yml/runs?status=waiting&per_page=100',
    'repos/acme/widgets/actions/runs/101', 'repos/acme/widgets/actions/runs/104']
# Must-fail controls: without the release the stuck run stays; without the
# bound a young waiting run is cancelled; without the list's status filter an
# in-progress run reaches the re-read; without the re-read a run that left
# waiting is cancelled.
skipped = ['refresh-release-skipped=104 status=in_progress']
for name, old, new, expected in (
    ('release', 'gh api --method POST', ': gh api --method POST', (cancels(), out)),
    ('bound', ' and now - (.updated_at | fromdateiso8601) > 1800', '',
     (cancels(101, 102), ['refresh-released=101', 'refresh-released=102'] + skipped)),
    ('status', 'select(.status == "waiting" and ', 'select(',
     (cancels(101), ['refresh-released=101', 'refresh-release-skipped=103 status=in_progress'] + skipped)),
    ('re-read', 'if [ "$status" != waiting ]; then', 'if false; then',
     (cancels(101, 104), ['refresh-released=101', 'refresh-released=104'])),
):
    assert body.count(old) == 1, name
    mutant = run(body.replace(old, new))
    assert mutant == expected, (name, mutant)
PY
then ok 'release job force-cancels only a run waiting past the bound before the grouped refresh and skips one that left waiting before the cancel; release, bound, status, re-read and group controls'; else bad 'stuck-waiting release'; fi
if python3 - "$SKILL_DIR/templates/review-gate-writer.yml" "$TMP" <<'PY'
from pathlib import Path
import os
import re
import subprocess
import sys
import textwrap

template = Path(sys.argv[1]).read_text()
blocks = re.findall(r'^      - name: Install kendex for change classification\n(.*?)(?=^      - name:)', template, re.M | re.S)
assert len(blocks) == 1, 'writer installer step missing'
block = blocks[0]
assert 'KENDEX_VERSION' not in block, 'writer retains an engine version pin'
assert re.search(r'^          GH_TOKEN: ""$', block, re.M)
assert re.search(r'^          GITHUB_TOKEN: \$\{\{ github.token \}\}$', block, re.M)
body = textwrap.dedent(block.split('        run: |\n')[1])
root = Path(sys.argv[2]) / 'writer-install'
scripts = root / '.agents/skills/review-gate/scripts'
scripts.mkdir(parents=True)
bin_dir = root / 'bin'
bin_dir.mkdir()

def executable(path, body):
    path.write_text('#!/usr/bin/env bash\nset -euo pipefail\n' + body)
    path.chmod(0o755)

executable(scripts / 'review-policy', '''case "$1" in
  --check-config) printf 'review-policy=%s\\n' "$POLICY" ;;
  --lock-kendex) printf 'review-policy-lock-kendex=%s\\n' "$LOCK_MODE" ;;
  *) exit 2 ;;
esac
''')
executable(scripts / 'install-latest.sh', '''printf 'latest|%s|%s\\n' "$GH_TOKEN" "$GITHUB_TOKEN" >>"$INSTALLS"
''')
executable(bin_dir / 'curl', '''printf '%s\\n' "$*" >"$CURL_ARGS"
printf '%s\\n' 'printf "main\\n" >>"$INSTALLS"; exit "$MAIN_EXIT"'
''')
env = {'PATH': str(bin_dir) + os.pathsep + os.environ['PATH'], 'HOME': str(root),
       'GH_TOKEN': '', 'GITHUB_TOKEN': 'read-only-workflow-token',
       'KENDEX_INSTALLER_REPO': 'vanillagreencom/kendex',
       'KENDEX_INSTALLER_SHA': 'f6ad9491a810a9256f04f66f8d083eb9db709602',
       'RUNNER_TEMP': str(root), 'GITHUB_ENV': str(root / 'github-env'),
       'INSTALLS': str(root / 'installs'), 'CURL_ARGS': str(root / 'curl-args')}

def run(command, policy, lock, main_exit):
    (root / 'installs').write_text('')
    (root / 'github-env').write_text('')
    result = subprocess.run(['bash', '-c', command], cwd=root,
                            env=dict(env, POLICY=policy, LOCK_MODE=lock, MAIN_EXIT=str(main_exit)),
                            text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    return (root / 'installs').read_text().splitlines()

# Run the template's actual shell body. The installer itself has its own
# immutable-commit and credential-boundary suite in install-latest.test.sh.
for policy, lock, main_exit, expected in (
    ('active', 'off', 0, ['latest||read-only-workflow-token']),
    ('inactive', 'off', 0, []),
    ('active', 'main', 0, ['latest||read-only-workflow-token', 'main']),
    ('active', 'main', 1, ['latest||read-only-workflow-token', 'main']),
):
    assert run(body, policy, lock, main_exit) == expected, (policy, lock, main_exit)
    if lock == 'main':
        assert (root / 'curl-args').read_text().strip() == ('-fsSL https://raw.githubusercontent.com/'
            'vanillagreencom/kendex/f6ad9491a810a9256f04f66f8d083eb9db709602/install.sh')
        recorded = (root / 'github-env').read_text().splitlines()
        assert recorded == ([f'HARNESS_CI_LOCK_KENDEX={root}/kendex-lock/.local/bin/kendex'] if main_exit == 0 else [])
needle = '  .agents/skills/review-gate/scripts/install-latest.sh'
assert body.count(needle) == 1
mutant = body.replace(needle, '  : # ' + needle.strip())
assert mutant != body
assert run(mutant, 'active', 'off', 0) != ['latest||read-only-workflow-token'], 'missed writer install control'
PY
then ok 'writer uses the latest installer before optional fixed-commit main installation; dropped-call control'; else bad 'writer latest installation'; fi
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
