#!/usr/bin/env bash
# Surface: copilot-wait and its shared Copilot run/timeline reader.
# Inputs: scripts/copilot-wait, scripts/lib/copilot-check-runs.sh,
# scripts/lib/{gh-auth,gh-repo,lane-mail-nap}.sh, scripts/orch-env,
# github/scripts/lib/{gh-auth,gh-repo,repo-probe,repo-paths}.sh.
# The same GitHub stubs drive the wait and the old read-without-wait control.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/virtual-clock.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'copilot_wait: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "copilot_wait: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'copilot_wait: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
mkdir -p "$TMP_ROOT/repo/.agents/skills/orch" "$TMP_ROOT/bin"
cp -R "$REPO_ROOT/skills/orch/scripts" "$TMP_ROOT/repo/.agents/skills/orch/scripts"
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/repo/.agents/skills/github"
git -C "$TMP_ROOT/repo" init -q
git -C "$TMP_ROOT/repo" config gc.auto 0
git -C "$TMP_ROOT/repo" config maintenance.auto false
virtual_clock_install "$TMP_ROOT/bin" "$TMP_ROOT/clock"
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
cat > "$TMP_ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'auth status'*) exit 0 ;;
  'repo view'*) echo o/r ;;
  'pr view 42 --repo o/r --json headRefOid --jq .headRefOid')
    head="$HEAD_A"
    if [[ "$MODE" == moved && "$(cat "$READS")" -ge 1 ]]; then head="$HEAD_B"; fi
    [[ "$MODE" != invalid-head ]] || head=null
    echo "$head"
    ;;
  'api repos/o/r/commits/'*'/check-runs?filter=all&per_page=100 --paginate --slurp')
    count="$(cat "$READS")"; count=$((count + 1)); echo "$count" > "$READS"
    status=completed
    case "$MODE" in
      finishing|moved|mail) [[ "$count" -gt 1 ]] || status=in_progress ;;
      active) status=in_progress ;;
      review-landed) status=in_progress ;;
      queued) status=queued ;;
      fail) echo 'HTTP 403: Forbidden' >&2; exit 1 ;;
      timeline*) echo '[{"check_runs":[]}]'; exit 0 ;;
    esac
    started='"2026-10-09T07:24:02Z"'
    [[ "$MODE" != queued ]] || started=null
    printf '[{"check_runs":[{"name":"CI","status":"in_progress"}]},{"check_runs":[{"id":72,"name":"copilot-pull-request-reviewer","status":"%s","started_at":%s}]}]\n' "$status" "$started"
    ;;
  'api repos/o/r/issues/42/timeline?per_page=100 --paginate --slurp')
    case "$MODE" in
      timeline-fail) echo 'HTTP 403: Forbidden' >&2; exit 1 ;;
      timeline-invalid) echo '[{}]'; exit 0 ;;
      timeline-request|timeline-work|timeline-reviewed|timeline-old-review|timeline-human-review)
        event=review_requested
        [[ "$MODE" != timeline-work ]] || event=copilot_work_started
        jq -nc --arg event "$event" --arg head "$HEAD_A" --arg mode "$MODE" '
          [[{event:"reviewed",user:{login:"Copilot"},commit_id:"old",id:40},
            {event:$event,id:73,created_at:"2026-10-09T07:23:47Z",
             requested_reviewer:{login:"Copilot",type:"Bot"},actor:{login:"bmethod",type:"User"}}],
           if $mode == "timeline-reviewed" then [{event:"reviewed",user:{login:"Copilot"},commit_id:$head,id:41}]
           elif $mode == "timeline-old-review" then [{event:"reviewed",user:{login:"Copilot"},commit_id:"old",id:41}]
           elif $mode == "timeline-human-review" then [{event:"reviewed",user:{login:"colleague"},commit_id:$head,id:41}]
           else [] end]'
        ;;
      *) echo '[[]]' ;;
    esac
    ;;
  'api repos/o/r/pulls/42/reviews?per_page=100 --paginate --slurp')
    if [[ "$(cat "$READS")" -le 1 ]]; then echo '[[]]'; exit 0; fi
    jq -nc --arg head "$HEAD_A" --arg mode "$MODE" '[[{id:81,user:{login:"Copilot"},commit_id:$head,state:"APPROVED",
      submitted_at: (if $mode == "review-landed" then "2026-10-09T07:27:06Z" else "2026-10-09T06:40:13Z" end)}]]'
    ;;
  'api graphql'*)
    jq -nc --argjson read "$(cat "$READS")" '
      {data:{repository:{pullRequest:{number:42,title:"Example",headRefName:"topic",
        files:{nodes:[],pageInfo:{hasNextPage:false,endCursor:null}},
        comments:{nodes:[],pageInfo:{hasNextPage:false,endCursor:null}},
        reviewThreads:{pageInfo:{hasNextPage:false,endCursor:null},nodes:
          (if $read > 1 then [{id:"PRRT_81",isResolved:false,isOutdated:false,path:"sample.sh",line:1,
            comments:{nodes:[{author:{login:"Copilot"},body:"Finding",url:"https://example.test/pull/42#discussion_r81"}],
              pageInfo:{hasNextPage:false,endCursor:null}}}] else [] end)}}}}}'
    ;;
  *) printf 'stub: unexpected=%s\n' "$*" >&2; exit 9 ;;
