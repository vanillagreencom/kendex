#!/usr/bin/env bash
# Regression tests for the orch-env effective-setting reader (vstack#543).
#
# orch-env VAR_NAME DEFAULT prints the effective value of a vstack [env]
# setting with the standard precedence (process env > vstack.settings.toml
# [env] > supplied default). With a numeric default, a non-numeric effective
# value falls back to the default so workflow cycle bounds always get a
# usable number. Workflows use it to read CI_FIX_MAX_CYCLES (default 6).

set -euo pipefail

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
# toplevel, so each scenario gets its own repo with no vstack settings noise.
proj_bare="$TMP_ROOT/proj-bare"
git init -q "$proj_bare"

proj_settings="$TMP_ROOT/proj-settings"
git init -q "$proj_settings"
cat > "$proj_settings/vstack.settings.toml" <<'TOML'
[env]
CI_FIX_MAX_CYCLES = "4"
TOML

proj_bad="$TMP_ROOT/proj-bad"
git init -q "$proj_bad"
cat > "$proj_bad/vstack.settings.toml" <<'TOML'
[env]
CI_FIX_MAX_CYCLES = "many"
TOML

# Test 1: nothing set anywhere -> the supplied default.
got="$(cd "$proj_bare" && env -u CI_FIX_MAX_CYCLES "$ORCH_ENV" CI_FIX_MAX_CYCLES 6)"
assert_eq "$got" "6" "prints the supplied default when the setting is unset"

# Test 2: vstack.settings.toml [env] value wins over the default.
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
(cd "$proj_bare" && "$ORCH_ENV" CI_FIX_MAX_CYCLES >/dev/null 2>&1)
missing_arg_code=$?
(cd "$proj_bare" && "$ORCH_ENV" 'bad-name!' 6 >/dev/null 2>&1)
bad_name_code=$?
set -e
assert_eq "$missing_arg_code" "2" "missing DEFAULT argument exits 2"
assert_eq "$bad_name_code" "2" "invalid variable name exits 2"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
