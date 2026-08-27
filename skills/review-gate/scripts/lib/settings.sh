# shellcheck shell=bash
# Settings resolution for the review-gate engine. Sourced (not executed) by
# review-predicate.sh, review-writer.sh, pr-watch.sh and the selftest.
#
# Resolution order for every key read through rg_setting (the REVIEW_GATE_*
# family, plus shared keys like PR_REVIEW_WAIT_SECS):
#   1. explicit environment — a SET variable wins even when set to the empty
#      string, so a caller (or the selftest) can force "explicitly empty";
#   2. .env.local (KEY=value, quotes optional — parsed, never sourced);
#   3. .kendex/settings.toml, then the repo's committed kendex.settings.toml
#      (the [env] table's sole `KEY = "value"` assignment; an explicit
#      REVIEW_GATE_SETTINGS_FILE consults only itself);
#   4. the built-in default passed by the caller.
#
# ONE per-key exception: REVIEW_GATE_MODE skips layer 2. The local waiter
# and the CI gate must resolve that switch identically, and CI has no
# .env.local — a dotenv value could disable the wait while the gate still
# enforces. It reads environment, then the settings files, then the default.
#
# REVIEW_GATE_SETTINGS_FILE=/dev/null is the force-defaults handle and means
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
# Scripts run from the repo root in CI (workflow working directory), so the
# default settings path is relative.

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
    echo "::error::$1: settings source is a symlink that does not resolve (dangling target, cycle, or over-long chain); a source is skipped only when it is absent" >&2
  else
    echo "::error::$1: settings source exists but is not a regular file (directory, FIFO, socket or device); a source is skipped only when it is absent" >&2
  fi
  return 1
}

# One read discipline for every settings probe: grep exits 0/1 are
# measurements, anything else is an unreadable source and fails loud —
# falling through to a lower-precedence layer would silently change the
# resolved value.
rg_settings_grep() { # REGEX FILE — matching lines on stdout; 1 = no match
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
# unreadable source and fails loud, same discipline as rg_settings_grep.
rg_env_table() { # FILE — [env]-table lines on stdout; 1 + ::error on a
                 # malformed header; 2 + ::error when unreadable
  local status=0
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
    in_env { print }
  ' < "$1" || status=$?
  [ "$status" -ne 3 ] || return 1
  if [ "$status" -ne 0 ]; then
    echo "::error::$1: unreadable while resolving a setting (awk exit $status)" >&2
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
  matches="$(rg_settings_grep "^[[:space:]]*(export[[:space:]]+)?${name}=" "$file")" || status=$?
  [ "$status" -le 1 ] || return 2
  line="$(printf '%s\n' "$matches" | tail -n 1)"
  [ -n "$line" ] || return 1
  if ! val="$(rg_dotenv_value "${line#*=}")"; then
    echo "::error::$file: unsupported syntax for $name (a quoted value must end at its closing quote, optionally followed by a comment)" >&2
    return 2
  fi
  printf '%s' "$val"
}

rg_setting() { # NAME DEFAULT — resolved value on stdout; nonzero + ::error on
               # a present-but-unparseable assignment (callers must propagate)
  local name="$1" default="$2" line val file table status matches
  # The name is interpolated into ERE patterns below; constrain it to the
  # identifier shape every real key has, so a metacharacter can neither
  # misgrep nor inject pattern syntax.
  case "$name" in
    "" | [0-9]* | *[!A-Za-z0-9_]*)
      echo "::error::rg_setting: invalid key name '$name' (shell identifier shape required: [A-Za-z_][A-Za-z0-9_]*)" >&2
      return 1
      ;;
  esac
  # Indirect expansion, not eval: a non-literal NAME must never become code.
  # ${!name+x} tests set-ness of the variable NAMED by $name (Bash 3.2-safe).
  if [ -n "${!name+x}" ]; then
    printf '%s' "${!name}"
    return 0
  fi
  # /dev/null is the force-defaults handle: it selects NO settings source at
  # all, the dotenv layer included. Keeping that in one place — here, ahead
  # of every source — is what keeps this loader and the copies vendored from
  # it (size-ratchet, growth-guards) answering the sentinel identically.
  if [ "${REVIEW_GATE_SETTINGS_FILE:-}" = "/dev/null" ]; then
    printf '%s' "$default"
    return 0
  fi
  # .env.local beats the settings files — EXCEPT for REVIEW_GATE_MODE, the
  # named per-key exception (header contract): the waiter and the gate must
  # resolve that switch from sources both sides can see.
  case "$name" in
    REVIEW_GATE_MODE) ;;
    *)
      status=0
      val="$(rg_dotenv_layer ".env.local" "$name")" || status=$?
      [ "$status" -ne 2 ] || return 1
      if [ "$status" -eq 0 ]; then
        printf '%s' "$val"
        return 0
      fi
      ;;
  esac
  # Nested project settings override the root file (the standard loader
  # order); an explicit REVIEW_GATE_SETTINGS_FILE consults only itself.
  # Set-but-EMPTY is unset: "" names no file, and consulting only it would
  # resolve every key to its built-in default with nothing said — /dev/null
  # (answered above) is the one force-defaults handle.
  if [ -n "${REVIEW_GATE_SETTINGS_FILE:-}" ]; then
    set -- "$REVIEW_GATE_SETTINGS_FILE"
  else
    set -- ".kendex/settings.toml" "kendex.settings.toml"
  fi
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
    # the built-in default (kendex#1059).
    status=0
    matches="$(printf '%s\n' "$table" | grep -E -- "^[[:space:]]*${name}[[:space:]]*=")" || status=$?
    [ "$status" -le 1 ] || return 1
    if [ "$status" -eq 0 ]; then
      # A re-assigned name is ambiguous — which value wins would be an
      # accident of read order. Silently taking the first could read a
      # stale value on a security-sensitive path, so ambiguity is a
      # configuration error.
      if [ "$(printf '%s\n' "$matches" | grep -c .)" -gt 1 ]; then
        echo "::error::$file: $name is assigned more than once in [env] (each key must be unique in the table)" >&2
        return 1
      fi
      line="$(printf '%s\n' "$matches" | head -n 1)"
      # A PRESENT assignment this parser cannot read (e.g. TOML array syntax
      # for a list key) must fail LOUDLY, never collapse to empty: an empty
      # value can silently widen the gate (empty trusted-logins = any
      # non-author). Only the contract shape is supported — the value is
      # quote-free and backslash-free ([^"\]*), which makes the extraction
      # exact even with a trailing TOML comment (accepted); anything else is
      # a configuration error.
      if ! printf '%s\n' "$line" | grep -Eq -- "^[[:space:]]*${name}[[:space:]]*=[[:space:]]*\"[^\"\\\\]*\"[[:space:]]*(#.*)?\$"; then
        echo "::error::$file: unsupported syntax for $name (expected a single-line basic string with no '\"' and no '\\': $name = \"value\"; list keys pack items with ';' separators)" >&2
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
