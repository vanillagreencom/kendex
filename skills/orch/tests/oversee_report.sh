#!/usr/bin/env bash
# oversee-report: when the overseer's status report is due, and the rows
# it renders from the fleet state, GitHub and the tracker.
#
# Every case runs the real script against a fleet state under TMP_ROOT, with
# gh, the Linear CLI and the clock stubbed, and asserts its exit status, its
# stdout whole where stdout is the protocol, and the keyed first stderr line
# of a refusal. A report's age is its file's modification time, so each case
# stamps the files it plants against the stubbed clock.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

# shellcheck source=lib/oversee-report-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/oversee-report-fixture.sh"

# A fleet with one of each: KEN-1 landed after the last report, and a fork's
# PR on the ken-1 branch name and one with no head owner did not, KEN-3 landed
# before it, KEN-9 is no fleet item, KEN-2 and KEN-3 still run, KEN-2 with an
# open PR; KEN-4 to KEN-6 wait in the queue and one question is open. KEN-2
# waits on an ask and on red checks, KEN-3 on a post-PR stop. KEN-7 is still
# preparing on its host. KEN-10 is parked on its host, its sandbox stopped
# while #14 waits for the queue, so nothing reads its disk. KEN-3 has
# recorded implement, fix and restack validation runs; KEN-2 not yet.
seed_fleet() {
  new_case "$1"
  report -3600
  fleet '+ {launch_queue: ["KEN-4", "KEN-5", "KEN-6"]}' \
    "$(lane KEN-1 done)" "$(lane KEN-2 running)" "$(lane KEN-3 running)" "$(lane KEN-7 preparing -86400 ssh-a)" \
    "$(lane KEN-10 parked -86400 ssh-a | jq -c '.parked = {pr: 14, head: "abc123", repo: "owner/repo", at: "2026-09-20T00:00:00Z"}')"
  echo '{"id":"1790000000-0-a","kind":"ask","to":"owner","text":"Merge the pricing change?","options":["yes","no"],"recommend":"yes","wait":120,"deadline":"2026-09-26T03:00:00Z"}' \
    > "$CASE/pending-overseer.jsonl"
  echo '{"id":"1790000000-1-a","kind":"ask","text":"Which schema?"}' > "$CASE/pending-KEN-2.jsonl"
  echo '[{"number": 12, "branch": "ken-2", "failed_checks": ["test", "lint"]}]' > "$CASE/failing.json"
  item_state KEN-3 '{"post_pr_stop": {"name": "review-round-cap", "gate": "review", "remaining": ["one unresolved review thread"]},
    "first_panel": {}, "rereview_cycles": 1, "cycles": 7,
    "pr_comment_review": {"iterations": 3, "patched_causes": [{"cause": "a", "commit": "aaa111"}, {"cause": "a", "commit": "bbb222"}]},
    "stages": [{"kind": "implement"}, {"kind": "fix"}, {"kind": "fix"}, {"kind": "fix"}, {"kind": "review"}],
    "validate_rounds": [{"round_id": "r1", "kind": "implement", "mode": "full", "seconds": 3300, "lanes": "lint,test", "selection": "all"},
      {"round_id": "r2", "kind": "fix", "mode": "range", "seconds": 290, "lanes": "lint", "selection": "subset"},
      {"round_id": "r3", "kind": "restack", "mode": "range", "seconds": 60},
      {"round_id": "r4", "kind": "restack", "mode": "range", "seconds": 60}],
    "restack_skips": [{}, {}], "restacks": 4}'
  item_state KEN-2 '{"post_pr_stop": null}'
  printf '%s\n' "$(merged_pr 11 ken-1 -60 abcdef1234)" "$(merged_pr 13 ken-3 -7200 1234567abc)" \
    "$(merged_pr 19 ken-9 -60 9999999aaa)" "$(merged_pr 21 ken-1 -30 2121212aaa someone-else)" \
    "$(merged_pr 23 ken-1 -30 2323232aaa -)" | jq -s . > "$CASE/merged.json"
  echo '[{"number": 12, "headRefName": "ken-2"}]' > "$CASE/open.json"
  local n
  for n in 1 2 3 4 5 6 7 8 9 10; do issue "KEN-$n" "Title $n" "Outcome $n | kept"; done
}

# The suite's clock reads before the week the review cap fell, so no case but
# the Escapes ones below, each on a later clock, reads a count.
ESCAPES_UNREAD="Escapes: unread (the clock reads before the cap week 2026-09-28)"

echo "=== render: Landed carries each Linear item's live state ==="
landed_states() {
  new_case "landed-states-$1"
  report -3600
  fleet '' "$(lane KEN-1 done)" "$(lane KEN-2 done)" "$(lane KEN-3 done)" "$(lane issue-4 done '' '' github owner/repo)"
  local n state
  # Distinct merge times follow the report's oldest-first ordering contract.
  for n in 1 2 3; do
    case "$n" in 1) state=Done ;; 2) state=Verifying ;; 3) state='' ;; esac
    jq -n --arg state "$state" '{title: "Item", state: $state}' > "$CASE/linear-KEN-$n.json"
    merged_pr "$n" "ken-$n" "$(( (n - 5) * 60 ))" abcdef1234
  done > "$CASE/merged.jsonl"
  echo '{"title":"Item","state":"CLOSED"}' > "$CASE/issue-4.json"
  merged_pr 4 issue-4 -60 abcdef1234 >> "$CASE/merged.jsonl"
  jq -s . "$CASE/merged.jsonl" > "$CASE/merged.json"
  run -- render --state "$CASE/state.json" --repo owner/repo
  assert_eq "$RC|$(awk '/^\| (KEN-|issue-)/ {print $2, $3, $4, $5}' <<<"$OUT")" \
    '0|KEN-1 (#1, abcdef1) Done
KEN-2 (#2, abcdef1) Verifying
KEN-3 (#3, abcdef1) |
issue-4 (#4, abcdef1) |' 'the report protocol names live Linear states and leaves absent or GitHub states empty'
}
landed_states shipped
STATE_REPORT="$(mutant_scripts landed-states/orch oversee-report)/oversee-report" || exit 1
ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/landed-states/github"
mutate_file "$STATE_REPORT" '|| label+=" $ITEM_STATE"' '|| :'
if (FAIL=0; REPORT_UNDER_TEST="$STATE_REPORT" landed_states omitted; [[ "$FAIL" -eq 0 ]]) > "$TMP_ROOT/landed-states.out"; then
  fail 'omitting the live state did not redden the Landed cells'
else
  assert_file_contains "$TMP_ROOT/landed-states.out" '  FAIL  ' 'the control rejects the previous state-free cells'
fi

echo "=== render: the cycle owner supplies lane and open medians beside Landed ==="
# The report file is the overseer's protocol. Old records have no lane time;
# new records carry both spans. Their stored verdicts cannot set miss share.
cycle_report() {
  new_case "cycle-$1"
  fleet '' \
    '{"item":"KEN-1","status":"done","cycle":{"class":"micro","actual":3557,"lane_secs":1200,"open":3437,"verdict":"miss"}}' \
    '{"item":"KEN-2","status":"done","cycle":{"class":"micro","actual":8899,"lane_secs":6536,"open":8779,"verdict":"met"}}' \
    '{"item":"KEN-3","status":"done","cycle":{"class":"micro","actual":2500,"lane_secs":900,"open":2380,"verdict":"miss"}}' \
    '{"item":"KEN-4","status":"done","cycle":{"class":"small","actual":100,"open":80,"verdict":"met"}}'
  run -- render --state "$CASE/state.json" --repo owner/repo
  assert_eq "$RC|$(awk '/^Landed|^Cycles:/' <<<"$OUT")" \
    '0|Landed: none
Cycles: class=micro lane_median=1200 open_median=3437 miss_share=1/3
Cycles: class=small lane_median=- open_median=80 miss_share=-' \
    'the report shows both class medians beside Landed and leaves legacy lane time unread'
}
cycle_report shipped
CYCLE_REPORT="$(mutant_scripts cycle-report/orch oversee-report)/oversee-report" || exit 1
ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/cycle-report/github"
mutate_file "$CYCLE_REPORT" 'class|lane_median|open_median|miss_share' 'class|open_median|miss_share'
if (FAIL=0; REPORT_UNDER_TEST="$CYCLE_REPORT" cycle_report missing-lane; [[ "$FAIL" -eq 0 ]]) > "$TMP_ROOT/cycle-report.out"; then
  fail 'the report mutation did not redden the cycle row'
else
  assert_file_contains "$TMP_ROOT/cycle-report.out" '  FAIL  ' 'the report rejects a missing lane median'
fi

echo "=== write: formatter failure refuses before report publication ==="
REAL_AWK="$(command -v awk)"
export CYCLE_REAL_AWK="$REAL_AWK"
cat > "$TMP_ROOT/bin/awk" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == '/^rollup / '* && -f "$CASE/format-fail" ]]; then
  echo 'cycle formatter failed' >&2
  exit 23
fi
exec "$CYCLE_REAL_AWK" "$@"
STUB
chmod +x "$TMP_ROOT/bin/awk"
formatter_write() {
  new_case "formatter-$1"
  fleet '' '{"item":"KEN-1","status":"done","cycle":{"class":"micro","lane_secs":1200,"open":3437}}'
  printf 'Cycle times measured.\n%s\n' "$OWNER_ROWS" > "$CASE/summary.txt"
  touch "$CASE/format-fail"
  run "CYCLE_REAL_AWK=$REAL_AWK" -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt"
  assert_eq "$RC|$(first_err)|$OUT|$(find "$CASE/progress-reports" -type f 2>/dev/null | wc -l | tr -d ' ')|$([[ -s "$CASE/mail.calls" ]] && echo sent || echo absent)" \
    "2|oversee-report: cycle-format=$CASE/state.json||0|absent" 'formatter failure refuses without printing, publishing or sending an incomplete report'
  assert_file_contains "$CASE/err" 'cycle formatter failed' 'formatter refusal preserves the producer error'
}
formatter_write shipped
FORMAT_REPORT="$(mutant_scripts formatter-report/orch oversee-report)/oversee-report" || exit 1
ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/formatter-report/github"
mutate_file "$FORMAT_REPORT" '|| refuse cycle-format "$STATE" "$(cat "$WORK_DIR/cycle-format.err")"' '|| :'
if (FAIL=0; REPORT_UNDER_TEST="$FORMAT_REPORT" formatter_write swallowed; [[ "$FAIL" -eq 0 ]]) > "$TMP_ROOT/formatter-report.out"; then
  fail 'swallowing the formatter failure did not redden publication refusal'
else
  assert_file_contains "$TMP_ROOT/formatter-report.out" '  FAIL  ' 'write refuses the swallowed formatter failure'
fi
rm -f -- "${TMP_ROOT:?}/bin/awk"

echo "=== render: the rows from a fleet ==="
seed_fleet render_fleet
run -- render --state "$CASE/state.json" --repo owner/repo
WANT="Landed:
| issue | what it is | why it matters |
| --- | --- | --- |
| KEN-1 (#11, abcdef1) | Title 1 | Outcome 1 \\| kept |
$ESCAPES_UNREAD

Running:
| issue | what it is | why it matters |
| --- | --- | --- |
| KEN-2 (#12, running) | Title 2 | Outcome 2 \\| kept |
| KEN-3 (no PR, running) | Title 3 | Outcome 3 \\| kept |
| KEN-7 (no PR, preparing) | Title 7 | Outcome 7 \\| kept |
| KEN-10 (#14, parked) | Title 10 | Outcome 10 \\| kept |

Validation:
- KEN-2: no validation run recorded
- KEN-3: 62 min over 4 runs: implement full 55 selection=all lanes=lint,test, fix range 5 selection=subset lanes=lint, restack range 1 selection=unreported, restack range 1 selection=unreported; restack re-test skipped 2 times

Rounds:
- KEN-2: review_rounds=0 fix_receipts=unread validation_runs=unread restacks=0 repeated_class_rounds=unread
- KEN-3: review_rounds=5 fix_receipts=3 validation_runs=unread restacks=4 repeated_class_rounds=1

Use 1: none

Next:
| issue | what it is | why it matters |
| --- | --- | --- |
| KEN-4 | Title 4 | Outcome 4 \\| kept |
| KEN-5 | Title 5 | Outcome 5 \\| kept |
| KEN-6 | Title 6 | Outcome 6 \\| kept |

Waiting on you:
- Question for you: Merge the pricing change? (recommended yes; defaults to it after 2026-09-26T03:00:00Z)
- KEN-2 waits on the overseer to answer: Which schema?
- KEN-2 waits on red checks on #12: test, lint
- KEN-3 waits on a stopped review gate, review-round-cap: one unresolved review thread"
assert_eq "$RC|$OUT" "0|$WANT" \
  "Landed holds only the fleet item merged since the last report, Running each live, preparing or parked lane with its PR, the parked one's from its record, Validation each running lane's minutes in total and per run, Next the queue, Waiting on you the open owner ask with its recommendation and deadline then each running lane's blockers"

echo "=== render: round counts use the shared reader ==="
for name in fixes restacks; do
  ROUND_REPORT="$(mutant_scripts "report-round-$name/orch" lib/lane-gitfile.sh)/oversee-report" || exit 1
  ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/report-round-$name/github"
  case "$name" in
    fixes) old='[.stages[] | select(.kind == "fix")] | length' new='.cycles' ;;
    restacks) old='(.restacks // 0)' new='0' ;;
  esac
  mutate_file "${ROUND_REPORT%/*}/lib/lane-gitfile.sh" "$old" "$new"
  seed_fleet "round_${name}_mutant"
  REPORT_UNDER_TEST="$ROUND_REPORT" run -- render --state "$CASE/state.json" --repo owner/repo
  assert_eq "$RC" "0" "control: $name leaves the report readable"
  if (FAIL=0; assert_eq "$OUT" "$WANT" round-control; [[ "$FAIL" -eq 0 ]]) > "$CASE/control.out"; then
    fail "control: $name did not redden the report count row"
  else
    assert_file_contains "$CASE/control.out" '- KEN-3: review_rounds=5' "control: $name reddens the report count row"
  fi
done
new_case rounds_no_state
report -60
fleet '' "$(lane KEN-3 running)"
issue KEN-3 "Title 3" "Outcome 3"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_contains "$OUT" 'Rounds:
- KEN-3: review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread' "a running lane with no state has unread round counts"

echo "=== render: one completed restack reads 1 whatever its validation route ==="
# KEN-2 restacked with no run or skip recorded, KEN-3 with a range run, KEN-4
# with a skipped re-test: each counts its restack once.
new_case rounds_restack_routes
report -60
fleet '' "$(lane KEN-2 running)" "$(lane KEN-3 running)" "$(lane KEN-4 running)"
item_state KEN-2 '{"stages": [], "restacks": 1}'
item_state KEN-3 '{"stages": [], "restacks": 1, "validate_rounds": [{"round_id": "restack-1", "kind": "restack", "mode": "range", "seconds": 60}]}'
item_state KEN-4 '{"stages": [], "restacks": 1, "restack_skips": [{}]}'
for n in 2 3 4; do issue "KEN-$n" "Title $n" "Outcome $n"; done
run -- render --state "$CASE/state.json" --repo owner/repo
assert_contains "$OUT" 'Rounds:
- KEN-2: review_rounds=0 fix_receipts=0 validation_runs=unread restacks=1 repeated_class_rounds=unread
- KEN-3: review_rounds=0 fix_receipts=0 validation_runs=unread restacks=1 repeated_class_rounds=unread
- KEN-4: review_rounds=0 fix_receipts=0 validation_runs=unread restacks=1 repeated_class_rounds=unread' \
  "one restack reads restacks=1 with no record, a range run or a skip beside it"

echo "=== render: Waiting on you reads the overseer mailbox and nothing else ==="
seed_fleet owner_asks_mail
touch "$CASE/owner-mail-fail"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: owner-asks=overseer" \
  "an overseer mailbox that cannot be listed refuses rather than render Waiting on you as none"

echo "=== render: Waiting on you holds a lane's asks, not its unread directives ==="
# lane-mail pending lists the directives the overseer sent and the lane has
# not read beside the asks; the directive waits on the lane, not on the owner.
seed_fleet pending_directive
echo '{"id":"1790000000-2-b","kind":"directive","text":"Rebase first."}' >> "$CASE/pending-KEN-2.jsonl"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$OUT" "0|$WANT" "an unread directive beside an ask leaves Waiting on you with the ask alone"

echo "=== render and due: the GitHub auth ladder ==="
# A revoked env token with no keyring falls through to the project's
# GH_BOT_TOKEN, as the watch's own ladder does; with no working credential the
# report refuses by name rather than read GitHub unauthenticated.
seed_fleet auth_bot_fallback
touch "$CASE/auth-fail"
run GH_TOKEN=ghp_stale0000 GH_BOT_TOKEN=ghp_bot00000 -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$OUT" "0|$WANT" "render, a revoked GH_TOKEN and no keyring: GH_BOT_TOKEN reads the same rows"
seed_fleet auth_none
touch "$CASE/auth-fail"
run GH_TOKEN=ghp_stale0000 GH_BOT_TOKEN=ghp_stale_bot -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: auth-failed=github" "render, no credential works: refused as auth-failed"
# A keyring the ladder settles on holds for the failing-check list too: an
# inherited GH_BOT_TOKEN that GitHub rejects is not picked up behind it.
seed_fleet auth_keyring_stale_bot
run GH_BOT_TOKEN=ghp_stale_bot -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$OUT" "0|$WANT" "render, the keyring works beside a revoked inherited GH_BOT_TOKEN: the keyring reads the same rows"
# A revoked env token the keyring replaces warns on stderr; a later refusal
# still names its key on the first line, and the warning follows it.
seed_fleet auth_keyring_refusal
touch "$CASE/gh-fail"
run GH_TOKEN=ghp_stale0000 -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)|$(grep -c '^Warning: GH_TOKEN' "$CASE/err" || true)" "2|oversee-report: pr-list=owner/repo|1" \
  "render, keyring replaces a revoked GH_TOKEN, then the list fails: the key is the first stderr line, the warning after it"
