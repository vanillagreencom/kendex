#!/usr/bin/env bash
# Tests for the merge group's narrowed row: a diff of skill Markdown alone
# runs only the suites that read it. tools/guard --doc-reach answers the
# readers, tools/ci-job-set publishes them as `suites=` with the shards that
# run them, and each shard step of skill-tests.yml passes its candidates
# against the list `tools/ci-job-set --suite-list` prints.
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

# The readers of PATHS in DIR, one line, or `exit=N` where the reach refused.
reach() { # DIR PATHS
  local status=0 got
  got="$(cd "$1" && printf '%s\n' $2 | "$GUARD" --doc-reach 2>"$TMP/reach-err")" || status=$?
  [ "$status" -eq 0 ] || { printf 'exit=%s' "$status"; return 0; }
  printf '%s' "$got" | tr '\n' ' ' | sed 's/ $//'
}

# THE WORLD: the selection fixture's crates and skills, plus a package whose
# guide each kind of reader reads or does not.
W="$TMP/prose-world"
cp -R "$SEL_WORLD" "$W"
mkdir -p "$W/skills/demo/references" "$W/skills/demo/tests" "$W/skills/copier/tests" "$W/skills/copier/scripts"
printf -- '---\nname: demo\n---\n' >"$W/skills/demo/SKILL.md"
printf '# Guide\n' >"$W/skills/demo/references/guide.md"
mkdir -p "$W/.agents/skills/demo/references"
cp "$W/skills/demo/references/guide.md" "$W/.agents/skills/demo/references/guide.md"
# A suite whose note declares SKILL.md alone, and whose code names no guide.
printf '#!/usr/bin/env bash\n# Inputs: skills/demo/SKILL.md\nhead -1 "$ROOT/SKILL.md"\n' \
  >"$W/skills/demo/tests/declared.test.sh"
# A suite with no note whose code names the guide.
printf '#!/usr/bin/env bash\ngrep -q Guide "$ROOT/references/guide.md"\n' >"$W/skills/demo/tests/named.test.sh"
# A tools suite naming the guide by its repository path.
printf '#!/usr/bin/env bash\ngrep -q Guide "$ROOT/skills/demo/references/guide.md"\n' >"$W/tools/tests/guide.test.sh"
# A suite copying the package that holds the guide, and one copying only its
# own scripts.
printf '#!/usr/bin/env bash\ncp -R "$ROOT/skills/demo" "$sandbox/demo"\n' >"$W/skills/copier/tests/copy.test.sh"
printf '#!/usr/bin/env bash\ncp -R "$ROOT/skills/copier/scripts" "$sandbox/s"\n' >"$W/skills/copier/tests/quiet.test.sh"
git -C "$W" add -A
GUIDE="skills/demo/references/guide.md .agents/skills/demo/references/guide.md"
GUIDE_READERS="skills/copier/tests/copy.test.sh skills/demo/tests/named.test.sh tools/tests/guide.test.sh"

# PATHS|EXPECTED readers. Each reader kind selects its suite; a suite whose
# note leaves the document out, and a copy of another package's directory,
# do not. A copy names the package it reaches, not the directory below it.
reach_rows=0
while IFS='|' read -r paths expected; do
  reach_rows=$((reach_rows + 1))
  check "reach: $paths" "$expected" "$(reach "$W" "$paths")"
done <<ROWS
$GUIDE|$GUIDE_READERS
skills/demo/SKILL.md|skills/copier/tests/copy.test.sh skills/demo/tests/declared.test.sh
skills/copier/README.md|skills/copier/tests/quiet.test.sh
skills/demo/scripts/x|exit=2
ROWS
[ "$reach_rows" -eq 4 ] || { echo "the reach table read $reach_rows rows" >&2; exit 1; }

