#!/usr/bin/env bash
# Exercise consumer adoption with the real environment and workflow validators.
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
printf '[".agents/skills/other/SKILL.md",{"path":".github/workflows/other.yml","template":".agents/skills/other/templates/other.yml","templateHash":"sha256:0000000000000000000000000000000000000000000000000000000000000000"}]\n' >"$PRISTINE/.kendex-generated.json"


sandbox
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 0 ] && adoption_metadata; then ok 'adoption copies both templates and records exact metadata'; else bad "initial adoption (rc=$RC)" "$OUT"; fi
cp "$DIR/.kendex-generated.json" "$TMP/inventory-before"
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 0 ] && cmp -s "$TMP/inventory-before" "$DIR/.kendex-generated.json"; then ok 'repeated adoption keeps the inventory unchanged'; else bad "repeated adoption (rc=$RC)" "$OUT"; fi

# Refresh records the new template hash before adoption. The earlier template
# in history proves that the old workflow copy remains unedited.
commit "$DIR"
printf '\n# new template bytes\n' >>"$DIR/$TEMPLATE"
record_template_hash
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 0 ] && adoption_metadata && ! grep -q '^refresh-warning=' <<<"$OUT"; then ok 'template history permits a silent update despite a changed inventory hash'; else bad "template history adoption (rc=$RC)" "$OUT"; fi

# Consumer installs can lack workflow records. A preserved checkout supplies
# both its vendored bytes and older shipped versions in history.
# input | record | warning | writer
while IFS='|' read -r input record warning writer; do
  sandbox
  if [ "$writer" = absent ]; then
    rm -- "${DIR:?}/.github/workflows/review-gate-writer.yml"
    settings "$DIR" REVIEW_GATE_WRITER optional
    settings "$DIR" REVIEW_GATE_MODE off
  fi
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
  writer_name=review-gate-writer.yml
  [ "$writer" != absent ] || writer_name=-
  if [ "$warning" = yes ]; then
    if workflow_edit_matches "$TMP/edit-report" "$REFRESH:8" && adoption_metadata "$writer_name"; then
      ok "$input record=$record writer=$writer replaces the edit with one warning and a first-line report"
    else bad "$input record=$record writer=$writer (rc=$RC)" "$OUT"; fi
  elif [ "$RC" -eq 0 ] && ! grep -q '^refresh-warning=' <<<"$OUT" && [ ! -s "$TMP/edit-report" ] && adoption_metadata "$writer_name"; then
    ok "$input record=$record writer=$writer adopts silently and records the written copy"
  else bad "$input record=$record writer=$writer (rc=$RC)" "$OUT"; fi
done <<'ROWS'
current|missing|no|present
historical|missing|no|present
historical|matching|no|present
vendored|missing|no|present
hand-edit|missing|yes|present
hand-edit|matching|yes|present
hand-edit|missing|yes|absent
ROWS

# Keep the warning text but disable its producer. The edited copy still
# updates; the warning/report assertion must turn red.
file_edit "$trusted" "$ADOPT" 1 '^    if not shipped:$' 's/^    if not shipped:$/    if False and not shipped:/'
chmod +x "$trusted/$ADOPT"
file_edit "$DIR" "$REFRESH" 1 '^name: ' 's/^name: .*/name: consumer edit/'
run_refresh_command "$DIR" "$trusted/$ADOPT" --templates-dir "$DIR/.agents/skills/review-gate/templates" --workflow-edit-report "$TMP/edit-report"
if [ "$RC" -eq 0 ] && adoption_metadata - && ! workflow_edit_matches "$TMP/edit-report" "$REFRESH:8"; then
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

# A supported check_run opt-in changes the writer's bytes. Adoption must keep
# those bytes and remove the render record from its earlier exact adoption.
sandbox
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -ne 0 ] || ! jq -e 'any(.[] | objects; .path == ".github/workflows/review-gate-writer.yml")' \
    "$DIR/.kendex-generated.json" >/dev/null; then
  bad "customized writer setup has no prior adoption record (rc=$RC)" "$OUT"
  exit 1
