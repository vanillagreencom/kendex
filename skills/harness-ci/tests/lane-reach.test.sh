#!/usr/bin/env bash
# Inputs: harness-ci scripts, change-scope and the change-class action.
set -euo pipefail
# The action and CLI spawn python3. Scope their venv to this suite's process tree.
if [ -n "${LANE_REACH_PYTHON_BIN:-}" ]; then
  export PATH="$LANE_REACH_PYTHON_BIN:$PATH"
fi
# shellcheck source=../../change-scope/tests/lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../change-scope/tests/lib/sandbox.sh"

root="$(cd "$TEST_DIR/../../.." && pwd)"
repo="$(new_repo lane-reach)"
trusted="$SANDBOX/base"
classifier="${ACTION_ROOT:-$root}"
action="$root/.github/actions/change-class/classify"
python3 -c 'import tomllib, yaml'

mkdir -p "$repo/.github/workflows" "$repo/tools/other" "$repo/web" "$repo/cargo" \
  "$repo/.agents/skills/math/scripts" "$repo/.codex/skills/math" "$SANDBOX/bin"
write_workflow() {
  local shape="$1" id cwd run lane needs
  cat <<'YAML'
name: CI
on: [pull_request, merge_group, push]
jobs:
  changes:
    outputs:
      lanes: ${{ steps.classify.outputs.lanes }}
      lane_shell: ${{ steps.lanes.outputs.lane_shell }}
      lane_cargo: ${{ steps.lanes.outputs.lane_cargo }}
      lane_web: ${{ steps.lanes.outputs.lane_web }}
      lane_installed: ${{ steps.lanes.outputs.lane_installed }}
    steps:
      - id: classify
        uses: vanillagreencom/kendex/.github/actions/change-class@main
      - id: lanes
        env:
          LANE_VERDICTS: ${{ steps.classify.outputs.lane_verdicts }}
        run: printf '%s\n' "$LANE_VERDICTS" >>"$GITHUB_OUTPUT"
YAML
  while IFS='|' read -r id cwd run; do
    case "$shape" in
      no-cargo|queue-prerequisite|deleted-workdir) [ "$id" != cargo ] || continue ;;
      web-only) [ "$id" = web ] || continue ;;
    esac
    lane="$id"
    needs=changes
    case "$id" in
      shell_share) lane=shell ;;
      installed) needs='[changes, shell]' ;;
    esac
    if [ "$shape:$id" = deleted-workdir:shell ]; then
      cwd=check-cwd run=true
    fi
    cat <<YAML
  $id:
    needs: $needs
    if: \${{ !cancelled() && (needs.changes.result != 'success' || (needs.changes.outputs.lanes != 'false' && needs.changes.outputs.lane_$lane != 'false')) }}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - working-directory: $cwd
        run: $run
YAML
    if [ "$id" = shell ]; then
      cat <<'YAML'
      - run: bash ./tools/shared.sh
      - working-directory: tools/other
        run: bash ../shared.sh
YAML
    fi
    if [ "$shape:$id" = queue-prerequisite:installed ]; then
      printf '%s\n' '      - run: cat ./shared.mjs'
    fi
  done <<'ROWS'
shell|.|bash ./tools/check.sh
shell_share|.|bash ./tools/peer.sh
cargo|cargo|cargo test -p primary
web|web|./node_modules/.bin/vitest run
installed|.|bash ./.agents/skills/math/scripts/check.sh
ROWS
  cat <<'YAML'
  docs:
    needs: changes
    if: ${{ !cancelled() }}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: test -f ./README.md
YAML
}
write_workflow full >"$repo/.github/workflows/ci.yml"

printf '%s\n' 'cat ./tools/outer.sh' 'source ./tools/outer.sh' 'cat ./shared.mjs' >"$repo/tools/check.sh"
printf '%s\n' 'source ./tools/input.sh' >"$repo/tools/outer.sh"
printf '%s\n' 'true' >"$repo/tools/input.sh"
printf '%s\n' 'true' >"$repo/tools/peer.sh"
printf '%s\n' 'source ./context.sh' >"$repo/tools/shared.sh"
printf '%s\n' 'true' >"$repo/context.sh"
printf '%s\n' 'true' >"$repo/tools/other/context.sh"
printf '%s\n' 'Fixture documentation' >"$repo/README.md"
printf '%s\n' 'true' >"$repo/.agents/skills/math/scripts/check.sh"
printf '%s\n' 'installed' >"$repo/.codex/skills/math/SKILL.md"
reader=.agents/skills/harness-ci/scripts/change-class
mkdir -p "$repo/${reader%/*}"
printf '%s\n' '# HARNESS_CI_PER_PUSH_REASON is read by this render.' >"$repo/$reader"
cat >"$repo/.kendex-generated.json" <<'JSON'
[".agents/skills/math/scripts/check.sh",".codex/skills/math/SKILL.md"]
JSON
cat >"$repo/.kendex-lock.json" <<'JSON'
{"entries":{
  "skill:math:claude":{"enabled":true,"sourceRepo":"example/catalog","emitted":{"kind":"skill","name":"math","paths":[".agents/skills/math"]}},
  "skill:math:codex":{"enabled":true,"sourceRepo":"example/catalog","emitted":{"kind":"skill","name":"math","paths":[".agents/skills/math",".codex/skills/math"]}},
  "mcp:native:copilot":{"enabled":true,"sourceRepo":"example/catalog"}
}}
JSON

cat >"$repo/cargo/Cargo.toml" <<'TOML'
[workspace]
resolver = "2"
members = ["primary", "bridge", "leaf", "spare"]
TOML
for package in primary bridge leaf spare; do
  mkdir -p "$repo/cargo/$package/src"
  cat >"$repo/cargo/$package/Cargo.toml" <<TOML
[package]
name = "$package"
version = "0.1.0"
edition = "2021"
TOML
  printf 'pub fn value() -> u8 { 42 }\n' >"$repo/cargo/$package/src/lib.rs"
done
printf '\n[dependencies]\nbridge = { path = "../bridge" }\n' >>"$repo/cargo/primary/Cargo.toml"
printf '\n[dependencies]\nleaf = { path = "../leaf" }\n' >>"$repo/cargo/bridge/Cargo.toml"
(cd "$repo/cargo" && cargo generate-lockfile --offline)

