#!/usr/bin/env bash
# Tests for kendex-env.sh project-config precedence.
#
# Contract (highest to lowest priority):
#   parent-process env > .env.local > .kendex/settings.toml >
#   kendex.settings.toml > default
# A `.env` file is never read. The TOML reader loads the [env] table only;
# a duplicate key inside [env], a value outside the contract grammar
# (single-line basic with no `"` or `\`, or literal with no apostrophe), or a `[`-leading line that
# is not a lone [name] header, fails the load.
#
# Parent values win over every project file. For other keys, `.env.local` stays
# above both settings files.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$TEST_DIR/.." && pwd)/scripts/lib/kendex-env.sh"
TMP_ROOT="$(mktemp -d)" || { echo "kendex-env-precedence: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "kendex-env-precedence: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "kendex-env-precedence: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
# mutant_scripts and mutate_file, the two halves of the stdout control.
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

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

# Scenario 3: parent GH_ISSUE_PATTERN must survive a conflicting lowercase
# pattern in project settings.
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

# The parent check must not repeat its exported-name walk for each settings key.
# Keep the full load trace; FUNCNAME limits the bound to the parent check.
TRACE_PROJ="$TMP_ROOT/trace-project"
mkdir -p "$TRACE_PROJ/.kendex"
printf '[env]\n' > "$TRACE_PROJ/kendex.settings.toml"
for ((i = 1; i <= 100; i++)); do
  printf 'KENDEX_TRACE_KEY_%s = "root-value"\n' "$i" >> "$TRACE_PROJ/kendex.settings.toml"
done
printf '[env]\nNESTED_PARENT = "nested-file"\nNESTED_FILE = "nested-value"\n' > "$TRACE_PROJ/.kendex/settings.toml"
printf 'PRIVATE_PARENT=private-file\nPRIVATE_FILE=private-value\n' > "$TRACE_PROJ/.env.local"
LINEAR_SCRIPTS="$(mutant_scripts linear-parent-check lib/kendex-env.sh)" || exit 1
mutate_file "$LINEAR_SCRIPTS/lib/kendex-env.sh" \
  '  [[ "${_KENDEX_PARENT_ENV_NAME_SET-}" == *" $1 "* ]]' \
  '  local name="$1" snapshot_name
  for snapshot_name in ${_KENDEX_PARENT_ENV_NAMES[@]+"${_KENDEX_PARENT_ENV_NAMES[@]}"}; do
    [[ "$snapshot_name" == "$name" ]] && return 0
  done
  return 1'

for variant in production base-control; do
  trace_lib="$LIB"
  [[ "$variant" != base-control ]] || trace_lib="$LINEAR_SCRIPTS/lib/kendex-env.sh"
  parent_counts=()
  full_counts=()
  for extra_names in 100 400; do
    trace="$TMP_ROOT/$variant-$extra_names.trace"
    # A fresh environment prevents the first load's exports from entering the next snapshot.
    trace_result=$(env -i PATH="$PATH" "$BASH" --noprofile --norc -c '
      set -euo pipefail
      source "$1"
      export KENDEX_TRACE_KEY_1=parent-root KENDEX_TRACE_KEY_100_SUFFIX=prefix-only
      export NESTED_PARENT=parent-nested PRIVATE_PARENT=parent-private
      for ((i = 1; i <= $3; i++)); do export "KENDEX_EXTRA_$i=extra"; done
      exec 9> "$4"
      BASH_XTRACEFD=9
      PS4="+"'\''${FUNCNAME[0]:-main}: '\''
      # Bash 3.2 has no BASH_XTRACEFD; the same descriptor captures its stderr trace.
      { set -x; kendex_load_project_env "$2"; set +x; } 2>&9
      printf "%s|%s|%s|%s|%s|%s\n" "$KENDEX_TRACE_KEY_1" "$KENDEX_TRACE_KEY_100" \
        "$NESTED_PARENT" "$NESTED_FILE" "$PRIVATE_PARENT" "$PRIVATE_FILE"
    ' kendex-env-trace "$trace_lib" "$TRACE_PROJ" "$extra_names" "$trace")
    assert_eq "$trace_result" "parent-root|root-value|parent-nested|nested-value|parent-private|private-value" \
      "$variant: $extra_names extra exports preserve parent precedence and load unexported keys"
    # macOS awk rejects kendex_bom_guard's backslash-escaped BOM bytes in a UTF-8 locale.
    parent_count=$(LC_ALL=C awk '/^\++kendex_parent_env_has: / { count++ } END { print count+0 }' "$trace")
    full_count=$(wc -l < "$trace")
    assert_le 1 "$parent_count" "$variant: parent check appears in the trace"
    parent_counts+=("$parent_count")
    full_counts+=("$full_count")
  done
  parent_growth=$((parent_counts[1] - parent_counts[0]))
  full_growth=$((full_counts[1] - full_counts[0]))
  printf 'trace: variant=%s added-names=300 parent-lines=%s,%s parent-growth=%s full-lines=%s,%s full-growth=%s\n' \
    "$variant" "${parent_counts[0]}" "${parent_counts[1]}" "$parent_growth" \
    "${full_counts[0]}" "${full_counts[1]}" "$full_growth"
  growth_status=pass
  [[ "$parent_growth" -le "$((4 * 300))" ]] || growth_status=fail
  expected_growth=pass
  if [[ "$variant" == base-control ]]; then
    expected_growth=fail
    assert_le "$((100 * 300))" "$parent_growth" "control: the base name walk exceeds the growth bound"
  fi
  assert_eq "$growth_status" "$expected_growth" "$variant: parent-check growth bound"
done

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
    pass "scenario 6: $name fails the load"
  else
    fail "scenario 6: $name fails the load" "code=$code err=$err"
  fi
}
s6_case "a duplicate key inside [env]" $'[env]\nDUP = "a"\nDUP = "b"' "kendex-env: duplicate-key file=$PROJ6/kendex.settings.toml key=DUP"
# The malformed-file checks run BEFORE the parent-env skip: a parent export
# of the same key must not turn a refused file into a loadable one.
s6_case "a duplicate key the parent also exports" $'[env]\nDUP = "a"\nDUP = "b"' "kendex-env: duplicate-key file=$PROJ6/kendex.settings.toml key=DUP" "DUP=parent-value"
# `seen` spans the whole file, not one section run: re-entering [env]
# through another table is the same ambiguity as two adjacent lines.
s6_case "a duplicate split across re-entered [env] sections" $'[env]\nDUP = "a"\n[other]\nX = "x"\n[env]\nDUP = "b"' "kendex-env: duplicate-key file=$PROJ6/kendex.settings.toml key=DUP"
s6_case "an apostrophe inside a literal value" $'[env]\nSQ = \x27can\x27t\x27' "kendex-env: value-syntax file=$PROJ6/kendex.settings.toml key=SQ"
s6_case "an array value" $'[env]\nARR = ["a", "b"]' "kendex-env: value-syntax file=$PROJ6/kendex.settings.toml key=ARR"
s6_case "a backslash in the value" $'[env]\nBS = "a\\b"' "kendex-env: value-syntax file=$PROJ6/kendex.settings.toml key=BS"
s6_case "an unquoted value" $'[env]\nUNQ = bare' "kendex-env: value-syntax file=$PROJ6/kendex.settings.toml key=UNQ"
# Headers are held to the same fail-loud standard: a `[`-leading line the
# reader cannot parse hides ([env] with a trailing comment) or leaks (a
# quoted foreign header after [env]) whole tables if it passes as content.
s6_case "a commented [env] header" $'[env] # comment\nHIDDEN = "x"' "kendex-env: table-header file=$PROJ6/kendex.settings.toml lineno="
s6_case "a quoted foreign header after [env]" $'[env]\nGOOD = "y"\n["notes"]\nLEAK = "z"' "kendex-env: table-header file=$PROJ6/kendex.settings.toml lineno="
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
    pass "scenario 8: $name fails the load and names the path"
  else
    fail "scenario 8: $name fails the load and names the path" "code=$code stderr: $err"
  fi
}
s8_case "a DIRECTORY at .env.local" 'mkdir .env.local' "kendex-env: not-file arg1=$TMP_ROOT/proj8/.env.local"
s8_case "a DANGLING SYMLINK at kendex.settings.toml" 'ln -s missing.toml kendex.settings.toml' "kendex-env: unresolved-link arg1=$TMP_ROOT/proj8/kendex.settings.toml"
s8_case "a DIRECTORY at .kendex/settings.toml" 'mkdir -p .kendex/settings.toml' "kendex-env: not-file arg1=$TMP_ROOT/proj8/.kendex/settings.toml"
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
  s8_case "an UNREADABLE kendex.settings.toml" 'printf "[env]\nX = \"y\"\n" > kendex.settings.toml && chmod 000 kendex.settings.toml' "kendex-env: unreadable arg1=$TMP_ROOT/proj8/kendex.settings.toml"
