#!/usr/bin/env bash
# Shared project configuration loader for vstack skill scripts.
#
# Load order is intentionally compatible with the historical env-file flow:
#   1. .env
#   2. vstack.settings.toml or .vstack/settings.toml ([env] table only)
#   3. .env.local
#
# The TOML reader is deliberately small and only accepts a public [env] table
# with shell-style variable names:
#
#   [env]
#   WORKTREE_BASE_DIR = "../trees"
#   ORCH_STATE_DIR = "tmp"

vstack_source_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  # shellcheck source=/dev/null
  source "$file"
}

vstack_trim() {
  local value="$1"
  value="${value#"${value%%[!$' \t\r\n']*}"}"
  value="${value%"${value##*[!$' \t\r\n']}"}"
  printf '%s' "$value"
}

vstack_unquote_value() {
  local value
  value="$(vstack_trim "$1")"

  if [[ "$value" == \[*\] ]]; then
    value="${value:1:${#value}-2}"
    value="${value//,/ }"
    value="${value//\"/}"
    value="${value//\'/}"
    value="$(vstack_trim "$value")"
  elif [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value:1:${#value}-2}"
    value="${value//\\\"/\"}"
    value="${value//\\\\/\\}"
  elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value="${value:1:${#value}-2}"
  else
    value="${value%%#*}"
    value="$(vstack_trim "$value")"
  fi

  printf '%s' "$value"
}

vstack_load_settings_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  local section="" line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="$(vstack_trim "$line")"
    [[ -z "$line" || "$line" == \#* ]] && continue

    if [[ "$line" =~ ^\[([A-Za-z0-9_.-]+)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi

    [[ "$section" == "env" && "$line" == *=* ]] || continue
    key="$(vstack_trim "${line%%=*}")"
    value="${line#*=}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    value="$(vstack_unquote_value "$value")"

    # Parent-process values win over project [env] tables. The snapshot array is
    # only present when called via vstack_load_project_env; `declare -p`
    # short-circuits (without erroring under set -u) when it is undeclared, e.g.
    # a standalone call, so the assoc-array key subscript is only evaluated once
    # the array is known to exist.
    if declare -p _VSTACK_PARENT_ENV >/dev/null 2>&1 && [[ -v "_VSTACK_PARENT_ENV[$key]" ]]; then
      continue
    fi

    printf -v "$key" '%s' "$value"
    export "$key"
  done < "$file"
}

vstack_load_project_env() {
  local project_root="$1"
  [[ -n "$project_root" ]] || return 0

  # Snapshot parent-process variables (name -> value) so project files cannot
  # clobber caller-provided values (documented precedence: parent process wins
  # over project files). compgen -e lists only exported names (the environment),
  # excluding this function's locals, and is captured before any file loads so
  # it holds parent env only — not values set by .env below. The stored value is
  # used to re-assert parent precedence after loading.
  declare -gA _VSTACK_PARENT_ENV=()
  local _vstack_name
  while IFS= read -r _vstack_name; do
    _VSTACK_PARENT_ENV["$_vstack_name"]="${!_vstack_name-}"
  done < <(compgen -e)

  # Load order (lowest to highest among project files): .env, then settings,
  # then .env.local. vstack_load_settings_file skips parent keys directly; the
  # env files are sourced wholesale, so their clobbers are undone below.
  vstack_source_env_file "$project_root/.env"
  vstack_load_settings_file "$project_root/vstack.settings.toml"
  vstack_load_settings_file "$project_root/.vstack/settings.toml"
  vstack_source_env_file "$project_root/.env.local"

  # Re-assert parent values so parent env wins over every project file, while
  # the .env < settings < .env.local order is preserved for non-parent keys.
  # Only changed keys are rewritten; a readonly var can never differ from its
  # snapshot, so this never attempts to assign one.
  for _vstack_name in "${!_VSTACK_PARENT_ENV[@]}"; do
    if [[ "${!_vstack_name-}" != "${_VSTACK_PARENT_ENV[$_vstack_name]}" ]]; then
      export "$_vstack_name=${_VSTACK_PARENT_ENV[$_vstack_name]}"
    fi
  done

  unset _VSTACK_PARENT_ENV
}
