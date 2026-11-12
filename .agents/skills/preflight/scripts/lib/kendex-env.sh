#!/usr/bin/env bash
# Shared project configuration loader for kendex skill scripts.
#
# Sources, lowest to highest precedence among project files:
#   1. kendex.settings.toml, then .kendex/settings.toml ([env] table only)
#   2. the project's private env file, .env.local unless KENDEX_ENV_FILE
#      names another, read as data and never run (kendex_read_env_file)
# The caller's own environment outranks every project file —
# kendex_load_project_env snapshots and re-asserts it. A `.env` file is
# never read; shared settings belong in kendex.settings.toml, personal and
# secret overrides in the private env file.
#
# KENDEX_ENV_FILE is the one setting that decides which file is read
# rather than what a value is, so it is resolved after the settings load
# and before the private file. It is a path relative to the project root:
# an absolute path, a `..` segment, a backslash or a colon fails the load
# rather than reading a file outside the project. It is the same key the
# app writes when a person names a private file, so one project names one
# file once, and the app's own checks — that git does not track or carry
# the file — are what make writing a credential there safe.
#
# The TOML reader accepts the kendex settings contract and nothing else:
#
#   [env]
#   WORKTREE_BASE_DIR = "../trees"
#   ORCH_STATE_DIR = "tmp"
#
# Assignments outside [env] belong to other tools and are ignored. Inside
# [env], a duplicate key fails the load. Values are single-line basic
# strings with no `"` or `\`, or literal strings with no apostrophe inside. An optional trailing `#`
# comment is allowed. Other shapes fail the load — both
# resolver families read exactly this shape, so a value either decodes
# identically everywhere or fails loud here. Headers are held to the same
# standard: a line starting with `[` must be a lone `[name]` header, and
# any other `[`-leading shape fails the load — headers decide which
# assignments load, so one this reader cannot parse must never pass as an
# ignorable line. A file that begins with a UTF-8 byte-order mark is
# refused the same way: the BOM is neither whitespace nor `[` nor a key
# character, so the first header or assignment would silently misclassify.
#
# Every variable the loader keeps its state in, its locals and the parent
# snapshot alike, starts with `_kendex_`, and a key in either file that
# starts with it fails the load. A key is assigned with `printf -v` while
# the loader is still running, so a key naming one of its variables would
# overwrite the loader's own state: `lineno = 'a[$(cmd)]'` runs cmd at the
# next `$((lineno + 1))`. One prefix keeps that true for a variable added
# later.

# Parent-process env snapshot (name/value pairs). Bash 3.2 (macOS system
# bash) has no associative arrays, so the snapshot is a pair of parallel
# indexed arrays for the value restore. A space-delimited name string avoids
# scanning the arrays for each settings key; exported names contain no spaces.
# Populated only by kendex_load_project_env; an absent name string keeps
# standalone kendex_load_settings_file calls working under set -u.

