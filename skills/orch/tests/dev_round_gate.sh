#!/usr/bin/env bash
# Tests for the one thing that authorizes a fix round: the round
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
ROUND_WRITE=round_write
STATE="$REPO_ROOT/skills/orch/scripts/workflow-state"
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
# The mode a fix round runs is read from the project's settings, and orch-env
# reads the process environment first: a developer's own range command would
# otherwise decide the fix receipts' acceptance.
unset DEV_VALIDATE_RANGE_CMD
VRUN="$(validate_run_dir "$TMP_ROOT/validate-run" full)"
LIVE_SCRIPTS="$(mutant_scripts live)" || exit 1
CHECK="$LIVE_SCRIPTS/dev-artifact-check"
ROUND_WRITE_BIN="$LIVE_SCRIPTS/dev-round-write"
RETURN_WRITE="$LIVE_SCRIPTS/dev-return-write"

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

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
git -C "$wt" config gc.auto 0
git -C "$wt" config maintenance.auto false
git -C "$wt" commit -q --allow-empty -m base
init_growth_state "$STATE" "$wt" issue-826 seed

# A round whose diff adds a protected file it was never authorized to add. Every
# case below asks whether some other spelling of the check lets it through.
"$ROUND_WRITE" --worktree "$wt" --issue issue-826 --round-id 1-1 --item 1 "fix finding" "tools/guard on a staged render" >/dev/null
mkdir -p "$wt/tools"
printf 'sneaky\n' > "$wt/tools/sneaky-check"
git -C "$wt" add tools/sneaky-check
git -C "$wt" commit -q -m sneaky
head_sha="$(git -C "$wt" rev-parse HEAD)"
"$RETURN_WRITE" --worktree "$wt" --kind fix --issue issue-826 --round-id 1-1 --branch b \
  --commit "$head_sha" --validate pass --validate-run-dir "$(round_run_dir "$TMP_ROOT/run-wt-1-1-1" "$wt" issue-826 1-1)" --item 1 Applied done >/dev/null

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
  --commit "$head_sha" --validate pass --validate-run-dir "$VRUN" >/dev/null
assert_eq "$(env ORCH_STATE_DIR="$wt/tmp" "$CHECK" --worktree "$wt" --issue issue-826 \
  --round-id 2-2 | jq -r '.reason')" "valid" \
  "a flagless implement receipt is unaffected by the fix-round requirement"

# --- the record's base_sha is a git revision, not a free string -------------
# It reaches `git diff` as an argument. A value git parses as an OPTION never
# reaches revision parsing: git exits 0 over an empty probe, the additions list
# comes back empty, and the gate reports valid over a round that adds anything
# it likes. A `--` separator cannot stand in for the grammar: git does stop
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

# A trailing newline is the same anchoring in the opposite direction:
# Oniguruma's `$` matches before a string-final newline, so an unanchored form
# accepts a path the writer cannot produce. `$'...'` holds the newline that a
# command substitution would strip.
jq --arg add $'tools/a\n' '.adds = [$add]' "$TMP_ROOT/record-honest.json" > "$TMP_ROOT/adds.json"
cp "$TMP_ROOT/adds.json" "$record"
set +e
"$CHECK" --worktree "$wt" --issue issue-826 --round-id 1-1 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "a record whose adds path ends in a newline fails closed"
set -e

# The same anchoring on base_sha: 40 hex plus a trailing newline.
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

# A cut remains a scope declaration. Its receipt uses the same item and
# addition checks even when the branch grows.
cut_wt="$wt"
"$ROUND_WRITE" --worktree "$cut_wt" --issue issue-826 --round-id 5-5 --cut \
  --item 1 "cut work back to the Done-when" "the branch this round cuts" >/dev/null
cut_record="$cut_wt/tmp/dev-round-issue-826-5-5.json"
assert_eq "$(jq -r '.cut' "$cut_record")" "true" "the scope cut is recorded"
seq 1 1000 > "$cut_wt/growth.txt"
git -C "$cut_wt" add growth.txt
git -C "$cut_wt" commit -q -m growth
cut_head="$(git -C "$cut_wt" rev-parse HEAD)"
"$RETURN_WRITE" --worktree "$cut_wt" --kind fix --issue issue-826 --round-id 5-5 --branch main \
  --commit "$cut_head" --validate pass --validate-run-dir "$(round_run_dir "$TMP_ROOT/run-cut" "$cut_wt" issue-826 5-5)" --item 1 Applied "cut work to scope" >/dev/null
assert_eq "$(reason --worktree "$cut_wt" --issue issue-826 --round-id 5-5 --expect-items-from-round)" \
  "valid" "branch growth does not refuse a scope cut"

# The declaration is still a boolean. The same record and receipt isolate its type.
jq '.cut = "true"' "$cut_record" > "$TMP_ROOT/cut-string.json"
cp "$TMP_ROOT/cut-string.json" "$cut_record"
set +e
"$CHECK" --worktree "$cut_wt" --issue issue-826 --round-id 5-5 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "a round record whose cut is a non-boolean fails closed"
set -e

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
