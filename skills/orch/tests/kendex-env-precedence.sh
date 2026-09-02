#!/usr/bin/env bash
# Regression tests for kendex-env.sh project-config precedence.
#
# Contract (highest to lowest priority):
#   parent-process env > .env.local > .kendex/settings.toml >
#   kendex.settings.toml > default
# A `.env` file is never read. The TOML reader loads the [env] table only;
# a duplicate key inside [env], a value outside the contract grammar
# (single-line double-quoted, no `"`, no `\`), or a `[`-leading line that
# is not a lone [name] header, fails the load.
#
# Bug 2 (kendex#507): the settings loader clobbered caller-provided env. Parent
# values must now win over every project file, while the settings < .env.local
# order is preserved for keys the parent did not set.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

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
# Indented header, indented key, and trailing spaces on both — a shape the
# loader accepts only because it trims every line, and the fixture that
# makes the trim's RESULT load-bearing rather than just its call: lose the
# assignment (a shadowed out-var, a fork) and `  [env]  ` stops reading as
# a header, so the whole table is silently dropped and scenario 1's FOO is
# unset. Written with printf so the trailing runs survive an editor.
printf '  [env]  \n  FOO = "from-settings"  \nBAR = "bar-settings"\n' > "$PROJ/kendex.settings.toml"
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

# Scenario 9: the per-line path forks no subshell. A wrapper delegating to
# the real kendex_trim records two things per call. $BASH_SUBSHELL is the
# direct measure — a fork raises it, and no variable can carry that back
# out of the fork, so each call appends its depth relative to the loader's
# own frame to a file; every recorded depth is 0 or a call ran inside a
# subshell, wherever in the loop the fork was introduced. The call count is
# the second: it is exact, so ONE call site reverted to a command
# substitution is caught by the increment lost with its subshell. Seven for
# a three-line file — every line trimmed, plus the key trim and the
# kendex_decode_value trim for each of the two assignments.
PROJ9="$TMP_ROOT/proj9"
mkdir -p "$PROJ9"
printf '[env]\nK1 = "v1"\nK2 = "v2"\n' > "$PROJ9/kendex.settings.toml"
S9_LEVELS="$TMP_ROOT/s9-subshell-levels"
: > "$S9_LEVELS"
set +e
s9_out=$(
  set -euo pipefail
  source "$LIB"
  trim_body="$(declare -f kendex_trim)"
  eval "_kendex_trim_real${trim_body#kendex_trim}"
  S9_BASE=$BASH_SUBSHELL
  kendex_trim() {
    TRIM_CALLS=$((TRIM_CALLS + 1))
    printf '%s\n' "$((BASH_SUBSHELL - S9_BASE))" >> "$S9_LEVELS"
    _kendex_trim_real "$@"
  }
  TRIM_CALLS=0
  kendex_load_settings_file "$PROJ9/kendex.settings.toml"
  printf '%s|%s|%s\n' "$TRIM_CALLS" "$K1" "$K2"
)
s9_code=$?
set -e
assert_eq "$s9_code" "0" "scenario 9 loads without error"
assert_eq "$s9_out" "7|v1|v2" "scenario 9: every kendex_trim call the loader makes is visible in its own shell, none lost to a command substitution"
assert_eq "$(sort -u "$S9_LEVELS" | paste -sd, -)" "0" "scenario 9: every kendex_trim call runs at the loader's own subshell depth, none inside a fork"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
