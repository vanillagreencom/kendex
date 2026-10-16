#!/usr/bin/env bash
# overseer-approve against a fake GitHub API: the approval call's shape, the
# head-prefix refusal, the credential refusal, and that the token never shows.
set -euo pipefail
export MSYS=winsymlinks:nativestrict
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$TEST_DIR/../../.." && pwd -P)"
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/growth-state.sh"
mkdir -p "$REPO_ROOT/tmp"
TMP_ROOT="$(mktemp -d "$REPO_ROOT/tmp/overseer-approve.XXXXXX")" || { echo 'overseer_approve: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "overseer_approve: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'overseer_approve: scratch=resolve-failed' >&2; exit 1; }
trap '[[ -z ${FOREIGN_PARENT_TOKEN:-} ]] || rm -f -- "$FOREIGN_PARENT_TOKEN"; rm -rf -- "${TMP_ROOT:?}"' EXIT

TOKEN=ghs_fixtureOverseerReviewToken
GIVEN=0123456789abcdef0123456789abcdef01234567
MOVED=fedcba9876543210fedcba9876543210fedcba98
PREFIX_MOVED=01234567fedcba9876543210fedcba9876543210
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/home" "$TMP_ROOT/cwd"
printf '%s\n' "$TOKEN" > "$TMP_ROOT/token"
: > "$TMP_ROOT/token-empty"
printf '%s\nsecond\n' "$TOKEN" > "$TMP_ROOT/token-two-lines"
printf '%s' "$TOKEN" > "$TMP_ROOT/token-no-newline"
printf '%s\n\n' "$TOKEN" > "$TMP_ROOT/token-final-newlines"
printf '%s\r\n' "$TOKEN" > "$TMP_ROOT/token-crlf"
printf '%5000s' '' | tr ' ' x > "$TMP_ROOT/token-long"
printf '%s\0' "$TOKEN" > "$TMP_ROOT/token-nul"
chmod 600 "$TMP_ROOT"/token*
for mode in 640 604 620 602 610 601 000; do
  cp "$TMP_ROOT/token" "$TMP_ROOT/token-$mode"
  chmod "$mode" "$TMP_ROOT/token-$mode"
done
UNREADABLE_CAUSE=malformed
[[ ! -r "$TMP_ROOT/token-000" ]] || UNREADABLE_CAUSE=accepted
mkfifo "$TMP_ROOT/token-fifo"
mkdir "$TMP_ROOT/shared-parent"
cp -p "$TMP_ROOT/token" "$TMP_ROOT/shared-parent/token"
chmod 770 "$TMP_ROOT/shared-parent"
ln -s "$TMP_ROOT/token" "$TMP_ROOT/token-link"
[[ -L "$TMP_ROOT/token-link" ]] || exit 1
FOREIGN_FILE=/etc/passwd
if [[ -O "$FOREIGN_FILE" ]]; then
  FOREIGN_FILE="$TMP_ROOT/token-foreign"
  cp -p "$TMP_ROOT/token" "$FOREIGN_FILE"
  chown 1 "$FOREIGN_FILE"
fi
[[ ! -O "$FOREIGN_FILE" ]] || exit 1
# A private file in another account's directory must name that parent. The
# sticky temp root permits this hostile layout without changing its owner.
FOREIGN_PARENT="$(cd -- /tmp && pwd -P)" || exit 1
if [[ "$EUID" -eq 0 ]]; then
  FOREIGN_PARENT="$TMP_ROOT/foreign-parent"
  mkdir "$FOREIGN_PARENT"
  chmod 700 "$FOREIGN_PARENT"
  chown 1 "$FOREIGN_PARENT"
else
  [[ ! -O "$FOREIGN_PARENT" && -k "$FOREIGN_PARENT" && -w "$FOREIGN_PARENT" ]] || {
    printf 'overseer_approve: foreign-parent=unavailable path=%s\n' "$FOREIGN_PARENT" >&2
    exit 1
  }
fi
FOREIGN_PARENT_TOKEN="$(mktemp "$FOREIGN_PARENT/orch-parent-owner.XXXXXX")" || exit 1
cp -p "$TMP_ROOT/token" "$FOREIGN_PARENT_TOKEN"
chmod 600 "$FOREIGN_PARENT_TOKEN"
[[ -f "$FOREIGN_PARENT_TOKEN" && -O "$FOREIGN_PARENT_TOKEN" && ! -O "$FOREIGN_PARENT" ]] || exit 1
printf 'Each decline holds.\n"Quoted" line\n' > "$TMP_ROOT/body"
CALLS="$TMP_ROOT/calls"
INPUT="$TMP_ROOT/input"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"
CHECK_READS="$TMP_ROOT/check-reads"
HEAD_READS="$TMP_ROOT/head-reads"
CLOCK="$TMP_ROOT/clock"
SLEEPS="$TMP_ROOT/sleeps"
REPLY_CALLS="$TMP_ROOT/reply-calls"
SYSTEM_SLEEP="$(type -P sleep)" || exit 1

# One `<GH_TOKEN>|<argv>` line per call; the POST's stdin is kept whole.
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Reader API calls use separate evidence so the existing approval-call
# assertions keep their scope. The reader itself judges the Copilot body.
case "$*" in
  'api user --jq .login')
    if [[ "${GH_TOKEN:-}" == fixture_lane ]]; then echo 'lane-app[bot]'; else echo 'overseer-app[bot]'; fi
    exit 0 ;;
  'api graphql '*)
    if [[ "$*" == *'viewer {'* ]]; then
      if [[ "${GH_TOKEN:-}" == fixture_lane ]]; then
        echo '{"data":{"viewer":{"login":"lane-app[bot]","databaseId":2002}}}'
      else
        echo '{"data":{"viewer":{"login":"overseer-app[bot]","databaseId":4004}}}'
      fi
    elif [[ "$REPLY_MODE" == bad-lane-reply ]]; then
      echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"comments":{"totalCount":2,"nodes":[{"author":{"login":"copilot-pull-request-reviewer","__typename":"Bot","databaseId":3003},"authorAssociation":"NONE","body":"The read can accept an empty value."},{"author":{"login":"lane-app","__typename":"Bot","databaseId":2002},"authorAssociation":"CONTRIBUTOR","body":"Tracked separately."}]}}]}}}}}'
    else
      echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
    fi
    exit 0 ;;
  'api repos/o/r/pulls/42')
    printf '%s|%s|%s\n' "${GH_TOKEN:-}" "${GH_REPO:-}" "$*" >> "$REPLY_CALLS"
    case "$REPLY_MODE" in
      unavailable) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
      malformed) echo '{}'; exit 0 ;;
    esac
    jq -nc --arg head "$REPLY_HEAD" '{head:{sha:$head},user:{login:"author",type:"User",id:1001}}'
    exit 0 ;;
  'api repos/o/r/pulls/42/reviews?per_page=100 --paginate')
    if [[ "$REPLY_MODE" == body-findings || "$REPLY_MODE" == lane-disposition ]]; then
      jq -nc --arg head "$REPLY_HEAD" '[{id:5539256602,state:"COMMENTED",commit_id:$head,user:{login:"copilot-pull-request-reviewer[bot]",type:"Bot",id:3003},author_association:"NONE",body:"<!-- ccr-overview-v2 -->\n\n### Changes recommended\n\nTwo problems remain in the review body.\n\n**0 open findings**"}]'
    else echo '[]'; fi
    exit 0 ;;
  'api repos/o/r/issues/42/comments?per_page=100 --paginate')
    if [[ "$REPLY_MODE" == lane-disposition ]]; then
      jq -nc --arg head "$REPLY_HEAD" '[{user:{login:"lane-app[bot]",type:"Bot",id:2002},author_association:"CONTRIBUTOR",body:("Dispositions at " + $head + "\nreview:5539256602 - Declined: the caller rejects empty values before the read.")}]'
    else echo '[]'; fi
    exit 0 ;;
