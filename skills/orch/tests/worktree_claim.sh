#!/usr/bin/env bash
# Regression tests for worktree-claim: the delegation-side possession gate over
# the worktree skill's session guard. Two sessions working the same issue share
# one lease owner, so the owner match alone cannot refuse a sibling writer; the
# per-claim generation token can. worktree-claim binds a caller to the token it
# claimed under and fails closed (exit 75) when any other holder — a different
# issue's lease, a foreign lock, a sibling's re-claim, or a lease released
# underneath an expectation — would make the caller a second writer.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
CLAIM="$REPO_ROOT/skills/orch/scripts/worktree-claim"
GUARD="$REPO_ROOT/skills/worktree/scripts/worktree-session-guard"
STATE="$REPO_ROOT/skills/orch/scripts/workflow-state"
export WORKTREE_SESSION_GUARD="$GUARD"

# Isolate fixtures from system and developer git configuration.
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    pass "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

# Run worktree-claim capturing stdout, stderr, and exit status.
run_out="$TMP_ROOT/run.out"
run_err="$TMP_ROOT/run.err"
RUN_RC=0
run_claim() {
  RUN_RC=0
  "$CLAIM" "$@" >"$run_out" 2>"$run_err" || RUN_RC=$?
}

lease_gen() {
  "$GUARD" status "$1" --owner "$2" 2>/dev/null | jq -r '.generation'
}

echo "=== fixture ==="

main_repo="$TMP_ROOT/repo"
git init -q "$main_repo"
git -C "$main_repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m seed
wt_a="$TMP_ROOT/wt-a"
wt_b="$TMP_ROOT/wt-b"
wt_c="$TMP_ROOT/wt-c"
wt_d="$TMP_ROOT/wt-d"
git -C "$main_repo" worktree add -q -b vst-1 "$wt_a"
git -C "$main_repo" worktree add -q -b vst-2 "$wt_b"
git -C "$main_repo" worktree add -q -b vst-3 "$wt_c"
git -C "$main_repo" worktree add -q -b vst-4 "$wt_d"
pass "four linked worktrees created"

echo
echo "=== controls: the gate is consulted, not vacuous ==="

# The guard refuses the main checkout, so the wrapper must fail there — a
# wrapper that exits 0 here is not talking to the guard at all.
run_claim --worktree "$main_repo" --issue VST-1
assert_eq "$RUN_RC" "1" "main checkout is refused (guard is actually consulted)"

# A guard that cannot run fails closed, never silently unguarded.
WORKTREE_SESSION_GUARD="$TMP_ROOT/no-such-guard" run_claim --worktree "$wt_a" --issue VST-1
assert_eq "$RUN_RC" "1" "unrunnable guard fails closed with exit 1"

echo
echo "=== usage ==="

run_claim --worktree "$wt_a"
assert_eq "$RUN_RC" "1" "missing --issue is a usage error"
run_claim --issue VST-1
assert_eq "$RUN_RC" "1" "missing --worktree is a usage error"
run_claim --worktree "$wt_a" --issue VST-1 --expect-gen not-a-token
assert_eq "$RUN_RC" "1" "malformed --expect-gen is a usage error"
run_claim --worktree "$TMP_ROOT/absent" --issue VST-1
assert_eq "$RUN_RC" "1" "a worktree path that does not exist is a usage error"

echo
echo "=== first possession: claim prints the generation token ==="

run_claim --worktree "$wt_a" --issue VST-1
assert_eq "$RUN_RC" "0" "fresh claim succeeds"
tok_1="$(cat "$run_out")"
assert_eq "$(wc -l <"$run_out" | tr -d ' ')" "1" "stdout is exactly one line"
assert_eq "$([[ "$tok_1" =~ ^[0-9]+-[0-9a-f]+$ ]] && echo ok)" "ok" "printed token matches the lease generation grammar"
assert_eq "$(lease_gen "$wt_a" VST-1)" "$tok_1" "printed token is the lease's recorded generation"

echo
echo "=== continuation: --expect-gen verifies and refreshes ==="

run_claim --worktree "$wt_a" --issue VST-1 --expect-gen "$tok_1"
assert_eq "$RUN_RC" "0" "matching --expect-gen succeeds"
assert_eq "$(cat "$run_out")" "$tok_1" "refresh carries the same token"
assert_eq "$(lease_gen "$wt_a" VST-1)" "$tok_1" "the lease generation is unchanged by a refresh"

