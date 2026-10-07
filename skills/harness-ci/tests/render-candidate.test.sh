#!/usr/bin/env bash
# Endpoint ownership buys prerequisites only. Direct CI waivers keep their
# ownership-gain refusal, including when an author lists new product content.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

repo="$(new_repo candidate)"
commit_paths "$repo" base .agents/skills/orch/SKILL.md
base="$(git -C "$repo" rev-parse HEAD)"
rows=0
while IFS='|' read -r label path listed expected; do
  rows=$((rows + 1))
  git -C "$repo" checkout -q -B "case-$rows" "$base"
  if [ "$listed" = yes ]; then
    jq --arg p "$path" '. + [$p] | sort' "$repo/.kendex-generated.json" >"$SANDBOX/inventory"
    mv "$SANDBOX/inventory" "$repo/.kendex-generated.json"
  fi
  commit_paths "$repo" "$label" "$path"
  assert_eq "$label: prerequisites" "render_candidate=$expected" \
    "$(classify --mode render-candidate --repo "$repo" --event pull_request --base "$base")"
  assert_verdict "$label: no direct waiver" false --repo "$repo" --event pull_request --base "$base"
done <<'ROWS'
new render|.agents/skills/orch/added.md|yes|true
planted product ownership|runtime/new.conf|yes|true
unclaimed product|runtime/other.conf|no|false
ROWS
require_rows candidate "$rows"

git -C "$repo" checkout -q case-1
mutant_class="$(mutant candidate-refused harness-only \
  'if [ "$classification" != render-candidate ]; then' 'if true; then')"
mutant_harness="${mutant_class%/*}/harness-only"
assert_eq "must-fail: retaining the old subset guard prevents prerequisites for a new render" render_candidate=false \
  "$("$mutant_harness" --mode render-candidate --repo "$repo" --event pull_request --base "$base" 2>/dev/null)"

git -C "$repo" checkout -q case-2
mutant_class="$(mutant candidate-waiver harness-only \
  'if [ "$classification" != render-candidate ]; then' 'if false; then')"
mutant_harness="${mutant_class%/*}/harness-only"
assert_eq "must-fail: removing default refusal grants a planted product waiver" harness_only=true \
  "$("$mutant_harness" --repo "$repo" --event pull_request --base "$base" 2>/dev/null)"

git -C "$repo" checkout -q case-1
mutant_class="$(mutant candidate-base-only harness-only \
  '    [ "$endpoint" != "$head" ] || inventory="$head_inventory"' \
  '    [ "$endpoint" != "$head" ] || inventory="$base_inventory"')"
mutant_harness="${mutant_class%/*}/harness-only"
assert_eq "must-fail: base-only ownership misses a new generated file" render_candidate=false \
  "$("$mutant_harness" --mode render-candidate --repo "$repo" --event pull_request --base "$base" 2>/dev/null)"

report render-candidate
