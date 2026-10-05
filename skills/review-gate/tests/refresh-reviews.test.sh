#!/usr/bin/env bash
# Run the shipped writer against a durable GitHub fixture and a real git
# checkout holding each pull request's commits. The second run sees the first
# run's replies; a resolve failure also keeps its prior reply.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)" || { echo "refresh-reviews: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "refresh-reviews: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "refresh-reviews: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
TMP="$TMP_ROOT"
. "$TEST_DIR/lib/sandbox.sh"
BIN="$TMP/bin"
mkdir -p "$BIN" "$TMP/home" "$TMP/skills/harness-ci/scripts" "$TMP/skills/review-gate"
cp "$TEST_DIR/lib/refresh-gh.py" "$BIN/gh"
chmod +x "$BIN/gh"
# Every copy of the writer sits beside this classifier, as the package does.
SCRIPTS="$TMP/skills/review-gate/scripts"
cp -R "$SKILL_DIR/scripts" "$SCRIPTS"
# The classifier and the reporter are dependencies with their own suites.
# This suite proves the writer consumes the classifier's exact answer and
# answers each finding by the issue the reporter names.
cat >"$TMP/skills/harness-ci/scripts/change-class" <<'CLASSIFIER'
#!/usr/bin/env bash
set -euo pipefail
exec python3 "$GH_MOCK" classify "$@"
CLASSIFIER
chmod +x "$TMP/skills/harness-ci/scripts/change-class"
cat >"$SCRIPTS/refresh-report.py" <<'REPORT'
import json, os, sys
from pathlib import Path
assert os.environ['KENDEX_ISSUES_TOKEN']=='upstream-fixture-token'
p=Path(os.environ['GH_FIXTURE']); w=json.loads(p.read_text())
rows=json.load(sys.stdin)
w.setdefault('reports', []).extend(rows)
p.write_text(json.dumps(w))
unfiled=w.get('unfiled', [])
unclaimed=w.get('unclaimed', [])
# report={pr, mode} makes this pull request's reporter fail or misreport.
fault=w.get('report', {})
mode=fault.get('mode') if str(fault.get('pr'))==sys.argv[2] else None
if mode=='error': sys.exit(1)
out=[{'root': r['root'], 'note': ('No single kendex package claims this path' if r['root'] in unclaimed
                               else 'Issues token unavailable' if r['root'] in unfiled else f"Note {r['root']}"),
      'issue': None if r['root'] in unfiled + unclaimed else f"https://github.com/vanillagreencom/kendex/issues/{r['root']}"}
     for r in rows]
if mode=='missing-root': out=out[1:]
if mode=='bad-issue': out=[dict(r, issue=5) for r in out]
json.dump(out, sys.stdout)
REPORT

# The consumer checkout: one base commit and one head commit per pull request.
REPO="$TMP/repo"
git init -q "$REPO"
git -C "$REPO" config gc.auto 0
git -C "$REPO" config maintenance.auto false
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"
HEADS=""
for number in 1 2 3 4; do
  git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "head $number"
  HEADS="$HEADS $(git -C "$REPO" rev-parse HEAD)"
done

FIXTURE="$TMP/world.json"
BASE="$TMP/base.json"
# shellcheck disable=SC2086 # one argument per head sha
python3 - "$BASE" "$BASE_SHA" $HEADS <<'PY'
import json, sys
out, base, *heads = sys.argv[1:]
bot={'login':'lanes[bot]','type':'Bot'}
reviewer={'login':'copilot','type':'Bot'}
human={'login':'person','type':'User'}
prs=[]
for number, state, merged, branch in [(1,'open',None,'kendex/refresh'),(2,'closed','now','kendex/refresh'),(3,'closed',None,'kendex/refresh'),(4,'open',None,'feature')]:
    root=number*10
    prs.append({'number':number,'state':state,'merged_at':merged,
        'base':{'sha':base},
        'head':{'ref':branch,'sha':heads[number-1],'repo':{'full_name':'acme/repo'}},'user':bot,
        'threads':[{'id':f'T{number}','root':root,'resolved':False},{'id':f'H{number}','root':root+1,'resolved':False}],
        'comments':[{'id':root,'body':'Rendered source defect.','path':'.agents/skill.sh','html_url':f'https://github.com/acme/repo/pull/{number}#discussion_r{root}','user':reviewer,
                     'line':root+3,'start_line':root+1,'side':'RIGHT','start_side':'RIGHT'},
                    {'id':root+1,'body':'Human request.','path':'.agents/skill.sh','user':human}]})
