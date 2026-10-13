#!/usr/bin/env bash
# Surface: lane_launch_line's scrub of the launching session's identity,
# LANE_LAUNCH_SCRUB in lib/lane-launch.sh. A tmux window takes the server's
# environment, so the rendered line is what clears the parent's identity on
# that route; the detached route is open-terminal-mode.sh's and the hosted one
# open-terminal-lane-hosted.sh's. Each row runs the line as open-terminal's
# launch_finish wraps a local launch, under a parent environment holding every
# listed name, and reads the child's environment from a harness fixture.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${LAUNCH_LIB_UNDER_TEST:-$TEST_DIR/../scripts/lib}"

# A real tmux route keeps shell initialization and custom functions intact.
# The server, rather than only the launcher process, holds the parent identity.
if [[ "${1:-}" == --raw-case ]]; then
  ROOT="$2" OT="$3" PANE_SHELL="$4" DEFAULT_COMMAND="$5"
  source "$TEST_DIR/lib/open-terminal-stubs.sh"
  source "$LIB/lane-launch.sh"
  REAL_TMUX="$(command -v tmux)" || exit 1
  mkdir -p "$ROOT/bin" "$ROOT/real-bin" "$ROOT/home/.config/fish"
  ot_stub_bin "$ROOT/bin"
  printf '#!%s\nexec %q -S %q "$@"\n' "$BASH" "$REAL_TMUX" "$ROOT/socket" > "$ROOT/real-bin/tmux"
  chmod +x "$ROOT/real-bin/tmux"
  cat > "$ROOT/bin/probe" <<'STUB'
#!/usr/bin/env bash
held=""
for identity_name in $SCRUB_NAMES; do
  [[ -z "${!identity_name+set}" ]] || held+="$identity_name,"
done
printf 'held=%s|origin=%s|function=called\n' "${held:--}" "${KENDEX_LANE_ORIGIN-unset}" > "$PROBE_RESULT"
STUB
  chmod +x "$ROOT/bin/probe"
  printf 'raw_probe() { %q; }\n' "$ROOT/bin/probe" > "$ROOT/home/.bash_profile"
  cp "$ROOT/home/.bash_profile" "$ROOT/bashrc"
  printf 'function raw_probe\n  %s\nend\n' "$ROOT/bin/probe" > "$ROOT/home/.config/fish/config.fish"
  parent=()
  for identity_name in "${LANE_LAUNCH_SCRUB[@]}"; do parent+=("$identity_name=parent-$identity_name"); done
  tm() { "$REAL_TMUX" -S "$ROOT/socket" "$@"; }
  trap 'tm kill-server 2>/dev/null || true' EXIT
  trap 'exit 143' TERM
  env -i PATH="$ROOT/real-bin:$ROOT/bin:$PATH" HOME="$ROOT/home" SHELL="$PANE_SHELL" \
    "${parent[@]}" SCRUB_NAMES="${LANE_LAUNCH_SCRUB[*]}" PROBE_RESULT="$ROOT/result" \
    "$REAL_TMUX" -S "$ROOT/socket" -f /dev/null new-session -d -s fixture -x 200 -y 50
  tm set-option -g default-shell "$PANE_SHELL"
  command=""
  if [[ "$DEFAULT_COMMAND" == configured ]]; then
    if [[ "${PANE_SHELL##*/}" == fish ]]; then command="exec $PANE_SHELL -i"
    else printf -v command 'exec %q --noprofile --rcfile %q -i' "$PANE_SHELL" "$ROOT/bashrc"; fi
  fi
  tm set-option -g default-command "$command"
  env -i PATH="$ROOT/real-bin:$ROOT/bin:$PATH" HOME="$ROOT/home" ORCH_TMUX_SESSION=fixture \
    ORCH_LANE_HOST=local ORCH_STATE_DIR="$ROOT/state" WORKTREE_CLI="$ROOT/bin/worktree" \
    OT_WT_LOG="$ROOT/worktree.log" OT_WT_FIXED="$ROOT/worktree" LINEAR_TEAM= \
    "$OT" --tmux --cmd raw_probe KEN-1 > "$ROOT/launch.log" 2>&1
  for i in {1..100}; do [[ ! -s "$ROOT/result" ]] || exit 0; sleep 0.02; done
  tm capture-pane -p -t fixture:KEN-1 >> "$ROOT/launch.log"
  exit 1
fi

