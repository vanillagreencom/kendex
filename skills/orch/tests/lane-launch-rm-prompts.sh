#!/usr/bin/env bash
# Surface: lane_launch_line and ol_command_line's Claude rm-prompt environment.
# The provider reads these variables before settings. Execute the rendered
# commands with a harness fixture to prove the variables reach the process.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${LAUNCH_LIB_UNDER_TEST:-$TEST_DIR/../scripts/lib}"
TMP_ROOT="$(mktemp -d)" || { echo "lane-launch-rm-prompts: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lane-launch-rm-prompts: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lane-launch-rm-prompts: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"

mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/claude" <<'STUB'
#!/bin/sh
printf '%s|%s' "${CLAUDE_CODE_DISABLE_INLINE_SHELL_RM_PROMPT:-unset}" "${CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT:-unset}"
STUB
chmod +x "$TMP_ROOT/bin/claude"
for harness in codex pi opencode copilot; do cp "$TMP_ROOT/bin/claude" "$TMP_ROOT/bin/$harness"; done

render() { # LIB FORM HARNESS FLAGS
  env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT" "$BASH" -c '
    source "$1/lane-launch.sh"
    source "$1/overseer-launch.sh"
    form="$2"; harness="$3"; flags="$4"; root="$5"; DEP_ERR="$5/dep.err"
    if [[ "$form" == overseer ]]; then
      cd -- "$root"
      # ol_command_line consumes readiness from lane_trust_prepare. This
      # fixture supplies the no-home result to exercise that command branch.
      lane_trust_prepare() { LANE_TRUST_HOME=""; LANE_TRUST_ROUTE=none; }
      read -r -a words <<<"$flags"
      ol_command_line "$harness" tmp/handoff.md "" "$root" "${words[@]}" || exit
      printf "%s" "$OL_CMD"
    else
      [[ "$form" != launcher ]] || form="launcher:$root/bin/$harness"
      lane_launch_line "$harness $flags" "$harness" CLAUDE_CONFIG_DIR "$root/account" "$form"
    fi
  ' _ "$1" "$2" "$3" "$4" "$TMP_ROOT"
}

while IFS='|' read -r form harness flags inline substitution label; do
  want="$inline|$substitution"
  line="$(render "$LIB" "$form" "$harness" "$flags")"
  if [[ "$want" == '1|1' ]]; then
    assert_contains "$line" 'CLAUDE_CODE_DISABLE_INLINE_SHELL_RM_PROMPT=1' "$label: inline launch word"
    assert_contains "$line" 'CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT=1' "$label: substitution launch word"
  else
    assert_not_contains "$line" CLAUDE_CODE_DISABLE_INLINE_SHELL_RM_PROMPT "$label: no inline launch word"
    assert_not_contains "$line" CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT "$label: no substitution launch word"
  fi
  got="$(env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT" "$BASH" -c "$line")"
  assert_eq "$got" "$want" "$label: process environment"
done <<'ROWS'
launcher|claude|--dangerously-skip-permissions|1|1|Claude bypass launcher
prefix|claude|--dangerously-skip-permissions|1|1|Claude bypass prefix
launcher|claude|--permission-mode=bypassPermissions|1|1|Claude attached bypass launcher
prefix|claude|--permission-mode bypassPermissions|1|1|Claude separate bypass prefix
overseer|claude|--dangerously-skip-permissions|1|1|Claude bypass overseer without home
overseer|claude|--permission-mode=bypassPermissions|1|1|Claude attached bypass overseer without home
launcher|claude|--permission-mode=dontAsk|unset|unset|Claude dontAsk launcher
prefix|claude|--model fable|unset|unset|Claude without bypass
overseer|claude|--permission-mode=dontAsk|unset|unset|Claude dontAsk overseer without home
prefix|claude|-- '--dangerously-skip-permissions'|unset|unset|Claude bypass text after option delimiter
prefix|codex|--dangerously-bypass-approvals-and-sandbox|unset|unset|Codex bypass prefix
launcher|codex|--dangerously-bypass-approvals-and-sandbox|unset|unset|Codex bypass launcher
prefix|pi|--dangerously-skip-permissions|unset|unset|Pi command
prefix|opencode|--dangerously-skip-permissions|unset|unset|OpenCode command
prefix|copilot|--allow-all|unset|unset|Copilot bypass command
ROWS

# Drop both env words while retaining their text. The first launch assertion
# must fail, and the suite must return nonzero. Copy all library dependencies.
if [[ -z "${LAUNCH_LIB_UNDER_TEST:-}" ]]; then
  cp -R "$LIB" "$TMP_ROOT/mutant-lib"
  python3 - "$TMP_ROOT/mutant-lib/lane-launch.sh" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
old = "printf 'CLAUDE_CODE_DISABLE_INLINE_SHELL_RM_PROMPT=1 CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT=1'"
text = path.read_text()
assert text.count(old) == 1
changed = text.replace(old, old.replace("printf", ":", 1))
assert changed != text
path.write_text(changed)
PY
  rc=0
  env LAUNCH_LIB_UNDER_TEST="$TMP_ROOT/mutant-lib" "$BASH" "$TEST_DIR/lane-launch-rm-prompts.sh" > "$TMP_ROOT/control.out" 2>&1 || rc=$?
  assert_eq "$rc" 1 'control: dropping launch env words fails the suite'
  assert_contains "$(cat "$TMP_ROOT/control.out")" '  FAIL  Claude bypass launcher: inline launch word' 'control: the first bypass row rejects absent env words'
fi
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
