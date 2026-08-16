# shellcheck shell=bash
# Settings resolution for the review-gate engine. Sourced (not executed) by
# review-predicate.sh, review-writer.sh, pr-watch.sh and the selftest.
#
# Resolution order for every key read through rg_setting (the REVIEW_GATE_*
# family, plus shared keys like PR_REVIEW_WAIT_SECS):
#   1. explicit environment — a SET variable wins even when set to the empty
#      string, so a caller (or the selftest) can force "explicitly empty";
#   2. the repo's committed vstack.settings.toml (the file's sole uncommented
#      `KEY = "value"` assignment; the file path can be overridden with
#      REVIEW_GATE_SETTINGS_FILE, e.g. /dev/null to force built-in defaults);
#   3. the built-in default passed by the caller.
#
# The parser reads flat single-line basic-string TOML assignments only —
# exactly the shape vstack.settings.toml [env] blocks use. List-valued keys
# therefore pack multiple items into one string with ';' separators.
#
# Keys are matched FILE-WIDE by exact name, with no TOML-table awareness:
# adopter settings sit under an [env] table, and a table-aware top-level
# parser would resolve none of them. The consequence is a contract: every
# key name read through rg_setting is reserved across the whole file — an
# assignment under an unrelated table would be read as the setting, so
# callers must keep these names unique file-wide. The one detectable
# ambiguity, the same name assigned more than once, fails loud below.
#
# Scripts run from the repo root in CI (workflow working directory), so the
# default settings path is relative.

# A source is skipped only when it is ABSENT. A path that exists as
# something else — directory, FIFO, socket, device — fails -f exactly like
# an absent one, and a symlink that does not resolve fails -e as well as -f,
# so -L is what sees it at all: either shape would skip a configured source
# with nothing said and let a lower-precedence value decide. /dev/null is
# the documented force-defaults handle and stays exempt.
rg_settings_usable() { # PATH — 0 = readable-shaped or absent; 1 + ::error otherwise
  [ "$1" != "/dev/null" ] || return 0
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

rg_setting() { # NAME DEFAULT — resolved value on stdout; nonzero + ::error on
               # a present-but-unparseable assignment (callers must propagate)
  local name="$1" default="$2" line val file status matches
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
  file="${REVIEW_GATE_SETTINGS_FILE:-vstack.settings.toml}"
  rg_settings_usable "$file" || return 1
  if [ -f "$file" ]; then
    # Key PRESENCE decides, not value non-emptiness: `NAME = ""` is a real
    # assignment ("empty disables" per the settings docs) and must override the
    # built-in default, exactly like a set-but-empty env var does above.
    # Leading whitespace before a key is valid TOML, so matching is
    # whitespace-tolerant everywhere (presence, ambiguity guard, extraction)
    # — anchoring at column one made an indented duplicate bypass the
    # fail-loud guard and an indented sole assignment collapse silently to
    # the built-in default (vstack#1059).
    status=0
    matches="$(rg_settings_grep "^[[:space:]]*${name}[[:space:]]*=" "$file")" || status=$?
    [ "$status" -le 1 ] || return 1
    if [ "$status" -eq 0 ]; then
      # File-wide matching (header contract) makes a re-assigned name
      # ambiguous — e.g. the same key under two tables. Silently taking the
      # first could read an unrelated table's value on a security-sensitive
      # path, so ambiguity is a configuration error.
      if [ "$(printf '%s\n' "$matches" | grep -c .)" -gt 1 ]; then
        echo "::error::$file: $name is assigned more than once (keys are matched file-wide regardless of TOML table; each name must be unique in the file)" >&2
        return 1
      fi
      line="$(printf '%s\n' "$matches" | head -n 1)"
      # A PRESENT assignment this parser cannot read (e.g. TOML array syntax
      # for a list key) must fail LOUDLY, never collapse to empty: an empty
      # value can silently widen the gate (empty trusted-logins = any
      # non-author). Only the flat single-line basic-string shape is
      # supported — the value is quote-free ([^"]*), which makes the
      # extraction exact even with a trailing TOML comment (accepted);
      # anything else is a configuration error.
      if ! printf '%s\n' "$line" | grep -Eq -- "^[[:space:]]*${name}[[:space:]]*=[[:space:]]*\"[^\"]*\"[[:space:]]*(#.*)?\$"; then
        echo "::error::$file: unsupported syntax for $name (expected a single-line basic string: $name = \"value\"; list keys pack items with ';' separators)" >&2
        return 1
      fi
      val="$(printf '%s\n' "$line" | sed -n "s/^[[:space:]]*${name}[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*\$/\1/p")"
      printf '%s' "$val"
      return 0
    fi
  fi
  printf '%s' "$default"
}
