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
# flock exists. The guard itself does not: its mutation mutex falls back to an
# exclusive-file mutex on hosts with no flock, reached here by running the guard on a
# PATH built without flock.
set -euo pipefail
# The fixtures' origin is a local path that names no GitHub repository, so
# the suite names the default branch.
export WORKTREE_DEFAULT_BRANCH=main
# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call below at the real repository; -C overrides neither.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/messages.sh
source "$TEST_DIR/lib/messages.sh"
# shellcheck source=lib/session-harness.sh
source "$TEST_DIR/lib/session-harness.sh"
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

TMP_ROOT="$(mktemp -d)" || { echo "worktree_session_guard_lifecycle: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "worktree_session_guard_lifecycle: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "worktree_session_guard_lifecycle: scratch=resolve-failed" >&2; exit 1; }
trap 'session_harness_stop_all; rm -rf -- "${TMP_ROOT:?}"' EXIT

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
  message_records |
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
    removed) printf 'worktree-removed: <topic>' ;;
    cleaned-free) printf 'worktree-cleaned: <free>' ;;
    cleaned-topic) printf 'worktree-cleaned: <topic>' ;;
    cleaned-both) printf 'worktree-cleaned: <free>;worktree-cleaned: <topic>' ;;
    usage) printf 'worktree-help: cleanup' ;;
    *) printf 'UNKNOWN-OUT-SPEC:%s' "$1" ;;
  esac
}


err_text() {
  case "$1" in
    -) printf '' ;;
    released:*) printf 'worktree-lease-released: path=<topic> owner=%s;worktree-branch-deleted: topic' "${1#released:}" ;;
    locked-other) printf 'worktree-worktree-locked: <topic>' ;;
    held) printf 'worktree-cleanup-lease-held: <topic>' ;;
    fresh) printf 'worktree-cleanup-lease-fresh: <topic>' ;;
    stale-released) printf 'worktree-lease-stale-released: <topic>' ;;
    pending-skip) printf 'worktree-cleanup-zero-commit: <pending>' ;;
    unknown-option) printf 'worktree-cleanup-option-unknown: --bogus' ;;
    ttl-nan) printf 'worktree-cleanup-ttl-invalid: abc' ;;
    unguarded) printf 'worktree-session-guard-unavailable: <guard>' ;;
    reuse-foreign:*) printf 'worktree-lease-foreign: <topic>;worktree-guard-owner-conflict: path=<topic> owner=%s' "${1#reuse-foreign:}" ;;
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
assert_contains "$dry_sweep_out" "worktree-guard-would-release: $REUSE_WT" "sweep dry-run reports the stale lease"
assert_eq "$(guard_status_code "$REUSE_WT" "$REUSE_ROOT/main" --owner ISSUE-1)" "0" \
  "sweep dry-run leaves the lease in place"

sweep_out="$("$GUARD_SCRIPT" sweep --repo "$REUSE_ROOT/main" --ttl-minutes 0)"
assert_contains "$sweep_out" "worktree-guard-released: $REUSE_WT" "sweep releases the stale lease"
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

# A claim behind a holder that never lets go refuses by name once the guard's
# own wait runs out, rather than waiting until its caller kills it. A flock
# first on PATH shortens whatever `-w` the guard passes to one second, so the
# row proves the bound is passed and refused on, not its length.
BOUND_BIN="$TMP_ROOT/bound-bin"
mkdir -p "$BOUND_BIN"
cat >"$BOUND_BIN/flock" <<EOF
#!/usr/bin/env bash
args=()
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -w) args+=(-w 1); shift 2 ;;
    *) args+=("\$1"); shift ;;
  esac
done
exec $(command -v flock) "\${args[@]}"
EOF
chmod +x "$BOUND_BIN/flock"
BOUND_WT="$MUTEX_ROOT/trees/bounded"
git -C "$MUTEX_ROOT/main" worktree add -q -b bounded "$BOUND_WT" main
bounded_wait_row() { # GUARD
  local lock="$MUTEX_ROOT/main/.git/kendex-worktree-session-guard.lock" bound_rc=0 bound_err
  exec 8>"$lock"
  flock -x 8
  bound_err=$(PATH="$BOUND_BIN:$PATH" timeout 5 "$1" claim "$BOUND_WT" --owner OWNER-B 2>&1 >/dev/null) || bound_rc=$?
  exec 8>&-
  assert_eq "rc=$bound_rc record=${bound_err%%$'\n'*} state=$(guard_status_code "$BOUND_WT" "$MUTEX_ROOT/main")" \
    "rc=1 record=worktree-guard-lock-timeout: $lock state=3" \
    "a claim the mutex holds past the guard's bound refuses by name and writes no lease"
}
bounded_wait_row "$GUARD_SCRIPT"

# Must-fail control: a guard copy that waits on flock with no bound is cut off
# by the row's own timeout instead.
BOUND_CONTROL="$TMP_ROOT/bound-control"
cp -R "$WORKTREE_PACKAGE_DIR/scripts" "$BOUND_CONTROL"
BOUND_ANCHOR='flock -x -w "$wait" 9'
assert_eq "$(grep -cF -- "$BOUND_ANCHOR" "$BOUND_CONTROL/worktree-session-guard")" "1" \
  "control: the flock bound anchor appears once in the guard"
BOUND_ANCHOR=$BOUND_ANCHOR awk '{ i = index($0, ENVIRON["BOUND_ANCHOR"]); if (i) $0 = substr($0, 1, i - 1) "flock -x 9" substr($0, i + length(ENVIRON["BOUND_ANCHOR"])); print }' \
  "$WORKTREE_PACKAGE_DIR/scripts/worktree-session-guard" >"$BOUND_CONTROL/worktree-session-guard"
assert_eq "$(grep -cF -- "$BOUND_ANCHOR" "$BOUND_CONTROL/worktree-session-guard")" "0" \
  "control: the planted guard drops the flock bound"
bound_control_log="$(PASS=0 FAIL=0; bounded_wait_row "$BOUND_CONTROL/worktree-session-guard")"
assert_eq "$(grep -c '^  FAIL  ' <<<"$bound_control_log")" "1" \
  "control: the planted guard fails the bounded-wait row"

echo "=== claim --owner --adopt takes over the session's env-owned lease ==="

