#!/usr/bin/env bash
# Regression tests for kendex-env.sh project-config precedence.
#
# Contract (highest to lowest priority):
#   parent-process env > .env.local > .kendex/settings.toml >
#   kendex.settings.toml > default
# A `.env` file is never read. The TOML reader loads the [env] table only;
# a duplicate key inside [env], a value outside the contract grammar
# (single-line double-quoted, no `"`, no `\`), or a `[`-leading line that
# is not a lone [name] header, fails the load — as does a leading UTF-8
# BOM in any project file.
#
# Bug 2 (kendex#507): the settings loader clobbered caller-provided env. Parent
# values must now win over every project file, while the settings < .env.local
# order is preserved for keys the parent did not set.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$TEST_DIR/.." && pwd)/scripts/lib/kendex-env.sh"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

echo "=== kendex-env precedence ==="

# Shared project root for scenarios 1 and 2. The .env file is a planted
# control: its FOO must never surface, and its QUX must stay unset.
PROJ="$TMP_ROOT/proj"
mkdir -p "$PROJ/.kendex"
printf 'FOO="from-dotenv"\nQUX="only-in-dotenv"\n' > "$PROJ/.env"
cat > "$PROJ/kendex.settings.toml" <<'TOML'
[env]
FOO = "from-settings"
BAR = "bar-settings"
TOML
printf '[env]\nBAR = "bar-nested"\n' > "$PROJ/.kendex/settings.toml"
printf 'BAZ="from-local"\n' > "$PROJ/.env.local"

# Scenario 1: no parent values -> settings apply, .kendex beats the root
# file, .env.local applies, and nothing from .env surfaces.
set +e
s1_out=$(
  set -euo pipefail
  source "$LIB"
  kendex_load_project_env "$PROJ"
  printf '%s|%s|%s|%s\n' "$FOO" "$BAR" "$BAZ" "${QUX-unset}"
)
s1_code=$?
set -e
assert_eq "$s1_code" "0" "scenario 1 loads without error"
assert_eq "$s1_out" "from-settings|bar-nested|from-local|unset" "scenario 1: settings apply, .kendex/settings.toml wins over the root file, .env.local applied, .env ignored"

# Scenario 2: parent FOO exported -> parent wins over the settings files;
# a key the parent did not set (BAR) is still taken from settings.
set +e
s2_out=$(
  set -euo pipefail
  export FOO=from-parent
  source "$LIB"
  kendex_load_project_env "$PROJ"
  printf '%s|%s\n' "$FOO" "$BAR"
)
s2_code=$?
set -e
assert_eq "$s2_code" "0" "scenario 2 loads without error"
assert_eq "$s2_out" "from-parent|bar-nested" "scenario 2: parent env wins over project files; other settings keys still applied"

# Scenario 3: the issue's exact case. Parent GH_ISSUE_PATTERN must survive a
# conflicting lowercase pattern in project settings.
PROJ3="$TMP_ROOT/proj3"
mkdir -p "$PROJ3"
cat > "$PROJ3/kendex.settings.toml" <<'TOML'
[env]
GH_ISSUE_PATTERN = "cc-[0-9]+"
TOML
set +e
s3_out=$(
  set -euo pipefail
  export GH_ISSUE_PATTERN='CC-[0-9]+'
  source "$LIB"
  kendex_load_project_env "$PROJ3"
  printf '%s\n' "$GH_ISSUE_PATTERN"
)
s3_code=$?
set -e
assert_eq "$s3_code" "0" "scenario 3 loads without error"
assert_eq "$s3_out" 'CC-[0-9]+' "scenario 3: parent GH_ISSUE_PATTERN wins over conflicting settings"

# Scenario 4: standalone-call safety. kendex_load_settings_file must work in a
# fresh subshell with no _KENDEX_PARENT_ENV snapshot, without erroring under
# set -u, and still set a fresh key.
STANDALONE="$TMP_ROOT/standalone.toml"
cat > "$STANDALONE" <<'TOML'
[env]
FRESH_KEY = "fresh-val"
TOML
set +e
s4_out=$(
  set -euo pipefail
  source "$LIB"
  kendex_load_settings_file "$STANDALONE"
  printf '%s\n' "$FRESH_KEY"
)
s4_code=$?
set -e
assert_eq "$s4_code" "0" "scenario 4: standalone settings load does not error without a snapshot"
assert_eq "$s4_out" "fresh-val" "scenario 4: standalone settings load sets a fresh key"

