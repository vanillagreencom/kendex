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

heal_case() { # HARNESS HOME SESSION [SCRIPTS] [CALLER_HOME] [CALLER_SESSION] [START_ID] [PANE_SHAPE] [ROW]
  local scripts="${4:-$SRC_DIR}" before after
  (
    cd "$TMP_ROOT/repo"
    "$SRC_DIR/workflow-state" init oversee >/dev/null
    "$SRC_DIR/workflow-state" set oversee overseer "$(jq -nc --arg h "$1" --arg home "$2" --arg s "$3" \
      '{server:"7000",pane:"%9",harness:$h,home:$home,session_id:$s}')" >/dev/null
  )
  before=$(cd "$TMP_ROOT/repo" && "$SRC_DIR/workflow-state" get oversee .overseer)
  mkdir -p "$TMP_ROOT/repo/tmp/lane-mail/overseer"
  rm -f -- "$TMP_ROOT/repo/tmp/lane-mail/overseer/session-7000-9.jsonl"
  if [[ "${9:-yes}" == yes ]]; then
    jq -nc --arg s "${7-s1}" '{event:"SessionStart",harness:"claude",session_id:$s}' \
      > "$TMP_ROOT/repo/tmp/lane-mail/overseer/session-7000-9.jsonl"
  fi
  HEAL_RC=0
  env -u ORCH_STATE_DIR "HEAL_PANE_SHAPE=${8:-shell}" "$BASH" -euo pipefail -c '
    cd "$1"
    SCRIPT_DIR=$2 DEP_ERR=$3
    . "$SCRIPT_DIR/lib/lane-context.sh"
    . "$SCRIPT_DIR/lib/overseer-launch.sh"
    # Pure process-map input for the existing evidence owner, not liveness.
    tmux() { printf "%s\n" 7000; }
    ps() {
      [[ "$*" == "-o comm= -p 7000" ]] || return 1
      case "$HEAL_PANE_SHAPE" in
        shell) printf "%s\n" bash ;;
        direct) printf "%s\n" claude ;;
        *) return 1 ;;
      esac
    }
    ol_record_heal 7000 %9 1790000000 claude "$4" "$5" "$6"
  ' _ "$TMP_ROOT/repo" "$scripts" "$TMP_ROOT/heal.err" "${5-/claude}" "${6-s1}" "[$before]" 2>"$TMP_ROOT/stderr" || HEAL_RC=$?
  after=$(cd "$TMP_ROOT/repo" && "$SRC_DIR/workflow-state" get oversee .overseer)
  HEAL_CHANGED=no
  [[ "$after" == "$before" ]] || HEAL_CHANGED=yes
  HEAL_BINDING=$(jq -r '[.server_start,.harness,.home,.session_id]|@csv' <<<"$after")
}

while IFS='|' read -r harness home session caller_home caller_session start_id pane_shape row changed; do
  heal_case "$harness" "$home" "$session" "$SRC_DIR" "$caller_home" "$caller_session" "$start_id" "$pane_shape" "$row"
  assert_eq "$HEAL_CHANGED" "$changed" "heal agrees with recorded identity $harness $home $session" "$TMP_ROOT/heal.err"
  assert_eq "$HEAL_RC" "$([[ "$changed" == yes ]] && echo 0 || echo 1)" "only the matching native session can heal" "$TMP_ROOT/stderr"
  if [[ "$changed" == yes ]]; then
    assert_eq "$HEAL_BINDING" "1790000000,\"claude\",\"${home:-$caller_home}\",\"$caller_session\"" 'the native session fills every missing binding field'
  fi
done <<'ROWS'
|||/claude|s1|s1|shell|yes|yes
claude|/claude|s1|/claude|s1|s1|unread|no|yes
copilot|/claude|s1|/claude|s1|s1|shell|yes|no
claude|/other|s1|/claude|s1|s1|shell|yes|no
claude|/claude|child|/claude|s1|s1|shell|yes|no
||child|/claude|s1|s1|shell|yes|no
claude|/claude|s1||s1|s1|unread|no|yes
|||/claude|||shell|yes|no
|||/claude|child|s1|shell|yes|no
|||/claude|s1||shell|yes|no
|||/claude|s1|s1|direct|yes|no
|||/claude|s1|s1|direct|no|no
|||/claude|s1|s1|shell|no|no
|||/claude|s1|s1|unread|yes|no
ROWS

for rule in harness home session_id missing initial pane; do
  control=$(mutant_scripts "heal-$rule" lib/overseer-launch.sh)
  case "$rule" in
    harness)
      mutate_file "$control/lib/overseer-launch.sh" 'and ((.harness // "") == "" or .harness == $harness)' 'and true'
      heal_case copilot /claude s1 "$control" ;;
    home)
      mutate_file "$control/lib/overseer-launch.sh" 'and ((.home // "") == "" or $home == "" or .home == $home)' 'and true'
      heal_case claude /other s1 "$control" ;;
    session_id)
      mutate_file "$control/lib/overseer-launch.sh" 'and ((.session_id // "") as $bound | if $bound != "" then $bound == $session else $native.harness == $harness and ($native.session_id // "") == $session end)' 'and true'
      heal_case claude /claude child "$control" ;;
    missing)
      mutate_file "$control/lib/overseer-launch.sh" 'def ol_native_match($harness; $home; $session; $native): $session != ""' 'def ol_native_match($harness; $home; $session; $native): true'
      heal_case "" "" "" "$control" /claude "" "" ;;
    initial)
      mutate_file "$control/lib/overseer-launch.sh" '$native.harness == $harness and ($native.session_id // "") == $session' 'true'
      heal_case "" "" "" "$control" /claude child s1 ;;
    pane)
      mutate_file "$control/lib/overseer-launch.sh" 'is_bare_shell "${pane_comm##*/}" || return 1' ': # pane shape unchecked'
      heal_case "" "" "" "$control" /claude s1 s1 direct yes ;;
  esac
  assert_eq "$HEAL_CHANGED" yes "control: dropping $rule fails the unchanged-record assertion"
done
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
