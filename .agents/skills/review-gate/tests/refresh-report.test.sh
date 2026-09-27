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
  print(json.dumps([".agents/skills/review-gate/scripts/test.sh"]))
 else: print(Path(os.environ["HISTORICAL_LOCK"]).read_text())
elif name=="kendex":
 assert os.environ["GH_TOKEN"]=="consumer"
 assert sys.argv[1:5]==["report","--asset","review-gate","--scope"]
 if os.environ.get("REAL_KENDEX"):
  os.execv(os.environ["REAL_KENDEX"], ["kendex",*sys.argv[1:]])
 lock=json.loads(Path(".kendex-lock.json").read_text())
 owned=any(e.get("sourceRepo")=="vanillagreencom/kendex" for e in lock["entries"].values())
 route="--repo vanillagreencom/kendex --label ci-infra" if owned else "--repo acme/repo"
 print("would run: gh issue create "+route+" --title test",file=sys.stderr)
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
findings=[{'path':'.agents/skills/review-gate/scripts/test.sh','body':'The shipped command fails.\n$(touch should-not-exist)',
           'url':'https://github.com/acme/repo/pull/1#discussion_r10'}]
findings[0]['claim']=findings[0]['body']
def reset(**extra):
 world.write_text(json.dumps(dict(issues=[],writes=[],**extra))); summary.write_text('')
def run(driver=skill/'scripts/refresh-report.py', rows=findings, overrides=None):
 result=subprocess.run(['python3',str(driver),'a'*40,'1'],input=json.dumps(rows),text=True,
                       capture_output=True,env=dict(env,**(overrides or {})),cwd=root)
 assert result.returncode==0,result.stderr
 return json.loads(world.read_text())
reset(); first=run()
assert len(first['writes'])==1
issue=first['issues'][0]
assert issue['labels']==['bug','ci-infra','agent:generalist']
assert issue['title'].startswith('[kendex-render:')
assert 'Reached by:' in issue['body'] and env['GITHUB_RUN_ID'] in issue['body']
assert findings[0]['path'] in issue['body'] and findings[0]['url'] in issue['body']
assert not (root/'should-not-exist').exists()
assert len(run()['writes'])==1
assert len(run(overrides={'GITHUB_RUN_ID':'43'})['writes'])==2
# Identical text from fresh inline comments or shifted suppressed locations
# must reuse one issue. Different claim text must keep its own issue.
inline_pair=[dict(findings[0],url='https://github.com/acme/repo/pull/1#discussion_r10'),
             dict(findings[0],url='https://github.com/acme/repo/pull/2#discussion_r20')]
suppressed_pair=[dict(findings[0],body=f"### Suppressed comments (1)\n**{findings[0]['path']}:{line}**\nDefect",
                      claim=f"### Suppressed comments (1)\n**{findings[0]['path']}**\nDefect") for line in (1,20)]
for original, repeated in (inline_pair, suppressed_pair):
 reset(); run(rows=[original]); reused=run(rows=[repeated],overrides={'GITHUB_RUN_ID':'43'})
 assert len(reused['issues'])==1 and '\n'.join('> '+line for line in original['body'].splitlines()) in reused['issues'][0]['body']
 assert '\n'.join('> '+line for line in repeated['body'].splitlines()) in reused['writes'][-1]['body']
 distinct=dict(repeated,body=repeated['body']+'\nAnother defect.',claim=repeated['claim']+'\nAnother defect.')
 assert len(run(rows=[distinct])['issues'])==2
# A closed report is absent from GitHub's open-only listing and permits a new issue.
reset(); assert len(run()['issues'])==1
for overrides, extra in [({'KENDEX_ISSUES_TOKEN':''},{}), ({},{'deny':True})]:
 reset(**extra); result=run(overrides=overrides)
 assert result['writes']==[] and 'issues/new?' in summary.read_text()
 assert findings[0]['url'] in summary.read_text()
# Permission recovery runs the same candidates even after earlier policy replies.
reset(); run(overrides={'KENDEX_ISSUES_TOKEN':''}); assert len(run()['issues'])==1
reset(); assert run(rows=[dict(findings[0],path='src/private.py')])['writes']==[]
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
assert 'Package routing unresolved' in summary.read_text()
# Controls preserve matching text while removing each independent rule.
source=(skill/'scripts/refresh-report.py').read_text()
for needle,replacement,rows,expect in [
 ('if path not in records:', 'if True or path not in records:', findings, 'path'),
 ('if existing:', 'if False and existing:', findings, 'dedup'),
 ('finding["claim"]', 'finding["claim"] if False else finding["body"]', suppressed_pair, 'claim'),
 ('[repo, path, finding["claim"]]', '[repo, path, finding["claim"], finding["url"]]', inline_pair, 'instance'),
 ('            ).stderr', '            ).stdout', findings, 'stream'),
]:
 assert source.count(needle)==1
 mutant=root/(expect+'.py'); mutant.write_text(source.replace(needle,replacement))
 reset()
 if expect=='dedup':
  run(mutant); assert len(run(mutant)['issues'])==2
 elif expect in ('claim','instance'):
  run(mutant,rows=[rows[0]]); assert len(run(mutant,rows=[rows[1]])['issues'])==2
 else:
  assert run(mutant,rows=rows)['writes']==[]
PY
then ok 'reporter token isolation, render binding, labels, evidence, duplicate handling and permission fallback'; else bad 'reporter behavior and controls'; fi
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
