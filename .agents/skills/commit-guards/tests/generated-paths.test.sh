#!/usr/bin/env bash
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/lib/harness.bash"
source "$TEST_DIR/../scripts/lib/generated-paths.sh"

# The writer emits a JSON array of literal paths, not a glob list or stream.
for inventory in '[]' '[".agents/skills/a*/x.md","space name.md"]'; do
  generated_paths_load "$inventory"
done
generated_path_contains '.agents/skills/a*/x.md'
generated_path_contains 'space name.md'
if generated_path_contains '.agents/skills/abc/x.md'; then exit 1; fi
if generated_path_contains 'name.md'; then exit 1; fi
for inventory in '' 'invalid' '{}' '[null]' '[""]' '[] []' '["a\nb"]' '["a\u0000b"]'; do
  rc=0
  generated_paths_load "$inventory" >"$TMP/result" 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || { printf 'invalid inventory accepted: %s\n' "$inventory"; exit 1; }
done
echo 'generated inventory reader: passed'
