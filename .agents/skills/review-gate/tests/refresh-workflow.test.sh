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
 # The consumer runs a kendex release, never a main build; the release route
 # picks which one and holds the installer commit to its tag.
 install=next(s for s in steps if s.get('name')=='Install pinned kendex')
 assert re.fullmatch(r'v\d+\.\d+\.\d+',install['env']['KENDEX_VERSION'])
 assert install['env']['KENDEX_INSTALLER_REPO']=='vanillagreencom/kendex'
 assert install['env']['GH_TOKEN']=='""'
 assert 'raw.githubusercontent.com/$KENDEX_INSTALLER_REPO/$KENDEX_INSTALLER_SHA/install.sh" | sh -s -- --version "$KENDEX_VERSION"' in install['run']
 # A tag can be moved, so the installer path names a 40-hex commit and no
 # ${KENDEX_VERSION once the step's env values are put in.
 url=re.search(r'curl -fsSL "([^"]*)"',install['run']).group(1)
 for k in ('KENDEX_INSTALLER_REPO','KENDEX_INSTALLER_SHA'): url=url.replace('$'+k,install['env'].get(k,''))
 assert re.fullmatch(r'https://raw\.githubusercontent\.com/vanillagreencom/kendex/[0-9a-f]{40}/install\.sh',url),url
check(workflow)
for mutation in ('repository','permission','exposure','branch','fallback','self','pin','installer'):
 w=copy.deepcopy(workflow);job=w['jobs']['refresh'];steps=job['steps'];token=next(s for s in steps if s.get('id')=='issues-token')
 if mutation=='repository': token['with']['repositories']='kendex,consumer'
 elif mutation=='permission': token['with']['permission-contents']='write'
 elif mutation=='exposure': steps[0]['env']={'TOKEN':'${{ steps.issues-token.outputs.token }}'}
 elif mutation=='branch': job['if']='true'
 elif mutation=='self': job['if']=job['if'].split(' && ')[1]
 elif mutation=='pin': next(s for s in steps if s.get('name')=='Install pinned kendex')['env']['KENDEX_VERSION']='main-build-261-1-d1637e9ee73474603707339935ebaed33d175269'
 elif mutation=='installer': next(s for s in steps if s.get('name')=='Install pinned kendex')['env']['KENDEX_INSTALLER_SHA']='v1.1.0'
 else: token['continue-on-error']=False
 try: check(w)
 except AssertionError: pass
 else: raise AssertionError('must-fail control missed '+mutation)
PY
then ok 'default-branch environment, consumer and Issues token boundaries, the kendex pin, the installer commit, fallback and mutation controls'; else bad 'workflow token boundary'; fi
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
