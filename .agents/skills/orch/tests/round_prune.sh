#!/usr/bin/env bash
# round-prune: the round-start prune of a lane worktree's build output. Past the
# disk mark it runs the owner-scoped `worktree cleanup --targets-only` under the
# item's own lease and records the bytes in workflow state; below the mark it
# prunes nothing. Each row builds a fresh checkout with a linked worktree at
# trees/topic on branch ken-1 holding Cargo output, leased to KEN-1 the way start-worktree
# claims it, and a df on PATH reporting the row's disk use for the target/
# volume and a far lower use for any other path.
#
# Bash 3.2 compatible.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
export LC_ALL=C

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
ORCH_SCRIPTS="$REPO_ROOT/skills/orch/scripts"
SESSION_GUARD="$REPO_ROOT/skills/worktree/scripts/worktree-session-guard"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)" || exit 2
trap 'rm -rf "$TMP_ROOT"' EXIT

# mutant_scripts and mutate_file, the two halves of the control below.
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

# df as round-prune calls it, `df -P -- PATH`: DF_TARGET_USED percent for a
# path ending in /target, DF_OUTSIDE_USED for one ending in /cargo-out, 10
# percent for any other, so a row holds only while the volume of the target
# the build uses is the one read. DF_FAIL fails it and DF_JUNK prints a use
# that is not a number.
mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/df" <<'SH'
#!/usr/bin/env bash
[[ -z "${DF_FAIL:-}" ]] || exit 1
used=10
case "${!#}" in
  */target) used="${DF_TARGET_USED:?}" ;;
  */cargo-out) used="${DF_OUTSIDE_USED:?}" ;;
esac
[[ -z "${DF_JUNK:-}" ]] || used=unknown
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/fake 1000 1 1 %s%% /\n' "$used"
SH
chmod +x "$TMP_ROOT/bin/df"

ROOT="" MAIN="" WT="" STATE=""
# An artifact of N real bytes; a truncated file would allocate no blocks.
fill() { head -c "$2" /dev/zero >"$1"; }

KEY="" BRANCH=""
build() { # NAME [LEASE_OWNER] [STATE_WORKTREE] [STATE_KEY] [BRANCH]
  # STATE_WORKTREE: "branch" records the branch alone, "none" a branch no
  # worktree has checked out, "main" the main checkout and its branch as an
  # ad-hoc local review key records them, anything else the worktree and its
  # branch.
  ROOT="$TMP_ROOT/$1"
  MAIN="$ROOT/main"
  WT="$ROOT/trees/topic"
  KEY="${4:-KEN-1}"
  BRANCH="${5:-ken-1}"
  STATE="$ROOT/state"
  mkdir -p "$MAIN" "$STATE"
  git -C "$MAIN" init -q -b main
  # The EXIT trap removes this repository, so no background writer may race it.
  git -C "$MAIN" config gc.auto 0
  git -C "$MAIN" config maintenance.auto false
  git -C "$MAIN" config user.email test@example.com
  git -C "$MAIN" config user.name Test
  git -C "$MAIN" config commit.gpgsign false
  printf '[package]\nname = "x"\n' >"$MAIN/Cargo.toml"
  printf '/target\n' >"$MAIN/.gitignore"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -q -m base
  git -C "$MAIN" worktree add -q -b "$BRANCH" "$WT" main
  mkdir -p "$WT/target/debug/deps"
  : >"$WT/target/debug/.cargo-lock"
  fill "$WT/target/debug/deps/unit-0.rlib" 65536
  [[ -z "${2:-}" ]] || "$SESSION_GUARD" claim "$WT" --owner "$2" >/dev/null
  if [[ "${3:-}" == branch ]]; then
    "$ORCH_SCRIPTS/workflow-state" --state-dir "$STATE" init "$KEY" --branch "$BRANCH" >/dev/null
  elif [[ "${3:-}" == none ]]; then
    "$ORCH_SCRIPTS/workflow-state" --state-dir "$STATE" init "$KEY" --branch gone-branch >/dev/null
  elif [[ "${3:-}" == main ]]; then
    "$ORCH_SCRIPTS/workflow-state" --state-dir "$STATE" init "$KEY" --worktree "$MAIN" --branch main >/dev/null
  else
    "$ORCH_SCRIPTS/workflow-state" --state-dir "$STATE" init "$KEY" --worktree "$WT" --branch "$BRANCH" >/dev/null
  fi
}

