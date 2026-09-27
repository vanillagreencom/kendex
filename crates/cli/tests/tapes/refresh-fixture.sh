#!/usr/bin/env bash
# The world refresh.tape records: a home under DIR with a catalog, and two
# identical projects, app for the rich half and app-plain for the plain
# one. Each is a git checkout whose manifest was installed and committed,
# then declared one more skill, so a refresh asks before it writes and then
# offers the commit. Prints the shell lines the tape runs kendex under.
set -euo pipefail
# shellcheck source=SCRIPTDIR/fixture-lib.sh
. "$(dirname "$0")/fixture-lib.sh"
world "${1:?usage: refresh-fixture.sh DIR}" refresh-fixture

skill tidy "keeps a tree tidy"
skill commit-guards "keeps commits small"
skill docs-writing "writes documentation"

project() { # NAME
  local project="$home/dev/$1"
  mkdir -p "$project"
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
  git -C "$project" init -q
  (cd "$project" && kendex refresh -y --scope project --leave >/dev/null)
  git -C "$project" add -A
  git -C "$project" commit -q -m install
  printf '\n[skills.commit-guards]\nsource = "cat"\n' >>"$project/kendex.toml"
  git -C "$project" commit -q -am "declare commit-guards"
}
project app
project app-plain

tape_lines "$home/dev/app"
