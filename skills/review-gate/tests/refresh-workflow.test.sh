#!/usr/bin/env bash
# This suite checks the permission inputs consumed by the GitHub token action.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT
. "$TEST_DIR/lib/sandbox.sh"
if python3 - "$SKILL_DIR/templates/kendex-refresh.yml" <<'PY'
import copy,json,re,sys
# Read the literal token-action inputs and step environments. Full YAML
# syntax belongs to preflight; this contract uses only block mappings.
text=open(sys.argv[1]).read()
job=dict(re.findall(r'^    (if|environment): (.+)$',text,re.M))
steps=[]
for block in re.split(r'^      - ',text,flags=re.M)[1:]:
 step={}; current=None
 for line in block.splitlines():
  if current!='run' and line.lstrip().startswith('#'): continue
  match=re.match(r'^(?:        )?(name|uses|id|continue-on-error): (.+)$',line)
  if match:
   k,v=match.groups();step[k]=True if v=='true' else v;continue
  if line in ('        with:', '        env:'):
   current=line.strip()[:-1];step[current]={};continue
  if line=='        run: |': current='run';step[current]='';continue
  if current=='run': step[current]+=line.strip()+'\n';continue
  if current in ('with','env'):
   match=re.match(r'^          ([a-zA-Z_-]+): (.+)$',line)
   assert match,line
   k,v=match.groups();step[current][k]=v
 steps.append(step)
job['steps']=steps
workflow={'jobs':{'refresh':job}}
def check(w):
 job=w['jobs']['refresh']; steps=job['steps']
 assert job['environment']=='kendex'
 assert "github.ref == format('refs/heads/{0}', github.event.repository.default_branch)" in job['if']
 assert "github.repository != 'vanillagreencom/kendex'" in job['if']
 tokens=[s for s in steps if s.get('uses','').startswith('actions/create-github-app-token@')]
 assert len(tokens)==2
 consumer,upstream=tokens
 assert consumer['with']['repositories']=='${{ github.event.repository.name }}'
 assert consumer['with']['owner']=='${{ github.repository_owner }}'
 assert 'permission-issues' not in consumer['with']
 assert upstream['with']['owner']=='vanillagreencom'
 assert upstream['with']['repositories']=='kendex'
 assert {k:v for k,v in upstream['with'].items() if k.startswith('permission-')}=={'permission-issues':'write'}
 assert upstream['continue-on-error'] is True
 for token in tokens:
  assert token['with']['app-id']=='${{ secrets.FLEET_GH_APP_ID }}'
  assert token['with']['private-key']=='${{ secrets.FLEET_GH_APP_PRIVATE_KEY }}'
  assert not token['with'].get('skip-token-revoke',False)
 # The upstream token reaches exactly the trusted review answerer, after refresh.
 users=[s for s in steps if 'steps.issues-token.outputs.token' in json.dumps(s)]
 assert len(users)==1
 assert users[0]['env']['GH_TOKEN']=='${{ steps.token.outputs.token }}'
 assert users[0]['env']['KENDEX_ISSUES_TOKEN']=='${{ steps.issues-token.outputs.token }}'
 assert '$RUNNER_TEMP/refresh-skills/.agents/skills/review-gate/scripts/refresh-reviews.sh' in users[0]['run']
 assert steps.index(upstream)>next(i for i,s in enumerate(steps) if 'refresh-consumer.sh' in s.get('run',''))
 # The installer owns run-time release resolution. No workflow value can
 # keep a consumer on a version after the catalog moves forward.
 install=next(s for s in steps if s.get('name')=='Install latest released kendex')
 assert set(install['env'])=={'GH_TOKEN','GITHUB_TOKEN'}
 assert install['env']['GH_TOKEN']=='""'
 assert install['env']['GITHUB_TOKEN']=='${{ github.token }}'
 assert [s for s in steps if 'github.token' in json.dumps(s)]==[install]
 assert steps.index(consumer)>steps.index(install)
 assert install['run']=='set -euo pipefail\nexec .agents/skills/review-gate/scripts/install-latest.sh\n'
 assert 'KENDEX_VERSION' not in json.dumps(w)
check(workflow)
for mutation in ('repository','permission','exposure','branch','fallback','self','pin','installer','api-token','app-token','gh-token','early-app'):
 w=copy.deepcopy(workflow);job=w['jobs']['refresh'];steps=job['steps'];token=next(s for s in steps if s.get('id')=='issues-token')
 if mutation=='repository': token['with']['repositories']='kendex,consumer'
 elif mutation=='permission': token['with']['permission-contents']='write'
 elif mutation=='exposure': steps[0]['env']={'TOKEN':'${{ steps.issues-token.outputs.token }}'}
 elif mutation=='branch': job['if']='true'
 elif mutation=='self': job['if']=job['if'].split(' && ')[1]
 elif mutation=='pin': next(s for s in steps if s.get('name')=='Install latest released kendex')['env']['KENDEX_VERSION']='v1.2.0'
 elif mutation=='installer': next(s for s in steps if s.get('name')=='Install latest released kendex')['run']='set -euo pipefail\ntrue # exec .agents/skills/review-gate/scripts/install-latest.sh\n'
 elif mutation=='api-token': next(s for s in steps if s.get('name')=='Install latest released kendex')['env'].pop('GITHUB_TOKEN')
 elif mutation=='app-token': next(s for s in steps if s.get('name')=='Install latest released kendex')['env']['GITHUB_TOKEN']='${{ steps.token.outputs.token }}'
 elif mutation=='gh-token': next(s for s in steps if s.get('name')=='Install latest released kendex')['env']['GH_TOKEN']='${{ github.token }}'
 elif mutation=='early-app':
  consumer=next(s for s in steps if s.get('id')=='token');steps.remove(consumer);steps.insert(0,consumer)
 else: token['continue-on-error']=False
 try: check(w)
 except AssertionError: pass
 else: raise AssertionError('must-fail control missed '+mutation)
PY
then ok 'default-branch environment, token boundaries, unpinned release installation, fallback and mutation controls'; else bad 'workflow token boundary'; fi
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
