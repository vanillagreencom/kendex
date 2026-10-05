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
import re
import subprocess
import sys

skill, root = map(Path, sys.argv[1:3])
real_cli = sys.argv[3]
# Refresh-consumer owns the parse. This mode only formats its three arrays.
reporter = skill / 'scripts/refresh-report.py'
astra = 'SECOND_OPINION_CODEX_CMD = "codex exec -m gpt-6-astra"'
fable = 'ORCH_OVERSEER_PREFERENCE = "claude:Fable:high"'
def settings_run(entries, script=reporter):
 return subprocess.run(['python3', str(script), '--settings'], input=json.dumps(entries),
                       text=True, capture_output=True, env={'PATH':'/usr/bin:/bin'})
def settings(refused=(), deprecated=(), models=(), script=reporter):
 result = settings_run(dict(refused=refused, deprecated=deprecated, deprecated_models=models), script)
 assert result.returncode == 0, result.stderr
 return result.stdout
def model_rows(out):
 return [line for line in out.splitlines() if line.startswith('- <code>')]
for refused, deprecated, present in [
 ([], [], False),
 ([], ['claude:1:high'], True),
 (['claude::high', 'codex:0:low'], ['claude:1:high'], True),
 (['<script>`bad\nentry</script>'], [], True),
]:
 out = settings(refused, deprecated)
 assert ('## Settings' in out) == present
 assert out.count('ORCH_OVERSEER_PREFERENCE:') == len(refused) + len(deprecated)
 assert not present or 'harness:model:effort' in out
 assert '<script>' not in out and '`bad' not in out
 assert '## Deprecated models' not in out
 if not present: assert out == ''
# Each pinned setting is one row, in the order the scan read the file.
for models, rows in [
 ([astra], ['- <code>SECOND_OPINION_CODEX_CMD = &quot;codex exec -m gpt-6-astra&quot;</code>']),
 ([fable], ['- <code>ORCH_OVERSEER_PREFERENCE = &quot;claude:Fable:high&quot;</code>']),
 ([fable, astra, 'X = "fable <b> `x` y"'], ['- <code>ORCH_OVERSEER_PREFERENCE = &quot;claude:Fable:high&quot;</code>',
                                          '- <code>SECOND_OPINION_CODEX_CMD = &quot;codex exec -m gpt-6-astra&quot;</code>',
                                          '- <code>X = &quot;fable &lt;b&gt; &#96;x&#96; y&quot;</code>']),
]:
 out = settings(models=models)
 assert out.count('## Deprecated models\n') == 1 and '## Settings' not in out, out
 assert model_rows(out) == rows, out
both = settings(deprecated=['claude:1:high'], models=[astra])
assert both.index('## Settings') < both.index('## Deprecated models') and len(model_rows(both)) == 1
source = reporter.read_text()
# The settings mode reads the package's retired list beside its scripts
# directory, so a mutant runs from the same layout.
mutants = root / 'package/scripts'
mutants.mkdir(parents=True)
(root / 'package/retired-settings.json').write_bytes((skill / 'retired-settings.json').read_bytes())
# A runner installed before deprecated_models emits two arrays to this reporter.
two_keys = dict(refused=[], deprecated=['claude:1:high'])
legacy = settings_run(two_keys)
assert legacy.returncode == 0, legacy.stderr
assert legacy.stdout.count('ORCH_OVERSEER_PREFERENCE:') == 1 and '## Deprecated models' not in legacy.stdout
needle = 'entries.get("deprecated_models", [])'
assert source.count(needle) == 1
strict = mutants / 'strict-report.py'
strict.write_text(source.replace(needle, 'entries["deprecated_models"]'))
assert 'KeyError' in settings_run(two_keys, strict).stderr
for needle, refused, deprecated, models in [
 ('    if rows:\n', [], ['claude:1:high'], []),
 ('    if models:\n', [], [], [astra]),
]:
 assert source.count(needle) == 1
 mutant = mutants / 'settings-report.py'
 changed = source.replace(needle, '# ' + needle + '    if False:\n')
 assert changed != source
 mutant.write_text(changed)
 assert settings(refused, deprecated, models, mutant) == ''
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
def consumer(committed, notes, script=reporter):
 entries = dict(refused=[], deprecated=[], deprecated_models=[], committed=committed)
 if notes is not None: entries['notes'] = notes
 result = settings_run(entries, script)
 assert result.returncode == 0, result.stderr
 rows = re.findall(r'^- <code>.*?</code>', result.stdout, re.M)
 assert (result.stdout == '') == (rows == []) and result.stdout.count('## Consumer settings\n') == (rows != []), result.stdout
 return rows
