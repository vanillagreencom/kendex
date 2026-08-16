#!/usr/bin/env bash
# `remove <ID>` derives a lease-release identity from the issue ID (#907) — an
# identity ANY session naming that issue can produce — so before trusting it
# the release asks whether the claiming session is still alive. The lease
# records the claiming SESSION LEADER's pid (a transient CLI pid would be dead
# before anyone could probe it) and the host: a live unrelated pid on this
# host refuses the removal (`remove --force` overrides), while our own
# session, a dead pid, or an ancestor of the removing process proceeds
# exactly as before.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_PACKAGE_DIR="$(cd "$TEST_DIR/.." && pwd)"
WORKTREE_SCRIPT="$WORKTREE_PACKAGE_DIR/scripts/worktree"
GUARD_SCRIPT="$WORKTREE_PACKAGE_DIR/scripts/worktree-session-guard"

TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
SLEEPER_PID=""
# A backgrounded external command is a forked copy of this shell until it
# execs; a signal that lands in that window makes the CHILD run this EXIT
# trap and delete TMP_ROOT under the running test. Only the test process
# itself may clean up.
cleanup() {
  [[ "${BASHPID:-$$}" == "$$" ]] || return 0
  [[ -n "$SLEEPER_PID" ]] && kill "$SLEEPER_PID" 2>/dev/null
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

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

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    pass "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  fi
}

assert_path_exists() {
  [[ -e "$1" ]] && pass "$2" || fail "$2 (missing: $1)"
}

assert_path_absent() {
  [[ ! -e "$1" ]] && pass "$2" || fail "$2 (still exists: $1)"
}

# Exit code of `guard status`: 0 ours, 3 no lock, 4 non-guard lock, 75 foreign.
guard_status_code() {
  local wt="$1" repo="$2" rc=0
  shift 2
  "$GUARD_SCRIPT" status "$wt" --repo "$repo" "$@" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

make_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  git -C "$repo" config commit.gpgsign false
  printf 'base\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m base
}

# The guard records the claiming process's own pid, which is transient. The
# scenario under test is a lease whose recorded pid belongs to a still-running
# session, so the pid is rewritten in place in the registration's lock file —
# the same file `git worktree lock --reason` wrote the lease to.
plant_lease_pid() {
  local lock_file="$1" pid="$2"
  sed "s/ pid=[0-9]* / pid=$pid /" "$lock_file" > "$lock_file.planted"
  mv "$lock_file.planted" "$lock_file"
}

echo "=== a real claim records a session-durable pid ==="

# The vacuity check: the recorded pid must still be ALIVE after the claiming
# guard invocation has exited — recording the guard CLI's own $$ fails this,
# because that process is dead the moment the claim returns, and a liveness
# gate keyed on it never fires on a real lease.
REC_ROOT="$TMP_ROOT/recorded"
make_repo "$REC_ROOT/main"
git -C "$REC_ROOT/main" worktree add -q -b issue-rec "$REC_ROOT/trees/issue-rec" main
REC_WT="$REC_ROOT/trees/issue-rec"
"$GUARD_SCRIPT" claim "$REC_WT" --owner issue-rec >/dev/null
rec_pid="$(sed -n 's/.* pid=\([0-9]*\) .*/\1/p' "$REC_ROOT/main/.git/worktrees/issue-rec/locked")"
if [[ "$rec_pid" =~ ^[1-9][0-9]*$ ]]; then
  pass "the claim records a numeric pid"
else
  fail "the claim records a numeric pid (got: '$rec_pid')"
fi
if ps -o pid= -p "$rec_pid" >/dev/null 2>&1; then
  pass "the recorded pid is alive after the claim returns"
else
  fail "the recorded pid is alive after the claim returns (pid=$rec_pid is dead)"
fi
test_sid="$(ps -o sess= -p $$ 2>/dev/null | tr -d '[:space:]' || true)"
if ! [[ "$test_sid" =~ ^[1-9][0-9]*$ ]]; then
  test_sid="$(ps -o sid= -p $$ 2>/dev/null | tr -d '[:space:]' || true)"
fi
if [[ "$test_sid" =~ ^[1-9][0-9]*$ ]]; then
  assert_eq "$rec_pid" "$test_sid" "the recorded pid is this session's leader"
else
  printf '  SKIP  session id not resolvable via ps here; leader equality not checked\n'
fi

# Same-session teardown with that live recorded pid: the claiming session
# removing its own worktree must stay frictionless.
set +e
rec_out=$(cd "$REC_ROOT/main" && env -u VSTACK_SESSION_OWNER -u HT_SESSION_OWNER \
  "$WORKTREE_SCRIPT" remove issue-rec 2>"$REC_ROOT/rec.err")
