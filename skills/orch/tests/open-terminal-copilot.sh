#!/usr/bin/env bash
# Tests for the Copilot CLI commands open-terminal builds: the kickoff, whose
# brief is the value of `-i`, and the relaunch, which resumes the lane's own
# session by the id its session record names, found by the directory that
# record names. Also the account a named copilot lane is launched under, which
# lib/lane-launch.sh decides.
#
# Each launch runs a byte-identical copy of open-terminal inside a temp git
# repo, so `git rev-parse --show-toplevel` resolves to a hermetic PROJECT_ROOT,
# with the worktree CLI and gh stubbed and ghostty stubbed to capture the
# composed command it would launch.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# An inherited or configured lane host would turn these local launches into
# hosted ones; the caller environment outranks project settings.
export ORCH_LANE_HOST=local
# shellcheck source=lib/shared-skill-libs.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/shared-skill-libs.sh"
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT
# The account these launches read their session store from: LANES_HOME's
# default copilot home, with COPILOT_HOME pinned empty so the developer's own
# account is never scanned.
FLEET_HOME="$TMP_ROOT/fleet-home"
mkdir -p "$FLEET_HOME"
LAUNCH_ENV=(LANES_HOME="$FLEET_HOME" COPILOT_HOME=)

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
cat > "$BIN/ghostty" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${!#}" > "$OT_CAPTURE"
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/gh"
chmod +x "$BIN/ghostty" "$BIN/gh"
export TERMINAL=ghostty

# Stub worktree CLI: `create <item>` makes and prints a temp dir; `exists`
# answers nothing, so a relaunch takes the bare create.
STUB="$TMP_ROOT/worktree-stub"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "create" ]]; then
  d="$TMP_ROOT/wt/\${2:-unknown}"
  mkdir -p "\$d"
  [[ -d "\$d/.git" ]] || git init -q "\$d"
  printf '%s\n' "\$d"
  exit 0
fi
exit 1
EOF
chmod +x "$STUB"

# stage DIR — a copy of the orch scripts in a git repo of its own.
stage() {
  mkdir -p "$1/scripts"
  cp -R "$SCRIPTS_DIR/." "$1/scripts/"
  orch_fixture_shared_libs "$1"
  git -C "$1" init -q
}
REPO="$TMP_ROOT/repo"
stage "$REPO"

# launch NAME ARGS... — the command CC's launch composed, in CMD, or empty with
# its stderr in ERR. ROW_ENV holds assignments a row adds to LAUNCH_ENV.
CMD="" ERR=""
ROW_ENV=()
launch() { # NAME ARGS...
  local name="$1" i rc=0
  shift
  rm -f -- "$TMP_ROOT/$name.cap"
  ( cd "$REPO" && env "${LAUNCH_ENV[@]}" ${ROW_ENV[@]+"${ROW_ENV[@]}"} OT_CAPTURE="$TMP_ROOT/$name.cap" ORCH_STATE_DIR="$TMP_ROOT/state" \
      PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "${OT:-$REPO/scripts/open-terminal}" --ghostty "$@" ) \
    >/dev/null 2>"$TMP_ROOT/$name.err" || rc=$?
  ERR="$(cat "$TMP_ROOT/$name.err")"
  CMD=""
  [[ "$rc" -eq 0 ]] || return 0
  # The stubbed terminal is started in the background, so its capture lands
  # after open-terminal itself has exited.
  for i in $(seq 1 50); do
    [[ -s "$TMP_ROOT/$name.cap" ]] && break
    sleep 0.1
  done
  CMD="$(cat "$TMP_ROOT/$name.cap" 2>/dev/null || true)"
}

FLAGS='--model claude-opus-5 --reasoning-effort high --allow-all'
# The words every copilot command leads with, quoted per token as start_cmd
# quotes each flag: the autopilot launch settings, then the question-off word,
# then the caller's flags.
LEAD="'--autopilot' '--max-autopilot-continues' '3' '--no-ask-user' '--model' 'claude-opus-5' '--reasoning-effort' 'high' '--allow-all'"

echo "=== a copilot lane starts with its brief as the value of -i ==="
launch linear --harness copilot --launch-flags "$FLAGS" cc-737
assert_contains "$CMD" "copilot $LEAD -i 'Read .agents/skills/orch/SKILL.md and execute the orch start workflow for CC-737'" \
  "linear:copilot emits the prose kickoff after its launch settings, question-off word and flags"
