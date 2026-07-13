#!/usr/bin/env bash
# Regression tests for vstack-env.sh project-config precedence.
#
# Contract (highest to lowest priority):
#   parent-process env  >  .env.local  >  vstack.settings.toml/.vstack/settings.toml  >  .env
#
# Bug 2 (vstack#507): the settings loader clobbered caller-provided env. Parent
# values must now win over every project file, while the .env < settings <
# .env.local order is preserved for keys the parent did not set.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$TEST_DIR/.." && pwd)/scripts/lib/vstack-env.sh"
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

echo "=== vstack-env precedence ==="

# Shared project root for scenarios 1 and 2.
PROJ="$TMP_ROOT/proj"
mkdir -p "$PROJ"
printf 'FOO="from-env"\n' > "$PROJ/.env"
cat > "$PROJ/vstack.settings.toml" <<'TOML'
[env]
FOO = "from-settings"
BAR = "bar-settings"
TOML
printf 'BAZ="from-local"\n' > "$PROJ/.env.local"

# Scenario 1: no parent FOO -> settings overrides .env (existing contract).
set +e
s1_out=$(
  set -euo pipefail
  source "$LIB"
  vstack_load_project_env "$PROJ"
  printf '%s|%s|%s\n' "$FOO" "$BAR" "$BAZ"
)
s1_code=$?
set -e
assert_eq "$s1_code" "0" "scenario 1 loads without error"
assert_eq "$s1_out" "from-settings|bar-settings|from-local" "scenario 1: settings overrides .env; .env.local applied"

# Scenario 2: parent FOO exported -> parent wins over both .env and settings;
# a key the parent did not set (BAR) is still taken from settings.
set +e
s2_out=$(
  set -euo pipefail
  export FOO=from-parent
  source "$LIB"
  vstack_load_project_env "$PROJ"
  printf '%s|%s\n' "$FOO" "$BAR"
)
s2_code=$?
set -e
assert_eq "$s2_code" "0" "scenario 2 loads without error"
assert_eq "$s2_out" "from-parent|bar-settings" "scenario 2: parent env wins over project files; other settings keys still applied"

# Scenario 3: the issue's exact case. Parent GH_ISSUE_PATTERN must survive a
# conflicting lowercase pattern in project settings.
PROJ3="$TMP_ROOT/proj3"
mkdir -p "$PROJ3"
printf 'FOO="from-env"\n' > "$PROJ3/.env"
cat > "$PROJ3/vstack.settings.toml" <<'TOML'
[env]
GH_ISSUE_PATTERN = "cc-[0-9]+"
TOML
set +e
s3_out=$(
  set -euo pipefail
  export GH_ISSUE_PATTERN='CC-[0-9]+'
  source "$LIB"
  vstack_load_project_env "$PROJ3"
  printf '%s\n' "$GH_ISSUE_PATTERN"
)
s3_code=$?
set -e
assert_eq "$s3_code" "0" "scenario 3 loads without error"
assert_eq "$s3_out" 'CC-[0-9]+' "scenario 3: parent GH_ISSUE_PATTERN wins over conflicting settings"

# Scenario 4: standalone-call safety. vstack_load_settings_file must work in a
# fresh subshell with no _VSTACK_PARENT_ENV snapshot, without erroring under
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
  vstack_load_settings_file "$STANDALONE"
  printf '%s\n' "$FRESH_KEY"
)
s4_code=$?
set -e
assert_eq "$s4_code" "0" "scenario 4: standalone settings load does not error without a snapshot"
assert_eq "$s4_out" "fresh-val" "scenario 4: standalone settings load sets a fresh key"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
