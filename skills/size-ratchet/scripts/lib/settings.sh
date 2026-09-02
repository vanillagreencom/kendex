# shellcheck shell=bash
# Settings resolution for size-ratchet. Sourced (not executed) by
# scripts/size-ratchet.
#
# VENDORED from skills/review-gate/scripts/lib/settings.sh (rg_setting),
# renamed sr_setting: skills are standalone-installable, so a consumer that
# installs only size-ratchet has no review-gate tree to source from. Keep
# the logic in sync with the original; behavioral fixes belong there first.
#
# Resolution order for every key read through sr_setting (the SIZE_RATCHET_*
# family):
#   1. explicit environment — a SET variable wins even when set to the empty
#      string, so a caller can force "explicitly empty";
#   2. .env.local (KEY=value, quotes optional — parsed, never sourced);
#   3. .kendex/settings.toml, then the repo's committed kendex.settings.toml
#      (the [env] table's sole `KEY = "value"` assignment; an explicit
#      SIZE_RATCHET_SETTINGS_FILE consults only itself);
#   4. the built-in default passed by the caller.
# A `.env` file is never read.
#
# SIZE_RATCHET_SETTINGS_FILE=/dev/null is the force-defaults handle and means
# NO settings source at all: layers 2-3 are skipped whole, leaving explicit
# environment variables and the built-in defaults.
#
# The parser reads the [env] table only, and inside it accepts flat
# single-line basic-string assignments whose value contains no `"` and no
# `\` — exactly the kendex settings contract, decoded identically by every
# kendex resolver. An assignment outside [env] belongs to another tool and
# is ignored; a key re-assigned inside [env], or a value in any other
# shape, fails loud below.
#
# The caller cds to the repo root before resolving, so the default settings
# path is relative.

# Extract the value of one parsed dotenv assignment (text after `KEY=`).
# Quoted values end at the FIRST closing delimiter — dotenv/shell
# semantics; an embedded delimiter would need escaping, which this parser
# does not support — so a quote inside a trailing comment can never leak
# into the value: KEY="500" # say "ratchet" assigns 500. Anything else
# after the closing quote (an adjacent segment like KEY="tools/base".tsv)
# is a shape this parser cannot read and fails NONZERO — truncating it
# would silently load the wrong value. Unquoted values end at the first
# whitespace: KEY=500 # ratchet assigns 500.
sr_dotenv_value() { # RAW — value on stdout; nonzero on an unsupported shape
  local val="$1" rest
  case "$val" in
    \"*\"*)
      val="${val#\"}"
      rest="${val#*\"}"
      val="${val%%\"*}"
      ;;
    \'*\'*)
      val="${val#\'}"
      rest="${val#*\'}"
      val="${val%%\'*}"
      ;;
    *)
      printf '%s' "${val%%[[:space:]]*}"
      return 0
      ;;
  esac
  # Only whitespace, or whitespace followed by a #comment, may follow the
  # closing quote. An ADJACENT # (KEY="abc"#def) is not a comment in shell
  # semantics — it is an adjacent segment, and truncating it would load an
  # unintended value, so it fails like any other unsupported shape.
  case "$rest" in
    "") printf '%s' "$val"; return 0 ;;
    [[:space:]]*)
      rest="${rest#"${rest%%[![:space:]]*}"}"
      case "$rest" in
        "" | "#"*) printf '%s' "$val"; return 0 ;;
      esac
      ;;
  esac
  return 1
}

# A source is skipped only when it is ABSENT. A path that exists as
# something else — directory, FIFO, socket, device — fails -f exactly like
# an absent one, and a symlink that does not resolve fails -e as well as -f,
# so -L is what sees it at all: either shape would skip a configured source
# with nothing said and let a lower-precedence value decide. The /dev/null
# force-defaults handle never reaches here — sr_setting answers it before any
# source is consulted.
sr_settings_usable() { # PATH — 0 = readable-shaped or absent; 1 + ::error otherwise
  { [ -e "$1" ] || [ -L "$1" ]; } || return 0
  [ ! -f "$1" ] || return 0
  if [ ! -e "$1" ]; then
    echo "::error::$1: settings source is a symlink that does not resolve (dangling target, cycle, or over-long chain); a source is skipped only when it is absent" >&2
  else
    echo "::error::$1: settings source exists but is not a regular file (directory, FIFO, socket or device); a source is skipped only when it is absent" >&2
  fi
  return 1
}

