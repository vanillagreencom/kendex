# shellcheck shell=bash
#
# Owner: open-terminal, which sources this file locally and runs it on a host.
#
# The relaunch session lookup: which harness transcript a --relaunch or --wake
# resumes, and the id the harness resumes it by. It reads open-terminal's
# globals (LANE_ENV, LAUNCH_FLAGS, LANES_CLI) and calls its
# launch_ambient_codex_home and copilot_launch_home on the local path.
#
# Hosted entry point: bash lane-relaunch.sh HARNESS ITEM LAUNCH_FLAGS.
# open-terminal's rendered command consumes stdout as the resume id. Exit 1
# means no session; exit 2 means lookup failed, never permission to start fresh.

# open-terminal records the choices it can repeat in `recovery`. Older records
# and custom commands cannot recover their original permissions, so the watch
# must refuse before stopping a lane. The host and tracker retain their existing
# lane-record meanings, including null host meaning local.
lane_recovery_args() { # RECORD ACCOUNT STATE_DIR LAUNCHER
  local fields item harness flags refresh tracker repo
  LANE_RECOVERY_CAUSE=permission-choice-unrecorded
  LANE_RECOVERY_ARGS=() LANE_RECOVERY_CWD="" LANE_RECOVERY_HOST="" LANE_RECOVERY_SESSION=""
  fields="$(jq -er 'select((.recovery | type) == "object"
      and (.recovery.cwd | type) == "string" and (.recovery.cwd | length) > 0
      and (.recovery.flags | type) == "string" and (.recovery.refresh | type) == "boolean")
    | [.item, .harness, .recovery.cwd, .recovery.flags, (.recovery.refresh | tostring),
       (.host // "local"), (.recovery.session // ""), .tracker, (.repo // "")]
    | join("\u001f")' <<<"$1")" || return 1
  IFS=$'\x1f' read -r item harness LANE_RECOVERY_CWD flags refresh LANE_RECOVERY_HOST LANE_RECOVERY_SESSION tracker repo <<<"$fields"
  LANE_RECOVERY_CAUSE=checkout-unavailable
  LANE_RECOVERY_CWD="$(cd -- "$LANE_RECOVERY_CWD" && pwd -P)" || return 1
  LANE_RECOVERY_ARGS=("$4" --tmux --relaunch --continue-resume --harness "$harness" --lane "$2"
    --launch-flags "$flags" --state-dir "$3" --host "$LANE_RECOVERY_HOST" --tracker "$tracker")
  [[ -z "$repo" ]] || LANE_RECOVERY_ARGS+=(--repo "$repo")
  [[ "$refresh" != true ]] || LANE_RECOVERY_ARGS+=(--lane-refresh)
  if [[ "$tracker" == github ]]; then LANE_RECOVERY_ARGS+=("${item#issue-}")
  else LANE_RECOVERY_ARGS+=("$item"); fi
  LANE_RECOVERY_CAUSE=""
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

# Transcript fallback for Claude listSessions, Codex thread/list and Pi
# SessionManager.list: shell launches lack SDK/app-server connections; Codex
# copies across accounts. Worktree metadata owns repository/item, never prompts.
# Pi workers use kendex/sessions, outside its lead store; Pi parents are forks.
#
# Copilot is the exception: how its events.jsonl records a kickoff is not
# measured, so a copilot session is the one lib/copilot-session.sh's
# copilot_session_in_worktree names for the lane's worktree, one item's alone.
# A record quoting its path names no directory there and matches nothing, which
# renders the fresh brief. So does a record with no events beside it, which
# `copilot --resume=<id>` exits 1 on with "No session, task, or name matched",
# in `-p` and at a pane alike (1.0.88, the log naming "Cannot create session
# from empty events array"). An older resumable record in the same worktree is
# resumed in its place.
find_relaunch_session() { # HARNESS WORKTREE [HOST_CODEX_HOME]
  local harness="$1" cwd="$2" home="${LANES_HOME:-$HOME}" config roots root inventory match_filter="" files file best="" best_root="" rc relative target
  command -v jq >/dev/null 2>&1 || return 2
  cwd="$(cd -- "$cwd" && pwd -P)" || return 2
  case "$harness" in
    claude) roots="$home/.claude-shared/projects"; match_filter='first(inputs|fromjson?|select(.cwd!=null)) // {} | {cwd, lead:(.isSidechain!=true)}' ;;
    codex)
      if [[ -n "${3:-}" ]]; then config="$3"
      else
        config="$(launch_ambient_codex_home)" || return 2
        [[ "${LANE_ENV%%=*}" != CODEX_HOME ]] || config="${LANE_ENV#*=}"
      fi
      [[ -x "$LANES_CLI" ]] || return 2
      inventory="$("$LANES_CLI" list --local --harness codex --json)" || return 2
      roots="$(jq -er --arg d "$config" 'if type=="array" and all(.[]; (.config_dir|type)=="string") then ([.[]|.config_dir]+[$d]|unique[]|.+"/sessions") else error("inventory") end' <<<"$inventory")" || return 2
      # SessionMeta defaults an omitted source to vscode in Codex's protocol.
      match_filter='first(inputs|fromjson?|select(.type=="session_meta")|.payload) // {} |
        {cwd, lead:((.source=="cli" or .source=="vscode" or (has("source")|not)) and .parent_thread_id==null)}' ;;
    pi) roots="$(pi_relaunch_root "$cwd" "$home")" || return 2; match_filter='first(inputs|fromjson?|select(.type=="session")) // {} | {cwd, lead:true}' ;;
    copilot)
      config="$(copilot_launch_home)"
      copilot_session_in_worktree "$config" "$cwd"
      return ;;
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
        [[ -n "$best" && ! "$file" -nt "$best" ]] || { best="$file"; best_root="$root"; }
      else rc=$?; [[ "$rc" -eq 1 ]] || return 2; fi
    done <<<"$files"
  done <<<"$roots"
  [[ -n "$best" ]] || return 1
  if [[ "$harness" == codex && "$best_root" != "$config/sessions" ]]; then
    relative="${best#"$best_root"/}"; target="$config/sessions/$relative"
    if [[ -e "$target" ]]; then cmp -s -- "$best" "$target" || return 2
    else mkdir -p -- "${target%/*}" || return 2; cp -p -- "$best" "$target" || return 2; fi
    best="$target"
  fi
  printf '%s\n' "$best"
}
# The id a harness resumes a transcript by: the file's basename for claude,
# the session_meta id inside a codex transcript, the file itself for pi,
# whose --session takes a path, and a copilot session's own id, read from its
# workspace.yaml by lib/copilot-session.sh. Empty is a transcript the harness cannot resume, and a
# failure.
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  LAUNCH_FLAGS="$3" LANE_ENV=""
  LANES_CLI="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)/lanes" || exit 2
  session_file="" lookup_rc=0
  session_file="$(find_relaunch_session "$1" "$PWD" "${CODEX_HOME:-$HOME/.codex}")" || lookup_rc=$?
  case "$lookup_rc" in
    0) session_id_of "$1" "$session_file" && exit 0 ;;
    1) exit 1 ;;
  esac
  printf 'lane-relaunch: session-scan-failed item=%s harness=%s\n' "$2" "$1" >&2
  exit 2
fi
