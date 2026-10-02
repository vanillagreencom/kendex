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
# The preserved refresh runner has no structured failure report. Exercise the
# documented classifier record from its captured stdout/stderr as one table.
CAUSE_RC=0
python3 - "$ROOT/tools/consumer-refresh" >"$TMP/cause-output" 2>&1 <<'PY' || CAUSE_RC=$?
from pathlib import Path
import runpy, sys
text = Path(sys.argv[1]).read_text()
cause = runpy.run_path(sys.argv[1])['cause']
record = 'class: class=standard measured=false cause=render-retirement-unproved path=.agents/skills/my skill/SKILL.md'
read = 'refresh-error=read value=class'
baseline = record + '\nchange_class=standard\n' + read
rows = (
    ('equal space-bearing classifier refusal', baseline, True, True),
    ('changed full record', baseline.replace('my skill', 'other skill'), False, True),
    ('changed classifier cause', baseline.replace('render-retirement-unproved', 'render-path-unowned'), False, True),
    ('missing classifier record', read, False, False),
    ('missing measured field', baseline.replace(' measured=false', ''), False, False),
    ('unknown failure', 'unkeyed failure', False, False),
    ('duplicate classifier record', record + '\n' + baseline, False, False),
    ('generic refresh failure', baseline + '\nrefresh-error=refresh value=1', False, False),
    ('other failed read', baseline.replace('value=class', 'value=tree'), False, False),
    ('platform read failure', baseline + '\ngh-shim-error=unhandled value=api', False, False),
)
for label, output, expected, comparable in rows:
    actual = bool(cause(output)) and cause(output) == cause(baseline)
    assert actual == expected and bool(cause(output)) == comparable, label
    print('cause-control=' + label)
# Keep the producer intact. Token parsing must break the space-bearing row;
# dropping fields must break full-record equality; other reads stay refused.
for old, new, label in (
    ('return records + classes', 'return records + classes if all(len(line.split()) == 5 for line in classes) else ()', 'equal space-bearing classifier refusal'),
    ('return records + classes', 'return records + tuple(line.split(" path=")[0] for line in classes)', 'changed full record'),
    ('line != "refresh-error=read value=class"', 'False', 'other failed read'),
    ('if len(classes) != 1 or not classes[0].startswith(', 'if False and classes[0].startswith(', 'missing measured field'),
):
    assert text.count(old) == 1
    changed = text.replace(old, new)
    assert changed != text
    namespace = {'__file__': sys.argv[1], '__name__': 'cause_control'}
    exec(compile(changed, sys.argv[1], 'exec'), namespace)
    mutant = namespace['cause']
    output, expected, comparable = next((output, expected, comparable)
        for row_label, output, expected, comparable in rows if row_label == label)
    actual = bool(mutant(output)) and mutant(output) == mutant(baseline)
    assert actual != expected or bool(mutant(output)) != comparable, label + ' mutant did not turn red'
PY
CAUSE_OUT="$(cat -- "$TMP/cause-output")" || { printf 'consumer-refresh-test: cause-output=read-failed\n' >&2; exit 1; }
if [ "$CAUSE_RC" -eq 0 ]; then ok 'full classifier refusals compare unchanged; unknown and other failures stay red'; else bad 'classifier cause controls' "$CAUSE_OUT"; fi
gate "$TMP/snapshot.gz" "$TMP/candidate"
if [ "$RC" -eq 0 ] && grep -qxF 'consumer-refresh=pass repository=fixture baseline-exit=0 candidate-exit=0' <<<"$OUT"; then
  ok 'real committed consumer refresh passes through a temporary-root alias against the retained catalog'
