#!/usr/bin/env bash
# Pins for lib/settings.sh's gg_setting contract: explicit env > .env.local
# > .kendex/settings.toml > kendex.settings.toml > built-in default, with
# `.env` read by nothing, only the [env] table consulted, the contract value
# grammar (single-line double-quoted, no `"`, no `\`) enforced loudly over
# the whole table, a malformed lower source failing under a higher override,
# and a source skipped only when it is ABSENT: a directory, a dangling or
# cyclic symlink, or an unreadable file at a source path is a loud refusal,
# never a silent fall-through to the next layer. One table: a world builds
# the directory, the key resolves under ENVS, and a row pins the exit
# status with the value printed and every error line. The staged-index
# resolution of a tracked source is index-reads.test.sh's and
# commit-msg-settings.test.sh's.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
SETTINGS="$SKILL_DIR/scripts/lib/settings.sh"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"

PASS=0
FAIL=0
assert_eq() { # LABEL EXPECT ACTUAL
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"
  fi
}

# One line for a resolution in the row's world: the exit status, the value
# printed, and every error line joined by ';'. The key and the settings-file
# override are unset first, so only ENVS (comma-separated assignments)
# reach the resolver.
K=COMMIT_GUARDS_TP
R=""
resolve() { # ENVS [KEY]
  local envs=() rc=0 out="" err=""
  [ -z "$1" ] || IFS=',' read -ra envs <<<"$1"
  out="$(cd "$R" && { unset "$K" COMMIT_GUARDS_SETTINGS_FILE 2>/dev/null; env ${envs[@]+"${envs[@]}"} bash -c '
    set -euo pipefail
    source "$0"
    gg_setting "$1" dflt
  ' "$SETTINGS" "${2:-$K}" 2>"$TMP/err"; })" || rc=$?
  # bash names the resolver's own path and line when a redirect inside it is
  # refused; the path and the line number are not the row's to pin.
  err="$(LC_ALL=C sed -e "s#$SETTINGS#<settings.sh>#" -e 's/line [0-9]*:/line N:/' "$TMP/err" | LC_ALL=C paste -sd ';' -)"
  printf 'rc=%s value=%s%s' "$rc" "$out" "${err:+ err=$err}"
}

# World vocabulary: a fresh directory per row, a name used twice refused.
world() { # NAME
  R="$TMP/$1"
  [ ! -e "$R" ] || { echo "harness: world $1 already exists" >&2; exit 2; }
  mkdir -p "$R/.kendex"
}
put() { printf '%b' "$2" >"$R/$1"; } # PATH CONTENT (printf %b)
root() { world "$1"; put kendex.settings.toml '[env]\nCOMMIT_GUARDS_TP = "root"\n'; } # NAME — the root file says root
fx_nested() { root "$1"; put .kendex/settings.toml '[env]\nCOMMIT_GUARDS_TP = "nested"\n'; } # NAME
fx_dotenv() { fx_nested "$1"; put .env.local 'COMMIT_GUARDS_TP=dotenv\n'; } # NAME
fx_dotenv_only() { world dotenv-only; put .env 'COMMIT_GUARDS_TP=from-dotenv\n'; }
toml() { world "$1"; shift; put kendex.settings.toml "$*"; } # NAME CONTENT... — the root file holds CONTENT, the fixture column's words rejoined
fx_backslash() { world backslash; printf '[env]\nCOMMIT_GUARDS_TP = "a\\b"\n' >"$R/kendex.settings.toml"; }
fx_bom() { world bom; printf '\357\273\277[env]\nCOMMIT_GUARDS_TP = "hidden"\n' >"$R/kendex.settings.toml"; }
fx_dir_settings() { root dir-settings; mkdir -p "$R/nonregular.dir"; }
fx_dangling() { root dangling; ln -s missing.toml "$R/dangling.settings.toml"; }
fx_cyclic() { root cyclic; ln -s cycle-b.settings.toml "$R/cycle-a.settings.toml"; ln -s cycle-a.settings.toml "$R/cycle-b.settings.toml"; }
fx_resolving() { root resolving; put link-target.settings.toml '[env]\nCOMMIT_GUARDS_TP = "linked"\n'; ln -s link-target.settings.toml "$R/link.settings.toml"; }
fx_env_dir() { root "$1"; mkdir -p "$R/.env.local"; } # NAME
fx_env_dangling() { root env-dangling; ln -s missing.env "$R/.env.local"; }
dotenv() { root "$1"; shift; put .env.local "$*\n"; } # NAME LINE... — .env.local holds the rejoined words
fx_nested_dup() { root nested-dup; put .kendex/settings.toml '[env]\nCOMMIT_GUARDS_TP = "a"\nCOMMIT_GUARDS_TP = "b"\n'; }
ERR_DUP='::error::.kendex/settings.toml: COMMIT_GUARDS_TP is assigned more than once in [env] (each key must be unique in the table)'
NOT_REGULAR='settings source exists but is not a regular file (directory, FIFO, socket or device); a source is skipped only when it is absent'
NOT_RESOLVING='settings source is a symlink that does not resolve (dangling target, cycle, or over-long chain); a source is skipped only when it is absent'

