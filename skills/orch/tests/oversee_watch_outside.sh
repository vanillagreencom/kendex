#!/usr/bin/env bash
# oversee-watch outside-contribution events: which open issues and pull
# requests are outside the fleet, that each is reported once and a pull request
# again on a new head, what turns the check off, and what it refuses to run on.
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

# item NUMBER LOGIN TYPE ASSOCIATION [pr] — one issues-endpoint row; `pr` marks
# the pull request the issues endpoint lists beside the issues.
item() {
  local pr=""
  [[ "${5:-}" != pr ]] || pr=',"pull_request":{"url":"x"}'
  printf '{"number":%s,"user":{"login":"%s","type":"%s"},"author_association":"%s"%s}' "$1" "$2" "$3" "$4" "$pr"
}
# pull NUMBER LOGIN TYPE ASSOCIATION HEAD — one pulls-endpoint row.
pull() {
  printf '{"number":%s,"user":{"login":"%s","type":"%s"},"author_association":"%s","head":{"sha":"%s"}}' "$1" "$2" "$3" "$4" "$5"
}

HEAD_A="$(printf 'a%.0s' {1..40})"
HEAD_B="$(printf 'b%.0s' {1..40})"
OUTSIDE_PR="$(pull 3100 giladbarnea User CONTRIBUTOR "$HEAD_A")"
OUTSIDE_PR_PUSHED="$(pull 3100 giladbarnea User CONTRIBUTOR "$HEAD_B")"
OUTSIDE_PR_LISTED="$(item 3100 giladbarnea User CONTRIBUTOR pr)"
OUTSIDE_ISSUE="$(item 3101 giladbarnea User NONE)"
LANES_PR="$(pull 3134 vanillagreen-fleet-lanes[bot] Bot CONTRIBUTOR "$HEAD_A")"
OWNER_PR="$(pull 3130 bmethod User COLLABORATOR "$HEAD_A")"
MEMBER_ISSUE="$(item 3129 teammate User MEMBER)"
OWNER_ISSUE="$(item 3128 founder User OWNER)"
PR_EVENT="EVENT outside-contribution owner/repo#3100 kind=pr author=giladbarnea"
PRIVATE_MEMBER_ISSUE="$(item 3127 bmethod User CONTRIBUTOR)"
PRIVATE_MEMBER_PR="$(pull 3126 bmethod User CONTRIBUTOR "$HEAD_A")"
READER_ISSUE="$(item 3125 reader User CONTRIBUTOR)"
NEWCOMER_ISSUE="$(item 3124 newcomer User NONE)"
READER_EVENTS="EVENT outside-contribution owner/repo#3125 kind=issue author=reader
EVENT outside-contribution owner/repo#3124 kind=issue author=newcomer"

# outside_mutant NAME OLD NEW — a watch whose outside-contribution library has
# OLD replaced by NEW; MUTANT_BIN is its oversee-watch.
outside_mutant() {
  local dir="$TMP_ROOT/$1" lib
  lib="$(mutant_scripts "$1/orch" lib/outside-contribution.sh)/lib/outside-contribution.sh" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$dir/github"
  mutate_file "$lib" "$2" "$3"
  MUTANT_BIN="$dir/orch/scripts/oversee-watch"
}

# Cases that turn on the permission read: a private organization member, whom
# the app's token reads as CONTRIBUTOR, holding admin; two authors with read
# alone; and a read that fails. Each takes the watch to run as its argument.
case_private_member() { # WATCH
  new_case outside_private_member
  printf '[%s]\n' "$PRIVATE_MEMBER_PR" > "$STUB_DIR/pulls.json"
  printf '[%s]\n' "$PRIVATE_MEMBER_ISSUE" > "$STUB_DIR/issues.json"
  printf 'admin\n' > "$STUB_DIR/permission.bmethod.txt"
  WATCH_BIN="$1" run --
}
case_readers() { # WATCH
  new_case outside_readers
  printf '[%s,%s]\n' "$READER_ISSUE" "$NEWCOMER_ISSUE" > "$STUB_DIR/issues.json"
  printf 'read\n' > "$STUB_DIR/permission.reader.txt"
  printf 'read\n' > "$STUB_DIR/permission.newcomer.txt"
  WATCH_BIN="$1" run --
}
case_permission_failed() { # WATCH
  new_case outside_permission_failed
  printf '[%s]\n' "$READER_ISSUE" > "$STUB_DIR/issues.json"
  printf 'gh: Server Error (HTTP 502)\n' > "$STUB_DIR/permission.reader.err"
  WATCH_BIN="$1" run --
}
PERMISSION_FAILED='oversee-watch: outside-list-failed repo=owner/repo list=collaborator-permission login=reader exit=1'

