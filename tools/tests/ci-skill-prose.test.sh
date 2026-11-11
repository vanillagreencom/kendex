#!/usr/bin/env bash
# Tests for the merge group's narrowed row: a diff of skill Markdown alone
# keeps the row its paths select, save an orch leg left with no suite, and
# skips, inside its shards, each suite
# whose own `# Inputs:` note covers no changed document. tools/guard
# --note-skips names those suites, tools/ci-job-set publishes them as
# `skipped_suites=`, and each shell suite step of skill-tests.yml runs the
# candidates `tools/ci-job-set --suite-list` keeps.
# Inputs: tools/guard, tools/ci-job-set, tools/lib/*, tools/rust-reads,
# tools/macos-test-contracts, tools/macos-test-contracts.json,
# .github/workflows/skill-tests.yml, skills/jarvis/SKILL.md,
# skills/jarvis/references/decisions.md, skills/jarvis/tests/
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ci-job-set-world.sh
. "$TEST_DIR/lib/ci-job-set-world.sh"
# shellcheck source=lib/ci-job-set-case.sh
. "$TEST_DIR/lib/ci-job-set-case.sh"
GUARD="$ROOT/tools/guard"
# A copy of ci-job-set with no guard beside it, whose --note-skips query
# fails: the row the paths select with no suite skipped.
cp "$JOB_SET" "$TMP/rule/tools/ci-job-set"
WHOLE="$TMP/rule/tools/ci-job-set"

# The suites --note-skips names for PATHS in DIR, on one line, or `exit=N`.
skips() { # DIR PATHS
  local status=0 got
  got="$(cd "$1" && printf '%s\n' $2 | "$GUARD" --note-skips 2>"$TMP/skips-err")" || status=$?
  [ "$status" -eq 0 ] || { printf 'exit=%s' "$status"; return 0; }
  printf '%s' "$got" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'
}

# THE WORLD: the selection fixture's crates and skills, plus a package whose
# guide each kind of note covers or does not.
W="$TMP/prose-world"
cp -R "$SEL_WORLD" "$W"
mkdir -p "$W/skills/demo/references" "$W/skills/demo/tests" "$W/.agents/skills/demo/references"
printf -- '---\nname: demo\n---\n' >"$W/skills/demo/SKILL.md"
printf '# Guide\n' | tee "$W/skills/demo/references/guide.md" >"$W/.agents/skills/demo/references/guide.md"
note_suite() { # PATH NOTE-LINES — a suite whose header holds NOTE-LINES and whose code reads nothing
  printf '#!/usr/bin/env bash\n%s\ntrue\n' "$2" >"$W/$1"
}
note_suite skills/demo/tests/declared.test.sh '# Inputs: skills/demo/SKILL.md'
note_suite skills/demo/tests/continued.test.sh $'# Inputs: skills/demo/SKILL.md,\n# skills/demo/references/guide.md.'
note_suite skills/demo/tests/slashed.test.sh '# Inputs: skills/demo/references/'
note_suite skills/demo/tests/folder.test.sh '# Inputs: skills/demo/references'
note_suite skills/demo/tests/globbed.test.sh '# Inputs: skills/demo/*'
note_suite skills/demo/tests/prose.test.sh '# Inputs: the demo scripts and this suite.'
note_suite skills/demo/tests/relative.test.sh '# Inputs: references/guide.md'
note_suite skills/demo/tests/braced.test.sh '# Inputs: skills/demo/{SKILL,README}.md'
note_suite skills/demo/tests/plain.test.sh '# no note'
note_suite tools/tests/tool.test.sh '# Inputs: tools/tests/'
git -C "$W" add -A
GUIDE="skills/demo/references/guide.md .agents/skills/demo/references/guide.md"

# PATHS|EXPECTED skips. A suite runs where its note covers a path, as a case
# pattern, a directory or a continuation line, and where it has no note it
# can take: none, prose, a path relative to its tree or a brace list.
skip_rows=0
while IFS='|' read -r paths expected; do
  skip_rows=$((skip_rows + 1))
  check "skips: $paths" "$expected" "$(skips "$W" "$paths")"
done <<ROWS
$GUIDE|skills/demo/tests/declared.test.sh tools/tests/tool.test.sh
.agents/skills/demo/references/guide.md|skills/demo/tests/declared.test.sh tools/tests/tool.test.sh
skills/demo/SKILL.md|skills/demo/tests/folder.test.sh skills/demo/tests/slashed.test.sh tools/tests/tool.test.sh
skills/demo/SKILL.md $GUIDE|tools/tests/tool.test.sh
skills/demo/scripts/x|exit=2
ROWS
[ "$skip_rows" -eq 5 ] || { echo "the skips table read $skip_rows rows" >&2; exit 1; }

# A suite whose own code names a document its note leaves out fails the
# check, as a checkout path, from a sibling package or below its own root.
# A path a fixture writes, bare or under .agents/, is no read and passes.
# SOURCE|EXPECTED
while IFS='|' read -r source expected; do
  printf '#!/usr/bin/env bash\n# Inputs: skills/demo/SKILL.md\n%s\n' "$source" >"$W/skills/demo/tests/declared.test.sh"
  check "consistency: $source" "$expected" "$(skips "$W" "$GUIDE" | sed 's/ .*//')"
