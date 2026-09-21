#!/usr/bin/env bash
# Tests for the orch-env effective-setting reader.
#
# orch-env VAR_NAME DEFAULT prints the effective value of a kendex [env]
# setting with the standard precedence (process env > kendex.settings.toml
# [env] > supplied default). With a numeric default, a non-numeric effective
# value falls back to the default so workflow cycle bounds always get a
# usable number. Workflows use it to read CI_FIX_MAX_CYCLES (default 6).
#
# It also applies the ORCH_USER_MODE composition: under `ceo`, a composed
# autonomy key the ladder leaves unset resolves to its unattended value rather
# than to the caller's default. ../references/communication-modes.md § Composition
# is the table; this suite pins the script that applies it.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

ORCH_ENV="$REPO_ROOT/skills/orch/scripts/orch-env"

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

echo "=== orch-env effective-setting reader ==="

# Isolated project roots: orch-env resolves the project from the cwd's git
# toplevel, so each scenario gets its own repo with no kendex settings noise.
proj_bare="$TMP_ROOT/proj-bare"
git init -q "$proj_bare"

proj_settings="$TMP_ROOT/proj-settings"
git init -q "$proj_settings"
cat > "$proj_settings/kendex.settings.toml" <<'TOML'
[env]
CI_FIX_MAX_CYCLES = "4"
TOML

proj_bad="$TMP_ROOT/proj-bad"
git init -q "$proj_bad"
cat > "$proj_bad/kendex.settings.toml" <<'TOML'
[env]
CI_FIX_MAX_CYCLES = "many"
TOML

# Test 1: nothing set anywhere -> the supplied default.
got="$(cd "$proj_bare" && env -u CI_FIX_MAX_CYCLES "$ORCH_ENV" CI_FIX_MAX_CYCLES 6)"
assert_eq "$got" "6" "prints the supplied default when the setting is unset"

# Test 2: kendex.settings.toml [env] value wins over the default.
got="$(cd "$proj_settings" && env -u CI_FIX_MAX_CYCLES "$ORCH_ENV" CI_FIX_MAX_CYCLES 6)"
assert_eq "$got" "4" "settings-file value overrides the default"

# Test 3: process env wins over the settings file.
got="$(cd "$proj_settings" && CI_FIX_MAX_CYCLES=9 "$ORCH_ENV" CI_FIX_MAX_CYCLES 6)"
assert_eq "$got" "9" "process env overrides the settings-file value"

# Test 4: non-numeric settings value with a numeric default -> default.
got="$(cd "$proj_bad" && env -u CI_FIX_MAX_CYCLES "$ORCH_ENV" CI_FIX_MAX_CYCLES 6)"
assert_eq "$got" "6" "non-numeric settings value falls back to the numeric default"

# Test 5: non-numeric env override with a numeric default -> default.
got="$(cd "$proj_bare" && CI_FIX_MAX_CYCLES=abc "$ORCH_ENV" CI_FIX_MAX_CYCLES 6)"
assert_eq "$got" "6" "non-numeric env value falls back to the numeric default"

# Test 6: non-numeric defaults pass any value through unchanged.
got="$(cd "$proj_bad" && env -u CI_FIX_MAX_CYCLES "$ORCH_ENV" CI_FIX_MAX_CYCLES auto)"
assert_eq "$got" "many" "non-numeric default does not enforce numeric values"

# Test 7: usage errors exit 2.
set +e
(cd "$proj_bare" && "$ORCH_ENV" CI_FIX_MAX_CYCLES >/dev/null 2>"$TMP_ROOT/args.err")
missing_arg_code=$?
(cd "$proj_bare" && "$ORCH_ENV" 'bad-name!' 6 >/dev/null 2>"$TMP_ROOT/name.err")
bad_name_code=$?
set -e
assert_eq "$missing_arg_code" "2" "missing DEFAULT argument exits 2"
assert_eq "$bad_name_code" "2" "invalid variable name exits 2"
assert_eq "$(sed -n '1p' "$TMP_ROOT/args.err")" "orch-env: argument-count count=1" "missing operand identifies the count"
assert_eq "$(sed -n '1p' "$TMP_ROOT/name.err")" "orch-env: invalid-name name=bad-name!" "invalid variable identifies the name"

