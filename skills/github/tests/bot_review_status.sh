#!/usr/bin/env bash
# Unit tests for bot_review_status_compute (the multi-bot review-signal
# abstraction) and the multi-reviewer verdict aggregation built on it.
#
# All tests are fixture-driven — they call bot_review_status_compute with
# preloaded JSON inputs and assert on the returned status/signals. No `gh`
# calls are made.
#
# Run:  bash skills/github/tests/bot_review_status.sh
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="$TEST_DIR/fixtures"
LIB="$TEST_DIR/../scripts/lib/github-api.sh"
SCRIPTS_DIR="$TEST_DIR/../scripts"

# get_repo_info / project root helpers in github-api.sh shell out to gh + git.
# Stub project root to the test dir so `set -u` does not blow up at source time.
PROJECT_ROOT="$TEST_DIR"
# shellcheck source=/dev/null
source "$LIB"

PASS=0
FAIL=0

assert_eq() {
    local got="$1" want="$2" name="$3"
    if [[ "$got" == "$want" ]]; then
        PASS=$((PASS + 1))
        printf '  ok    %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" name="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
        printf '  ok    %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
    fi
}

fx() { cat "$FIXTURES/$1"; }

echo "=== bot_review_status_compute ==="

# --- 1. Claude checklist pending then approved ---
echo "Test 1: Claude checklist pending then approved"

out=$(bot_review_status_compute \
    "review-bot[bot]" \
    "$(fx empty.json)" \
    "$(fx claude_pending_comments.json)" \
    "$(fx empty.json)" \
    "$(fx empty.json)" \
    "$(fx empty.json)")
assert_eq "$(echo "$out" | jq -r .status)" "pending" "1a status=pending"
assert_contains "$(echo "$out" | jq -c .signals)" "sticky:pending" "1a signals contain sticky:pending"

out=$(bot_review_status_compute \
    "review-bot[bot]" \
    "$(fx claude_approved_reviews.json)" \
    "$(fx claude_approved_comments.json)" \
    "$(fx empty.json)" \
    "$(fx empty.json)" \
    "$(fx empty.json)")
assert_eq "$(echo "$out" | jq -r .status)" "approved" "1b status=approved (formal review)"
assert_contains "$(echo "$out" | jq -c .signals)" "formal_review:approved" "1b signals contain formal_review:approved"
assert_contains "$(echo "$out" | jq -c .signals)" "sticky:approved" "1b signals contain sticky:approved"

out=$(bot_review_status_compute \
    "claude[bot]" \
    "$(fx empty.json)" \
    "$(fx claude_review_summary_comments.json)" \
    "$(fx empty.json)" \
    "$(fx empty.json)" \
    "$(fx empty.json)")
assert_eq "$(echo "$out" | jq -r .status)" "approved" "1c status=approved (Claude Review Summary comment only)"
assert_contains "$(echo "$out" | jq -c .signals)" "sticky:approved" "1c signals contain sticky:approved"

# --- 2. Codex 👀 only = pending ---
echo "Test 2: Codex eyes-reaction only = pending"
out=$(bot_review_status_compute \
    "chatgpt-codex-connector[bot]" \
    "$(fx empty.json)" \
    "$(fx empty.json)" \
    "$(fx codex_eyes_body_reactions.json)" \
    "$(fx empty.json)" \
    "$(fx empty.json)")
assert_eq "$(echo "$out" | jq -r .status)" "pending" "2 status=pending"
assert_contains "$(echo "$out" | jq -c .signals)" "reaction:eyes" "2 signals contain reaction:eyes"

# --- 3. Codex inline comments = changes ---
echo "Test 3: Codex inline unresolved threads = changes"
out=$(bot_review_status_compute \
    "chatgpt-codex-connector[bot]" \
    "$(fx empty.json)" \
    "$(fx empty.json)" \
    "$(fx codex_eyes_body_reactions.json)" \
    "$(fx empty.json)" \
    "$(fx codex_inline_threads.json)")
