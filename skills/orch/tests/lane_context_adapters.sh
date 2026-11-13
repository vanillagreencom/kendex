#!/usr/bin/env bash
# Tests for what lib/lane-context.sh and its adapters under lib/adapters/
# still answer: a Claude model's launch identity and window, the launch's
# compaction settings, a context record's fields, and the Copilot hook scope.
#
# LIB_UNDER_TEST names another copy of the library, with its adapters beside
# it, for the must-fail controls at the end; each control runs only the one
# table its planted defect reaches.
# Inputs: skills/agent-runtime/, skills/agent-runtime/scripts/, skills/change-scope/references/,
# skills/change-scope/scripts/, skills/communication/references/reports.md, skills/mailbox/scripts/,
# skills/orch/runtime/, skills/orch/scripts/, skills/orch/tests/.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
LIB="${LIB_UNDER_TEST:-$SCRIPTS_DIR/lib/lane-context.sh}"

TMP_ROOT="$(mktemp -d)" || { echo "lane_context_adapters: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lane_context_adapters: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lane_context_adapters: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

# The suite is a run of tables, each opened by `section NAME`. An ordinary run
# covers every table. A control's run, of a mutated copy, names the one table its planted defect
# reaches in LANE_CONTEXT_SUITE_ONLY, and runs that table alone. SITES records
# each assertion under its table, so a control finds the table from the
# assertion it expects to go red and refuses a name that two tables share.
SECTION_NOW=setup
SITES="$TMP_ROOT/sites"
: > "$SITES"
section() { # NAME
  SECTION_NOW="$1"
  [[ -z "${LIB_UNDER_TEST:-}" || -z "${LANE_CONTEXT_SUITE_ONLY:-}" || "$LANE_CONTEXT_SUITE_ONLY" == "$1" ]]
}
eval "assertions_$(declare -f pass)"
eval "assertions_$(declare -f fail)"
pass() { printf '%s\t%s\n' "$SECTION_NOW" "$1" >> "$SITES"; assertions_pass "$@"; }
fail() { printf '%s\t%s\n' "$SECTION_NOW" "$1" >> "$SITES"; assertions_fail "$@"; }

unset ANTHROPIC_BASE_URL ANTHROPIC_DEFAULT_FABLE_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL
unset CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_MANTLE CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST

if section claude-identity; then
  echo "=== Claude families and native aliases need no version pins ==="
  echo "=== resolved Claude launch identity ==="
  while IFS='|' read -r model pin want mode recorded; do
    got="$(env ANTHROPIC_DEFAULT_OPUS_MODEL="$pin" ANTHROPIC_DEFAULT_FABLE_MODEL="$pin" \
      ANTHROPIC_DEFAULT_SONNET_MODEL="$pin" ANTHROPIC_DEFAULT_HAIKU_MODEL="$pin" "$BASH" -euo pipefail -c \
      '. "$1"; lane_adapter_claude_model_id "$2" "$3" "$4"' _ "$LIB" "$model" "${mode:-resolved}" "$recorded")"
    assert_eq "$got" "$want" "${mode:-resolved} identity $model pin=$pin"
  done <<'ROWS'
fable-5-1||claude-fable-5-1
claude-fable-5-1||claude-fable-5-1
claude-fable-5-1[1m]||claude-fable-5-1
claude-opus-4-8-20261001||claude-opus-4-8-20261001
sonnet||
sonnet|claude-sonnet-4-6|
sonnet[1m]|claude-sonnet-4-6|
fable||
best||
default||
opus||
sonnet|claude-sonnet-4-6|sonnet|recorded
sonnet|claude-sonnet-4-6|sonnet|launch
sonnet[1m]|claude-sonnet-4-6|sonnet[1m]|launch
opus|claude-opus-5-5|opus|launch
fable|claude-fable-5-5|fable|launch
haiku|claude-haiku-5-5|haiku|launch
fable||fable|recorded
opus[1m]||opus|recorded
haiku||haiku|recorded
fable-5-1||claude-fable-5-1|recorded
claude-opus-4-8-20261001||claude-opus-4-8-20261001|recorded
claude-sonnet-4-6|claude-sonnet-5-5|sonnet|resolved|sonnet
claude-opus-4-8||opus|resolved|opus[1m]
claude-fable-5-1||fable|resolved|fable
claude-haiku-5-5||haiku|resolved|haiku
claude-opus-4-8||claude-opus-4-8|resolved|sonnet
claude-opus-4-8||claude-opus-4-8|resolved|claude-opus-4-6
opusplan||opusplan|launch
MyProviderModel||MyProviderModel|launch
fable-5-1[1m]||claude-fable-5-1|launch
ROWS
  # `model|window|id`: a model, its window, and the id a launch writes for it.
  # An id with a measured window reads it ahead of its family; every other
  # spelling of the family, alias and version alike, reads the family's
  # budget. Claude receives native aliases and applies its own family
  # overrides.
  while IFS='|' read -r model want id; do
    assert_eq "$(bash -c 'set -euo pipefail; source "$1"; lane_adapter_claude_window "$2"; lane_adapter_claude_model_id "$2"' _ "$LIB" "$model" | tr '\n' '|')" \
      "${want:+$want|}${id:-$model}|" "claude window of $model: ${want:-none}, written as ${id:-$model}"
  done <<'ROWS'
fable|1000000
opus[1m]|1000000
claude-opus-5-5|1000000
sonnet|200000
Sonnet|200000|sonnet
claude-sonnet-5|1000000
claude-sonnet-5-5|1000000
Claude-Sonnet-5-5|1000000|claude-sonnet-5-5
haiku|200000
claude-haiku-4-5|200000
claude-haiku-4-5-20251001|200000
claude-haiku-5-5|200000
claude-sonnet-9-9|200000
claude-sonnet-4-6|200000
claude-sonnet-4-5|200000
claude-sonnet-5-1|200000
sonnet[1m]|200000
claude-sonnet-5-5[1m]|200000
haiku[1m]|200000
MyProviderModel|200000|myprovidermodel
|200000
ROWS
fi

if section dry-launch; then
  echo "=== dry launch keeps compaction off for new models ==="
  # Exercise the production gate and command builder in one shell. The second
  # build must not repeat the notice the first build emitted.
  while IFS='|' read -r model window notices; do
    got="$("$BASH" -euo pipefail -c '
      source "${1%/*}/lane-launch.sh"
      launch_choice_lead_settings claude --model "$2"
      launch_choice_lead_settings --question-off claude --model "$2"
      printf "%s|%s|%s\n" "$LAUNCH_CHOICE_COMPACTION" "$(lane_adapter_claude_window "$2")" "${LAUNCH_CHOICE_KEPT[*]}"
    ' _ "$LIB" "$model" 2>"$TMP_ROOT/launch.err")"
    assert_eq "${got%%|*}" on "dry launch $model disables compaction"
    remaining="${got#*|}"
    assert_eq "${remaining%%|*}" "$window" "dry launch $model uses its budget"
    assert_contains "${remaining#*|}" '--settings={"env":{"DISABLE_AUTO_COMPACT":"1"}}' "dry launch $model carries compaction settings"
    assert_eq "$(grep -c '^claude-window-default model=' "$TMP_ROOT/launch.err" || true)" "$notices" "dry launch $model notice count"
    if [[ "$notices" == 1 ]]; then
      assert_eq "$(cat "$TMP_ROOT/launch.err")" "claude-window-default model=$model window=$window" "dry launch $model notice fields"
    fi
  done <<'ROWS'
claude-sonnet-9-9|200000|0
claude-haiku-5-5|200000|0
claude-opus-5-5|1000000|0
claude-lyra-9-9|200000|1
ROWS
fi

if section record; then
  echo "=== a context record's fields ==="
  # shellcheck disable=SC2016  # expanded by the child shell.
  fields() { bash -c 'source "$1"; if lane_context_record_fields "$2"; then
      printf "rc=0 harness=%s tokens=%s pane=%s session=%s gap=%s at=%s\n" "$LANE_CTX_HARNESS" "${LANE_CTX_TOKENS:-none}" "$LANE_CTX_PANE_KEY" "${LANE_CTX_SESSION:-none}" "${LANE_CTX_GAP:-none}" "${LANE_CTX_AT:+set}"
    else echo "rc=$?"; fi' _ "$LIB" "$1"; }
  while IFS='|' read -r record expected what; do
    assert_eq "$(fields "$record")" "$expected" "$what"
  done <<'ROWS'
{"harness":"claude","model":null,"tokens":null,"window":null,"used_pct":null,"capacity_source":null,"session_id":"s1","pane_key":"7000 %9","gap":"home-unnamed","at":"t"}|rc=0 harness=claude tokens=none pane=7000 %9 session=s1 gap=home-unnamed at=set|a gap record parses with its gap, its session and no tokens
{"harness":"claude","tokens":5,"gap":null,"pane_key":"k","at":"t"}|rc=0 harness=claude tokens=5 pane=k session=none gap=none at=set|a reading parses with no gap
{"harness":"claude","tokens":null,"gap":null,"pane_key":"k"}|rc=1|a record with neither a reading nor a gap is no record
{"harness":"claude","tokens":5,"gap":"home-unnamed","pane_key":"k"}|rc=1|a record carrying both a reading and a gap is no record
ROWS
fi

if section scope; then
  echo "=== the Copilot hook scope a session loads ==="
  SCOPES="$TMP_ROOT/scopes"
  scope() { # ROOT HOME
    local out rc=0
    out="$(bash -c 'source "$1"; lane_context_copilot_hooks "$2" "$3"' _ "$LIB" "$1" "$2")" || rc=$?
    printf 'rc=%s %s' "$rc" "${out#"$SCOPES"/}"
  }
  # render_hooks DIR NAME... — each NAME rendered as Copilot loads a hook, its
  # script beside its registry document; a name spelled NAME.sh renders the
  # script alone.
  render_hooks() { # DIR NAME...
    local dir="$1" name
    shift
    mkdir -p "$dir"
    for name in "$@"; do
      case "$name" in
        *.sh) : > "$dir/$name" ;;
        *) : > "$dir/$name.sh"; : > "$dir/$name.json" ;;
      esac
    done
  }
  render_hooks "$SCOPES/repo/.github/hooks" lane-mail-check lane-mail-compact lane-mail-start
  render_hooks "$SCOPES/home/hooks" lane-mail-check lane-mail-compact lane-mail-start
  render_hooks "$SCOPES/half/.github/hooks" lane-mail-check
  render_hooks "$SCOPES/nostart/.github/hooks" lane-mail-check lane-mail-compact
  render_hooks "$SCOPES/bare/.github/hooks" lane-mail-check lane-mail-compact.sh lane-mail-start
  # `root|home|want`, `-` naming none.
  while IFS='|' read -r root home want; do
    [ "$root" != - ] || root=""
    [ "$home" != - ] || home=""
    assert_eq "$(scope "${root:+$SCOPES/$root}" "${home:+$SCOPES/$home}")" "$want" "scope ${root:-none} under ${home:-none}: $want"
  done <<'ROWS'
