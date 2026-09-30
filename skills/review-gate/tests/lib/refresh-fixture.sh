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

# The rolling refresh runner uses real git and isolates all service inputs.
run_refresh() { # CONTENT VERIFY CLASS
  local result=0
  rm -f -- "${TMP:?}/state/auth"
  OUT="$(cd "$repo" && env -i PATH="$TMP/bin:$PATH" HOME="$TMP/home" TMPDIR="$TMP" GH_TOKEN=test-token GH_REPO=acme/test REFRESH_APP_SLUG=lanes TEST_STATE="$TMP/state" TEST_REAL_GIT="$REAL_GIT" TEST_CONTENT="$1" TEST_VERIFY="$2" TEST_CLASS="$3" TEST_MEASURED="${MEASURED:-true}" TEST_REASON="${CLASS_REASON:-cause=renders-match-their-sources}" TEST_CLASS_EXIT="${CLASS_EXIT:-0}" TEST_HOSTILE="${HOSTILE:-}" TEST_FRESH_TEMPLATES="$TMP/fresh-templates" TEST_GH_SHIM="$TMP/standard-gh" GH_SHIM_FIXTURES="$FIXTURES" bash "$runner" 2>&1)" || result=$?
  RC="$result"
}

reset_default() {
  git -C "$repo" reset --hard -q
  git -C "$repo" checkout -q main
}

# Assert the runner's publication record, body data and arm decision together.
refresh_class_matches() { # CLASS STATE ARM REASON METHOD
  [ "$RC" -eq 0 ] &&
    grep -qxF -- "refresh-state=$2 pr=1 class=$1" <<<"$OUT" &&
    grep -qxF -- "class: class=$1 measured=true $4" "$TMP/state/body" &&
    grep -qF -- "api --method $5 repos/acme/test/pulls" "$TMP/state/calls" &&
    if [ "$3" = yes ]; then [ -f "$TMP/state/armed" ]; else [ ! -f "$TMP/state/armed" ]; fi
}

refresh_stopped_at_class() { # REMOTE_HEAD
  local after
  after="$(git --git-dir="$TMP/remote" rev-parse refs/heads/kendex/refresh)" || return 1
  [ "$RC" -eq 1 ] && [ "$after" = "$1" ] &&
    grep -qxF 'refresh-error=read value=class' <<<"$OUT" &&
    ! grep -qE '^api --method (POST|PATCH)|^pr merge ' "$TMP/state/calls"
}
