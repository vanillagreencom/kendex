#!/usr/bin/env bash
# Consumer settings are the producer of deprecated numeric preference entries.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/growth-state.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'overseer-preference: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "overseer-preference: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'overseer-preference: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
LIB="$TEST_DIR/../scripts/lib/overseer-launch.sh"
cat >"$TMP_ROOT/read" <<'SH'
set -euo pipefail
source "${1%/*}/lane-launch.sh"
source "$1"
OL_WALK_CALLER_MODEL="$3"
rc=0
ol_preference_entries "$2" || rc=$?
models=()
for entry in ${OL_ENTRIES[@]+"${OL_ENTRIES[@]}"}; do
  ol_entry_model "$entry"
  models+=("$OL_ENTRY_HARNESS:$OL_ENTRY_MODEL:$OL_ENTRY_EFFORT")
done
printf '%s|%s|%s|%s|%s|%s\n' "$rc" "$OL_NAMED" "${models[*]-}" "${OL_DEPRECATED_ENTRIES[*]-}" "${OL_REFUSED_ENTRIES[*]-}" "$OL_BAD_ENTRY"
# A second parse in the same process must not repeat the warning.
ol_preference_entries "$2" || :
SH
for row in \
  'claude:1:high|fable|0|1|claude:fable:high|claude:1:high|||1' \
  'codex:12:medium|gpt-6-astra|0|1|codex:gpt-6-astra:medium|codex:12:medium|||1' \
  'copilot:2:high|fable|0|1|copilot:fable:high|copilot:2:high|||1' \
  'pi:1:high|pi-claude/fable|0|1|pi:pi-claude/fable:high|pi:1:high|||1' \
  'claude:1:high,codex:2:low|fable|0|2|claude:fable:high codex:fable:low|claude:1:high codex:2:low|||1' \
  'claude:fable:high|other|0|1|claude:fable:high||||0' \
  'pi:pi-claude/fable:high|other|0|1|pi:pi-claude/fable:high||||0' \
  '|fable|0|0|||||0' \
  'claude:0:high|fable|1|0|||claude:0:high|claude:0:high|0' \
  'claude::high|fable|1|0|||claude::high|claude::high|0' \
  'claude:-1:high|fable|1|0|||claude:-1:high|claude:-1:high|0' \
  'claude:1x:high|fable|1|0|||claude:1x:high|claude:1x:high|0' \
  'claude:1:HIGH|fable|1|0|||claude:1:HIGH|claude:1:HIGH|0' \
  'bad,claude:1:high,codex::low|fable|1|1|claude:fable:high|claude:1:high|bad codex::low|bad|1'; do
  IFS='|' read -r preference caller rc named models deprecated refused first warnings <<<"$row"
  OUT="$(env -i PATH="$PATH" bash "$TMP_ROOT/read" "$LIB" "$preference" "$caller" 2>"$TMP_ROOT/err")"
  warning_count="$(wc -l <"$TMP_ROOT/err" | tr -d ' ')"
  assert_eq "$OUT|$warning_count" "$rc|$named|$models|$deprecated|$refused|$first|$warnings" "parse $preference on caller $caller"
  if [[ "$warnings" == 1 ]]; then
    assert_eq "$(cat "$TMP_ROOT/err")" "preference-deprecated entry=${deprecated%% *} form=harness:model:effort" "warning names the original entry and replacement form"
  fi
done

# The owner supplies the same resolved model to its account pick and launch
# flags. The lanes stand-in returns its real exit-3/counts contract on Sonnet.
cat >"$TMP_ROOT/walk" <<'SH'
set -euo pipefail
source "${1%/*}/lane-launch.sh"
source "${1%/*}/lane-context.sh"
source "$1"
DEP_ERR="$2/err"
SCRIPT_DIR="${1%/lib/*}"
# Do not stub any model owner: only the lanes command's external result.
ol_lanes() {
  local model
  model=$(launch_choice_value --model "$*") || return 1
  printf '%s\n' "$model" >> "$PICKS"
  if [[ "$model" == claude-sonnet-5 && "$WALL" == 1 ]]; then
    printf '%s\n' '{"walled":1,"unmeasured":0}'
    return 3
  fi
  printf '%s\n' '{"config_dir":"/fixture/account"}'
}
OL_WALK_CALLER_HARNESS=claude OL_WALK_CALLER_MODEL=haiku
OL_WALK_CALLER_PICK_MODEL=haiku OL_WALK_CALLER_EFFORT=high
OL_WALK_SOURCE_HARNESS=claude OL_WALK_SOURCE_FLAGS=--dangerously-skip-permissions
if [[ "$MODE" == caller ]]; then entry=caller; else entry=claude:haiku:high; fi
ol_walk 5 '' "$entry" codex:gpt-6-astra:high
ol_launch_flags "$OL_HARNESS" "$OL_MODEL" "$OL_EFFORT" "$OL_PICK_MODEL" claude --dangerously-skip-permissions
model=$(launch_choice_launch_model "$OL_HARNESS" "${OL_FLAGS[*]}") || exit 1
printf '%s|%s|%s|%s\n' "$OL_HARNESS" "$OL_MODEL" "$OL_PICK_MODEL" "$model"
SH
for mode in named caller; do
  for wall in 0 1; do
    : >"$TMP_ROOT/picks"
    OUT="$(env -i PATH="$PATH" HOME="$TMP_ROOT" MODE="$mode" WALL="$wall" PICKS="$TMP_ROOT/picks" \
      bash "$TMP_ROOT/walk" "$LIB" "$TMP_ROOT" 2>"$TMP_ROOT/warnings")" || exit 1
    if [[ "$wall" == 1 ]]; then
      want='codex|gpt-6-astra|gpt-6-astra|gpt-6-astra'
      picks=$'claude-sonnet-5\ngpt-6-astra'
    else
      want='claude|claude-sonnet-5|claude-sonnet-5|claude-sonnet-5'
      picks=claude-sonnet-5
    fi
    assert_eq "$OUT|$(cat "$TMP_ROOT/picks")|$(wc -l <"$TMP_ROOT/warnings" | tr -d ' ')" \
      "$want|$picks|1" "$mode walk judges and launches the resolved model at wall=$wall"
  done