printf '%s\n' '{"type":"module","devDependencies":{"vitest":"4.1.11"}}' >"$repo/web/package.json"
printf '%s\n' 'export { value } from "./café.mjs"' >"$repo/web/bridge.mjs"
printf '%s\n' 'export const value = 42' >"$repo/web/café.mjs"
printf '%s\n' 'export const spare = 42' >"$repo/web/spare-é.mjs"
printf '%s\n' 'export const shared = 42' >"$repo/shared.mjs"
cat >"$repo/web/check.test.mjs" <<'JS'
import { expect, test } from 'vitest'
import { value } from './bridge.mjs'
import { shared } from '../shared.mjs'
test('module', () => expect(value + shared).toBe(84))
JS
printf '%s\n' 'shell external.settings # reason: the external runner reads the setting' \
  >"$repo/.github/ci-lanes.conf"
printf 'node_modules\n' >"$repo/.gitignore"

git -C "$repo" add -A
git -C "$repo" commit -qm 'queue default'
queue_base="$(git -C "$repo" rev-parse HEAD)"
printf '[env]\nHARNESS_CI_PER_PUSH_REASON = "direct render landings"\n' >"$repo/kendex.settings.toml"
git -C "$repo" add -A
git -C "$repo" commit -qm 'per-push opt-back'
opted_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-static "$opted_base"
write_workflow no-cargo >"$repo/.github/workflows/ci.yml"
git -C "$repo" commit -qam 'static shell, Vitest and installed-package lanes'
static_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-vitest-package "$static_base"
write_workflow web-only >"$repo/.github/workflows/ci.yml"
git -C "$repo" rm -q -- .github/ci-lanes.conf
printf '%s\n' 'export const value = 42' >"$repo/.codex/skills/math/imported.mjs"
printf '%s\n' 'export const sibling = 42' >"$repo/.codex/skills/math/sibling.mjs"
cat >"$repo/.kendex-generated.json" <<'JSON'
[".agents/skills/math/scripts/check.sh",".codex/skills/math/SKILL.md",".codex/skills/math/imported.mjs",".codex/skills/math/sibling.mjs"]
JSON
cat >"$repo/web/check.test.mjs" <<'JS'
import { expect, test } from 'vitest'
import { value } from '../.codex/skills/math/imported.mjs'
test('installed package', () => expect(value).toBe(42))
JS
git -C "$repo" add -A
git -C "$repo" commit -qm 'Vitest reads a module from an installed package'
vitest_package_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-vitest-copilot "$vitest_package_base"
mkdir -p "$repo/.github/skills"
git -C "$repo" mv -- .codex/skills/math .github/skills/math
python3 - "$repo" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for name in ('.kendex-generated.json', '.kendex-lock.json', 'web/check.test.mjs'):
    path = root / name
    source = path.read_text()
    updated = source.replace('.codex/skills', '.github/skills').replace(
        'skill:math:codex', 'skill:math:copilot')
    assert updated != source
    path.write_text(updated)
PY
git -C "$repo" commit -qam 'Vitest reads a module from a Copilot copy-mode skill'
vitest_copilot_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-vitest-disabled "$vitest_copilot_base"
git -C "$repo" mv -- .github/skills/math/SKILL.md .github/skills/math/SKILL.md.disabled
python3 - "$repo" <<'PY'
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
inventory = root / '.kendex-generated.json'
paths = json.loads(inventory.read_text())
paths[paths.index('.github/skills/math/SKILL.md')] += '.disabled'
inventory.write_text(json.dumps(paths) + '\n')
lock = root / '.kendex-lock.json'
record = json.loads(lock.read_text())
record['entries']['skill:math:copilot']['enabled'] = False
lock.write_text(json.dumps(record) + '\n')
PY
git -C "$repo" commit -qam 'the Copilot copy of the skill is switched off'
vitest_disabled_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-vitest-unowned "$vitest_disabled_base"
printf '%s\n' '{"entries":[]}' >"$repo/.kendex-lock.json"
git -C "$repo" commit -qam 'an install record the reader cannot use'
vitest_unowned_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-agent-pair "$static_base"
mkdir -p "$repo/.codex/agents" "$repo/.github/agents"
printf 'name = "auditor"\n' >"$repo/.codex/agents/auditor.toml"
printf 'auditor\n' >"$repo/.github/agents/auditor.agent.md"
printf '%s\n' 'cat ./.github/agents/auditor.agent.md' >"$repo/tools/check.sh"
python3 - "$repo" <<'PY'
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
renders = {'codex': '.codex/agents/auditor.toml', 'copilot': '.github/agents/auditor.agent.md'}
inventory = root / '.kendex-generated.json'
inventory.write_text(json.dumps(json.loads(inventory.read_text()) + list(renders.values())) + '\n')
lock = root / '.kendex-lock.json'
record = json.loads(lock.read_text())
for harness, path in renders.items():
    record['entries'][f'agent:auditor:{harness}'] = {
        'enabled': True, 'sourceRepo': 'example/catalog',
        'emitted': {'kind': 'agent', 'name': 'auditor', 'paths': [path]},
    }
lock.write_text(json.dumps(record) + '\n')
PY
git -C "$repo" add -A
git -C "$repo" commit -qm 'a shell lane reads the Copilot render of an agent package'
agent_pair_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-command-pair "$static_base"
mkdir -p "$repo/.claude/commands" "$repo/.agents/skills/audit"
printf 'audit\n' >"$repo/.claude/commands/audit.md.disabled"
printf 'audit\n' >"$repo/.agents/skills/audit/SKILL.md.disabled"
printf '%s\n' 'cat ./.agents/skills/audit/SKILL.md.disabled' >"$repo/tools/check.sh"
python3 - "$repo" <<'PY'
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
# kendex emits a Codex command as a skill tree and parks both renders.
renders = {
    'claude': ('command', '.claude/commands/audit.md.disabled', '.claude/commands/audit.md.disabled'),
    'codex': ('skill', '.agents/skills/audit/SKILL.md.disabled', '.agents/skills/audit'),
}
inventory = root / '.kendex-generated.json'
inventory.write_text(json.dumps(json.loads(inventory.read_text()) +
                                [path for _, path, _ in renders.values()]) + '\n')
lock = root / '.kendex-lock.json'
record = json.loads(lock.read_text())
for harness, (kind, _, position) in renders.items():
    record['entries'][f'command:audit:{harness}'] = {
        'enabled': False, 'sourceRepo': 'example/catalog',
        'emitted': {'kind': kind, 'name': 'audit', 'paths': [position]},
    }
