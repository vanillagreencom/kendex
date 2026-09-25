#!/usr/bin/env bash
# validate-standard.sh against a fake GitHub: a repository matching the
# standard reports every row ok, and each drifted element reports its own
# row and no other. The whole verdict listing is compared, so a row that
# goes missing or flips beside the drifted one is caught too.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "$1"
  printf '%s\n' "$2" | sed 's/^/        /'
}

# A skill copy with a test-owned standard, so the expected values below are
# literals and not a second reading of the shipped manifest.
SKILL="$TMP/skill"
BIN="$TMP/bin"
BASE="$TMP/base"
mkdir -p "$SKILL" "$BIN" "$BASE"
cp -R "$SKILL_DIR/scripts" "$SKILL/scripts"
cat >"$SKILL/standard.json" <<'JSON'
{
  "required_contexts": ["Review gate", "CI"],
  "app": "lanes-app",
  "environment": "kendex",
  "environment_secrets": ["APP_ID", "APP_KEY"]
}
JSON
cp "$TEST_DIR/lib/gh-shim.sh" "$BIN/gh"
chmod +x "$BIN/gh"

# The matching world.
cat >"$BASE/repository.json" <<'JSON'
{"full_name": "acme/widgets", "default_branch": "main"}
JSON
cat >"$BASE/rules.json" <<'JSON'
[
  {"type": "merge_queue", "parameters": {"merge_method": "SQUASH"}, "ruleset_source_type": "Organization", "ruleset_id": 1},
  {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "Review gate"}, {"context": "CI"}]}, "ruleset_source_type": "Organization", "ruleset_id": 1},
  {"type": "pull_request", "parameters": {"required_review_thread_resolution": true}, "ruleset_source_type": "Organization", "ruleset_id": 1},
  {"type": "copilot_code_review", "parameters": {"review_on_push": true}, "ruleset_source_type": "Organization", "ruleset_id": 2}
]
JSON
printf '{"id": 1, "bypass_actors": []}\n' >"$BASE/ruleset-1.json"
printf '{"id": 2, "bypass_actors": []}\n' >"$BASE/ruleset-2.json"
cat >"$BASE/installations.json" <<'JSON'
{"installations": [{"app_slug": "other-app", "repository_selection": "selected"}, {"app_slug": "lanes-app", "repository_selection": "all"}]}
JSON
cat >"$BASE/environments.json" <<'JSON'
{"environments": [{"name": "copilot", "deployment_branch_policy": null}, {"name": "kendex", "deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}]}
JSON
printf '{"branch_policies": [{"name": "main", "type": "branch"}]}\n' >"$BASE/branch-policies.json"
printf '{"secrets": [{"name": "APP_ID"}, {"name": "APP_KEY"}, {"name": "OTHER"}]}\n' >"$BASE/environment-secrets.json"
printf '{"secrets": [{"name": "OTHER"}]}\n' >"$BASE/repository-secrets.json"
printf '{"secrets": [{"name": "SHARED"}]}\n' >"$BASE/organization-secrets.json"

BASELINE='ok check=standard-ruleset-source value=Organization
ok check=standard-merge-queue value=present
ok check=standard-required-contexts value=CI\;Review\ gate
ok check=standard-conversation-resolution value=true
ok check=standard-copilot-review value=present
ok check=standard-bypass-actors value=0
ok check=standard-app value=all
ok check=standard-environment value=custom:branch:main
ok check=standard-environment-secrets value=APP_ID\;APP_KEY
ok check=standard-secrets-outside value=none'

# The baseline with each named row turned to FAIL at its observed value.
# OVERRIDES is `check=value` pairs separated by `^`, values as printed.
expected_listing() { # OVERRIDES
  local line check pair out=""
  while IFS= read -r line; do
    check="${line#ok check=}"
    check="${check%% value=*}"
    local hit=""
    local rest="$1"
    while [ -n "$rest" ]; do
      pair="${rest%%^*}"
      [ "$pair" = "$rest" ] && rest="" || rest="${rest#*^}"
      [ "${pair%%=*}" = "$check" ] && hit="FAIL check=$check value=${pair#*=}"
    done
    out="${out:+$out
}${hit:-$line}"
  done <<<"$BASELINE"
  printf '%s' "$out"
}

run() { # FIXTURES SHIM_FAIL — sets OUT (verdict lines) and RC
  RC=0
  RAW="$(env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP" GH_SHIM_FIXTURES="$1" GH_SHIM_FAIL="$2" \
    "$SKILL/scripts/validate-standard.sh" 2>&1)" || RC=$?
  OUT="$(grep -E '^(ok|FAIL) check=' <<<"$RAW" || true)"
}

echo "=== each drifted element reports its own row ==="
# name ~ shim failure ~ fixture file ~ jq edit of it ~ overrides
rows=0
while IFS='~' read -r name fail file edit overrides; do
  [ -n "$name" ] || continue
  rows=$((rows + 1))
  dir="$TMP/case-$rows"
  cp -R "$BASE" "$dir"
  if [ -n "$file" ]; then
    jq "$edit" "$dir/$file" >"$dir/$file.new" && mv "$dir/$file.new" "$dir/$file"
  fi
  run "$dir" "$fail"
  want="$(expected_listing "$overrides")"
  want_rc=1
  [ -n "$overrides" ] || want_rc=0
  if [ "$RC" -eq "$want_rc" ] && [ "$OUT" = "$want" ]; then
    ok "$name"
  else
    bad "$name (rc=$RC, want $want_rc)" "$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$OUT") || true)
