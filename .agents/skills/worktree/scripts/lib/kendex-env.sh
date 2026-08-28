#!/usr/bin/env bash
# Shared project configuration loader for kendex skill scripts.
#
# Sources, lowest to highest precedence among project files:
#   1. kendex.settings.toml, then .kendex/settings.toml ([env] table only)
#   2. .env.local
# The caller's own environment outranks every project file —
# kendex_load_project_env snapshots and re-asserts it. A `.env` file is
# never read; shared settings belong in kendex.settings.toml, personal and
# secret overrides in .env.local.
#
# The TOML reader accepts the kendex settings contract and nothing else:
#
#   [env]
#   WORKTREE_BASE_DIR = "../trees"
#   ORCH_STATE_DIR = "tmp"
#
# Assignments outside [env] belong to other tools and are ignored. Inside
# [env], a duplicate key or a value in any shape other than a single-line
# double-quoted string with no `"` and no `\` (an optional trailing `#`
# comment allowed) is a configuration error that fails the load — both
# resolver families read exactly this shape, so a value either decodes
# identically everywhere or fails loud here. Headers are held to the same
# standard: a line starting with `[` must be a lone `[name]` header, and
# any other `[`-leading shape fails the load — headers decide which
# assignments load, so one this reader cannot parse must never pass as an
# ignorable line. A file that begins with a UTF-8 byte-order mark is
# refused the same way: the BOM is neither whitespace nor `[` nor a key
# character, so the first header or assignment would silently misclassify.

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

# A UTF-8 byte-order mark is neither whitespace nor `[` nor a key character
# to any reader in either resolver family, so a BOM-prefixed first line
# silently misfiles the header or assignment it hides. Refuse the file
# whole, same discipline as the header rule. Read via stdin so the path is
# never an operand.
kendex_bom_guard() { # FILE — 0 = no leading BOM; 1 + ::error otherwise
  if [[ "$(head -c 3 < "$1" 2>/dev/null)" == $'\xEF\xBB\xBF' ]]; then
    echo "::error::$1: file starts with a UTF-8 byte-order mark; remove it (the first header or assignment would otherwise be misread)" >&2
    return 1
  fi
}

# A source is skipped only when it is ABSENT. A path that exists as
# something else — directory, FIFO, socket, device — fails -f exactly like
# an absent one, and a dangling symlink fails -e as well as -f, so -L is
# what sees it at all: either shape would silently skip a configured
# source and let a lower-precedence value decide. Same rule the
# rg/gg/sr resolver family enforces on its sources.
kendex_source_usable() { # PATH — 0 = readable regular file or absent; 1 + ::error otherwise
  if [[ -f "$1" ]]; then
    [[ -r "$1" ]] && return 0
    echo "::error::$1: source exists but is unreadable (permission denied); a source is skipped only when it is absent" >&2
    return 1
  fi
  { [[ -e "$1" || -L "$1" ]]; } || return 0
  if [[ ! -e "$1" ]]; then
    echo "::error::$1: source is a symlink that does not resolve (dangling target, cycle, or over-long chain); a source is skipped only when it is absent" >&2
  else
    echo "::error::$1: source exists but is not a regular file (directory, FIFO, socket or device); a source is skipped only when it is absent" >&2
  fi
  return 1
}

kendex_source_env_file() {
  local file="$1"
  kendex_source_usable "$file" || return 1
  [[ -f "$file" ]] || return 0
  kendex_bom_guard "$file" || return 1
  # shellcheck source=/dev/null
  source "$file"
}

kendex_trim() {
  local value="$1"
  value="${value#"${value%%[!$' \t\r\n']*}"}"
  value="${value%"${value##*[!$' \t\r\n']}"}"
  printf '%s' "$value"
}

# Decode one [env] value per the settings contract: a single-line basic
# string containing no `"` and no `\`, optionally followed by a `#`
# comment. Anything else is a shape the contract does not carry.
kendex_decode_value() { # RAW — decoded value on stdout; 1 = not contract shape
  local value regex='^"([^"\]*)"[[:space:]]*(#.*)?$'
  value="$(kendex_trim "$1")"
  [[ "$value" =~ $regex ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}

kendex_load_settings_file() {
  local file="$1"
  kendex_source_usable "$file" || return 1
  [[ -f "$file" ]] || return 0
  kendex_bom_guard "$file" || return 1

  local section="" line key value seen=" " lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    line="$(kendex_trim "$line")"
    [[ -z "$line" || "$line" == \#* ]] && continue

    # A `[`-leading line is a header or an error, never content: `[env] # c`
    # would hide the whole table behind silent defaults, and a quoted or
    # doubled header after [env] would leave foreign keys loading as [env]
    # keys.
    if [[ "$line" == \[* ]]; then
      if [[ "$line" =~ ^\[([A-Za-z0-9_.-]+)\]$ ]]; then
        section="${BASH_REMATCH[1]}"
        continue
      fi
      echo "::error::$file:$lineno: unsupported table header shape (a header is a lone [name] on its own line, with no comment and no second bracket)" >&2
      return 1
    fi

    [[ "$section" == "env" && "$line" == *=* ]] || continue
    key="$(kendex_trim "${line%%=*}")"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    # Which duplicate wins would be an accident of read order, so a re-assigned
    # key is a configuration error — the same ambiguity guard the settings.sh
    # resolver family applies. Checked before the parent-env skip: a malformed
    # file must fail identically whatever this session exports.
    if [[ "$seen" == *" $key "* ]]; then
      echo "::error::$file: $key is assigned more than once in [env] (each key must be unique in the table)" >&2
      return 1
    fi
    seen="$seen$key "
    if ! value="$(kendex_decode_value "${line#*=}")"; then
      echo "::error::$file: unsupported syntax for $key (expected a single-line basic string with no '\"' and no '\\': $key = \"value\")" >&2
      return 1
    fi

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
  # it holds parent env only — not values set by the project files below. The
  # stored value is used to re-assert parent precedence after loading. Assigning
  # without `local` makes the snapshot arrays global from inside this function.
  _KENDEX_PARENT_ENV_NAMES=()
  _KENDEX_PARENT_ENV_VALUES=()
  local _kendex_name
  while IFS= read -r _kendex_name; do
    _KENDEX_PARENT_ENV_NAMES+=("$_kendex_name")
    _KENDEX_PARENT_ENV_VALUES+=("${!_kendex_name-}")
  done < <(compgen -e)

  # Load order (lowest to highest among project files): settings, then
  # .env.local. kendex_load_settings_file skips parent keys directly; the
  # env file is sourced wholesale, so its clobbers are undone below. A
  # refused load — settings or a BOM-prefixed .env.local — fails the whole
  # call: resolving on a partial or silently reinterpreted file would be
  # worse than stopping.
  kendex_load_settings_file "$project_root/kendex.settings.toml" || return 1
  kendex_load_settings_file "$project_root/.kendex/settings.toml" || return 1
  kendex_source_env_file "$project_root/.env.local" || return 1

  # Re-assert parent values so parent env wins over every project file, while
  # the settings < .env.local order is preserved for non-parent keys.
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
