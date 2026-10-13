#!/usr/bin/env bash
# Pin the argv the built-in Codex target receives: `--disable hooks` keeps the
# project's Codex hooks out of the nested review.
. "$(dirname "${BASH_SOURCE[0]}")/lib/roster-world.bash"
EXPECTED=$'exec\n-s\nread-only\n-c\nmodel_reasoning_effort=xhigh\n--disable\nhooks\n--ephemeral'
for row in default example project control version-control; do
  build "$row" current:none models:codex
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >"%s/argv"\nexec "%s/bin/lane-codex" "$@"\n' "$ROW" "$ROW" >"$ROW/bin/codex"
  chmod +x "$ROW/bin/codex"
  want="$EXPECTED"
  case "$row" in
    default) ;;
    example) cp "$SKILL_DIR/kendex.settings.toml.example" "$PROJ/kendex.settings.toml"; want=$'exec\n-m\ngpt-6.1-sol\n'"${EXPECTED#*$'\n'}" ;;
    # The row alone: the project's Codex room check needs the fleet's accounts.
    project) { echo '[env]'; grep '^SECOND_OPINION_CODEX_CMD = ' "$SKILL_DIR/../../kendex.settings.toml"; } >"$PROJ/kendex.settings.toml"; want=$'exec\n-m\ngpt-6.1-sol\n'"${EXPECTED#*$'\n'}" ;;
    # The control retains the flag text but removes it from the executable default.
    control) mutate_script "$SO" ' --disable hooks --ephemeral"' ' --ephemeral" # retained control text: --disable hooks' ;;
    version-control) mutate_script "$SO" 'DEFAULT_CODEX_CMD="codex exec -s' 'DEFAULT_CODEX_CMD="codex exec -m gpt-6.1-sol -s' ;;
  esac
  rc=0
  env -i HOME="$ROW" PATH="$ROW/bin:$PATH" ${W_ENV[@]+"${W_ENV[@]}"} "$SO" quick --cwd "$WORK" --output "$ROW/out/out.json" "inspect file.txt" >"$ROW/stdout" 2>"$ROW/stderr" || rc=$?
  assert_eq "$rc" 0 "$row run returns a usable reply"
  if [[ "$row" != *control ]]; then assert_eq "$(cat "$ROW/argv")" "$want" "$row codex argv disables hooks"; continue; fi
  control_rc=0
  (assert_eq "$(cat "$ROW/argv")" "$EXPECTED" "must-fail: $row"; [[ "$FAIL" -eq 0 ]]) || control_rc=$?
  assert_eq "$control_rc" 1 "$row turns the argv pin red"
done
finish
