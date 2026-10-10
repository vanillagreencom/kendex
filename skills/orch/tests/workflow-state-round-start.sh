#!/usr/bin/env bash
# Surface: workflow-state new-round-id. Inputs: workflow-state and its lib/.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/growth-state.sh"
source "$TEST_DIR/lib/virtual-clock.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'round-start: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'round-start: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'round-start: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
WS="$TEST_DIR/../scripts/workflow-state"
mkdir -p "$TMP_ROOT/clock-bin"
virtual_clock_install "$TMP_ROOT/clock-bin" "$TMP_ROOT/clock"
printf '1767225600\n' > "$STUB_CLOCK"
round_start() {
  local bin="$1" field="$2" kind="$3" sd="$TMP_ROOT/state-$field-${4:-live}" rid
  "$bin" --state-dir "$sd" init KEN-1 >/dev/null
  rid="$(PATH="$TMP_ROOT/clock-bin:$PATH" "$bin" --state-dir "$sd" new-round-id KEN-1 "$field")"
  jq -r --arg field "$field" --arg round "$rid" --arg kind "$kind" '
    .[$field] == $round and
    (if $kind == "none" then (.stages // []) == [] else
      .stages == [{kind: $kind, round_id: $round, start: 1767225600, end: null}]
      end)' "$sd/workflow-state-KEN-1.json"
}
while read -r field kind; do
  assert_eq "$(round_start "$WS" "$field" "$kind")" true "$field stores token and $kind stage"
done <<'ROWS'
dev_round_id dev
review_round_id review
other_field none
ci_round_id none
ROWS
MUTANT="$(mutant_scripts no-start workflow-state)/workflow-state"
mutate_file "$MUTANT" '| .stages = ((.stages // []) + [{kind: $kind, round_id: $round, start: $now, end: null}])' '| .stages = (.stages // [])'
assert_eq "$(round_start "$MUTANT" dev_round_id dev mutant)" false 'control: dropping the stage fails the same round-start assertion'
MUTANT="$(mutant_scripts wrong-start workflow-state)/workflow-state"
mutate_file "$MUTANT" 'start: $now, end: null' 'start: 0, end: null'
assert_eq "$(round_start "$MUTANT" dev_round_id dev wrong-time)" false 'control: a wrong numeric start fails the same round-start assertion'
printf 'pass: %s fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
