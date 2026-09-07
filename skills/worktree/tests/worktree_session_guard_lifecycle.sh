#!/usr/bin/env bash
# Lifecycle integration between `worktree` and `worktree-session-guard`: the
# verbs against a lease as one table, then the guard's own surfaces.
#
# The shape under test is Option C from the issue: claiming is NOT automatic —
# `create` never takes a lease — while the DESTRUCTIVE operations all respect
# one. That split is the whole design:
#
#   * If `create` claimed, every worktree would stay claimed for life (nothing
#     but an explicit `remove` releases), so a lease-aware `cleanup` would stop
#     collecting merged worktrees entirely unless `--stale` were passed. The
#     alternative — releasing on a provably merged branch — guts the guarantee,
#     because uncommitted work in a merged tree is exactly what gets lost.
#   * The destructive side is where the failure actually was, so that is what
#     is wired: `cleanup` never collects a claimed tree, `remove` releases only
#     its OWN lease, `create --reuse` refuses a foreign one and refreshes its
#     own.
#
# The `worktree` script's own per-issue claim lock requires flock(1) (`create`
# refuses to run without it), so this integration suite can only run where
# flock exists. The guard itself does not: its mutation mutex falls back to a
# mkdir mutex on hosts with no flock, reached here by running the guard on a
# PATH built without flock.
set -euo pipefail
# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call below at the real repository; -C overrides neither.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_PACKAGE_DIR="$(cd "$TEST_DIR/.." && pwd)"
WORKTREE_SCRIPT="$WORKTREE_PACKAGE_DIR/scripts/worktree"
GUARD_SCRIPT="$WORKTREE_PACKAGE_DIR/scripts/worktree-session-guard"

# A suite that cannot execute on this host reds. Skipping into a green would
# report that the lifecycle holds on a platform where nothing here ran, which
# is the one answer a second platform must never give. macOS ships no flock —
# it is util-linux — so a stock Mac reds here and says what to install; the
# macOS CI leg supplies flock for exactly this reason.
if ! command -v flock >/dev/null 2>&1; then
  printf 'FAIL: worktree lifecycle integration needs flock(1) for the per-issue claim lock, and this host has none. `create` refuses without it, so nothing below could run. Install flock (util-linux) and re-run.\n' >&2
  exit 1
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

# Exit code of `guard status`: 0 ours, 3 no lock, 4 non-guard lock, 75 foreign.
guard_status_code() {
  local wt="$1" repo="$2" rc=0
  shift 2
  "$GUARD_SCRIPT" status "$wt" --repo "$repo" "$@" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}:${2:-}" in
  pr:list) ;;
  pr:view) printf 'issue-x\n' ;;
esac
STUB
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"

# A scripts directory whose guard cannot run.
NOGUARD_SCRIPTS="$TMP_ROOT/noguard-scripts"
mkdir -p "$NOGUARD_SCRIPTS"
cp -R "$WORKTREE_PACKAGE_DIR/scripts/." "$NOGUARD_SCRIPTS/"
chmod -x "$NOGUARD_SCRIPTS/worktree-session-guard"

make_repo() {
  local root="$1"
  mkdir -p "$root/main" "$root/gh-state"
  git -C "$root/main" init -q -b main
  git -C "$root/main" config user.email test@example.com
  git -C "$root/main" config user.name Test
  git -C "$root/main" config commit.gpgsign false
  printf 'base\n' >"$root/main/base.txt"
  git -C "$root/main" add base.txt
  git -C "$root/main" commit -q -m base
  printf 'WORKTREE_BASE_DIR="../trees"\n' >"$root/main/.env.local"
  git init -q --bare "$root/origin.git"
  git -C "$root/main" remote add origin "$root/origin.git"
  git -C "$root/main" push -q -u origin main
}

# --- the lifecycle verbs against a lease: one table -----------------------------
# A row builds its own checkout from a step word list (a worktree the script
# created, a merged tree, a second merged tree, a zero-commit tree, a lease
# claimed under an owner), names the session identity in the environment, runs
# one command line from the main checkout, and pins the exit status, stdout
# (usage text by its first line), stderr whole, and what is left: each tree of
# the fixture with the owner of its lease.

ROOT=""
MAIN=""
TREES=""
ROW_SCRIPT=""
ROW_ENV=()

