# shellcheck shell=bash
# Settings resolution for the review-gate engine. Sourced (not executed) by
# review-predicate.sh, approval-refire.sh and the selftest.
#
# Resolution order for every REVIEW_GATE_* key:
#   1. explicit environment — a SET variable wins even when set to the empty
#      string, so a caller (or the selftest) can force "explicitly empty";
#   2. the repo's committed vstack.settings.toml (first uncommented
#      `KEY = "value"` assignment; the file path can be overridden with
#      REVIEW_GATE_SETTINGS_FILE, e.g. /dev/null to force built-in defaults);
#   3. the built-in default passed by the caller.
#
# The parser reads flat single-line basic-string TOML assignments only —
# exactly the shape vstack.settings.toml [env] blocks use. List-valued keys
# therefore pack multiple items into one string with ';' separators.
#
# Scripts run from the repo root in CI (workflow working directory), so the
# default settings path is relative.

rg_setting() { # NAME DEFAULT — resolved value on stdout; nonzero + ::error on
               # a present-but-unparseable assignment (callers must propagate)
  local name="$1" default="$2" line val file
  # Indirect expansion, not eval: a non-literal NAME must never become code.
  # ${!name+x} tests set-ness of the variable NAMED by $name (Bash 3.2-safe).
  if [ -n "${!name+x}" ]; then
    printf '%s' "${!name}"
    return 0
  fi
  file="${REVIEW_GATE_SETTINGS_FILE:-vstack.settings.toml}"
  if [ -f "$file" ]; then
    # Key PRESENCE decides, not value non-emptiness: `NAME = ""` is a real
    # assignment ("empty disables" per the settings docs) and must override the
    # built-in default, exactly like a set-but-empty env var does above.
    if grep -q "^$name[[:space:]]*=" "$file"; then
      line="$(grep "^$name[[:space:]]*=" "$file" | head -n 1)"
      # A PRESENT assignment this parser cannot read (e.g. TOML array syntax
      # for a list key) must fail LOUDLY, never collapse to empty: an empty
      # value can silently widen the gate (empty trusted-logins = any
      # non-author). Only the flat single-line basic-string shape is
      # supported; anything else is a configuration error.
      if ! printf '%s\n' "$line" | grep -q "^$name[[:space:]]*=[[:space:]]*\".*\"[[:space:]]*\$"; then
        echo "::error::$file: unsupported syntax for $name (expected a single-line basic string: $name = \"value\"; list keys pack items with ';' separators)" >&2
        return 1
      fi
      val="$(printf '%s\n' "$line" | sed -n "s/^$name[[:space:]]*=[[:space:]]*\"\(.*\)\"[[:space:]]*\$/\1/p")"
      printf '%s' "$val"
      return 0
    fi
  fi
  printf '%s' "$default"
}
