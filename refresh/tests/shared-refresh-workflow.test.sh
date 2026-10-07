#!/usr/bin/env bash
# Holds .github/workflows/refresh-consumer.yml, the shared workflow each
# consumer's caller runs: its job and token boundaries, the rule that every
# step body runs its scripts from the kendex checkout, and its install step's
# actual shell body against a recorded tag list and installer. Both refresh
# step bodies run recording executables to check their path, working
# directory and failure status. What
# refresh-consumer.sh itself sources is refresh-consumer.test.sh's.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW="$TEST_DIR/../../.github/workflows/refresh-consumer.yml"
TMP="$(mktemp -d)" || { echo 'shared-refresh-workflow: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP && ! -L $TMP ]] || { echo "shared-refresh-workflow: scratch=not-a-directory value=[$TMP]" >&2; exit 1; }
TMP="$(cd -- "$TMP" && pwd -P)" || { echo 'shared-refresh-workflow: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'
  return 0
}

if python3 - "$WORKFLOW" "$TMP" "$BASH" <<'PY'
import copy, json, pathlib, re, subprocess, sys
# Read the literal job keys, step inputs and run bodies. Full YAML syntax
# belongs to preflight; this contract uses only block mappings.
text = open(sys.argv[1]).read()
job = dict(re.findall(r'^    (environment|runs-on): (.+)$', text, re.M))
steps = []
for block in re.split(r'^      - ', text, flags=re.M)[1:]:
    step = {}; current = None
    for line in block.splitlines():
        if current != 'run' and line.lstrip().startswith('#'):
            continue
        match = re.match(r'^(?:        )?(name|uses|id|continue-on-error|working-directory): (.+)$', line)
        if match:
            k, v = match.groups(); step[k] = True if v == 'true' else v; current = None; continue
        if line in ('        with:', '        env:'):
            current = line.strip()[:-1]; step[current] = {}; continue
        if line == '        run: |':
            current = 'run'; step[current] = ''; continue
        if current == 'run':
            step[current] += line.strip() + '\n'; continue
        if current in ('with', 'env'):
            match = re.match(r'^          ([a-zA-Z_-]+): (.+)$', line)
            assert match, line
            k, v = match.groups(); step[current][k] = v
    steps.append(step)
job['steps'] = steps
assert len(steps) >= 6, 'step parser found too few steps'

workspace = pathlib.Path(sys.argv[2]) / 'workspace'
consumer_dir = workspace / 'consumer'
release_dir = workspace / 'kendex' / 'refresh'
consumer_dir.mkdir(parents=True)
release_dir.mkdir(parents=True)
record = workspace / 'executions'
for script in ('refresh-consumer.sh', 'refresh-reviews.sh'):
    executable = release_dir / script
    executable.write_text('#!' + sys.argv[3] + '\nset -euo pipefail\n'
                          'printf "%s|%s\\n" "$0" "$PWD" >>"$RECORD"\n'
                          'exit "$SCRIPT_EXIT"\n')
    executable.chmod(0o755)

def check(job):
    steps = job['steps']
    assert job['environment'] == 'kendex'
    assert job['runs-on'] == "${{ vars.CI_RUNNER_2V || 'ubuntu-latest' }}"
    checkouts = [s for s in steps if s.get('uses', '').startswith('actions/checkout@')]
    assert len(checkouts) == 2
    consumer, kendex = checkouts
    assert all(s['with']['persist-credentials'] == 'false' for s in checkouts)
    assert consumer['with']['path'] == 'consumer' and 'repository' not in consumer['with']
    assert kendex['with'] == {'repository': '${{ job.workflow_repository }}', 'ref': '${{ job.workflow_sha }}',
                              'path': 'kendex', 'persist-credentials': 'false'}
    # Every step body runs its scripts from the kendex checkout at the
    # workflow's commit. The .agents/ assertion reads step bodies only.
    runs = [s for s in steps if 'run' in s]
    assert runs and not any('.agents/' in s['run'] for s in runs)
    for script in ('refresh-consumer.sh', 'refresh-reviews.sh'):
        users = [s for s in runs if script in s['run']]
        assert len(users) == 1
        assert users[0]['working-directory'] == 'consumer'
        assert f'exec "$GITHUB_WORKSPACE/kendex/refresh/{script}"' in users[0]['run']
        # Execute the workflow's own body from the consumer checkout. The
        # record identifies the release executable, so a commented call or
        # execution of a consumer copy cannot satisfy the contract.
        for status in (0, 47):
            record.write_text('')
            result = subprocess.run([sys.argv[3], '-c', users[0]['run']], cwd=consumer_dir,
                                    env={'PATH': '/usr/bin:/bin', 'GITHUB_WORKSPACE': str(workspace),
                                         'RECORD': str(record), 'SCRIPT_EXIT': str(status)},
                                    capture_output=True, text=True, timeout=10)
            assert record.read_text() == f'{release_dir / script}|{consumer_dir}\n', (script, status, 'execution')
            assert result.returncode == status, (script, status, 'failure propagation', result.returncode)
    install = next(s for s in runs if './install.sh' in s['run'])
    assert install['working-directory'] == 'kendex'
    assert install['env'] == {'GH_TOKEN': '""', 'WORKFLOW_REF': '${{ job.workflow_ref }}', 'WORKFLOW_SHA': '${{ job.workflow_sha }}'}
    tokens = [s for s in steps if s.get('uses', '').startswith('actions/create-github-app-token@')]
    assert len(tokens) == 2
    repository, upstream = tokens
    assert steps.index(repository) > steps.index(install)
    assert repository['with']['owner'] == '${{ github.repository_owner }}'
    assert repository['with']['repositories'] == '${{ github.event.repository.name }}'
    assert 'permission-issues' not in repository['with']
    assert upstream['with']['owner'] == 'vanillagreencom' and upstream['with']['repositories'] == 'kendex'
    assert {k: v for k, v in upstream['with'].items() if k.startswith('permission-')} == {'permission-issues': 'write'}
    assert upstream['continue-on-error'] is True
    for token in tokens:
        assert token['with']['app-id'] == '${{ secrets.FLEET_GH_APP_ID }}'
        assert token['with']['private-key'] == '${{ secrets.FLEET_GH_APP_PRIVATE_KEY }}'
    users = [s for s in steps if 'steps.issues-token.outputs.token' in json.dumps(s)]
    assert len(users) == 1 and 'refresh-reviews.sh' in users[0]['run']
    assert not any('steps.token.outputs.token' in json.dumps(s) for s in steps[:steps.index(repository)])

check(job)
for script in ('refresh-consumer.sh', 'refresh-reviews.sh'):
    print(f'  executed: {script} from release checkout with consumer cwd; status=0,47')
for mutation in ('consumer-script', 'consumer-cwd', 'kendex-ref', 'credentials', 'exposure', 'repository', 'early-token',
                 'consumer-disabled-exec', 'reviews-disabled-exec', 'consumer-masked-failure', 'reviews-masked-failure'):
    j = copy.deepcopy(job); steps = j['steps']
    refresh = next(s for s in steps if 'refresh-consumer.sh' in s.get('run', ''))
    if mutation == 'consumer-script':
        refresh['run'] = refresh['run'].replace('"$GITHUB_WORKSPACE/kendex/refresh/', '"$GITHUB_WORKSPACE/consumer/.agents/skills/review-gate/scripts/')
    elif mutation == 'consumer-cwd': refresh['working-directory'] = 'kendex'
    elif mutation == 'kendex-ref': steps[1]['with']['ref'] = '${{ github.sha }}'
    elif mutation == 'credentials': steps[1]['with']['persist-credentials'] = 'true'
    elif mutation == 'exposure': refresh['env']['TOKEN'] = '${{ steps.issues-token.outputs.token }}'
    elif mutation == 'repository': next(s for s in steps if s.get('id') == 'issues-token')['with']['repositories'] = 'kendex,consumer'
    elif mutation == 'early-token':
        token = next(s for s in steps if s.get('id') == 'token'); steps.remove(token); steps.insert(0, token)
    elif mutation.endswith(('-disabled-exec', '-masked-failure')):
        script = 'refresh-consumer.sh' if mutation.startswith('consumer-') else 'refresh-reviews.sh'
        step = next(s for s in steps if script in s.get('run', ''))
        call = f'exec "$GITHUB_WORKSPACE/kendex/refresh/{script}"'
        assert step['run'].count(call) == 1, mutation
        replacement = ': # ' + call if mutation.endswith('-disabled-exec') else call[5:] + ' || true # ' + call
        step['run'] = step['run'].replace(call, replacement)
    assert json.dumps(j) != json.dumps(job), mutation
    try: check(j)
    except AssertionError as error:
        if mutation.endswith(('-disabled-exec', '-masked-failure')):
            expected = 'execution' if mutation.endswith('-disabled-exec') else 'failure propagation'
            assert error.args[0][2] == expected, (mutation, error)
            print('  control rejected: ' + mutation)
    else: raise AssertionError('must-fail control missed ' + mutation)
PY
then ok 'step bodies execute release scripts in the consumer cwd and propagate failure under the job and token boundaries; mutation controls'
else bad 'shared workflow structure'; fi

# A caller on a branch other than its default gets no secret: the one job,
# whose steps alone read secrets and mint tokens, does not start. The row
# evaluates the job's own condition for each caller context, and is the one
# owner of the default-branch and self-exclusion rules; each control drops
# one clause from a copy.
guard_matches() { # WORKFLOW
  python3 - "$1" <<'GUARD'
import re, sys
job = open(sys.argv[1]).read().split('\njobs:\n', 1)[1]
jobs = re.findall(r'^  ([A-Za-z0-9_-]+):$', job, re.M)
assert jobs == ['refresh'], jobs
condition = re.search(r'^    if: (.+)$', job, re.M).group(1)
assert job.index('    if: ') < min(job.index(m) for m in ('secrets.', 'create-github-app-token'))
# Each clause is one of the two forms the guard uses; any other refuses.
def runs_for(repository, ref, default_branch):
    result = True
    for clause in condition.split(' && '):
        own = re.fullmatch(r"github\.repository != '([^']+)'", clause)
        branch = clause == "github.ref == format('refs/heads/{0}', github.event.repository.default_branch)"
        assert own or branch, clause
        result = result and (repository != own.group(1) if own else ref == 'refs/heads/' + default_branch)
    return result
for repository, ref, default_branch, runs in (
    ('acme/widgets', 'refs/heads/main', 'main', True),
    ('acme/widgets', 'refs/heads/feature', 'main', False),
    ('acme/widgets', 'refs/heads/main', 'trunk', False),
    ('acme/widgets', 'refs/tags/v1', 'main', False),
    ('vanillagreencom/kendex', 'refs/heads/main', 'main', False),
):
    assert runs_for(repository, ref, default_branch) is runs, (repository, ref)
GUARD
}
if guard_matches "$WORKFLOW"; then ok 'a caller off its default branch, or kendex itself, starts no secret-reading job'
else bad 'default-branch guard'; fi
while IFS='|' read -r rule expression; do
  sed "$expression" "$WORKFLOW" >"$TMP/unguarded.yml"
  if ! cmp -s "$WORKFLOW" "$TMP/unguarded.yml" && ! guard_matches "$TMP/unguarded.yml" 2>/dev/null; then
    ok "control: a dropped $rule clause turns the guard row red"
  else bad "$rule guard control"; fi
done <<'ROWS'
branch|s/ \&\& github.ref == format('refs\/heads\/{0}', github.event.repository.default_branch)//
self-exclusion|s/github.repository != 'vanillagreencom\/kendex' \&\& //
ROWS

# The called job reads a secret only when the workflow declares it and the
# caller maps it; an undeclared one reads empty. The declarations under
# on.workflow_call equal the secrets the steps read, each optional; each
# control edits one in a copy.
declared_matches() { # WORKFLOW
  python3 - "$1" <<'DECLARED'
import re, sys
on, job = open(sys.argv[1]).read().split('\njobs:\n', 1)
block = re.search(r'^  workflow_call:\n(?:    #.*\n)*    secrets:\n((?:      .*\n)+)', on, re.M)
assert block, 'no declared secrets'
declared = re.findall(r'^      ([A-Za-z0-9_]+):\n        required: (\S+)$', block.group(1), re.M)
assert len(declared) * 2 == len(block.group(1).splitlines()), block.group(1)
read = sorted(set(re.findall(r'\$\{\{ secrets\.([A-Za-z0-9_]+) \}\}', job)))
assert read, 'the steps read no secret'
assert [name for name, _ in declared] == read, (declared, read)
assert all(required == 'false' for _, required in declared), declared
DECLARED
}
if declared_matches "$WORKFLOW"; then ok 'the workflow declares, each optional, exactly the secrets its steps read'
else bad 'declared secrets'; fi
while IFS='|' read -r rule expression; do
  sed "$expression" "$WORKFLOW" >"$TMP/undeclared.yml"
  if ! cmp -s "$WORKFLOW" "$TMP/undeclared.yml" && ! declared_matches "$TMP/undeclared.yml" 2>/dev/null; then
    ok "control: $rule turns the declared secrets row red"
  else bad "$rule declared secrets control"; fi
done <<'ROWS'
a renamed declaration|s/^      FLEET_GH_APP_PRIVATE_KEY:$/      FLEET_GH_APP_KEY:/
a required declaration|1,/^        required: false$/s/^        required: false$/        required: true/
ROWS

# The install step's own body, extracted from the workflow.
python3 - "$WORKFLOW" "$TMP/install-body" <<'PY'
import re, sys, textwrap
text = open(sys.argv[1]).read()
blocks = re.findall(r'^      - name: Install the release tagged on this commit\n(.*?)(?=^      - )', text, re.M | re.S)
assert len(blocks) == 1, 'install step missing'
body = textwrap.dedent(blocks[0].split('        run: |\n')[1])
assert 'set -euo pipefail' in body
open(sys.argv[2], 'w').write(body)
PY
mkdir -p "$TMP/bin" "$TMP/kendex"
cat >"$TMP/bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = 'ls-remote --tags origin' ] || exit 2
[ "$TAGS_EXIT" -eq 0 ] || exit "$TAGS_EXIT"
cat "$TAGS"
SH
cat >"$TMP/kendex/install.sh" <<'SH'
printf '%s|%s|%s\n' "$*" "${GH_TOKEN-unset}" "${GITHUB_TOKEN-unset}" >>"$INSTALLS"
[ "$INSTALL_EXIT" -eq 0 ] || exit "$INSTALL_EXIT"
printf '#!/bin/sh\nprintf "kendex %%s\\n" "%s"\n' "$INSTALLED" >"$HOME/.local/bin/kendex"
chmod +x "$HOME/.local/bin/kendex"
SH
chmod +x "$TMP/bin/git"
A=1111111111111111111111111111111111111111
B=2222222222222222222222222222222222222222
C=3333333333333333333333333333333333333333
O=4444444444444444444444444444444444444444

run_install() { # BODY REF TAG_LINES INSTALLED [TAGS_EXIT INSTALL_EXIT]
  printf '%b' "$3" >"$TMP/tags"
  rm -rf -- "${TMP:?}/home"
  mkdir -p "$TMP/home"
  : >"$TMP/installs"
  : >"$TMP/github-path"
  RC=0
  OUT="$(cd "$TMP/kendex" && env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP/home" GH_TOKEN="" \
    WORKFLOW_REF="vanillagreencom/kendex/.github/workflows/refresh-consumer.yml@$2" WORKFLOW_SHA="$A" \
    GITHUB_PATH="$TMP/github-path" TAGS="$TMP/tags" TAGS_EXIT="${5:-0}" INSTALL_EXIT="${6:-0}" \
    INSTALLS="$TMP/installs" INSTALLED="$4" bash -c "$(cat "$1")" 2>&1)" || RC=$?
}