esac
printf '%s|%s\n' "${GH_TOKEN:-}" "$*" >> "$CALLS"
case "$*" in
  'api repos/o/r/issues/42/timeline?per_page=100 --paginate --slurp')
    if [[ "$CHECK_MODE" == cycle-* ]]; then
      jq -nc --arg head "$LIVE_HEAD" --arg current "$LIVE_HEAD" --arg old "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" --arg mode "$CHECK_MODE" --argjson count "$(cat "$CHECK_READS")" '
        def req($id;$at): {event:"review_requested",id:$id,commit_id:null,created_at:$at,requested_reviewer:{login:"Copilot",type:"Bot"}};
        def work($id;$at): {event:"copilot_work_started",id:$id,commit_id:null,commit_url:null,created_at:$at,actor:{login:"bmethod",type:"User"},performed_via_github_app:{slug:"copilot-pull-request-reviewer"}};
        def rev($id;$head;$at): {event:"reviewed",id:$id,commit_id:$head,user:{login:"Copilot",type:"Bot"},state:"commented",submitted_at:$at};
        (if ($mode | startswith("cycle-cancel")) then "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" else $head end) as $b |
        [[{event:"committed",sha:$b,committer:{date:"2026-10-09T05:00:00Z"}},
          {event:"committed",sha:$current,committer:{date:"2026-10-09T05:00:01Z"}},
          {event:"head_ref_force_pushed",commit_id:$old,created_at:"2026-10-09T06:00:00Z"},req(73;"2026-10-09T06:10:00Z")],
         (if ($mode | startswith("cycle-cancel")) then [{event:"review_request_removed",created_at:"2026-10-09T06:11:00Z",requested_reviewer:{login:"Copilot",type:"Bot"}}]
          else [work(75;"2026-10-09T06:10:35Z"),rev(81;$old;"2026-10-09T06:20:00Z")] end),
         (if $mode == "cycle-cancel-boundary" then [{event:"head_ref_force_pushed",commit_id:$b,created_at:"2026-10-09T06:30:00Z"}] else [] end),
         (if ($mode | startswith("cycle-rereview")) then [req(76;"2026-10-09T06:25:00Z"),work(77;"2026-10-09T06:25:35Z"),rev(82;$old;"2026-10-09T06:26:00Z")] else [] end),
         (if ($mode | startswith("cycle-cancel")) then [req(74;"2026-10-09T06:41:20Z"),work(78;"2026-10-09T06:41:55Z"),rev(83;$b;"2026-10-09T06:42:05Z")] else [] end),
         (if ($mode | contains("newer")) then [req(79;"2026-10-09T06:43:00Z"),work(80;"2026-10-09T06:43:35Z")] else [] end),
         (if $count > 1 then [rev(84;$current;"2026-10-09T06:45:00Z")] else [] end)]'
    elif [[ "$CHECK_MODE" == timeline ]]; then
      jq -nc --arg head "$LIVE_HEAD" --argjson count "$(cat "$CHECK_READS")" '
        [[{event:"review_requested",id:73,created_at:"2026-10-09T06:41:20Z",requested_reviewer:{login:"Copilot"}}],
         if $count > 1 then [{event:"reviewed",id:81,user:{login:"Copilot"},commit_id:$head,submitted_at:"2026-10-09T06:42:05Z"}] else [] end]'
    else echo '[[]]'; fi
    ;;
  'api repos/o/r/commits/'*'/check-runs?filter=all&per_page=100 --paginate --slurp')
    [[ "$*" == "api repos/o/r/commits/$LIVE_HEAD/check-runs?filter=all&per_page=100 --paginate --slurp" ]] || exit 9
    count="$(cat "$CHECK_READS")"
    count=$((count + 1))
    printf '%s\n' "$count" > "$CHECK_READS"
    state=in_progress
    started='"2026-10-09T06:41:20Z"'
    case "$CHECK_MODE" in
      completed) state=completed ;;
      timeline|cycle-*) echo '[{"check_runs":[]}]'; exit 0 ;;
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
# GitHub authentication polls its own child with fractional sleeps. Only
# whole-second Copilot waits advance this fixture's clock.
case "$1" in *.*) exec "$REAL_SLEEP" "$@" ;; esac
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
  : > "$REPLY_CALLS"
  printf '0\n' > "$CHECK_READS"
  printf '0\n' > "$HEAD_READS"
  printf '0\n' > "$CLOCK"
  : > "$SLEEPS"
  rm -f -- "$INPUT"
  RC=0
  (cd -- "$TMP_ROOT/cwd" && env -i GIT_CEILING_DIRECTORIES="$TMP_ROOT" PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT/home" \
    ${setting[@]+"${setting[@]}"} \
    GH_BOT_TOKEN=fixture_lane \
    CALLS="$CALLS" INPUT="$INPUT" LIVE_HEAD="$live" POST="$post" \
    CHECK_MODE="${CHECK_MODE-finishing}" CHECK_READS="$CHECK_READS" \
    HEAD_READS="$HEAD_READS" AFTER_HOLD_HEAD="${AFTER_HOLD_HEAD-$live}" \
    CLOCK="$CLOCK" SLEEPS="$SLEEPS" ORCH_COPILOT_HOLD_SECS="${HOLD_SECS-600}" \
    REPLY_CALLS="$REPLY_CALLS" REPLY_MODE="${REPLY_MODE-pass}" REPLY_HEAD="${REPLY_HEAD-$live}" TMPDIR="$TMP_ROOT" REAL_SLEEP="$SYSTEM_SLEEP" \
    ORCH_OVERSEER_REVIEW_LOGIN="${REVIEW_LOGIN-review-app[bot]}" \
    "$BASH" "$script" "$@" > "$OUT" 2> "$ERR") || RC=$?
  STDERR_KEY="$(sed -n 1p "$ERR")"
  NCALLS="$(wc -l < "$CALLS" | tr -d ' ')"
}

