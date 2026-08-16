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
#   3. .vstack/settings.toml, then the repo's committed vstack.settings.toml
#      (sole uncommented `KEY = "value"` assignment; an explicit
#      SIZE_RATCHET_SETTINGS_FILE consults only itself, e.g. /dev/null);
#   4. .env (same shape);
#   5. the built-in default passed by the caller.
#
# The parser reads flat single-line basic-string TOML assignments only —
# exactly the shape vstack.settings.toml [env] blocks use.
#
# Keys are matched FILE-WIDE by exact name, with no TOML-table awareness:
# adopter settings sit under an [env] table, and a table-aware top-level
# parser would resolve none of them. The consequence is a contract: every
# key name read through sr_setting is reserved across the whole file — an
# assignment under an unrelated table would be read as the setting, so
# callers must keep these names unique file-wide. The one detectable
# ambiguity, the same name assigned more than once, fails loud below.
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

sr_setting() { # NAME DEFAULT — resolved value on stdout; nonzero + ::error on
               # a present-but-unparseable assignment (callers must propagate)
  local name="$1" default="$2" line val file
  # The name is interpolated into ERE patterns below; constrain it to the
  # identifier shape every real key has, so a metacharacter can neither
  # misgrep nor inject pattern syntax.
  case "$name" in
    "" | [0-9]* | *[!A-Za-z0-9_]*)
      echo "::error::sr_setting: invalid key name '$name' (shell identifier shape required: [A-Za-z_][A-Za-z0-9_]*)" >&2
      return 1
      ;;
  esac
  # Indirect expansion, not eval: a non-literal NAME must never become code.
  # ${!name+x} tests set-ness of the variable NAMED by $name (Bash 3.2-safe).
  if [ -n "${!name+x}" ]; then
    printf '%s' "${!name}"
    return 0
  fi
  # Env-file overrides (standard project layering: .env.local beats the
  # committed settings, .env is the base) — LAST matching KEY= line wins (shell-sourcing semantics),
  # optional surrounding quotes stripped. Parsed, never sourced.
  if [ -f ".env.local" ]; then
    line="$(grep -E -- "^[[:space:]]*(export[[:space:]]+)?${name}=" .env.local | tail -n 1 || true)"
    if [ -n "$line" ]; then
      if ! val="$(sr_dotenv_value "${line#*=}")"; then
        echo "::error::.env.local: unsupported syntax for $name (a quoted value must end at its closing quote, optionally followed by a comment)" >&2
        return 1
      fi
      printf '%s' "$val"
      return 0
    fi
  fi
  # Nested project settings override the root file (the standard loader
  # order); an explicit SIZE_RATCHET_SETTINGS_FILE consults only itself.
  if [ -n "${SIZE_RATCHET_SETTINGS_FILE+x}" ]; then
    set -- "$SIZE_RATCHET_SETTINGS_FILE"
  else
    set -- ".vstack/settings.toml" "vstack.settings.toml"
  fi
  for file in "$@"; do
  # The fall-back past this file covers an ABSENT PLAIN FILE only. A path
  # that EXISTS as something else — directory, FIFO, socket, device — fails
  # -f exactly like an absent one, so the configured settings would be
  # skipped with nothing said and the built-in default would decide.
  # /dev/null is the documented force-defaults handle and stays exempt.
  if [ "$file" != "/dev/null" ] && [ -e "$file" ] && [ ! -f "$file" ]; then
    echo "::error::$file: settings path exists but is not a regular file (directory, FIFO, socket or device); the fall-back to built-in defaults covers an absent plain file only" >&2
    return 1
  fi
  if [ -f "$file" ]; then
    # Key PRESENCE decides, not value non-emptiness: `NAME = ""` is a real
    # assignment and must override the built-in default, exactly like a
    # set-but-empty env var does above.
    # Leading whitespace before a key is valid TOML, so matching is
    # whitespace-tolerant everywhere (presence, ambiguity guard, extraction)
    # — anchoring at column one made an indented duplicate bypass the
    # fail-loud guard and an indented sole assignment collapse silently to
    # the built-in default (vstack#1059).
    if grep -Eq -- "^[[:space:]]*${name}[[:space:]]*=" "$file"; then
      # File-wide matching (header contract) makes a re-assigned name
      # ambiguous — e.g. the same key under two tables. Silently taking the
      # first could read an unrelated table's value, so ambiguity is a
      # configuration error.
      if [ "$(grep -Ec -- "^[[:space:]]*${name}[[:space:]]*=" "$file")" -gt 1 ]; then
        echo "::error::$file: $name is assigned more than once (keys are matched file-wide regardless of TOML table; each name must be unique in the file)" >&2
        return 1
      fi
      line="$(grep -E -- "^[[:space:]]*${name}[[:space:]]*=" "$file" | head -n 1)"
      # A PRESENT assignment this parser cannot read must fail LOUDLY, never
      # collapse to empty. Only the flat single-line basic-string shape is
      # supported — the value is quote-free ([^"]*), which makes the
      # extraction exact even with a trailing TOML comment (accepted);
      # anything else is a configuration error.
      if ! printf '%s\n' "$line" | grep -Eq -- "^[[:space:]]*${name}[[:space:]]*=[[:space:]]*\"[^\"]*\"[[:space:]]*(#.*)?\$"; then
        echo "::error::$file: unsupported syntax for $name (expected a single-line basic string: $name = \"value\")" >&2
        return 1
      fi
      val="$(printf '%s\n' "$line" | sed -n "s/^[[:space:]]*${name}[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*\$/\1/p")"
      printf '%s' "$val"
      return 0
    fi
  fi
  done
  if [ -f ".env" ]; then
    line="$(grep -E -- "^[[:space:]]*(export[[:space:]]+)?${name}=" .env | tail -n 1 || true)"
    if [ -n "$line" ]; then
      if ! val="$(sr_dotenv_value "${line#*=}")"; then
        echo "::error::.env: unsupported syntax for $name (a quoted value must end at its closing quote, optionally followed by a comment)" >&2
        return 1
      fi
      printf '%s' "$val"
      return 0
    fi
  fi
  printf '%s' "$default"
}
