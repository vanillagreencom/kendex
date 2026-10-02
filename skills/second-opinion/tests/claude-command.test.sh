#!/usr/bin/env bash
# Pin the argv the built-in Claude target receives, not its help text.
# The host probe checks enforcement; this fixture checks dispatch in every mode.
. "$(dirname "${BASH_SOURCE[0]}")/lib/roster-world.bash"
EXPECTED=$'-p\n--no-session-persistence\n--model\nclaude-opus-5-5\n--effort\nhigh\n--restricted\n--permission-mode\ndontAsk\n--tools\nBash,Read,Glob,Grep\n--allowedTools\nBash(read-only:true),Read,Glob,Grep\n--setting-sources='
# Each control retains the flag text but removes it from the executable default.
ROWS='review|-
audit|-
challenge|-
quick|-
quick|override
quick|example
quick|project
quick|--permission-mode dontAsk
quick|--tools Bash,Read,Glob,Grep
quick|--restricted
quick|--setting-sources='
i=0
while IFS='|' read -r mode change; do
  i=$((i + 1))
  build "argv-$i" current:none models:claude
  mkdir -p "$ROW/.claude"
  printf '{"permissions":{"defaultMode":"bypassPermissions"}}\n' >"$ROW/.claude/settings.json"
  cat >"$ROW/bin/claude" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$@" >"$ROW/argv"
exec "$ROW/bin/lane-claude" "\$@"
SH
  chmod +x "$ROW/bin/claude"
  want="$EXPECTED"
  case "$change" in
    -) ;;
    override) W_ENV+=("SECOND_OPINION_CLAUDE_CMD=claude --custom-command"); want=--custom-command ;;
    example) cp "$SKILL_DIR/kendex.settings.toml.example" "$PROJ/kendex.settings.toml" ;;
    project) cp "$SKILL_DIR/../../kendex.settings.toml" "$PROJ/kendex.settings.toml" ;;
    *)
      python3 - "$SO" "$change" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
assert not path.is_symlink()
text = path.read_text()
lines = [line for line in text.splitlines() if line.startswith('DEFAULT_CLAUDE_CMD=')]
assert len(lines) == 1
old = lines[0]
flag = ' ' + sys.argv[2]
assert old.count(flag) == 1
new = old.replace(flag, '') + '\n# retained control text: ' + sys.argv[2]
changed = text.replace(old, new)
assert changed != text
path.write_text(changed)
PY
      ;;
  esac
  args=("$mode" --cwd "$WORK" --output "$ROW/out/out.json")
  if [[ "$mode" == review ]]; then args+=(--range HEAD); else args+=("inspect file.txt"); fi
  rc=0
  env -i HOME="$ROW" PATH="$ROW/bin:$PATH" ${W_ENV[@]+"${W_ENV[@]}"} "$SO" "${args[@]}" >"$ROW/stdout" 2>"$ROW/stderr" || rc=$?
  assert_eq "$rc" 0 "$mode/$change returns a usable reply"
  assert_eq "$(jq -r .summary "$ROW/out/out.json")" clean "$mode/$change preserves the reply"
  got="$(cat "$ROW/argv")"
  case "$change" in
    -|override|example|project) assert_eq "$got" "$want" "$mode/$change argv under a bypass default" ;;
    *)
      control_rc=0
      (assert_eq "$got" "$want" "must-fail: $change"; [[ "$FAIL" -eq 0 ]]) || control_rc=$?
      assert_eq "$control_rc" 1 "$change control turns the argv pin red"
      ;;
  esac
done <<<"$ROWS"
help_text="$("$SO" --help)"
help_cmd="$(awk '/^  claude:/ { on=1; sub(/^  claude: /, "") } on && /^          Bash/ { exit } on { gsub(/^ +/, ""); printf "%s ", $0 }' <<<"$help_text")"
assert_eq "${help_cmd% }" "claude ${EXPECTED//$'\n'/ }" "help exposes the same default command"
finish