# A package installed from a lock file, the output the round-start prune must
# leave: nothing reinstalls it between rounds.
install_js() {
  mkdir -p "$WT/pkg/node_modules/left-pad"
  printf '{"name":"pkg"}\n' >"$WT/pkg/package.json"
  printf '{"lockfileVersion":3}\n' >"$WT/pkg/package-lock.json"
  fill "$WT/pkg/node_modules/left-pad/index.js" 4096
}

# One validation run writing the artifact of source state N, the way a build
# after a dependency change writes a unit under a new hash beside the old one.
full_run() {
  mkdir -p "$WT/target/debug/deps"
  fill "$WT/target/debug/deps/unit-$1.rlib" 65536
}

OUT="" RC=0
ROW_ENV=()
prune() { # USED [SCRIPTS_DIR] — a fresh round id, then the round-start prune
  local scripts="${2:-$ORCH_SCRIPTS}"
  "$ORCH_SCRIPTS/workflow-state" --state-dir "$STATE" new-round-id "$KEY" dev_round_id >/dev/null
  RC=0
  OUT="$(cd "$MAIN" && env -u CARGO_TARGET_DIR PATH="$TMP_ROOT/bin:$PATH" DF_TARGET_USED="$1" ORCH_ROUND_PRUNE_DISK_PCT=75 \
    ORCH_WORKTREE_BIN="$REPO_ROOT/skills/worktree/scripts/worktree" ${ROW_ENV[@]+"${ROW_ENV[@]}"} \
    "$scripts/round-prune" --state-dir "$STATE" "$KEY" 2>/dev/null)" || RC=$?
}

# A worktree CLI that reports a whole prune and then exits 1, as one whose
# claimed lease could not be released does after the engine's summary.
cat >"$TMP_ROOT/bin/summary-then-fail" <<'SH'
#!/usr/bin/env bash
printf 'worktree-output-prune-summary: worktree=x mode=apply units=1 bytes=4096 uninspected-processes=0\n'
exit 1
SH
chmod +x "$TMP_ROOT/bin/summary-then-fail"

# Row setups, each on the fresh checkout build made.
row_setup() {
  ROW_ENV=()
  case "$1" in
    -) ;;
    js) install_js ;;
    hold-lock)
      flock -x "$WT/target/debug/.cargo-lock" -c "touch '$ROOT/locked'; sleep 60" &
      HOLDER=$!
      while [[ ! -e "$ROOT/locked" ]]; do sleep 0.05; done
      ;;
    summary-fails) ROW_ENV=("ORCH_WORKTREE_BIN=$TMP_ROOT/bin/summary-then-fail") ;;
    target-relative) ROW_ENV=("CARGO_TARGET_DIR=target") ;;
    target-absolute) ROW_ENV=("CARGO_TARGET_DIR=$WT/target") ;;
    # A Cargo target on a path outside the worktree, holding a built profile,
    # on a volume full or roomy while the worktree's own reads the row's use.
    target-outside-full | target-outside-roomy)
      mkdir -p "$ROOT/outside/cargo-out/debug/deps"
      : >"$ROOT/outside/cargo-out/debug/.cargo-lock"
      fill "$ROOT/outside/cargo-out/debug/deps/unit-9.rlib" 4096
      ROW_ENV=("CARGO_TARGET_DIR=$ROOT/outside/cargo-out")
      case "$1" in
        *full) ROW_ENV+=(DF_OUTSIDE_USED=80) ;;
        *) ROW_ENV+=(DF_OUTSIDE_USED=74) ;;
      esac
      ;;
    *) echo "UNKNOWN-SETUP: $1" >&2; exit 2 ;;
  esac
}
HOLDER=""
row_teardown() {
  [[ -z "$HOLDER" ]] || { kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; HOLDER=""; }
}

# The round-prune line with the round, worktree and a positive byte figure aliased.
line() {
  printf '%s' "$OUT" | sed -e "s| round=[^ ]*| round=<round>|" -e "s| worktree=$WT$| worktree=<wt>|" \
    -e 's/ bytes=[1-9][0-9]*/ bytes=<positive>/'
}