assert_eq "$(echo "$out" | jq -r .status)" "changes" "3 status=changes"
assert_eq "$(echo "$out" | jq -r .unresolved_threads)" "1" "3 unresolved_threads=1 (resolved+outdated excluded)"
assert_contains "$(echo "$out" | jq -c .signals)" "inline:1" "3 signals contain inline:1"

# --- 4. Codex 👍 + no unresolved threads = approved ---
echo "Test 4: Codex thumbs-up + no unresolved threads = approved"
out=$(bot_review_status_compute \
    "chatgpt-codex-connector[bot]" \
    "$(fx empty.json)" \
    "$(fx empty.json)" \
    "$(fx codex_thumbs_body_reactions.json)" \
    "$(fx empty.json)" \
    "$(fx empty.json)")
assert_eq "$(echo "$out" | jq -r .status)" "approved" "4 status=approved"
assert_contains "$(echo "$out" | jq -c .signals)" "reaction:+1" "4 signals contain reaction:+1"

# --- 7. No configured reviewers / no signal = unknown (not approved) ---
echo "Test 7: No signal of any kind = unknown"
out=$(bot_review_status_compute \
    "some-bot[bot]" \
    "$(fx empty.json)" \
    "$(fx empty.json)" \
    "$(fx empty.json)" \
    "$(fx empty.json)" \
    "$(fx empty.json)")
assert_eq "$(echo "$out" | jq -r .status)" "unknown" "7 status=unknown"

# --- Aggregation tests (multi-reviewer verdict over compute entries) ---
echo
echo "=== aggregation (verdict + completion) ==="

# Reference aggregate_verdict implementation kept inline so this script does not
# need to source any wrapper (which would also pull in project-env loading).
agg() {
    jq -r '
        [.[] | select(.status != "skipped")] as $effective |
        if   ($effective | any(.status == "changes"))  then "changes"
        elif ($effective | any(.status == "pending"))  then "pending"
        elif ($effective | any(.status == "unknown") and ($effective | all(.status != "approved"))) then "pending"
        elif ($effective | any(.status == "approved")) then "approved"
        else "pending" end
    ' <<<"$1"
}
any_blocking() {
    local n
    n=$(jq '[.[] | select(.status == "pending" or .status == "unknown")] | length' <<<"$1")
    [[ "$n" -gt 0 ]]
}

# --- 5. Claude done but Codex pending = pending verdict + blocking ---
echo "Test 5: Claude approved + Codex pending = pending (blocking, not complete)"
claude_entry=$(bot_review_status_compute \
    "review-bot[bot]" \
    "$(fx claude_approved_reviews.json)" \
    "$(fx claude_approved_comments.json)" \
    "$(fx empty.json)" "$(fx empty.json)" "$(fx empty.json)")
codex_entry=$(bot_review_status_compute \
    "chatgpt-codex-connector[bot]" \
    "$(fx empty.json)" \
    "$(fx empty.json)" \
    "$(fx codex_eyes_body_reactions.json)" \
    "$(fx empty.json)" \
    "$(fx empty.json)")
combined=$(jq -c -n --argjson a "$claude_entry" --argjson b "$codex_entry" '[$a, $b]')
assert_eq "$(agg "$combined")" "pending" "5 verdict=pending"
if any_blocking "$combined"; then
    PASS=$((PASS + 1)); echo "  ok    5 any_blocking=true (would emit timeout, not complete)"
else
    FAIL=$((FAIL + 1)); echo "  FAIL  5 any_blocking should be true"
fi
# pending_reviewers list includes Codex
pending_list=$(echo "$combined" | jq -c '[.[] | select(.status == "pending" or .status == "unknown") | .reviewer]')
assert_eq "$pending_list" '["chatgpt-codex-connector[bot]"]' "5 pending_reviewers=[codex]"

