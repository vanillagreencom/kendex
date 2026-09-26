#!/usr/bin/env bash
# provision-environment.sh against a fake GitHub holding one provisioned
# repository, one unprovisioned repository and one archived repository: a
# dry run plans exactly one create and one no-op and writes nothing, each
# drift of the provisioned one is converged by exactly the writes it needs,
# and a run that cannot enumerate every repository or has no secret value
# writes nothing.
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

# A skill copy with a test-owned standard, so the names below are literals
# and not a second reading of the shipped manifest.
SKILL="$TMP/skill"
BIN="$TMP/bin"
BASE="$TMP/base"
mkdir -p "$SKILL" "$BIN" "$BASE/repos/acme/done" "$BASE/repos/acme/fresh"
cp -R "$SKILL_DIR/scripts" "$SKILL/scripts"
cat >"$SKILL/standard.json" <<'JSON'
{
  "required_contexts": ["CI"],
  "app": "lanes-app",
  "environment": "kendex",
  "environment_secrets": ["APP_ID", "APP_KEY"]
}
JSON
cp "$TEST_DIR/lib/gh-shim.sh" "$BIN/gh"
chmod +x "$BIN/gh"

cat >"$BASE/installations.json" <<'JSON'
{"installations": [{"app_slug": "other-app", "repository_selection": "selected"}, {"app_slug": "lanes-app", "repository_selection": "all"}]}
JSON
# Three repositories owned, archived one included, and three listed.
printf '{"login": "acme", "public_repos": 2, "total_private_repos": 1}\n' >"$BASE/organization.json"
cat >"$BASE/organization-repositories.json" <<'JSON'
[
  {"full_name": "acme/done", "default_branch": "main", "archived": false},
  {"full_name": "acme/fresh", "default_branch": "trunk", "archived": false},
  {"full_name": "acme/old", "default_branch": "main", "archived": true}
]
JSON
DONE="$BASE/repos/acme/done"
cat >"$DONE/environments.json" <<'JSON'
{"environments": [{"name": "copilot", "deployment_branch_policy": null}, {"name": "kendex", "deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}, "protection_rules": [{"id": 9, "type": "branch_policy"}]}]}
JSON
printf '{"branch_policies": [{"id": 1, "name": "main", "type": "branch"}]}\n' >"$DONE/branch-policies.json"
printf '{"secrets": [{"name": "APP_ID"}, {"name": "APP_KEY"}, {"name": "OTHER"}]}\n' >"$DONE/environment-secrets-kendex.json"
printf '{"environments": []}\n' >"$BASE/repos/acme/fresh/environments.json"

KEY='-----BEGIN RSA PRIVATE KEY-----
line two
-----END RSA PRIVATE KEY-----'
# Copies BASE to DIR and applies each jq EDIT to the FILE beside it, FILES
# comma-separated under DIR/PREFIX and EDITS `^`-separated in the same order.
world() { # DIR PREFIX FILES EDITS
  local dir="$1" prefix="$2" files="$3" edits="$4" file edit
  cp -R "$BASE" "$dir"
  while [ -n "$files" ]; do
    file="${files%%,*}"
    edit="${edits%%^*}"
    [ "$file" = "$files" ] && files="" || files="${files#*,}"
    [ "$edit" = "$edits" ] && edits="" || edits="${edits#*^}"
    jq "$edit" "$dir/$prefix$file" >"$dir/edit.json"
    mv "$dir/edit.json" "$dir/$prefix$file"
  done
}

# Sets RAW, REPORT (the record, step and total lines), WRITES and RC.
# SECRETS `yes` hands the script both secret values; a dry run needs none.
run() { # FIXTURES SHIM_FAIL SECRETS ARGS...
  local fixtures="$1" fail="$2" secrets=""
  [ "$3" != yes ] || secrets=1
  shift 3
  RC=0
  rm -f -- "$fixtures/.writes.log"
  RAW="$(env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP" GH_SHIM_FIXTURES="$fixtures" GH_SHIM_FAIL="$fail" \
    ${secrets:+APP_ID=4242} ${secrets:+"APP_KEY=$KEY"} "$SKILL/scripts/provision-environment.sh" "$@" 2>&1)" || RC=$?
  REPORT="$(grep -E '^(provision(-total)? |  step=)' <<<"$RAW" || true)"
  WRITES=""
  if [ -f "$fixtures/.writes.log" ]; then
    WRITES="$(cat "$fixtures/.writes.log")"
  fi
}

# The record and step lines of one repository.
record_of() { # REPO
  awk -v head="provision repo=$1 " 'index($0, head) == 1 { on = 1; print; next } /^provision/ { on = 0 } on && /^  step=/ { print }' <<<"$REPORT"
}

# Each write as METHOD URL, or secret-set with its repository and name; the
# bodies and values are pinned once, below.
write_shapes() {
  sed -E 's/^(secret-set repo=[^ ]* env=[^ ]* name=[^ ]*) value=.*/\1/; s/^([A-Z]+ [^ ]+) .*/\1/' <<<"$WRITES"
}

echo "=== a dry run plans one create and one no-op ==="
run "$BASE" "" no --org acme --dry-run
want='provision repo=acme/done result=current
provision repo=acme/fresh result=would-create
  step=create-environment value=kendex
  step=add-policy value=branch:trunk
  step=set-secret value=APP_ID
  step=set-secret value=APP_KEY
provision-total repositories=2 changed=1 current=1 failed=0'
if [ "$RC" -eq 0 ] && [ "$REPORT" = "$want" ] && [ -z "$WRITES" ]; then
  ok "with no secret value, the provisioned repository is current, the other would be created step by step, the archived one is not listed, and nothing is written"
else
  bad "dry run (rc=$RC)" "$RAW
writes: $WRITES"
fi

echo "=== a dry run plans each drift's steps ==="
# name ~ fixture files under repos/acme/done ~ jq edits ~ acme/done's
# record and steps, `|`-separated
while IFS='~' read -r name files edits want; do
  [ -n "$name" ] || continue
  dir="$TMP/dry-$name"
  world "$dir" repos/acme/done/ "$files" "$edits"
  run "$dir" "" no --org acme --dry-run
  got="$(record_of acme/done | paste -sd '|' -)"
  if [ "$RC" -eq 0 ] && [ "$got" = "$want" ] && [ -z "$WRITES" ]; then
    ok "$name"
  else
    bad "$name (rc=$RC)" "want: $want
got:  $got
$RAW"
  fi
done <<'ROWS'
deploys from every branch~environments.json~.environments[1].deployment_branch_policy = null~provision repo=acme/done result=would-update|  step=switch-policy value=every-branch|  step=keep-only-policy value=branch:main
a second branch policy and a missing secret~branch-policies.json,environment-secrets-kendex.json~.branch_policies += [{"id": 2, "name": "dev", "type": "branch"}]^.secrets = [{"name": "APP_ID"}]~provision repo=acme/done result=would-update|  step=delete-policy value=branch:dev|  step=set-secret value=APP_KEY
ROWS

echo "=== a run creates the unprovisioned repository with these bodies ==="
run "$BASE" "" yes --org acme
want_writes="PUT repos/acme/fresh/environments/kendex
POST repos/acme/fresh/environments/kendex/deployment-branch-policies
secret-set repo=acme/fresh env=kendex name=APP_ID
secret-set repo=acme/fresh env=kendex name=APP_KEY"
put_body="$(sed -n 's/^PUT [^ ]* //p' <<<"$WRITES")"
put_policy=""
[ -z "$put_body" ] || put_policy="$(eval "printf '%s' $put_body" | jq -c '.deployment_branch_policy')"
key_line="$(grep '^secret-set repo=acme/fresh env=kendex name=APP_KEY ' <<<"$WRITES" || true)"
key_value=""
[ -z "$key_line" ] || eval "key_value=${key_line#* value=}"
if [ "$RC" -eq 0 ] &&
  [ "$(grep -x 'provision repo=acme/fresh result=created' <<<"$REPORT")" != "" ] &&
  [ "$(write_shapes)" = "$want_writes" ] &&
  [ "$put_policy" = '{"protected_branches":false,"custom_branch_policies":true}' ] &&
  grep -qx 'POST repos/acme/fresh/environments/kendex/deployment-branch-policies name=trunk\\ type=branch' <<<"$WRITES" &&
  grep -qx 'secret-set repo=acme/fresh env=kendex name=APP_ID value=4242' <<<"$WRITES" &&
  [ "$key_value" = "$KEY" ]; then
  ok "one environment on custom policies, the default branch as its policy, both secrets with the supplied values"
else
  bad "create (rc=$RC)" "$RAW
writes:
$WRITES"
fi

echo "=== each drift of the provisioned repository gets exactly its writes ==="
# name ~ shim failure ~ fixture files under repos/acme/done ~ jq edits ~
# acme/done's result ~ acme/done's writes (`;`-separated shapes). The
# switch rows hold the branch policies GitHub returns after the switch.
rows=0
while IFS='~' read -r name fail files edits result writes; do
  [ -n "$name" ] || continue
  rows=$((rows + 1))
  dir="$TMP/case-$rows"
  world "$dir" repos/acme/done/ "$files" "$edits"
  run "$dir" "$fail" yes --org acme
  got_result="$(sed -n 's/^provision repo=acme\/done result=//p' <<<"$REPORT")"
  got_writes="$(write_shapes | grep ' repo=acme/done \| repos/acme/done/' | paste -sd ';' - || true)"
  want_rc=0
  [ "$result" != failed ] || want_rc=1
  if [ "$RC" -eq "$want_rc" ] && [ "$got_result" = "$result" ] && [ "$got_writes" = "$writes" ]; then
    ok "$name"
  else
    bad "$name (rc=$RC, want $want_rc; result $got_result)" "want writes: $writes
got writes:  $got_writes
$RAW"
  fi
done <<'ROWS'
provisioned~~~~current~
environment absent~~environments.json~.environments |= [.[0]]~created~PUT repos/acme/done/environments/kendex;POST repos/acme/done/environments/kendex/deployment-branch-policies;secret-set repo=acme/done env=kendex name=APP_ID;secret-set repo=acme/done env=kendex name=APP_KEY
deploys from every branch~~environments.json,branch-policies.json~.environments[1].deployment_branch_policy = null^.branch_policies = []~updated~PUT repos/acme/done/environments/kendex;POST repos/acme/done/environments/kendex/deployment-branch-policies
deploys from protected branches~~environments.json,branch-policies.json~.environments[1].deployment_branch_policy = {"protected_branches": true, "custom_branch_policies": false}^.branch_policies = [{"id": 4, "name": "release", "type": "branch"}]~updated~PUT repos/acme/done/environments/kendex;DELETE repos/acme/done/environments/kendex/deployment-branch-policies/4;POST repos/acme/done/environments/kendex/deployment-branch-policies
deploys from every branch behind required reviewers~~environments.json~.environments[1].deployment_branch_policy = null | .environments[1].protection_rules += [{"id": 7, "type": "required_reviewers"}]~failed~
a second branch policy~~branch-policies.json~.branch_policies += [{"id": 2, "name": "dev", "type": "branch"}]~updated~DELETE repos/acme/done/environments/kendex/deployment-branch-policies/2
a tag policy named for the default branch~~branch-policies.json~.branch_policies = [{"id": 3, "name": "main", "type": "tag"}]~updated~DELETE repos/acme/done/environments/kendex/deployment-branch-policies/3;POST repos/acme/done/environments/kendex/deployment-branch-policies
no branch policy~~branch-policies.json~.branch_policies = []~updated~POST repos/acme/done/environments/kendex/deployment-branch-policies
a secret whose name only starts like a standard one~~environment-secrets-kendex.json~.secrets = [{"name": "APP_ID"}, {"name": "APP_KEY_OLD"}]~updated~secret-set repo=acme/done env=kendex name=APP_KEY
environments unreadable~environments~~~failed~
branch policies unreadable~branch-policies~~~failed~
secrets unreadable~environment-secrets-kendex~~~failed~
a secret write refused~secret-set~environment-secrets-kendex.json~.secrets = [{"name": "APP_ID"}]~failed~
ROWS
[ "$rows" -gt 0 ] || bad "the drift table ran no row" ""

echo "=== a failed repository does not stop the others ==="
# acme/done has no environment and its creation is refused; acme/fresh is
# provisioned on main, so its record shows the loop went on past the failure.
dir="$TMP/case-one-fails"
world "$dir" "" organization-repositories.json,repos/acme/done/environments.json '.[1].default_branch = "main"^.environments |= [.[0]]'
cp "$DONE/environments.json" "$DONE/branch-policies.json" "$DONE/environment-secrets-kendex.json" "$dir/repos/acme/fresh/"
run "$dir" PUT:environment yes --org acme
want='provision repo=acme/done result=failed
provision repo=acme/fresh result=current
provision-total repositories=2 changed=0 current=1 failed=1'
if [ "$RC" -eq 1 ] && [ "$REPORT" = "$want" ] && [ -z "$WRITES" ]; then
  ok "a repository after a failed one is still read"
else
  bad "a repository after a failed one is still read (rc=$RC)" "$RAW"
fi

echo "=== nothing is attempted ==="
# A PATH that holds bash and dirname and no jq.
NOJQ="$TMP/nojq"
mkdir -p "$NOJQ"
ln -s "$(command -v bash)" "$NOJQ/bash"
ln -s "$(command -v dirname)" "$NOJQ/dirname"
# name ~ shim failure ~ fixture files ~ jq edits ~ secret values (yes or
# no) ~ PATH ~ arguments (space-separated) ~ first error line
while IFS='~' read -r name fail files edits values path args key; do
  [ -n "$name" ] || continue
  dir="$TMP/refuse-$name"
  world "$dir" "" "$files" "$edits"
  secrets=""
  [ "$values" != yes ] || secrets=1
  RC=0
  rm -f -- "$dir/.writes.log"
  # shellcheck disable=SC2086
  RAW="$(env -i PATH="${path:-$BIN:/usr/bin:/bin}" HOME="$TMP" GH_SHIM_FIXTURES="$dir" GH_SHIM_FAIL="$fail" \
    ${secrets:+APP_ID=4242} ${secrets:+"APP_KEY=$KEY"} "$SKILL/scripts/provision-environment.sh" $args 2>&1)" || RC=$?
  first="${RAW%%
*}"
  if [ "$RC" -eq 2 ] && [ "${first%% value=*}" = "$key" ] && [ ! -e "$dir/.writes.log" ] && ! grep -qE '^provision(-total)? ' <<<"$RAW"; then
    ok "$name"
  else
    bad "$name (rc=$RC)" "$RAW"
  fi
done <<ROWS
no organization~~~~yes~~--dry-run~review-gate-error=org-missing
an unknown argument~~~~yes~~--org acme --repo acme/done~review-gate-error=unknown-argument
a secret value unset~~~~no~~--org acme~review-gate-error=secret-value-missing
no jq~~~~yes~$NOJQ~--org acme --dry-run~review-gate-error=jq-missing
the app on selected repositories~~installations.json~.installations[1].repository_selection = "selected"~yes~~--org acme~review-gate-error=app-selection
the app not installed~~installations.json~.installations |= [.[0]]~yes~~--org acme~review-gate-error=app-absent
installations unreadable~installations~~~yes~~--org acme~review-gate-error=installation-read
the organization unreadable~organization~~~yes~~--org acme~review-gate-error=organization-read
no private count for a credential that is not an owner~~organization.json~del(.total_private_repos)~yes~~--org acme~review-gate-error=organization-count
a repository the credential cannot see~~organization.json~.total_private_repos = 2~yes~~--org acme~review-gate-error=repositories-partial
repositories unreadable~organization-repositories~~~yes~~--org acme~review-gate-error=repositories-read
every repository archived~~organization-repositories.json~map(.archived = true)~yes~~--org acme~review-gate-error=repositories-none
ROWS

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
