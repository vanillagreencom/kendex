#!/usr/bin/env bash
# Behavioral tests for the SHIPPED skills/review-gate/scripts/merged-sweep.sh
# — the post-merge half of the needs-attention reducer (KEN-1021). One
# stubbed gh serving one GraphQL fixture, every reduction arm driven offline.
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
#   ms22b. an unwritable state file         -> exit 2, and NO stdout lines
#   ms23. --help before GH_REPO and flags   -> exit 0
#   ms24. many PRs                          -> still ONE query
#   ms25.  a PRE-merge thread, re-raised    -> a finding (the re-raise shape)
#   ms26.  older canonical, newer bare      -> a finding (the LAST decides)
#   ms27.  more PRs than --limit reads      -> a sweep line that REPEATS
#   ms28.  --state-file                     -> that file, never the default
#   ms29.  a relative state dir             -> anchored on the repo root
#   ms30.  a repo the read cannot reach     -> exit 2, never quiet silence
#   ms31.  GH_REPO carrying search syntax   -> exit 2 before the query
#   ms32.  a settings-file dir, two cwds    -> ONE baseline, either way
#   ms33.  a missing reduction lib          -> exit 2, never bash's exit 1
#   ms33c. a lib readable but truncated     -> exit 2, naming the symbol
#   ms34.  the QUERY actually sent          -> qualifiers, type, probe, merged:
#   ms35.  drafted pre-merge, published later-> a finding, not createdAt
#   ms36.  a decline with no reason        -> answers nothing, both arms
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$TEST_DIR/.." && pwd)"
SWEEP="$SKILL_ROOT/scripts/merged-sweep.sh"
TMP_ROOT="$(mktemp -d)"
[ -n "$TMP_ROOT" ] || { echo "FATAL: mktemp -d returned an empty path" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

PASS=0
FAIL=0

# shellcheck source=lib/merged-sweep-fixtures.sh
. "$TEST_DIR/lib/merged-sweep-fixtures.sh"

echo "=== merged-sweep reduction table ==="

# --- ms1..ms5: the finding, then the dedupe ------------------------------

LATE_REVIEW="$(review REV_late "$AFTER_MERGE" COMMENTED "P2: this leaks a handle" codex Bot)"
fixture "$(envelope "$(pr 10 "$MERGED_AT" dev "[$LATE_REVIEW]" '[]' '[]')")"

fresh_state
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "1" "ms1: a post-merge review exits 1"
assert_row ms1 "$out" "10" "$HEAD_A8" "post-merge-findings" \
  "1 review(s) and 0 review thread(s) landed after the merge"

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

# From a FRESH baseline, so a --no-state pass that wrongly wrote state would
# change the next pass's answer; run after a stateful one it could not.
fresh_state
set +e
out=$(run_sweep -- --no-state); rc=$?
set -e
assert_eq "$rc" "1" "ms5b: --no-state from a fresh baseline reports the finding"
if [ -e "$TMP_ROOT/state/acme_widgets" ]; then
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "ms5b: --no-state wrote a state file"
else
  PASS=$((PASS + 1)); printf '  ok    %s\n' "ms5b: and wrote no state file"
fi
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "1" "ms5c: so the next STATEFUL pass still calls it news"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "0" "ms5d: and only then goes quiet"

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

# ms9b: a BOT issue comment is no answer, whatever it says. Bots quote each
# other, so a bot writing "Declined:" would otherwise clear a real finding.
fresh_state
fixture "$(envelope "$(pr 11 "$MERGED_AT" dev "[$LATE_REVIEW]" \
  "[$(comment "$LATER" "Declined: handled upstream" helperbot Bot)]" '[]')")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "1" "ms9b: a bot issue comment answers nothing, even in a disposition form"

# ms9c: ordinary chatter after a real answer must not reopen it — the
# STANDING reply is the last one in a REPLY FORM, not the last comment.
fresh_state
fixture "$(envelope "$(pr 11 "$MERGED_AT" dev "[$LATE_REVIEW]" \
  "[$(comment "$(iso -900)" "Declined: the handle is closed on the error path" dev User),$(comment "$LATER" "thanks, that reads better" dev User)]" '[]')")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "0" "ms9c: chatter after a disposition does not reopen the finding"

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

# ms14b: a HUMAN post-merge comment that is not a disposition is a finding,
# not a reply — a thread whose only post-merge content is one must surface.
fresh_state
HUMAN_FINDING="$(thread THR_human 1 "$(comment "$AFTER_MERGE" "this path still double-frees" dev User)")"
fixture "$(envelope "$(pr 12 "$MERGED_AT" dev '[]' '[]' "[$HUMAN_FINDING]")")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "1" "ms14b: a human post-merge comment is a finding, not a reply"
assert_contains "$out" "0 review(s) and 1 review thread(s)" "ms14b: counted as a thread finding"

# ms14c: inside a THREAD a human non-disposition comment is content on a
# line, so it is a finding even after a real reply — the fail-closed
# reading, and deliberately unlike ms9c's conversation arm.
fresh_state
CHATTER="$(thread THR_chatter 3 \
  "$(comment "$AFTER_MERGE" "P2: this leaks" codex Bot)" \
  "$(comment "$(iso -900)" "Fixed in a1b2c3d4e5f6" dev User)" \
  "$(comment "$LATER" "and the retry path has the same shape" dev User)")"
fixture "$(envelope "$(pr 12 "$MERGED_AT" dev '[]' '[]' "[$CHATTER]")")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "1" "ms14c: a human thread comment after a disposition is new content, not chatter to ignore"

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

# ms16b (finding #5): a long thread that opened AND closed before the merge
# hides nothing — comments are read newest-first, so truncation drops only
# older pre-merge ones.
fresh_state
PRE_DEEP="$(thread THR_predeep 60 \
  "$(comment "$BEFORE_MERGE" "a long pre-merge argument" codex Bot)" \
  "$(comment "$BEFORE_MERGE" "Fixed in a1b2c3d4e5f6" dev User)")"
fixture "$(envelope "$(pr 13 "$MERGED_AT" dev '[]' '[]' "[$PRE_DEEP]")")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "0" "ms16b: a pre-merge-only long thread is not post-merge activity"
assert_eq "$out" "" "ms16b: and claims nothing the data contradicts"

# ms16c (finding #6): reviewThreads has no documented order, so a truncated
# thread page fails closed even when the page it returned is mixed.
fresh_state
fixture "$(envelope "$(pr 13 "$MERGED_AT" dev '[]' '[]' "[$PRE_THREAD]" -1 40)")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "1" "ms16c: a truncated thread page fails closed whatever its order"
assert_contains "$out" "beyond the read bound" "ms16c: and says so"

# ms19b (finding #7): a timestamp that will not parse cannot be placed
# either side of the merge, so it surfaces rather than vanishing.
fresh_state
fixture "$(envelope "$(pr 13 "$MERGED_AT" dev \
  "[$(review REV_bad "not-a-date" COMMENTED "P2: this leaks" codex Bot)]" '[]' '[]')")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "1" "ms19b: an unparsable review timestamp fails closed, never a silent drop"
assert_contains "$out" "will not parse" "ms19b: and names the cause"
fresh_state
fixture "$(envelope "$(pr 13 "$MERGED_AT" dev '[]' '[]' \
  "[$(thread THR_badts 1 "$(comment "null" "P1: bad path" codex Bot)")]")")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "1" "ms19c: an unparsable thread-comment timestamp fails closed too"

# --- ms17..ms22: read failures and config errors -------------------------

fresh_state
printf '%s\n' '{"errors":[{"message":"nope"}],"data":{"search":null}}' > "$TMP_ROOT/fixture.json"
run_split
assert_eq "$SPLIT_RC" "2" "ms17: graphql errors beside the data exit 2"
assert_contains "$SPLIT_ERR" "::error::" "ms17: the diagnostic is on STDERR"
assert_eq "$SPLIT_OUT" "" "ms17: and stdout is empty — exit 2 never looks like findings"

# The container arm is reached by a well-formed envelope with no errors key,
# so it shares no coverage with the arm above.
fresh_state
printf '%s\n' '{"data":{"search":null}}' > "$TMP_ROOT/fixture.json"
run_split
assert_eq "$SPLIT_RC" "2" "ms17b: a null search container exits 2 with no errors key to lean on"
assert_contains "$SPLIT_ERR" "::error::" "ms17b: on stderr"
assert_eq "$SPLIT_OUT" "" "ms17b: and stdout is empty"

fresh_state
fixture "$(envelope "$(pr 10 "$MERGED_AT" dev "[$LATE_REVIEW]" '[]' '[]')")"
run_split STUB_EMPTYBYTES=yes
assert_eq "$SPLIT_RC" "2" "ms18: a zero-byte read exits 2"
assert_contains "$SPLIT_ERR" "zero bytes" "ms18: named as a broken read, never as zero PRs"
assert_eq "$SPLIT_OUT" "" "ms18: with stdout empty"

fresh_state
run_split STUB_READ_FAIL=yes
assert_eq "$SPLIT_RC" "2" "ms18b: a failed listing call exits 2"
assert_contains "$SPLIT_ERR" "--limit" "ms18b: and the diagnostic names the knob that fixes a 504"
assert_eq "$SPLIT_OUT" "" "ms18b: with stdout empty"

fresh_state
fixture "$(envelope "$(pr 14 "$MERGED_AT" dev "[$LATE_REVIEW]" '[]' '[]' \
  | jq '.headRefOid = "not-a-sha"')")"
run_split
assert_eq "$SPLIT_RC" "2" "ms19: a row without a usable head sha exits 2 (broken read)"
assert_eq "$SPLIT_OUT" "" "ms19: with stdout empty"

fixture "$(envelope "$(pr 10 "$MERGED_AT" dev "[$LATE_REVIEW]" '[]' '[]')")"
set +e
(cd "$TMP_ROOT/cwd" && PATH="$TMP_ROOT/bin:$PATH" env -u GH_REPO "$SWEEP") \
  >"$TMP_ROOT/split.out" 2>"$TMP_ROOT/split.err"; rc=$?
set -e
assert_eq "$rc" "2" "ms20: a missing GH_REPO exits 2"
assert_contains "$(cat "$TMP_ROOT/split.err")" "GH_REPO is required" "ms20: named on STDERR"
assert_eq "$(cat "$TMP_ROOT/split.out")" "" "ms20: with stdout empty"
for bad in "acme" "acme/widgets/extra" "/widgets" "acme/"; do
  set +e
  out=$(run_sweep GH_REPO="$bad"); rc=$?
  set -e
  assert_eq "$rc" "2" "ms20b: GH_REPO '$bad' is refused"
done

for bad_flag in "--limit 0" "--limit 81" "--limit 101" "--limit abc" "--window 90s" "--window 1234567890123"; do
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
fixture "$(envelope "$(pr 10 "$MERGED_AT" dev "[$LATE_REVIEW]" '[]' '[]')")"
set +e
out=$(run_sweep -- --limit 80); rc=$?
set -e
assert_eq "$rc" "1" "ms21c: --limit 80 is the documented ceiling and is accepted"
fresh_state
set +e
out=$(run_sweep -- --limit 0080 --window 0172800); rc=$?
set -e
assert_eq "$rc" "1" "ms21d: zero-padded numbers are judged by magnitude, not by digit count"
fresh_state
set +e
out=$(run_sweep -- --limit 0081); rc=$?
set -e
assert_eq "$rc" "2" "ms21e: and a zero-padded value over the ceiling is still refused"

fresh_state
mkdir -p "$TMP_ROOT/state"
printf 'x\n' > "$TMP_ROOT/state/acme_widgets"
chmod 000 "$TMP_ROOT/state/acme_widgets"
if [ -r "$TMP_ROOT/state/acme_widgets" ]; then
  # Running as root (or on a filesystem that ignores the mode) makes this
  # arm unreachable; say so rather than assert an unproducible pass.
  echo "  skip  ms22: the state file stayed readable at mode 000 (root, or a permissionless filesystem)"
else
  set +e
  out=$(run_sweep); rc=$?
  set -e
  assert_eq "$rc" "2" "ms22: an unreadable state file exits 2, never a silent fresh baseline"
  assert_contains "$out" "cannot read the state file" "ms22: named as the READ, not any later write"
fi
chmod 644 "$TMP_ROOT/state/acme_widgets"
fresh_state

# ms22c: an unwritable state DIR fails at mkdir, before any read.
mkdir -p "$TMP_ROOT/ro"
chmod 500 "$TMP_ROOT/ro"
if [ -w "$TMP_ROOT/ro" ]; then
  echo "  skip  ms22c: the state directory stayed writable at mode 500 (root, or a permissionless filesystem)"
else
  run_split REVIEW_GATE_MERGED_SWEEP_STATE_DIR="$TMP_ROOT/ro/nested"
  assert_eq "$SPLIT_RC" "2" "ms22c: a state directory that cannot be created exits 2"
  assert_contains "$SPLIT_ERR" "could not create the state directory" "ms22c: named on stderr"
  assert_eq "$SPLIT_OUT" "" "ms22c: with stdout empty"
fi
chmod 755 "$TMP_ROOT/ro"

# ms22d: an explicitly empty state dir is a config error, not a disable —
# --no-state is how a caller runs without state.
run_split REVIEW_GATE_MERGED_SWEEP_STATE_DIR=""
assert_eq "$SPLIT_RC" "2" "ms22d: an explicitly empty state directory is a config error"
assert_contains "$SPLIT_ERR" "explicitly empty" "ms22d: and says so"

# A failed state write must exit 2 with NOTHING on stdout: lines beside a
# non-zero exit read as findings, not as a failure.
fixture "$(envelope "$(pr 10 "$MERGED_AT" dev "[$LATE_REVIEW]" '[]' '[]')")"
set +e
out=$( (cd "$TMP_ROOT/cwd" && PATH="$TMP_ROOT/bin:$PATH" \
  env GH_REPO=acme/widgets STUB_FIXTURE="$TMP_ROOT/fixture.json" \
  "$SWEEP" --state-file "$TMP_ROOT/no-such-dir/state" 2>/dev/null) ); rc=$?
set -e
assert_eq "$rc" "2" "ms22b: an unwritable state file exits 2"
assert_eq "$out" "" "ms22b: and prints NO attention lines — exit 2 is the global-failure shape"
set +e
err=$( (cd "$TMP_ROOT/cwd" && PATH="$TMP_ROOT/bin:$PATH" \
  env GH_REPO=acme/widgets STUB_FIXTURE="$TMP_ROOT/fixture.json" \
  "$SWEEP" --state-file "$TMP_ROOT/no-such-dir/state" 2>&1 >/dev/null) )
set -e
assert_contains "$err" "could not write the state file" "ms22b: the reason is on stderr"

# --- ms28: --state-file, documented but until now untested ---------------
fresh_state
rm -f -- "${TMP_ROOT:?}/explicit-state"
fixture "$(envelope "$(pr 10 "$MERGED_AT" dev "[$LATE_REVIEW]" '[]' '[]')")"
set +e
out=$(run_sweep -- --state-file "$TMP_ROOT/explicit-state"); rc=$?
set -e
assert_eq "$rc" "1" "ms28: --state-file reports the finding on the first pass"
if [ -f "$TMP_ROOT/explicit-state" ]; then
  PASS=$((PASS + 1)); printf '  ok    %s\n' "ms28: and wrote the file it was given"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "ms28: the named state file was not written"
fi
assert_contains "$(cat "$TMP_ROOT/explicit-state" 2>/dev/null)" "REV_late" "ms28: holding the finding key"
if [ -d "$TMP_ROOT/state" ]; then
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "ms28: the default state dir was created despite --state-file"
else
  PASS=$((PASS + 1)); printf '  ok    %s\n' "ms28: and the default state dir was never created"
fi
set +e
out=$(run_sweep -- --state-file "$TMP_ROOT/explicit-state"); rc=$?
set -e
assert_eq "$rc" "0" "ms28b: and the second pass dedupes against it"
rm -f -- "${TMP_ROOT:?}/explicit-state"

# --- ms29: a RELATIVE state dir is anchored on the repository root -------
# The rising edge is the whole point of the state layer, so a loop running
# from a different directory must not silently start from an empty baseline.
git init -q "$TMP_ROOT/repo" 2>/dev/null
mkdir -p "$TMP_ROOT/repo/sub"
AT_REL=(REVIEW_GATE_MERGED_SWEEP_STATE_DIR="sweep-state")
if [ -d "$TMP_ROOT/repo/.git" ]; then
  fixture "$(envelope "$(pr 10 "$MERGED_AT" dev "[$LATE_REVIEW]" '[]' '[]')")"
  run_at "$TMP_ROOT/repo" "${AT_REL[@]}"
  assert_eq "$SPLIT_RC" "1" "ms29: the first pass from the repo root reports the finding"
  if [ -f "$TMP_ROOT/repo/sweep-state/acme_widgets" ]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "ms29: writing under the repository root"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "ms29: no state file under the repository root"
  fi
  run_at "$TMP_ROOT/repo/sub" "${AT_REL[@]}"
  assert_eq "$SPLIT_RC" "0" "ms29b: a second pass from a SUBDIRECTORY keeps the same baseline"
  if [ -d "$TMP_ROOT/repo/sub/sweep-state" ]; then
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "ms29b: a second state dir appeared under the cwd"
  else
    PASS=$((PASS + 1)); printf '  ok    %s\n' "ms29b: and created no second state dir beside the cwd"
  fi
else
  echo "  skip  ms29: git init produced no working tree here"
fi

# ms29c: outside a working tree a relative state dir cannot be anchored, and
# that is a loud config error rather than a silent fall back to the cwd.
mkdir -p "$TMP_ROOT/notrepo"
set +e
(cd "$TMP_ROOT/notrepo" && PATH="$TMP_ROOT/bin:$PATH" \
   env GH_REPO=acme/widgets STUB_FIXTURE="$TMP_ROOT/fixture.json" \
       GIT_CEILING_DIRECTORIES="$TMP_ROOT" REVIEW_GATE_MERGED_SWEEP_STATE_DIR="sweep-state" \
   "$SWEEP") >"$TMP_ROOT/split.out" 2>"$TMP_ROOT/split.err"; rc=$?
set -e
assert_eq "$rc" "2" "ms29c: a relative state dir outside a working tree exits 2"
assert_contains "$(cat "$TMP_ROOT/split.err")" "repository root" "ms29c: naming the anchor it could not resolve"
assert_eq "$(cat "$TMP_ROOT/split.out")" "" "ms29c: with stdout empty"

# --- ms23: the contract is readable with no environment ------------------

set +e
out=$( (cd "$TMP_ROOT/cwd" && env -u GH_REPO "$SWEEP" --help) ); rc=$?
set -e
assert_eq "$rc" "0" "ms23: --help exits 0 with GH_REPO unset"
assert_contains "$out" "Usage: merged-sweep.sh" "ms23: --help prints usage"
assert_contains "$out" "post-merge-findings" "ms23: --help names the attention kind"
assert_contains "$out" "always GLOBAL" "ms23: --help carries the one exit-2 shape"
assert_not_contains "$out" "error\` lines on" "ms23: and promises no per-PR error lines, which no path emits"
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

# --- ms25 (finding #8): the re-raise shape -------------------------------
# A reviewer commenting again on a line it already flagged lands in a
# PRE-merge thread; reading only the opening reported silence over that.
fresh_state
RERAISE="$(thread THR_reraise 2 \
  "$(comment "$BEFORE_MERGE" "nit: name this" codex Bot)" \
  "$(comment "$AFTER_MERGE" "P1: this drops the error on the retry path" codex Bot)")"
fixture "$(envelope "$(pr 12 "$MERGED_AT" dev '[]' '[]' "[$RERAISE]")")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "1" "ms25: a pre-merge thread re-raised after the merge is a finding"
assert_contains "$out" "0 review(s) and 1 review thread(s)" "ms25: counted as a thread finding"

# The same thread whose only post-merge comment IS the answer stays quiet.
fresh_state
ANSWER_ONLY="$(thread THR_answeronly 2 \
  "$(comment "$BEFORE_MERGE" "nit: name this" codex Bot)" \
  "$(comment "$AFTER_MERGE" "Fixed in a1b2c3d4e5f6" dev User)")"
fixture "$(envelope "$(pr 12 "$MERGED_AT" dev '[]' '[]' "[$ANSWER_ONLY]")")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "0" "ms25b: a post-merge comment that IS the answer is not a finding"

# --- ms26 (finding #4): the LAST reply decides, on both arms -------------
fresh_state
SUPERSEDED="$(thread THR_superseded 3 \
  "$(comment "$AFTER_MERGE" "P2: this leaks" codex Bot)" \
  "$(comment "$(iso -900)" "Fixed in a1b2c3d4e5f6" dev User)" \
  "$(comment "$LATER" "tracking that separately" dev User)")"
fixture "$(envelope "$(pr 12 "$MERGED_AT" dev '[]' '[]' "[$SUPERSEDED]")")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "1" "ms26: a canonical reply superseded by a bare track-word no longer answers"

fresh_state
fixture "$(envelope "$(pr 11 "$MERGED_AT" dev "[$LATE_REVIEW]" \
  "[$(comment "$(iso -900)" "Fixed in a1b2c3d4e5f6" dev User),$(comment "$LATER" "tracking that separately" dev User)]" '[]')")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "1" "ms26b: same on the review arm — the newest reply is the standing one"

# And the order that DOES answer: the bare track-word first, canonical last.
fresh_state
fixture "$(envelope "$(pr 11 "$MERGED_AT" dev "[$LATE_REVIEW]" \
  "[$(comment "$(iso -900)" "tracking that separately" dev User),$(comment "$LATER" "Fixed in a1b2c3d4e5f6" dev User)]" '[]')")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "0" "ms26c: a canonical reply newer than the bare one answers"

# --- ms27 (finding #2): a window the page could not cover ----------------
fresh_state
STUB_ISSUE_COUNT=86 fixture "$(STUB_ISSUE_COUNT=86 envelope "$(pr 11 "$MERGED_AT" dev '[]' '[]' '[]')")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "1" "ms27: a window holding more merged PRs than the page read fails closed"
assert_contains "$out" "86 merged PR(s) in the window, 1 read" "ms27: naming the count it could not reach"
assert_contains "$out" "UNSWEPT" "ms27: and saying the remainder is unswept"
assert_contains "$out" "raise --limit (max 80)" "ms27: naming the remedy that applies below the ceiling"
assert_row ms27 "$out" "-" "--------" "sweep:window-truncated" "UNSWEPT"

# ms27b: a STANDING condition, not an event — keyed, it fires once only.
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "1" "ms27b: the coverage row REPEATS while the gap holds — it is not an event"
assert_contains "$out" "86 merged PR(s) in the window" "ms27b: naming the same standing gap"
if [ -s "$TMP_ROOT/state/acme_widgets" ]; then
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "ms27b: the coverage row wrote a dedupe key"
else
  PASS=$((PASS + 1)); printf '  ok    %s\n' "ms27b: and wrote no dedupe key of its own"
fi

# ms27f: a gap that WORSENS is the case a constant key hid completely —
# pass 1 at 3, pass 2 at 500, and the second pass must still report.
fresh_state
fixture "$(STUB_ISSUE_COUNT=3 envelope "$(pr 11 "$MERGED_AT" dev '[]' '[]' '[]')")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "1" "ms27f: a small gap reports"
fixture "$(STUB_ISSUE_COUNT=500 envelope "$(pr 11 "$MERGED_AT" dev '[]' '[]' '[]')")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "1" "ms27f: and a gap that worsened is never silent"
assert_contains "$out" "500 merged PR(s) in the window" "ms27f: reporting the WORSE count, not the old one"

# At the ceiling the only remedy left is the window, and the line says that
# rather than telling the operator to raise a limit already at its maximum.
# Its own fixture, so reordering or editing ms27 cannot change what it tests.
fresh_state
fixture "$(STUB_ISSUE_COUNT=86 envelope "$(pr 11 "$MERGED_AT" dev '[]' '[]' '[]')")"
set +e
out=$(run_sweep -- --limit 80); rc=$?
set -e
assert_eq "$rc" "1" "ms27e: a window over the ceiling still fails closed"
assert_contains "$out" "already at its 80 ceiling" "ms27e: at the ceiling the remedy named is the window"
assert_not_contains "$out" "raise --limit" "ms27e: and never tells the operator to raise a maxed-out limit"

fresh_state
fixture "$(STUB_HAS_NEXT=true envelope "$(pr 11 "$MERGED_AT" dev '[]' '[]' '[]')")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "1" "ms27c: hasNextPage alone also fails closed"

fresh_state
fixture "$(envelope "$(pr 11 "$MERGED_AT" dev '[]' '[]' '[]')")"
set +e
out=$(run_sweep); rc=$?
set -e
assert_eq "$rc" "0" "ms27d: a page that reached the whole window says nothing"

# --- ms30: the repository boundary fails CLOSED --------------------------
# search answers an unreadable repository with issueCount 0, no errors and
# gh exit 0 — a quiet window's shape. Only the probe tells them apart.
fresh_state
fixture "$(STUB_NO_REPO=yes envelope)"
run_split
assert_eq "$SPLIT_RC" "2" "ms30: a repository the read could not reach exits 2, never quiet silence"
assert_contains "$SPLIT_ERR" "could not be read" "ms30: naming the repository as the cause"
assert_eq "$SPLIT_OUT" "" "ms30: with stdout empty"
# The must-fail control: the SAME empty set with the probe answering is an
# ordinary quiet window, so the arm above is proving the probe.
fresh_state
fixture "$(envelope)"
run_split
assert_eq "$SPLIT_RC" "0" "ms30b: the same empty result set from a READABLE repo is just a quiet window"

# --- ms31: GH_REPO is spliced into a search query ------------------------
# Search syntax smuggled through it returns a legitimately empty set, so
# without a charset check the sweep exits 0 over an unswept repository.
for bad in "acme/widgets is:draft" "acme/widgets zzzznotarealtoken" "acme/wid gets" "acme/widgets\"x" "acme/widg<ets"; do
  fresh_state
  set +e
  out=$(run_sweep GH_REPO="$bad"); rc=$?
  set -e
  assert_eq "$rc" "2" "ms31: GH_REPO '$bad' is refused before the query"
done
# And the control: every character a real owner/repo name uses still passes.
fresh_state
fixture "$(envelope "$(pr 10 "$MERGED_AT" dev "[$LATE_REVIEW]" '[]' '[]')")"
set +e
out=$(run_sweep GH_REPO="acme-org.io_x/widgets.js-2"); rc=$?
set -e
assert_eq "$rc" "1" "ms31b: a name using every allowed character is accepted"

# --- ms32: the KEY resolves from the repository root, like the path ------
# The value was anchored, the key was not, so an off-root settings-file
# consumer took the default and anchored a DIFFERENT directory.
git init -q "$TMP_ROOT/repo2" 2>/dev/null
mkdir -p "$TMP_ROOT/repo2/sub"
if [ -d "$TMP_ROOT/repo2/.git" ]; then
  printf '[env]\nREVIEW_GATE_MERGED_SWEEP_STATE_DIR = "var/sweepstate"\n' \
    > "$TMP_ROOT/repo2/kendex.settings.toml"
  fixture "$(envelope "$(pr 10 "$MERGED_AT" dev "[$LATE_REVIEW]" '[]' '[]')")"
  run_at "$TMP_ROOT/repo2"
  assert_eq "$SPLIT_RC" "1" "ms32: the first pass from the repo root reports the finding"
  run_at "$TMP_ROOT/repo2/sub"
  assert_eq "$SPLIT_RC" "0" "ms32b: a pass from a SUBDIRECTORY reads the same settings-file baseline"
  if [ -d "$TMP_ROOT/repo2/tmp/review-gate-merged-sweep" ]; then
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "ms32b: the off-root pass fell back to the BUILT-IN default dir"
  else
    PASS=$((PASS + 1)); printf '  ok    %s\n' "ms32b: and never fell back to the built-in default directory"
  fi
else
  echo "  skip  ms32: git init produced no working tree here"
fi

# --- ms33: a missing lib is a read failure, not bash's exit 1 -------------
# Sourced under set -e, a missing lib exits 1 with no stdout — the code
# promising attention lines. Run a COPY, leaving the shipped tree alone.
LIBTEST="$TMP_ROOT/skillcopy"
cp -R "$SKILL_ROOT/scripts" "$LIBTEST"
rm -f "$LIBTEST/lib/merged-sweep-reduce.sh"
fixture "$(envelope "$(pr 10 "$MERGED_AT" dev "[$LATE_REVIEW]" '[]' '[]')")"
SWEEP_REAL="$SWEEP"; SWEEP="$LIBTEST/merged-sweep.sh"
run_split
assert_eq "$SPLIT_RC" "2" "ms33: a missing reduction lib exits 2, not bash's exit 1"
assert_contains "$SPLIT_ERR" "the skill install is incomplete" "ms33: naming the install as the cause"
assert_eq "$SPLIT_OUT" "" "ms33: with stdout empty"
chmod 000 "$LIBTEST/lib/settings.sh"
if [ -r "$LIBTEST/lib/settings.sh" ]; then
  echo "  skip  ms33b: settings.sh stayed readable at mode 000 (root, or a permissionless filesystem)"
else
  run_split
  assert_eq "$SPLIT_RC" "2" "ms33b: an unreadable settings lib exits 2 the same way"
  assert_eq "$SPLIT_OUT" "" "ms33b: with stdout empty"
fi
chmod 644 "$LIBTEST/lib/settings.sh"

# ms33c: readable but TRUNCATED — the only case lib_defines answers, and one
# neither arm above reaches, since ms33 deletes the lib and ms33b unreads it.
head -5 "$SKILL_ROOT/scripts/lib/merged-sweep-reduce.sh" > "$LIBTEST/lib/merged-sweep-reduce.sh"
run_split
assert_eq "$SPLIT_RC" "2" "ms33c: a lib that is readable but defines nothing exits 2"
assert_contains "$SPLIT_ERR" "defines no MERGED_SWEEP_REDUCE_JQ" "ms33c: naming the symbol the lib owes"
assert_eq "$SPLIT_OUT" "" "ms33c: with stdout empty"
SWEEP="$SWEEP_REAL"

# --- ms34: the REQUEST the coverage claim rests on -----------------------
# Every arm above feeds the stub a fixture, which proves nothing about what
# was ASKED for: replacing the qualifier set once left the suite green.
fresh_state
fixture "$(envelope "$(pr 10 "$MERGED_AT" dev "[$LATE_REVIEW]" '[]' '[]')")"
for w in 172800 3600; do
  : > "$TMP_ROOT/argv.log"
  set +e
  run_sweep STUB_ARGV_LOG="$TMP_ROOT/argv.log" -- --no-state --window "$w" >/dev/null 2>&1
  set -e
  assert_sent_query "ms34 (--window $w)" "$w"
done

# --- ms35: the EFFECTIVE PUBLICATION time, not the creation time ---------
# A reviewer drafting during the merge queue and submitting just after it
# is the ordinary shape of this finding, and that review carries createdAt
# < mergedAt. One fixture drives all three cases; the counts pin each.
fresh_state
LATE_SUB="$(review REV_q "$BEFORE_MERGE" COMMENTED "P1: drafted in the queue" codex Bot "$AFTER_MERGE")"
NO_FIELD="$(review REV_nf "$AFTER_MERGE" COMMENTED "P2: late, older shape" codex Bot none)"
LATE_PUB="$(thread THR_q 1 "$(comment "$BEFORE_MERGE" "P2: drafted in the queue" codex Bot "$LATER")")"
fixture "$(envelope "$(pr 14 "$MERGED_AT" dev "[$LATE_SUB,$NO_FIELD]" '[]' "[$LATE_PUB]")")"
run_split
assert_eq "$SPLIT_RC" "1" "ms35: work drafted before the merge and PUBLISHED after it is a finding"
assert_contains "$SPLIT_OUT" "2 review(s) and 1 review thread(s)" "ms35: the review by submittedAt, the thread comment by publishedAt, a field-less shape by createdAt"

assert_decline_reason_arms

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