# THE NARROWED ROW over the world: the readers as `suites=`, the shards that
# run their packages, the lanes of any measured prose row. A path that is
# not skill Markdown takes the row its paths select.
row() { # PATHS — the shards and suites words, or the refusal key
  local got
  got="$(SELECT_IN="$1" selection micro false "$(printf '%s\n' $2)")"
  case "$got" in exit=*) printf '%s' "$got" ;; *) printf '%s %s' "${got% shards=*}" "shards=$(field shards <<<"$got") suites=$(field suites <<<"$got")" ;; esac
}
suites_json() { printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(. != ""))'; }
check "row: the guide's readers and their shards" \
  "$(lanes linux false false false true) shards=[\"guards-tools\",\"guards-tools-tail\",\"rest\"] suites=$(suites_json $GUIDE_READERS)" \
  "$(row "$W" "$GUIDE")"
check "row: a path outside skill Markdown takes the measured row" "suites=all" \
  "$(row "$W" "skills/demo/references/guide.md skills/demo/scripts/x" | sed 's/.* //')"
check "row: render is unchanged by a narrowed selection" "suites=all" \
  "$(SELECT_IN="$W" selection render false skills/demo/references/guide.md | sed 's/.* //')"

# A diff of more documents than the reach's bound, renders counted with
# their sources, takes the row its paths select.
many="$(for n in $(seq 1 21); do printf 'skills/demo/references/d%s.md .agents/skills/demo/references/d%s.md ' "$n" "$n"; done)"
check "row: past the document bound the paths' row runs" "suites=all" "$(row "$W" "$many" | sed 's/.* //')"
few="$(for n in $(seq 1 20); do printf 'skills/demo/references/d%s.md .agents/skills/demo/references/d%s.md ' "$n" "$n"; done)"
check "row: at the bound the reach answers" 'suites=["skills/copier/tests/copy.test.sh"]' "$(row "$W" "$few" | sed 's/.* //')"

# A reach a file of which cannot be read keeps every reader running: the row
# the paths select.
cp -R "$W" "$TMP/unread-world"
chmod 000 "$TMP/unread-world/skills/copier/tests/quiet.test.sh"
check "an unreadable reader leaves the reach unread" "exit=2" "$(reach "$TMP/unread-world" "$GUIDE")"
check "and the row it would narrow runs every suite" "suites=all" \
  "$(row "$TMP/unread-world" "$GUIDE" | sed 's/.* //')"
chmod 644 "$TMP/unread-world/skills/copier/tests/quiet.test.sh"

# A suite whose own code names the document outside its note fails the
# check, and the selection is refused. A fixture's bare relative path is no
# read of the checkout and passes.
cp -R "$W" "$TMP/liar-world"
printf '#!/usr/bin/env bash\n# Inputs: skills/demo/SKILL.md\ncat "$ROOT/skills/demo/references/guide.md"\n' \
  >"$TMP/liar-world/skills/demo/tests/declared.test.sh"
check "a note leaving out a document its suite names fails the reach" "exit=1" "$(reach "$TMP/liar-world" "$GUIDE")"
check "and the selection is refused" "exit=2 inputs-undeclared" "$(row "$TMP/liar-world" "$GUIDE")"
printf '#!/usr/bin/env bash\n# Inputs: skills/demo/SKILL.md\nwrite "$repo" skills/demo/references/guide.md\n' \
  >"$TMP/liar-world/skills/demo/tests/declared.test.sh"
check "a fixture path the suite writes is no read" "$GUIDE_READERS" "$(reach "$TMP/liar-world" "$GUIDE")"

# THE LIST: whole paths, each with a space on either side, which a step
# compares a candidate with; `all` for an empty selection or `all`.
list_of() { # SELECTION — the line, quoted, or `exit=N CAUSE`
  local status=0 got
  got="$(SUITE_SELECTION="$1" "$JOB_SET" --suite-list 2>"$TMP/list-err")" || status=$?
  [ "$status" -eq 0 ] || { printf 'exit=%s %s' "$status" "$(sed -n 's/^ci-job-set: cause=//p' "$TMP/list-err")"; return 0; }
  printf "'%s'" "$got"
}
while IFS='|' read -r selection expected; do
  check "list: '$selection'" "$expected" "$(list_of "$selection")"
