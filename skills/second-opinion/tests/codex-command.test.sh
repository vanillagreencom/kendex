#!/usr/bin/env bash
# The built-in Codex target: the argv it receives, where `--disable hooks` keeps
# the project's Codex hooks out of the nested review, and how its usage-limit
# refusal is recorded.
. "$(dirname "${BASH_SOURCE[0]}")/lib/roster-world.bash"
EXPECTED=$'exec\n-s\nread-only\n-c\nmodel_reasoning_effort=xhigh\n--ephemeral\n--disable\nhooks\n--json'
for row in default example project version-control env-codex copilot opaque copilot-control; do
  build "$row" current:none models:codex
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >"%s/argv"\nexec "%s/bin/lane-codex" "$@"\n' "$ROW" "$ROW" >"$ROW/bin/codex"
  chmod +x "$ROW/bin/codex"
  want="$EXPECTED"
  case "$row" in
    default) ;;
    example) cp "$SKILL_DIR/kendex.settings.toml.example" "$PROJ/kendex.settings.toml"; want=$'exec\n-m\ngpt-6.1-sol\n-s\nread-only\n-c\nmodel_reasoning_effort=xhigh\n--disable\nhooks\n--ephemeral\n--disable\nhooks\n--json' ;;
    # The row alone: the project's Codex room check needs the fleet's accounts.
    project) { echo '[env]'; grep '^SECOND_OPINION_CODEX_CMD = ' "$SKILL_DIR/../../kendex.settings.toml"; } >"$PROJ/kendex.settings.toml"; want=$'exec\n-m\ngpt-6.1-sol\n-s\nread-only\n-c\nmodel_reasoning_effort=xhigh\n--disable\nhooks\n--ephemeral\n--disable\nhooks\n--json' ;;
    version-control) mutate_script "$SO" 'DEFAULT_CODEX_CMD="codex exec -s' 'DEFAULT_CODEX_CMD="codex exec -m gpt-6.1-sol -s' ;;
    env-codex) W_ENV+=("SECOND_OPINION_CODEX_CMD=env -u SO_TEST_UNSET SO_TEST_PREFIX=1 $ROW/bin/codex exec -s read-only -c model_reasoning_effort=xhigh --ephemeral") ;;
    copilot|opaque|copilot-control)
      program=1copilot
      [[ $row != opaque ]] || program=review-wrapper
      cat >"$ROW/bin/$program" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
root=${0%/bin/*}
printf '%s\n' "$@" >"$root/argv"
printf '%s' "${COPILOT_ALLOW_ALL:-unset}" >"$root/allow-all"
for arg in "$@"; do
  case "$arg" in --disable|--json) exit 1 ;; esac
done
exec "$root/bin/lane-codex" "$@"
SH
      chmod +x "$ROW/bin/$program"
      W_ENV+=("SECOND_OPINION_CODEX_CMD=env COPILOT_ALLOW_ALL=false $program --model gpt-6.1-sol --reasoning-effort medium --silent --no-ask-user --disable-builtin-mcps --available-tools bash view rg glob --deny-tool write")
      want=$'--model\ngpt-6.1-sol\n--reasoning-effort\nmedium\n--silent\n--no-ask-user\n--disable-builtin-mcps\n--available-tools\nbash\nview\nrg\nglob\n--deny-tool\nwrite'
      [[ $row != copilot-control ]] || mutate_script "$SO" '[[ ${program##*/} != codex ]]' '[[ $(harness_model "$TARGET_CLI") != codex ]]'
      ;;
  esac
  rc=0
  env -i HOME="$ROW" PATH="$ROW/bin:$PATH" ${W_ENV[@]+"${W_ENV[@]}"} "$SO" review --range HEAD --cwd "$WORK" --output "$ROW/out/out.json" >"$ROW/stdout" 2>"$ROW/stderr" || rc=$?
  got="$rc:$(jq -r '.verdict' "$ROW/out/out.json" 2>/dev/null || printf missing)"
  if [[ $row == copilot-control ]]; then
    assert_eq "$got" 5:missing "$row rejects foreign flags before artifact creation"
    assert_eq "$(cat "$ROW/argv")" "$want"$'\n--disable\nhooks\n--json' "$row restores target-name flag injection"
    control_rc=0
    (FAIL=0; assert_eq "$got" 0:pass "must-fail: $row artifact"; [[ "$FAIL" -eq 0 ]]) || control_rc=$?
    assert_eq "$control_rc" 1 "$row turns the usable artifact check red"
    continue
  fi
  assert_eq "$got" 0:pass "$row run writes a usable review artifact"
  case "$row" in copilot|opaque) assert_eq "$(cat "$ROW/allow-all")" false "$row keeps configured write restriction" ;; esac
  if [[ "$row" != *control ]]; then assert_eq "$(cat "$ROW/argv")" "$want" "$row backend argv"; continue; fi
  control_rc=0
  (assert_eq "$(cat "$ROW/argv")" "$EXPECTED" "must-fail: $row"; [[ "$FAIL" -eq 0 ]]) || control_rc=$?
  assert_eq "$control_rc" 1 "$row turns the argv pin red"
done

