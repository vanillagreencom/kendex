#!/usr/bin/env bash
# Lifecycle integration between `worktree` and `worktree-session-guard` (#877).
#
# The shape under test is Option C from the issue: claiming is NOT automatic —
# `create` never takes a lease — while the DESTRUCTIVE operations all respect
# one. That split is the whole design:
#
#   * If `create` claimed, every worktree would stay claimed for life (nothing
#     but an explicit `remove` releases), so a lease-aware `cleanup` would stop
#     collecting merged worktrees entirely unless `--stale` were passed. The
#     alternative — releasing on a provably merged branch — guts the guarantee,
#     because uncommitted work in a merged tree is exactly what the CC-1000
#     incident lost.
#   * The destructive side is where the incident actually was, so that is what
#     is wired: `cleanup` never collects a claimed tree, `remove` releases only
#     its OWN lease, `create --reuse` refuses a foreign one and refreshes its
#     own.
#
# The guard serializes every mutation through flock(1), so this suite can only
# run where flock exists — a capability check, matching worktree_session_guard.sh.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_PACKAGE_DIR="$(cd "$TEST_DIR/.." && pwd)"
WORKTREE_SCRIPT="$WORKTREE_PACKAGE_DIR/scripts/worktree"
GUARD_SCRIPT="$WORKTREE_PACKAGE_DIR/scripts/worktree-session-guard"

if ! command -v flock >/dev/null 2>&1; then
  printf 'SKIP: worktree session guard lifecycle needs flock(1), which is not on PATH\n' >&2
  exit 0
fi

TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
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
  local root="$1"
  mkdir -p "$root/main" "$root/bin" "$root/gh-state"
  git -C "$root/main" init -q -b main
  git -C "$root/main" config user.email test@example.com
  git -C "$root/main" config user.name Test
  git -C "$root/main" config commit.gpgsign false
  printf 'base\n' >"$root/main/base.txt"
  git -C "$root/main" add base.txt
  git -C "$root/main" commit -q -m base
  printf 'WORKTREE_BASE_DIR="../trees"\n' >"$root/main/.env"
  git init -q --bare "$root/origin.git"
  git -C "$root/main" remote add origin "$root/origin.git"
  git -C "$root/main" push -q -u origin main

  cat >"$root/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}:${2:-}" in
  pr:list) ;;
  pr:view) printf 'issue-x\n' ;;
esac
STUB
  chmod +x "$root/bin/gh"
}

# A merged worktree that `cleanup` would collect if nothing held it.
add_merged_tree() {
  local root="$1" name="$2"
  git -C "$root/main" worktree add -q -b "$name" "$root/trees/$name" main
}

echo "=== create does not claim ==="

ROOT="$TMP_ROOT/create"
make_repo "$ROOT"
export PATH="$ROOT/bin:$PATH"
export GH_STATE="$ROOT/gh-state"
export VSTACK_SESSION_OWNER="ISSUE-1"

(cd "$ROOT/main" && "$WORKTREE_SCRIPT" create issue-1 >/dev/null 2>&1)
CREATED="$ROOT/trees/issue-1"
assert_path_exists "$CREATED" "create made the worktree"
# 3 is "no lock at all". Anything else means create took a lease, which would
# make cleanup lease-aware-but-useless for every consumer.
assert_eq "$(guard_status_code "$CREATED" "$ROOT/main")" "3" \
  "create leaves the worktree unclaimed"

echo "=== remove releases its own lease ==="

"$GUARD_SCRIPT" claim "$CREATED" --owner ISSUE-1 >/dev/null
assert_eq "$(guard_status_code "$CREATED" "$ROOT/main" --owner ISSUE-1)" "0" \
  "the lease is held before remove"
set +e
remove_out=$(cd "$ROOT/main" && "$WORKTREE_SCRIPT" remove issue-1 2>"$ROOT/remove.err")
remove_code=$?
set -e
assert_eq "$remove_code" "0" "remove of a self-claimed worktree exits 0"
assert_contains "$remove_out" "Removed: $CREATED" "remove reports the removal"
assert_contains "$(cat "$ROOT/remove.err")" "Released session guard lease (owner=ISSUE-1)" \
  "remove says it released the lease rather than doing it silently"
assert_path_absent "$CREATED" "the self-claimed worktree is gone"

echo "=== remove refuses a foreign lease ==="

