#!/usr/bin/env bash
# In-place carve-outs: a path under .agents that the repo's own kendex.toml
# declares `source = "in-place"`, or any .agents/hooks script, is project
# source — never render output. Without a manifest, or under any other
# declaration, .agents stays a render tree.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

repo="$(new_repo in-place)"
mkdir -p "$repo"
cat >"$repo/kendex.toml" <<'MANIFEST'
schema = 6

[skills.mine]
source = "in-place"

[skills.orch]
source = "kendex"
MANIFEST
commit_paths "$repo" "baseline" README.md
base="$(git -C "$repo" rev-parse HEAD)"

case_verdict() { # LABEL EXPECTED PATH...
  local label="$1" expected="$2"
  shift 2
  git -C "$repo" checkout -q -B "case" "$base"
  git -C "$repo" clean -qfd -e kendex.toml
  commit_paths "$repo" "$label" "$@"
  assert_verdict "$label" "$expected" --repo "$repo" --event push --base "$base" --head HEAD
}

case_verdict "an in-place skill edit alone" false \
  .agents/skills/mine/SKILL.md
case_verdict "a rendered skill beside the same manifest" true \
  .agents/skills/orch/SKILL.md
case_verdict "an undeclared .agents skill stays render output" true \
  .agents/skills/stranger/SKILL.md
case_verdict "an adopted hook script alone" false \
  .agents/hooks/claim.sh
case_verdict "an in-place edit inside an otherwise-render diff" false \
  .agents/skills/mine/scripts/tool.sh .claude/agents/rust.md

# A skill name that merely shares a prefix or suffix with a declared one is
# somebody else's tree.
case_verdict "a prefix of the declared name is not it" true \
  .agents/skills/min/SKILL.md
case_verdict "an extension of the declared name is not it" true \
  .agents/skills/mine2/SKILL.md

# No manifest, no carve-outs: the answer before in-place existed.
norepo="$(new_repo no-manifest)"
commit_paths "$norepo" "baseline" README.md
nobase="$(git -C "$norepo" rev-parse HEAD)"
commit_paths "$norepo" "render edit" .agents/skills/mine/SKILL.md
assert_verdict "without a manifest every .agents path is render output" true \
  --repo "$norepo" --event push --base "$nobase" --head HEAD

report in-place
