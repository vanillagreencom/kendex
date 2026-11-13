#!/usr/bin/env bash
# Tests for the suites a shard step runs: tools/ci-job-set publishes, as
# `skipped_suites=`, every shell suite outside the reach tools/guard
# --suite-reach derives for the changed paths, and each shell suite step of
# skill-tests.yml runs the candidates `tools/ci-job-set --suite-list` keeps.
# Inputs: tools/guard, tools/ci-job-set, tools/lib/*, tools/rust-reads,
# tools/macos-test-contracts, tools/macos-test-contracts.json,
# .github/workflows/skill-tests.yml
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ci-job-set-world.sh
. "$TEST_DIR/lib/ci-job-set-world.sh"
# shellcheck source=lib/ci-job-set-case.sh
. "$TEST_DIR/lib/ci-job-set-case.sh"
# A copy of ci-job-set with no guard beside it, whose reach cannot be read:
# every shard runs whole.
cp "$JOB_SET" "$TMP/rule/tools/ci-job-set"
WHOLE="$TMP/rule/tools/ci-job-set"

# THE WORLD: the selection fixture's crates and skills, plus a package whose
# guide some suites' notes cover, one suite's code reads, and the rest leave
# out.
W="$TMP/prose-world"
cp -R "$SEL_WORLD" "$W"
mkdir -p "$W/skills/demo/references" "$W/skills/demo/tests" "$W/.agents/skills/demo/references"
printf -- '---\nname: demo\n---\n' >"$W/skills/demo/SKILL.md"
printf '# Guide\n' | tee "$W/skills/demo/references/guide.md" >"$W/.agents/skills/demo/references/guide.md"
note_suite() { # PATH NOTE-LINES — a suite whose header holds NOTE-LINES and whose code reads nothing
  printf '#!/usr/bin/env bash\n%s\ntrue\n' "$2" >"$W/$1"
}
note_suite skills/demo/tests/declared.test.sh '# Inputs: skills/demo/SKILL.md'
note_suite skills/demo/tests/slashed.test.sh '# Inputs: skills/demo/references/'
note_suite skills/demo/tests/folder.test.sh '# Inputs: skills/demo/references'
note_suite skills/demo/tests/plain.test.sh '# no note'
printf '#!/usr/bin/env bash\ncat "$SKILL_DIR/references/guide.md"\n' >"$W/skills/demo/tests/reader.test.sh"
git -C "$W" add -A
GUIDE="skills/demo/references/guide.md .agents/skills/demo/references/guide.md"

# THE ROW: every suite outside the guide's reach is skipped; the reach holds
# each suite whose note covers the guide, a directory item included, and the
# suite whose code reads it. A copy that cannot read the reach skips none.
row() { # DIR PATHS [JOB-SET] — the selection with its skips cut, and the skips
  local got
  got="$(SELECT_IN="$1" SELECT_WITH="${3:-$JOB_SET}" selection micro false "$(printf '%s\n' $2)")"
  printf '%s|%s' "${got% skipped_suites=*}" "$(field skipped_suites <<<"$got")"
}
skipped="$(row "$W" "$GUIDE" | sed 's/.*|//')"
for suite in declared plain; do
  check "row: the guide skips the $suite suite" true \
    "$(jq --arg t "skills/demo/tests/$suite.test.sh" 'index($t) != null' <<<"$skipped")"
done
for suite in slashed folder reader; do
  check "row: the guide runs the $suite suite" false \
    "$(jq --arg t "skills/demo/tests/$suite.test.sh" 'index($t) != null' <<<"$skipped")"
done
whole="$(row "$W" "$GUIDE" "$WHOLE")"
check "row: the copy that cannot read the reach skips nothing" "[]" "${whole#*|}"
check "row: and runs every shard" "$ROSTER" "$(sed 's/.* shards=\([^ ]*\).*/\1/' <<<"${whole%|*}")"
check "row: render skips none" "[]" \
  "$(SELECT_IN="$W" selection render false skills/demo/references/guide.md | field skipped_suites)"