# A merged worktree that `cleanup` would collect if nothing held it. The
# branch carries a unique commit that reached main through a merge commit's
# side parent: ancestry alone is not enough for collection — a zero-commit
# branch sitting on the mainline is pending work and must survive.
add_merged_tree() {
  local name="$1"
  git -C "$MAIN" worktree add -q -b "$name" "$ROOT/trees/$name" main
  printf '%s\n' "$name" >"$ROOT/trees/$name/$name.txt"
  git -C "$ROOT/trees/$name" add "$name.txt"
  git -C "$ROOT/trees/$name" commit -q -m "$name: work"
  git -C "$MAIN" merge -q --no-ff -m "merge $name" "$name"
  git -C "$MAIN" push -q origin main
  TREES="$TREES $name"
}

claim() {
  "$GUARD_SCRIPT" claim "$ROOT/trees/$1" --owner "$2" >/dev/null
}

step() {
  case "$1" in
    # `create` through the script, under the self identity.
    created)
      (cd "$MAIN" && env KENDEX_SESSION_OWNER=ISSUE-1 "$WORKTREE_SCRIPT" create topic >/dev/null 2>&1)
      TREES="$TREES topic"
      ;;
    merged) add_merged_tree topic ;;
    free) add_merged_tree free ;;
    pending)
      git -C "$MAIN" worktree add -q -b pending "$ROOT/trees/pending" main
      TREES="$TREES pending"
      ;;
    claim-self) claim topic ISSUE-1 ;;
    claim-other) claim topic OTHER-SESSION ;;
    claim-issue) claim topic topic ;;
    claim-x) claim topic SESSION-X ;;
    claim-pending) claim pending GONE-SESSION ;;
    no-guard) ROW_SCRIPT="$NOGUARD_SCRIPTS/worktree" ;;
    *)
      echo "UNKNOWN-STEP: $1" >&2
      exit 2
      ;;
  esac
}

build() {
  local word
  ROOT="$TMP_ROOT/$1"
  shift
  MAIN="$ROOT/main"
  TREES="" ROW_SCRIPT="$WORKTREE_SCRIPT"
  ROW_ENV=()
  make_repo "$ROOT"
  for word in "$@"; do step "$word"; done
}

# The env column: the session identity the command runs under. The script's
# ladder ends at $USER (a login, not a session), so `none` unsets that too:
# the only identity such a command can carry is the issue ID it names.
session_env() {
  case "$1" in
    none) ROW_ENV=(-u KENDEX_SESSION_OWNER -u HT_SESSION_OWNER -u USER) ;;
    self) ROW_ENV=(-u HT_SESSION_OWNER KENDEX_SESSION_OWNER=ISSUE-1) ;;
    x) ROW_ENV=(-u HT_SESSION_OWNER KENDEX_SESSION_OWNER=SESSION-X) ;;
    *)
      echo "UNKNOWN-ENV-SPEC: $1" >&2
      exit 2
      ;;
  esac
}

# Each fixture tree as name=<present|absent>/<branch|no-branch>/<lease>: the
# directory, its branch ref in the main checkout, and the lease owner, or the
# guard's own status code when no guard lease is held (3 no lock, 4 a lock
# taken outside the guard, 1 no worktree there at all).
state() {
  local name out="" presence branch owner rc
  for name in $TREES; do
    presence=absent
    [[ -e "$ROOT/trees/$name" ]] && presence=present
    branch=no-branch
    git -C "$MAIN" show-ref --verify --quiet "refs/heads/$name" && branch=branch
    rc=0
    owner="$("$GUARD_SCRIPT" status "$ROOT/trees/$name" --repo "$MAIN" 2>/dev/null | jq -r '.owner // empty')" || rc=$?
    out="$out $name=$presence/$branch/${owner:-$rc}"
  done
  printf '%s' "${out# }"
}

alias_text() {
  sed -e "s|$ROOT/trees/topic|<topic>|g" -e "s|$ROOT/trees/free|<free>|g" -e "s|$ROOT/trees/pending|<pending>|g" \
    -e "s|$NOGUARD_SCRIPTS/worktree-session-guard|<guard>|g" -e "s|$WORKTREE_SCRIPT|<worktree>|g" -e "s|$MAIN|<main>|g" \
    -e 's/Lock reason: kendex-session-guard v1 owner=\([^ ]*\) pid=.*/Lock reason: <lease owner=\1>/' \
    -e '/^Usage: /q' -e 's/;/\\;/g' | paste -s -d ';' -
}