echo
echo "=== sibling re-claim fails the displaced session closed ==="

# A sibling session on the SAME issue takes possession directly through the
# guard: the same-owner claim mints a new generation.
"$GUARD" claim "$wt_a" --owner VST-1 >/dev/null
tok_2="$(lease_gen "$wt_a" VST-1)"
# Control: the displacement is real before asserting the compare refuses.
assert_eq "$([[ "$tok_2" != "$tok_1" ]] && echo displaced)" "displaced" \
  "control: the sibling claim minted a different generation"

run_claim --worktree "$wt_a" --issue VST-1 --expect-gen "$tok_1"
assert_eq "$RUN_RC" "75" "the displaced session's next stamp exits 75"
if grep -q -- "$tok_1" "$run_err" && grep -q -- "$tok_2" "$run_err"; then
  pass "the refusal names both the expected and the recorded generation"
else
  fail "the refusal must name expected ($tok_1) and recorded ($tok_2) generations: $(cat "$run_err")"
fi

run_claim --worktree "$wt_a" --issue VST-1 --expect-gen "$tok_2"
assert_eq "$RUN_RC" "0" "the claiming sibling's own token still verifies"

echo
echo "=== token-less repossession displaces, then the old token is dead ==="

run_claim --worktree "$wt_a" --issue VST-1
assert_eq "$RUN_RC" "0" "possession without --expect-gen re-claims a same-owner lease"
tok_3="$(cat "$run_out")"
assert_eq "$([[ "$tok_3" != "$tok_2" ]] && echo minted)" "minted" "repossession mints a fresh generation"
run_claim --worktree "$wt_a" --issue VST-1 --expect-gen "$tok_2"
assert_eq "$RUN_RC" "75" "the displaced sibling's token now exits 75"

echo
echo "=== foreign owner and foreign lock refuse ==="

"$GUARD" claim "$wt_b" --owner VST-2 >/dev/null
run_claim --worktree "$wt_b" --issue VST-1
assert_eq "$RUN_RC" "75" "a different issue's live lease exits 75"
if grep -q 'VST-2' "$run_err"; then
  pass "the refusal names the owning issue"
else
  fail "the refusal must name the owner VST-2: $(cat "$run_err")"
fi
run_claim --worktree "$wt_b" --issue VST-1 --expect-gen "$tok_3"
assert_eq "$RUN_RC" "75" "a different issue's lease exits 75 under --expect-gen too"
assert_eq "$(grep -c 'claimed by another owner' "$run_err")" "1" \
  "a foreign owner is diagnosed as a foreign owner, not as a stale generation"

git -C "$main_repo" worktree lock --reason "manual hold" "$wt_c"
run_claim --worktree "$wt_c" --issue VST-1
assert_eq "$RUN_RC" "75" "a lock taken outside the guard exits 75"
run_claim --worktree "$wt_c" --issue VST-1 --expect-gen "$tok_3"
assert_eq "$RUN_RC" "75" "a foreign lock exits 75 under --expect-gen too"
assert_eq "$(grep -c 'locked outside the session guard' "$run_err")" "1" \
  "a foreign lock is diagnosed as a foreign lock, not as a stale generation"

echo
echo "=== a lease released underneath an expectation refuses ==="

"$GUARD" release "$wt_a" --owner VST-1 >/dev/null 2>&1
run_claim --worktree "$wt_a" --issue VST-1 --expect-gen "$tok_3"
assert_eq "$RUN_RC" "75" "expected generation with no lease at all exits 75"
assert_eq "$(grep -c 'carries no session lease' "$run_err")" "1" \
  "a released lease is diagnosed as a missing lease, not as a stale generation"
run_claim --worktree "$wt_a" --issue VST-1
assert_eq "$RUN_RC" "0" "deliberate token-less repossession recovers the released tree"
"$GUARD" release "$wt_a" --owner VST-1 >/dev/null 2>&1

echo
echo "=== a sibling landing during the refresh is caught by the re-read ==="

