#!/usr/bin/env bash
# Surface: lane-close. Inputs: scripts/lane-close, scripts/lib/*.sh, github/scripts/lib/.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/shared-skill-libs.sh"

TEST_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TMP_ROOT="$(mktemp -d)" || { echo 'lane-close-merged: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'lane-close-merged: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'lane-close-merged: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
SCRIPTS="$TMP_ROOT/skills/orch/scripts"
mkdir -p "$SCRIPTS" "$TMP_ROOT/skills/worktree/scripts" "$TMP_ROOT/skills/mailbox/scripts" "$TMP_ROOT/bin"
cp "$TEST_DIR/../scripts/lane-close" "$SCRIPTS/lane-close"
cp -R "$TEST_DIR/../scripts/lib" "$SCRIPTS/lib"
orch_fixture_shared_libs "$TMP_ROOT/skills/orch"
export MERGED_FIXTURE_ROOT="$TMP_ROOT"
export PATH="$TMP_ROOT/bin:$PATH"

cat > "$SCRIPTS/workflow-state" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root="$MERGED_FIXTURE_ROOT"
case "$1" in
  get) jq "$3" "$root/state" ;;
  remove) printf '%s\n' "$*" >> "$root/effects" ;;
  update)
    shift 2
    jq "$@" "$root/state" > "$root/next"
    mv "$root/next" "$root/state" ;;
  *) exit 97 ;;
esac
EOF
cat > "$SCRIPTS/lane-host" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root="$MERGED_FIXTURE_ROOT"
case "$1" in
  capabilities) printf 'kind=ssh\tstop=verb\tpane=local\n' ;;
  stop)
    printf '%s\n' "$*" >> "$root/effects"
    [[ "$MERGED_STOP_RC" == 0 ]] || exit "$MERGED_STOP_RC"
    : > "$root/exited"
    printf 'stopped item=issue-1 processes=1\n' ;;
  close)
    printf '%s\n' "$*" >> "$root/effects"
    exit "$MERGED_CLOSE_RC" ;;
  *) exit 97 ;;
esac
EOF
cat > "$TMP_ROOT/skills/mailbox/scripts/lane-mail" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == pending ]] || exit 97
printf '[]\n'
EOF
cat > "$TMP_ROOT/skills/worktree/scripts/worktree" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == merged ]] || exit 97
exit "$MERGED_PROOF_RC"
EOF
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root="$MERGED_FIXTURE_ROOT"
printf '%s\n' "$*" >> "$root/reads"
[[ "$MERGED_READER_RC" == 0 ]] || exit "$MERGED_READER_RC"
if [[ "$1 $2" == 'pr view' ]]; then printf 'OPEN\n'; exit 0; fi
[[ "$1 $2" == 'issue view' ]] || exit 97
[[ "$*" == *'--json state,stateReason --jq '* ]] || exit 97
jq -r '.state + " " + (.stateReason // "")' "$root/payload"
EOF
cat > "$TMP_ROOT/bin/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root="$MERGED_FIXTURE_ROOT"
case "$1" in
  list-panes)
    [[ ! -f "$root/exited" ]] || exit 0
    case "${*: -1}" in
      '#{pane_id}') printf '%%7\n' ;;
      '#{pane_id} #{pane_pid} #{pane_current_command}') printf '%%7 1 claude\n' ;;
      *) printf 'kendex\tissue-1\t%%7\t1\tclaude\n' ;;
    esac ;;
  capture-pane) printf '\342\235\257\302\240\n' ;;
  *) printf '%s\n' "$*" >> "$root/effects"; exit 97 ;;
esac
EOF
chmod +x "$SCRIPTS/lane-close" "$SCRIPTS/workflow-state" "$SCRIPTS/lane-host" \
  "$TMP_ROOT/skills/mailbox/scripts/lane-mail" "$TMP_ROOT/skills/worktree/scripts/worktree" "$TMP_ROOT/bin/gh" "$TMP_ROOT/bin/tmux"

run_case() { # SCRIPT PAYLOAD READER STOP CLOSE PROOF [probe|close|retained]
  local script="$1" mode="${7:-close}" args=()
  export MERGED_READER_RC="$3" MERGED_STOP_RC="$4" MERGED_CLOSE_RC="$5" MERGED_PROOF_RC="$6"
  printf '%s\n' "$2" > "$TMP_ROOT/payload"
  printf '%s\n' '{"lanes":[{"item":"issue-1","tracker":"github","repo":"owner/repo","harness":"claude","window":"issue-1","mail_root":"/srv/worktree","host":"fixture","status":"running"}]}' > "$TMP_ROOT/state"
  : > "$TMP_ROOT/effects"
  : > "$TMP_ROOT/reads"
  rm -f -- "$TMP_ROOT/exited"
  if [[ "$mode" == retained ]]; then
    jq '.lanes[0].pending_pr = {repo:"owner/repo",pr:2}' "$TMP_ROOT/state" > "$TMP_ROOT/next"
    mv "$TMP_ROOT/next" "$TMP_ROOT/state"
  fi
  [[ "$mode" == close ]] || args+=(--terminal-state)
  RC=0
  OUT="$("$script" ${args[@]+"${args[@]}"} issue-1 2> "$TMP_ROOT/err")" || RC=$?
}

