#!/usr/bin/env bash
# Ordered execution fall-through. The external CLI stubs produce real exits,
# timeout delays, and provider refusal codes. No dispatcher is stubbed.
# shellcheck source=lib/roster-world.bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/roster-world.bash"

DEFAULTS="ps:none current:none models:codex+claude+my-model count:1 cmd:codex=codex cmd:claude=claude cmd:my-model=extra"
FIRST='[{"name":"codex","cause":"exit-7","timed":true},{"name":"claude","cause":"answered","timed":true}]'

# label|world|command|expected rc, attempt records, execution order and calls
ROWS="
nonzero exit falls through and stops after the answer|exit:codex=7 failure-stdout:codex=login-required inline:claude=1|review|rc=0 $FIRST order=codex,claude calls=1,1,0|review-fallback
per-CLI timeout falls through|delay:codex=5 timeout:1|review|rc=0 [{\"name\":\"codex\",\"cause\":\"timeout\",\"timed\":true},{\"name\":\"claude\",\"cause\":\"answered\",\"timed\":true}] order=codex,claude calls=1,1,0
Anthropic rate-limit code on stderr with empty stdout falls through|refusal:codex=rate_limit_error codex:empty|review|rc=0 [{\"name\":\"codex\",\"cause\":\"quota\",\"timed\":true},{\"name\":\"claude\",\"cause\":\"answered\",\"timed\":true}] order=codex,claude calls=1,1,0
OpenAI quota code on stderr with empty stdout falls through|refusal:codex=insufficient_quota codex:empty|review|rc=0 [{\"name\":\"codex\",\"cause\":\"quota\",\"timed\":true},{\"name\":\"claude\",\"cause\":\"answered\",\"timed\":true}] order=codex,claude calls=1,1,0
Claude usage-limit banner with empty stdout falls through|refusal:codex=claude-banner codex:empty|review|rc=0 [{\"name\":\"codex\",\"cause\":\"quota\",\"timed\":true},{\"name\":\"claude\",\"cause\":\"answered\",\"timed\":true}] order=codex,claude calls=1,1,0
incomplete answer on stdout does not outrank a quota code on stderr|refusal:codex=insufficient_quota codex:partial|review|rc=0 [{\"name\":\"codex\",\"cause\":\"quota\",\"timed\":true},{\"name\":\"claude\",\"cause\":\"answered\",\"timed\":true}] order=codex,claude calls=1,1,0
usable answer on stdout outranks a quota code on stderr|refusal:codex=insufficient_quota|review|rc=0 [{\"name\":\"codex\",\"cause\":\"answered\",\"timed\":true}] order=codex calls=1,0,0
execution failure during the existing format retry falls through|codex:junk retry-exit:codex=7 inline:claude=1|review|rc=0 [{\"name\":\"codex\",\"cause\":\"answered\",\"timed\":true},{\"name\":\"codex\",\"cause\":\"exit-7\",\"timed\":true},{\"name\":\"claude\",\"cause\":\"answered\",\"timed\":true}] order=codex,codex,claude calls=2,1,0|review-fallback
a fall-through answer passes the first-response gate|codex:junk retry-exit:codex=7 claude:flagged-envelope|review|rc=5 [{\"name\":\"codex\",\"cause\":\"answered\",\"timed\":true},{\"name\":\"codex\",\"cause\":\"exit-7\",\"timed\":true},{\"name\":\"claude\",\"cause\":\"result-success\",\"timed\":true}] order=codex,codex,claude calls=2,1,0|envelope-cause
a fall-through exit passes the first-response gate|models:codex+claude codex:junk retry-exit:codex=7 exit:claude=8|review|rc=5 [{\"name\":\"codex\",\"cause\":\"answered\",\"timed\":true},{\"name\":\"codex\",\"cause\":\"exit-7\",\"timed\":true},{\"name\":\"claude\",\"cause\":\"exit-8\",\"timed\":true}] order=codex,codex,claude calls=2,1,0
a fall-through empty answer passes the first-response gate|models:codex+claude codex:junk retry-exit:codex=7 claude:empty|review|rc=5 [{\"name\":\"codex\",\"cause\":\"answered\",\"timed\":true},{\"name\":\"codex\",\"cause\":\"exit-7\",\"timed\":true},{\"name\":\"claude\",\"cause\":\"answered\",\"timed\":true}] order=codex,codex,claude calls=2,1,0
replacement review receives its own format retry|codex:junk retry-exit:codex=7 claude:junk retry:claude=clean inline:claude=1|review|rc=0 [{\"name\":\"codex\",\"cause\":\"answered\",\"timed\":true},{\"name\":\"codex\",\"cause\":\"exit-7\",\"timed\":true},{\"name\":\"claude\",\"cause\":\"answered\",\"timed\":true},{\"name\":\"claude\",\"cause\":\"answered\",\"timed\":true}] order=codex,codex,claude,claude calls=2,2,0|review-fallback
replacement audit receives its own format retry|codex:junk retry-exit:codex=7 claude:junk retry:claude=clean|audit|rc=0 [{\"name\":\"codex\",\"cause\":\"answered\",\"timed\":true},{\"name\":\"codex\",\"cause\":\"exit-7\",\"timed\":true},{\"name\":\"claude\",\"cause\":\"answered\",\"timed\":true},{\"name\":\"claude\",\"cause\":\"answered\",\"timed\":true}] order=codex,codex,claude,claude calls=2,2,0|audit-fallback
union keeps the format retry invocation|count:2 codex:junk retry:codex=clean|review|rc=0 [{\"name\":\"codex\",\"cause\":\"answered\",\"timed\":true},{\"name\":\"codex\",\"cause\":\"answered\",\"timed\":true},{\"name\":\"claude\",\"cause\":\"answered\",\"timed\":true}] order=codex,codex,claude calls=2,1,0
format recovery exit exhaustion keeps both invocations|models:codex codex:junk retry-exit:codex=7|review|rc=1 [{\"name\":\"codex\",\"cause\":\"answered\",\"timed\":true},{\"name\":\"codex\",\"cause\":\"exit-7\",\"timed\":true}] order=codex,codex calls=2,0,0
format recovery prose exhaustion keeps both invocations|models:codex codex:junk|review|rc=1 [{\"name\":\"codex\",\"cause\":\"answered\",\"timed\":true},{\"name\":\"codex\",\"cause\":\"answered\",\"timed\":true}] order=codex,codex calls=2,0,0
list exhaustion preserves both attempts and no opinion|models:codex+claude exit:codex=7 exit:claude=8|review|rc=5 [{\"name\":\"codex\",\"cause\":\"exit-7\",\"timed\":true},{\"name\":\"claude\",\"cause\":\"exit-8\",\"timed\":true}] order=codex,claude calls=1,1,0
room skip still precedes execution|room:codex=walled|review|rc=0 [{\"name\":\"claude\",\"cause\":\"answered\",\"timed\":true}] order=claude calls=0,1,0
failed model can answer through its next harness|model:codex=claude exit:codex=7|review|rc=0 $FIRST order=codex,claude calls=1,1,0
COUNT counts valid opinions, not failed attempts|count:2 exit:codex=7|review|rc=0 [{\"name\":\"codex\",\"cause\":\"exit-7\",\"timed\":true},{\"name\":\"claude\",\"cause\":\"answered\",\"timed\":true},{\"name\":\"my-model\",\"cause\":\"answered\",\"timed\":true}] order=codex,claude,extra calls=1,1,1
successful model excludes a second harness for it|count:2 model:claude=codex|review|rc=0 [{\"name\":\"codex\",\"cause\":\"answered\",\"timed\":true},{\"name\":\"my-model\",\"cause\":\"answered\",\"timed\":true}] order=codex,extra calls=1,0,1
forced target never falls through|exit:codex=7|review --target codex|rc=5 [{\"name\":\"codex\",\"cause\":\"exit-7\",\"timed\":true}] order=codex calls=1,0,0
"
n=0
while IFS='|' read -r label world command expected prompt; do
  [[ -n "$label" ]] || continue
  n=$((n + 1))
  # shellcheck disable=SC2086 # fixture words are a list
  build "fallback-$n" $DEFAULTS $world
  got=$(run_fallback "$command")
  assert_eq "$got" "$expected" "$label"
  case "$prompt" in
    review-fallback) assert_eq "$(request_state claude 1)" '{"inline_diff":true,"repair":false,"audit_original":false}' "$label: replacement receives its own diff and original request" ;;
    audit-fallback) assert_eq "$(request_state claude 1)" '{"inline_diff":false,"repair":false,"audit_original":true}' "$label: replacement receives the original audit request" ;;
    envelope-cause) assert_eq "$(jq -r .cause_source < "$ROW/out/out.json.failed.json")" 'claude result' "$label: the replacement's result envelope is the cause" ;;
  esac
  if [[ "$world" == exit:codex=7* && "$prompt" == review-fallback ]]; then
    assert_eq "$(jq '.qa_metadata.selected_count' < "$ROW/out/out.json")" 2 "$label: attempted eligible targets counted"
    assert_eq "$(grep -Fx -- login-required "$ROW/stderr")" login-required "$label: failed command stdout cause remains visible"
  fi
  if [[ "$world" == count:2* ]]; then
    selected=2
    [[ "$world" != *exit:codex=7* ]] || selected=3
    assert_eq "$(jq -c '[.qa_metadata.coverage, .qa_metadata.selected_count, ([.qa_metadata.lanes[] | select(.status == "ok")] | length), ([.qa_metadata.lanes[] | select(.status == "failed")] | length)]' < "$ROW/out/out.json")" "[\"full\",$selected,2,$((selected - 2))]" "$label: coverage counts valid opinions, not failures"
  fi
done <<<"$ROWS"

# Must-fail control: retain the call text but remove target advancement in a
# disposable copy. The nonzero-exit row must turn red, with only codex called.
# shellcheck disable=SC2086
build control $DEFAULTS exit:codex=7
python3 - "$SO" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
assert not p.is_symlink()
s = p.read_text()
old = '  walk_roster "$((before + 1))"'
assert s.count(old) == 1
changed = s.replace(old, "  : 'walk_roster \"$((before + 1))\"'")
assert changed != s
p.write_text(changed)
PY
control=$(run_fallback review)
assert_eq "$control" 'rc=5 [{"name":"codex","cause":"exit-7","timed":true}] order=codex calls=1,0,0' 'control: disabled advancement rejects the original fallback expectation'
assert_eq "$([[ "$control" != "rc=0 $FIRST order=codex,claude calls=1,1,0" ]] && printf red || printf green)" red 'the nonzero-exit test turns red under the mutant'
# Each control removes behavior in a disposable production script. The same
# request and record readbacks above must reject the mutant.
# label|world|rule|correct readback
CONTROLS='
replacement diff rebuild|exit:codex=7 inline:claude=1|rebuild|{"inline_diff":true,"repair":false,"audit_original":false}
original request reset|codex:junk retry-exit:codex=7 inline:claude=1|reset|{"inline_diff":true,"repair":false,"audit_original":false}
per-target recovery allowance|codex:junk retry-exit:codex=7 claude:junk retry:claude=clean|recovery|0
child invocation history|count:2 codex:junk retry:codex=clean|history|3
attempted target count|exit:codex=7|selected|2
stdout failure cause|exit:codex=7 failure-stdout:codex=login-required|cause|login-required
stdout answer outranks stderr|refusal:codex=insufficient_quota|answer|rc=0 [{"name":"codex","cause":"answered","timed":true}] order=codex calls=1,0,0
fall-through first-response gate|codex:junk retry-exit:codex=7 claude:flagged-envelope|gate|rc=5 [{"name":"codex","cause":"answered","timed":true},{"name":"codex","cause":"exit-7","timed":true},{"name":"claude","cause":"result-success","timed":true}] order=codex,codex,claude calls=2,1,0
fall-through exit first-response gate|models:codex+claude codex:junk retry-exit:codex=7 exit:claude=8|gate|rc=5 [{"name":"codex","cause":"answered","timed":true},{"name":"codex","cause":"exit-7","timed":true},{"name":"claude","cause":"exit-8","timed":true}] order=codex,codex,claude calls=2,1,0
fall-through empty-answer first-response gate|models:codex+claude codex:junk retry-exit:codex=7 claude:empty|gate|rc=5 [{"name":"codex","cause":"answered","timed":true},{"name":"codex","cause":"exit-7","timed":true},{"name":"claude","cause":"answered","timed":true}] order=codex,codex,claude calls=2,1,0
'
n=0
while IFS='|' read -r label world rule correct; do
  [[ -n "$label" ]] || continue
  n=$((n + 1))
  # shellcheck disable=SC2086 # fixture words are a list
  build "control-$n-$rule" $DEFAULTS $world
  case "$rule" in
    rebuild) mutate_script "$SO" '      PROMPT=$(build_review_prompt)' '      : '\''PROMPT=$(build_review_prompt)'\'' ' ;;
    reset) mutate_script "$SO" '    invocation_prompt="$PROMPT_TMP"' '    : '\''invocation_prompt="$PROMPT_TMP"'\'' ' ;;
    recovery) mutate_script "$SO" '      if [[ "$TARGET_CLI" != "$RECOVERY_TARGET" ]]; then' '      if false; then # "$TARGET_CLI" != "$RECOVERY_TARGET"' ;;
    history) mutate_script "$SO" '      lane_attempts=$(jq -ce '\''.qa_metadata.attempts | select(type == "array")'\'' <<<"$lane_raw" 2>/dev/null) || lane_attempts=""' '      lane_attempts="" # lane_attempts=$(jq -ce .qa_metadata.attempts <<<"$lane_raw")' ;;
    selected) mutate_script "$SO" '  SELECTED_COUNT=${#REVIEW_LANES[@]}
  if STAMPED=' '  SELECTED_COUNT=1 # SELECTED_COUNT=${#REVIEW_LANES[@]}
  if STAMPED=' ;;
    cause) mutate_script "$SO" '    CLI_FAILURE_CAUSE=$(printf '\''%s\n'\'' "$partial" | tail -20)' '    : '\''CLI_FAILURE_CAUSE=$(printf "%s\n" "$partial" | tail -20)'\'' ' ;;
    answer) mutate_script "$SO" '    elif [[ -z "$RESULT_ENVELOPE_CAUSE" ]] && $REVIEW_LIKE && answer_json=' '    elif false && [[ -z "$RESULT_ENVELOPE_CAUSE" ]] && $REVIEW_LIKE && answer_json=' ;;
    gate) mutate_script "$SO" '  [[ $invocation_prompt != "$PROMPT_TMP" ]] || gate_first_response' '  [[ $invocation_prompt != "$PROMPT_TMP" ]] || : gate_first_response' ;;
  esac
  got=$(run_fallback review)
  case "$rule" in
    rebuild|reset) actual=$(request_state claude 1) ;;
    recovery) actual="${got%% *}"; actual="${actual#rc=}" ;;
    history) actual=$(jq '.qa_metadata.attempts | length' < "$ROW/out/out.json") ;;
    selected) actual=$(jq '.qa_metadata.selected_count' < "$ROW/out/out.json") ;;
    cause) actual=$(grep -Fx -- login-required "$ROW/stderr" || true) ;;
    answer|gate) actual="$got" ;;
  esac
  assert_eq "$([[ "$actual" != "$correct" ]] && printf red || printf green)" red "control: $label turns its assertion red"
done <<<"$CONTROLS"

# Detached execution must budget for the whole sequential roster, not one CLI.
# shellcheck disable=SC2086
build budget $DEFAULTS models:codex+claude
assert_eq "$(detached_budget)" 122 'detached deadline includes both possible CLI windows'
# shellcheck disable=SC2086
build budget-control $DEFAULTS models:codex+claude
python3 - "${SO}-runtime" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
assert not p.is_symlink()
s = p.read_text()
old = 'targets=${#ROSTER[@]}'
assert s.count(old) == 1
changed = s.replace(old, 'targets=1 # targets=${#ROSTER[@]}')
assert changed != s
p.write_text(changed)
PY
assert_eq "$(detached_budget)" 91 'control: one-target budget turns the deadline test red'
finish