echo "=== oversee-watch outside contributions ==="

# One outside pull request and one outside issue print one event each, pull
# requests first, and end the run as news: no heartbeat follows them. The pull
# request the issues endpoint also lists is not a second event, and the next
# pass reports neither.
new_case outside_once
printf '[%s]\n' "$OUTSIDE_PR" > "$STUB_DIR/pulls.json"
printf '[%s,%s]\n' "$OUTSIDE_PR_LISTED" "$OUTSIDE_ISSUE" > "$STUB_DIR/issues.json"
run --
assert_eq "$RC|$(events)|$(grep -c '^EVENT heartbeat' <<<"$OUT" || true)" \
  "0|$PR_EVENT head=$HEAD_A
EVENT outside-contribution owner/repo#3101 kind=issue author=giladbarnea|0" \
  "an outside pull request and an outside issue are one event each, and the run ends on them" "$ERR"
run --
assert_eq "$RC|$(events)|$(head -n 1 <<<"$OUT")" "0|none|$HEARTBEAT" \
  "a pull request or issue already reported, on the same head, is not a second event" "$ERR"

# A push moves the listed head: the pull request is reported once more, on the
# new head, and not again while that head stands.
new_case outside_pushed
printf '[%s]\n' "$OUTSIDE_PR" > "$STUB_DIR/pulls.json"
run --
printf '[%s]\n' "$OUTSIDE_PR_PUSHED" > "$STUB_DIR/pulls.json"
run --
assert_eq "$RC|$(events)" "0|$PR_EVENT head=$HEAD_B" \
  "a pull request whose head moved is reported again with the new head" "$ERR"
run --
assert_eq "$RC|$(events)" "0|none" "the moved head is reported once" "$ERR"

# Control: every fleet identity prints nothing, the lanes app first among them.
for row in \
  "a lanes-app pull request prints nothing|pulls|$LANES_PR" \
  "the owner's collaborator pull request prints nothing|pulls|$OWNER_PR" \
  "an organization member's issue prints nothing|issues|$MEMBER_ISSUE" \
  "the repository owner's issue prints nothing|issues|$OWNER_ISSUE"; do
  IFS='|' read -r label list body <<<"$row"
  new_case outside_fleet
  printf '[%s]\n' "$body" > "$STUB_DIR/$list.json"
  run --
  assert_eq "$RC|$(events)|$(head -n 1 <<<"$OUT")" "0|none|$HEARTBEAT" "control: $label" "$ERR"
done

# A CONTRIBUTOR whose permission on the repository is admin, a private
# organization member as the app's token reads one, is fleet: neither the pull
# request nor the issue prints, and the login is read once in the pass.
case_private_member ""
assert_eq "$RC|$(events)|$(head -n 1 <<<"$OUT")|$(grep -c '^api repos/owner/repo/collaborators/bmethod/permission ' "$STUB_DIR/gh.calls" || true)" \
  "0|none|$HEARTBEAT|1" "a CONTRIBUTOR author with admin permission is fleet, read once per pass" "$ERR"

# CONTRIBUTOR and NONE authors whose permission is read are still outside.
case_readers ""
assert_eq "$RC|$(events)" "0|$READER_EVENTS" \
  "CONTRIBUTOR and NONE authors with read permission are reported" "$ERR"

# A permission read that fails is not a verdict: the pass exits as a failed
# list does, naming the login and GitHub's words.
case_permission_failed ""
assert_eq "$RC|$(events)|$(grep -c "$PERMISSION_FAILED" "$ERR" || true)|$(grep -c 'HTTP 502' "$ERR" || true)" \
  "2|none|1|1" "a failed permission read exits 2 naming the repository, the login and GitHub's words" "$ERR"

# An item that closes leaves the list and its row with it, so the same number
# reopened is news again.
new_case outside_reopened
printf '[%s]\n' "$OUTSIDE_PR" > "$STUB_DIR/pulls.json"
run --
printf '[]\n' > "$STUB_DIR/pulls.json"
run --
printf '[%s]\n' "$OUTSIDE_PR" > "$STUB_DIR/pulls.json"
run --
assert_eq "$RC|$(events)" "0|$PR_EVENT head=$HEAD_A" \
  "a pull request closed and reopened is reported again" "$ERR"