fi
cp "$DIR/.kendex-generated.json" "$TMP/opt-in-inventory-before"
workflow_edit "$DIR" 2 '^  # +(check_run:|types: \[created, completed\]$)' \
  's|^  #   check_run:$|  check_run:|; s|^  #     types: \[created, completed\]$|    types: [created, completed]|'
cp "$DIR/.github/workflows/review-gate-writer.yml" "$TMP/opt-in-writer-before"
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 0 ] && cmp -s "$TMP/opt-in-writer-before" "$DIR/.github/workflows/review-gate-writer.yml" &&
    python3 - "$DIR/.kendex-generated.json" "$TMP/opt-in-inventory-before" <<'PY_OPT_IN'
import json
from pathlib import Path
import sys
before = json.loads(Path(sys.argv[2]).read_text())
expected = [e for e in before if not isinstance(e, dict) or e["path"] != ".github/workflows/review-gate-writer.yml"]
assert json.loads(Path(sys.argv[1]).read_text()) == expected
PY_OPT_IN
then
  ok 'check_run opt-in preserves writer bytes and removes its stale render record'
else
  bad "customized writer adoption (rc=$RC)" "$OUT"
fi

sandbox
printf '{"environments":[]}\n' >"$FIXTURES/environments.json"
cp "$DIR/.github/workflows/review-gate-writer.yml" "$TMP/writer-before"
cp "$DIR/.kendex-generated.json" "$TMP/inventory-before"
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 1 ] && grep -qF 'scripts/provision-environment.sh --org acme' <<<"$OUT" &&
    [ ! -e "$DIR/$REFRESH" ] && cmp -s "$TMP/writer-before" "$DIR/.github/workflows/review-gate-writer.yml" &&
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
if [ "$RC" -eq 0 ] && adoption_metadata; then ok 'control: ignored environment failure allows adoption'; else bad "control: environment guard (rc=$RC)" "$OUT"; fi

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
if [ "$RC" -eq 0 ] && adoption_metadata; then
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

# Template ownership survives adoption, a writer rename, and a later update.
sandbox
printf '{"full_name":"acme/widgets","default_branch":"main"}\n' >"$FIXTURES/repository.json"
run_refresh_command "$DIR" "$DIR/$ADOPT"
[ "$RC" -eq 0 ] && adoption_metadata || exit 1
cp "$DIR/.kendex-generated.json" "$TMP/renamed-before"
commit "$DIR"
(cd "$DIR" && git mv .github/workflows/review-gate-writer.yml .github/workflows/gate.yml)
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 0 ] && adoption_metadata gate.yml; then
  ok 'renamed writer adoption records the validator-selected path'
else bad 'renamed writer initial adoption' "$OUT"; fi
commit "$DIR"
file_edit "$DIR" .agents/skills/review-gate/templates/review-gate-writer.yml 1 '^    timeout-minutes: 15$' \
  's/^    timeout-minutes: 15$/    timeout-minutes: 16/'
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 0 ] && adoption_metadata gate.yml; then
  ok 'renamed writer update retains exact inventory metadata'
else bad 'renamed writer template update' "$OUT"; fi
python3 - "$DIR/$ADOPT" <<'PATH_CONTROL'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(); needle='not isinstance(e, dict) or e["template"] != owner'
assert s.count(needle)==1
p.write_text(s.replace(needle,'path_of(e) != relative')+"\n# "+needle+"\n")
PATH_CONTROL
cp "$TMP/renamed-before" "$DIR/.kendex-generated.json"
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 0 ] && jq -e 'any(.[] | objects; .path == ".github/workflows/review-gate-writer.yml") and any(.[] | objects; .path == ".github/workflows/gate.yml")' "$DIR/.kendex-generated.json" >/dev/null; then
  ok 'control: path ownership retains the stale record after a writer rename'
else bad 'template ownership control' "$OUT"; fi

# A repository with no review gate adopts, refreshes and updates the refresh
# workflow with no writer. Its earlier writer record is retired.
sandbox
run_refresh_command "$DIR" "$DIR/$ADOPT"
[ "$RC" -eq 0 ] && adoption_metadata || { bad "no-writer setup (rc=$RC)" "$OUT"; exit 1; }
rm -- "${DIR:?}/.github/workflows/review-gate-writer.yml"
commit "$DIR"
cp "$DIR/.kendex-generated.json" "$TMP/no-writer-before"
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 1 ] && grep -qxF 'FAIL check=workflow-count value=0' <<<"$OUT" &&
    cmp -s "$TMP/no-writer-before" "$DIR/.kendex-generated.json"; then
  ok 'a missing required writer refuses adoption without touching the inventory'