for committed, notes, rows in consumer_rows:
 assert consumer(committed, notes) == rows, (committed, notes)
for needle, replacement in [
 ('if key in retired["keys"]', 'if False'),
 ('if value in retired["values"].get(key, [])', 'if False'),
 ('entries.get("notes", [])', '[]'),
]:
 assert source.count(needle) == 1
 mutant = mutants / 'consumer-report.py'
 mutant.write_text(source.replace(needle, replacement))
 assert any(consumer(c, n, mutant) != rows for c, n, rows in consumer_rows), needle
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
  print(json.dumps([".agents/skills/review-gate/SKILL.md",".agents/skills/review-gate/scripts/test.sh",
                    ".claude/skills/review-gate/SKILL.md",".github/agents/reviewer.agent.md",
                    ".kendex-generated.json",".kendex-lock.json"]))
 elif sys.argv[-1].endswith(".kendex-lock.json"): print(Path(os.environ["HISTORICAL_LOCK"]).read_text())
 else: sys.stdout.write(w["files"][sys.argv[-1].split(":",1)[1]])
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
 assert sys.argv[1]=="api" and sys.argv[2].startswith(("repos/vanillagreencom/kendex/issues","search/issues?"))
 if w.get("deny"):
  print("gh: Resource not accessible by integration (HTTP 403)",file=sys.stderr); sys.exit(1)
 if "--input" in sys.argv:
  p=json.load(sys.stdin)
  w["writes"].append(p)
  if sys.argv[2].endswith("/comments"):
   result={"html_url":"https://github.com/vanillagreencom/kendex/issues/1#comment"}
  else:
   number=len(w["issues"])+1
   result=dict(p,number=number,state="open",state_reason=None,
               html_url=f"https://github.com/vanillagreencom/kendex/issues/{number}")
   w["issues"].append(result)
  state.write_text(json.dumps(w)); print(json.dumps(result))
 else:
  # GitHub search: whole-token title matches, closed issues included
  # unless the query narrows to is:open.
  from urllib.parse import parse_qs, urlsplit
  q=parse_qs(urlsplit(sys.argv[2]).query)["q"][0]
  assert q.startswith("repo:vanillagreencom/kendex is:issue ") and " in:title " in q
  terms=q.split(" in:title ",1)[1].split(" OR ")
  w.setdefault("searches",[]).append(terms); state.write_text(json.dumps(w))
  items=[i for i in w["issues"] if any(t in i["title"] for t in terms)
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
(root/'kendex.toml').write_text('schema = 6\n')
(root/'.kendex-lock.json').write_text(json.dumps({'version':11,'entries':{'skill:review-gate:codex':{
 'name':'review-gate','kind':'skill','harness':'codex','source':'kendex',
 'sourceRepo':'vanillagreencom/kendex','sourceHash':'x','enabled':True}}}))
(root/'historical-lock.json').write_bytes((root/'.kendex-lock.json').read_bytes())
findings=[{'root':10,'path':'.agents/skills/review-gate/scripts/test.sh','body':'The shipped command fails.\n$(touch should-not-exist)',
           'url':'https://github.com/acme/repo/pull/1#discussion_r10'}]
# The stdout protocol refresh-reviews reads: one {root, issue, note} per row.
results=[]
# The package's SKILL.md at the source, and as a consumer renders it with a
# project-instructions block that shifts every line.
skill_md=['---','name: review-gate','---','','Run the gate.','Then read the verdict.','']
files={'.agents/skills/review-gate/SKILL.md':'\n'.join(skill_md),
       '.claude/skills/review-gate/SKILL.md':'\n'.join(skill_md[:4]+['## Project Instructions','']+skill_md[4:])}
def reset(**extra):
 world.write_text(json.dumps(dict(issues=[],writes=[],files=files,**extra))); summary.write_text('')
def attempt(driver, rows, overrides):
 return subprocess.run(['python3',str(driver),'a'*40,'1'],input=json.dumps(rows),text=True,
                       capture_output=True,env=dict(env,**(overrides or {})),cwd=root)
def run(driver=skill/'scripts/refresh-report.py', rows=findings, overrides=None):
 result=attempt(driver, rows, overrides)
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
# One package line reviewed in two consumers, at other rendered paths, line
# numbers and wording, is one finding. Once its issue is closed, a later
# refresh files and comments nothing and answers with the closed issue.
consumer_a=dict(findings[0],root=30,path='.agents/skills/review-gate/SKILL.md',body='Step order is wrong.',
                line=6,start_line=5,side='RIGHT',start_side='RIGHT',url='https://github.com/acme/repo/pull/1#discussion_r30')
consumer_b=dict(consumer_a,root=40,path='.claude/skills/review-gate/SKILL.md',body='These two steps run backwards.',
                line=8,start_line=7,url='https://github.com/other/repo/pull/9#discussion_r40')
second_consumer={'GH_REPO':'other/repo','GITHUB_RUN_ID':'43'}
def package_line(driver=skill/'scripts/refresh-report.py'):
 reset(); run(driver,rows=[consumer_a]); folded=run(driver,rows=[consumer_b],overrides=second_consumer)
 if len(folded['issues'])!=1 or results[0]['note']!='Existing open report': return 'consumers'
 folded['issues'][0].update(state='closed',state_reason='not_planned'); world.write_text(json.dumps(folded))
 later=run(driver,rows=[consumer_a],overrides={'GITHUB_RUN_ID':'44'})
 if later['writes']!=folded['writes'] or results!=[{'root':30,'issue':folded['issues'][0]['html_url'],
                                                    'note':'Closed upstream as not planned'}]: return 'closed'
 return 'one'
assert package_line()=='one'
# The fold stops at the line: another line of the same file, a base-side
# comment and a file-level comment are their own findings, and the
# wording identifies the last two.
other_line=dict(consumer_a,line=5,start_line=None)
base_side=dict(consumer_a,side='LEFT')
for rows, issues in [
 ([consumer_a, other_line], 2),
 ([base_side, dict(base_side,body='Another wording.')], 2),
 ([dict(consumer_a,line=None,start_line=None), dict(consumer_b,line=None,start_line=None)], 2),
 ([consumer_a, consumer_b], 1),
]:
 reset(); assert len(run(rows=rows)['issues'])==issues, rows
 # Search indexes a new issue late; one run's repeat rides on its own filing.
 assert len({r['issue'] for r in results})==issues
# A comment naming lines past the head file is no line it was shown.
reset(); refused=attempt(skill/'scripts/refresh-report.py',[dict(consumer_a,line=99)],None)
assert refused.returncode!=0 and json.loads(world.read_text())['writes']==[]
# Searches stay under GitHub's query length and cover every marker; an
# incomplete search proves no absence and files nothing.
many=[dict(consumer_a,root=50+n,line=None,start_line=None,body=f'Defect {n}.') for n in range(4)]
reset(); searched=run(rows=many)
assert len(searched['issues'])==4 and max(map(len,searched['searches']))<=3
assert sorted(t for q in searched['searches'] for t in q)==sorted(i['title'][15:79] for i in searched['issues'])
reset(incomplete=True); refused=attempt(skill/'scripts/refresh-report.py',[consumer_a],None)
assert refused.returncode!=0 and json.loads(world.read_text())['writes']==[]
for overrides, extra in [({'KENDEX_ISSUES_TOKEN':''},{}), ({},{'deny':True})]:
 reset(**extra); result=run(overrides=overrides)
 assert result['writes']==[] and 'issues/new?' in summary.read_text()
 assert results[0]['root']==10 and results[0]['issue'] is None
 assert findings[0]['url'] in summary.read_text()
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
 ('if path in records else set()', 'if False and path in records else set()', findings, 'path'),
 ('elif existing:', 'elif False and existing:', findings, 'dedup'),
 ('[name, str(inner), reviewed(finding)]', '[name, str(inner), reviewed(finding), finding["url"]]', inline_pair, 'instance'),
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
 ('            url = "https://github.com/" + UPSTREAM', '            url = filed = "https://github.com/" + UPSTREAM', {'KENDEX_ISSUES_TOKEN':''}, [{}]),
 ('url = result["html_url"]', 'url = filed = result["html_url"]', {}, [{}, {'GITHUB_RUN_ID':'43'}]),
]:
 assert source.count(needle)==1
 mutant=root/'filed.py'; mutant.write_text(source.replace(needle,replacement))
 reset()
 for extra in runs: run(mutant,overrides=dict(overrides,**extra))
 assert results[0]['issue'] is not None and not results[0]['issue'].endswith('/issues/1')
