#!/usr/bin/env bash
# Exercise consumer adoption with the real environment validator.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)" || { echo 'adopt-refresh: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP && ! -L $TMP ]] || { echo "adopt-refresh: scratch=not-a-directory value=[$TMP]" >&2; exit 1; }
TMP="$(cd -- "$TMP" && pwd -P)" || { echo 'adopt-refresh: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT
. "$TEST_DIR/lib/refresh-fixture.sh"
ADOPT='.agents/skills/review-gate/scripts/adopt-refresh.sh'
REFRESH='.github/workflows/kendex-refresh.yml'
TEMPLATE='.agents/skills/review-gate/templates/kendex-refresh.yml'


sandbox
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 0 ] && adoption_metadata "$DIR" "$REFRESH" "$TEMPLATE"; then ok 'adoption copies both templates and records exact metadata'; else bad "initial adoption (rc=$RC)" "$OUT"; fi
cp "$DIR/.kendex-generated.json" "$TMP/inventory-before"
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 0 ] && cmp -s "$TMP/inventory-before" "$DIR/.kendex-generated.json"; then ok 'repeated adoption keeps the inventory unchanged'; else bad "repeated adoption (rc=$RC)" "$OUT"; fi

# Refresh records the new template hash before adoption. The earlier template
# in history proves that the old workflow copy remains unedited.
commit "$DIR"
printf '\n# new template bytes\n' >>"$DIR/$TEMPLATE"
record_template_hash
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 0 ] && adoption_metadata "$DIR" "$REFRESH" "$TEMPLATE" && ! grep -q '^refresh-warning=' <<<"$OUT"; then ok 'template history permits a silent update despite a changed inventory hash'; else bad "template history adoption (rc=$RC)" "$OUT"; fi

# Consumer installs can lack workflow records. A preserved checkout supplies
# both its vendored bytes and older shipped versions in history.
# input | record | warning
while IFS='|' read -r input record warning; do
  sandbox
  cp "$DIR/$TEMPLATE" "$DIR/$REFRESH"
  if [ "$input" = hand-edit ]; then
    file_edit "$DIR" "$REFRESH" 1 '^name: ' 's/^name: .*/name: consumer edit/'
  fi
  if [ "$record" = matching ]; then
    python3 - "$DIR" "$REFRESH" "$TEMPLATE" <<'RECORD'
import hashlib, json, sys
from pathlib import Path
root = Path(sys.argv[1]); inventory = root / '.kendex-generated.json'
entries = json.loads(inventory.read_text())
entries.append({'path': sys.argv[2], 'template': sys.argv[3], 'templateHash': 'sha256:' + hashlib.sha256((root / sys.argv[2]).read_bytes()).hexdigest()})
inventory.write_text(json.dumps(entries))
RECORD
  fi
  # Later committed templates must not make older history unreachable.
  if [ "$input" = historical ]; then printf '# intermediate shipped bytes\n' >>"$DIR/$TEMPLATE"; fi
  commit "$DIR"
  trusted="$TMP/trusted-$SANDBOX_N"
  git -C "$DIR" worktree add --detach -q "$trusted" HEAD
  if [ "$input" = vendored ]; then
    # Neither history nor the refreshed template holds this version.
    printf '# preserved vendored bytes\n' >>"$trusted/$TEMPLATE"
    cp "$trusted/$TEMPLATE" "$DIR/$REFRESH"
  fi
  if [ "$input" != current ]; then printf '# new template bytes\n' >>"$DIR/$TEMPLATE"; fi
  run_refresh_command "$DIR" "$trusted/$ADOPT" --templates-dir "$DIR/.agents/skills/review-gate/templates" --workflow-edit-report "$TMP/edit-report"
  if [ "$warning" = yes ]; then
    if workflow_edit_matches "$TMP/edit-report" "$REFRESH:8" && adoption_metadata "$DIR" "$REFRESH" "$TEMPLATE"; then
      ok "$input record=$record replaces the edit with one warning and a first-line report"
    else bad "$input record=$record (rc=$RC)" "$OUT"; fi
  elif [ "$RC" -eq 0 ] && ! grep -q '^refresh-warning=' <<<"$OUT" && [ ! -s "$TMP/edit-report" ] && adoption_metadata "$DIR" "$REFRESH" "$TEMPLATE"; then
    ok "$input record=$record adopts silently and records the written copy"
  else bad "$input record=$record (rc=$RC)" "$OUT"; fi
done <<'ROWS'
current|missing|no
historical|missing|no
historical|matching|no
vendored|missing|no
hand-edit|missing|yes
hand-edit|matching|yes
ROWS

