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
# validated twice, a full implement round and a range fix round; KEN-2 not yet.
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
    "validate_rounds": [{"round_id": "r1", "kind": "implement", "mode": "full", "seconds": 3300, "lanes": "lint,test", "selection": "all"},
      {"round_id": "r2", "kind": "fix", "mode": "range", "seconds": 290, "lanes": "lint", "selection": "subset"}]}'
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
- KEN-3: 60 min over 2 runs: implement full 55 selection=all lanes=lint,test, fix range 5 selection=subset lanes=lint

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
mutate_file "$CLOUD_MUTANT/lib/lane-gitfile.sh" '[[ "$files" != none ]] || return 0' '{ [[ "$files" != none ]] || true; } || return 0'
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
mkdir -p "$CASE/host/w/KEN-7" "$CASE/host/clone/tmp"
echo "gitdir: /clone/.git/worktrees/KEN-7" > "$CASE/host/w/KEN-7/.git"
echo '{"validate_rounds": [{"round_id": "r1", "kind": "implement", "mode": "full", "seconds": 89}]}' > "$CASE/host/clone/tmp/workflow-state-KEN-7.json"
run ORCH_STATE_DIR=tmp -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^Validation/ { on = 1; next } on && /^$/ { on = 0 } on' <<<"$OUT")" "0|- KEN-7: 1 min over 1 run: implement full 1 selection=unreported" \
  "a hosted lane's validation minutes are read from the clone its worktree's .git names"
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
ROW10='| KEN-10 (#14, parked) | Title 10 | Outcome 10 \| kept |'
ROW8='| KEN-8 (no PR, running) | Title 8 | Outcome 8 \| kept |'
VAL3='- KEN-3: 60 min over 2 runs: implement full 55 selection=all lanes=lint,test, fix range 5 selection=subset lanes=lint'
VAL8='- KEN-8: validation unread, its host unreachable'
WANT8="$(row10="$ROW10" row8="$ROW8" val3="$VAL3" val8="$VAL8" awk '{ print }
  $0 == ENVIRON["row10"] { print ENVIRON["row8"] } $0 == ENVIRON["val3"] { print ENVIRON["val8"] }' <<<"$WANT")"
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
printf 'Nobody hears this.\n%s\n' "$OWNER_ROWS" > "$CASE/summary.txt"
touch "$CASE/notice-fail"
run -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt"
FILE="$CASE/progress-reports/$("$REAL_DATE" -u -d "@$NOW" +%m-%d-%H-%M 2>/dev/null || "$REAL_DATE" -u -r "$NOW" +%m-%d-%H-%M).md"
assert_eq "$RC|$(first_err)|$([[ -f "$FILE" ]] && echo written || echo missing)|$([[ -n "$OUT" && "$OUT" == "$(cat "$FILE")" ]] && echo printed)" \
  "2|oversee-report: notice=$FILE|written|printed" \
  "a notice that cannot be sent is refused by name after the report is printed, the file standing"
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
for mode in live unguarded missing-id; do
  new_case "notice_retry_$mode"
  git -C "$CASE" init -q
  git -C "$CASE" config gc.auto 0
  git -C "$CASE" config maintenance.auto false
  fleet ''
  printf 'Work continues.\n%s\n' "$OWNER_ROWS" > "$CASE/summary.txt"
  MAIL_UNDER_TEST="$TEST_DIR/../scripts/lane-mail"; REPORT_UNDER_TEST="$REPORT_BIN"
  [[ "$mode" != unguarded ]] || MAIL_UNDER_TEST="$NOTICE_MUTANT"
  [[ "$mode" != missing-id ]] || REPORT_UNDER_TEST="$RECEIPT_MUTANT"
  run OVERSEE_REPORT_LANE_MAIL="$MAIL_UNDER_TEST" -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt"
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
    assert_eq "$WRITE_RESULT" "0|oversee-report: report-written=$FILE notice-id=$ID|$(cat "$FILE")" "write names its sent notice"
    assert_eq "$RC|$(first_err)|$(jq -rs 'length' < "$MAILBOX")" "2|lane-mail: duplicate id=$ID|1" "retry refuses before appending"
    [[ "$FAIL" -eq 0 ]]
  )" || CONTROL_RC=$?
  WANT=1; [[ "$mode" != live ]] || WANT=0
  assert_eq "$CONTROL_RC" "$WANT" "$mode: the same receipt fixture passes live and turns red with the planted defect" "$CASE/err"
done
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
run OVERSEE_REPORT_LANE_MAIL="$TEST_DIR/../scripts/lane-mail" -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt"
FILE="$CASE/progress-reports/$("$REAL_DATE" -u -d "@$NOW" +%m-%d-%H-%M 2>/dev/null || "$REAL_DATE" -u -r "$NOW" +%m-%d-%H-%M).md"
assert_eq "$RC|$(sed -n '1p;3p' "$CASE/err" | paste -sd '|' -)|$([[ -n "$OUT" && "$OUT" == "$(cat "$FILE")" ]] && echo printed)|$(wc -l < "$MAILBOX" | tr -d ' ')" \
  "2|oversee-report: notice=$FILE|lane-mail: owner-notice-repeated=overseer id=by-hand|printed|1" \
  "a summary the owner holds from a hand notice prints the report and refuses its notice, appending nothing"