# The refresh carries the CURRENT lease generation across untouched, so a
# sibling that claims between the pre-refresh read and the refresh leaves this
# call holding a token the lease no longer records. The post-refresh re-read is
# the only thing that sees it. A shim forwards to the real guard and lets a
# sibling claim land in exactly that window.
shim="$TMP_ROOT/guard-shim"
cat >"$shim" <<EOF
#!/usr/bin/env bash
set -uo pipefail
rc=0
"$GUARD" "\$@" || rc=\$?
if [ "\${1:-}" = refresh ] && [ "\$rc" -eq 0 ] && [ -n "\${SHIM_SIBLING_OWNER:-}" ]; then
  "$GUARD" claim "\$2" --owner "\$SHIM_SIBLING_OWNER" >/dev/null 2>&1 || true
fi
exit "\$rc"
EOF
chmod +x "$shim"

run_claim --worktree "$wt_a" --issue VST-1
tok_4="$(cat "$run_out")"
assert_eq "$RUN_RC" "0" "fixture: the tree is possessed again"

# Control: the shim is transparent when it injects no sibling, so the failure
# below is the injected claim and not the shim itself.
WORKTREE_SESSION_GUARD="$shim" run_claim --worktree "$wt_a" --issue VST-1 --expect-gen "$tok_4"
assert_eq "$RUN_RC" "0" "control: the passthrough shim verifies exactly as the guard does"
assert_eq "$(cat "$run_out")" "$tok_4" "control: the passthrough shim returns the same token"

WORKTREE_SESSION_GUARD="$shim" SHIM_SIBLING_OWNER=VST-1 \
  run_claim --worktree "$wt_a" --issue VST-1 --expect-gen "$tok_4"
assert_eq "$RUN_RC" "75" "a sibling claim landing during the refresh exits 75"
assert_eq "$([[ "$(lease_gen "$wt_a" VST-1)" != "$tok_4" ]] && echo displaced)" "displaced" \
  "control: the injected sibling really did displace the lease"
"$GUARD" release "$wt_a" --owner VST-1 >/dev/null 2>&1

echo
echo "=== workflow state binds the token across rounds ==="

state_dir="$wt_d/tmp"
mkdir -p "$state_dir"
(cd "$wt_d" && "$STATE" init VST-4 --worktree "$wt_d" --branch vst-4) >/dev/null
state_file="$state_dir/workflow-state-VST-4.json"
assert_eq "$([[ -f "$state_file" ]] && echo ok)" "ok" "control: workflow state exists for the round"
assert_eq "$(jq -r '.worktree_gen // "absent"' "$state_file")" "absent" \
  "control: state carries no lease token before the first stamp"

run_claim --worktree "$wt_d" --issue VST-4
assert_eq "$RUN_RC" "0" "the first stamp takes possession"
tok_d="$(cat "$run_out")"
assert_eq "$(jq -r '.worktree_gen // "absent"' "$state_file")" "$tok_d" \
  "the first stamp records the token in workflow state"

# The second stamp passes no token: it must read the stored one and VERIFY,
# not mint a replacement, or a sibling could never be detected.
run_claim --worktree "$wt_d" --issue VST-4
assert_eq "$RUN_RC" "0" "the next stamp succeeds while the session still holds the tree"
assert_eq "$(cat "$run_out")" "$tok_d" "the next stamp reports the stored token, not a new one"
assert_eq "$(lease_gen "$wt_d" VST-4)" "$tok_d" "the next stamp did not mint over the lease"

# A sibling session takes the tree through the guard; the bound session's next
# stamp must refuse rather than delegate a second writer into it.
"$GUARD" claim "$wt_d" --owner VST-4 >/dev/null
tok_d2="$(lease_gen "$wt_d" VST-4)"
assert_eq "$([[ "$tok_d2" != "$tok_d" ]] && echo displaced)" "displaced" \
  "control: the sibling claim displaced the stored token"
run_claim --worktree "$wt_d" --issue VST-4
assert_eq "$RUN_RC" "75" "a state-bound stamp exits 75 once a sibling has re-claimed"
assert_eq "$(jq -r '.worktree_gen' "$state_file")" "$tok_d" \
  "the refused stamp leaves the stored token untouched"

# --state-dir reaches the same file the workflow-state CLI resolves.
run_claim --worktree "$wt_d" --issue VST-4 --state-dir tmp
assert_eq "$RUN_RC" "75" "--state-dir resolves the same bound token"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