json.dump({'prs':prs,'writes':[]},open(out,'w'))
PY
DRIVER="$SCRIPTS/refresh-reviews.sh"
run_writer() {
  RC=0
  OUT="$(cd "$REPO" && env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP/home" \
    GH_REPO=acme/repo GH_TOKEN=fixture-token KENDEX_ISSUES_TOKEN=upstream-fixture-token GH_FIXTURE="$FIXTURE" GH_MOCK="$BIN/gh" \
    EXPECT_REPO="$REPO" bash "$DRIVER" 2>&1)" || RC=$?
}
# A mutant is a copy of the scripts directory beside the same classifier.
mutant() { # NAME NEEDLE REPLACEMENT
  cp -R "$SCRIPTS" "$TMP/skills/review-gate/$1"
  python3 - "$TMP/skills/review-gate/$1/refresh-reviews.sh" "$2" "$3" <<'MUTATE'
from pathlib import Path
import sys
p, needle, replacement = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
s = p.read_text()
assert not p.is_symlink(), p
assert s.count(needle) == 1, needle
changed = s.replace(needle, replacement)
assert changed != s, needle
p.write_text(changed)
MUTATE
  DRIVER="$TMP/skills/review-gate/$1/refresh-reviews.sh"
}

# Filed and resolved: each automatic thread on the open and the merged rolling
# pull request is filed with the lines its comment names, answered with a
# reply naming its issue and the reporter's note, then resolved. Human threads
# and other pull requests stay untouched.
filed_and_resolved() {
  [ "$RC" -eq 0 ] && jq -e '
    ([.writes[] | [.kind, .pr]] | sort) == [["reply",1],["reply",2],["resolve",1],["resolve",2]]
    and .proofs == [1,2] and ([.reports[].root] == [10,20])
    and all(.prs[0:2][]; .threads[0].resolved and (.threads[1].resolved | not))
    and all(.prs[2:][]; all(.threads[]; .resolved | not))
    and ([.writes[] | select(.kind == "reply") | .body | capture("^Filed upstream as (?<u>[^ ]+)\\. (?<n>Note [0-9]+)\\. ")]
      == [{u:"https://github.com/vanillagreencom/kendex/issues/10",n:"Note 10"},
          {u:"https://github.com/vanillagreencom/kendex/issues/20",n:"Note 20"}])
    and ([.reports[] | [.line, .start_line, .side, .start_side]] == [[13,11,"RIGHT","RIGHT"],[23,21,"RIGHT","RIGHT"]])
    ' "$FIXTURE" >/dev/null
}
# A failed filing: PR 1's finding is not filed, so its thread gets no reply
# and stays open, while PR 2's filed finding is answered and resolved. The
# run then fails, with an annotation naming the open thread.
unfiled_stays_open() {
  [ "$RC" -ne 0 ] && jq -e '
    ([.writes[] | [.kind, .pr]] | sort) == [["reply",2],["resolve",2]]
    and (.prs[0].threads[0].resolved | not) and .prs[1].threads[0].resolved
    ' "$FIXTURE" >/dev/null && grep -q '^upstream-unfiled pr=1 finding=10 ' <<<"$OUT" \
    && grep -q '^::error::upstream-unfiled pr=1 thread=T1 finding=10 note=Issues token unavailable ' <<<"$OUT"
}
# A not-filed finding on a thread already resolved by hand holds nothing:
# no write on PR 1, a plain record, no annotation and a passing run.
unfiled_resolved_clear() {
  [ "$RC" -eq 0 ] && jq -e '([.writes[] | select(.pr == 1)] | length) == 0
    and ([.writes[] | select(.pr == 2) | .kind] | sort) == ["reply","resolve"]' "$FIXTURE" >/dev/null \
    && grep -q '^upstream-unfiled-resolved pr=1 finding=10 ' <<<"$OUT" \
    && ! grep -q '^::error::' <<<"$OUT"
}
# A reporter failure on PR 1 holds that pull request alone: no write on it,
# PR 2 still answered, the named error record and annotation, a failed run.
report_held() { # KEY
  [ "$RC" -ne 0 ] && jq -e '([.writes[] | select(.pr == 1)] | length) == 0
    and ([.writes[] | select(.pr == 2) | .kind] | sort) == ["reply","resolve"]' "$FIXTURE" >/dev/null \
    && grep -q "^refresh-reviews-error=$1 value=1\$" <<<"$OUT" \
    && grep -q "^::error::refresh-reviews-error=$1 pr=1 " <<<"$OUT"
}
# An earlier PR-author reply without the filing prefix is no answer: the
# resolved thread is filed and gets one filing reply, and no resolve.
declined_refiled() {
  [ "$RC" -eq 0 ] && jq -e '[.writes[] | select(.pr == 1) | .kind] == ["reply"]
    and ([.writes[] | select(.pr == 1) | .body | startswith("Filed upstream as ")] == [true])
    and any(.reports[]; .root == 10)' "$FIXTURE" >/dev/null
}
# An unmeasured classifier fallback on PR 1 is no verdict: nothing is filed or
# written there, a warning names the cause, and PR 2 is still answered.
unclassified_held() {
  [ "$RC" -eq 0 ] && jq -e '([.writes[] | select(.pr == 1)] | length) == 0
    and ([.writes[] | select(.pr == 2) | .kind] | sort) == ["reply","resolve"]
    and ([.reports[].root] == [20])' "$FIXTURE" >/dev/null \
    && grep -q '^refresh-reviews=unclassified pr=1 cause=render-proof-failed$' <<<"$OUT" \
    && grep -q '^::warning::refresh-reviews=unclassified pr=1 cause=render-proof-failed ' <<<"$OUT"
}

