#!/usr/bin/env bash
# Source adoption removes the file from the writer inventory.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"
repo="$(new_repo in-place)"
commit_paths "$repo" baseline .agents/skills/orch/SKILL.md
base="$(git -C "$repo" rev-parse HEAD)"
commit_paths "$repo" render .agents/skills/orch/SKILL.md
assert_verdict "recorded render skips product checks" true --repo "$repo" --event push --base "$base"
jq 'map(select(. != ".agents/skills/orch/SKILL.md"))' "$repo/.kendex-generated.json" >"$repo/inventory.tmp"
mv "$repo/inventory.tmp" "$repo/.kendex-generated.json"
commit_paths "$repo" adoption .agents/skills/orch/SKILL.md
assert_verdict "source adoption runs product checks" false --repo "$repo" --event push --base "$base"
report in-place
