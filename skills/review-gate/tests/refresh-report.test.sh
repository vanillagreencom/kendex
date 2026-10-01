#!/usr/bin/env bash
# The reporter runs with process-boundary doubles for GitHub and git.
# KENDEX_REPORT_TEST_BIN optionally runs the published CLI in the fixture home;
# the default double uses that CLI's stderr routing stream.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT
. "$TEST_DIR/lib/sandbox.sh"
if python3 - "$SKILL_DIR" "$TMP" "${KENDEX_REPORT_TEST_BIN:-}" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys

skill, root = map(Path, sys.argv[1:3])
real_cli = sys.argv[3]
# Refresh-consumer owns the parse. This mode only formats its two arrays.
reporter = skill / 'scripts/refresh-report.py'
for refused, deprecated, present in [
 ([], [], False),
 ([], ['claude:1:high'], True),
 (['claude::high', 'codex:0:low'], ['claude:1:high'], True),
 (['<script>`bad\nentry</script>'], [], True),
]:
 result = subprocess.run(['python3', str(reporter), '--settings'],
                         input=json.dumps(dict(refused=refused, deprecated=deprecated)),
                         text=True, capture_output=True, env={'PATH':'/usr/bin:/bin'})
 assert result.returncode == 0, result.stderr
 assert ('## Settings' in result.stdout) == present
 assert result.stdout.count('ORCH_OVERSEER_PREFERENCE:') == len(refused) + len(deprecated)
 assert not present or 'harness:model:effort' in result.stdout
 assert '<script>' not in result.stdout and '`bad' not in result.stdout
 if not present: assert result.stdout == ''
source = reporter.read_text()
needle = '    if rows:\n'
assert source.count(needle) == 1
mutant = root / 'settings-report.py'
changed = source.replace(needle, '# ' + needle + '    if False:\n')
assert changed != source
mutant.write_text(changed)
control = subprocess.run(['python3', str(mutant), '--settings'],
                         input=json.dumps(dict(refused=[], deprecated=['claude:1:high'])),
                         text=True, capture_output=True, env={'PATH':'/usr/bin:/bin'})
assert control.returncode == 0 and control.stdout == ''
(root / 'bin').mkdir()
mock = root / 'bin/mock'
mock.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
name=Path(sys.argv[0]).name
assert "KENDEX_ISSUES_TOKEN" not in os.environ
state=Path(os.environ["WORLD"])
w=json.loads(state.read_text())
if name=="git":
 assert os.environ["GH_TOKEN"]=="consumer"
 if sys.argv[1]=="fetch": sys.exit(0)
 if sys.argv[-1].endswith(".kendex-generated.json"):
  print(json.dumps([".agents/skills/review-gate/scripts/test.sh",".github/agents/reviewer.agent.md",
                    ".kendex-generated.json",".kendex-lock.json"]))
 else: print(Path(os.environ["HISTORICAL_LOCK"]).read_text())
elif name=="kendex":
 assert os.environ["GH_TOKEN"]=="consumer"
 assert sys.argv[1:5]==["report","--asset","review-gate","--scope"]
 if os.environ.get("REAL_KENDEX"):
  os.execv(os.environ["REAL_KENDEX"], ["kendex",*sys.argv[1:]])
 lock=json.loads(Path(".kendex-lock.json").read_text())
 owned=any(e.get("sourceRepo")=="vanillagreencom/kendex" for e in lock["entries"].values())
 # The CLI names --repo only for a kendex-owned package.
 route=" --repo vanillagreencom/kendex --label ci-infra" if owned else ""
 print("would run: gh issue create"+route+" --title test",file=sys.stderr)
else:
 assert name=="gh" and os.environ["GH_TOKEN"]=="upstream"
 assert sys.argv[1]=="api" and sys.argv[2].startswith("repos/vanillagreencom/kendex/issues")
 if w.get("deny"):
  print("gh: Resource not accessible by integration (HTTP 403)",file=sys.stderr); sys.exit(1)
 if "--input" in sys.argv:
  p=json.load(sys.stdin)
  w["writes"].append(p)
  if sys.argv[2].endswith("/comments"):
   result={"html_url":"https://github.com/vanillagreencom/kendex/issues/1#comment"}
  else:
   result=dict(p,number=len(w["issues"])+1,html_url="https://github.com/vanillagreencom/kendex/issues/1")
   w["issues"].append(result)
  state.write_text(json.dumps(w)); print(json.dumps(result))
 else: print(json.dumps([w["issues"]]))
