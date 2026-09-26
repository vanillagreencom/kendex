#!/usr/bin/env bash
# provision-environment.sh against a fake GitHub holding one provisioned
# repository, one unprovisioned repository and one archived repository: a
# dry run plans exactly one create and one no-op and writes nothing, each
# drift of the provisioned one is converged by exactly the writes it needs,
# and a run that cannot enumerate or has no secret value writes nothing.
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
cat >"$BASE/organization-repositories.json" <<'JSON'
[
  {"full_name": "acme/done", "default_branch": "main", "archived": false},
  {"full_name": "acme/fresh", "default_branch": "trunk", "archived": false},
  {"full_name": "acme/old", "default_branch": "main", "archived": true}
]
JSON
DONE="$BASE/repos/acme/done"
cat >"$DONE/environments.json" <<'JSON'
{"environments": [{"name": "copilot", "deployment_branch_policy": null}, {"name": "kendex", "deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}]}
JSON
printf '{"branch_policies": [{"id": 1, "name": "main", "type": "branch"}]}\n' >"$DONE/branch-policies.json"
printf '{"secrets": [{"name": "APP_ID"}, {"name": "APP_KEY"}, {"name": "OTHER"}]}\n' >"$DONE/environment-secrets-kendex.json"
printf '{"environments": []}\n' >"$BASE/repos/acme/fresh/environments.json"

KEY='-----BEGIN RSA PRIVATE KEY-----
line two
-----END RSA PRIVATE KEY-----'

run() { # FIXTURES SHIM_FAIL ARGS... — sets RAW, RECORDS (record and total lines), WRITES and RC
  local fixtures="$1" fail="$2"
  shift 2
  RC=0
  rm -f -- "$fixtures/.writes.log"
  RAW="$(env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP" GH_SHIM_FIXTURES="$fixtures" GH_SHIM_FAIL="$fail" \
    APP_ID=4242 APP_KEY="$KEY" "$SKILL/scripts/provision-environment.sh" "$@" 2>&1)" || RC=$?
  RECORDS="$(grep -E '^provision(-total)? ' <<<"$RAW" || true)"
  WRITES=""
  if [ -f "$fixtures/.writes.log" ]; then
    WRITES="$(cat "$fixtures/.writes.log")"
  fi
}

# Each write as METHOD URL, or secret-set with its repository and name; the
# bodies and values are pinned once, below.
write_shapes() {
  sed -E 's/^(secret-set repo=[^ ]* env=[^ ]* name=[^ ]*) value=.*/\1/; s/^([A-Z]+ [^ ]+) .*/\1/' <<<"$WRITES"
}

echo "=== a dry run plans one create and one no-op ==="
run "$BASE" "" --org acme --dry-run
want='provision repo=acme/done result=current
provision repo=acme/fresh result=would-create
provision-total repositories=2 changed=1 current=1 failed=0'
if [ "$RC" -eq 0 ] && [ "$RECORDS" = "$want" ] && [ -z "$WRITES" ]; then
  ok "the provisioned repository is current, the other would be created, the archived one is not listed, and nothing is written"
else
  bad "dry run (rc=$RC)" "$RAW
writes: $WRITES"
fi
# A dry run needs no secret value.
RC=0
RAW="$(env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP" GH_SHIM_FIXTURES="$BASE" \
  "$SKILL/scripts/provision-environment.sh" --org acme --dry-run 2>&1)" || RC=$?
if [ "$RC" -eq 0 ] && grep -qx 'provision repo=acme/fresh result=would-create' <<<"$RAW"; then
  ok "a dry run without secret values"
else
  bad "a dry run without secret values (rc=$RC)" "$RAW"
fi

echo "=== a run creates the unprovisioned repository with these bodies ==="
run "$BASE" "" --org acme
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
  [ "$(grep -x 'provision repo=acme/fresh result=created' <<<"$RECORDS")" != "" ] &&
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
# name ~ shim failure ~ fixture file under repos/acme/done ~ jq edit ~
# acme/done's result ~ acme/done's writes (`;`-separated shapes)
rows=0
while IFS='~' read -r name fail file edit result writes; do
  [ -n "$name" ] || continue
  rows=$((rows + 1))
  dir="$TMP/case-$rows"
  cp -R "$BASE" "$dir"
  if [ -n "$file" ]; then
    jq "$edit" "$dir/repos/acme/done/$file" >"$dir/edit.json"
    mv "$dir/edit.json" "$dir/repos/acme/done/$file"
  fi
  run "$dir" "$fail" --org acme
  got_result="$(sed -n 's/^provision repo=acme\/done result=//p' <<<"$RECORDS")"
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
deploys from every branch~~environments.json~.environments[1].deployment_branch_policy = null~updated~PUT repos/acme/done/environments/kendex
deploys from protected branches~~environments.json~.environments[1].deployment_branch_policy = {"protected_branches": true, "custom_branch_policies": false}~updated~PUT repos/acme/done/environments/kendex
a second branch policy~~branch-policies.json~.branch_policies += [{"id": 2, "name": "dev", "type": "branch"}]~updated~DELETE repos/acme/done/environments/kendex/deployment-branch-policies/2
a tag policy named for the default branch~~branch-policies.json~.branch_policies = [{"id": 3, "name": "main", "type": "tag"}]~updated~DELETE repos/acme/done/environments/kendex/deployment-branch-policies/3;POST repos/acme/done/environments/kendex/deployment-branch-policies
no branch policy~~branch-policies.json~.branch_policies = []~updated~POST repos/acme/done/environments/kendex/deployment-branch-policies
a secret whose name only starts like a standard one~~environment-secrets-kendex.json~.secrets = [{"name": "APP_ID"}, {"name": "APP_KEY_OLD"}]~updated~secret-set repo=acme/done env=kendex name=APP_KEY
environments unreadable~environments~~~failed~
branch policies unreadable~branch-policies~~~failed~
secrets unreadable~environment-secrets-kendex~~~failed~
the environment write refused~PUT:environment~environments.json~.environments |= [.[0]]~failed~
a secret write refused~secret-set~environment-secrets-kendex.json~.secrets = [{"name": "APP_ID"}]~failed~
ROWS
[ "$rows" -gt 0 ] || bad "the drift table ran no row" ""

echo "=== a failed repository does not stop the others ==="
# acme/done has no environment and its creation is refused; acme/fresh is
# provisioned on main, so its record shows the loop went on past the failure.
dir="$TMP/case-one-fails"
cp -R "$BASE" "$dir"
jq '.[1].default_branch = "main"' "$BASE/organization-repositories.json" >"$dir/organization-repositories.json"
cp "$DONE/environments.json" "$DONE/branch-policies.json" "$DONE/environment-secrets-kendex.json" "$dir/repos/acme/fresh/"
jq '.environments |= [.[0]]' "$DONE/environments.json" >"$dir/repos/acme/done/environments.json"
run "$dir" PUT:environment --org acme
want='provision repo=acme/done result=failed
provision repo=acme/fresh result=current
provision-total repositories=2 changed=0 current=1 failed=1'
if [ "$RC" -eq 1 ] && [ "$RECORDS" = "$want" ] && [ -z "$WRITES" ]; then
  ok "a repository after a failed one is still read"
else
  bad "a repository after a failed one is still read (rc=$RC)" "$RAW"
fi

echo "=== nothing is attempted ==="
# name ~ shim failure ~ fixture file ~ jq edit ~ secret variable left unset
# ~ arguments (space-separated) ~ first error line
while IFS='~' read -r name fail file edit drop args key; do
  [ -n "$name" ] || continue
  dir="$TMP/refuse-$name"
  cp -R "$BASE" "$dir"
  if [ -n "$file" ]; then
    jq "$edit" "$dir/$file" >"$dir/edit.json"
    mv "$dir/edit.json" "$dir/$file"
  fi
  RC=0
  rm -f -- "$dir/.writes.log"
  set -- APP_ID=4242 APP_KEY="$KEY"
  [ "$drop" != APP_ID ] || set -- APP_KEY="$KEY"
  # shellcheck disable=SC2086
  RAW="$(env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP" GH_SHIM_FIXTURES="$dir" GH_SHIM_FAIL="$fail" "$@" \
    "$SKILL/scripts/provision-environment.sh" $args 2>&1)" || RC=$?
  first="${RAW%%
*}"
  if [ "$RC" -eq 2 ] && [ "${first%% value=*}" = "$key" ] && [ ! -e "$dir/.writes.log" ] && ! grep -qE '^provision(-total)? ' <<<"$RAW"; then
    ok "$name"
  else
    bad "$name (rc=$RC)" "$RAW"
  fi
done <<'ROWS'
no organization~~~~~--dry-run~review-gate-error=org-missing
an unknown argument~~~~~--org acme --repo acme/done~review-gate-error=unknown-argument
a secret value unset~~~~APP_ID~--org acme~review-gate-error=secret-value-missing
the app on selected repositories~~installations.json~.installations[1].repository_selection = "selected"~~--org acme~review-gate-error=app-selection
the app not installed~~installations.json~.installations |= [.[0]]~~--org acme~review-gate-error=app-absent
installations unreadable~installations~~~~--org acme~review-gate-error=installation-read
repositories unreadable~organization-repositories~~~~--org acme~review-gate-error=repositories-read
every repository archived~~organization-repositories.json~map(.archived = true)~~--org acme~review-gate-error=repositories-none
ROWS

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
