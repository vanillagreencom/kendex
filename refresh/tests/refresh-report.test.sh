#!/usr/bin/env bash
# The reporter runs with process-boundary doubles for GitHub and git.
# KENDEX_REPORT_TEST_BIN optionally runs the published CLI in the fixture home;
# the default double uses that CLI's stderr routing stream.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFRESH_DIR="$(cd "$TEST_DIR/.." && pwd)"
SKILL_DIR="$REFRESH_DIR/../skills/review-gate"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT
. "$TEST_DIR/lib/sandbox.sh"
if python3 - "$REFRESH_DIR" "$TMP" "${KENDEX_REPORT_TEST_BIN:-}" <<'PY'
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys

skill, root = map(Path, sys.argv[1:3])
real_cli = sys.argv[3]
# Refresh-consumer owns the scan. This mode only formats its rows.
reporter = skill / 'refresh-report.py'
astra = 'SECOND_OPINION_CODEX_CMD = "codex exec -m gpt-6-astra"'
fable = 'AGENT_RUNTIME_CONTROLLER_PREFERENCE = "claude:Fable:high"'
def settings_run(entries):
 return subprocess.run(['python3', str(reporter), '--settings'], input=json.dumps(entries),
                       text=True, capture_output=True, env={'PATH':'/usr/bin:/bin'})
def settings(models):
 result = settings_run(dict(deprecated_models=models))
 assert result.returncode == 0, result.stderr
 return result.stdout
# Model rows produce no report.
legacy_models = [astra, fable, 'X = "fable <b> `x` y"']
assert settings(models=legacy_models) == ''
# Consumer settings: a retired key, a retired default under its own key and
# each classifier note make one row; a current value, a retired value under
# another key and an unlisted key make none. Rows are untrusted text.
gate = '- <code>PR_REVIEW_GATE</code>'
timeout = '- <code>SECOND_OPINION_TIMEOUT = &quot;300&quot;</code>'
unset = 'setting-unset: setting=HARNESS_CI_QUEUE_PATHS'
queue = 'queue-only: queue_only=true cause=queue-list-undeclared'
consumer_rows = [
 ({}, None, []),
 ({'PR_REVIEW_GATE': 'on', 'SECOND_OPINION_COUNT': '1', 'PR_REVIEW_GATE_X': 'on'}, [], [gate]),
 ({'SECOND_OPINION_TIMEOUT': '300', 'SECOND_OPINION_COUNT': '300'}, None, [timeout]),
 ({'SECOND_OPINION_TIMEOUT': '1080'}, [unset, queue], ['- <code>' + unset + '</code>', '- <code>' + queue + '</code>']),
 ({'PR_REVIEW_GATE': '<b>`x`</b>'}, ['queue-only: path=a <b> `x` y'],
  [gate, '- <code>queue-only: path=a &lt;b&gt; &#96;x&#96; y</code>']),
]
def consumer(committed, notes):
 entries = dict(committed=committed)
 if notes is not None: entries['notes'] = notes
 result = settings_run(entries)
 assert result.returncode == 0, result.stderr
 rows = re.findall(r'^- <code>.*?</code>', result.stdout, re.M)
 assert (result.stdout == '') == (rows == []) and result.stdout.count('## Consumer settings\n') == (rows != []), result.stdout
 return rows
for committed, notes, rows in consumer_rows:
 assert consumer(committed, notes) == rows, (committed, notes)
# A renamed retired key's row names the key that replaces it; a retired key
# with no successor keeps the plain row. Only a retired key has a successor.
retired_list = json.loads((skill.parent / 'skills/review-gate/retired-settings.json').read_text())
assert set(retired_list['successors']) <= set(retired_list['keys']), set(retired_list['successors']) - set(retired_list['keys'])
plain = '- <code>ORCH_REPORT_COLUMNS</code>: retired; no package reads it.'
renamed = '- <code>ORCH_LANE_MAX_PCT</code>: retired; no package reads it. Set <code>AGENT_RUNTIME_ACCOUNT_MAX_PCT</code> instead.'
def renames():
 result = settings_run(dict(committed={'ORCH_LANE_MAX_PCT': '90', 'ORCH_REPORT_COLUMNS': 'issue'}))
 assert result.returncode == 0, result.stderr
 return [line for line in result.stdout.splitlines() if line.startswith('- ')]