new_case auth_due_fallback
report -60
fleet '' "$(lane KEN-1 running -86400)"
echo "[$(merged_pr 11 ken-1 -30 abcdef1234)]" > "$CASE/merged.json"
touch "$CASE/auth-fail"
run ORCH_REPORT_EVERY_ISSUES=1 GH_TOKEN=ghp_stale0000 GH_BOT_TOKEN=ghp_bot00000 -- due --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$OUT" "0|report-due reason=issues since=$(at -60) landed=1" "due, a revoked GH_TOKEN and no keyring: GH_BOT_TOKEN counts the landing"
touch "$CASE/auth-fail"
run ORCH_REPORT_EVERY_ISSUES=1 GH_TOKEN=ghp_stale0000 -- due --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: auth-failed=github" "due, no credential works: refused as auth-failed"

echo "=== render: nothing since the last report ==="
new_case render_empty
report -60
fleet '' "$(lane KEN-1 done)"
echo "[$(merged_pr 11 ken-1 -120 abcdef1234)]" > "$CASE/merged.json"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$OUT" "0|Landed: none
$ESCAPES_UNREAD

Running: none

Validation: none

Rounds: none

Use 1: none

Next: none

Waiting on you: none" "a fleet with nothing new renders each row as none and exits 0"

echo "=== render: the Escapes line under Landed ==="
# The case is the project checkout. Its origin/main and bug list hold two
# escapes in the week of 09-21, one in the week of 09-14, one in the cap's
# week of 09-28 and two in the week of 10-05. Months after the cap's week,
# the line still reads its count.
escapes_world() { # CASE
  local row
  escapes_checkout "$1"
  for row in "2026-09-14T10:00:00Z|feat: x (#30)" "2026-09-15T10:00:00Z|Revert \"feat: x (#30)\" (#31)" \
    "2026-09-21T09:00:00Z|feat: y (#32)" "2026-09-21T10:00:00Z|feat: z (#33)" "2026-09-21T11:00:00Z|Revert \"feat: z (#33)\" (#34)" \
    "2026-09-29T10:00:00Z|feat: w (#35)" "2026-10-05T10:00:00Z|feat: v (#36)" "2026-10-06T10:00:00Z|Revert \"feat: v (#36)\" (#37)" \
    "2026-10-06T11:00:00Z|feat: u (#38)"; do
    escapes_commit "$1" "$(jq -rn --arg s "${row%%|*}" '$s | fromdateiso8601')" "${row#*|}"
  done
  escapes_publish "$1"
  for row in "KEN-32|2026-09-21T12:00:00Z|#32" "KEN-35|2026-09-30T10:00:00Z|#35" "KEN-38|2026-10-07T10:00:00Z|#38"; do
    escapes_bug "${row%%|*}" "$(jq -rn --arg s "$(cut -d'|' -f2 <<<"$row")" '$s | fromdateiso8601')" "it breaks" \
      "Regressed-by: ${row##*|}"
  done | jq -s . > "$1/bugs.json"
}
# the clock|the Escapes line
ESCAPE_ROWS=(
  "2027-01-13T12:00:00Z|Escapes: this week 0, last week 0, the week the review cap fell to 1 (2026-09-28) 1"
  "2026-10-14T12:00:00Z|Escapes: this week 0, last week 2, the week the review cap fell to 1 (2026-09-28) 1"
)
for row in "${ESCAPE_ROWS[@]}"; do
  clock="${row%%|*}"
  new_case "escapes_$clock"
  report -60
  fleet '' "$(lane KEN-1 done)"
  escapes_world "$CASE"
  jq -rn --arg s "$clock" '$s | fromdateiso8601' > "$CASE/now"
  run GH_REPO=owner/repo -- render --state "$CASE/state.json" --repo owner/repo
  # The Escapes line and the first word of the line above it, Landed's.
  assert_eq "$RC|$(awk '/^Escapes:/ { print prev " / " $0 } { prev = $1; sub(/:$/, "", prev) }' <<<"$OUT")" "0|Landed / ${row#*|}" \
    "under Landed, the Escapes line counts this week, last week and the cap's week at $clock"
done

