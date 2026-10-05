#!/usr/bin/env bash
# The one reader of a workflow's lane declaration, .github/ci-lanes.conf, for
# the change-class action's classify, which answers a verdict per lane, and
# change-class, whose queue-only line names a lane deferred to the merge
# queue. Sourced; bash 3.2 compatible, so no associative array.
#
# The grammar: `<lane>[:event-uniform][:queue] <glob>...` per line, the marks
# in either order, `#` to the end of a line a comment. A name is lowercase
# letters, digits, `_` and `-`, starting with a letter or digit. A lane named
# on several lines reads every glob they give it, and carries a mark where
# any of them carries it.
#
# ci_lanes_read FILE fills lane N's name, its globs (one per line) and its
# two marks (true|false) at index N of lane_names, lane_globs, lane_uniform
# and lane_queue, and the count in lane_count. Where FILE is unreadable or
# malformed it returns 1 with the cause in declaration_note; the arrays are
# then partial and the caller discards them.
# ci_lanes_claims INDEX PATH returns 0 where one of lane INDEX's globs
# matches PATH, setting LANE_GLOB_HIT to that glob. A glob is a shell
# pattern, so `*` also matches `/`; extglob is off for the match whatever
# the caller set, so every reader matches one grammar.

lane_names=()
lane_globs=()
lane_uniform=()
lane_queue=()
lane_count=0
declaration_note=""
LANE_GLOB_HIT=""

ci_lanes_read() { # FILE
  local text line number=0 name raw uniform queue glob index
  lane_names=() lane_globs=() lane_uniform=() lane_queue=() lane_count=0
  declaration_note=""
  text="$(cat -- "$1" 2>/dev/null)" ||
    { declaration_note="cause=unreadable"; return 1; }
  while IFS= read -r line; do
    number=$((number + 1))
    line="${line%%#*}"
    set -f
    # shellcheck disable=SC2086 # a line is blank-separated words
    set -- $line
    set +f
    [ "$#" -gt 0 ] || continue
    raw="$1" name="$1"
    shift
    uniform=false queue=false
    while :; do
      case "$name" in
        *:event-uniform) uniform=true name="${name%:event-uniform}" ;;
        *:queue) queue=true name="${name%:queue}" ;;
        *) break ;;
      esac
    done
    case "$name" in
      '' | [!abcdefghijklmnopqrstuvwxyz0123456789]* | *[!abcdefghijklmnopqrstuvwxyz0123456789_-]*)
        declaration_note="cause=bad-name line=$number name=$raw"
        return 1 ;;
    esac
    [ "$#" -gt 0 ] ||
      { declaration_note="cause=no-globs line=$number lane=$name"; return 1; }
    index=0
    while [ "$index" -lt "$lane_count" ] && [ "${lane_names[$index]}" != "$name" ]; do
      index=$((index + 1))
    done
    if [ "$index" -eq "$lane_count" ]; then
      lane_names[$index]="$name"
      lane_globs[$index]=""
      lane_uniform[$index]=false
      lane_queue[$index]=false
      lane_count=$((lane_count + 1))
    fi
    [ "$uniform" = false ] || lane_uniform[$index]=true
    [ "$queue" = false ] || lane_queue[$index]=true
    for glob in "$@"; do
      lane_globs[$index]="${lane_globs[$index]}$glob
"
    done
  done <<<"$text"
  [ "$lane_count" -gt 0 ] || { declaration_note="cause=no-lanes"; return 1; }
}

ci_lanes_claims() { # INDEX PATH
  local glob extglob=false status=1 IFS='
'
  LANE_GLOB_HIT=""
  ! shopt -q extglob || { extglob=true; shopt -u extglob; }
  set -f; for glob in ${lane_globs[$1]}; do
    # shellcheck disable=SC2254 # the glob is a pattern
    case "$2" in
      $glob) LANE_GLOB_HIT="$glob" status=0; break ;;
    esac
  done
  set +f
  [ "$extglob" = false ] || shopt -s extglob
  return "$status"
}
