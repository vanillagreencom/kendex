# shellcheck shell=bash
# Settings resolution for the reducer and organization-standard tools.
#
# Resolution order for every key read through rg_setting (the REVIEW_GATE_*
# family, plus shared keys like PR_REVIEW_WAIT_SECS):
#   1. explicit environment — a SET variable wins even when set to the empty
#      string, so a caller (or the selftest) can force "explicitly empty";
#   2. .env.local, or rg_setting's PRIVATE_FILE argument (KEY=value, quotes
#      optional, parsed, never sourced); an empty argument skips this layer;
#   3. .kendex/settings.toml, then the repo's committed kendex.settings.toml
#      (the [env] table's sole `KEY = "value"` assignment; an explicit
#      REVIEW_GATE_SETTINGS_FILE consults only itself);
#   4. the built-in default passed by the caller.
#
# REVIEW_GATE_SETTINGS_FILE=/dev/null is the force-defaults handle and means
# NO settings source at all: layers 2-3 are skipped whole, leaving explicit
# environment variables and the built-in defaults.
#
# The parser reads the [env] table only, and inside it accepts flat
# single-line basic strings with no `"` or `\`, or literal strings with no
# apostrophe inside — the kendex settings contract, read identically by every
# kendex resolver. An assignment outside [env] belongs to another tool and
# is ignored; a key re-assigned inside [env], or a value in any other
# shape, fails loud below.
#
# Scripts run from the repo root in CI (workflow working directory), so the
# default settings path is relative.

# Refusals start with the stable diagnostics protocol; source values remain
# the resolver's stdout protocol and never include diagnostic text.
rg_settings_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
if [ ! -r "$rg_settings_script_dir/diagnostics.sh" ]; then
  printf 'review-gate-error=diagnostics-load value=%q\n%s\n' "$rg_settings_script_dir/diagnostics.sh" 'Could not load the diagnostics library.' >&2
  return 1
fi
. "$rg_settings_script_dir/diagnostics.sh" 2>/dev/null || {
  printf 'review-gate-error=diagnostics-load value=%q\n%s\n' "$rg_settings_script_dir/diagnostics.sh" 'Could not load the diagnostics library.' >&2
  return 1
}
unset rg_settings_script_dir

# A source is skipped only when it is ABSENT. A path that exists as
# something else — directory, FIFO, socket, device — fails -f exactly like
# an absent one, and a symlink that does not resolve fails -e as well as -f,
# so -L is what sees it at all: either shape would skip a configured source
# with nothing said and let a lower-precedence value decide. The /dev/null
# force-defaults handle never reaches here — rg_setting answers it before any
# source is consulted.
rg_settings_usable() { # PATH — 0 = readable-shaped or absent; 1 + ::error otherwise
  { [ -e "$1" ] || [ -L "$1" ]; } || return 0
  [ ! -f "$1" ] || return 0
  if [ ! -e "$1" ]; then
    rg_message error settings-symlink "$1" "::error::$1: settings source is a symlink that does not resolve (dangling target, cycle, or over-long chain); a source is skipped only when it is absent" >&2
  else
    rg_message error settings-type "$1" "::error::$1: settings source exists but is not a regular file (directory, FIFO, socket or device); a source is skipped only when it is absent" >&2
  fi
  return 1
}

# A UTF-8 byte-order mark is neither whitespace nor `[` nor a key character
# to any reader here, so a BOM-prefixed first line silently misfiles the
# header or assignment it hides. Refuse the source whole, same discipline
# as the header rule. Read via stdin so the path is never an operand.
rg_bom_guard() { # FILE — 0 = no leading BOM; 1 + ::error otherwise
  if [ ! -r "$1" ]; then
    rg_message error settings-unreadable "$1" "::error::$1: settings source is not readable" >&2
    return 1
  fi
  if [ "$(head -c 3 < "$1" 2>/dev/null)" = "$(printf '\357\273\277')" ]; then
    rg_message error settings-bom "$1" "::error::$1: file starts with a UTF-8 byte-order mark; remove it (the first header or assignment would otherwise be misread)" >&2
    return 1
  fi
}

# One read discipline for every settings probe: grep exits 0/1 are
# measurements, anything else is an unreadable source and fails loud —
# falling through to a lower-precedence layer would silently change the
# resolved value.
rg_settings_grep() { # REGEX FILE — matching lines on stdout; 1 = no match
  local status=0
  grep -E -- "$1" "$2" 2>/dev/null || status=$?
  if [ "$status" -gt 1 ]; then
    rg_message error settings-grep "$2" "::error::$2: unreadable while resolving a setting (grep exit $status)" >&2
    return 2
  fi
  return "$status"
}