rec_code=$?
set -e
assert_eq "$rec_code" "0" "same-session remove <ID> with a live recorded leader exits 0"
assert_contains "$rec_out" "Removed: $REC_WT" "the same-session removal reports the removal"
assert_path_absent "$REC_WT" "the same-session worktree is gone"

echo "=== a live foreign session's issue-keyed lease refuses remove <ID> ==="

ROOT="$TMP_ROOT/live"
make_repo "$ROOT/main"
git -C "$ROOT/main" worktree add -q -b issue-live "$ROOT/trees/issue-live" main
LIVE_WT="$ROOT/trees/issue-live"
"$GUARD_SCRIPT" claim "$LIVE_WT" --owner issue-live >/dev/null
sleep 300 &
SLEEPER_PID=$!
plant_lease_pid "$ROOT/main/.git/worktrees/issue-live/locked" "$SLEEPER_PID"

set +e
live_out=$(cd "$ROOT/main" && env -u VSTACK_SESSION_OWNER -u HT_SESSION_OWNER \
  "$WORKTREE_SCRIPT" remove issue-live 2>"$ROOT/live.err")
live_code=$?
set -e
live_err="$(cat "$ROOT/live.err")"
assert_eq "$live_code" "1" "remove <ID> under a live foreign lease exits nonzero"
assert_contains "$live_err" "claimed by a live session" \
  "the refusal says the claiming session is still running"
assert_contains "$live_err" "(owner=issue-live pid=$SLEEPER_PID)" \
  "the refusal names the owner and the live pid"
assert_contains "$live_err" "remove \"issue-live\" --force" \
  "the refusal names the --force way out"
assert_contains "$live_err" "release \"$LIVE_WT\" --owner \"issue-live\"" \
  "the refusal names the guard's own release command"
if grep -qF "Removed:" <<<"$live_out"; then
  fail "a refused remove does not report a removal"
else
  pass "a refused remove does not report a removal"
fi
assert_path_exists "$LIVE_WT" "the live session's worktree survives"
assert_eq "$(guard_status_code "$LIVE_WT" "$ROOT/main" --owner issue-live)" "0" \
  "the live session's lease survives"

echo "=== remove <ID> --force overrides only the liveness refusal ==="

set +e
force_out=$(cd "$ROOT/main" && env -u VSTACK_SESSION_OWNER -u HT_SESSION_OWNER \
  "$WORKTREE_SCRIPT" remove issue-live --force 2>"$ROOT/force.err")
force_code=$?
set -e
assert_eq "$force_code" "0" "remove --force under a live foreign lease exits 0"
assert_contains "$force_out" "Removed: $LIVE_WT" "remove --force reports the removal"
assert_contains "$(cat "$ROOT/force.err")" "Released session guard lease (owner=issue-live)" \
  "remove --force releases the lease rather than bypassing the guard"
assert_path_absent "$LIVE_WT" "the worktree is gone after --force"
kill "$SLEEPER_PID" 2>/dev/null || true
wait "$SLEEPER_PID" 2>/dev/null || true
SLEEPER_PID=""

echo "=== the env owner matching the issue ID does not skip the liveness gate ==="

# VSTACK_SESSION_OWNER/HT_SESSION_OWNER are set to the ISSUE ID by the
# orchestrating workflows, so a sibling session on the same issue exports the
# very same string. The recorded pid must still decide.
ENV_ROOT="$TMP_ROOT/envowner"
make_repo "$ENV_ROOT/main"
git -C "$ENV_ROOT/main" worktree add -q -b issue-envown "$ENV_ROOT/trees/issue-envown" main
ENV_WT="$ENV_ROOT/trees/issue-envown"
"$GUARD_SCRIPT" claim "$ENV_WT" --owner issue-envown >/dev/null
sleep 300 &
ENV_SLEEPER=$!
plant_lease_pid "$ENV_ROOT/main/.git/worktrees/issue-envown/locked" "$ENV_SLEEPER"

set +e
env_out=$(cd "$ENV_ROOT/main" && VSTACK_SESSION_OWNER=issue-envown \
  "$WORKTREE_SCRIPT" remove issue-envown 2>"$ENV_ROOT/env.err")
env_code=$?
set -e
assert_eq "$env_code" "1" "remove <ID> with VSTACK_SESSION_OWNER equal to the issue ID still refuses"
assert_contains "$(cat "$ENV_ROOT/env.err")" "(owner=issue-envown pid=$ENV_SLEEPER)" \
  "the env-owner path names the live pid it refused on"
