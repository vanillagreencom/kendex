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
# The link refuses the shell job; a claim would select the lane in its place.
git -C "$repo" rm -q -- .github/ci-lanes.conf
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
edit_file() { # FILE OLD NEW...: replace the first OLD of each pair, which must be present
  python3 - "$@" <<'PY'
from pathlib import Path
import sys
path, *pairs = sys.argv[1:]
path = Path(path)
source = path.read_text()
for old, new in zip(pairs[::2], pairs[1::2]):
    old, new = old.replace("\\n", "\n"), new.replace("\\n", "\n")
    assert old in source, old
    source = source.replace(old, new, 1)
path.write_text(source)
PY
}
edit_workflow() { edit_file "$repo/.github/workflows/ci.yml" "$@"; }
git -C "$repo" checkout -qb fixture-workflow-env "$static_base"
# A consumer ci.yml shape: literal workflow env that every job inherits.
edit_workflow '\njobs:\n' \
  '\nenv:\n  CARGO_TERM_COLOR: always\n  RUSTFLAGS: -D warnings\n  CI_CONFIG: ci/settings.toml\n  BASH_ENV: ./tools/env.sh\njobs:\n'
printf 'source ./tools/env-lib.sh\n' >"$repo/tools/env.sh"
# Only BASH_ENV is sourced: this file is no shell the reader can follow.
mkdir -p "$repo/ci"
printf '[ci]\nmode = "strict"\n' >"$repo/ci/settings.toml"
printf 'true\n' >"$repo/tools/env-lib.sh"
printf 'setting\n' >"$repo/orphan.settings"
printf '%s\n' 'orphan orphan.settings # reason: a job in another workflow reads the setting' \
  >>"$repo/.github/ci-lanes.conf"
git -C "$repo" add -A
git -C "$repo" commit -qm 'a literal workflow env and a declared lane that gates no job'
workflow_env_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-workflow-env-step "$workflow_env_base"
edit_workflow '      - run: test -f ./README.md\n' \
  "      - run: test -f ./README.md\n      - if: needs.changes.outputs.lane_orphan != 'false'\n        run: cat ./orphan.settings\n"
git -C "$repo" commit -qam 'a step in an ungated job reads the ungated lane'
git -C "$repo" checkout -qb fixture-workflow-env-unreadable "$workflow_env_base"
# The dispatch would otherwise name the job's own command in the diagnostic.
edit_workflow '        run: bash ./tools/check.sh\n' \
  '        run: bash ./tools/check.sh\n      - run: bin/check --lane shell\n'
printf 'export PATH="$PWD/bin:$PATH"\n' >"$repo/tools/env.sh"
git -C "$repo" commit -qam 'a BASH_ENV script the shell reader cannot follow'
# Each workflow shape the reader refuses, as branch fixture-LABEL.
while IFS='|' read -r refusal old new; do
  git -C "$repo" checkout -qb "fixture-$refusal" "$workflow_env_base"
  edit_workflow "$old" "$new"
  git -C "$repo" commit -qam "$refusal"
done <<'ROWS'
workflow-env-expression|  RUSTFLAGS: -D warnings\n|  RUSTFLAGS: ${{ vars.RUSTFLAGS }}\n
workflow-env-absolute|  CI_CONFIG: ci/settings.toml\n|  CI_CONFIG: /home/runner/work/R/R/ci/settings.toml\n
workflow-env-bash-env-absolute|  BASH_ENV: ./tools/env.sh\n|  BASH_ENV: /home/runner/work/R/R/tools/env.sh\n
workflow-env-bash-env-blank|  BASH_ENV: ./tools/env.sh\n|  BASH_ENV: ./tools/env ci.sh\n
workflow-env-option|  RUSTFLAGS: -D warnings\n|  RUSTFLAGS: -C link-arg=-Tlink.x\n
workflow-defaults|\nenv:\n|\ndefaults:\n  run:\n    working-directory: tools\nenv:\n
ROWS
# An env value naming a file a tool loads as code, which reads a sibling.
git -C "$repo" checkout -qb fixture-workflow-env-preload "$workflow_env_base"
edit_workflow '  CI_CONFIG: ci/settings.toml\n' \
  '  CI_CONFIG: ci/settings.toml\n  NODE_OPTIONS: --require ./tools/setup.cjs\n'
printf "require('./setup-lib.cjs')\n" >"$repo/tools/setup.cjs"
printf 'module.exports = 42\n' >"$repo/tools/setup-lib.cjs"
git -C "$repo" add -A
git -C "$repo" commit -qm 'a workflow env preload requires a sibling module'
git -C "$repo" checkout -qb fixture-workflow-env-wrapper "$workflow_env_base"
edit_workflow '  CI_CONFIG: ci/settings.toml\n' '  CI_CONFIG: ci/settings.toml\n  RUSTC_WRAPPER: ./tools/wrap.sh\n'
printf '#!/usr/bin/env bash\nsource ./tools/wrap-lib.sh\n' >"$repo/tools/wrap.sh"
chmod +x "$repo/tools/wrap.sh"
printf 'true\n' >"$repo/tools/wrap-lib.sh"
git -C "$repo" add -A
git -C "$repo" commit -qm 'a workflow env wrapper sources a helper'
# HTIO-57's ci.yml gates: each lane also runs only in the merge queue. The
# unguarded copy drops the classifier-failure fallback.
for shape in event-gate event-gate-unguarded; do
  git -C "$repo" checkout -qb "fixture-$shape" "$static_base"
  python3 - "$repo/.github/workflows/ci.yml" "$shape" <<'PY'