fi

# Scenario 9: the per-line path forks no subshell. A wrapper delegating to
# the real kendex_trim records two things per call. $BASH_SUBSHELL is the
# direct measure — a fork raises it, and no variable can carry that back
# out of the fork, so each call appends its depth relative to the loader's
# own frame to a file; every recorded depth is 0 or a call ran inside a
# subshell, wherever in the loop the fork was introduced. The call count is
# the second: it is exact, so ONE call site rewritten as a command
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

# Scenario 10: which private env file the loader reads. .env.local unless
# KENDEX_ENV_FILE names another, and the named path never leaves the
# project — a private env file is SOURCED, so a path the project did not
# mean to name runs somebody else's file in this shell.
#
# The app writes the same key when a person names a private file, so this
# is where the two sides meet: it also pins that a value the app writes,
# single-quoted, comes back out byte for byte.
PROJ10="$TMP_ROOT/proj10"
mkdir -p "$PROJ10"
printf '%s\n' "SECRET='kept-local'" > "$PROJ10/.env.local"
# The second line is exactly what the app writes for a value carrying the
# characters a shell would otherwise act on. Written through %s so this
# file's own printf leaves the backslash alone.
printf '%s\n' "SECRET='kept-chosen'" "LITERAL='a b#c\"d\\e'" > "$PROJ10/.env.secrets"

