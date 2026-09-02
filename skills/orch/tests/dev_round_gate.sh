#!/usr/bin/env bash
# Regression tests for the one thing that authorizes a fix round: the round
# record dev-round-write stamps at delegation time. dev-artifact-check reads it
# for both the delegated item set and the protected additions the round may
# make, so anything that lets a check run WITHOUT that record, or lets a record
# reach the additions probe carrying a base_sha or an adds path the reader's
# own rules forbid, is a bypass of the whole gate rather than one weak
# assertion.
#
# Each case here pairs a control that must pass with a mutation of exactly one
# input that must refuse, so a refusal cannot be credited to the wrong arm.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
CHECK="$REPO_ROOT/skills/orch/scripts/dev-artifact-check"
ROUND_WRITE_BIN="$REPO_ROOT/skills/orch/scripts/dev-round-write"
ROUND_WRITE=round_write
RETURN_WRITE="$REPO_ROOT/skills/orch/scripts/dev-return-write"
STATE="$REPO_ROOT/skills/orch/scripts/workflow-state"
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

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

round_write() {
  growth_round_write "$STATE" "$ROUND_WRITE_BIN" "$@"
}

reason() {
  "$CHECK" "$@" 2>/dev/null | jq -r '.reason'
}

echo "=== dev round gate ==="

wt="$TMP_ROOT/wt"
mkdir -p "$wt"
git -C "$wt" init -q -b main
git -C "$wt" config user.email test@example.com
git -C "$wt" config user.name Test
git -C "$wt" config commit.gpgsign false
git -C "$wt" commit -q --allow-empty -m base
init_growth_state "$STATE" "$wt" issue-826 seed 1000000

# A round that added a protected file it was never authorized to add. Every
# case below asks whether some other spelling of the check lets it through.
"$ROUND_WRITE" --worktree "$wt" --issue issue-826 --round-id 1-1 --item 1 "fix finding" "tools/guard on a staged render" >/dev/null
mkdir -p "$wt/tools"
printf 'sneaky\n' > "$wt/tools/sneaky-check"
git -C "$wt" add tools/sneaky-check
git -C "$wt" commit -q -m sneaky
head_sha="$(git -C "$wt" rev-parse HEAD)"
"$RETURN_WRITE" --worktree "$wt" --kind fix --issue issue-826 --round-id 1-1 --branch b \
  --commit "$head_sha" --validate pass --item 1 Applied done >/dev/null

assert_eq "$(reason --worktree "$wt" --issue issue-826 --round-id 1-1 --expect-items-from-round)" \
  "unapproved_additions" "control: the bound check refuses the unlisted addition"

# --- omitting the flag is not a way past the gate ---------------------------
# Without --expect-items-from-round there is no delegated set and no authorized
# additions list, so validate_artifact would fall back to the weak
# non-empty-items rule and never run the additions probe at all.
set +e
flagless_out="$("$CHECK" --worktree "$wt" --issue issue-826 --round-id 1-1 2>/dev/null)"
flagless_rc=$?
set -e
assert_eq "$flagless_rc" "2" "a flagless fix receipt over an unlisted addition refuses with exit 2"
assert_eq "$([[ -z "$flagless_out" ]] && echo silent || jq -r '.ok' <<<"$flagless_out")" "silent" \
  "the flagless refusal reports no verdict at all, never ok=true"

# An implement round writes no round record, so it stays flagless.
"$RETURN_WRITE" --worktree "$wt" --kind implement --issue issue-826 --round-id 2-2 --branch b \
  --commit "$head_sha" --validate pass >/dev/null
assert_eq "$(env ORCH_STATE_DIR="$wt/tmp" "$CHECK" --worktree "$wt" --issue issue-826 \
  --round-id 2-2 | jq -r '.reason')" "valid" \
  "a flagless implement receipt is unaffected by the fix-round requirement"

# --- the record's base_sha is a git revision, not a free string -------------
# It reaches `git diff` as an argument. A value git parses as an OPTION never
# reaches revision parsing: git exits 0 over an empty probe, the additions list
# comes back empty, and the gate reports valid over a round that added anything
# it liked. A `--` separator cannot stand in for the grammar: git does stop
# option parsing there, but everything after it is a pathspec, so the revision
# pair could not be passed at all.
record="$wt/tmp/dev-round-issue-826-1-1.json"
cp "$record" "$TMP_ROOT/record-honest.json"
for bad_base in "--output=$TMP_ROOT/sink" "HEAD" "0123456789abcdef0123456789abcdef0123456Z" ""; do
  jq --arg base "$bad_base" '.base_sha = $base' "$TMP_ROOT/record-honest.json" > "$TMP_ROOT/bad.json"
  cp "$TMP_ROOT/bad.json" "$record"
  set +e
  "$CHECK" --worktree "$wt" --issue issue-826 --round-id 1-1 --expect-items-from-round >/dev/null 2>&1
  bad_rc=$?
  set -e
  assert_eq "$bad_rc" "2" "a base_sha outside 40 hex ('$bad_base') refuses before the additions probe"