run_rows() { # label | world | envs | expect
  local row label fx envs expect words
  for row in "$@"; do
    IFS='|' read -r label fx envs expect <<<"$row"
    R=""
    read -ra words <<<"$fx"
    "${words[@]}"
    assert_eq "$label" "$expect" "$(resolve "$envs")"
  done
}

echo "=== the resolution ladder, one layer at a time; .env is read by nothing ==="
run_rows \
  "no source configured: the built-in default answers|world bare||rc=0 value=dflt" \
  "kendex.settings.toml supplies the value|root root||rc=0 value=root" \
  ".kendex/settings.toml beats kendex.settings.toml|fx_nested nested||rc=0 value=nested" \
  ".env.local beats both settings files|fx_dotenv dotenv||rc=0 value=dotenv" \
  "the explicit environment beats every project file|fx_dotenv explicit|COMMIT_GUARDS_TP=explicit|rc=0 value=explicit" \
  "a SET-but-empty environment value still wins: explicitly empty|fx_dotenv explicit-empty|COMMIT_GUARDS_TP=|rc=0 value=" \
  "a .env assignment is read by nothing and the default answers|fx_dotenv_only||rc=0 value=dflt"

echo "=== only the [env] table is read, and it is validated whole ==="
run_rows \
  "an assignment ABOVE the [env] header is ignored|toml above COMMIT_GUARDS_TP = \"top\"\n[env]\nCOMMIT_GUARDS_OTHER = \"x\"\n||rc=0 value=dflt" \
  "an assignment under an UNRELATED table is ignored|toml unrelated-table [notes]\nCOMMIT_GUARDS_TP = \"elsewhere\"\n||rc=0 value=dflt" \
  "control: the same assignment inside [env] resolves|toml in-env [env]\nCOMMIT_GUARDS_TP = \"in-env\"\n||rc=0 value=in-env" \
  "a trailing comment is dropped from the decoded value, a quote inside it included|toml comment [env]\nCOMMIT_GUARDS_TP = \"kept\" # a \"quoted\" comment\n||rc=0 value=kept" \
  "a key assigned twice inside [env] is a config error naming the key, in the nested file under a good root file|fx_nested_dup||rc=1 value= err=$ERR_DUP" \
  "a backslash in the value is a config error, never decoded|fx_backslash||rc=1 value= err=::error::kendex.settings.toml: unsupported syntax for COMMIT_GUARDS_TP (expected a single-line basic string, no double quote and no backslash: COMMIT_GUARDS_TP = \"value\")" \
  "a commented [env] header is a config error naming its line, not an invisible table|toml header [env] # comment\nCOMMIT_GUARDS_TP = \"hidden\"\n||rc=1 value= err=::error::kendex.settings.toml:1: unsupported table header shape (a header is a lone [name] on its own line, with no comment and no second bracket)" \
  "a leading byte-order mark is a config error, not a misread first line|fx_bom||rc=1 value= err=::error::kendex.settings.toml: file starts with a UTF-8 byte-order mark; remove it (the first header or assignment would otherwise be misread)" \
  "an unrelated non-contract assignment fails the read|toml unrelated-bare [env]\nUNRELATED = bare\nCOMMIT_GUARDS_TP = \"v\"\n||rc=1 value= err=::error::kendex.settings.toml: unsupported syntax for UNRELATED (expected a single-line basic string, no double quote and no backslash: UNRELATED = \"value\")" \
  "an unrelated duplicated key fails the read|toml unrelated-dup [env]\nUNRELATED = \"a\"\nUNRELATED = \"b\"\nCOMMIT_GUARDS_TP = \"v\"\n||rc=1 value= err=::error::kendex.settings.toml: UNRELATED is assigned more than once in [env] (each key must be unique in the table)" \
  "an exported value does not mask a malformed settings file|toml masked-dup [env]\nDUP = \"a\"\nDUP = \"b\"\n|COMMIT_GUARDS_TP=explicit|rc=1 value= err=::error::kendex.settings.toml: DUP is assigned more than once in [env] (each key must be unique in the table)" \
  "an exported value does not mask a DIRECTORY at .env.local|fx_env_dir env-dir-masked|COMMIT_GUARDS_TP=explicit|rc=1 value= err=::error::.env.local: $NOT_REGULAR"

