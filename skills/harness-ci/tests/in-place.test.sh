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


# Every spelling a declaration legally wears: quoted keys (spaces included),
# single quotes, indentation, spaces around the dotted key, trailing value
# comments, a [skills] table with inline and dotted entries, and top-level
# dotted keys — inline tables are single-line by TOML 1.0.
spell="$(new_repo spellings)"
cat >"$spell/kendex.toml" <<'MANIFEST'
schema = 6

[skills]
tabled = { source = "in-place" }
dotted.source = "in-place"

[skills."ship it"]
source = "in-place"

  [skills.indented]
  source = "in-place" # kept in place

[ skills . spaced ]
source = 'in-place'

[skills.tripled]
source = """in-place"""

[skills.lit3]
source = '''in-place'''
MANIFEST
commit_paths "$spell" "baseline" README.md
spellbase="$(git -C "$spell" rev-parse HEAD)"
spell_case() { # LABEL EXPECTED PATH
  git -C "$spell" checkout -q -B "case" "$spellbase"
  git -C "$spell" clean -qfd -e kendex.toml
  commit_paths "$spell" "$1" "$3"
  assert_verdict "$1" "$2" --repo "$spell" --event push --base "$spellbase" --head HEAD
}
spell_case "a quoted name with a space" false ".agents/skills/ship it/SKILL.md"
spell_case "an indented declaration with a value comment" false .agents/skills/indented/SKILL.md
spell_case "spaces around the dotted key, single-quoted value" false .agents/skills/spaced/SKILL.md
spell_case "an inline table under the skills table" false .agents/skills/tabled/SKILL.md
spell_case "a dotted entry under the skills table" false .agents/skills/dotted/SKILL.md
spell_case "a multiline-basic-string value" false .agents/skills/tripled/SKILL.md
spell_case "a multiline-literal-string value" false .agents/skills/lit3/SKILL.md

# Top-level dotted spellings live in their own manifest: TOML lets one style
# define the skills table, not both.
dotted="$(new_repo dotted)"
printf '%s\n' 'schema = 6' 'skills.inline = { source = "in-place" }' 'skills.deep.source = "in-place"' >"$dotted/kendex.toml"
commit_paths "$dotted" "baseline" README.md
dottedbase="$(git -C "$dotted" rev-parse HEAD)"
for dotted_skill in inline deep; do
  git -C "$dotted" checkout -q -B "case" "$dottedbase"
  git -C "$dotted" clean -qfd -e kendex.toml
  commit_paths "$dotted" "$dotted_skill" ".agents/skills/$dotted_skill/SKILL.md"
  assert_verdict "a top-level dotted $dotted_skill declaration" false --repo "$dotted" --event push --base "$dottedbase" --head HEAD
done

# A CRLF manifest is legal TOML; the carriage return must not defeat the
# anchored matches.
crlf="$(new_repo crlf)"
printf 'schema = 6\r\n\r\n[skills.mine]\r\nsource = "in-place"\r\n' >"$crlf/kendex.toml"
commit_paths "$crlf" "baseline" README.md
crlfbase="$(git -C "$crlf" rev-parse HEAD)"
commit_paths "$crlf" "edit" .agents/skills/mine/SKILL.md
assert_verdict "a CRLF manifest still carves" false --repo "$crlf" --event push --base "$crlfbase" --head HEAD

report in-place
