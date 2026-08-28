# shellcheck shell=bash
# Settings resolution for the growth-guards check family. Sourced (not
# executed) by every scripts/* check.
#
# Standalone by design: a consumer that installs only growth-guards has no
# review-gate tree to source its settings loader from. This copy's one
# divergence is the index-scoped resolution the hook lanes need.
#
# Resolution order for every key read through gg_setting (the GROWTH_GUARDS_*
# family):
#   1. explicit environment — a SET variable wins even when set to the empty
#      string, so a caller can force "explicitly empty";
#   2. .env.local (KEY=value, quotes optional — parsed, never sourced);
#   3. .kendex/settings.toml, then the repo's committed kendex.settings.toml
#      (the [env] table's sole `KEY = "value"` assignment; an explicit
#      GROWTH_GUARDS_SETTINGS_FILE consults only itself);
#   4. the built-in default passed by the caller.
# A `.env` file is never read.
#
# GROWTH_GUARDS_SETTINGS_FILE=/dev/null is the force-defaults handle and means
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
# into the value: KEY="500" # say "ceiling" assigns 500. Anything else
# after the closing quote (an adjacent segment like KEY="tools/base".tsv)
# is a shape this parser cannot read and fails NONZERO — truncating it
# would silently load the wrong value. Unquoted values end at the first
# whitespace: KEY=500 # ceiling assigns 500.
set -euo pipefail