# Scenario 5: only the [env] table loads. A top-level assignment and one
# under another table belong to other tools; the trailing comment on a
# loaded value is dropped, and an explicit empty value is a real assignment.
PROJ5="$TMP_ROOT/proj5"
mkdir -p "$PROJ5"
cat > "$PROJ5/kendex.settings.toml" <<'TOML'
TOPLEVEL = "not-config"
[other]
IN_OTHER = "not-config"
[env]
COMMENTED = "kept"   # the comment is not part of the value
EMPTIED = ""
TOML
set +e
s5_out=$(
  set -euo pipefail
  export EMPTIED=parent-had-it
  source "$LIB"
  kendex_load_project_env "$PROJ5"
  printf '%s|%s|%s|%s\n' "${TOPLEVEL-unset}" "${IN_OTHER-unset}" "$COMMENTED" "$EMPTIED"
)
s5_code=$?
set -e
assert_eq "$s5_code" "0" "scenario 5 loads without error"
assert_eq "$s5_out" "unset|unset|kept|parent-had-it" "scenario 5: only [env] loads, comments are stripped, parent set-ness holds"

# Scenario 5b: the same explicit empty value IS the assignment when the
# parent does not set the key — set-but-empty after the load, never unset
# and never a fallthrough to some other layer.
set +e
s5b_out=$(
  set -euo pipefail
  source "$LIB"
  kendex_load_project_env "$PROJ5"
  printf '%s|%s\n' "${EMPTIED+isset}" "${EMPTIED-unset}"
)
s5b_code=$?
set -e
assert_eq "$s5b_code" "0" "scenario 5b loads without error"
assert_eq "$s5b_out" "isset|" "scenario 5b: an explicit empty value is a real set-but-empty assignment when no parent value exists"

# Scenario 6: contract violations fail the load instead of resolving on a
# reinterpreted file. Each shape must exit nonzero with an ::error naming
# the key — a loader that silently skipped or leniently decoded any of them
# turns this scenario red.
PROJ6="$TMP_ROOT/proj6"
mkdir -p "$PROJ6"
s6_case() { # NAME CONTENT EXPECT_SUBSTRING [EXPORT_ASSIGNMENT]
  local name="$1" content="$2" want="$3" exported="${4:-}" code=0 err
  printf '%s\n' "$content" > "$PROJ6/kendex.settings.toml"
  set +e
  err=$(
    set -euo pipefail
    [[ -z "$exported" ]] || export "$exported"
    source "$LIB"
    kendex_load_project_env "$PROJ6" 2>&1 >/dev/null
  )
  code=$?
  set -e
  if [[ "$code" -ne 0 && "$err" == *"$want"* ]]; then
    PASS=$((PASS + 1)); printf '  ok    scenario 6: %s fails the load\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  scenario 6: %s fails the load (code=%s err=%s)\n' "$name" "$code" "$err"
  fi
}
s6_case "a duplicate key inside [env]" $'[env]\nDUP = "a"\nDUP = "b"' "DUP is assigned more than once in [env]"
# The malformed-file checks run BEFORE the parent-env skip: a parent export
# of the same key must not turn a refused file into a loadable one.
s6_case "a duplicate key the parent also exports" $'[env]\nDUP = "a"\nDUP = "b"' "DUP is assigned more than once in [env]" "DUP=parent-value"
# `seen` spans the whole file, not one section run: re-entering [env]
# through another table is the same ambiguity as two adjacent lines.
s6_case "a duplicate split across re-entered [env] sections" $'[env]\nDUP = "a"\n[other]\nX = "x"\n[env]\nDUP = "b"' "DUP is assigned more than once in [env]"
s6_case "a single-quoted value" $'[env]\nSQ = \x27sv\x27' "unsupported syntax for SQ"
s6_case "an array value" $'[env]\nARR = ["a", "b"]' "unsupported syntax for ARR"
s6_case "a backslash in the value" $'[env]\nBS = "a\\b"' "unsupported syntax for BS"
s6_case "an unquoted value" $'[env]\nUNQ = bare' "unsupported syntax for UNQ"
# Headers are held to the same fail-loud standard: a `[`-leading line the
# reader cannot parse hides ([env] with a trailing comment) or leaks (a
# quoted foreign header after [env]) whole tables if it passes as content.
s6_case "a commented [env] header" $'[env] # comment\nHIDDEN = "x"' "unsupported table header shape"
s6_case "a quoted foreign header after [env]" $'[env]\nGOOD = "y"\n["notes"]\nLEAK = "z"' "unsupported table header shape"
# A UTF-8 BOM is neither whitespace nor `[` to this reader: a BOM'd first
# header would leave every assignment outside any table — silent defaults.
s6_case "a BOM-prefixed first header" "$(printf '\357\273\277')"$'[env]\nHIDDEN = "x"' "byte-order mark"