# A measured non-render PR leaves findings untouched. The warning counts
# unanswered live bot findings, including resolved ones the reporter would
# file, and excludes human requests, outdated findings and durable answers.
not_render_fixture() {
  jq '.prs[0] += {class:"change_class=standard",cause:"excluded-path"}
    | .prs[0].threads += [
        {id:"resolved-live",root:12,resolved:true},
        {id:"outdated",root:13,resolved:false,outdated:true},
        {id:"answered",root:14,resolved:false}]
    | .prs[0].comments[0] as $root
    | .prs[0].comments += [($root | .id=12),($root | .id=13),($root | .id=14),
        {id:500,in_reply_to_id:14,path:$root.path,user:.prs[0].user,
          body:"Filed upstream as https://github.com/vanillagreencom/kendex/issues/7"}]' "$BASE" >"$FIXTURE"
}
not_render_warned() {
  [ "$RC" -eq 0 ] && jq -e '([.writes[] | select(.pr == 1)] | length) == 0
    and ([.writes[] | select(.pr == 2) | .kind] | sort) == ["reply","resolve"]
    and ([.reports[].root] == [20])' "$FIXTURE" >/dev/null \
    && grep -q '^::warning::refresh-reviews=not-render pr=1 cause=excluded-path unanswered=2 ' <<<"$OUT"
}

# A second run over answered threads files, writes and classifies nothing.
idempotent() {
  [ "$RC" -eq 0 ] && jq -e '(.writes | length) == 4 and .proofs == [1,2] and (.reports | length) == 2' "$FIXTURE" >/dev/null
}

# The talk inventory threads arrive unresolved, with automatic authors and
# no replies. The same fixture also tests a live unclaimed inventory path.
skipped_fixture() { # OUTDATED PATH
  jq --argjson outdated "$1" --arg path "$2" '.unclaimed=[10,20]
    | .prs[0:2][] |= (.threads[0].outdated=$outdated | .comments[0].path=$path)' "$BASE" >"$FIXTURE"
}
skipped_and_resolved() {
  [ "$RC" -eq 0 ] && jq -e '
    ([.writes[] | [.kind, .pr]] | sort) == [["reply",1],["reply",2],["resolve",1],["resolve",2]]
    and .proofs == [1,2]
    and ([.reports[]?.root] == [])
    and all(.prs[0:2][]; .threads[0].resolved and (.threads[1].resolved | not))
    and all(.prs[2:][]; all(.threads[]; .resolved | not))
    and ([.writes[] | select(.kind == "reply") | .body | startswith("Not filed upstream: ")] == [true,true])
    and all(.writes[] | select(.kind == "reply"); .body | contains("outdated"))
    ' "$FIXTURE" >/dev/null \
    && [ "$(grep -c '^upstream-skipped ' <<<"$OUT")" -eq 2 ] \
    && grep -q '^upstream-skipped pr=1 finding=10 cause=outdated$' <<<"$OUT" \
    && grep -q '^upstream-skipped pr=2 finding=20 cause=outdated$' <<<"$OUT" \
    && ! grep -q '^::error::' <<<"$OUT"
}
skipped_retry() {
  [ "$RC" -eq 0 ] && jq -e '(.writes | length) == 4 and .proofs == [1,2]
    and ([.reports[]?.root] == [])' "$FIXTURE" >/dev/null \
    && grep -q '^refresh-reviews=already-answered pr=1$' <<<"$OUT" \
    && grep -q '^refresh-reviews=already-answered pr=2$' <<<"$OUT"
}

unclaimed_stays_open() {
  [ "$RC" -eq 1 ] && jq -e '(.writes | length) == 0 and .proofs == [1,2]
    and ([.reports[].root] == [10,20])
    and all(.prs[]; all(.threads[]; .resolved | not))' "$FIXTURE" >/dev/null \
    && grep -q '^upstream-unfiled pr=1 finding=10 ' <<<"$OUT" \
    && grep -q '^upstream-unfiled pr=2 finding=20 ' <<<"$OUT" \
    && grep -q '^::error::upstream-unfiled pr=1 thread=T1 finding=10 ' <<<"$OUT" \
    && grep -q '^::error::upstream-unfiled pr=2 thread=T2 finding=20 ' <<<"$OUT" \
    && ! grep -q '^upstream-skipped ' <<<"$OUT"
}