run() {
  local -a argv
  local rc=0
  read -r -a argv <<<"$1"
  (cd "$MAIN" && env "${ROW_ENV[@]}" GH_STATE="$ROOT/gh-state" "$ROW_SCRIPT" "${argv[@]}" >"$ROOT/out" 2>"$ROOT/err") || rc=$?
  printf 'rc=%s out=%s err=%s %s' "$rc" "$(alias_text <"$ROOT/out")" "$(alias_text <"$ROOT/err")" "$(state)"
}

out_text() {
  case "$1" in
    -) printf '' ;;
    path) printf '<topic>' ;;
    removed) printf 'Removed: <topic>' ;;
    cleaned-free) printf 'Cleaned: <free>' ;;
    cleaned-topic) printf 'Cleaned: <topic>' ;;
    cleaned-both) printf 'Cleaned: <free>;Cleaned: <topic>' ;;
    usage) printf 'Usage: worktree cleanup [--stale] [--ttl-minutes N]' ;;
    *) printf 'UNKNOWN-OUT-SPEC:%s' "$1" ;;
  esac
}

LOCKED_TAIL='Nothing in the worktree was modified.;A lock usually means a live session owns this worktree\; confirm it is finished first.;To release the lock and retry:;  git -C "<main>" worktree unlock "<topic>"'

err_text() {
  case "$1" in
    -) printf '' ;;
    released:*) printf "Released session guard lease (owner=%s): <topic>;Deleted branch 'topic' — merged into origin/main." "${1#released:}" ;;
    locked-other) printf '%s' "Error: <topic> is a locked worktree\; refusing to remove it.;  Worktree: <topic>;  Lock reason: <lease owner=OTHER-SESSION>;$LOCKED_TAIL" ;;
    held) printf '%s' 'Skipped (a session holds a guard lease): <topic>;  Let that session release it, or pass --stale to collect leases past the 720m TTL.' ;;
    fresh) printf '%s' 'Skipped (guard lease is not past the 720m TTL): <topic>' ;;
    stale-released) printf '%s' 'Released stale session guard lease: <topic>' ;;
    pending-skip) printf '%s' "Skipped (branch 'pending' has no commits of its own — pending work, not merged): <pending>;  Zero-commit worktrees are never collected\; drop it explicitly with: <worktree> remove \"<pending>\"" ;;
    unknown-option) printf '%s' "Error: unknown option '--bogus' for cleanup;Run: <worktree> cleanup --help" ;;
    ttl-nan) printf '%s' 'Error: --ttl-minutes must be a non-negative integer of at most 10 digits' ;;
    unguarded) printf '%s' 'Warning: worktree-session-guard is not executable at <guard>\; session leases were NOT checked or released, so worktrees are unguarded.' ;;
    reuse-foreign:*) printf 'Error: <topic> is claimed by another session\\; refusing to reuse it.;  worktree-session-guard: <topic> is claimed by owner=%s;Coordinate with the owning session instead of reusing its worktree.' "${1#reuse-foreign:}" ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s' "$1" ;;
  esac
}