recorded() { # — the current round's record, bytes aliased as in line()
  "$ORCH_SCRIPTS/workflow-state" --state-dir "$STATE" get "$KEY" \
    '.round_prunes[.dev_round_id] | "\(.action) used=\(.used_pct) mark=\(.mark_pct) bytes=\(if .bytes > 0 then "<positive>" else .bytes end)"'
}

artifacts() { (cd "$WT/target/debug" && find . -type f | sed 's|^\./||' | sort | paste -s -d ',' -); }
js_left() { [[ ! -d "$WT/pkg" ]] || printf ' js=%s' "$(cd "$WT/pkg" && find node_modules -type f | paste -s -d ',' -)"; }
outside_left() { [[ ! -d "$ROOT/outside" ]] || printf ' outside=%s' "$(cd "$ROOT/outside/cargo-out/debug" && find deps -type f | paste -s -d ',' -)"; }

echo "=== round-prune: the mark decides ==="
# label|target/ volume use %|state key|branch|lease owner|state worktree|setup|rc|line action and bytes|record|output left
ROWS="
past the mark the round prunes the lane's own output under its lease|80|KEN-1|ken-1|KEN-1|-|-|0|pruned used-pct=80 mark-pct=75 bytes=<positive>|pruned used=80 mark=75 bytes=<positive>|.cargo-lock
at the mark it prunes too|75|KEN-1|ken-1|KEN-1|-|-|0|pruned used-pct=75 mark-pct=75 bytes=<positive>|pruned used=75 mark=75 bytes=<positive>|.cargo-lock
below the mark nothing is pruned and a warm target stays|74|KEN-1|ken-1|KEN-1|-|-|0|below-mark used-pct=74 mark-pct=75 bytes=0|below-mark used=74 mark=75 bytes=0|.cargo-lock,deps/unit-0.rlib
another session's lease fails the prune, recorded, and keeps the output|80|KEN-1|ken-1|KEN-9|-|-|1|failed used-pct=80 mark-pct=75 bytes=0|failed used=80 mark=75 bytes=0|.cargo-lock,deps/unit-0.rlib
past the mark a lock-file node_modules survives the round|80|KEN-1|ken-1|KEN-1|-|js|0|pruned used-pct=80 mark-pct=75 bytes=<positive>|pruned used=80 mark=75 bytes=<positive>|.cargo-lock js=node_modules/left-pad/index.js
a build holding the target lock fails the round and keeps the output|80|KEN-1|ken-1|KEN-1|-|hold-lock|1|failed used-pct=80 mark-pct=75 bytes=0|failed used=80 mark=75 bytes=0|.cargo-lock,deps/unit-0.rlib
a prune that reports its summary and then exits non-zero is failed, not pruned|80|KEN-1|ken-1|KEN-1|-|summary-fails|1|failed used-pct=80 mark-pct=75 bytes=<positive>|failed used=80 mark=75 bytes=<positive>|.cargo-lock,deps/unit-0.rlib
a state keyed apart from the lease prunes under the owner its branch names|80|pr-5|ken-1|KEN-1|-|-|0|pruned used-pct=80 mark-pct=75 bytes=<positive>|pruned used=80 mark=75 bytes=<positive>|.cargo-lock
a branch naming no issue is pruned under the state key|80|KEN-1|topic|KEN-1|-|-|0|pruned used-pct=80 mark-pct=75 bytes=<positive>|pruned used=80 mark=75 bytes=<positive>|.cargo-lock
a state carrying only a branch prunes the worktree that has it checked out|80|pr-5|ken-1|KEN-1|branch|-|0|pruned used-pct=80 mark-pct=75 bytes=<positive>|pruned used=80 mark=75 bytes=<positive>|.cargo-lock
a state whose branch no worktree holds records no-worktree and lets the round go|80|pr-5|ken-1|KEN-1|none|-|0|no-worktree used-pct=0 mark-pct=75 bytes=0|no-worktree used=0 mark=75 bytes=0|.cargo-lock,deps/unit-0.rlib
a state naming the main checkout records no-worktree and prunes nothing|80|pr-5|ken-1|KEN-1|main|-|0|no-worktree used-pct=0 mark-pct=75 bytes=0|no-worktree used=0 mark=75 bytes=0|.cargo-lock,deps/unit-0.rlib
a relative CARGO_TARGET_DIR naming the worktree's target/ is pruned|80|KEN-1|ken-1|KEN-1|-|target-relative|0|pruned used-pct=80 mark-pct=75 bytes=<positive>|pruned used=80 mark=75 bytes=<positive>|.cargo-lock
an absolute CARGO_TARGET_DIR at the worktree's target/ is pruned|80|KEN-1|ken-1|KEN-1|-|target-absolute|0|pruned used-pct=80 mark-pct=75 bytes=<positive>|pruned used=80 mark=75 bytes=<positive>|.cargo-lock
past the mark a CARGO_TARGET_DIR outside the worktree fails closed and prunes nothing|10|KEN-1|ken-1|KEN-1|-|target-outside-full|1|target-elsewhere used-pct=80 mark-pct=75 bytes=0|target-elsewhere used=80 mark=75 bytes=0|.cargo-lock,deps/unit-0.rlib outside=deps/unit-9.rlib
below the mark a CARGO_TARGET_DIR outside the worktree prunes nothing, read on its own volume|80|KEN-1|ken-1|KEN-1|-|target-outside-roomy|0|below-mark used-pct=74 mark-pct=75 bytes=0|below-mark used=74 mark=75 bytes=0|.cargo-lock,deps/unit-0.rlib outside=deps/unit-9.rlib
"
n=0
while IFS='|' read -r label used key branch owner state_wt setup rc action record left; do
  [[ -n "$label" ]] || continue
  n=$((n + 1))
  build "row-$n" "$owner" "$state_wt" "$key" "$branch"
  row_setup "$setup"
  prune "$used"
  row_teardown
  assert_eq "rc=$RC $(line) | $(recorded) | $(artifacts)$(js_left)$(outside_left)" \
    "rc=$rc round-prune: action=$action round=<round> worktree=$([[ "$state_wt" == none || "$state_wt" == main ]] || echo '<wt>') | $record | $left" "$label"
