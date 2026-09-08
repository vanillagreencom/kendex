#!/usr/bin/env bash
# Unit pins for lib/settings.sh's rg_setting contract: a value on stdout and
# exit 0, or a `::error` naming the cause and a nonzero exit, never a silent
# fall-through to the caller default. Leading whitespace before a key is
# valid TOML, so matching is whitespace-tolerant everywhere — presence, the
# duplicate-key ambiguity guard, and extraction; column-one anchoring once
# let an indented duplicate bypass the guard on a security-sensitive key and
# made an indented sole assignment collapse to the built-in default.
#
# Three tables, one per way a source reaches the resolver: a file named by
# REVIEW_GATE_SETTINGS_FILE, a path shape at that handle, and the default
# sources layered under a working directory. One run and one assertion per
# row, on the fields the row names.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=../scripts/lib/settings.sh
source "$SKILL_DIR/scripts/lib/settings.sh"

PASS=0
FAIL=0
assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

# write_spec PATH SPEC — materializes one source at a path nothing else
# holds: `-` leaves it absent, `DIR` makes a directory, `DANGLING` a symlink
# to nothing, `UNREADABLE` a file of mode 000, and anything else is the
# file's lines, `;` apart.
write_spec() {
  [[ ! -d "$1" ]] || rmdir "$1"
  rm -f "$1"
  case "$2" in
    -) ;;
    DIR) mkdir "$1" ;;
    DANGLING) ln -s missing.target "$1" ;;
    UNREADABLE) printf '[env]\nREVIEW_GATE_TN = "configured"\n' >"$1"; chmod 000 "$1" ;;
    *) printf '%s\n' "$2" | tr ';' '\n' >"$1" ;;
  esac
}

# resolve DIR FILE ENV NAME DEFAULT — one rg_setting call: from DIR, with
# REVIEW_GATE_SETTINGS_FILE set to FILE (`unset` leaves it unset), the key
# unset unless ENV assigns it (`NAME=value`). Hermetic: rg_setting resolves
# a set variable before any file, so a leaked variable from the invoking
# shell would mask every file-parsing row. OUT is stdout, ERR stderr, RC the
# exit status.
resolve() {
  local dir="$1" file="$2" env="$3" name="$4" default="$5"
  OUT=""; ERR=""; RC=0
  OUT="$(cd "$dir" && {
    unset "$name" REVIEW_GATE_SETTINGS_FILE 2>/dev/null
    [[ "$file" == unset ]] || export REVIEW_GATE_SETTINGS_FILE="$file"
    [[ -z "$env" ]] || export "${env?}"
    rg_setting "$name" "$default" 2>"$TMP/err"
  })" || RC=$?
  ERR="$(cat "$TMP/err")"
}

# observe EXPECT — the run's value of every field EXPECT names, in order:
#   rc       exit status
#   out      the resolved value, `+` for a space, `-` for empty; a value the
#            encoding cannot tell apart (one carrying `+`, or a literal `-`)
#            renders as UNENCODABLE rather than as its collision
#   err~<t>  whether stderr names <t>, `+` read as a space: the one phrase
#            that tells this refusal from its neighbours, since every refusal
#            exits 1
observe() {
  local got="" token name value needle
  # $1 is split on whitespace into fields; pathname expansion must not also
  # rewrite a token, so a bracket in an err~ phrase can never match a file in
  # the caller's working directory. The call sites are command substitutions,
  # so this stays inside the subshell.
  set -f
  for token in $1; do
    name="${token%%=*}"
    case "$name" in
      rc) value="$RC" ;;
      out)
        case "$OUT" in
          *+*|-) value="UNENCODABLE($OUT)" ;;
          *) value="${OUT// /+}"; value="${value:--}" ;;
        esac ;;
      err~*)
        needle="${name#err~}"; needle="${needle//+/ }"
        value="$(grep -qF -- "$needle" <<<"$ERR" && echo true || echo false)" ;;
      *) value=UNKNOWN_FIELD ;;
    esac
    got="$got $name=$value"
  done
  printf '%s' "${got# }"
}