RUN="$REPO_ROOT/skills/orch/scripts/overseer-approve"
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
assert_eq "$(cat "$REPLY_CALLS")" "fixture_lane|o/r|api repos/o/r/pulls/42" \
  'the reader keeps the router-selected identity and target repository' "$ERR"

identity_scripts="$(mutant_scripts reader-identity/orch overseer-approve)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/reader-identity/github"
mutate_file "$identity_scripts/overseer-approve" 'reply_result="$(GH_REPO="$REPO"' \
  'reply_result="$(GH_TOKEN="$token" GH_REPO="$REPO"'

# The reader's verdict and full head, rather than the caller's short prefix,
# decide whether a body-only finding can receive an approval.
while IFS='|' read -r label mode reader_head want_rc want_post result subject; do
  REPLY_MODE="$mode" REPLY_HEAD="$reader_head" CHECK_MODE=completed
  subject_script="$RUN"
  [[ "${subject:-}" != identity-control ]] || subject_script="$identity_scripts/overseer-approve"
  run_approve "$subject_script" "$TMP_ROOT/token" "$GIVEN" ok 42 "${GIVEN:0:8}" \
    --body-file "$TMP_ROOT/body" --repo o/r --hold-copilot
  posted=no
  [[ ! -f "$INPUT" ]] || posted=yes
  assert_eq "$RC|$posted" "$want_rc|$want_post" "$label" "$ERR"
  if [[ "$want_rc" != 0 ]]; then
    assert_eq "$(wc -l < "$ERR" | tr -d ' ')|${STDERR_KEY%% pr=*}" '1|overseer-approve: review-replies' \
      "$label emits one keyed refusal" "$ERR"
    assert_contains "$STDERR_KEY" "$result" "$label names the reader result" "$ERR"
    assert_contains "$STDERR_KEY" ' fix=' "$label supplies a remedy" "$ERR"
  fi
