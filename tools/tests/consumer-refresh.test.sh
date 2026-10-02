#!/usr/bin/env bash
# The gate uses the existing consumer world and pre-platform committed scripts.
# Real kendex refreshes only disposable consumers; no catalog checkout is applied.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
REAL_KENDEX="$(command -v kendex)" || { printf 'consumer-refresh-test: kendex=missing\n' >&2; exit 1; }
TEST_DIR="$ROOT/skills/review-gate/tests"
SKILL_DIR="$ROOT/skills/review-gate"
TMP="$(mktemp -d)" || { echo 'consumer-refresh-test: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP && ! -L $TMP ]] || { echo "consumer-refresh-test: scratch=not-a-directory value=[$TMP]" >&2; exit 1; }
TMP="$(cd -- "$TMP" && pwd -P)" || { echo 'consumer-refresh-test: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
. "$TEST_DIR/lib/refresh-fixture.sh"
mkdir -p "$TMP/candidate"
# Export the current catalog, not its unrelated historical blobs. A hosted
# checkout can be a blob-filtered clone whose upload-pack cannot lazily fetch
# those old blobs; this fixture needs the current tree, not shipment history.
git -C "$ROOT" archive --format=tar HEAD >"$TMP/catalog.tar"
tar -xf "$TMP/catalog.tar" -C "$TMP/candidate"
git -C "$TMP/candidate" init -q -b main
git -C "$TMP/candidate" -c core.hooksPath=/dev/null -c user.name=fixture -c user.email=fixture@example.invalid add -A
git -C "$TMP/candidate" -c core.hooksPath=/dev/null -c user.name=fixture -c user.email=fixture@example.invalid commit -qm 'catalog fixture'
git -C "$TMP/candidate" config gc.auto 0
git -C "$TMP/candidate" config maintenance.auto false
git -C "$TMP/candidate" config user.name fixture
git -C "$TMP/candidate" config user.email fixture@example.invalid
mkdir -p "$TMP/catalogs/vanillagreencom"
ln -s "$TMP/candidate" "$TMP/catalogs/vanillagreencom/kendex"
# The refresh fixture owner supplies the consumer repository and adoption
# inventory. Replace its neutral skill copies with real catalog installations.
sandbox
consumer="$DIR"
rm -rf -- "${consumer:?}/.agents/skills"
mkdir -p "$TMP/home/.claude"
printf 'schema = 6\n[sources.kendex]\nrepo = "vanillagreencom/kendex"\n[install]\nharnesses = ["codex"]\nmethod = "copy"\n[skills.review-gate]\nsource = "kendex"\n' >"$consumer/kendex.toml"
# The fixture installer records real hashes and the real generated inventory.
(cd -- "$consumer" && env -i PATH="$PATH" HOME="$TMP/home" KENDEX_REAL_HOME=1 \
  KENDEX_BACKGROUND_REFRESH=off KENDEX_GIT_BASE="file://$TMP/catalogs" KENDEX_UI=plain \
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  "$REAL_KENDEX" refresh --scope project --yes --leave)
cp "$TEST_DIR/fixtures/pre-platform/"*.sh "$consumer/.agents/skills/review-gate/scripts/"
chmod +x "$consumer/.agents/skills/review-gate/scripts/"*.sh
printf '#!/usr/bin/env bash\nexit 1\n' >"$consumer/.agents/skills/review-gate/scripts/review-writer.sh"
cp "$SKILL_DIR/templates/review-gate-writer.yml" "$consumer/.github/workflows/review-gate-writer.yml"
cp "$SKILL_DIR/templates/kendex-refresh.yml" "$consumer/.github/workflows/kendex-refresh.yml"
record_adoption "$consumer" .github/workflows/review-gate-writer.yml .agents/skills/review-gate/templates/review-gate-writer.yml
record_adoption "$consumer" .github/workflows/kendex-refresh.yml .agents/skills/review-gate/templates/kendex-refresh.yml
# Capture the same input format the platform collector produces. The fixture
# seed provided to this lane lacks committed skills and is not used as inventory.
python3 - "$consumer" "$FIXTURES" "$TMP/snapshot.gz" <<'PY'
import base64, gzip, json
from pathlib import Path
import sys
root, platform, target = map(Path, sys.argv[1:])
files = {p.relative_to(root).as_posix(): {"mode": "100755" if p.stat().st_mode & 0o111 else "100644",
         "data": base64.b64encode(p.read_bytes()).decode()}
         for p in root.rglob("*") if p.is_file() and ".git" not in p.relative_to(root).parts}
world = {p.stem: json.loads(p.read_text()) for p in platform.glob("*.json")}
world["repository"]["full_name"] = "vanillagreencom/fixture"
snapshot = {"schema": 1, "consumers": {"fixture": {"commit": "fixture", "platform": world, "files": files}}}
target.write_bytes(gzip.compress(json.dumps(snapshot).encode(), mtime=0))
PY
printf 'fixture\n' >"$TMP/inventory"
# tempfile reads TMPDIR; this alias reaches macOS's temporary-path case on Linux.
mkdir -p "$TMP/replay-root"
ln -s "$TMP/replay-root" "$TMP/replay-alias"
gate() {
  RC=0
  OUT="$(env -i PATH="$PATH" HOME="$TMP" TMPDIR="$TMP/replay-alias" python3 "${GATE:-$ROOT/tools/consumer-refresh}" check \
    --inventory "$TMP/inventory" --snapshot "$1" --baseline "${BASELINE:-$TMP/candidate}" \
    --catalog "$2" --kendex "$REAL_KENDEX" 2>&1)" || RC=$?
}
gate "$TMP/snapshot.gz" "$TMP/candidate"
if [ "$RC" -eq 0 ] && grep -qxF 'consumer-refresh=pass repository=fixture baseline-exit=0 candidate-exit=0' <<<"$OUT"; then
  ok 'real committed consumer refresh passes through a temporary-root alias against the retained catalog'
else bad 'real consumer baseline' "$OUT"; fi
# Remove the writer template in a disposable candidate catalog. This is the
# historical production defect, not a mutation of a fixture's fake refresh.
git clone -q --no-hardlinks "$TMP/candidate" "$TMP/removed"
git -C "$TMP/removed" config gc.auto 0
git -C "$TMP/removed" config maintenance.auto false
rm -- "$TMP/removed/skills/review-gate/templates/review-gate-writer.yml"
git -C "$TMP/removed" -c core.hooksPath=/dev/null -c user.name=fixture -c user.email=fixture@example.invalid add -A
git -C "$TMP/removed" -c core.hooksPath=/dev/null -c user.name=fixture -c user.email=fixture@example.invalid commit -qm 'remove writer template'
gate "$TMP/snapshot.gz" "$TMP/removed"
if [ "$RC" -eq 1 ] && grep -qxF 'consumer-refresh=regression repository=fixture baseline-exit=0 candidate-exit=2' <<<"$OUT" &&
  grep -qxF 'review-gate-error=template-missing value=<sandbox>/consumer/.agents/skills/review-gate/templates/review-gate-writer.yml' <<<"$OUT"; then
  ok 'control: writer-template removal turns the gate red'
else bad 'writer-template removal control' "$OUT"; fi
BASELINE="$TMP/removed" gate "$TMP/snapshot.gz" "$TMP/removed"
if [ "$RC" -eq 0 ] && grep -qxF 'consumer-refresh=baseline-failure repository=fixture baseline-exit=2 candidate-exit=2' <<<"$OUT"; then
  ok 'an unchanged keyed baseline refusal is not a consumer pass or PR regression'
else bad 'baseline failure comparison' "$OUT"; fi
# The preserved adopter extracts the job environment from the refreshed
# template. Its absence is a different keyed refusal than the missing writer.
git clone -q --no-hardlinks "$TMP/candidate" "$TMP/no-environment"
git -C "$TMP/no-environment" config gc.auto 0
git -C "$TMP/no-environment" config maintenance.auto false
python3 - "$TMP/no-environment/skills/review-gate/templates/kendex-refresh.yml" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1]).resolve()
text = path.read_text()
old = '    environment: kendex\n'
assert text.count(old) == 1
changed = text.replace(old, '')
assert changed != text
path.write_text(changed)
PY
git -C "$TMP/no-environment" -c core.hooksPath=/dev/null -c user.name=fixture -c user.email=fixture@example.invalid add -A
git -C "$TMP/no-environment" -c core.hooksPath=/dev/null -c user.name=fixture -c user.email=fixture@example.invalid commit -qm 'remove refresh environment'
BASELINE="$TMP/removed" gate "$TMP/snapshot.gz" "$TMP/no-environment"
if [ "$RC" -eq 1 ] && grep -qxF 'consumer-refresh=regression repository=fixture baseline-exit=2 candidate-exit=2' <<<"$OUT" &&
  grep -qxF 'review-gate-error=template-missing value=<sandbox>/consumer/.agents/skills/review-gate/templates/review-gate-writer.yml' <<<"$OUT" &&
  grep -qxF 'review-gate-error=standard-setting-missing value=REVIEW_GATE_STANDARD_ENVIRONMENT' <<<"$OUT"; then
  ok 'different keyed baseline and candidate refusals are a regression'
