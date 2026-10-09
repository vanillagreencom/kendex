#!/usr/bin/env bash
# overseer-approve against a fake GitHub API: the approval call's shape, the
# head-prefix refusal, the credential refusal, and that the token never shows.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$TEST_DIR/../../.." && pwd -P)"
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/growth-state.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'overseer_approve: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "overseer_approve: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'overseer_approve: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

TOKEN=ghs_fixtureOverseerReviewToken
GIVEN=0123456789abcdef0123456789abcdef01234567
MOVED=fedcba9876543210fedcba9876543210fedcba98
PREFIX_MOVED=01234567fedcba9876543210fedcba9876543210
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/home" "$TMP_ROOT/cwd"
printf '%s\n' "$TOKEN" > "$TMP_ROOT/token"
: > "$TMP_ROOT/token-empty"
printf '%s\nsecond\n' "$TOKEN" > "$TMP_ROOT/token-two-lines"
printf 'Each decline holds.\n"Quoted" line\n' > "$TMP_ROOT/body"
CALLS="$TMP_ROOT/calls"
INPUT="$TMP_ROOT/input"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"
CHECK_READS="$TMP_ROOT/check-reads"
HEAD_READS="$TMP_ROOT/head-reads"
CLOCK="$TMP_ROOT/clock"
SLEEPS="$TMP_ROOT/sleeps"

# One `<GH_TOKEN>|<argv>` line per call; the POST's stdin is kept whole.
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s\n' "${GH_TOKEN:-}" "$*" >> "$CALLS"
case "$*" in
  'api repos/o/r/commits/'*'/check-runs?filter=all&per_page=100 --paginate --slurp')
    [[ "$*" == "api repos/o/r/commits/$LIVE_HEAD/check-runs?filter=all&per_page=100 --paginate --slurp" ]] || exit 9
    count="$(cat "$CHECK_READS")"
    count=$((count + 1))
    printf '%s\n' "$count" > "$CHECK_READS"
    state=in_progress
    started='"2026-10-09T06:41:20Z"'
    case "$CHECK_MODE" in
      completed) state=completed ;;
      finishing) [[ "$count" -eq 1 ]] || state=completed ;;
      queued) state=queued; started=null; [[ "$count" -eq 1 ]] || state=completed ;;
      failed) echo 'gh: Resource not accessible by integration (HTTP 403)' >&2; exit 1 ;;
      later-failed) [[ "$count" -eq 1 ]] || { echo 'gh: Forbidden (HTTP 403)' >&2; exit 1; } ;;
      empty) :; exit 0 ;;
      malformed) echo '[{"check_runs":null}]'; exit 0 ;;
      invalid-json) echo 'invalid JSON'; exit 0 ;;
    esac
    # The in-flight run is on a later page, after an unrelated active check
    # and an earlier completed Copilot attempt. The reader must see them all.
    printf '[{"check_runs":[{"name":"CI","status":"in_progress"},{"name":"copilot-pull-request-reviewer","id":71,"status":"completed"}]},{"check_runs":[{"name":"copilot-pull-request-reviewer","id":72,"status":"%s","started_at":%s}]}]\n' "$state" "$started"
    ;;
  'api repos/o/r/pulls/42 --jq .head.sha')
    count="$(cat "$HEAD_READS")"
    count=$((count + 1))
    printf '%s\n' "$count" > "$HEAD_READS"
    head="$LIVE_HEAD"
    [[ "$count" -eq 1 ]] || head="$AFTER_HOLD_HEAD"
    if [[ $head == fail ]]; then echo 'gh: Not Found (HTTP 404)' >&2; exit 1; fi
    echo "$head"
    ;;
  'api --method POST repos/o/r/pulls/42/reviews --input -')
    cat > "$INPUT"
    case "$POST" in
      ok) printf '{"state":"APPROVED","user":{"login":"vanillagreen-overseer[bot]"},"commit_id":"%s"}\n' "$LIVE_HEAD" ;;
      unreadable) echo '{}' ;;
      refused*)
        echo '{"message":"Unprocessable Entity"}'
        echo 'gh: Unprocessable Entity (HTTP 422)' >&2
        exit 1
        ;;
    esac
    ;;
  'api repos/o/r/pulls/42/reviews --paginate --slurp')
    case "$POST" in
      refused-approved) printf '[[{"state":"COMMENTED"}],[{"state":"APPROVED","user":{"login":"review-app[bot]"},"commit_id":"%s"}]]\n' "$LIVE_HEAD" ;;
      refused-other-app) printf '[[{"state":"APPROVED","user":{"login":"other-app[bot]"},"commit_id":"%s"}]]\n' "$LIVE_HEAD" ;;
      refused-old-head) echo '[[{"state":"APPROVED","user":{"login":"review-app[bot]"},"commit_id":"old"}]]' ;;
      refused-commented) printf '[[{"state":"COMMENTED","user":{"login":"review-app[bot]"},"commit_id":"%s"}]]\n' "$LIVE_HEAD" ;;
      refused-read-failed) echo 'gh: Forbidden (HTTP 403)' >&2; exit 1 ;;
      refused-unreadable) echo 'invalid JSON' ;;
      refused-wrong-shape) echo '[{}]' ;;
      refused-empty) : ;;
      *) echo '[[]]' ;;
    esac
    ;;
  *) printf 'gh: unexpected argv=%s\n' "$*" >&2; exit 9 ;;