done <<<"$ROWS"
[[ "$n" -ge 15 ]] || { echo "the row table was not read" >&2; exit 2; }
row_setup -


# The suite's one must-fail control: a copy whose comparison never reaches the
# mark prunes nothing past it.
NEVER="$(mutant_scripts never round-prune)" || exit 1
mutate_file "$NEVER/round-prune" 'if [[ "$used" -ge "$mark" ]]; then' 'if false; then'
build control-never KEN-1
prune 80 "$NEVER"
[[ "$(artifacts)" == ".cargo-lock" ]] &&
  assert_eq "pruned" "not pruned" "control: with the mark never reached the output past it is kept" ||
  assert_eq "kept" "kept" "control: with the mark never reached the output past it is kept"

# Must-fail control: a copy that takes the state's worktree field as it stands
# takes the main checkout for a lane's tree.
mkdir -p "$MUTANTS/raw-worktree"
cp -a "$ORCH_SCRIPTS" "$MUTANTS/raw-worktree/scripts"
LW_ANCHOR='worktree="$("$GIT_CONTEXT" lane-worktree "$worktree" "$branch")" || { message worktree-list "$branch" >&2; exit 2; }'
[[ "$(grep -Fc -- "$LW_ANCHOR" "$ORCH_SCRIPTS/round-prune")" == 1 ]] || { echo "control: the lane-worktree call could not be found in round-prune" >&2; exit 2; }
A="$LW_ANCHOR" awk 'index($0, ENVIRON["A"]) { print ":"; next } { print }' "$ORCH_SCRIPTS/round-prune" >"$MUTANTS/raw-worktree/scripts/round-prune"
build control-raw-worktree KEN-1 main pr-5
prune 80 "$MUTANTS/raw-worktree/scripts"
[[ "$(line)" == *"action=no-worktree"* ]] &&
  assert_eq "no-worktree" "another action" "control: taking the worktree field as it stands takes the main checkout for a lane's tree" ||
  assert_eq "taken" "taken" "control: taking the worktree field as it stands takes the main checkout for a lane's tree"

# A worktree listing git cannot give: which tree the state names is unknown,
# so the round refuses with nothing pruned or recorded. SCRIPTS' round-prune
# under a git that fails `worktree list` and runs every other command.
REAL_GIT="$(command -v git)"
GIT_LIST_FAIL_BIN="$TMP_ROOT/git-list-fail-bin"
mkdir -p "$GIT_LIST_FAIL_BIN"
cat > "$GIT_LIST_FAIL_BIN/git" <<STUB
#!/usr/bin/env bash
wt="" list=""
for a in "\$@"; do
  [[ "\$a" != worktree ]] || wt=1
  [[ "\$a" != list ]] || list=1
