# shellcheck shell=bash
#
# Owner: open-terminal, the one script that sources this file.
#
# The relaunch session lookup: which harness transcript a --relaunch or --wake
# resumes, and the id the harness resumes it by. It reads open-terminal's
# globals (TRACKER, LANE_ENV, LAUNCH_FLAGS, LANES_CLI) and calls its
# launch_ambient_codex_home, so it is loaded by that script alone.
#
# Sourced, never run.

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

# Find the newest transcript whose harness kickoff names the item.
find_relaunch_session() { # HARNESS ITEM WORKTREE
  local harness="$1" item="$2" cwd="$3" home="${LANES_HOME:-$HOME}" config roots root inventory id_match match_filter files file best="" best_root="" rc relative target
  command -v jq >/dev/null 2>&1 || return 2
  # Whether a kickoff record names the item, for every harness: one expression,
  # so the letter-case rule has a single home and one test pins it. The id is
  # matched without regard to case because a transcript holds whatever spelling
  # its own launch rendered, and an earlier launcher rendered the case
  # GH_ISSUE_PATTERN was written in rather than the tracker's canonical one, so
  # a case-sensitive scan would miss a lane's own session and resume nothing.
  id_match='|first|tostring|test("(^|[^A-Za-z0-9])"+$i+"([^A-Za-z0-9]|$)"; "i")'
  # Which record is the kickoff differs per harness. Codex writes injected
  # repository instructions as user response items, so only its user_message
  # event identifies the work item. Claude Code and Pi keep their own
  # first-message formats.
  case "$harness" in
    claude) roots="$home/.claude-shared/projects"; match_filter='[inputs|fromjson?|select(.type=="user")|.message.content]'"$id_match" ;;
    codex)
      config="$(launch_ambient_codex_home)"; [[ "${LANE_ENV%%=*}" != CODEX_HOME ]] || config="${LANE_ENV#*=}"
      [[ -x "$LANES_CLI" ]] || return 2
      inventory="$("$LANES_CLI" list --local --harness codex --json)" || return 2
      roots="$(jq -er --arg d "$config" 'if type=="array" and all(.[]; (.config_dir|type)=="string") then ([.[]|.config_dir]+[$d]|unique[]|.+"/sessions") else error("inventory") end' <<<"$inventory")" || return 2
      match_filter='[inputs|fromjson?|select(.type=="event_msg" and .payload.type=="user_message")|.payload.message]'"$id_match" ;;
    pi) roots="$(pi_relaunch_root "$cwd" "$home")" || return 2; match_filter='[inputs|fromjson?|select(.type=="message" and .message.role=="user")|.message.content]'"$id_match" ;;
  esac
  [[ "$TRACKER" != github ]] || item="#$item"
  while IFS= read -r root; do
    [[ -n "$root" && -e "$root" ]] || continue
    [[ -d "$root" && -r "$root" ]] || return 2
    # A Claude child repeats its lead's kickoff below a subagents directory.
    # Only direct project children are lead transcripts; other stores recurse.
    if [[ "$harness" == claude ]]; then
      files="$(find -H "$root" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -print 2>/dev/null)" || return 2
    else
      files="$(find -H "$root" -type f -name '*.jsonl' -print 2>/dev/null)" || return 2
    fi
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      if jq -Rne --arg i "$item" "$match_filter" "$file" >/dev/null 2>&1; then
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
# the session_meta id inside a codex transcript, and the file itself for pi,
# whose --session takes a path. Empty is a transcript the harness cannot
# resume, and a failure.
session_id_of() { # HARNESS SESSION_FILE
  local id=""
  case "$1" in
    claude) id="$(basename "$2" .jsonl)" ;;
    codex) id="$(jq -Rrn 'first(inputs|fromjson?|select(.type=="session_meta")|.payload.id)//empty' "$2")" ;;
    pi) id="$2" ;;
  esac
  [[ -n "$id" ]] || return 1
  printf '%s\n' "$id"
}