done <<'ROWS'
cat "$ROOT/skills/demo/references/guide.md"|exit=1
cat "$TEST_DIR/../../demo/references/guide.md"|exit=1
cat "$SKILL_DIR/references/guide.md"|exit=1
write "$repo" skills/demo/references/guide.md|skills/demo/tests/declared.test.sh
cp guide "$sandbox/.agents/skills/demo/references/guide.md"|skills/demo/tests/declared.test.sh
ROWS
LIAR="$TMP/liar-world"
cp -R "$W" "$LIAR"
printf '#!/usr/bin/env bash\n# Inputs: skills/demo/SKILL.md\ncat "$ROOT/skills/demo/references/guide.md"\n' >"$LIAR/skills/demo/tests/declared.test.sh"
skips "$LIAR" "$GUIDE" >/dev/null
check "consistency: the refusal names the suite and the document" \
  "guard: inputs-undeclared=skills/demo/tests/declared.test.sh path=skills/demo/references/guide.md" \
  "$(grep '^guard: ' "$TMP/skips-err")"
note_suite skills/demo/tests/declared.test.sh '# Inputs: skills/demo/SKILL.md'

# THE NARROWED ROW: every word of the row the paths select, the shards among
# them, with the skips added; the row skips none where the paths are not all
# skill Markdown, where the class is not measured, or where --note-skips
# refuses.
row() { # DIR PATHS [JOB-SET] — the selection with its skips cut, and the skips
  local got
  got="$(SELECT_IN="$1" SELECT_WITH="${3:-$JOB_SET}" selection micro false "$(printf '%s\n' $2)")"
  printf '%s|%s' "${got% skipped_suites=*}" "$(field skipped_suites <<<"$got")"
}
whole="$(row "$W" "$GUIDE" "$WHOLE")"
check "row: the copy without a guard skips nothing" "[]" "${whole#*|}"
check "row: the guide keeps the row its paths select" "${whole%|*}" "$(row "$W" "$GUIDE" | sed 's/|.*//')"
check "row: and skips the suites whose notes leave it out" \
  '["skills/demo/tests/declared.test.sh","tools/tests/tool.test.sh"]' "$(row "$W" "$GUIDE" | sed 's/.*|//')"
check "row: a path outside skill Markdown skips none" "[]" \
  "$(row "$W" "skills/demo/references/guide.md skills/demo/scripts/x" | sed 's/.*|//')"
check "row: render skips none" "[]" \
  "$(SELECT_IN="$W" selection render false skills/demo/references/guide.md | field skipped_suites)"
check "row: a refused note skips none" "[]" "$(row "$LIAR" "$GUIDE" | sed 's/.*|//')"
UNREAD="$TMP/unread-world"
cp -R "$W" "$UNREAD"
chmod 000 "$UNREAD/skills/demo/tests/prose.test.sh"
if [ -r "$UNREAD/skills/demo/tests/prose.test.sh" ]; then
  ok "unread: skipped, a file mode 000 stays readable to this user"
else
  check "unread: a suite that cannot be read fails the query" "exit=2" "$(skips "$UNREAD" "$GUIDE")"
  check "unread: and the row skips none" "[]" "$(row "$UNREAD" "$GUIDE" | sed 's/.*|//')"
fi
chmod 644 "$UNREAD/skills/demo/tests/prose.test.sh"

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

# THE REAL TREE. KEN-4773's one line in Jarvis's decisions reference keeps
# the row its paths select, save the four orch legs, every suite of which it
# skips, and skips the long Jarvis suites, whose notes leave that reference
# out; SKILL.md, which command-declarations declares, keeps that suite.
real() { # PATHS — the selection with its skips cut, and the skips
  local got
  got="$(SELECT_WITH="${2:-$JOB_SET}" selection micro false "$(printf '%s\n' $1)")"
  printf '%s|%s' "${got% skipped_suites=*}" "$(field skipped_suites <<<"$got")"
}
DECISIONS="skills/jarvis/references/decisions.md .agents/skills/jarvis/references/decisions.md"
narrow="$(real "$DECISIONS")"
check "real: the decisions reference keeps the row its paths select, save the orch legs" \
  "$(real "$DECISIONS" "$WHOLE" | sed 's/|.*//; s/"orch-[a-z]*",//g')" "${narrow%|*}"
check "real: and that row runs the Jarvis shard" "" "$(shards_miss +jarvis "$(field shards <<<"${narrow%|*}")")"
for long in controls succession session task; do
  check "real: and skips the long $long suite" true \
    "$(jq --arg t "skills/jarvis/tests/$long.test.sh" 'index($t) != null' <<<"${narrow#*|}")"
done
check "real: SKILL.md runs command-declarations" false \
  "$(real skills/jarvis/SKILL.md | sed 's/.*|//' | jq 'index("skills/jarvis/tests/command-declarations.test.sh") != null')"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