# Every --repo is read for pull requests; issues are read in the first alone.
new_case outside_second_repo
printf '[%s]\n' "$(pull 7 visitor User FIRST_TIME_CONTRIBUTOR "$HEAD_B")" > "$STUB_DIR/pulls.owner_other.json"
printf '[%s]\n' "$(item 8 visitor User NONE)" > "$STUB_DIR/issues.owner_other.json"
run -- --repo owner/repo --repo owner/other
assert_eq "$RC|$(events)|$(grep -c 'repos/owner/other/issues' "$STUB_DIR/gh.calls" || true)" \
  "0|EVENT outside-contribution owner/other#7 kind=pr author=visitor head=$HEAD_B|0" \
  "a second repository's outside pull request is reported and its issues are not read" "$ERR"

# A deleted account has no user: it is outside, under GitHub's ghost name.
new_case outside_ghost
printf '[{"number":5,"user":null,"author_association":"NONE"}]\n' > "$STUB_DIR/issues.json"
run --
assert_eq "$RC|$(events)" "0|EVENT outside-contribution owner/repo#5 kind=issue author=ghost" \
  "an item whose author account was deleted is outside" "$ERR"

# The setting: off lists nothing and makes no call; any other value is refused.
new_case outside_off
printf '[%s]\n' "$OUTSIDE_PR" > "$STUB_DIR/pulls.json"
run ORCH_EXTERNAL_TRIAGE=off --
assert_eq "$RC|$(events)|$(grep -cE 'api --paginate repos/[^ ]+/(pulls|issues)\?' "$STUB_DIR/gh.calls" || true)" "0|none|0" \
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
assert_eq "$RC|$(grep -c 'oversee-watch: outside-list-failed repo=owner/repo list=issues exit=1' "$ERR" || true)|$(grep -c 'HTTP 502' "$ERR" || true)" \
  "2|1|1" "a failed issue list exits 2 naming the repository, the list and GitHub's words" "$ERR"
for row in \
  "a list line with no whole number is refused|$(pull '"12; rm"' x User NONE "$HEAD_A")" \
  "a pull request line with no head commit is refused|$(pull 12 x User NONE '')"; do
  IFS='|' read -r label body <<<"$row"
  new_case outside_list_invalid
  printf '[%s]\n' "$body" > "$STUB_DIR/pulls.json"
  run --
  assert_eq "$RC|$(events)|$(grep -c 'oversee-watch: outside-list-invalid repo=owner/repo list=pulls' "$ERR" || true)" \
    "2|none|1" "$label" "$ERR"
done

# Must-fail control: with the baseline row read dropped, the second pass
# reports the same pull request again.
outside_mutant outside-mutant '[[ "$prior" != "$value" ]] || continue' ':'
new_case outside_mutant
printf '[%s]\n' "$OUTSIDE_PR" > "$STUB_DIR/pulls.json"
WATCH_BIN="$MUTANT_BIN" run --
WATCH_BIN="$MUTANT_BIN" run --
assert_eq "$(events)" "$PR_EVENT head=$HEAD_A" \
  "control: without the baseline read the second pass reports the same pull request again" "$ERR"

# Must-fail controls for the permission read, one per rule.
outside_mutant outside-mutant-no-permission '! outside_author_is_fleet "$repo" "$login" || continue' ':'
case_private_member "$MUTANT_BIN"
assert_eq "$RC|$(events)" "0|EVENT outside-contribution owner/repo#3126 kind=pr author=bmethod head=$HEAD_A
EVENT outside-contribution owner/repo#3127 kind=issue author=bmethod" \
  "control: without the permission read the admin CONTRIBUTOR is reported" "$ERR"
outside_mutant outside-mutant-read-fleet 'admin | maintain | write)' 'admin | maintain | write | read)'
case_readers "$MUTANT_BIN"
assert_eq "$RC|$(events)" "0|none" \
  "control: with read counted as fleet the read-permission authors are not reported" "$ERR"
outside_mutant outside-mutant-failure-404 "grep -q '(HTTP 404)' \"\$errf\"" 'true'
case_permission_failed "$MUTANT_BIN"
assert_eq "$RC|$(events)" "0|EVENT outside-contribution owner/repo#3125 kind=issue author=reader" \
  "control: a failed read taken as a 404 reports the author as outside instead of exiting" "$ERR"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