# label|fixture|env|command|rc|out|err|state
ROWS='
create claims nothing|created|self|-|-|-|-|topic=present/branch/3
remove releases its own lease and says so|created claim-self|self|remove topic|0|removed|released:ISSUE-1|topic=absent/no-branch/1
remove refuses a foreign lease by its owner and leaves it in place|merged claim-other|self|remove topic|1|-|locked-other|topic=present/branch/OTHER-SESSION
remove <ID> derives the issue identity with no session env|merged claim-issue|none|remove topic|0|removed|released:topic|topic=absent/no-branch/1
remove <ID> still honours the session env identity|merged claim-x|x|remove topic|0|removed|released:SESSION-X|topic=absent/no-branch/1
create <ID> --reuse keeps the issue-keyed lease with no session env|created claim-issue|none|create topic --reuse|0|path|-|topic=present/branch/topic
create <ID> --reuse with no session env refuses a session-keyed lease|created claim-self|none|create topic --reuse|75|-|reuse-foreign:ISSUE-1|topic=present/branch/ISSUE-1
cleanup collects the unclaimed merged tree and names the held one|merged free claim-other|self|cleanup|0|cleaned-free|held|topic=present/branch/OTHER-SESSION free=absent/no-branch/1
cleanup --stale leaves a fresh lease alone|merged claim-other|self|cleanup --stale|0|-|fresh|topic=present/branch/OTHER-SESSION
cleanup --stale --ttl-minutes 0 releases a past-TTL lease and collects|merged claim-other|self|cleanup --stale --ttl-minutes 0|0|cleaned-topic|stale-released|topic=absent/no-branch/1
cleanup skips a zero-commit tree and names it|merged pending|self|cleanup|0|cleaned-topic|pending-skip|topic=absent/no-branch/1 pending=present/branch/3
cleanup --stale neither collects a zero-commit tree nor releases its lease|pending claim-pending|self|cleanup --stale --ttl-minutes 0|0|-|pending-skip|pending=present/branch/GONE-SESSION
cleanup rejects an unknown option|merged|self|cleanup --bogus|1|-|unknown-option|topic=present/branch/3
cleanup rejects a non-numeric --ttl-minutes|merged|self|cleanup --stale --ttl-minutes abc|1|-|ttl-nan|topic=present/branch/3
cleanup --help prints usage and collects nothing|merged|self|cleanup --help|0|usage|-|topic=present/branch/3
an unavailable guard is announced once and cleanup proceeds unguarded|merged free no-guard|self|cleanup|0|cleaned-both|unguarded|topic=absent/no-branch/1 free=absent/no-branch/1
create --reuse refuses a foreign lease as active work|created claim-other|self|create topic --reuse|75|-|reuse-foreign:OTHER-SESSION|topic=present/branch/OTHER-SESSION
create --reuse under its own lease succeeds and keeps it|created claim-self|self|create topic --reuse|0|path|-|topic=present/branch/ISSUE-1
'

echo "=== the lifecycle verbs against a lease ==="
n=0
while IFS='|' read -r label fixture envspec command rc out err want_state; do
  [[ -n "$label$fixture$envspec$command$rc$out$err$want_state" ]] || continue
  n=$((n + 1))
  # shellcheck disable=SC2086
  build "row-$n" $fixture
  session_env "$envspec"
  if [[ "$command" == - ]]; then
    assert_eq "$(state)" "$want_state" "$label"
    continue
  fi
  assert_eq "$(run "$command")" "rc=$rc out=$(out_text "$out") err=$(err_text "$err") $want_state" "$label"
done <<<"$ROWS"

# `create --reuse` under our own lease REFRESHES the heartbeat rather than
# re-claiming: a reuse cycle longer than the TTL would otherwise be swept as
# abandoned while still working, and a re-claim would reset claimed_at and
# momentarily drop the lock. The guard reads the wall clock with no override,
# so the refresh is pinned as an interval: the heartbeat after a one-second
# wait is later, the claim time is not. Once per identity rung the reuse can
# own the lease through: the issue ID with no session env, then the env.
lease_stamp() {
  "$GUARD_SCRIPT" status "$ROOT/trees/topic" --repo "$MAIN" --owner "$1" 2>/dev/null | jq -r ".$2"
}
heartbeat_pins() {
  local owner="$1" envspec="$2" before_heartbeat before_claimed
  session_env "$envspec"
  before_heartbeat="$(lease_stamp "$owner" heartbeat_at)"
  before_claimed="$(lease_stamp "$owner" claimed_at)"
  sleep 1
  (cd "$MAIN" && env "${ROW_ENV[@]}" "$WORKTREE_SCRIPT" create topic --reuse >/dev/null 2>&1)
  if [[ -n "$before_heartbeat" && "$(lease_stamp "$owner" heartbeat_at)" > "$before_heartbeat" ]]; then
    pass "reuse under the $envspec env refreshes the $owner lease heartbeat"
  else
    fail "reuse under the $envspec env refreshes the $owner lease heartbeat (before=$before_heartbeat after=$(lease_stamp "$owner" heartbeat_at))"
  fi
  assert_eq "$(lease_stamp "$owner" claimed_at)" "$before_claimed" \
    "reuse under the $envspec env refreshes in place rather than re-claiming (lock never drops)"
}
build heartbeat-issue created claim-issue
heartbeat_pins topic none
build heartbeat created claim-self
heartbeat_pins ISSUE-1 self

# --- the guard's own surfaces ---------------------------------------------------
REUSE_ROOT="$ROOT"
REUSE_WT="$ROOT/trees/topic"

echo "=== list and sweep ==="