echo "=== render: Use 1 counts the use1 rows since the last report by outcome ==="
# A use1 row from before the last report and a ruling row count for nothing;
# an outcome outside the three is counted as unrecognized, never dropped. The
# window's edges: a row stamped at the last report's time counts, and one
# stamped at NOW belongs to the next report.
seed_use1() {
  new_case "$1"
  report -3600
  fleet "+ {fleet_log: [
    {at: \"$(at -7200)\", kind: \"use1\", item: \"KEN-1\", outcome: \"fallback\", text: \"PR #1 head a\"},
    {at: \"$(at -3600)\", kind: \"use1\", item: \"KEN-8\", outcome: \"declined-unchanged\", text: \"PR #8 head g\"},
    {at: \"$(at 0)\", kind: \"use1\", item: \"KEN-9\", outcome: \"fallback\", text: \"PR #9 head h\"},
    {at: \"$(at -600)\", kind: \"use1\", item: \"KEN-2\", outcome: \"approved-on-rerequest\", text: \"PR #2 head b\"},
    {at: \"$(at -500)\", kind: \"use1\", item: \"KEN-3\", outcome: \"approved-on-rerequest\", text: \"PR #3 head c\"},
    {at: \"$(at -400)\", kind: \"use1\", item: \"KEN-4\", outcome: \"declined-unchanged\", text: \"PR #4 head d\"},
    {at: \"$(at -300)\", kind: \"use1\", item: \"KEN-5\", outcome: \"fallbak\", text: \"PR #5 head e\"},
    {at: \"$(at -200)\", kind: \"ruling\", item: \"KEN-6\", text: \"fallback\"}]}" "$(lane KEN-1 done)"
  echo '[]' > "$CASE/merged.json"
}
USE1_WANT="Use 1: approved-on-rerequest=2 fallback=0 declined-unchanged=2 unrecognized=1"
seed_use1 render_use1
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^Use 1/' <<<"$OUT")" "0|$USE1_WANT" \
  "Use 1 counts each outcome since the last report, an unknown outcome as unrecognized"
jq '.fleet_log += [{at: "yesterday", kind: "use1", item: "KEN-7", outcome: "fallback", text: "PR #7 head f"}]' \
  "$CASE/state.json" > "$CASE/state.next" && mv -- "$CASE/state.next" "$CASE/state.json"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: state=$CASE/state.json" \
  "a use1 row whose stamp is not ISO 8601 refuses rather than count or drop it"

echo "=== render: ORCH_REPORT_UPCOMING caps Next ==="
# A queue of six, so the default cap of 5 is what stops it.
for row in "2|KEN-4,KEN-5" "0|none" "|KEN-4,KEN-5,KEN-6,KEN-8,KEN-9"; do
  IFS='|' read -r upcoming want <<<"$row"
  seed_fleet "upcoming_${upcoming:-default}"
  jq '.launch_queue = ["KEN-4", "KEN-5", "KEN-6", "KEN-8", "KEN-9", "KEN-1"]' "$CASE/state.json" > "$CASE/state.next"
  mv -- "$CASE/state.next" "$CASE/state.json"
  if [[ -n "$upcoming" ]]; then run ORCH_REPORT_UPCOMING="$upcoming" -- render --state "$CASE/state.json" --repo owner/repo
  else run -- render --state "$CASE/state.json" --repo owner/repo; fi
  got="$(awk '/^Next/ { on = 1; if ($0 == "Next: none") print "none"; next } on && /^$/ { on = 0 } on && /^\| KEN-/ { print $2 }' <<<"$OUT" | paste -sd, -)"
  assert_eq "$RC|$got" "0|$want" "ORCH_REPORT_UPCOMING=${upcoming:-unset} renders Next as $want"
done

echo "=== render: Next leaves out what has launched ==="
seed_fleet next_launched
jq '.launch_queue = ["KEN-2", "KEN-1", "KEN-4", "KEN-7", "KEN-5"]' "$CASE/state.json" > "$CASE/state.next"
mv -- "$CASE/state.next" "$CASE/state.json"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^Next/ { on = 1; next } on && /^$/ { on = 0 } on && /^\| KEN-/ { print $2 }' <<<"$OUT" | paste -sd, -)" "0|KEN-4,KEN-5" \
  "a queued item with a lanes[] record of any status, running, preparing or done, is not Next's"

echo "=== render: Next names a held item and its holder ==="
# KEN-2 keeps src/a.sh as its touched set and its open #12 changes src/b.sh;
# KEN-6 names no Location and KEN-8 an unticked one.
seed_fleet next_held
jq '(.lanes[] | select(.item == "KEN-2")).touched = ["src/a.sh"] | .launch_queue += ["KEN-8"]' "$CASE/state.json" > "$CASE/state.next"
mv -- "$CASE/state.next" "$CASE/state.json"
for row in 'KEN-4|`src/a.sh`' 'KEN-5|`src/b.sh`' 'KEN-8|src/c.sh (the gate)'; do
  jq --arg loc "${row#*|}" '.description = "**Location**: \($loc)"' "$CASE/linear-${row%%|*}.json" > "$CASE/state.next"
  mv -- "$CASE/state.next" "$CASE/linear-${row%%|*}.json"
done
echo '[{"number": 12, "headRefName": "ken-2", "changedFiles": 1}]' > "$CASE/open.json"
echo '[[{"filename": "src/b.sh"}]]' > "$CASE/pr-12.json"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk -F' [|] ' '/^Next/ { on = 1; next } on && /^$/ { on = 0 } on && /^\| KEN-/ { print substr($1, 3) }' <<<"$OUT" | paste -sd, -)" \
  "0|KEN-4 (held by KEN-2: src/a.sh),KEN-5 (held by #12: src/b.sh),KEN-6,KEN-8 (overlap unread: location)" \
  "a queued item sharing a file with a running lane or an open pull request names that holder; an unticked Location labels its row"

echo "=== render: Next labels a legacy lane's unticked Location ==="
# KEN-3 runs with no touched set and its Location line names no path, so the
# judgement of KEN-4 cannot read what the lane holds and says whose body it was.
seed_fleet next_lane_unread
jq '.description = "**Location**: src/d.sh (the gate)"' "$CASE/linear-KEN-3.json" > "$CASE/state.next"
mv -- "$CASE/state.next" "$CASE/linear-KEN-3.json"
jq '.description = "**Location**: `src/a.sh`"' "$CASE/linear-KEN-4.json" > "$CASE/state.next"
mv -- "$CASE/state.next" "$CASE/linear-KEN-4.json"
echo '[]' > "$CASE/open.json"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk -F' [|] ' '/^Next/ { on = 1; next } on && /^$/ { on = 0 } on && /^\| KEN-4/ { print substr($1, 3) }' <<<"$OUT")" \
  "0|KEN-4 (overlap unread: lane:KEN-3:location)" \
  "a held lane with no touched set and an unticked Location line labels the row it blocks, and the report still prints"

echo "=== render: ORCH_REPORT_COLUMNS picks and orders the columns ==="
seed_fleet columns
run ORCH_REPORT_COLUMNS="why it matters, issue" -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk 'NR <= 4' <<<"$OUT")" "0|Landed:
| why it matters | issue |
| --- | --- |
| Outcome 1 \\| kept | KEN-1 (#11, abcdef1) |" "a custom column list renders those columns in its order"

echo "=== render: the tracker is the record's, else the key's, and never a guess ==="
# Rows: tracker | repo | the issue-7 row it renders.
while IFS='|' read -r tracker repo want; do
  new_case "identity_${tracker:-none}_${repo:-none}"
  report -60
  fleet '' "$(lane issue-7 running -86400 "" "$tracker" "$repo")"
  jq -n '{title: "GitHub title", body: "## Done when\n- GitHub outcome"}' > "$CASE/issue-7.json"
  jq -n '{title: "Linear title", description: "## Done when\n- Linear outcome"}' > "$CASE/linear-issue-7.json"
  run -- render --state "$CASE/state.json" --repo owner/repo
  assert_eq "$RC|$(awk '/^\| issue-7/' <<<"$OUT")" "0|$want" \
    "an issue-N lane with tracker '${tracker:-none}' and repo '${repo:-none}' renders '$want'"
done <<'ROWS'
github|owner/repo|| issue-7 (no PR, running) | GitHub title | GitHub outcome |
linear|owner/repo|| issue-7 (no PR, running) | Linear title | Linear outcome |
||| issue-7 (no PR, running) | (tracker unknown) | - |
github||| issue-7 (no PR, running) | (repo unknown) | - |
ROWS

new_case identity_github_not_issue
report -60
fleet '' "$(lane KEN-7 running -86400 "" github owner/repo)"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^\| KEN-7/' <<<"$OUT")" "0|| KEN-7 (no PR, running) | (no issue number) | - |" \
  "a GitHub record whose key is not issue-N is not read, and says so"

echo "=== render: Landed reads one merged search per repository ==="
# Unrelated merges are read and matched away; a search that reaches GitHub's
# ceiling refuses, since merges past it would be missing.
new_case landed_busy_repo
report -3600
fleet '' "$(lane KEN-1 done)"
issue KEN-1 "Title 1" "Outcome 1"
jq -n --arg at "$(at -60)" '[range(600) | {number: (1000 + .), headRefName: "other-\(.)", headRepositoryOwner: {login: "owner"}, mergedAt: $at, mergeCommit: {oid: "ffffffffff"}}]
  + [{number: 11, headRefName: "ken-1", headRepositoryOwner: {login: "owner"}, mergedAt: $at, mergeCommit: {oid: "abcdef1234"}}]' > "$CASE/merged.json"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk 'NR == 4' <<<"$OUT")" "0|| KEN-1 (#11, abcdef1) | Title 1 | Outcome 1 |" \
  "600 merges on other branches leave the fleet's own merge rendered"
for row in "999|0" "1000|2"; do
  IFS='|' read -r count want <<<"$row"
  jq -n --arg at "$(at -60)" --argjson n "$count" '[range($n) | {number: (1000 + .), headRefName: "other-\(.)", headRepositoryOwner: {login: "owner"}, mergedAt: $at, mergeCommit: {oid: "ffffffffff"}}]' > "$CASE/merged.json"
  run -- render --state "$CASE/state.json" --repo owner/repo
  got="$RC"; [[ "$RC" -eq 0 ]] || got="$RC|$(first_err)"
  [[ "$want" == 0 ]] || want="2|oversee-report: pr-list-truncated=owner/repo"
  assert_eq "$got" "$want" "$count merges in one repository's search against its ceiling of 1000"
done

# Lane records outlive their lanes, so the reads must not grow with them: one
# merged search per repository, whatever the fleet has launched.
new_case landed_call_count
report -3600
fleet '' "$(lane KEN-1 done)" "$(lane KEN-2 done)" "$(lane KEN-3 done)" "$(lane KEN-4 done)" "$(lane KEN-5 running)"
issue KEN-5 "Title 5" "Outcome 5"
run -- render --state "$CASE/state.json" --repo owner/a --repo owner/b
assert_eq "$RC|$(grep -c -- '--state merged' "$CASE/gh.calls")|$(grep -c -- '--head' "$CASE/gh.calls" || true)" "0|2|0" \
  "five lane records over two repositories take two merged searches and no per-branch read"

echo "=== render: Landed finds a lane's pull request on a branch that names no item ==="
# A Claude cloud session pushes to claude/..., so its pull request is the
# item's by the key in its title's scope or right after Closes; a parked
# record's own number holds whatever the branch, in the repository that
# record names. KEN-4's earlier record carries no park, and the parked one
# after it is the one read. #33 and #37 close KEN-30, not KEN-3; #34, #35
# and #36 only mention KEN-3: in a body, in another item's title, and in a
# revert title. owner/other's #44 shares the parked number and names no item.
new_case landed_cloud_branch
report -3600
fleet '' "$(lane KEN-1 done)" "$(lane KEN-2 done)" "$(lane KEN-3 done)" "$(lane KEN-4 done -172800)" \
  "$(lane KEN-4 parked -86400 ssh-a | jq -c '.parked = {pr: 44, head: "abc123", repo: "Owner/Repo", at: "2026-09-20T00:00:00Z"}')"
for n in 1 2 3 4; do issue "KEN-$n" "Title $n" "Outcome $n"; done
printf '%s\n' \
  "$(merged_pr 31 claude/fix-a -90 3131313aaa | jq -c '. + {title: "fix(KEN-1): a"}')" \
  "$(merged_pr 32 claude/fix-b -80 3232323aaa | jq -c '. + {title: "chore: b", body: "## Completed Issues\r\n- Closes KEN-2 - b\r\n"}')" \
  "$(merged_pr 33 claude/fix-c -70 3333333aaa | jq -c '. + {title: "fix(KEN-30): c", body: "- Closes KEN-30"}')" \
  "$(merged_pr 34 claude/fix-d -60 3434343aaa | jq -c '. + {title: "chore: d", body: "Follow-up to KEN-3."}')" \
  "$(merged_pr 35 ken-1805 -58 3535353aaa | jq -c '. + {title: "refactor(KEN-1805): x before KEN-3 grows it"}')" \
  "$(merged_pr 36 revert-31 -56 3636363aaa | jq -c '. + {title: "Revert \"fix(KEN-3): c\""}')" \
  "$(merged_pr 37 claude/fix-g -54 3737373aaa | jq -c '. + {title: "chore: g", body: "- Closes KEN-30 - Follow-up to KEN-3"}')" \
  "$(merged_pr 44 claude/fix-e -50 4444444aaa)" | jq -s . > "$CASE/merged.json"
merged_pr 44 claude/other -40 4040404aaa | jq -c '. + {title: "chore: unrelated"}' | jq -s . > "$CASE/merged.owner_other.json"
LANDED_CLOUD_WANT="0|| KEN-1 (#31, 3131313) | Title 1 | Outcome 1 |
| KEN-2 (#32, 3232323) | Title 2 | Outcome 2 |
| KEN-4 (#44, 4444444) | Title 4 | Outcome 4 |"
landed_rows() { printf '%s|%s' "$RC" "$(awk '/^Landed/ { on = 1; next } /^Escapes/ { on = 0 } on && /^\| KEN-/' <<<"$OUT")"; }
run -- render --state "$CASE/state.json" --repo owner/repo --repo owner/other
assert_eq "$(landed_rows)" "$LANDED_CLOUD_WANT" \
  "a claude/ pull request lands by its title scope or Closes reference and a parked one by its number in its own repository, and one naming another item or only mentioning it does not"
# Rows, tab-separated: case, the file under scripts/, its text, the
# replacement, want.
while IFS=$'\t' read -r name file old new want; do
  scripts="$(mutant_scripts "landed-$name/orch" "$file")" || exit 1
  ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/landed-$name/github"
  mutate_file "$scripts/$file" "$old" "$new"
  REPORT_UNDER_TEST="$scripts/oversee-report" run -- render --state "$CASE/state.json" --repo owner/repo --repo owner/other
  assert_eq "$(landed_rows)" "${want//\\n/$'\n'}" "control: $name"
done <<'ROWS'
no_title_rule	lib/lane-state.sh	or ((.title // "") | ascii_downcase | test(	or false and ((.title // "") | ascii_downcase | test(	0|| KEN-2 (#32, 3232323) | Title 2 | Outcome 2 |\n| KEN-4 (#44, 4444444) | Title 4 | Outcome 4 |
title_anywhere	lib/lane-state.sh	test("^[a-z]+\\(([^)]*[ ,])?" + $word + "([ ,][^)]*)?\\)!?:")	test("(^|[^a-z0-9])" + $word + "($|[^a-z0-9])")	0|| KEN-1 (#31, 3131313) | Title 1 | Outcome 1 |\n| KEN-2 (#32, 3232323) | Title 2 | Outcome 2 |\n| KEN-3 (#35, 3535353) | Title 3 | Outcome 3 |\n| KEN-3 (#36, 3636363) | Title 3 | Outcome 3 |\n| KEN-4 (#44, 4444444) | Title 4 | Outcome 4 |
no_closes_rule	lib/lane-state.sh	test("^\\s*([-*+]\\s+)?closes\\s+" + $word + "($|[^a-z0-9])")	false	0|| KEN-1 (#31, 3131313) | Title 1 | Outcome 1 |\n| KEN-4 (#44, 4444444) | Title 4 | Outcome 4 |
closes_anywhere	lib/lane-state.sh	closes\\s+" + $word	closes\\s.*" + $word	0|| KEN-1 (#31, 3131313) | Title 1 | Outcome 1 |\n| KEN-2 (#32, 3232323) | Title 2 | Outcome 2 |\n| KEN-3 (#37, 3737373) | Title 3 | Outcome 3 |\n| KEN-4 (#44, 4444444) | Title 4 | Outcome 4 |
no_word_end	lib/lane-state.sh	+ $word + "($|[^a-z0-9])")	+ $word)	0|| KEN-1 (#31, 3131313) | Title 1 | Outcome 1 |\n| KEN-2 (#32, 3232323) | Title 2 | Outcome 2 |\n| KEN-3 (#33, 3333333) | Title 3 | Outcome 3 |\n| KEN-3 (#37, 3737373) | Title 3 | Outcome 3 |\n| KEN-4 (#44, 4444444) | Title 4 | Outcome 4 |
no_number_rule	lib/lane-state.sh	select(.number == $pr	select(false	0|| KEN-1 (#31, 3131313) | Title 1 | Outcome 1 |\n| KEN-2 (#32, 3232323) | Title 2 | Outcome 2 |
first_record	oversee-report	map((map(select(.parked)) | first) // first	map(first	0|| KEN-1 (#31, 3131313) | Title 1 | Outcome 1 |\n| KEN-2 (#32, 3232323) | Title 2 | Outcome 2 |
any_repo_number	oversee-report	(if ($lane.parked.repo // "" | ascii_downcase) == ($repo | ascii_downcase) then $lane.parked.pr else null end)	$lane.parked.pr	0|| KEN-1 (#31, 3131313) | Title 1 | Outcome 1 |\n| KEN-2 (#32, 3232323) | Title 2 | Outcome 2 |\n| KEN-4 (#44, 4444444) | Title 4 | Outcome 4 |\n| KEN-4 (#44, 4040404) | Title 4 | Outcome 4 |
ROWS

# Direct pushes use the append-only cycle log, not the lane's last cycle.
# Out-of-window records, PR cycles and repeat-miss notes are not landings.
echo "=== Landed: direct-push cycle records share the merge window and order ==="
seed_direct_push() {
  new_case "$1"
  report -3600
  fleet '+ {fleet_log: [
    {at: "'"$(at -60)"'", kind: "cycle", item: "KEN-1", text: "cycle item=KEN-1 commit=abcdef1234 class=small"},
    {at: "'"$(at -7200)"'", kind: "cycle", item: "KEN-2", text: "cycle item=KEN-2 commit=2222222aaa class=small"},
    {at: "'"$(at -30)"'", kind: "cycle", item: "KEN-2", text: "cycle item=KEN-2 pr=7 class=small"},
    {at: "'"$(at -20)"'", kind: "cycle", item: "KEN-2", text: "repeat-miss phase=review items=KEN-2 causes=thread_fix"},
    {at: "'"$(at 0)"'", kind: "cycle", item: "KEN-2", text: "cycle item=KEN-2 commit=2222222aaa class=small"}
  ]}' "$(lane KEN-1 done)" "$(lane KEN-2 done)"
  issue KEN-1 "Title 1" "Outcome 1 | kept"
  issue KEN-2 "Title 2" "Outcome 2 | kept"
}
DIRECT_WANT="| KEN-1 (direct push, abcdef1) | Title 1 | Outcome 1 \\| kept |"
while IFS='|' read -r name merge_offset direct_offset threshold count; do
  seed_direct_push "direct_push_$name"
  want="$DIRECT_WANT"
  if [[ "$merge_offset" != none ]]; then
    merged_pr 7 ken-2 "$merge_offset" 7777777aaa | jq -s . > "$CASE/merged.json"
    want="| KEN-2 (#7, 7777777) | Title 2 | Outcome 2 \\| kept |"$'\n'"$want"
  fi
  if [[ "$direct_offset" != none ]]; then
    jq --arg at "$(at "$direct_offset")" '.fleet_log += [{at: $at, kind: "cycle", item: "KEN-1", text: "cycle item=KEN-1 commit=1111111aaa class=small"}]' \
      "$CASE/state.json" > "$CASE/next.json"
    mv "$CASE/next.json" "$CASE/state.json"
    want="| KEN-1 (direct push, 1111111) | Title 1 | Outcome 1 \\| kept |"$'\n'"$want"
  fi
  run -- render --state "$CASE/state.json" --repo owner/repo
  assert_eq "$(landed_rows)" "0|$want" "$name: direct pushes and merges share Landed in time order"
  run ORCH_REPORT_EVERY_MINUTES=0 "ORCH_REPORT_EVERY_ISSUES=$threshold" -- due --state "$CASE/state.json" --repo owner/repo
  due_want=""
  [[ "$threshold" -gt "$count" ]] || due_want="report-due reason=issues since=$(at -3600) landed=$count"
  assert_eq "$RC|$OUT" "0|$due_want" "$name: due counts each landed item once"
done <<'ROWS'
direct|none|none|1|1
mixed|-90|none|2|2
boundary|none|-3600|1|1
repeated|none|-90|2|1
ROWS

DIRECT_MUTANT="$(mutant_scripts direct-push/orch oversee-report)/oversee-report" || exit 1
ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/direct-push/github"
mutate_file "$DIRECT_MUTANT" 'select(.kind == "cycle")' 'select(false and .kind == "cycle")'
seed_direct_push direct_push_mutant
REPORT_UNDER_TEST="$DIRECT_MUTANT" run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^Landed/ { print }' <<<"$OUT")" "0|Landed: none" \
  "control: the PR-only reader omits the direct-push landing"
REPORT_UNDER_TEST="$DIRECT_MUTANT" run ORCH_REPORT_EVERY_MINUTES=0 ORCH_REPORT_EVERY_ISSUES=1 -- due --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$OUT" "0|" "control: the PR-only reader does not trigger the direct-push cadence"

# ORCH_CONNECTED_REPOS: each listed repository is read after --repo by the
# merged search and the open pull request list, once and in one spelling, so a
# merge there lands in the report and an open pull request there runs; a
# setting orch-env cannot read refuses. KEN-1 merged as other/repo#31 and
# KEN-2 is open there as #32. SETTING `absent` sets none and `retired` sets
# ORCH_CONSUMER_REPOS, which orch-env refuses on every read. Sets CONNECTED to
# the exit, the repositories each list read in order, the KEN- cells, and the
# first stderr line of a refusal.
connected_report() { # NAME SETTING [REPORT]
  local envs=()
  new_case "$1"
  report -3600
  fleet '' "$(lane KEN-1 done)" "$(lane KEN-2 running)"
  issue KEN-1 "Title 1" "Outcome 1"
  issue KEN-2 "Title 2" "Outcome 2"
  merged_pr 31 ken-1 -60 3131313aaa other | jq -s . > "$CASE/merged.other_repo.json"
  echo '[{"number": 32, "headRefName": "ken-2"}]' > "$CASE/open.other_repo.json"
  case "$2" in
    absent) ;;
    retired) envs=(ORCH_CONSUMER_REPOS=x/y) ;;
    *) envs=("ORCH_CONNECTED_REPOS=$2") ;;
  esac
  REPORT_UNDER_TEST="${3:-}" run ${envs[@]+"${envs[@]}"} -- render --state "$CASE/state.json" --repo owner/repo
  CONNECTED="rc=$RC"
  if [[ "$RC" -eq 0 ]]; then
    CONNECTED+=" merged=$(awk '/--state merged/ { for (i = 1; i < NF; i++) if ($i == "--repo") { printf "%s%s", sep, $(i + 1); sep = "," } }' "$CASE/gh.calls")"
    CONNECTED+=" open=$(awk '/--state open/ { for (i = 1; i < NF; i++) if ($i == "--repo") { printf "%s%s", sep, $(i + 1); sep = "," } }' "$CASE/gh.calls")"
    CONNECTED+=" cells=$(grep -o '^| KEN-[0-9]* ([^)]*)' <<<"$OUT" | sed 's/^| //' | paste -sd, -)"
  else
    CONNECTED+=" err=$(first_err)"
  fi
}
CONNECTED_ABSENT="rc=0 merged=owner/repo open=owner/repo cells=KEN-2 (no PR, running)"
for row in \
  "connected_listed|Other/Repo OWNER/repo|rc=0 merged=owner/repo,other/repo open=owner/repo,other/repo cells=KEN-1 (#31, 3131313),KEN-2 (#32, running)|a listed repository is read after --repo, once, in one spelling, and its merge and open pull request are reported" \
  "connected_absent|absent|$CONNECTED_ABSENT|with no setting only --repo is read" \
  "connected_unread|retired|rc=2 err=oversee-report: setting-read=ORCH_CONNECTED_REPOS|a setting orch-env cannot read refuses as setting-read"; do
  IFS='|' read -r name setting want label <<<"$row"
  connected_report "$name" "$setting"
  assert_eq "$CONNECTED" "$want" "$label"
done
# One control per rule: without the append the listed repository is read by
# nothing, and without the refusal the run goes on to workflow-state's report
# path, whose own orch-env read refuses the same retired setting.
CONNECTED_MUTANT="$(mutant_scripts connected-add/orch oversee-report)/oversee-report" || exit 1
ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/connected-add/github"
mutate_file "$CONNECTED_MUTANT" 'REPOS+=(${CONNECTED_REPOS[@]+"${CONNECTED_REPOS[@]}"})' 'true || REPOS+=(${CONNECTED_REPOS[@]+"${CONNECTED_REPOS[@]}"})'
connected_report connected_add_control "Other/Repo OWNER/repo" "$CONNECTED_MUTANT"
assert_eq "$CONNECTED" "$CONNECTED_ABSENT" "control: without the append only --repo is read"
UNREAD_MUTANT="$(mutant_scripts connected-unread/orch oversee-report)/oversee-report" || exit 1
ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/connected-unread/github"
mutate_file "$UNREAD_MUTANT" '|| refuse setting-read ORCH_CONNECTED_REPOS' '|| true || refuse setting-read ORCH_CONNECTED_REPOS'
connected_report connected_unread_control retired "$UNREAD_MUTANT"
assert_eq "$CONNECTED" "rc=2 err=oversee-report: report-path=--succession" \
  "control: without the refusal the run reads on past the setting, to the next reader orch-env refuses"

# A first report inside the 7-day lookback reaches the fleet start, whatever
# the minutes setting says.
new_case landed_first_report
fleet '' "$(lane KEN-1 done -86400)" "$(lane KEN-2 done -86400)"
issue KEN-1 "Title 1" "Outcome 1"
issue KEN-2 "Title 2" "Outcome 2"
printf '%s\n' "$(merged_pr 11 ken-1 -10000 abcdef1234)" "$(merged_pr 12 ken-2 -3600 1212121aaa)" | jq -s . > "$CASE/merged.json"
for minutes in unset 0 ""; do
  : > "$CASE/gh.calls"
  if [[ "$minutes" == unset ]]; then run -- render --state "$CASE/state.json" --repo owner/repo
  else run ORCH_REPORT_EVERY_MINUTES="$minutes" -- render --state "$CASE/state.json" --repo owner/repo; fi
  assert_eq "$RC|$(awk '/^Landed/' <<<"$OUT")|$(awk '/^\| KEN-/' <<<"$OUT")|$(grep -c -- "merged:>=$(at -86400)" "$CASE/gh.calls")" \
    "0|Landed:|| KEN-1 (#11, abcdef1) | Title 1 | Outcome 1 |
| KEN-2 (#12, 1212121) | Title 2 | Outcome 2 ||1" \
    "a first report with ORCH_REPORT_EVERY_MINUTES '$minutes' lists every merge since the fleet start"
done

# Past the lookback, on every path: a thousand old merges no longer reach the
# search, the report renders, and its Landed row says where it stopped.
LOOKBACK_START="$(at -604800)"
while IFS='|' read -r name settings report_age verb want; do
  new_case "landed_lookback_$name"
  [[ "$report_age" == none ]] || report "-$report_age"
  fleet '' "$(lane KEN-1 done -2592000)" "$(lane KEN-2 running -2592000)"
  issue KEN-1 "Title 1" "Outcome 1"
  issue KEN-2 "Title 2" "Outcome 2"
  jq -n --arg old "$(at -1728000)" --arg new "$(at -86400)" '[range(1000) | {number: (2000 + .), headRefName: "other-\(.)", headRepositoryOwner: {login: "owner"}, mergedAt: $old, mergeCommit: {oid: "ffffffffff"}}]
    + [{number: 11, headRefName: "ken-1", headRepositoryOwner: {login: "owner"}, mergedAt: $new, mergeCommit: {oid: "abcdef1234"}}]' > "$CASE/merged.json"
  read -r -a envs <<<"$settings"
  run ${envs[@]+"${envs[@]}"} -- "$verb" --state "$CASE/state.json" --repo owner/repo
  got="$RC|$(grep -c -- "merged:>=$LOOKBACK_START" "$CASE/gh.calls" || true)"
  if [[ "$verb" == due ]]; then got+="|$OUT"
  else got+="|$(awk '/^Landed/' <<<"$OUT");rows=$(grep -c '^| KEN-1 (#11, abcdef1) ' <<<"$OUT" || true)"; fi
  want="${want//@START/$LOOKBACK_START}"
  want="${want//@FLEET/$(at -2592000)}"
  assert_eq "$got" "0|1|$want" "$name: past the 7-day lookback the window stops there and the call succeeds"
done <<'ROWS'
minutes_off_issues_no_report|ORCH_REPORT_EVERY_MINUTES=0 ORCH_REPORT_EVERY_ISSUES=1|none|due|report-due reason=issues since=@FLEET landed=1
report_older_than_lookback||2592000|render|Landed (since @START, earlier merges not listed):;rows=1
ROWS

echo "=== render: every --repo is read, and a record's repo is its own ==="
new_case multi_repo
report -3600
# KEN-1's merge on the first --repo is newer than KEN-3's on the second, so
# Landed runs in merge order, not in item or --repo order. KEN-2's red check
# is on the second --repo alone.
fleet '' "$(lane KEN-1 done)" "$(lane KEN-3 done)" "$(lane KEN-2 running)" "$(lane issue-8 running -86400 "" github owner/b)"
issue KEN-1 "Title 1" "Outcome 1"
issue KEN-2 "Title 2" "Outcome 2"
issue KEN-3 "Title 3" "Outcome 3"
echo "[$(merged_pr 11 ken-1 -30 abcdef1234)]" > "$CASE/merged.owner_a.json"
echo "[$(merged_pr 13 ken-3 -90 1234567abc)]" > "$CASE/merged.owner_b.json"
echo '[{"number": 12, "branch": "ken-2", "failed_checks": ["test"]}]' > "$CASE/failing.owner_b.json"
echo '[]' > "$CASE/failing.owner_a.json"
echo '[]' > "$CASE/open.owner_a.json"
echo '[{"number": 12, "headRefName": "ken-2"}]' > "$CASE/open.owner_b.json"
jq -n '{title: "Issue in b", body: "## Done when\n- b outcome"}' > "$CASE/issue-8.owner_b.json"
jq -n '{title: "Issue in a", body: "## Done when\n- a outcome"}' > "$CASE/issue-8.owner_a.json"
run -- render --state "$CASE/state.json" --repo owner/a --repo owner/b
assert_eq "$RC|$(awk '/^\| (KEN-|issue-)/' <<<"$OUT")" "0|| KEN-3 (#13, 1234567) | Title 3 | Outcome 3 |
| KEN-1 (#11, abcdef1) | Title 1 | Outcome 1 |
| KEN-2 (#12, running) | Title 2 | Outcome 2 |
| issue-8 (no PR, running) | Issue in b | b outcome |" \
  "merges in both --repo values land oldest first, an open PR in the second is rendered, and the issue is read in the repo its record names"
assert_eq "$(awk '/^Waiting on you/ { on = 1; next } on' <<<"$OUT")" "- KEN-2 waits on red checks on #12: test" \
  "a red check in the second --repo is read under that repo"

echo "=== render: tracker text is fitted to one line ==="
new_case cell_text
report -60
fleet '' "$(lane KEN-1 running)"
echo '{"id":"1790000000-0-b","kind":"ask","to":"owner","text":"line one\nline two"}' > "$CASE/pending-overseer.jsonl"
jq -n '{title: ("T" * 200), description: "Intro\r\n## Done when\r\n* CRLF outcome\r\n"}' > "$CASE/linear-KEN-1.json"
run -- render --state "$CASE/state.json" --repo owner/repo
LONG="$(printf 'T%.0s' $(seq 157))..."
# Rows: what | the rendered line | want.
while IFS='|' read -r what line want; do
  assert_eq "$RC|$line" "0|$want" "$what"
done <<ROWS
a title past 160 characters keeps 157 and an ellipsis|$(awk -F' [|] ' '/^\| KEN-1/ { print $2 }' <<<"$OUT")|$LONG
a CRLF description still yields its Done-when line|$(awk -F' [|] ' '/^\| KEN-1/ { sub(/ \|$/, "", $3); print $3 }' <<<"$OUT")|CRLF outcome
an owner question with a newline is one list line, and one with no recommendation names none|$(awk '/^- Question for you/' <<<"$OUT")|- Question for you: line one line two
ROWS

echo "=== render: a reserved owner ask names no default and reads overdue from its deadline until answered ==="
new_case reserved_ask
report -60
fleet '' "$(lane KEN-1 running)"
jq -n '{title: "Title 1", description: "## Done when\n* Outcome 1\n"}' > "$CASE/linear-KEN-1.json"
printf '%s\n' \
  '{"id":"1790000000-0-c","kind":"ask","to":"owner","text":"Cut 2.0.0?","options":["cut","hold"],"reserved":true,"wait":60,"deadline":"2026-09-21T14:13:20Z"}' \
  '{"id":"1790000000-0-d","kind":"ask","to":"owner","text":"Delete the bucket?","options":["delete","keep"],"reserved":true,"wait":60,"deadline":"2026-09-21T14:13:21Z"}' \
  '{"id":"1790000000-0-e","kind":"ask","to":"owner","text":"Sign the lease?","options":["sign","wait"],"reserved":true,"wait":60,"deadline":"2026-09-21T14:13:20Z"}' \
  > "$CASE/pending-overseer.jsonl"
# lane-mail's class for an owner answer, which leaves its ask pending until a close.
echo '{"box":"to-lane","kind":"answer","re":"1790000000-0-e","by":"text","closes":false,"mail_class":"resolution","text":"wait"}' >> "$CASE/events.jsonl"
RESERVED_WANT="- Question for you: Cut 2.0.0? (reserved, no default; overdue since 2026-09-21T14:13:20Z)
- Question for you: Delete the bucket? (reserved, no default; due 2026-09-21T14:13:21Z)
- Question for you: Sign the lease? (reserved, answered, awaiting close)"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^- Question for you/' <<<"$OUT")" "0|$RESERVED_WANT" \
  "a reserved ask names no default, reads overdue at its deadline, due a second short of it, and awaiting close once answered"
RESERVED_MUTANT="$(mutant_scripts reserved-overdue/orch oversee-report)/oversee-report" || exit 1
ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/reserved-overdue/github"
mutate_file "$RESERVED_MUTANT" '(.deadline | fromdateiso8601) <= $now' 'false'
REPORT_UNDER_TEST="$RESERVED_MUTANT" run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^- Question for you: Cut/' <<<"$OUT")" "0|- Question for you: Cut 2.0.0? (reserved, no default; due 2026-09-21T14:13:20Z)" \
  "control: without the deadline comparison the report still renders and the overdue ask reads due"
ANSWERED_MUTANT="$(mutant_scripts reserved-answered/orch oversee-report)/oversee-report" || exit 1
ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/reserved-answered/github"
mutate_file "$ANSWERED_MUTANT" 'if .reserved == true and (.id | IN($answered[]))' 'if false'
REPORT_UNDER_TEST="$ANSWERED_MUTANT" run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^- Question for you: Sign/' <<<"$OUT")" "0|- Question for you: Sign the lease? (reserved, no default; overdue since 2026-09-21T14:13:20Z)" \
  "control: without the answered rule the answered reserved ask reads overdue"

echo "=== render: a hosted lane's stop is read from its clone ==="
new_case hosted_stop
report -60
fleet '' "$(lane KEN-7 running -86400 ssh-a)"
issue KEN-7 "Title 7" "Outcome 7"
mkdir -p "$CASE/host/w/KEN-7" "$CASE/host/clone/tmp"
echo "gitdir: /clone/.git/worktrees/KEN-7" > "$CASE/host/w/KEN-7/.git"
echo '{"post_pr_stop": {"name": "ci-fix-cap", "gate": "ci", "remaining": ["test"]}}' > "$CASE/host/clone/tmp/workflow-state-KEN-7.json"
run ORCH_STATE_DIR=tmp -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^Waiting on you/ { on = 1; next } on' <<<"$OUT")" "0|- KEN-7 waits on a stopped ci gate, ci-fix-cap: test" \
  "a hosted lane's post-PR stop is read from the clone its worktree's .git names"
echo "gitdir: /clone/.git" > "$CASE/host/w/KEN-7/.git"
run ORCH_STATE_DIR=tmp -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: item-state=KEN-7" "a .git that names no linked worktree refuses rather than read as no state"
echo "gitdir: /clone/.git/worktrees/KEN-7" > "$CASE/host/w/KEN-7/.git"
rm -f -- "${CASE:?}/host/clone/tmp/workflow-state-KEN-7.json"
run ORCH_STATE_DIR=tmp -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^Waiting on you/' <<<"$OUT")" "0|Waiting on you: none" "a hosted lane with no state file on its host waits on nothing"
# A read lane-host refused at its per-home cap names that cause, never a
# state that could not be read. Rows: the path refused.
for path in /w/KEN-7/.git /clone/tmp/workflow-state-KEN-7.json; do
  printf '%s' "$path" > "$CASE/host-busy"
  run ORCH_STATE_DIR=tmp -- render --state "$CASE/state.json" --repo owner/repo
  assert_eq "$RC|$(first_err)" "2|oversee-report: lane-host-busy=KEN-7" "a $path read lane-host refused at its cap refuses as lane-host-busy"
done
rm -f -- "${CASE:?}/host-busy"
# ../workflows/merge-pr.md § 5 removes a merged lane's worktree before
# lane-close runs: the host answers touch and has no .git there.
rm -f -- "${CASE:?}/host/w/KEN-7/.git"
run ORCH_STATE_DIR=tmp -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^Waiting on you/' <<<"$OUT")" "0|Waiting on you: none" "a hosted lane whose worktree is gone renders, waiting on nothing"

echo "=== render: a running claude-cloud lane has no mailbox or state to read ==="
# Its host kind declares channel=session and files=none, so neither the
# real lane-mail's host-unreachable refusal of its mailbox read nor the
# dispatcher's refusal of a provider verb is reached.
new_case cloud_lane
report -60
fleet '' "$(lane KEN-7 running -86400 claude-cloud)"
issue KEN-7 "Title 7" "Outcome 7"
cloud_row() { printf '%s|%s|%s|%s' "$RC" "$(first_err)" "$(awk '/^Validation:/ { getline; print }' <<<"$OUT")" "$(awk '/^Waiting on you/ { on = 1 } on' <<<"$OUT")"; }
CLOUD_WANT="0||- KEN-7: no validation run recorded|Waiting on you: none"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$(cloud_row)" "$CLOUD_WANT" \
  "a running claude-cloud lane renders with no mailbox blocker, no host-unreachable validation row and no item-state refusal"
MAIL_MUTANT="$(mutant_scripts cloud-mail/orch oversee-report)" || exit 1
ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/cloud-mail/github"
mutate_file "$MAIL_MUTANT/oversee-report" '      session|task) ;;' '      session|task) asks="$(ORCH_LANE_HOST="$host" "$LANE_MAIL" "${args[@]}" 2>"$WORK_DIR/mail.err")" || rc=$? ;;'
REPORT_UNDER_TEST="$MAIL_MUTANT/oversee-report" run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$(cloud_row)" "0||- KEN-7: validation unread, its host unreachable|Waiting on you:
- KEN-7 mailbox unreadable (mail-read=KEN-7): lane-mail: host-unreachable=KEN-7 state=unknown" \
  "control: a claude-cloud lane whose mailbox is read lists it as unreadable on a host-unreachable validation row"
CLOUD_MUTANT="$(mutant_scripts cloud-report/orch lib/lane-gitfile.sh)" || exit 1
ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/cloud-report/github"
mutate_file "$CLOUD_MUTANT/lib/lane-gitfile.sh" 'if [[ "$files" == none ]]; then' 'if [[ "$files" == none ]] && false; then'
REPORT_UNDER_TEST="$CLOUD_MUTANT/oversee-report" run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$(cloud_row | cut -d'|' -f1-2)" "2|oversee-report: item-state=KEN-7" \
  "control: a claude-cloud lane read for its state refuses the report"

echo "=== render: a lane's validation minutes are its own state's ==="
# A hosted lane's rounds are read from its clone as its stop is; one round
# reads singular, and a round list the state cannot sum refuses rather than
# render a total it did not read.
new_case hosted_validation
report -60
fleet '' "$(lane KEN-7 running -86400 ssh-a)"
issue KEN-7 "Title 7" "Outcome 7"
mkdir -p "$CASE/host/w/KEN-7/tmp" "$CASE/host/clone/tmp"
echo "gitdir: /clone/.git/worktrees/KEN-7" > "$CASE/host/w/KEN-7/.git"
printf 'dev-validate-runs-v1\ndev-validate-finished\ndev-validate-bounded\ndev-validate-running\n' > "$CASE/host/w/KEN-7/tmp/validation-runs"
echo '{"validate_rounds": [{"round_id": "r1", "kind": "implement", "mode": "full", "seconds": 89}]}' > "$CASE/host/clone/tmp/workflow-state-KEN-7.json"
run ORCH_STATE_DIR=tmp -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^Validation/ { on = 1; next } on && /^$/ { on = 0 } on' <<<"$OUT")" "0|- KEN-7: 1 min over 1 run: implement full 1 selection=unreported" \
  "a hosted lane's validation minutes are read from the clone its worktree's .git names"
assert_contains "$OUT" '- KEN-7: review_rounds=0 fix_receipts=unread validation_runs=3 restacks=0 repeated_class_rounds=unread' \
  'the report counts hosted starts before their round receipts exist'
# Reported selection is independent of full versus range invocation.
echo '{"validate_rounds": [{"round_id": "r1", "kind": "implement", "mode": "full", "seconds": 89, "lanes": "test,lint", "selection": "subset"}]}' > "$CASE/host/clone/tmp/workflow-state-KEN-7.json"
run ORCH_STATE_DIR=tmp -- render --state "$CASE/state.json" --repo owner/repo
assert_contains "$OUT" "implement full 1 selection=subset lanes=test,lint" "a hosted round reports the lanes beside its minutes"
LANE_MUTANT="$(mutant_scripts lane-report/orch oversee-report)/oversee-report" || exit 1
ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/lane-report/github"
mutate_file "$LANE_MUTANT" '.selection // "unreported"' '"unreported"'
REPORT_UNDER_TEST="$LANE_MUTANT" run ORCH_STATE_DIR=tmp -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC" "0" "control: the report still runs when it drops selection"
assert_not_contains "$OUT" "implement full 1 selection=subset lanes=test,lint" "control: dropping selection reds the reported-round assertion"
# A restack whose re-test restack-skip skipped is recorded in restack_skips,
# which the row names after the runs and never counts as one.
echo '{"validate_rounds": [{"round_id": "r1", "kind": "implement", "mode": "full", "seconds": 89}],
  "restack_skips": [{"head": "h1", "validated_head": "v1", "paths": ["skills/p/SKILL.md"]}, {"head": "h2", "validated_head": "v1", "paths": []}]}' \
  > "$CASE/host/clone/tmp/workflow-state-KEN-7.json"
SKIPS_WANT="0|- KEN-7: 1 min over 1 run: implement full 1 selection=unreported; restack re-test skipped 2 times"
run ORCH_STATE_DIR=tmp -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^Validation/ { on = 1; next } on && /^$/ { on = 0 } on' <<<"$OUT")" "$SKIPS_WANT" \
  "a lane's skipped restack re-tests follow its runs and are not counted as runs"
SKIPS_MUTANT="$(mutant_scripts skips-report/orch oversee-report)/oversee-report" || exit 1
ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/skips-report/github"
mutate_file "$SKIPS_MUTANT" '.restack_skips // []' '[]'
REPORT_UNDER_TEST="$SKIPS_MUTANT" run ORCH_STATE_DIR=tmp -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$([[ "$RC|$(awk '/^Validation/ { on = 1; next } on && /^$/ { on = 0 } on' <<<"$OUT")" == "$SKIPS_WANT" ]] && echo named || echo unnamed)" \
  "unnamed" "control: a report that reads no restack_skips drops the skips from the row"
echo '{"validate_rounds": [{"round_id": "r1", "kind": "implement", "mode": "full", "seconds": "89"}]}' > "$CASE/host/clone/tmp/workflow-state-KEN-7.json"
run ORCH_STATE_DIR=tmp -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: item-state=KEN-7" "a round whose seconds are no number refuses rather than render a total"
rm -f -- "${CASE:?}/host/clone/tmp/workflow-state-KEN-7.json"
run ORCH_STATE_DIR=tmp -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^Validation/ { on = 1; next } on && /^$/ { on = 0 } on' <<<"$OUT")" "0|- KEN-7: no validation run recorded" \
  "a lane with no state on its host has no validation run recorded"
echo "=== render and write: a lane whose mailbox cannot be read is marked, the rest reported ==="
# KEN-8 runs on a host that no longer knows the item: its mailbox read fails,
# and its state, on that host too, is not read (the host fails every call, so
# a read would refuse as item-state).
seed_unreadable() {
  seed_fleet "$1"
  jq -c --argjson lane "$(lane KEN-8 running -86400 ssh-b)" '.lanes += [$lane]' "$CASE/state.json" > "$CASE/state.next"
  mv -- "$CASE/state.next" "$CASE/state.json"
  printf 'lane-mail: host-unreachable=KEN-8 state=unknown\nThe lane host could not be reached.\n' > "$CASE/mail-fail-KEN-8"
  touch "$CASE/host-gone-KEN-8"
}
seed_unreadable mail_unreadable
MARK="- KEN-8 mailbox unreadable (mail-read=KEN-8): lane-mail: host-unreachable=KEN-8 state=unknown"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_contains "$OUT" '- KEN-8: review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread' "a lane whose host did not answer has unread round counts"
ROW10='| KEN-10 (#14, parked) | Title 10 | Outcome 10 \| kept |'
ROW8='| KEN-8 (no PR, running) | Title 8 | Outcome 8 \| kept |'
VAL3='- KEN-3: 62 min over 4 runs: implement full 55 selection=all lanes=lint,test, fix range 5 selection=subset lanes=lint, restack range 1 selection=unreported, restack range 1 selection=unreported; restack re-test skipped 2 times'
ROUND3='- KEN-3: review_rounds=5 fix_receipts=3 validation_runs=unread restacks=4 repeated_class_rounds=1'
ROUND8='- KEN-8: review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread'
VAL8='- KEN-8: validation unread, its host unreachable'
WANT8="$(row10="$ROW10" row8="$ROW8" val3="$VAL3" val8="$VAL8" round3="$ROUND3" round8="$ROUND8" awk '{ print }
  $0 == ENVIRON["row10"] { print ENVIRON["row8"] } $0 == ENVIRON["val3"] { print ENVIRON["val8"] } $0 == ENVIRON["round3"] { print ENVIRON["round8"] }' <<<"$WANT")"
assert_eq "$RC|$OUT" "0|$WANT8
$MARK" "render lists KEN-8 under Running, marks its validation unread and its mailbox under Waiting on you, and every other lane as before"
printf 'One lane is unreadable.\n%s\n' "$OWNER_ROWS" > "$CASE/summary.txt"
run -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt"
assert_eq "$RC|$(awk 'END { print }' <<<"$OUT")" "0|$MARK" "write writes the report with the unreadable lane marked"
echo '{"lanes": [' > "$CASE/state.json"
run -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt"
assert_eq "$RC|$(first_err)" "2|oversee-report: state=$CASE/state.json" "a fleet state file that cannot be read still refuses"
# A local lane's state is on this host, so its stop is still read even where
# the refusal names a host.
seed_fleet mail_unreadable_local
echo 'lane-mail: host-unreachable=KEN-3' > "$CASE/mail-fail-KEN-3"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(grep '^- KEN-3 ' <<<"$OUT")" "0|- KEN-3 mailbox unreadable (mail-read=KEN-3): lane-mail: host-unreachable=KEN-3
- KEN-3 waits on a stopped review gate, review-round-cap: one unresolved review thread" \
  "a local lane whose mailbox read fails is marked and its stored stop still listed"
# A hosted lane whose host answers but whose mailbox read fails still has its
# stop read from that host.
new_case mail_read_failed_hosted
report -60
fleet '' "$(lane KEN-7 running -86400 ssh-a)"
issue KEN-7 "Title 7" "Outcome 7"
mkdir -p "$CASE/host/w/KEN-7" "$CASE/host/clone/tmp"
echo "gitdir: /clone/.git/worktrees/KEN-7" > "$CASE/host/w/KEN-7/.git"
echo '{"post_pr_stop": {"name": "ci-fix-cap", "gate": "ci", "remaining": ["test"]}}' > "$CASE/host/clone/tmp/workflow-state-KEN-7.json"
echo 'lane-mail: mail-read-failed=KEN-7' > "$CASE/mail-fail-KEN-7"
run ORCH_STATE_DIR=tmp -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^Waiting on you/ { on = 1; next } on' <<<"$OUT")" "0|- KEN-7 mailbox unreadable (mail-read=KEN-7): lane-mail: mail-read-failed=KEN-7
- KEN-7 waits on a stopped ci gate, ci-fix-cap: test" "a hosted lane whose host answers keeps its stop when its mailbox read fails"
# Only a refusal naming the lane's own host or mailbox is marked: a missing
# helper, a crash, a global refusal or another item's refusal still refuses.
while IFS='|' read -r name status text; do
  seed_unreadable "mail_$name"
  echo "$status" > "$CASE/mail-exit-KEN-8"
  printf '%s\n' "$text" > "$CASE/mail-fail-KEN-8"
  run -- render --state "$CASE/state.json" --repo owner/repo
  assert_eq "$RC|$(first_err)" "2|oversee-report: mail-read=KEN-8" "a mailbox failure of kind $name refuses the report"
done <<'ROWS'
crash|1|lane-mail: host-unreachable=KEN-8 state=unknown
global|2|lane-mail: root-unresolved=/w/KEN-8
other-item|2|lane-mail: host-unreachable=KEN-9 state=unknown
prefix-item|2|lane-mail: mail-read-failed=KEN-80
other-key|2|lane-mail: item-case-variant=KEN-8
ROWS
seed_fleet mail_helper_missing
run OVERSEE_REPORT_LANE_MAIL="$CASE/no-lane-mail" -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: owner-reports=overseer" "a lane-mail helper that is not there refuses the report"

echo "=== write: each merge lands in exactly one report ==="
# KEN-3 merged at the second the lists are read, and KEN-2 merges while the
# render reads KEN-1's issue, after its lists were read. Neither is in this
# report; both are in the next.
new_case merge_mid_render
report -3600
fleet '' "$(lane KEN-1 running)" "$(lane KEN-2 done)" "$(lane KEN-3 done)"
for n in 1 2 3; do issue "KEN-$n" "Title $n" "Outcome $n"; done
echo "[$(merged_pr 9 ken-3 0 9999999aaa)]" > "$CASE/merged.json"
merged_pr 7 ken-2 1 7777777aaa > "$CASE/merge-on-read-KEN-1.json"
printf 'One lane is running.\n%s\n' "$OWNER_ROWS" > "$CASE/summary.txt"
run -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt"
FILE="$(awk -F= 'NR == 1 { split($2, path, " "); print path[1] }' "$CASE/err")"
STAMPED="$(stat -c %Y -- "$FILE" 2>/dev/null || stat -f %m -- "$FILE")"
assert_eq "$RC|$(awk '/^Landed/' <<<"$OUT")|$STAMPED|$([[ -f "$CASE/merge-on-read-KEN-1.json" ]] && echo unmerged || echo merged)" \
  "0|Landed: none|$NOW|merged" "a write covers merges before the moment it read its lists, and its file carries that moment"
echo "$((NOW + 120))" > "$CASE/now"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^\| KEN-[23] /' <<<"$OUT")" "0|| KEN-3 (#9, 9999999) | Title 3 | Outcome 3 |
| KEN-2 (#7, 7777777) | Title 2 | Outcome 2 |" "the next report lists both merges the written one left out"

echo "=== write: the chat and the file carry one report ==="
seed_fleet write_report
printf 'Two items landed and one waits on you.\n%s\n\n\n' "$OWNER_ROWS" > "$CASE/summary.txt"
run -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt" --succession
NAME="$("$REAL_DATE" -u -d "@$NOW" +%m-%d-%H-%M 2>/dev/null || "$REAL_DATE" -u -r "$NOW" +%m-%d-%H-%M)-succession.md"
FILE="$CASE/progress-reports/$NAME"
assert_eq "$RC|$(first_err)" "0|oversee-report: report-written=$FILE notice-id=notice-1" "a succession write names its file MM-DD-HH-MM-succession.md"
assert_eq "printed=$([[ -n "$OUT" ]] && echo yes)|$OUT" "printed=yes|$(cat "$FILE" 2>/dev/null)" "what write prints is the file's content, byte for byte"
assert_eq "$(grep -c -E '^(Landed|Running|Validation|Use 1|Next|Waiting on you):' <<<"$OUT")|$(awk 'NR == 1' <<<"$OUT")|$(grep -c -F 'Two items landed' <<<"$OUT")" \
  "6|Landed:|0" "the report is the six rows alone: the summary is in neither the file nor the print"
assert_eq "$(awk '{ $NF = "TEXT"; print }' "$CASE/mail.calls")" "notice --item overseer --to owner --attach $FILE --file TEXT" \
  "write sends the owner one report notice carrying the file"
run -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt" --succession
assert_eq "$RC|$(first_err)" "2|oversee-report: report-exists=$FILE" "a second report under the same name is refused, never overwritten"
: > "$CASE/empty.txt"
run -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/empty.txt"
assert_eq "$RC|$(first_err)" "2|oversee-report: summary=$CASE/empty.txt" "a write with an empty summary is refused"
# The notice's text is the summary file's text, the trailing blank lines
# dropped; the stub keeps the argv alone, so the text is read through a copy
# of the stub that saves it.
seed_fleet write_notice_text
printf 'One line.\n%s\n\n' "$OWNER_ROWS" > "$CASE/summary.txt"
sed 's@printf .%s\\n. "\$\*" >> "\$CASE/mail.calls"@cat "$9" > "$CASE/notice.txt"@' "$TMP_ROOT/bin/lane-mail" > "$TMP_ROOT/bin/lane-mail-saving"
chmod +x "$TMP_ROOT/bin/lane-mail-saving"
assert_eq "$(cmp -s "$TMP_ROOT/bin/lane-mail-saving" "$TMP_ROOT/bin/lane-mail" && echo same || echo differs)" "differs" \
  "the saving stub really differs from the recording one"
run OVERSEE_REPORT_LANE_MAIL="$TMP_ROOT/bin/lane-mail-saving" -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt"
assert_eq "$RC|$(cat "$CASE/notice.txt")" "0|One line.
$OWNER_ROWS" "the notice's text is the summary, its trailing blank lines dropped"
seed_fleet write_notice_fails
printf 'KEN-42 waits.\n%s\n' "$OWNER_ROWS" > "$CASE/summary.txt"
touch "$CASE/notice-fail"
run -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt"
FILE="$CASE/progress-reports/$("$REAL_DATE" -u -d "@$NOW" +%m-%d-%H-%M 2>/dev/null || "$REAL_DATE" -u -r "$NOW" +%m-%d-%H-%M).md"
assert_eq "$RC|$(first_err)|$([[ -f "$FILE" ]] && echo written || echo missing)|$([[ -n "$OUT" && "$OUT" == "$(cat "$FILE")" ]] && echo printed)" \
  "2|oversee-report: notice=$FILE|written|printed" \
  "a notice that cannot be sent is refused by name after the report is printed, the file standing"
assert_eq "$(awk '/^oversee-report: summary-shape=/ {print}' "$CASE/err")" \
  'oversee-report: summary-shape=bare-id line=1' "a notice refusal retains the advisory finding after its refusal key"
seed_fleet write_report_off
printf 'The overseer hands over.\n%s\n' "$OWNER_ROWS" > "$CASE/summary.txt"
run ORCH_REPORT=off -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt" --succession
assert_eq "$RC|$(first_err)" "0|oversee-report: report-written=$CASE/progress-reports/$NAME notice-id=notice-1" \
  "ORCH_REPORT=off silences due alone: a succession write still writes"

echo "=== write: notice receipt and retry against the real mailbox ==="
NOTICE_DIR="$(mutant_scripts notice-repeat/orch lib/mailbox-append.sh)" || exit 1
NOTICE_MUTANT="$NOTICE_DIR/lane-mail"
mutate_file "$NOTICE_DIR/lib/mailbox-append.sh" 'if [ -n "${4:-}" ]; then' \
  'if false && [ -n "${4:-}" ]; then'
RECEIPT_MUTANT="$(mutant_scripts receipt/orch oversee-report)/oversee-report" || exit 1
ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/receipt/github"
mutate_file "$RECEIPT_MUTANT" 'message report-written "$TARGET notice-id=${NOTICE_ID%% *}"' \
  'message report-written "$TARGET"'
PATH_MUTANT="$(mutant_scripts report-path/orch oversee-report)/oversee-report" || exit 1
ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/report-path/github"
mutate_file "$PATH_MUTANT" 'REPORT_DIR="$(cd -- "${REPORT_PATH%/*}" && pwd -P)"' \
  'REPORT_DIR="${REPORT_PATH%/*}"'
while IFS='|' read -r mode directory; do
  new_case "notice_retry_${mode}_${directory//\//_}"
  git -C "$CASE" init -q
  git -C "$CASE" config gc.auto 0
  git -C "$CASE" config maintenance.auto false
  mkdir -p "$CASE/progress-reports" "$CASE/reports"
  ln -s progress-reports "$CASE/report-link"
  fleet ''
  printf 'Work continues.\n%s\n' "$OWNER_ROWS" > "$CASE/summary.txt"
  MAIL_UNDER_TEST="$TEST_DIR/../../mailbox/scripts/lane-mail"; REPORT_UNDER_TEST="$REPORT_BIN"
  [[ "$mode" != unguarded ]] || MAIL_UNDER_TEST="$NOTICE_MUTANT"
  [[ "$mode" != missing-id ]] || REPORT_UNDER_TEST="$RECEIPT_MUTANT"
  [[ "$mode" != unnormalized ]] || REPORT_UNDER_TEST="$PATH_MUTANT"
  run ORCH_PROGRESS_REPORT_DIR="$directory" OVERSEE_REPORT_LANE_MAIL="$MAIL_UNDER_TEST" -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt"
  MAILBOX="$CASE/tmp/lane-mail/overseer/to-overseer.jsonl"
  ID="$(jq -r '.id' < "$MAILBOX")" || exit 1
  FILE="$(jq -r '.attach' < "$MAILBOX")" || exit 1
  WRITE_RESULT="$RC|$(first_err)|$OUT"
  RC=0
  OUT="$(cd "$CASE" && env -u ORCH_ASK_WAIT_MINUTES -u ORCH_STATE_DIR \
    PATH="$TMP_ROOT/bin:$PATH" CASE="$CASE" ORCH_PROGRESS_REPORT_DIR="$CASE/progress-reports" \
    "$MAIL_UNDER_TEST" notice --item overseer --to owner --attach "$FILE" --file "$CASE/summary.txt" 2>"$CASE/err")" || RC=$?
  CONTROL_RC=0
  CONTROL_OUT="$(
    FAIL=0
    assert_eq "$WRITE_RESULT" "0|oversee-report: report-written=$CASE/$directory/${FILE##*/} notice-id=$ID|$(cat "$FILE")" "write names its sent notice"
    assert_eq "$RC|$(first_err)|$(jq -rs 'length' < "$MAILBOX")" "2|lane-mail: duplicate id=$ID|1" "retry refuses before appending"
    # workflow-state emits the configured spelling; the real notice above
    # records its physical attachment. Both fleet and session readers use it.
    for caller in fleet session; do
      session_args=(--state "$CASE/state.json" --repo owner/repo)
      [[ "$caller" != session ]] || session_args=(--session-start "$((NOW - 86400))")
      echo "$NOW" > "$CASE/now"
      run ORCH_PROGRESS_REPORT_DIR="$directory" OVERSEE_REPORT_LANE_MAIL="$MAIL_UNDER_TEST" -- due ${session_args[@]+"${session_args[@]}"}
      assert_eq "$RC|$OUT" '0|' "$caller: the sent attachment advances cadence for $directory"
      echo "$((NOW + 7200))" > "$CASE/now"
      run ORCH_PROGRESS_REPORT_DIR="$directory" OVERSEE_REPORT_LANE_MAIL="$MAIL_UNDER_TEST" -- due ${session_args[@]+"${session_args[@]}"}
      assert_eq "$RC|$OUT" "0|report-due reason=minutes since=$(at 0)" "$caller: the next checkpoint retains the collection cutoff for $directory"
    done
    [[ "$FAIL" -eq 0 ]]
  )" || CONTROL_RC=$?
  WANT=1; [[ "$mode" != live ]] || WANT=0
  assert_eq "$CONTROL_RC" "$WANT" "$mode: the same receipt fixture passes live and turns red with the planted defect" "$CASE/err"
done <<'ROWS'
live|progress-reports
live|./progress-reports
live|reports/../progress-reports
live|report-link
unguarded|progress-reports
missing-id|progress-reports
unnormalized|./progress-reports
ROWS
REPORT_UNDER_TEST="$REPORT_BIN"

echo "=== write: a summary the owner already holds ==="
# The summary went out by hand as an owner notice 210 seconds before `write`
# sends it again with the report file: the report is written and printed, and
# the notice is refused with the mailbox unchanged. Lane-mail's refusal is the
# third line, under the key and its English.
new_case notice_text_held
git -C "$CASE" init -q
git -C "$CASE" config gc.auto 0
git -C "$CASE" config maintenance.auto false
fleet ''
printf 'Work continues.\n%s\n' "$OWNER_ROWS" > "$CASE/summary.txt"
MAILBOX="$CASE/tmp/lane-mail/overseer/to-overseer.jsonl"
mkdir -p "${MAILBOX%/*}"
jq -cn --arg at "$(at -210)" --rawfile text "$CASE/summary.txt" \
  '{id: "by-hand", kind: "notice", at: $at, from: "overseer", to: "owner", text: ($text | sub("\n$"; ""))}' > "$MAILBOX"
run OVERSEE_REPORT_LANE_MAIL="$TEST_DIR/../../mailbox/scripts/lane-mail" -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt"
FILE="$CASE/progress-reports/$("$REAL_DATE" -u -d "@$NOW" +%m-%d-%H-%M 2>/dev/null || "$REAL_DATE" -u -r "$NOW" +%m-%d-%H-%M).md"
assert_eq "$RC|$(sed -n '1p;3p' "$CASE/err" | paste -sd '|' -)|$([[ -n "$OUT" && "$OUT" == "$(cat "$FILE")" ]] && echo printed)|$(wc -l < "$MAILBOX" | tr -d ' ')" \
  "2|oversee-report: notice=$FILE|lane-mail: owner-notice-repeated=overseer id=by-hand|printed|1" \
  "a summary the owner holds from a hand notice prints the report and refuses its notice, appending nothing"

echo "=== write: owner summary findings advise while the report sends ==="
# The overseer supplies the upload comment. Its keyed findings are the
# writer's correction protocol; no finding blocks publication or edits text.
summary_write() { # CASE_SUFFIX
  new_case "summary_${name}_$1"
  fleet ''
  printf '%s\n%s\n\n\n' "$lead" "$rows" > "$CASE/summary.txt"
  run OVERSEE_REPORT_LANE_MAIL="$TMP_ROOT/bin/lane-mail-saving" ${envs[@]+"${envs[@]}"} -- \
    write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt"
  local file="$CASE/progress-reports/${NAME%-succession.md}.md"
  assert_eq "$RC|$(awk '/^oversee-report: summary-shape=/ {print}' "$CASE/err")" "0|$want" \
    "summary $name sends and prints each keyed finding" "$CASE/err"
  assert_eq "$([[ -f "$file" && -n "$OUT" && "$OUT" == "$(cat "$file")" ]] && echo written)|$(jq -sr '[.[] | select(.kind == "notice" and .to == "owner") | .attach] | join("|")' "$CASE/events.jsonl" 2>/dev/null || true)" \
    "written|$file" "summary $name writes, prints and sends the report once" "$CASE/err"
  assert_eq "$(cat "$CASE/notice.txt" 2>/dev/null || true)" "$(cat "$CASE/summary.txt")" \
    "summary $name reaches the notice unchanged" "$CASE/err"
  run ${envs[@]+"${envs[@]}"} -- check-summary --summary-file "$CASE/summary.txt"
  assert_eq "$RC|$OUT|$(awk '/^oversee-report: summary-shape=/ {print}' "$CASE/err")" "0||$want" \
    "summary $name check-only has the same findings and no report" "$CASE/err"
  assert_eq "$(wc -l < "$CASE/events.jsonl" | tr -d ' ')" 1 "summary $name check-only sends no second notice"

}
while IFS='~' read -r name mode setting want; do
  rows="$OWNER_ROWS"
  lead='Work continues.'
  case "$mode" in
    normal) ;;
    tiered)
      lead='> *Overall:* Work reaches people within the day.'
      rows="$(cat <<'REPORT'
>
> *What's going well:* Reports reach the owner.
>
> *What's not going well:* Two reports arrived late.

```
Readings
```

- Reports arrive on time.
  - *<https://linear.app/vanillagreen/issue/KEN-42|[KEN-42]>* _(17 h)_
    - _The morning report includes overnight work._

_The owner can read every report._

```
Completed
```

- *<https://linear.app/vanillagreen/issue/KEN-43|[KEN-43]>* Clearer reports

```
In progress
```

- The next report is being written.

```
Blocked
```

- One report needs its source.

```
Waiting on you
```

- Choose the report time.

_The morning report needs this choice._

```
Headroom remaining
```

- *Claude:* 40% _(2 accounts)_
- *Codex:* 27% _(3 accounts)_
- *Copilot:* 9% _(1 account)_

```
Overseer self-analysis
```

- *Good:* I read the reports before sending.
- *Bad:* I sent one report late.

_I changed the reminder._

`Next report: 8 am`
REPORT
)" ;;
    sub-words|sub-id)
      item='KEN-42'
      if [[ "$mode" == sub-words ]]; then
        item='one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twentyone'
      fi
      rows+=$'\n  - '"$item" ;;
    bare-id) lead='KEN-42 is ready.' ;;
    bare-pr) lead='The change (#42) is ready.' ;;
    markdown-id) lead='[KEN-42](https://linear.app/vanillagreen/issue/KEN-42) is ready.' ;;
    github-link) lead='See <https://github.com/owner/repo/pull/42|the change>.' ;;
    commit-link) lead='See https://github.com/owner/repo/commit/abcdef.' ;;
    missing) rows="${rows%$'\n\n```\nWaiting on you'*}" ;;
    spacing) rows="${rows//$'\n\n```'/$'\n```'}" ;;
    key-last) rows="${rows/- Nothing/- Outcome (*<https:\/\/linear.app\/vanillagreen\/issue\/KEN-42|[KEN-42]>*)}" ;;
    two-keys) rows="${rows/- Nothing/- *<https:\/\/linear.app\/vanillagreen\/issue\/KEN-42|[KEN-42]>* waits on *<https:\/\/linear.app\/vanillagreen\/issue\/KEN-43|[KEN-43]>*}" ;;
    header) rows="${rows/Completed/Finished}" ;;
    inline-header) rows="${rows/$'```\nCompleted\n```'/'```Completed```'}" ;;
    unclosed-header) rows+=$'\n```\nCompleted' ;;
    opening) lead='*Overall:* Work continues.' ;;
    bullet-label) rows+=$'\n- Good: Read the report.' ;;
    words20|words21|links20|all)
      item=""
      for ((n=0; n<18; n++)); do item+="word "; done
      case "$mode" in
        words20) item+="word word" ;;
        words21|all) item+="word word word" ;;
        links20) item+="<https://example.com/reading|Source> <https://example.com/reading2|Source>" ;;
      esac
      if [[ "$mode" == all ]]; then
        lead='KEN-42: https://github.com/owner/repo/pull/42'
        rows=$'\n```\nCompleted\n```\n- '"$item"$'\n- '"$item"$'\n- KEN-43: https://github.com/owner/repo/commit/abcdef'
      else
        rows="${rows/- Nothing/- $item}"
      fi ;;
    cap20|cap21)
      extra=16
      [[ "$mode" != cap21 ]] || extra=17
      for ((n=0; n<extra; n++)); do rows+=$'\n- Detail'; done ;;
    figures) rows=$'\nClaude headroom: available\nCount: available\n'"$rows" ;;
    *) echo "oversee_report: fixture-mode=$mode" >&2; exit 1 ;;
  esac
  want="${want//;/$'\n'}"
  envs=()
  [[ -z "$setting" ]] || envs+=("$setting")
  summary_write shipped
  case "$name" in
    key-last|two-keys|header|opening)
      mutant="$(mutant_scripts "shape-original-$name/orch" oversee-report)/oversee-report" || exit 1
      ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "${mutant%/orch/scripts/*}/github"
      case "$name" in
        key-last|two-keys)
          mutate_file "$mutant" 'if (keys && (keys != 1' 'if (0 && keys && (keys != 1' ;;
        header)
          mutate_file "$mutant" 'if (!($0 in sections) && !session_header)' 'if (0 && !($0 in sections) && !session_header)' ;;
        opening)
          mutate_file "$mutant" 'if (!(key in labels) || index($0, labels[key]) != 1)' 'if (0 && (!(key in labels) || index($0, labels[key]) != 1))' ;;
      esac
      if (FAIL=0; REPORT_UNDER_TEST="$mutant" summary_write disabled; [[ "$FAIL" -eq 0 ]]) > "$TMP_ROOT/shape-original-$name.out"; then
        fail "disabled checker passed the changed $name row"
      else
        assert_file_contains "$TMP_ROOT/shape-original-$name.out" "  FAIL  summary $name sends and prints each keyed finding" \
          "the $name row rejects removed production behavior"
      fi ;;
  esac
  if [[ "$name" == tiered-summary ]]; then
    mutant="$(mutant_scripts shape-nested-cap/orch oversee-report)/oversee-report" || exit 1
    ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/shape-nested-cap/github"
    mutate_file "$mutant" 'if ($0 ~ /^[-*][[:space:]]+/) items++' 'if (1 || $0 ~ /^[-*][[:space:]]+/) items++'
    if (FAIL=0; REPORT_UNDER_TEST="$mutant" summary_write nested-cap; [[ "$FAIL" -eq 0 ]]) > "$TMP_ROOT/shape-nested-cap.out"; then
      fail "summary control nested-cap did not redden top-level cap coverage"
    else
      assert_file_contains "$TMP_ROOT/shape-nested-cap.out" '  FAIL  summary tiered-summary sends and prints each keyed finding' \
        "summary coverage rejects counting nested bullets"
      assert_file_contains "$TMP_ROOT/shape-nested-cap.out" 'oversee-report: summary-shape=layout item-lines=12 cap=10' \
        "nested bullet control reaches the configured cap"
    fi
  fi
  if [[ "$name" == all-findings ]]; then
    # Restore refusal or truncate the finding list in private copies. The
    # same send-and-findings assertions must reject either regression.
    for defect in refuse first-only; do
      mutant="$(mutant_scripts "shape-$defect/orch" oversee-report)/oversee-report" || exit 1
      ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/shape-$defect/github"
      case "$defect" in
        refuse)
          old='[[ -z "$SHAPE_FINDINGS" ]] || printf '\''%s\n'\'' "$SHAPE_FINDINGS" >&2'
          new='[[ -z "$SHAPE_FINDINGS" ]] || { printf '\''%s\n'\'' "$SHAPE_FINDINGS" >&2; exit 2; }' ;;
        first-only)
          old='printf "oversee-report: summary-shape=%s%s\n", rule, detail'
          new='if (findings++ == 0) printf "oversee-report: summary-shape=%s%s\n", rule, detail' ;;
      esac
      mutate_file "$mutant" "$old" "$new"
      if (FAIL=0; REPORT_UNDER_TEST="$mutant" summary_write "$defect"; [[ "$FAIL" -eq 0 ]]) > "$TMP_ROOT/shape-$defect.out"; then
        fail "summary control $defect did not redden send-and-findings coverage"
      else
        assert_file_contains "$TMP_ROOT/shape-$defect.out" '  FAIL  ' "summary coverage rejects $defect"
      fi
    done
  fi
