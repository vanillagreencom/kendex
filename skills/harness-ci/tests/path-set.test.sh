#!/usr/bin/env bash
# The path set: every render tree answers true, anything beside one answers
# false, and near misses remain product paths.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

repo="$(new_repo path-set)"
commit_paths "$repo" "baseline" README.md
base="$(git -C "$repo" rev-parse HEAD)"

# One commit per row, measured against the same baseline.
case_verdict() { # LABEL EXPECTED PATH...
  local label="$1" expected="$2"
  shift 2
  git -C "$repo" checkout -q -B case "$base"
  git -C "$repo" clean -qfd
  commit_paths "$repo" "$label" "$@"
  assert_verdict "$label" "$expected" \
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
generated-families|true|.agents/skills/orch/SKILL.md .claude/agents/rust.md .codex/agents/rust.md .opencode/agent/rust.md .cursor/rules/rust.mdc .pi/kendex/hooks/guard.ts opencode.json
opencode-jsonc|true|opencode.jsonc
opencode-both|true|opencode.json opencode.jsonc
mixed-paths|false|.agents/skills/orch/SKILL.md src/main.rs
product-only|false|src/main.rs
deep-generated-path|true|.agents/skills/review-gate/scripts/lib/settings.sh
pi-runtime-config|true|.pi/settings.json
generated-outside-harness|true|runtime/agent.conf
generated-configs-and-shim|true|.gemini/settings.json .github/agents/rust.agent.md CLAUDE.md
unrecorded-harness-source|false|.claude/source.ts
carrier-manifest|false|.pi/packages/example/package.json
.agentsfoo/notes.md|false|.agentsfoo/notes.md
.agents-old/notes.md|false|.agents-old/notes.md
opencode.json.bak|false|opencode.json.bak
ui/opencode.json|false|ui/opencode.json
opencode.jsonc.bak|false|opencode.jsonc.bak
ui/opencode.jsonc|false|ui/opencode.jsonc
opencode.jsonc5|false|opencode.jsonc5
.claudefoo|false|.claudefoo
.agents|false|.agents
CASES
require_rows path-set "$path_row_count"

# Seed the carrier manifest before changing its extension. Each verdict now
# has one product path that can make it false.
git -C "$repo" checkout -q -B case "$base"
git -C "$repo" clean -qfd
mkdir -p "$repo/.pi/packages/example/extensions"
printf '%s\n' '{"name":"example","scripts":{"test":"node test.js"},"pi":{"extensions":["extensions/main.ts"]}}' >"$repo/.pi/packages/example/package.json"
git -C "$repo" add -A
git -C "$repo" commit -q -m "seed Pi carrier"
package_base="$(git -C "$repo" rev-parse HEAD)"
commit_paths "$repo" "create Pi source" .pi/packages/example/extensions/main.ts
assert_verdict carrier-extension-create false \
  --repo "$repo" --event push --base "$package_base" --head HEAD
extension_head="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" rm -q .pi/packages/example/extensions/main.ts
git -C "$repo" commit -q -m "delete Pi source"
assert_verdict carrier-extension-delete false \
  --repo "$repo" --event push --base "$extension_head" --head HEAD

# Deletion uses the base inventory.
git -C "$repo" checkout -q -B case "$base"
git -C "$repo" rm -q README.md
git -C "$repo" commit -q -m "delete the product file"
assert_verdict product-delete false \
  --repo "$repo" --event push --base "$base" --head HEAD

# A path first claimed by the head inventory remains product work.
git -C "$repo" checkout -q -B case "$base"
git -C "$repo" clean -qfd
jq '. + ["src/claimed.rs"]' "$repo/.kendex-generated.json" >"$repo/inventory.tmp"
mv "$repo/inventory.tmp" "$repo/.kendex-generated.json"
commit_paths "$repo" "product claims generated ownership" src/claimed.rs
assert_verdict ownership-gain false \
  --repo "$repo" --event push --base "$base" --head HEAD

report path-set
