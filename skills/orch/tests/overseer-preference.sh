#!/usr/bin/env bash
# Consumer settings are the producer of deprecated numeric preference entries,
# of old exact model ids and of model classes. Each model is classified
# through fixtures/tier-model/kendex, kendex's answers as it gives them;
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
  ol_entry_model "$entry" || { models+=("unread=$OL_CLASS_ERR"); continue; }
  ol_model_line "$OL_ENTRY_WARNING"
  models+=("$OL_ENTRY_HARNESS${OL_ENTRY_HOST:+@$OL_ENTRY_HOST}:$OL_ENTRY_MODEL:$OL_ENTRY_EFFORT${OL_ENTRY_CLASS:+#$OL_ENTRY_CLASS}")
done
printf '%s|%s|%s|%s|%s|%s\n' "$rc" "$OL_NAMED" "${models[*]-}" "${OL_DEPRECATED_ENTRIES[*]-}" "${OL_REFUSED_ENTRIES[*]-}" "$OL_BAD_ENTRY"
# A second parse and read in the same process must not repeat a warning.
ol_preference_entries "$2" "${4:-}" || :
for entry in ${OL_ENTRIES[@]+"${OL_ENTRIES[@]}"}; do ol_entry_model "$entry" && ol_model_line "$OL_ENTRY_WARNING" || :; done
SH
# observe PREFERENCE CALLER [LIB [HELD]] — the read's answer, then the one
# preference-deprecated line's fields and the model each kendex
# model-resolution line names as selected, the read handing each entry's
# warning to ol_model_line, which prints one per process; HELD runs the read
# under ORCH_MODEL_LINES_HELD=1.
observe() {
  local out deprecation held=()
  [[ -z "${4:-}" ]] || held=(ORCH_MODEL_LINES_HELD=1)
  out="$(env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TABLE_PATH" ${held[@]+"${held[@]}"} \
    bash "$TMP_ROOT/read" "${3:-$LIB}" "$1" "$2" 2>"$TMP_ROOT/err")" || :
  deprecation="$(sed -n 's/^preference-deprecated //p' "$TMP_ROOT/err")"
  printf '%s|%s|%s\n' "$out" "$deprecation" \
    "$(sed -n 's/^model-resolution: .* selected=\([^ ]*\) .*/\1/p' "$TMP_ROOT/err" | tr '\n' ' ' | sed 's/ $//')"
}
# A model is written `harness:model:effort#class` where kendex names its class.
NUMERIC='entry=claude:1:high form=harness:model:effort'
while IFS= read -r row; do
  IFS='|' read -r preference caller expected <<<"$row"
  assert_eq "$(observe "$preference" "$caller")" "$expected" "parse $preference on caller $caller"
done <<ROWS
claude:1:high|fable|0|1|claude:fable:high#top|claude:1:high|||$NUMERIC|
claude:1:high|opus|0|1|claude:opus:high#standard|claude:1:high|||$NUMERIC|
claude:1:high|claude-opus-5-5|0|1|claude:claude-opus-5-5:high|claude:1:high|||$NUMERIC|
codex:12:medium|gpt-6-astra|0|1|codex:gpt-6-astra:medium|codex:12:medium|||entry=codex:12:medium form=harness:model:effort|
copilot:2:high|fable|0|1|copilot:fable:high#top|copilot:2:high|||entry=copilot:2:high form=harness:model:effort|
pi:1:high|pi-claude/fable|0|1|pi:pi-claude/fable:high|pi:1:high|||entry=pi:1:high form=harness:model:effort|
claude:1:high,codex:2:low|fable|0|2|claude:fable:high#top codex:fable:low#top|claude:1:high codex:2:low|||$NUMERIC|
claude:fable:high|other|0|1|claude:fable:high#top|||||fable
pi:pi-claude/fable:high|other|0|1|pi:pi-claude/fable:high|||||
|fable|0|0||||||
claude:0:high|fable|1|0|||claude:0:high|claude:0:high||
claude::high|fable|0|1|claude::high|||||
codex::high|fable|0|1|codex::high|||||
claude:1:high,claude::high|fable|0|2|claude:fable:high#top claude::high|claude:1:high|||$NUMERIC|
claude:-1:high|fable|1|0|||claude:-1:high|claude:-1:high||
claude:1x:high|fable|1|0|||claude:1x:high|claude:1x:high||
claude:1:HIGH|fable|1|0|||claude:1:HIGH|claude:1:HIGH||
bad,claude:1:high,codex::low|fable|1|2|claude:fable:high#top codex::low|claude:1:high|bad|bad|$NUMERIC|
claude:standard:high,codex:standard:high|other|0|2|claude:opus:high#standard codex::high#standard|||||opus
codex:top:low,claude:fast:high|other|0|2|codex::low#top claude:haiku:high#fast|||||native-default
copilot:standard:high,copilot:top:low|other|0|2|copilot::high#standard copilot::low#top|||||native-default
claude:opus:high,codex:gpt-6.1-sol:high|other|0|2|claude:opus:high#standard codex:gpt-6.1-sol:high|||||opus
claude:claude-opus-5-5:high,codex:gpt-5.5:high|other|0|2|claude:claude-opus-5-5:high codex:gpt-5.5:high||||entry=claude:claude-opus-5-5:high form=model-class|
copilot:claude-opus-5.5:high|other|0|1|copilot:claude-opus-5.5:high|||||
ROWS
# A read started under ORCH_MODEL_LINES_HELD, a launcher's child, prints
# neither line.
assert_eq "$(observe claude:standard:high,claude:claude-opus-5-5:high other "" held)" \
  '0|2|claude:opus:high#standard claude:claude-opus-5-5:high|||||' \
  "a held read prints no model-resolution or preference-deprecated line"