$RAW"
  fi
done <<'ROWS'
a repository matching the standard~~~~
a per-repository rule~~rules.json~.[1].ruleset_source_type = "Repository"~standard-ruleset-source=Repository:1
no ruleset at all~~rules.json~[]~standard-ruleset-source=none^standard-merge-queue=absent^standard-required-contexts=''^standard-conversation-resolution=false^standard-copilot-review=absent
no merge queue~~rules.json~del(.[0])~standard-merge-queue=absent
an extra required context~~rules.json~.[1].parameters.required_status_checks += [{"context": "Cargo"}]~standard-required-contexts=CI\;Cargo\;Review\ gate
a missing required context~~rules.json~.[1].parameters.required_status_checks = [{"context": "Review gate"}]~standard-required-contexts=Review\ gate
threads need no resolution~~rules.json~.[2].parameters.required_review_thread_resolution = false~standard-conversation-resolution=false
no Copilot review~~rules.json~del(.[3])~standard-copilot-review=absent
a bypass actor~~ruleset-2.json~.bypass_actors = [{"actor_type": "RepositoryRole", "actor_id": 5}]~standard-bypass-actors=1
bypass actors withheld from the token~~ruleset-1.json~del(.bypass_actors)~standard-bypass-actors=unreadable:1
the app on selected repositories~~installations.json~.installations[1].repository_selection = "selected"~standard-app=selected
the app not installed~~installations.json~.installations |= [.[0]]~standard-app=absent
installations unreadable~installations~~~standard-app=unreadable
the environment deploys from every branch~~environments.json~.environments[1].deployment_branch_policy = null~standard-environment=unrestricted
the environment deploys from protected branches~~environments.json~.environments[1].deployment_branch_policy = {"protected_branches": true, "custom_branch_policies": false}~standard-environment=protected-branches
the environment deploys from a second branch~~branch-policies.json~.branch_policies += [{"name": "dev", "type": "branch"}]~standard-environment=custom:branch:main\,branch:dev
branch policies unreadable~branch-policies~~~standard-environment=unreadable
the environment lacks a secret~~environment-secrets.json~.secrets |= map(select(.name != "APP_KEY"))~standard-environment-secrets=APP_ID
environment secrets unreadable~environment-secrets~~~standard-environment-secrets=unreadable
a repository secret of a standard name~~repository-secrets.json~.secrets += [{"name": "APP_ID"}]~standard-secrets-outside=repository:APP_ID
an organization secret of a standard name~~organization-secrets.json~.secrets += [{"name": "APP_KEY"}]~standard-secrets-outside=organization:APP_KEY
organization secrets unreadable~organization-secrets~~~standard-secrets-outside=unreadable:organization
ROWS