done
if [[ -n "\$wt" && -n "\$list" ]]; then echo "fatal: planted failure" >&2; exit 128; fi
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$GIT_LIST_FAIL_BIN/git"
listing_refused() { # NAME SCRIPTS
  build "listing-$1" KEN-1
  "$ORCH_SCRIPTS/workflow-state" --state-dir "$STATE" new-round-id "$KEY" dev_round_id >/dev/null
  RC=0
  OUT="$(cd "$MAIN" && env PATH="$GIT_LIST_FAIL_BIN:$TMP_ROOT/bin:$PATH" DF_TARGET_USED=80 \
    "$2/round-prune" --state-dir "$STATE" "$KEY" 2>&1)" || RC=$?
  LISTING="rc=$RC $(grep -m 1 '^round-prune: ' <<<"$OUT" || true) git=$(grep -c -x 'fatal: planted failure' <<<"$OUT" || true) recorded=$("$ORCH_SCRIPTS/workflow-state" --state-dir "$STATE" get "$KEY" '.round_prunes // {} | length') left=$(artifacts)"
}
listing_refused shipped "$ORCH_SCRIPTS"
assert_eq "$LISTING" "rc=2 round-prune: worktree-list=ken-1 git=1 recorded=0 left=.cargo-lock,deps/unit-0.rlib" \
  "a worktree listing git cannot give is refused as worktree-list with nothing pruned or recorded"
# Must-fail control: a copy that drops the refusal reads the failed listing as
# no worktree and records the round.
mkdir -p "$MUTANTS/listing-ignored"
cp -a "$ORCH_SCRIPTS" "$MUTANTS/listing-ignored/scripts"
A="$LW_ANCHOR" awk 'index($0, ENVIRON["A"]) { print "worktree=\"$(\"$GIT_CONTEXT\" lane-worktree \"$worktree\" \"$branch\")\" || worktree=\"\""; next } { print }' \
  "$ORCH_SCRIPTS/round-prune" >"$MUTANTS/listing-ignored/scripts/round-prune"
listing_refused listing-ignored "$MUTANTS/listing-ignored/scripts"
[[ "$LISTING" == "rc=0 "* ]] &&
  assert_eq "recorded" "recorded" "control: without the worktree-list refusal a failed listing records the round" ||
  assert_eq "$LISTING" "rc=0 ..." "control: without the worktree-list refusal a failed listing records the round"

# A registered tree whose directory is gone: git still lists it on the
# state's branch, and it is no lane target. STALE reads SCRIPTS' round.
stale_tree() { # NAME SCRIPTS
  build "stale-$1" KEN-1 branch pr-5
  rm -rf -- "${WT:?}"
  prune 80 "$2"
  STALE="rc=$RC $(line)"
}
stale_tree shipped "$ORCH_SCRIPTS"
assert_eq "$STALE" "rc=0 round-prune: action=no-worktree used-pct=0 mark-pct=75 bytes=0 round=<round> worktree=" \
  "a state whose branch sits on a registered tree with no directory records no-worktree"
# Must-fail control: a git-context that takes a registered tree whatever its
# directory hands the round a target that is gone.
mkdir -p "$MUTANTS/stale-dir"
cp -a "$ORCH_SCRIPTS" "$MUTANTS/stale-dir/scripts"
SD_ANCHOR='[[ -d "$path" ]] || lane=false'
[[ "$(grep -Fc -- "$SD_ANCHOR" "$ORCH_SCRIPTS/git-context")" == 1 ]] || { echo "control: the directory check could not be found in git-context" >&2; exit 2; }
A="$SD_ANCHOR" awk 'index($0, ENVIRON["A"]) { print ":"; next } { print }' "$ORCH_SCRIPTS/git-context" >"$MUTANTS/stale-dir/scripts/git-context"
stale_tree stale-dir "$MUTANTS/stale-dir/scripts"
[[ "$STALE" == *"action=no-worktree"* ]] &&
  assert_eq "$STALE" "another outcome" "control: taking a registered tree whatever its directory hands the round a gone target" ||
  assert_eq "gone target" "gone target" "control: taking a registered tree whatever its directory hands the round a gone target"