FOREIGN_ROOT="$TMP_ROOT/foreign"
make_repo "$FOREIGN_ROOT"
add_merged_tree "$FOREIGN_ROOT" "issue-foreign"
FOREIGN_WT="$FOREIGN_ROOT/trees/issue-foreign"
"$GUARD_SCRIPT" claim "$FOREIGN_WT" --owner OTHER-SESSION >/dev/null
set +e
foreign_out=$(cd "$FOREIGN_ROOT/main" && "$WORKTREE_SCRIPT" remove issue-foreign 2>"$FOREIGN_ROOT/foreign.err")
foreign_code=$?
set -e
foreign_err="$(cat "$FOREIGN_ROOT/foreign.err")"
assert_eq "$foreign_code" "1" "remove of a foreign-claimed worktree exits nonzero"
assert_contains "$foreign_err" "locked worktree" "the refusal names the lock"
assert_contains "$foreign_err" "OTHER-SESSION" "the refusal names the owning session"
assert_contains "$foreign_err" "Nothing in the worktree was modified." \
  "the refusal states the tree was left intact"
assert_path_exists "$FOREIGN_WT" "the foreign-claimed worktree survives"
assert_eq "$(guard_status_code "$FOREIGN_WT" "$FOREIGN_ROOT/main" --owner OTHER-SESSION)" "0" \
  "the foreign lease is left in place"
if grep -qF "Removed:" <<<"$foreign_out"; then
  fail "remove of a foreign-claimed worktree does not report a removal"
else
  pass "remove of a foreign-claimed worktree does not report a removal"
fi

echo "=== issue-addressed calls derive the owner (default install) ==="

# start.md claims with `--owner ISSUE_ID`, and a default install sets no
# session-owner env var — so `remove <ID>` must derive that same identity from
# its own argument, or claim and release never agree (#907).
DERIVE_ROOT="$TMP_ROOT/derive"
make_repo "$DERIVE_ROOT"
export GH_STATE="$DERIVE_ROOT/gh-state"
add_merged_tree "$DERIVE_ROOT" "issue-d1"
D1="$DERIVE_ROOT/trees/issue-d1"
"$GUARD_SCRIPT" claim "$D1" --owner issue-d1 >/dev/null
set +e
(cd "$DERIVE_ROOT/main" && env -u VSTACK_SESSION_OWNER -u HT_SESSION_OWNER \
  "$WORKTREE_SCRIPT" remove issue-d1 >/dev/null 2>"$DERIVE_ROOT/derive.err")
derive_code=$?
set -e
assert_eq "$derive_code" "0" "remove <ID> releases the issue-keyed lease with no session env"
assert_contains "$(cat "$DERIVE_ROOT/derive.err")" "Released session guard lease (owner=issue-d1)" \
  "the released identity is the issue ID the command was addressed with"
assert_path_absent "$D1" "the issue-claimed worktree is gone"

# The session env identity is still honoured when it, not the issue ID, owns
# the lease — the derivation adds an identity, it does not remove one.
add_merged_tree "$DERIVE_ROOT" "issue-d2"
D2="$DERIVE_ROOT/trees/issue-d2"
"$GUARD_SCRIPT" claim "$D2" --owner SESSION-X >/dev/null
set +e
(cd "$DERIVE_ROOT/main" && env -u HT_SESSION_OWNER VSTACK_SESSION_OWNER=SESSION-X \
  "$WORKTREE_SCRIPT" remove issue-d2 >/dev/null 2>"$DERIVE_ROOT/derive2.err")
derive2_code=$?
set -e
assert_eq "$derive2_code" "0" "remove <ID> still honours the session env identity"
assert_contains "$(cat "$DERIVE_ROOT/derive2.err")" "(owner=SESSION-X)" \
  "the env-owned lease is released as the env identity"
assert_path_absent "$D2" "the env-claimed worktree is gone"

# `create <ID> --reuse` derives the same identity, so the session that claimed
# per start.md can re-enter its own worktree without env plumbing.
env -u VSTACK_SESSION_OWNER -u HT_SESSION_OWNER bash -c \
  "cd '$DERIVE_ROOT/main' && '$WORKTREE_SCRIPT' create issue-d3" >/dev/null 2>&1
