#!/usr/bin/env bash
# Which range each event measures. pull_request takes the merge base, because
# the base branch moves under an open PR. push and merge_group take the two
# endpoints, because a force-push leaves the `before` sha off the head's
# history and a merge base there is a commit the push already discarded.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

# --- push: the force-push case ------------------------------------------
repo="$(new_repo force-push)"
commit_paths "$repo" "baseline" README.md
fork="$(git -C "$repo" rev-parse HEAD)"

git -C "$repo" checkout -q -b topic
commit_paths "$repo" "product work" src/feature.rs
before="$(git -C "$repo" rev-parse HEAD)"

# The force-push: the product commit is dropped and replaced by a render-only
# one, so the endpoints share only the fork point.
git -C "$repo" reset -q --hard "$fork"
commit_paths "$repo" "render only" .agents/skills/orch/SKILL.md
after="$(git -C "$repo" rev-parse HEAD)"

assert_verdict "a force-push that discards product work answers false" false \
  --repo "$repo" --event push --base "$before" --head "$after"

merge_base_view="$(git -C "$repo" diff --name-only --no-renames "$before...$after")"
assert_eq "the merge-base range would have seen only the render" \
  ".agents/skills/orch/SKILL.md" "$merge_base_view"

# --- pull_request: the moving base branch --------------------------------
pr="$(new_repo moving-base)"
commit_paths "$pr" "baseline" README.md

git -C "$pr" checkout -q -b feature
commit_paths "$pr" "render only" .claude/agents/rust.md
pr_head="$(git -C "$pr" rev-parse HEAD)"

git -C "$pr" checkout -q main
commit_paths "$pr" "unrelated product work on main" src/other.rs
pr_base="$(git -C "$pr" rev-parse HEAD)"

assert_verdict "a render-only PR is unaffected by base-branch commits" true \
  --repo "$pr" --event pull_request --base "$pr_base" --head "$pr_head"

assert_verdict "the same endpoints read end-to-end pick up the base's work" false \
  --repo "$pr" --event push --base "$pr_base" --head "$pr_head"

# --- merge_group: the endpoint form ---------------------------------------
mg="$(new_repo merge-group)"
commit_paths "$mg" "baseline" README.md
mg_base="$(git -C "$mg" rev-parse HEAD)"
commit_paths "$mg" "render only" .codex/agents/rust.md
mg_head="$(git -C "$mg" rev-parse HEAD)"

assert_verdict "a render-only merge group answers true" true \
  --repo "$mg" --event merge_group --base "$mg_base" --head "$mg_head"

commit_paths "$mg" "product work" src/main.rs
assert_verdict "a mixed merge group answers false" false \
  --repo "$mg" --event merge_group --base "$mg_base" --head HEAD

# --head defaults to HEAD rather than requiring the caller to name it.
assert_verdict "--head defaults to HEAD" false \
  --repo "$mg" --event merge_group --base "$mg_base"

report event-ranges
