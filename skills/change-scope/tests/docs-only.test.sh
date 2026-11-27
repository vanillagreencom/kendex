#!/usr/bin/env bash
# Docs-only accepts the documentation set, docs/, changelog.d/ and every
# Markdown file at any path, and rejects every other path, and
# --outside-output lists every path it rejected. Pull-request and
# merge-group events use the shared endpoint rules.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

repo="$(new_repo docs-only)"
commit_paths "$repo" baseline seed.txt
base="$(git -C "$repo" rev-parse HEAD)"

case_verdict() { # LABEL EXPECTED PATH...
  local label="$1" expected="$2"
  shift 2
  git -C "$repo" checkout -q -B case "$base"
  git -C "$repo" clean -qfd
  commit_paths "$repo" "$label" "$@"
  assert_docs_verdict "$label" "$expected" \
    --repo "$repo" --event push --base "$base" --head HEAD
}

# label | verdict | changed paths
path_row_count=0
while IFS='|' read -r label expected paths; do
  path_row_count=$((path_row_count + 1))
  # The table paths have no spaces. Word splitting makes each one an argument.
  # shellcheck disable=SC2086
  case_verdict "$label" "$expected" $paths
done <<'CASES'
docs-tree|true|docs/guide.md docs/architecture/topic.html
changelog-tree|true|changelog.d/added/ci.md
root-markdown|true|README.md CONTRIBUTING.markdown
all-doc-families|true|docs/guide.md changelog.d/fixed/ci.md AGENTS.md
mixed-product|false|docs/guide.md crates/core/src/lib.rs
skill-markdown|true|skills/review-gate/SKILL.md skills/review-gate/references/guide.md
agent-markdown|true|agents/generalist.md
nested-markdown|true|.github/README.md tools/AGENTS.md
hooks-source|false|hooks/pre-commit-check.sh
settings|false|kendex.settings.toml
docs-near-miss|false|documentation/guide.txt
changelog-near-miss|false|changelog.draft/entry.txt
root-text|false|README.txt
CASES
require_rows docs-only-paths "$path_row_count"

git -C "$repo" checkout -q -B case "$base"
git -C "$repo" clean -qfd
commit_paths "$repo" "event endpoints" docs/events.md
head="$(git -C "$repo" rev-parse HEAD)"
assert_docs_verdict pull-request true \
  --repo "$repo" --event pull_request --base "$base" --head "$head"
assert_docs_verdict merge-group true \
  --repo "$repo" --event merge_group --base "$base" --head "$head"

output_file="$SANDBOX/docs-output"
out="$("$HARNESS_ONLY" --mode docs --repo "$repo" --event merge_group \
  --base "$base" --head "$head" --output "$output_file" 2>/dev/null)"
assert_eq "docs mode writes the GitHub output" \
  "docs_only=true stdout=docs_only=true" \
  "$(cat "$output_file") stdout=$out"

# --outside-output lists every changed path outside the set, not only the
# first the verdict names, and is written empty where every path is inside.
outside_file="$SANDBOX/outside"
git -C "$repo" checkout -q -B case "$base"
git -C "$repo" clean -qfd
commit_paths "$repo" "outside" README.md crates/core/src/lib.rs docs/guide.md skills/orch/SKILL.md skills/orch/run.sh
"$HARNESS_ONLY" --mode docs --repo "$repo" --event push --base "$base" --head HEAD \
  --outside-output "$outside_file" >/dev/null 2>&1
assert_eq "docs mode lists every changed path outside the set" \
  "crates/core/src/lib.rs skills/orch/run.sh" "$(tr '\n' ' ' <"$outside_file" | sed 's/ $//')"
"$HARNESS_ONLY" --mode docs --repo "$repo" --event merge_group --base "$base" \
  --head "$head" --outside-output "$outside_file" >/dev/null 2>&1
assert_eq "docs mode writes an empty outside list where every path is inside" \
  "0" "$(wc -c <"$outside_file" | tr -d ' ')"

report docs-only
