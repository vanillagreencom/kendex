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
# shellcheck source=lib/process-table.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/process-table.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
TMP_ROOT="$(mktemp -d)" || { echo "open-terminal-copilot: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "open-terminal-copilot: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "open-terminal-copilot: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
# The account these launches read their session store from: LANES_HOME's
# default copilot home, with COPILOT_HOME pinned empty so the developer's own
# account is never scanned.
FLEET_HOME="$TMP_ROOT/fleet-home"
mkdir -p "$FLEET_HOME"
# HOME is the fleet home too, since every copilot command names the shared
# skills under it, COPILOT_GITHUB_TOKEN a fixture every launched command
# clears, and GH_TOKEN one every launched command keeps.
LAUNCH_ENV=(LANES_HOME="$FLEET_HOME" HOME="$FLEET_HOME" COPILOT_HOME= COPILOT_GITHUB_TOKEN=copilot-fixture GH_TOKEN=gh-fixture)

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
# The harness a wake runs detached, in place of a terminal: its argv lands in
# the capture the same way, and the environment it was handed beside it,
# written first, so a row that waits for the capture finds it whole.
cat > "$BIN/copilot" <<'EOF'
#!/usr/bin/env bash
printf 'COPILOT_ALLOW_ALL=%s COPILOT_SKILLS_DIRS=%s COPILOT_GITHUB_TOKEN=%s GH_TOKEN=%s\n' "${COPILOT_ALLOW_ALL-unset}" \
  "${COPILOT_SKILLS_DIRS-unset}" "${COPILOT_GITHUB_TOKEN-unset}" "${GH_TOKEN-unset}" > "$OT_CAPTURE.env"
printf '%s\n' "copilot $*" > "$OT_CAPTURE"
exit 0
EOF
chmod +x "$BIN/ghostty" "$BIN/gh" "$BIN/copilot"
export TERMINAL=ghostty
# The process table a wake reads, empty unless a row writes one: no process on
# the host running under another user can answer for these lanes.
PROC_BIN="$TMP_ROOT/proc-bin"
proc_table_install "$PROC_BIN"
PROC_TABLE="$TMP_ROOT/proc-table.txt"
PROC_CWD_FILE="$TMP_ROOT/proc-cwd.txt"
PROC_HIDDEN_PIDS=""
export PROC_TABLE PROC_CWD_FILE PROC_HIDDEN_PIDS
proc_table_write "$PROC_TABLE"
proc_cwd_write "$PROC_CWD_FILE"

# Stub worktree CLI: `create <item>` makes and prints a temp dir; `exists`
# answers nothing, so a relaunch takes the bare create; `path` names the dir
# create makes, which a wake reads its worktree from.
STUB="$TMP_ROOT/worktree-stub"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ "\${1:-}" != "path" ]] || { printf '%s\n' "$TMP_ROOT/wt/\${2:-unknown}"; exit 0; }
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
# its stderr in ERR; its stdout in OUT. ROW_ENV holds assignments a row adds to
# LAUNCH_ENV.
CMD="" ERR="" OUT=""
ROW_ENV=()
launch() { # NAME ARGS...
  local name="$1" i rc=0
  shift
  rm -f -- "$TMP_ROOT/$name.cap"
  ( cd "$REPO" && env "${LAUNCH_ENV[@]}" ${ROW_ENV[@]+"${ROW_ENV[@]}"} OT_CAPTURE="$TMP_ROOT/$name.cap" ORCH_STATE_DIR="$TMP_ROOT/state" \
      PATH="$BIN:$PROC_BIN:$PATH" WORKTREE_CLI="$STUB" "${OT:-$REPO/scripts/open-terminal}" --ghostty "$@" ) \
    >"$TMP_ROOT/$name.out" 2>"$TMP_ROOT/$name.err" || rc=$?
  ERR="$(cat "$TMP_ROOT/$name.err")"
  OUT="$(cat "$TMP_ROOT/$name.out")"
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
# quotes each flag: the launch settings, then the question-off word, then the
# caller's flags.
LEAD="'--autopilot' '--max-autopilot-continues' '3' '--context' 'long_context' '--no-auto-update' '--no-ask-user' '--model' 'claude-opus-5' '--reasoning-effort' 'high' '--allow-all'"
# The environment every copilot command carries, ahead of the account, and
# the account a launch naming no lane runs on: the default copilot home.
COP_ENV="env -u COPILOT_GITHUB_TOKEN COPILOT_SKILLS_DIRS='$FLEET_HOME/.agents/skills' COPILOT_ALLOW_ALL=true"
COP_AMBIENT="COPILOT_HOME='$FLEET_HOME/.copilot'"

echo "=== a copilot lane starts with its brief as the value of -i ==="
launch linear --harness copilot --launch-flags "$FLAGS" cc-737
assert_contains "$CMD" "&& $COP_ENV $COP_AMBIENT copilot $LEAD -i 'Read .agents/skills/orch/SKILL.md and execute the orch start workflow for CC-737'" \
  "linear:copilot emits the prose kickoff after its launch settings, question-off word and flags, under its launch environment and the pane's own account"
assert_not_contains "$CMD" '$' "the linear:copilot command contains no \$"
assert_eq "$(grep -c '^open-terminal: launch-trusted .*route=allow-all-env' <<<"$OUT" || true)" "1" \
  "an allow-all launch reports its folder trusted through COPILOT_ALLOW_ALL"
launch github --tracker github --repo acme/widgets --harness copilot --launch-flags "$FLAGS" 42
assert_contains "$CMD" "copilot $LEAD -i 'Read .agents/skills/orch/SKILL.md and execute the orch start workflow for github acme/widgets#42'" \
  "github:copilot emits the same kickoff carrying repo#item"

# A caller's own copy of one launch setting is dropped, whether or not it
# typed the others.
launch dedup --harness copilot --launch-flags "$FLAGS --context long_context" cc-737
assert_eq "$(grep -o "'--context'" <<<"$CMD" | wc -l | tr -d '[:space:]')" "1" \
  "a caller's --context long_context is dropped for the row's own copy, never carried twice"
# A --cmd template is the caller's own command, and it runs under the launch
# environment all the same, on a named account or the default one.
CMD_T="copilot --model claude-opus-5 --reasoning-effort high --allow-all --no-ask-user -i start-{item}"
launch cmd-bare --harness copilot --cmd "$CMD_T" CC-750
assert_contains "$CMD" "&& $COP_ENV $COP_AMBIENT copilot --model claude-opus-5 --reasoning-effort high --allow-all --no-ask-user -i start-CC-750" \
  "a --cmd launch naming no lane carries the launch environment on the default account"
mkdir -p "$TMP_ROOT/.1copilot"
launch cmd-lane --harness copilot --lane "$TMP_ROOT/.1copilot" --cmd "$CMD_T" CC-751
assert_contains "$CMD" "&& $COP_ENV COPILOT_HOME='$TMP_ROOT/.1copilot' copilot --model claude-opus-5 --reasoning-effort high --allow-all --no-ask-user -i start-CC-751" \
  "a --cmd launch under --lane carries the named account and the launch environment"

# Folder trust rides the caller's own allow-all posture: COPILOT_ALLOW_ALL
# approves every tool, so a command naming neither --allow-all nor --yolo sets
# it empty beside the shared skills and keeps its permission prompts.
SKILLS_ONLY="env -u COPILOT_GITHUB_TOKEN COPILOT_SKILLS_DIRS='$FLEET_HOME/.agents/skills' COPILOT_ALLOW_ALL= $COP_AMBIENT"
launch no-allow --harness copilot --launch-flags "--model claude-opus-5 --reasoning-effort high" cc-752
assert_contains "$CMD" "&& $SKILLS_ONLY copilot " \
  "a launch naming no allow-all spelling carries an empty COPILOT_ALLOW_ALL"
assert_eq "$(grep -c '^open-terminal: permission-prompt ' <<<"$ERR" || true)" "1" \
  "and it still warns that the lane can stop at a permission prompt"
assert_eq "$(grep -c '^open-terminal: launch-trusted ' <<<"$OUT" || true)" "0" \
  "and it reports no folder trust, which its empty COPILOT_ALLOW_ALL does not grant"
launch yolo --harness copilot --launch-flags "--model claude-opus-5 --reasoning-effort high --yolo" cc-753
assert_contains "$CMD" "&& $COP_ENV $COP_AMBIENT copilot " "--yolo, the other full allow-all spelling, carries COPILOT_ALLOW_ALL"
launch tools-only --harness copilot --launch-flags "--model claude-opus-5 --reasoning-effort high --allow-all-tools" cc-754
assert_contains "$CMD" "&& $SKILLS_ONLY copilot " \
  "the tools-only --allow-all-tools leaves paths and URLs asking, so it carries an empty COPILOT_ALLOW_ALL"
launch cmd-narrow --harness copilot --cmd "copilot --model claude-opus-5 --reasoning-effort high --no-ask-user -i start-{item}" CC-755
assert_contains "$CMD" "&& $SKILLS_ONLY copilot --model claude-opus-5" \
  "a --cmd template naming no allow-all spelling carries an empty COPILOT_ALLOW_ALL"

echo "=== a copilot relaunch resumes the session whose record names the lane's worktree ==="
# session ID DIR STAMP [HOME [EVENTS]] — a session record as Copilot CLI
# 1.0.88 writes it, under the account HOME (the default copilot home by
# default), its file dated STAMP in touch -t form, which BSD and GNU touch both
# take. EVENTS `none` leaves out the events.jsonl a session that ran a turn
# holds, as one whose sign-in failed before its first event does.
session() { # ID DIR STAMP [HOME [EVENTS]]
  local d="${4:-$FLEET_HOME/.copilot}/session-state/$1"
  mkdir -p "$d"
  printf 'id: %s\ncwd: %s\ngit_root: %s\nbranch: cc-738\nclient_name: github/cli\nuser_named: false\n' "$1" "$2" "$2" > "$d/workspace.yaml"
  [[ "${5:-}" == none ]] || printf '%s\n' '{"type":"session.start"}' > "$d/events.jsonl"
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
# A killed lane's relaunch that died before its first event left a newer
# record with none: the lookup passes it for the session that ran.
session 66666666-ffff-4fff-8fff-666666666666 "$WT" 200001010500 "" none
launch relaunch-eventless --relaunch --harness copilot --launch-flags "$FLAGS" CC-738
assert_contains "$CMD" "copilot $LEAD --resume=22222222-bbbb-4bbb-8bbb-222222222222 -i $RESUME_LINE" \
  "a newer record with no events is passed over for the newest session that ran"
session 77777777-aaaa-4aaa-8aaa-777777777777 "$TMP_ROOT/wt/CC-743" 200001010600 "" none
launch relaunch-only-eventless --relaunch --harness copilot --launch-flags "$FLAGS" CC-743
assert_contains "$CMD" "copilot $LEAD -i 'Read .agents/skills/orch/SKILL.md and execute the orch start workflow for CC-743'" \
  "a worktree whose only record holds no events starts afresh rather than resuming what copilot cannot"
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
assert_contains "$CMD" "&& $COP_ENV COPILOT_HOME='$TMP_ROOT/.1copilot' copilot $LEAD --resume=" \
  "the resume runs under the named account and the launch environment"
session 55555555-eeee-4eee-8eee-555555555555 "$TMP_ROOT/wt/CC-742" 200001010400 "$TMP_ROOT/.envcopilot"
ROW_ENV=(COPILOT_HOME="$TMP_ROOT/.envcopilot")
launch relaunch-env --relaunch --harness copilot --launch-flags "$FLAGS" CC-742
ROW_ENV=()
assert_contains "$CMD" "--resume=55555555-eeee-4eee-8eee-555555555555 -i" \
  "a relaunch naming no lane resumes from the store the ambient COPILOT_HOME names"

echo "=== a relaunch of a retired session, or onto another harness, starts afresh ==="
# handoff ITEM JSON — the item's workflow state, where every launch here reads
# it: the `handoff` record a lane writes before it ends its session.
handoff() { mkdir -p "$TMP_ROOT/state"; printf '%s\n' "$2" > "$TMP_ROOT/state/workflow-state-$1.json"; }
handoff CC-738 '{"handoff":{"merged":[],"remaining":["open the PR"],"written_at":"2000-01-01T06:00:00Z"}}'
launch retired --relaunch --harness copilot --launch-flags "$FLAGS" CC-738
assert_contains "$CMD" "copilot $LEAD -i 'Read .agents/skills/orch/SKILL.md and execute the orch start workflow for CC-738'" \
  "a standing handoff record retires the lane's session: the relaunch renders the start brief, which continues from the record"
handoff CC-738 '{"handoff":{"merged":[],"remaining":["open the PR"],"written_at":"2000-01-01T06:00:00Z","resumed_at":946713600}}'
launch retired-resumed --relaunch --harness copilot --launch-flags "$FLAGS" CC-738
assert_contains "$CMD" "--resume=22222222-bbbb-4bbb-8bbb-222222222222 -i" \
  "a record a relaunched lane already resumed from retires nothing: the session it started resumes"
handoff CC-738 '{"handoff":'
launch retired-unreadable --relaunch --harness copilot --launch-flags "$FLAGS" CC-738
assert_eq "${CMD:-none} $(grep -c "^open-terminal: handoff-unreadable item=CC-738 state=$TMP_ROOT/state/workflow-state-CC-738.json\$" <<<"$ERR" || true)" "none 1" \
  "a state file the judge cannot read refuses the relaunch rather than resuming a session it may have retired"
rm -f -- "${TMP_ROOT:?}/state/workflow-state-CC-738.json"
# A relaunch whose stderr is a regular file keeps what that file already held:
# the retirement read leaves the relaunch's own stderr as it found it.
# stderr_kept SCRIPT — 1 where the line written before the relaunch survives
# and the relaunch still renders its command, 0 otherwise.
stderr_kept() {
  printf 'earlier-line\n' > "$TMP_ROOT/stderr-kept.err"
  rm -f -- "${TMP_ROOT:?}/stderr-kept.cap"
  ( cd "$REPO" && env "${LAUNCH_ENV[@]}" OT_CAPTURE="$TMP_ROOT/stderr-kept.cap" ORCH_STATE_DIR="$TMP_ROOT/state" \
      PATH="$BIN:$PROC_BIN:$PATH" WORKTREE_CLI="$STUB" "$1" --ghostty --relaunch --harness copilot --launch-flags "$FLAGS" CC-738 ) \
    >/dev/null 2>>"$TMP_ROOT/stderr-kept.err" || :
  for _ in $(seq 1 50); do [[ -s "$TMP_ROOT/stderr-kept.cap" ]] && break; sleep 0.1; done
  if [[ "$(head -1 "$TMP_ROOT/stderr-kept.err")" == earlier-line && -s "$TMP_ROOT/stderr-kept.cap" ]]; then echo 1; else echo 0; fi
}
assert_eq "$(stderr_kept "$REPO/scripts/open-terminal")" "1" \
  "a relaunch appending to a stderr file keeps the line written before it"
# stderr_reopen — what a `2>/dev/stderr` redirect inside a command
# substitution does to a stderr opened for append on a regular file, the
# redirect the /dev/stderr control plants: `truncates` where the open reopens
# the file (Linux, whose /dev/stderr resolves through /proc/self/fd),
# `duplicates` where it copies the descriptor (macOS devfs), so the hazard
# that control guards cannot occur. Any other result is printed as
# `broken: CONTENT`.
stderr_reopen() {
  local probe="$TMP_ROOT/stderr-reopen.err" rc=0 held
  printf 'probe-line\n' > "$probe"
  # shellcheck disable=SC2034  # the assignment carries the substitution's exit status
  ( answer="$(: 2>/dev/stderr)" ) 2>>"$probe" || rc=$?
  held="$(cat -- "$probe")"
  if [[ "$rc" -ne 0 ]]; then printf 'broken: rc=%s %s\n' "$rc" "$held"
  elif [[ -z "$held" ]]; then echo truncates
  elif [[ "$held" == probe-line ]]; then echo duplicates
  else printf 'broken: %s\n' "$held"; fi
}
# The lane ran on copilot and is relaunched on claude: nothing in claude's
# store names the item, so claude starts it afresh on its own brief.
launch switched --relaunch --harness claude --launch-flags '--model opus --effort high' CC-738
assert_contains "$CMD" "'/orch start CC-738'" \
  "a relaunch onto another harness finds none of the copilot session and starts afresh"
assert_not_contains "$CMD" "--resume" "the switched relaunch resumes nothing"

echo "=== a copilot wake resumes the lane's session in print mode, and only an idle one ==="
launch wake --wake --harness copilot --launch-flags "$FLAGS" CC-738
assert_eq "$CMD" "copilot --autopilot --max-autopilot-continues 3 --context long_context --no-auto-update --no-ask-user --model claude-opus-5 --reasoning-effort high --allow-all --resume=22222222-bbbb-4bbb-8bbb-222222222222 -p Run .agents/skills/orch/scripts/lane-mail inbox --item CC-738 and act on every directive it prints." \
  "the wake resumes the newest session that ran, by its id, its inbox line the value of -p"
assert_eq "$(cat "$TMP_ROOT/wake.cap.env" 2>/dev/null)" "COPILOT_ALLOW_ALL=true COPILOT_SKILLS_DIRS=$FLEET_HOME/.agents/skills COPILOT_GITHUB_TOKEN=unset GH_TOKEN=gh-fixture" \
  "the woken copilot runs under the launch environment, COPILOT_GITHUB_TOKEN cleared and GH_TOKEN kept"
# A COPILOT_ALLOW_ALL the launching shell exports never widens a restrictive
# launch: the woken copilot reads it empty, not true and not unset.
# restrictive_wake NAME — a wake naming no allow-all spelling, run by the
# open-terminal in OT, under an exported COPILOT_ALLOW_ALL=true.
restrictive_wake() {
  ROW_ENV=(COPILOT_ALLOW_ALL=true)
  launch "$1" --wake --harness copilot --launch-flags "--model claude-opus-5 --reasoning-effort high" CC-738
  ROW_ENV=()
}
restrictive_wake wake-restrictive
assert_eq "$(cat "$TMP_ROOT/wake-restrictive.cap.env" 2>/dev/null)" "COPILOT_ALLOW_ALL= COPILOT_SKILLS_DIRS=$FLEET_HOME/.agents/skills COPILOT_GITHUB_TOKEN=unset GH_TOKEN=gh-fixture" \
  "a restrictive wake under an exported COPILOT_ALLOW_ALL=true runs copilot with it empty"
launch wake-none --wake --harness copilot --launch-flags "$FLAGS" CC-743
assert_eq "${CMD:-none} $(grep -c '^open-terminal: session-missing item=CC-743 harness=copilot' <<<"$ERR" || true)" "none 1" \
  "a worktree whose only record holds no events has no session to wake, and nothing starts"
# A copilot process in the lane's worktree: the binary names itself
# MainThread, and with no idle signal a live one is never judged idle.
sleep 300 & LIVE_PID=$!
proc_table_write "$PROC_TABLE" "$LIVE_PID 1 MainThread"
proc_cwd_write "$PROC_CWD_FILE" "$LIVE_PID=$WT"
launch wake-live --wake --harness copilot --launch-flags "$FLAGS" CC-738
kill "$LIVE_PID" 2>/dev/null || :
proc_table_write "$PROC_TABLE"
proc_cwd_write "$PROC_CWD_FILE"
assert_eq "${CMD:-none} $(grep -c '^open-terminal: wake-refused item=CC-738 reason=unjudged' <<<"$ERR" || true)" "none 1" \
  "a live copilot session is refused as unjudged, never doubled by a second process"

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

echo "=== every local copilot launch runs under its account's environment ==="
# COPILOT_GITHUB_TOKEN cleared so the account's stored login is the identity,
# GH_TOKEN and GITHUB_TOKEN kept for the lane's own gh calls, the shared
# skills named again and folder trust granted, under both forms:
# the account variable in front of `copilot` for a launch naming no lane or a
# lane with no launcher, and the launcher named for the account's directory,
# `1copilot` for `.1copilot`, which sets COPILOT_HOME itself. `label|--lane
# value, or - for none|the words the line runs`. Each line is then run with a
# probe standing in for what it starts, under an ambient value for each token.
POLICY="env -u COPILOT_GITHUB_TOKEN COPILOT_SKILLS_DIRS='$FLEET_HOME/.agents/skills' COPILOT_ALLOW_ALL=true"
mkdir -p "$TMP_ROOT/.2copilot"
cp -- "$BIN/copilot" "$TMP_ROOT/copilot-capture"
PROBE='#!/bin/sh\nprintf "%%s|%%s|%%s|%%s\\n" "${COPILOT_GITHUB_TOKEN-unset}" "${GH_TOKEN-unset}" "${GITHUB_TOKEN-unset}" "$COPILOT_ALLOW_ALL"\n'
# shellcheck disable=SC2059  # the probe's own format, written as a script.
printf "$PROBE" > "$BIN/copilot"
# shellcheck disable=SC2059
printf "$PROBE" > "$BIN/1copilot"
chmod +x "$BIN/copilot" "$BIN/1copilot"
# probe_launch — what the probe prints when the launch in CMD runs it, under
# an ambient value for each token.
probe_launch() {
  (cd "$TMP_ROOT" && COPILOT_GITHUB_TOKEN=placeholder GH_TOKEN=app-token GITHUB_TOKEN=actions-token PATH="$BIN:$PATH" bash -c "${CMD#*&& }")
}
N=750
while IFS='|' read -r label lane words; do
  N=$((N + 1))
  if [[ "$lane" == - ]]; then
    launch "env-$N" --harness copilot --launch-flags "$FLAGS" "cc-$N"
  else
    launch "env-$N" --harness copilot --lane "$lane" --launch-flags "$FLAGS" "cc-$N"
  fi
  assert_contains "$CMD" "&& $words $LEAD -i" "$label"
  assert_eq "$(probe_launch)" "unset|app-token|actions-token|true" \
    "$label: the launched copilot sees no COPILOT_GITHUB_TOKEN, GH_TOKEN and GITHUB_TOKEN reach it, and it trusts the folder"
done <<ROWS
a launch naming no lane runs on the default account|-|$POLICY COPILOT_HOME='$FLEET_HOME/.copilot' copilot
a named lane with no launcher runs under its account variable|$TMP_ROOT/.2copilot|$POLICY COPILOT_HOME='$TMP_ROOT/.2copilot' copilot
a named lane with a launcher runs that launcher under the same policy|$TMP_ROOT/.1copilot|$POLICY '$BIN/1copilot'
ROWS
# Must-fail control: the clearing cut from a private copy of the policy, and
# the probe sees the ambient COPILOT_GITHUB_TOKEN.
CLEARING="printf 'env -u COPILOT_GITHUB_TOKEN COPILOT_SKILLS_DIRS"
stage "$TMP_ROOT/unset-ctrl"
mutate_file "$TMP_ROOT/unset-ctrl/scripts/lib/lane-launch.sh" "$CLEARING" "printf 'env COPILOT_SKILLS_DIRS"
OT="$TMP_ROOT/unset-ctrl/scripts/open-terminal" launch unset-ctrl --harness copilot --launch-flags "$FLAGS" cc-761
assert_contains "$CMD" "copilot $LEAD -i" "the control's launch renders its command"
assert_eq "$(probe_launch)" "placeholder|app-token|actions-token|true" \
  "control: without -u COPILOT_GITHUB_TOKEN its ambient token reaches the launched copilot ahead of its stored login"
mv -- "$TMP_ROOT/copilot-capture" "$BIN/copilot"
printf '#!/bin/sh\n' > "$BIN/1copilot"

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
# The retirement read handed /dev/stderr, which a relaunch whose stderr is a
# regular file reopens and truncates, losing the line written before it. Only
# where the box's /dev/stderr open reopens the file: where it duplicates the
# descriptor, the mutant truncates nothing and the control stands down.
stage "$TMP_ROOT/stderr-ctrl"
mutate_file "$TMP_ROOT/stderr-ctrl/scripts/open-terminal" 'lane_handoff_standing "$3" "" ' 'lane_handoff_standing "$3" /dev/stderr '
STDERR_REOPEN="$(stderr_reopen)"
case "$STDERR_REOPEN" in
  truncates)
    assert_eq "$(stderr_kept "$TMP_ROOT/stderr-ctrl/scripts/open-terminal")" "0" \
      "control: a retirement read through /dev/stderr truncates the relaunch's stderr file" ;;
  duplicates)
    pass "control stands down: a /dev/stderr open duplicates the descriptor here, so a retirement read through it truncates nothing" ;;
  *)
    fail "probe: a 2>/dev/stderr redirect neither truncated nor kept the stderr file" "$STDERR_REOPEN" ;;
