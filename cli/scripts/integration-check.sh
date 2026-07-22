#!/usr/bin/env bash
# Source integration check: install everything from this repo into a throwaway
# downstream project, refresh it twice, and verify installed workflow contracts.
#
# `vstack add` resolves PROJECT scope by walking up from the CWD
# (cli/src/config.rs::find_project_root_within) looking for .vstack-lock.json or
# a harness dir (.claude/ .cursor/ .codex/ .opencode/ .pi/ .agents/). Running it
# from inside this checkout installs into the checkout itself. This wrapper
# runs from a seeded temp project and verifies the reported and on-disk scope.
#
# Generator checks live here, not in skills/orch/tests: they require both the
# source CLI and canonical source tree. Installed regressions must remain
# runnable without either source-only dependency.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd -P)
cli_dir=$(cd "$script_dir/.." && pwd -P)
repo_root=$(cd "$cli_dir/.." && pwd -P)
canonical=$repo_root/skills/orch/workflows/start.md
canonical_dev=$repo_root/skills/dev/workflows/dev-implement.md
markdownlint_cli_version=0.49.1

cargo build --manifest-path "$cli_dir/Cargo.toml"

tmp_project=$(mktemp -d)
trap 'rm -rf "$tmp_project"' EXIT
mkdir "$tmp_project/.claude" # project marker — .git is not one (see config.rs)
tmp_phys=$(cd "$tmp_project" && pwd -P)
generated=$tmp_phys/.agents/skills/orch/workflows/start.md
generated_relative=.agents/skills/orch/workflows/start.md
generated_dev=$tmp_phys/.agents/skills/dev/workflows/dev-implement.md
installed_dev_cache_test=$tmp_phys/.agents/skills/dev/tests/linear-cache-preflight-contract.test.sh
installed_run_all=$tmp_phys/.agents/skills/orch/tests/run-all.sh
obsolete_installed_test=$tmp_phys/.agents/skills/orch/tests/generated-start-markdownlint.sh
snapshot=$tmp_phys/start-after-add.md
external_caller_cwd=$tmp_phys/external-caller
project_lock=$tmp_phys/.vstack-lock.json
mkdir "$external_caller_cwd"

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "$1" >&2
}

indent_log() {
  sed 's/^/        /' "$1" >&2
}

assert_generated_matches() {
  local phase=$1
  if cmp -s "$canonical" "$generated"; then
    pass "$phase output matches canonical start workflow"
  else
    fail "$phase output differs from canonical start workflow"
    diff -u "$canonical" "$generated" || true
  fi
}

assert_dev_generated_matches() {
  local phase=$1
  if cmp -s "$canonical_dev" "$generated_dev"; then
    pass "$phase output matches canonical dev-implement workflow"
  else
    fail "$phase output differs from canonical dev-implement workflow"
    diff -u "$canonical_dev" "$generated_dev" || true
  fi
}

lint_generated() {
  local phase=$1

  # These three style rules are intentionally disabled by the downstream
  # repository from #586. All other defaults, including MD022/55/56, run.
  if command -v markdownlint >/dev/null 2>&1; then
    if (cd "$tmp_phys" && markdownlint --disable MD013 MD031 MD060 -- \
      "$generated_relative"); then
      pass "$phase output passes markdownlint"
    else
      fail "$phase output fails markdownlint"
    fi
  elif command -v npx >/dev/null 2>&1; then
    if (cd "$tmp_phys" && npx --yes \
      "--package=markdownlint-cli@$markdownlint_cli_version" -- \
      markdownlint --disable MD013 MD031 MD060 -- \
      "$generated_relative"); then
      pass "$phase output passes markdownlint"
    else
      fail "$phase output fails markdownlint"
    fi
  else
    fail "$phase output could not be linted: markdownlint and npx are unavailable"
  fi
}

check_generated() {
  local phase=$1
  if [[ -f "$generated" ]]; then
    pass "$phase generated the orch start workflow"
    assert_generated_matches "$phase"
    lint_generated "$phase"
  else
    fail "$phase generated the orch start workflow"
  fi
}

check_dev_generated() {
  local phase=$1
  if [[ -f "$generated_dev" ]]; then
    pass "$phase generated the dev-implement workflow"
    assert_dev_generated_matches "$phase"
  else
    fail "$phase generated the dev-implement workflow"
  fi
}

assert_all_lock_entries_source_repo() {
  local phase=$1
  local entry_count
  local source_repo_count
  entry_count=$(grep -c '"name":' "$project_lock" || true)
  source_repo_count=$(grep -Ec '"source_repo": "[^"/]+/[^"/]+"' "$project_lock" || true)
  if [[ $entry_count -gt 0 && $source_repo_count -eq $entry_count ]]; then
    pass "$phase persists source repository identity for every lock entry"
  else
    fail "$phase persists source repository identity for every lock entry"
  fi
}

echo "=== downstream install and workflow verification ==="