from pathlib import Path
import sys
path, shape = Path(sys.argv[1]), sys.argv[2]
old = "${{ !cancelled() && (needs.changes.result != 'success' || ("
new = "${{ !cancelled() && github.event_name == 'merge_group' && (" + (
    "(" if shape == "event-gate-unguarded" else "needs.changes.result != 'success' || (")
source = path.read_text()
assert old in source
path.write_text(source.replace(old, new))
PY
  git -C "$repo" commit -qam "$shape"
done
# A consumer whose Rust and Vitest jobs the reader refuses keeps a reasoned
# claim for each, beside a shell lane it proves. The Vitest job reads a file
# before the step the reader refuses.
git -C "$repo" checkout -qb fixture-refused-claims "$opted_base"
edit_workflow '      - working-directory: cargo\n' \
  '      - uses: dtolnay/rust-toolchain@stable\n      - working-directory: cargo\n' \
  '      - working-directory: web\n' \
  '      - run: cat ./ops/notes.txt\n      - working-directory: web\n        run: npm ci\n      - working-directory: web\n'
printf '%s\n' 'cargo cargo/* # reason: the toolchain action picks the compiler' \
  'web web/* # reason: npm ci installs what the suite loads' >>"$repo/.github/ci-lanes.conf"
mkdir -p "$repo/ops"
printf 'notes\n' >"$repo/ops/notes.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm 'refused Rust and Vitest jobs with reasoned claims'
refused_claims_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-refused-shared "$refused_claims_base"
# Both refused lanes claim one settings file, and the Rust lane also claims a
# file the proved shell lane reads.
printf '%s\n' 'cargo context.sh ops/toolchain.env # reason: the toolchain action reads the shared settings' \
  'web ops/toolchain.env # reason: npm ci reads the toolchain settings' >>"$repo/.github/ci-lanes.conf"
printf 'toolchain\n' >"$repo/ops/toolchain.env"
git -C "$repo" add -A
git -C "$repo" commit -qm 'refused lanes claim a shared settings file and a shell input'
refused_shared_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-refused-unclaimed "$refused_claims_base"
# The refused Vitest job reads nothing before its refusal, so only the
# missing claim can select it.
edit_workflow '      - run: cat ./ops/notes.txt\n' ''
edit_file "$repo/.github/ci-lanes.conf" 'web web/* # reason: npm ci installs what the suite loads\n' ''
git -C "$repo" commit -qam 'the refused Vitest job has no claim'
refused_unclaimed_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-checkout-path "$refused_claims_base"
# The CI template's layout: the job runs in the directory its checkout creates.
edit_workflow '      - uses: dtolnay/rust-toolchain@stable\n      - working-directory: cargo\n' \
  '      - uses: actions/checkout@v7\n        with:\n          path: subject\n      - working-directory: subject\n'
git -C "$repo" commit -qam 'a refused job runs in the directory its checkout creates'
checkout_path_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-refused-executable "$refused_claims_base"
# The claimed shell job runs a script whose interpreter the reader refuses.
edit_workflow '        run: bash ../shared.sh\n' '        run: bash ../shared.sh\n      - run: ./tools/run.py\n'
printf '#!/usr/bin/env python3\nprint("run")\n' >"$repo/tools/run.py"
chmod +x "$repo/tools/run.py"
git -C "$repo" add -A
git -C "$repo" commit -qm 'a claimed shell job runs a Python script'
refused_executable_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-linked-workdir "$refused_claims_base"
# The claimed Cargo job runs in its crates through a tracked link.
ln -s cargo "$repo/crates"
edit_workflow '      - working-directory: cargo\n' '      - working-directory: crates\n'
edit_file "$repo/.github/ci-lanes.conf" 'cargo cargo/* ' 'cargo rust-toolchain.toml '
git -C "$repo" add -A
git -C "$repo" commit -qm 'a claimed Cargo job runs in a linked directory'
linked_workdir_base="$(git -C "$repo" rev-parse HEAD)"
# The Cargo and Vitest readers each read their job, then a shape refusal
# follows: the toolchain action, and an imported module that reads the
# environment. The shell job tests for a file a change can add to a package
# tree Cargo scans.
git -C "$repo" checkout -qb fixture-refused-scope "$opted_base"
edit_workflow '      - working-directory: cargo\n' \
  '      - uses: dtolnay/rust-toolchain@stable\n      - working-directory: cargo\n'
printf '%s\n' 'export const shared = process.env.SHARED ? 0 : 42' >"$repo/shared.mjs"
printf '%s\n' 'test -e ./cargo/primary/notes.txt' >>"$repo/tools/check.sh"
printf '{"lockfileVersion":3}\n' >"$repo/web/package-lock.json"
printf '%s\n' 'cargo rust-toolchain.toml # reason: the toolchain action picks the compiler' \
  'web web/fixtures/* # reason: the suite reads its fixtures at runtime' >>"$repo/.github/ci-lanes.conf"