esac
EOF
chmod +x "$TMP_ROOT/bin/gh"

# Inject the clock through executable fixtures. No real wait decides a row.
cat > "$TMP_ROOT/bin/date" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == +%s ]] || exit 9
cat "$CLOCK"
EOF
cat > "$TMP_ROOT/bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >> "$SLEEPS"
now="$(cat "$CLOCK")"
printf '%s\n' "$((now + $1))" > "$CLOCK"
EOF
chmod +x "$TMP_ROOT/bin/date" "$TMP_ROOT/bin/sleep"

run_approve() { # SCRIPT TOKEN_FILE LIVE_HEAD POST ARGS...
  local script="$1" token_file="$2" live="$3" post="$4" setting=()
  shift 4
  [[ -z "$token_file" ]] || setting=("ORCH_OVERSEER_REVIEW_TOKEN_FILE=$token_file")
  : > "$CALLS"
  printf '0\n' > "$CHECK_READS"
  printf '0\n' > "$HEAD_READS"
  printf '0\n' > "$CLOCK"
  : > "$SLEEPS"
  rm -f -- "$INPUT"
  RC=0
  (cd -- "$TMP_ROOT/cwd" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT/home" \
    ${setting[@]+"${setting[@]}"} \
    CALLS="$CALLS" INPUT="$INPUT" LIVE_HEAD="$live" POST="$post" \
    CHECK_MODE="${CHECK_MODE-finishing}" CHECK_READS="$CHECK_READS" \
    HEAD_READS="$HEAD_READS" AFTER_HOLD_HEAD="${AFTER_HOLD_HEAD-$live}" \
    CLOCK="$CLOCK" SLEEPS="$SLEEPS" ORCH_COPILOT_HOLD_SECS="${HOLD_SECS-600}" \
    ORCH_OVERSEER_REVIEW_LOGIN="${REVIEW_LOGIN-review-app[bot]}" \
    "$BASH" "$script" "$@" > "$OUT" 2> "$ERR") || RC=$?
  STDERR_KEY="$(sed -n 1p "$ERR")"
  NCALLS="$(wc -l < "$CALLS" | tr -d ' ')"
}

RUN="$REPO_ROOT/skills/orch/scripts/overseer-approve"
SUPPLIER="the control VM for a hosted overseer, the fleet worker on the owner's machine for a local one"
APPROVE=(42 "$GIVEN" --body-file "$TMP_ROOT/body" --repo o/r)

run_approve "$RUN" "$TMP_ROOT/token" "$GIVEN" ok "${APPROVE[@]}"
assert_eq "$RC|$(cat "$OUT")" "0|APPROVED vanillagreen-overseer[bot] 0123456" \
  'approval prints state, login and short commit' "$ERR"
assert_eq "$(cat "$CALLS")" "$TOKEN|api repos/o/r/pulls/42 --jq .head.sha
$TOKEN|api --method POST repos/o/r/pulls/42/reviews --input -" \
  'live head read then one POST to the reviews path, both with the file token' "$ERR"
assert_eq "$(jq -c . "$INPUT")" \
  "$(jq -cn --arg sha "$GIVEN" '{commit_id: $sha, event: "APPROVE", body: "Each decline holds.\n\"Quoted\" line\n"}')" \
  'the review binds the given commit, APPROVE and the body text' "$ERR"