# --- 6. Both terminal = complete ---
echo "Test 6: Claude approved + Codex approved = complete"
codex_entry=$(bot_review_status_compute \
    "chatgpt-codex-connector[bot]" \
    "$(fx empty.json)" \
    "$(fx empty.json)" \
    "$(fx codex_thumbs_body_reactions.json)" \
    "$(fx empty.json)" \
    "$(fx empty.json)")
combined=$(jq -c -n --argjson a "$claude_entry" --argjson b "$codex_entry" '[$a, $b]')
assert_eq "$(agg "$combined")" "approved" "6 verdict=approved"
if any_blocking "$combined"; then
    FAIL=$((FAIL + 1)); echo "  FAIL  6 any_blocking should be false"
else
    PASS=$((PASS + 1)); echo "  ok    6 any_blocking=false (would emit complete)"
fi

# --- 7b. Skipped reviewer does not block ---
echo "Test 7b: Skipped reviewer is excluded from verdict and blocking"
skipped_entry=$(jq -c -n '{reviewer:"chatgpt-codex-connector[bot]",status:"skipped",signals:["config:skipped"],updated_at:"",unresolved_threads:0}')
combined=$(jq -c -n --argjson a "$claude_entry" --argjson b "$skipped_entry" '[$a, $b]')
assert_eq "$(agg "$combined")" "approved" "7b verdict=approved (skipped excluded)"
if any_blocking "$combined"; then
    FAIL=$((FAIL + 1)); echo "  FAIL  7b any_blocking should be false (skipped is terminal)"
else
    PASS=$((PASS + 1)); echo "  ok    7b skipped is treated as terminal"
fi

# --- 7c. Empty reviewer set (no signal anywhere) = pending verdict ---
echo "Test 7c: Empty reviewer set aggregates to pending (not approved)"
assert_eq "$(agg '[]')" "pending" "7c agg([])=pending"

# --- Review-signal auto-detection ---
echo
echo "=== detect_bot_reviewers_from_inputs ==="
detected=$(detect_bot_reviewers_from_inputs "$(fx empty.json)" "$(fx mixed_bot_comments.json)" "$(fx empty.json)" | paste -sd, -)
assert_eq "$detected" "claude[bot]" "detect excludes non-review bot linkback comments"
detected=$(detect_bot_reviewers_from_inputs "$(fx empty.json)" "$(fx untrusted_status_comments.json)" "$(fx empty.json)" | paste -sd, -)
assert_eq "$detected" "" "detect excludes untrusted non-review bot status comment"
selected=$(select_sticky_comment_from_comments "$(fx untrusted_status_comments.json)" "review-bot[bot]" true)
assert_eq "$selected" "" "sticky fallback ignores non-review bot status comment"
detected=$(detect_bot_reviewers_from_inputs "$(fx empty.json)" "$(fx empty.json)" "$(fx codex_eyes_body_reactions.json)" | paste -sd, -)
assert_eq "$detected" "chatgpt-codex-connector[bot]" "detect includes known review bot PR-body reaction"
detected=$(detect_bot_reviewers_from_inputs "$(fx empty.json)" "$(fx empty.json)" "$(fx untrusted_body_reactions.json)" | paste -sd, -)
assert_eq "$detected" "" "detect excludes untrusted bot PR-body reaction"

# --- Reaction normalization (REST + GraphQL forms) ---
echo
echo "=== reaction normalization ==="
assert_eq "$(_normalize_reaction_content THUMBS_UP)" "+1"   "norm THUMBS_UP -> +1"
assert_eq "$(_normalize_reaction_content +1)"        "+1"   "norm +1 -> +1"
assert_eq "$(_normalize_reaction_content EYES)"      "eyes" "norm EYES -> eyes"
assert_eq "$(_normalize_reaction_content eyes)"      "eyes" "norm eyes -> eyes"