done <<'ROWS'
["skills/b/tests/x.test.sh"]|' skills/b/tests/x.test.sh '
["skills/a/tests/x.test.sh","skills/c/tests/y.test.sh"]|' skills/a/tests/x.test.sh skills/c/tests/y.test.sh '
[]|' '
all|'all'
|'all'
["a b"]|exit=2 suite-selection-unreadable
skills/a/tests/x.test.sh|exit=2 suite-selection-unreadable
ROWS

# THE STEP: a shard step whose candidates the list leaves out runs no
# battery and passes, a same-named suite of another tree among them; one it
# keeps runs that suite alone. The step is the workflow's own text, run
# against a stub battery runner.
step_run() { # STEP-NAME SELECTION — the runner's arguments, or `none`, and the exit
  local dir="$TMP/step" status=0
  rm -rf -- "${dir:?}"
  mkdir -p "$dir/tools" "$dir/skills/review-gate/tests" "$dir/skills/orch/tests"
  cp "$JOB_SET" "$dir/tools/ci-job-set"
  : >"$dir/skills/review-gate/tests/a.test.sh"
  : >"$dir/skills/review-gate/tests/b.test.sh"
  printf '#!/usr/bin/env bash\nprintf "%%s " "$@" >"$CALLS"\n' >"$dir/skills/orch/tests/run-all.sh"
  awk -v name="$1" '
    $0 ~ "^      - name: " name "$" { found = 1; next }
    found && /^        run: \|$/ { body = 1; next }
    body && /^          / { print substr($0, 11); next }
    body { exit }
  ' "$ROOT/.github/workflows/skill-tests.yml" >"$dir/step.sh"
  [ -s "$dir/step.sh" ] || { printf 'no-step'; return 0; }
  (cd "$dir" && CALLS="$dir/calls" SHARD_SUITES="$2" bash -eu step.sh >/dev/null 2>&1) || status=$?
  printf '%s exit=%s' "$( [ -f "$dir/calls" ] && sed 's/ $//' "$dir/calls" || echo none)" "$status"
}
while IFS='|' read -r selection expected; do
  check "review-gate step: '$selection'" "$expected" "$(step_run 'review-gate suites' "$selection")"
done <<'ROWS'
["tools/tests/guide.test.sh"]|none exit=0
["skills/other/tests/b.test.sh"]|none exit=0
["skills/review-gate/tests/b.test.sh"]|--battery skills/review-gate/tests =b.test exit=0
all|--battery skills/review-gate/tests =a.test =b.test exit=0
ROWS

# THE REAL TREE, for the change that set this row up: KEN-4773's one line in
# Jarvis's decisions reference runs none of the Jarvis suites, whose notes
# leave that reference out, while SKILL.md, which command-declarations
# declares, runs that suite and the Jarvis shard.
real="$(selection micro false "$(printf '%s\n' skills/jarvis/references/decisions.md .agents/skills/jarvis/references/decisions.md)")"
check "real: the decisions reference selects no Jarvis suite" "" \
  "$(field suites <<<"$real" | jq -r '.[] | select(startswith("skills/jarvis/"))')"
check "real: and no Jarvis shard" "" "$(shards_miss -jarvis "$(field shards <<<"$real")")"
real="$(selection micro false skills/jarvis/SKILL.md)"
check "real: SKILL.md selects command-declarations" "true" \
  "$(field suites <<<"$real" | jq 'index("skills/jarvis/tests/command-declarations.test.sh") != null')"
check "real: and the Jarvis shard that runs it" "" "$(shards_miss +jarvis "$(field shards <<<"$real")")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
