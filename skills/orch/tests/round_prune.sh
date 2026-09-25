#!/usr/bin/env bash
# round-prune: the round-start prune of a lane worktree's build output. Past the
# disk mark it runs the owner-scoped `worktree cleanup --targets-only` under the
# item's own lease and records the bytes in workflow state; below the mark it
# prunes nothing. Each row builds a fresh checkout with a linked worktree at
# trees/topic holding Cargo output, leased to KEN-1 the way start-worktree
# claims it, and a df on PATH reporting the row's disk use.
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

# df as round-prune calls it, `df -P -- PATH`, answering FAKE_DF_USED percent.
mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/df" <<'SH'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/fake 1000 %s %s %s%% /\n' "${FAKE_DF_USED:?}" "$((1000 - FAKE_DF_USED))" "$FAKE_DF_USED"
SH
chmod +x "$TMP_ROOT/bin/df"

ROOT="" MAIN="" WT="" STATE=""
# An artifact of N real bytes; a truncated file would allocate no blocks.
fill() { head -c "$2" /dev/zero >"$1"; }

build() { # NAME [LEASE_OWNER]
  ROOT="$TMP_ROOT/$1"
  MAIN="$ROOT/main"
  WT="$ROOT/trees/topic"
  STATE="$ROOT/state"
  mkdir -p "$MAIN" "$STATE"
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email test@example.com
  git -C "$MAIN" config user.name Test
  git -C "$MAIN" config commit.gpgsign false
  printf '[package]\nname = "x"\n' >"$MAIN/Cargo.toml"
  printf '/target\n' >"$MAIN/.gitignore"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -q -m base
  git -C "$MAIN" worktree add -q -b topic "$WT" main
  mkdir -p "$WT/target/debug/deps"
  : >"$WT/target/debug/.cargo-lock"
  fill "$WT/target/debug/deps/unit-0.rlib" 65536
  [[ -z "${2:-}" ]] || "$SESSION_GUARD" claim "$WT" --owner "$2" >/dev/null
  "$ORCH_SCRIPTS/workflow-state" --state-dir "$STATE" init KEN-1 --worktree "$WT" --branch topic >/dev/null
}

# One validation run writing the artifact of source state N, the way a build
# after a dependency change writes a unit under a new hash beside the old one.
full_run() {
  mkdir -p "$WT/target/debug/deps"
  fill "$WT/target/debug/deps/unit-$1.rlib" 65536
}

OUT="" RC=0
prune() { # USED [SCRIPTS_DIR] — a fresh round id, then the round-start prune
  local scripts="${2:-$ORCH_SCRIPTS}"
  "$ORCH_SCRIPTS/workflow-state" --state-dir "$STATE" new-round-id KEN-1 dev_round_id >/dev/null
  RC=0
  OUT="$(cd "$MAIN" && env PATH="$TMP_ROOT/bin:$PATH" FAKE_DF_USED="$1" ORCH_ROUND_PRUNE_DISK_PCT=75 \
    ORCH_WORKTREE_BIN="$REPO_ROOT/skills/worktree/scripts/worktree" \
    "$scripts/round-prune" --state-dir "$STATE" KEN-1 2>/dev/null)" || RC=$?
}

# The round-prune line with the round, worktree and a positive byte figure aliased.
line() {
  printf '%s' "$OUT" | sed -e "s| round=[^ ]*| round=<round>|" -e "s| worktree=$WT$| worktree=<wt>|" \
    -e 's/ bytes=[1-9][0-9]*/ bytes=<positive>/'
}

recorded() { # — the current round's record, bytes aliased as in line()
  "$ORCH_SCRIPTS/workflow-state" --state-dir "$STATE" get KEN-1 \
    '.round_prunes[.dev_round_id] | "\(.action) used=\(.used_pct) mark=\(.mark_pct) bytes=\(if .bytes > 0 then "<positive>" else .bytes end)"'
}

artifacts() { (cd "$WT/target/debug" && find . -type f | sed 's|^\./||' | sort | paste -s -d ',' -); }