kendex_env_message() { # KEY ARG...
  local _kendex_message_key="$1"
  shift
  case "$_kendex_message_key" in
    byte-order-mark)
      printf 'kendex-env: byte-order-mark arg1=%s\n' "$1"
      printf '%s\n' "::error::$1: file starts with a UTF-8 byte-order mark; remove it (the first header or assignment would otherwise be misread)"
      ;;
    unreadable)
      printf 'kendex-env: unreadable arg1=%s\n' "$1"
      printf '%s\n' "::error::$1: source exists but is unreadable (permission denied); a source is skipped only when it is absent"
      ;;
    unresolved-link)
      printf 'kendex-env: unresolved-link arg1=%s\n' "$1"
      printf '%s\n' "::error::$1: source is a symlink that does not resolve (dangling target, cycle, or over-long chain); a source is skipped only when it is absent"
      ;;
    not-file)
      printf 'kendex-env: not-file arg1=%s\n' "$1"
      printf '%s\n' "::error::$1: source exists but is not a regular file (directory, FIFO, socket or device); a source is skipped only when it is absent"
      ;;
    table-header)
      printf 'kendex-env: table-header file=%s lineno=%s\n' "$1" "$2"
      printf '%s\n' "::error::$1:$2: unsupported table header shape (a header is a lone [name] on its own line, with no comment and no second bracket)"
      ;;
    duplicate-key)
      printf 'kendex-env: duplicate-key file=%s key=%s\n' "$1" "$2"
      printf '%s\n' "::error::$1: $2 is assigned more than once in [env] (each key must be unique in the table)"
      ;;
    private-env-path)
      printf 'kendex-env: private-env-path arg1=%s\n' "$1"
      printf '%s\n' "::error::KENDEX_ENV_FILE is $1: it must name a file inside the project, written as a relative path with no '..' segment, no backslash and no colon"
      ;;
    private-env-blocked)
      printf 'kendex-env: private-env-blocked arg1=%s\n' "$1"
      printf '%s\n' "::error::the private env file $1 cannot exist: a component of its path is a file, not a directory; name a path whose parents are directories"
      ;;
    private-env-outside)
      printf 'kendex-env: private-env-outside arg1=%s\n' "$1"
      printf '%s\n' "::error::the private env file $1 resolves outside the project through a link on the way to it; a private env file supplies this project's values, so it must stay inside the project it belongs to"
      ;;
    private-env-unresolved)
      printf 'kendex-env: private-env-unresolved arg1=%s\n' "$1"
      printf '%s\n' "::error::$1 could not be resolved, so nothing can say whether the private env file is inside the project; a source that cannot be placed is not read"
      ;;
    private-env-line)
      printf 'kendex-env: private-env-line file=%s lineno=%s\n' "$1" "$2"
      printf '%s\n' "::error::$1:$2: the private env file is read as data and never run, so each line is blank, a # comment, or [export ]KEY=VALUE, where VALUE is a single-quoted string with no apostrophe inside, a double-quoted string with no '\"', '\\', '\$' or backtick inside, or a bare word of letters, digits and _ . / : @ % + , = -, optionally followed by a space and a # comment"
      ;;
    reserved-key)
      printf 'kendex-env: reserved-key file=%s key=%s\n' "$1" "$2"
      printf '%s\n' "::error::$1: $2 starts with _kendex_, the prefix this loader keeps for its own variables; rename the key"
      ;;
    destination-attributes)
      printf 'kendex-env: destination-attributes file=%s lineno=%s key=%s\n' "$1" "$2" "$3"
      printf '%s\n' "::error::$1:$2: $3 has integer, array or name-reference attributes that can evaluate or redirect a settings assignment; use an ordinary scalar variable"
      ;;
    value-syntax)
      printf 'kendex-env: value-syntax file=%s key=%s\n' "$1" "$2"
      printf '%s\n' "::error::$1: unsupported syntax for $2 (expected a single-line basic string with no '\"' or '\\', or a literal string with no apostrophe inside)"
      ;;
  esac
}

kendex_parent_env_has() {
  [[ "${_kendex_parent_env_name_set-}" == *" $1 "* ]]
}

kendex_key_usable() { # FILE KEY LINE — 0 = safe assignment destination; 1 + ::error otherwise
  if [[ "$2" == _kendex_* ]]; then
    kendex_env_message reserved-key "$1" "$2" >&2
    return 1
  fi
  kendex_parent_env_has "$2" && return 0
  # printf -v retains destination attributes. Integers and array subscripts
  # evaluate text, and references redirect it, even after literal decoding.
  local _kendex_attributes
  if _kendex_attributes=$(declare -p "$2" 2>/dev/null); then
    _kendex_attributes="${_kendex_attributes#declare -}"
    _kendex_attributes="${_kendex_attributes%% *}"
    if [[ "$_kendex_attributes" == *[iaAn]* ]]; then
      kendex_env_message destination-attributes "$1" "$3" "$2" >&2
      return 1
    fi
  fi
  return 0
}

# A UTF-8 byte-order mark is neither whitespace nor `[` nor a key character
# to any reader in either resolver family, so a BOM-prefixed first line
# silently misfiles the header or assignment it hides. Refuse the file
# whole, same discipline as the header rule. Read via stdin so the path is
# never an operand.
kendex_bom_guard() { # FILE — 0 = no leading BOM; 1 + ::error otherwise
  local _kendex_prefix="" LC_ALL=C
  if IFS= read -r -n 3 -d '' _kendex_prefix < "$1" 2>/dev/null &&
     [[ "$_kendex_prefix" == $'\xEF\xBB\xBF' ]]; then
    kendex_env_message byte-order-mark "$@" >&2
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
    kendex_env_message unreadable "$@" >&2
    return 1
  fi
  { [[ -e "$1" || -L "$1" ]]; } || return 0
  if [[ ! -e "$1" ]]; then
    kendex_env_message unresolved-link "$@" >&2
  else
    kendex_env_message not-file "$@" >&2
  fi
  return 1
}

