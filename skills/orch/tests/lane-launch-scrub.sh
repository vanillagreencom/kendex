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
TMP_ROOT="$(mktemp -d)" || { echo "lane-launch-scrub: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lane-launch-scrub: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lane-launch-scrub: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"

# The shipped list, with the names KEN-3859 requires as its floor. Read from
# the shipped library even under the control, whose library lists none of it.
NAMES="$(env -i PATH="$PATH" "$BASH" -c 'source "$1/lane-launch.sh" && printf "%s " "${LANE_LAUNCH_SCRUB[@]}"' _ "$TEST_DIR/../scripts/lib")" \
  || { echo "lane-launch-scrub: list=unread" >&2; exit 1; }
for name in CLAUDECODE CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID JARVIS_RECORD; do
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
    line="$(lane_launch_line "$cmd" "$harness" "$var" "$dir" "$form")" || exit
    printf "export KENDEX_LANE_ORIGIN=%s && export KENDEX_USER_EMAIL=%s && %s" \
      "$(lane_single_quote "$root/wt")" "$(lane_single_quote "")" "$line"
  ' _ "$LIB" "$1" "$2" "$3" "$TMP_ROOT" "${4:-}"
}

# FORM|HARNESS|ACCOUNT VAR (- for none)|FLAGS|LABEL
printf '%s\n' \
  'prefix|claude|CLAUDE_CONFIG_DIR||Claude lane under the prefix' \
  'launcher|codex|CODEX_HOME||Codex lane through its launcher' \
  'prefix|copilot|COPILOT_HOME||Copilot lane' \
  'unchecked|pi|-||no lane picked' \
  'custom|claude|CLAUDE_CONFIG_DIR||custom command under an account' \
  'custom|claude|-|--dangerously-skip-permissions|custom command under launch env words' \
  > "$TMP_ROOT/rows"
while IFS='|' read -r form harness var flags label; do
  account_var="${var#-}"
  line="$(render "$form" "$harness" "$account_var" "$flags")"
  # The parent's own account stands in the environment too: a picked lane's
  # variable is set after the scrub and wins.
  parent=(TMUX=parent-server TMUX_PANE=%9 CLAUDE_CONFIG_DIR=/parent CODEX_HOME=/parent COPILOT_HOME=/parent)
  for name in $NAMES; do parent+=("$name=parent-$name"); done
  got="$(env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT" "${parent[@]}" \
    SCRUB_NAMES="$NAMES" ACCOUNT_VAR="${account_var:-CLAUDE_CONFIG_DIR}" "$BASH" -c "$line")"
  account=/parent
  [[ -z "$account_var" ]] || account="$TMP_ROOT/account"
  assert_eq "$got" "held=-|account=$account|origin=$TMP_ROOT/wt|pane=%9" "$label: child environment"
done < "$TMP_ROOT/rows"

# Must-fail control: a scrub list naming none of the shipped names leaves every
# one of them in the child. Copy all library dependencies.
if [[ -z "${LAUNCH_LIB_UNDER_TEST:-}" ]]; then
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
  env LAUNCH_LIB_UNDER_TEST="$TMP_ROOT/mutant-lib" "$BASH" "$TEST_DIR/lane-launch-scrub.sh" > "$TMP_ROOT/control.out" 2>&1 || rc=$?
  assert_eq "$rc" 1 'control: a launch line without the scrub fails the suite'
  control="$(cat "$TMP_ROOT/control.out")"
  for label in 'Claude lane under the prefix' 'custom command under launch env words'; do
    assert_contains "$control" "  FAIL  $label: child environment" "control: $label reds"
  done
  assert_contains "$control" "held=${NAMES// /,}|" 'control: the child holds every listed name'
fi
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