done
assert_eq "$([[ -e "$TMP_ROOT/sink" ]] && echo wrote || echo no)" "no" \
  "the refused base_sha never reached git as an option"
cp "$TMP_ROOT/record-honest.json" "$record"
assert_eq "$(reason --worktree "$wt" --issue issue-826 --round-id 1-1 --expect-items-from-round)" \
  "unapproved_additions" "restoring the honest base_sha restores the refusal"

# 40 hex naming no object answers no to every git question, "is it an ancestor
# of HEAD" included — which is the orphaned-base stop, where the gate does not
# run. A base this repository cannot answer for is a failed comparison.
jq --arg base "0123456789abcdef0123456789abcdef01234567" '.base_sha = $base' \
  "$TMP_ROOT/record-honest.json" > "$TMP_ROOT/ghost.json"
cp "$TMP_ROOT/ghost.json" "$record"
assert_eq "$(reason --worktree "$wt" --issue issue-826 --round-id 1-1 --expect-items-from-round)" \
  "comparison_failed" "a base_sha naming no object refuses rather than skipping the gate"
cp "$TMP_ROOT/record-honest.json" "$record"

# A trailing newline is the other half of the same bug, in the opposite
# direction: Oniguruma's `$` matches before a string-final newline, so the
# unanchored form accepted a path the writer cannot produce. `$'...'` holds
# the newline that a command substitution would strip.
jq --arg add $'tools/a\n' '.adds = [$add]' "$TMP_ROOT/record-honest.json" > "$TMP_ROOT/adds.json"
cp "$TMP_ROOT/adds.json" "$record"
set +e
"$CHECK" --worktree "$wt" --issue issue-826 --round-id 1-1 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "a record whose adds path ends in a newline fails closed"
set -e

# The same anchoring bug on base_sha: 40 hex plus a trailing newline.
jq --arg base $'0123456789abcdef0123456789abcdef01234567\n' '.base_sha = $base' \
  "$TMP_ROOT/record-honest.json" > "$TMP_ROOT/base.json"
cp "$TMP_ROOT/base.json" "$record"
set +e
"$CHECK" --worktree "$wt" --issue issue-826 --round-id 1-1 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "a base_sha of 40 hex plus a trailing newline fails closed"
set -e
cp "$TMP_ROOT/record-honest.json" "$record"

# --- the record must be a regular file at its own path ----------------------
# Only the symlink changes between the two halves: same bytes, same token, same
# schema. A refusal here can come from nothing but the symlink.
"$ROUND_WRITE" --worktree "$wt" --issue issue-826 --round-id 4-4 --item 1 "later round" "tools/guard on a staged render" >/dev/null
linked_record="$wt/tmp/dev-round-issue-826-4-4.json"
set +e
"$CHECK" --worktree "$wt" --issue issue-826 --round-id 4-4 --expect-items-from-round >/dev/null 2>&1
control_rc=$?
set -e
assert_eq "$([[ "$control_rc" == "2" ]] && echo refused || echo read)" "read" \
  "control: the same record as a regular file passes the record gates"
cp "$linked_record" "$TMP_ROOT/link-target.json"
rm -f "$linked_record"
ln -s "$TMP_ROOT/link-target.json" "$linked_record"
set +e
"$CHECK" --worktree "$wt" --issue issue-826 --round-id 4-4 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "a symlinked round record fails closed"
set -e

# --- the cut round: the size check moves, it is not dropped (KEN-1165) ------
# A branch over its size tripwire can only be brought back by a round that runs
# while it is oversized, and dev-round-write refused to record exactly that
# round. --cut lets the record be written; what stops --cut from becoming a way
# around the tripwire is that acceptance re-measures the branch.
cut_wt="$TMP_ROOT/cut-wt"
mkdir -p "$cut_wt"
git -C "$cut_wt" init -q -b main
git -C "$cut_wt" config user.email test@example.com
git -C "$cut_wt" config user.name Test
git -C "$cut_wt" config commit.gpgsign false
git -C "$cut_wt" commit -q --allow-empty -m base
git -C "$cut_wt" switch -q -c cut
printf 'one\ntwo\n' > "$cut_wt/change.txt"
git -C "$cut_wt" add change.txt
git -C "$cut_wt" commit -q -m implementation
# baseline 2 lines, so the cap is 4; the branch then grows to 5.
init_growth_state "$STATE" "$cut_wt" issue-1165 1-1 2
printf 'three\nfour\nfive\n' >> "$cut_wt/change.txt"
git -C "$cut_wt" add change.txt
git -C "$cut_wt" commit -q -m over-limit

cut_reason() {
  env ORCH_STATE_DIR="$cut_wt/tmp" "$CHECK" "$@" 2>/dev/null | jq -r '.reason'
}