# A model kendex cannot classify leaves its entry unresolved with kendex's
# words, distinct from an invalid entry, and one that needs no read stands.
mkdir -p "$TMP_ROOT/broken"
printf '#!/bin/sh\necho "kendex: broken" >&2\nexit 1\n' >"$TMP_ROOT/broken/kendex"
chmod +x "$TMP_ROOT/broken/kendex"
OUT="$(env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TMP_ROOT/broken:$PATH" bash "$TMP_ROOT/read" "$LIB" 'codex::high,claude:standard:high' other 2>"$TMP_ROOT/err")"
assert_eq "$OUT" "0|2|codex::high unread=kendex: broken|||" "an unclassified model refuses its entry with kendex's words"
# A read that succeeds writes nothing to DEP_ERR, which a later refusal
# relays as its cause.
: >"$TMP_ROOT/dep"
env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TABLE_PATH" DEP_ERR="$TMP_ROOT/dep" bash -c \
  'set -euo pipefail; source "$1"; ol_entry_model claude:fast:high; ol_entry_model codex:standard:high' _ "$LIB" 2>/dev/null
assert_eq "$(cat "$TMP_ROOT/dep")" "" "a successful read leaves DEP_ERR empty"
# Lane settings may name a host. Overseer settings keep their local route.
while IFS='|' read -r preference mode expected; do
  OUT="$(env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TABLE_PATH" "$BASH" "$TMP_ROOT/read" "$LIB" "$preference" other "$mode" 2>"$TMP_ROOT/err")"
  assert_eq "$OUT" "$expected" "host grammar: $preference mode=$mode"
done <<'ROWS'
claude@claude-cloud:standard:high|lane|0|1|claude@claude-cloud:opus:high#standard|||
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
# The last-choice mark: lane mode, the final entry alone, stripped from the
# entry it marks. A read is `rc|mark|entries|first refused`.
cat >"$TMP_ROOT/mark" <<'SH'
set -euo pipefail
source "$1"
rc=0
ol_preference_entries "$2" "${3:-}" || rc=$?
printf '%s|%s|%s|%s\n' "$rc" "$OL_LAST_CHOICE" "${OL_ENTRIES[*]-}" "$OL_BAD_ENTRY"
SH
mark_read() { # LIB PREFERENCE MODE
  env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TABLE_PATH" "$BASH" "$TMP_ROOT/mark" "$@" 2>"$TMP_ROOT/err"
}
while IFS='|' read -r label preference mode expected; do
  assert_eq "$(mark_read "$LIB" "$preference" "$mode")" "$expected" "last-choice grammar: $label"
done <<'ROWS'
final lane entry marked|claude:opus:high,pi:github-copilot/gpt-6.1-sol:high:last|lane|0|1|claude:opus:high pi:github-copilot/gpt-6.1-sol:high|
unmarked lane walk|claude:opus:high,codex:gpt-6.1-sol:high|lane|0|0|claude:opus:high codex:gpt-6.1-sol:high|
hosted final entry marked|codex:gpt-6.1-sol:high,pi@local:github-copilot/gpt-6.1-sol:high:last|lane|0|1|codex:gpt-6.1-sol:high pi@local:github-copilot/gpt-6.1-sol:high|
earlier entry marked|claude:opus:high:last,codex:gpt-6.1-sol:high|lane|1|0|codex:gpt-6.1-sol:high|claude:opus:high:last
overseer preference marked|claude:opus:high,codex:gpt-6.1-sol:high:last||1|0|claude:opus:high|codex:gpt-6.1-sol:high:last
effort word last is no mark|claude:opus:last|lane|0|0|claude:opus:last|
another fourth field|claude:opus:high:first|lane|1|0||claude:opus:high:first
ROWS
# Each control drops one condition of the mark in a copy of the lib, and the
# row that condition decides turns red.
while IFS='|' read -r mutation preference mode old new green; do
  MUTANT="$(mutant_scripts "mark-$mutation" lib/overseer-launch.sh)"
  mutate_file "$MUTANT/lib/overseer-launch.sh" "$old" "$new"
  if [[ "$(mark_read "$MUTANT/lib/overseer-launch.sh" "$preference" "$mode")" != "$green" ]]; then
    pass "control: $mutation turns the $preference row red"
  else
    fail "control: $mutation leaves the $preference row green"
  fi