# One drifted element that answers two rows: without the environment there
# is no secret to ask for, and the secrets row says why rather than passing.
echo "=== the environment's absence answers both of its rows ==="
dir="$TMP/case-no-environment"
cp -R "$BASE" "$dir"
jq '.environments |= [.[0]]' "$dir/environments.json" >"$dir/e" && mv "$dir/e" "$dir/environments.json"
run "$dir" ""
want="$(expected_listing 'standard-environment=absent^standard-environment-secrets=absent')"
if [ "$RC" -eq 1 ] && [ "$OUT" = "$want" ]; then ok "an absent environment"; else bad "an absent environment (rc=$RC)" "$RAW"; fi

echo "=== a failed read is unreadable, never a match ==="
run "$BASE" rules
want="$(expected_listing 'standard-ruleset-source=unreadable^standard-merge-queue=unreadable^standard-required-contexts=unreadable^standard-conversation-resolution=unreadable^standard-copilot-review=unreadable^standard-bypass-actors=unreadable')"
if [ "$RC" -eq 1 ] && [ "$OUT" = "$want" ]; then ok "the effective rules unreadable"; else bad "the effective rules unreadable (rc=$RC)" "$RAW"; fi
run "$BASE" environments
want="$(expected_listing 'standard-environment=unreadable^standard-environment-secrets=unreadable')"
if [ "$RC" -eq 1 ] && [ "$OUT" = "$want" ]; then ok "the environments unreadable"; else bad "the environments unreadable (rc=$RC)" "$RAW"; fi

echo "=== the check could not run ==="
# name ~ shim failure ~ manifest replacement (empty keeps the test's) ~ argument ~ first error line
while IFS='~' read -r name fail manifest arg key; do
  [ -n "$name" ] || continue
  cp "$SKILL/standard.json" "$TMP/standard.keep"
  [ -z "$manifest" ] || printf '%s\n' "$manifest" >"$SKILL/standard.json"
  RC=0
  RAW="$(env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP" GH_SHIM_FIXTURES="$BASE" GH_SHIM_FAIL="$fail" \
    "$SKILL/scripts/validate-standard.sh" ${arg:+"$arg"} 2>&1)" || RC=$?
  mv "$TMP/standard.keep" "$SKILL/standard.json"
  first="${RAW%%
*}"
  if [ "$RC" -eq 2 ] && [ "${first%% value=*}" = "$key" ] && ! grep -qE '^(ok|FAIL) check=' <<<"$RAW"; then
    ok "$name"
  else
    bad "$name (rc=$RC)" "$RAW"
  fi
done <<'ROWS'
the repository unreadable~repository~~~review-gate-error=repository-read
a manifest without an app~~{"required_contexts": ["CI"], "environment": "kendex", "environment_secrets": ["A"]}~~review-gate-error=standard-malformed
a manifest with no contexts~~{"required_contexts": [], "app": "a", "environment": "kendex", "environment_secrets": ["A"]}~~review-gate-error=standard-malformed
an argument~~~--repo~review-gate-error=unknown-arguments
ROWS

# The shipped manifest passes the same shape check: with the repository
# read failing, the first refusal is the read, not the manifest.
RC=0
RAW="$(env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP" GH_SHIM_FIXTURES="$BASE" GH_SHIM_FAIL=repository \
  "$SKILL_DIR/scripts/validate-standard.sh" 2>&1)" || RC=$?
if [ "$RC" -eq 2 ] && [ "${RAW%% value=*}" = "review-gate-error=repository-read" ]; then
  ok "the shipped standard.json is well-formed"
else
  bad "the shipped standard.json is well-formed (rc=$RC)" "$RAW"
fi

[ "$rows" -gt 0 ] || { bad "the drift table ran no row" ""; }
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
