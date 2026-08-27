#!/usr/bin/env bash
# --no-renames is load-bearing. Moving a product file INTO a render tree
# deletes source; with rename detection on, git lists only the post-image and
# the diff reads as render-only, so the lanes that would have judged the
# deletion never run.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

repo="$(new_repo rename)"
commit_paths "$repo" "baseline" src/app.ts .agents/skills/orch/SKILL.md
base="$(git -C "$repo" rev-parse HEAD)"

mkdir -p "$repo/.agents/skills/orch"
git -C "$repo" mv src/app.ts .agents/skills/orch/app.ts
git -C "$repo" commit -q -m "move a product file into the render"

assert_verdict "a product file moved into the render answers false" false \
  --repo "$repo" --event push --base "$base" --head HEAD

# The control: with rename detection left on, the same diff lists one path and
# every path it lists is a render path. That is the wrong answer this flag
# exists to prevent, so the suite pins it rather than trusting the comment.
detected="$(git -C "$repo" diff --name-only "$base" HEAD)"
assert_eq "rename detection alone would list only the post-image" \
  ".agents/skills/orch/app.ts" "$detected"

undetected="$(git -C "$repo" diff --name-only --no-renames "$base" HEAD | sort | tr '\n' ' ')"
assert_eq "--no-renames lists the deletion too" \
  ".agents/skills/orch/app.ts src/app.ts " "$undetected"

# A move that stays inside the render is still render-only.
inside_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" mv .agents/skills/orch/app.ts .agents/skills/orch/renamed.ts
git -C "$repo" commit -q -m "move inside the render"
assert_verdict "a move within the render stays true" true \
  --repo "$repo" --event push --base "$inside_base" --head HEAD

# And a render file moved OUT to a product path is a product change.
out_base="$(git -C "$repo" rev-parse HEAD)"
mkdir -p "$repo/src"
git -C "$repo" mv .agents/skills/orch/renamed.ts src/renamed.ts
git -C "$repo" commit -q -m "move out of the render"
assert_verdict "a move out of the render answers false" false \
  --repo "$repo" --event push --base "$out_base" --head HEAD

report rename-into-render