assert renames() == [renamed, plain], renames()
(root / 'bin').mkdir()
mock = root / 'bin/mock'
mock.write_text('''#!/usr/bin/env python3
import json,os,sys
from datetime import datetime, timezone
from pathlib import Path
name=Path(sys.argv[0]).name
assert "KENDEX_ISSUES_TOKEN" not in os.environ
state=Path(os.environ["WORLD"])
w=json.loads(state.read_text())
if name=="git":
 assert os.environ["GH_TOKEN"]=="consumer"
 if sys.argv[1]=="fetch": sys.exit(0)
 if sys.argv[-1].endswith(".kendex-generated.json"):
  print(json.dumps([".agents/skills/review-gate/SKILL.md",".agents/skills/review-gate/scripts/test.sh",
                    ".agents/skills/review-gate/README.md",".agents/skills/ship/SKILL.md",".claude/commands/ship.md",
                    ".claude/agents/maintainer.md",".claude/agents/runtime.md",".codex/agents/runtime.toml",
                    ".claude/skills/review-gate/SKILL.md",".github/agents/reviewer.agent.md",
                    ".kendex-generated.json",".kendex-lock.json"]))
 elif sys.argv[-1].endswith(".kendex-lock.json"): print(Path(os.environ["HISTORICAL_LOCK"]).read_text())
 else: sys.stdout.write(w["files"][sys.argv[-1].split(":",1)[1]])
elif name=="kendex":
 assert os.environ["GH_TOKEN"]=="consumer"
 assert sys.argv[1:3]==["report","--asset"] and sys.argv[4]=="--scope"
 if os.environ.get("REAL_KENDEX"):
  os.execv(os.environ["REAL_KENDEX"], ["kendex",*sys.argv[1:]])
 lock=json.loads(Path(".kendex-lock.json").read_text())
 owned=any((lock["installations"][e["installation"]] if lock["version"]==12 else e)["name"]==sys.argv[3]
           and e.get("sourceRepo")=="vanillagreencom/kendex" for e in lock["entries"].values())
 # The CLI names --repo only for a kendex-owned package.
 route=" --repo vanillagreencom/kendex --label ci-infra" if owned else ""
 print("would run: gh issue create"+route+" --title test",file=sys.stderr)
else:
 assert name=="gh" and os.environ["GH_TOKEN"]=="upstream"
 assert sys.argv[1]=="api" and sys.argv[2].startswith(("repos/vanillagreencom/kendex/issues","search/issues?"))
 # fail: [scope, stderr], scope being every call, writes only or searches only.
 scope,message=w.get("fail") or (None,None)
 if scope=="all" or scope==("write" if "--input" in sys.argv else "search"):
  print(message,file=sys.stderr); sys.exit(1)
 if "--input" in sys.argv:
  p=json.load(sys.stdin)
  w["writes"].append(p)
  if sys.argv[2].endswith("/comments"):
   result={"html_url":"https://github.com/vanillagreencom/kendex/issues/1#comment"}
  else:
   number=len(w["issues"])+1
   # lag: the lookups ("search", "list") that do not yet return this filing.
   result=dict(p,number=number,state="open",state_reason=None,user={"login":"kendex[bot]","type":"Bot"},
               html_url=f"https://github.com/vanillagreencom/kendex/issues/{number}",
               updated_at=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),lag=w.get("lag",[]))
   w["issues"].append(result)
  state.write_text(json.dumps(w)); print(json.dumps(result))
 elif sys.argv[2].startswith("repos/vanillagreencom/kendex/issues?"):
  # The REST issue list: every issue updated at or after since, in the
  # state asked for, one page per --paginate --slurp element.
  from urllib.parse import parse_qs, urlsplit
  q={k:v[0] for k,v in parse_qs(urlsplit(sys.argv[2]).query).items()}
  assert "--paginate" in sys.argv and "--slurp" in sys.argv
  w["lists"]=w.get("lists",0)+1; state.write_text(json.dumps(w))
  items=[i for i in w["issues"] if "list" not in i.get("lag",[]) and i.get("updated_at","")>=q["since"]
         and q["state"] in ("all",i["state"])]
  print(json.dumps([items]))
 else:
  # GitHub search: substring title matches, closed issues included unless
  # the query narrows to is:open. Free text past 256 characters, qualifiers
  # and OR operators aside, is refused as GitHub refuses it.
  from urllib.parse import parse_qs, urlsplit
  q=parse_qs(urlsplit(sys.argv[2]).query)["q"][0]
  assert q.startswith("repo:vanillagreencom/kendex is:issue ") and " in:title " in q
  terms=q.split(" in:title ",1)[1].split(" OR ")
  if len(" ".join(terms))>256:
   print("gh: Validation Failed: The search is longer than 256 characters. (HTTP 422)",file=sys.stderr); sys.exit(1)
  w.setdefault("searches",[]).append(terms); state.write_text(json.dumps(w))
  items=[i for i in w["issues"] if any(t in i["title"] for t in terms) and "search" not in i.get("lag",[])
         and ("is:open" not in q or i["state"]=="open")]
  print(json.dumps([{"total_count":len(items),"incomplete_results":bool(w.get("incomplete")),"items":items}]))
''')
mock.chmod(0o755)
for name in ('git','kendex','gh'): (root/'bin'/name).symlink_to(mock)
world=root/'world.json'; summary=root/'summary'
env={'PATH':str(root/'bin')+':/usr/bin:/bin','HOME':str(root),'GH_TOKEN':'consumer',
     'GH_REPO':'acme/repo','KENDEX_ISSUES_TOKEN':'upstream','GITHUB_RUN_ID':'42',
     'GITHUB_STEP_SUMMARY':str(summary),'WORLD':str(world),'HISTORICAL_LOCK':str(root/'historical-lock.json'),
     'REAL_KENDEX':real_cli,'KENDEX_REAL_HOME':'1','KENDEX_BACKGROUND_REFRESH':'off'}