assert_not_contains "$(cat "$OUT" "$ERR")" "$TOKEN" 'approval prints no token'

# label | check response sequence | flag | bound | exit | POST | read count | final key
while IFS='|' read -r label mode flag bound want_rc want_post want_reads want_key; do
  CHECK_MODE="$mode" HOLD_SECS="$bound"
  flags=()
  [[ "$flag" != yes ]] || flags=(--hold-copilot)
  run_approve "$RUN" "$TMP_ROOT/token" "$GIVEN" ok "${APPROVE[@]}" ${flags[@]+"${flags[@]}"}
  posted=no
  [[ ! -f "$INPUT" ]] || posted=yes
  last_key="$(sed -n 's/^overseer-approve: \([^ ]*\).*/\1/p' "$ERR" | tail -1)"
  assert_eq "$RC|$posted|$(cat "$CHECK_READS")|$last_key" \
    "$want_rc|$want_post|$want_reads|$want_key" "$label" "$ERR"
  assert_not_contains "$(cat "$OUT" "$ERR")" "$TOKEN" "$label prints no token"
  if [[ "$want_post" == yes ]]; then
    assert_eq "$(jq -r .commit_id "$INPUT")" "$GIVEN" "$label binds the live head" "$ERR"
  fi
done <<'EOF'
in-progress run completes|finishing|yes|600|5|no|2|copilot-finished
queued run completes|queued|yes|600|5|no|2|copilot-finished
run outlasts bound|running|yes|3|0|yes|2|copilot-hold-expired
run completes at bound|finishing|yes|10|0|yes|2|copilot-hold-expired
flag absent during run|running|no|3|0|yes|0|
read forbidden|failed|yes|600|1|no|1|copilot-read-failed
later read forbidden|later-failed|yes|600|1|no|2|copilot-read-failed
empty response|empty|yes|600|1|no|1|copilot-read-failed
malformed page|malformed|yes|600|1|no|1|copilot-read-failed
invalid JSON|invalid-json|yes|600|1|no|1|copilot-read-failed
already completed|completed|yes|600|0|yes|1|
invalid bound|running|yes|invalid|1|no|0|copilot-hold-setting
zero bound|running|yes|0|1|no|0|copilot-hold-setting
EOF
unset CHECK_MODE HOLD_SECS

# A review-fix push can change the head during the hold. A caller's short
# prefix must still bind the full initial head when expiry permits approval.
CHECK_MODE=running HOLD_SECS=3
while IFS='|' read -r label after_head given_head want_rc want_key; do
  AFTER_HOLD_HEAD="$after_head"
  run_approve "$RUN" "$TMP_ROOT/token" "$GIVEN" ok 42 "$given_head" \
    --body-file "$TMP_ROOT/body" --repo o/r --hold-copilot
  posted=no
  [[ ! -f "$INPUT" ]] || posted=yes
  last_key="$(sed -n 's/^overseer-approve: \([^ ]*\).*/\1/p' "$ERR" | tail -1)"
  assert_eq "$RC|$posted|$(cat "$HEAD_READS")|$last_key" \
    "$want_rc|no|2|$want_key" "$label" "$ERR"
  assert_eq "$(cat "$SLEEPS")" 3 "$label follows the expired hold" "$ERR"
done <<EOF
head moved during hold|$MOVED|$GIVEN|4|head-moved
same prefix moved during hold|$PREFIX_MOVED|${GIVEN:0:8}|4|head-moved
head reread failed|fail|$GIVEN|1|head-read-failed
EOF
assert_contains "$(cat "$ERR")" 'gh: Not Found (HTTP 404)' 'failed reread keeps the API error' "$ERR"
unset CHECK_MODE HOLD_SECS AFTER_HOLD_HEAD

CHECK_MODE=finishing
run_approve "$RUN" "$TMP_ROOT/token" "$GIVEN" ok "${APPROVE[@]}" --hold-copilot
assert_eq "$STDERR_KEY" \
  "overseer-approve: copilot-in-flight pr=42 repo=o/r head=$GIVEN run=72 started_at=2026-10-09T06:41:20Z" \
  'hold notice identifies the later-page active run' "$ERR"