done <<EOF
Copilot COMMENTED body findings without a thread|body-findings|$GIVEN|1|no|suppressed-entry
reader passes the bound head|pass|$GIVEN|0|yes|
reader passes another head|pass|$MOVED|1|no|$MOVED
reader cannot read the review|unavailable|$GIVEN|1|no|read-failed
reader receives malformed evidence|malformed|$GIVEN|1|no|read-malformed
lane app answers a body finding on a person-authored PR|lane-disposition|$GIVEN|0|yes|
lane app names no issue in a thread reply on a person-authored PR|bad-lane-reply|$GIVEN|1|no|untracked-claim
must-fail: changed reader identity rejects the valid lane answer|lane-disposition|$GIVEN|1|no|suppressed-entry|identity-control
must-fail: changed reader identity ignores the invalid lane reply|bad-lane-reply|$GIVEN|0|yes||identity-control
EOF
unset REPLY_MODE REPLY_HEAD CHECK_MODE

scripts="$(mutant_scripts reader-missing/orch overseer-approve)" || exit 1
mkdir -p "$TMP_ROOT/reader-missing/github/scripts"
ln -s "$REPO_ROOT/skills/github/scripts/lib" "$TMP_ROOT/reader-missing/github/scripts/lib"
run_approve "$scripts/overseer-approve" "$TMP_ROOT/token" "$GIVEN" ok "${APPROVE[@]}"
assert_eq "$RC|${STDERR_KEY%% pr=*}|$NCALLS" '1|overseer-approve: review-replies|1' \
  'a missing reader refuses before the approval POST' "$ERR"