(root/'kendex.toml').write_text('schema = 7\n')
def entry(name, kind, harness):
 return {'name':name,'kind':kind,'harness':harness,'source':'kendex',
         'sourceRepo':'vanillagreencom/kendex','sourceHash':'x','enabled':True}
(root/'.kendex-lock.json').write_text(json.dumps({'version':11,'entries':{
 'skill:review-gate:codex':entry('review-gate','skill','codex'),
 'agent:runtime:claude':entry('runtime','agent','claude'),
 'agent:maintainer:claude':entry('maintainer','agent','claude'),
 'command:ship:claude':entry('ship','command','claude'),
 'command:ship:codex':entry('ship','command','codex')}}))
(root/'historical-lock.json').write_bytes((root/'.kendex-lock.json').read_bytes())
findings=[{'root':10,'path':'.agents/skills/review-gate/scripts/test.sh','body':'The shipped command fails.\n$(touch should-not-exist)',
           'url':'https://github.com/acme/repo/pull/1#discussion_r10'}]
# The stdout protocol refresh-reviews reads: one {root, issue, note} per row.
results=[]
# The package's SKILL.md at the source, and as a consumer renders it with a
# project-instructions block that shifts every line.
skill_md=['---','name: review-gate','---','','Run the gate.','Then read the verdict.','']
# A script whose `fi` windows repeat with identical surrounding lines, and two
# single-file packages sharing a line, whose only repeated text is their first
# and last lines.
agent='---\nname: x\nDo the work.\n---\n'
block='run() {\n  if a; then\n    x\n  fi\n}\n\n'
files={'.agents/skills/review-gate/SKILL.md':'\n'.join(skill_md),
       '.claude/skills/review-gate/SKILL.md':'\n'.join(skill_md[:4]+['## Project Instructions','']+skill_md[4:]),
       '.agents/skills/review-gate/scripts/test.sh':block*3,
       '.claude/agents/runtime.md':agent,'.claude/agents/maintainer.md':agent,
       '.codex/agents/runtime.toml':'name = "x"\ndeveloper_instructions = """\nDo the work.\n"""\n',
       '.agents/skills/review-gate/README.md':'Run the gate.\n',
       '.claude/commands/ship.md':'Ship it.\n',
       '.agents/skills/ship/SKILL.md':'---\nname: ship\ndescription: Ship.\n---\nShip it.\n'}
def reset(**extra):
 world.write_text(json.dumps(dict(dict(issues=[],writes=[],files=files),**extra))); summary.write_text('')
def attempt(rows, overrides):
 return subprocess.run(['python3',str(reporter),'a'*40,'1'],input=json.dumps(rows),text=True,
                       capture_output=True,env=dict(env,**(overrides or {})),cwd=root)