s10_load() { # SETTINGS_BODY NAME -> the SECRET the loader exports
  (
    unset -v SECRET LITERAL KENDEX_ENV_FILE
    printf '%s' "$1" > "$PROJ10/kendex.settings.toml"
    # shellcheck source=/dev/null
    source "$LIB"
    kendex_load_project_env "$PROJ10" >/dev/null 2>&1 || { echo "REFUSED"; exit 0; }
    printf '%s|%s\n' "${SECRET:-}" "${LITERAL:-}"
  )
}

assert_eq "$(s10_load '')" "kept-local|" "scenario 10: no key names .env.local"
assert_eq \
  "$(s10_load '[env]
KENDEX_ENV_FILE = ".env.secrets"
')" \
  'kept-chosen|a b#c"d\e' \
  "scenario 10: KENDEX_ENV_FILE names the file, and a single-quoted value reads back byte for byte"

# Every spelling that could reach outside the project fails the load loud
# rather than resolving on the default: a source the project did not mean
# to name is one this shell would run.
s10_refuses() { # PATH NAME
  local err code
  set +e
  err=$(
    unset -v KENDEX_ENV_FILE
    printf '[env]\nKENDEX_ENV_FILE = "%s"\n' "$1" > "$PROJ10/kendex.settings.toml"
    # shellcheck source=/dev/null
    source "$LIB"
    kendex_load_project_env "$PROJ10" 2>&1 >/dev/null
  )
  code=$?
  set -e
  if [[ "$code" -ne 0 && "$err" == *"kendex-env: private-env-path arg1=$1"* ]]; then
    pass "scenario 10: $2 fails the load and names the path"
  else
    fail "scenario 10: $2 fails the load and names the path" "code=$code stderr: $err"
  fi
}
s10_refuses "/etc/passwd" "an ABSOLUTE path"
s10_refuses "../outside.env" "a LEADING .. segment"
s10_refuses "a/../../outside.env" "a NESTED .. segment"
s10_refuses "C:keys.env" "a DRIVE COLON"

# Spelling is only half the guarantee. A name with no `..` in it reads a
# file anywhere at all when a directory on the way is a link out of the
# project, and this loader SOURCES what it opens.
s10_link_refuses() { # NAME REASON — plants the shape, then expects the named refusal
  local err code
  set +e
  err=$(
    unset -v KENDEX_ENV_FILE
    printf '[env]\nKENDEX_ENV_FILE = "%s"\n' "$1" > "$PROJ10/kendex.settings.toml"
    # shellcheck source=/dev/null
    source "$LIB"
    kendex_load_project_env "$PROJ10" 2>&1 >/dev/null
  )
  code=$?
  set -e
  if [[ "$code" -ne 0 && "$err" == *"kendex-env: $2 arg1=$1"* ]]; then
    pass "scenario 10: $1 fails the load as $2"
  else
    fail "scenario 10: $1 fails the load as $2" "code=$code stderr: $err"
  fi
}