TMP_ROOT="$(mktemp -d)" || { echo "lane-launch-scrub: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lane-launch-scrub: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lane-launch-scrub: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/growth-state.sh"
source "$TEST_DIR/lib/shared-skill-libs.sh"

# The shipped list, with the names KEN-3859 requires as its floor. Read from
# the shipped library even under the control, whose library lists none of it.
NAMES="$(env -i PATH="$PATH" "$BASH" -c 'source "$1/lane-launch.sh" && printf "%s " "${LANE_LAUNCH_SCRUB[@]}"' _ "$TEST_DIR/../scripts/lib")" \
  || { echo "lane-launch-scrub: list=unread" >&2; exit 1; }
for name in CLAUDECODE CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID JARVIS_RECORD JARVIS_GENERATION; do
  assert_contains " $NAMES" " $name " "the scrub list names $name"
done

# The harness prints which listed names it holds, its account variable named
# by ACCOUNT_VAR, the launch origin and its tmux pane.
mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/claude" <<'STUB'
#!/usr/bin/env bash
held=""
for name in $SCRUB_NAMES; do [[ -z "${!name+set}" ]] || held+="$name,"; done
printf 'held=%s|account=%s|origin=%s|pane=%s' "${held:--}" "${!ACCOUNT_VAR:-unset}" \
  "${KENDEX_LANE_ORIGIN:-unset}" "${TMUX_PANE:-unset}"
printf '|record=%s|generation=%s' "${JARVIS_RECORD:-unset}" "${JARVIS_GENERATION:-unset}"
STUB
chmod +x "$TMP_ROOT/bin/claude"
for harness in codex pi copilot; do cp "$TMP_ROOT/bin/claude" "$TMP_ROOT/bin/$harness"; done
# A lane's own launcher exports its account and runs the harness, as 1codex does.
cat > "$TMP_ROOT/bin/1codex" <<STUB
#!/usr/bin/env bash
export CODEX_HOME='$TMP_ROOT/account'
exec codex "\$@"
STUB
chmod +x "$TMP_ROOT/bin/1codex"

# render FORM HARNESS VAR [FLAGS] — the line launch_finish types into a local
# pane: a lane's under its picked account, or a custom command, which a Claude
# bypass flag gives env words of its own, so it runs under `bash -c`.
render() {
  env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT" "$BASH" -c '
    source "$1/lane-launch.sh"
    form="$2"; harness="$3"; var="$4"; root="$5"; flags="$6"
    [[ "$form" != launcher ]] || form="launcher:$root/bin/1$harness"
    dir=""
    [[ -z "$var" ]] || dir="$root/account"
    cmd="$harness"
    [[ "$form" != custom ]] || cmd="true && exec $harness $flags"
    child_env=""
    if [[ "$7" == explicit ]]; then
      child_env="JARVIS_RECORD=$(lane_single_quote "$root/child record.json") JARVIS_GENERATION=7"
      line="$(lane_launch_line "$cmd" "$harness" "$var" "$dir" "$form" "" "$child_env")" || exit
    else
      line="$(lane_launch_line "$cmd" "$harness" "$var" "$dir" "$form")" || exit
    fi
    printf "export KENDEX_LANE_ORIGIN=%s && export KENDEX_USER_EMAIL=%s && %s" \
      "$(lane_single_quote "$root/wt")" "$(lane_single_quote "")" "$line"
  ' _ "$LIB" "$1" "$2" "$3" "$TMP_ROOT" "${4:-}" "${5:-}"
}

# FORM|HARNESS|ACCOUNT VAR (- for none)|FLAGS|LABEL|CHILD_ENV
printf '%s\n' \
  'prefix|claude|CLAUDE_CONFIG_DIR||Claude lane under the prefix' \
  'launcher|codex|CODEX_HOME||Codex lane through its launcher' \
  'prefix|copilot|COPILOT_HOME||Copilot lane' \
  'unchecked|pi|-||no lane picked' \
  'custom|claude|CLAUDE_CONFIG_DIR||custom command under an account' \
  'custom|claude|-|--permission-mode=bypassPermissions|custom command under launch env words' \
  'prefix|claude|CLAUDE_CONFIG_DIR||explicit Jarvis child identity|explicit' \
  > "$TMP_ROOT/rows"
while IFS='|' read -r form harness var flags label child_env; do
  account_var="${var#-}"
  line="$(render "$form" "$harness" "$account_var" "$flags" "$child_env")"
  # The parent's own account stands in the environment too: a picked lane's
  # variable is set after the scrub and wins.
  parent=(TMUX=parent-server TMUX_PANE=%9 CLAUDE_CONFIG_DIR=/parent CODEX_HOME=/parent COPILOT_HOME=/parent)
  for name in $NAMES; do parent+=("$name=parent-$name"); done
  got="$(env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT" "${parent[@]}" \
    SCRUB_NAMES="$NAMES" ACCOUNT_VAR="${account_var:-CLAUDE_CONFIG_DIR}" "$BASH" -c "$line")"
  account=/parent
  [[ -z "$account_var" ]] || account="$TMP_ROOT/account"
  identity='held=-'; record=unset; generation=unset
  if [[ "$child_env" == explicit ]]; then
    identity='held=JARVIS_RECORD,JARVIS_GENERATION,'
    record="$TMP_ROOT/child record.json"; generation=7
  fi
  assert_eq "$got" "$identity|account=$account|origin=$TMP_ROOT/wt|pane=%9|record=$record|generation=$generation" "$label: child environment"
done < "$TMP_ROOT/rows"

