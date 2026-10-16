#!/usr/bin/env bash
# Consumer settings are the producer of deprecated numeric preference entries,
# of old exact model ids and of model classes. A class reads the class table
# through fixtures/tier-model/kendex, the table's rows as kendex answers them;
# tier-model-fixture.sh holds a real kendex to that fixture.
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
TABLE_PATH="$TEST_DIR/fixtures/tier-model:$PATH"
cat >"$TMP_ROOT/read" <<'SH'
set -euo pipefail
source "$1"
OL_WALK_CALLER_MODEL="$3"
rc=0
ol_preference_entries "$2" "${4:-}" || rc=$?
models=()
for entry in ${OL_ENTRIES[@]+"${OL_ENTRIES[@]}"}; do
  ol_entry_model "$entry" || { models+=(unread); continue; }
  models+=("$OL_ENTRY_HARNESS${OL_ENTRY_HOST:+@$OL_ENTRY_HOST}:$OL_ENTRY_MODEL:$OL_ENTRY_EFFORT${OL_ENTRY_CLASS:+#$OL_ENTRY_CLASS}")
done
printf '%s|%s|%s|%s|%s|%s\n' "$rc" "$OL_NAMED" "${models[*]-}" "${OL_DEPRECATED_ENTRIES[*]-}" "${OL_REFUSED_ENTRIES[*]-}" "$OL_BAD_ENTRY"
# A second parse in the same process must not repeat the warning.
ol_preference_entries "$2" "${4:-}" || :
SH
# A model is written `harness:model:effort#class` where the table names its class.
for row in \
  'claude:1:high|fable|0|1|claude:fable:high|claude:1:high|||1' \
  'codex:12:medium|gpt-6-astra|0|1|codex:gpt-6-astra:medium|codex:12:medium|||1' \
  'copilot:2:high|fable|0|1|copilot:fable:high|copilot:2:high|||1' \
  'pi:1:high|pi-claude/fable|0|1|pi:pi-claude/fable:high|pi:1:high|||1' \
  'claude:1:high,codex:2:low|fable|0|2|claude:fable:high codex:fable:low|claude:1:high codex:2:low|||1' \
  'claude:fable:high|other|0|1|claude:fable:high#top||||0' \
  'pi:pi-claude/fable:high|other|0|1|pi:pi-claude/fable:high||||0' \
  '|fable|0|0|||||0' \
  'claude:0:high|fable|1|0|||claude:0:high|claude:0:high|0' \
  'claude::high|fable|0|1|claude::high||||0' \
  'codex::high|fable|0|1|codex::high||||0' \
  'claude:1:high,claude::high|fable|0|2|claude:fable:high claude::high|claude:1:high|||1' \
  'claude:-1:high|fable|1|0|||claude:-1:high|claude:-1:high|0' \
  'claude:1x:high|fable|1|0|||claude:1x:high|claude:1x:high|0' \
  'claude:1:HIGH|fable|1|0|||claude:1:HIGH|claude:1:HIGH|0' \
  'bad,claude:1:high,codex::low|fable|1|2|claude:fable:high codex::low|claude:1:high|bad|bad|1' \
  'claude:standard:high,codex:standard:high|other|0|2|claude:opus:high#standard codex:gpt-6.1-sol:high#standard||||0' \
  'codex:top:low,claude:fast:high|other|0|2|codex:gpt-6-astra:low#top claude:haiku:high#fast||||0' \
  'claude:opus:high,codex:gpt-6.1-sol:high|other|0|2|claude:opus:high#standard codex:gpt-6.1-sol:high#standard||||0' \
  'claude:claude-opus-5-5:high|other|0|1|claude:claude-opus-5-5:high|claude:claude-opus-5-5:high|||1' \
  'claude:claude-opus-5-5:high,codex:gpt-5.5:high|other|0|2|claude:claude-opus-5-5:high codex:gpt-5.5:high|claude:claude-opus-5-5:high codex:gpt-5.5:high|||1' \
  'copilot:claude-opus-5.5:high|other|0|1|copilot:claude-opus-5.5:high||||0'; do
  IFS='|' read -r preference caller rc named models deprecated refused first warnings <<<"$row"
  OUT="$(env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TABLE_PATH" bash "$TMP_ROOT/read" "$LIB" "$preference" "$caller" 2>"$TMP_ROOT/err")"
  warning_count="$(wc -l <"$TMP_ROOT/err" | tr -d ' ')"
  assert_eq "$OUT|$warning_count" "$rc|$named|$models|$deprecated|$refused|$first|$warnings" "parse $preference on caller $caller"
  if [[ "$warnings" == 1 ]]; then
    assert_eq "$(cat "$TMP_ROOT/err")" "preference-deprecated entry=${deprecated%% *} form=harness:model:effort" "warning names the original entry and replacement form"
  fi
done
# A class with no model on its harness runs the harness default, and one line
# per process says so, however many entries name such a class.
OUT="$(env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TABLE_PATH" bash "$TMP_ROOT/read" "$LIB" 'copilot:standard:high,copilot:top:low' other 2>"$TMP_ROOT/err")"
assert_eq "$OUT|$(cat "$TMP_ROOT/err")" \
  "0|2|copilot::high#standard copilot::low#top||||model-class-default harness=copilot class=standard model=harness-default" \
  "a class with no model on its harness runs the harness default with one warning"