# A session-start hook claims under the env ladder; the workflow then claims
# the same tree under the issue ID with --adopt. Any other --owner claim, such
# as cleanup's own, is refused by that lease, and refresh refuses --adopt. A
# row: label|args|env|rc|owner after|first stderr line, args following the
# worktree path. Each starts from a lease alice took with no --owner.
HANDOVER_WT="$MUTEX_ROOT/trees/handover"
git -C "$MUTEX_ROOT/main" worktree add -q -b handover "$HANDOVER_WT" main
HANDOVER_CONFLICT="worktree-guard-owner-conflict: path=$HANDOVER_WT owner=alice"
HANDOVER="the env owner's lease passes to an adopting --owner|claim --owner ISSUE-1 --adopt|USER=alice|0|ISSUE-1|
the ladder's top rung is the env owner|claim --owner ISSUE-1 --adopt|KENDEX_SESSION_OWNER=alice USER=bob|0|ISSUE-1|
another env owner is refused|claim --owner ISSUE-1 --adopt|USER=bob|75|alice|$HANDOVER_CONFLICT
an explicit owner without --adopt is refused|claim --owner ISSUE-1|USER=alice|75|alice|$HANDOVER_CONFLICT
refresh refuses --adopt|refresh --owner ISSUE-1 --adopt|USER=alice|1|alice|worktree-guard-option-command: --adopt=refresh
refresh refuses --session|refresh --owner alice --session|USER=alice|1|alice|worktree-guard-option-command: --session=refresh"
handover_rows() { # GUARD
  local guard="$1" label argspec envspec expected_rc expected_owner expected_record handover_rc handover_err verb
  local -a handover_args handover_env
  while IFS='|' read -r label argspec envspec expected_rc expected_owner expected_record; do
    read -r verb argspec <<<"$argspec"
    read -r -a handover_args <<<"$argspec"
    read -r -a handover_env <<<"$envspec"
    "$guard" release "$HANDOVER_WT" --force >/dev/null 2>&1 || :
    env -u KENDEX_SESSION_OWNER -u HT_SESSION_OWNER USER=alice "$guard" claim "$HANDOVER_WT" >/dev/null
    handover_rc=0
    session_harness_run "$HANDOVER_HARNESS" "$PWD" env -u KENDEX_SESSION_OWNER -u HT_SESSION_OWNER "${handover_env[@]}" \
      "$guard" "$verb" "$HANDOVER_WT" "${handover_args[@]}" || handover_rc=$?
    handover_err="$(cat -- "$HANDOVER_HARNESS/err")"
    assert_eq "rc=$handover_rc owner=$("$guard" status "$HANDOVER_WT" --repo "$MUTEX_ROOT/main" | jq -r .owner) record=${handover_err%%$'\n'*}" \
      "rc=$expected_rc owner=$expected_owner record=$expected_record" "$label"
  done <<<"$HANDOVER"
}
# Each claim runs inside an owned harness stand-in, so the session process an
# --adopt claim records is that stand-in wherever the suite runs.
HANDOVER_HARNESS="$TMP_ROOT/handover-harness"
session_harness_start "$HANDOVER_HARNESS" claude
handover_rows "$GUARD_SCRIPT"

# Must-fail controls, each a guard copy with one text replaced: an env owner
# that never matches refuses the takeover, so both takeover rows go red; a
# guard that adopts on every claim admits on an env match alone, so the
# unflagged claim goes red; an --adopt that refresh accepts lets refresh take
# the lease over, so the refresh row goes red. A row: label|text|replacement|
# rows expected to fail.
HANDOVER_ANCHOR='env_owner="${KENDEX_SESSION_OWNER:-${HT_SESSION_OWNER:-${USER:-}}}"'
HANDOVER_GATE="require_flag_applies --adopt 'claim'"
HANDOVER_CONTROLS="env owner never matches|$HANDOVER_ANCHOR|$HANDOVER_ANCHOR; env_owner=|the env owner's lease passes to an adopting --owner;the ladder's top rung is the env owner
adopt on every claim|$HANDOVER_ANCHOR|$HANDOVER_ANCHOR; adopt=true|an explicit owner without --adopt is refused
refresh takes --adopt|$HANDOVER_GATE|require_flag_applies --adopt 'claim refresh'|refresh refuses --adopt
refresh takes --session|require_flag_applies --session 'claim'|require_flag_applies --session 'claim refresh'|refresh refuses --session"
control_n=0
while IFS='|' read -r control_label control_text control_replacement expected_fails; do
  control_n=$((control_n + 1))
  control_dir="$TMP_ROOT/handover-control-$control_n"
  cp -R "$WORKTREE_PACKAGE_DIR/scripts" "$control_dir"
  assert_eq "$(grep -cF -- "$control_text" "$GUARD_SCRIPT")" "1" \
    "control: $control_label replaces text the guard holds once"
  CONTROL_TEXT=$control_text CONTROL_REPLACEMENT=$control_replacement awk '{ i = index($0, ENVIRON["CONTROL_TEXT"]); if (i) $0 = substr($0, 1, i - 1) ENVIRON["CONTROL_REPLACEMENT"] substr($0, i + length(ENVIRON["CONTROL_TEXT"])); print }' \
    "$GUARD_SCRIPT" >"$control_dir/worktree-session-guard"
  assert_eq "$(grep -cF -- "$control_replacement" "$control_dir/worktree-session-guard")" "1" \
    "control: $control_label is planted once"
  handover_control_log="$(PASS=0 FAIL=0; handover_rows "$control_dir/worktree-session-guard")"
  assert_eq "$(sed -n 's/^  FAIL  //p' <<<"$handover_control_log" | paste -s -d ';' -)" "$expected_fails" \
    "control: the planted guard ($control_label) fails its rows"
done <<<"$HANDOVER_CONTROLS"
session_harness_stop "$HANDOVER_HARNESS"

echo "=== release refusal records ==="