echo "=== a source is skipped only when it is ABSENT; the overrides that force defaults ==="
run_rows \
  "a SET-but-EMPTY COMMIT_GUARDS_SETTINGS_FILE is unset and reads the default sources|root empty-override|COMMIT_GUARDS_SETTINGS_FILE=|rc=0 value=root" \
  "COMMIT_GUARDS_SETTINGS_FILE=/dev/null forces the built-in default past every source|fx_dotenv devnull|COMMIT_GUARDS_SETTINGS_FILE=/dev/null|rc=0 value=dflt" \
  "an ABSENT explicit settings file falls back to the built-in default|root absent-explicit|COMMIT_GUARDS_SETTINGS_FILE=absent.settings.toml|rc=0 value=dflt" \
  "a DIRECTORY at the settings path is a config error, not a silent default|fx_dir_settings|COMMIT_GUARDS_SETTINGS_FILE=nonregular.dir|rc=1 value= err=::error::nonregular.dir: $NOT_REGULAR" \
  "a DANGLING symlink at the settings path is a config error|fx_dangling|COMMIT_GUARDS_SETTINGS_FILE=dangling.settings.toml|rc=1 value= err=::error::dangling.settings.toml: $NOT_RESOLVING" \
  "a CYCLIC symlink at the settings path is a config error|fx_cyclic|COMMIT_GUARDS_SETTINGS_FILE=cycle-a.settings.toml|rc=1 value= err=::error::cycle-a.settings.toml: $NOT_RESOLVING" \
  "control: a RESOLVING symlink reads its target|fx_resolving|COMMIT_GUARDS_SETTINGS_FILE=link.settings.toml|rc=0 value=linked" \
  "a DIRECTORY at .env.local is a config error where the settings file would have answered|fx_env_dir env-dir||rc=1 value= err=::error::.env.local: $NOT_REGULAR" \
  "a DANGLING .env.local symlink is a config error, not a silent skip|fx_env_dangling||rc=1 value= err=::error::.env.local: $NOT_RESOLVING" \
  "control: with .env.local absent the settings file answers|root env-absent||rc=0 value=root"

echo "=== the .env.local grammar: last assignment wins, quotes stripped, a comment after the closing quote dropped ==="
run_rows \
  "an export prefix is accepted|dotenv env-export export COMMIT_GUARDS_TP=exported||rc=0 value=exported" \
  "the LAST matching assignment wins|dotenv env-last COMMIT_GUARDS_TP=first\nCOMMIT_GUARDS_TP=last||rc=0 value=last" \
  "double quotes are stripped and a comment after the closing quote dropped|dotenv env-dq COMMIT_GUARDS_TP=\"quoted value\" # comment||rc=0 value=quoted value" \
  "single quotes are stripped|dotenv env-sq COMMIT_GUARDS_TP='single'||rc=0 value=single" \
  "an unquoted value ends at the first whitespace|dotenv env-bare COMMIT_GUARDS_TP=abc def||rc=0 value=abc" \
  "a segment adjacent to the closing quote is a config error naming the key, not a truncated value|dotenv env-adjacent COMMIT_GUARDS_TP=\"abc\"#def||rc=1 value= err=::error::.env.local: unsupported syntax for COMMIT_GUARDS_TP (a quoted value must end at its closing quote, optionally followed by a comment)"
assert_eq "a key that is not a shell identifier is refused before any source is read" "rc=1 value= err=::error::gg_setting: invalid key name 'bad-key' (shell identifier shape required: [A-Za-z_][A-Za-z0-9_]*)" "$(root bad-key; resolve '' bad-key)"

echo "=== an unreadable .env.local fails loud, never falls through ==="
if [ "$(id -u)" -eq 0 ]; then
  printf '  skip  the unreadable-source pins need a non-root reader (chmod 000 cannot deny root)\n'
else
  root unreadable
  put .env.local 'COMMIT_GUARDS_TP=dotenv\n'
  chmod 000 "$R/.env.local"
  assert_eq "an unreadable .env.local is a config error: falling through would have read root" "rc=1 value= err=<settings.sh>: line N: .env.local: Permission denied;::error::.env.local: unreadable while resolving a setting (permission denied)" "$(resolve '')"
  chmod 600 "$R/.env.local"
  assert_eq "control: the same file, readable, supplies its value" "rc=0 value=dotenv" "$(resolve '')"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