# Filing a package kendex report routes elsewhere turns its not-filed row red.
# The filing link and the issue need the title only a routed finding has, so
# no mutant can offer either for a finding the route rule turned away.
mutant=root/'label.py'; changed=source
for needle,replacement in [
 ('if "--repo" in args and args[args.index("--repo") + 1] == UPSTREAM and "--label" in args:', 'if True:'),
 ('row["label"] = args[args.index("--label") + 1]', 'row["label"] = "ci-infra"'),
]:
 assert changed.count(needle)==1, needle
 changed=changed.replace(needle,replacement)
mutant.write_text(changed)
for name, row, overrides, note in not_filed_rows:
 assert not_filed(mutant, row, overrides, note) == (name != 'elsewhere'), name
# Each identity and lookup rule: the consumer repository or the wording in
# the identity, an open-only search, a closed issue read as open, and this
# run's own filing forgotten.
for needle,replacement,expect in [
 ('[name, str(inner), reviewed(finding)]', '[repo, name, str(inner), reviewed(finding)]', 'consumers'),
 ('[name, str(inner), reviewed(finding)]', '[name, str(inner), finding["body"]]', 'consumers'),
 ('is:issue in:title', 'is:issue is:open in:title', 'closed'),
 ('if existing and existing["state"] != "open":', 'if False and existing:', 'closed'),
]:
 assert source.count(needle)==1, needle
 mutant=root/'identity.py'; mutant.write_text(source.replace(needle,replacement))
 assert package_line(mutant)==expect, needle
