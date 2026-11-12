#!/usr/bin/env bash
# tools/guard runs every selected shell suite, across trees, in one
# skills/orch/tests/run-all.sh call: one --battery per tree and filters
# qualified by tree, so a base name two trees share selects one suite. A
# .test.mjs suite keeps its own direct run. The runner rows prove the
# qualified filter, that orch's ALONE list still holds in a --battery pool,
# and that the runner copies these rows mutate are never discovered as suites.
# Inputs: tools/guard, skills/orch/tests/run-all.sh
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/lib/guard-world.sh"

# --- the runner ---------------------------------------------------------------
# W is a repository holding a copy of the runner, so a row can mutate its
# source, and three trees: skills/a and skills/b share same.test, and the
# runner's own directory holds a suite planted in its ALONE list.
W="$TMP/pool"
runner_copy() { # NAME [SED-EXPR] — a runner at $W/skills/orch/tests/NAME.runner,
  # which the battery it sits in does not take for a suite
  local src="$W/skills/orch/tests/$1.runner"
  cp "$REPO/skills/orch/tests/run-all.sh" "$src"
  sed -i.bak '/^ALONE=($/a\
  held
' "$src"
  [ -z "${2:-}" ] || sed -i.bak "$2" "$src"
  rm -f -- "$src.bak"
}
mkdir -p "$W/skills/a/tests" "$W/skills/b/tests" "$W/skills/orch/tests/lib" \
  "$W/skills/orch/scripts/lib" "$W/skills/github/scripts/lib" "$TMP/pool-bin"
git -C "$W" init -q
cp "$REPO/skills/orch/tests/lib/suite-process.sh" "$W/skills/orch/tests/lib/"
printf '#!/usr/bin/env bash\n:\n' > "$W/skills/orch/tests/lib/git-env.sh"
cp "$REPO/skills/orch/scripts/lib/lane-state.sh" "$W/skills/orch/scripts/lib/"
cp "$REPO/skills/github/scripts/lib/group-leader.sh" "$W/skills/github/scripts/lib/"
for s in a/tests/same.test b/tests/same.test b/tests/other.test orch/tests/held orch/tests/pooled; do
  printf '#!/usr/bin/env bash\necho "pass: 1   fail: 0"\n' > "$W/skills/$s.sh"
done
printf '#!/usr/bin/env bash\necho 4\n' > "$TMP/pool-bin/nproc"
chmod +x "$TMP/pool-bin/nproc"
runner_copy run-all
grep -q '^ *held$' "$W/skills/orch/tests/run-all.runner" || bad "the copied runner's ALONE list holds the planted name"
runner_copy unqualified '/^    =\*:\*) battery_tree/d'
runner_copy alone-dropped 's/^  TEST_DIRS=()$/  ALONE=(); TEST_DIRS=()/'

echo "=== the battery that holds the copied runners discovers none of them ==="
# A copy the runner took for a suite would run its own battery, itself
# included, without end. The runner hands its discovered suites to
# RUN_ALL_NATIVE_CONTRACTS before it starts any; this probe records them and
# refuses, so no suite starts.
printf '#!/usr/bin/env bash\ncat > "$DISCOVERED"\nexit 1\n' > "$TMP/discover"
chmod +x "$TMP/discover"
discovered() { # BATTERY — the base names the runner discovers in BATTERY
  : > "$TMP/discovered"
  (cd "$W" && DISCOVERED="$TMP/discovered" RUN_ALL_NATIVE_CONTRACTS="$TMP/discover" TMPDIR="$TMP" \
    bash "$REPO/skills/orch/tests/run-all.sh" --battery "$1" >/dev/null 2>&1) || true
  sed 's|.*/||' "$TMP/discovered" | paste -sd ' ' -
}
got="$(discovered skills/orch/tests)"
if [ "$got" = "held.sh pooled.sh" ]; then ok "no copied runner is discovered as a suite"
else
  bad "no copied runner is discovered as a suite" "got [$got]"
  # The rows below would run the copy, and it would recurse.
  printf 'pass: %s   fail: %s\n' "$PASS" "$FAIL"
  exit 1