echo "=== a file named by REVIEW_GATE_SETTINGS_FILE ==="
# `label|lines|name|default|env|expect`: the lines land in a fresh settings
# file the handle names. The name reaches indirect expansion and is
# interpolated into ERE and sed patterns, so the identifier-shape rejection
# is what stands between a metacharacter name and pattern injection. Values
# are single-line basic strings with no double quote and no backslash, a
# trailing comment accepted; a backslash cannot mean an escape in one reader
# and a literal in another, so it is refused. The whole [env] table is
# validated, not only the requested key, and an exported value never masks a
# malformed file: kendex-env refuses the same files before its parent-env
# skip, so a per-key extractor would split the family contract.
file_table() {
  local row label lines name default env expect before=$((PASS + FAIL))
  for row in "$@"; do
    IFS='|' read -r label lines name default env expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'file_table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    write_spec "$TMP/settings.toml" "$lines"
    resolve "$TMP" "$TMP/settings.toml" "$env" "$name" "$default"
    assert_eq "$(observe "$expect")" "$expect" "$label"
  done
  [[ "$((PASS + FAIL))" -gt "$before" ]] || { echo "file_table: no row was asserted" >&2; exit 2; }
}
file_table \
  'a column-one assignment reads|[env];REVIEW_GATE_T1 = "col1"|REVIEW_GATE_T1|dflt||rc=0 out=col1' \
  'an indented sole assignment reads, not the silent default|[env];  REVIEW_GATE_T2 = "indented"|REVIEW_GATE_T2|dflt||rc=0 out=indented' \
  'an explicit empty assignment overrides the default (empty disables)|[env];REVIEW_GATE_T3 = ""|REVIEW_GATE_T3|dflt||rc=0 out=-' \
  'an explicit environment variable wins over the file|[env];REVIEW_GATE_T4 = "file"|REVIEW_GATE_T4|dflt|REVIEW_GATE_T4=env|rc=0 out=env' \
  'a column-one duplicate is a config error|[env];REVIEW_GATE_T5 = "a";REVIEW_GATE_T5 = "b"|REVIEW_GATE_T5|dflt||rc=1 out=- err~assigned+more+than+once=true' \
  'an INDENTED duplicate is a config error, not invisible to the guard|[env];REVIEW_GATE_T6 = "a";  REVIEW_GATE_T6 = "b"|REVIEW_GATE_T6|dflt||rc=1 out=- err~assigned+more+than+once=true' \
  'two indented duplicates are a config error|[env];  REVIEW_GATE_T7 = "a";  REVIEW_GATE_T7 = "b"|REVIEW_GATE_T7|dflt||rc=1 out=- err~assigned+more+than+once=true' \
  'array syntax is a config error|[env];REVIEW_GATE_T8 = ["array"]|REVIEW_GATE_T8|dflt||rc=1 out=- err~unsupported+syntax=true' \
  'indented array syntax is a config error, not a silent default|[env];  REVIEW_GATE_T9 = ["array"]|REVIEW_GATE_T9|dflt||rc=1 out=- err~unsupported+syntax=true' \
  'a leading-digit name is refused|[env];REVIEW_GATE_OK = "x"|9BADNAME|dflt||rc=1 out=- err~invalid+key+name=true' \
  'a regex-metacharacter name is refused before any interpolation|[env];REVIEW_GATE_OK = "x"|REVIEW_GATE.DOT|dflt||rc=1 out=- err~invalid+key+name=true' \
  'an underscore-prefixed name stays valid|[env];_REVIEW_GATE_U = "u1"|_REVIEW_GATE_U|dflt||rc=0 out=u1' \
  'an assignment ABOVE the [env] header is ignored|REVIEW_GATE_TT = "top";[env];REVIEW_GATE_OTHER = "x"|REVIEW_GATE_TT|dflt||rc=0 out=dflt' \
  'an assignment under an UNRELATED table is ignored|[notes];REVIEW_GATE_TT = "elsewhere"|REVIEW_GATE_TT|dflt||rc=0 out=dflt' \
  'a duplicate across re-entered [env] sections is a config error|[env];REVIEW_GATE_TT = "a";[notes];x = "y";[env];REVIEW_GATE_TT = "b"|REVIEW_GATE_TT|dflt||rc=1 out=- err~assigned+more+than+once+in+[env]=true' \
  'a trailing comment is dropped from the decoded value|[env];REVIEW_GATE_TC = "spaced value" # trailing comment|REVIEW_GATE_TC|dflt||rc=0 out=spaced+value' \
  'a backslash in the value is a config error, never decoded|[env];REVIEW_GATE_TB = "a\b"|REVIEW_GATE_TB|dflt||rc=1 out=- err~unsupported+syntax=true' \
  'a commented [env] header is a config error, not an invisible table|[env] # comment;REVIEW_GATE_TH = "hidden"|REVIEW_GATE_TH|dflt||rc=1 out=- err~unsupported+table+header+shape=true' \
  'a quoted foreign header after [env] is a config error, not a leaked key|[env];x = "y";["notes"];REVIEW_GATE_TH = "leak"|REVIEW_GATE_TH|dflt||rc=1 out=- err~unsupported+table+header+shape=true' \
  'an unrelated non-contract assignment fails the read|[env];UNRELATED = bare;REVIEW_GATE_TW = "v"|REVIEW_GATE_TW|dflt||rc=1 out=- err~unsupported+syntax+for+UNRELATED=true' \
  'an unrelated duplicated key fails the read|[env];UNRELATED = "a";UNRELATED = "b";REVIEW_GATE_TW = "v"|REVIEW_GATE_TW|dflt||rc=1 out=- err~UNRELATED+is+assigned+more+than+once=true' \
  'an unrelated backslash value fails the read|[env];UNRELATED = "a\b";REVIEW_GATE_TW = "v"|REVIEW_GATE_TW|dflt||rc=1 out=- err~unsupported+syntax+for+UNRELATED=true' \
  'an exported value does not mask a malformed settings file|[env];DUP = "a";DUP = "b"|REVIEW_GATE_TV|dflt|REVIEW_GATE_TV=envwin|rc=1 out=- err~assigned+more+than+once=true'