else bad "missing required writer (rc=$RC)" "$OUT"; fi
settings "$DIR" REVIEW_GATE_WRITER optional
settings "$DIR" REVIEW_GATE_MODE off
commit "$DIR"
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 0 ] && grep -qxF 'ok check=workflow-absent value=optional' <<<"$OUT" && adoption_metadata -; then
  ok 'no-writer adoption records the refresh copy and retires the writer record'
else bad "no-writer adoption (rc=$RC)" "$OUT"; fi
cp "$DIR/.kendex-generated.json" "$TMP/no-writer-adopted"
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 0 ] && cmp -s "$TMP/no-writer-adopted" "$DIR/.kendex-generated.json"; then
  ok 'repeated no-writer adoption keeps the inventory unchanged'
else bad "repeated no-writer adoption (rc=$RC)" "$OUT"; fi

# Refresh records the new template hash before adoption, as above.
commit "$DIR"
printf '\n# new template bytes\n' >>"$DIR/$TEMPLATE"
record_template_hash
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 0 ] && adoption_metadata -; then
  ok 'no-writer refresh updates an unedited refresh workflow'
else bad "no-writer template update (rc=$RC)" "$OUT"; fi
commit "$DIR"
# The appended blank line differs first, immediately after the unedited copy.
first_edit_line="$(awk 'END { print NR + 1 }' "$DIR/$REFRESH")" || exit 1
printf '\n# consumer edit\n' >>"$DIR/$REFRESH"
run_refresh_command "$DIR" "$DIR/$ADOPT" --workflow-edit-report "$TMP/no-writer-report"
if workflow_edit_matches "$TMP/no-writer-report" "$REFRESH:$first_edit_line" && adoption_metadata -; then
  ok 'no-writer adoption reconciles an edited refresh workflow and reports its first divergent line'
else bad "no-writer edited refresh (rc=$RC)" "$OUT"; fi

# Keep the report and warning but replace the measured line with the name
# field's line. A later edit must not accept that constant location.
file_edit "$DIR" "$ADOPT" 1 '\{relative\}:\{line\}' 's/{relative}:{line}/{relative}:8/'
chmod +x "$DIR/$ADOPT"
printf '\n# consumer edit\n' >>"$DIR/$REFRESH"
run_refresh_command "$DIR" "$DIR/$ADOPT" --workflow-edit-report "$TMP/no-writer-report"
if adoption_metadata - && workflow_edit_matches "$TMP/no-writer-report" "$REFRESH:8" &&
    ! workflow_edit_matches "$TMP/no-writer-report" "$REFRESH:$first_edit_line"; then
  ok 'control: a constant report line breaks the appended-edit location assertion'
else bad 'first divergent line control' "$OUT"; fi

# The retirement's control keeps the ownership filter's text and skips it for
# an absent writer; the earlier writer record then survives adoption.
sandbox
run_refresh_command "$DIR" "$DIR/$ADOPT"
[ "$RC" -eq 0 ] && adoption_metadata || { bad "retirement control setup (rc=$RC)" "$OUT"; exit 1; }
rm -- "${DIR:?}/.github/workflows/review-gate-writer.yml"
settings "$DIR" REVIEW_GATE_WRITER optional
settings "$DIR" REVIEW_GATE_MODE off
commit "$DIR"
python3 - "$DIR/$ADOPT" <<'RETIRE_CONTROL'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(); needle='entries = [e for e in entries if not isinstance(e, dict) or e["template"] != owner]'
assert s.count(needle)==1
p.write_text(s.replace(needle,'entries = entries if copied is None else ['+needle[len('entries = ['):]))
RETIRE_CONTROL
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 0 ] && jq -e 'any(.[] | objects; .path == ".github/workflows/review-gate-writer.yml")' "$DIR/.kendex-generated.json" >/dev/null; then
  ok 'control: skipping the ownership filter keeps an absent writer record'
else bad 'writer retirement control' "$OUT"; fi
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