OUTSIDE10="$TMP_ROOT/outside10"
mkdir -p "$OUTSIDE10"
printf '%s\n' "SECRET='not-this-project'" > "$OUTSIDE10/stolen.env"
ln -s "$OUTSIDE10" "$PROJ10/linked"
s10_link_refuses "linked/stolen.env" "private-env-outside"

# The file ITSELF being a link is the project's own layout and still
# loads: a git worktree links .env.local back to its main checkout so
# every worktree shares one credential file, and refusing that would stop
# every package in every worktree. The line the guard draws is the
# configured NAME reaching out, not the directory's own contents.
printf '%s\n' "SECRET='kept-through-link'" > "$OUTSIDE10/shared.env"
ln -s "$OUTSIDE10/shared.env" "$PROJ10/linked.env"
assert_eq \
  "$(s10_load '[env]
KENDEX_ENV_FILE = "linked.env"
')" \
  'kept-through-link|' \
  "scenario 10: a LINKED private file is the project's own layout and loads"

# A directory inside the project is not a way out, so a nested private
# file still loads: the check refuses an escape, not a subdirectory.
mkdir -p "$PROJ10/keys"
printf '%s\n' "SECRET='kept-nested'" > "$PROJ10/keys/private.env"
assert_eq \
  "$(s10_load '[env]
KENDEX_ENV_FILE = "keys/private.env"
')" \
  'kept-nested|' \
  "scenario 10: a nested private file inside the project still loads"

# A component that exists as a regular file blocks the path: nothing can
# be created under it. Climbing past it would call the path contained and
# then read as absent, so the credential would silently never load.
printf 'X=1\n' > "$PROJ10/blocking"
s10_link_refuses "blocking/private.env" "private-env-blocked"

# The default is held to the same rule, in both directions: a linked
# .env.local loads, and a .env.local reached through a linked directory
# does not. The guard is about the path, never about which of the two
# named the file.
PROJ10B="$TMP_ROOT/proj10b"
mkdir -p "$PROJ10B"
ln -s "$OUTSIDE10/shared.env" "$PROJ10B/.env.local"
s10b_default=$(
  unset -v SECRET KENDEX_ENV_FILE
  # shellcheck source=/dev/null
  source "$LIB"
  kendex_load_project_env "$PROJ10B" >/dev/null 2>&1
  printf '%s\n' "${SECRET:-}"
)
assert_eq "$s10b_default" "kept-through-link" \
  "scenario 10: a LINKED .env.local is the project's own layout and loads"

# A backslash never reaches that check: the settings grammar refuses the
# value first, and refusing it twice would say the grammar was optional.
# Pinned here so the two refusals stay told apart.
set +e
s10_backslash=$(
  unset -v KENDEX_ENV_FILE
  printf '[env]\nKENDEX_ENV_FILE = "keys\\local.env"\n' > "$PROJ10/kendex.settings.toml"
  # shellcheck source=/dev/null
  source "$LIB"
  kendex_load_project_env "$PROJ10" 2>&1 >/dev/null
)
set -e
case "$s10_backslash" in
  *"kendex-env: value-syntax"*"key=KENDEX_ENV_FILE"*)
    pass "scenario 10: a BACKSLASH fails on the value grammar, before the path check" ;;
  *)
    fail "scenario 10: a BACKSLASH fails on the value grammar, before the path check" "stderr: $s10_backslash" ;;
esac

# The caller's environment outranks the project's answer here as it does
# everywhere else: an exported KENDEX_ENV_FILE decides which file loads.
printf '[env]\nKENDEX_ENV_FILE = ".env.secrets"\n' > "$PROJ10/kendex.settings.toml"
s10_parent=$(
  unset -v SECRET
  export KENDEX_ENV_FILE=.env.local
  # shellcheck source=/dev/null
  source "$LIB"
  kendex_load_project_env "$PROJ10" >/dev/null 2>&1
  printf '%s\n' "${SECRET:-}"
)
assert_eq "$s10_parent" "kept-local" "scenario 10: an exported KENDEX_ENV_FILE outranks the project's"