else bad 'different baseline failure comparison' "$OUT"; fi
# Gate controls keep the matched code visible and remove its behavior.
python3 - "$ROOT/tools/consumer-refresh" "$TMP" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).resolve()
text = source.read_text()
for name, old, new in (
    ('mutant', 'failed = True', '# failed = True\n                failed = False'),
    ('cause-mutant', 'elif base_rc != 0 and cause(out) and cause(out) == cause(base_out):',
     '# elif base_rc != 0 and cause(out) and cause(out) == cause(base_out):\n'
     '            elif base_rc != 0 and cause(out):'),
    ('snapshot-mutant', 'if os.path.lexists(args.baseline / ".github/consumer-snapshots.json.gz"):',
     '# if os.path.lexists(args.baseline / ".github/consumer-snapshots.json.gz"):\n'
     '        if False:'),
    ('root-mutant', 'tmp = Path(temporary).resolve()',
     '# tmp = Path(temporary).resolve()\n        tmp = Path(temporary)'),
):
    assert text.count(old) == 1
    changed = text.replace(old, new)
    assert changed != text
    path = Path(sys.argv[2]) / name
    path.write_text(changed.replace('ROOT = Path(__file__).resolve().parent.parent',
        'ROOT = Path(' + repr(str(source.parent.parent)) + ')'))
    path.chmod(0o755)