lock.write_text(json.dumps(record) + '\n')
PY
git -C "$repo" add -A
git -C "$repo" commit -qm 'a shell lane reads the Codex render of a switched-off command'
command_pair_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-deleted-workdir "$static_base"
write_workflow deleted-workdir >"$repo/.github/workflows/ci.yml"
mkdir -p "$repo/check-cwd"
printf 'only\n' >"$repo/check-cwd/only.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm 'a check working directory with one tracked file'
deleted_workdir_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-symlink "$static_base"
mkdir -p "$repo/other/subdir"
ln -s other/subdir "$repo/link"
: >"$repo/other/subdir/.gitkeep"
printf 'old\n' >"$repo/other/input.txt"
printf 'root\n' >"$repo/input.txt"
printf 'cat ./link/../input.txt\n' >"$repo/tools/check.sh"
git -C "$repo" add -A
git -C "$repo" commit -qm 'shell input through a symlink and parent component'
symlink_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-parent-hop "$static_base"
mkdir -p "$repo/tools/cache"
printf 'only\n' >"$repo/tools/cache/only.txt"
printf 'input\n' >"$repo/tools/input.txt"
printf 'cat ./tools/cache/../input.txt\n' >"$repo/tools/check.sh"
git -C "$repo" add -A
git -C "$repo" commit -qm 'shell input through a tracked directory and a parent component'
parent_hop_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-cargo-child "$opted_base"
cat >"$repo/cargo/primary/src/lib.rs" <<'RS'
#[path = "../../spare/src/mod.rs"]
mod external;

#[test]
fn checks_child() {
    assert_eq!(external::child::value(), 42);
}
RS
printf 'pub mod child;\n' >"$repo/cargo/spare/src/mod.rs"
printf 'pub fn value() -> u8 { 42 }\n' >"$repo/cargo/spare/src/child.rs"
git -C "$repo" add -A
git -C "$repo" commit -qm 'Cargo compiles a child of an out-of-package module'
cargo_child_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-cargo-linked-child "$opted_base"
mkdir -p "$repo/cargo/primary/linked"
cat >"$repo/cargo/primary/src/lib.rs" <<'RS'
#[cfg(test)]
#[path = "../linked/mod.rs"]
mod linked;

#[test]
fn checks_linked_child() {
    assert_eq!(linked::child::value().trim(), "42");
}
RS
printf 'pub mod child;\n' >"$repo/cargo/primary/linked/mod.rs"
cat >"$repo/cargo/primary/linked/child.rs" <<'RS'
pub fn value() -> &'static str {
    include_str!("../../spare/src/input.txt")
}
RS
printf '42\n' >"$repo/cargo/spare/src/input.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm 'a linked child reads an input outside its target source tree'
cargo_linked_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-cargo-parent-hop "$opted_base"
mkdir -p "$repo/cargo/spare/cache"
printf 'only\n' >"$repo/cargo/spare/cache/only.txt"
for input in cargo/spare/hop.txt cargo/spare/input.txt cargo/bridge/hop.txt; do
  printf '42\n' >"$repo/$input"
done
cat >"$repo/cargo/primary/src/lib.rs" <<'RS'
#[test]
fn reads_through_directories() {
    assert_eq!(include_str!("../../spare/cache/../hop.txt").trim(), "42");
    assert_eq!(include_str!("../../bridge/src/../hop.txt").trim(), "42");
    assert_eq!(bridge::INPUT.trim(), "42");
}
RS
printf '%s\n' 'pub fn value() -> u8 { 42 }' \
  'pub const INPUT: &str = include_str!("../../spare/input.txt");' >"$repo/cargo/bridge/src/lib.rs"
printf '%s\n' 'cat ./cargo/spare/input.txt' >>"$repo/tools/check.sh"
git -C "$repo" add -A
git -C "$repo" commit -qm 'Rust includes pass through a member directory and a dependency source tree'
cargo_parent_hop_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-queue-prerequisite "$static_base"
write_workflow queue-prerequisite >"$repo/.github/workflows/ci.yml"
printf '%s\n' 'shell:queue shared.mjs # reason: the queue also checks the shared module' \
  >"$repo/.github/ci-lanes.conf"
printf 'HARNESS_CI_QUEUE_PATHS = ""\n' >>"$repo/kendex.settings.toml"
queue_reader=.agents/skills/harness-ci/scripts/lib/ci-lanes.sh
mkdir -p "$repo/${queue_reader%/*}"
cp "$HARNESS_CI_PACKAGE/scripts/lib/ci-lanes.sh" "$repo/$queue_reader"
git -C "$repo" add -A
git -C "$repo" commit -qm 'a selected lane needs a queue-marked reader of a shared input'
queue_prereq_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-shared-runtime "$static_base"
cat >"$repo/web/check.test.mjs" <<'JS'
import { expect, test, vi } from 'vitest'
test('runtime input shared by shell', async () => {
  const loaded = await vi.importActual('../shared.mjs')
  expect(loaded.shared).toBe(42)
})
JS
git -C "$repo" commit -qam 'load the shell input through the Vitest runtime'
shared_runtime_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-runtime-only "$static_base"
write_workflow web-only >"$repo/.github/workflows/ci.yml"
git -C "$repo" rm -q -- .github/ci-lanes.conf
printf '%s\n' 'export const value = 42' >"$repo/runtime-only.mjs"
cat >"$repo/web/check.test.mjs" <<'JS'
import { expect, test, vi as loader } from 'vitest'
test('runtime input in a one-lane workflow', async () => {
  const loaded = await loader.importActual('../runtime-only.mjs')
  expect(loaded.value).toBe(42)
})
JS
git -C "$repo" add -A
git -C "$repo" commit -qm 'one Vitest lane reads a runtime-only module'
runtime_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-computed "$runtime_base"
printf '%s\n' 'export const value = 0' >"$repo/web/shared.mjs"
printf '%s\n' 'export const value = 42' >"$repo/web/shared.mjs-runtime.mjs"
cat >"$repo/web/check.test.mjs" <<'JS'
import { expect, test } from 'vitest'
test('computed module path in a one-lane workflow', async () => {
  const suffix = '-runtime.mjs'
  const loaded = await import('./shared.mjs' + suffix)
  expect(loaded.value).toBe(42)
})
JS
git -C "$repo" add -A
git -C "$repo" commit -qm 'one Vitest lane reads a computed module path'
computed_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-shell "$opted_base"
printf '%s\n' 'input=./shared.mjs' 'cat "$input"' >"$repo/tools/check.sh"
git -C "$repo" commit -qam 'shell command with a computed input'
shell_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-import "$opted_base"
cat >"$repo/web/opaque.test.mjs" <<'JS'
import { basename } from /* Node built-in */ 'path'
import { expect, test } from 'vitest'
test('base name', () => expect(basename('/root/item')).toBe('item'))
JS
git -C "$repo" add -A
git -C "$repo" commit -qm 'Vitest command with a commented nonlocal import'
import_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-config "$opted_base"
printf '{"compilerOptions":{"experimentalDecorators":true}}\n' >"$repo/tsconfig.json"
printf '%s\n' 'cat ./tsconfig.json' >"$repo/tools/check.sh"
cat >"$repo/web/check.test.mjs" <<'JS'
import { expect, test } from 'vitest'
test('module', () => expect(42).toBe(42))
JS
printf 'export const value = 42\n' >"$repo/web/bridge.mjs"
cat >"$repo/web/decorators.test.ts" <<'TS'
import { expect, test } from 'vitest'
function tag(_target: unknown, _name: string, _index: number) {}
class Subject {
  value(@tag input: number) { return input }
}
test('parameter decorator', () => expect(new Subject().value(42)).toBe(42))
TS
git -C "$repo" add -A
git -C "$repo" commit -qm 'Vitest inherits decorators from the root config'
config_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-indexed "$opted_base"
python3 - "$repo/.github/workflows/ci.yml" <<'PY'
from pathlib import Path
import re
import sys
path = Path(sys.argv[1])
updated, gates = re.subn(r"needs\.changes\.outputs\.lane_([a-z_]+)",
                        r"needs.changes.outputs[format('lane{0}\1', '_')]",
                        path.read_text())