echo "=== the shape at the settings-file handle ==="
# `label|path|env|expect`, resolving REVIEW_GATE_TN from $TMP with the handle
# set to PATH. A directory fails -f like an absent file and a dangling or
# cyclic symlink fails -e as well, so an existence test alone would resolve
# every key to its caller default with nothing said; an existing non-regular
# or unreadable source is a config error naming the file, and only an ABSENT
# plain file or the /dev/null sentinel falls to the default. A relative path
# that starts with a dash or carries `=` is a file operand, never a grep
# option or an awk assignment.
mkdir -p "$TMP/nonregular.dir"
ln -s missing.toml "$TMP/dangling.settings.toml"
ln -s cycle-b.settings.toml "$TMP/cycle-a.settings.toml"
ln -s cycle-a.settings.toml "$TMP/cycle-b.settings.toml"
printf '[env]\nREVIEW_GATE_TN = "linked"\n' >"$TMP/link-target.settings.toml"
ln -s link-target.settings.toml "$TMP/link.settings.toml"
printf '[env]\nREVIEW_GATE_TN = "dashfile"\n' >"$TMP/-e"
printf '[env]\nREVIEW_GATE_TN = "eqfile"\n' >"$TMP/policy=on.toml"
write_spec "$TMP/unreadable.settings.toml" UNREADABLE
path_table() {
  local row label path env expect before=$((PASS + FAIL))
  for row in "$@"; do
    IFS='|' read -r label path env expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'path_table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    resolve "$TMP" "$path" "$env" REVIEW_GATE_TN dflt
    assert_eq "$(observe "$expect")" "$expect" "$label"
  done
  [[ "$((PASS + FAIL))" -gt "$before" ]] || { echo "path_table: no row was asserted" >&2; exit 2; }
}
path_table \
  "a DIRECTORY settings path is a config error, not a silent default|$TMP/nonregular.dir||rc=1 out=- err~not+a+regular+file=true" \
  "a DANGLING symlink settings path is a config error, not a silent default|$TMP/dangling.settings.toml||rc=1 out=- err~does+not+resolve=true" \
  "a CYCLIC symlink settings path is a config error, not a silent default|$TMP/cycle-a.settings.toml||rc=1 out=- err~does+not+resolve=true" \
  "a RESOLVING symlink reads its target|$TMP/link.settings.toml||rc=0 out=linked" \
  "/dev/null forces the built-in default|/dev/null||rc=0 out=dflt" \
  "an ABSENT plain file falls back to the default|$TMP/absent.settings.toml||rc=0 out=dflt" \
  "a dash-prefixed relative path reads its value (no option-injection fallback)|-e||rc=0 out=dashfile" \
  "an =-containing relative path reads its value (no awk-assignment fallback)|policy=on.toml||rc=0 out=eqfile"
if [ "$(id -u)" -eq 0 ]; then
  echo "  skip  unreadable-source rows need a non-root reader (chmod 000 cannot deny root)"
