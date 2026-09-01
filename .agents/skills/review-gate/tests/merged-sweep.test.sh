#!/usr/bin/env bash
# Behavioral tests for the SHIPPED skills/review-gate/scripts/merged-sweep.sh
# — the post-merge half of the needs-attention reducer (KEN-1021). One
# stubbed gh serving one GraphQL fixture, every reduction arm driven
# offline.
#
# Reduction table:
#   ms1.  late bot review, no answer        -> post-merge-findings, exit 1
#   ms2.  the same state, second pass       -> silence, exit 0 (the dedupe)
#   ms3.  a SECOND finding on that PR       -> news again
#   ms4.  the finding clears, then recurs   -> news again (rising edge)
#   ms5.  --no-state                        -> re-reports, writes nothing
#   ms6.  a Declined: comment after it      -> answered, silence
#   ms7.  a track-word comment naming an id -> answered, silence
#   ms7b. a BARE track-word                 -> answers nothing
#   ms8.  an answer BEFORE the review       -> still unanswered
#   ms9.  the PR author's own late review   -> not a finding
#   ms10. a late APPROVED / DISMISSED row   -> not a finding
#   ms11. reviews and threads pre-merge     -> silence
#   ms12. merged outside the window         -> silence
#   ms13. late thread with a human reply    -> answered, silence
#   ms14. late thread whose reply is a Bot  -> still a finding
#   ms15. reviews page entirely post-merge  -> overflow, fail CLOSED
#   ms16. thread past the comment bound     -> overflow, fail CLOSED
#   ms17. graphql errors in the envelope    -> exit 2, stderr only
#   ms18. zero-byte read                    -> exit 2 (never "no PRs")
#   ms19. a row without a head sha          -> exit 2 (broken read)
#   ms20. GH_REPO missing / malformed       -> exit 2
#   ms21. --limit out of range, bad numbers -> exit 2 (never clamped)
#   ms22. an unreadable state file          -> exit 2 (never silent)
#   ms23. --help before every requirement   -> exit 0
#   ms24. many PRs                          -> still ONE query
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$TEST_DIR/.." && pwd)"
SWEEP="$SKILL_ROOT/scripts/merged-sweep.sh"
TMP_ROOT="$(mktemp -d)"
[ -n "$TMP_ROOT" ] || { echo "FATAL: mktemp -d returned an empty path" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        must not contain: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  else
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  fi
}

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/cwd"

# The gh stub answers exactly one call — the sweep issues one query per
# invocation, and a second call would be a regression ms24 reports.
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -u
[[ "${1:-}" == "api" && "${2:-}" == "graphql" ]] || { echo "unexpected gh call: $*" >&2; exit 1; }
echo call >> "${STUB_CALL_LOG:-/dev/null}"
if [[ "${STUB_READ_FAIL:-}" == "yes" ]]; then echo "HTTP 502" >&2; exit 1; fi
if [[ "${STUB_EMPTYBYTES:-}" == "yes" ]]; then exit 0; fi
cat "${STUB_FIXTURE:?}"
EOF
chmod +x "$TMP_ROOT/bin/gh"

# Timestamps are built from the RUN's clock, so the window arithmetic is
# exercised against real "now" rather than a frozen fixture date that would
# drift out of every window as the suite ages.
NOW="$(date -u +%s)"
iso() { # OFFSET_SECS_FROM_NOW
  date -u -d "@$((NOW + $1))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$((NOW + $1))" +%Y-%m-%dT%H:%M:%SZ
}
MERGED_AT="$(iso -3600)"       # merged an hour ago
BEFORE_MERGE="$(iso -7200)"
AFTER_MERGE="$(iso -1800)"
LATER="$(iso -600)"
OLD_MERGE="$(iso -864000)"     # ten days ago — outside the default window
OLD_AFTER="$(iso -863000)"

HEAD_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