assert_eq "$(cat "$SLEEPS")" 10 'the hold polls at its fixed interval' "$ERR"
assert_eq "$(sed -n 2p "$CALLS")" \
  "$TOKEN|api repos/o/r/commits/$GIVEN/check-runs?filter=all&per_page=100 --paginate --slurp" \
  'the check-run read uses the approval token and full live head' "$ERR"
CHECK_MODE=queued
run_approve "$RUN" "$TMP_ROOT/token" "$GIVEN" ok "${APPROVE[@]}" --hold-copilot
assert_eq "${STDERR_KEY##* started_at=}" none 'queued work can have no start time' "$ERR"
CHECK_MODE=running HOLD_SECS=3
run_approve "$RUN" "$TMP_ROOT/token" "$GIVEN" ok "${APPROVE[@]}" --hold-copilot
assert_eq "$(cat "$SLEEPS")|$(sed -n 2p "$ERR")" \
  "3|overseer-approve: copilot-hold-expired pr=42 repo=o/r head=$GIVEN run=72 waited=3" \
  'expiry names the held run and measured duration' "$ERR"
assert_eq "$(cat "$HEAD_READS")|$(sed -n 4p "$CALLS")" \
  "2|$TOKEN|api repos/o/r/pulls/42 --jq .head.sha" \
  'expiry rereads the full live head with the approval token before POST' "$ERR"
CHECK_MODE=failed HOLD_SECS=600
run_approve "$RUN" "$TMP_ROOT/token" "$GIVEN" ok "${APPROVE[@]}" --hold-copilot
assert_contains "$(cat "$ERR")" 'gh: Resource not accessible by integration (HTTP 403)' \
  'a check-run read refusal keeps the API error' "$ERR"
unset CHECK_MODE HOLD_SECS

# pr-watch prints the head as 8 characters; the review binds the full live one.
run_approve "$RUN" "$TMP_ROOT/token" "$GIVEN" ok 42 "${GIVEN:0:8}" --body-file "$TMP_ROOT/body" --repo o/r
assert_eq "$RC|$NCALLS|$(cat "$OUT")" "0|2|APPROVED vanillagreen-overseer[bot] 0123456" \
  'an 8-character head approves' "$ERR"
assert_eq "$(jq -r .commit_id "$INPUT")" "$GIVEN" 'a prefix head posts the full live commit' "$ERR"

# label | token file | live head | post | head | rc | first stderr line | gh calls
while IFS='|' read -r label token_file live post head want_rc want_key want_calls; do
  [[ -n "$label" ]] || continue
  token_file="${token_file//@/$TMP_ROOT/}"
  run_approve "$RUN" "$token_file" "$live" "$post" 42 "$head" --body-file "$TMP_ROOT/body" --repo o/r
  assert_eq "$RC|$STDERR_KEY|$NCALLS|$(cat "$OUT")" "$want_rc|$want_key|$want_calls|" "$label" "$ERR"
  assert_not_contains "$(cat "$OUT" "$ERR")" "$TOKEN" "$label prints no token"
  [[ "$want_rc" != 3 ]] || assert_eq "$(sed -n 2p "$ERR")" \
    "The fleet supplies this token file: $SUPPLIER. It must hold one non-empty line, the overseer app's installation token. Nothing was posted." \
    "$label names the supplier" "$ERR"