repo|home|rc=0 repo/.github/hooks
half|home|rc=0 home/hooks
bare|home|rc=0 home/hooks
half|-|rc=1 
nostart|home|rc=0 home/hooks
nostart|-|rc=1 
bare|-|rc=1 
-|home|rc=0 home/hooks
-|-|rc=1 
ROWS
fi

if [[ -z "${LIB_UNDER_TEST:-}" ]]; then
  echo "=== must-fail controls ==="
  SECTION_NOW=controls
  TABLE_SITES="$TMP_ROOT/table-sites"
  cp -- "$SITES" "$TABLE_SITES"
  # control_table PATTERN SITES — the one table whose assertions begin with
  # PATTERN, as a control's FAIL line does. A pattern no table, or two tables,
  # begin with names no table: a duplicate elsewhere never lets the wrong
  # table satisfy a control.
  control_table() { # PATTERN SITES
    local tables
    tables="$(PATTERN="$1" awk -F'\t' 'index($2, ENVIRON["PATTERN"]) == 1 && !seen[$1]++ { print $1 }' "$2")"
    [[ -n "$tables" && "$tables" != *$'\n'* ]] || return 1
    printf '%s\n' "$tables"
  }
  printf 'one\tshared name\ntwo\tshared name too\nthree\tunique name\nthree\tunique name again\n' > "$TMP_ROOT/dup-sites"
  assert_eq "$(control_table 'unique name' "$TMP_ROOT/dup-sites")" three "a pattern one table holds names that table"
  assert_eq "$(control_table 'shared name' "$TMP_ROOT/dup-sites" || echo none)" none "a pattern two tables hold names no table"
  assert_eq "$(control_table 'absent name' "$TMP_ROOT/dup-sites" || echo none)" none "a pattern no table holds names no table"
  # control NAME FILE OLD NEW PATTERN — a copy of the library whose FILE has OLD
  # replaced by NEW, run through the one table PATTERN is a FAIL line of; the
  # table must print PATTERN once.
  control() { # NAME FILE OLD NEW PATTERN
    local copy="$TMP_ROOT/control-$1/lib" out table
    table="$(control_table "$5" "$TABLE_SITES" || true)"
    assert_eq "${table:+one}" one "control $1: $5 begins the assertions of one table"
    [[ -n "$table" ]] || return 0
    mkdir -p "$copy"
    cp -R "$SCRIPTS_DIR/lib/." "$copy/"
    assert_eq "$(grep -c -F -e "$3" "$copy/$2" || true)" "1" "control $1 finds exactly one site to mutate"
    perl -i -pe 'BEGIN { ($o, $n) = (shift, shift) } s/\Q$o\E/$n/g' -- "$3" "$4" "$copy/$2"
    out="$(LANE_CONTEXT_SUITE_ONLY="$table" LIB_UNDER_TEST="$copy/lane-context.sh" bash "${BASH_SOURCE[0]}" 2>&1 || true)"
    assert_eq "$(grep -cF -- "FAIL  $5" <<<"$out" || true)" "1" "control $1: $5 goes red"
  }
  control native-alias adapters/claude.sh '[[ "${2:-}" != launch ]] || model=${1:-}' 'model=${ANTHROPIC_DEFAULT_SONNET_MODEL:-$model}' \
    'launch identity sonnet pin=claude-sonnet-4-6'
  control version-identity adapters/claude.sh '  printf '\''%s\n'\'' "${model}"' '  printf '\''%s\n'\'' "${model%-20261001}"' \
    'resolved identity claude-opus-4-8-20261001 pin='
  control unresolved-model adapters/claude.sh '      *) model="" ;;' '      *) : ;;' \
    'resolved identity best pin='
  control version-spelling adapters/claude.sh 'model="claude-$model"' ':' \
    'resolved identity fable-5-1 pin='
  control capacity-spelling adapters/claude.sh 'case "${2:-}" in launch | resolved | recorded) model=${model%\[1m\]} ;; esac' ':' \
    'resolved identity claude-fable-5-1[1m] pin='
  control recorded-alias adapters/claude.sh 'if [[ "${2:-}" != resolved ]]; then' 'if false; then' \
    'recorded identity sonnet pin=claude-sonnet-4-6'
  control scope-registry lane-context.sh '[ -f "$dir/$name.sh" ] && [ -f "$dir/$name.json" ]' '[ -f "$dir/$name.sh" ]' \
    'scope bare under none'
  control scope-start lane-context.sh 'LANE_CONTEXT_COPILOT_HOOKS="lane-mail-check lane-mail-compact lane-mail-start"' 'LANE_CONTEXT_COPILOT_HOOKS="lane-mail-check lane-mail-compact"' \
    'scope nostart under none'
  control claude-family adapters/claude.sh '*sonnet*=200000' '*sonnet*=1000000' \
    'claude window of sonnet: 200000'
  control claude-default adapters/claude.sh 'LANE_ADAPTER_CLAUDE_DEFAULT_WINDOW=200000' 'LANE_ADAPTER_CLAUDE_DEFAULT_WINDOW=1000000' \
    'dry launch claude-lyra-9-9 uses its budget'
  control claude-new-model-launch adapters/claude.sh '  printf '\''%s\n'\'' "$LANE_ADAPTER_CLAUDE_DEFAULT_WINDOW"' '  return 0' \
    'dry launch claude-lyra-9-9 disables compaction'
  control claude-notice adapters/claude.sh 'LANE_ADAPTER_CLAUDE_WINDOW_NOTICED=true' ':' \
    'dry launch claude-lyra-9-9 notice count'
  control gap-parsed lane-context.sh 'or (.tokens == null and (.gap | type)' 'or (false and (.gap | type)' \
    'a gap record parses with its gap, its session and no tokens'
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
