#!/usr/bin/env bash
# Tests for open-terminal's --brief-file: the brief a --cmd command places as
# {brief} reaches the harness as the file's text, whatever quote, `$` or
# backtick it holds, on every launch path.
#
# Each launch path hands the rendered line to a different shell: open_gui to
# `bash -lc`, open_tmux to the pane's shell, and a hosted launch to the remote
# shell behind the provider's prefix, one more quoting layer. A row launches
# through the stubs, takes the line the launcher handed over (the GUI
# terminal's argument, or the paste the tmux stub logged), runs it in a real
# shell, and compares what a stub harness received with the file.
#
# The pairing refusals, one row each: a --brief-file with no {brief}, a
# {brief} with no --brief-file, and a path that is not a readable file.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# An inherited lane or host setting would point these launches at the
# operator's real accounts or provider; the hosted row passes the stub itself.
unset ORCH_LANE_DIRS ORCH_LANE_ALIASES ORCH_LANE_EXCLUDE ORCH_LANE_RETIRE ORCH_LANES_USAGE_TTL CODEX_HOME
unset ORCH_LANES_CLAUDE_CLIENT_ID ORCH_LANES_TOKEN_CMD ORCH_LANES_CLAUDE_TOKEN_URL ORCH_LANE_MAX_PCT
export ORCH_LANE_HOST=local
# shellcheck source=lib/shared-skill-libs.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/shared-skill-libs.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# shellcheck source=lib/lanes-fixture.sh
source "$TEST_DIR/lib/lanes-fixture.sh"
# shellcheck source=lib/open-terminal-stubs.sh
source "$TEST_DIR/lib/open-terminal-stubs.sh"
# shellcheck source=lib/question-off.sh
source "$TEST_DIR/lib/question-off.sh"
# mutant_scripts and mutate_file, the two halves of each control below.
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

FETCHER="$TMP_ROOT/fetch"
make_fetcher "$FETCHER"
standard_home home
OT_STUB_BIN="$TMP_ROOT/ot-bin"
ot_stub_bin "$OT_STUB_BIN"
HOST_STUB="$TEST_DIR/fixtures/lane-host"

# The harness the rendered line starts, by absolute path so a login shell's
# rebuilt PATH cannot answer with another: it writes its last argument, the
# brief, to RECEIVED byte for byte.
RECEIVED="$TMP_ROOT/received"
HARNESS_STUB="$TMP_ROOT/harness"
printf '#!/usr/bin/env bash\nprintf %%s "${!#}" > %q\n' "$RECEIVED" > "$HARNESS_STUB"
chmod +x "$HARNESS_STUB"

# The brief: an apostrophe, double quotes, a dollar sign, backticks, an
# ampersand, a backslash, a printf directive and a placeholder word, each of
# which one of the shells or the renderer would otherwise read. The file ends
# in a newline, as a file the harness file tool writes does; the harness gets
# the text without it.
BRIEF_FILE="$TMP_ROOT/brief.md"
cat > "$BRIEF_FILE" <<'BRIEF'
Read the agent's brief: say "done", keep $HOME and `whoami` as written, a & b, C:\tmp, 100%s, {issue}.
BRIEF
BRIEF_WANT="$TMP_ROOT/brief.want"
printf '%s' "$(cat "$BRIEF_FILE")" > "$BRIEF_WANT"
CMD="$HARNESS_STUB --model opus --effort high $QUESTION_OFF_ALL {brief}"

# The directory a hosted lane's remote shell opens in, and the provider's disk
# the stub serves under it: the launch reads the lane's `.git` there for the
# clone its marker belongs under.
REMOTE_LANE="$TMP_ROOT/remote-lane"
mkdir -p "$REMOTE_LANE" "$TMP_ROOT/provider$REMOTE_LANE"
printf 'gitdir: /srv/clone/.git/worktrees/lane\n' > "$TMP_ROOT/provider$REMOTE_LANE/.git"

# --- harness -----------------------------------------------------------------