# Keep the warning text but disable its producer. The edited copy still
# updates; the warning/report assertion must turn red.
file_edit "$trusted" "$ADOPT" 1 '^    if not shipped:$' 's/^    if not shipped:$/    if False and not shipped:/'
chmod +x "$trusted/$ADOPT"
file_edit "$DIR" "$REFRESH" 1 '^name: ' 's/^name: .*/name: consumer edit/'
run_refresh_command "$DIR" "$trusted/$ADOPT" --templates-dir "$DIR/.agents/skills/review-gate/templates" --workflow-edit-report "$TMP/edit-report"
if [ "$RC" -eq 0 ] && adoption_metadata "$DIR" "$REFRESH" "$TEMPLATE" && ! workflow_edit_matches "$TMP/edit-report" "$REFRESH:8"; then
  ok 'control: silenced edit detection breaks the warning/report assertion'
else bad 'workflow edit warning control' "$OUT"; fi

# A workflow symlink comes from a consumer checkout. Never write its target.
sandbox
cp "$DIR/$TEMPLATE" "$TMP/symlink-target"
ln -s "$TMP/symlink-target" "$DIR/$REFRESH"
cp "$DIR/.kendex-generated.json" "$TMP/symlink-inventory"
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 1 ] && grep -qxF "refresh-error=workflow-symlink value=$DIR/$REFRESH" <<<"$OUT" &&
    cmp -s "$TMP/symlink-target" "$DIR/$TEMPLATE" && cmp -s "$TMP/symlink-inventory" "$DIR/.kendex-generated.json"; then
  ok 'workflow-symlink stops adoption without writing its target or inventory'
else bad 'workflow symlink stop' "$OUT"; fi
file_edit "$DIR" "$ADOPT" 1 '^if refresh\.is_symlink\(\):$' 's/^if refresh\.is_symlink():$/if False and refresh.is_symlink():/'
chmod +x "$DIR/$ADOPT"
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 0 ] && ! grep -q '^refresh-error=workflow-symlink ' <<<"$OUT"; then
  ok 'control: disabled symlink guard breaks the must-fail row'
else bad 'workflow symlink control' "$OUT"; fi

sandbox
printf '{"environments":[]}\n' >"$FIXTURES/environments.json"
cp "$DIR/.kendex-generated.json" "$TMP/inventory-before"
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 1 ] && grep -qF 'scripts/provision-environment.sh --org acme' <<<"$OUT" &&
    [ ! -e "$DIR/$REFRESH" ] &&
    cmp -s "$TMP/inventory-before" "$DIR/.kendex-generated.json"; then
  ok 'an absent environment refuses adoption before any workflow copy'
else
  bad "environment refusal (rc=$RC)" "$OUT"
fi

# Adoption must consume the environment validator's status, even if the
# validator still emits the same failure record and provisioning command.
file_edit "$DIR" "$ADOPT" 1 '^  "\$SCRIPT_DIR/validate-standard.sh" --environment-only$' \
  's/ --environment-only$/ --environment-only || true/'
chmod +x "$DIR/$ADOPT"
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 0 ] && adoption_metadata "$DIR" "$REFRESH" "$TEMPLATE"; then ok 'control: ignored environment failure allows adoption'; else bad "control: environment guard (rc=$RC)" "$OUT"; fi

# Adoption judges the environment and secrets the refresh template reads. The
# consumer's settings name another environment, fully provisioned, and each
# row leaves the template's short in one way; the failed check is its own.
KENDEX_ENVIRONMENT='{"name":"kendex","deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
OTHER_ENVIRONMENT='{"name":"other","deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
printf '{"secrets":[{"name":"OTHER_ID"},{"name":"OTHER_KEY"}]}\n' >"$FIXTURES/environment-secrets-other.json"
cp "$FIXTURES/environment-secrets-kendex.json" "$TMP/kendex-secrets"
# name ~ environments listed ~ kendex's secrets ~ failed verdict line
while IFS='~' read -r name environments secrets verdict; do
  sandbox
  settings "$DIR" REVIEW_GATE_STANDARD_ENVIRONMENT other
  settings "$DIR" REVIEW_GATE_STANDARD_SECRETS 'OTHER_ID;OTHER_KEY'
  commit "$DIR"
  printf '{"environments":[%s]}\n' "$environments" >"$FIXTURES/environments.json"
  printf '{"secrets":[%s]}\n' "$secrets" >"$FIXTURES/environment-secrets-kendex.json"
  run_refresh_command "$DIR" "$DIR/$ADOPT"
  if [ "$RC" -eq 1 ] && grep -qxF "$verdict" <<<"$OUT" && [ ! -e "$DIR/$REFRESH" ]; then
    ok "$name refuses adoption whatever the settings name"
  else
    bad "$name (rc=$RC)" "$OUT"
  fi