for needle,replacement,rows,issues in [
 ('                    known[marker] = created\n', '                    pass\n', [consumer_a, consumer_b], 2),
 ('if end is None or finding.get("side") != "RIGHT":', 'if end is None:', [base_side, dict(base_side,body='Another wording.')], 1),
]:
 assert source.count(needle)==1, needle
 mutant=root/'lookup.py'; mutant.write_text(source.replace(needle,replacement))
 reset(); assert len(run(mutant,rows=rows)['issues'])==issues, needle
# The line-range refusal and the incomplete-search refusal each let a run
# through when removed, and a wider batch breaks the query bound.
for needle,replacement,rows,extra in [
 ('if not 1 <= start <= end <= len(lines):', 'if False:', [dict(consumer_a,line=99)], {}),
 ('p.get("incomplete_results") is False', 'True', [consumer_a], {'incomplete':True}),
]:
 assert source.count(needle)==1, needle
 mutant=root/'refusal.py'; mutant.write_text(source.replace(needle,replacement))
 reset(**extra); assert attempt(mutant,rows,None).returncode==0, needle
needle='SEARCH_TERMS = 3\n'
assert source.count(needle)==1
mutant=root/'batch.py'; mutant.write_text(source.replace(needle,'SEARCH_TERMS = 4\n'))
reset(); assert max(map(len,run(mutant,rows=many)['searches']))==4
PY
then ok 'reporter token isolation, render binding, labels, evidence, duplicate handling and permission fallback'; else bad 'reporter behavior and controls'; fi
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