git -C "$REUSE_ROOT/main" worktree add -q -b manual "$REUSE_ROOT/manual" main
git -C "$REUSE_ROOT/main" worktree lock --reason manual "$REUSE_ROOT/manual"
REFUSALS="unsupported flag|$MUTEX_WT|--owner OWNER-A --dry-run|1|worktree-guard-option-command: --dry-run=release|0
foreign owner|$MUTEX_WT|--owner OWNER-B|75|worktree-guard-owner-conflict: path=$MUTEX_WT owner=OWNER-A|0
fresh lease|$MUTEX_WT|--stale|75|worktree-guard-lease-not-stale: $MUTEX_WT|0
missing lease|$REUSE_WT|--owner OWNER-A|3|worktree-guard-lease-missing: $REUSE_WT|3
manual lock|$REUSE_ROOT/manual|--owner OWNER-A|4|worktree-guard-lock-unmanaged: $REUSE_ROOT/manual|4"
while IFS='|' read -r label refusal_path flags expected_rc expected_record expected_state; do
  read -r -a refusal_args <<<"$flags"
  refusal_rc=0
  refusal_err=$("$GUARD_SCRIPT" release "$refusal_path" "${refusal_args[@]}" 2>&1 >/dev/null) || refusal_rc=$?
  assert_eq "rc=$refusal_rc record=${refusal_err%%$'\n'*} state=$(guard_status_code "$refusal_path" "$refusal_path" --owner OWNER-A)" \
    "rc=$expected_rc record=$expected_record state=$expected_state" "$label"
done <<<"$REFUSALS"

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
  "worktree-guard-released: $REL_WT" "sweep releases a destroyed worktree's lease"

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
newline_rc=0
newline_err=$("$GUARD_SCRIPT" refresh "$NL_WT" --owner NL-OTHER 2>&1 >/dev/null) || newline_rc=$?
assert_eq "rc=$newline_rc record=${newline_err%%$'\n'*}" \
  "rc=75 record=worktree-guard-owner-conflict: path=$NL_ROOT/trees/issue\\nnl owner=NL-OWNER" \
  "a refusal keeps the newline path in one message record"

BROKEN_GUARD_DIR="$TMP_ROOT/broken"$'\n'"guard"
mkdir -p "$BROKEN_GUARD_DIR"
cp "$GUARD_SCRIPT" "$BROKEN_GUARD_DIR/worktree-session-guard"
chmod +x "$BROKEN_GUARD_DIR/worktree-session-guard"
missing_helper_rc=0
missing_helper_err=$("$BROKEN_GUARD_DIR/worktree-session-guard" status "$NL_WT" 2>&1 >/dev/null) || missing_helper_rc=$?
assert_eq "rc=$missing_helper_rc record=${missing_helper_err%%$'\n'*}" \
  "rc=1 record=worktree-message-library: path=${BROKEN_GUARD_DIR//$'\n'/\\n}/lib/messages.sh recovery=fix-links-from-main" \
  "a missing helper path containing a newline stays in one bootstrap record"

echo "=== the exclusive-file mutex serializes claims on a flock-less host ==="

# Stock macOS ships no flock(1), so there the exclusive-file mutex is not a fallback:
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

RACE_ROOT="$TMP_ROOT/exclusive-file-race"
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

echo "=== session processes hold a lease ==="

# A session-bound claim records the harness process it runs under, and every
# automatic release or takeover reads that process back. Each harness here is
# an owned stand-in under the harness's name (lib/session-harness.sh); the same
# rows run with Claude holding and Codex claiming, then the reverse. Each run
# builds its own repository, so a control's run starts from a clean one.
LIVE_WT=''
live_tree() {
  live_n=$((live_n + 1))
  LIVE_WT="$LIVE_ROOT/trees/live-$live_n"
  git -C "$LIVE_MAIN" worktree add -q -b "live-$live_n" "$LIVE_WT" main
}
live_owner() {
  "$GUARD_SCRIPT" status "$LIVE_WT" --repo "$LIVE_MAIN" 2>/dev/null | jq -r 'if .managed then .owner elif .locked then "unmanaged" else "none" end'
}
# Runs the guard under test inside harness DIR as USER, leaving its status in
# LIVE_RC.
in_harness() { # DIR USER GUARD-ARGS...
  local dir="$1" user="$2"
  shift 2
  LIVE_RC=0
  session_harness_run "$dir" "$LIVE_MAIN" env -u KENDEX_SESSION_OWNER -u HT_SESSION_OWNER "USER=$user" "PATH=$LIVE_PATH" "$GUARD_UNDER_TEST" "$@" || LIVE_RC=$?
}

# label|holder lease|edits|claim rc|owner after|claimant's PID recorded
#   holder lease  held: a session-bound claim inside the holder; plain: a
#                 plain --owner claim; manual: a lock outside the guard
#   edits         expire, restart (the holder's recorded start), rehost (its
#                 host), reboot (its boot id), renamespace (its PID
#                 namespace), zombie (the recorded process becomes a zombie
#                 the suite holds), absent (the claimant's ps reports the
#                 holder's PID absent), failing (the claimant's ps fails
#                 within ps itself on the holder's PID), clockstep (the
#                 claimant's ps answers
#                 the holder's lstart with another wall-clock time), each
#                 applied in order; - for none
# A row whose edit restarts the holder too keeps the lease on the one rule it
# names, since a restarted session alone would be taken over.
RECLAIM_ROWS="an expired lease whose session started at another time is taken over|held|expire restart|0|alice|yes
an expired lease whose session is a zombie is taken over|held|expire zombie|0|alice|yes
an expired lease whose session lives stays held|held|expire|75|bob|no
an unexpired lease whose session is dead stays held|held|restart|75|bob|no
an expired lease recorded on another host stays held|held|expire restart rehost|75|bob|no
an expired lease that records no session stays held|plain|expire|75|bob|no
a lock outside the guard stays held|manual|-|75|unmanaged|no"
# Each host reads a start and a boot in its own way: /proc carries the start
# in ticks since boot, which a wall-clock step leaves alone, and the boot id
# and PID namespace; without /proc, ps answers both the start and an absent
# PID.
PROC_IDENTITY=false
[[ ! -r /proc/self/stat || ! -r /proc/sys/kernel/random/boot_id || ! -e /proc/self/ns/pid ]] || PROC_IDENTITY=true
if [[ "$PROC_IDENTITY" == true ]]; then
  RECLAIM_ROWS="$RECLAIM_ROWS
an expired lease whose session ran before a reboot is taken over|held|expire reboot|0|alice|yes
an expired lease recorded in another PID namespace stays held|held|expire restart renamespace|75|bob|no
an expired lease whose session's wall-clock start moved stays held|held|expire clockstep|75|bob|no"
else
  RECLAIM_ROWS="$RECLAIM_ROWS
