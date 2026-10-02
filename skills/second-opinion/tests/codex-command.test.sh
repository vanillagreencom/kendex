#!/usr/bin/env bash
# Pin the argv the built-in Codex target receives, not its help text.
# `--disable hooks` keeps the project's Codex hooks out of the nested review.
. "$(dirname "${BASH_SOURCE[0]}")/lib/roster-world.bash"
EXPECTED=$'exec\n-m\ngpt-6.1-sol\n-s\nread-only\n-c\nmodel_reasoning_effort=xhigh\n--disable\nhooks\n--ephemeral'
# The control retains the flag text but removes it from the executable default.
ROWS='-
example
project
--disable hooks'
i=0
while IFS= read -r change; do
  i=$((i + 1))
  build "argv-$i" current:none models:codex
  cat >"$ROW/bin/codex" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$@" >"$ROW/argv"
exec "$ROW/bin/lane-codex" "\$@"
SH
  chmod +x "$ROW/bin/codex"
  case "$change" in
    -) ;;
    example) cp "$SKILL_DIR/kendex.settings.toml.example" "$PROJ/kendex.settings.toml" ;;
    # The row alone: the project's Codex room check needs the fleet's accounts.
    project) { echo '[env]'; grep '^SECOND_OPINION_CODEX_CMD = ' "$SKILL_DIR/../../kendex.settings.toml"; } >"$PROJ/kendex.settings.toml" ;;
    *)
      python3 - "$SO" "$change" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
assert not path.is_symlink()
text = path.read_text()
lines = [line for line in text.splitlines() if line.startswith('DEFAULT_CODEX_CMD=')]
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
  rc=0
  env -i HOME="$ROW" PATH="$ROW/bin:$PATH" ${W_ENV[@]+"${W_ENV[@]}"} "$SO" quick --cwd "$WORK" --output "$ROW/out/out.json" "inspect file.txt" >"$ROW/stdout" 2>"$ROW/stderr" || rc=$?
  assert_eq "$rc" 0 "$change returns a usable reply"
  got="$(cat "$ROW/argv")"
  case "$change" in
    -|example|project) assert_eq "$got" "$EXPECTED" "$change argv" ;;
    *)
      control_rc=0
      (assert_eq "$got" "$EXPECTED" "must-fail: $change"; [[ "$FAIL" -eq 0 ]]) || control_rc=$?
      assert_eq "$control_rc" 1 "$change control turns the argv pin red"
      ;;
  esac
done <<<"$ROWS"
help_text="$("$SO" --help)"
help_cmd="$(awk '/^  codex:/ { on=1; sub(/^  codex: /, "") } on && /^          The/ { exit } on { gsub(/^ +/, ""); printf "%s ", $0 }' <<<"$help_text")"
assert_eq "${help_cmd% }" "codex ${EXPECTED//$'\n'/ }" "help exposes the same default command"
finish