PY
GATE="$TMP/root-mutant" gate "$TMP/snapshot.gz" "$TMP/candidate"
if [ "$RC" -eq 1 ] && grep -q '^consumer-refresh-error=link-target value=' <<<"$OUT"; then
  ok 'control: unresolved temporary-root alias turns the real replay assertion red'
else bad 'temporary-root alias mutant' "$OUT"; fi
GATE="$TMP/mutant" gate "$TMP/snapshot.gz" "$TMP/removed"
if [ "$RC" -eq 0 ]; then ok 'control: disabled regression refusal turns the removal assertion red'; else bad 'regression refusal mutant' "$OUT"; fi
GATE="$TMP/cause-mutant" BASELINE="$TMP/removed" gate "$TMP/snapshot.gz" "$TMP/no-environment"
if [ "$RC" -eq 0 ] && grep -qxF 'consumer-refresh=baseline-failure repository=fixture baseline-exit=2 candidate-exit=2' <<<"$OUT" &&
  grep -qxF 'review-gate-error=template-missing value=<sandbox>/consumer/.agents/skills/review-gate/templates/review-gate-writer.yml' <<<"$OUT" &&
  grep -qxF 'review-gate-error=standard-setting-missing value=REVIEW_GATE_STANDARD_ENVIRONMENT' <<<"$OUT"; then
  ok 'control: disabled cause equality turns the different-refusal assertion red'
else bad 'cause equality mutant' "$OUT"; fi
mkdir -p "$TMP/bootstrap" "$TMP/deployed/.github"
cp "$TMP/snapshot.gz" "$TMP/deployed/.github/consumer-snapshots.json.gz"
for row in absent removed empty missing-consumer missing-input unsafe-path unsafe-link unknown-mode; do
  path="$TMP/$row.gz"
  if [ "$row" != absent ] && [ "$row" != removed ]; then
    python3 - "$TMP/snapshot.gz" "$path" "$row" <<'PY'
import gzip, json
from pathlib import Path
import sys
source, target, row = sys.argv[1:]
data = json.loads(gzip.decompress(Path(source).read_bytes()))
if row == 'empty': data = {}
elif row == 'missing-consumer': data['consumers'] = {}
elif row == 'missing-input': del data['consumers']['fixture']['files']['.kendex-lock.json']
elif row in ('unsafe-path', 'unsafe-link', 'unknown-mode'):
    import base64
    name = '../escape' if row == 'unsafe-path' else 'probe'
    mode = '120000' if row == 'unsafe-link' else '160000' if row == 'unknown-mode' else '100644'
    data['consumers']['fixture']['files'][name] = {'mode': mode, 'data': base64.b64encode(b'../escape').decode()}
else: raise AssertionError(row)
Path(target).write_bytes(gzip.compress(json.dumps(data).encode()))
PY
  fi
  baseline="$TMP/candidate"
  if [ "$row" = absent ]; then baseline="$TMP/bootstrap"; fi
  if [ "$row" = removed ]; then baseline="$TMP/deployed"; fi
  BASELINE="$baseline" gate "$path" "$TMP/candidate"
  if [ "$row" = absent ]; then
    if [ "$RC" -eq 0 ] && [ "$OUT" = consumer-snapshot=absent ]; then ok 'bootstrap permits only total absence'; else bad 'bootstrap' "$OUT"; fi
  elif [ "$row" = removed ]; then
    if [ "$RC" -eq 1 ] && [ "$OUT" = "consumer-refresh-error=input-missing value=$path" ]; then
      ok 'control: post-deployment snapshot removal turns the gate red'
    else bad 'post-deployment snapshot removal' "$OUT"; fi
  elif [ "$row" = missing-input ]; then
    if [ "$RC" -eq 1 ] && grep -qxF 'consumer-refresh-error=input-missing value=.kendex-lock.json' <<<"$OUT"; then ok "$row refuses before execution"; else bad "$row" "$OUT"; fi
  elif [ "$RC" -eq 1 ]; then ok "$row refuses before execution"; else bad "$row" "$OUT"; fi
done
GATE="$TMP/snapshot-mutant" BASELINE="$TMP/deployed" gate "$TMP/removed.gz" "$TMP/candidate"
if [ "$RC" -eq 0 ] && [ "$OUT" = consumer-snapshot=absent ]; then
  ok 'control: disabled baseline snapshot check turns the removal assertion red'
else bad 'baseline snapshot mutant' "$OUT"; fi
printf '\nconsumer-refresh-test: pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
