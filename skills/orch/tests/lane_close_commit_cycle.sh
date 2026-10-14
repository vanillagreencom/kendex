#!/usr/bin/env bash
# Surface: lane-close. Inputs: scripts/lane-close, scripts/lib/, linear/scripts/lib/.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TMP_ROOT="$(mktemp -d)" || { echo 'lane-close-commit: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'lane-close-commit: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'lane-close-commit: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
SCRIPTS="$TMP_ROOT/skills/orch/scripts"
mkdir -p "$SCRIPTS" "$TMP_ROOT/skills/linear/scripts" "$TMP_ROOT/skills/mailbox/scripts" "$TMP_ROOT/bin"
cp -R "$TEST_DIR/../scripts/lib" "$SCRIPTS/lib"
cp -R "$TEST_DIR/../../linear/scripts/lib" "$TMP_ROOT/skills/linear/scripts/lib"
cp "$TEST_DIR/../scripts/lane-close" "$SCRIPTS/lane-close"

export COMMIT_CLOSE_ROOT="$TMP_ROOT"
export PATH="$TMP_ROOT/bin:$PATH"
cat > "$SCRIPTS/workflow-state" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$COMMIT_CLOSE_ROOT/state-calls"
[[ "${1:-}" != --state-dir ]] || shift 2
verb="$1"; shift
[[ "$verb" != remove ]] || exit 0
[[ "$1" == oversee ]]; shift
case "$verb" in
  get) jq "$1" "$COMMIT_CLOSE_ROOT/state" ;;
  update)
    jq "$@" "$COMMIT_CLOSE_ROOT/state" > "$COMMIT_CLOSE_ROOT/next"
    mv "$COMMIT_CLOSE_ROOT/next" "$COMMIT_CLOSE_ROOT/state" ;;
  *) exit 2 ;;
esac
EOF
cat > "$TMP_ROOT/skills/linear/scripts/linear.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$COMMIT_CLOSE_ROOT/tracker-calls"
[[ "$1 $2" == 'issues get' ]] || exit 2
printf '{"state_type":"%s"}\n' "${COMMIT_CLOSE_ITEM_STATE:-started}"
EOF
cat > "$TMP_ROOT/skills/mailbox/scripts/lane-mail" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == pending ]] || exit 2
EOF
cat > "$SCRIPTS/lane-host" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$COMMIT_CLOSE_ROOT/host-calls"
case "$1" in
  capabilities) printf 'kind=ssh\tstop=verb\tpane=local\n' ;;
  status) printf 'running\n' ;;
  cat)
    [[ "$COMMIT_CLOSE_WHERE" == standing ]] || exit 2
    printf 'gitdir: /host/.git/worktrees/ken-1\n' ;;
  touch) : ;;
  stop) printf 'lane-host: stop-worktree-removed item=KEN-1\n' >&2; exit 4 ;;
  close) printf 'closed item=KEN-1\n' ;;
  *) exit 2 ;;
esac
EOF
cat > "$TMP_ROOT/bin/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$COMMIT_CLOSE_ROOT/tmux-calls"
case "$1" in
  list-panes)
    if [[ "${*: -1}" == '#{pane_id}' ]]; then printf '%%7\n'
    else printf 'fleet\tKEN-1\t%%7\t%s\tpython\n' "$$"; fi ;;
  capture-pane)
    if [[ "$COMMIT_CLOSE_ACTIVITY" == idle ]]; then printf '\342\235\257\302\240\n'
    else printf 'esc to interrupt\n'; fi ;;
  kill-window) : ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$SCRIPTS/lane-close" "$SCRIPTS/workflow-state" "$SCRIPTS/lane-host" \
  "$TMP_ROOT/skills/linear/scripts/linear.sh" "$TMP_ROOT/skills/mailbox/scripts/lane-mail" "$TMP_ROOT/bin/tmux"