gg_dotenv_value() { # RAW — value on stdout; nonzero on an unsupported shape
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
# force-defaults handle never reaches here — gg_setting answers it before any
# source is consulted.
gg_settings_usable() { # PATH — 0 = readable-shaped or absent; 1 + ::error otherwise
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
gg_settings_normalize_path() { # PATH — normalized path on stdout ("" when it cancels out)
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

# With GG_SETTINGS_FROM_INDEX=1 a TRACKED settings source is read from the
# INDEX, a source staged for DELETION governs as absent, and an untracked one
# (a personal .env.local) is the worktree copy, which is all there is. A
# tracked SYMLINK fails loud: its index blob is the target name, not settings,
# and parsing that would resolve every key to its built-in default.
# GG_SETTINGS_INDEX_DIR holds the materialized copies; the caller owns it.
gg_settings_source() { # FILE — the path to actually read; nonzero + ::error on failure
  local file="$1" copy="" status=0 entry="" norm="" head_status=0 tree_status=0 tmp=""
  if [ "${GG_SETTINGS_FROM_INDEX:-0}" != "1" ] || [ -z "${GG_SETTINGS_INDEX_DIR:-}" ]; then
    printf '%s' "$file"
    return 0
  fi
  # An ABSOLUTE path is never an index entry, and git refuses such a pathspec
  # with the same 128 an operational failure returns — so it is answered here,
  # before the probes below: the worktree copy is all it ever has.
  case "$file" in
    /*)
      printf '%s' "$file"
      return 0
      ;;
  esac
  # Everything else is judged by what it NORMALIZES to, not by whether it
  # spells a `..`: `sub/../kendex.settings.toml` is the committed settings
  # file, and treating any `..` as an escape read it from the worktree — the
  # unstaged-edit bypass the hook lane exists to close. Only a path that still
  # leaves the repository once normalized (or cancels out to nothing) keeps
  # the worktree copy, and it keeps the ORIGINAL spelling, which is what the
  # caller's own file tests and diagnostics name.
  norm="$(gg_settings_normalize_path "$file")"
  case "$norm" in
    "" | ".." | "../"*)
      printf '%s' "$file"
      return 0
      ;;
  esac
  file="$norm"
  # --error-unmatch reserves exit 1 for the one expected answer, "the index
  # has no such path"; every other nonzero status is a FAILING git, not a
  # measurement. Reading them alike let an operational failure pass for
  # "untracked", which resolved the key from the worktree copy or the
  # built-in default — a committed policy silently swapped for a looser one,
  # admitting a commit its own configuration rejects.
  git ls-files --error-unmatch -- ":(literal)$file" >/dev/null 2>&1 || status=$?
  case "$status" in
    0) ;;
    1)
      # The HEAD probe is classified like the index probe above: cat-file -e
      # exits 128 both for "no such path" and for an operational failure, so
      # a bare probe read a broken git as "never tracked" and let a
      # recreated worktree copy authorize staged content. An unborn HEAD
      # carries nothing by definition (rev-parse reserves exit 1 for it).
      git rev-parse --verify --quiet HEAD >/dev/null 2>&1 || head_status=$?
      case "$head_status" in
        0)
          # ls-tree, never cat-file -e: with rev:path syntax git answers
          # "no such path in HEAD" with the same 128 an operational failure
          # returns, so only ls-tree (exit 0, empty output for an absent
          # path) can tell the two apart.
          entry="$(git ls-tree HEAD -- ":(literal)$file" 2>/dev/null)" || tree_status=$?
          if [ "$tree_status" -ne 0 ]; then
            echo "::error::$file: could not probe HEAD while resolving a setting (git ls-tree exit $tree_status); refusing to treat it as untracked" >&2
            return 1
          fi
          case "${entry:+tracked}" in
            tracked)
              printf '%s' "$GG_SETTINGS_INDEX_DIR/settings.absent"
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
  # `ls-files -s` exits 0 whether or not the path matches, so a nonzero status
  # is a failing invocation and gets the same refusal — an unread mode would
  # let the symlink shape below through to the silent resolve-to-default it
  # exists to prevent.
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
  # Percent-encode the path into the cache name: '/' and '.' both collapsing
  # to '_' let distinct sources alias one another, and the first one
  # materialized would then answer for the rest. '%' is escaped first, so the
  # mapping is reversible and collision-free.
  copy="$GG_SETTINGS_INDEX_DIR/settings.$(printf '%s' "$file" | sed -e 's/%/%25/g' -e 's|/|%2F|g' -e 's/[.]/%2E/g')"
  if [ ! -f "$copy" ]; then
    # Write-then-rename inside the cache directory. A direct redirect onto
    # $copy leaves a TRUNCATED cache behind an interrupt, and the next run
    # reads it as the complete staged copy — resolving keys to wrong or empty
    # values, which for a key naming a check to run means the check runs
    # nowhere while the chain still reports OK.
    tmp="$copy.$$.part"
    if ! git show ":$file" >"$tmp" 2>/dev/null; then
      rm -f -- "$tmp"
      echo "::error::$file: could not read the staged copy while resolving a setting" >&2
      return 1
    fi
    if ! mv -- "$tmp" "$copy"; then
      rm -f -- "$tmp"
      echo "::error::$file: could not materialize the staged copy while resolving a setting" >&2
      return 1
    fi
  fi
  printf '%s' "$copy"
}

# A UTF-8 byte-order mark is neither whitespace nor `[` nor a key character
# to any reader here, so a BOM-prefixed first line silently misfiles the
# header or assignment it hides. Refuse the source whole, same discipline
# as the header rule. Read via stdin so the path is never an operand.
gg_bom_guard() { # FILE — 0 = no leading BOM; 1 + ::error otherwise
  if [ "$(head -c 3 < "$1" 2>/dev/null)" = "$(printf '\357\273\277')" ]; then
    echo "::error::$1: file starts with a UTF-8 byte-order mark; remove it (the first header or assignment would otherwise be misread)" >&2
    return 1
  fi
}

# One read discipline for every settings probe: grep exits 0/1 are
# measurements, anything else is an unreadable source and fails loud —
# falling through to a lower-precedence layer would silently change the
# resolved value.
gg_settings_grep() { # REGEX FILE — matching lines on stdout; 1 = no match
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
# unreadable source and fails loud, same discipline as gg_settings_grep.
gg_env_table() { # FILE — [env]-table lines on stdout; 1 + ::error on a
                 # malformed header or leading BOM; 2 + ::error when unreadable
  local status=0
  gg_bom_guard "$1" || return 1
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

# One dotenv layer (.env.local): the LAST matching KEY= line wins
# (shell-sourcing semantics), optional surrounding quotes stripped. Parsed,
# never sourced. 0 = value on stdout; 1 = this layer assigns nothing;
# 2 = the layer is unusable and resolution must fail loud.
gg_dotenv_layer() { # FILE NAME
  local file="$1" name="$2" src line val matches status=0
  src="$(gg_settings_source "$file")" || return 2
  gg_settings_usable "$src" || return 2
  [ -f "$src" ] || return 1
  gg_bom_guard "$src" || return 2
  matches="$(gg_settings_grep "^[[:space:]]*(export[[:space:]]+)?${name}=" "$src")" || status=$?
  [ "$status" -le 1 ] || return 2
  line="$(printf '%s\n' "$matches" | tail -n 1)"
  [ -n "$line" ] || return 1
  if ! val="$(gg_dotenv_value "${line#*=}")"; then
    echo "::error::$file: unsupported syntax for $name (a quoted value must end at its closing quote, optionally followed by a comment)" >&2
    return 2
  fi
  printf '%s' "$val"
}

gg_setting() { # NAME DEFAULT — resolved value on stdout; nonzero + ::error on
               # a present-but-unparseable assignment (callers must propagate)
  local name="$1" default="$2" line val file table status matches
  # The name is interpolated into ERE patterns below; constrain it to the
  # identifier shape every real key has, so a metacharacter can neither
  # misgrep nor inject pattern syntax.
  case "$name" in
    "" | [0-9]* | *[!A-Za-z0-9_]*)
      echo "::error::gg_setting: invalid key name '$name' (shell identifier shape required: [A-Za-z_][A-Za-z0-9_]*)" >&2
      return 1
      ;;
  esac
  # Every applicable TOML source is validated BEFORE any source answers:
  # kendex-env validates before its parent-env skip, and a malformed
  # committed file must fail identically whatever the session exports or
  # .env.local says — an override must never let a broken file pass
  # silently. The list is the same one extraction walks below: an explicit
  # GROWTH_GUARDS_SETTINGS_FILE consults only itself (set-but-EMPTY is
  # unset: "" names no file), and /dev/null selects no sources at all, so
  # nothing is checked for it.
  if [ "${GROWTH_GUARDS_SETTINGS_FILE:-}" != "/dev/null" ]; then
    if [ -n "${GROWTH_GUARDS_SETTINGS_FILE:-}" ]; then
      set -- "$GROWTH_GUARDS_SETTINGS_FILE"
    else
      set -- ".kendex/settings.toml" "kendex.settings.toml"
    fi
    for file in "$@"; do
      file="$(gg_settings_source "$file")" || return 1
      gg_settings_usable "$file" || return 1
      if [ -f "$file" ]; then
        gg_env_table "$file" >/dev/null || return 1
      fi
    done
  fi
  # Indirect expansion, not eval: a non-literal NAME must never become code.
  # ${!name+x} tests set-ness of the variable NAMED by $name (Bash 3.2-safe).
  if [ -n "${!name+x}" ]; then
    printf '%s' "${!name}"
    return 0
  fi
  # /dev/null is the force-defaults handle: it selects NO settings source at
  # all, so the dotenv layer around the settings files is skipped with it.
  # Skipping only the TOML layer left .env.local still deciding, so a caller
  # asking for built-in defaults got whatever the repository's env file
  # happened to say.
  if [ "${GROWTH_GUARDS_SETTINGS_FILE:-}" = "/dev/null" ]; then
    printf '%s' "$default"
    return 0
  fi
  # Standard project layering: .env.local beats the committed settings.
  status=0
  val="$(gg_dotenv_layer ".env.local" "$name")" || status=$?
  [ "$status" -ne 2 ] || return 1
  if [ "$status" -eq 0 ]; then
    printf '%s' "$val"
    return 0
  fi
  # Nested project settings override the root file (the standard loader
  # order); the positional list was built — and every present file already
  # validated whole — before any source answered, above.
  for file in "$@"; do
  file="$(gg_settings_source "$file")" || return 1
  gg_settings_usable "$file" || return 1
  if [ -f "$file" ]; then
    table="$(gg_env_table "$file")" || return 1
    # Key PRESENCE decides, not value non-emptiness: `NAME = ""` is a real
    # assignment and must override the built-in default, exactly like a
    # set-but-empty env var does above. Leading whitespace before a key is
    # valid TOML, so matching is whitespace-tolerant everywhere — presence,
    # ambiguity guard and extraction alike.
    status=0
    matches="$(printf '%s\n' "$table" | grep -E -- "^[[:space:]]*${name}[[:space:]]*=")" || status=$?
    [ "$status" -le 1 ] || return 1
    if [ "$status" -eq 0 ]; then
      # A re-assigned name is ambiguous — which value wins would be an
      # accident of read order, so ambiguity is a configuration error.
      if [ "$(printf '%s\n' "$matches" | grep -c .)" -gt 1 ]; then
        echo "::error::$file: $name is assigned more than once in [env] (each key must be unique in the table)" >&2
        return 1
      fi
      line="$(printf '%s\n' "$matches" | head -n 1)"
      # A PRESENT assignment this parser cannot read fails LOUDLY, never
      # collapses to empty. Only the contract shape is supported: a
      # quote-free, backslash-free value ([^"\]*) makes the extraction exact
      # even with a trailing TOML comment.
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
