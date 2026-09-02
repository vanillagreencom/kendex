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

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