# Lexically normalize a repo-relative path: drop empty and `.` segments, and
# let `..` pop the segment before it. Pure string surgery — no symlink
# resolution, Bash 3.2-safe. The index records canonical paths, so a source
# named `sub/../kendex.settings.toml` is the same entry as
# `kendex.settings.toml` and has to probe, and materialize, as that one. A
# `..` with nothing left to pop ACCUMULATES rather than vanishing, so a path
# that really does leave the repository stays visible as one to the caller.
sr_settings_normalize_path() { # PATH — normalized path on stdout ("" when it cancels out)
  local rest="$1" out="" seg
  while [ -n "$rest" ]; do
    seg="${rest%%/*}"
    if [ "$seg" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    case "$seg" in
      "" | ".") ;;
      "..")
        case "$out" in
          "" | ".." | */..) out="${out:+$out/}.." ;;
          */*) out="${out%/*}" ;;
          *) out="" ;;
        esac
        ;;
      *) out="${out:+$out/}$seg" ;;
    esac
  done
  printf '%s' "$out"
}
# ls-tree answers for a COMPLETE path only, so a settings source reached
# through a symlinked parent has no entry — indistinguishable from a source
# HEAD does not carry. Every ancestor is classified before the absent
# sentinel may be returned; the rule is DEVELOPMENT.md, Trusted reference
# snapshot. Detection only: nothing here reads a target or follows a link.
sr_settings_head_absence_real() { # NORMALIZED-PATH — 0 = the sentinel is earned; 1 + ::error
  local rest="$1" prefix="" entry="" status=0 mode=""
  while :; do
    case "$rest" in */*) ;; *) return 0 ;; esac
    prefix="${prefix:+$prefix/}${rest%%/*}"
    rest="${rest#*/}"
    status=0
    entry="$(git ls-tree HEAD -- ":(literal)$prefix" 2>/dev/null)" || status=$?
    if [ "$status" -ne 0 ]; then
      echo "::error::$prefix: could not query HEAD while resolving a setting (git ls-tree exit $status)" >&2
      return 1
    fi
    [ -n "$entry" ] || return 0
    mode="${entry%% *}"
    [ "$mode" != 040000 ] || continue
    case "$mode" in 120000) mode="a symlink" ;; *) mode="mode $mode" ;; esac
    echo "::error::$prefix: HEAD carries this path component as $mode, not a directory; HEAD settings cannot be resolved through it" >&2
    return 1
  done
}
# A flat, reversible name for a repo-relative path, so a snapshot directory
# holds one entry per source. Parameter expansion rather than sed: this runs
# for every source of every key read, and a fork here is most of what a small
# repository spends resolving its settings.
sr_settings_slug() { # PATH — sets SR_SETTINGS_SLUG
  local s="$1"
  s="${s//%/%25}"
  s="${s//\//%2F}"
  s="${s//./%2E}"
  SR_SETTINGS_SLUG="$s"
}

SR_SETTINGS_NL='
'