# The install caller needs the path read, even when that file changes the selector.
PROJ_SELECTED="$TMP_ROOT/selected-private"
mkdir -p "$PROJ_SELECTED"
printf '[env]\nKENDEX_ENV_FILE = "selected.env"\n' > "$PROJ_SELECTED/kendex.settings.toml"
printf '%s\n' 'SECRET=selected-secret' 'KENDEX_ENV_FILE=other.env' > "$PROJ_SELECTED/selected.env"
SELECTED_SCRIPTS="$(mutant_scripts selected-path lib/kendex-env.sh)" || exit 1
mutate_file "$SELECTED_SCRIPTS/lib/kendex-env.sh" \
  '    printf -v "$2" '\''%s'\'' "$_kendex_private_file"' \
  '    printf -v "$2" '\''%s'\'' "$KENDEX_ENV_FILE"'
for variant in production mutant; do
  selected_lib="$LIB"
  [[ "$variant" != mutant ]] || selected_lib="$SELECTED_SCRIPTS/lib/kendex-env.sh"
  for form in legacy output-variable; do
    selected_result=$(
      unset SECRET KENDEX_ENV_FILE
      source "$selected_lib"
      kendex_project_env_supports selected-private-path || exit 1
      if kendex_project_env_supports unknown-capability; then exit 1; fi
      selected_path=unchanged
      if [[ "$form" == legacy ]]; then
        kendex_load_project_env "$PROJ_SELECTED"
      else
        kendex_load_project_env "$PROJ_SELECTED" selected_path
      fi
      printf '%s|%s\n' "$SECRET" "$selected_path"
    )
    expected_path=unchanged
    if [[ "$form" == output-variable ]]; then
      expected_path=selected.env
      [[ "$variant" != mutant ]] || expected_path=other.env
    fi
    assert_eq "$selected_result" "selected-secret|$expected_path" "$variant: $form preserves loaded values and reports the path read"
  done
done

# A project can print while its private env file loads. Consumers parse stdout.
PROJ11="$TMP_ROOT/proj11"
mkdir -p "$PROJ11/accounts"
git -C "$PROJ11" init -q
printf '%s\n' 'echo env-file-output' 'KENDEX_STDOUT_TEST=private-value' > "$PROJ11/.env.local"
# The must-fail control: the loader's source left on stdout.
NOISY_SCRIPTS="$(mutant_scripts noisy-loader lib/kendex-env.sh)" || exit 1
mutate_file "$NOISY_SCRIPTS/lib/kendex-env.sh" '  source "$file" >&2' '  source "$file"'

for variant in production mutant; do
  scripts="${LIB%/lib/*}"
  expected_stdout=""
  expected_stderr="env-file-output"
  expected_json="array"
  expected_parse=pass
  expected_value="private-value"
  if [[ "$variant" == mutant ]]; then
    scripts="$NOISY_SCRIPTS"
    expected_stdout="env-file-output"
    expected_stderr=""
    expected_json=""
    expected_parse=fail
    expected_value=$'env-file-output\nprivate-value'
  fi
  (
    unset KENDEX_ENV_FILE KENDEX_STDOUT_TEST CODEX_HOME
    unset ORCH_LANE_DIRS ORCH_LANE_ALIASES ORCH_LANE_EXCLUDE ORCH_LANE_RETIRE
    export LANES_HOME="$PROJ11/accounts" OVERSEE_WATCH_STATE_DIR="$PROJ11/state"
    cd "$PROJ11"
    # shellcheck source=/dev/null
    source "$scripts/lib/kendex-env.sh"
    kendex_load_project_env "$PROJ11" > "$PROJ11/out" 2> "$PROJ11/err"
    "$scripts/orch-env" KENDEX_STDOUT_TEST default > "$PROJ11/value" 2> "$PROJ11/value-err"
    # Finish the writer before jq can reject the mutant's first line.
    "$scripts/lanes" list --json > "$PROJ11/lanes-out" 2> "$PROJ11/lanes-err"
    parse_status=pass
    jq -r type < "$PROJ11/lanes-out" > "$PROJ11/json" 2> "$PROJ11/jq-err" || parse_status=fail
    printf '%s\n' "$parse_status" > "$PROJ11/parse-status"
  )
  assert_eq "$(cat "$PROJ11/out")" "$expected_stdout" "$variant: loader stdout"
  assert_eq "$(cat "$PROJ11/err")" "$expected_stderr" "$variant: loader stderr"
  assert_eq "$(cat "$PROJ11/value")" "$expected_value" "$variant: orch-env returns only its value"
  assert_eq "$(cat "$PROJ11/value-err")" "$expected_stderr" "$variant: orch-env preserves env messages"
  assert_eq "$(cat "$PROJ11/parse-status")" "$expected_parse" "$variant: lanes JSON parse status"
  assert_eq "$(cat "$PROJ11/json")" "$expected_json" "$variant: lanes JSON type"
  assert_eq "$(cat "$PROJ11/lanes-err")" "$expected_stderr" "$variant: lanes preserves env messages"
