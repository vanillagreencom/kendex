#!/usr/bin/env bash
# tools/guard's configured skill instructions rule: each managed skill render
# carries the outer project block, and shared instructions carry their inner
# block. The controls isolate shared-marker enforcement and a failed render
# path normalization.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/guard-world.sh
. "$TEST_DIR/lib/guard-world.sh"

seed_skill() { # NAME
  local name=$1
  mkdir -p "$R/skills/$name" "$R/.agents/skills/$name"
  printf '%s\n' '---' "name: $name" '---' '# Skill' >"$R/skills/$name/SKILL.md"
  cp "$R/skills/$name/SKILL.md" "$R/.agents/skills/$name/SKILL.md"
  git -C "$R" add "skills/$name/SKILL.md" ".agents/skills/$name/SKILL.md"
}

echo "=== configured instructions require their render blocks ==="
# KEY | SKILL | BLOCK: shared keys require both markers; a named key requires
# the outer marker. Quoted `*` is the second shared spelling the renderer owns.
while IFS='|' read -r key skill block; do
  reset_world
  seed_skill "$skill"
  [ "$block" != shared ] ||
    printf '%s\n' '---' "name: $skill" '---' '<!-- kendex:project-instructions:start -->' '<!-- kendex:project-instructions:end -->' '# Skill' >"$R/.agents/skills/$skill/SKILL.md"
  printf '%s\n' '[skill-instructions]' "$key = \"Rule.\"" >"$R/kendex-local.toml"
  git -C "$R" add kendex-local.toml
  run_guard
  [ "$RC" -ne 0 ] && [[ "$OUT" == *"guard: missing-skill-instructions=1"* ]] \
    && [[ "$OUT" == *".agents/skills/$skill/SKILL.md"* ]] \
    && ok "$key instructions require the $block render block" \
    || bad "$key instructions require the $block render block" "rc=$RC out=$OUT"

  if [ "$key" = all ] && mutant_guard "s@^    grep -Fxq '<!-- kendex:shared-instructions:start -->'.*@    :@"; then
    run_mutant
    [ "$RC" -eq 0 ] \
      && ok "control: without shared-marker enforcement the isolated missing marker passes" \
      || bad "control: without shared-marker enforcement the isolated missing marker passes" "rc=$RC out=$OUT"
  elif [ "$key" = all ]; then
    bad "control: shared-marker enforcement could not be disabled in a guard copy"
  fi

  {
    printf '%s\n' '---' "name: $skill" '---' '<!-- kendex:project-instructions:start -->' '## Project Instructions' ''
    if [ "$block" = shared ]; then
      printf '%s\n' '<!-- kendex:shared-instructions:start -->' 'Rule.' '<!-- kendex:shared-instructions:end -->'
    else
      printf '%s\n' 'Rule.'
    fi
    printf '%s\n' '<!-- kendex:project-instructions:end -->' '# Skill'
  } >"$R/.agents/skills/$skill/SKILL.md"
  run_guard
  [ "$RC" -eq 0 ] \
    && ok "$key instructions pass with the $block render block" \
    || bad "$key instructions pass with the $block render block" "rc=$RC out=$OUT"
done <<'ROWS'
all|shared-all|shared
named|named|project
"*"|shared-star|shared
ROWS

printf '%s\n' '#!/bin/sh' 'exit 9' >"$MUTANT_TOOLS/sort"
chmod +x "$MUTANT_TOOLS/sort"
run_guard PATH="$MUTANT_TOOLS:$PATH"
[ "$RC" -ne 0 ] && [[ "$OUT" == *"guard: render-tracked-set=unreadable"* ]] \
  && ok "a failed render path normalization blocks the guard" || bad "a failed render path normalization blocks the guard" "rc=$RC out=$OUT"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