done <<ROWS
the template's environment absent~$OTHER_ENVIRONMENT~~FAIL check=standard-environment value=absent
the template's environment short of a secret~$KENDEX_ENVIRONMENT,$OTHER_ENVIRONMENT~{"name":"FLEET_GH_APP_ID"}~FAIL check=standard-environment-secrets value=FLEET_GH_APP_ID
ROWS

# The control keeps the template's names in the script and stops passing them
# to the validator, which then reads the consumer's settings and adopts.
file_edit "$DIR" "$ADOPT" 1 '^REVIEW_GATE_STANDARD_ENVIRONMENT="\$template_environment" REVIEW_GATE_STANDARD_SECRETS=' \
  's/^REVIEW_GATE_STANDARD_ENVIRONMENT=\(.*\) REVIEW_GATE_STANDARD_SECRETS=/TEMPLATE_ENVIRONMENT=\1 TEMPLATE_SECRETS=/'
chmod +x "$DIR/$ADOPT"
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 0 ] && adoption_metadata "$DIR" "$REFRESH" "$TEMPLATE"; then
  ok 'control: the settings-named environment adopts once the template names stay unpassed'
else bad "control: template names (rc=$RC)" "$OUT"; fi
printf '{"environments":[%s]}\n' "$KENDEX_ENVIRONMENT" >"$FIXTURES/environments.json"
cp "$TMP/kendex-secrets" "$FIXTURES/environment-secrets-kendex.json"

sandbox
printf '{"full_name":"vanillagreencom/kendex","default_branch":"main"}\n' >"$FIXTURES/repository.json"
cp "$DIR/.kendex-generated.json" "$TMP/self-inventory"
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 0 ] && [ ! -e "$DIR/$REFRESH" ] && cmp -s "$TMP/self-inventory" "$DIR/.kendex-generated.json"; then
  ok 'kendex adoption leaves workflows and inventory unchanged'
else bad 'kendex self-exclusion' "$OUT"; fi
file_edit "$DIR" "$ADOPT" 1 'if \[ "\$repository" = vanillagreencom/kendex \]; then' \
  's/if \[ "\$repository" = vanillagreencom\/kendex \]; then/if false; then/'
chmod +x "$DIR/$ADOPT"
printf '{"environments":[{"name":"kendex","deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}]}\n' >"$FIXTURES/environments.json"
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 0 ] && [ -e "$DIR/$REFRESH" ]; then
  ok 'control: removed self-exclusion adopts the consumer workflow in kendex'
else bad 'self-exclusion control did not reach adoption' "$OUT"; fi

sandbox
printf '{"full_name":"acme/widgets","default_branch":"main"}\n' >"$FIXTURES/repository.json"
run_refresh_command "$DIR" "$DIR/$ADOPT"
[ "$RC" -eq 0 ] && adoption_metadata "$DIR" "$REFRESH" "$TEMPLATE" || exit 1
# Refresh records the new template hash before adoption, as above.
commit "$DIR"
printf '\n# new template bytes\n' >>"$DIR/$TEMPLATE"
record_template_hash
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 0 ] && adoption_metadata "$DIR" "$REFRESH" "$TEMPLATE"; then
  ok 'no-writer refresh updates an unedited refresh workflow'
else bad "no-writer template update (rc=$RC)" "$OUT"; fi
commit "$DIR"
# The appended blank line differs first, immediately after the unedited copy.
first_edit_line="$(awk 'END { print NR + 1 }' "$DIR/$REFRESH")" || exit 1
printf '\n# consumer edit\n' >>"$DIR/$REFRESH"
run_refresh_command "$DIR" "$DIR/$ADOPT" --workflow-edit-report "$TMP/no-writer-report"
if workflow_edit_matches "$TMP/no-writer-report" "$REFRESH:$first_edit_line" && adoption_metadata "$DIR" "$REFRESH" "$TEMPLATE"; then
  ok 'no-writer adoption reconciles an edited refresh workflow and reports its first divergent line'
else bad "no-writer edited refresh (rc=$RC)" "$OUT"; fi

