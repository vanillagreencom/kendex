# shellcheck shell=bash
# Test runners share one process identity reader and bounded tree teardown.
# Every read is `ps`, which Linux procps and macOS both answer, so a runner
# starts and stops its suites with nothing built and no other package present.
# STOP_GRACE belongs to the caller.

# A live process's start time, which with its pid names that one process: a
# number freed by its exit and handed to a later process comes back with
# another start. The start prints in the C locale and UTC so two reads of one
# process spell it alike. Status 1 is a process that has ended, a zombie
# included; status 2 is a read that gave no answer. A caller that signals
# acts on status 0 alone.
started_at() { # PID
  local out rc=0
  local -a fields=()
  out="$(LC_ALL=C TZ=UTC ps -o stat= -o lstart= -p "$1" 2>/dev/null)" || rc=$?
  read -r -a fields <<<"$out"
  if [ "$rc" -ne 0 ]; then
    # `ps -p` exits 1 and prints nothing for a pid with no process.
    [ "$rc" -eq 1 ] && [ "${#fields[@]}" -eq 0 ] && return 1
    return 2
  fi
  case "${fields[0]:-}" in
    '') return 2 ;;
    Z*) return 1 ;;
  esac
  [ "${#fields[@]}" -gt 1 ] || return 2
  printf '%s\n' "${fields[*]:1}"
}

# The processes below ROOT in TABLE, `ps -A -o pid= -o ppid=` rows, one pid a
# line, nearest first. Each pid is listed once, so a table read mid-reparent
# that holds a cycle ends.
tree_below() { # TABLE ROOT
  awk -v root="$2" '
    NF >= 2 { kids[$2] = kids[$2] " " $1 }
    END {
      queue[1] = root; seen[root] = 1; n = 1
      for (i = 1; i <= n; i++) {
        m = split(kids[queue[i]], child, " ")
        for (j = 1; j <= m; j++) {
          if (child[j] in seen) continue
          seen[child[j]] = 1; queue[++n] = child[j]; print child[j]
        }
      }
    }' <<<"$1"
}

# PID and every process under it, one `PID START` line each. Taken before any
# signal: a process whose parent the stop ends is no longer found under it. A
# process table that cannot be read leaves PID alone in it.
tree_of() { # PID
  local table pid start
  table="$(ps -A -o pid= -o ppid= 2>/dev/null)" || table=""
  while read -r pid; do
    [ -n "$pid" ] || continue
    start="$(started_at "$pid")" && printf '%s %s\n' "$pid" "$start"
  done <<<"$1
$(tree_below "$table" "$1")"
  return 0
}

# The processes of TREE that are still the ones listed there, one pid a line.
tree_live() { # TREE
  local pid start
  while read -r pid start; do
    [ -n "$pid" ] && [ "$(started_at "$pid")" = "$start" ] && printf '%s\n' "$pid"
  done <<<"$1"
  return 0
}

signal_tree() { # SIGNAL TREE
  local pid
  for pid in $(tree_live "$2"); do kill -"$1" "$pid" 2>/dev/null; done
  return 0
}

tree_running() { [ -n "$(tree_live "$1")" ]; } # TREE

# One bounded teardown for cancellation and overdue suites. Keep identities
# from before TERM: a parent that exits no longer leads to its descendants.
stop_tree() { # TREE
  local until=$((SECONDS + STOP_GRACE))
  signal_tree TERM "$1"
  while tree_running "$1" && [ "$SECONDS" -lt "$until" ]; do sleep 0.1; done
  signal_tree KILL "$1"
}
