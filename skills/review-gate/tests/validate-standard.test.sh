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
  "ci_context": "CI",
  "gate_context": "Review gate",
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
# Every baseline rule is organization-sourced, so its ruleset is read
# through the organization endpoint. The repository-endpoint copy of ruleset
# 2 carries an actor, so a read through the wrong endpoint reports 1.
printf '{"id": 1, "bypass_actors": []}\n' >"$BASE/org-ruleset-1.json"
printf '{"id": 2, "bypass_actors": []}\n' >"$BASE/org-ruleset-2.json"
printf '{"id": 1, "bypass_actors": []}\n' >"$BASE/ruleset-1.json"
printf '{"id": 2, "bypass_actors": [{"actor_type": "RepositoryRole", "actor_id": 9}]}\n' >"$BASE/ruleset-2.json"
cat >"$BASE/installations.json" <<'JSON'
{"installations": [{"app_slug": "other-app", "repository_selection": "selected"}, {"app_slug": "lanes-app", "repository_selection": "all"}]}
JSON
cat >"$BASE/environments.json" <<'JSON'
{"environments": [{"name": "copilot", "deployment_branch_policy": null}, {"name": "kendex", "deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}]}
JSON
printf '{"branch_policies": [{"name": "main", "type": "branch"}]}\n' >"$BASE/branch-policies.json"
printf '{"name": "main", "protected": true, "protection": {"enabled": false}}\n' >"$BASE/branch.json"
printf '{"secrets": [{"name": "APP_ID"}, {"name": "APP_KEY"}, {"name": "OTHER"}]}\n' >"$BASE/environment-secrets-kendex.json"
printf '{"secrets": [{"name": "COPILOT_TOKEN"}]}\n' >"$BASE/environment-secrets-copilot.json"
printf '{"secrets": [{"name": "OTHER"}]}\n' >"$BASE/repository-secrets.json"
# The organization-wide list and the list shared with this repository are
# two endpoints; only the first answers for the organization scope.
printf '{"secrets": [{"name": "SHARED"}]}\n' >"$BASE/organization-secrets.json"
printf '{"secrets": [{"name": "SHARED"}, {"name": "ELSEWHERE"}]}\n' >"$BASE/organization-actions-secrets.json"
printf '{"secrets": [{"name": "NPM_TOKEN"}]}\n' >"$BASE/dependabot-secrets.json"
printf '{"secrets": []}\n' >"$BASE/organization-dependabot-secrets.json"
# The default branch's head, dead, is the queue's merge commit. Its first
# associated pull request merged into another branch, so a read that ignores
# the base takes the wrong head.
printf '{"sha": "dead"}\n' >"$BASE/commit.json"
cat >"$BASE/commit-pulls.json" <<'JSON'
[
  {"number": 20, "merged_at": "2026-09-22T09:00:00Z", "base": {"ref": "release"}, "head": {"sha": "cafe"}},
  {"number": 12, "merged_at": null, "base": {"ref": "main"}, "head": {"sha": "c0c0"}},
  {"number": 11, "merged_at": "2026-09-21T09:00:00Z", "base": {"ref": "main"}, "head": {"sha": "beef"}}
]
JSON
# The pull_request leg: the CI workflow's run carries the lanes and their
# aggregate; the second run is another workflow's. The merge_group leg on the
# head runs the CI workflow alone.
printf '{"workflow_runs": [{"id": 7}, {"id": 8}]}\n' >"$BASE/workflow-runs.json"
printf '{"jobs": [{"name": "lint-typecheck"}, {"name": "build"}, {"name": "CI"}]}\n' >"$BASE/jobs-7.json"
printf '{"jobs": [{"name": "writer"}]}\n' >"$BASE/jobs-8.json"
printf '{"workflow_runs": [{"id": 9}]}\n' >"$BASE/workflow-runs-merge-group.json"
printf '{"jobs": [{"name": "lint-typecheck"}, {"name": "build"}, {"name": "CI"}]}\n' >"$BASE/jobs-9.json"

BASELINE='ok check=standard-ruleset-source value=Organization
ok check=standard-merge-queue value=present
ok check=standard-required-contexts value=CI\;Review\ gate
ok check=standard-conversation-resolution value=true
ok check=standard-copilot-review value=present
ok check=standard-bypass-actors value=0
ok check=standard-classic-protection value=off
ok check=standard-ci-context value=CI\;build\;lint-typecheck\;writer
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
# name ~ shim failure ~ fixture files (comma-separated) ~ jq edit of each
# ~ overrides. A fixture that does not exist yet, such as a second page, is
# written from the edit alone.
rows=0
while IFS='~' read -r name fail files edit overrides; do
  [ -n "$name" ] || continue
  rows=$((rows + 1))
  dir="$TMP/case-$rows"
  cp -R "$BASE" "$dir"
  for file in $(tr ',' ' ' <<<"$files"); do
    if [ -f "$dir/$file" ]; then
      jq "$edit" "$dir/$file" >"$dir/$file.new"
    else
      jq -n "$edit" >"$dir/$file.new"
    fi
    mv "$dir/$file.new" "$dir/$file"
  done
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
a bypass actor on each ruleset adds up~~org-ruleset-1.json,org-ruleset-2.json~.bypass_actors = [{"actor_type": "RepositoryRole", "actor_id": 5}]~standard-bypass-actors=2
bypass actors withheld from the token~~org-ruleset-1.json~del(.bypass_actors)~standard-bypass-actors=unreadable:1
a repository ruleset's actors read through the repository endpoint~~rules.json~.[3].ruleset_source_type = "Repository"~standard-ruleset-source=Repository:2^standard-bypass-actors=1
a ruleset source with no ruleset read is unreadable~~rules.json~.[3].ruleset_source_type = "Enterprise"~standard-ruleset-source=Enterprise:2^standard-bypass-actors=unreadable:2
a per-repository rule on the second page~~rules.page2.json~[{"type": "deletion", "ruleset_source_type": "Repository", "ruleset_id": 1}]~standard-ruleset-source=Repository:1
classic protection beside the rulesets~~branch.json~.protection.enabled = true~standard-classic-protection=on
the branch unreadable~branch~~~standard-classic-protection=unreadable
the app on selected repositories~~installations.json~.installations[1].repository_selection = "selected"~standard-app=selected
the app not installed~~installations.json~.installations |= [.[0]]~standard-app=absent
installations unreadable~installations~~~standard-app=unreadable
lanes reporting their own names and no CI aggregate~~jobs-7.json~.jobs |= map(select(.name != "CI"))~standard-ci-context=ci-context-missing:pull_request:build\;lint-typecheck\;writer
an aggregate whose name only starts with CI~~jobs-7.json~.jobs |= map(if .name == "CI" then .name = "CI Required" else . end)~standard-ci-context=ci-context-missing:pull_request:CI\ Required\;build\;lint-typecheck\;writer
no job ran on the pull request~~workflow-runs.json~.workflow_runs = []~standard-ci-context=ci-context-missing:pull_request:none
the CI job on the second page of a run's jobs~~jobs-7.json,jobs-7.page2.json~if . == null then {"jobs": [{"name": "CI"}]} else .jobs |= map(select(.name != "CI")) end~
the CI run on the second page of runs~~jobs-7.json,workflow-runs.page2.json,jobs-10.json~if . == null then {"workflow_runs": [{"id": 10}], "jobs": [{"name": "CI"}]} else .jobs |= map(select(.name != "CI")) end~
a head that did not come through the merge queue~~workflow-runs-merge-group.json~.workflow_runs = []~standard-ci-context=merge-group-unobserved:CI\;build\;lint-typecheck\;writer
a merge group that ran no CI job~~jobs-9.json~.jobs |= map(select(.name != "CI"))~standard-ci-context=ci-context-missing:merge_group:build\;lint-typecheck
a head no merged pull request produced~~commit-pulls.json~map(.merged_at = null)~standard-ci-context=no-associated-pull-request
a head merged only into another branch~~commit-pulls.json~map(select(.base.ref != "main"))~standard-ci-context=no-associated-pull-request
a branch head that is not a sha~~commit.json~.sha = "main"~standard-ci-context=unreadable
a merged head that is not a sha~~commit-pulls.json~.[2].head.sha = "main"~standard-ci-context=unreadable
the branch head unreadable~commit~~~standard-ci-context=unreadable
the head's pull requests unreadable~commit-pulls~~~standard-ci-context=unreadable
pull_request runs unreadable~workflow-runs~~~standard-ci-context=unreadable
the head's merge_group runs unreadable~workflow-runs-merge-group~~~standard-ci-context=unreadable
a run's jobs unreadable~jobs-8~~~standard-ci-context=unreadable
the environment deploys from every branch~~environments.json~.environments[1].deployment_branch_policy = null~standard-environment=unrestricted
the environment deploys from protected branches~~environments.json~.environments[1].deployment_branch_policy = {"protected_branches": true, "custom_branch_policies": false}~standard-environment=protected-branches
the environment deploys from a second branch~~branch-policies.json~.branch_policies += [{"name": "dev", "type": "branch"}]~standard-environment=custom:branch:main\,branch:dev
branch policies unreadable~branch-policies~~~standard-environment=unreadable
a tag policy named for the default branch~~branch-policies.json~.branch_policies = [{"name": "main", "type": "tag"}]~standard-environment=custom:tag:main
a secret whose name only starts like a standard one~~environment-secrets-kendex.json~.secrets = [{"name": "APP_ID"}, {"name": "APP_KEY_OLD"}]~standard-environment-secrets=APP_ID
the environment lacks a secret~~environment-secrets-kendex.json~.secrets |= map(select(.name != "APP_KEY"))~standard-environment-secrets=APP_ID
environment secrets unreadable~environment-secrets-kendex~~~standard-environment-secrets=unreadable
a repository secret of a standard name~~repository-secrets.json~.secrets += [{"name": "APP_ID"}]~standard-secrets-outside=repository:APP_ID
a repository secret of a standard name on the second page~~repository-secrets.page2.json~{"secrets": [{"name": "APP_ID"}]}~standard-secrets-outside=repository:APP_ID
a repository secret whose name only starts like a standard one~~repository-secrets.json~.secrets += [{"name": "APP_ID_OLD"}]~
a standard name in another environment~~environment-secrets-copilot.json~.secrets += [{"name": "APP_ID"}]~standard-secrets-outside=environment:copilot:APP_ID
a repository Dependabot secret of a standard name~~dependabot-secrets.json~.secrets += [{"name": "APP_KEY"}]~standard-secrets-outside=dependabot:APP_KEY
an organization Dependabot secret of a standard name~~organization-dependabot-secrets.json~.secrets += [{"name": "APP_ID"}]~standard-secrets-outside=dependabot-organization:APP_ID
another environment's secrets unreadable~environment-secrets-copilot~~~standard-secrets-outside=unreadable:environment:copilot
repository Dependabot secrets unreadable~dependabot-secrets~~~standard-secrets-outside=unreadable:dependabot
an organization secret of a standard name not shared with this repository~~organization-actions-secrets.json~.secrets += [{"name": "APP_KEY"}]~standard-secrets-outside=organization:APP_KEY
organization secrets unreadable~organization-actions-secrets~~~standard-secrets-outside=unreadable:organization
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
want="$(expected_listing 'standard-environment=unreadable^standard-environment-secrets=unreadable^standard-secrets-outside=unreadable:environments')"
if [ "$RC" -eq 1 ] && [ "$OUT" = "$want" ]; then ok "the environments unreadable"; else bad "the environments unreadable (rc=$RC)" "$RAW"; fi

echo "=== each failed read keeps its own cause ==="
# A withheld field beside a failed read, and a failed read followed by
# successful ones: each cause line names its own read.
dir="$TMP/case-causes"
cp -R "$BASE" "$dir"
jq 'del(.bypass_actors)' "$dir/org-ruleset-1.json" >"$dir/r" && mv "$dir/r" "$dir/org-ruleset-1.json"
run "$dir" org-ruleset-2
if grep -qx '  2: gh-shim-error=api value=org-ruleset-2' <<<"$RAW" && grep -q '^  1: ' <<<"$RAW" &&
  ! grep -q '^  1: gh-shim' <<<"$RAW" && grep -qx 'FAIL check=standard-bypass-actors value=unreadable:1\\,2' <<<"$RAW"; then
  ok "a withheld field and a failed ruleset read each name their own cause"
else
  bad "a withheld field and a failed ruleset read each name their own cause" "$RAW"
fi
run "$BASE" organization-actions-secrets
if grep -qx '  organization: gh-shim-error=api value=organization-actions-secrets' <<<"$RAW"; then
  ok "a failed secret read keeps its cause after later reads succeed"
else
  bad "a failed secret read keeps its cause after later reads succeed" "$RAW"
fi

echo "=== the CI context is read on both legs of the latest merge ==="
# The row's reads in order: the branch head, its pull requests, the
# pull_request leg on the merged pull request's head, and the merge_group leg
# on the branch head.
dir="$TMP/case-latest-merge"
cp -R "$BASE" "$dir"
rm -f -- "${dir:?}/.urls.log"
run "$dir" ""
want_urls='repos/acme/widgets/commits/main
repos/acme/widgets/commits/dead/pulls
repos/acme/widgets/actions/runs?head_sha=beef&event=pull_request&per_page=100
repos/acme/widgets/actions/runs?head_sha=dead&event=merge_group&per_page=100'
got_urls="$(grep -E '/commits/|/actions/runs\?' "$dir/.urls.log" || true)"
if [ "$got_urls" = "$want_urls" ]; then
  ok "the reads name the branch head, its merged pull request's head and the merge_group leg"
else
  bad "the reads name the branch head, its merged pull request's head and the merge_group leg" "$(diff <(printf '%s\n' "$want_urls") <(printf '%s\n' "$got_urls") || true)"
fi

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
a manifest without an app~~{"ci_context": "CI", "gate_context": "Review gate", "environment": "kendex", "environment_secrets": ["A"]}~~review-gate-error=standard-malformed
a manifest without a gate context~~{"ci_context": "CI", "app": "a", "environment": "kendex", "environment_secrets": ["A"]}~~review-gate-error=standard-malformed
a manifest without a CI context~~{"gate_context": "Review gate", "app": "a", "environment": "kendex", "environment_secrets": ["A"]}~~review-gate-error=standard-malformed
a manifest whose two contexts are one~~{"ci_context": "CI", "gate_context": "CI", "app": "a", "environment": "kendex", "environment_secrets": ["A"]}~~review-gate-error=standard-malformed
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