done <<EOF
head moved|@token|$MOVED|ok|$GIVEN|4|overseer-approve: head-moved pr=42 given=$GIVEN live=$MOVED|1
prefix head moved|@token|$MOVED|ok|${GIVEN:0:8}|4|overseer-approve: head-moved pr=42 given=${GIVEN:0:8} live=$MOVED|1
head read failed|@token|fail|ok|$GIVEN|1|overseer-approve: head-read-failed pr=42 repo=o/r|1
live head not a sha|@token|${GIVEN}0|ok|$GIVEN|1|overseer-approve: head-read-failed pr=42 repo=o/r|1
token file unset||$GIVEN|ok|$GIVEN|3|overseer-approve: credential setting=ORCH_OVERSEER_REVIEW_TOKEN_FILE file=|0
token file missing|@missing|$GIVEN|ok|$GIVEN|3|overseer-approve: credential setting=ORCH_OVERSEER_REVIEW_TOKEN_FILE file=$TMP_ROOT/missing|0
token file empty|@token-empty|$GIVEN|ok|$GIVEN|3|overseer-approve: credential setting=ORCH_OVERSEER_REVIEW_TOKEN_FILE file=$TMP_ROOT/token-empty|0
token file two lines|@token-two-lines|$GIVEN|ok|$GIVEN|3|overseer-approve: credential setting=ORCH_OVERSEER_REVIEW_TOKEN_FILE file=$TMP_ROOT/token-two-lines|0
post refused|@token|$GIVEN|refused|$GIVEN|1|overseer-approve: post-failed pr=42 repo=o/r commit=$GIVEN|3
answer unreadable|@token|$GIVEN|unreadable|$GIVEN|1|overseer-approve: response-unread pr=42 repo=o/r commit=$GIVEN|2
EOF
run_approve "$RUN" "$TMP_ROOT/token" "$GIVEN" refused "${APPROVE[@]}"
assert_contains "$(cat "$ERR")" 'gh: Unprocessable Entity (HTTP 422)' 'a refused post prints GitHub'"'"'s message' "$ERR"

# The overseer consumes the state/login/commit line, even when POST failed.
# label | reviews response | rc | stdout | refusal key
while IFS='|' read -r label post want_rc want_out want_key; do
  run_approve "$RUN" "$TMP_ROOT/token" "$GIVEN" "$post" "${APPROVE[@]}"
  assert_eq "$RC|$(cat "$OUT")|${STDERR_KEY%% pr=*}" "$want_rc|$want_out|$want_key" "$label" "$ERR"
  assert_eq "$(sed -n 3p "$CALLS")" "$TOKEN|api repos/o/r/pulls/42/reviews --paginate --slurp" \
    "$label reads all review pages with the same token" "$ERR"
done <<EOF
approval despite HTTP 422|refused-approved|0|APPROVED review-app[bot] 0123456|
another app's approval|refused-other-app|1||overseer-approve: post-failed
approval on another head|refused-old-head|1||overseer-approve: post-failed
app comment only|refused-commented|1||overseer-approve: post-failed
reviews read failed|refused-read-failed|1||overseer-approve: read-back-failed
reviews unreadable|refused-unreadable|1||overseer-approve: read-back-failed
reviews wrong shape|refused-wrong-shape|1||overseer-approve: read-back-failed
reviews empty|refused-empty|1||overseer-approve: read-back-failed
EOF
REVIEW_LOGIN=""
run_approve "$RUN" "$TMP_ROOT/token" "$GIVEN" refused-approved "${APPROVE[@]}"
unset REVIEW_LOGIN
assert_eq "$RC|${STDERR_KEY%% pr=*}|$(cat "$OUT")" "1|overseer-approve: read-back-failed|" \
  'an unset app identity cannot confirm an approval' "$ERR"
run_approve "$RUN" "$TMP_ROOT/token" fail ok "${APPROVE[@]}"
assert_contains "$(cat "$ERR")" 'gh: Not Found (HTTP 404)' 'a failed head read prints gh'"'"'s words' "$ERR"

# label | args | rc | first stderr line
while IFS='|' read -r label args want_rc want_key; do
  [[ -n "$label" ]] || continue
  read -r -a argv <<<"${args//@/$TMP_ROOT/}"
  run_approve "$RUN" "$TMP_ROOT/token" "$GIVEN" ok "${argv[@]}"
  assert_eq "$RC|$STDERR_KEY|$NCALLS" "$want_rc|$want_key|0" "$label" "$ERR"
done <<EOF
hash pr number|#42 $GIVEN --body-file @body --repo o/r|2|overseer-approve: usage reason=pr-number value=#42
zero pr number|0 $GIVEN --body-file @body --repo o/r|2|overseer-approve: usage reason=pr-number value=0
six-character head|42 012345 --body-file @body --repo o/r|2|overseer-approve: usage reason=head-sha value=012345
41-character head|42 ${GIVEN}0 --body-file @body --repo o/r|2|overseer-approve: usage reason=head-sha value=${GIVEN}0
upper-case head|42 0123456789ABCDEF --body-file @body --repo o/r|2|overseer-approve: usage reason=head-sha value=0123456789ABCDEF
no body file|42 $GIVEN --repo o/r|2|overseer-approve: usage reason=missing-body-file value=
unreadable body file|42 $GIVEN --body-file @nobody --repo o/r|2|overseer-approve: body-file path=$TMP_ROOT/nobody
repo not owner/repo|42 $GIVEN --body-file @body --repo not-a-repo|1|overseer-approve: repo-shape repo=not-a-repo
EOF