done <<'ROWS'
bare-id~bare-id~~oversee-report: summary-shape=bare-id line=1
bare-pr~bare-pr~~oversee-report: summary-shape=bare-id line=1
markdown-id~markdown-id~~oversee-report: summary-shape=bare-id line=1
github-link~github-link~~oversee-report: summary-shape=github-link line=1
commit-link~commit-link~~oversee-report: summary-shape=github-link line=1
waiting-on-you~missing~~oversee-report: summary-shape=waiting-on-you
conforming~normal~~
key-last~key-last~~oversee-report: summary-shape=item-line line=6
two-keys~two-keys~~oversee-report: summary-shape=item-line line=6
header~header~~oversee-report: summary-shape=label line=4
inline-header~inline-header~~oversee-report: summary-shape=label line=3
unclosed-header~unclosed-header~~oversee-report: summary-shape=label line=22
opening~opening~~oversee-report: summary-shape=label line=1
bullet-label~bullet-label~~oversee-report: summary-shape=label line=22
tiered-summary~tiered~ORCH_REPORT_SUMMARY_LINES=10~
sub-bullet-words~sub-words~~oversee-report: summary-shape=layout line=22 words=21
sub-bullet-id~sub-id~~oversee-report: summary-shape=bare-id line=22
label-spacing~spacing~~
words~words21~~oversee-report: summary-shape=layout line=6 words=21
word-boundary~words20~~
two-links~links20~~
line-cap~cap21~~oversee-report: summary-shape=layout item-lines=21 cap=20
at-cap~cap20~~
custom-cap~normal~ORCH_REPORT_SUMMARY_LINES=3~oversee-report: summary-shape=layout item-lines=4 cap=3
figures~figures~ORCH_REPORT_SUMMARY_LINES=4~
all-findings~all~ORCH_REPORT_SUMMARY_LINES=2~oversee-report: summary-shape=bare-id line=1;oversee-report: summary-shape=github-link line=1;oversee-report: summary-shape=layout line=6 words=21;oversee-report: summary-shape=layout line=7 words=21;oversee-report: summary-shape=bare-id line=8;oversee-report: summary-shape=github-link line=8;oversee-report: summary-shape=waiting-on-you;oversee-report: summary-shape=layout item-lines=3 cap=2
ROWS
# A changed installed template is the authority, not a checker label list.
template_labels() {
  mutant="$(mutant_scripts "shape-template-$1/orch" oversee-report)/oversee-report" || exit 1
  local sibling="${mutant%/orch/scripts/*}"
  ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$sibling/github"
  mkdir -p "$sibling/communication/references"
  cp "$TEST_DIR/../../communication/references/reports.md" "$sibling/communication/references/reports.md"
  mutate_file "$sibling/communication/references/reports.md" $'\nCompleted\n' $'\nFinished\n'
  if [[ "$1" == fixed ]]; then
    mutate_file "$mutant" 'TEMPLATE="$SCRIPT_DIR/../../communication/references/reports.md"' \
      "TEMPLATE=\"$TEST_DIR/../../communication/references/reports.md\""
  fi
  name="template-$1"; lead='Work continues.'; envs=()
  rows="${OWNER_ROWS/Completed/Finished}"; want=''
  REPORT_UNDER_TEST="$mutant" summary_write renamed
  rows="$OWNER_ROWS"; want='oversee-report: summary-shape=label line=4'
  REPORT_UNDER_TEST="$mutant" summary_write stale
}
template_labels shipped
if (FAIL=0; template_labels fixed; [[ "$FAIL" -eq 0 ]]) > "$TMP_ROOT/shape-template.out"; then
  fail 'checker ignoring its installed template passed the rename control'