set +e
"$ROUND_WRITE" --worktree "$cut_wt" --issue issue-1165 --round-id 1-1 \
  --item 1 "cut the branch back to the Done-when" "the branch this round shrinks" >/dev/null 2>&1
uncut_rc=$?
set -e
assert_eq "$uncut_rc" "3" "control: the oversized branch refuses an undeclared round"
"$ROUND_WRITE" --worktree "$cut_wt" --issue issue-1165 --round-id 1-1 --cut \
  --item 1 "cut the branch back to the Done-when" "the branch this round shrinks" >/dev/null
assert_eq "$(jq -r '.cut' "$cut_wt/tmp/dev-round-issue-1165-1-1.json")" "true" \
  "the declared cut is recorded, so its item set is still checked at acceptance"

# The cut lands: the branch comes back under the cap and the receipt is accepted.
printf 'one\ntwo\n' > "$cut_wt/change.txt"
git -C "$cut_wt" add change.txt
git -C "$cut_wt" commit -q -m cut
cut_head="$(git -C "$cut_wt" rev-parse HEAD)"
"$RETURN_WRITE" --worktree "$cut_wt" --kind fix --issue issue-1165 --round-id 1-1 --branch cut \
  --commit "$cut_head" --validate pass --item 1 Applied "cut to the Done-when" >/dev/null
assert_eq "$(cut_reason --worktree "$cut_wt" --issue issue-1165 --round-id 1-1 --expect-items-from-round)" \
  "valid" "a cut that brought the branch back to the cap is accepted"

# Must-fail: the same declaration over a round that grew the branch instead.
# Only the round's effect on the branch differs from the arm above.
"$ROUND_WRITE" --worktree "$cut_wt" --issue issue-1165 --round-id 2-2 --cut \
  --item 1 "cut the branch back to the Done-when" "the branch this round shrinks" >/dev/null
printf 'three\nfour\nfive\nsix\n' >> "$cut_wt/change.txt"
git -C "$cut_wt" add change.txt
git -C "$cut_wt" commit -q -m grew
grew_head="$(git -C "$cut_wt" rev-parse HEAD)"
"$RETURN_WRITE" --worktree "$cut_wt" --kind fix --issue issue-1165 --round-id 2-2 --branch cut \
  --commit "$grew_head" --validate pass --item 1 Applied "cut to the Done-when" >/dev/null
assert_eq "$(cut_reason --worktree "$cut_wt" --issue issue-1165 --round-id 2-2 --expect-items-from-round)" \
  "cut_not_shrunk" "a round declared a cut that grew the branch is refused"

# Must-fail: the cap goes unreadable between stamp and acceptance. Nothing about
# the branch changes — only the baseline the cap is computed from. The refusal
# has to be positive: measure_size_tripwire sets BRANCH_GROWTH_CURRENT and
# BRANCH_GROWTH_LIMIT only on success, so a caller that let the failure through
# would compare two empty strings, find them not greater, and accept a cut
# whose branch was never measured.
"$STATE" --state-dir "$cut_wt/tmp" set issue-1165 pr '{"baseline_lines":null}' >/dev/null
assert_eq "$(cut_reason --worktree "$cut_wt" --issue issue-1165 --round-id 2-2 --expect-items-from-round)" \
  "cut_unmeasurable" "a cut whose cap cannot be read is refused, never accepted unmeasured"
# The same unreadable cap at stamp time: --cut skips the over-limit refusal, not
# the measurement, so the environment failure is loud before a round is minted
# rather than after one has been delegated against an immutable record.
set +e
"$ROUND_WRITE" --worktree "$cut_wt" --issue issue-1165 --round-id 3-3 --cut \
  --item 1 "cut the branch back to the Done-when" "the branch this round shrinks" >/dev/null 2>&1
assert_eq "$?" "2" "a declared cut over an unreadable baseline refuses at stamp time"
set -e
assert_eq "$([[ -e "$cut_wt/tmp/dev-round-issue-1165-3-3.json" ]] && echo wrote || echo none)" "none" \
  "the refused cut wrote no record"
"$STATE" --state-dir "$cut_wt/tmp" set issue-1165 pr '{"baseline_lines":2}' >/dev/null

# Must-fail: the record's cut is a boolean, and a hand-edited string is not it.
# Only the field's type differs from the arm above — same token, same items,
# same base_sha — so a refusal here can come from nothing else.
cut_record="$cut_wt/tmp/dev-round-issue-1165-2-2.json"
jq '.cut = "true"' "$cut_record" > "$TMP_ROOT/cut-string.json"
cp "$TMP_ROOT/cut-string.json" "$cut_record"
set +e
env ORCH_STATE_DIR="$cut_wt/tmp" "$CHECK" --worktree "$cut_wt" --issue issue-1165 \
  --round-id 2-2 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "a round record whose cut is a non-boolean fails closed"
set -e

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
