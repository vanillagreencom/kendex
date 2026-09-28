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
# The refusals, each with its control: a --brief-file with no {brief}, a
# {brief} with no --brief-file, a path that is not a readable file, a file
# holding only whitespace, and a {brief} inside a quote or behind a backslash.
# The inline-brief rows, balanced and unbalanced, are
# open-terminal-claude-handoff.sh's.
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
TMP_ROOT="$(mktemp -d)" || { echo "open-terminal-brief-file: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "open-terminal-brief-file: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "open-terminal-brief-file: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

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
# bare double quotes, the hand interpolation the file route replaces. The line
# still parses and the harness still runs, so the only thing that differs from
# the rows above is the brief it receives: its $HOME and backticks expanded.
# Its PROJECT_ROOT resolves through a git repository of its own.
QUOTE_OT="$(mutant_scripts brief-double-quoted open-terminal)/open-terminal" || exit 1
git -C "$TMP_ROOT/brief-double-quoted" init -q
orch_fixture_shared_libs "$TMP_ROOT/brief-double-quoted"
mutate_file "$QUOTE_OT" 'quoted="$(lane_single_quote "$BRIEF_TEXT")"' 'quoted="\"$BRIEF_TEXT\""'
run_ot "$QUOTE_OT" "TMUX=" --ghostty --harness claude --cmd "$CMD" --brief-file "$BRIEF_FILE" CC-4
line="$(gui_line)" || line=""
assert_eq "rc=$RC harness=$(received "$line")" "rc=0 harness=altered" \
  "control: a brief placed between bare double quotes reaches the harness altered" "$OUT"

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
# mutant NAME OLD NEW — sets MUTANT_OT to a copy of open-terminal with one
# refusal's condition replaced, in a git repository of its own. Run in this
# shell, not a substitution, so mutate_file's two assertions are counted.
mutant() {
  local scripts
  scripts="$(mutant_scripts "$1" open-terminal)" || exit 1
  MUTANT_OT="$scripts/open-terminal"
  git -C "$TMP_ROOT/$1" init -q
  orch_fixture_shared_libs "$TMP_ROOT/$1"
  mutate_file "$MUTANT_OT" "$2" "$3"
}

INLINE_CMD="$HARNESS_STUB --model opus --effort high $QUESTION_OFF_ALL 'an inline brief'"
refusal_row "a brief file beside a command with no {brief} is refused, since it would reach no harness" \
  "$OT" brief-unreferenced option=--brief-file --cmd "$INLINE_CMD" --brief-file "$BRIEF_FILE"
mutant brief-unreferenced '[[ "$CMD_TEMPLATE" == *"{brief}"* ]] || { ot_message brief-unreferenced' 'true || { ot_message brief-unreferenced'
control_row "control: without its refusal the unreferenced brief file launches" \
  "$MUTANT_OT" \
  --cmd "$INLINE_CMD" --brief-file "$BRIEF_FILE"

refusal_row "a {brief} with no brief file is refused, since the harness would start on an empty brief" \
  "$OT" brief-file-missing option=--cmd --cmd "$CMD"
mutant brief-file-missing 'elif [[ "$CMD_TEMPLATE" == *"{brief}"* ]]; then' 'elif false; then'
control_row "control: without its refusal the placeholder with no file launches" \
  "$MUTANT_OT" \
  --cmd "$CMD"

refusal_row "a brief file path that is not a readable file is refused, naming the path" \
  "$OT" brief-file-unreadable "path=$TMP_ROOT/absent.md" --cmd "$CMD" --brief-file "$TMP_ROOT/absent.md"
mutant brief-unreadable '2>/dev/null)" || { ot_message brief-file-unreadable' '2>/dev/null)" || BRIEF_TEXT=x || { ot_message brief-file-unreadable'
control_row "control: without its refusal the unreadable brief file launches" \
  "$MUTANT_OT" \
  --cmd "$CMD" --brief-file "$TMP_ROOT/absent.md"

# A zero-byte file, one holding newlines alone and one holding spaces alone
# each leave the harness nothing to do.
EMPTY_BRIEF="$TMP_ROOT/empty.md"
for content in "" $'\n\n' $'  \t \n'; do
  printf '%s' "$content" > "$EMPTY_BRIEF"
  refusal_row "a brief file holding $(printf '%q' "$content") is refused as empty, naming the path" \
    "$OT" brief-file-empty "path=$EMPTY_BRIEF" --cmd "$CMD" --brief-file "$EMPTY_BRIEF"
done
mutant brief-empty '[[ "$BRIEF_TEXT" == *[![:space:]]* ]] || { ot_message brief-file-empty' 'true || { ot_message brief-file-empty'
control_row "control: without its refusal the whitespace-only brief file launches" \
  "$MUTANT_OT" \
  --cmd "$CMD" --brief-file "$EMPTY_BRIEF"

echo "=== {brief} stands bare, since open-terminal supplies its quotes ==="
# Inside single quotes the brief's own quotes would close the caller's early;
# inside double quotes its $ and backticks would reach the shell; behind a
# backslash its opening quote would be escaped.
mutant brief-quoted 'if [[ "${text:i:7}" == "{brief}" &&' 'if false && [[ "${text:i:7}" == "{brief}" &&'
QUOTED_OT="$MUTANT_OT"
for placed in "'{brief}'" '"{brief}"' '\{brief}'; do
  refusal_row "a {brief} written as $placed is refused before a worktree" \
    "$OT" brief-quoted item=CC-5 --cmd "$HARNESS_STUB --model opus --effort high $QUESTION_OFF_ALL $placed" --brief-file "$BRIEF_FILE"
  control_row "control: without its refusal a {brief} written as $placed launches" \
    "$QUOTED_OT" --cmd "$HARNESS_STUB --model opus --effort high $QUESTION_OFF_ALL $placed" --brief-file "$BRIEF_FILE"
done

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