an expired lease whose session PID the system reports absent is taken over|held|expire absent|0|alice|yes
an expired lease whose session ps fails to read stays held|held|expire failing|75|bob|no"
fi

reclaim_rows() { # HOLDER CLAIMANT
  local holder="$1" claimant="$2" label lease edits want_rc want_owner want_recorded edit hdir cdir holder_pid claimant_pid got_recorded
  while IFS='|' read -r label lease edits want_rc want_owner want_recorded; do
    live_tree
    hdir="$LIVE_ROOT/harness-$live_n-holder"
    cdir="$LIVE_ROOT/harness-$live_n-claimant"
    session_harness_start "$hdir" "$holder"
    holder_pid=$SESSION_HARNESS_PID
    session_harness_start "$cdir" "$claimant"
    claimant_pid=$SESSION_HARNESS_PID
    LIVE_PATH="$PATH"
    case "$lease" in
      held) in_harness "$hdir" bob claim "$LIVE_WT" --session ;;
      plain) "$GUARD_SCRIPT" claim "$LIVE_WT" --owner bob >/dev/null ;;
      manual) git -C "$LIVE_MAIN" worktree lock --reason manual "$LIVE_WT" ;;
    esac
    for edit in $edits; do
      case "$edit" in
        -) ;;
        expire) session_lease_rewrite "$LIVE_WT" expire ;;
        restart | rehost | reboot | renamespace) session_lease_rewrite "$LIVE_WT" "$edit" "$holder_pid" ;;
        zombie)
          session_zombie_start "$LIVE_ROOT/zombie-$live_n"
          session_lease_rewrite "$LIVE_WT" zombie "$holder_pid" "$SESSION_ZOMBIE_PID" \
            "$(source "$(dirname -- "$GUARD_UNDER_TEST")/lib/process-identity.sh" && process_start "$SESSION_ZOMBIE_PID")"
          ;;
        absent)
          session_absent_ps "$LIVE_ROOT/absent-ps-$live_n" "$holder_pid"
          LIVE_PATH="$LIVE_ROOT/absent-ps-$live_n:$PATH"
          ;;
        failing)
          session_failing_ps "$LIVE_ROOT/failing-ps-$live_n" "$holder_pid"
          LIVE_PATH="$LIVE_ROOT/failing-ps-$live_n:$PATH"
          ;;
        clockstep)
          session_clockstep_ps "$LIVE_ROOT/clockstep-ps-$live_n" "$holder_pid"
          LIVE_PATH="$LIVE_ROOT/clockstep-ps-$live_n:$PATH"
          ;;
      esac
    done
    in_harness "$cdir" alice claim "$LIVE_WT" --session
    got_recorded=no
    [[ ",$(session_lease_pids "$GUARD_SCRIPT" "$LIVE_WT" "$LIVE_MAIN")," != *",$claimant_pid,"* ]] || got_recorded=yes
    assert_eq "rc=$LIVE_RC owner=$(live_owner) recorded=$got_recorded" \
      "rc=$want_rc owner=$want_owner recorded=$want_recorded" "$holder holds, $claimant claims: $label"
    session_harness_stop "$hdir"
    session_harness_stop "$cdir"
    session_harness_stop "$LIVE_ROOT/zombie-$live_n"
  done <<<"$RECLAIM_ROWS"
}

# The other automatic releases against one expired lease, live and then dead.
# A row: label|command|edit|rc|owner after, the command run from the suite's
# own process, never the holding session.
RELEASE_ROWS="release --stale keeps an expired lease whose session lives|release --stale|-|7|bob
release --stale releases an expired lease whose session is dead|release --stale|restart|0|none
sweep keeps an expired lease whose session lives|sweep|-|0|bob
sweep releases an expired lease whose session is dead|sweep|restart|0|none
remove's close-out from another process keeps a live session's lease|release --owner bob --inactive|-|7|bob
remove's close-out releases a dead session's lease|release --owner bob --inactive|restart|0|none"
[[ "$PROC_IDENTITY" != true ]] || RELEASE_ROWS="$RELEASE_ROWS
release --stale releases an expired lease whose session ran before a reboot|release --stale|reboot|0|none
sweep releases an expired lease whose session ran before a reboot|sweep|reboot|0|none
remove's close-out releases a lease whose session ran before a reboot|release --owner bob --inactive|reboot|0|none"

release_rows() { # HARNESS
  local harness="$1" label argspec edit want_rc want_owner hdir rc
  local -a args
  while IFS='|' read -r label argspec edit want_rc want_owner; do
    live_tree
    hdir="$LIVE_ROOT/harness-$live_n"
    session_harness_start "$hdir" "$harness"
    LIVE_PATH="$PATH"
    in_harness "$hdir" bob claim "$LIVE_WT" --session
    session_lease_rewrite "$LIVE_WT" expire
    [[ "$edit" == - ]] || session_lease_rewrite "$LIVE_WT" "$edit" "$SESSION_HARNESS_PID"
    read -r -a args <<<"$argspec"
    if [[ "${args[0]}" == sweep ]]; then
      args+=(--repo "$LIVE_MAIN")
    else
      args=("${args[0]}" "$LIVE_WT" "${args[@]:1}" --repo "$LIVE_MAIN")
    fi
    rc=0
    "$GUARD_UNDER_TEST" "${args[@]}" >/dev/null 2>&1 || rc=$?
    assert_eq "rc=$rc owner=$(live_owner)" "rc=$want_rc owner=$want_owner" "$harness: $label"
    session_harness_stop "$hdir"
  done <<<"$RELEASE_ROWS"
}

