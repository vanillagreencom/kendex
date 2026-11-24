#!/usr/bin/env bash
# Inputs: harness-ci scripts, change-scope and the change-class action.
set -euo pipefail
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
on: [merge_group, push]
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
      no-cargo) [ "$id" != cargo ] || continue ;;
      web-only) [ "$id" = web ] || continue ;;
    esac
    lane="$id"
    needs=changes
    case "$id" in
      shell_share) lane=shell ;;
      installed) needs='[changes, shell]' ;;
    esac
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
    printf '%s\n' '{"version":1,"clean":true,"checked":2,"failed":0,"base_owned":[{"path":".codex/skills/math","owns":"tree"}],"rows":[{"kind":"skill","name":"math","state":"ok","positions":[{"path":".codex/skills/math","owns":"tree"}]},{"kind":"inventory","state":"ok","positions":[{"path":".kendex-generated.json","owns":"file"}]}]}'
    ;;
esac
VERIFY
chmod +x "$SANDBOX/bin/kendex"

verdict() { sed -n "/^lane_$1=/s/^lane_$1=//p" "$2"; }
while IFS='|' read -r label path shell cargo web installed event expected_gate; do
  base="$opted_base"
  push_ref=refs/heads/main
  case "$label" in
    source|removed-source|shared-gate|shell-workdir|vitest-import|vitest-unread|vitest-external|installed|installed-push|shared-root-config)
      base="$static_base" ;;
    shared-runtime) base="$shared_runtime_base" ;;
    runtime-only) base="$runtime_base" ;;
    computed-import) base="$computed_base" ;;
    aggregate-render) base="$aggregate_base" ;;
    indexed-render) base="$indexed_base" ;;
    aliased-render) base="$aliased_base" ;;
    shell-unresolved) base="$shell_base" ;;
    vitest-unresolved-import) base="$import_base" ;;
    vitest-inherited|push-unresolved) base="$config_base" ;;
    queued-render-push) base="$queue_base" ;;
    feature-render-push) push_ref=refs/heads/feature ;;
  esac
  event="${event:-merge_group}"
  git -C "$trusted" checkout -q --detach "$base"
  git -C "$repo" checkout -q -B row "$base"
  case "$label" in
    removed-source) git -C "$repo" rm -q -- "$path" ;;
    checkout-attributes|nested-attributes) printf '*.sh eol=crlf\n' >"$repo/$path" ;;
    vitest-import) printf 'export const value = 43\n' >"$repo/$path" ;;
    vitest-external|shared-runtime) printf 'export const shared = 43\n' >"$repo/$path" ;;
    runtime-only|computed-import) printf 'export const value = 43\n' >"$repo/$path" ;;
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
  esac
  : >"$SANDBOX/action"
  : >"$SANDBOX/local"
  head="$(git -C "$repo" rev-parse HEAD)"
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
      "$CHANGE_CLASS" --event "$event" --base "$base" --head "$head" --queue-only-default true \
      --repo "$repo" --lanes-from "$trusted" --output "$SANDBOX/local"
  ) \
    >"$SANDBOX/stdout" 2>"$SANDBOX/local-log" || { cat "$SANDBOX/local-log"; exit 1; }
  for lane in shell cargo web installed; do
    actual="$(verdict "$lane" "$SANDBOX/action")"
    if [ "$actual" != "${!lane}" ]; then cat "$SANDBOX/action-log" >&2; fi
    assert_eq "$label $lane" "${!lane}" "$actual"
    assert_eq "$label $lane local parity" "$actual" "$(verdict "$lane" "$SANDBOX/local")"
  done
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
shell-unresolved|shared.mjs|true|true|true|true
cargo-path-dependency|cargo/leaf/src/lib.rs|false|true|false|false
cargo-unread|cargo/spare/src/lib.rs|false|false|false|false
vitest-import|web/café.mjs|false||true|false
vitest-unread|web/spare-é.mjs|false||false|false
cargo-unresolved-vitest-unread|web/spare-é.mjs|false|true|false|false
vitest-external|shared.mjs|true||true|true
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
ROWS
report "derived lane reach"