run_row() { # SCRIPT CYCLE WHERE ACTIVITY
  local rc=0 live=0 plain=0 merged=0 kept=0
  export COMMIT_CLOSE_WHERE="$3" COMMIT_CLOSE_ACTIVITY="$4"
  : > "$TMP_ROOT/state-calls"; : > "$TMP_ROOT/tracker-calls"
  : > "$TMP_ROOT/host-calls"; : > "$TMP_ROOT/tmux-calls"
  jq -n --argjson cycle "$2" '{lanes:[{item:"KEN-1",tracker:"linear",harness:"claude",
    window:"KEN-1",host:"/host",mail_root:"/host/worktree",status:"running",cycle:$cycle}]}' > "$TMP_ROOT/state"
  "$1" --state-dir "$TMP_ROOT" KEN-1 > "$TMP_ROOT/out" 2> "$TMP_ROOT/err" || rc=$?
  grep -Eq '^lane-close: lane-live item=KEN-1 state=(idle|working) pane=%7$' "$TMP_ROOT/err" && live=1
  grep -Fxq 'close --item KEN-1' "$TMP_ROOT/host-calls" && plain=1
  grep -Fxq 'close --item KEN-1 --merged' "$TMP_ROOT/host-calls" && merged=1
  grep -Fxq 'lane-close: item-files-kept item=KEN-1 cause=open' "$TMP_ROOT/out" && kept=1
  RESULT="rc=$rc live=$live plain=$plain merged=$merged kept=$kept status=$(jq -r '.lanes[0].status' "$TMP_ROOT/state")"
  assert_not_contains "$(cat "$TMP_ROOT/tracker-calls")" 'issues update' 'close leaves acceptance on the open item'
  if [[ "${COMMIT_CLOSE_ITEM_STATE:-started}" == started ]]; then
    assert_not_contains "$(cat "$TMP_ROOT/state-calls")" 'remove KEN-1' 'close retains the item files'
  fi
}

COMMIT='{"commit":"ba26ffe746dc0a3dea6f937c3dff02cbc92bcaea","stamps":{"merged":"2026-10-14T17:00:00Z"}}'
CLOSED='rc=0 live=0 plain=1 merged=0 kept=1 status=done'
REFUSED='rc=1 live=1 plain=0 merged=0 kept=0 status=running'
# cycle|worktree|activity|expected
for row in \
  "$COMMIT|gone|idle|$CLOSED" \
  "$COMMIT|standing|idle|$REFUSED" \
  "$COMMIT|gone|working|$REFUSED" \
  '{"pr":7}|gone|idle|'"$CLOSED" \
  '{"pr":7}|standing|idle|'"$REFUSED" \
  '{"commit":"ba26ffe746dc0a3dea6f937c3dff02cbc92bcaea","stamps":{"merged":null}}|gone|idle|'"$REFUSED"; do
  IFS='|' read -r cycle where activity want <<< "$row"
  run_row "$SCRIPTS/lane-close" "$cycle" "$where" "$activity"
  assert_eq "$RESULT" "$want" "cycle=$cycle worktree=$where activity=$activity" "$TMP_ROOT/err"
done

# item_merged reads the same recorded cycle after the tracker completes the item.
export COMMIT_CLOSE_ITEM_STATE=completed
run_row "$SCRIPTS/lane-close" "$COMMIT" gone idle
assert_eq "$RESULT" 'rc=0 live=0 plain=0 merged=1 kept=0 status=done' \
  'completed direct-push delivery also reaches the existing merged archive route' "$TMP_ROOT/err"
unset COMMIT_CLOSE_ITEM_STATE

# The former PR-only reading must reach lane-live on the commit-and-gone row.
python3 - "$SCRIPTS/lane-close" "$SCRIPTS/lane-close-pr-only" <<'PY'
import pathlib
import sys
source = pathlib.Path(sys.argv[1]).read_text()
start = source.index('record_merged() {')
end = source.index('\n}', start) + 2
old = source[start:end]
assert source.count(old) == 1
changed = source.replace(old, 'record_merged() { jq -e \'.cycle.pr? | numbers\' <<<"$record" >/dev/null 2>&1; }')
assert changed != source
pathlib.Path(sys.argv[2]).write_text(changed)
PY
chmod +x "$SCRIPTS/lane-close-pr-only"
run_row "$SCRIPTS/lane-close-pr-only" "$COMMIT" gone idle
assert_eq "$RESULT" "$REFUSED" 'control: PR-only reading refuses the delivered commit cycle' "$TMP_ROOT/err"
export COMMIT_CLOSE_ITEM_STATE=completed
run_row "$SCRIPTS/lane-close-pr-only" "$COMMIT" gone idle
assert_eq "$RESULT" 'rc=0 live=0 plain=1 merged=0 kept=0 status=done' \
  'control: PR-only reading also misses delivered commits in item_merged' "$TMP_ROOT/err"
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