# Both helpers assign into a caller-named variable instead of printing.
# kendex_load_settings_file reaches kendex_trim once for every line, and
# three times on an assignment line — twice directly, for the line and for
# the key, and once more inside kendex_decode_value. A helper that printed
# could only be read back through a command substitution, so every one of
# those was a fork, on every settings file every skill script loads.
#
# The assignment is a `printf -v` into a name the CALLER chose, so it is
# lost to the helper's own local whenever the two spellings meet: never
# pass a helper its own scratch name — `_kendex_trimmed` to kendex_trim,
# `_kendex_decode_raw` or `_kendex_decode_regex` to kendex_decode_value.
# Nothing enforces that; the two sets are spelled apart precisely so
# kendex_decode_value can hand its own scratch to kendex_trim.
kendex_trim() { # OUT_VAR RAW — RAW without leading or trailing whitespace, assigned to OUT_VAR
  local _kendex_trimmed="$2"
  _kendex_trimmed="${_kendex_trimmed#"${_kendex_trimmed%%[!$' \t\r\n']*}"}"
  _kendex_trimmed="${_kendex_trimmed%"${_kendex_trimmed##*[!$' \t\r\n']}"}"
  printf -v "$1" '%s' "$_kendex_trimmed"
}

# Basic strings need no decoding under this contract. Literal strings
# preserve backslashes and double quotes as text. Both end at the first
# closing delimiter, so a quote in a trailing comment stays outside.
kendex_decode_value() { # OUT_VAR RAW — decoded value assigned to OUT_VAR; 1 = not contract shape, OUT_VAR untouched; overwrites the caller's BASH_REMATCH, since the match runs in the caller's shell rather than a subshell
  local _kendex_decode_raw _kendex_decode_regex='^"([^"\]*)"[[:space:]]*(#.*)?$'
  kendex_trim _kendex_decode_raw "$2"
  if [[ "$_kendex_decode_raw" == \'* ]]; then
    _kendex_decode_regex="^'([^']*)'[[:space:]]*(#.*)?$"
  fi
  [[ "$_kendex_decode_raw" =~ $_kendex_decode_regex ]] || return 1
  printf -v "$1" '%s' "${BASH_REMATCH[1]}"
}

kendex_load_settings_file() {
  local _kendex_file="$1"
  kendex_source_usable "$_kendex_file" || return 1
  [[ -f "$_kendex_file" ]] || return 0
  kendex_bom_guard "$_kendex_file" || return 1

  local _kendex_section="" _kendex_line _kendex_key _kendex_value _kendex_seen=" " _kendex_lineno=0
  while IFS= read -r _kendex_line || [[ -n "$_kendex_line" ]]; do
    _kendex_lineno=$((_kendex_lineno + 1))
    _kendex_line="${_kendex_line%$'\r'}"
    kendex_trim _kendex_line "$_kendex_line"
    [[ -z "$_kendex_line" || "$_kendex_line" == \#* ]] && continue

    # A `[`-leading line is a header or an error, never content: `[env] # c`
    # would hide the whole table behind silent defaults, and a quoted or
    # doubled header after [env] would leave foreign keys loading as [env]
    # keys.
    if [[ "$_kendex_line" == \[* ]]; then
      if [[ "$_kendex_line" =~ ^\[([A-Za-z0-9_.-]+)\]$ ]]; then
        _kendex_section="${BASH_REMATCH[1]}"
        continue
      fi
      kendex_env_message table-header "$_kendex_file" "$_kendex_lineno" >&2
      return 1
    fi

    [[ "$_kendex_section" == "env" && "$_kendex_line" == *=* ]] || continue
    kendex_trim _kendex_key "${_kendex_line%%=*}"
    [[ "$_kendex_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    kendex_key_usable "$_kendex_file" "$_kendex_key" "$_kendex_lineno" || return 1
    # Which duplicate wins would be an accident of read order, so a re-assigned
    # key is a configuration error — the same ambiguity guard the settings.sh
    # resolver family applies. Checked before the parent-env skip: a malformed
    # file must fail identically whatever this session exports.
    if [[ "$_kendex_seen" == *" $_kendex_key "* ]]; then
      kendex_env_message duplicate-key "$_kendex_file" "$_kendex_key" >&2
      return 1
    fi
    _kendex_seen="$_kendex_seen$_kendex_key "
    if ! kendex_decode_value _kendex_value "${_kendex_line#*=}"; then
      kendex_env_message value-syntax "$_kendex_file" "$_kendex_key" >&2
      return 1
    fi

    # Parent-process values win over project [env] tables. The snapshot is
    # only populated when called via kendex_load_project_env; standalone calls
    # see an empty snapshot and load every key.
    if kendex_parent_env_has "$_kendex_key"; then
      continue
    fi

    printf -v "$_kendex_key" '%s' "$_kendex_value"
    export "$_kendex_key"
  done < "$_kendex_file"
}

# The private env file is data: it sits in the project checkout, so running
# it would let whoever writes there choose code this caller runs on its own
# account. A line is blank, a `#` comment, or `[export ]KEY=VALUE`, and
# kendex_env_line_value says which values read as the shell would read them.
# Any other line fails the load, naming the file and the line: a line read
# some other way than the shell reads it would load a value nobody wrote.
#
# Reading and assigning are two steps. Nothing is assigned until the whole
# file has been read, and kendex_load_project_env assigns only after its
# parent snapshot is gone, so no line can land on a variable the loader is
# still using: Bash expands `$(...)` inside a name such as `a[$(cmd)]` when
# a variable holding that name is expanded indirectly or counted.

# The value of one assignment, or 1 where the shell would not read RAW as
# that literal text: it would run a command, expand a name or split words.
# A bare word is taken as written. A quoted value is the settings grammar's
# own string (kendex_decode_value), except where the shell reads a quoted
# value differently: a `#` touching the closing quote is part of the value
# there, and double quotes expand `$` and backticks.
kendex_env_line_value() { # OUT_VAR RAW — value assigned to OUT_VAR; 1 = outside the grammar, OUT_VAR untouched
  local _kendex_line_decoded
  local _kendex_line_bare='^([A-Za-z0-9_./:@%+,=-]*)([[:space:]]+#.*)?$'
  local _kendex_line_glued="^('[^']*'|\"[^\"]*\")#"
  if [[ "$2" =~ $_kendex_line_bare ]]; then
    printf -v "$1" '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  case "$2" in
    \'* | \"*) ;;
    *) return 1 ;;
  esac
  [[ ! "$2" =~ $_kendex_line_glued ]] || return 1
  kendex_decode_value _kendex_line_decoded "$2" || return 1
  [[ "$2" != \"* || "$_kendex_line_decoded" != *[\$\`]* ]] || return 1
  printf -v "$1" '%s' "$_kendex_line_decoded"
}

# Reads FILE into _kendex_private_values, three entries per assignment: the
# key, the value, and `export` or `plain`. A key the parent snapshot holds is
# left out, as kendex_load_settings_file leaves it out.
kendex_read_env_file() { # FILE — 0 = read, an absent FILE included; 1 + ::error otherwise
  local _kendex_env_line _kendex_env_lineno=0 _kendex_env_key _kendex_env_value _kendex_env_form LC_ALL=C
  local _kendex_env_assignment='^([A-Za-z_][A-Za-z0-9_]*)=(.*)$'
  _kendex_private_values=()
  kendex_source_usable "$1" || return 1
  [[ -f "$1" ]] || return 0
  kendex_bom_guard "$1" || return 1
  while IFS= read -r _kendex_env_line || [[ -n "$_kendex_env_line" ]]; do
    _kendex_env_lineno=$((_kendex_env_lineno + 1))
    _kendex_env_line="${_kendex_env_line%$'\r'}"
    kendex_trim _kendex_env_line "$_kendex_env_line"
    [[ -z "$_kendex_env_line" || "$_kendex_env_line" == \#* ]] && continue
    _kendex_env_form=plain
    if [[ "$_kendex_env_line" =~ ^export[[:space:]]+(.*)$ ]]; then
      _kendex_env_form=export
      _kendex_env_line="${BASH_REMATCH[1]}"
    fi
    _kendex_env_key=""
    if [[ "$_kendex_env_line" =~ $_kendex_env_assignment ]]; then
      _kendex_env_key="${BASH_REMATCH[1]}"
      kendex_env_line_value _kendex_env_value "${BASH_REMATCH[2]}" || _kendex_env_key=""
    fi
    if [[ -z "$_kendex_env_key" ]]; then
      kendex_env_message private-env-line "$1" "$_kendex_env_lineno" >&2
      return 1
    fi
    kendex_key_usable "$1" "$_kendex_env_key" "$_kendex_env_lineno" || return 1
    kendex_parent_env_has "$_kendex_env_key" ||
      _kendex_private_values+=("$_kendex_env_key" "$_kendex_env_value" "$_kendex_env_form")
  done < "$1"
}

# Assigns what kendex_read_env_file read, as the shell would have: an
# `export` line exports its key, and any other line sets a variable that is
# exported only when it already was or the caller runs under `set -a`. It
# keeps no variable of its own for a line to overwrite.
kendex_assign_env_file() {
  set -- ${_kendex_private_values[@]+"${_kendex_private_values[@]}"}
  unset _kendex_private_values
  while (($# >= 3)); do
    printf -v "$1" '%s' "$2" || return 1
    [[ "$3" != export ]] || export "$1"
    shift 3
  done
}

# One private env file, read and assigned, for a caller that loads it alone.
# The name is older than the rule: the file is never sourced.
kendex_source_env_file() { # FILE
  kendex_read_env_file "$1" || return 1
  kendex_assign_env_file
}

# Which file this project keeps its secrets in, relative to its root.
# Read from KENDEX_ENV_FILE, which the settings load above has already
# exported when the project sets it, and which the caller's environment
# outranks like every other key.
#
# The path is refused rather than resolved when it could reach outside the
# project: a path a project did not mean to name would load somebody else's
# values into this shell.
# Whether the DIRECTORY the private env file sits in stays inside the
# project once every link on the way is followed. Spelling alone cannot
# answer that: `config/priv.env` names nothing outside the project, and
# reads a file anywhere at all when `config` points out of it. The file
# may not exist yet, so the deepest existing ancestor is what is resolved
# and the rest is spelling, which kendex_private_env_file has already
# judged. `cd -P` gives Bash its physical PWD on every supported Bash;
# readlink -f and realpath are not portable.
#
# The file ITSELF being a link is left alone on purpose, and this is the
# line between the two. A directory link is the configured NAME reaching
# somewhere the project never wrote down, which is what this guard is
# against. A link at the private file is the project's own layout, put
# there by whoever owns the directory: a git worktree links `.env.local`
# back to its main checkout so every worktree shares one credential file,
# and refusing that would stop every package in every worktree while
# stopping nobody who can already write inside the project root.
kendex_inside_project() { # PROJECT_ROOT RELATIVE_FILE — 0 = the file's directory is inside; 1 + ::error otherwise
  local _kendex_root="$1" _kendex_file="$2" _kendex_top _kendex_path _kendex_dir _kendex_at
  local _kendex_cwd="$PWD"
  if cd -P -- "$_kendex_root" >/dev/null 2>&1; then
    _kendex_top="$PWD"
    cd -- "$_kendex_cwd" >/dev/null || return 1
  else
    kendex_env_message private-env-unresolved "$_kendex_root" >&2
    return 1
  fi
  _kendex_path="$_kendex_root/$_kendex_file"
  # Climb only past components that are ABSENT. One that exists as
  # something other than a directory blocks the path: no file can be
  # created under it, so climbing past it would resolve the project root,
  # call the path contained, and then read as absent — the credential
  # silently never loads and nothing says why.
  _kendex_dir="${_kendex_path%/*}"
  while [[ -n "$_kendex_dir" && ! -e "$_kendex_dir" ]]; do
    _kendex_dir="${_kendex_dir%/*}"
  done
  [[ -n "$_kendex_dir" ]] || _kendex_dir="/"
  if [[ ! -d "$_kendex_dir" ]]; then
    kendex_env_message private-env-blocked "$_kendex_file" >&2
    return 1
  fi
  if cd -P -- "$_kendex_dir" >/dev/null 2>&1; then
    _kendex_at="$PWD"
    cd -- "$_kendex_cwd" >/dev/null || return 1
  else
    kendex_env_message private-env-unresolved "$_kendex_dir" >&2
    return 1
  fi
  if [[ "$_kendex_at" != "$_kendex_top" && "$_kendex_at" != "$_kendex_top"/* ]]; then
    kendex_env_message private-env-outside "$_kendex_file" >&2
    return 1
  fi
}

kendex_private_env_file() { # OUT_VAR PROJECT_ROOT — project-relative private env file, assigned to OUT_VAR
  local _kendex_named="${KENDEX_ENV_FILE:-}"
  if [[ -z "$_kendex_named" ]]; then
    _kendex_named='.env.local'
  else
    case "$_kendex_named" in
      /* | *:* | *\\* | .. | ../* | */../* | */..)
        kendex_env_message private-env-path "$_kendex_named" >&2
        return 1
        ;;
    esac
  fi
  # The default is checked too, so the guarantee is one rule rather than a
  # rule about configured names: `.env.local` linked out of the project
  # reads somebody else's file just as surely as a named path does.
  kendex_inside_project "$2" "$_kendex_named" || return 1
  printf -v "$1" '%s' "$_kendex_named"
}

# Consumers check this contract before project files can assign caller locals.
kendex_project_env_supports() { # CAPABILITY
  [[ "$1" == selected-private-path ]]
}

kendex_load_project_env() { # PROJECT_ROOT [PRIVATE_FILE_OUT_VAR] — optional output is the selected project-relative path
  local _kendex_project_root="$1"
  [[ -n "$_kendex_project_root" ]] || return 0
  local _kendex_empty_private
  if [[ ! -f "$_kendex_project_root/kendex.settings.toml" && ! -f "$_kendex_project_root/.kendex/settings.toml" ]]; then
    kendex_source_usable "$_kendex_project_root/kendex.settings.toml" || return 1
    kendex_source_usable "$_kendex_project_root/.kendex/settings.toml" || return 1
    kendex_private_env_file _kendex_empty_private "$_kendex_project_root" || return 1
    kendex_source_usable "$_kendex_project_root/$_kendex_empty_private" || return 1
    if [[ ! -f "$_kendex_project_root/$_kendex_empty_private" ]]; then
      [[ -z "${2:-}" ]] || printf -v "$2" '%s' "$_kendex_empty_private"
      return 0
    fi
  fi

  # Snapshot parent-process variables (name -> value) so project files cannot
  # clobber caller-provided values (documented precedence: parent process wins
  # over project files). compgen -e lists only exported names (the environment),
  # excluding this function's locals, and is captured before any file loads so
  # it holds parent env only — not values set by the project files below. The
  # stored value re-asserts parent precedence after loading. Assigning
  # without `local` makes the snapshot arrays global from inside this function.
  _kendex_parent_env_names=()
  _kendex_parent_env_values=()
  _kendex_parent_env_name_set=" "
  local _kendex_name
  while IFS= read -r _kendex_name; do
    _kendex_parent_env_names+=("$_kendex_name")
    _kendex_parent_env_values+=("${!_kendex_name-}")
    _kendex_parent_env_name_set+="$_kendex_name "
  done < <(compgen -e)

  # Load order (lowest to highest among project files): settings, then the
  # private env file. Both readers skip parent keys directly, and a settings
  # clobber of a parent value is undone below. A refused load — settings, a
  # private path outside the project, a private line outside its grammar, or
  # a BOM-prefixed file — fails the whole call: resolving on a partial or
  # silently reinterpreted file would be worse than stopping.
  kendex_load_settings_file "$_kendex_project_root/kendex.settings.toml" || return 1
  kendex_load_settings_file "$_kendex_project_root/.kendex/settings.toml" || return 1
  local _kendex_private_file
  kendex_private_env_file _kendex_private_file "$_kendex_project_root" || return 1
  kendex_read_env_file "$_kendex_project_root/$_kendex_private_file" || return 1

  # Re-assert parent values so parent env wins over every project file, while
  # the settings < .env.local order is preserved for non-parent keys.
  # Only changed keys are rewritten; a readonly var can never differ from its
  # snapshot, so this never attempts to assign one.
  local _kendex_i
  for ((_kendex_i = 0; _kendex_i < ${#_kendex_parent_env_names[@]}; _kendex_i++)); do
    _kendex_name="${_kendex_parent_env_names[$_kendex_i]}"
    if [[ "${!_kendex_name-}" != "${_kendex_parent_env_values[$_kendex_i]}" ]]; then
      export "$_kendex_name=${_kendex_parent_env_values[$_kendex_i]}"
    fi
  done

  unset _kendex_parent_env_names _kendex_parent_env_values _kendex_parent_env_name_set
  # The private values land only once the snapshot the loop above expands is gone.
  kendex_assign_env_file || return 1
  if [[ -n "${2:-}" ]]; then
    printf -v "$2" '%s' "$_kendex_private_file"
  fi
}