# run_ot OT ENV ARGS... — one launch of OT with the stubs and a fresh log set
# under $RUN. ENV is a semicolon-separated list of `env` arguments. OUT is
# stdout and stderr together, the way a caller sees a launch.
RUN_SEQ=0
run_ot() {
  local ot="$1" env_list="$2" env_args=() items item
  shift 2
  RUN="$TMP_ROOT/runs/$((++RUN_SEQ))"
  mkdir -p "$RUN"
  # The worktree stub appends to this log, so an empty one is a launch that
  # created nothing; the control rows prove the stub is reached.
  : > "$RUN/worktree.log"
  if [[ -n "$env_list" ]]; then
    IFS=';' read -ra items <<<"$env_list"
    for item in "${items[@]}"; do env_args+=("$item"); done
  fi
  OUT=$(env LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' \
    LANE_HOST_STUB_DIR="$TMP_ROOT/provider" LANE_HOST_STUB_LOG="$RUN/host.log" \
    ORCH_TMUX_VERIFY_SECS=1 ORCH_LANE_SSH_PROMPT_SECS=1 ORCH_LANE_MAX_PCT=95 \
    OT_TMUX_LOG="$RUN/tmux.log" OT_TMUX_SERVER_PID="$$" OT_TMUX_PANES="$RUN/panes" OT_CAPTURE="$RUN/gui" \
    OT_WT_LOG="$RUN/worktree.log" OVERSEE_WATCH_STATE_DIR="$RUN/state" ORCH_STATE_DIR="$RUN/state" \
    PATH="$OT_STUB_BIN:$PATH" WORKTREE_CLI="$OT_STUB_BIN/worktree" \
    ${env_args[@]+"${env_args[@]}"} "$ot" "$@" 2>&1)
  RC=$?
}

# gui_line — the command open_gui handed `bash -lc`, once the detached terminal
# stub has written it.
gui_line() {
  local i
  for i in $(seq 1 50); do
    [[ -s "$RUN/gui" ]] && { cat "$RUN/gui"; return 0; }
    sleep 0.1
  done
  return 1
}

# typed_line TEXT — the one line pasted into the pane that holds TEXT; none,
# or more than one, fails.
typed_line() {
  local lines
  lines="$(grep -F -- "$1" "$RUN/tmux.log")" || return 1
  [[ "$lines" != *$'\n'* ]] || return 1
  printf '%s\n' "$lines"
}

# received LINE — runs LINE the way its shell would and prints what the stub
# harness received, or `unrun` when it received nothing. `clear` is a no-op
# here: the pane line opens on it and the suite has no terminal to clear.
received() {
  rm -f -- "$RECEIVED"
  env HOME="$TMP_ROOT/home" bash -c "clear() { :; }; $1" >/dev/null 2>&1
  if [[ -f "$RECEIVED" ]]; then cmp -s "$RECEIVED" "$BRIEF_WANT" && echo verbatim || echo altered; else echo unrun; fi
}

OT="$SCRIPTS_DIR/open-terminal"
mkdir -p "$TMP_ROOT/home"

echo "=== a brief file reaches the harness verbatim on every launch path ==="
run_ot "$OT" "TMUX=" --ghostty --harness claude --cmd "$CMD" --brief-file "$BRIEF_FILE" CC-1
line="$(gui_line)" || line=""
assert_eq "rc=$RC harness=$(received "$line")" "rc=0 harness=verbatim" \
  "the GUI launch hands bash -lc a line whose brief the harness receives verbatim" "$OUT"

run_ot "$OT" "TMUX=stub,1,0;ORCH_TMUX_SESSION=stub" --tmux --harness claude --cmd "$CMD" --brief-file "$BRIEF_FILE" CC-2
line="$(typed_line "clear; $HARNESS_STUB ")" || line=""
assert_eq "rc=$RC harness=$(received "$line")" "rc=0 harness=verbatim" \
  "the local tmux launch pastes a line whose brief the harness receives verbatim" "$OUT"

# The provider's prefix is the reference one, a login shell, so the remote
# shell reads the brief through one more quoting layer than a local pane.
run_ot "$OT" "TMUX=stub,1,0;ORCH_TMUX_SESSION=stub;ORCH_LANE_ALIASES=eclaude=work;LANE_HOST_STUB_CREATE_LINE=ssh-target=lane.example"$'\t'"path=$REMOTE_LANE"$'\t'"remote-prefix=exec bash -lc" \
  --host "$HOST_STUB" --harness claude --lane work --repo o/r --cmd "$CMD" --brief-file "$BRIEF_FILE" CC-3
line="$(typed_line "exec bash -lc 'cd ")" || line=""
assert_eq "rc=$RC ssh=$(grep -cxF "clear; ssh 'lane.example'" "$RUN/tmux.log") harness=$(received "$line")" "rc=0 ssh=1 harness=verbatim" \
  "the hosted launch types a remote line whose brief the harness receives verbatim through the provider's shell" "$OUT"

# The must-fail control: a copy of open-terminal that places the brief between
# bare quotes, the hand interpolation the file route replaces. Its PROJECT_ROOT
# resolves through a git repository of its own.
QUOTE_OT="$(mutant_scripts brief-unquoted open-terminal)/open-terminal" || exit 1
git -C "$TMP_ROOT/brief-unquoted" init -q
orch_fixture_shared_libs "$TMP_ROOT/brief-unquoted"
mutate_file "$QUOTE_OT" 'quoted="$(lane_single_quote "$BRIEF_TEXT")"' "quoted=\"'\$BRIEF_TEXT'\""
run_ot "$QUOTE_OT" "TMUX=" --ghostty --harness claude --cmd "$CMD" --brief-file "$BRIEF_FILE" CC-4
line="$(gui_line)" || line=""
got="$(received "$line")"
assert_eq "$([[ "$got" != verbatim ]] && echo reddened || echo "$got")" "reddened" \
  "control: a brief placed between bare quotes does not reach the harness verbatim"

echo "=== a brief file and its placeholder come as a pair ==="
# refusal_row LABEL OT KEY FIELD ARGS... — a launch refused before any window
# or worktree, its first line naming KEY and FIELD.
refusal_row() {
  local label="$1" ot="$2" key="$3" field="$4"
  shift 4
  run_ot "$ot" "TMUX=" --ghostty --harness claude "$@" CC-5
  assert_eq "rc=$RC first=$(sed -n 1p <<<"$OUT") creates=$(grep -c '^create ' "$RUN/worktree.log")" \
    "rc=1 first=open-terminal: $key $field creates=0" "$label" "$OUT"
}
# control_row LABEL OT ARGS... — the same launch under a copy whose refusal is
# gone, which now reaches a worktree.
control_row() {
  local label="$1" ot="$2"
  shift 2
  run_ot "$ot" "TMUX=" --ghostty --harness claude "$@" CC-5
  assert_eq "rc=$RC creates=$(grep -c '^create ' "$RUN/worktree.log")" "rc=0 creates=1" "$label" "$OUT"
}
# mutant NAME OLD NEW — a copy of open-terminal with one refusal's condition
# replaced, in a git repository of its own.
mutant() {
  local ot
  ot="$(mutant_scripts "$1" open-terminal)/open-terminal" || exit 1
  git -C "$TMP_ROOT/$1" init -q
  orch_fixture_shared_libs "$TMP_ROOT/$1"
  mutate_file "$ot" "$2" "$3" >&2
  printf '%s\n' "$ot"
}

INLINE_CMD="$HARNESS_STUB --model opus --effort high $QUESTION_OFF_ALL 'an inline brief'"
refusal_row "a brief file beside a command with no {brief} is refused, since it would reach no harness" \
  "$OT" brief-unreferenced option=--brief-file --cmd "$INLINE_CMD" --brief-file "$BRIEF_FILE"
control_row "control: without its refusal the unreferenced brief file launches" \
  "$(mutant brief-unreferenced '[[ "$CMD_TEMPLATE" == *"{brief}"* ]] || { ot_message brief-unreferenced' 'true || { ot_message brief-unreferenced')" \
  --cmd "$INLINE_CMD" --brief-file "$BRIEF_FILE"

refusal_row "a {brief} with no brief file is refused, since the harness would start on an empty brief" \
  "$OT" brief-file-missing option=--cmd --cmd "$CMD"
control_row "control: without its refusal the placeholder with no file launches" \
  "$(mutant brief-file-missing 'elif [[ "$CMD_TEMPLATE" == *"{brief}"* ]]; then' 'elif false; then')" \
  --cmd "$CMD"

refusal_row "a brief file path that is not a readable file is refused, naming the path" \
  "$OT" brief-file-unreadable "path=$TMP_ROOT/absent.md" --cmd "$CMD" --brief-file "$TMP_ROOT/absent.md"
control_row "control: without its refusal the unreadable brief file launches" \
  "$(mutant brief-unreadable '2>/dev/null)" || { ot_message brief-file-unreadable' '2>/dev/null)" || true || { ot_message brief-file-unreadable')" \
  --cmd "$CMD" --brief-file "$TMP_ROOT/absent.md"

# An inline brief is still the caller's own shell text: one whose quotes
# balance launches as before, and one that leaves a quote open is refused with
# the key whose remedy names the file route.
refusal_row "an inline brief that leaves a quote open is refused before a worktree" \
  "$OT" cmd-unbalanced-quote item=CC-5 --cmd "$HARNESS_STUB --model opus --effort high $QUESTION_OFF_ALL 'the agent\\'s brief'"
run_ot "$OT" "TMUX=" --ghostty --harness claude --cmd "$INLINE_CMD" CC-6
assert_eq "rc=$RC" "rc=0" "an inline brief whose quotes balance still launches" "$OUT"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