# VG-612 and HT-2311 configured Codex without --disable hooks. Human output
# showed their verdict only on stderr before a read-only handoff and Stop loop.
# The writer injects that OS error; the CLI models Codex's documented event
# transport, not the wrapper's parser. The one blocking sleep models an uncleared
# Stop and is bounded by the real wrapper timeout in its owned process group.
while IFS='|' read -r row answer mutation want_rc want_verdict want_hook; do
  build "$row" current:none models:codex timeout:3
  W_ENV+=("SECOND_OPINION_CODEX_CMD=$ROW/bin/codex exec -m gpt-6.1-sol -s read-only -c model_reasoning_effort=high --ephemeral")
  [[ $mutation != failed* ]] || W_ENV+=(SO_TEST_CLI_EXIT=1)
  response "$answer" codex >"$ROW/review"
  cat >"$ROW/bin/write-artifact" <<'SH'
#!/usr/bin/env bash
printf 'attempt\n' >"${0%/bin/write-artifact}/write-attempt"
printf 'write=read-only\nRead-only file system\n' >&2
exit 1
SH
  cat >"$ROW/bin/lane-mail-check" <<'SH'
#!/usr/bin/env bash
printf 'blocked\n' >"${0%/bin/lane-mail-check}/stop-hook"
printf 'lane-mail-check: context=600000\n' >&2
exit 2
SH
  cat >"$ROW/bin/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
root=${0%/bin/codex}
[[ ${SO_TEST_CLI_EXIT:-0} == 0 ]] || exec 2>/dev/null
cat >/dev/null
hooks=true; json=false
printf '%s\n' "$@" >"$root/argv"
while [[ $# -gt 0 ]]; do
  if [[ $1 == --disable && ${2:-} == hooks ]]; then hooks=false; fi
  [[ $1 != --json ]] || json=true
  shift
done
if $json; then
  printf '{"type":"thread.started","thread_id":"review"}\n'
  # A tool/prompt echo is never an assistant verdict.
  jq -cn --rawfile text "$root/resp-codex" '{type:"item.completed",item:{type:"command_execution",aggregated_output:$text}}'
  if [[ -s $root/review ]]; then
    jq -cn --rawfile text "$root/review" '{type:"item.completed",item:{type:"agent_message",text:$text}}'
  fi
else
  cat "$root/review" >&2
fi
"$root/bin/write-artifact" || :
if $hooks && ! "$root/bin/lane-mail-check"; then sleep 30; fi
if $json; then
  if [[ ${SO_TEST_CLI_EXIT:-0} == 0 ]]; then printf '{"type":"turn.completed"}\n'
  else printf '{"type":"turn.failed","error":{"message":"upstream error"}}\n'; fi
fi
exit "${SO_TEST_CLI_EXIT:-0}"
SH
  chmod +x "$ROW/bin/codex" "$ROW/bin/write-artifact" "$ROW/bin/lane-mail-check"
  case "$mutation" in
    old) mutate_script "$SO" 'cmd="$cmd --disable hooks --json"' ': # retained command policy: --disable hooks --json' ;;
    text) mutate_script "$SO" 'cmd="$cmd --disable hooks --json"' 'cmd="$cmd --disable hooks" # retained transport: --json' ;;
    failed-control) mutate_script "$SO" 'if [[ $EXIT_CODE -eq 0 ]]; then unwrap_codex_events; fi' 'unwrap_codex_events # retained success guard: $EXIT_CODE -eq 0' ;;
  esac
  result=$(run review)
  assert_eq "${result%% *}" "rc=$want_rc" "$row exit"
  assert_eq "$(cat "$ROW/write-attempt")" attempt "$row attempted read-only artifact write"
  hook=none
  [[ ! -f "$ROW/stop-hook" ]] || hook=$(cat "$ROW/stop-hook")
  assert_eq "$hook" "$want_hook" "$row Stop hook reach"
  if [[ $want_rc == 0 ]]; then
    assert_eq "$(jq -r '.verdict' "$ROW/out/out.json")" "$want_verdict" "$row printed verdict recorded"
    assert_eq "$(jq -r '.qa_metadata.attempts[0] | .cause == "answered" and .seconds < 3' "$ROW/out/out.json")" true "$row ends before timeout"
    assert_eq "$(grep -A1 -- '^-s$' "$ROW/argv")" $'-s\nread-only' "$row keeps read-only sandbox"
  else
    assert_eq "$(jq -r '.attempts[0].cause' "$ROW/out/out.json.failed.json")" "$want_verdict" "$row preserves failed record"
    assert_eq "$([[ -e "$ROW/out/out.json" ]] && printf present || printf absent)" absent "$row writes no verdict"
    if [[ $mutation == failed* ]]; then
      # Codex errors can be stdout events alone. Preserve the original stream,
      # including an earlier assistant answer, without accepting it as a verdict.
      got=$(jq -r '.cause_source == "codex stdout" and (.partial_stdout | contains("\"turn.failed\""))' "$ROW/out/out.json.failed.json")
      if [[ $mutation == failed-control ]]; then
        control_rc=0
        (assert_eq "$got" true "must-fail: $row"; [[ $FAIL -eq 0 ]]) || control_rc=$?
        assert_eq "$control_rc" 1 "$row turns failure preservation red"
      else assert_eq "$got" true "$row preserves the stdout error events"; fi
    fi
  fi
done <<'ROWS'
override-pass|clean|-|0|pass|none
override-blocker|parse|-|0|action_required|none
no-verdict|empty|-|5|answered|none
nonzero-events|clean|failed|5|exit-1|none
nonzero-events-control|clean|failed-control|5|exit-1|none
old-wrapper-control|clean|old|5|timeout|blocked
human-output-control|clean|text|5|answered|none
ROWS

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