assert_not_contains "$CMD" '$' "the linear:copilot command contains no \$"
launch github --tracker github --repo acme/widgets --harness copilot --launch-flags "$FLAGS" 42
assert_contains "$CMD" "copilot $LEAD -i 'Read .agents/skills/orch/SKILL.md and execute the orch start workflow for github acme/widgets#42'" \
  "github:copilot emits the same kickoff carrying repo#item"

echo "=== a copilot relaunch resumes the session whose record names the lane's worktree ==="
# session ID DIR STAMP [HOME] — a session record as Copilot CLI 1.0.88 writes
# it, under the account HOME (the default copilot home by default), its file
# dated STAMP in touch -t form, which BSD and GNU touch both take.
session() { # ID DIR STAMP [HOME]
  local d="${4:-$FLEET_HOME/.copilot}/session-state/$1"
  mkdir -p "$d"
  printf 'id: %s\ncwd: %s\ngit_root: %s\nbranch: cc-738\nclient_name: github/cli\nuser_named: false\n' "$1" "$2" "$2" > "$d/workspace.yaml"
  touch -t "$3" "$d/workspace.yaml"
}
WT="$TMP_ROOT/wt/CC-738"
session 11111111-aaaa-4aaa-8aaa-111111111111 "$WT" 200001010000
session 22222222-bbbb-4bbb-8bbb-222222222222 "$WT" 200001010100
session 33333333-cccc-4ccc-8ccc-333333333333 "$TMP_ROOT/wt/CC-999" 200001010200
RESUME_LINE="'Resume the orch workflow for CC-738 from where this session stopped. Run .agents/skills/orch/scripts/lane-mail inbox --item CC-738 first and act on every directive it prints, then re-arm your mailbox monitor on .agents/skills/orch/scripts/lane-mail watch --once --item CC-738 as a background command.'"
launch relaunch --relaunch --harness copilot --launch-flags "$FLAGS" CC-738
assert_contains "$CMD" "copilot $LEAD --resume=22222222-bbbb-4bbb-8bbb-222222222222 -i $RESUME_LINE" \
  "the newest session in the lane's own worktree is resumed, its continuation line re-arming the --once monitor"
launch relaunch-none --relaunch --harness copilot --launch-flags "$FLAGS" CC-740
assert_contains "$CMD" "copilot $LEAD -i 'Read .agents/skills/orch/SKILL.md and execute the orch start workflow for CC-740'" \
  "a relaunch whose worktree no session record names renders the fresh brief"
# The store is the account the launch runs on: a named lane's, then the
# ambient COPILOT_HOME, and only then the default home. Each row's records sit
# in that store alone.
session 44444444-dddd-4ddd-8ddd-444444444444 "$TMP_ROOT/wt/CC-741" 200001010300 "$TMP_ROOT/.1copilot"
launch relaunch-lane --relaunch --harness copilot --lane "$TMP_ROOT/.1copilot" --launch-flags "$FLAGS" CC-741
assert_contains "$CMD" "--resume=44444444-dddd-4ddd-8ddd-444444444444 -i" \
  "a relaunch under --lane resumes from that account's own session store"
session 55555555-eeee-4eee-8eee-555555555555 "$TMP_ROOT/wt/CC-742" 200001010400 "$TMP_ROOT/.envcopilot"
ROW_ENV=(COPILOT_HOME="$TMP_ROOT/.envcopilot")
launch relaunch-env --relaunch --harness copilot --launch-flags "$FLAGS" CC-742
ROW_ENV=()
assert_contains "$CMD" "--resume=55555555-eeee-4eee-8eee-555555555555 -i" \
  "a relaunch naming no lane resumes from the store the ambient COPILOT_HOME names"

echo "=== a named copilot lane runs under COPILOT_HOME ==="
(
  set +u
  # shellcheck source=../scripts/lib/lane-launch.sh
  source "$SCRIPTS_DIR/lib/lane-launch.sh"
  printf '#!/bin/sh\n' > "$BIN/1copilot"
  chmod +x "$BIN/1copilot"
  PATH="$BIN:$PATH"
  printf '%s|%s|%s\n' "$(lane_env_prefix copilot "$TMP_ROOT/.1copilot")" \
    "$(lane_launch_form 'copilot --model m' copilot "$TMP_ROOT/.1copilot")" \
    "$(lane_launch_form 'copilot --model m' copilot "$TMP_ROOT/.work")"
) > "$TMP_ROOT/account.out"
assert_eq "$(cat "$TMP_ROOT/account.out")" "COPILOT_HOME=$TMP_ROOT/.1copilot|launcher:$BIN/1copilot|prefix" \
  "the account variable is COPILOT_HOME, and a launcher named for the account's directory is the whole selector"

