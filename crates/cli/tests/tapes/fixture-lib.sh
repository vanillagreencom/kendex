# shellcheck shell=bash
# Sourced by the tape fixtures: the home a recording runs kendex in, the
# catalog skill helper, and the shell lines each fixture prints for its
# tape. Each fixture sets `set -euo pipefail` before sourcing this.

# world ROOT FIXTURE: refuse a ROOT that exists, then make a home under it,
# point kendex and git at it, and set `home` and `catalog`.
world() {
  local root=$1 fixture=$2
  if [ -e "$root" ]; then
    echo "$fixture: exists=$root" >&2
    exit 2
  fi
  home="$root/home"
  catalog="$home/catalog"
  mkdir -p "$home"
  export HOME="$home" KENDEX_REAL_HOME=1 KENDEX_BACKGROUND_REFRESH=off
  export XDG_CONFIG_HOME="$home/.config" XDG_CACHE_HOME="$home/.cache" XDG_DATA_HOME="$home/.local/share"
  printf '[user]\n\tname = Sam\n\temail = sam@example.com\n[init]\n\tdefaultBranch = main\n' >"$home/.gitconfig"
}

# skill NAME DESCRIPTION: a skill in the catalog.
skill() {
  mkdir -p "$catalog/skills/$1"
  printf -- '---\nname: %s\ndescription: %s\n---\nUse %s with care.\n' "$1" "$2" "$1" >"$catalog/skills/$1/SKILL.md"
}

# tape_lines PROJECT: the lines the tape evals to run kendex in this home,
# from PROJECT.
tape_lines() {
  printf 'export HOME=%q KENDEX_REAL_HOME=1 KENDEX_BACKGROUND_REFRESH=off XDG_CONFIG_HOME=%q XDG_CACHE_HOME=%q XDG_DATA_HOME=%q\ncd %q\n' \
    "$home" "$home/.config" "$home/.cache" "$home/.local/share" "$1"
}