def run(rows=findings, overrides=None):
 result=attempt(rows, overrides)
 assert result.returncode==0,result.stderr
 results[:]=json.loads(result.stdout)
 return json.loads(world.read_text())
# The historical record and current record can both be compact. Natural
# fixture keys are deliberately independent of the production hash codec.
legacy=(root/'.kendex-lock.json').read_text()
expanded=json.loads(legacy)
compact={'version':12,'installations':{},'entries':{}}
for key, value in expanded['entries'].items():
 compact['installations'][key]={f:value[f] for f in ('name','kind','harness','source')}
 compact['entries'][key]={f:v for f,v in value.items() if f not in ('name','kind','harness','source')}
 compact['entries'][key]['installation']=key
for path in (root/'.kendex-lock.json',root/'historical-lock.json'):
 path.write_text(json.dumps(compact))
reset(); compact_result=run()
assert len(compact_result['writes'])==1 and results[0]['root']==10
for path in (root/'.kendex-lock.json',root/'historical-lock.json'): path.write_text(legacy)
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
# A later run's thread already on the issue adds nothing; a new thread's
# evidence comment leaves the finding filed under the issue.
assert len(run(overrides={'GITHUB_RUN_ID':'43'})['writes'])==1
later_thread=dict(findings[0],root=11,url='https://github.com/acme/repo/pull/1#discussion_r11')
assert len(run(rows=[later_thread],overrides={'GITHUB_RUN_ID':'43'})['writes'])==2
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
# One package line reviewed in two consumers, at other rendered paths, line
# numbers and wording, is one finding. Once its issue is closed, a later
# refresh files and comments nothing and answers with the closed issue.
consumer_a=dict(findings[0],root=30,path='.agents/skills/review-gate/SKILL.md',body='Step order is wrong.',
                line=6,start_line=5,side='RIGHT',start_side='RIGHT',url='https://github.com/acme/repo/pull/1#discussion_r30')
consumer_b=dict(consumer_a,root=40,path='.claude/skills/review-gate/SKILL.md',body='These two steps run backwards.',
                line=8,start_line=7,url='https://github.com/other/repo/pull/9#discussion_r40')
second_consumer={'GH_REPO':'other/repo','GITHUB_RUN_ID':'43'}
def package_line(lag=()):
 reset(lag=list(lag)); filed=run(rows=[consumer_a])
 # The first consumer filed 50 minutes before the second one runs: inside
 # the documented index lag, outside a narrowed one.
 filed['issues'][0]['updated_at']=(datetime.now(timezone.utc)-timedelta(minutes=50)).strftime('%Y-%m-%dT%H:%M:%SZ')
 world.write_text(json.dumps(filed))
 folded=run(rows=[consumer_b],overrides=second_consumer)
 if len(folded['issues'])!=1 or results[0]['note']!='Existing open report': return 'consumers'
 folded['issues'][0].update(state='closed',state_reason='not_planned'); world.write_text(json.dumps(folded))
 later=run(rows=[consumer_a],overrides={'GITHUB_RUN_ID':'44'})
 if later['writes']!=folded['writes'] or results!=[{'root':30,'issue':folded['issues'][0]['html_url'],
                                                    'note':'Closed upstream as not planned'}]: return 'closed'
 return 'one'
# Consumers on one schedule report together: the second run's search misses
# the first run's filing, and the issue list still answers it.
for lag in ((), ('search',)):
 assert package_line(lag=lag)=='one', lag
