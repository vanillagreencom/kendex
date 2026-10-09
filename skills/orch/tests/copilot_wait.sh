#!/usr/bin/env bash
# Surface: copilot-wait and its shared Copilot run/timeline reader.
# Inputs: scripts/copilot-wait, scripts/lib/copilot-check-runs.sh,
# scripts/lib/{gh-auth,gh-repo,lane-mail-nap}.sh, scripts/orch-env,
# github/scripts/lib/{gh-auth,gh-repo,kendex-env,bounded}.sh.
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
  'auth status'*)
    if [[ "${GH_TOKEN:-}${GITHUB_TOKEN:-}" == stale || "${MODE:-}" == auth-dead ]]; then
      echo 'auth failed' >&2; exit 1
    fi
    exit 0
    ;;
  'api user --jq .login')
    if [[ "${GH_TOKEN:-}${GITHUB_TOKEN:-}" == stale || "${MODE:-}" == auth-dead ]]; then
      echo 'auth failed' >&2; exit 1
    fi
    echo fixture-user
    ;;
  'repo view'*) echo o/r ;;
  'pr view 42 --repo o/r --json headRefOid --jq .headRefOid')
    head="$HEAD_A"
    [[ "$MODE" != head-fail && !( "$MODE" == head-confirm-fail && "$(cat "$READS")" -gt 0 ) ]] || { echo 'HTTP 403: Forbidden' >&2; exit 1; }
    [[ "$MODE" != auth-valid || "${GH_TOKEN:-}${GITHUB_TOKEN:-}" == valid ]] || exit 9
    if [[ "$MODE" == moved && "$(cat "$READS")" -ge 1 ]]; then head="$HEAD_B"; fi
    [[ "$MODE" != invalid-head ]] || head=null
    case "$MODE" in timeline-old-review*|timeline-newer-request*|timeline-overlap*|timeline-duplicate-old|timeline-cancelled|timeline-boundary-null|timeline-review-null) head="$HEAD_B" ;; esac
    echo "$head"
    ;;
  'api repos/o/r/commits/'*'/check-runs?filter=all&per_page=100 --paginate --slurp')
    count="$(cat "$READS")"; count=$((count + 1)); echo "$count" > "$READS"
    status=completed
    case "$MODE" in
      finishing|moved|mail) [[ "$count" -gt 1 ]] || status=in_progress ;;
      active|active-old-review|reviews-fail) status=in_progress ;;
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
      timeline-boundary-null|timeline-review-null)
        jq -nc --arg head "$HEAD_A" --arg mode "$MODE" '[[
          {event:"review_requested",id:73,created_at:"2026-10-09T07:00:00Z",requested_reviewer:{login:"Copilot"}},
          {event:"reviewed",id:81,user:{login:"Copilot"},commit_id:(if $mode == "timeline-review-null" then null else $head end),submitted_at:"2026-10-09T07:10:00Z"},
          {event:"head_ref_force_pushed",commit_id:(if $mode == "timeline-boundary-null" then null else $head end),created_at:"2026-10-09T07:20:00Z"}]]'
        ;;

      timeline-old-review*|timeline-newer-request*|timeline-overlap*|timeline-duplicate-old|timeline-cancelled)
        jq -nc --arg a "$HEAD_A" --arg b "$HEAD_B" --arg mode "$MODE" '
          def request($id;$at): {event:"review_requested",id:$id,created_at:$at,commit_id:null,requested_reviewer:{login:"Copilot",type:"Bot"}};
          def review($head;$at): {event:"reviewed",id:(if $at == "2026-10-09T07:10:00Z" then 81 else 82 end),user:{login:"Copilot",type:"Bot"},commit_id:$head,submitted_at:$at};
          [(if $mode == "timeline-overlap-unknown" or $mode == "timeline-old-review-ordinary" or $mode == "timeline-newer-request-ordinary" or $mode == "timeline-duplicate-old" or $mode == "timeline-cancelled" then [{event:"committed",sha:$b,committer:{date:"2026-10-09T06:00:00Z"}}] else [] end),
           [{event:"head_ref_force_pushed",commit_id:$a,created_at:"2026-10-09T06:50:00Z"},
            request(73;"2026-10-09T07:00:00Z")],
           (if ($mode | startswith("timeline-old-review")) or ($mode | startswith("timeline-newer-request")) or $mode == "timeline-duplicate-old"
            then [review($a;"2026-10-09T07:10:00Z")] else [] end),
           (if $mode == "timeline-overlap-unknown" or $mode == "timeline-old-review-ordinary" or $mode == "timeline-newer-request-ordinary" or $mode == "timeline-duplicate-old" or $mode == "timeline-cancelled"
            then []
            elif $mode == "timeline-overlap-ordinary"
            then [{event:"review_dismissed",commit_id:null,created_at:"2026-10-09T07:20:00Z",dismissed_review:{state:"approved",dismissal_commit_id:$b}}]
            else [{event:"head_ref_force_pushed",commit_id:$b,created_at:"2026-10-09T07:20:00Z"}] end),
           (if $mode == "timeline-cancelled" then [{event:"review_request_removed",requested_reviewer:{login:"Copilot"},created_at:"2026-10-09T07:15:00Z"}] else [] end),
           (if ($mode | startswith("timeline-old-review")) then [] else [request(74;"2026-10-09T07:23:47Z")] end),
           (if ($mode | startswith("timeline-overlap")) or $mode == "timeline-duplicate-old" or $mode == "timeline-cancelled" then [review($a;"2026-10-09T07:27:06Z")] else [] end)]'
        ;;
      timeline-request|timeline-initial|timeline-work|timeline-reviewed|timeline-human-review|timeline-removed|timeline-human-removed)
        event=review_requested
        [[ "$MODE" != timeline-work ]] || event=copilot_work_started
        jq -nc --arg event "$event" --arg head "$HEAD_A" --arg old "$HEAD_B" --arg mode "$MODE" '
          [[{event:"reviewed",user:{login:"Copilot"},commit_id:$old,id:40,submitted_at:"2026-10-09T06:40:00Z"},
            (if $mode == "timeline-initial" then empty else {event:"head_ref_force_pushed",commit_id:$head,created_at:"2026-10-09T07:20:00Z"} end),
            {event:$event,id:73,created_at:"2026-10-09T07:23:47Z",commit_id:null,
             requested_reviewer:(if $mode == "timeline-work" then null else {login:"Copilot",type:"Bot"} end),actor:{login:"bmethod",type:"User"}}],
           if $mode == "timeline-reviewed" then [{event:"reviewed",user:{login:"Copilot"},commit_id:$head,id:41,submitted_at:"2026-10-09T07:27:06Z"}]
           elif $mode == "timeline-human-review" then [{event:"reviewed",user:{login:"colleague"},commit_id:$head,id:41,submitted_at:"2026-10-09T07:27:06Z"}]
           elif $mode == "timeline-removed" then [{event:"review_request_removed",requested_reviewer:{login:"Copilot"}}]
           elif $mode == "timeline-human-removed" then [{event:"review_request_removed",requested_reviewer:{login:"colleague"}}]
           else [] end]'
        ;;
      *) echo '[[]]' ;;
    esac
    ;;
  'api repos/o/r/pulls/42/reviews?per_page=100 --paginate --slurp')
    [[ "$MODE" != reviews-fail ]] || { echo 'HTTP 403: Forbidden' >&2; exit 1; }
    if [[ "$MODE" == active-old-review ]]; then
      jq -nc --arg head "$HEAD_B" '[[{id:81,user:{login:"Copilot"},commit_id:$head,state:"APPROVED",submitted_at:"2026-10-09T07:27:06Z"}]]'
      exit 0
    fi
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
run_wait() { # MODE [BOUND] [ITEM] [TOKEN_VARIABLE=VALUE]
  echo 0 > "$TMP_ROOT/reads"
  local args=() auth=() mail=""
  [[ -z "${4:-}" ]] || auth=("$4")
  if [[ -n "${3:-}" ]]; then
    args=(--item "$3")
    mail="$TMP_ROOT/repo/tmp/lane-mail/$3/to-lane.jsonl"
    rm -f -- "$mail"
  fi
  RC=0
  OUT=$(cd "$TMP_ROOT/repo" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$HOME" \
    ${auth[@]+"${auth[@]}"} \
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
  'active-old-review|3|1|expired|none|72|3'
  'queued|3|1|expired|none|72|3'
  'timeline-request|3|1|expired|none|73|3'
  'timeline-initial|3|1|expired|none|73|3'
  'timeline-work|3|1|expired|none|73|3'
  'timeline-reviewed|3|0|none|none|none|0'
  'timeline-old-review|3|0|none|none|none|0'
  'timeline-old-review-ordinary|3|0|none|none|none|0'
  'timeline-newer-request-ordinary|3|1|expired|none|74|3'
  'timeline-duplicate-old|3|1|expired|none|74|3'
  'timeline-cancelled|3|1|expired|none|74|3'
  'timeline-newer-request|3|1|expired|none|74|3'
  'timeline-overlap|3|1|expired|none|74|3'
  'timeline-overlap-ordinary|3|1|expired|none|74|3'
  'timeline-overlap-unknown|3|1|expired|none|74|3'
  'timeline-removed|3|0|none|none|none|0'
  'timeline-human-removed|3|1|expired|none|73|3'
  'timeline-human-review|3|1|expired|none|73|3'
  'moved|20|0|none|none|none|10'
)
for row in "${rows[@]}"; do
  IFS='|' read -r mode bound rc state review run waited <<<"$row"
  run_wait "$mode" "$bound"
  assert_eq "$RC $(field state) $(field review) $(field run) $(field waited)" \
    "$rc $state $review $run $waited" "$mode: current-head result" "$TMP_ROOT/err"
done
for mode in fail timeline-fail timeline-invalid timeline-boundary-null timeline-review-null invalid-head head-fail head-confirm-fail reviews-fail; do
  run_wait "$mode"
  assert_eq "$RC" 1 "$mode: failed reads refuse" "$TMP_ROOT/err"
  assert_eq "$OUT" '' "$mode: failed reads print no passing result"
  assert_contains "$(sed -n 1p "$TMP_ROOT/err")" 'copilot-wait: read-failed operation=' "$mode: refusal starts with its key"
  if [[ "$mode" == *fail ]]; then
    assert_contains "$(cat "$TMP_ROOT/err")" 'HTTP 403: Forbidden' "$mode: refusal retains the API detail"
  fi
done
for token in GH_TOKEN=stale GITHUB_TOKEN=stale GH_TOKEN=valid GITHUB_TOKEN=valid; do
  mode=completed
  [[ "$token" != *=valid ]] || mode=auth-valid
  run_wait "$mode" 20 '' "$token"
  assert_eq "$RC $(field state)" '0 none' "$token: available credentials reach the head read" "$TMP_ROOT/err"
done
run_wait auth-dead 20 '' GH_TOKEN=stale
assert_eq "$RC $OUT" '3 ' 'unavailable environment and keyring credentials refuse' "$TMP_ROOT/err"
assert_eq "$(sed -n 1p "$TMP_ROOT/err")" 'copilot-wait: auth-unavailable pr=42' 'auth refusal starts with its key'
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
mutate "$SCRIPT" '  runs="$(orch_copilot_check_runs "$REPO" "$head" "$PR_NUM" 2>"$ERR_FILE")" || refuse copilot' \
  '  runs="$(orch_copilot_check_runs "$REPO" "$head" "$PR_NUM" 2>"$ERR_FILE")" || runs="[]" # refuse copilot'
run_wait fail
assert_eq "$RC $(field state)" '0 none' 'must-fail: the refusal row rejects a failed read treated as none'
cp "$TMP_ROOT/wait.pristine" "$SCRIPT"
# shellcheck disable=SC2016
mutate "$SCRIPT" 'orch_sanitize_gh_env 2>>"$AUTH_ERR_FILE" || true' ': # orch_sanitize_gh_env 2>>"$AUTH_ERR_FILE" || true'
run_wait completed 20 '' GH_TOKEN=stale
assert_eq "$RC" 3 'must-fail: inherited stale credentials require the shared keyring fallback'
cp "$TMP_ROOT/wait.pristine" "$SCRIPT"
# shellcheck disable=SC2016
mutate "$SCRIPT" '  runs="$(orch_copilot_check_runs "$REPO" "$head" "$PR_NUM" 2>"$ERR_FILE")" || refuse copilot' \
  '  runs="$(orch_copilot_check_runs "$REPO" "$head" "$PR_NUM")" || refuse copilot'
run_wait fail
assert_eq "$(sed -n 1p "$TMP_ROOT/err")" 'HTTP 403: Forbidden' 'must-fail: failed-read rows reject dependency stderr before the refusal'
cp "$TMP_ROOT/wait.pristine" "$SCRIPT"
mutate "$READER" '$event.commit_id == $head' 'true'
run_wait timeline-overlap 3
assert_eq "$(field state)" none 'must-fail: an old-head completion cannot release the newer request'
cp "$TMP_ROOT/reader.pristine" "$READER"
mutate "$READER" '($unassigned | length) == 1' 'false and ($unassigned | length) == 1'
run_wait timeline-old-review-ordinary 3
assert_eq "$(field state)" expired 'must-fail: a unique completed old cycle stays closed after an ordinary push'
cp "$TMP_ROOT/reader.pristine" "$READER"
mutate "$READER" '.cycles |= map(select(.id != $unassigned[0].id))' '.cycles = []'
run_wait timeline-overlap 3
assert_eq "$(field state)" none 'must-fail: assigning an old completion cannot consume every cycle'
cp "$TMP_ROOT/reader.pristine" "$READER"
mutate "$READER" '(.completed | index($event.commit_id)) == null' 'true'
run_wait timeline-duplicate-old 3
assert_eq "$(field state)" none 'must-fail: a completed head cannot claim a newer unknown cycle'
cp "$TMP_ROOT/reader.pristine" "$READER"
mutate "$READER" '.cycles |= map(.pending = false)' '.cycles = []'
run_wait timeline-cancelled 3
assert_eq "$(field state)" none 'must-fail: a cancelled cycle retains ownership of its late completion'
cp "$TMP_ROOT/reader.pristine" "$READER"
mutate "$READER" 'error("Copilot head boundary is unreadable")' '.'
run_wait timeline-boundary-null 3
assert_eq "$(field state)" none 'must-fail: an unreadable head boundary cannot yield a passing result'
cp "$TMP_ROOT/reader.pristine" "$READER"
mutate "$READER" 'error("Copilot completion identity is unreadable")' '.'
run_wait timeline-review-null 3
assert_eq "$(field state)" expired 'must-fail: an unreadable completion cannot settle a cycle'
cp "$TMP_ROOT/reader.pristine" "$READER"
mutate "$READER" '$event.event == "review_request_removed" and' 'false and $event.event == "review_request_removed" and'
run_wait timeline-removed 3
assert_eq "$(field state)" expired 'must-fail: removed requests must close'
cp "$TMP_ROOT/reader.pristine" "$READER"
# shellcheck disable=SC2016
mutate "$SCRIPT" '      and ($since == "" or ((.submitted_at | type) == "string" and .submitted_at >= $since)))] |' \
  '      and (true or $since == "" or ((.submitted_at | type) == "string" and .submitted_at >= $since)))] |'
run_wait active 3
assert_eq "$(field state)" settled 'must-fail: an older review cannot settle a new request'
cp "$TMP_ROOT/wait.pristine" "$SCRIPT"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