while IFS= read -r path; do
  skipped_fixture true "$path"
  run_writer
  if skipped_and_resolved; then
    ok "outdated $path: a keyed skip, one not-filed reply and one resolve per automatic thread"
  else bad "outdated $path skip-and-resolve" "$OUT"; fi
  run_writer
  if skipped_retry; then
    ok "outdated $path: the not-filed marker prevents a second reply, report and classification"
  else bad "outdated $path retry" "$OUT"; fi
done <<'SKIPPED'
.kendex-generated.json
.agents/skill.sh
SKIPPED

skipped_fixture false .kendex-generated.json
run_writer
if unclaimed_stays_open; then
  ok 'live unclaimed inventory threads: keyed unfiled records, no reply or resolution, and a failed run'
else bad 'live unclaimed findings must stay open' "$OUT"; fi

cp "$BASE" "$FIXTURE"
run_writer
if filed_and_resolved; then
  ok 'open and merged rolling PRs: each automatic thread is filed, answered with its issue and resolved'
else bad 'filed and resolved' "$OUT"; fi
run_writer
if idempotent; then
  ok 'a durable reply prevents a second filing, reply and classification'
else bad 'idempotent retry' "$OUT"; fi

jq '.unfiled=[10]' "$BASE" >"$FIXTURE"
run_writer
if unfiled_stays_open; then
  ok 'a finding whose filing fails gets no reply and its thread stays open'
else bad 'failed filing leaves the thread open' "$OUT"; fi
jq 'del(.unfiled)' "$FIXTURE" >"$TMP/new"
mv "$TMP/new" "$FIXTURE"
run_writer
if [ "$RC" -eq 0 ] && jq -e '([.writes[] | select(.pr == 1) | .kind] | sort) == ["reply","resolve"]
    and ([.writes[] | select(.pr == 2)] | length) == 2 and .prs[0].threads[0].resolved' "$FIXTURE" >/dev/null; then
  ok 'a later successful filing answers and resolves the open thread once'
else bad 'retry after a failed filing' "$OUT"; fi
jq '.unfiled=[10] | .prs[0].threads[0].resolved=true' "$BASE" >"$FIXTURE"
run_writer
if unfiled_resolved_clear; then
  ok 'a not-filed finding on a thread resolved by hand neither annotates nor fails the run'
else bad 'a resolved not-filed thread must not hold the run' "$OUT"; fi

# A late thread on a merged PR is filed alone; the answered one stays quiet.
cp "$BASE" "$FIXTURE"
run_writer
jq '.prs[1].threads += [{id:"L2",root:25,resolved:false}]
  | .prs[1].comments += [{id:25,body:"Late defect.",path:".agents/late.sh",user:{login:"copilot",type:"Bot"}}]' "$FIXTURE" >"$TMP/new"
mv "$TMP/new" "$FIXTURE"
run_writer
if [ "$RC" -eq 0 ] && jq -e '(.writes | length) == 6 and ([.writes[-2:][] | [.kind, .pr]] == [["reply",2],["resolve",2]])
    and .reports[-1].root == 25 and (.reports | length) == 3' "$FIXTURE" >/dev/null; then
  ok 'a late merged finding is filed and answered alone'
else bad 'late merged finding' "$OUT"; fi

# Fetched documents past both argv limits: Linux caps one argument at 128 KiB
# (MAX_ARG_STRLEN) and macOS a whole command at 1 MiB (kern.argmax). PR 1's
# threads, review comments and findings each exceed 256 KiB, through long
# human thread ids and one long automatic body, and the findings alone, like
# the threads and comments together, exceed 2 MiB through that body.
large_fixture() {
  python3 - "$BASE" "$FIXTURE" <<'PY'
import json, sys
base, out = sys.argv[1:]
world = json.load(open(base))
pr = world['prs'][0]
pr['comments'][0]['body'] = 'Rendered source defect. ' + 'x' * (2 * 1024 * 1024)
for n in range(300):
    pr['threads'].append({'id': f'L{n}' + 'p' * 1000, 'root': 5000 + n, 'resolved': False})
    pr['comments'].append({'id': 5000 + n, 'body': 'Human note.', 'path': 'docs/guide.md',
                           'user': {'login': 'person', 'type': 'User'}})
compact = lambda doc: len(json.dumps(doc, separators=(',', ':')))
threads = [{'id': t['id'], 'isResolved': t['resolved'], 'isOutdated': False, 'root': t['root']} for t in pr['threads']]
sizes = [compact(threads), compact(pr['comments']), compact(pr['comments'][0]['body'])]
if min(sizes) <= 256 * 1024 or min(sizes[2], sizes[0] + sizes[1]) <= 2 * 1024 * 1024:
    sys.exit(f'refresh-reviews: fixture=below-argv-limit value={sizes}')
json.dump(world, open(out, 'w'))
PY
}
large_fixture
run_writer
if filed_and_resolved; then
  ok 'threads, comments and findings past the argv limit are joined, filed, answered and resolved'