# A class table kendex cannot answer leaves the entry that needed it
# unresolved, distinct from an invalid entry, and one that needs none stands.
mkdir -p "$TMP_ROOT/broken"
printf '#!/bin/sh\necho "kendex: broken" >&2\nexit 1\n' >"$TMP_ROOT/broken/kendex"
chmod +x "$TMP_ROOT/broken/kendex"
OUT="$(env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TMP_ROOT/broken:$PATH" bash "$TMP_ROOT/read" "$LIB" 'codex::high,claude:standard:high' other 2>"$TMP_ROOT/err")"
assert_eq "$OUT" "0|2|codex::high unread|||" "an unread class table refuses the entry that needed it"
# Lane settings may name a host. Overseer settings keep their local route.
while IFS='|' read -r preference mode expected; do
  OUT="$(env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TABLE_PATH" "$BASH" "$TMP_ROOT/read" "$LIB" "$preference" other "$mode" 2>"$TMP_ROOT/err")"
  assert_eq "$OUT" "$expected" "host grammar: $preference mode=$mode"
done <<'ROWS'
claude@claude-cloud:standard:high|lane|0|1|claude@claude-cloud:opus:high#standard|||
claude@claude-cloud:claude-opus-5-5:high|lane|0|1|claude@claude-cloud:claude-opus-5-5:high|claude@claude-cloud:claude-opus-5-5:high||
pi@/opt/daytona:github-copilot/gpt-6.1-sol:high|lane|0|1|pi@/opt/daytona:github-copilot/gpt-6.1-sol:high|||
claude@claude-cloud:claude-opus-5-5:high||1|0|||claude@claude-cloud:claude-opus-5-5:high|claude@claude-cloud:claude-opus-5-5:high
claude@:opus:high|lane|1|0|||claude@:opus:high|claude@:opus:high
claude@cloud@local:opus:high|lane|1|0|||claude@cloud@local:opus:high|claude@cloud@local:opus:high
claude@cloud;exec:opus:high|lane|1|0|||claude@cloud;exec:opus:high|claude@cloud;exec:opus:high
ROWS
# A bare word such as false is true inside [[ ... ]]. Each control keeps its
# original condition but makes only that condition false.
while IFS='|' read -r mutation preference mode old admitted; do
  OUT="$(env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TABLE_PATH" "$BASH" "$TMP_ROOT/read" "$LIB" "$preference" other "$mode" 2>"$TMP_ROOT/err")"
  assert_eq "$OUT" "1|0|||$preference|$preference" "control baseline: $mutation refuses $preference"
  MUTANT="$(mutant_scripts "$mutation" lib/overseer-launch.sh)"
  mutate_file "$MUTANT/lib/overseer-launch.sh" "$old" "( 0 == 1 && $old )"
  OUT="$(env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TABLE_PATH" "$BASH" "$TMP_ROOT/read" "$MUTANT/lib/overseer-launch.sh" "$preference" other "$mode" 2>"$TMP_ROOT/err")"
  assert_eq "$OUT" "0|1|$admitted|||" "control: $mutation admits $preference"
done <<'ROWS'
host-grammar|claude@:opus:high|lane|! "$host" =~ ^[a-zA-Z0-9_./~-]+$|claude:opus:high#standard
overseer-host-refusal|claude@claude-cloud:opus:high||"${2:-}" != lane|claude@claude-cloud:opus:high#standard
ROWS
# Each control turns one row above red: its preference parsed by a copy of
# the lib with one line replaced must no longer give that row's answer.
control() { # MUTATION PREFERENCE CALLER GREEN OLD NEW
  local mutant out warnings
  mutant="$(mutant_scripts "$1" lib/overseer-launch.sh)"
  python3 - "$mutant/lib/overseer-launch.sh" "$5" "$6" <<'PY'
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
  out="$(env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TABLE_PATH" bash "$TMP_ROOT/read" "$mutant/lib/overseer-launch.sh" "$2" "$3" 2>"$TMP_ROOT/err")" || :
  warnings="$(wc -l <"$TMP_ROOT/err" | tr -d ' ')"
  if [[ "$out|$warnings" != "$4" ]]; then
    pass "control: $1 turns the $2 assertion red"
  else
    fail "control: $1 did not turn the $2 assertion red"
  fi
}
NUMERIC_GREEN='0|1|claude:fable:high|claude:1:high|||1'
control refusal claude:1:high fable "$NUMERIC_GREEN" \
  '    if [[ "$entry" =~ ^(claude|codex|copilot|pi):[1-9][0-9]*:[a-z]+$ ]]; then' \
  '    if false && [[ "$entry" =~ ^(claude|codex|copilot|pi):[1-9][0-9]*:[a-z]+$ ]]; then'
control model claude:1:high fable "$NUMERIC_GREEN" \
  '    OL_ENTRY_MODEL="${OL_WALK_CALLER_MODEL:-$OL_PREFERENCE_CALLER_MODEL}"' '  : # caller model is dropped'
control warning claude:1:high fable "$NUMERIC_GREEN" '  (( ! OL_DEPRECATION_WARNED )) || return 0' '  :'
control class claude:standard:high other '0|1|claude:opus:high#standard||||0' \
  '    OL_CLASS="$class" OL_CLASS_MODEL="$model"' '    OL_CLASS="$class"'
control old-id claude:claude-opus-5-5:high other '0|1|claude:claude-opus-5-5:high|claude:claude-opus-5-5:high|||1' \
  '  (( OL_ENTRY_CLASS_RC != 2 )) || ol_deprecated "$1"' '  :'
control copilot-id copilot:claude-opus-5.5:high other '0|1|copilot:claude-opus-5.5:high||||0' \
  '  (( ! named )) || return 2' '  return 2'
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