# The settings loader's own words follow the keyed line, never precede it.
printf '[env]\nX = 1\n' > "$TMP_ROOT/cwd/kendex.settings.toml"
run_approve "$RUN" "$TMP_ROOT/token" "$GIVEN" ok "${APPROVE[@]}"
rm -- "${TMP_ROOT:?}/cwd/kendex.settings.toml"
assert_eq "$RC|$STDERR_KEY|$NCALLS" "1|overseer-approve: settings-load root=$TMP_ROOT/cwd|0" \
  'a malformed settings file refuses settings-load first' "$ERR"
assert_contains "$(sed -n '3,$p' "$ERR")" 'kendex-env: ' 'the loader'"'"'s words follow settings-load' "$ERR"

# Must-fail controls, each asserting what its mutant does, so a mutant that
# cannot start turns the suite red. Without the live-head check the moved
# head is approved; without the live-head shape check a junk head that
# starts with the given one passes the prefix check and is posted.
scripts="$(mutant_scripts mutant/orch overseer-approve)"
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/mutant/github"
mutate_file "$scripts/overseer-approve" \
  '[[ "$live" == "$expected"* ]] || refuse 4 head-moved' 'true || refuse 4 head-moved'
run_approve "$scripts/overseer-approve" "$TMP_ROOT/token" "$MOVED" ok "${APPROVE[@]}"
assert_eq "$RC|$NCALLS|$(cat "$OUT")" "0|2|APPROVED vanillagreen-overseer[bot] fedcba9" \
  'head-check control approves the moved head' "$ERR"

scripts="$(mutant_scripts mutant/orch overseer-approve)"
mutate_file "$scripts/overseer-approve" '|| ! "$live" =~ ^[0-9a-f]{40}$ ]]' ']]'
run_approve "$scripts/overseer-approve" "$TMP_ROOT/token" "${GIVEN}0" ok "${APPROVE[@]}"
assert_eq "$RC|$NCALLS|$(jq -r .commit_id "$INPUT")" "0|2|${GIVEN}0" \
  'head-shape control posts the junk head' "$ERR"

# Restore the previous failed-POST behavior in a disposable copy.
scripts="$(mutant_scripts mutant/orch overseer-approve)"
mutate_file "$scripts/overseer-approve" \
  '  if ! response="$(GH_TOKEN="$token" gh api "repos/$REPO/pulls/$PR_NUM/reviews" --paginate --slurp' \
  '  oa_message post-failed "$PR_NUM" "$REPO" "$live" >&2
  exit 1
  if ! response="$(GH_TOKEN="$token" gh api "repos/$REPO/pulls/$PR_NUM/reviews" --paginate --slurp'
run_approve "$scripts/overseer-approve" "$TMP_ROOT/token" "$GIVEN" refused-approved "${APPROVE[@]}"
assert_eq "$RC|$NCALLS|${STDERR_KEY%% pr=*}|$(cat "$OUT")" "1|2|overseer-approve: post-failed|" \
  'failed-POST control reports failure despite the existing approval' "$ERR"

# Today's approval path, with the flag accepted but its hold bypassed, posts
# before the fixture's running review finishes. The normal completion row
# above rejects that behavior. Other controls remove each independent guard.
scripts="$(mutant_scripts mutant/orch overseer-approve)"
mutate_file "$scripts/overseer-approve" 'if [[ "$HOLD_COPILOT" -eq 1 ]]; then' \
  'if false; then # if [[ "$HOLD_COPILOT" -eq 1 ]]; then'
CHECK_MODE=finishing
run_approve "$scripts/overseer-approve" "$TMP_ROOT/token" "$GIVEN" ok "${APPROVE[@]}" --hold-copilot
assert_eq "$RC|$(cat "$CHECK_READS")|$(cat "$OUT")" \
  '0|0|APPROVED vanillagreen-overseer[bot] 0123456' 'hold control approves before Copilot finishes' "$ERR"

