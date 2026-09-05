# shellcheck shell=bash
# Staged runs read tracked project settings from the index. Other runs read
# the working tree. The shared kendex loader remains the only parser.

pf_stage_settings_file() { # SOURCE SNAPSHOT-ROOT
  local path="$1" snapshot="$2" entry="" status=0 head_entry="" mode=""
  entry="$(git ls-files -s -- ":(literal)$path" 2>/dev/null)" || status=$?
  if [ "$status" -ne 0 ]; then
    echo "::error::$path: could not query the index while loading preflight settings" >&2
    return 1
  fi
  if [ -n "$entry" ]; then
    mode="${entry%% *}"
    case "$mode" in
      100*) ;;
      *)
        echo "::error::$path: staged settings source is not a regular file" >&2
        return 1
        ;;
    esac
    case "$path" in
      */*) mkdir -p -- "$snapshot/${path%/*}" 2>/dev/null || {
        echo "::error::$path: could not prepare the staged settings snapshot" >&2
        return 1
      } ;;
    esac
    git show ":0:$path" >"$snapshot/$path" 2>/dev/null || {
      echo "::error::$path: could not read the staged settings source" >&2
      return 1
    }
    return 0
  fi

  status=0
  head_entry="$(git ls-tree HEAD -- ":(literal)$path" 2>/dev/null)" || status=$?
  if [ "$status" -ne 0 ]; then
    echo "::error::$path: could not query HEAD while loading preflight settings" >&2
    return 1
  fi
  # A path HEAD carries but the index does not is staged for deletion.
  [ -z "$head_entry" ] || return 0
  kendex_source_usable "$path" || return 1
  [ -f "$path" ] || return 0
  case "$path" in
    */*) mkdir -p -- "$snapshot/${path%/*}" 2>/dev/null || {
      echo "::error::$path: could not prepare the settings snapshot" >&2
      return 1
    } ;;
  esac
  cp -- "$path" "$snapshot/$path" 2>/dev/null || {
    echo "::error::$path: could not read the settings source" >&2
    return 1
  }
}

pf_load_project_env() { # MODE ROOT SCRATCH
  local mode="$1" root="$2" scratch="$3" snapshot="$3/settings"
  if [ "$mode" != staged ]; then
    kendex_load_project_env "$root"
    return
  fi
  mkdir -p -- "$snapshot/.kendex" || return 1
  pf_stage_settings_file kendex.settings.toml "$snapshot" || return 1
  pf_stage_settings_file .kendex/settings.toml "$snapshot" || return 1
  pf_stage_settings_file .env.local "$snapshot" || return 1
  kendex_load_project_env "$snapshot"
}
