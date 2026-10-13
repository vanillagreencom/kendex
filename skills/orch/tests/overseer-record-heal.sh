#!/usr/bin/env bash
# Surface: lib/overseer-launch.sh::ol_record_heal.
# Inputs: scripts/lib/overseer-launch.sh and workflow-state with its libraries.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd -P)"
TMP_ROOT="$(mktemp -d)" || { echo 'overseer-record-heal: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'overseer-record-heal: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'overseer-record-heal: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
mkdir "$TMP_ROOT/repo"
git -C "$TMP_ROOT/repo" init -q
git -C "$TMP_ROOT/repo" config gc.auto 0
git -C "$TMP_ROOT/repo" config maintenance.auto false

heal_case() { # HARNESS HOME SESSION [SCRIPTS]
  local scripts="${4:-$SRC_DIR}" before after
  (
    cd "$TMP_ROOT/repo"
    "$SRC_DIR/workflow-state" init oversee >/dev/null
    "$SRC_DIR/workflow-state" set oversee overseer "$(jq -nc --arg h "$1" --arg home "$2" --arg s "$3" \
      '{server:"7000",pane:"%9",harness:$h,home:$home,session_id:$s}')" >/dev/null
  )
  before=$(cd "$TMP_ROOT/repo" && "$SRC_DIR/workflow-state" get oversee .overseer)
  env -u ORCH_STATE_DIR "$BASH" -euo pipefail -c '
    cd "$1"
    SCRIPT_DIR=$2 DEP_ERR=$3
    . "$SCRIPT_DIR/lib/overseer-launch.sh"
    ol_record_heal 7000 %9 1790000000 claude /claude s1
  ' _ "$TMP_ROOT/repo" "$scripts" "$TMP_ROOT/heal.err"
  after=$(cd "$TMP_ROOT/repo" && "$SRC_DIR/workflow-state" get oversee .overseer)
  HEAL_CHANGED=no
  [[ "$after" == "$before" ]] || HEAL_CHANGED=yes
  HEAL_BINDING=$(jq -r '[.server_start,.harness,.home,.session_id]|@csv' <<<"$after")
}

while IFS='|' read -r harness home session changed; do
  heal_case "$harness" "$home" "$session"
  assert_eq "$HEAL_CHANGED" "$changed" "heal agrees with recorded identity $harness $home $session" "$TMP_ROOT/heal.err"
  if [[ "$changed" == yes ]]; then
    assert_eq "$HEAL_BINDING" '1790000000,"claude","/claude","s1"' 'the native session fills every missing binding field'
  fi
done <<'ROWS'
|||yes
claude|/claude|s1|yes
copilot|/claude|s1|no
claude|/other|s1|no
claude|/claude|child|no
||child|no
ROWS

for rule in harness home session_id; do
  control=$(mutant_scripts "heal-$rule" lib/overseer-launch.sh)
  case "$rule" in
    harness)
      mutate_file "$control/lib/overseer-launch.sh" 'and ((.harness // "") == "" or .harness == $harness)' 'and true'
      heal_case copilot /claude s1 "$control" ;;
    home)
      mutate_file "$control/lib/overseer-launch.sh" 'and ((.home // "") == "" or $home == "" or .home == $home)' 'and true'
      heal_case claude /other s1 "$control" ;;
    session_id)
      mutate_file "$control/lib/overseer-launch.sh" 'and ((.session_id // "") == "" or .session_id == $session)' 'and true'
      heal_case claude /claude child "$control" ;;
  esac
  assert_eq "$HEAL_CHANGED" yes "control: dropping $rule fails the unchanged-record assertion"
done
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