scripts="$(mutant_scripts mutant/orch overseer-approve)"
mutate_file "$scripts/overseer-approve" 'if [[ "$HOLD_COPILOT" -eq 1 ]]; then' \
  'if true; then # if [[ "$HOLD_COPILOT" -eq 1 ]]; then'
run_approve "$scripts/overseer-approve" "$TMP_ROOT/token" "$GIVEN" ok "${APPROVE[@]}"
assert_eq "$RC|$(cat "$CHECK_READS")|$(cat "$OUT")" '5|2|' \
  'opt-in control holds a route that omitted the flag' "$ERR"

scripts="$(mutant_scripts mutant/orch overseer-approve)"
mutate_file "$scripts/overseer-approve" '      exit 1
    fi
    now="$(date +%s)"' '      runs="[]" # exit 1
    fi
    now="$(date +%s)"'
CHECK_MODE=failed
run_approve "$scripts/overseer-approve" "$TMP_ROOT/token" "$GIVEN" ok "${APPROVE[@]}" --hold-copilot
assert_eq "$RC|$(cat "$OUT")" '0|APPROVED vanillagreen-overseer[bot] 0123456' \
  'read-failure control approves with unreadable work' "$ERR"

scripts="$(mutant_scripts mutant/orch overseer-approve)"
mutate_file "$scripts/overseer-approve" '"$waited" -ge "$hold_secs"' '"$waited" -gt "$hold_secs"'
CHECK_MODE=finishing HOLD_SECS=10
run_approve "$scripts/overseer-approve" "$TMP_ROOT/token" "$GIVEN" ok "${APPROVE[@]}" --hold-copilot
assert_eq "$RC|$(cat "$OUT")" '5|' 'bound control refuses after the hold expired' "$ERR"
unset CHECK_MODE HOLD_SECS

# This control keeps the initial head read, but bypasses only the reread
# after expiry. The moved-head and failed-read rows above reject its POST.
scripts="$(mutant_scripts mutant/orch overseer-approve)"
mutate_file "$scripts/overseer-approve" '      oa_read_live_head "$live"' \
  '      : # oa_read_live_head "$live"'
CHECK_MODE=running HOLD_SECS=3
while IFS= read -r after_head; do
  AFTER_HOLD_HEAD="$after_head"
  run_approve "$scripts/overseer-approve" "$TMP_ROOT/token" "$GIVEN" ok "${APPROVE[@]}" --hold-copilot
  assert_eq "$RC|$(cat "$HEAD_READS")|$(jq -r .commit_id "$INPUT")" "0|1|$GIVEN" \
    'reread control approves without checking the post-hold head' "$ERR"
done <<EOF
$MOVED
fail
EOF
unset CHECK_MODE HOLD_SECS AFTER_HOLD_HEAD

# The zero-bound row already proves normal refusal. Removing that refusal
# alone authorizes an immediate approval even while Copilot still runs.
scripts="$(mutant_scripts mutant/orch overseer-approve)"
mutate_file "$scripts/overseer-approve" \
  '[[ "$hold_secs" =~ ^[1-9][0-9]*$ ]] || refuse 1 copilot-hold-setting "$hold_secs"' \
  'true || refuse 1 copilot-hold-setting "$hold_secs"'
CHECK_MODE=running HOLD_SECS=0
run_approve "$scripts/overseer-approve" "$TMP_ROOT/token" "$GIVEN" ok "${APPROVE[@]}" --hold-copilot
assert_eq "$RC|$(cat "$CHECK_READS")|$(cat "$SLEEPS")|$(jq -r .commit_id "$INPUT")" "0|1||$GIVEN" \
  'setting control approves immediately with a zero bound' "$ERR"
unset CHECK_MODE HOLD_SECS

scripts="$(mutant_scripts mutant/orch lib/copilot-check-runs.sh)"
mutate_file "$scripts/lib/copilot-check-runs.sh" \
  'select(.status == "queued" or .status == "in_progress")' \
  'select(.status == "queued") | # select(.status == "queued" or .status == "in_progress")'
CHECK_MODE=finishing
run_approve "$scripts/overseer-approve" "$TMP_ROOT/token" "$GIVEN" ok "${APPROVE[@]}" --hold-copilot
assert_eq "$RC|$(cat "$OUT")" '0|APPROVED vanillagreen-overseer[bot] 0123456' \
  'status control overlooks a running review' "$ERR"
unset CHECK_MODE

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
