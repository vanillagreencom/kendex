#!/usr/bin/env bash
# Run the shipped writer against a durable GitHub fixture. The second run
# sees the first run's replies; a resolve failure also keeps its prior reply.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT
. "$TEST_DIR/lib/sandbox.sh"
BIN="$TMP/bin"
mkdir -p "$BIN" "$TMP/home"
cp "$TEST_DIR/lib/refresh-gh.py" "$BIN/gh"
chmod +x "$BIN/gh"
cp -R "$SKILL_DIR/scripts" "$TMP/trusted-scripts"
# The predicate is a dependency: its parser and class policy have their own
# suites. This suite proves the writer consumes its exact bound result.
cat >"$TMP/trusted-scripts/review-predicate.sh" <<'PREDICATE'
#!/usr/bin/env bash
set -euo pipefail
exec python3 "$GH_MOCK" predicate
PREDICATE
# Reporting transport has its own process suite; capture the caller's input.
cat >"$TMP/trusted-scripts/refresh-report.py" <<'REPORT'
import json, os
from pathlib import Path
assert os.environ['KENDEX_ISSUES_TOKEN']=='upstream-fixture-token'
p=Path(os.environ['GH_FIXTURE']); w=json.loads(p.read_text())
w.setdefault('reports', []).extend(json.load(__import__('sys').stdin))
p.write_text(json.dumps(w))
REPORT
DRIVER="$TMP/trusted-scripts/refresh-reviews.sh"
FIXTURE="$TMP/world.json"
BASE="$TMP/base.json"
python3 - "$BASE" <<'PY'
import json, sys
bot={'login':'lanes[bot]','type':'Bot'}
reviewer={'login':'copilot','type':'Bot'}
human={'login':'person','type':'User'}
prs=[]
for number, state, merged, branch in [(1,'open',None,'kendex/refresh'),(2,'closed','now','kendex/refresh'),(3,'closed',None,'kendex/refresh'),(4,'open',None,'feature')]:
    root=number*10
    prs.append({'number':number,'state':state,'merged_at':merged,
        'base':{'sha':'c'*40},
        'head':{'ref':branch,'sha':'a'*40,'repo':{'full_name':'acme/repo'}},'user':bot,
        'threads':[{'id':f'T{number}','root':root,'resolved':False},{'id':f'H{number}','root':root+1,'resolved':False}],
        'comments':[{'pull_request_review_id':root+100,'id':root,'body':'Rendered source defect.','path':'.agents/skill.sh','html_url':f'https://github.com/acme/repo/pull/{number}#discussion_r{root}','user':reviewer},
                    {'id':root+1,'body':'Human request.','path':'.agents/skill.sh','user':human}],
        'reviews':[{'id':root+100,'html_url':f'https://github.com/acme/repo/pull/{number}#review', 'user':reviewer,'state':'COMMENTED','commit_id':'b'*40,
                    'body':'### Suppressed comments (2)\n**.agents/with space.sh:1**\nDefect A\n**.agents/next.sh:2**\nDefect B'}],
        'issue_comments':[]})
json.dump({'prs':prs,'writes':[]},open(sys.argv[1],'w'))
PY
run_writer() {
  RC=0
  OUT="$(cd "$TMP" && env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP/home" \
    GH_REPO=acme/repo GH_TOKEN=fixture-token KENDEX_ISSUES_TOKEN=upstream-fixture-token GH_FIXTURE="$FIXTURE" GH_MOCK="$BIN/gh" \
    REVIEW_GATE_SETTINGS_FILE=/dev/null bash "$DRIVER" "$@" 2>&1)" || RC=$?
}

cp "$BASE" "$FIXTURE"
run_writer
if [ "$RC" -eq 0 ] && jq -e '
  ([.writes[].kind] | sort) == (["reply","resolve","disposition","reply","resolve","disposition"] | sort)
  and ([.writes[].pr] | unique) == [1,2]
  and .proofs == [1,2]
  and all(.prs[0:2][]; .threads[0].resolved and (.threads[1].resolved | not))
  and all(.prs[0:2][].issue_comments[];
      .body | startswith("Dispositions at aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n\n"))
  and all(.writes[] | select(.kind == "reply"); .body | startswith("Declined: render class"))
  ' "$FIXTURE" >/dev/null; then
  ok 'open and merged rolling PRs receive policy replies, resolutions and bound dispositions; humans and other PRs remain untouched'