''')
mock.chmod(0o755)
for name in ('git','kendex','gh'): (root/'bin'/name).symlink_to(mock)
world=root/'world.json'; summary=root/'summary'
env={'PATH':str(root/'bin')+':/usr/bin:/bin','HOME':str(root),'GH_TOKEN':'consumer',
     'GH_REPO':'acme/repo','KENDEX_ISSUES_TOKEN':'upstream','GITHUB_RUN_ID':'42',
     'GITHUB_STEP_SUMMARY':str(summary),'WORLD':str(world),'HISTORICAL_LOCK':str(root/'historical-lock.json'),
     'REAL_KENDEX':real_cli,'KENDEX_REAL_HOME':'1','KENDEX_BACKGROUND_REFRESH':'off'}
(root/'kendex.toml').write_text('schema = 6\n')
(root/'.kendex-lock.json').write_text(json.dumps({'version':11,'entries':{'skill:review-gate:codex':{
 'name':'review-gate','kind':'skill','harness':'codex','source':'kendex',
 'sourceRepo':'vanillagreencom/kendex','sourceHash':'x','enabled':True}}}))
(root/'historical-lock.json').write_bytes((root/'.kendex-lock.json').read_bytes())
findings=[{'root':10,'path':'.agents/skills/review-gate/scripts/test.sh','body':'The shipped command fails.\n$(touch should-not-exist)',
           'url':'https://github.com/acme/repo/pull/1#discussion_r10'}]
# The stdout protocol refresh-reviews reads: one {root, issue, note} per row.
results=[]
def reset(**extra):
 world.write_text(json.dumps(dict(issues=[],writes=[],**extra))); summary.write_text('')
def run(driver=skill/'scripts/refresh-report.py', rows=findings, overrides=None):
 result=subprocess.run(['python3',str(driver),'a'*40,'1'],input=json.dumps(rows),text=True,
                       capture_output=True,env=dict(env,**(overrides or {})),cwd=root)
 assert result.returncode==0,result.stderr
 results[:]=json.loads(result.stdout)
 return json.loads(world.read_text())
reset(); first=run()
assert len(first['writes'])==1
issue=first['issues'][0]
assert results==[{'root':10,'issue':issue['html_url'],'note':'Filed for upstream confirmation'}]
assert issue['labels']==['bug','ci-infra','agent:maintainer']
assert issue['title'].startswith('[kendex-render:')
assert 'Reached by:' in issue['body'] and env['GITHUB_RUN_ID'] in issue['body']
assert findings[0]['path'] in issue['body'] and findings[0]['url'] in issue['body']
assert not (root/'should-not-exist').exists()
assert len(run()['writes'])==1
assert results[0]['issue']==issue['html_url']
# A later run's evidence comment leaves the finding filed under the issue.
assert len(run(overrides={'GITHUB_RUN_ID':'43'})['writes'])==2
assert results[0]['issue']==issue['html_url'] and results[0]['note']=='Existing open report'
# Identical text from a fresh inline comment must reuse one issue. Different
# text must keep its own issue.
inline_pair=[dict(findings[0],url='https://github.com/acme/repo/pull/1#discussion_r10'),
             dict(findings[0],root=20,url='https://github.com/acme/repo/pull/2#discussion_r20')]
original, repeated = inline_pair
reset(); run(rows=[original]); reused=run(rows=[repeated],overrides={'GITHUB_RUN_ID':'43'})
assert len(reused['issues'])==1 and '\n'.join('> '+line for line in original['body'].splitlines()) in reused['issues'][0]['body']
assert '\n'.join('> '+line for line in repeated['body'].splitlines()) in reused['writes'][-1]['body']
assert results==[{'root':20,'issue':reused['issues'][0]['html_url'],'note':'Existing open report'}]
distinct=dict(repeated,body=repeated['body']+'\nAnother defect.')
assert len(run(rows=[distinct])['issues'])==2
# A closed report is absent from GitHub's open-only listing and permits a new issue.
reset(); assert len(run()['issues'])==1
for overrides, extra in [({'KENDEX_ISSUES_TOKEN':''},{}), ({},{'deny':True})]:
 reset(**extra); result=run(overrides=overrides)
 assert result['writes']==[] and 'issues/new?' in summary.read_text()
 assert results[0]['root']==10 and results[0]['issue'] is None
 assert findings[0]['url'] in summary.read_text()
# Permission recovery runs the same candidates even after earlier policy replies.
reset(); run(overrides={'KENDEX_ISSUES_TOKEN':''}); assert len(run()['issues'])==1
reset(); assert run(rows=[dict(findings[0],path='src/private.py')])['writes']==[]
assert results==[{'root':10,'issue':None,'note':'Not a rendered file'}]
# Only a kendex report route to kendex with a package label files. The lock and
# a Copilot agent render are inventory paths no package claims, and a package
# routed elsewhere is not kendex's: none is filed, the note says why, and the
# summary row carries the evidence but no kendex filing link.
foreign_lock=json.loads((root/'historical-lock.json').read_text())
foreign_lock['entries']['skill:review-gate:codex']['sourceRepo']='another/catalog'
(root/'foreign-lock.json').write_text(json.dumps(foreign_lock))
unclaimed='No single kendex package claims this path'
elsewhere='kendex report does not route review-gate to vanillagreencom/kendex'
not_filed_rows=[
 ('lock', dict(findings[0],path='.kendex-lock.json'), {}, unclaimed),
 ('agent', dict(findings[0],path='.github/agents/reviewer.agent.md'), {}, unclaimed),
 ('elsewhere', findings[0], {'HISTORICAL_LOCK':str(root/'foreign-lock.json')}, elsewhere),
]
def not_filed(driver, row, overrides, note):
 reset(); world=run(driver,rows=[row],overrides=overrides); text=summary.read_text()
 return (world['writes']==[] and results==[{'root':10,'issue':None,'note':note}]
         and row['url'] in text and 'issues/new' not in text)
for name, row, overrides, note in not_filed_rows:
 assert not_filed(skill/'scripts/refresh-report.py', row, overrides, note), name
# A late merged-PR report must keep the recorded package route after removal
# or replacement through the consumer's supported package commands.
for drift in ('removed', 'replaced'):
 current=json.loads((root/'historical-lock.json').read_text())
 if drift=='removed': current['entries']={}
 else: current['entries']['skill:review-gate:codex']['sourceRepo']='another/catalog'
 (root/'.kendex-lock.json').write_text(json.dumps(current))
 reset(); assert len(run()['issues'])==1, drift
 assert len(run()['issues'])==1, drift
# The current checkout is now foreign-owned. Removing historical isolation
# must turn the report into fallback, even though its inventory is still valid.
source=(skill/'scripts/refresh-report.py').read_text()
needle='cwd=project, env=consumer_env'
assert source.count(needle)==1
mutant=root/'current-checkout.py'
mutant.write_text(source.replace(needle,'cwd=None if True else project, env=consumer_env'))
reset(); assert run(mutant)['writes']==[]
assert results[0]['note']==elsewhere
# Controls preserve matching text while removing each independent rule.
source=(skill/'scripts/refresh-report.py').read_text()
for needle,replacement,rows,expect in [
 ('if path not in records:', 'if True or path not in records:', findings, 'path'),
 ('if existing:', 'if False and existing:', findings, 'dedup'),
 ('[repo, path, finding["body"]]', '[repo, path, finding["body"], finding["url"]]', inline_pair, 'instance'),
 ('            ).stderr', '            ).stdout', findings, 'stream'),
]:
 assert source.count(needle)==1
 mutant=root/(expect+'.py'); mutant.write_text(source.replace(needle,replacement))
 reset()
 if expect=='dedup':
  run(mutant); assert len(run(mutant)['issues'])==2
 elif expect=='instance':
  run(mutant,rows=[rows[0]]); assert len(run(mutant,rows=[rows[1]])['issues'])==2
 else:
  assert run(mutant,rows=rows)['writes']==[]
# The filed issue is the rule refresh-reviews resolves on. An unfiled finding
# reported with its filing link, and a finding reported under the evidence
# comment rather than the issue, each turn a case above red.
for needle,replacement,overrides,runs in [
 ('        filed = None\n', '        filed = fallback\n', {'KENDEX_ISSUES_TOKEN':''}, [{}]),
 ('url = result["html_url"]', 'url = filed = result["html_url"]', {}, [{}, {'GITHUB_RUN_ID':'43'}]),
]:
 assert source.count(needle)==1
 mutant=root/'filed.py'; mutant.write_text(source.replace(needle,replacement))
 reset()
 for extra in runs: run(mutant,overrides=dict(overrides,**extra))
 assert results[0]['issue'] is not None and not results[0]['issue'].endswith('/issues/1')
# Filing, or offering the filing link, without a kendex route and package
# label turns every not-filed row red.
for needle,replacement in [
 ('        if token and label:\n', '        if token and (label or True):\n'),
 ('url = fallback if label else None', 'url = fallback if label or True else None'),
]:
 assert source.count(needle)==1
 mutant=root/'label.py'; mutant.write_text(source.replace(needle,replacement))
 for name, row, overrides, note in not_filed_rows:
  assert not not_filed(mutant, row, overrides, note), (name, replacement)
PY
then ok 'reporter token isolation, render binding, labels, evidence, duplicate handling and permission fallback'; else bad 'reporter behavior and controls'; fi
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