# Success: the exact report, the installer arguments with no token, the
# path record, and the behind-release record when WARN names the newest tag.
install_matches() { # TAG WARN
  local records
  records="$(grep -E '^(kendex-install|refresh-warning)' <<<"$OUT")" || return 1
  [ "$RC" -eq 0 ] || return 1
  if [ -n "$2" ]; then
    [ "$records" = "refresh-warning=behind-release tag=$1 newest=$2
kendex-install: version=$1 commit=$A" ] || return 1
  else
    [ "$records" = "kendex-install: version=$1 commit=$A" ] || return 1
  fi
  [ "$(cat "$TMP/installs")" = "--version $1 --cli-only|unset|unset" ] &&
    [ "$(cat "$TMP/github-path")" = "$TMP/home/.local/bin" ]
}

# Refusal: one keyed record and, before the installer, no install.
install_refused() { # CAUSE VALUE INSTALLS
  [ "$RC" -eq 1 ] && grep -qxF "kendex-install: cause=$1 value=$2" <<<"$OUT" &&
    ! grep -q '^kendex-install: version=' <<<"$OUT" &&
    [ "$(wc -l <"$TMP/installs" | tr -d ' ')" -eq "$3" ] && [ ! -s "$TMP/github-path" ]
}

# name | ref | tag list | installed version | tags exit | installer exit | expected
# The expected column is ok:TAG:NEWEST or refused:CAUSE:VALUE:INSTALLS.
while IFS='|' read -r name ref tags installed tags_exit install_exit expected; do
  run_install "$TMP/install-body" "$ref" "$tags" "$installed" "$tags_exit" "$install_exit"
  IFS=: read -r kind first second third <<<"$expected"
  if [ "$kind" = ok ]; then
    if install_matches "$first" "$second"; then ok "$name"; else bad "$name (rc=$RC)" "$OUT"; fi
  elif install_refused "$first" "$second" "$third"; then ok "$name"
  else bad "$name (rc=$RC)" "$OUT"; fi
done <<ROWS
one stable tag on the commit installs it|refs/tags/v1|$A\trefs/tags/v1.7.0\n$B\trefs/tags/v1.6.0\n$A\trefs/tags/v1\n|1.7.0|0|0|ok:v1.7.0:
an annotated tag selects by its peeled commit|refs/tags/v1|$O\trefs/tags/v1.7.0\n$A\trefs/tags/v1.7.0^{}\n|1.7.0|0|0|ok:v1.7.0:
a higher stable tag of the same major warns behind-release|refs/tags/v1|$A\trefs/tags/v1.6.0\n$B\trefs/tags/v1.7.0\n|1.6.0|0|0|ok:v1.6.0:v1.7.0
patch numbers compare as numbers|refs/tags/v1|$A\trefs/tags/v1.7.9\n$B\trefs/tags/v1.7.10\n|1.7.9|0|0|ok:v1.7.9:v1.7.10
another major's newer tag is not behind-release|refs/tags/v1|$A\trefs/tags/v1.7.0\n$C\trefs/tags/v2.0.0\n|1.7.0|0|0|ok:v1.7.0:
a prerelease tag is not a release|refs/tags/v1|$A\trefs/tags/v1.7.0\n$A\trefs/tags/v1.8.0-rc.1\n$B\trefs/tags/v1.8.0-rc.2\n|1.7.0|0|0|ok:v1.7.0:
a runtime commit different from the installed release tag refuses before install|refs/tags/v1|$B\trefs/tags/v1.6.0\n$A\trefs/tags/v1\n|1.6.0|0|0|refused:release-tags:0:0
a commit with two stable tags refuses before install|refs/tags/v1|$A\trefs/tags/v1.7.0\n$A\trefs/tags/v1.7.1\n|1.7.1|0|0|refused:release-tags:2:0
another major's release tag does not count|refs/tags/v1|$A\trefs/tags/v2.0.0\n|2.0.0|0|0|refused:release-tags:0:0
a branch ref refuses|refs/heads/main|$A\trefs/tags/v1.7.0\n|1.7.0|0|0|refused:workflow-ref:vanillagreencom/kendex/.github/workflows/refresh-consumer.yml@refs/heads/main:0
a failed tag read refuses|refs/tags/v1|$A\trefs/tags/v1.7.0\n|1.7.0|1|0|refused:tags-read:origin:0
a failed installer refuses|refs/tags/v1|$A\trefs/tags/v1.7.0\n|1.7.0|0|1|refused:installer-run:v1.7.0:1
an engine reporting another version refuses|refs/tags/v1|$A\trefs/tags/v1.7.0\n|1.6.0|0|0|refused:engine-version:kendex 1.6.0:1
ROWS

# Each rule keeps its matched text in a disposable copy of the body and
# loses its behavior; the row it governs then turns red.
while IFS='~' read -r rule pattern replacement ref tags installed expected tags_exit install_exit; do
  python3 - "$TMP/install-body" "$TMP/mutant" "$pattern" "$replacement" <<'PY'
import sys
body = open(sys.argv[1]).read()
assert body.count(sys.argv[3]) == 1, sys.argv[3]
changed = body.replace(sys.argv[3], sys.argv[4] + ' # ' + sys.argv[3].replace('\n', ' '))
assert changed != body
open(sys.argv[2], 'w').write(changed)
PY
  run_install "$TMP/mutant" "$ref" "$tags" "$installed" "${tags_exit:-0}" "${install_exit:-0}"
  IFS=: read -r kind first second third <<<"$expected"
  if [ "$kind" = ok ]; then
    if ! install_matches "$first" "$second"; then ok "control: $rule"; else bad "control missed: $rule" "$OUT"; fi
  elif ! install_refused "$first" "$second" "$third"; then ok "control: $rule"
  else bad "control missed: $rule" "$OUT"; fi
done <<ROWS
engine version~[ "\$installed" = "kendex \${tag#v}" ] ||~true ||~refs/tags/v1~$A\trefs/tags/v1.7.0\n~1.6.0~refused:engine-version:kendex 1.6.0:1
runtime commit differs~[ "\$count" -eq 1 ] ||~true ||~refs/tags/v1~$B\trefs/tags/v1.6.0\n~1.6.0~refused:release-tags:0:0
two stable tags~[ "\$count" -eq 1 ] ||~true ||~refs/tags/v1~$A\trefs/tags/v1.7.0\n$A\trefs/tags/v1.7.1\n~1.7.1~refused:release-tags:2:0
behind-release~if [ "\$newest" != "\$tag" ]; then~if false; then~refs/tags/v1~$A\trefs/tags/v1.6.0\n$B\trefs/tags/v1.7.0\n~1.6.0~ok:v1.6.0:v1.7.0
peeled commit~if (peeled || !(name in commit)) commit[name] = \$1 }~if (!(name in commit)) commit[name] = \$1 }~refs/tags/v1~$O\trefs/tags/v1.7.0\n$A\trefs/tags/v1.7.0^{}\n~1.7.0~ok:v1.7.0:
workflow ref~@refs/tags/v([0-9]+)\$ ]] ||~@refs/(tags/v|heads/)([0-9]+|main)\$ ]] ||~refs/heads/main~$A\trefs/tags/v1.7.0\n~1.7.0~refused:workflow-ref:vanillagreencom/kendex/.github/workflows/refresh-consumer.yml@refs/heads/main:0
tags read~git ls-remote --tags origin)" ||~git ls-remote --tags origin || true)" ||~refs/tags/v1~$A\trefs/tags/v1.7.0\n~1.7.0~refused:tags-read:origin:0~1~0
installer run~--cli-only ||~--cli-only || true ||~refs/tags/v1~$A\trefs/tags/v1.7.0\n~1.7.0~refused:installer-run:v1.7.0:1~0~1
ROWS
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
