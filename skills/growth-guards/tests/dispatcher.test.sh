#!/usr/bin/env bash
# Pins for scripts/growth-guards (the dispatcher): the batch runs exactly
# the enabled checks and aggregates fail-closed (any incomplete check is
# exit 2, any violation exit 1), single-check invocation passes flags and
# exit codes through, and the check-list configuration is validated.
#
# Marker words are assembled from split tokens so this file never contains
# a marker shape itself.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
GG="$SKILL_DIR/scripts/growth-guards"
. "$TEST_DIR/lib/harness.bash"

unset GROWTH_GUARDS_CHECKS GROWTH_GUARDS_TODO_EXCLUDES GROWTH_GUARDS_BYTE_CEILING_KB \
  GROWTH_GUARDS_BYTE_EXCLUDES GROWTH_GUARDS_SUPPRESSION_EXCLUDES \
  GROWTH_GUARDS_SUPPRESSION_BASELINE GROWTH_GUARDS_CONFLICT_EXCLUDES \
  GROWTH_GUARDS_COMMIT_TYPES GROWTH_GUARDS_SETTINGS_FILE 2>/dev/null || true

TD="TO""DO"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

new_repo() { # NAME
  R="$TMP/$1"
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}

run_gg() { # [VAR=val] -- [args...] — run in $R; sets OUT and RC
  local envs=() args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --)
        shift
        args=("$@")
        break
        ;;
      *) envs+=("$1") ;;
    esac
    shift
  done
  OUT=""
  RC=0
  OUT="$(cd "$R" && env ${envs[@]+"${envs[@]}"} "$GG" ${args[@]+"${args[@]}"} 2>&1)" || RC=$?
}

echo "=== batch: a clean repo runs every default check and passes ==="
new_repo clean
printf 'fn main() {}\n' >"$R/ok.rs"
git -C "$R" add -A
run_gg
[ "$RC" -eq 0 ] \
  && case "$OUT" in *"growth-guards: todo-ban"*"growth-guards: byte-ceiling"*"growth-guards: suppression-ban"*"growth-guards: conflict-markers"*"growth-guards: OK"*) true ;; *) false ;; esac \
  && ok "the batch runs todo-ban, byte-ceiling, suppression-ban, conflict-markers and reports OK" \
  || bad "batch runs the four default checks" "rc=$RC out=$OUT"
run_gg -- all
[ "$RC" -eq 0 ] && ok "'all' is the same batch" || bad "'all' is the same batch" "rc=$RC out=$OUT"

echo "=== batch: one violating check makes the batch exit 1 ==="
printf '// %s: planted for the dispatcher\n' "$TD" >"$R/planted.rs"
git -C "$R" add -A
run_gg
[ "$RC" -eq 1 ] && case "$OUT" in *"growth-guards: violations"*) true ;; *) false ;; esac \
  && ok "a todo-ban violation aggregates to batch exit 1" \
  || bad "violation aggregates to exit 1" "rc=$RC out=$OUT"

echo "=== GROWTH_GUARDS_CHECKS narrows the batch (and that is provable) ==="
run_gg GROWTH_GUARDS_CHECKS=byte-ceiling --
[ "$RC" -eq 0 ] && case "$OUT" in *todo-ban*) false ;; *"growth-guards: byte-ceiling"*) true ;; *) false ;; esac \
  && ok "with only byte-ceiling enabled, the planted marker no longer fails the batch" \
  || bad "narrowed batch skips todo-ban" "rc=$RC out=$OUT"
run_gg
[ "$RC" -eq 1 ] && ok "control: the default batch still fails on the same fixture" \
  || bad "control: default batch fails on the fixture" "rc=$RC out=$OUT"
git -C "$R" rm -q --cached planted.rs
rm "$R/planted.rs"

echo "=== check-list validation fails loud ==="
run_gg GROWTH_GUARDS_CHECKS=commit-msg --
[ "$RC" -eq 2 ] && case "$OUT" in *"cannot run in the batch"*) true ;; *) false ;; esac \
  && ok "commit-msg in the batch list is exit 2 with the hook pointer" \
  || bad "commit-msg in the batch list is exit 2" "rc=$RC out=$OUT"
run_gg GROWTH_GUARDS_CHECKS=no-such-check --
[ "$RC" -eq 2 ] && case "$OUT" in *"unknown check 'no-such-check'"*) true ;; *) false ;; esac \
  && ok "an unknown name in the check list is exit 2" \
  || bad "unknown name in the check list is exit 2" "rc=$RC out=$OUT"
run_gg "GROWTH_GUARDS_CHECKS= " --
[ "$RC" -eq 2 ] && ok "an empty check list is exit 2" || bad "empty check list is exit 2" "rc=$RC out=$OUT"

echo "=== batch aggregation is fail-closed: an incomplete check is exit 2 ==="
run_gg GROWTH_GUARDS_BYTE_CEILING_KB=abc --
[ "$RC" -eq 2 ] && case "$OUT" in *"did not complete (exit 2)"*"could not complete every check"*) true ;; *) false ;; esac \
  && ok "a check that exits 2 makes the whole batch exit 2, named in the summary" \
  || bad "incomplete check aggregates to exit 2" "rc=$RC out=$OUT"

echo "=== single-check invocation: exit codes and flags pass through ==="
run_gg -- todo-ban
[ "$RC" -eq 0 ] && case "$OUT" in "todo-ban: OK"*) true ;; *) false ;; esac \
  && ok "a single check runs alone with its own output" || bad "single check runs alone" "rc=$RC out=$OUT"
run_gg -- byte-ceiling --all
[ "$RC" -eq 0 ] && case "$OUT" in *"full sweep"*) true ;; *) false ;; esac \
  && ok "flags pass through to the named check (--all reached byte-ceiling)" \
  || bad "flags pass through" "rc=$RC out=$OUT"
OUT="$(cd "$R" && printf 'feat: dispatched\n' | "$GG" commit-msg 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 0 ] && ok "commit-msg IS invocable by name (only the batch refuses it)" \
  || bad "commit-msg invocable by name" "rc=$RC out=$OUT"
run_gg -- no-such-check
[ "$RC" -eq 2 ] && case "$OUT" in *"unknown check 'no-such-check'"*) true ;; *) false ;; esac \
  && ok "an unknown check name is exit 2 naming the known set" \
  || bad "unknown check name is exit 2" "rc=$RC out=$OUT"
run_gg -- all --extra
[ "$RC" -eq 2 ] && ok "'all' with extra arguments is exit 2" || bad "'all' with extras is exit 2" "rc=$RC out=$OUT"
run_gg -- --help
[ "$RC" -eq 0 ] && case "$OUT" in *"usage: growth-guards"*) true ;; *) false ;; esac \
  && ok "--help prints usage at exit 0" || bad "--help prints usage" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