echo "=== write: owner summary shape before any report or notice ==="
# The real producer is the overseer's --summary-file upload comment.
# Each mutant keeps its detector and diagnostic but disables that rule's
# refusal decision, so the same refusal assertion turns red.
while IFS='~' read -r name lead mode setting rule; do
  rows="$OWNER_ROWS"
  case "$mode" in
    normal) ;;
    missing) rows=$'\n*Landed*\n- Nothing\n\n*Running*\n- Nothing\n\n*Blocked*\n- Nothing' ;;
    spacing) rows=$'\n*Landed*\n- Nothing\n*Running*\n- Nothing\n\n*Blocked*\n- Nothing\n\n*Waiting on you*\n- Nothing' ;;
    long) rows+=$'\nMore detail.\nMore detail.\nMore detail.' ;;
    *) echo "oversee_report: fixture-mode=$mode" >&2; exit 1 ;;
  esac
  new_case "summary_$name"
  fleet ''
  printf '%s\n%s\n' "$lead" "$rows" > "$CASE/summary.txt"
  envs=()
  [[ -z "$setting" ]] || envs+=("$setting")
  run ${envs[@]+"${envs[@]}"} -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt"
  artifacts="$(find "$CASE" -name '*.md' -o -name 'progress-reports' -o -name 'mail.calls' -o -name 'gh.calls')"
  assert_eq "$RC|$(first_err)|$OUT|$artifacts" "2|oversee-report: summary-shape=$rule||" \
    "summary $name refuses without rendering, writing a report or sending a notice"
  # One must-fail control per rule, on the row whose name is the rule.
  if [[ "$name" == "$rule" ]]; then
    mutant="$(mutant_scripts "shape-$name/orch" oversee-report)/oversee-report" || exit 1
    ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/shape-$name/github"
    case "$rule" in
      bare-id) old='if (bare) print "bare-id"'; new='if (0 && bare) print "bare-id"' ;;
      github-link) old='else if (github) print "github-link"'; new='else if (0 && github) print "github-link"' ;;
      waiting-on-you) old='else if (!waiting) print "waiting-on-you"'; new='else if (0 && !waiting) print "waiting-on-you"' ;;
      label-spacing) old='else if (spacing) print "label-spacing"'; new='else if (0 && spacing) print "label-spacing"' ;;
      line-cap) old='else if (NR > cap) print "line-cap"'; new='else if (0 && NR > cap) print "line-cap"' ;;
      *) echo "oversee_report: fixture-rule=$rule" >&2; exit 1 ;;
    esac
    mutate_file "$mutant" "$old" "$new"
    REPORT_UNDER_TEST="$mutant" run ${envs[@]+"${envs[@]}"} -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt"
    assert_eq "$RC|$(first_err)" "0|oversee-report: report-written=$CASE/progress-reports/${NAME%-succession.md}.md notice-id=notice-1" \
      "control: removing $rule lets its defective summary write, reddening the refusal check"
  fi
done <<'ROWS'
bare-id~KEN-42 is ready.~normal~~bare-id
bare-pr~The change (#42) is ready.~normal~~bare-id
markdown-id~[KEN-42](https://linear.app/vanillagreen/issue/KEN-42) is ready.~normal~~bare-id
github-link~See <https://github.com/owner/repo/pull/42|the change>.~normal~~github-link
commit-link~See https://github.com/owner/repo/commit/abcdef.~normal~~github-link
waiting-on-you~Work continues.~missing~~waiting-on-you
label-spacing~Work continues.~spacing~~label-spacing
line-cap~Work continues.~long~~line-cap
custom-cap~Work continues.~normal~ORCH_REPORT_SUMMARY_LINES=12~line-cap
first-failure~KEN-42: https://github.com/owner/repo/pull/42~missing~~bare-id
ROWS
new_case summary_at_cap
fleet ''
printf 'The fix shipped (<https://linear.app/vanillagreen/issue/KEN-42|KEN-42>).\n%s\nDetail.\nDetail.\n\n\n' "$OWNER_ROWS" > "$CASE/summary.txt"
run -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt"
assert_eq "$RC" "0" "mrkdwn links and a summary at the default cap write; trailing blanks do not count"
new_case summary_custom_cap
fleet ''
printf 'Work continues.\n%s\nDetail.\nDetail.\nDetail.\n' "$OWNER_ROWS" > "$CASE/summary.txt"
run ORCH_REPORT_SUMMARY_LINES=16 -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt"
assert_eq "$RC" "0" "a configured cap above the default allows its boundary"
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
run ORCH_REPORT_EVERY_ISSUES=2 -- due --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$OUT" "0|report-due reason=issues since=$(at -60) landed=2" "due, two items landed reach ORCH_REPORT_EVERY_ISSUES=2"
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

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