D3="$DERIVE_ROOT/trees/issue-d3"
assert_path_exists "$D3" "derivation reuse fixture was created"
"$GUARD_SCRIPT" claim "$D3" --owner issue-d3 >/dev/null
set +e
env -u VSTACK_SESSION_OWNER -u HT_SESSION_OWNER bash -c \
  "cd '$DERIVE_ROOT/main' && '$WORKTREE_SCRIPT' create issue-d3 --reuse" >/dev/null 2>"$DERIVE_ROOT/derive3.err"
derive3_code=$?
set -e
assert_eq "$derive3_code" "0" "create <ID> --reuse refreshes the issue-keyed lease with no session env"
assert_eq "$(guard_status_code "$D3" "$DERIVE_ROOT/main" --owner issue-d3)" "0" \
  "the issue-keyed lease survives the reuse"

echo "=== cleanup is lease-aware ==="

CLEAN_ROOT="$TMP_ROOT/cleanup"
make_repo "$CLEAN_ROOT"
add_merged_tree "$CLEAN_ROOT" "issue-free"
add_merged_tree "$CLEAN_ROOT" "issue-held"
HELD="$CLEAN_ROOT/trees/issue-held"
FREE="$CLEAN_ROOT/trees/issue-free"
"$GUARD_SCRIPT" claim "$HELD" --owner LIVE-SESSION >/dev/null

set +e
clean_out=$(cd "$CLEAN_ROOT/main" && "$WORKTREE_SCRIPT" cleanup 2>"$CLEAN_ROOT/cleanup.err")
clean_code=$?
set -e
clean_err="$(cat "$CLEAN_ROOT/cleanup.err")"
assert_eq "$clean_code" "0" "cleanup exits 0 with a held worktree present"
assert_contains "$clean_out" "Cleaned: $FREE" "cleanup still collects unclaimed merged worktrees"
assert_path_absent "$FREE" "the unclaimed merged worktree is gone"
assert_path_exists "$HELD" "the claimed worktree survives cleanup"
assert_contains "$clean_err" "Skipped (a session holds a guard lease): $HELD" \
  "cleanup reports the skip instead of silently passing over it"
assert_contains "$clean_err" "--stale" "the skip message names the recovery path"
assert_eq "$(guard_status_code "$HELD" "$CLEAN_ROOT/main" --owner LIVE-SESSION)" "0" \
  "cleanup does not release the lease it skipped"

echo "=== cleanup --stale respects the TTL ==="

# A fresh lease is not stale at any sane TTL, so --stale must still refuse it.
set +e
fresh_out=$(cd "$CLEAN_ROOT/main" && "$WORKTREE_SCRIPT" cleanup --stale 2>"$CLEAN_ROOT/fresh.err")
fresh_code=$?
set -e
assert_eq "$fresh_code" "0" "cleanup --stale exits 0 with only a fresh lease"
assert_path_exists "$HELD" "cleanup --stale leaves a fresh lease alone"
assert_contains "$(cat "$CLEAN_ROOT/fresh.err")" "not past the" \
  "cleanup --stale explains that the lease is too young"
if grep -qF "Cleaned: $HELD" <<<"$fresh_out"; then
  fail "cleanup --stale does not collect a fresh lease"
else
  pass "cleanup --stale does not collect a fresh lease"
fi

# --ttl-minutes 0 makes every lease stale, which is the abandoned-session path.
set +e
stale_out=$(cd "$CLEAN_ROOT/main" && "$WORKTREE_SCRIPT" cleanup --stale --ttl-minutes 0 2>"$CLEAN_ROOT/stale.err")
stale_code=$?
set -e
assert_eq "$stale_code" "0" "cleanup --stale --ttl-minutes 0 exits 0"
assert_contains "$stale_out" "Cleaned: $HELD" "cleanup --stale collects a past-TTL lease"
assert_path_absent "$HELD" "the abandoned worktree is collected"
assert_contains "$(cat "$CLEAN_ROOT/stale.err")" "Released stale session guard lease: $HELD" \
  "cleanup --stale says which lease it released"

echo "=== cleanup option handling ==="

set +e
bogus_err=$(cd "$CLEAN_ROOT/main" && "$WORKTREE_SCRIPT" cleanup --bogus 2>&1 >/dev/null)
bogus_code=$?
set -e
assert_eq "$bogus_code" "1" "cleanup rejects an unknown option"
assert_contains "$bogus_err" "unknown option '--bogus'" "cleanup names the unknown option"