# --- ORCH_USER_MODE composition --------------------------------------------
#
# Each row runs with the composed key and the mode cleared from the process
# environment, so only the project's settings file and the script's own mapping
# can answer.

proj_mode="$TMP_ROOT/proj-mode"
git init -q "$proj_mode"
printf '[env]\n' > "$proj_mode/kendex.settings.toml"

proj_override="$TMP_ROOT/proj-override"
git init -q "$proj_override"
cat > "$proj_override/kendex.settings.toml" <<'TOML'
[env]
ORCH_USER_MODE = "ceo"
ORCH_MERGE_AUTONOMY = "ask"
TOML

proj_engineer="$TMP_ROOT/proj-engineer"
git init -q "$proj_engineer"
cat > "$proj_engineer/kendex.settings.toml" <<'TOML'
[env]
ORCH_USER_MODE = "engineer"
TOML

# Test 8: the package default mode composes each autonomy key.
got="$(cd "$proj_mode" && env -u ORCH_USER_MODE -u ORCH_DECISION_MODE "$ORCH_ENV" ORCH_DECISION_MODE ask)"
assert_eq "$got" "auto-recommended" "ceo composes the decision mode over the caller default"
got="$(cd "$proj_mode" && env -u ORCH_USER_MODE -u ORCH_MERGE_AUTONOMY "$ORCH_ENV" ORCH_MERGE_AUTONOMY ask)"
assert_eq "$got" "auto" "ceo composes merge autonomy over the caller default"
got="$(cd "$proj_mode" && env -u ORCH_USER_MODE -u PM_CREATE_AUTONOMY "$ORCH_ENV" PM_CREATE_AUTONOMY ask)"
assert_eq "$got" "auto" "ceo composes issue-creation autonomy over the caller default"

# Test 9: composition reaches composed keys only.
got="$(cd "$proj_mode" && env -u ORCH_USER_MODE -u CI_FIX_MAX_CYCLES "$ORCH_ENV" CI_FIX_MAX_CYCLES 6)"
assert_eq "$got" "6" "an uncomposed key keeps the caller default under ceo"

# Test 10: a key the settings ladder sets wins over the composed value.
got="$(cd "$proj_override" && env -u ORCH_USER_MODE -u ORCH_MERGE_AUTONOMY "$ORCH_ENV" ORCH_MERGE_AUTONOMY auto)"
assert_eq "$got" "ask" "an explicit settings value outranks the composed value"

# Test 11: engineer leaves every composed key on its caller default.
got="$(cd "$proj_engineer" && env -u ORCH_USER_MODE -u ORCH_DECISION_MODE "$ORCH_ENV" ORCH_DECISION_MODE ask)"
assert_eq "$got" "ask" "engineer keeps the decision mode's caller default"
got="$(cd "$proj_engineer" && env -u ORCH_USER_MODE -u PM_CREATE_AUTONOMY "$ORCH_ENV" PM_CREATE_AUTONOMY ask)"
assert_eq "$got" "ask" "engineer keeps issue-creation autonomy's caller default"

# Must-fail control: a private copy with the composition branch removed must
# hand back the caller's default where test 8 read the composed value. The copy
# takes the whole scripts directory because orch-env sources lib/ beside it.
MUTANT_SCRIPTS="$TMP_ROOT/mutant-scripts"
cp -R "$REPO_ROOT/skills/orch/scripts" "$MUTANT_SCRIPTS"
MUTANT="$MUTANT_SCRIPTS/orch-env"
assert_eq "$(grep -Fc '  composed_value "$VAR_NAME"' "$MUTANT")" "1" \
  "composition control finds exactly one live mapping call"
sed -i.bak 's/^    composed_value "\$VAR_NAME"$/    COMPOSED=/' "$MUTANT"
assert_eq "$([[ ! -L "$MUTANT" ]] && ! cmp -s "$MUTANT" "$ORCH_ENV" && echo changed)" "changed" \
  "composition control changes the private copy"
got="$(cd "$proj_mode" && env -u ORCH_USER_MODE -u ORCH_MERGE_AUTONOMY "$MUTANT" ORCH_MERGE_AUTONOMY ask)"
assert_eq "$got" "ask" "must-fail control: without the mapping ceo falls back to the caller default"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