else bad 'documents past the argv limit' "$OUT"; fi

while IFS='|' read -r mode key; do
  jq --arg mode "$mode" '.report={pr:1,mode:$mode}' "$BASE" >"$FIXTURE"
  run_writer
  if report_held "$key"; then
    ok "reporter $mode holds its pull request alone and fails the run"
  else bad "reporter $mode must hold its pull request" "$OUT"; fi
done <<'REPORTS'
error|report
missing-root|report-shape
bad-issue|report-shape
REPORTS

declined_fixture() {
  jq '.prs[0].threads[0].resolved=true
    | .prs[0].comments += [{id:500,in_reply_to_id:10,path:".agents/skill.sh",user:.prs[0].user,
        body:"Declined: render class; the fix belongs in the kendex source catalog."}]' "$BASE" >"$FIXTURE"
}
declined_fixture
run_writer
if declined_refiled; then
  ok 'a resolved thread with an earlier Declined reply is filed and answered once'
else bad 'a Declined reply must not count as an answer' "$OUT"; fi

jq '.prs[0] += {class:"change_class=standard",measured:false,cause:"render-proof-failed"}' "$BASE" >"$FIXTURE"
run_writer
if unclassified_held; then
  ok 'an unmeasured classifier fallback is reported as unclassified and writes nothing'
else bad 'unmeasured classifier fallback' "$OUT"; fi

not_render_fixture
run_writer
if not_render_warned; then
  ok 'a measured non-render PR warns with its cause and unanswered live bot count'
else bad 'measured non-render warning' "$OUT"; fi

while IFS= read -r mode; do
  jq --arg mode "$mode" '.prs[0] += {class:"change_class=standard",cause:"excluded-path"}
    | if $mode == "outdated" then .prs[0].threads[0].outdated=true
      else .prs[0].comments += [{id:500,in_reply_to_id:10,path:".agents/skill.sh",user:.prs[0].user,
        body:"Filed upstream as https://github.com/vanillagreencom/kendex/issues/7"}] end' "$BASE" >"$FIXTURE"
  run_writer
  if [ "$RC" -eq 0 ] && grep -q '^refresh-reviews=not-render pr=1 ' <<<"$OUT" \
      && ! grep -q '^::warning::refresh-reviews=not-render pr=1 ' <<<"$OUT"; then
    ok "a non-render PR with only $mode bot findings has no unanswered-live warning"
  else bad "non-render $mode warning" "$OUT"; fi
done <<'NO_LIVE'
outdated
answered
NO_LIVE

jq '.failure={kind:"resolve",mode:"error"}' "$BASE" >"$FIXTURE"
run_writer
if [ "$RC" -ne 0 ] && [ "$(jq '.writes | length' "$FIXTURE")" = 1 ]; then
  ok 'a failed resolution keeps the posted reply as a retry record'
else bad 'interrupted resolution fails closed' "$OUT"; fi
jq 'del(.failure)' "$FIXTURE" >"$TMP/new"
mv "$TMP/new" "$FIXTURE"
run_writer
if [ "$RC" -eq 0 ] && jq -e '[.writes[] | select(.kind=="reply" and .pr==1)] | length==1' "$FIXTURE" >/dev/null; then
  ok 'retry resolves an already answered thread without another reply'
else bad 'interrupted retry' "$OUT"; fi

while IFS='|' read -r kind mode; do
  jq --arg kind "$kind" --arg mode "$mode" '.failure={kind:$kind,mode:$mode}' "$BASE" >"$FIXTURE"
  run_writer
  if [ "$RC" -ne 0 ] && [ "$(jq '.writes | length' "$FIXTURE")" = 0 ]; then
    ok "$kind $mode stops before policy writes"
  else bad "$kind $mode must fail closed" "$OUT"; fi