done <<'ROWS'
final-only|claude:opus:high:last,codex:gpt-6.1-sol:high|lane|      if [[ -n "$rest" ]]; then|      if false; then|1|0|codex:gpt-6.1-sol:high|claude:opus:high:last
lane-only|claude:opus:high,codex:gpt-6.1-sol:high:last||"${2:-}" == lane && "$entry" == *:*:*:last|"$entry" == *:*:*:last|1|0|claude:opus:high|codex:gpt-6.1-sol:high:last
ROWS
# Each control turns one row above red: its preference parsed by a copy of
# the lib with one line replaced must no longer give that row's answer.
control() { # MUTATION PREFERENCE CALLER GREEN OLD NEW [HELD]
  local mutant
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
  if [[ "$(observe "$2" "$3" "$mutant/lib/overseer-launch.sh" "${7:-}")" != "$4" ]]; then
    pass "control: $1 turns the $2 assertion red"
  else
    fail "control: $1 did not turn the $2 assertion red"
  fi
}
NUMERIC_GREEN="0|1|claude:fable:high#top|claude:1:high|||$NUMERIC|"
CLASSES='claude:standard:high,codex:standard:high'
CLASSES_GREEN='0|2|claude:opus:high#standard codex::high#standard|||||opus'
control refusal claude:1:high fable "$NUMERIC_GREEN" \
  '    if [[ "$entry" =~ ^(claude|codex|copilot|pi):[1-9][0-9]*:[a-z]+$ ]]; then' \
  '    if false && [[ "$entry" =~ ^(claude|codex|copilot|pi):[1-9][0-9]*:[a-z]+$ ]]; then'
control model claude:1:high fable "$NUMERIC_GREEN" \
  '    OL_ENTRY_MODEL="${OL_WALK_CALLER_MODEL:-$OL_PREFERENCE_CALLER_MODEL}"' '  : # caller model is dropped'
control warning claude:1:high fable "$NUMERIC_GREEN" '  (( ! OL_DEPRECATION_WARNED )) || return 0' '  :'
# A numeric copilot entry keeps the caller's model, so the runtime answer's
# harness-default line names a model the launch does not run.
control numeric-line copilot:2:high fable '0|1|copilot:fable:high#top|copilot:2:high|||entry=copilot:2:high form=harness:model:effort|' \
  '    [[ "$OL_CLASS_MODEL" != "$OL_ENTRY_MODEL" ]] || OL_ENTRY_WARNING="$OL_CLASS_WARNING"' '    OL_ENTRY_WARNING="$OL_CLASS_WARNING"'
control numeric-class claude:1:high opus "0|1|claude:opus:high#standard|claude:1:high|||$NUMERIC|" \
  '    OL_ENTRY_CLASS="$OL_CLASS"' '    :'
control alias "$CLASSES" other "$CLASSES_GREEN" \
  '    OL_CLASS_MODEL="$selector$window" OL_CLASS_WARNING="$warning"' '    OL_CLASS_MODEL="$word$window" OL_CLASS_WARNING="$warning"'
control alias-warning "$CLASSES" other "$CLASSES_GREEN" \
  '    OL_CLASS_MODEL="$selector$window" OL_CLASS_WARNING="$warning"' '    OL_CLASS_MODEL="$selector$window" OL_CLASS_WARNING=""'
control resolution-warning "$CLASSES" other "$CLASSES_GREEN" \
  '  [[ -n "$1" ]] && (( ! OL_CLASS_WARNED )) || return 0' '  [[ -n "$1" ]] || return 0'
OLD_ID_GREEN='0|2|claude:claude-opus-5-5:high codex:gpt-5.5:high||||entry=claude:claude-opus-5-5:high form=model-class|'
control old-id claude:claude-opus-5-5:high,codex:gpt-5.5:high other "$OLD_ID_GREEN" \
  '  (( OL_ENTRY_CLASS_RC != 2 )) || ol_deprecated "entry=$1" form=model-class' '  :'