esac
# The helper's empty ERR_FILE arm cut: the run is sent to a file named by the
# empty string, fails, and the relaunch refuses rather than launching.
stage "$TMP_ROOT/stderr-arm-ctrl"
mutate_file "$TMP_ROOT/stderr-arm-ctrl/scripts/lib/lane-state.sh" '  else answer="$(cd -- "$dir" && "$@")" || rc=$?; fi' '  else answer="$(cd -- "$dir" && "$@" 2>"$err")" || rc=$?; fi'
assert_eq "$(stderr_kept "$TMP_ROOT/stderr-arm-ctrl/scripts/open-terminal")" "0" \
  "control: without the helper's empty ERR_FILE arm the relaunch is refused"
# The events test cut: the newest record in the worktree is resumed though it
# holds no events, which copilot refuses to resume.
stage "$TMP_ROOT/events-ctrl"
mutate_file "$TMP_ROOT/events-ctrl/scripts/lib/lane-relaunch.sh" ' && -s "${file%/*}/events.jsonl" ]]' ' ]]'
OT="$TMP_ROOT/events-ctrl/scripts/open-terminal" launch events-ctrl --relaunch --harness copilot --launch-flags "$FLAGS" CC-738
assert_contains "$CMD" "--resume=66666666-ffff-4fff-8fff-666666666666 -i" \
  "control: without the events test the relaunch resumes a record copilot cannot load"
