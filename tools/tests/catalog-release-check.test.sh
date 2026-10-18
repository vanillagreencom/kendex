#!/usr/bin/env bash
# Inputs: tools/catalog-release-check
# The release wrapper reads actual rendered manifests. The fixture engine
# supplies rendering and refuses a schema its manifest reader cannot hold.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../.." && pwd)"
TMP_ROOT="$(mktemp -d)" || { echo 'catalog-release-check: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "catalog-release-check: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'catalog-release-check: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
mkdir -p "$TMP_ROOT/catalog/skills/demo" "$TMP_ROOT/bin"
if [ "$#" -gt 0 ]; then
  [ "$#" -eq 1 ] && [ -x "$1" ] || exit 2
  ln -s "$1" "$TMP_ROOT/bin/kendex.real"
fi
cat > "$TMP_ROOT/bin/kendex" <<'PY'
#!/usr/bin/env python3
import pathlib
import os
import shutil
import sys
import tomllib

if sys.argv[1] == '--version':
    print('kendex 1.0.0')
elif sys.argv[1] == 'add':
    shutil.copytree(pathlib.Path(sys.argv[2]) / 'skills', pathlib.Path.cwd() / '.agents/skills')
elif sys.argv[1:3] == ['source', 'list']:
    schema = tomllib.loads(pathlib.Path('kendex.toml').read_text())['schema']
    print(f'schema-probe={schema}', flush=True)
    reader = pathlib.Path(__file__).with_suffix('.real')
    if reader.is_file():
        os.execv(str(reader), [str(reader), *sys.argv[1:]])
    sys.exit(0 if schema == 7 else 2)
elif sys.argv[1] not in ['check', 'refresh', 'verify']:
    sys.exit(2)
PY
chmod +x "$TMP_ROOT/bin/kendex"
PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n%s\n' "$1" "$OUT"; }
run_check() { # SCRIPT
  RC=0
  OUT="$(python3 "$1" "$TMP_ROOT/bin/kendex" "$TMP_ROOT/catalog" 2>&1)" || RC=$?
}
for row in '7|0' '999|1'; do
  IFS='|' read -r schema expected <<< "$row"
  printf 'schema = %s\n' "$schema" > "$TMP_ROOT/catalog/skills/demo/kendex.toml"
  run_check "$REPO/tools/catalog-release-check"
  if [ "$RC" -eq "$expected" ]; then
    if [ "$expected" -eq 0 ] || { [[ "$OUT" == *'skills/demo/kendex.toml'* ]] && [[ "$OUT" == *'schema-probe=999'* ]]; }; then
      ok "shipped schema $schema returns $expected"
    else
      bad "shipped schema $schema did not reach the engine reader"
    fi
  else
    bad "shipped schema $schema returns $expected, got $RC"
  fi
done
# Must-fail: retaining discovery but ignoring its refusal lets the same
# actual shipped schema=999 file pass the release wrapper.
python3 - "$REPO/tools/catalog-release-check" "$TMP_ROOT/mutant" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
needle = 'diagnostic = shipped_manifests(binary, root / "fresh/project", root / "manifests", ceilings)'
assert source.count(needle) == 1
mutant = source.replace(needle, needle + '\n        diagnostic = None')
assert mutant != source
Path(sys.argv[2]).write_text(mutant)
PY
run_check "$TMP_ROOT/mutant"
[ "$RC" -eq 0 ] && [[ "$OUT" == *'result=pass'* ]] && ok 'control: ignoring the schema refusal passes the incompatible file' || bad 'control: ignoring the schema refusal passes the incompatible file'
printf '\npass: %s fail: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