else bad 'complete policy dispositions' "$OUT"; fi
run_writer
if [ "$RC" -eq 0 ] && jq -e '.writes | length == 6' "$FIXTURE" >/dev/null \
    && jq -e '.proofs == [1,2]' "$FIXTURE" >/dev/null; then
  ok 'durable replies and disposition lines prevent duplicate writes'
else bad 'idempotent retry' "$OUT"; fi

run_writer --report-only
if [ "$RC" -eq 0 ] && jq -e '(.reports | length) == 6 and (.writes | length) == 6' "$FIXTURE" >/dev/null; then
  ok 'reporting collects accepted automatic findings after all policy replies exist'
else bad 'reporting must remain independent of durable policy replies' "$OUT"; fi

# A later refresh assigns new inline IDs and moves suppressed locations.
# Candidate claim text stays fixed while evidence keeps those new locations.
cp "$FIXTURE" "$TMP/before-metadata"
jq '.reports=[] | .prs |= map(.comments[0].id += 1000 | .threads[0].root += 1000
  | .comments[0].html_url += "0" | .reviews[0].body |= gsub(":1\\*\\*";":11**") | .reviews[0].body |= gsub(":2\\*\\*";":22**"))' "$FIXTURE" >"$TMP/moved-metadata"
cp "$TMP/moved-metadata" "$FIXTURE"
run_writer --report-only
if [ "$RC" -eq 0 ] && jq -e --slurpfile before "$TMP/before-metadata" '
  ([.reports[] | {path,claim}]) == ([$before[0].reports[] | {path,claim}])
  and any(.reports[]; (.body | contains(":11**")) and (.claim | contains("**.agents/with space.sh**")))
  and (.reports[0].url != $before[0].reports[0].url) and all(.reports[]; has("key") | not)
  ' "$FIXTURE" >/dev/null; then
  ok 'new inline IDs and moved suppressed locations retain claim text and original evidence'
else bad 'stable candidate claim text' "$OUT"; fi
cp -R "$TMP/trusted-scripts" "$TMP/claim-mutant"
python3 - "$TMP/claim-mutant/refresh-reviews.sh" <<'CLAIM_CONTROL'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(); needle='($locations | index($token)) != null'
assert s.count(needle)==1
p.write_text(s.replace(needle,'false and ('+needle+')'))
CLAIM_CONTROL
DRIVER="$TMP/claim-mutant/refresh-reviews.sh"
cp "$TMP/moved-metadata" "$FIXTURE"
run_writer --report-only
if [ "$RC" -eq 0 ] && jq -e '(.reports | length)==6 and any(.reports[]; .claim | contains("**.agents/with space.sh:11**"))' "$FIXTURE" >/dev/null; then
  ok 'control: disabled metadata normalization changes the claim text'
else bad 'claim metadata control' "$OUT"; fi
DRIVER="$TMP/trusted-scripts/refresh-reviews.sh"
cp "$TMP/before-metadata" "$FIXTURE"

# A late review on a merged PR adds one new suppressed entry. Old entries
# remain answered even when the review groups have changed.
jq '.prs[1].reviews += [{user:{login:"copilot",type:"Bot"}, state:"COMMENTED", commit_id:("b"*40), body:"### Previously missed (1)\n`.agents/late.sh:3`\nLate defect"}]' "$FIXTURE" >"$TMP/new"
mv "$TMP/new" "$FIXTURE"
run_writer
if [ "$RC" -eq 0 ] && jq -e '.writes | length == 7 and .[-1].pr == 2 and .[-1].kind == "disposition" and (.[-1].body | contains(".agents/late.sh:3") and (contains(".agents/next.sh:2") | not))' "$FIXTURE" >/dev/null; then
  ok 'late merged findings get only their missing disposition'
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
reviews|error
reviews|empty
review-comments|error
review-comments|object
issue-comments|empty
threads|error
threads|empty
threads|object
threads|unfinished
pull|error
pull|empty
pull|object
pull|moved
ROWS
jq '.prs[0].reviews[0].body="### Suppressed comments (2)\n**.agents/only.sh:1**"' "$BASE" >"$FIXTURE"
run_writer
if [ "$RC" -ne 0 ] && [ "$(jq '.writes | length' "$FIXTURE")" = 0 ]; then
  ok 'unreadable suppressed blocks refuse before thread replies'
