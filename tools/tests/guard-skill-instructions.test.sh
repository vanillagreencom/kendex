#!/usr/bin/env bash
set -euo pipefail; unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/guard-world.sh
. "$TEST_DIR/lib/guard-world.sh"
seed_skill() { # NAME [SUFFIX]
  local name=$1 suffix=${2:-}
  mkdir -p "$R/skills/$name" "$R/.agents/skills/$name"
  printf '%s\n' '---' "name: $name" '---' '# Skill' >"$R/skills/$name/SKILL.md"
  cp "$R/skills/$name/SKILL.md" "$R/.agents/skills/$name/SKILL.md$suffix"
  git -C "$R" add "skills/$name/SKILL.md" ".agents/skills/$name/SKILL.md$suffix"
}
configure() { # HEADER KEY
  printf '%s\n' 'schema = 6' 'is_source_catalog = true' >"$R/kendex.toml"
  printf '%s\n' "$1" "$2 = \"Rule.\"" >"$R/kendex-local.toml"
  git -C "$R" add kendex.toml kendex-local.toml
}
render_block() { # NAME SUFFIX MODE
  local path="$R/.agents/skills/$1/SKILL.md$2"
  case "$3" in
    project) printf '%s\n' '<!-- kendex:project-instructions:start -->' '<!-- kendex:project-instructions:end -->' ;;
    complete) printf '%s\n' '<!-- kendex:project-instructions:start -->' '<!-- kendex:shared-instructions:start -->' '<!-- kendex:shared-instructions:end -->' '<!-- kendex:project-instructions:end -->' ;;
    no-project-end) printf '%s\n' '<!-- kendex:project-instructions:start -->' '<!-- kendex:shared-instructions:start -->' '<!-- kendex:shared-instructions:end -->' ;;
    no-shared-end) printf '%s\n' '<!-- kendex:project-instructions:start -->' '<!-- kendex:shared-instructions:start -->' '<!-- kendex:project-instructions:end -->' ;;
  esac >"$path"
}
expect_red() { # LABEL [PATH]
  run_guard
  [ "$RC" -ne 0 ] && [[ "$OUT" == *"guard: missing-skill-instructions=1"* ]] && [[ "$OUT" == *"${2:-.agents/skills/}"* ]] \
    && ok "$1" || bad "$1" "rc=$RC out=$OUT"
}
expect_green() { run_guard; [ "$RC" -eq 0 ] && ok "$1" || bad "$1" "rc=$RC out=$OUT"; }
echo "=== configured instructions require their render blocks ==="; while IFS='|' read -r key skill block; do
  reset_world; seed_skill "$skill"; configure '[skill-instructions]' "$key"
  [ "$block" != shared ] || render_block "$skill" "" project
  expect_red "$key instructions require the $block render block" ".agents/skills/$skill/SKILL.md"
  if [ "$key" = all ] && mutant_guard '/^shared_skill_instruction_is_configured() {/,/^}/c\
shared_skill_instruction_is_configured() { return 1; }'; then
    run_mutant; [ "$RC" -eq 0 ] && ok "control: without shared-marker enforcement the isolated missing marker passes" \
      || bad "control: without shared-marker enforcement the isolated missing marker passes" "rc=$RC out=$OUT"
  elif [ "$key" = all ]; then bad "control: shared-marker enforcement could not be disabled"
  fi
  render_block "$skill" "" complete; expect_green "$key instructions pass with the $block render block"
done <<'ROWS'
all|shared-all|shared
named|named|project
"*"|shared-star|shared
ROWS
echo "=== the effective TOML parser and managed render spellings ==="; while IFS='|' read -r header label; do
  reset_world; seed_skill alternate; configure "$header" alternate
  expect_red "$label table header configures the skill"
done <<'HEADERS'
["skill-instructions"]|a quoted
[skill-instructions] # team rules|a commented
HEADERS
reset_world; seed_skill disabled .disabled; git -C "$R" commit -q -m disabled; configure '[skill-instructions]' disabled
expect_red "a disabled render still requires its configured block" '.agents/skills/disabled/SKILL.md.disabled'
render_block disabled .disabled complete; expect_green "a disabled render passes with its complete block"
echo "=== instruction blocks require both markers ==="; while IFS='|' read -r key mode label; do
  reset_world; seed_skill half; configure '[skill-instructions]' "$key"; render_block half "" "$mode"
  expect_red "$label closing marker is required"
done <<'MARKERS'
half|no-project-end|the project
all|no-shared-end|the shared
MARKERS
printf '%s\n' '#!/bin/sh' 'exit 9' >"$MUTANT_TOOLS/sort"; chmod +x "$MUTANT_TOOLS/sort"
run_guard PATH="$MUTANT_TOOLS:$PATH"
[ "$RC" -ne 0 ] && [[ "$OUT" == *"guard: render-tracked-set=unreadable"* ]] \
  && ok "a failed render path normalization blocks the guard" || bad "a failed render path normalization blocks the guard" "rc=$RC out=$OUT"
printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]