assert_contains "$STDERR_KEY" 'result=unavailable fix=' 'a missing reader names its result and remedy' "$ERR"

# Restore the prior approval behavior in a disposable copy. The body-only
# row above must reject this approval, even though the reader found it.
scripts="$(mutant_scripts reader-bypass/orch overseer-approve)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/reader-bypass/github"
mutate_file "$scripts/overseer-approve" \
  '[[ "$reply_status" -eq 0 && "$reply_result" == "review-replies: pass head=$live" ]]' \
  'true || [[ "$reply_status" -eq 0 && "$reply_result" == "review-replies: pass head=$live" ]]'
REPLY_MODE=body-findings CHECK_MODE=completed
run_approve "$scripts/overseer-approve" "$TMP_ROOT/token" "$GIVEN" ok "${APPROVE[@]}" --hold-copilot
assert_eq "$RC|$(cat "$OUT")|$(jq -r .commit_id "$INPUT")" \
  "0|APPROVED vanillagreen-overseer[bot] 0123456|$GIVEN" \
  'must-fail: bypassing the reader result approves the Copilot body findings' "$ERR"
unset REPLY_MODE CHECK_MODE

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
pending timeline work is reviewed|timeline|yes|600|5|no|2|copilot-finished
completed old cycle stays closed after push|cycle-completed|yes|600|0|yes|1|
completed old cycle stays closed after ordinary push|cycle-completed-ordinary|yes|600|0|yes|1|
new request after ordinary push stays pending|cycle-newer-ordinary|yes|600|5|no|2|copilot-finished
second completed review stays closed after ordinary push|cycle-rereview-completed-ordinary|yes|600|0|yes|1|
new request after two completed reviews stays pending|cycle-rereview-newer-ordinary|yes|600|5|no|2|copilot-finished
completed cancelled history after ordinary pushes|cycle-cancel-completed|yes|600|0|yes|1|
cancelled history retains newer request|cycle-cancel-newer|yes|600|5|no|2|copilot-finished
completed cancelled history after verified boundary|cycle-cancel-boundary|yes|600|0|yes|1|
new request stays pending after old completion|cycle-newer|yes|600|5|no|2|copilot-finished
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

CHECK_MODE=timeline
run_approve "$RUN" "$TMP_ROOT/token" "$GIVEN" ok "${APPROVE[@]}" --hold-copilot
assert_eq "$STDERR_KEY|$(cat "$SLEEPS")" \
  "overseer-approve: copilot-in-flight pr=42 repo=o/r head=$GIVEN run=73 started_at=2026-10-09T06:41:20Z|10" \
  'timeline hold names the pending request and polls before finishing' "$ERR"
unset CHECK_MODE

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
done <<EOF
head moved|@token|$MOVED|ok|$GIVEN|4|overseer-approve: head-moved pr=42 given=$GIVEN live=$MOVED|1
prefix head moved|@token|$MOVED|ok|${GIVEN:0:8}|4|overseer-approve: head-moved pr=42 given=${GIVEN:0:8} live=$MOVED|1
head read failed|@token|fail|ok|$GIVEN|1|overseer-approve: head-read-failed pr=42 repo=o/r|1
live head not a sha|@token|${GIVEN}0|ok|$GIVEN|1|overseer-approve: head-read-failed pr=42 repo=o/r|1
post refused|@token|$GIVEN|refused|$GIVEN|1|overseer-approve: post-failed pr=42 repo=o/r commit=$GIVEN|3
answer unreadable|@token|$GIVEN|unreadable|$GIVEN|1|overseer-approve: response-unread pr=42 repo=o/r commit=$GIVEN|2
EOF

