#!/usr/bin/env bash
# The world check.tape records: a home under DIR with a catalog, a project
# that declares three of its skills for two harnesses, one install whose
# files are gone, and one declared over files kendex did not write. Prints
# the shell lines the tape runs kendex under.
set -euo pipefail
root=${1:?usage: check-fixture.sh DIR}
if [ -e "$root" ]; then
  echo "check-fixture: exists=$root" >&2
  exit 2
fi
home="$root/home"
catalog="$home/catalog"
project="$home/dev/app"
mkdir -p "$project/.claude" "$project/.agents"
export HOME="$home" KENDEX_REAL_HOME=1 KENDEX_BACKGROUND_REFRESH=off
export XDG_CONFIG_HOME="$home/.config" XDG_CACHE_HOME="$home/.cache" XDG_DATA_HOME="$home/.local/share"

skill() { # NAME DESCRIPTION
  mkdir -p "$catalog/skills/$1"
  printf -- '---\nname: %s\ndescription: %s\n---\nUse %s with care.\n' "$1" "$2" "$1" >"$catalog/skills/$1/SKILL.md"
}
skill tidy "keeps a tree tidy"
skill commit-guards "keeps commits small"
skill docs-writing "writes documentation"

cat >"$project/kendex.toml" <<TOML
schema = 6

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
(cd "$project" && kendex refresh -y --scope project >/dev/null 2>&1)

# Deleted after the install.
rm -r -- "${project:?}/.agents/skills/docs-writing"
# Declared over files kendex never wrote.
mkdir -p "$project/.claude/skills/commit-guards"
printf -- '---\nname: commit-guards\ndescription: an older copy\n---\nOlder.\n' >"$project/.claude/skills/commit-guards/SKILL.md"
printf '\n[skills.commit-guards]\nsource = "cat"\n' >>"$project/kendex.toml"

printf 'export HOME=%q KENDEX_REAL_HOME=1 KENDEX_BACKGROUND_REFRESH=off XDG_CONFIG_HOME=%q XDG_CACHE_HOME=%q XDG_DATA_HOME=%q\ncd %q\n' \
  "$home" "$home/.config" "$home/.cache" "$home/.local/share" "$project"