# Keep the report and warning but replace the measured line with the name
# field's line. A later edit must not accept that constant location.
file_edit "$DIR" "$ADOPT" 1 '\{relative\}:\{line\}' 's/{relative}:{line}/{relative}:8/'
chmod +x "$DIR/$ADOPT"
printf '\n# consumer edit\n' >>"$DIR/$REFRESH"
run_refresh_command "$DIR" "$DIR/$ADOPT" --workflow-edit-report "$TMP/no-writer-report"
if adoption_metadata "$DIR" "$REFRESH" "$TEMPLATE" && workflow_edit_matches "$TMP/no-writer-report" "$REFRESH:8" &&
    ! workflow_edit_matches "$TMP/no-writer-report" "$REFRESH:$first_edit_line"; then
  ok 'control: a constant report line breaks the appended-edit location assertion'
else bad 'first divergent line control' "$OUT"; fi

OWNER=".agents/skills/review-gate/templates/review-gate-writer.yml"
# The automatic runner invokes its preserved adopter without retirement
# input, while reading templates from the refreshed checkout.
while IFS='|' read -r mutation expected; do
  sandbox
  writer='.github/workflows/retired.yml'
  printf 'retired workflow\n' >"$DIR/$writer"
  record_adoption "$DIR" "$writer" "$OWNER"
  commit "$DIR"
  trusted="$TMP/automatic-$SANDBOX_N"
  git -C "$DIR" worktree add --detach -q "$trusted" HEAD
  case "$mutation" in
    none) ;;
    retirement)
      file_edit "$trusted" "$ADOPT" 1 '^retiring = retired if ' 's/else \[\]$/else retired/' ;;
    warning)
      file_edit "$trusted" "$ADOPT" 1 '^    print\("refresh-warning=legacy-writer' 's/^    print/    # print/' ;;
    *) exit 2 ;;
  esac
  run_refresh_command "$DIR" "$trusted/$ADOPT" --templates-dir "$DIR/.agents/skills/review-gate/templates"
  warning_count="$(awk '/^refresh-warning=legacy-writer / { count++ } END { print count + 0 }' <<<"$OUT")" || exit 1
  matched=no
  if retirement_matches "$DIR" "$writer" "$OWNER" preserved &&
      [ "$warning_count" -eq 1 ] && grep -qxF "refresh-warning=legacy-writer value=$OWNER" <<<"$OUT"; then matched=yes; fi
  if [ "$RC" -eq 0 ] && [ "$matched" = "$expected" ]; then ok "automatic legacy writer mutation=$mutation"; else bad "automatic legacy writer mutation=$mutation (rc=$RC)" "$OUT"; fi
done <<'AUTOMATIC'
none|yes
retirement|no
warning|no
AUTOMATIC