# Resolution against a snapshot is a pure function of the snapshot and the
# path: nothing in a run rewrites the index or moves HEAD under it. Each key
# read re-asks for the same two settings files and .env.local, and each ask
# costs several git probes, so the answer is recorded beside the snapshot it
# came from. It has to be ON DISK: every caller wraps this in a command
# substitution, and a shell variable would not survive that subshell.
sr_settings_source() { # FILE — the path to actually read; nonzero + ::error on failure
  local dir="" memo="" resolved=""
  if [ "${SR_SETTINGS_FROM_HEAD:-0}" = "1" ]; then
    dir="${SR_SETTINGS_HEAD_DIR:-}"
  elif [ "${SR_SETTINGS_FROM_INDEX:-0}" = "1" ]; then
    dir="${SR_SETTINGS_INDEX_DIR:-}"
  fi
  # No snapshot: nothing to memoize, and nowhere to put it.
  [ -n "$dir" ] || { sr_settings_resolve "$1"; return; }
  sr_settings_slug "$1"
  memo="$dir/settings.resolved.$SR_SETTINGS_SLUG"
  if [ -f "$memo" ]; then
    IFS= read -r resolved <"$memo" || resolved=""
    # A resolution is always a path, so an empty read is a torn or unreadable
    # memo, never a recorded answer: fall through and resolve it again.
    if [ -n "$resolved" ]; then
      printf '%s' "$resolved"
      return 0
    fi
  fi
  resolved="$(sr_settings_resolve "$1")" || return 1
  # A memo holds one line, so a resolution carrying a newline cannot come back
  # out: the read above would return its first line, which names no file, and
  # the key would fall back to its default with nothing said. Guarded on the
  # value, not on what built it, so a new return path cannot reopen this.
  case "$resolved" in
    *"$SR_SETTINGS_NL"*)
      printf '%s' "$resolved"
      return 0
      ;;
  esac
  # The memo is only a cache, and a slug spends three characters on `/` and
  # `.`, so a legal path can encode past NAME_MAX. A write that cannot land
  # costs a re-resolve, not an answer; stderr first silences bash's error.
  printf '%s\n' "$resolved" 2>/dev/null >"$memo" || :
  printf '%s' "$resolved"
}