if grep -qF "Removed:" <<<"$env_out"; then
  fail "the env-owner removal does not report a removal"
else
  pass "the env-owner removal does not report a removal"
fi
assert_path_exists "$ENV_WT" "the sibling's worktree survives an equal-env-owner removal"
assert_eq "$(guard_status_code "$ENV_WT" "$ENV_ROOT/main" --owner issue-envown)" "0" \
  "the sibling's lease survives an equal-env-owner removal"
kill "$ENV_SLEEPER" 2>/dev/null || true
wait "$ENV_SLEEPER" 2>/dev/null || true

echo "=== compare-and-release refuses a lease re-claimed after the liveness check ==="

# The liveness verdict and the release are two guard calls; a sibling that
# claims in between mints a new lease GENERATION. `release --expect-gen` is
# what makes the pair atomic — it re-reads the generation under the same lock.
# The token is the claim's, not the pid's, because the OS reuses pids.
CAS_ROOT="$TMP_ROOT/cas"
make_repo "$CAS_ROOT/main"
git -C "$CAS_ROOT/main" worktree add -q -b issue-cas "$CAS_ROOT/trees/issue-cas" main
CAS_WT="$CAS_ROOT/trees/issue-cas"
"$GUARD_SCRIPT" claim "$CAS_WT" --owner issue-cas >/dev/null
CAS_LOCK="$CAS_ROOT/main/.git/worktrees/issue-cas/locked"
lease_gen() { sed -n 's/.* gen=\([^ ]*\) .*/\1/p' "$1"; }
cas_gen_before="$(lease_gen "$CAS_LOCK")"
cas_pid_before="$(sed -n 's/.* pid=\([0-9]*\) .*/\1/p' "$CAS_LOCK")"

if [[ -n "$cas_gen_before" ]]; then
  pass "a claim records a lease generation"
else
  fail "a claim records a lease generation"
fi

# A refresh continues the SAME claim, so it must carry the generation across:
# a token that rotated per heartbeat would refuse every release that took more
# than one heartbeat to decide.
"$GUARD_SCRIPT" refresh "$CAS_WT" --owner issue-cas >/dev/null
assert_eq "$(lease_gen "$CAS_LOCK")" "$cas_gen_before" \
  "a refresh carries the generation across unchanged"

# Control: the release DOES go through when the lease still records the
# generation the caller checked — without this the refusals below prove nothing.
set +e
cas_ok_out=$("$GUARD_SCRIPT" release "$CAS_WT" --owner issue-cas --repo "$CAS_ROOT/main" \
  --expect-gen "$cas_gen_before" 2>"$CAS_ROOT/cas-ok.err")
cas_ok_code=$?
set -e
assert_eq "$cas_ok_code" "0" "control: --expect-gen matching the lease releases it"
assert_contains "$cas_ok_out" "released $CAS_WT" "control: the matching release is reported"

# The racing case: re-claim, then release naming the generation seen BEFORE.
"$GUARD_SCRIPT" claim "$CAS_WT" --owner issue-cas >/dev/null
sleep 300 &
CAS_SLEEPER=$!
plant_lease_pid "$CAS_LOCK" "$CAS_SLEEPER"
set +e
"$GUARD_SCRIPT" release "$CAS_WT" --owner issue-cas --repo "$CAS_ROOT/main" \
  --expect-gen "$cas_gen_before" >/dev/null 2>"$CAS_ROOT/cas.err"
cas_code=$?
set -e
assert_eq "$cas_code" "75" "--expect-gen refuses a lease re-claimed since the check"
assert_contains "$(cat "$CAS_ROOT/cas.err")" "re-claimed since it was checked" \
  "the refusal says the lease was re-claimed under the caller"
assert_contains "$(cat "$CAS_ROOT/cas.err")" "expected gen=$cas_gen_before" \
  "the refusal names the generation the caller checked"
assert_eq "$(guard_status_code "$CAS_WT" "$CAS_ROOT/main" --owner issue-cas)" "0" \
  "the re-claimed lease survives the compare-and-release refusal"

# THE PID-REUSE CASE. The replacement claim is planted with the SAME pid the
# caller checked, which is what the OS does when it reuses a freed pid. A pid
# compare passes here and unlocks a live lease; only the generation refuses.
cas_reuse_gen="$(lease_gen "$CAS_LOCK")"
plant_lease_pid "$CAS_LOCK" "$cas_pid_before"
assert_eq "$(sed -n 's/.* pid=\([0-9]*\) .*/\1/p' "$CAS_LOCK")" "$cas_pid_before" \
  "the replacement claim records the same pid the caller checked (reuse)"