else
  assert_file_contains "$TMP_ROOT/shape-template.out" '  FAIL  summary template-fixed sends and prints each keyed finding' \
    'the template rename row rejects ignoring the installed template'
fi
for cap in '' 0 -1 text; do
  run "ORCH_REPORT_SUMMARY_LINES=$cap" -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt"
  assert_eq "$RC|$(first_err)" "2|oversee-report: setting=ORCH_REPORT_SUMMARY_LINES:$cap" "an invalid summary cap refuses"
done

echo "=== due: the cadence ==="
# Rows: case | report age in seconds, or none | settings | merged PR offsets | want.
while IFS='|' read -r name age settings merges want; do
  new_case "due_$name"
  [[ "$age" == none ]] || report "-$age"
  fleet '' "$(lane KEN-1 running -86400)"
  printf '%s\n' "[]" > "$CASE/merged.json"
  if [[ -n "$merges" ]]; then
    n=11
    for offset in $merges; do merged_pr "$n" ken-1 "$offset" abcdef1234; n=$((n + 1)); done | jq -s . > "$CASE/merged.json"
  fi
  read -r -a envs <<<"$settings"
  run ${envs[@]+"${envs[@]}"} -- due --state "$CASE/state.json" --repo owner/repo
  want="${want//@AGE/$(at "-${age/none/86400}")}"
  assert_eq "$RC|$OUT" "0|$want" "due, $name"
