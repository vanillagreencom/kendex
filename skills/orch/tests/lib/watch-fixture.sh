# shellcheck shell=bash
# Launch and identity suites do not judge watch passes. Their sibling watch
# records its real process claim and waits. The watch-specific suites use the
# production reader, including first-launch death detection.
source "$(dirname "${BASH_SOURCE[0]}")/growth-state.sh"
_WATCH_FIXTURE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib" && pwd)/watch-pid.sh"
source "$_WATCH_FIXTURE_LIB"

fixture_watch_neighbor() { # PRIVATE_LAUNCHER
  local dir
  dir="$(dirname "$1")"
  [[ "$dir" == "$TMP_ROOT/"* ]] || { echo 'watch-fixture: launcher=not-private' >&2; return 1; }
  if [[ -f "$dir/oversee-watch" && ! -L "$dir/oversee-watch" ]]; then return 0; fi
  [[ ! -L "$dir/oversee-watch" ]] || rm -- "${dir:?}/oversee-watch"
  cat > "$dir/oversee-watch" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$_WATCH_FIXTURE_LIB"
state="" prev="" args=()
for arg in "\$@"; do
  [[ "\$arg" != -- ]] || break
  args+=("\$arg")
  [[ "\$prev" != --state ]] || state="\$arg"
  prev="\$arg"
done
[[ -n "\$state" ]]
if watch_pid_live "\$state"; then watch_stop "\$WATCH_PID" "\$state"; fi
watch_pid_write "\$state" "\${TMUX_PANE:-none}" "\${OVERSEE_WATCH_ORIGIN:-hand}" "\$0" "\${args[@]}"
child=""
finish() {
  watch_pid_release "\$state"
  [[ -z "\$child" ]] || kill -TERM "\$child" 2>/dev/null || true
  [[ -z "\$child" ]] || wait "\$child" 2>/dev/null || true
  exit 0
}
trap finish TERM INT
sleep 100000 &
child=\$!
wait "\$child"
EOF
  chmod +x "$dir/oversee-watch"
}

fixture_watch_stop() { # STATE
  local rc=0
  watch_pid_live "$1" || rc=$?
  case "$rc" in
    0) watch_stop "$WATCH_PID" "$1" ;;
    1) ;;
    *) return "$rc" ;;
  esac
}