# Payload, reader, stop, close, merge proof, terminal answer, close outcome.
while IFS='|' read -r name payload reader stop close proof terminal expected; do
  run_case "$SCRIPTS/lane-close" "$payload" "$reader" "$stop" "$close" "$proof" probe
  assert_eq "rc=$RC out=$OUT effects=$(cat "$TMP_ROOT/effects")" "$terminal effects=" "$name terminal probe" "$TMP_ROOT/err"
  run_case "$SCRIPTS/lane-close" "$payload" "$reader" "$stop" "$close" "$proof"
  effects="$(tr '\n' ';' < "$TMP_ROOT/effects")"
  assert_eq "rc=$RC status=$(jq -r '.lanes[0].status' "$TMP_ROOT/state") effects=$effects" "$expected" "$name idle close" "$TMP_ROOT/err"
done <<'EOF'
merged absent reason|{"state":"MERGED"}|0|0|0|0|rc=0 out=completed|rc=0 status=done effects=stop --item issue-1 --harness claude;remove issue-1;close --item issue-1 --merged;
merged empty reason|{"state":"MERGED","stateReason":""}|0|0|0|0|rc=0 out=completed|rc=0 status=done effects=stop --item issue-1 --harness claude;remove issue-1;close --item issue-1 --merged;
closed completed|{"state":"CLOSED","stateReason":"COMPLETED"}|0|0|0|0|rc=0 out=completed|rc=0 status=done effects=stop --item issue-1 --harness claude;remove issue-1;close --item issue-1 --merged;
closed not planned|{"state":"CLOSED","stateReason":"NOT_PLANNED"}|0|0|0|0|rc=0 out=canceled|rc=0 status=done effects=stop --item issue-1 --harness claude;remove issue-1;close --item issue-1;
closed duplicate|{"state":"CLOSED","stateReason":"DUPLICATE"}|0|0|0|0|rc=0 out=canceled|rc=0 status=done effects=stop --item issue-1 --harness claude;remove issue-1;close --item issue-1;
closed absent reason|{"state":"CLOSED"}|0|0|0|0|rc=0 out=canceled|rc=0 status=done effects=stop --item issue-1 --harness claude;remove issue-1;close --item issue-1;
open absent reason|{"state":"OPEN"}|0|0|0|1|rc=0 out=open|rc=1 status=running effects=
open completed reason|{"state":"OPEN","stateReason":"COMPLETED"}|0|0|0|1|rc=0 out=open|rc=1 status=running effects=
failed reader|{"state":"MERGED"}|9|0|0|0|rc=2 out=|rc=1 status=running effects=
provider stop refused|{"state":"MERGED"}|0|9|0|0|rc=0 out=completed|rc=1 status=running effects=stop --item issue-1 --harness claude;
provider close refused|{"state":"MERGED"}|0|0|9|0|rc=0 out=completed|rc=9 status=running effects=stop --item issue-1 --harness claude;remove issue-1;close --item issue-1 --merged;
merge proof absent|{"state":"MERGED"}|0|0|0|1|rc=0 out=completed|rc=0 status=done effects=stop --item issue-1 --harness claude;remove issue-1;close --item issue-1;
EOF

run_case "$SCRIPTS/lane-close" '{"state":"MERGED"}' 0 0 0 0 retained
assert_eq "rc=$RC out=$OUT effects=$(cat "$TMP_ROOT/effects")" 'rc=0 out=open effects=' 'retained open PR holds the terminal probe' "$TMP_ROOT/err"
assert_not_contains "$(cat "$TMP_ROOT/reads")" 'issue view' 'retained PR hold precedes item read'

# Restore CLOSED-only classification in the disposable production copy.
python3 - "$SCRIPTS/lane-close" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
assert not path.is_symlink()
source = path.read_text()
target = 'if [[ "$state" == MERGED ]]; then ITEM_END=completed; return 0; fi'
assert source.count(target) == 1
changed = source.replace(target, 'if [[ "$state" == CLOSED && "$reason" == COMPLETED ]]; then ITEM_END=completed; return 0; fi')
assert changed != source
path.write_text(changed)
PY
run_case "$SCRIPTS/lane-close" '{"state":"MERGED"}' 0 0 0 0 probe
assert_eq "rc=$RC out=$OUT" 'rc=0 out=open' 'CLOSED-only control rejects the merged completion assertion' "$TMP_ROOT/err"
printf '\npass: %s fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