# The retirement cut from the lookup's gate: a standing record no longer stops
# the relaunch from resuming the session its lane ended.
stage "$TMP_ROOT/retired-ctrl"
mutate_file "$TMP_ROOT/retired-ctrl/scripts/open-terminal" ' && "$RELAUNCH_RETIRED" == false && ' ' && '
handoff CC-738 '{"handoff":{"merged":[],"remaining":["open the PR"],"written_at":"2000-01-01T06:00:00Z"}}'
OT="$TMP_ROOT/retired-ctrl/scripts/open-terminal" launch retired-ctrl --relaunch --harness copilot --launch-flags "$FLAGS" CC-738
rm -f -- "${TMP_ROOT:?}/state/workflow-state-CC-738.json"
assert_contains "$CMD" "--resume=22222222-bbbb-4bbb-8bbb-222222222222 -i" \
  "control: without the retirement gate a relaunch resumes the session its lane handed off"
# Copilot cut from the wake's harness gate: the wake is refused before any
# session is read.
stage "$TMP_ROOT/wake-gate-ctrl"
mutate_file "$TMP_ROOT/wake-gate-ctrl/scripts/open-terminal" '"$LANE_HOST" != local || ! "$HARNESS" =~ ^(claude|codex|pi|copilot)$ ) ]]; then' '"$LANE_HOST" != local || ! "$HARNESS" =~ ^(claude|codex|pi)$ ) ]]; then'
OT="$TMP_ROOT/wake-gate-ctrl/scripts/open-terminal" launch wake-gate-ctrl --wake --harness copilot --launch-flags "$FLAGS" CC-738
assert_eq "${CMD:-none} $(grep -c '^open-terminal: wake-invalid option=--wake harness=copilot' <<<"$ERR" || true)" "none 1" \
  "control: without copilot in the wake gate a copilot wake is wake-invalid"