done <<'ROWS'
pulls|error
pulls|empty
pulls|object
review-comments|error
review-comments|object
threads|error
threads|empty
threads|object
threads|unfinished
threads|missing-outdated
pull|error
pull|empty
pull|object
pull|moved
ROWS
# The join's own refusals: a thread root absent from the REST read is a
# disagreement, and any other jq failure names jq. A string user on a
# PR-author-shaped reply makes the answered test error at .user.login.
join_fixture() { # MODE
  case "$1" in
    missing-root) jq '.prs[0].threads[0].root=99' "$BASE" >"$FIXTURE" ;;
    jq-error) jq '.prs[0].comments += [{id:500,in_reply_to_id:10,path:".agents/skill.sh",user:"lanes[bot]",body:"x"}]' "$BASE" >"$FIXTURE" ;;
    *) echo "refresh-reviews: join-mode=unknown value=$1" >&2; exit 1 ;;
  esac
}
join_refused() { # KEY
  [ "$RC" -ne 0 ] && [ "$(jq '.writes | length' "$FIXTURE")" = 0 ] \
    && grep -q "^refresh-reviews-error=$1 value=1\$" <<<"$OUT" \
    && [ "$(grep -c '^refresh-reviews-error=' <<<"$OUT")" -eq 1 ]
}
while IFS='|' read -r mode key; do
  join_fixture "$mode"
  run_writer
  if join_refused "$key"; then
    ok "join $mode stops before policy writes with refresh-reviews-error=$key"
  else bad "join $mode must report $key" "$OUT"; fi
done <<'JOINS'
missing-root|thread-actions
jq-error|actions-jq
JOINS

# A head this checkout lacks is fetched; a failed fetch writes nothing.
jq --arg sha "$(printf 'd%.0s' $(seq 40))" '.prs[0].head.sha=$sha' "$BASE" >"$FIXTURE"
run_writer
if [ "$RC" -ne 0 ] && [ "$(jq '.writes | length' "$FIXTURE")" = 0 ] && grep -q 'refresh-reviews-error=fetch' <<<"$OUT"; then
  ok 'an unfetchable head stops before policy writes'
else bad 'missing head must fail closed' "$OUT"; fi

# A merged pull request's head survives only under refs/pull/N/head on the
# origin. Each call pushes a fresh head the checkout lacks.
ORIGIN="$TMP/origin.git"
WORK="$TMP/work"
git clone -q --bare "$REPO" "$ORIGIN"
git clone -q "$ORIGIN" "$WORK"
git -C "$REPO" remote add origin "$ORIGIN"
pull_head_fixture() { # LABEL
  git -C "$WORK" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "merged head $1"
  PULL_HEAD="$(git -C "$WORK" rev-parse HEAD)" || return 1
  git -C "$WORK" push -q -f origin HEAD:refs/pull/2/head || return 1
  if git -C "$REPO" cat-file -e "$PULL_HEAD^{commit}" 2>/dev/null; then
    echo "refresh-reviews: fixture=head-present value=$PULL_HEAD" >&2
    return 1
  fi
  jq --arg sha "$PULL_HEAD" '.prs[1].head.sha=$sha' "$BASE" >"$FIXTURE"
}
pull_head_fixture real
run_writer
if filed_and_resolved && git -C "$REPO" cat-file -e "$PULL_HEAD^{commit}"; then
  ok 'a merged head present only under its pull-request ref is fetched, classified, filed and resolved'
else bad 'merged head fetch' "$OUT"; fi

# Identical branch names and findings cannot turn another class into render
# authority. Each row drives both an open and a merged PR.
while IFS='|' read -r code class; do
  jq --arg class "$class" '.prs |= map(.class=$class)' "$BASE" >"$FIXTURE"
  run_writer
  if [ "$RC" -eq "$code" ] && [ "$(jq '.writes | length' "$FIXTURE")" = 0 ] \
      && [ "$(jq '.reports // [] | length' "$FIXTURE")" = 0 ] \
      && { [ "$code" -ne 0 ] || grep -q '^refresh-reviews=not-render pr=1 ' <<<"$OUT"; }; then
    ok "class answer [$class] cannot authorize filing or writes"
  else bad "class answer [$class] must leave findings untouched" "$OUT"; fi
done <<'CLASSES'
0|change_class=standard
0|change_class=small
0|change_class=trivial
0|change_class=render extra
0|
1|error
CLASSES

# Must-fail controls. Each keeps its needle's text, removes one rule, and
# must turn the named case above red.
while IFS='|' read -r name needle replacement; do
  mutant "$name" "$needle" "$replacement"
  cp "$BASE" "$FIXTURE"
  run_writer
  if ! filed_and_resolved; then
    ok "must-fail control: $name fails the filed-and-resolved case"
  else bad "$name control did not detect the planted defect" "$OUT"; fi
done <<'FILED'
filed-mutant|reply="$REPLY_PREFIX$issue. $note$REPLY_TAIL"|reply="$REPLY_PREFIX${issue:+x}. $note$REPLY_TAIL" # $issue
note-mutant|reply="$REPLY_PREFIX$issue. $note$REPLY_TAIL"|reply="$REPLY_PREFIX$issue$REPLY_TAIL" # $note
lines-mutant|url: $root.html_url, line: $root.line, start_line: $root.start_line,|url: $root.html_url, line: null, start_line: $root.start_line,
FILED
mutant unfiled-mutant 'if [ -z "$issue" ]; then' 'if false; then # [ -z "$issue" ]'
jq '.unfiled=[10]' "$BASE" >"$FIXTURE"
run_writer
if ! unfiled_stays_open; then
  ok 'must-fail control: answering an unfiled finding fails the failed-filing case'