set +e
ttl_err=$(cd "$CLEAN_ROOT/main" && "$WORKTREE_SCRIPT" cleanup --stale --ttl-minutes abc 2>&1 >/dev/null)
ttl_code=$?
set -e
assert_eq "$ttl_code" "1" "cleanup rejects a non-numeric --ttl-minutes"
assert_contains "$ttl_err" "non-negative integer" "the --ttl-minutes refusal says what is required"

help_out=$(cd "$CLEAN_ROOT/main" && "$WORKTREE_SCRIPT" cleanup --help)
assert_contains "$help_out" "--stale" "cleanup --help documents --stale"
assert_contains "$help_out" "never collected" "cleanup --help states the lease guarantee"

echo "=== create --reuse and leases ==="

REUSE_ROOT="$TMP_ROOT/reuse"
make_repo "$REUSE_ROOT"
export GH_STATE="$REUSE_ROOT/gh-state"
VSTACK_SESSION_OWNER="ISSUE-R" \
  bash -c "cd '$REUSE_ROOT/main' && '$WORKTREE_SCRIPT' create issue-r" >/dev/null 2>&1
REUSE_WT="$REUSE_ROOT/trees/issue-r"

# Another session holds it: reuse must refuse by name and change nothing.
"$GUARD_SCRIPT" claim "$REUSE_WT" --owner OTHER-R >/dev/null
set +e
reuse_err=$(VSTACK_SESSION_OWNER="ISSUE-R" bash -c \
  "cd '$REUSE_ROOT/main' && '$WORKTREE_SCRIPT' create issue-r --reuse" 2>&1 >/dev/null)
reuse_code=$?
set -e
assert_eq "$reuse_code" "75" "reuse of a foreign-claimed worktree exits 75 (active work)"
assert_contains "$reuse_err" "claimed by another session" "the reuse refusal is explicit"
assert_contains "$reuse_err" "OTHER-R" "the reuse refusal names the owning session"
assert_path_exists "$REUSE_WT" "the foreign-claimed worktree survives a refused reuse"

# Our own lease: reuse must REFRESH the heartbeat, not merely tolerate the
# lease. A reuse cycle longer than the TTL would otherwise be swept as
# abandoned while it is still working.
"$GUARD_SCRIPT" release "$REUSE_WT" --owner OTHER-R --force >/dev/null 2>&1
"$GUARD_SCRIPT" claim "$REUSE_WT" --owner ISSUE-R >/dev/null 2>&1
lease_heartbeat() {
  "$GUARD_SCRIPT" status "$REUSE_WT" --repo "$REUSE_ROOT/main" --owner ISSUE-R 2>/dev/null \
    | jq -r '.heartbeat_at'
}
before_heartbeat="$(lease_heartbeat)"
before_claimed="$("$GUARD_SCRIPT" status "$REUSE_WT" --repo "$REUSE_ROOT/main" --owner ISSUE-R 2>/dev/null | jq -r '.claimed_at')"
sleep 1
set +e
VSTACK_SESSION_OWNER="ISSUE-R" bash -c \
  "cd '$REUSE_ROOT/main' && '$WORKTREE_SCRIPT' create issue-r --reuse" >/dev/null 2>"$REUSE_ROOT/reuse-own.err"
reuse_own_code=$?
set -e
after_heartbeat="$(lease_heartbeat)"
after_claimed="$("$GUARD_SCRIPT" status "$REUSE_WT" --repo "$REUSE_ROOT/main" --owner ISSUE-R 2>/dev/null | jq -r '.claimed_at')"
assert_eq "$reuse_own_code" "0" "reuse of a self-claimed worktree succeeds"
assert_eq "$(guard_status_code "$REUSE_WT" "$REUSE_ROOT/main" --owner ISSUE-R)" "0" \
  "reuse leaves our own lease in place"
if [[ -n "$before_heartbeat" && "$after_heartbeat" > "$before_heartbeat" ]]; then
  pass "reuse refreshes the lease heartbeat"
else
  fail "reuse refreshes the lease heartbeat (before=$before_heartbeat after=$after_heartbeat)"
fi
# `refresh` extends the heartbeat without ever unlocking; a re-claim would reset
# claimed_at and momentarily drop the lock, which is what this pins against.
assert_eq "$after_claimed" "$before_claimed" \
  "reuse refreshes in place rather than re-claiming (lock never drops)"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
