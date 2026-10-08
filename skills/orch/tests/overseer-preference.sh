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
source "$1"
OL_WALK_CALLER_MODEL="$3"
rc=0
ol_preference_entries "$2" "${4:-}" || rc=$?
models=()
for entry in ${OL_ENTRIES[@]+"${OL_ENTRIES[@]}"}; do
  ol_entry_model "$entry"
  models+=("$OL_ENTRY_HARNESS${OL_ENTRY_HOST:+@$OL_ENTRY_HOST}:$OL_ENTRY_MODEL:$OL_ENTRY_EFFORT")
done
printf '%s|%s|%s|%s|%s|%s\n' "$rc" "$OL_NAMED" "${models[*]-}" "${OL_DEPRECATED_ENTRIES[*]-}" "${OL_REFUSED_ENTRIES[*]-}" "$OL_BAD_ENTRY"
# A second parse in the same process must not repeat the warning.
ol_preference_entries "$2" "${4:-}" || :
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
# Lane settings may name a host. Overseer settings keep their local route.
while IFS='|' read -r preference mode expected; do
  OUT="$(env -i PATH="$PATH" "$BASH" "$TMP_ROOT/read" "$LIB" "$preference" other "$mode" 2>"$TMP_ROOT/err")"
  assert_eq "$OUT" "$expected" "host grammar: $preference mode=$mode"
done <<'ROWS'
claude@claude-cloud:claude-opus-5-5:high|lane|0|1|claude@claude-cloud:claude-opus-5-5:high|||
pi@/opt/daytona:github-copilot/gpt-6.1-sol:high|lane|0|1|pi@/opt/daytona:github-copilot/gpt-6.1-sol:high|||
claude@claude-cloud:claude-opus-5-5:high||1|0|||claude@claude-cloud:claude-opus-5-5:high|claude@claude-cloud:claude-opus-5-5:high
claude@:opus:high|lane|1|0|||claude@:opus:high|claude@:opus:high
claude@cloud@local:opus:high|lane|1|0|||claude@cloud@local:opus:high|claude@cloud@local:opus:high
claude@cloud;exec:opus:high|lane|1|0|||claude@cloud;exec:opus:high|claude@cloud;exec:opus:high
ROWS
# A bare word such as false is true inside [[ ... ]]. Each control keeps its
# original condition but makes only that condition false.
while IFS='|' read -r mutation preference mode old admitted; do
  OUT="$(env -i PATH="$PATH" "$BASH" "$TMP_ROOT/read" "$LIB" "$preference" other "$mode" 2>"$TMP_ROOT/err")"
  assert_eq "$OUT" "1|0|||$preference|$preference" "control baseline: $mutation refuses $preference"
  MUTANT="$(mutant_scripts "$mutation" lib/overseer-launch.sh)"
  mutate_file "$MUTANT/lib/overseer-launch.sh" "$old" "( 0 == 1 && $old )"
  OUT="$(env -i PATH="$PATH" "$BASH" "$TMP_ROOT/read" "$MUTANT/lib/overseer-launch.sh" "$preference" other "$mode" 2>"$TMP_ROOT/err")"
  assert_eq "$OUT" "0|1|$admitted|||" "control: $mutation admits $preference"
done <<'ROWS'
host-grammar|claude@:opus:high|lane|! "$host" =~ ^[a-zA-Z0-9_./~-]+$|claude:opus:high
overseer-host-refusal|claude@claude-cloud:opus:high||"${2:-}" != lane|claude@claude-cloud:opus:high
ROWS
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