# The fold stops at the line: another line of the same file, a base-side
# comment and a file-level comment are their own findings, and the
# wording identifies the last two.
# Text repeated in one file keys on its lines and the wording, never its
# position: two claims on `fi` are two findings, one claim on `fi` or on a
# fence folds wherever it sits and whichever render it is in, and text at
# the first and last lines repeats. A range and a single line sharing its
# end are two findings, and a single-file package folds by its own name.
other_line=dict(consumer_a,line=5,start_line=None)
same_end=dict(consumer_a,root=31,start_line=None)
base_side=dict(consumer_a,side='LEFT')
first_fi=dict(consumer_a,root=32,path='.agents/skills/review-gate/scripts/test.sh',line=4,start_line=None)
repeated_text=[first_fi, dict(first_fi,root=33,line=10,body='Another defect.')]
same_claim=[first_fi, dict(first_fi,root=33,line=10)]
fences=[dict(consumer_a,root=34,line=3,start_line=None), dict(consumer_b,root=35,line=1,start_line=None,body=consumer_a['body'])]
agent_a=dict(consumer_a,root=60,path='.claude/agents/runtime.md',line=3,start_line=None)
agents=[agent_a, dict(agent_a,root=61,body='Another wording.'), dict(agent_a,root=62,path='.claude/agents/maintainer.md')]
harnesses=[agent_a, dict(agent_a,root=65,path='.codex/agents/runtime.toml',body='Another wording.')]
# A command renders as a Claude command file and as a Codex skill tree; a
# skill's two files sharing a line stay two.
command_harnesses=[dict(agent_a,root=66,path='.claude/commands/ship.md',line=1),
                   dict(agent_a,root=67,path='.agents/skills/ship/SKILL.md',line=5,body='Another wording.')]
skill_files=[dict(agent_a,root=68,path='.agents/skills/review-gate/SKILL.md',line=5),
             dict(agent_a,root=69,path='.agents/skills/review-gate/README.md',line=1)]
file_ends=[dict(agent_a,root=63,line=1), dict(agent_a,root=64,line=4,body='Another wording.')]
for rows, issues in [
 ([consumer_a, other_line], 2),
 ([consumer_a, same_end], 2),
 (repeated_text, 2),
 (same_claim, 1),
 (fences, 1),
 (file_ends, 2),
 (agents, 2),
 (harnesses, 1),
 (command_harnesses, 1),
 (skill_files, 2),
 ([base_side, dict(base_side,body='Another wording.')], 2),
 ([dict(consumer_a,line=None,start_line=None), dict(consumer_b,line=None,start_line=None)], 2),
 ([consumer_a, consumer_b], 1),
]:
 reset(); assert len(run(rows=rows)['issues'])==issues, rows
 # Search indexes a new issue late; one run's repeat rides on its own filing.
 assert len({r['issue'] for r in results})==issues
# A closed issue on repeated text answers only its own claim: after a block
# is inserted above the reviewed `fi` or one deleted, another claim on the
# same line is filed anew.
reshapes=(block*4, block*2)
def reshaped(text):
 reset(); closed=run(rows=[dict(first_fi,line=10)])
 closed['issues'][0].update(state='closed',state_reason='completed')
 closed['files'][first_fi['path']]=text; world.write_text(json.dumps(closed))
 later=run(rows=[dict(first_fi,root=36,line=10,body='Another defect.',
                             url='https://github.com/acme/repo/pull/2#discussion_r36')],overrides={'GITHUB_RUN_ID':'43'})
 return len(later['issues']), results[0]['note']
for text in reshapes:
 assert reshaped(text)==(2,'Filed for upstream confirmation'), text
# Search and the issue list both miss this run's own filing; a repeat in the
# run rides on that filing.
def own_filing():
 reset(lag=['search','list']); return len(run(rows=[consumer_a, consumer_b])['issues'])
assert own_filing()==1
# Each thread folded onto this run's own filing leaves its text and evidence.
def folded_evidence():
 reset(); writes=run(rows=[consumer_a, consumer_b])['writes']
 return [w['body'] for w in writes if 'title' not in w]