# Execute the launch in each configured shell, including a default-command
# that initializes the custom function. A bounded child owns each tmux server.
if [[ -z "${LAUNCH_LIB_UNDER_TEST:-}" ]]; then
  raw_case() { # NAME SCRIPT SHELL DEFAULT_COMMAND EXPECTED_HELD
    local case_name="$1" script="$2" shell="$3" command="$4" held="$5" rc=0 actual=missing
    local root="$TMP_ROOT/$case_name"
    mkdir -p "$root"
    timeout 20 "$BASH" "$TEST_DIR/open-terminal-lane-launch-scrub.sh" --raw-case "$root" "$script" "$shell" "$command" > "$root/log" 2>&1 || rc=$?
    [[ ! -f "$root/result" ]] || actual="$(cat "$root/result")"
    [[ ! -f "$root/launch.log" ]] || cat "$root/launch.log" >> "$root/log"
    assert_eq "exit=$rc $actual" "exit=0 held=$held|origin=$root/worktree|function=called" \
      "$case_name: raw tmux custom function keeps its shell and clears identity" "$root/log"
  }
  RAW_SHELLS="$BASH"
  if fish_path="$(command -v fish)"; then RAW_SHELLS+=$'\n'"$fish_path"; fi
  while IFS= read -r shell; do
    for command in login configured; do
      raw_case "${shell##*/}-$command" "$TEST_DIR/../scripts/open-terminal" "$shell" "$command" -
    done
  done <<< "$RAW_SHELLS"
  RAW_CONTROL="$(mutant_scripts raw-shell-scrub lib/lane-launch.sh)" || exit 1
  orch_fixture_shared_libs "${RAW_CONTROL%/scripts}"
  mutate_file "$RAW_CONTROL/lib/lane-launch.sh" \
    'for name in "${LANE_LAUNCH_SCRUB[@]}"; do LANE_LAUNCH_SHELL_ARGV+=(-u "$name"); done' \
    'for name in KEN_3859_CONTROL; do LANE_LAUNCH_SHELL_ARGV+=(-u "$name"); done'
  SAVED_FAIL="$FAIL"
  FAIL=0
  raw_case control-raw "$RAW_CONTROL/open-terminal" "$BASH" configured - > "$TMP_ROOT/raw-control.out"
  RAW_CONTROL_FAIL="$FAIL"
  FAIL="$SAVED_FAIL"
  assert_eq "$RAW_CONTROL_FAIL" 1 'control: a raw tmux launch without pane scrubbing fails the identity assertion'
  assert_contains "$(cat "$TMP_ROOT/raw-control.out")" "held=${NAMES// /,}|" \
    'control: the raw custom function receives every parent identity name'
fi

# Must-fail control: a scrub list naming none of the shipped names leaves every
# one of them in the child. Copy all library dependencies.
if [[ -z "${LAUNCH_LIB_UNDER_TEST:-}" ]]; then
  cp -R "$LIB" "$TMP_ROOT/child-mutant-lib"
  python3 - "$TMP_ROOT/child-mutant-lib/lane-launch.sh" <<'PYCONTROL'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
old = '  [[ -z "${7:-}" ]] || scrub+=" $7"'
text = path.read_text()
assert text.count(old) == 1
changed = text.replace(old, '  [[ -z "${7:-}" ]] || :')
assert changed != text
path.write_text(changed)
PYCONTROL
  rc=0
  env LAUNCH_LIB_UNDER_TEST="$TMP_ROOT/child-mutant-lib" "$BASH" "$TEST_DIR/open-terminal-lane-launch-scrub.sh" > "$TMP_ROOT/child-control.out" 2>&1 || rc=$?
  assert_eq "$rc" 1 'control: omitting explicit child assignments fails the suite'
  assert_contains "$(cat "$TMP_ROOT/child-control.out")" '  FAIL  explicit Jarvis child identity: child environment' \
    'control: the child row rejects missing identity values'
  cp -R "$LIB" "$TMP_ROOT/mutant-lib"
  python3 - "$TMP_ROOT/mutant-lib/lane-launch.sh" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
old = "LANE_LAUNCH_SCRUB=(\n"
text = path.read_text()
assert text.count(old) == 1
changed = text.replace(old, "LANE_LAUNCH_SCRUB=(KEN_3859_CONTROL)\nLANE_LAUNCH_SCRUB_SHIPPED=(\n")
assert changed != text
path.write_text(changed)
PY
  rc=0
  env LAUNCH_LIB_UNDER_TEST="$TMP_ROOT/mutant-lib" "$BASH" "$TEST_DIR/open-terminal-lane-launch-scrub.sh" > "$TMP_ROOT/control.out" 2>&1 || rc=$?
  assert_eq "$rc" 1 'control: a launch line without the scrub fails the suite'
  control="$(cat "$TMP_ROOT/control.out")"
  for label in 'Claude lane under the prefix' 'custom command under launch env words'; do
    assert_contains "$control" "  FAIL  $label: child environment" "control: $label reds"
  done
  assert_contains "$control" "held=${NAMES// /,}|" 'control: the child holds every listed name'
fi
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