fi
mkdir -p "$W/skills/copied/tests"
cp "$REPO/skills/orch/tests/run-all.sh" "$W/skills/copied/tests/copied.sh"
got="$(discovered skills/copied/tests)"
if [ "$got" = copied.sh ]; then ok "control: a copied runner named .sh is discovered as a suite"
else bad "control: a copied runner named .sh is discovered as a suite" "got [$got]"; fi

STARTED=""
run_pool() { # RUNNER ARG... — the start order in STARTED, the status in RC
  local runner=$1
  shift
  RC=0
  OUT="$(cd "$W" && PATH="$TMP/pool-bin:$PATH" TMPDIR="$TMP" bash "$W/skills/orch/tests/$runner.runner" \
    --battery skills/a/tests --battery skills/b/tests "$@" 2>&1)" || RC=$?
  STARTED="$(sed -n 's/^start suite=//p' <<<"$OUT" | paste -sd ' ' -)"
}

echo "=== a filter qualified by tree selects that tree's suite alone ==="
# name | filters | rc and start order
while IFS='|' read -r name filters want; do
  # shellcheck disable=SC2086 # the filter list splits into its words
  run_pool run-all $filters
  got="rc=$RC${STARTED:+ $STARTED}"
  if [ "$got" = "$want" ]; then ok "$name"; else bad "$name" "want [$want] got [$got] out=$OUT"; fi
done <<'ROWS'
one tree's suite, where both trees hold the base name|=skills/a:same.test|rc=0 a--same.test
one suite from each tree|=skills/a:same.test =skills/b:other.test|rc=0 a--same.test b--other.test
a qualified rejector leaves the other tree's suite of that name|!=skills/a:same.test|rc=0 b--other.test b--same.test
a bare filter keeps its meaning in every tree|=same.test|rc=0 a--same.test b--same.test
a tree no battery has selects nothing|=skills/c:same.test|rc=1
ROWS
run_pool unqualified =skills/a:same.test
if [ "$RC" -ne 0 ] && [ -z "$STARTED" ]; then ok "control: without the qualified form the filter selects nothing"
else bad "control: without the qualified form the filter selects nothing" "rc=$RC started=$STARTED"; fi

echo "=== orch's ALONE list holds in a pool of batteries ==="
alone_order() { # RUNNER
  RC=0
  OUT="$(cd "$W" && PATH="$TMP/pool-bin:$PATH" TMPDIR="$TMP" bash "$W/skills/orch/tests/$1.runner" \
    --battery skills/orch/tests --battery skills/a/tests 2>&1)" || RC=$?
  STARTED="$(sed -n 's/^start suite=//p' <<<"$OUT" | paste -sd ' ' -)"
}
alone_order run-all
if [ "rc=$RC $STARTED" = "rc=0 orch--pooled a--same.test orch--held" ]; then
  ok "an ALONE suite starts after every pooled suite of every battery"
else bad "an ALONE suite starts after every pooled suite of every battery" "rc=$RC started=$STARTED"; fi
alone_order alone-dropped
if [ "rc=$RC $STARTED" = "rc=0 orch--held orch--pooled a--same.test" ]; then
  ok "control: a --battery run that drops the list pools the ALONE suite"
else bad "control: a --battery run that drops the list pools the ALONE suite" "rc=$RC started=$STARTED"; fi

# --- the guard ----------------------------------------------------------------
# skills/alpha and skills/beta each hold same.test.sh. A change to both
# scripts selects alpha's same.test, alpha's direct.test.mjs and beta's
# other.test; beta's same.test reads neither script. alpha's same.test and
# beta's other.test each wait for the other to start, so they pass only when
# they run side by side.
BARRIER="$TMP/barrier"
mkdir -p "$BARRIER" "$TMP/guard-bin"
for tree in alpha beta; do
  mkdir -p "$R/skills/$tree/scripts" "$R/skills/$tree/tests" "$R/.agents/skills/$tree/scripts"
  printf '#!/usr/bin/env bash\necho %s\n' "$tree" > "$R/skills/$tree/scripts/$tree.sh"
  cp "$R/skills/$tree/scripts/$tree.sh" "$R/.agents/skills/$tree/scripts/$tree.sh"
