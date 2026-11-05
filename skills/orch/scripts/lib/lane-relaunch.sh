# shellcheck shell=bash
#
# Owners: open-terminal's wake, which sources this file for the session its
# resume continues; the lane-mail-check hook's model-switch recovery, which
# runs it as `lane-relaunch.sh model-recovery`; and a Jarvis session, which
# reads a recorded session file through it.
#
# The session lookup: which harness transcript a wake resumes, and the id the
# harness resumes it by. It reads the caller's LAUNCH_FLAGS. Exit 1 means no
# session; exit 2 means the lookup failed, never permission to start fresh.

# The replacement is the runtime's: one `launch-lane` request written beside
# the fleet state, its path in LANE_RECOVERY_REQUEST, composed from the lane
# record as the runtime writes it, with the record's harness, tracker,
# repository, host and kind, the checkout the launch ran from as its
# mail_root (`checkout` on a hosted record, whose `mail_root` is its host's;
# else `mail_root`), the account where one is named, the refresh word, the
# model the switch recorded with its effort, the permission words the
# record's `permission` names, which the request carries as its own, and
# the continuation line as its brief. A record an earlier launcher wrote
# keeps its `recovery` object: its `cwd` and `refresh` stand in for the
# fields above where the record lacks them, and its `flags` name the
# selector whose `[1m]` suffix the model keeps, the effort the record lacks
# and, where the record names no `permission`, the permission choice the
# lane ran under. The host and tracker keep their lane-record meanings,
# including null host meaning local.
lane_recovery_request() { # RECORD ACCOUNT STATE_DIR
  local fields item harness flags refresh tracker repo kind model effort launch_model launch_id selector_id brief request permission
  LANE_RECOVERY_CAUSE=checkout-unrecorded
  LANE_RECOVERY_REQUEST="" LANE_RECOVERY_CWD="" LANE_RECOVERY_HOST="" LANE_RECOVERY_SESSION="" LANE_RECOVERY_PERMISSION=""
  fields="$(jq -er '(.checkout // .recovery.cwd // .mail_root) as $cwd
    | select(($cwd | type) == "string" and ($cwd | length) > 0)
    | [.item, .harness, $cwd, (.recovery.flags | strings // ""),
       ((.recovery.refresh // .refresh // false) == true | tostring),
       (.host // "local"), (.recovery.session // ""), (.tracker // ""), (.repo // ""), (.kind // ""),
       (.permission | strings // "")]
    | join("\u001f")' <<<"$1")" || return 1
  IFS=$'\x1f' read -r item harness LANE_RECOVERY_CWD flags refresh LANE_RECOVERY_HOST LANE_RECOVERY_SESSION tracker repo kind permission <<<"$fields"
  # A provider path is recorded as named, and the runtime resolves none.
  case "$LANE_RECOVERY_HOST" in
    local|claude-cloud|/*) ;;
    *) LANE_RECOVERY_CAUSE=provider-relative; return 1 ;;
  esac
  LANE_RECOVERY_CAUSE=model-unrecorded
  model="$(jq -er '.model | strings | select(length > 0)' <<<"$1")" || return 1
  model="$(launch_choice_model_id "$harness" "$model" recorded)" || return 1
  [[ -n "$model" ]] || return 1
  effort="$(jq -r '.effort // ""' <<<"$1")" || return 1
  if [[ -n "$flags" ]]; then
    launch_model="$(launch_choice_launch_model "$harness" "$flags")" || return 1
    launch_id="$(launch_choice_model_id "$harness" "$model" recorded "$launch_model")" || return 1
    selector_id="$(launch_choice_model_id "$harness" "$launch_model" recorded)" || return 1
    # Carry the suffix only from a matching explicit ID or family selector.
    if [[ "$harness" == claude && "$launch_model" == *\[1[mM]\]
        && "$launch_id" == "$selector_id" ]]; then
      model="${model}[1m]"
    fi
    [[ -n "$effort" ]] || effort="$(launch_choice_effort "$harness" "$flags")" || return 1
  fi
  if [[ -n "$permission" ]]; then LANE_RECOVERY_PERMISSION="$permission"
  elif [[ -n "$flags" ]]; then lane_recovery_permission "$harness" "$flags" || return 1; fi
  LANE_RECOVERY_CAUSE=checkout-unavailable
  LANE_RECOVERY_CWD="$(cd -- "$LANE_RECOVERY_CWD" && pwd -P)" || return 1
  LANE_RECOVERY_CAUSE=brief-unwritten
  brief="$3/model-recovery-$item.md"
  lane_recovery_continuation "$item" "$harness" > "$brief" || return 1
  LANE_RECOVERY_CAUSE=request-unwritten
  request="$3/model-recovery-$item.json"
  jq -cn --arg item "$item" --arg harness "$harness" --arg cwd "$LANE_RECOVERY_CWD" --argjson refresh "$refresh" --arg brief "$brief" \
    --arg tracker "$tracker" --arg repo "$repo" --arg model "$model" --arg effort "$effort" --arg account "$2" --arg kind "$kind" \
    --arg host "$LANE_RECOVERY_HOST" --arg permission "$LANE_RECOVERY_PERMISSION" '
    {op: "launch-lane", item: $item, harness: $harness, mail_root: $cwd, refresh: $refresh, brief_file: $brief}
    + ({tracker: $tracker, repo: $repo, model: $model, effort: $effort, account: $account, kind: $kind, permission: $permission} | with_entries(select(.value != "")))
    + (if $host == "local" then {} else {host: $host} end)' > "$request" || return 1
  LANE_RECOVERY_REQUEST="$request"
  LANE_RECOVERY_CAUSE=""
}

# The permission choice a released launch's flags carry, in
# LANE_RECOVERY_PERMISSION as the runtime takes it: the first spelling of the
# harness's permission table in FLAGS, a two-word spelling kept as its two
# words. A permission flag whose value the table lacks is a choice no launch
# line of the runtime carries, so the recovery refuses before stopping
# anything, permission-choice-unrepresentable. Flags with no permission word
# leave the choice to the launch's posture, as the launcher's own line did.
lane_recovery_permission() { # HARNESS FLAGS
  local spellings spec flag i
  LANE_RECOVERY_PERMISSION=""
  spellings="$(launch_choice_permission_spellings "$1")" || return 1
  launch_choice_shell_words "$2" || return 1
  for ((i = 0; i < ${#LAUNCH_CHOICE_ARGV[@]}; i++)); do
    [[ "$1" != claude || "${LAUNCH_CHOICE_ARGV[i]}" != -- ]] || break
    launch_choice_permission_match "$spellings" "${LAUNCH_CHOICE_ARGV[i]}" "${LAUNCH_CHOICE_ARGV[i+1]:-}"
    case "$LAUNCH_CHOICE_PERMISSION_SPAN" in
      1) LANE_RECOVERY_PERMISSION="${LAUNCH_CHOICE_ARGV[i]}"; return 0 ;;
      2) LANE_RECOVERY_PERMISSION="${LAUNCH_CHOICE_ARGV[i]} ${LAUNCH_CHOICE_ARGV[i+1]}"; return 0 ;;
    esac
    for spec in $spellings; do
      [[ "$spec" == *=* ]] || continue
      flag="${spec%%=*}"
      if [[ "${LAUNCH_CHOICE_ARGV[i]}" == "$flag" || "${LAUNCH_CHOICE_ARGV[i]}" == "$flag="* ]]; then
        LANE_RECOVERY_CAUSE=permission-choice-unrepresentable
        return 1
      fi
    done
  done
}

# The line a resumed lane runs first: read its inbox, then continue; a
# Claude or Copilot lane re-arms its mailbox monitor too. The unattended
# words close it, as they close every lane's brief.
lane_recovery_continuation() { # ITEM HARNESS
  local rearm=""
  case "$2" in
    claude) rearm=", then re-arm your mailbox monitor on .agents/skills/mailbox/scripts/lane-mail watch --item $1 through your harness background wake" ;;
    copilot) rearm=", then re-arm your mailbox monitor on .agents/skills/mailbox/scripts/lane-mail watch --once --item $1 as a background command" ;;
  esac
  printf '%s\n' "Resume the orch workflow for $1 from where this session stopped. Run .agents/skills/mailbox/scripts/lane-mail inbox --item $1 first and act on every envelope it prints, answers and directives alike, as its text directs$rearm. $LAUNCH_UNATTENDED_TEXT"
}

lane_recovery_stop_confirmed() { # OUTPUT ITEM
  local out="$1" item="$2"
  [[ "$out" =~ ^stopped\ item=([^\ ]+)\ processes=([0-9]+)$ && "${BASH_REMATCH[1]}" == "$item" ]]
}

lane_model_recovery_result() { # RECORD STATE_DIR SCRIPTS SESSION RESULT
  "$3/workflow-state" --state-dir "$2" update oversee '
    (.fleet_log[]? | select(.kind == "model-switched" and .item == $record.item
      and .session_id == $session
      and .launch_identity == ($record | {launch,launched_at}))).recovery = $result
    ' --argjson record "$1" --arg session "$4" --arg result "$5" >/dev/null
}

# The detached native stop cannot return its failure to the callback. Keep it
# on the same handoff the controller already reads, bound to this launch.
lane_native_model_stop() { # RECORD STATE_DIR SCRIPTS ITEM SESSION
  local record="$1" state_dir="$2" scripts="$3" item="$4" session="$5" pid start detail rc=0
  pid="$(jq -er '.launch.pid' <<<"$record")" || return 1
  start="$(jq -er '.launch.start' <<<"$record")" || return 1
  lane_stop_identity "$pid" "$start" claude || rc=$?
  [[ "$rc" -ne 0 ]] || return 0
  printf 'lane-relaunch: native-stop=failed item=%s cause=%s pid=%s launch_pid=%s exit=%s\n' \
    "$item" "$LANE_STOP_CAUSE" "${LANE_STOP_PID:-none}" "$pid" "$rc" >&2
  detail="$("$scripts/workflow-state" --state-dir "$state_dir" update "$item" '
    if .handoff.session_id == $session
      and .model_checks[$session].launch_identity == ($record | {launch,launched_at})
    then .handoff.stop_failure = {cause:$cause,pid:(if $pid == "" then null else $pid end),
      launch:$record.launch,exit:$exit,at:(now|strftime("%Y-%m-%dT%H:%M:%SZ"))}
    else . end' --arg session "$session" --argjson record "$record" \
      --arg cause "$LANE_STOP_CAUSE" --arg pid "$LANE_STOP_PID" --argjson exit "$rc" 2>&1)" || {
    printf 'lane-relaunch: native-stop=record-failed item=%s\n' "$item" >&2
    printf '%s\n' "$detail" >&2
    return 1
  }
  return "$rc"
}

# The hook acquires one session's recovery under workflow-state's lock before
# starting this outside the predecessor's process group. Compose the recovery
# request before stopping the predecessor; the runtime's launch follows the
# stop. A local predecessor is stopped by the runtime's close on the
# no-landing ground, interrupting its turn: the one reader of the record's
# launch identity, in the form the launch wrote it, and the writer of the
# lane's `stopped`. A hosted predecessor is stopped by its provider's verb.
lane_model_recovery() { # RECORD STATE_DIR SCRIPTS SESSION
  local record="$1" state_dir="$2" SCRIPT_DIR="$3" session="$4" fields item host harness account out claim close limit rc=0 result
  fields="$(jq -er '[.item, (.host // "local"), .harness, (.account // "")] | join("\u001f")' <<<"$record")" || return 1
  IFS=$'\x1f' read -r item host harness account <<<"$fields"
  limit="$("$SCRIPT_DIR/orch-env" ORCH_MODEL_RECOVERY_LIMIT 3)" || return 1
  claim="$("$SCRIPT_DIR/workflow-state" --state-dir "$state_dir" update-report oversee '
    first(.lanes[]? | select(.item == $item)) as $current
    | if $current.launch != $record.launch or $current.launched_at != $record.launched_at
        or $current.session_id != $record.session_id or $current.model_check.session_id != $session
        or $current.model_check.recovery_started == true
      then {state:.,report:false}
      else (.lanes[] | select(.item == $item)).model_check.recovery_started = true
        | (reduce (.fleet_log[]? | select(.item == $item)) as $row (0;
            if $row.kind == "model-recovery-reset" then 0
            elif $row.kind == "model-switched" and ($row.recovery == "replaced"
              or ($row.recovery == "starting" and $row.launch_identity != $current.model_check.launch_identity))
            then . + 1 else . end)) as $recoveries
        | if $recoveries + 1 >= ($limit | tonumber) then
            ("lane-relaunch: model-recovery=limit item=" + $item
              + " recoveries=" + ($recoveries | tostring) + " limit=" + $limit) as $text
            | .fleet_log = ((.fleet_log // []) + [{kind:"model-recovery-limit",item:$item,
                at:(now|strftime("%Y-%m-%dT%H:%M:%SZ")),recoveries:$recoveries,
                limit:($limit|tonumber),text:$text}])
            | {state:.,report:$text}
          else {state:.,report:true} end
      end' --arg item "$item" --arg session "$session" --argjson record "$record" --arg limit "$limit")" || return 1
  if [[ "$claim" != true && "$claim" != false ]]; then
    jq -r . <<<"$claim" >&2 || return 1
    return 1
  fi
  [[ "$claim" == true ]] || return 0
  lane_recovery_request "$record" "$account" "$state_dir" || {
    printf 'lane-relaunch: model-recovery=prepare-failed item=%s cause=%s\n' "$item" "$LANE_RECOVERY_CAUSE" >&2
    return 1
  }
  if [[ "$host" == local ]]; then
    # The close's status is its effect's own (--effect-exit): 0 the harness
    # stopped and the lane marked, 3 the stop failed with the lane standing,
    # 75 the close open with its answer unknown, which the launch below
    # would meet as an open intent; only the first launches.
    close="$state_dir/model-recovery-$item.close.json"
    jq -cn --arg item "$item" '{op: "close-owned-resources", item: $item,
      no_landing: {reason: "model-switch", source: "model-recovery", interrupt: true}}' > "$close" || return 1
    "$SCRIPT_DIR/orch-runtime" --state-dir "$state_dir" op --fleet --effect-exit --request "$close" >/dev/null || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      printf 'lane-relaunch: model-recovery=stop-failed item=%s cause=close exit=%s\n' "$item" "$rc" >&2
      return "$rc"
    fi
  else
    out="$(ORCH_LANE_HOST="$host" "$SCRIPT_DIR/lane-host" stop --item "$item" --harness "$harness")" || return 1
    lane_recovery_stop_confirmed "$out" "$item" || return 1
    "$SCRIPT_DIR/workflow-state" --state-dir "$state_dir" update oversee \
      '(.lanes[] | select(.item == $item and .launched_at == $launch)) |= (.status = "stopped")' \
      --arg item "$item" --arg launch "$(jq -r '.launched_at' <<<"$record")" >/dev/null || return 1
  fi
  [[ -z "$LANE_RECOVERY_SESSION" ]] || export ORCH_TMUX_SESSION="$LANE_RECOVERY_SESSION"
  cd -- "$LANE_RECOVERY_CWD" || return 1
  # A new mismatch can arrive before the runtime returns. Its new launch
  # identity proves that this pending replacement reached a live harness.
  # The launch's status is its effect's own (--effect-exit), never its
  # admission's alone: 0 the replacement confirmed, `replaced`; 75 its
  # intent open with the outcome unknown, left `starting` for the intent's
  # reconcile to settle, and counted as the attempt it is; any other status
  # nothing launched, `failed`.
  lane_model_recovery_result "$record" "$state_dir" "$SCRIPT_DIR" "$session" starting || return 1
  "$SCRIPT_DIR/orch-runtime" --state-dir "$state_dir" op --fleet --effect-exit --request "$LANE_RECOVERY_REQUEST" || rc=$?
  case "$rc" in
    0) result=replaced ;;
    75) return "$rc" ;;
    *) result=failed ;;
  esac
  lane_model_recovery_result "$record" "$state_dir" "$SCRIPT_DIR" "$session" "$result" || return 1
  return "$rc"
}

# Pi resolves a relative session directory from the process working directory,
# which is the item worktree for the command this launcher emits.
pi_relaunch_root() { # WORKTREE HOME
  local cwd="$1" home="$2" agent_dir="${PI_CODING_AGENT_DIR:-$home/.pi/agent}" root="" settings setting="" setting_rc token expect_value=false override_found=false project_trusted=false trust_override=false decision="" trust_rc
  local -a tokens=()
  cwd="$(cd "$cwd" && pwd -P)" || return 2
  case "$agent_dir" in "~") agent_dir="$home" ;; "~/"*) agent_dir="$home/${agent_dir#\~/}" ;; /*) ;; *) agent_dir="$cwd/$agent_dir" ;; esac
  if [[ -n "$LAUNCH_FLAGS" ]]; then
    read -r -a tokens <<<"$LAUNCH_FLAGS"
    for token in ${tokens[@]+"${tokens[@]}"}; do
      if [[ "$expect_value" == true ]]; then root="$token"; expect_value=false; override_found=true; continue; fi
      case "$token" in
        --session-dir) expect_value=true ;;
        --session-dir=*) root="${token#*=}"; [[ -n "$root" ]] || return 2; override_found=true ;;
        -a|--approve) project_trusted=true; trust_override=true ;;
        -na|--no-approve) project_trusted=false; trust_override=true ;;
      esac
    done
    [[ "$expect_value" == false ]] || return 2
  fi
  if [[ "$override_found" == false && -n "${PI_CODING_AGENT_SESSION_DIR:-}" ]]; then root="$PI_CODING_AGENT_SESSION_DIR"; override_found=true; fi
  if [[ "$override_found" == false ]]; then
    root="$agent_dir/sessions"
    settings="$agent_dir/settings.json"
    if [[ -e "$settings" ]]; then
      [[ -f "$settings" && -r "$settings" ]] || return 2
      setting_rc=0
      setting="$(jq -er 'if type!="object" then error("settings") elif has("sessionDir") and (.sessionDir|type)!="string" then error("sessionDir") elif has("sessionDir") then .sessionDir else empty end' "$settings")" || setting_rc=$?
      case "$setting_rc" in 0) if [[ -n "$setting" ]]; then root="$setting"; else root="$agent_dir/sessions"; fi ;; 4) ;; *) return 2 ;; esac
    fi
    settings="$cwd/.pi/settings.json"
    if [[ -e "$settings" ]]; then
      if [[ "$trust_override" == false ]]; then
        [[ ! -r "$agent_dir/settings.json" ]] || project_trusted="$(jq -r 'if .defaultProjectTrust=="always" then "true" else "false" end' "$agent_dir/settings.json")" || return 2
        if [[ -e "$agent_dir/trust.json" ]]; then
          [[ -f "$agent_dir/trust.json" && -r "$agent_dir/trust.json" ]] || return 2
          trust_rc=0
          decision="$(jq -er --arg p "$cwd" 'if type!="object" or any(.[]; .!=true and .!=false and .!=null) then error("trust") else [to_entries[]|select(.value==true or .value==false)|select(.key as $k|$k=="/" or $k==$p or ($p|startswith($k+"/")))]|sort_by(.key|length)|last|if .value==true then "true" elif .value==false then "false" else empty end end' "$agent_dir/trust.json")" || trust_rc=$?
          case "$trust_rc" in 0) project_trusted="$decision" ;; 4) ;; *) return 2 ;; esac
        fi
      fi
      if [[ "$project_trusted" == true ]]; then
        [[ -f "$settings" && -r "$settings" ]] || return 2
        setting_rc=0
        setting="$(jq -er 'if type!="object" then error("settings") elif has("sessionDir") and (.sessionDir|type)!="string" then error("sessionDir") elif has("sessionDir") then .sessionDir else empty end' "$settings")" || setting_rc=$?
        case "$setting_rc" in 0) if [[ -n "$setting" ]]; then root="$setting"; else root="$agent_dir/sessions"; fi ;; 4) ;; *) return 2 ;; esac
      fi
    fi
  fi
  case "$root" in "~") root="$home" ;; "~/"*) root="$home/${root#\~/}" ;; /*) ;; *) root="$cwd/$root" ;; esac
  printf '%s\n' "$root"
}

# Transcript fallback for Claude listSessions and Pi SessionManager.list:
# shell launches lack SDK/app-server connections. Worktree metadata owns
# repository/item, never prompts. Pi workers use kendex/sessions, outside its
# lead store; Pi parents are forks.
find_relaunch_session() { # HARNESS WORKTREE
  local harness="$1" cwd="$2" home="${LANES_HOME:-$HOME}" roots root match_filter="" files file best="" rc
  command -v jq >/dev/null 2>&1 || return 2
  cwd="$(cd -- "$cwd" && pwd -P)" || return 2
  case "$harness" in
    claude) roots="$home/.claude-shared/projects"; match_filter='first(inputs|fromjson?|select(.cwd!=null)) // {} | {cwd, lead:(.isSidechain!=true)}' ;;
    pi) roots="$(pi_relaunch_root "$cwd" "$home")" || return 2; match_filter='first(inputs|fromjson?|select(.type=="session")) // {} | {cwd, lead:true}' ;;
    *) return 1 ;;
  esac

  while IFS= read -r root; do
    [[ -n "$root" && -e "$root" ]] || continue
    [[ -d "$root" && -r "$root" ]] || return 2
    # A Claude child lives below a subagents directory.
    # Only direct project children are lead transcripts; other stores recurse.
    if [[ "$harness" == claude ]]; then
      files="$(find -H "$root" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -print 2>/dev/null)" || return 2
    else
      files="$(find -H "$root" -type f -name '*.jsonl' -print 2>/dev/null)" || return 2
    fi
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      if jq -Rne --arg cwd "$cwd" "$match_filter | .cwd==\$cwd and .lead" "$file" >/dev/null 2>&1; then
        [[ -n "$best" && ! "$file" -nt "$best" ]] || best="$file"
      else rc=$?; [[ "$rc" -eq 1 ]] || return 2; fi
    done <<<"$files"
  done <<<"$roots"
  [[ -n "$best" ]] || return 1
  printf '%s\n' "$best"
}
# The id a harness resumes a transcript by: the file's basename for claude,
# the session_meta id inside a codex transcript, the file itself for pi,
# whose --session takes a path, and a copilot session's own id, read from its
# workspace.yaml by lib/copilot-session.sh; a Jarvis session reads a recorded
# codex or copilot file through recorded_session_file below. Empty is a
# transcript the harness cannot resume, and a failure.
session_id_of() { # HARNESS SESSION_FILE
  local id=""
  case "$1" in
    claude) id="$(basename "$2" .jsonl)" ;;
    codex) id="$(jq -Rrn 'first(inputs|fromjson?|select(.type=="session_meta")|.payload.id)//empty' "$2")" ;;
    pi) id="$2" ;;
    copilot) id="$(copilot_session_id "$2")" || return 1 ;;
  esac
  [[ -n "$id" ]] || return 1
  printf '%s\n' "$id"
}

# A recorded target is exact. Jarvis uses this instead of the newest-session
# search above. A missing target is 1; unreadable or changed identity is 2.
recorded_session_file() { # HARNESS ACCOUNT NATIVE_ID SESSION_FILE
  local harness="$1" account="$2" id="$3" file="$4" actual
  if [[ "$harness" == copilot && -z "$file" ]]; then
    case "$id" in ''|.|..|*[!A-Za-z0-9._-]*) return 2 ;; esac
    file="$account/session-state/$id/workspace.yaml"
  fi
  [[ -n "$file" ]] || return 1
  [[ -e "$file" ]] || { [[ ! -L "$file" ]] || return 2; return 1; }
  [[ -f "$file" && -r "$file" ]] || return 2
  if [[ "$harness" == copilot ]]; then
    [[ -e "${file%/*}/events.jsonl" ]] || return 1
    [[ -f "${file%/*}/events.jsonl" && -r "${file%/*}/events.jsonl" ]] || return 2
    [[ -s "${file%/*}/events.jsonl" ]] || return 1
  else
    jq -Rne '[inputs | fromjson] | length > 0' -- "$file" >/dev/null || return 2
  fi
  actual="$(session_id_of "$harness" "$file")" || return 2
  if [[ "$harness" == pi ]]; then
    actual="$(jq -Rrn 'first(inputs|fromjson|select(.type=="session")|.id)//empty' -- "$file")" || return 2
  fi
  [[ "$actual" == "$id" ]] || return 2
  printf '%s\n' "$file"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  [[ "${1:-}" == model-recovery ]] || { printf 'lane-relaunch: usage=model-recovery RECORD STATE_DIR SESSION\n' >&2; exit 2; }
  scripts="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)" || exit 1
  . "$scripts/lib/lane-state.sh"
  . "$scripts/lib/lane-launch.sh"
  . "$scripts/lib/lane-capabilities.sh"
  lane_model_recovery "$2" "$3" "$scripts" "$4"
fi