git -C "$repo" add -A
git -C "$repo" commit -qm 'claimed Cargo and Vitest jobs refused after their readers ran'
refused_scope_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-refused-config "$refused_scope_base"
# Vite reads a TypeScript config under the root, which the Vitest reader
# refuses before its walk.
printf '{}\n' >"$repo/web/tsconfig.json"
git -C "$repo" add -A
git -C "$repo" commit -qm 'the refused Vitest root holds a TypeScript config'
refused_config_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-refused-import-package "$refused_scope_base"
# The Vitest reader resolves a TypeScript module outside its root, then
# refuses the next import in the same file before the walk reaches that module.
mkdir -p "$repo/lib"
printf '%s\n' '{"type":"module"}' >"$repo/lib/package.json"
printf '%s\n' 'export const lib: number = 42' >"$repo/lib/lib.ts"
cat >"$repo/web/check.test.mjs" <<'JS'
import { expect, test } from 'vitest'
import { lib } from '../lib/lib.ts'
import { other } from 'other'
test('module', () => expect(lib + other).toBe(84))
JS
git -C "$repo" add -A
git -C "$repo" commit -qm 'the refused Vitest job imports a module beside its own package file'
refused_import_package_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-refused-runner "$refused_scope_base"
# The claimed shell job dispatches a lane through a runner whose interpreter
# the reader refuses.
edit_workflow '        run: bash ../shared.sh\n' '        run: bash ../shared.sh\n      - run: bin/run --lane check\n'
mkdir -p "$repo/bin"
printf '#!/usr/bin/env python3\nprint("check")\n' >"$repo/bin/run"
chmod +x "$repo/bin/run"
git -C "$repo" add -A
git -C "$repo" commit -qm 'a claimed shell job runs a Python lane runner'
refused_runner_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-cargo-registry "$opted_base"
printf 'itoa = "1"\n' >>"$repo/cargo/bridge/Cargo.toml"
git -C "$repo" commit -qam 'a scanned package has a registry dependency'
cargo_registry_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-cargo-suite "$opted_base"
# An integration suite outside Cargo's target directories, which a tests link
# can expose.
mkdir -p "$repo/cargo/primary/suite"
printf '#[test]\nfn linked() {}\n' >"$repo/cargo/primary/suite/linked.rs"
git -C "$repo" add -A
git -C "$repo" commit -qm 'a package holds a suite outside its target directories'
cargo_suite_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-vitest-root-config "$static_base"
# Vitest run from web/ loads this ancestor config, which widens discovery to
# the repository.
printf '%s\n' "export default { test: { dir: '..', include: ['**/*.test.mjs'] } }" \
  >"$repo/vitest.config.mjs"
git -C "$repo" add -A
git -C "$repo" commit -qm 'an ancestor Vitest config widens discovery past the root'
vitest_root_config_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-vitest-refused-import "$static_base"
# The Vitest reader refuses an import it has resolved, and no shell lane reads it.
printf '%s\n' 'cat ./tools/outer.sh' 'source ./tools/outer.sh' >"$repo/tools/check.sh"
printf '%s\n' 'export const shared = process.env.SHARED ? 0 : 42' >"$repo/shared.mjs"
printf '%s\n' 'web web/fixtures/* # reason: the suite reads its fixtures at runtime' >>"$repo/.github/ci-lanes.conf"
git -C "$repo" commit -qam 'a claimed Vitest suite imports a module that reads the environment'
vitest_refused_import_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-claimed-cargo "$opted_base"
printf '%s\n' 'cargo cargo/* # reason: the toolchain file picks the compiler' >>"$repo/.github/ci-lanes.conf"
git -C "$repo" commit -qam 'a Cargo lane the reader can read keeps a reasoned claim'
claimed_cargo_base="$(git -C "$repo" rev-parse HEAD)"
# The shell lane claims one changed path while Cargo's reader leaves another
# changed path unresolved, so the claim must not reach the unresolved one.
git -C "$repo" checkout -qb fixture-claim-beside-unread "$opted_base"
printf '%s\n' 'shell cargo/spare/notes.txt # reason: the external runner reads the notes' >>"$repo/.github/ci-lanes.conf"
printf 'notes\n' >"$repo/cargo/spare/notes.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm 'a shell claim beside a Cargo read the reader leaves unresolved'
claim_beside_unread_base="$(git -C "$repo" rev-parse HEAD)"
# A claimed Vitest lane whose read the change itself leaves unproved: a
# changed package path beside an import no package owns, or a changed name
# git quotes in the private index.
git -C "$repo" checkout -qb fixture-vitest-change-caused "$static_base"
printf '%s\n' 'web web/fixtures/* # reason: the suite reads its fixtures at runtime' >>"$repo/.github/ci-lanes.conf"
mkdir -p "$repo/.agents/skills/loose"
printf '%s\n' 'export const helper = 42' >"$repo/.agents/skills/loose/helper.mjs"
printf '%s\n' 'export const slash = 42' >"$repo/web/back\\slash.mjs"
cat >"$repo/web/check.test.mjs" <<'JS'
import { expect, test } from 'vitest'
import { helper } from '../.agents/skills/loose/helper.mjs'
test('unowned package module', () => expect(helper).toBe(42))
JS
git -C "$repo" add -A
git -C "$repo" commit -qm 'a claimed Vitest lane imports a module no package owns'
vitest_change_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-cargo-child "$opted_base"
cat >"$repo/cargo/primary/src/lib.rs" <<'RS'
// let path = "/etc/hosts";
#[path = "../../spare/src/mod.rs"]
mod external;

