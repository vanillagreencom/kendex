#!/usr/bin/env bash
# oversee-watch outside-contribution events: which open issues and pull
# requests are outside the fleet, that each is reported once, what turns the
# check off, and what it refuses to run on.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"

HEARTBEAT="EVENT heartbeat loops=1 interval=0s since=none"

# run [ENV=VAL ...] -- ARGS... — one single-loop watch run; OUT, RC and ERR (a
# file) are what the checks read.
RUN_SEQ=0
run() {
  ERR="$TMP_ROOT/run-$((++RUN_SEQ)).err"
  OUT="$(run_watch "$@" --max-loops 1 2>"$ERR")" && RC=0 || RC=$?
}

# events — the run's outside-contribution lines, one per line, or `none`.
events() {
  local got
  got="$(grep '^EVENT outside-contribution ' <<<"$OUT" || true)"
  printf '%s' "${got:-none}"
}

# item NUMBER LOGIN TYPE ASSOCIATION [pr] — one issues-endpoint row.
item() {
  local pr=""
  [[ "${5:-}" != pr ]] || pr=',"pull_request":{"url":"x"}'
  printf '{"number":%s,"user":{"login":"%s","type":"%s"},"author_association":"%s"%s}' "$1" "$2" "$3" "$4" "$pr"
}

OUTSIDE_PR="$(item 3100 giladbarnea User CONTRIBUTOR pr)"
OUTSIDE_ISSUE="$(item 3101 giladbarnea User NONE)"
LANES_PR="$(item 3134 vanillagreen-fleet-lanes[bot] Bot CONTRIBUTOR pr)"
OWNER_PR="$(item 3130 bmethod User COLLABORATOR pr)"
MEMBER_ISSUE="$(item 3129 teammate User MEMBER)"
OWNER_ISSUE="$(item 3128 founder User OWNER)"

echo "=== oversee-watch outside contributions ==="

# One outside pull request and one outside issue print one event each, in the
# order the list gives them, and the next pass reports neither.
new_case outside_once
printf '[%s,%s]\n' "$OUTSIDE_PR" "$OUTSIDE_ISSUE" > "$STUB_DIR/issues.json"
run --
assert_eq "$RC|$(events)" \
  "0|EVENT outside-contribution owner/repo#3100 kind=pr author=giladbarnea
EVENT outside-contribution owner/repo#3101 kind=issue author=giladbarnea" \
  "an outside pull request and an outside issue are one event each" "$ERR"
run --
assert_eq "$RC|$(events)|$(head -n 1 <<<"$OUT")" "0|none|$HEARTBEAT" \
  "a pull request or issue already reported is not a second event" "$ERR"

# Control: every fleet identity prints nothing, the lanes app first among them.
for row in \
  "a lanes-app pull request prints nothing|$LANES_PR" \
  "the owner's collaborator pull request prints nothing|$OWNER_PR" \
  "an organization member's issue prints nothing|$MEMBER_ISSUE" \
  "the repository owner's issue prints nothing|$OWNER_ISSUE"; do
  IFS='|' read -r label body <<<"$row"
  new_case outside_fleet
  printf '[%s]\n' "$body" > "$STUB_DIR/issues.json"
  run --
  assert_eq "$RC|$(events)|$(head -n 1 <<<"$OUT")" "0|none|$HEARTBEAT" "control: $label" "$ERR"
done

# An item that closes leaves the list and its row with it, so the same number
# reopened is news again.
new_case outside_reopened
printf '[%s]\n' "$OUTSIDE_PR" > "$STUB_DIR/issues.json"
run --
printf '[]\n' > "$STUB_DIR/issues.json"
run --
printf '[%s]\n' "$OUTSIDE_PR" > "$STUB_DIR/issues.json"
run --
assert_eq "$RC|$(events)" "0|EVENT outside-contribution owner/repo#3100 kind=pr author=giladbarnea" \
  "a pull request closed and reopened is reported again" "$ERR"

# Every --repo is read for pull requests; issues are read in the first alone.
new_case outside_second_repo
printf '[]\n' > "$STUB_DIR/issues.owner_repo.json"
printf '[%s,%s]\n' "$(item 7 visitor User FIRST_TIME_CONTRIBUTOR pr)" "$(item 8 visitor User NONE)" \
  > "$STUB_DIR/issues.owner_other.json"
run -- --repo owner/repo --repo owner/other
assert_eq "$RC|$(events)" "0|EVENT outside-contribution owner/other#7 kind=pr author=visitor" \
  "a second repository's outside pull request is reported and its outside issue is not" "$ERR"

# A deleted account has no user: it is outside, under GitHub's ghost name.
new_case outside_ghost
printf '[{"number":5,"user":null,"author_association":"NONE"}]\n' > "$STUB_DIR/issues.json"
run --
assert_eq "$RC|$(events)" "0|EVENT outside-contribution owner/repo#5 kind=issue author=ghost" \
  "an item whose author account was deleted is outside" "$ERR"

# The setting: off lists nothing and makes no call; any other value is refused.
new_case outside_off
printf '[%s]\n' "$OUTSIDE_PR" > "$STUB_DIR/issues.json"
run ORCH_EXTERNAL_TRIAGE=off --
assert_eq "$RC|$(events)|$(grep -c 'api --paginate' "$STUB_DIR/gh.calls" || true)" "0|none|0" \
  "ORCH_EXTERNAL_TRIAGE=off lists nothing" "$ERR"
new_case outside_setting_invalid
run ORCH_EXTERNAL_TRIAGE=yes --
assert_eq "$RC|${OUT:-empty}|$(grep -c 'oversee-watch: external-triage-invalid setting=ORCH_EXTERNAL_TRIAGE value=yes' "$ERR" || true)" \
  "2|empty|1" "an ORCH_EXTERNAL_TRIAGE value other than on or off is refused" "$ERR"

# Refusals: a failed list and a line the check cannot read are unknown state,
# never an empty one.
new_case outside_list_failed
touch "$STUB_DIR/issues-fail"
run --
assert_eq "$RC|$(grep -c 'oversee-watch: outside-list-failed repo=owner/repo exit=1' "$ERR" || true)|$(grep -c 'HTTP 502' "$ERR" || true)" \
  "2|1|1" "a failed issue list exits 2 naming the repository and GitHub's words" "$ERR"
new_case outside_list_invalid
printf '[{"number":"12; rm","user":{"login":"x","type":"User"},"author_association":"NONE"}]\n' > "$STUB_DIR/issues.json"
run --
assert_eq "$RC|$(events)|$(grep -c 'oversee-watch: outside-list-invalid repo=owner/repo' "$ERR" || true)" \
  "2|none|1" "a list line with no whole number is refused" "$ERR"

# Must-fail control: with the baseline row read dropped, the second pass
# reports the same pull request again.
MUTANT_DIR="$TMP_ROOT/outside-mutant"
MUTANT_LIB="$(mutant_scripts outside-mutant/orch lib/outside-contribution.sh)/lib/outside-contribution.sh" || exit 1
ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
mutate_file "$MUTANT_LIB" '[[ -z "$prior" ]] || continue' ':'
new_case outside_mutant
printf '[%s]\n' "$OUTSIDE_PR" > "$STUB_DIR/issues.json"
WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run --
WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run --
assert_eq "$(events)" "EVENT outside-contribution owner/repo#3100 kind=pr author=giladbarnea" \
  "control: without the baseline read the second pass reports the same pull request again" "$ERR"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