assert gates > 0
path.write_text(updated)
PY
git -C "$repo" commit -qam 'equivalent lane lookups with computed output keys'
indexed_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-aliased "$opted_base"
python3 - "$repo/.github/workflows/ci.yml" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
updated = source.replace("\n      lane_", "\n      gate_").replace(
    "needs.changes.outputs.lane_", "needs.changes.outputs.gate_")
assert updated != source
path.write_text(updated)
PY
git -C "$repo" commit -qam 'forward per-lane verdicts through output aliases'
aliased_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-aggregate "$opted_base"
cat >"$repo/.github/workflows/ci.yml" <<'YAML'
name: CI
on: merge_group
env:
  TEST_MODE: smoke
jobs:
  changes:
    runs-on: ubuntu-latest
    steps:
      - id: classify
        uses: vanillagreencom/kendex/.github/actions/change-class@main
  ci:
    needs: changes
    runs-on: ubuntu-latest
    steps:
      - run: true
YAML
git -C "$repo" add -A
git -C "$repo" commit -qm 'aggregate-only workflow'
aggregate_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-dispatch "$queue_base"
git -C "$repo" rm -q -- .github/ci-lanes.conf
mkdir -p "$repo/bin" "$repo/.agents/skills/math/scripts/lib"
cat >"$repo/bin/check" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
lane_table=(
  "check-scans:
    scan
  "
  "check-lane-host:
    lane-host
  "
  "check-other:
    other
  "
)
step_scan() {
  bash ./bin/check-scans.sh
}
step_lane_host() {
  ./bin/check-lane-host.sh
}
step_other() {
  bash ./bin/check-other.sh
}
case ${1-} in
  --lane) run=$2 ;;
  *) exit 2 ;;
esac
for entry in "${lane_table[@]}"; do
  name=${entry%%:*}
  [ "$name" = "$run" ] || continue
  for member in ${entry#*:}; do
    case $member in
      @*|+host|+isolated) ;;
      *) "step_${member//-/_}" ;;
    esac
  done
done
SH
cat >"$repo/bin/check-lane-host.sh" <<'SH'
#!/usr/bin/env bash
source ./bin/markdown.sh
SH
chmod +x "$repo/bin/check" "$repo/bin/check-lane-host.sh"
fixture_helper=.agents/skills/math/scripts/lib/md-refs.awk
printf 'BEGIN { print 42 }\n' >"$repo/$fixture_helper"
printf 'cat ./%s\n' "$fixture_helper" >"$repo/bin/check-scans.sh"
printf 'cat ./%s\n' "$fixture_helper" >"$repo/bin/markdown.sh"
printf 'cat ./bin/other.txt\n' >"$repo/bin/check-other.sh"
printf 'unrelated input\n' >"$repo/bin/other.txt"
python3 - "$repo/.kendex-generated.json" "$fixture_helper" <<'PY'
import json
from pathlib import Path
import sys
inventory = Path(sys.argv[1])
paths = json.loads(inventory.read_text())
paths.append(sys.argv[2])
inventory.write_text(json.dumps(paths) + "\n")
PY
write_dispatch_workflow() {
  local gate="$1" shape="${2:-}" lane needs
  cat <<YAML
name: CI
on: [pull_request, merge_group]
jobs:
  changes:
    outputs:
      lanes: \${{ steps.markdown.outputs.markdown_only == 'true' && 'false' || steps.$gate.outputs.lanes }}
      markdown_only: \${{ steps.markdown.outputs.markdown_only }}
      change_class: \${{ steps.classify.outputs.change_class }}
      queue_deferred: \${{ steps.verdict.outputs.queue_deferred }}
      lane_check-scans: \${{ steps.verdict.outputs.lane_check-scans }}
      lane_check-lane-host: \${{ steps.verdict.outputs.lane_check-lane-host }}
      lane_check-other: \${{ steps.verdict.outputs.lane_check-other }}
YAML
  cat <<'YAML'
    env:
      EVENT: ${{ github.event_name }}
      BASE: ${{ github.event.pull_request.base.sha || github.event.merge_group.base_sha }}
      HEAD: ${{ github.event.pull_request.head.sha || github.event.merge_group.head_sha }}
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
      - id: markdown
        run: |
          markdown=false
          paths="$(git diff --name-only "$BASE" "$HEAD")"
          if [ -n "$paths" ] && ! grep -qv '\.md$' <<<"$paths"; then
            markdown=true
          fi
          echo "markdown_only=$markdown" >>"$GITHUB_OUTPUT"
      - id: classify
        uses: vanillagreencom/kendex/.github/actions/change-class@main
      - id: verdict
        env:
          QUEUE_ONLY: ${{ steps.classify.outputs.queue_only }}
          LANE_VERDICTS: ${{ steps.classify.outputs.lane_verdicts }}
YAML
  if [ "$shape" = wrong-event ]; then
    printf '%s\n' '          EVENT: pull_request'
  fi
  cat <<'YAML'
        run: |
          printf '%s\n' "$LANE_VERDICTS" >>"$GITHUB_OUTPUT"
          deferred=false
          if [ "$EVENT" = pull_request ] && [ "$QUEUE_ONLY" = true ] && grep -q '^lane_[a-z0-9_-]*=false$' <<<"$LANE_VERDICTS"; then
            deferred=true
            echo 'lane_check-scans=false' >>"$GITHUB_OUTPUT"
          fi
          echo "queue_deferred=$deferred" >>"$GITHUB_OUTPUT"
YAML
  for lane in check-scans check-other check-lane-host; do
    needs=changes
    if [ "$lane" = check-scans ] && [[ "$shape" = scan-*-prerequisite ]]; then
      needs='[changes, check-other]'
    fi
    cat <<YAML
  $lane:
    needs: $needs
YAML
    if [ "$lane" = check-scans ]; then
      cat <<'YAML'
    if: ${{ !cancelled() && (needs.changes.result != 'success' || (needs.changes.outputs.markdown_only == 'true' && github.event_name == 'merge_group') || (needs.changes.outputs.markdown_only != 'true' && ((needs.changes.outputs.change_class != 'render' && needs.changes.outputs.queue_deferred != 'true') || needs.changes.outputs.lane_check-scans != 'false'))) }}
YAML
    elif [ "$lane:$shape" = check-other:scan-independent-prerequisite ]; then
      printf '%s\n' '    if: ${{ !cancelled() }}'
    else
      cat <<YAML
    if: \${{ !cancelled() && (needs.changes.result != 'success' || (needs.changes.outputs.lanes != 'false' && needs.changes.outputs.lane_$lane != 'false')) }}
YAML
    fi
    cat <<YAML
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
YAML
    case "$lane:$shape" in
      check-lane-host:local-action)
        printf '%s\n' '      - uses: ./.github/actions/package-runtimes' ;;
      check-lane-host:opaque-host)
        printf '%s\n' '      - run: bin/check-opaque --lane check-lane-host'
        continue ;;
      check-scans:opaque-prefix)
        cat <<'YAML'
      - if: needs.changes.outputs.markdown_only == 'true'
        run: bin/check --markdown-merge