esac
STUB
chmod +x "$TMP_ROOT/bin/gh"
SCRIPT="$TMP_ROOT/repo/.agents/skills/orch/scripts/copilot-wait"
run_wait() { # MODE [BOUND] [ITEM]
  echo 0 > "$TMP_ROOT/reads"
  local args=() mail=""
  if [[ -n "${3:-}" ]]; then
    args=(--item "$3")
    mail="$TMP_ROOT/repo/tmp/lane-mail/$3/to-lane.jsonl"
    rm -f -- "$mail"
  fi
  RC=0
  OUT=$(cd "$TMP_ROOT/repo" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$HOME" \
    MODE="$1" HEAD_A="$HEAD_A" HEAD_B="$HEAD_B" READS="$TMP_ROOT/reads" \
    STUB_CLOCK="$STUB_CLOCK" STUB_REAL_DATE="$STUB_REAL_DATE" STUB_REAL_SLEEP="$STUB_REAL_SLEEP" \
    STUB_MAIL_TO="$mail" ORCH_COPILOT_HOLD_SECS="${2:-20}" \
    "$SCRIPT" 42 ${args[@]+"${args[@]}"} 2>"$TMP_ROOT/err") || RC=$?
}
field() { sed -n "s/.* $1=\([^ ]*\).*/\1/p" <<<"$OUT"; }
rows=(
  'finishing|20|0|settled|81|72|10'
  'review-landed|20|0|settled|81|72|10'
  'completed|20|0|none|none|none|0'
  'active|3|1|expired|none|72|3'
  'queued|3|1|expired|none|72|3'
  'timeline-request|3|1|expired|none|73|3'
  'timeline-work|3|1|expired|none|73|3'
  'timeline-reviewed|3|0|none|none|none|0'
  'timeline-old-review|3|1|expired|none|73|3'
  'timeline-human-review|3|1|expired|none|73|3'
  'moved|20|0|none|none|none|10'
)
for row in "${rows[@]}"; do
  IFS='|' read -r mode bound rc state review run waited <<<"$row"
  run_wait "$mode" "$bound"
  assert_eq "$RC $(field state) $(field review) $(field run) $(field waited)" \
    "$rc $state $review $run $waited" "$mode: current-head result" "$TMP_ROOT/err"
done
for mode in fail timeline-fail timeline-invalid invalid-head; do
  run_wait "$mode"
  assert_eq "$RC" 1 "$mode: failed reads refuse" "$TMP_ROOT/err"
  assert_eq "$OUT" '' "$mode: failed reads print no passing result"
  assert_contains "$(cat "$TMP_ROOT/err")" 'copilot-wait: read-failed operation=' "$mode: keyed refusal"
done
run_wait mail 20 KEN-9
assert_eq "$RC" 5 'lane mail interrupts without a verdict' "$TMP_ROOT/err"
assert_eq "$OUT" 'copilot-wait: mail=1' 'lane mail uses the waiter contract'

# pr-data is the workflow consumer. The same finishing run must have its
# review before that read. The old route reads immediately and misses it.
run_wait finishing
READ_DATA=$(cd "$TMP_ROOT/repo" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$HOME" READS="$TMP_ROOT/reads" \
  "$REPO_ROOT/skills/github/scripts/github.sh" pr-data 42)
assert_eq "$(jq -r '.threads[0].id' <<<"$READ_DATA")" PRRT_81 'the wait settles before the production pr-data read'
echo 0 > "$TMP_ROOT/reads"
READ_DATA=$(cd "$TMP_ROOT/repo" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$HOME" READS="$TMP_ROOT/reads" \
  "$REPO_ROOT/skills/github/scripts/github.sh" pr-data 42)
assert_eq "$(jq -r '.threads[0].id' <<<"$READ_DATA")" null 'must-fail: the old route misses the same review'

# Per-rule controls retain the expression and remove only its decision on
# disposable production copies. They execute the same row assertions.
mutate() { # PATH FROM TO
  python3 - "$1" "$2" "$3" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
old = p.read_text()
assert old.count(sys.argv[2]) == 1
new = old.replace(sys.argv[2], sys.argv[3])
assert new != old
p.write_text(new)
PY
}
cp "$SCRIPT" "$TMP_ROOT/wait.pristine"
READER="$TMP_ROOT/repo/.agents/skills/orch/scripts/lib/copilot-check-runs.sh"
cp "$READER" "$TMP_ROOT/reader.pristine"
mutate "$SCRIPT" '  if [[ "$waited" -ge "$BOUND" ]]; then state=expired; review=none; break; fi' \
  '  if [[ "$waited" -ge "$BOUND" ]]; then state=none; review=none; break; fi'
run_wait active 3
assert_eq "$(field state)" none 'must-fail: the bound row rejects a false none result'
cp "$TMP_ROOT/wait.pristine" "$SCRIPT"
mutate "$READER" '$event.event == "review_requested" and' 'false and $event.event == "review_requested" and'
run_wait timeline-request 3
assert_eq "$(field state)" none 'must-fail: the request row detects a disabled timeline rule'
cp "$TMP_ROOT/reader.pristine" "$READER"
mutate "$READER" '$event.event == "copilot_work_started"' 'false and $event.event == "copilot_work_started"'
run_wait timeline-work 3
assert_eq "$(field state)" none 'must-fail: the work-start row detects a disabled timeline rule'
cp "$TMP_ROOT/reader.pristine" "$READER"
mutate "$READER" 'map(select(.status == "queued" or .status == "in_progress") |' \
  'map(select(false and (.status == "queued" or .status == "in_progress")) |'
run_wait active 3
assert_eq "$(field state)" none 'must-fail: active-check discovery cannot become none'
cp "$TMP_ROOT/reader.pristine" "$READER"
# shellcheck disable=SC2016
mutate "$SCRIPT" '  runs="$(orch_copilot_check_runs "$REPO" "$head" "$PR_NUM")" || refuse copilot' \
  '  runs="$(orch_copilot_check_runs "$REPO" "$head" "$PR_NUM")" || runs="[]" # refuse copilot'
run_wait fail
assert_eq "$RC $(field state)" '0 none' 'must-fail: the refusal row rejects a failed read treated as none'
cp "$TMP_ROOT/wait.pristine" "$SCRIPT"
# shellcheck disable=SC2016
mutate "$SCRIPT" '      and ($since == "" or ((.submitted_at | type) == "string" and .submitted_at >= $since)))] |' \
  '      and (true or $since == "" or ((.submitted_at | type) == "string" and .submitted_at >= $since)))] |'
run_wait active 3
assert_eq "$(field state)" settled 'must-fail: an older review cannot settle a new request'
cp "$TMP_ROOT/wait.pristine" "$SCRIPT"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
