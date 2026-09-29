# shellcheck shell=bash
# Consumer workflow fixtures use the shared sandbox and real API parser.
. "$TEST_DIR/lib/sandbox.sh"
. "$TEST_DIR/lib/workflow-edit.sh"
BIN="$TMP/bin"
FIXTURES="$TMP/github"
mkdir -p "$BIN" "$FIXTURES"
cp "$TEST_DIR/lib/gh-shim.sh" "$BIN/gh"
chmod +x "$BIN/gh"
printf '{"full_name":"acme/widgets","default_branch":"main"}\n' >"$FIXTURES/repository.json"
printf '{"environments":[{"name":"kendex","deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}]}\n' >"$FIXTURES/environments.json"
printf '{"branch_policies":[{"name":"main","type":"branch"}]}\n' >"$FIXTURES/branch-policies.json"
printf '{"secrets":[{"name":"FLEET_GH_APP_ID"},{"name":"FLEET_GH_APP_PRIVATE_KEY"}]}\n' >"$FIXTURES/environment-secrets-kendex.json"

# run_refresh_command ROOT SCRIPT [ARGS...] keeps host credentials outside the
# child and reports through the sandbox's OUT and RC contract.
run_refresh_command() {
  local root="$1" script="$2"
  shift 2
  RC=0
  OUT="$(cd "$root" && env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP" \
    GH_SHIM_FIXTURES="$FIXTURES" GH_SHIM_FAIL="${SHIM_FAIL:-}" \
    "$script" "$@" 2>&1)" || RC=$?
}