log=$tmp_phys/vstack-add.log
if ! (cd "$tmp_phys" && "$cli_dir/target/debug/vstack" add "$repo_root" \
  --all --copy -y) >"$log" 2>&1; then
  cat "$log" >&2
  echo "FAIL: vstack add exited non-zero" >&2
  exit 1
fi

# display_path() shortens paths under $HOME to ~/…
tmp_display=$tmp_phys
case $tmp_phys in "$HOME"/*) tmp_display="~${tmp_phys#"$HOME"}" ;; esac

scope_line=$(grep '^Scope:' "$log" || true)
grep '^Installed' "$log" || true
echo "$scope_line"
case $scope_line in
*"($tmp_phys)"* | *"($tmp_display)"*)
  pass "install landed in the temp project; source checkout untouched"
  ;;
*)
  cat "$log" >&2
  echo "FAIL: scope resolved outside the temp project (expected $tmp_phys): $scope_line" >&2
  exit 1
  ;;
esac

check_generated "install"
check_dev_generated "install"
assert_all_lock_entries_source_repo "install"
if [[ -f "$generated" ]]; then
  cp "$generated" "$snapshot"
fi

# Model a legacy lock written before source_repo existed. Refresh must backfill
# the durable identity and save it, not merely keep it in memory for this run.
legacy_lock=$tmp_phys/.vstack-lock.legacy.json
sed '/"source_repo":/d' "$project_lock" >"$legacy_lock"
mv "$legacy_lock" "$project_lock"

# Model a downstream checkout installed before #592. A canonical refresh must
# remove the obsolete source-only regression before the installed suite runs.
printf '#!/usr/bin/env bash\nexit 99\n' >"$obsolete_installed_test"
if [[ -f "$obsolete_installed_test" ]]; then
  pass "fixture contains the obsolete installed source-only test"
else
  fail "fixture contains the obsolete installed source-only test"
fi

refresh_one_log=$tmp_phys/refresh-one.log
if (cd "$tmp_phys" && "$cli_dir/target/debug/vstack" refresh \
  --scope project -v) >"$refresh_one_log" 2>&1; then
  pass "first project refresh succeeds"
else
  fail "first project refresh succeeds"
  indent_log "$refresh_one_log"
fi

check_generated "first refresh"
check_dev_generated "first refresh"
assert_all_lock_entries_source_repo "first refresh"
if [[ ! -e "$obsolete_installed_test" ]]; then
  pass "first refresh removes the obsolete installed source-only test"
else
  fail "first refresh removes the obsolete installed source-only test"
fi
if [[ -f "$snapshot" && -f "$generated" ]]; then
  if cmp -s "$snapshot" "$generated"; then
    pass "first refresh preserves generated bytes"
  else
    fail "first refresh changes generated bytes"
  fi
fi

refresh_two_log=$tmp_phys/refresh-two.log
if (cd "$tmp_phys" && "$cli_dir/target/debug/vstack" refresh \
  --scope project -v) >"$refresh_two_log" 2>&1; then
  pass "second project refresh succeeds"
else
  fail "second project refresh succeeds"
  indent_log "$refresh_two_log"
fi

check_generated "second refresh"
check_dev_generated "second refresh"
if [[ -f "$snapshot" && -f "$generated" ]]; then
  if cmp -s "$snapshot" "$generated"; then
    pass "second refresh is byte-idempotent"
  else
    fail "second refresh changes generated bytes"
  fi
fi

if grep -Eq 'skill[[:space:]]+orch.*\(unchanged\)' "$refresh_two_log"; then
  pass "second refresh reports orch unchanged"
else
  fail "second refresh reports orch unchanged"
fi
if grep -Eq 'skill[[:space:]]+dev.*\(unchanged\)' "$refresh_two_log"; then
  pass "second refresh reports dev unchanged"
else
  fail "second refresh reports dev unchanged"
fi

installed_dev_log=$tmp_phys/installed-dev-cache-preflight.log
if [[ ! -f "$installed_dev_cache_test" ]]; then
  fail "installed dev cache-preflight regression exists"
elif (cd "$external_caller_cwd" && bash "$installed_dev_cache_test") \
  >"$installed_dev_log" 2>&1; then
  pass "refreshed installed dev cache-preflight regression passes externally"
else
  fail "refreshed installed dev cache-preflight regression passes externally"
  indent_log "$installed_dev_log"
fi

installed_suite_log=$tmp_phys/installed-orch-suite.log
if [[ ! -f "$installed_run_all" ]]; then
  fail "installed orch run-all exists"
elif (cd "$external_caller_cwd" && bash "$installed_run_all") \
  >"$installed_suite_log" 2>&1; then
  pass "refreshed installed orch suite passes from an external working directory"
else
  fail "refreshed installed orch suite passes from an external working directory"
  indent_log "$installed_suite_log"
fi

verify_log=$tmp_phys/verify.log
if (cd "$tmp_phys" && "$cli_dir/target/debug/vstack" verify \
  --scope project orch dev) >"$verify_log" 2>&1; then
  pass "verify confirms the refreshed orch and dev installs"
else
  fail "verify confirms the refreshed orch and dev installs"
  indent_log "$verify_log"
fi

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
