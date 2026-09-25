#!/usr/bin/env bash
# Pull requests use a merge-base range. Pushes and merge groups use their two
# endpoints so discarded force-push work still runs product checks.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

repo="$(new_repo force-push)"
commit_paths "$repo" baseline README.md
fork="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q -b topic
commit_paths "$repo" "product work" src/feature.rs
before="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" reset -q --hard "$fork"
commit_paths "$repo" "render only" .agents/skills/orch/SKILL.md
after="$(git -C "$repo" rev-parse HEAD)"

merge_base_view="$(git -C "$repo" diff --name-only --no-renames "$before...$after")"
assert_eq push-discards-product-merge-base-view \
  ".agents/skills/orch/SKILL.md" "$merge_base_view"

pr="$(new_repo moving-base)"
commit_paths "$pr" baseline README.md
git -C "$pr" checkout -q -b feature
commit_paths "$pr" "render only" .claude/agents/rust.md
pr_head="$(git -C "$pr" rev-parse HEAD)"
git -C "$pr" checkout -q main
commit_paths "$pr" "unrelated product work on main" src/other.rs
pr_base="$(git -C "$pr" rev-parse HEAD)"

mg="$(new_repo merge-group)"
commit_paths "$mg" baseline README.md
mg_base="$(git -C "$mg" rev-parse HEAD)"
commit_paths "$mg" "render only" .codex/agents/rust.md
mg_render_head="$(git -C "$mg" rev-parse HEAD)"
commit_paths "$mg" "product work" src/main.rs
mg_mixed_head="$(git -C "$mg" rev-parse HEAD)"

# label | verdict | repository | event | base | head
# A head beginning with default: checks that ref out and omits --head.
event_row_count=0
while IFS='|' read -r label expected case_repo event case_base case_head; do
  event_row_count=$((event_row_count + 1))
  case "$case_head" in
    default:*)
      git -C "$case_repo" checkout -q --detach "${case_head#default:}"
      assert_verdict "$label" "$expected" \
        --repo "$case_repo" --event "$event" --base "$case_base"
      ;;
    *)
      assert_verdict "$label" "$expected" \
        --repo "$case_repo" --event "$event" --base "$case_base" --head "$case_head"
      ;;
  esac
done <<CASES
push-discards-product|false|$repo|push|$before|$after
pr-moving-base|true|$pr|pull_request|$pr_base|$pr_head
push-same-moving-base|false|$pr|push|$pr_base|$pr_head
merge-group-render|true|$mg|merge_group|$mg_base|$mg_render_head
merge-group-mixed|false|$mg|merge_group|$mg_base|$mg_mixed_head
default-head-render|true|$mg|merge_group|$mg_base|default:$mg_render_head
default-head-mixed|false|$mg|merge_group|$mg_base|default:$mg_mixed_head
CASES
require_rows event-ranges "$event_row_count"

# Each verdict names the commits its range was read between, so a caller
# reading the same range's committed state resolves neither end itself: the
# merge base on a pull request, the commit the base endpoint resolved to on
# the others, and the commit the head endpoint resolved to, symbolic names
# included.
pr_merge_base="$(git -C "$pr" merge-base "$pr_base" "$pr_head")"
git -C "$mg" checkout -q --detach "$mg_render_head"
git -C "$mg" tag mg-base "$mg_base"
# label | repository | event | base | head | expected lines
resolved_row_count=0
while IFS='|' read -r label case_repo event case_base case_head expected; do
  resolved_row_count=$((resolved_row_count + 1))
  resolved="$("$HARNESS_ONLY" --repo "$case_repo" --event "$event" \
    --base "$case_base" --head "$case_head" 2>&1 >/dev/null |
    sed -n '/^base-rev: /p; /^head-rev: /p' | tr '\n' ' ')"
  assert_eq "$label" "$expected " "$resolved"
done <<CASES
a pull request names its merge base and head|$pr|pull_request|$pr_base|$pr_head|base-rev: $pr_merge_base head-rev: $pr_head
a merge group names its endpoints|$mg|merge_group|$mg_base|$mg_mixed_head|base-rev: $mg_base head-rev: $mg_mixed_head
a symbolic head is named by the commit it resolved to|$mg|merge_group|$mg_base|HEAD|base-rev: $mg_base head-rev: $mg_render_head
a symbolic base is named by the commit it resolved to|$mg|merge_group|mg-base|$mg_mixed_head|base-rev: $mg_base head-rev: $mg_mixed_head
CASES
require_rows event-ranges-resolved "$resolved_row_count"

report event-ranges
