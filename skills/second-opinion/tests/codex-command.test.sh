#!/usr/bin/env bash
# The built-in Codex target: the argv it receives, where `--disable hooks` keeps
# the project's Codex hooks out of the nested review, and how its usage-limit
# refusal is recorded.
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

# Codex's usage-limit refusal: exit 1, a stderr whose prompt echo fills the
# first 20 lines, then its ERROR: line with a curly apostrophe. The attempt is
# a quota refusal, the run says so, and the record's cause keeps the line.
LIMIT_LINE='ERROR: You’ve hit your usage limit. Visit https://chatgpt.com/settings/usage to purchase more credits or try again at Oct 22nd, 2026 6:30 AM.'
LIMIT_WANT="rc=5 attempts=quota reason=reported a quota/rate-limit refusal error=[\"$LIMIT_LINE\"]"
for row in usage-limit usage-limit-control; do
  build "$row" current:none models:codex
  printf '#!/usr/bin/env bash\ncat >/dev/null\nfor i in $(seq 25); do echo "- Changed files: echoed prompt line $i"; done >&2\nprintf "%%s\\n" %q >&2\nexit 1\n' "$LIMIT_LINE" >"$ROW/bin/codex"
  chmod +x "$ROW/bin/codex"
  [[ "$row" != *control ]] || mutate_script "$SO" "You('|’)ve hit" "You've hit"
  result=$(run review)
  got=$(jq -r --arg rc "${result%% *}" '"\($rc) attempts=\([.attempts[].cause] | join(",")) reason=\(.reason) error=\(.cause | split("\n") | map(select(startswith("ERROR:"))) | tojson)"' "$ROW/out/out.json.failed.json")
  if [[ "$row" != *control ]]; then assert_eq "$got" "$LIMIT_WANT" "a codex usage-limit refusal at exit 1 records quota and keeps its ERROR line"; continue; fi
  control_rc=0
  (assert_eq "$got" "$LIMIT_WANT" "must-fail: $row"; [[ "$FAIL" -eq 0 ]]) || control_rc=$?
  assert_eq "$control_rc" 1 "$row turns the usage-limit row red"
done
finish