echo "=== target/ across two runs ==="
# Two rounds, each starting with the round-start prune and ending with a
# validation run that leaves a superseded unit behind. Past the mark, target/
# after the second run holds what one run wrote; below it, both runs' units.
two_rounds() { # USED
  build "two-$1" KEN-1
  rm -f -- "$WT/target/debug/deps/unit-0.rlib"
  BEFORE="$(du -sk "$WT/target" | cut -f1)"
  prune "$1"
  full_run 1
  AFTER_ONE="$(du -sk "$WT/target" | cut -f1)"
  prune "$1"
  full_run 2
  AFTER_TWO="$(du -sk "$WT/target" | cut -f1)"
}
two_rounds 80
assert_eq "grew=$([[ "$AFTER_ONE" -gt "$BEFORE" ]] && echo yes) bounded=$([[ "$AFTER_TWO" -eq "$AFTER_ONE" ]] && echo yes) left=$(artifacts)" \
  "grew=yes bounded=yes left=.cargo-lock,deps/unit-2.rlib" \
  "past the mark target/ after two runs holds one run's output (kib: $BEFORE, $AFTER_ONE, $AFTER_TWO)"
two_rounds 74
assert_eq "grew=$([[ "$AFTER_TWO" -gt "$AFTER_ONE" ]] && echo yes) left=$(artifacts)" \
  "grew=yes left=.cargo-lock,deps/unit-1.rlib,deps/unit-2.rlib" \
  "below the mark target/ keeps both runs' output (kib: $BEFORE, $AFTER_ONE, $AFTER_TWO)"

echo "=== refusals ==="
build no-round KEN-1
RC=0
OUT="$(cd "$MAIN" && env PATH="$TMP_ROOT/bin:$PATH" DF_TARGET_USED=80 "$ORCH_SCRIPTS/round-prune" --state-dir "$STATE" "$KEY" 2>&1)" || RC=$?
assert_eq "rc=$RC ${OUT%%$'\n'*} left=$(artifacts)" \
  "rc=2 round-prune: state-missing=dev_round_id left=.cargo-lock,deps/unit-0.rlib" \
  "a state with no round id is refused, naming the field, before anything is pruned"
# Table-driven: a df that fails or answers no number refuses with nothing
# pruned or recorded.
for df_case in DF_FAIL=1 DF_JUNK=1; do
  build "df-${df_case%%=*}" KEN-1
  "$ORCH_SCRIPTS/workflow-state" --state-dir "$STATE" new-round-id "$KEY" dev_round_id >/dev/null
  RC=0
  OUT="$(cd "$MAIN" && env PATH="$TMP_ROOT/bin:$PATH" DF_TARGET_USED=80 "$df_case" \
    "$ORCH_SCRIPTS/round-prune" --state-dir "$STATE" "$KEY" 2>&1)" || RC=$?
  assert_eq "rc=$RC ${OUT%%$'\n'*} recorded=$("$ORCH_SCRIPTS/workflow-state" --state-dir "$STATE" get "$KEY" '.round_prunes // {} | length') left=$(artifacts)" \
    "rc=2 round-prune: disk=$WT/target recorded=0 left=.cargo-lock,deps/unit-0.rlib" \
    "a df run with $df_case is refused with nothing pruned or recorded"
done
# Table-driven: a mark outside 1 to 100 is refused with nothing pruned. A
# non-numeric value never reaches the check: orch-env answers the default for it.
for bad in 0 101; do
  build "mark-$bad" KEN-1
  "$ORCH_SCRIPTS/workflow-state" --state-dir "$STATE" new-round-id "$KEY" dev_round_id >/dev/null
  RC=0
  OUT="$(cd "$MAIN" && env PATH="$TMP_ROOT/bin:$PATH" DF_TARGET_USED=80 ORCH_ROUND_PRUNE_DISK_PCT="$bad" \
    "$ORCH_SCRIPTS/round-prune" --state-dir "$STATE" "$KEY" 2>&1)" || RC=$?
  assert_eq "rc=$RC ${OUT%%$'\n'*} left=$(artifacts)" \
    "rc=2 round-prune: mark=$bad left=.cargo-lock,deps/unit-0.rlib" \
    "the mark $bad is refused before anything is pruned"
done

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