done <<'ROWS'
under_interval|7140|||
at_interval|7200|||report-due reason=minutes since=@AGE
custom_interval|600|ORCH_REPORT_EVERY_MINUTES=10||report-due reason=minutes since=@AGE
empty_minutes|999999|ORCH_REPORT_EVERY_MINUTES=||
zero_minutes|999999|ORCH_REPORT_EVERY_MINUTES=0||
off|999999|ORCH_REPORT=off||
off_connected_unread|999999|ORCH_REPORT=off ORCH_CONSUMER_REPOS=x/y||
no_report_yet|none|||report-due reason=minutes since=@AGE
issues_reached|60|ORCH_REPORT_EVERY_ISSUES=1|-30|report-due reason=issues since=@AGE landed=1
issues_before_marker|60|ORCH_REPORT_EVERY_ISSUES=1|-120|
issues_under|60|ORCH_REPORT_EVERY_ISSUES=2|-30|
issues_one_item_two_prs|60|ORCH_REPORT_EVERY_ISSUES=2|-30 -20|
issues_past_lookback|691200|ORCH_REPORT_EVERY_MINUTES=0 ORCH_REPORT_EVERY_ISSUES=2|-86400|report-due reason=issues since=@AGE landed=1
issues_past_lookback_none|691200|ORCH_REPORT_EVERY_MINUTES=0 ORCH_REPORT_EVERY_ISSUES=2||
issues_inside_lookback|259200|ORCH_REPORT_EVERY_MINUTES=0 ORCH_REPORT_EVERY_ISSUES=2|-86400|
ROWS
# Off exits before ORCH_CONNECTED_REPOS is read, so a setting orch-env refuses
# cannot fail it. Control: the read planted above the off exit refuses.
OFF_MUTANT="$(mutant_scripts off-order/orch oversee-report)/oversee-report" || exit 1
ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/off-order/github"
mutate_file "$OFF_MUTANT" '[[ "$VERB" != due || "$REPORT" == on ]] || exit 0' \
  'CONNECTED="$(orch_connected_repos "${REPOS[@]}")" || refuse setting-read ORCH_CONNECTED_REPOS