# The wake's print mode cut: its line reaches copilot as an interactive turn,
# which a detached process with no terminal cannot run.
stage "$TMP_ROOT/wake-print-ctrl"
mutate_file "$TMP_ROOT/wake-print-ctrl/scripts/open-terminal" "%s--resume=%q -p%s" "%s--resume=%q -i%s"
OT="$TMP_ROOT/wake-print-ctrl/scripts/open-terminal" launch wake-print-ctrl --wake --harness copilot --launch-flags "$FLAGS" CC-738
assert_contains "$CMD" "--resume=22222222-bbbb-4bbb-8bbb-222222222222 -i Run" \
  "control: without the print-mode arm the wake line is an interactive turn"
# The launch environment cut from the builder: the command runs bare.
stage "$TMP_ROOT/env-ctrl"
mutate_file "$TMP_ROOT/env-ctrl/scripts/lib/lane-launch.sh" '  env_words="$(lane_copilot_env "$cmd" ' '  env_words="env" #'
OT="$TMP_ROOT/env-ctrl/scripts/open-terminal" launch env-ctrl --harness copilot --launch-flags "$FLAGS" cc-737
assert_eq "$(grep -c 'COPILOT_ALLOW_ALL=true' <<<"$CMD" || true)" "0" \
  "control: without the builder's copilot words the command carries no launch environment"