YAML
        ;;
      check-lane-host:opaque-prefix)
        cat <<'YAML'
      - run: |
          printf '%s\n' ready >/dev/null
          bin/check --lane check-lane-host
YAML
        continue ;;
    esac
    printf '      - run: bin/check --lane %s\n' "$lane"
  done
}
write_dispatch_workflow classify >"$repo/.github/workflows/ci.yml"
git -C "$repo" add -A
git -C "$repo" commit -qm 'a runner dispatches named lanes through a derived workflow gate'
dispatch_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-unmapped "$dispatch_base"
write_dispatch_workflow absent >"$repo/.github/workflows/ci.yml"
git -C "$repo" commit -qam 'the workflow gate has no output publisher'
dispatch_unmapped_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-opaque-dispatch "$dispatch_base"
cat >"$repo/bin/check" <<'SH'
#!/usr/bin/env bash
exec bash "./bin/$2.sh"
SH
write_dispatch_workflow classify local-action >"$repo/.github/workflows/ci.yml"
git -C "$repo" commit -qam 'the runner computes the script name'
dispatch_opaque_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-scan-prerequisite "$dispatch_base"
write_dispatch_workflow classify scan-independent-prerequisite >"$repo/.github/workflows/ci.yml"
git -C "$repo" commit -qam 'the scan prerequisite runs independently of the lanes output'
dispatch_scan_prereq_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-gated-scan-prerequisite "$dispatch_scan_prereq_base"
write_dispatch_workflow classify scan-gated-prerequisite >"$repo/.github/workflows/ci.yml"
git -C "$repo" commit -qam 'the scan depends on a job gated by the lanes output'
dispatch_gated_scan_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-opaque-prefix "$dispatch_base"
write_dispatch_workflow classify opaque-prefix >"$repo/.github/workflows/ci.yml"
git -C "$repo" commit -qam 'opaque steps before literal runner calls'
dispatch_opaque_prefix_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-opaque-host "$dispatch_base"
git -C "$repo" show "$dispatch_opaque_base:bin/check" >"$repo/bin/check-opaque"
chmod +x "$repo/bin/check-opaque"
write_dispatch_workflow classify opaque-host >"$repo/.github/workflows/ci.yml"
git -C "$repo" add -A
git -C "$repo" commit -qm 'a single opaque lane runner beside resolved peers'
dispatch_opaque_host_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-wrong-event "$dispatch_base"
write_dispatch_workflow classify wrong-event >"$repo/.github/workflows/ci.yml"
git -C "$repo" commit -qam 'a step shadows the job event with a pull request constant'
dispatch_wrong_event_base="$(git -C "$repo" rev-parse HEAD)"
git clone --quiet "$repo" "$trusted"
if [ -x "$root/ui/node_modules/.bin/vitest" ]; then
  modules="$root/ui/node_modules"
else
  # Resolve the real tool in the runner cache, outside all fixture checkouts.
  binary="$(npm exec --yes --package=vitest@4.1.11 -- which vitest)"
  modules="$(cd "$(dirname "$binary")/.." && pwd -P)"
fi
ln -s "$modules" "$trusted/web/node_modules"
ln -s "$modules" "$repo/web/node_modules"

# The verifier supplies the established render proof. Lane selection still
# reads the committed inventory and lock through the ordinary classifier.
cat >"$SANDBOX/bin/kendex" <<'VERIFY'
#!/usr/bin/env bash
case "$*" in
  --version) printf 'kendex 0.0.0-stub\n' ;;
  'verify --help') printf '%s\n' '  --bot-instructions-from <DIR>' ;;
  *)
    skill=.codex/skills/math
    [ ! -d .github/skills/math ] || skill=.github/skills/math
    printf '{"version":1,"clean":true,"checked":2,"failed":0,"base_owned":[{"path":"%s","owns":"tree"}],"rows":[{"kind":"skill","name":"math","state":"ok","positions":[{"path":"%s","owns":"tree"}]},{"kind":"inventory","state":"ok","positions":[{"path":".kendex-generated.json","owns":"file"}]}]}\n' "$skill" "$skill"
    ;;
esac
VERIFY
chmod +x "$SANDBOX/bin/kendex"

verdict() { sed -n "/^lane_$1=/s/^lane_$1=//p" "$2"; }

