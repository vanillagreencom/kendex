# shellcheck shell=bash
# A PATH with named commands hidden, for the cases that must run as a host
# without them. Sourced, never run as a suite: the runners glob tests/*.sh,
# so both the subdirectory and the .bash name keep this file out of every run.
#
# Mirroring the caller's own PATH rather than listing what to keep is what
# makes the fixture rot-proof: a script that grows a new dependency still
# finds it here, and only what was named is missing.

# One `ln` per source directory, not one per file — /usr/bin alone is a few
# thousand forks. A name already staged is skipped, which is PATH's own
# first-directory-wins rule. Nothing sets nullglob: a directory with no
# entries yields the unmatched pattern, which is not a file and is dropped by
# the same test that drops a non-executable one.
path_farm_without() { # DIR NAME... — stage DIR as a PATH missing every NAME
  local dir="$1" hidden="" src="" f="" base=""
  shift
  hidden=" $* "
  mkdir -p "$dir" || return 1
  while IFS= read -r src; do
    [ -d "$src" ] || continue
    local staged=()
    for f in "$src"/*; do
      { [ -f "$f" ] && [ -x "$f" ]; } || continue
      base="${f##*/}"
      case "$hidden" in *" $base "*) continue ;; esac
      [ ! -e "$dir/$base" ] || continue
      staged+=("$f")
    done
    [ "${#staged[@]}" -eq 0 ] || ln -s -- "${staged[@]}" "$dir/" 2>/dev/null || true
  done < <(printf '%s\n' "$PATH" | tr ':' '\n')
}