else bad 'failed-filing control did not detect the planted defect' "$OUT"; fi
mutant answered-mutant '.user.login == $author and (.body | startswith($prefix) or startswith($not_filed)))' \
  '.user.login == $author and (.body | startswith($prefix) or startswith($not_filed)) and false)'
cp "$BASE" "$FIXTURE"
run_writer
filed_and_resolved || bad 'control fixture reaches the guard' "$OUT"
run_writer
if ! idempotent; then
  ok 'must-fail control: a reply no longer read as an answer fails the idempotence case'
else bad 'answered control did not detect the planted defect' "$OUT"; fi
mutant class-mutant 'if [ "$class" != change_class=render ]; then' 'if false; then # class'
jq '.prs |= map(.class="change_class=standard")' "$BASE" >"$FIXTURE"
run_writer
if [ "$RC" -eq 0 ] && [ "$(jq '.writes | length' "$FIXTURE")" != 0 ]; then
  ok 'must-fail control: removed class guard permits writes for reviewed source changes'
else bad 'class control did not detect the planted defect' "$OUT"; fi
mutant token-mutant 'export -n KENDEX_ISSUES_TOKEN' ': # export'
cp "$BASE" "$FIXTURE"
run_writer
if [ "$RC" -ne 0 ] && [ "$(jq '.writes | length' "$FIXTURE")" = 0 ] && \
    grep -q 'refresh-reviews-error=class-proof' <<<"$OUT"; then
  ok 'must-fail control: exporting the upstream credential fails the classifier boundary'
else bad 'upstream credential control missed the leak' "$OUT"; fi
mutant prefix-mutant '(.body | startswith($prefix) or startswith($not_filed))' \
  '(.body | startswith($prefix) or startswith($not_filed) or true)'
declined_fixture
run_writer
if ! declined_refiled; then
  ok 'must-fail control: any PR-author reply read as an answer fails the Declined-reply case'
else bad 'prefix control did not detect the planted defect' "$OUT"; fi
mutant refspec-mutant 'refs/pull/$PR_NUMBER/head' 'refs/heads/kendex/refresh'
pull_head_fixture control
run_writer
if ! filed_and_resolved; then
  ok 'must-fail control: fetching the branch name instead of the pull-request ref fails the merged-head case'
else bad 'refspec control did not detect the planted defect' "$OUT"; fi
mutant measured-mutant "if [[ \" \$class_line \" == *' measured=true '* ]]; then" \
  "if true || [[ \" \$class_line \" == *' measured=true '* ]]; then"
jq '.prs[0] += {class:"change_class=standard",measured:false,cause:"render-proof-failed"}' "$BASE" >"$FIXTURE"
run_writer
if ! unclassified_held; then
  ok 'must-fail control: reading a fallback as a verdict fails the unclassified case'
else bad 'measured control did not detect the planted defect' "$OUT"; fi

mutant warning-mutant "printf '::warning::refresh-reviews=not-render" \
  ": '::warning::refresh-reviews=not-render"
not_render_fixture
run_writer
if ! not_render_warned; then
  ok 'must-fail control: a muted warning fails the measured non-render case'
else bad 'warning control did not detect the planted defect' "$OUT"; fi
mutant count-mutant 'select((.answered | not) and (.outdated | not))' \
  'select(true or ((.answered | not) and (.outdated | not)))'
not_render_fixture
run_writer
if ! not_render_warned; then
  ok 'must-fail control: counting outdated and answered findings fails the non-render case'
else bad 'count control did not detect the planted defect' "$OUT"; fi

# Each reporter-hold rule has its own control: the reporter exit guard, each
# clause of the output-shape guard, and the per-PR containment.
report_control() { # NAME NEEDLE REPLACEMENT MODE KEY
  mutant "$1" "$2" "$3"
  jq --arg mode "$4" '.report={pr:1,mode:$mode}' "$BASE" >"$FIXTURE"
  run_writer
  if ! report_held "$5"; then
    ok "must-fail control: $1 fails the reporter $4 case"
  else bad "$1 control did not detect the planted defect" "$OUT"; fi
}
report_control report-mutant 'hold report "$PR_NUMBER"' ': hold report "$PR_NUMBER"' error report
report_control shape-root-mutant 'and ([.[].root] | sort) == ([$findings[].root] | sort)' \
  'and (true or ([.[].root] | sort) == ([$findings[].root] | sort))' missing-root report-shape
report_control shape-issue-mutant '(.issue == null or (.issue | type) == "string")' \
  '(true or .issue == null or (.issue | type) == "string")' bad-issue report-shape