if [[ "$cas_reuse_gen" != "$cas_gen_before" ]]; then
  pass "the replacement claim carries a different generation despite the reused pid"
else
  fail "the replacement claim carries a different generation despite the reused pid"
fi
set +e
"$GUARD_SCRIPT" release "$CAS_WT" --owner issue-cas --repo "$CAS_ROOT/main" \
  --expect-gen "$cas_gen_before" >/dev/null 2>"$CAS_ROOT/cas-reuse.err"
cas_reuse_code=$?
set -e
assert_eq "$cas_reuse_code" "75" \
  "a replacement claim on a REUSED pid is still refused (the pid compare would have released it)"
assert_eq "$(guard_status_code "$CAS_WT" "$CAS_ROOT/main" --owner issue-cas)" "0" \
  "the live lease survives the reused-pid release attempt"
kill "$CAS_SLEEPER" 2>/dev/null || true
wait "$CAS_SLEEPER" 2>/dev/null || true

# THE SAME-OWNER RE-CLAIM CASE. A second session for the same issue claims
# while the lease is still LOCKED, which routes through claim's same-owner
# branch rather than a fresh lock. That claim is a replacement session, not a
# heartbeat: it must mint a new generation, or a release decided against the
# previous session's lease would unlock the replacement's live claim.
cas_live_gen="$(lease_gen "$CAS_LOCK")"
"$GUARD_SCRIPT" claim "$CAS_WT" --owner issue-cas >/dev/null
cas_reclaim_gen="$(lease_gen "$CAS_LOCK")"
if [[ -n "$cas_reclaim_gen" && "$cas_reclaim_gen" != "$cas_live_gen" ]]; then
  pass "a same-owner claim on a live lease mints a new generation"
else
  fail "a same-owner claim on a live lease mints a new generation"
fi
set +e
"$GUARD_SCRIPT" release "$CAS_WT" --owner issue-cas --repo "$CAS_ROOT/main" \
  --expect-gen "$cas_live_gen" >/dev/null 2>"$CAS_ROOT/cas-reclaim.err"
cas_reclaim_code=$?
set -e
assert_eq "$cas_reclaim_code" "75" \
  "--expect-gen from before a same-owner re-claim refuses to release"
assert_contains "$(cat "$CAS_ROOT/cas-reclaim.err")" "re-claimed since it was checked" \
  "the same-owner refusal says the lease was re-claimed"
assert_eq "$(guard_status_code "$CAS_WT" "$CAS_ROOT/main" --owner issue-cas)" "0" \
  "the replacement session's lease survives the stale release"

echo "=== a dead recorded pid proceeds as before ==="

DEAD_ROOT="$TMP_ROOT/dead"
make_repo "$DEAD_ROOT/main"
git -C "$DEAD_ROOT/main" worktree add -q -b issue-dead "$DEAD_ROOT/trees/issue-dead" main
DEAD_WT="$DEAD_ROOT/trees/issue-dead"
"$GUARD_SCRIPT" claim "$DEAD_WT" --owner issue-dead >/dev/null
# A pid that died on its own: signalling a just-forked job races its exec —
# the signal either hits the pre-exec child (which then runs this shell's
# EXIT trap) or is lost, leaving the sleeper alive for its full duration.
sleep 0 &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
plant_lease_pid "$DEAD_ROOT/main/.git/worktrees/issue-dead/locked" "$DEAD_PID"

set +e
dead_out=$(cd "$DEAD_ROOT/main" && env -u VSTACK_SESSION_OWNER -u HT_SESSION_OWNER \
  "$WORKTREE_SCRIPT" remove issue-dead 2>"$DEAD_ROOT/dead.err")
dead_code=$?
set -e
assert_eq "$dead_code" "0" "remove <ID> with a dead recorded pid exits 0"
assert_contains "$dead_out" "Removed: $DEAD_WT" "the dead-pid removal reports the removal"
assert_contains "$(cat "$DEAD_ROOT/dead.err")" "Released session guard lease (owner=issue-dead)" \
  "the dead-pid lease is released as the issue identity"
assert_path_absent "$DEAD_WT" "the dead-pid worktree is gone"

echo "=== a recorded pid on our own ancestor chain proceeds ==="