# --- compute_sticky_verdict_from_body ---
echo
echo "=== compute_sticky_verdict_from_body ==="
assert_eq "$(compute_sticky_verdict_from_body "View job\n- [ ] todo")" "pending" "checklist with no review section = pending"
assert_eq "$(compute_sticky_verdict_from_body "## Review\n✅ Approved")" "approved" "review section + ✅ + approved = approved"
assert_eq "$(compute_sticky_verdict_from_body "## Review\n⚠️ changes requested")" "changes" "review section + ⚠️ = changes"
assert_eq "$(compute_sticky_verdict_from_body "## Review\n✅ Approved with ⚠️ caveats")" "changes" "mixed signals = changes"
assert_eq "$(compute_sticky_verdict_from_body "$(jq -r '.[0].body' "$FIXTURES/claude_review_summary_comments.json")")" "approved" "Claude Review Summary approved despite unrelated changes prose"
assert_eq "$(compute_sticky_verdict_from_body "Verdict: changes")" "changes" "bare Verdict: changes = changes"
assert_eq "$(compute_sticky_verdict_from_body "Status: changes")" "changes" "bare Status: changes = changes"
assert_eq "$(compute_sticky_verdict_from_body "Recommendation: approve")" "approved" "bare Recommendation: approve = approved"
assert_eq "$(compute_sticky_verdict_from_body "Recommendation: do not approve")" "changes" "negated Recommendation approval = changes"
assert_eq "$(compute_sticky_verdict_from_body "Verdict: approval not recommended")" "changes" "approval-not-recommended verdict = changes"
assert_eq "$(compute_sticky_verdict_from_body "Status: pending approval")" "pending" "pending approval directive stays pending"
assert_eq "$(compute_sticky_verdict_from_body "Status: approval required")" "pending" "approval required directive stays pending"
assert_eq "$(compute_sticky_verdict_from_body "Verdict: approved; no changes requested but cannot merge")" "changes" "real blocker wins over approved plus no changes requested"
assert_eq "$(compute_sticky_verdict_from_body "Status: not ready for approval")" "pending" "not-ready-for-approval text stays pending"
assert_eq "$(compute_sticky_verdict_from_body "Status: not yet approved")" "pending" "not-yet-approved text stays pending"
assert_eq "$(compute_sticky_verdict_from_body "Status: not ready to approve")" "pending" "not-ready-to-approve text stays pending"
assert_eq "$(compute_sticky_verdict_from_body "Verdict: approval denied")" "changes" "approval denied text = changes"
assert_eq "$(compute_sticky_verdict_from_body "Verdict: approval withheld")" "changes" "approval withheld text = changes"
assert_eq "$(compute_sticky_verdict_from_body "Verdict: rejected")" "changes" "rejected verdict = changes"
assert_eq "$(compute_sticky_verdict_from_body "Verdict: denied")" "changes" "denied verdict = changes"
assert_eq "$(compute_sticky_verdict_from_body "Recommendation: no approval")" "changes" "no approval text = changes"