# Run the fixture's output steps and evaluate its actual job conditions with
# the same GitHub expression reader as ci-template.test.sh.
dispatch_workflow_jobs() { # REPO CLASSIFIER_OUTPUT BASE HEAD EVENT
  python3 - "$@" "$TEST_DIR/lib/gh-eval.py" "$SANDBOX" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import yaml

repo, classified, base, head, event, evaluator, sandbox = sys.argv[1:]
jobs = yaml.load((Path(repo) / ".github/workflows/ci.yml").read_text(), Loader=yaml.BaseLoader)["jobs"]
control = jobs["changes"]
github = {"event_name": event, "event": {"merge_group": {"base_sha": base, "head_sha": head}}}

def read_outputs(path):
    rows = iter(Path(path).read_text().splitlines())
    values = {}
    for row in rows:
        if "<<" in row:
            key, marker = row.split("<<", 1)
            lines = []
            while (line := next(rows)) != marker:
                lines.append(line)
            values[key] = "\n".join(lines)
        elif row:
            key, value = row.split("=", 1)
            values[key] = value
    return values

def expression(text):
    return text.removeprefix("${{").removesuffix("}}").strip()

def evaluate(text, context):
    return json.loads(subprocess.check_output(
        [sys.executable, evaluator, "value", json.dumps(context), expression(text)],
    ))

steps = {"classify": {"outputs": read_outputs(classified)}}
job_env = {name: evaluate(value, {"github": github}) for name, value in control["env"].items()}
for step in control["steps"]:
    if step.get("id") not in {"markdown", "verdict"}:
        continue
    step_env = {name: evaluate(value, {"steps": steps}) for name, value in step.get("env", {}).items()}
    output = Path(sandbox) / "dispatch-step-output"
    output.write_text("")
    subprocess.run(["bash", "-ec", step["run"]], cwd=repo, check=True,
                   env={**os.environ, **job_env, **step_env, "GITHUB_OUTPUT": str(output)})
    steps[step["id"]] = {"outputs": read_outputs(output)}

outputs = {name: evaluate(value, {"steps": steps}) for name, value in control["outputs"].items()}
results = {"changes": {"result": "success", "outputs": outputs}}
eligible = []
for name in ("check-other", "check-scans", "check-lane-host"):
    job = jobs[name]
    needs = job["needs"] if isinstance(job["needs"], list) else [job["needs"]]
    context = {"github": github, "needs": {need: results[need] for need in needs}}
    condition = f"{name}\t{','.join(needs)}\t{expression(job['if'])}\n"
    runs = subprocess.check_output([sys.executable, evaluator, "jobs", json.dumps(context)],
                                   input=condition, text=True).strip()
    results[name] = {"result": "success" if runs else "skipped"}
    if runs:
        eligible.append(name)
print(",".join(eligible))
PY
}