# Fleet writes private regular files and may omit or repeat the final LF.
# The overseer consumes the credential key; the cause names the failed input.
while IFS='|' read -r label file cause refused_file; do
  file="${file//@/$TMP_ROOT/}"
  refused_file="${refused_file//@/$TMP_ROOT/}"
  run_approve "$RUN" "$file" "$GIVEN" ok "${APPROVE[@]}"
  if [[ "$cause" == accepted ]]; then
    assert_eq "$RC|$NCALLS|$(jq -r .commit_id "$INPUT")" "0|2|$GIVEN" "$label" "$ERR"
  else
    assert_eq "$RC|$STDERR_KEY|$NCALLS|$(cat "$OUT")" \
      "3|overseer-approve: credential setting=ORCH_OVERSEER_REVIEW_TOKEN_FILE file=$file|0|" "$label" "$ERR"
    if [[ "$cause" != unset ]]; then
      assert_eq "$(grep '^orch_token_file_read: refused ' "$ERR")" \
        "orch_token_file_read: refused file=${refused_file:-$file} cause=$cause" "$label names its cause" "$ERR"
    fi
  fi
  assert_not_contains "$(cat "$OUT" "$ERR")" "$TOKEN" "$label prints no token"
done <<EOF
token file unset||unset|
token file missing|@missing|not-regular|
token file empty|@token-empty|malformed|
token file two lines|@token-two-lines|malformed|
token file CRLF|@token-crlf|malformed|
token file NUL|@token-nul|malformed|
token file over cap|@token-long|too-long|
token file FIFO|@token-fifo|not-regular|
token file foreign owner|$FOREIGN_FILE|not-owned|
token file group readable|@token-640|mode-640|
token file other readable|@token-604|mode-604|
token file group writable|@token-620|mode-620|
token file other writable|@token-602|mode-602|
token file group executable|@token-610|mode-610|
token file other executable|@token-601|mode-601|
token file mode 000|@token-000|$UNREADABLE_CAUSE|
token parent group writable|@shared-parent/token|mode-770|@shared-parent
token parent foreign owner|$FOREIGN_PARENT_TOKEN|not-owned|$FOREIGN_PARENT
token file final newline|@token|accepted|
token file no final newline|@token-no-newline|accepted|
token file repeated final newlines|@token-final-newlines|accepted|
token file symlink|@token-link|accepted|
EOF

# Skipping only the parent's ownership check invalidates the row above. A
# sticky temp root then reaches the write-mode refusal; a private parent reads.
scripts="$(mutant_scripts token-parent-owner/orch lib/gh-auth.sh)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/token-parent-owner/github"
mutate_file "$scripts/lib/gh-auth.sh" '[[ ! -O "$path" ]]' \
  '[[ "$path" == "$file" && ! -O "$path" ]]'
run_approve "$scripts/overseer-approve" "$FOREIGN_PARENT_TOKEN" "$GIVEN" ok "${APPROVE[@]}"
if [[ "$EUID" -eq 0 ]]; then
  assert_eq "$RC|$NCALLS" '0|2' 'control: foreign parent ownership refusal disappears' "$ERR"
else
  assert_eq "$RC|$NCALLS|$(cat "$OUT")" '3|0|' 'control: foreign parent reaches its mode refusal' "$ERR"
  assert_contains "$(cat "$ERR")" "orch_token_file_read: refused file=$FOREIGN_PARENT cause=mode-" \
    'control: skipping parent ownership reaches the next parent check' "$ERR"
fi
assert_not_contains "$(cat "$ERR")" "orch_token_file_read: refused file=$FOREIGN_PARENT cause=not-owned" \
  'control: the foreign-parent not-owned row fails' "$ERR"
assert_not_contains "$(cat "$OUT" "$ERR")" "$TOKEN" 'parent-owner control prints no token'