# Two sessions on one owner keep each other's records, the lease holds while
# either lives, and the close-out run from the holding session releases it.
shared_rows() { # FIRST SECOND
  local first="$1" second="$2" adir bdir apid bpid
  live_tree
  adir="$LIVE_ROOT/harness-$live_n-a"
  bdir="$LIVE_ROOT/harness-$live_n-b"
  session_harness_start "$adir" "$first"
  apid=$SESSION_HARNESS_PID
  session_harness_start "$bdir" "$second"
  bpid=$SESSION_HARNESS_PID
  LIVE_PATH="$PATH"
  in_harness "$adir" alice claim "$LIVE_WT" --session
  assert_eq "rc=$LIVE_RC pids=$(session_lease_pids "$GUARD_SCRIPT" "$LIVE_WT" "$LIVE_MAIN")" "rc=0 pids=$apid" \
    "$first: a session-bound claim records the harness process it runs under"
  in_harness "$bdir" alice claim "$LIVE_WT" --session
  assert_eq "rc=$LIVE_RC pids=$(session_lease_pids "$GUARD_SCRIPT" "$LIVE_WT" "$LIVE_MAIN")" "rc=0 pids=$bpid,$apid" \
    "$first then $second: a second session on the lease keeps the first one's record"
  session_lease_rewrite "$LIVE_WT" restart "$bpid"
  session_lease_rewrite "$LIVE_WT" expire
  LIVE_RC=0
  "$GUARD_UNDER_TEST" claim "$LIVE_WT" --owner carol >/dev/null 2>&1 || LIVE_RC=$?
  assert_eq "rc=$LIVE_RC owner=$(live_owner)" "rc=75 owner=alice" \
    "$first then $second: one live session holds an expired lease whose other session is dead"
  in_harness "$adir" alice release "$LIVE_WT" --owner alice --inactive --repo "$LIVE_MAIN"
  assert_eq "rc=$LIVE_RC owner=$(live_owner)" "rc=0 owner=none" \
    "$first then $second: the close-out from the holding session itself releases its lease"
  session_harness_stop "$adir"
  session_harness_stop "$bdir"
}

# A sandbox parked and relaunched in the same worktree boots anew: the
# relaunched session's start claim drops the record from before the boot, and
# its close-out releases the lease.
relaunch_rows() { # HARNESS
  local harness="$1" odir ndir npid
  live_tree
  odir="$LIVE_ROOT/harness-$live_n-before"
  ndir="$LIVE_ROOT/harness-$live_n-after"
  session_harness_start "$odir" "$harness"
  session_harness_start "$ndir" "$harness"
  npid=$SESSION_HARNESS_PID
  LIVE_PATH="$PATH"
  in_harness "$odir" bob claim "$LIVE_WT" --session
  session_lease_rewrite "$LIVE_WT" reboot "$(cat -- "$odir/pid")"
  in_harness "$ndir" bob claim "$LIVE_WT" --session
  assert_eq "rc=$LIVE_RC pids=$(session_lease_pids "$GUARD_SCRIPT" "$LIVE_WT" "$LIVE_MAIN")" "rc=0 pids=$npid" \
    "$harness: a relaunched session's claim drops the session from before the boot"
  in_harness "$ndir" bob release "$LIVE_WT" --owner bob --inactive --repo "$LIVE_MAIN"
  assert_eq "rc=$LIVE_RC owner=$(live_owner)" "rc=0 owner=none" \
    "$harness: the relaunched session's close-out releases its lease"
  session_harness_stop "$odir"
  session_harness_stop "$ndir"
}

# A reading that fails is unknown, never dead: each row plants one failure in
# a copy of the scripts under test, against an expired lease whose recorded
# session a working read finds dead. A row: label^file^line^replacement.
READ_FAILURE_ROWS='a failed process read keeps the lease^lib/process-identity.sh^  local stat='"''"' rest rc=0 start^  return 2
a failed identity reading keeps the lease^worktree-session-guard^	local pid start pidns boot host ns_part boot_part status^	return 1'
read_failure_rows() { # HARNESS
  local harness="$1" label file line replacement source_dir copy hdir rc state
  source_dir="$(dirname -- "$GUARD_UNDER_TEST")"
  while IFS='^' read -r label file line replacement; do
    live_tree
    hdir="$LIVE_ROOT/harness-$live_n"
    session_harness_start "$hdir" "$harness"
    LIVE_PATH="$PATH"
    in_harness "$hdir" bob claim "$LIVE_WT" --session
    session_lease_rewrite "$LIVE_WT" expire
    session_lease_rewrite "$LIVE_WT" restart "$SESSION_HARNESS_PID"
    copy="$LIVE_ROOT/read-failure-$live_n"
    cp -R "$source_dir" "$copy"
    assert_eq "$(grep -cxF -- "$line" "$source_dir/$file")" 1 "$harness: $label: the planted line stands once"
    LINE=$line REPLACEMENT=$replacement awk '$0 == ENVIRON["LINE"] { print ENVIRON["REPLACEMENT"]; next } { print }' \
      "$source_dir/$file" >"$copy/$file"
    state="$("$copy/worktree-session-guard" status "$LIVE_WT" --repo "$LIVE_MAIN" 2>/dev/null | jq -r .session_state)" || state=unread
    rc=0
    "$copy/worktree-session-guard" release "$LIVE_WT" --stale --repo "$LIVE_MAIN" >/dev/null 2>&1 || rc=$?
    assert_eq "state=$state rc=$rc owner=$(live_owner)" "state=unknown rc=7 owner=bob" "$harness: $label"
    session_harness_stop "$hdir"
  done <<<"$READ_FAILURE_ROWS"
}

# An established session's claim on a host without flock makes one attempt
# at the exclusive-file mutex another guard holds: maintenance, with the lease
# and that mutex left as they stand.
established_rows() { # HARNESS
  local harness="$1" hdir common
  live_tree
  hdir="$LIVE_ROOT/harness-$live_n"
  session_harness_start "$hdir" "$harness"
  LIVE_PATH="$PATH"
  in_harness "$hdir" bob claim "$LIVE_WT" --session
  common="$(git -C "$LIVE_MAIN" rev-parse --path-format=absolute --git-common-dir)"
  : >"$common/kendex-worktree-session-guard.lock.d"
  LIVE_PATH="$NOFLOCK_BIN"
  in_harness "$hdir" bob claim "$LIVE_WT" --session
  # The busy record is the zero-wait branch's own; a claim that waited out the
  # bound would end on the same exit with the timeout record instead.
  assert_eq "rc=$LIVE_RC first=$(message_records <"$hdir/err" | sed -n 1p) owner=$(live_owner) mutex=$([[ -e $common/kendex-worktree-session-guard.lock.d ]] && echo held || echo gone)" \
    "rc=6 first=worktree-guard-mutex-busy: $common/kendex-worktree-session-guard.lock.d owner=bob mutex=held" \
    "$harness: an established claim without flock makes one attempt at a held mutex"
  rm -f -- "${common:?}/kendex-worktree-session-guard.lock.d"
  session_harness_stop "$hdir"
}