while IFS='|' read -r kind expected; do
  sandbox
  writer="$DIR/.github/workflows/retired.yml"
  printf 'retired workflow\n' >"$writer"
  record_adoption "$DIR" .github/workflows/retired.yml "$OWNER"
  commit "$DIR"
  case "$kind" in
    initial) rm -- "${writer:?}"; printf '[]\n' >"$DIR/.kendex-generated.json" ;;
    new-install)
      rm -- "${writer:?}"
      git -C "$DIR" rm -q .kendex-generated.json
      commit "$DIR"
      printf '[]\n' >"$DIR/.kendex-generated.json" ;;
    retired|repeat) ;;
    missing) rm "$writer" ;;
    edited) printf 'consumer edit\n' >>"$writer" ;;
    symlink) mv "$writer" "$DIR/target"; ln -s ../../target "$writer" ;;
    unrecorded) mv "$writer" "$DIR/.github/workflows/review-gate-writer.yml"; writer="$DIR/.github/workflows/review-gate-writer.yml" ;;
    refresh-symlink|update)
      cp "$DIR/$TEMPLATE" "$DIR/$REFRESH"
      record_adoption "$DIR" "$REFRESH" "$TEMPLATE"
      commit "$DIR"
      case "$kind" in
        refresh-symlink) mv "$DIR/$REFRESH" "$DIR/refresh-target"; ln -s ../../refresh-target "$DIR/$REFRESH" ;;
        update) printf '\n# updated template\n' >>"$DIR/$TEMPLATE" ;;
      esac ;;
    environment) SHIM_FAIL='environments' ;;
    excluded) printf '{"full_name":"vanillagreencom/kendex","default_branch":"main"}\n' >"$FIXTURES/repository.json" ;;
    *) exit 2 ;;
  esac
  cp "$DIR/.kendex-generated.json" "$TMP/before"
  run_refresh_command "$DIR" "$DIR/$ADOPT" --retire-writer
  if [ "$expected" = pass ]; then
    if [ "$RC" -eq 0 ] && [ ! -e "$writer" ] && adoption_metadata "$DIR" "$REFRESH" "$TEMPLATE"; then ok "$kind"; else bad "$kind (rc=$RC)" "$OUT"; fi
    if [ "$kind" = retired ]; then
      if retirement_matches "$DIR" .github/workflows/retired.yml "$OWNER" removed; then
        ok 'explicit trusted retirement removes the writer and record'
      else bad 'explicit trusted retirement' "$OUT"; fi
      cp "$TMP/before" "$DIR/.kendex-generated.json"
      printf 'retired workflow\n' >"$writer"
      file_edit "$DIR" "$ADOPT" 1 '^retiring = retired if ' 's/^retiring = retired if /retiring = [] if /'
      run_refresh_command "$DIR" "$DIR/$ADOPT" --retire-writer
      if [ "$RC" -eq 0 ] && ! retirement_matches "$DIR" .github/workflows/retired.yml "$OWNER" removed; then
        ok 'control: disabled explicit retirement breaks the removal assertion'
      else bad 'explicit retirement control' "$OUT"; fi
    fi
    if [ "$kind" = repeat ]; then
      cp "$DIR/.kendex-generated.json" "$TMP/repeated"
      run_refresh_command "$DIR" "$DIR/$ADOPT" --retire-writer
      if [ "$RC" -eq 0 ] && cmp -s "$TMP/repeated" "$DIR/.kendex-generated.json" &&
          ! grep -q '^refresh-warning=legacy-writer ' <<<"$OUT"; then ok 'repeat unchanged without a legacy warning'; else bad 'repeat unchanged' "$OUT"; fi
    fi
  elif [ "$expected" = excluded ]; then
    if [ "$RC" -eq 0 ] && cmp -s "$TMP/before" "$DIR/.kendex-generated.json" && [ ! -e "$DIR/$REFRESH" ]; then ok "$kind"; else bad "$kind" "$OUT"; fi
  else
    if [ "$RC" -ne 0 ] && cmp -s "$TMP/before" "$DIR/.kendex-generated.json" && [ -e "$writer" ] && { [ "$expected" = environment ] || grep -q "^refresh-error=$expected value=" <<<"$OUT"; }; then ok "$kind"; else bad "$kind (rc=$RC)" "$OUT"; fi
  fi
  SHIM_FAIL=''
  printf '{"full_name":"acme/widgets","default_branch":"main"}\n' >"$FIXTURES/repository.json"
done <<'CASES'
initial|pass
new-install|pass
retired|pass
repeat|pass
missing|pass
edited|workflow-edited
symlink|workflow-symlink
unrecorded|workflow-unrecorded
refresh-symlink|workflow-symlink
update|pass
environment|environment
excluded|excluded
CASES

# Each independent ownership guard keeps its diagnostic and operands while
# the control disables its condition in a disposable script copy.
while IFS='|' read -r kind pattern replacement; do
  sandbox
  writer="$DIR/.github/workflows/retired.yml"
  printf 'retired workflow\n' >"$writer"
  record_adoption "$DIR" .github/workflows/retired.yml "$OWNER"
  commit "$DIR"
  case "$kind" in
    retired-edited) printf 'consumer edit\n' >>"$writer" ;;
    retired-symlink) mv "$writer" "$DIR/target"; ln -s ../../target "$writer" ;;
    unrecorded) mv "$writer" "$DIR/.github/workflows/review-gate-writer.yml" ;;
    refresh-symlink)
      cp "$DIR/$TEMPLATE" "$DIR/$REFRESH"
      record_adoption "$DIR" "$REFRESH" "$TEMPLATE"
      commit "$DIR"
      mv "$DIR/$REFRESH" "$DIR/refresh-target"; ln -s ../../refresh-target "$DIR/$REFRESH" ;;
  esac
  file_edit "$DIR" "$ADOPT" 1 "$pattern" "$replacement" 1
  run_refresh_command "$DIR" "$DIR/$ADOPT" --retire-writer
  if [ "$RC" -eq 0 ]; then ok "$kind control allows the forbidden mutation"; else bad "$kind control did not reach the guard" "$OUT"; fi
done <<'CONTROLS'
retired-edited|^        if not copied.is_file|s/^        if \(.*\):$/        if False and (\1):/
retired-symlink|^    if copied.is_symlink|s/^    if \(.*\):$/    if False and (\1):/
unrecorded|^if.*unrecorded.exists|s/^if \(.*\):$/if False and (\1):/
refresh-symlink|^if refresh.is_symlink|s/^if \(.*\):$/if False and (\1):/
CONTROLS
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