# Guard every shipped GitHub script, including commands that fixture-driven
# unit tests do not otherwise execute, against Bash 4-only syntax.
echo
echo "=== Bash 3.2 portability ==="
# --- shared bash32 pattern set: begin
# Every suite that scans for Bash 4 syntax carries this block verbatim, the
# .agents/skills/ render included.
# tools/tests/bash32-pattern-parity.test.sh holds the copies byte-identical
# and proves the set's teeth once, against the text these files ship. There
# is no file they could source instead: skills install independently, so a
# judge living inside one skill is absent from every install that skips it.
#
# What a text scan cannot decide: whether a script RUNS under Bash 3.2.
# Nothing here does — CI is Linux on Bash 5, and the `bash -n` pass is that
# same shell, so it parses Bash 4 without complaint. A construct assembled at
# runtime — eval, a command held in a variable, a heredoc piped to bash — is
# text this scan does not read as code, and neither is one split over a
# backslash continuation. A clean scan says the source carries no construct
# named below. It says nothing further.
#
# And the set is what it names, not everything Bash 4 added. Parameter
# transformations (${x@Q}), globstar, `wait -n` and `test -v` are outside it
# on purpose; each is its own construct rather than another spelling of one
# below, and adding one means adding its probe and its control with it.
# The Bash 4 builtins and the coproc keyword, bounded by the shell's word
# delimiters on both sides: blank, tab, `|`, `&`, `;`, `(`, `)`, `<`, `>`,
# backquote, and the line ends. That is the whole rule and it comes from the
# grammar, not from spellings.
#
# The bound is the WORD, not the identifier. `coproc=1` is an assignment
# token, `coproc-wrapper` a command name, `x=coproc` a value and
# `run --local` an option: in each the shell reads one word and none of them
# is the keyword, though every one of them ends an identifier. Bounding on
# the identifier flagged all four, which is the failure that matters most
# here — a portability suite that reddens correct Bash 3.2 source is one the
# first person it blocks turns off. The catches are unaffected:
# `coproc(echo hi)`, `coproc FOO`, `x && coproc reader`, `run;coproc cat`.
#
# This is the difference from the operators below, where the grammar gives no
# usable boundary and none is attempted.
PATTERN='(^|[[:blank:]|&;()<>`])(mapfile|readarray|coproc)([[:blank:]|&;()<>]|$)'
# declare/typeset/local/readonly carrying a Bash 4 attribute anywhere in the
# options: A (associative), g (global), n (nameref), l and u (the
# declare-family spelling of case conversion). Bash accepts the attributes in
# one cluster or in separate option words, and it accepts them in any order,
# so -A, -rA, -Ar and -r -A are one declaration written four ways and all
# four are caught. The command word takes the same word boundary as the names
# above, for the same reason: `my-declare -A x` and `run --local -A x` are
# legal Bash 3.2 and an identifier boundary flagged both.
PATTERN="$PATTERN"'|(^|[[:blank:]|&;()<>`])(declare|typeset|local|readonly)[[:blank:]]+([-+][[:alnum:]]+[[:blank:]]+)*[-+][[:alnum:]]*[Aglnu]'
# Automatic FD allocation: exec {fd}< , {fd}> , {fd}>>
PATTERN="$PATTERN"'|(^|[^$])\{[A-Za-z_][A-Za-z0-9_]*\}[<>]'
# Case conversion, one character or every one, either direction. The
# parameter forms come from the manual's lists rather than from recall: a
# name, a subscripted name, a positional, an indirect one, and the special
# ones, $ ! # ? - 0 @ and *. Bash 5.3 answers ${-^}, ${?^} and ${#^} with
# "bad substitution" instead of converting; they are matched all the same,
# since a line carrying one is broken under every bash and no correct 3.2
# source holds one, so taking the whole list reddens nothing legal.
# A subscript may hold one level of nesting, which is what indexing an array
# with another array's element needs: ${arr[x[0]]^}. Deeper than that is a
# stated limit below, not an oversight.
PATTERN="$PATTERN"'|\$\{!?([A-Za-z_][A-Za-z0-9_]*(\[([^][]|\[[^]]*\])*\])?|[0-9]+|[-#?$!@*])(,,?|\^\^?)'
# The pipe-with-stderr, the append-both redirection, and the two case
# terminators, matched plainly. There is no boundary anchor here, and that is
# a decision rather than an omission.
#
# Neighbouring characters cannot separate an operator from the same bytes
# inside a regex literal or a string, because the shell grammar permits
# almost anything on either side of one. `printf x |&]` parses, and so do
# `|&/bin/cat`, `|&'cat'`, `|&>out` and `x\(|& cat`. A right-hand set taken
# from the grammar must therefore admit `]`, and admitting `]` matches the
# bracket expression `[|&]` again. Four rounds of anchoring found the
# boundary too permissive twice and too restrictive twice; a rule that costs
# a door per round is the wrong rule, not an under-specified one.
#
# So the cost moves from an unauditable regex to a visible line. A script
# that spells one of these operators inside its own regex or string data IS
# flagged, and the fix is to write it so it does not: a bracket expression's
# members carry no order, so [;|&(`{] becomes [;(`{&|] and matches exactly
# the same characters. skills/preflight/scripts/preflight carries the six
# sites that needed it. A script that genuinely cannot avoid the spelling has
# no escape hatch here yet, and adding one is a change to make then.
#
# WHAT THIS CANNOT DECIDE, named so the next reader does not file it again.
#
# ONE SENTENCE COVERS ALL OF IT: a text scan reads text, and the shell reads
# words. Every gap below is that, in one direction or the other — a name the
# shell resolves through quote removal that the text does not spell, or text
# that spells a construct the shell never runs. Neither is an oversight and
# neither is chased; the answer to both is a lane that runs these suites
# under a real Bash 3.2, filed as this PR's follow-up.
#
# The misses are checked as misses in
# tools/tests/data/bash32-uncatchable.txt and the over-flags as over-flags in
# bash32-overflagged.txt, so neither list can quietly go stale:
#
#   - a name the shell reaches through quote removal: `'mapfile' -t v`,
#     `"declare" -A c`, `map\file -t v`. Bash strips the quoting before it
#     looks the word up, and doing that is the shell's job, not a scan's.
#   - a construct anywhere in the file text is flagged, comment or string
#     alike: `# never use coproc here`, `x=1  # no coproc`, `printf '%s\n'
#     "use coproc here"`. There is no comment skip, and that is deliberate.
#     A `#` line inside a multiline double-quoted word is LIVE CODE that bash
#     expands, so skipping `#` lines let `${name^^}` through a portability
#     gate in silence. Telling the two apart is lexing, and every cheap
#     approximation of it drops hits — it fails open, just less often. This
#     way the cost is loud, lands on whoever wrote the line, and is fixed by
#     respelling it, as preflight's brackets and orch's comments now are.
#   - an operator inside a regex literal or string data is flagged for the
#     same reason. That is the accepted cost of matching operators plainly,
#     and the fix is to respell the line as preflight's brackets now are.
#   - a subscript nested more than one level, or one whose inner expansion
#     carries a literal `]`, as in ${arr[${x%]}]^}. Balancing brackets is
#     beyond a regular expression, so the depth is bounded and declared
#     rather than guessed at.
#   - a construct assembled at runtime: eval, a command held in a variable, a
#     heredoc piped to bash. The text never appears, so nothing reads it.
#   - a declaration split over a backslash continuation, which a
#     line-oriented scan does not see at all.
#   - whether a script RUNS under Bash 3.2. Nothing here does.
#
# What covers these is not another pattern. Each SKILL.md declares the shell
# floor its scripts run on, and a lane running these suites under a real Bash
# 3.2 on the macOS runner is filed as the follow-up to this PR. Until that
# lands, every construct above has a Bash 3.2 spelling — `2>&1 |` for the
# pipe, `>>file 2>&1` for the redirection, a repeated case body for the
# fallthrough — and a script that writes those needs no verdict here.
PATTERN="$PATTERN"'|\|&|&>>|;;?&'
# --- shared bash32 pattern set: end
# grep's status is part of the answer: 0 found, 1 none, anything else is a
# scan that did not run — and a scan that did not run is not a clean tree.
# `|| true` swallowed that third case, so a malformed shared pattern or an
# unreadable scripts/ reported a clean one. The parity suite catches a
# malformed pattern in THIS repository; an independently installed github
# skill does not ship that suite, so this carrier fails closed on its own.
portability_violations=""
portability_status=0
portability_violations="$(grep -rnE "$PATTERN" "$SCRIPTS_DIR")" || portability_status=$?
if [ "$portability_status" -gt 1 ]; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  the portability scan over %s could not run (grep exited %s)\n' \
        "$SCRIPTS_DIR" "$portability_status"
else
    assert_eq "$portability_violations" "" "all shipped GitHub scripts avoid Bash 4-only constructs"
fi

echo
echo "----"
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