sr_settings_resolve() { # FILE — the path to actually read; nonzero + ::error on failure
  local file="$1" copy="" status=0 entry="" norm="" head_status=0 tree_status=0 target="" base="" depth=0
  if [ "${SR_SETTINGS_FROM_HEAD:-0}" = "1" ]; then
    if [ -z "${SR_SETTINGS_HEAD_DIR:-}" ]; then
      echo "::error::$file: SR_SETTINGS_HEAD_DIR is required for HEAD settings resolution" >&2
      return 1
    fi
    case "$file" in
      /*)
        printf '%s' "$SR_SETTINGS_HEAD_DIR/settings.absent"
        return 0
        ;;
    esac
    norm="$(sr_settings_normalize_path "$file")"
    case "$norm" in
      "" | ".." | "../"*)
        printf '%s' "$SR_SETTINGS_HEAD_DIR/settings.absent"
        return 0
        ;;
    esac
    file="$norm"
    while :; do
      status=0
      entry="$(git ls-tree HEAD -- ":(literal)$file" 2>/dev/null)" || status=$?
      if [ "$status" -ne 0 ]; then
        echo "::error::$file: could not query HEAD while resolving a setting (git ls-tree exit $status)" >&2
        return 1
      fi
      if [ -z "$entry" ]; then
        sr_settings_head_absence_real "$file" || return 1
        printf '%s' "$SR_SETTINGS_HEAD_DIR/settings.absent"
        return 0
      fi
      case "${entry%% *}" in
        100*) break ;;
        120000)
          target="$(git show "HEAD:$file" 2>/dev/null)" || {
            echo "::error::$file: could not read its HEAD symlink target" >&2
            return 1
          }
          case "$target" in
            "" | /* | *$'\n'*)
              echo "::error::$file: HEAD symlink target has no historical repository form" >&2
              return 1
              ;;
          esac
          case "$file" in */*) base="${file%/*}/" ;; *) base="" ;; esac
          norm="$(sr_settings_normalize_path "$base$target")"
          case "$norm" in
            "" | ".." | "../"*)
              echo "::error::$file: HEAD symlink target leaves the repository" >&2
              return 1
              ;;
          esac
          file="$norm"
          depth=$((depth + 1))
          [ "$depth" -lt 40 ] || { echo "::error::$1: HEAD settings symlink chain does not resolve" >&2; return 1; }
          ;;
        *)
          echo "::error::$file: HEAD settings source is not a regular file or symlink" >&2
          return 1
          ;;
      esac
    done
    sr_settings_slug "$file"
    copy="$SR_SETTINGS_HEAD_DIR/settings.file.$SR_SETTINGS_SLUG"
    if [ ! -f "$copy" ] && ! git show "HEAD:$file" >"$copy" 2>/dev/null; then
      rm -f -- "$copy"
      echo "::error::$file: could not read its HEAD settings content" >&2
      return 1
    fi
    printf '%s' "$copy"
    return 0
  fi
  if [ "${SR_SETTINGS_FROM_INDEX:-0}" != "1" ] || [ -z "${SR_SETTINGS_INDEX_DIR:-}" ]; then
    printf '%s' "$file"
    return 0
  fi
  case "$file" in
    /*)
      printf '%s' "$file"
      return 0
      ;;
  esac
  norm="$(sr_settings_normalize_path "$file")"
  case "$norm" in
    "" | ".." | "../"*)
      printf '%s' "$file"
      return 0
      ;;
  esac
  file="$norm"
  git ls-files --error-unmatch -- ":(literal)$file" >/dev/null 2>&1 || status=$?
  case "$status" in
    0) ;;
    1)
      git rev-parse --verify --quiet HEAD >/dev/null 2>&1 || head_status=$?
      case "$head_status" in
        0)
          entry="$(git ls-tree HEAD -- ":(literal)$file" 2>/dev/null)" || tree_status=$?
          if [ "$tree_status" -ne 0 ]; then
            echo "::error::$file: could not probe HEAD while resolving a setting (git ls-tree exit $tree_status); refusing to treat it as untracked" >&2
            return 1
          fi
          case "${entry:+tracked}" in
            tracked)
              printf '%s' "$SR_SETTINGS_INDEX_DIR/settings.absent"
              return 0
              ;;
            *) ;;
          esac
          ;;
        1) ;;
        *)
          echo "::error::$file: could not resolve HEAD while resolving a setting (git rev-parse exit $head_status); refusing to treat it as untracked" >&2
          return 1
          ;;
      esac
      printf '%s' "$file"
      return 0
      ;;
    *)
      echo "::error::$file: could not query the index while resolving a setting (git ls-files exit $status); refusing to treat it as untracked" >&2
      return 1
      ;;
  esac
  status=0
  entry="$(git ls-files -s -- ":(literal)$file" 2>/dev/null)" || status=$?
  if [ "$status" -ne 0 ]; then
    echo "::error::$file: could not read its index mode while resolving a setting (git ls-files exit $status)" >&2
    return 1
  fi
  case "${entry%% *}" in
    120000)
      echo "::error::$file: tracked as a symlink; staged settings resolution cannot read through it" >&2
      return 1
      ;;
  esac
  sr_settings_slug "$file"
  copy="$SR_SETTINGS_INDEX_DIR/settings.file.$SR_SETTINGS_SLUG"
  if [ ! -f "$copy" ]; then
    if ! git show ":$file" >"$copy" 2>/dev/null; then
      rm -f -- "$copy"
      echo "::error::$file: could not read the staged copy while resolving a setting" >&2
      return 1
    fi
  fi
  printf '%s' "$copy"
}

# A UTF-8 byte-order mark is neither whitespace nor `[` nor a key character
# to any reader here, so a BOM-prefixed first line silently misfiles the
# header or assignment it hides. Refuse the source whole, same discipline
# as the header rule. Read via stdin so the path is never an operand.
sr_bom_guard() { # FILE — 0 = no leading BOM; 1 + ::error otherwise
  if [ "$(head -c 3 < "$1" 2>/dev/null)" = "$(printf '\357\273\277')" ]; then
    echo "::error::$1: file starts with a UTF-8 byte-order mark; remove it (the first header or assignment would otherwise be misread)" >&2
    return 1
  fi
}

# One read discipline for every settings probe: grep exits 0/1 are
# measurements, anything else is an unreadable source and fails loud —
# falling through to a lower-precedence layer would silently change the
# resolved value.
sr_settings_grep() { # REGEX FILE — matching lines on stdout; 1 = no match
  local status=0
  grep -E -- "$1" "$2" || status=$?
  if [ "$status" -gt 1 ]; then
    echo "::error::$2: unreadable while resolving a setting (grep exit $status)" >&2
    return 2
  fi
  return "$status"
}

# The [env] table's lines. A table header is a lone [name] on its own line
# (whitespace tolerated); a `[`-leading line in ANY other shape is a
# configuration error — headers decide which assignments load, so
# `[env] # comment` passing as content hides the whole table behind silent
# defaults, and a quoted or doubled header after [env] leaves foreign keys
# reading as [env] keys. Lines before the first header belong to no table.
# The source is fed on stdin, never as an operand: awk parses an operand
# containing `=` as a variable assignment and would read no input while the
# resolver silently returns defaults. awk failing to read the source is an
# unreadable source and fails loud, same discipline as sr_settings_grep.
sr_env_table() { # FILE — [env]-table lines on stdout; 1 + ::error on a
                 # malformed header or leading BOM; 2 + ::error when unreadable
  local status=0
  sr_bom_guard "$1" || return 1
  awk -v src="$1" '
    /^[[:space:]]*\[/ && !/^[[:space:]]*\[[A-Za-z0-9_.-]+\][[:space:]]*$/ {
      printf "::error::%s:%d: unsupported table header shape (a header is a lone [name] on its own line, with no comment and no second bracket)\n", src, NR > "/dev/stderr"
      exit 3
    }
    /^[[:space:]]*\[/ {
      header = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", header)
      in_env = (header == "[env]")
      next
    }
    # The COMPLETE table is validated, not only the requested key: the
    # kendex-env.sh loader refuses a duplicate or non-contract assignment
    # anywhere in [env], and this family must refuse the same files. Its
    # silent skips are mirrored exactly too: lines with no = and keys that
    # are not plain identifiers pass through unread, never as errors.
    in_env {
      l = $0
      sub(/\r$/, "", l)
      if (l ~ /^[[:space:]]*$/ || l ~ /^[[:space:]]*#/) { print; next }
      if (l !~ /=/) { print; next }
      key = l
      sub(/^[[:space:]]*/, "", key)
      sub(/[[:space:]]*=.*$/, "", key)
      if (key !~ /^[A-Za-z_][A-Za-z0-9_]*$/) { print; next }
      if (key in seen) {
        printf "::error::%s: %s is assigned more than once in [env] (each key must be unique in the table)\n", src, key > "/dev/stderr"
        exit 3
      }
      seen[key] = 1
      value = l
      sub(/^[^=]*=[[:space:]]*/, "", value)
      sub(/[[:space:]]+$/, "", value)
      if (value !~ /^"[^"\\]*"[[:space:]]*(#.*)?$/) {
        printf "::error::%s: unsupported syntax for %s (expected a single-line basic string, no double quote and no backslash: %s = \"value\")\n", src, key, key > "/dev/stderr"
        exit 3
      }
      print
    }
  ' < "$1" || status=$?
  [ "$status" -ne 3 ] || return 1
  if [ "$status" -ne 0 ]; then
    echo "::error::$1: unreadable while resolving a setting (awk exit $status)" >&2
    return 2
  fi
}