rows=0
while IFS='|' read -r label path shell cargo web installed event expected_gate scans host other dispatch_cause dispatch_lanes; do
  [ -z "${LANE_REACH_CASE:-}" ] || [ "$label" = "$LANE_REACH_CASE" ] || continue
  rows=$((rows + 1))
  base="$opted_base"
  push_ref=refs/heads/main
  case "$label" in
    source|removed-source|shared-gate|shell-workdir|vitest-import|vitest-unread|vitest-external|installed|installed-push|shared-root-config)
      base="$static_base" ;;
    vitest-package-sibling) base="$vitest_package_base" ;;
    vitest-copilot-sibling) base="$vitest_copilot_base" ;;
    vitest-disabled-sibling) base="$vitest_disabled_base" ;;
    vitest-unowned-disabled) base="$vitest_unowned_base" ;;
    agent-pair) base="$agent_pair_base" ;;
    command-pair) base="$command_pair_base" ;;
    shell-parent-hop) base="$parent_hop_base" ;;
    shared-runtime) base="$shared_runtime_base" ;;
    shell-symlink) base="$symlink_base" ;;
    deleted-workdir) base="$deleted_workdir_base" ;;
    cargo-external-child) base="$cargo_child_base" ;;
    cargo-linked-child) base="$cargo_linked_base" ;;
    cargo-parent-hop|cargo-passed-dependency) base="$cargo_parent_hop_base" ;;
    queue-prerequisite) base="$queue_prereq_base" ;;
    runtime-only) base="$runtime_base" ;;
    computed-import) base="$computed_base" ;;
    aggregate-render) base="$aggregate_base" ;;
    indexed-render) base="$indexed_base" ;;
    aliased-render) base="$aliased_base" ;;
    shell-unresolved) base="$shell_base" ;;
    vitest-unresolved-import) base="$import_base" ;;
    vitest-inherited|push-unresolved) base="$config_base" ;;
    dispatch-helper|dispatch-host-source|dispatch-unrelated) base="$dispatch_base" ;;
    dispatch-unmapped) base="$dispatch_unmapped_base" ;;
    dispatch-unresolved) base="$dispatch_opaque_base" ;;
    dispatch-scan-prerequisite|dispatch-scan-readme) base="$dispatch_scan_prereq_base" ;;
    dispatch-scan-gated) base="$dispatch_gated_scan_base" ;;
    dispatch-opaque-prefix) base="$dispatch_opaque_prefix_base" ;;
    dispatch-opaque-host) base="$dispatch_opaque_host_base" ;;
    dispatch-wrong-event) base="$dispatch_wrong_event_base" ;;
    queued-render-push) base="$queue_base" ;;
    feature-render-push) push_ref=refs/heads/feature ;;
  esac
  event="${event:-merge_group}"
  git -C "$trusted" checkout -q --detach "$base"
  git -C "$repo" checkout -q -B row "$base"
  case "$label" in
    removed-source|deleted-workdir|shell-parent-hop|cargo-parent-hop) git -C "$repo" rm -q -- "$path" ;;
    # The shell lane reads the second file, which Cargo reads only through the dependency.
    cargo-passed-dependency) printf '\n' >>"$repo/$path"; printf '\n' >>"$repo/cargo/spare/input.txt" ;;
    checkout-attributes|nested-attributes) printf '*.sh eol=crlf\n' >"$repo/$path" ;;
    vitest-import) printf 'export const value = 43\n' >"$repo/$path" ;;
    vitest-external|shared-runtime) printf 'export const shared = 43\n' >"$repo/$path" ;;
    runtime-only|computed-import) printf 'export const value = 43\n' >"$repo/$path" ;;
    shell-symlink) printf 'physical\n' >"$repo/$path" ;;
    dispatch-helper) printf 'BEGIN { print 43 }\n' >"$repo/$path" ;;
    cargo-external-child) printf 'pub fn value() -> u8 { 43 }\n' >"$repo/$path" ;;
    cargo-linked-child) printf '43\n' >"$repo/$path" ;;
    shared-root-config) printf '{"private":true}\n' >"$repo/$path" ;;
    vitest-inherited|push-unresolved)
      printf '{"compilerOptions":{"experimentalDecorators":false}}\n' >"$repo/$path" ;;
    *) printf '\n' >>"$repo/$path" ;;
  esac
  git -C "$repo" add -A
  git -C "$repo" commit -qm "$label"
  case "$label" in
  vitest-inherited|shared-runtime|runtime-only|computed-import)
    [ -x "$trusted/web/node_modules/.bin/vitest" ] && [ -x "$repo/web/node_modules/.bin/vitest" ]
    base_status=0 head_status=0
    (cd "$trusted/web" && ./node_modules/.bin/vitest run) >"$SANDBOX/base-vitest-log" 2>&1 || base_status=$?
    (cd "$repo/web" && ./node_modules/.bin/vitest run) >"$SANDBOX/head-vitest-log" 2>&1 || head_status=$?
    [ "$base_status" = 0 ] || cat "$SANDBOX/base-vitest-log" >&2
    [ "$head_status" = 1 ] || cat "$SANDBOX/head-vitest-log" >&2
    assert_eq "$label passes actual Vitest at base" 0 "$base_status"
    assert_eq "$label fails actual Vitest after the change" 1 "$head_status" ;;
  shell-symlink)
    assert_eq "$label follows the link before its parent component" physical \
      "$(cd "$repo" && bash ./tools/check.sh)" ;;
  deleted-workdir)
    base_status=0 head_status=0
    (cd "$trusted/check-cwd") 2>/dev/null || base_status=$?
    (cd "$repo/check-cwd") 2>/dev/null || head_status=$?
    assert_eq "$label can enter the base directory" 0 "$base_status"
    assert_eq "$label cannot enter the changed directory" 1 "$head_status" ;;
  shell-parent-hop)
    base_status=0 head_status=0
    (cd "$trusted" && bash ./tools/check.sh) >/dev/null 2>&1 || base_status=$?
    (cd "$repo" && bash ./tools/check.sh) >/dev/null 2>&1 || head_status=$?
    assert_eq "$label reads its input through the base directory" 0 "$base_status"
    assert_eq "$label cannot pass through the removed directory" 1 "$head_status" ;;
  dispatch-helper)
    for member in check-scans check-lane-host; do
      assert_eq "$label $member reads the helper at runtime" "$(cat "$repo/$fixture_helper")" \
        "$(cd "$repo" && bin/check --lane "$member")"
    done ;;
  cargo-external-child|cargo-linked-child|cargo-parent-hop)
    base_status=0 head_status=0
    (cd "$trusted/cargo" && CARGO_TARGET_DIR="$SANDBOX/base-cargo-target" cargo test --offline --locked -p primary) \
      >"$SANDBOX/base-cargo-log" 2>&1 || base_status=$?
    (cd "$repo/cargo" && CARGO_TARGET_DIR="$SANDBOX/head-cargo-target" cargo test --offline --locked -p primary) \
      >"$SANDBOX/head-cargo-log" 2>&1 || head_status=$?
    [ "$base_status" = 0 ] || cat "$SANDBOX/base-cargo-log" >&2
    [ "$head_status" = 101 ] || cat "$SANDBOX/head-cargo-log" >&2
    assert_eq "$label passes actual Cargo at base" 0 "$base_status"
    assert_eq "$label fails actual Cargo after the change" 101 "$head_status" ;;
  esac
  : >"$SANDBOX/action"
  : >"$SANDBOX/local"
  head="$(git -C "$repo" rev-parse HEAD)"
  cli="$CHANGE_CLASS"
  case "$label" in
    dispatch-*) cli="${CHANGE_CLASS_UNDER_TEST:-$root/.agents/skills/harness-ci/scripts/change-class}" ;;
  esac
  printf '{"ref":"%s","before":"%s","after":"%s","forced":false,"repository":{"default_branch":"main"}}\n' \
    "$push_ref" "$base" "$head" >"$SANDBOX/event"
  PATH="$SANDBOX/bin:$PATH" CLASSIFIER="$classifier" EVENT="$event" BASE="$base" HEAD="$head" \
    GITHUB_REPOSITORY=example/lane-reach GITHUB_JOB=changes GITHUB_REF="$push_ref" \
    GITHUB_WORKFLOW_REF="example/lane-reach/.github/workflows/ci.yml@$push_ref" GITHUB_EVENT_PATH="$SANDBOX/event" \
    QUEUE_ONLY_DEFAULT=true \
    REPO="$repo" LANES_FROM="$trusted" GITHUB_OUTPUT="$SANDBOX/action" "$action" \
    >"$SANDBOX/stdout" 2>"$SANDBOX/action-log" || { cat "$SANDBOX/action-log"; exit 1; }
  (
    unset GITHUB_REPOSITORY GITHUB_JOB GITHUB_WORKFLOW_REF
    PATH="$SANDBOX/bin:$PATH" GITHUB_REF="$push_ref" GITHUB_EVENT_PATH="$SANDBOX/event" \
      "$cli" --event "$event" --base "$base" --head "$head" --queue-only-default true \
      --repo "$repo" --lanes-from "$trusted" --output "$SANDBOX/local"
  ) \
    >"$SANDBOX/stdout" 2>"$SANDBOX/local-log" || { cat "$SANDBOX/local-log"; exit 1; }
  for lane in shell cargo web installed; do
    actual="$(verdict "$lane" "$SANDBOX/action")"
    if [ "$actual" != "${!lane}" ]; then cat "$SANDBOX/action-log" >&2; fi
    assert_eq "$label $lane" "${!lane}" "$actual"
    assert_eq "$label $lane local parity" "$actual" "$(verdict "$lane" "$SANDBOX/local")"
  done
  case "$label" in
    dispatch-*)
      for implementation in action local; do
        output="$SANDBOX/$implementation"
        log="$SANDBOX/$implementation-log"
        actual="$(verdict check-lane-host "$output")"
        if [ "$actual" != "$host" ]; then cat "$log" >&2; fi
        assert_eq "$label $implementation scans" "$scans" "$(verdict check-scans "$output")"
        assert_eq "$label $implementation lane host" "$host" "$actual"
        assert_eq "$label $implementation other" "$other" "$(verdict check-other "$output")"
        assert_eq "$label $implementation gate" "${dispatch_lanes:-true}" "$(sed -n 's/^lanes=//p' "$output")"
        assert_eq "$label $implementation roster cause" "$dispatch_cause" \
          "$(sed -n 's/^lanes_cause=//p' "$output")"
        case "$label" in
          dispatch-scan-readme)
            assert_eq "$label $implementation class" trivial "$(sed -n 's/^change_class=//p' "$output")"
            assert_eq "$label $implementation scan and prerequisite run" 'check-other,check-scans' \
              "$(dispatch_workflow_jobs "$repo" "$output" "$base" "$head" "$event")" ;;
          dispatch-scan-prerequisite)
            assert_eq "$label $implementation ordinary eligible jobs" 'check-other,check-scans,check-lane-host' \
              "$(dispatch_workflow_jobs "$repo" "$output" "$base" "$head" "$event")" ;;
          dispatch-scan-gated)
            assert_eq "$label $implementation rejected prerequisite" 'unsupported-scan-prerequisite job=check-other' \
              "$(sed -n 's/^lane-reach: cause=//p' "$log")" ;;
          dispatch-unmapped)
            assert_eq "$label $implementation diagnostic" unmapped-lanes-output \
              "$(sed -n 's/^lane-reach: cause=//p' "$log")" ;;
          dispatch-wrong-event)
            assert_eq "$label $implementation diagnostic" unsupported-lanes-emitter \
              "$(sed -n 's/^lane-reach: cause=//p' "$log")" ;;
          dispatch-unresolved|dispatch-opaque-host)
            runner=bin/check
            if [ "$label" = dispatch-opaque-host ]; then runner=bin/check-opaque; fi
            assert_eq "$label $implementation diagnostic" \
              "job=check-lane-host cause=unresolved-lane-dispatch command=$runner --lane check-lane-host" \
              "$(sed -n 's/^lane-reach: \(job=check-lane-host cause=unresolved-lane-dispatch command=.*\) reason=.*/\1/p' "$log")" ;;
          dispatch-opaque-prefix)
            assert_eq "$label $implementation conditional step diagnostic" \
              'job=check-scans cause=opaque-step command=bin/check --lane check-scans' \
              "$(sed -n 's/^lane-reach: \(job=check-scans cause=opaque-step.*\)/\1/p' "$log")"
            assert_eq "$label $implementation unsupported setup diagnostic" \
              'job=check-lane-host cause=computed-command command=bin/check --lane check-lane-host' \
              "$(sed -n 's/^lane-reach: \(job=check-lane-host cause=computed-command.*\)/\1/p' "$log")" ;;
        esac
      done ;;
  esac
  if [ "$label" = vitest-disabled-sibling ]; then
    # Package ownership selects the reader; the unowned-marker fallback
    # would keep the lane as unread instead.
    for log in action-log local-log; do
      assert_eq "$label $log web evidence" hit \
        "$(sed -n 's/^lane: name=web verdict=true .* evidence=\([a-z]*\)$/\1/p' "$SANDBOX/$log")"
    done
  fi
  if [ "$label" = queue-prerequisite ]; then
    assert_eq "$label has queue proof" queue_only=true "$(sed -n '/^queue_only=/p' "$SANDBOX/action")"
  fi
  if [ -n "$expected_gate" ]; then
    assert_eq "$label render class" "change_class=render" "$(sed -n '/^change_class=/p' "$SANDBOX/action")"
    assert_eq "$label action global gate" "$expected_gate" \
      "$(sed -n '/^lanes=/s/^lanes=//p; /^lanes_cause=/s/^lanes_cause=//p' "$SANDBOX/action" | paste -sd, -)"
    assert_eq "$label CLI global gate" "$expected_gate" \
      "$(sed -n '/^lanes=/s/^lanes=//p; /^lanes_cause=/s/^lanes_cause=//p' "$SANDBOX/local" | paste -sd, -)"
  fi
