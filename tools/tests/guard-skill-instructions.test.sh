#!/usr/bin/env bash
# tools/guard's configured skill instructions rule: each managed skill render
# carries the outer project block, and shared instructions carry their inner
# block. The control removes the rule from a guard copy and expects the same
# missing block to pass.
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
  printf '%s\n' '[skill-instructions]' "$key = \"Rule.\"" >"$R/kendex-local.toml"
  git -C "$R" add kendex-local.toml
  run_guard
  [ "$RC" -ne 0 ] && [[ "$OUT" == *"guard: missing-skill-instructions=1"* ]] \
    && [[ "$OUT" == *".agents/skills/$skill/SKILL.md"* ]] \
    && ok "$key instructions require the $block render block" \
    || bad "$key instructions require the $block render block" "rc=$RC out=$OUT"

  if [ "$key" = all ]; then
    if mutant_guard '/^# A configured instruction /,/^require_render() {/ { /^require_render() {/!d; }'; then
      run_mutant
      [ "$RC" -eq 0 ] \
        && ok "control: with the configured-block rule deleted the missing block passes" \
        || bad "control: with the configured-block rule deleted the missing block passes" "rc=$RC out=$OUT"
    else
      bad "control: the configured-block rule could not be deleted from a guard copy"
    fi
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

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