review() { # id, createdAt, state, body, login, [typename]
  jq -n --arg id "$1" --arg at "$2" --arg st "$3" --arg body "$4" \
    --arg login "$5" --arg tn "${6:-Bot}" \
    '{id:$id, createdAt:$at, state:$st, body:$body, author:{login:$login, __typename:$tn}}'
}
comment() { # createdAt, body, login, [typename]
  jq -n --arg at "$1" --arg body "$2" --arg login "$3" --arg tn "${4:-User}" \
    '{createdAt:$at, body:$body, author:{login:$login, __typename:$tn}}'
}
thread() { # id, comments-totalCount, comment-json...
  local id="$1" total="$2"; shift 2
  jq -n --arg id "$id" --argjson total "$total" --argjson nodes "$(jq -sc '.' <<<"$*")" \
    '{id:$id, comments:{totalCount:$total, nodes:$nodes}}'
}
pr() { # number, mergedAt, author, reviews-json, comments-json, threads-json,
       # [reviews-totalCount], [threads-totalCount]
  jq -n --argjson n "$1" --arg merged "$2" --arg author "$3" --arg head "$HEAD_A" \
    --argjson rv "$4" --argjson cm "$5" --argjson th "$6" \
    --argjson rvt "${7:--1}" --argjson tht "${8:--1}" \
    '{number:$n, mergedAt:$merged, headRefOid:$head, author:{login:$author},
      reviews:{totalCount:(if $rvt < 0 then ($rv|length) else $rvt end), nodes:$rv},
      comments:{nodes:$cm},
      reviewThreads:{totalCount:(if $tht < 0 then ($th|length) else $tht end), nodes:$th}}'
}
envelope() { # pr-json...
  jq -n --argjson nodes "$(jq -sc '.' <<<"$*")" \
    '{data:{repository:{pullRequests:{nodes:$nodes}}}}'
}

fixture() { printf '%s\n' "$1" > "$TMP_ROOT/fixture.json"; }
fresh_state() { rm -rf -- "${TMP_ROOT:?}/state"; }

run_sweep() { # env-tokens... [-- flags...]
  local envs=() flags=() seen_sep=0 a
  for a in "$@"; do
    if [[ "$a" == "--" ]]; then seen_sep=1; continue; fi
    if [[ "$seen_sep" == "1" ]]; then flags+=("$a"); else envs+=("$a"); fi
  done
  (cd "$TMP_ROOT/cwd" \
    && PATH="$TMP_ROOT/bin:$PATH" \
       env GH_REPO=acme/widgets STUB_FIXTURE="$TMP_ROOT/fixture.json" \
           MERGED_SWEEP_STATE_DIR="$TMP_ROOT/state" "${envs[@]}" \
       "$SWEEP" ${flags[@]+"${flags[@]}"} 2>&1)
}

echo "=== merged-sweep reduction table ==="

# --- ms1..ms5: the finding, then the dedupe ------------------------------

LATE_REVIEW="$(review REV_late "$AFTER_MERGE" COMMENTED "P2: this leaks a handle" codex Bot)"
fixture "$(envelope "$(pr 10 "$MERGED_AT" dev "[$LATE_REVIEW]" '[]' '[]')")"

fresh_state
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "1" "ms1: a post-merge review exits 1"
assert_contains "$out" "post-merge-findings" "ms1: the attention kind is emitted"
assert_contains "$out" "1 review(s) and 0 review thread(s)" "ms1: the counts are named"
assert_contains "$out" "aaaaaaaa" "ms1: the line carries the 8-char head sha"

set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "0" "ms2: the SAME finding on a second pass exits 0"
assert_eq "$out" "" "ms2: and prints nothing (surfaced once)"

SECOND="$(review REV_two "$LATER" COMMENTED "P1: and this one too" codex Bot)"
fixture "$(envelope "$(pr 10 "$MERGED_AT" dev "[$LATE_REVIEW,$SECOND]" '[]' '[]')")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "1" "ms3: a NEW finding on an already-reported PR exits 1"
assert_contains "$out" "2 review(s)" "ms3: the line counts every standing finding"

ANSWER="$(comment "$LATER" "Declined: the handle is closed on the error path" dev User)"
fixture "$(envelope "$(pr 10 "$MERGED_AT" dev "[$LATE_REVIEW,$SECOND]" "[$ANSWER]" '[]')")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "0" "ms4a: answering every finding goes quiet"
fixture "$(envelope "$(pr 10 "$MERGED_AT" dev "[$LATE_REVIEW]" '[]' '[]')")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "1" "ms4b: a finding that cleared and recurred is news again"
assert_contains "$out" "post-merge-findings" "ms4b: and carries the kind"

set +e
out=$(run_sweep -- --no-state); rc=$?
set -e
assert_eq "$rc" "1" "ms5: --no-state re-reports a known finding"
assert_contains "$out" "post-merge-findings" "ms5: with the same kind"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "0" "ms5b: --no-state consumed no rising edge — the next stateful pass is still quiet"

# --- ms6..ms10: what is NOT a finding ------------------------------------

fresh_state
fixture "$(envelope "$(pr 11 "$MERGED_AT" dev "[$LATE_REVIEW]" \
  "[$(comment "$LATER" "Declined: the handle is closed on the error path" dev User)]" '[]')")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "0" "ms6: a later Declined: comment answers the review"
assert_eq "$out" "" "ms6: and nothing is printed"

fresh_state
fixture "$(envelope "$(pr 11 "$MERGED_AT" dev "[$LATE_REVIEW]" \
  "[$(comment "$LATER" "Tracked: KEN-1234" dev User)]" '[]')")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "0" "ms7: a later track-word comment NAMING an issue answers the review"