# The allow-all judge cut: every command carries COPILOT_ALLOW_ALL, approving
# every tool for a caller that named no allow-all posture.
stage "$TMP_ROOT/allow-ctrl"
mutate_file "$TMP_ROOT/allow-ctrl/scripts/lib/lane-launch.sh" '  ! lane_copilot_allows_all "$1" || allow="COPILOT_ALLOW_ALL=true"' '  allow="COPILOT_ALLOW_ALL=true"'
OT="$TMP_ROOT/allow-ctrl/scripts/open-terminal" launch allow-ctrl --harness copilot --launch-flags "--model claude-opus-5 --reasoning-effort high" cc-752
assert_contains "$CMD" "&& $COP_ENV $COP_AMBIENT copilot " \
  "control: without the allow-all judge a launch naming no allow-all spelling carries COPILOT_ALLOW_ALL"
# The route's allow-all judge cut: a launch naming no allow-all spelling
# reports a folder trust nothing granted.
stage "$TMP_ROOT/trust-route-ctrl"
mutate_file "$TMP_ROOT/trust-route-ctrl/scripts/open-terminal" ' || lane_copilot_allows_all "$cmd" || LANE_TRUST_ROUTE=none' ' || :'
OT="$TMP_ROOT/trust-route-ctrl/scripts/open-terminal" launch trust-route-ctrl --harness copilot --launch-flags "--model claude-opus-5 --reasoning-effort high" cc-752
assert_eq "$(grep -c '^open-terminal: launch-trusted .*route=allow-all-env' <<<"$OUT" || true)" "1" \
  "control: without the allow-all judge a restrictive launch reports its folder trusted"
