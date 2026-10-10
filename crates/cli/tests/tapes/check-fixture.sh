#!/usr/bin/env bash
# The world check.tape records: a home under DIR with a catalog, a project
# that declares three of its skills for two harnesses, one install whose
# files are gone, and one declared over files kendex did not write. Prints
# the shell lines the tape runs kendex under.
set -euo pipefail
# shellcheck source=SCRIPTDIR/fixture-lib.sh
. "$(dirname "$0")/fixture-lib.sh"
world "${1:?usage: check-fixture.sh DIR}" check-fixture
project="$home/dev/app"
mkdir -p "$project/.claude" "$project/.agents"

skill tidy "keeps a tree tidy"
skill commit-guards "keeps commits small"
skill docs-writing "writes documentation"

cat >"$project/kendex.toml" <<TOML
schema = 7

[sources.cat]
path = "$catalog"

[install]
harnesses = ["claude", "codex"]
method = "copy"

[skills.tidy]
source = "cat"

[skills.docs-writing]
source = "cat"
TOML
(cd "$project" && kendex refresh -y --scope project >/dev/null)

# Deleted after the install.
rm -r -- "${project:?}/.agents/skills/docs-writing"
# Declared over files kendex never wrote.
mkdir -p "$project/.claude/skills/commit-guards"
printf -- '---\nname: commit-guards\ndescription: an older copy\n---\nOlder.\n' >"$project/.claude/skills/commit-guards/SKILL.md"
printf '\n[skills.commit-guards]\nsource = "cat"\n' >>"$project/kendex.toml"

tape_lines "$project"
