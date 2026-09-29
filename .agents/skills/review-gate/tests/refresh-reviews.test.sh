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
json.dump([{'root': r['root'], 'note': 'Issues token unavailable' if r['root'] in unfiled else 'Filed',
            'issue': None if r['root'] in unfiled else f"https://github.com/vanillagreencom/kendex/issues/{r['root']}"}
           for r in rows], sys.stdout)
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
        'comments':[{'id':root,'body':'Rendered source defect.','path':'.agents/skill.sh','html_url':f'https://github.com/acme/repo/pull/{number}#discussion_r{root}','user':reviewer},
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
assert s.count(needle) == 1, needle
p.write_text(s.replace(needle, replacement))
MUTATE
  DRIVER="$TMP/skills/review-gate/$1/refresh-reviews.sh"
}

# Filed and resolved: each automatic thread on the open and the merged rolling
# pull request is filed, answered with a reply naming its issue, then resolved.
# Human threads and other pull requests stay untouched.
filed_and_resolved() {
  [ "$RC" -eq 0 ] && jq -e '
    ([.writes[] | [.kind, .pr]] | sort) == [["reply",1],["reply",2],["resolve",1],["resolve",2]]
    and .proofs == [1,2] and ([.reports[].root] == [10,20])
    and all(.prs[0:2][]; .threads[0].resolved and (.threads[1].resolved | not))
    and all(.prs[2:][]; all(.threads[]; .resolved | not))
    and ([.writes[] | select(.kind == "reply") | .body | capture("^Filed upstream as (?<u>[^ ]+)\\. ").u]
      == ["https://github.com/vanillagreencom/kendex/issues/10", "https://github.com/vanillagreencom/kendex/issues/20"])
    ' "$FIXTURE" >/dev/null
}
# A failed filing: PR 1's finding is not filed, so its thread gets no reply
# and stays open, while PR 2's filed finding is answered and resolved.
unfiled_stays_open() {
  [ "$RC" -eq 0 ] && jq -e '
    ([.writes[] | [.kind, .pr]] | sort) == [["reply",2],["resolve",2]]
    and (.prs[0].threads[0].resolved | not) and .prs[1].threads[0].resolved
    ' "$FIXTURE" >/dev/null && grep -q '^upstream-unfiled pr=1 finding=10 ' <<<"$OUT"
}

# A second run over answered threads files, writes and classifies nothing.
idempotent() {
  [ "$RC" -eq 0 ] && jq -e '(.writes | length) == 4 and .proofs == [1,2] and (.reports | length) == 2' "$FIXTURE" >/dev/null
}

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
pull|error
pull|empty
pull|object
pull|moved
ROWS
# A head this checkout lacks is fetched; a failed fetch writes nothing.
jq --arg sha "$(printf 'd%.0s' $(seq 40))" '.prs[0].head.sha=$sha' "$BASE" >"$FIXTURE"
run_writer
if [ "$RC" -ne 0 ] && [ "$(jq '.writes | length' "$FIXTURE")" = 0 ] && grep -q 'refresh-reviews-error=fetch' <<<"$OUT"; then
  ok 'an unfetchable head stops before policy writes'
else bad 'missing head must fail closed' "$OUT"; fi

# Identical branch names and findings cannot turn another class into render
# authority. Each row drives both an open and a merged PR.
while IFS='|' read -r code class; do
  jq --arg class "$class" '.prs |= map(.class=$class)' "$BASE" >"$FIXTURE"
  run_writer
  if [ "$RC" -eq "$code" ] && [ "$(jq '.writes | length' "$FIXTURE")" = 0 ] \
      && [ "$(jq '.reports // [] | length' "$FIXTURE")" = 0 ]; then
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
mutant filed-mutant 'reply="$REPLY_PREFIX$issue$REPLY_TAIL"' 'reply="$REPLY_PREFIX${issue:+x}$REPLY_TAIL" # $issue'
cp "$BASE" "$FIXTURE"
run_writer
if ! filed_and_resolved; then
  ok 'must-fail control: a reply that does not name the filed issue fails the filed-and-resolved case'
else bad 'filed-and-resolved control did not detect the planted defect' "$OUT"; fi
mutant unfiled-mutant 'if [ -z "$issue" ]; then' 'if false; then # [ -z "$issue" ]'
jq '.unfiled=[10]' "$BASE" >"$FIXTURE"
run_writer
if ! unfiled_stays_open; then
  ok 'must-fail control: answering an unfiled finding fails the failed-filing case'
else bad 'failed-filing control did not detect the planted defect' "$OUT"; fi
mutant answered-mutant '.user.login == $author and (.body | startswith($prefix)))' \
  '.user.login == $author and (.body | startswith($prefix)) and false)'
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
printf 'refresh-reviews: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