# The restrictive path's empty assignment cut: an exported COPILOT_ALLOW_ALL=true
# reaches the restrictive wake's copilot.
stage "$TMP_ROOT/allow-empty-ctrl"
mutate_file "$TMP_ROOT/allow-empty-ctrl/scripts/lib/lane-launch.sh" '  local allow="COPILOT_ALLOW_ALL="' '  local allow=""'
OT="$TMP_ROOT/allow-empty-ctrl/scripts/open-terminal" restrictive_wake allow-empty-ctrl
assert_contains "$(cat "$TMP_ROOT/allow-empty-ctrl.cap.env" 2>/dev/null)" "COPILOT_ALLOW_ALL=true " \
  "control: without the empty assignment a restrictive wake inherits the exported COPILOT_ALLOW_ALL=true"
# The route that hands a wake to the builder cut for the wake alone: the woken
# copilot runs bare, which the stub's own environment shows.
stage "$TMP_ROOT/wake-env-ctrl"
mutate_file "$TMP_ROOT/wake-env-ctrl/scripts/open-terminal" '|| "$HARNESS" == codex || "$HARNESS" == copilot ]]; then' '|| "$HARNESS" == codex || "$HARNESS" == copilot && "$WAKE" != true ]]; then'
OT="$TMP_ROOT/wake-env-ctrl/scripts/open-terminal" launch wake-env-ctrl --wake --harness copilot --launch-flags "$FLAGS" CC-738
assert_contains "$(cat "$TMP_ROOT/wake-env-ctrl.cap.env" 2>/dev/null)" "COPILOT_ALLOW_ALL=unset" \
  "control: without the wake's route to the builder the woken copilot has no launch environment"