else bad 'real consumer baseline' "$OUT"; fi
# Git receive-pack starts real automatic GC in the scratch bare remote. Lower
# its pack threshold in a disposable runtime copy so this small world reaches
# the same maintenance that a large installed consumer starts after push.
# Select GC explicitly because Git can default to geometric repacking instead.
python3 - "$ROOT/tools/consumer-refresh" "$TMP" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).resolve()
text = source.read_text()
old = '    git("clone", "--bare", "-q", str(consumer), str(remote))\n'
setup = '''    git("config", "--global", "trace2.eventTarget", TRACE)
    git("--git-dir", str(remote), "config", "maintenance.gc.enabled", "true")
    git("--git-dir", str(remote), "config", "gc.auto", "1")
    git("--git-dir", str(remote), "config", "gc.autoPackLimit", "1")
    git("--git-dir", str(remote), "repack", "-ad")
    subprocess.run(["git", "--git-dir", str(remote), "pack-objects",
                    str(remote / "objects/pack/pack")],
                   input=git("rev-parse", "HEAD"), cwd=consumer, env=env,
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
'''
assert text.count(old) == 1
changed = text.replace(old, old + setup)
assert changed != text
root = 'ROOT = Path(__file__).resolve().parent.parent'
assert changed.count(root) == 1
changed = changed.replace(root, 'ROOT = Path(' + repr(str(source.parent.parent)) + ')')
setting = '        git("config", "--global", key, "false")'
assert changed.count(setting) == 1
for name, content in (
    ('gc-gate', changed),
    ('gc-mutant', changed.replace(setting, '# ' + setting.strip() + '\n'
        '        git("config", "--global", key, "true")')),
):
    assert content != text
    trace = str(Path(sys.argv[2]) / (name + '.trace'))
    path = Path(sys.argv[2]) / name
    path.write_text(content.replace('TRACE', repr(trace)))
    path.chmod(0o755)
PY
for row in gc-gate gc-mutant; do
  GATE="$TMP/$row" gate "$TMP/snapshot.gz" "$TMP/candidate"
  GC_RC=0
  # Bash 3.2 counts parentheses inside heredocs in command substitutions.
  python3 - "$TMP/$row.trace" >"$TMP/gc-output" 2>&1 <<'PY' || GC_RC=$?
import json
from pathlib import Path
import sys
events = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
sessions = {event['sid'] for event in events
            if event['event'] == 'cmd_name' and event.get('name') == 'gc'}
maintenance = {event['sid'] for event in events
               if event['event'] == 'cmd_name' and event.get('name') == 'maintenance'}
repacking = {event['sid'] for event in events if event['sid'] in sessions
             and event['event'] == 'child_start' and 'repack' in event.get('argv', [])}
# Both replays must reach the remote's GC, not only its no-op threshold check.
assert len(repacking) == 2, 'consumer-refresh-test: gc-coverage'
for gc_sid in repacking:
    repack = next(event['child_id'] for event in events if event['sid'] == gc_sid
                  and event['event'] == 'child_start' and 'repack' in event.get('argv', []))
    completed = [index for index, event in enumerate(events) if event['sid'] == gc_sid
                 and event['event'] == 'child_exit' and event['child_id'] == repack
                 and event['code'] == 0]
    # Git can detach GC or its maintenance parent. A detached parent exits
    # before repack finishes and its child can emit a second inherited exit.
    for sid in {gc_sid} | {sid for sid in maintenance if gc_sid.startswith(sid + '/')}:
        exits = [index for index, event in enumerate(events)
                 if event['sid'] == sid and event['event'] == 'exit']
        assert len(exits) == 1 and len(completed) == 1 and completed[0] < exits[0], \
            'consumer-refresh-test: detached-gc'
PY
  GC_OUT="$(cat -- "$TMP/gc-output")" || { printf 'consumer-refresh-test: gc-output=read-failed\n' >&2; exit 1; }
  if [ "$row" = gc-gate ]; then
    if [ "$RC" -eq 0 ] && [ "$GC_RC" -eq 0 ] &&
      grep -qxF 'consumer-refresh=pass repository=fixture baseline-exit=0 candidate-exit=0' <<<"$OUT"; then
      ok 'real remote automatic GC finishes before replay cleanup'
    else bad 'remote automatic GC lifetime' "$OUT $GC_OUT"; fi
  elif [ "$GC_RC" -eq 1 ] && grep -qxF 'AssertionError: consumer-refresh-test: detached-gc' <<<"$GC_OUT"; then
    ok 'must-fail control: detached remote GC turns the lifetime assertion red'
  else bad 'detached remote GC control' "$OUT $GC_OUT"; fi
done
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