ANC_ROOT="$TMP_ROOT/ancestor"
make_repo "$ANC_ROOT/main"
git -C "$ANC_ROOT/main" worktree add -q -b issue-anc "$ANC_ROOT/trees/issue-anc" main
ANC_WT="$ANC_ROOT/trees/issue-anc"
"$GUARD_SCRIPT" claim "$ANC_WT" --owner issue-anc >/dev/null
# This test shell is an ancestor of the remove invocation below, standing in
# for the claiming session that later removes its own worktree.
plant_lease_pid "$ANC_ROOT/main/.git/worktrees/issue-anc/locked" "$$"

set +e
anc_out=$(cd "$ANC_ROOT/main" && env -u VSTACK_SESSION_OWNER -u HT_SESSION_OWNER \
  "$WORKTREE_SCRIPT" remove issue-anc 2>"$ANC_ROOT/anc.err")
anc_code=$?
set -e
assert_eq "$anc_code" "0" "remove <ID> with a live ancestor pid exits 0"
assert_contains "$anc_out" "Removed: $ANC_WT" "the ancestor-pid removal reports the removal"
assert_contains "$(cat "$ANC_ROOT/anc.err")" "Released session guard lease (owner=issue-anc)" \
  "the ancestor-pid lease is released as the issue identity"
assert_path_absent "$ANC_WT" "the ancestor-pid worktree is gone"

echo "=== end-to-end: a claim from a genuinely foreign session (setsid) ==="

# No planted pids: a real second session claims through the documented path
# and stays alive, and `remove <ID>` from this session must refuse without
# --force and proceed with it.
if command -v setsid >/dev/null 2>&1; then
  E2E_ROOT="$TMP_ROOT/e2e"
  make_repo "$E2E_ROOT/main"
  git -C "$E2E_ROOT/main" worktree add -q -b issue-e2e "$E2E_ROOT/trees/issue-e2e" main
  E2E_WT="$E2E_ROOT/trees/issue-e2e"
  setsid bash -c "echo \$\$ >'$E2E_ROOT/leader.pid'; '$GUARD_SCRIPT' claim '$E2E_WT' --owner issue-e2e >/dev/null 2>&1 && touch '$E2E_ROOT/claimed'; sleep 300" &
  E2E_JOB=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [[ -e "$E2E_ROOT/claimed" ]] && break
    sleep 0.25
  done
  E2E_LEADER="$(cat "$E2E_ROOT/leader.pid" 2>/dev/null || true)"
  if [[ ! -e "$E2E_ROOT/claimed" ]]; then
    fail "the foreign session claimed the worktree"
  else
    pass "the foreign session claimed the worktree"

    set +e
    e2e_out=$(cd "$E2E_ROOT/main" && env -u VSTACK_SESSION_OWNER -u HT_SESSION_OWNER \
      "$WORKTREE_SCRIPT" remove issue-e2e 2>"$E2E_ROOT/e2e.err")
    e2e_code=$?
    set -e
    assert_eq "$e2e_code" "1" "remove <ID> refuses while the foreign session lives"
    assert_contains "$(cat "$E2E_ROOT/e2e.err")" "claimed by a live session" \
      "the end-to-end refusal says the claiming session is still running"
    assert_contains "$(cat "$E2E_ROOT/e2e.err")" "pid=$E2E_LEADER" \
      "the end-to-end refusal names the foreign session leader"
    assert_path_exists "$E2E_WT" "the foreign session's worktree survives"
    assert_eq "$(guard_status_code "$E2E_WT" "$E2E_ROOT/main" --owner issue-e2e)" "0" \
      "the foreign session's lease survives"

    set +e
    e2e_force_out=$(cd "$E2E_ROOT/main" && env -u VSTACK_SESSION_OWNER -u HT_SESSION_OWNER \
      "$WORKTREE_SCRIPT" remove issue-e2e --force 2>"$E2E_ROOT/e2e-force.err")
    e2e_force_code=$?
    set -e
    assert_eq "$e2e_force_code" "0" "remove <ID> --force proceeds over the live foreign session"
    assert_contains "$e2e_force_out" "Removed: $E2E_WT" "the forced end-to-end removal is reported"
    assert_path_absent "$E2E_WT" "the worktree is gone after the forced removal"
  fi
  if [[ "$E2E_LEADER" =~ ^[1-9][0-9]*$ ]]; then
    kill -- -"$E2E_LEADER" 2>/dev/null || kill "$E2E_LEADER" 2>/dev/null || true
  fi
  wait "$E2E_JOB" 2>/dev/null || true
else
  printf 'SKIP: setsid not on PATH; the end-to-end foreign-session scenario was not exercised\n'
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