else bad 'suppressed count mismatch' "$OUT"; fi

# Identical branch names and findings cannot turn another predicate result
# into render authority. Each row drives both an open and a merged PR.
while IFS='|' read -r code verdict; do
  jq --arg verdict "$verdict" '.prs |= map(.policy=$verdict)' "$BASE" >"$FIXTURE"
  run_writer
  if [ "$RC" -eq "$code" ] && [ "$(jq '.writes | length' "$FIXTURE")" = 0 ]; then
    ok "predicate result $verdict cannot authorize policy writes"
  else bad "class proof $verdict must leave findings untouched" "$OUT"; fi
done <<'POLICIES'
0|verdict=approved detail=change class trivial requires no review evidence or thread wait
0|verdict=approved detail=review gate disabled by settings (REVIEW_GATE_MODE=off)
0|verdict=approved detail=review object on current head
0|verdict=threads-open detail=1 unresolved review thread(s)
0|verdict=approved detail=change class render requires review evidence
1|error
1|
POLICIES

# Control removes the answered guard's behavior but keeps its text. The
# same idempotence assertion above must observe duplicate replies on retry.
cp -R "$TMP/trusted-scripts" "$TMP/mutant"
python3 - "$TMP/mutant/refresh-reviews.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(); needle='if [ "$pending" = false ] && [ "$report_only" = false ]; then'
assert s.count(needle)==1
changed=s.replace(needle,'if false; then # '+needle)
needle='if [ "$answered" = false ]; then'
assert changed.count(needle)==1
changed=changed.replace(needle,'if :; then # '+needle)
assert changed != s
p.write_text(changed)
PY
DRIVER="$TMP/mutant/refresh-reviews.sh"
cp "$BASE" "$FIXTURE"
run_writer
[ "$RC" -eq 0 ] || bad 'control fixture reaches the guard' "$OUT"
run_writer
if [ "$RC" -eq 0 ] && [ "$(jq '.writes | length' "$FIXTURE")" != 6 ]; then
  ok 'must-fail control: removed answered guard makes idempotence assertion fail'
else bad 'must-fail control did not detect the planted defect' "$OUT"; fi
# The class guard is a production rule with its own must-fail control.
cp -R "$TMP/trusted-scripts" "$TMP/class-mutant"
python3 - "$TMP/class-mutant/refresh-reviews.sh" <<'PYCONTROL'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
needle="if [ \"$proof\" != 'verdict=approved detail=change class render requires no review evidence or thread wait' ]; then"
assert s.count(needle)==1
changed=s.replace(needle,'if false; then # '+needle)
assert changed != s
p.write_text(changed)
PYCONTROL
DRIVER="$TMP/class-mutant/refresh-reviews.sh"
jq '.prs |= map(.policy="verdict=approved detail=review object on current head")' "$BASE" >"$FIXTURE"
run_writer
if [ "$RC" -eq 0 ] && [ "$(jq '.writes | length' "$FIXTURE")" != 0 ]; then
  ok 'must-fail control: removed class guard permits writes for reviewed source changes'
else bad 'class control did not detect the planted defect' "$OUT"; fi
# Restoring export must fail at the predicate sentinel before any write.
cp -R "$TMP/trusted-scripts" "$TMP/token-mutant"
python3 - "$TMP/token-mutant/refresh-reviews.sh" <<'TOKEN_CONTROL'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(); needle='export -n KENDEX_ISSUES_TOKEN'
assert s.count(needle)==1
p.write_text(s.replace(needle,': # '+needle))
TOKEN_CONTROL
DRIVER="$TMP/token-mutant/refresh-reviews.sh"
cp "$BASE" "$FIXTURE"
run_writer --report-only
if [ "$RC" -ne 0 ] && [ "$(jq '.writes | length' "$FIXTURE")" = 0 ] && \
    grep -q 'refresh-reviews-error=class-proof' <<<"$OUT"; then
  ok 'must-fail control: exporting the upstream credential fails the predicate boundary'
else bad 'upstream credential control missed the leak' "$OUT"; fi
printf 'refresh-reviews: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