[[ "$VERB" != due || "$REPORT" == on ]] || exit 0'
new_case due_off_order_control
fleet '' "$(lane KEN-1 running -86400)"
REPORT_UNDER_TEST="$OFF_MUTANT" run ORCH_REPORT=off ORCH_CONSUMER_REPOS=x/y -- due --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: setting-read=ORCH_CONNECTED_REPOS" \
  "control: with the read above the off exit, off refuses on the unreadable setting"
# A due judged on minutes reaches no gh call, so a credential that would
# refuse is never asked.
new_case due_minutes_no_gh
report -7200
fleet '' "$(lane KEN-1 running -86400)"
touch "$CASE/auth-fail"
run ORCH_REPORT_EVERY_ISSUES=1 GH_TOKEN=ghp_stale0000 -- due --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$OUT|$([[ -s "$CASE/gh.calls" ]] && echo asked || echo unasked)" "0|report-due reason=minutes since=$(at -7200)|unasked" \
  "due, minutes reached: GitHub is not asked, so a failing credential does not refuse it"
new_case due_issues_two_items
report -60
fleet '' "$(lane KEN-1 running)" "$(lane KEN-2 done)"
printf '%s\n' "$(merged_pr 11 ken-1 -30 abcdef1234)" "$(merged_pr 12 ken-2 -20 1212121aaa)" | jq -s . > "$CASE/merged.json"
for caller in fleet session; do
  session_args=()
  [[ "$caller" != session ]] || session_args=(--session-start "$((NOW - 86400))")
  run ORCH_REPORT_EVERY_ISSUES=2 -- due --state "$CASE/state.json" --repo owner/repo ${session_args[@]+"${session_args[@]}"}
  assert_eq "$RC|$OUT" "0|report-due reason=issues since=$(at -60) landed=2" "due, $caller with fleet state retains the landed-item trigger"