# A session-bound claim whose process table cannot be read records no session
# process and says so, keeping its exit code.
unidentified_rows() {
  local bin="$LIVE_ROOT/no-table-bin" real rc=0 err
  live_tree
  real="$(command -v ps)"
  mkdir -p "$bin"
  printf '#!/usr/bin/env bash\ncase " $* " in *" -A "*) exit 2 ;; esac\nexec %q "$@"\n' "$real" >"$bin/ps"
  chmod +x "$bin/ps"
  err="$(env -u KENDEX_SESSION_OWNER -u HT_SESSION_OWNER USER=bob PATH="$bin:$PATH" "$GUARD_UNDER_TEST" claim "$LIVE_WT" --session 2>&1 >/dev/null)" || rc=$?
  assert_eq "rc=$rc err=$(message_records <<<"$err" | paste -s -d ';' -) owner=$(live_owner) pids=$(session_lease_pids "$GUARD_SCRIPT" "$LIVE_WT" "$LIVE_MAIN")" \
    "rc=0 err=worktree-guard-session-unidentified: path=$LIVE_WT owner=bob pids=" \
    "a session-bound claim that cannot read its session process says so and records none"
}

# The ps reading of a process the suite holds, on every host: a copy of the
# library with its /proc branch taken out reads through ps, as a host without
# /proc does. Only ps's own report of no such process reads as absent.
# A row: label|ps fixture, - for the real ps|status and output shape.
PS_READ_ROWS='ps reads a held process as running|-|rc=0 shape=state_start
ps that reports the PID absent reads as no process|absent|rc=0 shape=empty
ps that fails within itself gives no answer|failing|rc=2 shape=empty'
ps_read_rows() {
  local source lib="$LIVE_ROOT/ps-read-lib.sh" branch='  if [[ -d /proc/self ]]; then' hdir pid label fixture want bin rc out shape
  source="$(dirname -- "$GUARD_UNDER_TEST")/lib/process-identity.sh"
  assert_eq "$(grep -cxF -- "$branch" "$source")" 1 "ps read: the /proc branch stands once"
  BRANCH=$branch awk '$0 == ENVIRON["BRANCH"] { print "  if false; then"; next } { print }' "$source" >"$lib"
  hdir="$LIVE_ROOT/ps-read-holder"
  session_harness_start "$hdir" claude
  pid=$SESSION_HARNESS_PID
  while IFS='|' read -r label fixture want; do
    bin=''
    case "$fixture" in
      absent) bin="$LIVE_ROOT/ps-read-absent"; session_absent_ps "$bin" "$pid" ;;
      failing) bin="$LIVE_ROOT/ps-read-failing"; session_failing_ps "$bin" "$pid" ;;
    esac
    rc=0
    out="$(PATH="${bin:+$bin:}$PATH" "$BASH" -c '. "$1" && process_stat "$2"' _ "$lib" "$pid")" || rc=$?
    if [[ -z "$out" ]]; then
      shape=empty
    elif [[ "$out" =~ ^[A-Za-z]\ [^[:space:]]+$ ]]; then
      shape=state_start
    else
      shape="other:[$out]"
    fi
    assert_eq "rc=$rc shape=$shape" "$want" "ps read: $label"
  done <<<"$PS_READ_ROWS"
  session_harness_stop "$hdir"
}

liveness_rows() { # RUN GUARD GROUP...
  local group
  LIVE_ROOT="$TMP_ROOT/live-$1"
  GUARD_UNDER_TEST="$2"
  shift 2
  make_repo "$LIVE_ROOT"
  LIVE_MAIN="$LIVE_ROOT/main"
  live_n=0
  for group in "$@"; do
    case "$group" in
      shared) shared_rows claude codex; shared_rows codex claude ;;
      reclaim) reclaim_rows claude codex; reclaim_rows codex claude ;;
      release) release_rows claude; release_rows codex ;;
      relaunch) relaunch_rows claude; relaunch_rows codex ;;
      readfail) read_failure_rows claude; read_failure_rows codex ;;
      established) established_rows claude; established_rows codex ;;
      unidentified) unidentified_rows ;;
      psread) ps_read_rows ;;
    esac
  done
}
liveness_rows main "$GUARD_SCRIPT" shared reclaim release readfail established unidentified psread
[[ "$PROC_IDENTITY" != true ]] || liveness_rows boot "$GUARD_SCRIPT" relaunch