done
barrier_suite() { # FILE SCRIPT MINE OTHER
  cat > "$1" <<SH
#!/usr/bin/env bash
: "scripts/$2"
: > "\$BARRIER/$3"
for ((i = 0; i < 100; i++)); do
  [ ! -e "\$BARRIER/$4" ] || { echo "pass: 1   fail: 0"; exit 0; }
  sleep 0.1
done
echo "pass: 0   fail: 1"
exit 1
SH
}
barrier_suite "$R/skills/alpha/tests/same.test.sh" alpha.sh alpha beta
barrier_suite "$R/skills/beta/tests/other.test.sh" beta.sh beta alpha
printf '#!/usr/bin/env bash\n: > "$BARRIER/beta-same"\necho "pass: 1   fail: 0"\n' > "$R/skills/beta/tests/same.test.sh"
printf '// scripts/alpha.sh\n' > "$R/skills/alpha/tests/direct.test.mjs"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$NODE_LOG"\n' > "$TMP/guard-bin/node"
chmod +x "$TMP/guard-bin/node"
git -C "$R" add -A
entry_points_executable
git -C "$R" commit -qm pool
BASE="$(git -C "$R" rev-parse HEAD)"
for tree in alpha beta; do
  for f in "skills/$tree/scripts/$tree.sh" ".agents/skills/$tree/scripts/$tree.sh"; do
    printf 'echo changed\n' >> "$R/$f"
  done
done
export BARRIER NODE_LOG="$TMP/node.log"

pool_guard() { # GUARD NPROC — the run in OUT and RC, the barrier and node log reset
  rm -f -- "$BARRIER"/* "$NODE_LOG"
  printf '#!/usr/bin/env bash\necho %s\n' "$2" > "$TMP/guard-bin/nproc"
  chmod +x "$TMP/guard-bin/nproc"
  RC=0
  OUT="$(cd "$R" && PATH="$TMP/guard-bin:$PATH" "$1" --range "$BASE" 2>&1 </dev/null)" || RC=$?
}
pool_calls() { grep -c '^=== skills/orch/tests/run-all.sh ' <<<"$OUT" || true; }

echo "=== the guard runs the selected union in one pool call ==="
pool_guard "$GUARD" 4
calls=$(pool_calls)
if [ "$RC" -eq 0 ] && [ "$calls" -eq 1 ] && grep -qx 'suite=alpha--same.test seconds=[0-9]* pass=1 fail=0' <<<"$OUT" &&
  grep -qx 'suite=beta--other.test seconds=[0-9]* pass=1 fail=0' <<<"$OUT"; then
  ok "one runner call runs both trees' selected suites side by side"
else bad "one runner call runs both trees' selected suites side by side" "rc=$RC calls=$calls out=$OUT"; fi
if [ ! -e "$BARRIER/beta-same" ] && ! grep -q '^start suite=beta--same.test$' <<<"$OUT"; then
  ok "a base name another tree selected runs no suite in this tree"
else bad "a base name another tree selected runs no suite in this tree" "out=$OUT"; fi
if grep -qx '=== skills/alpha/tests/direct.test.mjs' <<<"$OUT" &&
  [ "$(cat "$NODE_LOG" 2>/dev/null)" = '--test skills/alpha/tests/direct.test.mjs' ]; then
  ok "a .test.mjs suite runs by itself on the direct route"
else bad "a .test.mjs suite runs by itself on the direct route" "node=$(cat "$NODE_LOG" 2>/dev/null) out=$OUT"; fi

pool_guard "$GUARD" 1
if [ "$RC" -ne 0 ] && grep -q '^guard: suite=skills/orch/tests/run-all.sh$' <<<"$OUT"; then
  ok "control: the barrier reds suites that do not run side by side"
else bad "control: the barrier reds suites that do not run side by side" "rc=$RC out=$OUT"; fi

if mutant_guard 's/pool_filters+=("=$d:${t%.sh}")/pool_filters+=("=${t%.sh}")/'; then
  pool_guard "$MUTANT_TOOLS/guard" 4
  if [ -e "$BARRIER/beta-same" ]; then ok "control: bare filters run the other tree's same-named suite"
  else bad "control: bare filters run the other tree's same-named suite" "out=$OUT"; fi
else bad "control: the bare-filter mutation changed the guard"; fi

printf 'pass: %s   fail: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