list_out="$("$GUARD_SCRIPT" list --repo "$REUSE_ROOT/main")"
assert_contains "$list_out" "\"path\":\"$REUSE_WT\"" "list includes the linked worktree"
assert_contains "$list_out" '"owner":"ISSUE-1"' "list includes the lease owner"

dry_sweep_out="$("$GUARD_SCRIPT" sweep --repo "$REUSE_ROOT/main" --ttl-minutes 0 --dry-run)"
assert_contains "$dry_sweep_out" "would release $REUSE_WT" "sweep dry-run reports the stale lease"
assert_eq "$(guard_status_code "$REUSE_WT" "$REUSE_ROOT/main" --owner ISSUE-1)" "0" \
  "sweep dry-run leaves the lease in place"

sweep_out="$("$GUARD_SCRIPT" sweep --repo "$REUSE_ROOT/main" --ttl-minutes 0)"
assert_contains "$sweep_out" "released $REUSE_WT" "sweep releases the stale lease"
assert_eq "$(guard_status_code "$REUSE_WT" "$REUSE_ROOT/main")" "3" \
  "sweep leaves the worktree unlocked"

echo "=== claim serializes on the guard mutex ==="

# Two owners racing `claim` both reading "no lease", both writing, and both
# exiting 0 is the failure this guard exists to stop, so claim's whole
# read-decide-write runs under the common-dir mutex. Holding that lock the way
# a mid-claim guard process holds it proves a second owner cannot get behind it.
MUTEX_ROOT="$TMP_ROOT/mutex"
make_repo "$MUTEX_ROOT"
MAIN="$MUTEX_ROOT/main"; ROOT="$MUTEX_ROOT"; add_merged_tree issue-m
MUTEX_WT="$MUTEX_ROOT/trees/issue-m"
exec 8>"$MUTEX_ROOT/main/.git/kendex-worktree-session-guard.lock"
flock -x 8
set +e
timeout 3 "$GUARD_SCRIPT" claim "$MUTEX_WT" --owner OWNER-B >/dev/null 2>&1
mutex_code=$?
set -e
assert_eq "$mutex_code" "124" "claim blocks while another mutation holds the guard mutex"
assert_eq "$(guard_status_code "$MUTEX_WT" "$MUTEX_ROOT/main")" "3" \
  "the blocked claim wrote no lease"
exec 8>&-
"$GUARD_SCRIPT" claim "$MUTEX_WT" --owner OWNER-A >/dev/null
set +e
"$GUARD_SCRIPT" claim "$MUTEX_WT" --owner OWNER-B >/dev/null 2>&1
second_code=$?
set -e
assert_eq "$second_code" "75" "with the mutex free only the first owner holds the lease"

echo "=== release refuses a flag it does not implement ==="

# --dry-run promises to preserve. release never implemented it, so accepting
# and ignoring the flag deleted the very lease the caller asked to keep.
set +e
dry_err=$("$GUARD_SCRIPT" release "$MUTEX_WT" --owner OWNER-A --dry-run 2>&1 >/dev/null)
dry_code=$?
set -e
assert_eq "$dry_code" "1" "release --dry-run is a usage failure"
assert_contains "$dry_err" "--dry-run does not apply to release" \
  "the refusal names the flag and the command"
assert_eq "$(guard_status_code "$MUTEX_WT" "$MUTEX_ROOT/main" --owner OWNER-A)" "0" \
  "the lease --dry-run promised to preserve is still held"

echo "=== registrations resolve without a cwd or a directory ==="

REG_ROOT="$TMP_ROOT/registration"
make_repo "$REG_ROOT"
MAIN="$REG_ROOT/main"; ROOT="$REG_ROOT"; add_merged_tree issue-rel
REL_WT="$REG_ROOT/trees/issue-rel"
"$GUARD_SCRIPT" claim "$REL_WT" --owner REL-OWNER >/dev/null
# git accepts a relative gitdir registration, and it is relative to the
# registration directory — never to whatever cwd the guard runs from.
printf '../../../../trees/issue-rel/.git\n' >"$REG_ROOT/main/.git/worktrees/issue-rel/gitdir"
assert_eq "$(guard_status_code "$REL_WT" "$REG_ROOT/main" --owner REL-OWNER)" "0" \
  "a relative gitdir registration resolves to its worktree"
assert_contains "$("$GUARD_SCRIPT" list --repo "$REG_ROOT/main")" "\"path\":\"$REL_WT\"" \
  "list resolves a relative gitdir registration"

