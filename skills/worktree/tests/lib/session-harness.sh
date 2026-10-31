#!/usr/bin/env bash
# Owned stand-ins for harness session processes, and the lease edits that put
# a recorded session in a chosen state.
#
# A stand-in is a copy of bash under the harness's name, so the guard's
# ancestor walk stops at it exactly as it stops at a real harness: it reads
# no harness name. The stand-in runs each command the suite sends as its own
# direct child and lives until the suite stops it, so its recorded process is
# live exactly while the suite holds it. Liveness is never read from an
# invented or reaped PID: a dead session is the held process with another
# recorded start, or a ps that reports its PID absent.
#
# session_harness_start DIR NAME  starts one under DIR; SESSION_HARNESS_PID.
# session_harness_run DIR CWD CMD...
#                                 runs CMD inside it from CWD, stdin from
#                                 /dev/null, stdout and stderr in DIR/out and
#                                 DIR/err; returns CMD's status.
# session_harness_stop DIR        ends it and reaps it.
# session_harness_stop_all        ends every one still running.

SESSION_HARNESS_DIRS=''

session_harness_start() { # DIR NAME
  local dir="$1" name="$2"
  mkdir -p -- "$dir/bin" || return 1
  cp -- "$BASH" "$dir/bin/$name" || return 1
  mkfifo -- "$dir/request" "$dir/answer" || return 1
  # Runs inside the copy itself; eval keeps each command a direct child.
  cat >"$dir/loop.sh" <<'EOF'
while IFS= read -r line <"$1"; do
  [ "$line" != exit ] || exit 0
  rc=0
  eval "$line" </dev/null >"$3" 2>"$4" || rc=$?
  printf '%s\n' "$rc" >"$2"
done
EOF
  "$dir/bin/$name" "$dir/loop.sh" "$dir/request" "$dir/answer" "$dir/out" "$dir/err" &
  SESSION_HARNESS_PID=$!
  printf '%s\n' "$SESSION_HARNESS_PID" >"$dir/pid"
  SESSION_HARNESS_DIRS="$SESSION_HARNESS_DIRS $dir"
}

session_harness_run() { # DIR CWD CMD...
  local dir="$1" cwd="$2" line rc
  shift 2
  printf -v line '%q ' "$@"
  printf -v line 'cd -- %q && %s' "$cwd" "$line"
  printf '%s\n' "$line" >"$dir/request"
  IFS= read -r rc <"$dir/answer"
  return "$rc"
}

session_harness_stop() { # DIR
  local pid
  pid="$(cat -- "$1/pid" 2>/dev/null)" || return 0
  # A stand-in that already ended has no reader on its request pipe.
  if kill -0 "$pid" 2>/dev/null; then
    printf 'exit\n' >"$1/request"
  fi
  wait "$pid" 2>/dev/null || :
  rm -f -- "$1/pid"
}

session_harness_stop_all() {
  local dir
  for dir in $SESSION_HARNESS_DIRS; do
    session_harness_stop "$dir"
  done
  SESSION_HARNESS_DIRS=''
}

# The recorded session PIDs of the lease on WT, comma-separated in lease order.
session_lease_pids() { # GUARD WT REPO
  "$1" status "$2" --repo "$3" 2>/dev/null | jq -r '.sessions | split(",") | map(split("/")[0]) | join(",")'
}

# Rewrites the guard lease on WT: `expire` moves its heartbeat past every TTL;
# `restart PID` gives PID's recorded identity another start, which the held
# process then contradicts; `rehost PID` moves that identity to another host.
# A rewrite that changes nothing refuses.
session_lease_rewrite() { # WT expire | restart PID | rehost PID
  local file lease before ids out='' id pid start pidns boot host
  local -a list=()
  file="$(git -C "$1" rev-parse --absolute-git-dir)/locked" || return 1
  lease="$(head -n 1 -- "$file")" || return 1
  before="$lease"
  case "$2" in
    expire) lease="$(sed 's/ heartbeat_epoch=[0-9]*/ heartbeat_epoch=1000/' <<<"$lease")" || return 1 ;;
    restart | rehost)
      ids="${lease##* sessions=}"
      ids="${ids%% *}"
      IFS=, read -r -a list <<<"$ids"
      for id in ${list[@]+"${list[@]}"}; do
        IFS=/ read -r pid start pidns boot host <<<"$id"
        if [ "$pid" = "$3" ]; then
          if [ "$2" = restart ]; then start=Thu_Jan__1_00:00:00_1970; else host=remote.invalid; fi
        fi
        out="${out:+$out,}$pid/$start/$pidns/$boot/$host"
      done
      lease="${lease/ sessions=$ids/ sessions=$out}"
      ;;
    *) echo "session-harness: rewrite=$2 kind=unknown" >&2; return 1 ;;
  esac
  [ "$lease" != "$before" ] || { echo "session-harness: rewrite=$2 change=none" >&2; return 1; }
  printf '%s\n' "$lease" >"$file"
}

# A directory whose ps reports PID absent to the start read and passes every
# other read to the real ps: the absent branch as synthetic ps output.
session_absent_ps() { # DIR PID
  local real
  real="$(command -v ps)" || return 1
  mkdir -p -- "$1" || return 1
  printf '#!/usr/bin/env bash\ncase " $* " in *" -o lstart= -p %s "*) exit 1 ;; esac\nexec %q "$@"\n' "$2" "$real" >"$1/ps"
  chmod +x "$1/ps"
}

# Holds the guard's repository mutex as a running guard holds it, through
# flock where it is on PATH; session_mutex_free lets it go.
session_mutex_hold() { # COMMON_DIR
  exec 7>"$1/kendex-worktree-session-guard.lock"
  flock -x 7
}
session_mutex_free() {
  exec 7>&-
}