#[test]
fn checks_child() {
    assert_eq!(external::child::value(), 42);
}
RS
printf 'pub mod child;\n' >"$repo/cargo/spare/src/mod.rs"
printf 'pub fn value() -> u8 { 42 }\n' >"$repo/cargo/spare/src/child.rs"
# The Cargo reader's literal-path scan meets the commented path first, which
# the shared resolver refuses as a shape cause. The claim names no child of
# the out-of-package module, so only the reader turning that refusal into one
# that leaves the job unread keeps the lane.
printf '%s\n' 'cargo rust-toolchain.toml # reason: the toolchain file picks the compiler' \
  >>"$repo/.github/ci-lanes.conf"
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
# The shape of fleet's bin/check at fleet f016d9f8: marks beside fixture names
# in the lane entries, lanes with no step, a step with more than literal
# commands on a lane no job runs, and each lane's fixture files found under
# bin/fixtures/LANE/ after its steps.
git -C "$repo" checkout -qb fixture-fleet-dispatch "$dispatch_base"
write_fleet_runner() { # TMUX_GUARD_CLOSE
  cat <<'SH'
#!/bin/bash
set -euo pipefail
lane_table=(
  "check-scans:
    scan
    @always
  "
  "check-lane-host:
    lane-host-home-guard
    lane-host-accounts.sh +isolated
  "
  "check-other:
    +host
  "
  "check-tmux:
    tmux-guard
  "
)
step_scan() {
  bash ./bin/check-scans.sh
}
step_lane_host_home_guard() {
  bash ./bin/check-lane-host.sh
}
step_tmux_guard() {
  local entry word
  for entry in "${lane_table[@]}"; do
    for word in ${entry#*:}; do
      bash "./bin/${word%.sh}.sh"
SH
  printf '%s\n' "$1"
  cat <<'SH'
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
      @*|+host|+isolated|*.sh|*.py) ;;
      *) "step_${member//-/_}" ;;
    esac
  done
  [ -d "bin/fixtures/$name" ] || continue
  fixtures=$(find "bin/fixtures/$name" -mindepth 1 -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' \) | LC_ALL=C sort)
  while IFS= read -r fixture <&3; do
    case $fixture in
      *.sh) bash "$fixture" ;;
      *.py) python3 "$fixture" ;;
    esac
  done 3<<<"$fixtures"
done
SH
}
write_fleet_runner '    done
  done' >"$repo/bin/check"
mkdir -p "$repo/bin/fixtures/check-lane-host" "$repo/bin/fixtures/check-other"
printf 'cat ./bin/host.txt\n' >"$repo/bin/fixtures/check-lane-host/lane-host-accounts.sh"
printf 'host input\n' >"$repo/bin/host.txt"
printf 'cat ./bin/other.txt\n' >"$repo/bin/fixtures/check-other/client.sh"
git -C "$repo" add -A
git -C "$repo" commit -qm 'a runner runs each lane fixture its directory holds'
dispatch_fleet_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-fleet-python "$dispatch_fleet_base"
printf 'print("client")\n' >"$repo/bin/fixtures/check-other/client.py"
git -C "$repo" add -A
git -C "$repo" commit -qm 'a lane runs a Python fixture'
dispatch_fleet_python_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb fixture-fleet-brace "$dispatch_fleet_base"
# The step's function ends on its last command's line, after a literal "{"
# argument, so the cat runs at the top level of every lane.
write_fleet_runner '    done
  done; echo {; }
cat ./bin/top.txt
step_after() {
  true' >"$repo/bin/check"
printf 'top input\n' >"$repo/bin/top.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm 'a step function closes before its brace line'
dispatch_fleet_brace_base="$(git -C "$repo" rev-parse HEAD)"
# A ")#" does not start a comment, so the "}" after it ends the step, and
# the "{" a later ")#" hides opens a group that closes the function's line.
git -C "$repo" checkout -qb fixture-fleet-brace-comment "$dispatch_fleet_brace_base"
write_fleet_runner '    done
  done; echo $(echo a)#b; }
cat ./bin/top.txt
: $(true)#; {
  true' >"$repo/bin/check"
git -C "$repo" commit -qam 'a step function closes after a comment-like word'
dispatch_fleet_brace_comment_base="$(git -C "$repo" rev-parse HEAD)"
# The backslash-newline joins "<<", and the quote in the heredoc's data
# pairs with the one in the later comment.
git -C "$repo" checkout -qb fixture-fleet-brace-heredoc "$dispatch_fleet_brace_base"
write_fleet_runner "    done
  done
  cat <\\
<EOF
'
EOF
  true; }
