#!/usr/bin/env bash
# Rename detection must stay off. A product file moved into a generated path
# still deletes product source and must run product checks.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

repo="$(new_repo rename)"
commit_paths "$repo" baseline src/app.ts .agents/skills/orch/SKILL.md
product_base="$(git -C "$repo" rev-parse HEAD)"

mkdir -p "$repo/.agents/skills/orch"
git -C "$repo" mv src/app.ts .agents/skills/orch/app.ts
git -C "$repo" commit -q -m "move product into generated output"
product_to_generated="$(git -C "$repo" rev-parse HEAD)"

detected="$(git -C "$repo" diff --name-only "$product_base" "$product_to_generated")"
assert_eq product-to-generated-rename-view \
  ".agents/skills/orch/app.ts" "$detected"

undetected="$(git -C "$repo" diff --name-only --no-renames "$product_base" "$product_to_generated" | sort | tr '\n' ' ')"
assert_eq product-to-generated-no-renames-view \
  ".agents/skills/orch/app.ts src/app.ts " "$undetected"

git -C "$repo" mv .agents/skills/orch/app.ts .agents/skills/orch/renamed.ts
git -C "$repo" commit -q -m "move inside generated output"
generated_to_generated="$(git -C "$repo" rev-parse HEAD)"

mkdir -p "$repo/src"
git -C "$repo" mv .agents/skills/orch/renamed.ts src/renamed.ts
git -C "$repo" commit -q -m "move generated output to product"
generated_to_product="$(git -C "$repo" rev-parse HEAD)"

# label | verdict | base | head
move_row_count=0
while IFS='|' read -r label expected case_base case_head; do
  move_row_count=$((move_row_count + 1))
  assert_verdict "$label" "$expected" \
    --repo "$repo" --event push --base "$case_base" --head "$case_head"
done <<CASES
product-to-generated|false|$product_base|$product_to_generated
generated-to-generated|true|$product_to_generated|$generated_to_generated
generated-to-product|false|$generated_to_generated|$generated_to_product
CASES
require_rows move "$move_row_count"

report rename-into-render
