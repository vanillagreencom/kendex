#!/usr/bin/env bash
# The world commit-offer.tape records: a home under DIR with a catalog, and
# two identical projects, app for the rich half and app-plain for the plain
# one. Each is a git checkout tracking a bare remote of its own, whose
# manifest was installed, committed and pushed, then declared one more
# skill, so an apply writes files kendex then offers to commit and push.
# Prints the shell lines the tape runs kendex under.
set -euo pipefail
root=${1:?usage: commit-offer-fixture.sh DIR}
if [ -e "$root" ]; then
  echo "commit-offer-fixture: exists=$root" >&2
  exit 2
fi
home="$root/home"
catalog="$home/catalog"
mkdir -p "$home"
export HOME="$home" KENDEX_REAL_HOME=1 KENDEX_BACKGROUND_REFRESH=off
export XDG_CONFIG_HOME="$home/.config" XDG_CACHE_HOME="$home/.cache" XDG_DATA_HOME="$home/.local/share"
printf '[user]\n\tname = Sam\n\temail = sam@example.com\n[init]\n\tdefaultBranch = main\n' >"$home/.gitconfig"

skill() { # NAME DESCRIPTION
  mkdir -p "$catalog/skills/$1"
  printf -- '---\nname: %s\ndescription: %s\n---\nUse %s with care.\n' "$1" "$2" "$1" >"$catalog/skills/$1/SKILL.md"
}
skill tidy "keeps a tree tidy"
skill commit-guards "keeps commits small"

project() { # NAME
  local project="$home/dev/$1" remote="$root/remotes/$1.git"
  mkdir -p "$project"
  git init -q --bare "$remote"
  cat >"$project/kendex.toml" <<TOML
schema = 6

[sources.cat]
path = "$catalog"

[install]
harnesses = ["claude"]
method = "copy"

[skills.tidy]
source = "cat"
TOML
  git -C "$project" init -q
  (cd "$project" && kendex refresh -y --scope project --leave >/dev/null)
  git -C "$project" add -A
  git -C "$project" commit -q -m install
  git -C "$project" remote add origin "$remote"
  git -C "$project" push -q -u origin main
  printf '\n[skills.commit-guards]\nsource = "cat"\n' >>"$project/kendex.toml"
  git -C "$project" commit -q -am "declare commit-guards"
}
project app
project app-plain

printf 'export HOME=%q KENDEX_REAL_HOME=1 KENDEX_BACKGROUND_REFRESH=off XDG_CONFIG_HOME=%q XDG_CACHE_HOME=%q XDG_DATA_HOME=%q\ncd %q\n' \
  "$home" "$home/.config" "$home/.cache" "$home/.local/share" "$home/dev/app"
