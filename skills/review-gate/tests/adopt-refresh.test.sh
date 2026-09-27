#!/usr/bin/env bash
# Exercise consumer adoption with the real environment and workflow validators.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT
. "$TEST_DIR/lib/refresh-fixture.sh"
ADOPT='.agents/skills/review-gate/scripts/adopt-refresh.sh'
REFRESH='.github/workflows/kendex-refresh.yml'
TEMPLATE='.agents/skills/review-gate/templates/kendex-refresh.yml'
printf '[".agents/skills/other/SKILL.md",{"path":".github/workflows/other.yml","template":".agents/skills/other/templates/other.yml","templateHash":"sha256:0000000000000000000000000000000000000000000000000000000000000000"}]\n' >"$PRISTINE/.kendex-generated.json"

# Every successful adoption must preserve unrelated entries and produce the
# exact workflow metadata that kendex verify reads, with no duplicate paths.
adoption_metadata() {
  python3 - "$DIR" "${1:-review-gate-writer.yml}" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
expected = [".agents/skills/other/SKILL.md", {"path":".github/workflows/other.yml","template":".agents/skills/other/templates/other.yml","templateHash":"sha256:0000000000000000000000000000000000000000000000000000000000000000"}]
for name in ("kendex-refresh.yml", "review-gate-writer.yml"):
    path = ".github/workflows/" + (sys.argv[2] if name == "review-gate-writer.yml" else name)
    template = ".agents/skills/review-gate/templates/" + name
    data = (root / template).read_bytes()
    assert (root / path).read_bytes() == data, path
    expected.append({"path": path, "template": template, "templateHash": "sha256:" + hashlib.sha256(data).hexdigest()})
assert json.loads((root / ".kendex-generated.json").read_text()) == sorted(expected, key=lambda e: e if isinstance(e, str) else e["path"])
PY
}

sandbox
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 0 ] && adoption_metadata; then ok 'adoption copies both templates and records exact metadata'; else bad "initial adoption (rc=$RC)" "$OUT"; fi
cp "$DIR/.kendex-generated.json" "$TMP/inventory-before"
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 0 ] && cmp -s "$TMP/inventory-before" "$DIR/.kendex-generated.json"; then ok 'repeated adoption keeps the inventory unchanged'; else bad "repeated adoption (rc=$RC)" "$OUT"; fi

# Refresh records the new template hash before adoption. The previous commit
# still records the old copy's hash, which must authorize its replacement.
commit "$DIR"
printf '\n# new template bytes\n' >>"$DIR/$TEMPLATE"
python3 - "$DIR" "$TEMPLATE" "$REFRESH" <<'PY_FIXTURE'
import hashlib
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
path = root / ".kendex-generated.json"
entries = json.loads(path.read_text())
record = next(e for e in entries if isinstance(e, dict) and e["path"] == sys.argv[3])
record["templateHash"] = "sha256:" + hashlib.sha256((root / sys.argv[2]).read_bytes()).hexdigest()
path.write_text(json.dumps(entries) + "\n")
PY_FIXTURE
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 0 ] && adoption_metadata; then ok 'prior recorded hash permits a template update'; else bad "prior hash adoption (rc=$RC)" "$OUT"; fi

cp "$DIR/.kendex-generated.json" "$TMP/inventory-before"
printf '\n# consumer edit\n' >>"$DIR/$REFRESH"
cp "$DIR/$REFRESH" "$TMP/refresh-before"
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 1 ] && grep -q '^refresh-error=workflow-edited value=' <<<"$OUT" &&
    cmp -s "$TMP/refresh-before" "$DIR/$REFRESH" && cmp -s "$TMP/inventory-before" "$DIR/.kendex-generated.json"; then
  ok 'an edited refresh workflow is refused without rewriting it or its inventory'
else
  bad "edited refresh (rc=$RC)" "$OUT"
fi

# The refusal's control preserves the diagnostic and operands but disables
# its branch. The same edited copy must then be overwritten incorrectly.
file_edit "$DIR" "$ADOPT" 1 '^    if recorded is None or ' \
  's/^    if \(recorded .*\):$/    if False and (\1):/'
chmod +x "$DIR/$ADOPT"
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 0 ] && adoption_metadata && ! cmp -s "$TMP/refresh-before" "$DIR/$REFRESH"; then
  ok 'control: disabled edit guard overwrites the consumer edit'
else
  bad "control: edit guard mutation did not reach the overwrite (rc=$RC)" "$OUT"
fi

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
file_edit "$DIR" "$ADOPT" 1 '^"\$SCRIPT_DIR/validate-standard.sh" --environment-only$' \
  's/ --environment-only$/ --environment-only || true/'
chmod +x "$DIR/$ADOPT"
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 0 ] && adoption_metadata; then ok 'control: ignored environment failure allows adoption'; else bad "control: environment guard (rc=$RC)" "$OUT"; fi

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
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