# A worktree whose directory tree was destroyed is precisely what sweep exists
# to clean up, so its lease must stay visible to list and collectable by sweep.
rm -rf -- "${REG_ROOT:?}/trees"
gone_list="$("$GUARD_SCRIPT" list --repo "$REG_ROOT/main")"
assert_contains "$gone_list" "\"path\":\"$REL_WT\"" "list still reports a destroyed worktree"
assert_contains "$gone_list" '"directory_present":false' "list marks the directory gone"
assert_contains "$("$GUARD_SCRIPT" sweep --repo "$REG_ROOT/main" --ttl-minutes 0)" \
  "released $REL_WT" "sweep releases a destroyed worktree's lease"

echo "=== a newline in a worktree path ==="

# A registration records its worktree path with a trailing newline, so reading
# only the file's first line truncates a path that contains one.
NL_ROOT="$TMP_ROOT/newline"
make_repo "$NL_ROOT"
NL_WT="$NL_ROOT/trees/issue"$'\n'"nl"
git -C "$NL_ROOT/main" worktree add -q -b issue-nl "$NL_WT" main
"$GUARD_SCRIPT" claim "$NL_WT" --owner NL-OWNER >/dev/null
assert_eq "$(guard_status_code "$NL_WT" "$NL_ROOT/main" --owner NL-OWNER)" "0" \
  "a worktree path containing a newline resolves for status"
assert_contains "$("$GUARD_SCRIPT" list --repo "$NL_ROOT/main")" \
  "\"path\":\"${NL_WT//$'\n'/\\n}\"" \
  "list reports the newline path as one escaped JSON object"

echo "=== the mkdir mutex serializes claims on a flock-less host ==="

# Stock macOS ships no flock(1), so there the mkdir mutex is not a fallback:
# it is the only thing serializing a claim, and a failure makes concurrent
# claims fail open unnoticed. The probe PATH is derived from the real one
# minus flock rather than naming the tools the guard uses, so it stays true as
# the guard changes.
NOFLOCK_BIN="$TMP_ROOT/noflock-bin"
mkdir -p "$NOFLOCK_BIN"
saved_ifs="$IFS"
IFS=:
for path_dir in $PATH; do
  IFS="$saved_ifs"
  if [[ -d "$path_dir" ]]; then
    for path_exe in "$path_dir"/*; do
      exe_name="${path_exe##*/}"
      if [[ "$exe_name" != flock && ! -e "$NOFLOCK_BIN/$exe_name" ]]; then
        ln -s "$path_exe" "$NOFLOCK_BIN/$exe_name" 2>/dev/null || true
      fi
    done
  fi
  IFS=:
done
IFS="$saved_ifs"
# Without this the whole control passes vacuously through the flock branch.
if PATH="$NOFLOCK_BIN" bash -c 'command -v flock' >/dev/null 2>&1; then
  fail "the probe PATH resolves no flock"
else
  pass "the probe PATH resolves no flock"
fi

RACE_ROOT="$TMP_ROOT/mkdir-race"
make_repo "$RACE_ROOT"
MAIN="$RACE_ROOT/main"; ROOT="$RACE_ROOT"; add_merged_tree issue-race
RACE_WT="$RACE_ROOT/trees/issue-race"
RACE_GO="$RACE_ROOT/go"
RACE_OUT="$RACE_ROOT/out"
mkdir -p "$RACE_OUT"
# Both claimants spin on one file so they enter the guard together; starting
# them in sequence would let the first finish before the second reads.
for racer in 1 2; do
  (
    until [[ -e "$RACE_GO" ]]; do :; done
    race_rc=0
    PATH="$NOFLOCK_BIN" "$GUARD_SCRIPT" claim "$RACE_WT" --owner "RACER-$racer" \
      >/dev/null 2>&1 || race_rc=$?
    printf '%s\n' "$race_rc" >"$RACE_OUT/$racer"
  ) &
done
sleep 0.4
: >"$RACE_GO"
wait
race_codes="$(cat "$RACE_OUT/1" "$RACE_OUT/2")"
assert_eq "$(printf '%s\n' "$race_codes" | grep -cx 0 || true)" "1" \
  "exactly one of two racing claimants takes the lease"
assert_eq "$(printf '%s\n' "$race_codes" | grep -cx 75 || true)" "1" \
  "the loser is refused rather than overwriting the winner"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