# The worktree verbs go through the guard's release. cleanup --stale names a
# lease kept for a live session apart from one not yet past the TTL; remove
# run by the session that holds the lease removes its own worktree, while the
# same command from any other process refuses that live session's lease.
verb_rows() { # RUN SCRIPTS-DIR
  local root="$TMP_ROOT/verbs-$1" script="$2/worktree" tree hdir hpid rc
  make_repo "$root"
  MAIN="$root/main"; ROOT="$root"; add_merged_tree topic
  tree="$root/trees/topic"
  hdir="$root/harness"
  session_harness_start "$hdir" claude
  hpid=$SESSION_HARNESS_PID
  LIVE_PATH="$PATH" LIVE_MAIN="$MAIN" GUARD_UNDER_TEST="$2/worktree-session-guard"
  in_harness "$hdir" topic claim "$tree" --session
  session_lease_rewrite "$tree" expire
  rc=0
  (cd "$MAIN" && env -u KENDEX_SESSION_OWNER -u HT_SESSION_OWNER -u USER GH_STATE="$root/gh-state" "$script" cleanup --stale >/dev/null 2>"$root/err") || rc=$?
  assert_eq "rc=$rc err=$(message_records <"$root/err" | sed "s|$tree|<topic>|g" | paste -s -d ';' -) present=$([[ -d $tree ]] && echo yes || echo no)" \
    "rc=0 err=worktree-cleanup-lease-session-held: <topic> present=yes" \
    "cleanup --stale keeps and names an expired lease whose session lives"
  rc=0
  (cd "$MAIN" && env -u KENDEX_SESSION_OWNER -u HT_SESSION_OWNER -u USER GH_STATE="$root/gh-state" "$script" remove topic >/dev/null 2>"$root/err") || rc=$?
  assert_eq "rc=$rc first=$(message_records <"$root/err" | sed -n "1s|$tree|<topic>|p") present=$([[ -d $tree ]] && echo yes || echo no)" \
    "rc=1 first=worktree-guard-lease-session-held: path=<topic> state=live present=yes" \
    "remove from another process keeps a live session's lease and its worktree"
  rc=0
  session_harness_run "$hdir" "$MAIN" env -u KENDEX_SESSION_OWNER -u HT_SESSION_OWNER -u USER GH_STATE="$root/gh-state" "$script" remove topic || rc=$?
  assert_eq "rc=$rc present=$([[ -d $tree ]] && echo yes || echo no)" "rc=0 present=no" \
    "remove run by the session that holds the lease removes its own worktree"
  session_harness_stop "$hdir"
  # A second merged tree whose expired lease's session is dead is collected.
  add_merged_tree second
  tree="$root/trees/second"
  session_harness_start "$hdir-2" codex
  hpid=$SESSION_HARNESS_PID
  in_harness "$hdir-2" second claim "$tree" --session
  session_lease_rewrite "$tree" expire
  session_lease_rewrite "$tree" restart "$hpid"
  rc=0
  (cd "$MAIN" && env -u KENDEX_SESSION_OWNER -u HT_SESSION_OWNER -u USER GH_STATE="$root/gh-state" "$script" cleanup --stale >/dev/null 2>&1) || rc=$?
  assert_eq "rc=$rc present=$([[ -d $tree ]] && echo yes || echo no)" "rc=0 present=no" \
    "cleanup --stale collects a merged tree whose expired lease's session is dead"
  session_harness_stop "$hdir-2"
}
verb_rows main "$WORKTREE_PACKAGE_DIR/scripts"

# Must-fail controls, each a scripts copy with one text replaced in one file;
# the row groups it names run against it, and the rows listed go red.
# A row: label^file^text^replacement^groups^expected fails^further expected
# fails where the host reads processes through /proc. The fails compare as a
# set.
LIVENESS_CONTROLS='launchers are not skipped^worktree-session-guard^readonly SESSION_LAUNCHERS='"' sh bash dash zsh ksh fish env timeout nice nohup setsid stdbuf '"'^readonly SESSION_LAUNCHERS='"'  '"'^shared^claude: a session-bound claim records the harness process it runs under;claude then codex: a second session on the lease keeps the first one'"'"'s record;claude then codex: one live session holds an expired lease whose other session is dead;claude then codex: the close-out from the holding session itself releases its lease;codex: a session-bound claim records the harness process it runs under;codex then claude: a second session on the lease keeps the first one'"'"'s record;codex then claude: one live session holds an expired lease whose other session is dead;codex then claude: the close-out from the holding session itself releases its lease
a write drops recorded sessions^worktree-session-guard^		out="$out,$identity"^		:^shared^claude then codex: a second session on the lease keeps the first one'"'"'s record;claude then codex: one live session holds an expired lease whose other session is dead;claude then codex: the close-out from the holding session itself releases its lease;codex then claude: a second session on the lease keeps the first one'"'"'s record;codex then claude: one live session holds an expired lease whose other session is dead;codex then claude: the close-out from the holding session itself releases its lease
takeover on age alone^worktree-session-guard^	[[ "$(lease_session_state "$1")" == dead ]]^	:^reclaim^claude holds, codex claims: an expired lease whose session lives stays held;claude holds, codex claims: an expired lease recorded on another host stays held;claude holds, codex claims: an expired lease that records no session stays held;codex holds, claude claims: an expired lease whose session lives stays held;codex holds, claude claims: an expired lease recorded on another host stays held;codex holds, claude claims: an expired lease that records no session stays held^claude holds, codex claims: an expired lease recorded in another PID namespace stays held;claude holds, codex claims: an expired lease whose session'"'"'s wall-clock start moved stays held;codex holds, claude claims: an expired lease recorded in another PID namespace stays held;codex holds, claude claims: an expired lease whose session'"'"'s wall-clock start moved stays held
release on age alone^worktree-session-guard^		none | dead) return 0 ;;^		*) return 0 ;;^release^claude: release --stale keeps an expired lease whose session lives;claude: sweep keeps an expired lease whose session lives;claude: remove'"'"'s close-out from another process keeps a live session'"'"'s lease;codex: release --stale keeps an expired lease whose session lives;codex: sweep keeps an expired lease whose session lives;codex: remove'"'"'s close-out from another process keeps a live session'"'"'s lease
the caller holds its own lease^worktree-session-guard^lease_session_state "$LEASE_TEXT" "$caller"^lease_session_state "$LEASE_TEXT"^shared^claude then codex: the close-out from the holding session itself releases its lease;codex then claude: the close-out from the holding session itself releases its lease
the host rule^worktree-session-guard^ || "$host" != "$HOST_LABEL"^^reclaim^claude holds, codex claims: an expired lease recorded on another host stays held;codex holds, claude claims: an expired lease recorded on another host stays held
a zombie runs^lib/process-identity.sh^if [[ -z "$now" || "${now%% *}" == Z ]]; then^if [[ -z "$now" ]]; then^reclaim^claude holds, codex claims: an expired lease whose session is a zombie is taken over;codex holds, claude claims: an expired lease whose session is a zombie is taken over
a session claim reads nothing silently^worktree-session-guard^[[ -n "$caller" ]] || worktree_message guard-session-unidentified^[[ -n "$caller" ]] || : guard-session-unidentified^unidentified^a session-bound claim that cannot read its session process says so and records none
a failed reading counts as dead^worktree-session-guard^			*) unknown=true ;;^			*) ;;^readfail^claude: a failed process read keeps the lease;claude: a failed identity reading keeps the lease;codex: a failed process read keeps the lease;codex: a failed identity reading keeps the lease
a failed process read counts as ended^worktree-session-guard^! status="$(process_identity_status "$pid" "$start")"^! status="$(process_identity_status "$pid" "$start" || echo ended)"^readfail^claude: a failed process read keeps the lease;codex: a failed process read keeps the lease
an established claim waits for the mutex^worktree-session-guard^acquire_guard_mutex "$COMMON_DIR" 0 ||^acquire_guard_mutex "$COMMON_DIR" ||^established^claude: an established claim without flock makes one attempt at a held mutex;codex: an established claim without flock makes one attempt at a held mutex
an established claim fails its admission^worktree-session-guard^acquire_guard_mutex "$COMMON_DIR" 0 || exit "$EXIT_MAINTENANCE"^acquire_guard_mutex "$COMMON_DIR" 0 || exit 1^established^claude: an established claim without flock makes one attempt at a held mutex;codex: an established claim without flock makes one attempt at a held mutex
a ps diagnostic reads as no process^lib/process-identity.sh^ && -z "$err" ]]^ ]]^psread^ps read: ps that fails within itself gives no answer'
PROC_LIVENESS_CONTROLS='a boot keeps its sessions^worktree-session-guard^	if [[ "$boot_part" == differ ]]; then^	if false; then^reclaim release relaunch^claude holds, codex claims: an expired lease whose session ran before a reboot is taken over;codex holds, claude claims: an expired lease whose session ran before a reboot is taken over;claude: release --stale releases an expired lease whose session ran before a reboot;claude: sweep releases an expired lease whose session ran before a reboot;claude: remove'"'"'s close-out releases a lease whose session ran before a reboot;codex: release --stale releases an expired lease whose session ran before a reboot;codex: sweep releases an expired lease whose session ran before a reboot;codex: remove'"'"'s close-out releases a lease whose session ran before a reboot;claude: a relaunched session'"'"'s claim drops the session from before the boot;claude: the relaunched session'"'"'s close-out releases its lease;codex: a relaunched session'"'"'s claim drops the session from before the boot;codex: the relaunched session'"'"'s close-out releases its lease
the start is wall-clock time^lib/process-identity.sh^  if [[ -d /proc/self ]]; then^  if false; then^reclaim^claude holds, codex claims: an expired lease whose session'"'"'s wall-clock start moved stays held;codex holds, claude claims: an expired lease whose session'"'"'s wall-clock start moved stays held'
[[ "$PROC_IDENTITY" != true ]] || LIVENESS_CONTROLS="$LIVENESS_CONTROLS
$PROC_LIVENESS_CONTROLS"
# Linux names a process started through the worktree script's `#!` line
# after its script, so only argv[0] shows the interpreter the walk passes.
# macOS names it after the interpreter, so there the name alone passes it and
# no walk reaches the argv[0] test this control removes. A probe started
# through the same line reads which naming this host uses.
ARGV0_CONTROL='a script interpreter stops the walk^worktree-session-guard^ && index(launchers, " " argv0[at] " ") == 0^^verbs^remove run by the session that holds the lease removes its own worktree'
probe_shebang="$(head -n 1 -- "$WORKTREE_SCRIPT")" || { echo "worktree_session_guard_lifecycle: comm-probe=shebang-unreadable" >&2; exit 1; }
[[ "$probe_shebang" == '#!'* ]] || { echo "worktree_session_guard_lifecycle: comm-probe=no-shebang value=[$probe_shebang]" >&2; exit 1; }
printf '%s\nLC_ALL=C ps -o comm= -p "$$"\n' "$probe_shebang" >"$TMP_ROOT/comm-probe" \
  || { echo "worktree_session_guard_lifecycle: comm-probe=write-failed" >&2; exit 1; }
