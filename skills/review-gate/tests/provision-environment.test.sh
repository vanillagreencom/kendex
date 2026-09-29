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
  "ci_context": "CI",
  "gate_context": "Review gate"
}
JSON
cp "$TEST_DIR/lib/gh-shim.sh" "$BIN/gh"
chmod +x "$BIN/gh"
# The owner's checkouts the script runs from: `full` declares the
# organization's values in its kendex.settings.toml, `none` declares none,
# `shell` names a secret that bash holds as a shell variable only, and
# `contexts` adds, in .env.local, a REVIEW_GATE_STANDARD_CONTEXTS the
# settings reader refuses, which only validate-standard.sh's full mode
# reads. The layer is .env.local because the reader judges that layer one
# key at a time; it judges a kendex.settings.toml [env] table whole.
mkdir -p "$TMP/consumer-full" "$TMP/consumer-none" "$TMP/consumer-shell" "$TMP/consumer-contexts"
printf '%s\n' '[env]' 'REVIEW_GATE_STANDARD_APP = "lanes-app"' 'REVIEW_GATE_STANDARD_ENVIRONMENT = "kendex"' \
  'REVIEW_GATE_STANDARD_SECRETS = "APP_ID;APP_KEY"' >"$TMP/consumer-full/kendex.settings.toml"
sed 's/"APP_ID;APP_KEY"/"APP_ID;BASH_VERSION"/' "$TMP/consumer-full/kendex.settings.toml" >"$TMP/consumer-shell/kendex.settings.toml"
grep -qF '"APP_ID;BASH_VERSION"' "$TMP/consumer-shell/kendex.settings.toml" || { echo "provision-environment.test: consumer-shell=edit-missed" >&2; exit 1; }
printf '[env]\n' >"$TMP/consumer-none/kendex.settings.toml"
cp "$TMP/consumer-full/kendex.settings.toml" "$TMP/consumer-contexts/kendex.settings.toml"
printf '%s\n' 'REVIEW_GATE_STANDARD_CONTEXTS="CI"x' >"$TMP/consumer-contexts/.env.local"

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

# The trailing newline is part of the value: the create block pins that
# the script and the shim carry it through byte-exact.
KEY=$'-----BEGIN RSA PRIVATE KEY-----\nline two\n-----END RSA PRIVATE KEY-----\n'
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
# It runs from the checkout CONSUMER names, `full` when unset.
run() { # FIXTURES SHIM_FAIL SECRETS ARGS...
  local fixtures="$1" fail="$2" secrets=""
  [ "$3" != yes ] || secrets=1
  shift 3
  RC=0
  rm -f -- "$fixtures/.writes.log"
  RAW="$(cd "$TMP/consumer-${CONSUMER:-full}" && env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP" GH_SHIM_FIXTURES="$fixtures" GH_SHIM_FAIL="$fail" \
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

# The same plan from a checkout whose REVIEW_GATE_STANDARD_CONTEXTS the
# settings reader refuses: the provisioning run never resolves that key.
CONSUMER=contexts run "$BASE" "" no --org acme --dry-run
if [ "$RC" -eq 0 ] && [ "$REPORT" = "$want" ] && [ -z "$WRITES" ]; then
  ok "an unreadable REVIEW_GATE_STANDARD_CONTEXTS leaves the dry run's plan as it is"
else
  bad "unreadable contexts (rc=$RC)" "$RAW
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
# name ~ shim failure ~ fixture files ~ jq edits ~ secret values (yes, no,
# or empty-id: APP_ID exported empty) ~ PATH ~ arguments (space-separated) ~
# first error line ~ consumer (empty: full) ~ its value (empty: not compared)
while IFS='~' read -r name fail files edits values path args key consumer value; do
  [ -n "$name" ] || continue
  dir="$TMP/refuse-$name"
  world "$dir" "" "$files" "$edits"
  case "$values" in
    yes) secrets=1 app_id=4242 ;;
    empty-id) secrets=1 app_id="" ;;
    no) secrets="" app_id="" ;;
    *) echo "provision-environment.test: row=$name values=$values" >&2; exit 1 ;;
  esac
  RC=0
  rm -f -- "$dir/.writes.log"
  # shellcheck disable=SC2086
  RAW="$(cd "$TMP/consumer-${consumer:-full}" && env -i PATH="${path:-$BIN:/usr/bin:/bin}" HOME="$TMP" GH_SHIM_FIXTURES="$dir" GH_SHIM_FAIL="$fail" \
    ${secrets:+"APP_ID=$app_id"} ${secrets:+"APP_KEY=$KEY"} "$SKILL/scripts/provision-environment.sh" $args 2>&1)" || RC=$?
  first="${RAW%%