# Scenario 7: a BOM-prefixed .env.local refuses the load the same way. The
# env file is SOURCED, and bash would read the BOM as part of the first
# command name — the assignment it hides would be silently dropped.
PROJ7="$TMP_ROOT/proj7"
mkdir -p "$PROJ7"
printf '\357\273\277BOMMED="x"\n' > "$PROJ7/.env.local"
set +e
s7_err=$(
  set -euo pipefail
  source "$LIB"
  kendex_load_project_env "$PROJ7" 2>&1 >/dev/null
)
s7_code=$?
set -e
assert_eq "$s7_code" "1" "scenario 7: a BOM-prefixed .env.local fails the load"
case "$s7_err" in
  *"byte-order mark"*)
    PASS=$((PASS + 1)); printf '  ok    scenario 7: the refusal names the BOM\n' ;;
  *)
    FAIL=$((FAIL + 1)); printf '  FAIL  scenario 7: the refusal names the BOM\n        stderr: %s\n' "$s7_err" ;;
esac

# Scenario 8: a source is skipped only when ABSENT. A present-but-unusable
# source (directory, dangling symlink, unreadable file) fails the load
# loud, naming the path — silently treating it as absent would let a
# lower-precedence value decide, the same fail-open the rg/gg/sr resolver
# family refuses. The .env.local case carries the same rule one step
# further: that file is SOURCED, and the shell status of that `source` is
# the whole of the guarantee. A single `|| return 0` on it drops the layer
# with nothing said, and only a source whose body RUNS and fails catches it.
s8_case() { # NAME STAGE EXPECT_SUBSTRING — STAGE runs inside the project dir
  local name="$1" stage="$2" want="$3" code=0 err proj="$TMP_ROOT/proj8"
  rm -rf "$proj"
  mkdir -p "$proj"
  ( cd "$proj" && eval "$stage" )
  set +e
  err=$(
    set -euo pipefail
    source "$LIB"
    kendex_load_project_env "$proj" 2>&1 >/dev/null
  )
  code=$?
  set -e
  if [ "$code" -ne 0 ] && case "$err" in *"$want"*) true ;; *) false ;; esac; then
    PASS=$((PASS + 1)); printf '  ok    scenario 8: %s fails the load and names the path\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  scenario 8: %s fails the load and names the path\n        code=%s stderr: %s\n' "$name" "$code" "$err"
  fi
}
s8_case "a DIRECTORY at .env.local" 'mkdir .env.local' ".env.local: source exists but is not a regular file"
s8_case "a DANGLING SYMLINK at kendex.settings.toml" 'ln -s missing.toml kendex.settings.toml' "kendex.settings.toml: source is a symlink that does not resolve"
s8_case "a DIRECTORY at .kendex/settings.toml" 'mkdir -p .kendex/settings.toml' "settings.toml: source exists but is not a regular file"
# A .env.local whose contents RUN and fail: the load must carry that status
# out, never swallow it and resolve on the layers below. The body has to be
# parseable — a syntax error aborts the whole subshell on its own, so it
# reads the same whatever the loader does — and it has to name the file,
# which a bare `false` would not. Unlike the unreadable arm this one needs
# no non-root guard: the command is missing for root too.
s8_case "a FAILING .env.local command" 'printf "no_such_cmd_xyz\n" > .env.local' ".env.local: line "
if [ "$(id -u)" -eq 0 ]; then
  printf '  skip  scenario 8: unreadable-source pin needs a non-root reader (chmod 000 cannot deny root)\n'
else
  s8_case "an UNREADABLE kendex.settings.toml" 'printf "[env]\nX = \"y\"\n" > kendex.settings.toml && chmod 000 kendex.settings.toml' "kendex.settings.toml: source exists but is unreadable"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