# Extraction commands share one failure rule. A failed read is never an
# empty value: trust lists and refresh reports both act on resolved values.
rg_settings_extract() { # FILE COMMAND [ARGS...] — stdin to extracted stdout
  local file="$1" command="$2" status=0
  shift 2
  "$command" "$@" 2>/dev/null || status=$?
  if [ "$status" -ne 0 ]; then
    rg_message error settings-extract "$file" "::error::$file: setting extraction failed ($command exit $status)" >&2
    return 2
  fi
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
# unreadable source and fails loud, same discipline as rg_settings_grep.
rg_env_table() { # FILE — [env]-table lines on stdout; 1 + ::error on a
                 # malformed header or leading BOM; 2 + ::error when unreadable
  local status=0
  rg_bom_guard "$1" || return 1
  awk -v src="$1" '
    /^[[:space:]]*\[/ && !/^[[:space:]]*\[[A-Za-z0-9_.-]+\][[:space:]]*$/ {
      printf "review-gate-error=settings-header value=%d\n::error::%s:%d: unsupported table header shape (a header is a lone [name] on its own line, with no comment and no second bracket)\n", NR, src, NR > "/dev/stderr"
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
        printf "review-gate-error=settings-duplicate value=%s\n::error::%s: %s is assigned more than once in [env] (each key must be unique in the table)\n", key, src, key > "/dev/stderr"
        exit 3
      }
      seen[key] = 1
      value = l
      sub(/^[^=]*=[[:space:]]*/, "", value)
      sub(/[[:space:]]+$/, "", value)
      if (value !~ /^"[^"\\]*"[[:space:]]*(#.*)?$/ &&
          value !~ /^\047[^\047]*\047[[:space:]]*(#.*)?$/) {
        printf "review-gate-error=settings-syntax value=%s\n::error::%s: unsupported syntax for %s (expected a single-line basic string with no double quote or backslash, or a literal string with no apostrophe inside)\n", key, src, key > "/dev/stderr"
        exit 3
      }
      print
    }
  ' < "$1" || status=$?
  [ "$status" -ne 3 ] || return 1
  if [ "$status" -ne 0 ]; then
    rg_message error settings-awk "$1" "::error::$1: unreadable while resolving a setting (awk exit $status)" >&2
    return 2
  fi
}

# Extract the value of one parsed dotenv assignment (text after `KEY=`).
# Quoted values end at the FIRST closing delimiter — dotenv/shell
# semantics; an embedded delimiter would need escaping, which this parser
# does not support — so a quote inside a trailing comment can never leak
# into the value: KEY="900" # say "quiet" assigns 900. Anything else
# after the closing quote (an adjacent segment like KEY="tools/base".tsv)
# is a shape this parser cannot read and fails NONZERO — truncating it
# would silently load the wrong value. Unquoted values end at the first
# whitespace: KEY=900 # quiet assigns 900.
rg_dotenv_value() { # RAW — value on stdout; nonzero on an unsupported shape
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

# One dotenv layer (.env.local): the LAST matching KEY= line wins
# (shell-sourcing semantics), optional surrounding quotes stripped. Parsed,
# never sourced. 0 = value on stdout; 1 = this layer assigns nothing;
# 2 = the layer is unusable and resolution must fail loud.
rg_dotenv_layer() { # FILE NAME
  local file="$1" name="$2" line val matches status=0
  rg_settings_usable "$file" || return 2
  [ -f "$file" ] || return 1
  rg_bom_guard "$file" || return 2
  matches="$(rg_settings_grep "^[[:space:]]*(export[[:space:]]+)?${name}=" "$file")" || status=$?
  [ "$status" -le 1 ] || return 2
  line="$(printf '%s\n' "$matches" | rg_settings_extract "$file" tail -n 1)" || return 2
  [ -n "$line" ] || return 1
  if ! val="$(rg_dotenv_value "${line#*=}")"; then
    rg_message error settings-dotenv "$name" "::error::$file: unsupported syntax for $name (a quoted value must end at its closing quote, optionally followed by a comment)" >&2
    return 2
  fi
  printf '%s' "$val"
}

rg_setting() { # NAME DEFAULT [PRIVATE_FILE] — resolved value on stdout; nonzero
               # on a present-but-unparseable assignment. Empty PRIVATE_FILE
               # skips dotenv when resolving the setting that selects its path.
  local name="$1" default="$2" private_file="${3-.env.local}" line val file table status matches
  # The name is interpolated into ERE patterns below; constrain it to the
  # identifier shape every real key has, so a metacharacter can neither
  # misgrep nor inject pattern syntax.
  case "$name" in
    "" | [0-9]* | *[!A-Za-z0-9_]*)
      rg_message error settings-key "$name" "::error::rg_setting: invalid key name '$name' (shell identifier shape required: [A-Za-z_][A-Za-z0-9_]*)" >&2
      return 1
      ;;
  esac
  # Validate every present source before a process value can answer.
  if [ "${REVIEW_GATE_SETTINGS_FILE:-}" != "/dev/null" ]; then
    if [ -n "${REVIEW_GATE_SETTINGS_FILE:-}" ]; then
      set -- "$REVIEW_GATE_SETTINGS_FILE"
    else
      set -- ".kendex/settings.toml" "kendex.settings.toml"
    fi
    for file in "$@"; do
      rg_settings_usable "$file" || return 1
      if [ -f "$file" ]; then
        rg_env_table "$file" >/dev/null || return 1
      fi
    done
    # Every present private source must be readable even when a process
    # value wins. An empty path deliberately selects no private layer.
    if [ -n "$private_file" ]; then
      rg_settings_usable "$private_file" || return 1
      if [ -f "$private_file" ]; then
        rg_bom_guard "$private_file" || return 1
      fi
    fi
  fi
  # Indirect expansion, not eval: a non-literal NAME must never become code.
  # ${!name+x} tests set-ness of the variable NAMED by $name (Bash 3.2-safe).
  if [ -n "${!name+x}" ]; then
    printf '%s' "${!name}"
    return 0
  fi
  # /dev/null is the force-defaults handle: it selects NO settings source at
  # all, the dotenv layer included. Keeping that in one place — here, ahead
  # of every source — is what keeps this loader and the copies vendored from
  # it (doc-limits, commit-guards) answering the sentinel identically.
  if [ "${REVIEW_GATE_SETTINGS_FILE:-}" = "/dev/null" ]; then
    printf '%s' "$default"
    return 0
  fi
  if [ -n "$private_file" ]; then
    status=0
    val="$(rg_dotenv_layer "$private_file" "$name")" || status=$?
    [ "$status" -ne 2 ] || return 1
    if [ "$status" -eq 0 ]; then
      printf '%s' "$val"
      return 0
    fi
  fi
  # Nested project settings override the root file (the standard loader
  # order); the positional list was built — and every present file already
  # validated whole — before any source answered, above.
  for file in "$@"; do
  rg_settings_usable "$file" || return 1
  if [ -f "$file" ]; then
    table="$(rg_env_table "$file")" || return 1
    # Key PRESENCE decides, not value non-emptiness: `NAME = ""` is a real
    # assignment ("empty disables" per the settings docs) and must override the
    # built-in default, exactly like a set-but-empty env var does above.
    # Leading whitespace before a key is valid TOML, so matching is
    # whitespace-tolerant everywhere (presence, ambiguity guard, extraction)
    # — anchoring at column one made an indented duplicate bypass the
    # fail-loud guard and an indented sole assignment collapse silently to
    # the built-in default.
    status=0
    matches="$(printf '%s\n' "$table" | grep -E -- "^[[:space:]]*${name}[[:space:]]*=")" || status=$?
    [ "$status" -le 1 ] || return 1
    if [ "$status" -eq 0 ]; then
      # A re-assigned name is ambiguous — which value wins would be an
      # accident of read order. Silently taking the first could read a
      # stale value on a security-sensitive path, so ambiguity is a
      # configuration error.
      if [ "$(printf '%s\n' "$matches" | grep -c .)" -gt 1 ]; then
        rg_message error settings-duplicate "$name" "::error::$file: $name is assigned more than once in [env] (each key must be unique in the table)" >&2
        return 1
      fi
      # The first line in-shell, never `printf | head -n 1`: head closes the
      # pipe on line one, and past the pipe buffer that SIGPIPEs printf, which
      # pipefail turns into a 141 the sourcing caller's errexit acts on. This
      # file sets no mode of its own; it runs in the caller's, which does.
      line="${matches%%$'\n'*}"
      # A PRESENT assignment this parser cannot read (e.g. TOML array syntax
      # for a list key) must fail LOUDLY, never collapse to empty: an empty
      # value can silently widen the gate (empty trusted-logins = any
      # non-author). Each supported string ends at its first closing
      # delimiter; a quote in a trailing comment stays outside.
      if ! grep -Eq -- "^[[:space:]]*${name}[[:space:]]*=[[:space:]]*(\"[^\"\\\\]*\"|'[^']*')[[:space:]]*(#.*)?\$" <<<"$line"; then
        rg_message error settings-syntax "$name" "::error::$file: unsupported syntax for $name (expected a single-line basic string with no '\"' or '\\', or a literal string with no apostrophe inside; list keys pack items with ';' separators)" >&2
        return 1
      fi
      val="$(printf '%s\n' "$line" | rg_settings_extract "$file" sed -n -e "s/^[[:space:]]*${name}[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*\$/\1/p;t" -e "s/^[[:space:]]*${name}[[:space:]]*=[[:space:]]*'\([^']*\)'.*\$/\1/p")" || return 1
      printf '%s' "$val"
      return 0
    fi
  fi
  done
  printf '%s' "$default"
}

# A packed list setting as one trimmed, non-empty entry per line. pipefail
# inside, checked at every caller: a list decides a trust boundary, and the
# last stage of the pipeline returns 0 on empty output. A `tr` that died would
# leave a RESTRICTED list looking empty, which the evidence read takes as "any
# non-author" — the trust list would open the gate it was set to close. A
# broken pipeline is a refusal instead.
rg_pack() { # RAW SEPARATORS -> one trimmed, non-empty entry per line
  ( set -o pipefail
    printf '%s\n' "$1" | tr "$2" '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;/^$/d' )
}