# Each launch setting its own run cut: the row's settings are one run, and a
# caller's copy of one of them is carried beside the row's.
stage "$TMP_ROOT/dedup-ctrl"
mutate_file "$TMP_ROOT/dedup-ctrl/scripts/lib/lane-launch.sh" '<<<"${settings//;/$nl}$nl$compaction$nl$question"' '<<<"$settings$nl$compaction$nl$question"'
OT="$TMP_ROOT/dedup-ctrl/scripts/open-terminal" launch dedup-ctrl --harness copilot --launch-flags "$FLAGS --context long_context" cc-737
assert_eq "$(grep -o "'--context'" <<<"$CMD" | wc -l | tr -d '[:space:]')" "2" \
  "control: with the settings one run a caller's --context is carried twice"
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
# The environment rules, each cut from a private copy: the policy in the
# launcher arm, and a launch naming no lane given no environment.
stage "$TMP_ROOT/launcher-ctrl"
mutate_file "$TMP_ROOT/launcher-ctrl/scripts/lib/lane-launch.sh" "launcher:*) printf '%s %s %s\\n' \"\$env_words\"" "launcher:*) printf 'env %s %s\\n'"
OT="$TMP_ROOT/launcher-ctrl/scripts/open-terminal" launch launcher-ctrl --harness copilot --lane "$TMP_ROOT/.1copilot" --launch-flags "$FLAGS" cc-755
assert_contains "$CMD" "'$BIN/1copilot' $LEAD -i" "the control's launch renders its command"
assert_not_contains "$CMD" "-u COPILOT_GITHUB_TOKEN" "control: without the policy in its arm a launcher runs with the ambient COPILOT_GITHUB_TOKEN"
stage "$TMP_ROOT/nolane-ctrl"
mutate_file "$TMP_ROOT/nolane-ctrl/scripts/open-terminal" '|| "$HARNESS" == codex || "$HARNESS" == copilot ]]; then' '|| "$HARNESS" == codex ]]; then'
OT="$TMP_ROOT/nolane-ctrl/scripts/open-terminal" launch nolane-ctrl --harness copilot --launch-flags "$FLAGS" cc-754
assert_contains "$CMD" "copilot $LEAD -i" "the control's launch renders its command"
assert_not_contains "$CMD" "COPILOT_ALLOW_ALL" "control: without its branch a launch naming no lane carries no account environment"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
