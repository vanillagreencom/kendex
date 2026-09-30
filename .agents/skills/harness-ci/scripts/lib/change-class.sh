#!/usr/bin/env bash
# Shared path rules for change-class and orch's item-tier Location inputs.
# Sourced with extglob enabled. No diff or repository settings are read here.
#
# change_class_path PATH PHASE sets CHANGE_CLASS_PATH and
# CHANGE_CLASS_PATH_CAUSE. PHASE is before-render, registry, pointer, narrow or
# launch (all phases). An unmatched path leaves both empty.
# change_class_path_load CONF reads the narrow-phase lists once. Returns 1
# on a read failure, with CHANGE_CLASS_PATH_CAUSE; callers must refuse a
# narrow class. Call it before the narrow or launch phase.
# change_class_path_match PATH GLOBS sets PATH_MATCH_HIT on the first match.
# GLOBS is newline-separated, with bash patterns matching the whole path.
# change_class_list_globs CONF KEYWORD reads the narrow-change list grammar.

change_class_path_match() { # PATH GLOBS
  local glob
  PATH_MATCH_HIT=""
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    # shellcheck disable=SC2254
    case "$1" in
      $glob) PATH_MATCH_HIT="path=$1 glob=$glob"; return 0 ;;
    esac
  done <<<"$2"
  return 1
}

change_class_list_globs() { # CONF KEYWORD
  awk -v kind="$2" '
    $1 == "superseded" { drop[$2] = 1 }
    $1 == kind { glob[++n] = $2 }
    END { for (i = 1; i <= n; i++) if (!(glob[i] in drop)) print glob[i] }
  ' "$1"
}

change_class_path_load() { # CONF
  CHANGE_CLASS_PATH_CAUSE=narrow-change-list-unreadable
  [ -r "$1" ] || return 1
  CHANGE_CLASS_EXCLUDED="$(change_class_list_globs "$1" path)" &&
    CHANGE_CLASS_INSTRUCTION="$(change_class_list_globs "$1" instruction)" || return 1
  CHANGE_CLASS_PATH_CAUSE=narrow-change-floor-missing
  [ -n "$CHANGE_CLASS_INSTRUCTION" ] || return 1
  CHANGE_CLASS_PATH_CAUSE=""
}

change_class_path() { # PATH PHASE
  local globs
  CHANGE_CLASS_PATH=""
  CHANGE_CLASS_PATH_CAUSE=""
  if [ "$2" = before-render ] || [ "$2" = launch ]; then
    # These files decide the render and classifier inputs. Gemini's shim
    # owns one key only, not the other settings its harness executes.
    globs='kendex.toml
kendex.settings.toml
kendex-local.toml
.kendex/settings.toml
.gemini/settings.json'
    if change_class_path_match "$1" "$globs"; then
      CHANGE_CLASS_PATH=standard
      CHANGE_CLASS_PATH_CAUSE="configuration-source $PATH_MATCH_HIT"
      return 0
    fi
  fi
  if [ "$2" = registry ] || [ "$2" = launch ]; then
    # Registries execute hooks, permissions and MCP servers. A proven render
    # can own their changed keys; a Location alone proves no render.
    globs='.claude/settings.json
.claude/settings.local.json
.mcp.json
.codex/config.toml
.codex/hooks.json
.cursor/hooks.json
.cursor/mcp.json
.agents/hooks.json
.agents/mcp_config.json
.github/copilot/settings.json
.github/copilot/settings.local.json
.github/mcp.json
.github/hooks/*.json
.pi/settings.json
.pi/kendex/hooks.json
opencode.json
opencode.jsonc'
    if change_class_path_match "$1" "$globs"; then
      CHANGE_CLASS_PATH=standard
      CHANGE_CLASS_PATH_CAUSE="configuration-source $PATH_MATCH_HIT"
      return 0
    fi
  fi
  if [ "$2" = pointer ] || [ "$2" = launch ]; then
    if change_class_path_match "$1" $'CLAUDE.md\n*/CLAUDE.md'; then
      CHANGE_CLASS_PATH=standard
      CHANGE_CLASS_PATH_CAUSE="instruction-pointer $PATH_MATCH_HIT"
      return 0
    fi
  fi
  if [ "$2" = narrow ] || [ "$2" = launch ]; then
    if change_class_path_match "$1" "$CHANGE_CLASS_EXCLUDED"; then
      CHANGE_CLASS_PATH=standard
      CHANGE_CLASS_PATH_CAUSE="excluded-path $PATH_MATCH_HIT"
      return 0
    fi
    if change_class_path_match "$1" "$CHANGE_CLASS_INSTRUCTION"; then
      CHANGE_CLASS_PATH=small
      CHANGE_CLASS_PATH_CAUSE="instruction-file $PATH_MATCH_HIT"
    fi
  fi
}