done
new_case due_two_lanes
fleet '' "$(lane KEN-1 running -40000)" "$(lane KEN-2 running -86400)"
run -- due --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$OUT" "0|report-due reason=minutes since=$(at -86400)" "due, with no report yet the fleet start is the earliest launch, not the first record's"
# Only a file named as a report is one: a newer note beside the reports moves
# nothing, and a succession report counts like any other.
new_case due_report_names
fleet '' "$(lane KEN-1 running -86400)"
report -7300
report -60 notes.md
run -- due --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$OUT" "0|report-due reason=minutes since=$(at -7300)" "due, a file not named as a report is not the last report"
when="$("$REAL_DATE" -u -d "@$((NOW - 60))" +%m-%d-%H-%M 2>/dev/null || "$REAL_DATE" -u -r "$((NOW - 60))" +%m-%d-%H-%M)"
report -60 "$when-succession.md"
run -- due --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$OUT" "0|" "due, a succession report is the last report"
new_case due_no_lanes
fleet ''
run -- due --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$OUT" "0|" "due, a state with no lane record has no fleet start and nothing is due"

echo "=== refusals ==="
while IFS='|' read -r setting want; do
  seed_fleet "refuse_${setting%%=*}"
  run "$setting" -- render --state "$CASE/state.json" --repo owner/repo
  assert_eq "$RC|$(first_err)" "2|oversee-report: setting=$want" "$setting is refused"
done <<'ROWS'
ORCH_REPORT=maybe|ORCH_REPORT:maybe
ORCH_REPORT_EVERY_MINUTES=2h|ORCH_REPORT_EVERY_MINUTES:2h
ORCH_REPORT_EVERY_ISSUES=-1|ORCH_REPORT_EVERY_ISSUES:-1
ORCH_REPORT_UPCOMING=05|ORCH_REPORT_UPCOMING:05
ORCH_REPORT_COLUMNS=issue,owner|ORCH_REPORT_COLUMNS:issue,owner
ORCH_REPORT_COLUMNS=issue,issue|ORCH_REPORT_COLUMNS:issue,issue
ORCH_REPORT_COLUMNS=|ORCH_REPORT_COLUMNS:
ROWS
seed_fleet refuse_gh
touch "$CASE/gh-fail"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: pr-list=owner/repo" "a failing merged list refuses rather than render Landed as none"
seed_fleet refuse_open
touch "$CASE/gh-fail-open"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: pr-list=owner/repo" "a failing open list alone refuses rather than render every lane with no PR"
seed_fleet refuse_tracker_missing
run OVERSEE_REPORT_TRACKER="$CASE/no-linear" -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: tracker-missing=$CASE/no-linear" "a Linear CLI that is not executable refuses by name"
seed_fleet refuse_write_only
run -- render --state "$CASE/state.json" --repo owner/repo --succession
assert_eq "$RC|$(first_err)" "2|oversee-report: args=write-only-option" "--succession on render is refused"
new_case refuse_gh_issue
report -60
fleet '' "$(lane issue-7 running -86400 "" github owner/repo)"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: tracker-read=issue-7" "a failing gh issue view refuses rather than render blank cells"
seed_fleet refuse_mail_busy
echo 'lane-mail: lane-host-busy=KEN-2' > "$CASE/mail-fail-KEN-2"
echo 69 > "$CASE/mail-exit-KEN-2"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: lane-host-busy=KEN-2" "a mailbox read lane-host refused at its cap refuses as lane-host-busy, not a row marked unreadable"
seed_fleet refuse_title
echo '{"description": "## Done when\n- no title here"}' > "$CASE/linear-KEN-2.json"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: tracker-read=KEN-2" "a tracker read with no title refuses rather than render a blank cell"
seed_fleet refuse_tracker
rm -f "$CASE/linear-KEN-2.json"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: tracker-read=KEN-2" "an issue the tracker cannot read refuses"
# The settings loader names the file and the fault on stderr before the
# refusal runs; that text is held, so the key is still the first line and the
# loader's line follows it.
seed_fleet refuse_settings
echo '[env] # a comment' > "$CASE/kendex.settings.toml"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)|$(grep -c '^kendex-env: table-header ' "$CASE/err" || true)" "2|oversee-report: settings-load=$CASE|1" \
  "a malformed settings file refuses as settings-load, the loader's line after the key"

# Without the github skill beside orch, the shared auth helper cannot load,
# and the report refuses by its own key rather than end on the helper's.
NOHELPER="$(mutant_scripts nohelper/orch)" || exit 1
seed_fleet auth_helper_missing
REPORT_UNDER_TEST="$NOHELPER/oversee-report" run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: auth-helper=$NOHELPER/lib/gh-auth.sh" \
  "render, no github skill beside orch: refused as auth-helper"

echo "=== must-fail control ==="
# One mutant for both verbs: without the auth ladder, a revoked env token reads
# GitHub as it stands, and render's list and due's count each refuse on it.
# The copy sits in a skills layout beside the github skill, whose shared auth
# helper lib/gh-auth.sh reaches through ../../../github.
MUTANT="$(mutant_scripts mutant/orch oversee-report)/oversee-report" || exit 1
ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/mutant/github"
ladder='  github_auth'
assert_eq "$(grep -cxF -- "$ladder" "$MUTANT")" "2" "control: the ladder is two call lines to strip"
awk -v line="$ladder" '$0 == line { print "  :"; next } { print }' "$REPORT_BIN" > "$MUTANT"
assert_eq "$(grep -cxF -- "$ladder" "$MUTANT")" "0" "control: both call lines are stripped"
seed_fleet auth_bot_fallback_mutant
touch "$CASE/auth-fail"
REPORT_UNDER_TEST="$MUTANT" run GH_TOKEN=ghp_stale0000 GH_BOT_TOKEN=ghp_bot00000 -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: pr-list=owner/repo" "control: without the ladder a revoked GH_TOKEN fails render's list"
new_case auth_due_fallback_mutant
report -60
fleet '' "$(lane KEN-1 running -86400)"
echo "[$(merged_pr 11 ken-1 -30 abcdef1234)]" > "$CASE/merged.json"
touch "$CASE/auth-fail"
REPORT_UNDER_TEST="$MUTANT" run ORCH_REPORT_EVERY_ISSUES=1 GH_TOKEN=ghp_stale0000 GH_BOT_TOKEN=ghp_bot00000 -- due --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: pr-list=owner/repo" "control: without the ladder due's count fails on a revoked GH_TOKEN"

# The mailbox read's busy branch: without it a read lane-host refused at its
# cap reads as a mailbox that failed.
BUSY_MUTANT="$(mutant_scripts busy/orch oversee-report)/oversee-report" || exit 1
ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/busy/github"
mutate_file "$BUSY_MUTANT" '[[ "$rc" -ne "$LANE_HOST_BUSY_EXIT" ]] || refuse lane-host-busy "$item" "$(cat "$WORK_DIR/mail.err")"' ':'
seed_fleet mail_busy_mutant
echo 'lane-mail: lane-host-busy=KEN-2' > "$CASE/mail-fail-KEN-2"
echo 69 > "$CASE/mail-exit-KEN-2"
REPORT_UNDER_TEST="$BUSY_MUTANT" run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: mail-read=KEN-2" "control: without it a refused mailbox read is mail-read"

# write's report body: with the summary written back above the rows, the
# summary shows in the print and the file, so the six-rows-alone row reddens.
SUMMARY_MUTANT="$(mutant_scripts summary/orch oversee-report)/oversee-report" || exit 1
ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/summary/github"
IFS= read -r body_line <<'EOF' || true
printf '%s\n' "$BODY" > "$TMP_FILE"
EOF
IFS= read -r summary_line <<'EOF' || true
printf '%s\n\n%s\n' "$SUMMARY_TEXT" "$BODY" > "$TMP_FILE"
EOF
mutate_file "$SUMMARY_MUTANT" "$body_line" "$summary_line"
seed_fleet write_summary_mutant
printf 'Two items landed and one waits on you.\n%s\n\n\n' "$OWNER_ROWS" > "$CASE/summary.txt"
REPORT_UNDER_TEST="$SUMMARY_MUTANT" run -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt" --succession
FILE="$CASE/progress-reports/$NAME"
assert_eq "$RC|$(awk 'NR == 1' <<<"$OUT")|$(grep -c -F 'Two items landed' <<<"$OUT")|$(grep -c -F 'Two items landed' "$FILE")" \
  "0|Two items landed and one waits on you.|1|1" "control: with the summary back in the body, the print and the file open with it"

# The renderer with no Escapes line, its one call stubbed out: the Escapes
# row reddens.
ESCAPES_MUTANT="$(mutant_scripts escapes/orch oversee-report)/oversee-report" || exit 1
ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/escapes/github"
mutate_file "$ESCAPES_MUTANT" '  escapes_row' '  : escapes_row'
new_case escapes_mutant
report -60
fleet '' "$(lane KEN-1 done)"
escapes_world "$CASE"
REPORT_UNDER_TEST="$ESCAPES_MUTANT" run GH_REPO=owner/repo -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^Escapes:/' <<<"$OUT")" "0|" "control: a renderer with no Escapes line prints none, which the Escapes row fails"

# The Use 1 window: without it the fallback rows from before the last report
# and at NOW are counted too.
USE1_MUTANT="$(mutant_scripts use1/orch oversee-report)/oversee-report" || exit 1
ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/use1/github"
mutate_file "$USE1_MUTANT" '$t >= $since and $t < $until' 'true'
seed_use1 render_use1_mutant
REPORT_UNDER_TEST="$USE1_MUTANT" run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^Use 1/' <<<"$OUT")" "0|${USE1_WANT/fallback=0/fallback=2}" \
  "control: without the window the use1 rows outside it are counted"

new_case tracker_owner_asks
report -60
fleet '' ''
printf '%s\n' \
  '{"id":"tracker-1","kind":"ask","to":"owner","issue":"KEN-7","tracker_posted":true,"text":"First tracker ask"}' \
  '{"id":"tracker-2","kind":"ask","to":"owner","issue":"KEN-8","tracker_posted":true,"text":"Second tracker ask"}' \
  '{"id":"chat-1","kind":"ask","to":"owner","text":"Chat ask"}' >"$CASE/pending-overseer.jsonl"
for item in KEN-7 KEN-8; do
  jq -n --arg url "https://linear.app/test/issue/$item" '{url:$url}' >"$CASE/linear-$item.json"
done
run -- render --state "$CASE/state.json" --repo owner/repo
TRACKER_WANT='2 on the tracker: [KEN-7](https://linear.app/test/issue/KEN-7), [KEN-8](https://linear.app/test/issue/KEN-8)
- Question for you: Chat ask'
assert_eq "$RC|$(awk '/^Waiting on you/ { on = 1; next } on' <<<"$OUT")" "0|$TRACKER_WANT" \
  'the report groups tracker links and keeps the chat-only ask line'
TRACKER_REPORT_MUTANT="$(mutant_scripts tracker-report/orch oversee-report)/oversee-report"
ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/tracker-report/github"
mutate_file "$TRACKER_REPORT_MUTANT" '[[ "$tracker_count" -gt 0 ]]' '[[ "$tracker_count" -lt 0 ]]'
REPORT_UNDER_TEST="$TRACKER_REPORT_MUTANT" run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^Waiting on you/ { on = 1; next } on' <<<"$OUT")" '0|- Question for you: Chat ask' \
  'control: dropping the tracker row fails the report grouping assertion'

# An unconfirmed item may have rejected every tracker write. The report
# keeps its native chat line without reading that unavailable item's link.
new_case tracker_owner_fallback
report -60
fleet '' ''
printf '%s\n' '{"id":"failed-1","kind":"ask","to":"owner","issue":"KEN-404","tracker_posted":false,"text":"Approve fallback?\nFull detail.","options":["approve","hold"],"recommend":"approve","deadline":"2026-09-26T03:00:00Z"}' \
  >"$CASE/pending-overseer.jsonl"
run -- render --state "$CASE/state.json" --repo owner/repo
FALLBACK_WANT='- Question for you: Approve fallback? Full detail. (recommended approve; defaults to it after 2026-09-26T03:00:00Z)'
assert_eq "$RC|$(awk '/^Waiting on you/ { on = 1; next } on' <<<"$OUT")" "0|$FALLBACK_WANT" \
  'an unconfirmed item keeps the complete chat report line without a tracker read'
TRACKER_REPORT_MUTANT="$(mutant_scripts tracker-fallback/orch oversee-report)/oversee-report"
ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/tracker-fallback/github"
mutate_file "$TRACKER_REPORT_MUTANT" '[.[] | select(.tracker_posted == true)]' '[.[] | select(.issue != null)]'
mutate_file "$TRACKER_REPORT_MUTANT" 'select(.tracker_posted == true) | .issue' 'select(.issue != null) | .issue'
mutate_file "$TRACKER_REPORT_MUTANT" 'select(.tracker_posted != true)' 'select(.issue == null)'
"$BASH" -n "$TRACKER_REPORT_MUTANT"
REPORT_UNDER_TEST="$TRACKER_REPORT_MUTANT" run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" '2|oversee-report: owner-asks=overseer' \
  'control: issue presence fails the unconfirmed chat report assertion'

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