echo "=== round-prune: the mark decides ==="
# label|disk used %|lease owner|rc|line action and bytes|record|artifacts left
ROWS="
past the mark the round prunes the lane's own output under its lease|80|KEN-1|0|pruned used-pct=80 mark-pct=75 bytes=<positive>|pruned used=80 mark=75 bytes=<positive>|.cargo-lock
at the mark it prunes too|75|KEN-1|0|pruned used-pct=75 mark-pct=75 bytes=<positive>|pruned used=75 mark=75 bytes=<positive>|.cargo-lock
below the mark nothing is pruned and a warm target stays|74|KEN-1|0|below-mark used-pct=74 mark-pct=75 bytes=0|below-mark used=74 mark=75 bytes=0|.cargo-lock,deps/unit-0.rlib
another session's lease fails the prune, recorded, and keeps the output|80|KEN-9|1|failed used-pct=80 mark-pct=75 bytes=0|failed used=80 mark=75 bytes=0|.cargo-lock,deps/unit-0.rlib
"
n=0
while IFS='|' read -r label used owner rc action record left; do
  [[ -n "$label" ]] || continue
  n=$((n + 1))
  build "row-$n" "$owner"
  prune "$used"
  assert_eq "rc=$RC $(line) | $(recorded) | $(artifacts)" \
    "rc=$rc round-prune: action=$action round=<round> worktree=<wt> | $record | $left" "$label"
done <<<"$ROWS"
[[ "$n" -ge 4 ]] || { echo "the row table was not read" >&2; exit 2; }

# Must-fail control: a copy whose comparison never reaches the mark prunes
# nothing past it, and a copy that always reaches it prunes below it.
MUTANTS="$TMP_ROOT/mutants"
for mutant in never always; do
  mkdir -p "$MUTANTS/$mutant"
  cp -a "$ORCH_SCRIPTS" "$MUTANTS/$mutant/scripts"
  case "$mutant" in
    never) replacement='if false; then' ;;
    always) replacement='if true; then' ;;
  esac
  sed -i.bak "s/^if \[\[ \"\$used\" -ge \"\$mark\" \]\]; then$/$replacement/" "$MUTANTS/$mutant/scripts/round-prune"
  if cmp -s "$MUTANTS/$mutant/scripts/round-prune" "$MUTANTS/$mutant/scripts/round-prune.bak"; then
    echo "control: the mark comparison could not be replaced in a round-prune copy" >&2
    exit 2
  fi
done
build control-never KEN-1
prune 80 "$MUTANTS/never/scripts"
[[ "$(artifacts)" == ".cargo-lock" ]] &&
  assert_eq "pruned" "not pruned" "control: with the mark never reached the output past it is kept" ||
  assert_eq "kept" "kept" "control: with the mark never reached the output past it is kept"
build control-always KEN-1
prune 74 "$MUTANTS/always/scripts"
[[ "$(artifacts)" == ".cargo-lock,deps/unit-0.rlib" ]] &&
  assert_eq "kept" "pruned" "control: with the mark always reached the output below it is pruned" ||
  assert_eq "pruned" "pruned" "control: with the mark always reached the output below it is pruned"

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
OUT="$(cd "$MAIN" && env PATH="$TMP_ROOT/bin:$PATH" FAKE_DF_USED=80 "$ORCH_SCRIPTS/round-prune" --state-dir "$STATE" KEN-1 2>&1)" || RC=$?
assert_eq "rc=$RC ${OUT%%$'\n'*} left=$(artifacts)" \
  "rc=2 round-prune: state=KEN-1 left=.cargo-lock,deps/unit-0.rlib" \
  "a state with no round id is refused before anything is read or pruned"
# Table-driven: a mark outside 1 to 100 is refused with nothing pruned. A
# non-numeric value never reaches the check: orch-env answers the default for it.
for bad in 0 101; do
  build "mark-$bad" KEN-1
  "$ORCH_SCRIPTS/workflow-state" --state-dir "$STATE" new-round-id KEN-1 dev_round_id >/dev/null
  RC=0
  OUT="$(cd "$MAIN" && env PATH="$TMP_ROOT/bin:$PATH" FAKE_DF_USED=80 ORCH_ROUND_PRUNE_DISK_PCT="$bad" \
    "$ORCH_SCRIPTS/round-prune" --state-dir "$STATE" KEN-1 2>&1)" || RC=$?
  assert_eq "rc=$RC ${OUT%%$'\n'*} left=$(artifacts)" \
    "rc=2 round-prune: mark=$bad left=.cargo-lock,deps/unit-0.rlib" \
    "the mark $bad is refused before anything is pruned"
done

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