done <<'ROWS'
source|tools/input.sh|true||false|false
removed-source|tools/input.sh|true||false|false
shared-gate|tools/peer.sh|true||false|false
shell-workdir|tools/other/context.sh|true||false|false
shell-symlink|other/input.txt|true||false|false
deleted-workdir|check-cwd/only.txt|true||false|false
shell-parent-hop|tools/cache/only.txt|true||false|false
agent-pair|.codex/agents/auditor.toml|true||false|false
command-pair|.claude/commands/audit.md.disabled|true||false|false
shell-unresolved|shared.mjs|true|true|true|true
cargo-path-dependency|cargo/leaf/src/lib.rs|false|true|false|false
cargo-external-child|cargo/spare/src/child.rs|false|true|false|false
cargo-linked-child|cargo/spare/src/input.txt|false|true|false|false
cargo-parent-hop|cargo/spare/cache/only.txt|false|true|false|false
cargo-passed-dependency|cargo/bridge/src/lib.rs|true|true|true|true
cargo-unread|cargo/spare/src/lib.rs|false|false|false|false
vitest-import|web/café.mjs|false||true|false
vitest-package-sibling|.codex/skills/math/sibling.mjs|||true||merge_group|true,derived-reach
vitest-copilot-sibling|.github/skills/math/sibling.mjs|||true||merge_group|true,derived-reach
vitest-disabled-sibling|.github/skills/math/sibling.mjs|||true|
vitest-unowned-disabled|.github/skills/math/sibling.mjs|||true|
vitest-unread|web/spare-é.mjs|false||false|false
cargo-unresolved-vitest-unread|web/spare-é.mjs|false|true|false|false
vitest-external|shared.mjs|true||true|true
queue-prerequisite|shared.mjs|true||true|true|pull_request
shared-runtime|shared.mjs|true||true|true
runtime-only|runtime-only.mjs|||true|
computed-import|web/shared.mjs-runtime.mjs|||true|
vitest-inherited|tsconfig.json|true|true|true|true
vitest-unresolved-import|tools/input.sh|true|true|true|true
installed|.codex/skills/math/SKILL.md|true||false|true|merge_group|true,derived-reach
installed-push|.codex/skills/math/SKILL.md|true||false|true|push|true,derived-reach
push-unresolved|tsconfig.json|true|true|true|true|push
queued-render-push|.codex/skills/math/SKILL.md|false|false|false|false|push|false,queue-only
feature-render-push|.codex/skills/math/SKILL.md|false||||push|false,render
aggregate-render|.codex/skills/math/SKILL.md|false||||merge_group|false,render
indexed-render|.codex/skills/math/SKILL.md|||||merge_group|true,lane-reach-unreadable
aliased-render|.codex/skills/math/SKILL.md|||||merge_group|true,lane-reach-unreadable
unplaced-addition|unplaced.txt|true|true|true|true
reasoned-exception|external.settings|true|true|true|true
shared-root-config|package.json|true||true|true
checkout-attributes|.gitattributes|true|true|true|true
nested-attributes|tools/.gitattributes|true|true|true|true
dispatch-helper|.agents/skills/math/scripts/lib/md-refs.awk|||||||true|true|true|derived-reach
dispatch-host-source|bin/markdown.sh|||||||false|true|false|derived-reach
dispatch-unrelated|bin/other.txt|||||||false|false|true|derived-reach
dispatch-unmapped|bin/other.txt||||||||||lane-reach-unreadable
dispatch-unresolved|bin/other.txt|||||||true|true|true|derived-reach
dispatch-scan-prerequisite|bin/markdown.sh|||||||false|true||derived-reach
dispatch-scan-readme|README.md||||||||||trivial|false
dispatch-scan-gated|bin/markdown.sh||||||||||lane-reach-unreadable
dispatch-opaque-prefix|bin/other.txt|||||||true|true|true|derived-reach
dispatch-opaque-host|bin/unplaced.txt|||||||false|true|false|derived-reach
dispatch-wrong-event|bin/other.txt||||||||||lane-reach-unreadable
ROWS
require_rows "derived lane reach" "$rows"
report "derived lane reach"