fresh_state
fixture "$(envelope "$(pr 11 "$MERGED_AT" dev "[$LATE_REVIEW]" \
  "[$(comment "$LATER" "tracking that separately" dev User)]" '[]')")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "1" "ms7b: a BARE track-word names no issue and answers nothing"

fresh_state
fixture "$(envelope "$(pr 11 "$MERGED_AT" dev "[$LATE_REVIEW]" \
  "[$(comment "$BEFORE_MERGE" "Declined: an answer to something else" dev User)]" '[]')")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "1" "ms8: an answer posted BEFORE the review answers nothing"

fresh_state
fixture "$(envelope "$(pr 11 "$MERGED_AT" dev \
  "[$(review REV_self "$AFTER_MERGE" COMMENTED "note to self" dev User)]" '[]' '[]')")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "0" "ms9: the PR author's own late review is not a finding"

fresh_state
fixture "$(envelope "$(pr 11 "$MERGED_AT" dev \
  "[$(review REV_ok "$AFTER_MERGE" APPROVED "" codex Bot),$(review REV_d "$LATER" DISMISSED "" codex Bot)]" '[]' '[]')")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "0" "ms10: a late APPROVED or DISMISSED row is not a finding"

# --- ms11/ms12: the merge boundary and the window ------------------------

fresh_state
PRE_THREAD="$(thread THR_pre 1 "$(comment "$BEFORE_MERGE" "nit" codex Bot)")"
fixture "$(envelope "$(pr 11 "$MERGED_AT" dev \
  "[$(review REV_pre "$BEFORE_MERGE" COMMENTED "found nothing" codex Bot)]" '[]' "[$PRE_THREAD]")")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "0" "ms11: reviews and threads that predate the merge are not findings"

fresh_state
fixture "$(envelope "$(pr 11 "$OLD_MERGE" dev \
  "[$(review REV_old "$OLD_AFTER" COMMENTED "P2 on an old merge" codex Bot)]" '[]' '[]')")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "0" "ms12: a PR merged outside the window is out of scope"
set +e
out=$(run_sweep -- --window 999999999); rc=$?
set -e
assert_eq "$rc" "1" "ms12b: a wide enough --window brings it back (the window is the filter, not the data)"

# --- ms13/ms14: thread replies ------------------------------------------

fresh_state
ANSWERED_THREAD="$(thread THR_ans 2 \
  "$(comment "$AFTER_MERGE" "this is wrong" codex Bot)" \
  "$(comment "$LATER" "Fixed in a1b2c3d4e5f6" dev User)")"
fixture "$(envelope "$(pr 12 "$MERGED_AT" dev '[]' '[]' "[$ANSWERED_THREAD]")")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "0" "ms13: a post-merge thread with a human disposition reply is answered"

fresh_state
BOT_REPLY_THREAD="$(thread THR_bot 2 \
  "$(comment "$AFTER_MERGE" "this is wrong" codex Bot)" \
  "$(comment "$LATER" "Fixed in a1b2c3d4e5f6" otherbot Bot)")"
fixture "$(envelope "$(pr 12 "$MERGED_AT" dev '[]' '[]' "[$BOT_REPLY_THREAD]")")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "1" "ms14: a bot reply is no disposition — bots quote each other"
assert_contains "$out" "0 review(s) and 1 review thread(s)" "ms14: counted as a thread finding"

# --- ms15/ms16: the read bounds fail CLOSED ------------------------------

fresh_state
# Every returned review is post-merge AND totalCount exceeds the page, so
# the sweep cannot prove it saw them all — answered ones included.
fixture "$(envelope "$(pr 13 "$MERGED_AT" dev "[$LATE_REVIEW]" \
  "[$(comment "$LATER" "Declined: answered every one" dev User)]" '[]' 99)")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "1" "ms15: a review page that cannot prove completeness fails closed"
assert_contains "$out" "beyond the read bound" "ms15: and says so"

fresh_state
DEEP_THREAD="$(thread THR_deep 500 "$(comment "$AFTER_MERGE" "x" codex Bot)" \
  "$(comment "$LATER" "Declined: covered above" dev User)")"
fixture "$(envelope "$(pr 13 "$MERGED_AT" dev '[]' '[]' "[$DEEP_THREAD]")")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "1" "ms16: a thread past the comment bound fails closed even when answered"
assert_contains "$out" "beyond the read bound" "ms16: and says so"

# --- ms17..ms22: read failures and config errors -------------------------

fresh_state
printf '%s\n' '{"errors":[{"message":"nope"}],"data":{"repository":null}}' > "$TMP_ROOT/fixture.json"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "2" "ms17: graphql errors beside the data exit 2"
assert_contains "$out" "::error::" "ms17: and report on stderr"
assert_not_contains "$out" "post-merge-findings" "ms17: with no per-PR lines"