echo "=== must-fail controls ==="
# The start arm renamed: the harness no longer has a command to start.
stage "$TMP_ROOT/arm-ctrl"
mutate_file "$TMP_ROOT/arm-ctrl/scripts/open-terminal" '    linear:copilot)  printf' '    linear:copilot-x)  printf'
OT="$TMP_ROOT/arm-ctrl/scripts/open-terminal" launch arm-ctrl --harness copilot --launch-flags "$FLAGS" cc-737
assert_eq "${CMD:-none} $(grep -c '^open-terminal: harness-unsupported harness=copilot' <<<"$ERR" || true)" "none 1" \
  "control: without its start arm a linear copilot launch is refused as harness-unsupported"
# The record's directory read under another key: no record names the worktree,
# and the relaunch starts afresh.
stage "$TMP_ROOT/cwd-ctrl"
mutate_file "$TMP_ROOT/cwd-ctrl/scripts/lib/lane-relaunch.sh" 'index($0, "cwd: ") == 1' 'index($0, "cwd:: ") == 1'
OT="$TMP_ROOT/cwd-ctrl/scripts/open-terminal" launch cwd-ctrl --relaunch --harness copilot --launch-flags "$FLAGS" CC-738
assert_contains "$CMD" "copilot $LEAD -i 'Read .agents/skills/orch/SKILL.md and execute the orch start workflow for CC-738'" \
  "control: without the record's directory the relaunch resumes nothing and starts afresh"
# The named lane's store cut from the lookup: the --lane relaunch scans the
# default home, which holds no record of its worktree, and starts afresh.
stage "$TMP_ROOT/lane-store-ctrl"
mutate_file "$TMP_ROOT/lane-store-ctrl/scripts/lib/lane-relaunch.sh" \
  '[[ "${LANE_ENV%%=*}" != COPILOT_HOME ]] || config="${LANE_ENV#*=}"' ':'
OT="$TMP_ROOT/lane-store-ctrl/scripts/open-terminal" launch lane-store-ctrl --relaunch --harness copilot --lane "$TMP_ROOT/.1copilot" --launch-flags "$FLAGS" CC-741
assert_contains "$CMD" "'--allow-all' -i 'Read .agents/skills/orch/SKILL.md and execute the orch start workflow for CC-741'" \
  "control: without the named lane's store a --lane relaunch resumes nothing"
# The account rules, each cut from a private copy of the library: the copilot
# variable, then copilot's admission to the launcher form.
account_ctrl() { # NAME OLD NEW — the copy's answers in $TMP_ROOT/NAME.out
  stage "$TMP_ROOT/$1"
  mutate_file "$TMP_ROOT/$1/scripts/lib/lane-launch.sh" "$2" "$3"
  (
    set +u
    # shellcheck source=/dev/null
    source "$TMP_ROOT/$1/scripts/lib/lane-launch.sh"
    PATH="$BIN:$PATH"
    printf '%s|%s\n' "$(lane_env_prefix copilot "$TMP_ROOT/.1copilot")" \
      "$(lane_launch_form 'copilot --model m' copilot "$TMP_ROOT/.1copilot")"
  ) > "$TMP_ROOT/$1.out"
}
account_ctrl prefix-ctrl '    copilot) var=COPILOT_HOME ;;' ''
assert_eq "$(cat "$TMP_ROOT/prefix-ctrl.out")" "CLAUDE_CONFIG_DIR=$TMP_ROOT/.1copilot|launcher:$BIN/1copilot" \
  "control: without its arm a copilot lane is prefixed with the claude variable"
account_ctrl form-ctrl '^(claude|codex|copilot)$' '^(claude|codex)$'
assert_eq "$(cat "$TMP_ROOT/form-ctrl.out")" "COPILOT_HOME=$TMP_ROOT/.1copilot|unchecked" \
  "control: without copilot in the form judge its launcher is never found"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