chmod -- +x "$TMP_ROOT/comm-probe" || { echo "worktree_session_guard_lifecycle: comm-probe=chmod-failed" >&2; exit 1; }
probe_comm="$("$TMP_ROOT/comm-probe")" || { echo "worktree_session_guard_lifecycle: comm-probe=ps-failed" >&2; exit 1; }
probe_comm="${probe_comm#"${probe_comm%%[![:space:]]*}"}"
probe_comm="${probe_comm%"${probe_comm##*[![:space:]]}"}"
probe_interpreter="${probe_shebang#'#!'}"
probe_interpreter="${probe_interpreter%% *}"
case "${probe_comm##*/}" in
  comm-probe) LIVENESS_CONTROLS="$LIVENESS_CONTROLS
$ARGV0_CONTROL" ;;
  "${probe_interpreter##*/}") ;;
  *) echo "worktree_session_guard_lifecycle: comm-probe=unexpected value=[$probe_comm]" >&2; exit 1 ;;
esac
control_n=0
while IFS='^' read -r control_label control_file control_text control_replacement control_groups expected_fails proc_fails; do
  [[ "$PROC_IDENTITY" != true || -z "$proc_fails" ]] || expected_fails="$expected_fails;$proc_fails"
  control_n=$((control_n + 1))
  control_dir="$TMP_ROOT/liveness-control-$control_n"
  cp -R "$WORKTREE_PACKAGE_DIR/scripts" "$control_dir"
  control_source="$WORKTREE_PACKAGE_DIR/scripts/$control_file"
  assert_eq "$(grep -cF -- "$control_text" "$control_source")" "1" \
    "control: $control_label replaces text $control_file holds once"
  CONTROL_TEXT=$control_text CONTROL_REPLACEMENT=$control_replacement awk '{ i = index($0, ENVIRON["CONTROL_TEXT"]); if (i) $0 = substr($0, 1, i - 1) ENVIRON["CONTROL_REPLACEMENT"] substr($0, i + length(ENVIRON["CONTROL_TEXT"])); print }' \
    "$control_source" >"$control_dir/$control_file"
  ! cmp -s "$control_source" "$control_dir/$control_file" || { echo "worktree_session_guard_lifecycle: control=$control_label mutation=unchanged" >&2; exit 2; }
  if [[ "$control_groups" == verbs ]]; then
    liveness_control_log="$(PASS=0 FAIL=0; verb_rows "control-$control_n" "$control_dir"; session_harness_stop_all)"
  else
    liveness_control_log="$(PASS=0 FAIL=0; liveness_rows "control-$control_n" "$control_dir/worktree-session-guard" $control_groups; session_harness_stop_all)"
  fi
  assert_eq "$(sed -n 's/^  FAIL  //p' <<<"$liveness_control_log" | LC_ALL=C sort | paste -s -d ';' -)" \
    "$(tr ';' '\n' <<<"$expected_fails" | LC_ALL=C sort | paste -s -d ';' -)" \
    "control: the planted guard ($control_label) fails its rows"
done <<<"$LIVENESS_CONTROLS"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