*}"
  if [ "$RC" -eq 2 ] && [ "${first%% value=*}" = "$key" ] && { [ -z "$value" ] || [ "${first#* value=}" = "$value" ]; } &&
    [ ! -e "$dir/.writes.log" ] && ! grep -qE '^provision(-total)? ' <<<"$RAW"; then
    ok "$name"
  else
    bad "$name (rc=$RC)" "$RAW"
  fi
done <<ROWS
no organization~~~~yes~~--dry-run~review-gate-error=org-missing
an unknown argument~~~~yes~~--org acme --repo acme/done~review-gate-error=unknown-argument
a secret value unset~~~~no~~--org acme~review-gate-error=secret-value-missing
a secret value exported empty~~~~empty-id~~--org acme~review-gate-error=secret-value-missing~~APP_ID
a secret named for a shell variable the environment lacks~~~~yes~~--org acme~review-gate-error=secret-value-missing~shell~BASH_VERSION
an owner checkout that declares nothing~~~~yes~~--org acme --dry-run~review-gate-error=standard-setting-missing~none~REVIEW_GATE_STANDARD_APP\,REVIEW_GATE_STANDARD_ENVIRONMENT\,REVIEW_GATE_STANDARD_SECRETS
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

# The secret reader's control reads the copy's value from the shell
# namespace, as the former indirect lookup did: BASH_VERSION, a shell
# variable the environment lacks, then reads as set, the run no longer
# refuses, and the shell's own value is written as the secret.
. "$TEST_DIR/lib/workflow-edit.sh"
cp "$SKILL/scripts/lib/standard.sh" "$TMP/standard-lib.keep"
file_edit "$SKILL" scripts/lib/standard.sh 1 'printenv -- "\$1"' 's/printenv -- "\$1"/echo "${!1:-}"/'
dir="$TMP/control-secret-value"
world "$dir" "" "" ""
RC=0
RAW="$(cd "$TMP/consumer-shell" && env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP" GH_SHIM_FIXTURES="$dir" GH_SHIM_FAIL="" \
  APP_ID=4242 "$SKILL/scripts/provision-environment.sh" --org acme 2>&1)" || RC=$?
if [ "$RC" -ne 2 ] && ! grep -q '^review-gate-error=secret-value-missing ' <<<"$RAW" &&
  grep -q '^secret-set repo=acme/done env=kendex name=BASH_VERSION ' "$dir/.writes.log" 2>/dev/null; then
  ok 'control: a reader of shell variables writes BASH_VERSION as a secret'
else
  bad "control: secret value reader (rc=$RC)" "$RAW"
fi
cp "$TMP/standard-lib.keep" "$SKILL/scripts/lib/standard.sh"

# The contexts key's scope guard: a copy that resolves it in the provision
# scope refuses the dry run the unreadable .env.local value above leaves as
# it is. The environment scope's control is in validate-standard.test.sh.
file_edit "$SKILL" scripts/lib/standard.sh 1 '^  if \[ "\$2" = full \]; then$' 's/^  if \[ "\$2" = full \]; then$/  if [ "$2" != environment ]; then/'
CONSUMER=contexts run "$BASE" "" no --org acme --dry-run
if [ "$RC" -eq 2 ] && [ -z "$REPORT" ] && [ -z "$WRITES" ]; then
  ok 'control: a contexts key resolved in the provision scope refuses the dry run'
else
  bad "control: contexts scope (rc=$RC)" "$RAW"
fi
cp "$TMP/standard-lib.keep" "$SKILL/scripts/lib/standard.sh"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
