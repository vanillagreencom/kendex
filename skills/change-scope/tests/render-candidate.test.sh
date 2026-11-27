#!/usr/bin/env bash
# Endpoint ownership buys prerequisites only. Direct CI waivers keep their
# ownership-gain refusal, including when an author lists new product content.
# The docs waiver follows the docs set alone: Markdown at any path is in it,
# a bot output among them.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

repo="$(new_repo candidate)"
printf '%s\n' '[bot-instructions.repo]' \
  'code_review_path = ".github/instructions/project-review.md"' >"$repo/kendex.toml"
commit_paths "$repo" base .agents/skills/orch/SKILL.md \
  .github/instructions/code-review.md .github/copilot-instructions.md \
  .github/instructions/runtime.instructions.md .github/instructions/project-review.md
base="$(git -C "$repo" rev-parse HEAD)"
rows=0
while IFS='|' read -r label path listed expected docs extra; do
  rows=$((rows + 1))
  git -C "$repo" checkout -q -B "case-$rows" "$base"
  if [ "$listed" = yes ]; then
    jq --arg p "$path" '. + [$p] | sort' "$repo/.kendex-generated.json" >"$SANDBOX/inventory"
    mv "$SANDBOX/inventory" "$repo/.kendex-generated.json"
  fi
  commit_paths "$repo" "$label" "$path" .agents/skills/orch/SKILL.md
  if [ -n "$extra" ]; then
    commit_paths "$repo" 'unclaimed path' "$extra"
  fi
  assert_eq "$label: prerequisites" "render_candidate=$expected" \
    "$(classify --mode render-candidate --repo "$repo" --event pull_request --base "$base")"
  assert_verdict "$label: no direct waiver" false --repo "$repo" --event pull_request --base "$base"
  assert_docs_verdict "$label: docs waiver" "$docs" --repo "$repo" --event pull_request --base "$base"
done <<'ROWS'
new render|.agents/skills/orch/added.md|yes|true|false
planted product ownership|runtime/new.conf|yes|true|false
unclaimed product|runtime/other.conf|no|false|false
adopted caller without inventory entry|.github/workflows/kendex-refresh.yml|no|true|false
adopted caller and unclaimed workflow|.github/workflows/kendex-refresh.yml|no|false|false|.github/workflows/other.yml
bot review doctrine without inventory entry|.github/instructions/code-review.md|no|true|true
Copilot instructions without inventory entry|.github/copilot-instructions.md|no|true|true
bot path instructions without inventory entry|.github/instructions/runtime.instructions.md|no|true|true
configured review path without inventory entry|.github/instructions/project-review.md|no|true|true
bot output and unclaimed product|.github/instructions/code-review.md|no|false|false|runtime/other.conf
ROWS
require_rows candidate "$rows"

git -C "$repo" checkout -q case-4
mutant_class="$(mutant candidate-caller-refused harness-only \
  '      "$HARNESS_CI_REFRESH_CALLER" | .github/copilot-instructions.md | .github/instructions/*) continue ;;' \
  '      .github/copilot-instructions.md | .github/instructions/*) continue ;;')"
assert_eq 'must-fail: refusing the adopted caller loses proof prerequisites' render_candidate=false \
  "$("${mutant_class%/*}/harness-only" --mode render-candidate --repo "$repo" --event pull_request --base "$base" 2>/dev/null)"

git -C "$repo" checkout -q case-5
mutant_class="$(mutant candidate-any-workflow harness-only \
  '      "$HARNESS_CI_REFRESH_CALLER" | .github/copilot-instructions.md | .github/instructions/*) continue ;;' \
  '      *) continue ;;')"
assert_eq 'must-fail: accepting every unclaimed path grants unrelated prerequisites' render_candidate=true \
  "$("${mutant_class%/*}/harness-only" --mode render-candidate --repo "$repo" --event pull_request --base "$base" 2>/dev/null)"

git -C "$repo" checkout -q case-6
mutant_class="$(mutant candidate-bot-refused harness-only \
  '      "$HARNESS_CI_REFRESH_CALLER" | .github/copilot-instructions.md | .github/instructions/*) continue ;;' \
  '      "$HARNESS_CI_REFRESH_CALLER") continue ;;')"
assert_eq 'must-fail: refusing bot outputs loses proof prerequisites' render_candidate=false \
  "$("${mutant_class%/*}/harness-only" --mode render-candidate --repo "$repo" --event pull_request --base "$base" 2>/dev/null)"

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