done
OUT="$(env -i PATH="$PATH" HOME="$TMP_ROOT" bash -c '
  set -euo pipefail; source "${1%/*}/lane-launch.sh"; source "$1"
  ol_account claude haiku; printf "%s\n" "$OL_ACCOUNT_MODEL"
' _ "$LIB" 2>"$TMP_ROOT/warnings")" || exit 1
assert_eq "$OUT" claude-sonnet-5 'the account owner resolves the Claude request before selection'
for mutation in entry caller account; do
  MUTANT="$(mutant_scripts "haiku-$mutation" lib/overseer-launch.sh)" || exit 1
  case "$mutation" in
    entry)
      old='  OL_ENTRY_MODEL="$(launch_choice_model_id "$OL_ENTRY_HARNESS" "$OL_ENTRY_MODEL" --request)" || return 1'
      new='  :'; mode=named ;;
    caller)
      old='      OL_PICK_MODEL="$(launch_choice_model_id "$OL_HARNESS" "$OL_PICK_MODEL" --request)" || return 1'
      new='      :'; mode=caller ;;
    account)
      old='  model="$(launch_choice_model_id "${1:-}" "$model" --request)" || return 1'
      new='  :'; mode=named ;;
  esac
  mutate_file "$MUTANT/lib/overseer-launch.sh" "$old" "# $old
$new"
  if [[ "$mutation" == account ]]; then
    OUT="$(env -i PATH="$PATH" HOME="$TMP_ROOT" bash -c '
      set -euo pipefail; source "${1%/*}/lane-launch.sh"; source "$1"
      ol_account claude haiku; printf "%s\n" "$OL_ACCOUNT_MODEL"
    ' _ "$MUTANT/lib/overseer-launch.sh" 2>"$TMP_ROOT/warnings")" || exit 1
    assert_eq "$OUT" haiku 'control: the unresolved account request misses Sonnet'
  else
    : >"$TMP_ROOT/picks"
    OUT="$(env -i PATH="$PATH" HOME="$TMP_ROOT" MODE="$mode" WALL=0 PICKS="$TMP_ROOT/picks" \
      bash "$TMP_ROOT/walk" "$MUTANT/lib/overseer-launch.sh" "$TMP_ROOT" 2>"$TMP_ROOT/warnings")" || exit 1
    assert_contains "$OUT" '|haiku|' "control: the unresolved $mutation request disagrees with its launch model"
  fi
done
for mutation in refusal model warning; do
  MUTANT="$(mutant_scripts "$mutation" lib/overseer-launch.sh)"
  case "$mutation" in
    refusal)
      old='    if [[ "$entry" =~ ^(claude|codex|copilot|pi):[1-9][0-9]*:[a-z]+$ ]]; then'
      new='    if false && [[ "$entry" =~ ^(claude|codex|copilot|pi):[1-9][0-9]*:[a-z]+$ ]]; then' ;;
    model)
      old='  [[ -n "$OL_ENTRY_MODEL" ]] || OL_ENTRY_MODEL="${OL_WALK_CALLER_MODEL:-$OL_PREFERENCE_CALLER_MODEL}"'
      new='  : # caller model is dropped' ;;
    warning)
      old='      if (( ! OL_DEPRECATION_WARNED )); then'
      new='      if true; then' ;;
  esac
  python3 - "$MUTANT/lib/overseer-launch.sh" "$old" "$new" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1]).resolve()
text = path.read_text()
old, new = sys.argv[2:]
assert text.count(old) == 1
changed = text.replace(old, '# ' + old + '\n' + new)
assert changed != text
path.write_text(changed)
PY
  OUT="$(env -i PATH="$PATH" bash "$TMP_ROOT/read" "$MUTANT/lib/overseer-launch.sh" 'claude:1:high' fable 2>"$TMP_ROOT/err")"
  warnings="$(wc -l <"$TMP_ROOT/err" | tr -d ' ')"
  if [[ "$OUT|$warnings" != '0|1|claude:fable:high|claude:1:high|||1' ]]; then
    pass "control: $mutation turns the numeric must-pass assertion red"
  else
    fail "control: $mutation did not turn the assertion red"
  fi
done
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