done

echo
# Prefix probes and physical path checks retain the loader's output and cwd.
PREFIX_SCRIPTS="$(mutant_scripts startup-prefix lib/kendex-env.sh)" || exit 1
mutate_file "$PREFIX_SCRIPTS/lib/kendex-env.sh" \
  '[[ "$_kendex_prefix" == $'\''\xEF\xBB\xBF'\'' ]]' \
  '[[ "$_kendex_prefix" == prefix-control-disabled ]]'
CWD_SCRIPTS="$(mutant_scripts startup-cwd lib/kendex-env.sh)" || exit 1
mutate_file "$CWD_SCRIPTS/lib/kendex-env.sh" \
  '    _kendex_at="$PWD"
    cd -- "$_kendex_cwd" >/dev/null || return 1' \
  '    _kendex_at="$PWD"
    :'

prefix_load() { # LIB PROJECT
  (
    unset KENDEX_ENV_FILE
    source "$1"
    prefix_cwd="$PWD"
    prefix_selected=unset
    prefix_rc=0
    kendex_load_project_env "$2" prefix_selected >"$2/out" 2>"$2/err" || prefix_rc=$?
    prefix_key=""
    IFS= read -r prefix_key <"$2/err" || :
    prefix_position=kept
    [[ "$PWD" == "$prefix_cwd" ]] || prefix_position=moved
    printf '%s|%s|%s|%s\n' "$prefix_rc" "$prefix_key" "$prefix_position" "$prefix_selected"
  )
}

PREFIX_ROWS='empty|kendex.settings.toml|empty|0
short|kendex.settings.toml|short|0
nul|kendex.settings.toml|nul|0
partial-bom|kendex.settings.toml|partial-bom|0
settings|kendex.settings.toml|settings|0
root-bom|kendex.settings.toml|bom|1
nested-bom|.kendex/settings.toml|bom|1
private-bom|.env.local|bom|1
absent|absent|absent|0'
for half in before after; do
  for repeat in 1 2 3 4 5; do
    while IFS='|' read -r prefix_name prefix_file prefix_content prefix_rc; do
      prefix_root="$TMP_ROOT/prefix-$half-$repeat-$prefix_name"
      mkdir -p "$prefix_root/.kendex"
      case "$prefix_content" in
        empty) : >"$prefix_root/$prefix_file" ;;
        short) printf '#' >"$prefix_root/$prefix_file" ;;
        nul) printf '\000\357\273\277# private or shared settings\n' >"$prefix_root/$prefix_file" ;;
        partial-bom) printf '\357\273' >"$prefix_root/$prefix_file" ;;
        settings) printf '[env]\nPREFIX_LOCAL = "loaded"\n' >"$prefix_root/$prefix_file" ;;
        bom) printf '\357\273\277# private or shared settings\n' >"$prefix_root/$prefix_file" ;;
        absent) ;;
      esac
      prefix_expected='0||kept|.env.local'
      [[ "$prefix_rc" != 1 ]] || prefix_expected="1|kendex-env: byte-order-mark arg1=$prefix_root/$prefix_file|kept|unset"
      assert_eq "$(prefix_load "$LIB" "$prefix_root")" "$prefix_expected" \
        "$half control: $prefix_name preserves prefix and cwd behavior ($repeat)"
    done <<<"$PREFIX_ROWS"
  done
  if [[ "$half" == before ]]; then
    prefix_root="$TMP_ROOT/prefix-before-1-root-bom"
    assert_eq "$(prefix_load "$PREFIX_SCRIPTS/lib/kendex-env.sh" "$prefix_root")" '0||kept|.env.local' \
      'control: the prefix rows reject a loader that accepts a byte-order mark'
    prefix_root="$TMP_ROOT/prefix-before-1-absent"
    assert_eq "$(prefix_load "$CWD_SCRIPTS/lib/kendex-env.sh" "$prefix_root")" '0||moved|.env.local' \
      'control: the cwd rows reject a physical path check that leaves the caller directory'
  fi
done

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