cat ./bin/top.txt
step_after() {
  true # it's" >"$repo/bin/check"
git -C "$repo" commit -qam 'a step function closes after a continued heredoc'
dispatch_fleet_brace_heredoc_base="$(git -C "$repo" rev-parse HEAD)"
# find lists a fixture name holding a newline as two lines, so the runner
# runs ./run.sh, a file no fixture names.
git -C "$repo" checkout -qb fixture-fleet-newline "$dispatch_fleet_base"
printf 'true\n' >"$repo/bin/fixtures/check-other/x"$'\n'"run.sh"
printf 'echo split\n' >"$repo/run.sh"
git -C "$repo" add -A
git -C "$repo" commit -qm 'a fixture name holds a newline'
dispatch_fleet_newline_base="$(git -C "$repo" rev-parse HEAD)"
# The host lane also reads a path on the shipped queue list, whose
# queue_only answer reads inputs=run, and claims another such path.
git -C "$repo" checkout -qb fixture-fleet-queue "$dispatch_fleet_base"
printf '[env]\nHARNESS_CI_PER_PUSH_REASON = "per-lane queue marks"\n' >"$repo/kendex.settings.toml"
printf '%s\n' 'check-lane-host:queue bin/fixtures/check-lane-host/* skills/review-gate/standard.json # reason: the queue proves the host lane' \
  >"$repo/.github/ci-lanes.conf"
mkdir -p "$repo/skills/review-gate/scripts"
printf 'queue input\n' >"$repo/skills/review-gate/scripts/x.txt"
printf '{}\n' >"$repo/skills/review-gate/standard.json"
printf 'cat ./skills/review-gate/scripts/x.txt\n' >>"$repo/bin/fixtures/check-lane-host/lane-host-accounts.sh"
mkdir -p "$repo/.agents/skills/harness-ci/scripts/lib"
cp "$HARNESS_CI_PACKAGE/scripts/lib/ci-lanes.sh" "$repo/.agents/skills/harness-ci/scripts/lib/ci-lanes.sh"
git -C "$repo" add -A
git -C "$repo" commit -qm 'the host lane takes the merge queue'
dispatch_fleet_queue_base="$(git -C "$repo" rev-parse HEAD)"
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
mkdir -p "$SANDBOX/failing-cargo"
printf '#!/usr/bin/env bash\nexit 1\n' >"$SANDBOX/failing-cargo/cargo"
chmod +x "$SANDBOX/failing-cargo/cargo"

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
while IFS='|' read -r label path shell cargo web installed event expected_gate scans host other dispatch_cause dispatch_lanes ungated; do
  [ -z "${LANE_REACH_CASE:-}" ] || [ "$label" = "$LANE_REACH_CASE" ] || continue
  rows=$((rows + 1))
  base="$opted_base"
  push_ref=refs/heads/main
  case "$label" in
    source|removed-source|shared-gate|shell-workdir|vitest-import|vitest-unread|vitest-external|installed|installed-push|shared-root-config|vitest-ancestor-config)
      base="$static_base" ;;
    vitest-package-sibling) base="$vitest_package_base" ;;
    vitest-copilot-sibling) base="$vitest_copilot_base" ;;
    vitest-disabled-sibling) base="$vitest_disabled_base" ;;
    vitest-unowned-disabled) base="$vitest_unowned_base" ;;
    agent-pair) base="$agent_pair_base" ;;
    command-pair) base="$command_pair_base" ;;
    shell-parent-hop) base="$parent_hop_base" ;;
    workflow-env|workflow-env-sourced|workflow-env-config|workflow-env-claimed) base="$workflow_env_base" ;;
    workflow-env-step-claimed) base="$(git -C "$repo" rev-parse fixture-workflow-env-step)" ;;
    workflow-env-*|workflow-defaults|event-gate*) base="$(git -C "$repo" rev-parse "fixture-$label")" ;;
    shared-runtime) base="$shared_runtime_base" ;;
    shell-symlink) base="$symlink_base" ;;
    refused-claim-shared|refused-claim-read) base="$refused_shared_base" ;;
    refused-claim-*|refused-proved-read|refused-ordinary-read) base="$refused_claims_base" ;;
    refused-unclaimed) base="$refused_unclaimed_base" ;;
    refused-shell-only|refused-vitest-package|refused-build-script|refused-added-target|refused-added-test)
      base="$refused_scope_base" ;;
    refused-vitest-config) base="$refused_config_base" ;;
    refused-import-package|refused-import-tsconfig) base="$refused_import_package_base" ;;
    refused-runner) base="$refused_runner_base" ;;
    cargo-registry-dependency) base="$cargo_registry_base" ;;
    cargo-tests-link) base="$cargo_suite_base" ;;
    vitest-root-config) base="$vitest_root_config_base" ;;
    refused-executable) base="$refused_executable_base" ;;
    linked-workdir-*) base="$linked_workdir_base" ;;
    vitest-refused-import) base="$vitest_refused_import_base" ;;
    checkout-path|restored-workdir|symlink-workdir) base="$checkout_path_base" ;;
    cargo-tool-failure) base="$claimed_cargo_base" ;;
    claim-beside-unread) base="$claim_beside_unread_base" ;;
    vitest-owner-unresolved|vitest-changed-unread) base="$vitest_change_base" ;;
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
    dispatch-fleet-python) base="$dispatch_fleet_python_base" ;;
    dispatch-fleet-brace) base="$dispatch_fleet_brace_base" ;;
    dispatch-fleet-brace-comment) base="$dispatch_fleet_brace_comment_base" ;;
    dispatch-fleet-brace-heredoc) base="$dispatch_fleet_brace_heredoc_base" ;;
    dispatch-fleet-newline) base="$dispatch_fleet_newline_base" ;;
    dispatch-fleet-queue-*) base="$dispatch_fleet_queue_base" ;;
    dispatch-fleet-*) base="$dispatch_fleet_base" ;;
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
    restored-workdir) mkdir -p "$repo/${path%/*}"; printf 'restored\n' >"$repo/$path" ;;
    refused-added-target|cargo-added-target) mkdir -p "$repo/${path%/*}"; printf '\n' >"$repo/$path" ;;
    symlink-workdir) ln -s cargo "$repo/$path" ;;
    cargo-tests-link) ln -s suite "$repo/$path" ;;
    vitest-root-config) mkdir -p "$repo/${path%/*}"; printf '\n' >"$repo/$path" ;;
    linked-workdir-swap)
      git -C "$repo" rm -q -- "$path"; mkdir "$repo/$path"; printf 'restored\n' >"$repo/$path/restored.txt" ;;
    shared-root-config) printf '{"private":true}\n' >"$repo/$path" ;;
    vitest-inherited|push-unresolved)
      printf '{"compilerOptions":{"experimentalDecorators":false}}\n' >"$repo/$path" ;;
    # A row's PATH field can name several paths, split at blanks.
    *)
      read -ra row_paths <<<"$path"
      for one in "${row_paths[@]}"; do printf '\n' >>"$repo/$one"; done ;;
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
  vitest-root-config)
    assert_eq "$label actual Vitest lists the test outside its root" ../lib/new.test.mjs \
      "$(cd "$repo/web" && ./node_modules/.bin/vitest list --filesOnly --json |
        python3 -c 'import json, os, sys; print(*sorted(os.path.relpath(row["file"]) for row in json.load(sys.stdin)
          if "lib/" in row["file"]))')" ;;
  shell-symlink)
    assert_eq "$label follows the link before its parent component" physical \
      "$(cd "$repo" && bash ./tools/check.sh)" ;;
  deleted-workdir)
    base_status=0 head_status=0
    (cd "$trusted/check-cwd") 2>/dev/null || base_status=$?
    (cd "$repo/check-cwd") 2>/dev/null || head_status=$?
    assert_eq "$label can enter the base directory" 0 "$base_status"
    assert_eq "$label cannot enter the changed directory" 1 "$head_status" ;;
  symlink-workdir)
    head_status=0
    (cd "$repo/$path") 2>/dev/null || head_status=$?
    assert_eq "$label can enter the linked directory" 0 "$head_status" ;;
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
  dispatch-fleet-fixture)
    assert_eq "$label lane host runs its step, then its fixture" \
      "$(cat "$repo/$fixture_helper" "$repo/bin/host.txt")" "$(cd "$repo" && bin/check --lane check-lane-host)" ;;
  dispatch-fleet-brace*)
    assert_eq "$label lane other reads the top-level input at runtime" \
      "$(cat "$repo/bin/top.txt" "$repo/bin/other.txt")" "$(cd "$repo" && bin/check --lane check-other)" ;;
  dispatch-fleet-newline)
    assert_eq "$label lane other runs the split name's second line" \
      "$(cat "$repo/bin/other.txt")"$'\n'split "$(cd "$repo" && bin/check --lane check-other)" ;;
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
  tools="$SANDBOX/bin"
  # Cargo fails on this run, which says nothing of the job's shape.
  [ "$label" != cargo-tool-failure ] || tools="$SANDBOX/failing-cargo:$tools"
  head="$(git -C "$repo" rev-parse HEAD)"
  cli="$CHANGE_CLASS"
  case "$label" in
    dispatch-*) cli="${CHANGE_CLASS_UNDER_TEST:-$root/.agents/skills/harness-ci/scripts/change-class}" ;;
  esac
  printf '{"ref":"%s","before":"%s","after":"%s","forced":false,"repository":{"default_branch":"main"}}\n' \
    "$push_ref" "$base" "$head" >"$SANDBOX/event"
  PATH="$tools:$PATH" CLASSIFIER="$classifier" EVENT="$event" BASE="$base" HEAD="$head" \
    GITHUB_REPOSITORY=example/lane-reach GITHUB_JOB=changes GITHUB_REF="$push_ref" \
    GITHUB_WORKFLOW_REF="example/lane-reach/.github/workflows/ci.yml@$push_ref" GITHUB_EVENT_PATH="$SANDBOX/event" \
    QUEUE_ONLY_DEFAULT=true \
    REPO="$repo" LANES_FROM="$trusted" GITHUB_OUTPUT="$SANDBOX/action" "$action" \
    >"$SANDBOX/stdout" 2>"$SANDBOX/action-log" || { cat "$SANDBOX/action-log"; exit 1; }
  (
    unset GITHUB_REPOSITORY GITHUB_JOB GITHUB_WORKFLOW_REF
    PATH="$tools:$PATH" GITHUB_REF="$push_ref" GITHUB_EVENT_PATH="$SANDBOX/event" \
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
          dispatch-fleet-python|dispatch-fleet-brace*|dispatch-fleet-newline)
            case "$label" in
              dispatch-fleet-python) reason='runner-fixture-opaque fixture=bin/fixtures/check-other/client.py' ;;
              dispatch-fleet-brace*) reason='runner-function-boundary-unproved function=step_tmux_guard' ;;
              *) reason='runner-fixture-name-newline folder=bin/fixtures/check-other' ;;
            esac
            assert_eq "$label $implementation diagnostic" \
              "cause=unresolved-lane-dispatch command=bin/check --lane check-other reason=$reason" \
              "$(sed -n 's/^lane-reach: job=check-other //p' "$log")" ;;
          dispatch-fleet-queue-*)
            cause=queue-deferred
            [ "$label" != dispatch-fleet-queue-unproved ] || cause=queue-cause-unproved
            assert_eq "$label $implementation host cause" "$cause" \
              "$(sed -n 's/^lane: name=check-lane-host verdict=[a-z]* cause=\([a-z-]*\) .*/\1/p' "$log")" ;;
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
  if [ -n "$ungated" ]; then
    for implementation in action local; do
      assert_eq "$label $implementation ungated lane" "$ungated" \
        "$(verdict orphan "$SANDBOX/$implementation")"
    done
  fi
  refusal=""
  case "$label" in
    workflow-env-expression|workflow-env-absolute|workflow-env-option) refusal=opaque-workflow-env ;;
    workflow-env-bash-env-absolute)
      refusal='opaque-workflow-env key=BASH_ENV path=/home/runner/work/R/R/tools/env.sh' ;;
    workflow-env-bash-env-blank) refusal="opaque-workflow-env key=BASH_ENV path='./tools/env ci.sh'" ;;
    workflow-defaults) refusal=opaque-workflow-defaults ;;
    event-gate-unguarded) refusal=unsupported-lane-gate ;;
  esac
  if [ -n "$refusal" ]; then
    for implementation in action local; do
      assert_eq "$label $implementation diagnostic" "$refusal" \
        "$(sed -n 's/^lane-reach: cause=//p' "$SANDBOX/$implementation-log")"
    done
  fi
  refused_jobs=""
  case "$label" in
    cargo-external-child) refused_jobs='job=cargo cause=computed-path' ;;
    cargo-registry-dependency) refused_jobs='job=cargo cause=cargo-external-dependency' ;;
    refused-shell-only|refused-vitest-package|refused-build-script|refused-added-target|refused-added-test)
      refused_jobs='job=cargo cause=opaque-action,job=web cause=vitest-opaque-source' ;;
    refused-vitest-config) refused_jobs='job=cargo cause=opaque-action,job=web cause=vitest-opaque-config' ;;
    refused-import-package|refused-import-tsconfig)
      refused_jobs='job=cargo cause=opaque-action,job=web cause=vitest-opaque-import' ;;
    refused-runner)
      refused_jobs='job=cargo cause=opaque-action,job=shell cause=unresolved-lane-dispatch,job=web cause=vitest-opaque-source' ;;
    refused-executable)
      refused_jobs='job=cargo cause=opaque-action,job=shell cause=unsupported-script-interpreter,job=web cause=opaque-shell-command' ;;
    refused-*) refused_jobs='job=cargo cause=opaque-action,job=web cause=opaque-shell-command' ;;
    checkout-path|restored-workdir|symlink-workdir|linked-workdir-swap)
      refused_jobs='job=cargo cause=working-directory-unproved,job=web cause=opaque-shell-command' ;;
    linked-workdir-target|linked-workdir-miss) refused_jobs='job=cargo cause=indirect-path,job=web cause=opaque-shell-command' ;;
    vitest-refused-import) refused_jobs='job=web cause=vitest-opaque-source' ;;
    vitest-root-config) refused_jobs='job=web cause=vitest-loaded-config' ;;
    cargo-tool-failure) refused_jobs='job=cargo cause=cargo-exit-1' ;;
    vitest-owner-unresolved) refused_jobs='job=web cause=vitest-import-owner-unresolved' ;;
    vitest-changed-unread) refused_jobs='job=web cause=vitest-changed-paths-unread' ;;
  esac
  if [ -n "$refused_jobs" ]; then
    # Each row holds only while the reader refuses these jobs for these causes.
    for implementation in action local; do
      assert_eq "$label $implementation refused jobs" "$refused_jobs" \
        "$(sed -n 's/^lane-reach: \(job=[a-z]* cause=[a-z0-9-]*\).*/\1/p' "$SANDBOX/$implementation-log" | sort | paste -sd, -)"
    done
  fi
  env_refusal=""
  case "$label" in
    workflow-env-unreadable) env_refusal='key=BASH_ENV path=tools/env.sh reason=computed-command' ;;
    workflow-env-preload) env_refusal='key=NODE_OPTIONS path=tools/setup.cjs reason=unsupported-script-interpreter' ;;
  esac
  if [ -n "$env_refusal" ]; then
    for implementation in action local; do
      assert_eq "$label $implementation diagnostic" "cause=opaque-workflow-env $env_refusal" \
        "$(sed -n 's/^lane-reach: job=shell //p' "$SANDBOX/$implementation-log")"
    done
  fi
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
workflow-env|tools/input.sh|true||false|false||||||||false
workflow-env-sourced|tools/env-lib.sh|true||false|true||||||||false
workflow-env-config|ci/settings.toml|true||false|true||||||||false
workflow-env-claimed|orphan.settings|false||false|false||||||||true
workflow-env-step|tools/input.sh|true||false|false||||||||false
workflow-env-step-claimed|orphan.settings|false||false|false||||||||true
workflow-env-unreadable|tools/input.sh|true||false|true||||||||false
workflow-env-preload|tools/setup-lib.cjs|true||false|true||||||||false
workflow-env-wrapper|tools/wrap-lib.sh|true||false|true||||||||false
workflow-env-expression|tools/input.sh||||
workflow-env-absolute|tools/input.sh||||
workflow-env-bash-env-absolute|tools/input.sh||||
workflow-env-bash-env-blank|tools/input.sh||||
workflow-env-option|tools/input.sh||||
workflow-defaults|tools/input.sh||||
event-gate|tools/input.sh|true||false|false
event-gate-unguarded|tools/input.sh||||
agent-pair|.codex/agents/auditor.toml|true||false|false
command-pair|.claude/commands/audit.md.disabled|true||false|false
shell-unresolved|shared.mjs|true|true|true|true
cargo-path-dependency|cargo/leaf/src/lib.rs|false|true|false|false
cargo-external-child|cargo/spare/src/child.rs|false|true|false|false
cargo-linked-child|cargo/spare/src/input.txt|false|true|false|false
cargo-parent-hop|cargo/spare/cache/only.txt|false|true|false|false
cargo-passed-dependency|cargo/bridge/src/lib.rs|true|true|false|false
cargo-unread|cargo/spare/src/lib.rs|false|false|false|false
cargo-registry-dependency|tools/input.sh|true|true|true|true
cargo-added-target|cargo/primary/tests/added.rs|false|true|false|false
cargo-tests-link|cargo/primary/tests|false|true|false|false
refused-claim-hit|cargo/spare/src/lib.rs|false|true|false|false
refused-claim-miss|tools/input.sh|true|false|false|false
refused-claim-shared|ops/toolchain.env|false|true|true|false
refused-claim-read|context.sh|true|true|false|false
refused-claim-pair|cargo/spare/src/lib.rs web/bridge.mjs|false|true|true|false
refused-claim-and-read|cargo/spare/src/lib.rs tools/input.sh|true|true|false|false
refused-unclaimed|ops/notes.txt|false|false|true|false
refused-proved-read|rust-toolchain.toml|false|true|false|false
refused-ordinary-read|ops/notes.txt|false|false|true|false
refused-executable|tools/run.py|true|false|false|false
refused-shell-only|cargo/primary/notes.txt|true|false|false|false
refused-vitest-package|web/package-lock.json|false|false|true|false
refused-build-script|cargo/primary/build.rs|false|true|false|false
refused-added-target|cargo/primary/tests/added.rs|false|true|false|false
refused-added-test|web/added.test.mjs|false|false|true|false
refused-vitest-config|web/added.test.mjs|false|false|true|false
refused-import-package|lib/package.json|false|false|true|false
refused-import-tsconfig|lib/tsconfig.json|false|false|true|false
refused-runner|bin/run|true|false|false|false
checkout-path|tools/input.sh|true|false|false|false
restored-workdir|subject/restored.txt|false|true|false|false
symlink-workdir|subject|false|true|false|false
linked-workdir-target|cargo/primary/src/lib.rs|false|true|false|false
linked-workdir-swap|crates|false|true|false|false
linked-workdir-miss|tools/input.sh|true|false|false|false
cargo-tool-failure|tools/input.sh|true|true|true|true
vitest-owner-unresolved|.codex/skills/math/SKILL.md|true||true|true|merge_group|true,derived-reach
vitest-changed-unread|web/back\slash.mjs|false||true|false
vitest-import|web/café.mjs|false||true|false
vitest-package-sibling|.codex/skills/math/sibling.mjs|||true||merge_group|true,derived-reach
vitest-copilot-sibling|.github/skills/math/sibling.mjs|||true||merge_group|true,derived-reach
vitest-disabled-sibling|.github/skills/math/sibling.mjs|||true|
vitest-unowned-disabled|.github/skills/math/sibling.mjs|||true|
vitest-unread|web/spare-é.mjs|false||false|false
vitest-ancestor-config|vite.config.mjs|false||true|false
vitest-root-config|lib/new.test.mjs|false||true|false
cargo-unresolved-vitest-unread|web/spare-é.mjs|false|true|false|false
claim-beside-unread|cargo/spare/notes.txt web/spare-é.mjs|true|true|false|false
vitest-external|shared.mjs|true||true|false
vitest-refused-import|shared.mjs|false||true|false
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
unplaced-addition|unplaced.txt|false|true|false|false
reasoned-exception|external.settings|true|true|true|true
shared-root-config|package.json|true||true|true
checkout-attributes|.gitattributes|true|true|true|true
nested-attributes|tools/.gitattributes|true|true|true|true
dispatch-helper|.agents/skills/math/scripts/lib/md-refs.awk|||||||true|true|false|derived-reach
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
dispatch-fleet-fixture|bin/host.txt|||||||false|true|false|derived-reach
dispatch-fleet-step|bin/markdown.sh|||||||false|true|false|derived-reach
dispatch-fleet-added|bin/fixtures/check-other/added.sh|||||||false|false|true|derived-reach
dispatch-fleet-python|bin/unplaced.txt|||||||false|false|true|derived-reach
dispatch-fleet-brace|bin/top.txt|||||||true|true|true|derived-reach
dispatch-fleet-brace-comment|bin/top.txt|||||||true|true|true|derived-reach
dispatch-fleet-brace-heredoc|bin/top.txt|||||||true|true|true|derived-reach
dispatch-fleet-newline|run.sh|||||||false|false|true|derived-reach
dispatch-fleet-queue-claimed|skills/review-gate/standard.json|||||pull_request||false|false|false|derived-reach
dispatch-fleet-queue-derived|bin/host.txt|||||pull_request||false|false|false|derived-reach
dispatch-fleet-queue-unproved|skills/review-gate/scripts/x.txt|||||pull_request||false|true|false|derived-reach
ROWS
require_rows "derived lane reach" "$rows"
report "derived lane reach"
