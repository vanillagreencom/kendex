#!/usr/bin/env bash
# Surface: workflow-state new-round-id. Inputs: workflow-state, oversee-cycle and their lib/.
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
mutate_file "$MUTANT" '+ [{kind: $kind, round_id: $round, start: $now, end: null}]' '+ []'
assert_eq "$(round_start "$MUTANT" dev_round_id dev mutant)" false 'control: dropping the stage fails the same round-start assertion'
MUTANT="$(mutant_scripts wrong-start workflow-state)/workflow-state"
mutate_file "$MUTANT" 'start: $now, end: null' 'start: 0, end: null'
assert_eq "$(round_start "$MUTANT" dev_round_id dev wrong-time)" false 'control: a wrong numeric start fails the same round-start assertion'
round_restart() {
  local bin="$1" kind="$2" label="$3" cycle="${4:-$TEST_DIR/../scripts/oversee-cycle}"
  local sd="$TMP_ROOT/restart-$label" first second before rows
  "$bin" --state-dir "$sd" init KEN-1 >/dev/null
  printf '1767225600\n' > "$STUB_CLOCK"
  first="$(PATH="$TMP_ROOT/clock-bin:$PATH" "$bin" --state-dir "$sd" new-round-id KEN-1 "${kind}_round_id")"
  "$bin" --state-dir "$sd" update KEN-1 --arg kind "$kind" '
    .stages += [{kind:$kind, round_id:"earlier", start:1767225500, end:null},
      {kind:(if $kind == "dev" then "review" else "dev" end), round_id:"other", start:1767225500, end:null},
      {kind:$kind, round_id:"closed", start:1767225400, end:1767225450}]'
  printf '1767225648\n' > "$STUB_CLOCK"
  second="$(PATH="$TMP_ROOT/clock-bin:$PATH" "$bin" --state-dir "$sd" new-round-id KEN-1 "${kind}_round_id")"
  jq -r --arg first "$first" --arg second "$second" '
    .stages as $s | [
      ([$s[] | select(.round_id == $first or .round_id == "earlier") |
        .end == 1767225648 and .superseded == true] | all),
      ($s[2].end == null and ($s[2] | has("superseded") | not)),
      ($s[3] == {kind:$s[0].kind, round_id:"closed", start:1767225400, end:1767225450}),
      ($s[4].round_id == $second and $s[4].start == 1767225648 and $s[4].end == null)
    ] | all' "$sd/workflow-state-KEN-1.json"
  "$WS" --state-dir "$sd" init oversee >/dev/null
  "$WS" --state-dir "$sd" update oversee '.lanes = [{item:"KEN-1"}]'
  rows="$(env ORCH_STATE_DIR="$sd" "$cycle" --state-dir "$sd" stages KEN-1)"
  # The overseer's stage reader consumes these machine-readable fields.
  if [[ "$rows" == *"round_id=$first start=1767225600 end=1767225648 superseded=1"* &&
        "$(grep -c "kind=$kind .*end=-" <<<"$rows")" == 1 ]]; then echo true; else echo false; fi
  "$bin" --state-dir "$sd" update KEN-1 '.stages[-1].end = 1767225650'
  before="$(jq -c '.stages' "$sd/workflow-state-KEN-1.json")"
  printf '1767225660\n' > "$STUB_CLOCK"
  PATH="$TMP_ROOT/clock-bin:$PATH" "$bin" --state-dir "$sd" new-round-id KEN-1 "${kind}_round_id" >/dev/null
  jq -r --argjson before "$before" '.stages[:-1] == $before' "$sd/workflow-state-KEN-1.json"
}
for kind in dev review; do
  assert_eq "$(round_restart "$WS" "$kind" "$kind")" $'true\ntrue\ntrue' "$kind restart closes all same-kind open stages, prints them, and preserves other or closed stages"
done
MUTANT="$(mutant_scripts no-supersede workflow-state)/workflow-state"
mutate_file "$MUTANT" '.end = $now | .superseded = true' '.'
assert_contains "$(round_restart "$MUTANT" review old-code)" $'false\nfalse' 'control: original mint behavior fails superseded state and output'
MUTANT="$(mutant_scripts all-kinds workflow-state)/workflow-state"
mutate_file "$MUTANT" '.kind == $kind and .end == null' '.end == null'
assert_contains "$(round_restart "$MUTANT" review all-kinds)" false 'control: closing another kind fails preservation'
MUTANT="$(mutant_scripts closed-again workflow-state)/workflow-state"
mutate_file "$MUTANT" '.kind == $kind and .end == null' '.kind == $kind'
assert_eq "$(round_restart "$MUTANT" review closed-again)" $'false\ntrue\nfalse' 'control: changing closed stages fails both closed-stage assertions'
MUTANT="$(mutant_scripts no-marker/orch oversee-cycle)/oversee-cycle"
ln -s "$TEST_DIR/../../github" "$TMP_ROOT/no-marker/github"
mutate_file "$MUTANT" 'if .superseded == true then " superseded=1" else "" end' 'if .superseded == true then "" else "" end'
assert_eq "$(round_restart "$WS" review no-marker "$MUTANT")" $'true\nfalse\ntrue' 'control: hiding superseded fails the stage reader assertion'
printf 'pass: %s fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
