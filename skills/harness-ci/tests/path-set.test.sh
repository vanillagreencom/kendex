#!/usr/bin/env bash
# The path set: every render tree answers true, anything beside one answers
# false, and the near misses that merely start with a render tree's name are
# product paths like any other.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

repo="$(new_repo path-set)"
commit_paths "$repo" "baseline" README.md
base="$(git -C "$repo" rev-parse HEAD)"

# One commit per case, each measured against the same baseline, so a case
# never inherits another's paths.
case_verdict() { # LABEL EXPECTED PATH...
  local label="$1" expected="$2"
  shift 2
  git -C "$repo" checkout -q -B "case" "$base"
  git -C "$repo" clean -qfd
  commit_paths "$repo" "$label" "$@"
  assert_verdict "$label" "$expected" --repo "$repo" --event push --base "$base" --head HEAD
}

case_verdict "every render tree at once" true \
  .agents/skills/orch/SKILL.md \
  .claude/agents/rust.md \
  .codex/agents/rust.md \
  .opencode/agent/rust.md \
  .cursor/rules/rust.mdc \
  .pi/kendex/hooks/guard.ts \
  opencode.json

# kendex writes opencode.jsonc where a project carries that spelling instead,
# so both names are the one OpenCode config.
case_verdict "the jsonc spelling of the config" true opencode.jsonc
case_verdict "both spellings side by side" true opencode.json opencode.jsonc

case_verdict "a render path beside a product path" false \
  .agents/skills/orch/SKILL.md src/main.rs

case_verdict "product paths alone" false src/main.rs

case_verdict "deeply nested render output" true \
  .agents/skills/review-gate/scripts/lib/settings.sh

case_verdict "Pi runtime config is generated" true .pi/settings.json
case_verdict "a Pi package without declared tests stays generated" true \
  .pi/packages/example/package.json

git -C "$repo" checkout -q -B "case" "$base"
git -C "$repo" clean -qfd
mkdir -p "$repo/.pi/packages/example/extensions"
printf '%s\n' '{"name":"example","scripts":{"test":"node test.js"},"pi":{"extensions":["extensions/main.ts"]}}' >"$repo/.pi/packages/example/package.json"
printf '%s\n' 'export const active = true;' >"$repo/.pi/packages/example/extensions/main.ts"
git -C "$repo" add -A
git -C "$repo" commit -q -m "Pi source package"
package_base="$(git -C "$repo" rev-parse HEAD)"
assert_verdict "a tested Pi extension is product source" false \
  --repo "$repo" --event push --base "$base" --head "$package_base"
git -C "$repo" rm -q .pi/packages/example/extensions/main.ts
git -C "$repo" commit -q -m "delete Pi source"
assert_verdict "deleting tested Pi extension code is a product change" false \
  --repo "$repo" --event push --base "$package_base" --head HEAD

# The near misses. A prefix match without the separator is a different path,
# and a suffix past the filename is a different file.
case_verdict ".agentsfoo is not .agents/" false .agentsfoo/notes.md
case_verdict ".agents-old is not .agents/" false .agents-old/notes.md
case_verdict "opencode.json.bak is not opencode.json" false opencode.json.bak
case_verdict "a nested opencode.json is not the root one" false ui/opencode.json
case_verdict "opencode.jsonc.bak is not opencode.jsonc" false opencode.jsonc.bak
case_verdict "a nested opencode.jsonc is not the root one" false ui/opencode.jsonc
case_verdict "opencode.jsonc5 is not opencode.jsonc" false opencode.jsonc5
case_verdict ".claudefoo is not .claude/" false .claudefoo
case_verdict "a bare .agents file is not the tree" false .agents

# A deletion is a change like any other: removing a product file cannot read
# as harness-only merely because the change touches nothing outside the render.
git -C "$repo" checkout -q -B "case" "$base"
git -C "$repo" rm -q README.md
git -C "$repo" commit -q -m "delete the product file"
assert_verdict "a product deletion answers false" false \
  --repo "$repo" --event push --base "$base" --head HEAD

report path-set
