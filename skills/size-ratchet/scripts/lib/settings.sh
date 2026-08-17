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

# A source is skipped only when it is ABSENT. A path that exists as
# something else — directory, FIFO, socket, device — fails -f exactly like
# an absent one, and a symlink that does not resolve fails -e as well as -f,
# so -L is what sees it at all: either shape would skip a configured source
# with nothing said and let a lower-precedence value decide. /dev/null is
# the documented force-defaults handle and stays exempt.
sr_settings_usable() { # PATH — 0 = readable-shaped or absent; 1 + ::error otherwise
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

# In staged mode a TRACKED settings source is read from the INDEX: the commit
# must satisfy its OWN configuration, and an unstaged threshold or path edit
# must not authorize content the commit does not carry. An untracked source
# (a personal .env.local) is the worktree copy, which is all there is.
# SR_SETTINGS_INDEX_DIR holds the materialized copies; the caller owns it.
sr_settings_source() { # FILE — the path to actually read; nonzero + ::error on failure
  local file="$1" copy=""
  if [ "${SR_SETTINGS_FROM_INDEX:-0}" != "1" ] || [ -z "${SR_SETTINGS_INDEX_DIR:-}" ]; then
    printf '%s' "$file"
    return 0
  fi
  if ! git ls-files --error-unmatch -- "$file" >/dev/null 2>&1; then
    if git cat-file -e "HEAD:$file" 2>/dev/null; then
      # Staged for deletion: the commit carries no such source, so it must
      # govern as ABSENT rather than through a recreated worktree copy. A
      # path that cannot exist is how the probes below read "not there".
      printf '%s' "$SR_SETTINGS_INDEX_DIR/settings.absent"
      return 0
    fi
    printf '%s' "$file"
    return 0
  fi
  # A symlink's index blob is its TARGET NAME, not settings content: parsing
  # it would silently resolve every key to its built-in default.
  case "$(git ls-files -s -- "$file" 2>/dev/null | cut -d' ' -f1)" in
    120000)
      echo "::error::$file: tracked as a symlink; staged settings resolution cannot read through it" >&2
      return 1
      ;;
  esac
  # Percent-encode the path into the cache name: '/' and '.' both collapsing
  # to '_' let distinct sources alias one another, and the first one
  # materialized would then answer for the rest. '%' is escaped first, so the
  # mapping is reversible and collision-free.
  copy="$SR_SETTINGS_INDEX_DIR/settings.$(printf '%s' "$file" | sed -e 's/%/%25/g' -e 's|/|%2F|g' -e 's/[.]/%2E/g')"
  if [ ! -f "$copy" ]; then
    if ! git show ":$file" >"$copy" 2>/dev/null; then
      rm -f -- "$copy"
      echo "::error::$file: could not read the staged copy while resolving a setting" >&2
      return 1
    fi
  fi
  printf '%s' "$copy"
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

sr_setting() { # NAME DEFAULT — resolved value on stdout; nonzero + ::error on
               # a present-but-unparseable assignment (callers must propagate)
  local name="$1" default="$2" line val file status matches
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
  local local_env=""
  local_env="$(sr_settings_source ".env.local")" || return 1
  sr_settings_usable "$local_env" || return 1
  if [ -f "$local_env" ]; then
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
  # Nested project settings override the root file (the standard loader
  # order); an explicit SIZE_RATCHET_SETTINGS_FILE consults only itself.
  if [ -n "${SIZE_RATCHET_SETTINGS_FILE+x}" ]; then
    set -- "$SIZE_RATCHET_SETTINGS_FILE"
  else
    set -- ".vstack/settings.toml" "vstack.settings.toml"
  fi
  for file in "$@"; do
  file="$(sr_settings_source "$file")" || return 1
  sr_settings_usable "$file" || return 1
  if [ -f "$file" ]; then
    # Key PRESENCE decides, not value non-emptiness: `NAME = ""` is a real
    # assignment and must override the built-in default, exactly like a
    # set-but-empty env var does above.
    # Leading whitespace before a key is valid TOML, so matching is
    # whitespace-tolerant everywhere (presence, ambiguity guard, extraction)
    # — anchoring at column one made an indented duplicate bypass the
    # fail-loud guard and an indented sole assignment collapse silently to
    # the built-in default (vstack#1059).
    status=0
    matches="$(sr_settings_grep "^[[:space:]]*${name}[[:space:]]*=" "$file")" || status=$?
    [ "$status" -le 1 ] || return 1
    if [ "$status" -eq 0 ]; then
      # File-wide matching (header contract) makes a re-assigned name
      # ambiguous — e.g. the same key under two tables. Silently taking the
      # first could read an unrelated table's value, so ambiguity is a
      # configuration error.
      if [ "$(printf '%s\n' "$matches" | grep -c .)" -gt 1 ]; then
        echo "::error::$file: $name is assigned more than once (keys are matched file-wide regardless of TOML table; each name must be unique in the file)" >&2
        return 1
      fi
      line="$(printf '%s\n' "$matches" | head -n 1)"
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
  local base_env=""
  base_env="$(sr_settings_source ".env")" || return 1
  sr_settings_usable "$base_env" || return 1
  if [ -f "$base_env" ]; then
    status=0
    matches="$(sr_settings_grep "^[[:space:]]*(export[[:space:]]+)?${name}=" "$base_env")" || status=$?
    [ "$status" -le 1 ] || return 1
    line="$(printf '%s\n' "$matches" | tail -n 1)"
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