report_control containment-mutant "printf '::error::refresh-reviews-error=%s pr=%s %s\\n' \"\$1\" \"\$2\" \"\$3\"" \
  "printf '::error::refresh-reviews-error=%s pr=%s %s\\n' \"\$1\" \"\$2\" \"\$3\"; exit 1" error report
mutant exit-mutant '[ "$held" -eq 0 ] || exit 1' '[ "$held" -eq 0 ] || exit 0'
jq '.unfiled=[10]' "$BASE" >"$FIXTURE"
run_writer
if ! unfiled_stays_open; then
  ok 'must-fail control: a zero exit after an unfiled thread fails the failed-filing case'
else bad 'end-of-run exit control did not detect the planted defect' "$OUT"; fi
mutant resolved-mutant 'if [ "$resolved" = true ]; then' 'if false; then # resolved'
jq '.unfiled=[10] | .prs[0].threads[0].resolved=true' "$BASE" >"$FIXTURE"
run_writer
if ! unfiled_resolved_clear; then
  ok 'must-fail control: holding on a resolved thread fails the resolved not-filed case'
else bad 'resolved-thread control did not detect the planted defect' "$OUT"; fi
mutant outdated-mutant 'if [ "$outdated" = true ]; then' 'if false && [ "$outdated" = true ]; then'
skipped_fixture true .kendex-generated.json
run_writer
if ! skipped_and_resolved; then
  ok 'must-fail control: disabling outdated resolution fails its inventory-thread case'
else bad 'outdated control did not detect the planted defect' "$OUT"; fi
mutant unclaimed-mutant 'if [ -z "$issue" ]; then' 'if false; then # [ -z "$issue" ]'
skipped_fixture false .kendex-generated.json
run_writer
if ! unclaimed_stays_open; then
  ok 'must-fail control: replying to and resolving a live unclaimed thread fails its inventory-thread case'
else bad 'unclaimed control did not detect the planted defect' "$OUT"; fi
mutant not-filed-marker-mutant 'startswith($not_filed)' '(startswith($not_filed) and false)'
skipped_fixture true .kendex-generated.json
run_writer
skipped_and_resolved || bad 'not-filed control fixture reaches the guard' "$OUT"
run_writer
if ! skipped_retry; then
  ok 'must-fail control: ignoring the not-filed marker fails the skip retry case'
else bad 'not-filed marker control did not detect the planted defect' "$OUT"; fi
mutant outdated-shape-mutant 'and (.isOutdated | type) == "boolean"' \
  'and (true or (.isOutdated | type) == "boolean")'
jq '.failure={kind:"threads",mode:"missing-outdated"}' "$BASE" >"$FIXTURE"
run_writer
if [ "$RC" -eq 0 ] && jq -e '(.writes | length) == 4' "$FIXTURE" >/dev/null; then
  ok 'must-fail control: accepting missing thread state permits writes from an incomplete read'
else bad 'outdated shape control did not detect the planted defect' "$OUT"; fi
# Each fetched document handed back to argv fails the argv-limit case, under
# the key of the jq call it breaks and with that failure's own text.
while IFS='|' read -r name needle replacement key text; do
  mutant "$name" "$needle" "$replacement"
  large_fixture
  run_writer
  if ! filed_and_resolved && grep -q "^refresh-reviews-error=$key value=1\$" <<<"$OUT" \
      && [ "$(grep -c '^refresh-reviews-error=' <<<"$OUT")" -eq 1 ] && grep -qF -- "$text" <<<"$OUT"; then
    ok "must-fail control: $name fails the argv-limit case"
  else bad "$name control did not detect the planted defect" "$OUT"; fi
done <<'ARGV'
actions-argv-mutant|actions="$(jq -nc --arg prefix|actions="$(jq -nc --argjson threads "$threads" --argjson comments "$review_comments" --arg prefix|actions-jq|Argument list too long
findings-argv-mutant|jq -en 'input as $findings|jq -en --argjson findings "$findings" 'input as $findings|report-shape|::error::refresh-reviews-error=report-shape pr=1
ARGV
# Each join refusal reported under the other's key fails its join case.
while IFS='|' read -r name needle replacement mode key; do
  mutant "$name" "$needle" "$replacement"
  join_fixture "$mode"
  run_writer
  if ! join_refused "$key"; then
    ok "must-fail control: $name fails the join $mode case"
  else bad "$name control did not detect the planted defect" "$OUT"; fi
done <<'JOINS'
missing-root-mutant|"$ROOT_MISSING_EXIT") fail thread-actions|"$ROOT_MISSING_EXIT") fail actions-jq|missing-root|thread-actions
jq-error-mutant|*) fail actions-jq|*) fail thread-actions|jq-error|actions-jq
JOINS
printf 'refresh-reviews: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