# THE LIST: the candidates a step runs, by whole path, in argument order:
# each one the skips do not name. Leaving one out records
# SUITE_LIST_DROPPED=true in the SUITE_LIST_DROPS file, which arms the leg's
# narrowed step; keeping every one records nothing.
CANDIDATES="skills/a/tests/x.test.sh skills/b/tests/x.test.sh skills/c/tests/y.test.sh"
list_of() { # SKIPPED — the kept candidates on one line and what was recorded, or `exit=N CAUSE`
  local status=0 got
  : >"$TMP/list-drops"
  # shellcheck disable=SC2086 # one candidate per word
  got="$(SKIPPED_SUITES="$1" SUITE_LIST_DROPS="$TMP/list-drops" "$JOB_SET" --suite-list $CANDIDATES 2>"$TMP/list-err")" || status=$?
  [ "$status" -eq 0 ] || { printf 'exit=%s %s' "$status" "$(sed -n 's/^ci-job-set: cause=//p' "$TMP/list-err")"; return 0; }
  printf "'%s' recorded='%s'" "$(printf '%s' "$got" | tr '\n' ' ')" "$(tr '\n' ' ' <"$TMP/list-drops")"
}
while IFS='|' read -r skipped expected; do
  check "list: '$skipped'" "$expected" "$(list_of "$skipped")"
done <<'ROWS'
["skills/b/tests/x.test.sh"]|'skills/a/tests/x.test.sh skills/c/tests/y.test.sh' recorded='SUITE_LIST_DROPPED=true '
["skills/c/tests/y.test.sh","skills/a/tests/x.test.sh"]|'skills/b/tests/x.test.sh' recorded='SUITE_LIST_DROPPED=true '
["skills/a/tests/x.test.sh","skills/b/tests/x.test.sh","skills/c/tests/y.test.sh"]|'' recorded='SUITE_LIST_DROPPED=true '
["skills/d/tests/x.test.sh"]|'skills/a/tests/x.test.sh skills/b/tests/x.test.sh skills/c/tests/y.test.sh' recorded=''
[]|'skills/a/tests/x.test.sh skills/b/tests/x.test.sh skills/c/tests/y.test.sh' recorded=''
|'skills/a/tests/x.test.sh skills/b/tests/x.test.sh skills/c/tests/y.test.sh' recorded=''
["a b"]|exit=2 suite-skips-unreadable
all|exit=2 suite-skips-unreadable
ROWS
check "list: a record that cannot be written fails the call" "exit=2 suite-list-unrecorded" \
  "$(status=0; SKIPPED_SUITES='["skills/a/tests/x.test.sh"]' SUITE_LIST_DROPS="$TMP/no-such-dir/env" "$JOB_SET" --suite-list skills/a/tests/x.test.sh 2>"$TMP/list-err" || status=$?; printf 'exit=%s %s' "$status" "$(sed -n 's/^ci-job-set: cause=//p' "$TMP/list-err")")"

