#!/usr/bin/env bash
# Collector input is a neutral committed tree behind GitHub's documented APIs.
# No fake consumer script runs under the collector's synthetic credential.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_DIR="$ROOT/skills/review-gate/tests"
SKILL_DIR="$ROOT/skills/review-gate"
TMP="$(mktemp -d)" || { echo 'consumer-snapshots-test: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP && ! -L $TMP ]] || { echo "consumer-snapshots-test: scratch=not-a-directory value=[$TMP]" >&2; exit 1; }
TMP="$(cd -- "$TMP" && pwd -P)" || { echo 'consumer-snapshots-test: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
. "$TEST_DIR/lib/refresh-fixture.sh"
printf 'fixture\n' >"$TMP/inventory"
mkdir -p "$TMP/read-bin"
cat >"$TMP/read-bin/gh" <<'PY'
#!/usr/bin/env python3
import io, json, os, sys, tarfile
from pathlib import Path
assert os.environ['GH_TOKEN'] == 'read-fixture'
endpoint = sys.argv[-1]
files = {'kendex.toml': b'schema = 6\n[sources.kendex]\nrepo = "vanillagreencom/kendex"\n',
         'kendex.settings.toml': b'[env]\n', '.kendex-lock.json': b'{}',
         '.kendex-generated.json': b'[".agents/skills/review-gate/scripts/refresh-consumer.sh"]',
         '.github/workflows/kendex-refresh.yml': b'name: Refresh kendex\n',
         '.agents/skills/review-gate/scripts/refresh-consumer.sh': b'#!/bin/sh\nexit 87\n',
         'private.txt': b'not a refresh input'}
mode = os.environ.get('CASE', 'pass')
if mode == 'read-failed' and endpoint.endswith('/environments'):
    print('gh: Resource not accessible by integration (HTTP 403)', file=sys.stderr)
    sys.exit(9)
if mode == 'missing-input': del files['.kendex-lock.json']
if endpoint.endswith('/commits/main'):
    result = {'sha': 'committed-sha', 'commit': {'committer': {'date': '2026-10-01T00:00:00Z'}}}
elif '/git/trees/' in endpoint:
    result = {'truncated': mode == 'truncated', 'tree': [
        {'path': p, 'mode': '100755' if p.endswith('.sh') else '100644', 'type': 'blob', 'sha': p}
        for p in files]}
elif '/tarball/' in endpoint:
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode='w:gz') as archive:
        for name, content in files.items():
            member = tarfile.TarInfo('repo-sha/' + name)
            member.size = len(content)
            archive.addfile(member, io.BytesIO(content))
    sys.stdout.buffer.write(output.getvalue())
    sys.exit(0)
elif endpoint.endswith('/environments'):
    result = [{'environments': []}]
elif endpoint.endswith('/deployment-branch-policies'):
    result = [{'branch_policies': []}]
elif endpoint.endswith('/secrets'):
    result = [{'secrets': []}]
elif endpoint == 'repos/vanillagreencom/fixture':
    result = {'default_branch': 'main', 'full_name': 'vanillagreencom/fixture'}
else: raise AssertionError(endpoint)
print(json.dumps(result))
PY
chmod +x "$TMP/read-bin/gh"
collect() {
  RC=0
  OUT="$(env -i PATH="$TMP/read-bin:$PATH" HOME="$TMP" GH_TOKEN=read-fixture CASE="$1" \
    "${COLLECTOR:-$ROOT/tools/consumer-refresh}" collect --inventory "$TMP/inventory" \
    --output "$TMP/$1.gz" 2>&1)" || RC=$?
}
collect pass
if [ "$RC" -eq 0 ] && grep -qxF 'consumer-collected=vanillagreencom/fixture commit=committed-sha' <<<"$OUT" &&
  python3 - "$TMP/pass.gz" <<'PY'
import gzip, json, sys
from pathlib import Path
snapshot = json.loads(gzip.decompress(Path(sys.argv[1]).read_bytes()))
consumer = snapshot['consumers']['fixture']
assert consumer['commit'] == 'committed-sha'
assert 'private.txt' not in consumer['files']
assert consumer['files']['.agents/skills/review-gate/scripts/refresh-consumer.sh']['mode'] == '100755'
assert consumer['platform']['repository']['full_name'] == 'vanillagreencom/fixture'
PY
then ok 'collector captures committed inputs and modes, not unrelated source'; else bad 'collector complete input' "$OUT"; fi
for row in 'read-failed|gh: Resource not accessible by integration (HTTP 403)' 'truncated|consumer-refresh-error=tree-truncated value=vanillagreencom/fixture' 'missing-input|consumer-refresh-error=input-missing value=vanillagreencom/fixture/.kendex-lock.json'; do
  IFS='|' read -r mode key <<<"$row"
  collect "$mode"
  if [ "$RC" -eq 1 ] && grep -qxF 'consumer-refresh-error=collect value=vanillagreencom/fixture' <<<"$OUT" &&
    { [ -z "$key" ] || grep -qxF "$key" <<<"$OUT"; } && [ ! -f "$TMP/$mode.gz" ]; then
    ok "control: $mode fails the named consumer without publishing partial input"
  else bad "$mode refusal" "$OUT"; fi
done
python3 - "$ROOT/tools/consumer-refresh" "$TMP/mutant" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
old = 'if tree["truncated"]:'
assert text.count(old) == 1
changed = text.replace(old, '# ' + old + '\n            if False:')
assert changed != text
path = Path(sys.argv[2])
path.write_text(changed)
path.chmod(0o755)
PY
COLLECTOR="$TMP/mutant" collect truncated
if [ "$RC" -eq 0 ]; then ok 'control: disabled tree refusal turns the incomplete-collection assertion red'; else bad 'collector mutant' "$OUT"; fi
printf '\nconsumer-snapshots-test: pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