comments=folded_evidence()
assert len(comments)==1 and consumer_b['url'] in comments[0] and '> '+consumer_b['body'] in comments[0]
# An issue an outside user wrote carrying the marker, open or closed, answers
# nothing and gets no comment: the finding is filed anew.
reset(); spoofed_title=run(rows=[consumer_a])['issues'][0]['title']
def spoofed(state):
 planted=dict(number=1,title=spoofed_title,body='Planted.',state=state,state_reason=None if state=='open' else 'completed',
              user={'login':'someone','type':'User'},html_url='https://github.com/vanillagreencom/kendex/issues/1',
              updated_at=datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
 reset(issues=[planted]); writes=run(rows=[consumer_a])['writes']
 return [w.get('title') for w in writes]==[spoofed_title] and results[0]['issue'].endswith('/issues/2')
for state in ('open','closed'):
 assert spoofed(state), state
# A comment naming lines past the head file is no line it was shown.
reset(); refused=attempt([dict(consumer_a,line=99)],None)
assert refused.returncode!=0 and json.loads(world.read_text())['writes']==[]
# Searches stay under GitHub's query length and cover every marker; an
# incomplete search proves no absence and files nothing.
many=[dict(consumer_a,root=50+n,line=None,start_line=None,body=f'Defect {n}.') for n in range(4)]
# Four findings that miss search read the recent issue list once.
def listed():
 reset(); searched=run(rows=many); return searched, searched.get('lists')
searched, lists = listed()
assert len(searched['issues'])==4 and len({r['issue'] for r in results})==4 and lists==1
assert sorted(t for q in searched['searches'] for t in q)==sorted(i['title'][15:79] for i in searched['issues'])
reset(incomplete=True); refused=attempt([consumer_a],None)
assert refused.returncode!=0 and json.loads(world.read_text())['writes']==[]
# No token, a token denied everywhere and one that can search but not write
# each leave the finding unfiled with a link. A denied evidence comment on an
# open App-filed issue leaves its thread unfiled too, linking that issue. A
# rate limit is no access answer: the run fails and waits for the next one.
denied='gh: Resource not accessible by integration (HTTP 403)'
access='kendex Issues access is unavailable'
access_rows=[
 ({'KENDEX_ISSUES_TOKEN':''}, {}, findings[0], 'issues/new?', 'Issues token unavailable'),
 ({}, {'fail':['all',denied]}, findings[0], 'issues/new?', access),
 ({}, {'fail':['write',denied]}, findings[0], 'issues/new?', access),
 ({}, {'fail':['write',denied],'issues':[issue]}, later_thread, issue['html_url'], access),
]
def unfiled(overrides, extra, row, link, note):
 reset(**extra); result=run(rows=[row],overrides=overrides); text=summary.read_text()
 return (result['writes']==[] and link in text and row['url'] in text
         and results==[{'root':row['root'],'issue':None,'note':note}])
for overrides, extra, row, link, note in access_rows:
 assert unfiled(overrides, extra, row, link, note), extra
rate_limits=[
 'gh: API rate limit exceeded for installation ID 1234. If you reach out to GitHub Support for help, please include the request ID AB12:3C4D. (HTTP 403)',
 'gh: You have exceeded a secondary rate limit. Please wait a few minutes before you try again. (HTTP 403)',
 'gh: Too Many Requests (HTTP 429)',
]
def rate_limited(message):
 reset(fail=['search',message]); result=attempt(findings,None)
 return result.returncode!=0 and 'rate-limited endpoint=search/issues?' in result.stderr \
        and json.loads(world.read_text())['writes']==[]
for message in rate_limits:
 assert rate_limited(message), message
# Permission recovery runs the same candidates even after earlier policy replies.
reset(); run(overrides={'KENDEX_ISSUES_TOKEN':''}); assert len(run()['issues'])==1

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
 ('outside', dict(findings[0],path='src/private.py'), {}, unclaimed),
 ('inventory', dict(findings[0],path='.kendex-generated.json'), {}, unclaimed),
 ('lock', dict(findings[0],path='.kendex-lock.json'), {}, unclaimed),
 ('agent', dict(findings[0],path='.github/agents/reviewer.agent.md'), {}, unclaimed),
 ('elsewhere', findings[0], {'HISTORICAL_LOCK':str(root/'foreign-lock.json')}, elsewhere),
]
def not_filed(row, overrides, note):
 reset(); world=run(rows=[row],overrides=overrides); text=summary.read_text()
 return (world['writes']==[] and results==[{'root':10,'issue':None,'note':note}]
         and row['url'] in text and 'issues/new' not in text)
for name, row, overrides, note in not_filed_rows:
 assert not_filed(row, overrides, note), name
# A late merged-PR report must keep the recorded package route after removal
# or replacement through the consumer's supported package commands.
for drift in ('removed', 'replaced'):
 current=json.loads((root/'historical-lock.json').read_text())
 if drift=='removed': current['entries']={}
 else: current['entries']['skill:review-gate:codex']['sourceRepo']='another/catalog'
 (root/'.kendex-lock.json').write_text(json.dumps(current))
 reset(); assert len(run()['issues'])==1, drift
 assert len(run()['issues'])==1, drift

PY
then ok 'reporter token isolation, render binding, labels, evidence, duplicate handling and permission fallback'; else bad 'reporter behavior'; fi
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