control exact-id-line claude:claude-opus-5-5:high,codex:gpt-5.5:high other "$OLD_ID_GREEN" \
  '    OL_CLASS=""' '    OL_CLASS=""; printf "%s\\n" "$warning" >&2'
control exact-id-harness claude:opus:high,codex:gpt-6.1-sol:high other \
  '0|2|claude:opus:high#standard codex:gpt-6.1-sol:high|||||opus' \
  '    [[ "$old_id" != true || "$1" != claude ]] || return 2' '    [[ "$old_id" != true ]] || return 2'
control lines-held claude:standard:high,claude:claude-opus-5-5:high other \
  '0|2|claude:opus:high#standard claude:claude-opus-5-5:high|||||' \
  '[[ -z "${ORCH_MODEL_LINES_HELD:-}" ]] || OL_LINES_HELD=1' ':' held

# The fixture records the actual argv of every dependency call. Each word
# needs one decision. Claude's answer applies the managed override; the
# other harnesses still receive their unsupported-list runtime context.
resolve_word() { # HARNESS WORD OVERRIDE [LIB [numeric]]
  : > "$TMP_ROOT/calls"
  env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TABLE_PATH" \
    KENDEX_TEST_CALLS="$TMP_ROOT/calls" KENDEX_TEST_STANDARD_OVERRIDE="$3" \
    "$BASH" -c '
      set -euo pipefail
      source "$1"
      rc=0
      if [[ "${4:-}" == numeric ]]; then
        OL_WALK_CALLER_MODEL="$3"
        ol_entry_model "$2:1:high" || rc=$?
        OL_CLASS="$OL_ENTRY_CLASS" OL_CLASS_MODEL="$OL_ENTRY_MODEL"
      else
        ol_model_class "$2" "$3" || rc=$?
      fi
      code=""
      if [[ "$rc" == 1 ]]; then code="$(jq -r ".resolution.code // empty" <<<"$OL_CLASS_ERR")"; fi
      printf "%s|%s|%s|%s\n" "$rc" "$OL_CLASS" "$OL_CLASS_MODEL" "$code"
    ' _ "${4:-$LIB}" "$1" "$2" "${5:-}"
}
while IFS='|' read -r harness word override status class model code context mode; do
  assert_eq "$(resolve_word "$harness" "$word" "$override" "$LIB" "$mode")" "$status|$class|$model|$code" \
    "managed word: $harness $word override=$override"
  assert_eq "$(jq -sc 'length' "$TMP_ROOT/calls")" 1 "one kendex call: $harness $word override=$override"
  assert_eq "$(jq -r 'index("--runtime-context-json") != null' "$TMP_ROOT/calls")" "$context" \
    "runtime context: $harness $word override=$override"
done <<'ROWS'
claude|top||0|top|fable||false
claude|standard|anthropic/claude-haiku-5-5|0|standard|haiku||false
claude|opus[1m]|anthropic/claude-haiku-5-5|0|standard|haiku[1m]||false
claude|standard|openai/gpt-6.2-sol|1||standard|unsupported-managed-model|false
claude|opus|openai/gpt-6.2-sol|0|standard|opus||true|numeric
claude|claude-opus-5-5||2||claude-opus-5-5||false
codex|standard||0|standard|||true
copilot|standard||0|standard|||true
ROWS
# A source copy that discards the managed alias must fail the override row.
MUTANT="$(mutant_scripts managed-alias lib/overseer-launch.sh)"
mutate_file "$MUTANT/lib/overseer-launch.sh" \
  '    OL_CLASS_MODEL="$selector$window" OL_CLASS_WARNING="$warning"' \
  '    OL_CLASS_MODEL="$word$window" OL_CLASS_WARNING="$warning"'
if [[ "$(resolve_word claude standard anthropic/claude-haiku-5-5 "$MUTANT/lib/overseer-launch.sh")" != '0|standard|haiku|' ]]; then
  pass "control: discarding the managed alias fails the override assertion"
else
  fail "control: discarding the managed alias passes the override assertion"
fi
MUTANT="$(mutant_scripts numeric-managed lib/overseer-launch.sh)"
mutate_file "$MUTANT/lib/overseer-launch.sh" \
  '    ol_model_class "$OL_ENTRY_HARNESS" "$OL_ENTRY_MODEL" classify || OL_ENTRY_CLASS_RC=$?' \
  '    ol_model_class "$OL_ENTRY_HARNESS" "$OL_ENTRY_MODEL" || OL_ENTRY_CLASS_RC=$?'
if [[ "$(resolve_word claude opus openai/gpt-6.2-sol "$MUTANT/lib/overseer-launch.sh" numeric)" != '0|standard|opus|' ]]; then
  pass "control: resolving the retained caller model fails numeric compatibility"
else
  fail "control: resolving the retained caller model passes numeric compatibility"
fi
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