sr_setting() { # NAME DEFAULT — resolved value on stdout; nonzero + ::error on
  local name="$1" default="$2" line val file table status matches source_name
  case "$name" in
    "" | [0-9]* | *[!A-Za-z0-9_]*)
      echo "::error::sr_setting: invalid key name '$name' (shell identifier shape required: [A-Za-z_][A-Za-z0-9_]*)" >&2
      return 1
      ;;
  esac
  if [ "${SIZE_RATCHET_SETTINGS_FILE:-}" != "/dev/null" ]; then
    if [ -n "${SIZE_RATCHET_SETTINGS_FILE:-}" ]; then
      set -- "$SIZE_RATCHET_SETTINGS_FILE"
    else
      set -- ".kendex/settings.toml" "kendex.settings.toml"
    fi
    for file in "$@"; do
      source_name="$file"
      file="$(sr_settings_source "$file")" || return 1
      if [ "${SR_SETTINGS_FROM_HEAD:-0}" = "1" ] && [ -n "${SIZE_RATCHET_SETTINGS_FILE:-}" ] \
        && [ "${SIZE_RATCHET_SETTINGS_FILE:-}" != "/dev/null" ] && [ ! -f "$file" ] \
        && { [ -e "$source_name" ] || [ -L "$source_name" ]; }; then
        table="$(sr_env_table "$source_name")" || return 1
        status=0
        matches="$(printf '%s\n' "$table" | grep -E -- "^[[:space:]]*${name}[[:space:]]*=")" || status=$?
        [ "$status" -le 1 ] || return 1
        if [ "$status" -eq 0 ]; then
          echo "::error::$source_name: $name has no historical form in HEAD" >&2
          return 1
        fi
      fi
      sr_settings_usable "$file" || return 1
      if [ -f "$file" ]; then
        sr_env_table "$file" >/dev/null || return 1
      fi
    done
    file="$(sr_settings_source ".env.local")" || return 1
    sr_settings_usable "$file" || return 1
    if [ -f "$file" ]; then
      sr_bom_guard "$file" || return 1
      if [ ! -r "$file" ]; then
        echo "::error::$file: unreadable while resolving a setting (permission denied)" >&2
        return 1
      fi
    fi
  fi
  if [ -n "${!name+x}" ]; then
    printf '%s' "${!name}"
    return 0
  fi
  if [ "${SIZE_RATCHET_SETTINGS_FILE:-}" = "/dev/null" ]; then
    printf '%s' "$default"
    return 0
  fi
  local local_env=""
  local_env="$(sr_settings_source ".env.local")" || return 1
  sr_settings_usable "$local_env" || return 1
  if [ "${SR_SETTINGS_FROM_HEAD:-0}" = "1" ] && [ ! -f "$local_env" ] && [ -f .env.local ]; then
    status=0
    matches="$(sr_settings_grep "^[[:space:]]*(export[[:space:]]+)?${name}=" .env.local)" || status=$?
    [ "$status" -le 1 ] || return 1
    if [ "$status" -eq 0 ]; then
      echo "::error::.env.local: $name has no historical form in HEAD" >&2
      return 1
    fi
  fi
  if [ -f "$local_env" ]; then
    sr_bom_guard "$local_env" || return 1
    status=0
    matches="$(sr_settings_grep "^[[:space:]]*(export[[:space:]]+)?${name}=" "$local_env")" || status=$?
    [ "$status" -le 1 ] || return 1
    line="$(printf '%s\n' "$matches" | tail -n 1)"
    if [ -n "$line" ]; then
      if ! val="$(sr_dotenv_value "${line#*=}")"; then
        echo "::error::.env.local: unsupported syntax for $name (a quoted value must end at its closing quote, optionally followed by a comment)" >&2
        return 1
      fi
      printf '%s' "$val"
      return 0
    fi
  fi
  for file in "$@"; do
  file="$(sr_settings_source "$file")" || return 1
  sr_settings_usable "$file" || return 1
  if [ -f "$file" ]; then
    table="$(sr_env_table "$file")" || return 1
    status=0
    matches="$(printf '%s\n' "$table" | grep -E -- "^[[:space:]]*${name}[[:space:]]*=")" || status=$?
    [ "$status" -le 1 ] || return 1
    if [ "$status" -eq 0 ]; then
      if [ "$(printf '%s\n' "$matches" | grep -c .)" -gt 1 ]; then
        echo "::error::$file: $name is assigned more than once in [env] (each key must be unique in the table)" >&2
        return 1
      fi
      line="$(printf '%s\n' "$matches" | head -n 1)"
      if ! printf '%s\n' "$line" | grep -Eq -- "^[[:space:]]*${name}[[:space:]]*=[[:space:]]*\"[^\"\\\\]*\"[[:space:]]*(#.*)?\$"; then
        echo "::error::$file: unsupported syntax for $name (expected a single-line basic string with no '\"' and no '\\': $name = \"value\")" >&2
        return 1
      fi
      val="$(printf '%s\n' "$line" | sed -n "s/^[[:space:]]*${name}[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*\$/\1/p")"
      printf '%s' "$val"
      return 0
    fi
  fi
  done
  printf '%s' "$default"
}