else
  # grep exits 0/1 are measurements; anything else means the source could
  # not be read. -f and -e both pass on a mode-000 file, so only the read
  # itself sees it, and falling back would resolve every key to its caller
  # default (an empty trusted-logins default widens the gate).
  RC=0
  rg_settings_grep "^REVIEW_GATE_TN" "$TMP/unreadable.settings.toml" >/dev/null 2>"$TMP/err" || RC=$?
  ERR="$(cat "$TMP/err")"
  assert_eq "$(observe "rc err~unreadable+while+resolving+a+setting")" "rc=2 err~unreadable+while+resolving+a+setting=true" "the read discipline reports 2 for an unreadable source, never 1 (no match)"
  path_table \
    "an UNREADABLE settings path is a config error naming the file, not a silent default|$TMP/unreadable.settings.toml||rc=1 out=- err~unreadable.settings.toml:+unreadable+while+resolving+a+setting=true"
  chmod 600 "$TMP/unreadable.settings.toml"
  path_table \
    "the same file, readable, resolves its value|$TMP/unreadable.settings.toml||rc=0 out=configured"
fi

echo "=== the default sources under a working directory ==="
# `label|root|nested|dotenv|file|name|default|env|expect`: kendex.settings.toml,
# .kendex/settings.toml and .env.local as specs in a fresh directory, with
# the handle FILE (`unset`, `/dev/null`, or `empty` for set-but-empty).
# The layering is .env.local > .kendex/settings.toml > kendex.settings.toml
# > default — except REVIEW_GATE_MODE, which reads only the environment and
# the COMMITTED kendex.settings.toml, so the local waiter and the CI gate
# (whose checkout has neither .env.local nor .kendex/) resolve the switch
# identically; a broken machine-local layer it never reads must not fail
# it. The /dev/null sentinel selects no source at all and loses only to an
# explicit environment variable; set-but-empty names no file and reads the
# default sources. The dotenv layer reads every supported shape, a quoted
# value ends at its FIRST closing delimiter, a trailing comment is dropped,
# and a shape the parser cannot read fails nonzero rather than truncating an
# adjacent segment into an unintended value; an unusable .env.local is a
# config error, never a skipped layer, even under an exported value.
WORLD_N=0
world_table() {
  local row label root nested dotenv file name default env expect dir before=$((PASS + FAIL))
  for row in "$@"; do
    IFS='|' read -r label root nested dotenv file name default env expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'world_table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    dir="$TMP/world.$((++WORLD_N))"
    mkdir -p "$dir/.kendex"
    write_spec "$dir/kendex.settings.toml" "$root"
    write_spec "$dir/.kendex/settings.toml" "$nested"
    write_spec "$dir/.env.local" "$dotenv"
    [[ "$file" != empty ]] || file=""
    resolve "$dir" "$file" "$env" "$name" "$default"
    assert_eq "$(observe "$expect")" "$expect" "$label"
  done
  [[ "$((PASS + FAIL))" -gt "$before" ]] || { echo "world_table: no row was asserted" >&2; exit 2; }
}
ROOT='[env];REVIEW_GATE_TP = "root";REVIEW_GATE_MODE = "off"'
world_table \
  'without the sentinel the settings file at the default path supplies the value|[env];REVIEW_GATE_TS = "fromfile"|-|-|unset|REVIEW_GATE_TS|dflt||rc=0 out=fromfile' \
  'the sentinel skips a populated settings file and the built-in default decides|[env];REVIEW_GATE_TS = "fromfile"|-|-|/dev/null|REVIEW_GATE_TS|dflt||rc=0 out=dflt' \
  'an explicit environment variable still wins over the sentinel|[env];REVIEW_GATE_TS = "fromfile"|-|-|/dev/null|REVIEW_GATE_TS|dflt|REVIEW_GATE_TS=fromenv|rc=0 out=fromenv' \
  'the sentinel skips a populated .env.local as well, the dotenv layer included|[env];REVIEW_GATE_TS = "fromfile"|-|REVIEW_GATE_TS=dotenv|/dev/null|REVIEW_GATE_TS|dflt||rc=0 out=dflt' \
  'a SET-but-EMPTY handle reads the default sources|[env];REVIEW_GATE_TE = "fromrepo"|-|-|empty|REVIEW_GATE_TE|dflt||rc=0 out=fromrepo' \
  "the root settings file supplies the value|$ROOT|-|-|unset|REVIEW_GATE_TP|dflt||rc=0 out=root" \
  ".kendex/settings.toml beats kendex.settings.toml|$ROOT|[env];REVIEW_GATE_TP = \"nested\"|-|unset|REVIEW_GATE_TP|dflt||rc=0 out=nested" \
  ".env.local beats both settings files|$ROOT|[env];REVIEW_GATE_TP = \"nested\"|REVIEW_GATE_TP=dotenv;REVIEW_GATE_MODE=enforce|unset|REVIEW_GATE_TP|dflt||rc=0 out=dotenv" \
  "REVIEW_GATE_MODE ignores .env.local and reads the settings file|$ROOT|[env];REVIEW_GATE_TP = \"nested\"|REVIEW_GATE_TP=dotenv;REVIEW_GATE_MODE=enforce|unset|REVIEW_GATE_MODE|enforce||rc=0 out=off" \
  'REVIEW_GATE_MODE ignores the machine-local .kendex/settings.toml|[env];REVIEW_GATE_TP = "root"|[env];REVIEW_GATE_MODE = "off"|REVIEW_GATE_TP=dotenv;REVIEW_GATE_MODE=enforce|unset|REVIEW_GATE_MODE|enforce||rc=0 out=enforce' \
  'REVIEW_GATE_MODE falls to the default over a dotenv-only value|[env];REVIEW_GATE_TP = "root"|-|REVIEW_GATE_TP=dotenv;REVIEW_GATE_MODE=off|unset|REVIEW_GATE_MODE|enforce||rc=0 out=enforce' \
  'a double-quoted dotenv value with a trailing comment extracts the content|[env];REVIEW_GATE_TP = "root"|-|REVIEW_GATE_TD="spaced value" # note|unset|REVIEW_GATE_TD|dflt||rc=0 out=spaced+value' \
  'a quote inside the trailing comment never leaks into the value|[env];REVIEW_GATE_TP = "root"|-|REVIEW_GATE_TD="900" # say "quiet"|unset|REVIEW_GATE_TD|dflt||rc=0 out=900' \
  'an export-form dotenv assignment is recognized|[env];REVIEW_GATE_TP = "root"|-|export REVIEW_GATE_TD=42|unset|REVIEW_GATE_TD|dflt||rc=0 out=42' \
  "a single-quoted dotenv value with a trailing comment extracts the content|[env];REVIEW_GATE_TP = \"root\"|-|REVIEW_GATE_TD='19' # note|unset|REVIEW_GATE_TD|dflt||rc=0 out=19" \
  "an apostrophe in the trailing comment never leaks into a single-quoted value|[env];REVIEW_GATE_TP = \"root\"|-|REVIEW_GATE_TD='29' # don't raise|unset|REVIEW_GATE_TD|dflt||rc=0 out=29" \
  'an adjacent segment after a quoted value fails loud, never truncates|[env];REVIEW_GATE_TP = "root"|-|REVIEW_GATE_TD="17".5|unset|REVIEW_GATE_TD|dflt||rc=1 out=- err~unsupported+syntax=true' \
  'an adjacent # after a quoted value is a segment, not a comment: fails loud|[env];REVIEW_GATE_TP = "root"|-|REVIEW_GATE_TD="17"#note|unset|REVIEW_GATE_TD|dflt||rc=1 out=- err~unsupported+syntax=true' \
  'a DIRECTORY at .env.local is a config error, not a skipped layer|[env];REVIEW_GATE_TP = "root"|-|DIR|unset|REVIEW_GATE_TD|dflt||rc=1 out=- err~not+a+regular+file=true' \
  'a DANGLING symlink at .env.local is a config error, not a skipped layer|[env];REVIEW_GATE_TP = "root"|-|DANGLING|unset|REVIEW_GATE_TD|dflt||rc=1 out=- err~does+not+resolve=true' \
  'a .env.local hit does not mask a malformed settings file|[env];DUP = "a";DUP = "b"|-|REVIEW_GATE_TV="local"|unset|REVIEW_GATE_TV|dflt||rc=1 out=- err~assigned+more+than+once=true' \
  'an exported value does not mask a DIRECTORY at .env.local|[env];REVIEW_GATE_TP = "root"|-|DIR|unset|REVIEW_GATE_TV|dflt|REVIEW_GATE_TV=envwin|rc=1 out=- err~not+a+regular+file=true' \
  'REVIEW_GATE_MODE resolves past a broken .env.local it never reads|[env];REVIEW_GATE_MODE = "off"|-|DIR|unset|REVIEW_GATE_MODE|enforce||rc=0 out=off'
if [ "$(id -u)" -eq 0 ]; then
  echo "  skip  unreadable-.env.local row needs a non-root reader (chmod 000 cannot deny root)"
else
  world_table \
    'an UNREADABLE .env.local is a config error, not a skipped layer|[env];REVIEW_GATE_TP = "root"|-|UNREADABLE|unset|REVIEW_GATE_TD|dflt||rc=1 out=- err~unreadable+while+resolving+a+setting=true'
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