# THE STEPS: each shell suite step is the workflow's own text, run against
# stub runners in an empty tree. A step whose every candidate is skipped
# runs no battery and passes; one that keeps a suite runs it, and a
# same-named suite of another tree is no stand-in for a skipped one.
WF="$ROOT/.github/workflows/skill-tests.yml"
step_dir() { # STEP-NAME — the stub tree, its step.sh, or `no-step`
  local dir="$TMP/step"
  rm -rf -- "${TMP:?}/step"
  mkdir -p "$dir/tools/tests" "$dir/skills/review-gate/tests" "$dir/skills/pooled/tests" "$dir/skills/orch/tests" "$dir/.github/workflows"
  cp "$JOB_SET" "$dir/tools/ci-job-set"
  cp "$WF" "$dir/.github/workflows/skill-tests.yml"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/tools/rust-reads"
  chmod +x "$dir/tools/rust-reads"
  : >"$dir/skills/review-gate/tests/a.test.sh"
  : >"$dir/skills/review-gate/tests/b.test.sh"
  # A package no shard claims, which the pooled step takes as a candidate.
  : >"$dir/skills/pooled/tests/c.test.sh"
  # An orch suite, which each orch shard step takes as a candidate.
  : >"$dir/skills/orch/tests/d.sh"
  printf '#!/usr/bin/env bash\nprintf "%%s " "$@" >>"$CALLS"\n' | tee "$dir/skills/orch/tests/run-all.sh" >"$dir/tools/tests/run-all.sh"
  awk -v name="$1" '
    $0 == "      - name: " name { found = 1; next }
    found && /^        run: \|$/ { body = 1; next }
    body && /^          / { print substr($0, 11); next }
    body && /^$/ { print; next }
    body { exit }
  ' "$WF" >"$dir/step.sh"
}
step_run() { # STEP-NAME SKIPPED — the runners' arguments, or `none`, the exit and whether the narrowed step is armed
  local dir="$TMP/step" status=0
  step_dir "$1"
  [ -s "$dir/step.sh" ] || { printf 'no-step'; return 0; }
  : >"$dir/env"
  (cd "$dir" && CALLS="$dir/calls" SKIPPED_SUITES="$2" GITHUB_ENV="$dir/env" bash -e -o pipefail step.sh >/dev/null 2>&1) || status=$?
  printf '%s exit=%s narrowed=%s' "$( [ -f "$dir/calls" ] && sed 's/ $//' "$dir/calls" || echo none)" "$status" \
    "$(grep -qx 'SUITE_LIST_DROPPED=true' "$dir/env" && echo yes || echo no)"
}
while IFS='|' read -r skipped expected; do
  check "review-gate step: '$skipped'" "$expected" "$(step_run 'review-gate suites' "$skipped")"
done <<'ROWS'
[]|--battery skills/review-gate/tests =a.test =b.test exit=0 narrowed=no
["skills/other/tests/b.test.sh"]|--battery skills/review-gate/tests =a.test =b.test exit=0 narrowed=no
["skills/review-gate/tests/b.test.sh"]|--battery skills/review-gate/tests =a.test exit=0 narrowed=yes
["skills/review-gate/tests/a.test.sh","skills/review-gate/tests/b.test.sh"]|none exit=0 narrowed=yes
ROWS
# Every shard step that runs a suite, read from the workflow, runs none
# where the skips name each of its candidates, and arms the narrowed step.
# The candidates are what the step hands --suite-list in the stub tree.
steps="$(awk '
  /^      - name: / { name = substr($0, 15); shard = 0; next }
  /^        if: matrix\.shard == / { shard = 1; next }
  shard && !/^ *#/ && /(^|[ !])bash (skills\/orch\/tests\/run-all\.sh|tools\/tests\/run-all\.sh|"\$t")/ && !seen[name]++ { print name }
' "$WF")"
for required in 'review-gate suites' 'tools suites' 'the two slowest tools suites' 'linear must-fail controls' 'Jarvis suites' 'all other skill suites'; do
  grep -qxF "$required" <<<"$steps" || bad "step discovery found no '$required'"
done
while IFS= read -r step; do
  step_dir "$step"
  printf '#!/usr/bin/env bash\nshift\nprintf "%%s\\n" "$@" | tee -a "$CANDIDATES_OUT"\n' >"$TMP/step/tools/ci-job-set"
  : >"$TMP/candidates"
  (cd "$TMP/step" && CALLS=/dev/null CANDIDATES_OUT="$TMP/candidates" GITHUB_ENV=/dev/null bash -e -o pipefail step.sh >/dev/null 2>&1) || true
  every="$(grep . "$TMP/candidates" | jq -Rsc 'split("\n") | map(select(. != ""))')"
  check "step: '$step' runs no suite where every candidate is skipped" "none exit=0 narrowed=yes" \
    "$(step_run "$step" "$every")"
done <<<"$steps"

# THE REAL TREE: a Jarvis reference read by none of the long Jarvis suites
# skips them, inside the shards its readers select.
real() { # PATHS — the skips
  selection micro false "$(printf '%s\n' $1)" | field skipped_suites
}
DECISIONS="skills/jarvis/references/decisions.md .agents/skills/jarvis/references/decisions.md"
narrow="$(real "$DECISIONS")"
for long in controls succession session task; do
  check "real: the decisions reference skips the long $long suite" true \
    "$(jq --arg t "skills/jarvis/tests/$long.test.sh" 'index($t) != null' <<<"$narrow")"
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
