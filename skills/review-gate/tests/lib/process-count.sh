# shellcheck shell=bash
# Process births of one watcher pass, the count the control VM's process-event
# connector reports as "parent of N births". Every executable on the search
# path is wrapped to log its pid and parent pid; the watcher's own bash
# processes trace their BASHPID through BASH_ENV. A birth is a pid whose
# parent is the watcher or one of its subshells, so a stub's own children are
# not the watcher's cost. Needs BASHPID and BASH_XTRACEFD (bash 4.1).

# pc_install DIR SEARCH_PATH — wrappers under DIR/bin, the trace hook DIR/bash-env.
pc_install() {
  local dir="$1" d exe name dirs=()
  mkdir -p "$dir/bin"
  IFS=: read -ra dirs <<<"$2"
  for d in ${dirs[@]+"${dirs[@]}"}; do
    [[ -d "$d" ]] || continue
    for exe in "$d"/*; do
      name="${exe##*/}"
      [[ -f "$exe" && -x "$exe" && ! -e "$dir/bin/$name" ]] || continue
      [[ "$exe$dir" != *"'"* ]] || continue
      printf '#!/bin/sh\nprintf "w %%s %%s %%s\\n" "$$" "$PPID" '\''%s'\'' >>'\''%s/log'\''\nexec '\''%s'\'' "$@"\n' \
        "$name" "$dir" "$exe" >"$dir/bin/$name"
    done
  done
  chmod +x "$dir/bin/"*
  printf '%s\n' \
    'case "$0" in' \
    "  */pr-watch.sh) [ -n \"\${BASHPID:-}\" ] || { printf 'process-count: unsupported-bash=%s\\n' \"\$BASH_VERSION\" >&2; exit 2; }; printf '%s\\n' \"\$\$\" >'$dir/main'; exec 19>>'$dir/trace'; BASH_XTRACEFD=19; PS4='+count:\${BASHPID:-\$\$}: '; set -x ;;" \
    'esac' >"$dir/bash-env"
}

# pc_reset DIR — forget the previous pass.
pc_reset() {
  : >"$1/log"
  : >"$1/trace"
  : >"$1/main"
}

# pc_births DIR [NAME] — births of the traced pass, or only those that ran NAME.
pc_births() {
  awk -v main="$(cat "$1/main")" -v only="${2:-}" '
    FILENAME == ARGV[1] {
      if (match($0, /^\++count:[0-9]+:/)) { p = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", p); traced[p] = 1 }
      next
    }
    { logged[$2] = 1; parent[NR] = $3; pid[NR] = $2; name[NR] = $4 }
    END {
      for (p in traced) if (p == main || !(p in logged)) own[p] = 1
      own[main] = 1
      if (only == "") for (p in traced) if (p != main) birth[p] = 1
      for (i in pid) if ((parent[i] in own) && pid[i] != main && (only == "" || name[i] == only)) birth[pid[i]] = 1
      n = 0
      for (p in birth) n++
      print n
    }' "$1/trace" "$1/log"
}