# The caller skips an unset setting. Exercise the reader's own unset contract.
source "$REPO_ROOT/skills/orch/scripts/lib/gh-auth.sh"
RC=0
orch_token_file_read > "$OUT" 2> "$ERR" || RC=$?
assert_eq "$RC|$(cat "$OUT")|$(cat "$ERR")" \
  '1||orch_token_file_read: refused file= cause=unset' 'reader unset argument names its cause' "$ERR"

# A token supplier can remove its file between the metadata probe and open.
# Remove it after the parent's real stat, so this open-error control also works
# when the test user can read mode-000 files.
STAT_BIN="$(type -P stat)" || exit 1
mkdir "$TMP_ROOT/stat-bin"
cat > "$TMP_ROOT/stat-bin/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"$REAL_STAT" "$@"
last=""
for last in "$@"; do :; done
[[ "$last" != "$TOKEN_PARENT" ]] || rm -- "$TOKEN_PATH"
EOF
chmod +x "$TMP_ROOT/stat-bin/stat"
RACE_FILE="$TMP_ROOT/token-read-race"
for variant in reader open-error-control; do
  reader="$REPO_ROOT/skills/orch/scripts/lib/gh-auth.sh"
  if [[ "$variant" == open-error-control ]]; then
    scripts="$(mutant_scripts token-open-error/orch lib/gh-auth.sh)" || exit 1
    ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/token-open-error/github"
    reader="$scripts/lib/gh-auth.sh"
    mutate_file "$reader" '} 2>/dev/null < "$file" || cause=malformed' \
      '} < "$file" 2>/dev/null || cause=malformed'
  fi
  printf '%s\n' "$TOKEN" > "$RACE_FILE"
  chmod 600 "$RACE_FILE"
  RC=0
  env -i PATH="$TMP_ROOT/stat-bin:$PATH" HOME="$TMP_ROOT/home" \
    REAL_STAT="$STAT_BIN" TOKEN_PARENT="$TMP_ROOT" TOKEN_PATH="$RACE_FILE" \
    "$BASH" -c 'set -euo pipefail; source "$1"; orch_token_file_read "$2"' \
    -- "$reader" "$RACE_FILE" > "$OUT" 2> "$ERR" || RC=$?
  key="orch_token_file_read: refused file=$RACE_FILE cause=malformed"
  assert_eq "$RC|$(cat "$OUT")|$(grep '^orch_token_file_read: refused ' "$ERR")" \
    "1||$key" "$variant: an open failure returns only a refusal" "$ERR"
  if [[ "$variant" == reader ]]; then
    assert_eq "$(cat "$ERR")" "$key" 'open failure emits one keyed line' "$ERR"
  else
    assert_not_contains "$(sed -n 1p "$ERR")" 'orch_token_file_read: refused ' \
      'control: redirecting input first puts an unkeyed error before the refusal' "$ERR"
  fi
  assert_not_contains "$(cat "$OUT" "$ERR")" "$TOKEN" "$variant: open failure prints no token"
done
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
# shellcheck disable=SC2016
mutate_file "$scripts/overseer-approve" 'orch_copilot_check_runs "$REPO" "$live" "$PR_NUM"' \
  'orch_copilot_check_runs "$REPO" "$live"'
CHECK_MODE=timeline
run_approve "$scripts/overseer-approve" "$TMP_ROOT/token" "$GIVEN" ok "${APPROVE[@]}" --hold-copilot
assert_eq "$RC|$(cat "$CHECK_READS")|$(cat "$OUT")" \
  '0|1|APPROVED vanillagreen-overseer[bot] 0123456' 'timeline control approves before the pending request is reviewed' "$ERR"

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
mutate_file "$scripts/lib/copilot-check-runs.sh" '$event.submitted_at >= .started_at' 'false and $event.submitted_at >= .started_at'
CHECK_MODE=cycle-cancel-completed HOLD_SECS=3
run_approve "$scripts/overseer-approve" "$TMP_ROOT/token" "$GIVEN" ok "${APPROVE[@]}" --hold-copilot
last_key="$(sed -n 's/^overseer-approve: \([^ ]*\).*/\1/p' "$ERR" | tail -1)"
assert_eq "$RC|$(cat "$CHECK_READS")|$last_key" '0|2|copilot-hold-expired' \
  'must-fail: completed history would create an approval hold after ordinary pushes' "$ERR"
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
