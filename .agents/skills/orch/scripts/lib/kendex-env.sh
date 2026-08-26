#!/usr/bin/env bash
# Shared project configuration loader for kendex skill scripts.
#
# Load order is intentionally compatible with the historical env-file flow:
#   1. .env
#   2. kendex.settings.toml or .kendex/settings.toml ([env] table only)
#   3. .env.local
#
# The TOML reader is deliberately small and only accepts a public [env] table
# with shell-style variable names:
#
#   [env]
#   WORKTREE_BASE_DIR = "../trees"
#   ORCH_STATE_DIR = "tmp"

# Parent-process env snapshot (name/value pairs). Bash 3.2 (macOS system
# bash) has no associative arrays, so the snapshot is a pair of parallel
# indexed arrays scanned linearly. Populated only by kendex_load_project_env;
# the guarded expansion below keeps standalone kendex_load_settings_file calls
# working when the snapshot was never taken (empty-array expansion is an
# unbound variable under Bash 3.2 with set -u).
kendex_parent_env_has() {
  local name="$1" snapshot_name
  for snapshot_name in ${_KENDEX_PARENT_ENV_NAMES[@]+"${_KENDEX_PARENT_ENV_NAMES[@]}"}; do
    [[ "$snapshot_name" == "$name" ]] && return 0
  done
  return 1
}

kendex_source_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  # shellcheck source=/dev/null
  source "$file"
}

kendex_trim() {
  local value="$1"
  value="${value#"${value%%[!$' \t\r\n']*}"}"
  value="${value%"${value##*[!$' \t\r\n']}"}"
  printf '%s' "$value"
}

kendex_unquote_value() {
  local value
  value="$(kendex_trim "$1")"

  if [[ "$value" == \[*\] ]]; then
    value="${value:1:${#value}-2}"
    value="${value//,/ }"
    value="${value//\"/}"
    value="${value//\'/}"
    value="$(kendex_trim "$value")"
  elif [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value:1:${#value}-2}"
    value="${value//\\\"/\"}"
    value="${value//\\\\/\\}"
  elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value="${value:1:${#value}-2}"
  else
    value="${value%%#*}"
    value="$(kendex_trim "$value")"
  fi

  printf '%s' "$value"
}

kendex_load_settings_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  local section="" line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="$(kendex_trim "$line")"
    [[ -z "$line" || "$line" == \#* ]] && continue

    if [[ "$line" =~ ^\[([A-Za-z0-9_.-]+)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi

    [[ "$section" == "env" && "$line" == *=* ]] || continue
    key="$(kendex_trim "${line%%=*}")"
    value="${line#*=}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    value="$(kendex_unquote_value "$value")"

    # Parent-process values win over project [env] tables. The snapshot is
    # only populated when called via kendex_load_project_env; standalone calls
    # see an empty snapshot and load every key.
    if kendex_parent_env_has "$key"; then
      continue
    fi

    printf -v "$key" '%s' "$value"
    export "$key"
  done < "$file"
}

kendex_load_project_env() {
  local project_root="$1"
  [[ -n "$project_root" ]] || return 0

  # Snapshot parent-process variables (name -> value) so project files cannot
  # clobber caller-provided values (documented precedence: parent process wins
  # over project files). compgen -e lists only exported names (the environment),
  # excluding this function's locals, and is captured before any file loads so
  # it holds parent env only — not values set by .env below. The stored value is
  # used to re-assert parent precedence after loading. Assigning without
  # `local` makes the snapshot arrays global from inside this function.
  _KENDEX_PARENT_ENV_NAMES=()
  _KENDEX_PARENT_ENV_VALUES=()
  local _kendex_name
  while IFS= read -r _kendex_name; do
    _KENDEX_PARENT_ENV_NAMES+=("$_kendex_name")
    _KENDEX_PARENT_ENV_VALUES+=("${!_kendex_name-}")
  done < <(compgen -e)

  # Load order (lowest to highest among project files): .env, then settings,
  # then .env.local. kendex_load_settings_file skips parent keys directly; the
  # env files are sourced wholesale, so their clobbers are undone below.
  kendex_source_env_file "$project_root/.env"
  kendex_load_settings_file "$project_root/kendex.settings.toml"
  kendex_load_settings_file "$project_root/.kendex/settings.toml"
  kendex_source_env_file "$project_root/.env.local"

  # Re-assert parent values so parent env wins over every project file, while
  # the .env < settings < .env.local order is preserved for non-parent keys.
  # Only changed keys are rewritten; a readonly var can never differ from its
  # snapshot, so this never attempts to assign one.
  local _kendex_i
  for ((_kendex_i = 0; _kendex_i < ${#_KENDEX_PARENT_ENV_NAMES[@]}; _kendex_i++)); do
    _kendex_name="${_KENDEX_PARENT_ENV_NAMES[$_kendex_i]}"
    if [[ "${!_kendex_name-}" != "${_KENDEX_PARENT_ENV_VALUES[$_kendex_i]}" ]]; then
      export "$_kendex_name=${_KENDEX_PARENT_ENV_VALUES[$_kendex_i]}"
    fi
  done

  unset _KENDEX_PARENT_ENV_NAMES _KENDEX_PARENT_ENV_VALUES
}
