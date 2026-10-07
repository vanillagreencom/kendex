#!/usr/bin/env bash
# Single-pass fleet writes use --state even outside ORCH_STATE_DIR.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/oversee-watch-harness.sh"

FIXTURE_HOST="$REPO_ROOT/skills/orch/tests/fixtures/lane-host"
CLOSE_SCRIPTS="$(mutant_scripts close/orch lane-mail)" || exit 1
cat > "$CLOSE_SCRIPTS/lane-mail" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
mkdir -p "$TMP_ROOT/close/linear/scripts"
cat > "$TMP_ROOT/close/linear/scripts/linear.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '{"state":"Done","state_type":"completed"}\n'
EOF
chmod +x "$TMP_ROOT/close/linear/scripts/linear.sh"
rm -- "$CLOSE_SCRIPTS/lane-host"
cat > "$CLOSE_SCRIPTS/lane-host" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == stop ]]; then
  printf 'lane-host-ssh: stop-worktree-removed item=%s\n' "$3" >&2
  exit 4
fi
exec "$REAL_LANE_HOST" "$@"
EOF
chmod +x "$CLOSE_SCRIPTS/lane-host"

close_in_fleet() { # NAME
  local fleet orch root rc=0
  new_case "$1"
  fleet="$STUB_DIR/fleet" orch="$STUB_DIR/orch" root="$STUB_DIR/remote"
  mkdir -p "$fleet" "$orch" "$root/srv/clone/tmp/lane-mail/issue-2" "$root/srv/lane/issue-2"
  printf '{"triaged":[]}\n' > "$orch/workflow-state-oversee.json"
  printf '{"triaged":[],"lanes":[{"item":"issue-2","tracker":"linear","harness":"codex","window":"gh-2","host":"%s","mail_root":"/srv/lane/issue-2","status":"running"}]}\n' \
    "$FIXTURE_HOST" > "$fleet/workflow-state-oversee.json"
  printf 'gitdir: /srv/clone/.git/worktrees/issue-2\n' > "$root/srv/lane/issue-2/.git"
  printf '{}\n' > "$root/srv/clone/tmp/workflow-state-issue-2.json"
  printf '[{"number":2,"headRefName":"issue-2","mergedAt":"2026-09-14T10:00:00Z"}]\n' > "$STUB_DIR/merged.json"
  printf 'bash\n' > "$STUB_DIR/cmd-gh-2.txt"
  set -- ORCH_STATE_DIR="$orch" ORCH_LANE_HOST="$FIXTURE_HOST" \
    LANE_HOST_STUB_LOG="$STUB_DIR/host.log" LANE_HOST_STUB_DIR="$root" \
    OVERSEE_WATCH_WORKFLOW_STATE="$REPO_ROOT/skills/orch/scripts/workflow-state" \
    OVERSEE_WATCH_LANE_CLOSE="$CLOSE_SCRIPTS/lane-close"
  run_watch "$@" LANE_HOST_STUB_HARNESS_STATE=running -- --max-loops 1 \
    --state "$fleet/workflow-state-oversee.json" > "$STUB_DIR/first.out" 2> "$STUB_DIR/first.err" || return
  rm -rf -- "${root:?}/srv/lane/issue-2"
  run_watch "$@" LANE_HOST_STUB_HARNESS_STATE=exited -- --max-loops 1 \
    --state "$fleet/workflow-state-oversee.json" > "$STUB_DIR/second.out" 2> "$STUB_DIR/second.err" || rc=$?
  printf 'rc=%s status=%s closes=%s default=%s\n' "$rc" \
    "$(jq -r '.lanes[0].status' "$fleet/workflow-state-oversee.json")" \
    "$(awk '/^close --item issue-2 / { n++ } END { print n+0 }' "$STUB_DIR/host.log")" \
    "$(jq -c . "$orch/workflow-state-oversee.json")"
}

assert_eq "$(close_in_fleet correct)" 'rc=0 status=done closes=1 default={"triaged":[]}' \
  'a single pass closes the hosted lane and its fleet record outside ORCH_STATE_DIR' "$TMP_ROOT/cases/correct/second.err"
MUTANT="$(mutant_scripts wrong-dir/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/wrong-dir/github"
mutate_file "$MUTANT" 'FLEET_STATE_DIR="${STATE_FILE%/*}"' 'FLEET_STATE_DIR="$WORKFLOW_STATE_DIR"'
assert_eq "$(WATCH_BIN="$MUTANT" close_in_fleet wrong)" 'rc=2 status=running closes=0 default={"triaged":[]}' \
  'control: using ORCH_STATE_DIR leaves the lane and fleet record open'

source "$(dirname "${BASH_SOURCE[0]}")/lib/overseer-watch-case.sh"
overseer_in_fleet() { # NAME
  local fleet orch state
  overseer_case "$1" idle
  fleet="$STUB_DIR/fleet" orch="$STUB_DIR/orch"
  mkdir -p "$fleet" "$orch"
  printf '{"triaged":[]}\n' > "$orch/workflow-state-oversee.json"
  printf '{"triaged":[]}\n' > "$fleet/workflow-state-oversee.json"
  state="$fleet/workflow-state-oversee.json"
  [[ "${2:-absolute}" != relative ]] || state="../cases/$1/fleet/workflow-state-oversee.json"
  run_watch TMUX_PANE="$PANE" ORCH_STATE_DIR="$orch" \
    OVERSEE_WATCH_SUCCEED="$TMP_ROOT/bin/succeed-stub.sh" \
    OVERSEE_WATCH_WORKFLOW_STATE="$REPO_ROOT/skills/orch/scripts/workflow-state" \
    -- --max-loops 1 --state "$state" > "$STUB_DIR/out" 2> "$STUB_DIR/err" || return
  printf 'fleet=%s default=%s\n' \
    "$(jq -r '.overseer.pane // "none"' "$fleet/workflow-state-oversee.json")" \
    "$(jq -r '.overseer.pane // "none"' "$orch/workflow-state-oversee.json")"
}
assert_eq "$(overseer_in_fleet overseer_correct)" 'fleet=%9 default=none' \
  'a single pass records the overseer in the supplied fleet state' "$TMP_ROOT/cases/overseer_correct/err"
assert_eq "$(overseer_in_fleet overseer_relative relative)" 'fleet=%9 default=none' \
  'a relative --state path selects the directory from the watch working directory' "$TMP_ROOT/cases/overseer_relative/err"
mutate_file "$MUTANT" 'WORKFLOW_STATE_ARGS=(--state-dir "$FLEET_STATE_DIR")' \
  'WORKFLOW_STATE_ARGS=(--state-dir "$WORKFLOW_STATE_DIR")'
assert_eq "$(WATCH_BIN="$MUTANT" overseer_in_fleet overseer_wrong)" 'fleet=none default=%9' \
  'control: the old overseer arguments write the session into the default state'

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