fresh_state
set +e
out=$(run_sweep STUB_EMPTYBYTES=yes); rc=$?
set -e
assert_eq "$rc" "2" "ms18: a zero-byte read exits 2"
assert_contains "$out" "zero bytes" "ms18: named as a broken read, never as zero PRs"

fresh_state
set +e
out=$(run_sweep STUB_READ_FAIL=yes); rc=$?
set -e
assert_eq "$rc" "2" "ms18b: a failed listing call exits 2"

fresh_state
fixture "$(envelope "$(pr 14 "$MERGED_AT" dev "[$LATE_REVIEW]" '[]' '[]' \
  | jq '.headRefOid = "not-a-sha"')")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "2" "ms19: a row without a usable head sha exits 2 (broken read)"

fixture "$(envelope "$(pr 10 "$MERGED_AT" dev "[$LATE_REVIEW]" '[]' '[]')")"
set +e
out=$( (cd "$TMP_ROOT/cwd" && PATH="$TMP_ROOT/bin:$PATH" env -u GH_REPO "$SWEEP" 2>&1) ); rc=$?
set -e
assert_eq "$rc" "2" "ms20: a missing GH_REPO exits 2"
assert_contains "$out" "GH_REPO is required" "ms20: and names the variable"
for bad in "acme" "acme/widgets/extra" "/widgets" "acme/"; do
  set +e
  out=$(run_sweep GH_REPO="$bad"); rc=$?
  set -e
  assert_eq "$rc" "2" "ms20b: GH_REPO '$bad' is refused"
done

for bad_flag in "--limit 0" "--limit 101" "--limit abc" "--window 90s" "--window 1234567890123"; do
  set +e
  # shellcheck disable=SC2086
  out=$(run_sweep -- $bad_flag); rc=$?
  set -e
  assert_eq "$rc" "2" "ms21: '$bad_flag' is a config error, never a clamp"
done
set +e
out=$(run_sweep -- --nonsense); rc=$?
set -e
assert_eq "$rc" "2" "ms21b: an unknown argument exits 2"

fresh_state
mkdir -p "$TMP_ROOT/state"
printf 'x\n' > "$TMP_ROOT/state/acme_widgets"
chmod 000 "$TMP_ROOT/state/acme_widgets"
if [ -r "$TMP_ROOT/state/acme_widgets" ]; then
  # Running as root (or on a filesystem that ignores the mode) makes this
  # arm unreachable; say so rather than assert a pass the environment
  # cannot produce.
  echo "  skip  ms22: the state file stayed readable at mode 000 (root, or a permissionless filesystem)"
else
  set +e
  out=$(run_sweep); rc=$?
  set -e
  assert_eq "$rc" "2" "ms22: an unreadable state file exits 2, never a silent fresh baseline"
  assert_contains "$out" "state file" "ms22: and names it"
fi
chmod 644 "$TMP_ROOT/state/acme_widgets"
fresh_state

# --- ms23: the contract is readable with no environment ------------------

set +e
out=$( (cd "$TMP_ROOT/cwd" && env -u GH_REPO "$SWEEP" --help) ); rc=$?
set -e
assert_eq "$rc" "0" "ms23: --help exits 0 with GH_REPO unset"
assert_contains "$out" "Usage: merged-sweep.sh" "ms23: --help prints usage"
assert_contains "$out" "post-merge-findings" "ms23: --help names the attention kind"
assert_contains "$out" "GLOBAL failures" "ms23: --help carries the exit-2 shapes"
set +e
out=$( (cd "$TMP_ROOT/cwd" && env -u GH_REPO "$SWEEP" -h) ); rc=$?
set -e
assert_eq "$rc" "0" "ms23b: -h exits 0"

# --- ms24: one query per invocation, whatever the PR count ---------------

fresh_state
fixture "$(envelope "$(pr 10 "$MERGED_AT" dev "[$LATE_REVIEW]" '[]' '[]')" \
  "$(pr 12 "$MERGED_AT" dev '[]' '[]' "[$(thread THR_x 1 "$(comment "$AFTER_MERGE" "bad" codex Bot)")]")")"
: > "$TMP_ROOT/calls.log"
set +e
out=$(run_sweep STUB_CALL_LOG="$TMP_ROOT/calls.log"); rc=$?
set -e
assert_eq "$rc" "1" "ms24: two PRs with findings exit 1"
assert_eq "$(grep -c . "$TMP_ROOT/calls.log")" "1" "ms24: the whole sweep is ONE query, whatever the PR count"
assert_eq "$(grep -c 'post-merge-findings' <<<"$out")" "2" "ms24: one line per PR"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
