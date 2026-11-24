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
export GITHUB_REPOSITORY=example/lane-reach
export GITHUB_WORKFLOW_REF="$GITHUB_REPOSITORY/.github/workflows/ci.yml@refs/heads/main"
export GITHUB_JOB=changes
python3 -c 'import tomllib, yaml'

mkdir -p "$repo/.github/workflows" "$repo/tools" "$repo/web" "$repo/cargo" \
  "$repo/.agents/skills/math/scripts" "$repo/.codex/skills/math" "$SANDBOX/bin"
{
  cat <<'YAML'
name: CI
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
  done <<'ROWS'
shell|.|bash ./tools/check.sh
shell_share|.|bash ./tools/peer.sh
cargo|cargo|cargo test -p primary
web|web|./node_modules/.bin/vitest run
installed|.|bash ./.agents/skills/math/scripts/check.sh
ROWS
} >"$repo/.github/workflows/ci.yml"

printf '%s\n' 'source ./tools/outer.sh' >"$repo/tools/check.sh"
printf '%s\n' 'source ./tools/input.sh' >"$repo/tools/outer.sh"
printf '%s\n' 'true' >"$repo/tools/input.sh"
printf '%s\n' 'true' >"$repo/tools/peer.sh"
printf '%s\n' 'true' >"$repo/.agents/skills/math/scripts/check.sh"
printf '%s\n' 'installed' >"$repo/.codex/skills/math/SKILL.md"
cat >"$repo/.kendex-generated.json" <<'JSON'
[".agents/skills/math/scripts/check.sh",".codex/skills/math/SKILL.md"]
JSON
cat >"$repo/.kendex-lock.json" <<'JSON'
{"entries":{
  "skill:math:claude":{"enabled":true,"sourceRepo":"example/catalog","emitted":{"kind":"skill","name":"math","paths":[".agents/skills/math"]}},
  "skill:math:codex":{"enabled":true,"sourceRepo":"example/catalog","emitted":{"kind":"skill","name":"math","paths":[".agents/skills/math",".codex/skills/math"]}}
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
printf '%s\n' 'export { value } from "./input.mjs"' >"$repo/web/bridge.mjs"
printf '%s\n' 'export const value = 42' >"$repo/web/input.mjs"
printf '%s\n' 'export const spare = 42' >"$repo/web/spare.mjs"
cat >"$repo/web/check.test.mjs" <<'JS'
import { expect, test } from 'vitest'
import { value } from './bridge.mjs'
test('module', () => expect(value).toBe(42))
JS
printf '%s\n' 'shell external.settings # reason: the external runner reads the setting' \
  >"$repo/.github/ci-lanes.conf"

git -C "$repo" add -A
git -C "$repo" commit -qm baseline
base="$(git -C "$repo" rev-parse HEAD)"
git clone --quiet "$repo" "$trusted"
if [ -x "$root/ui/node_modules/.bin/vitest" ]; then
  modules="$root/ui/node_modules"
else
  # Resolve the real tool in the runner cache, outside all fixture checkouts.
  binary="$(npm exec --yes --package=vitest@4.1.11 -- which vitest)"
  modules="$(cd "$(dirname "$binary")/.." && pwd -P)"
fi
ln -s "$modules" "$trusted/web/node_modules"

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
while IFS='|' read -r label path shell cargo web installed; do
  git -C "$repo" checkout -q -B row "$base"
  case "$label" in
    removed-source) git -C "$repo" rm -q -- "$path" ;;
    *) printf '\n' >>"$repo/$path" ;;
  esac
  git -C "$repo" add -A
  git -C "$repo" commit -qm "$label"
  : >"$SANDBOX/action"
  : >"$SANDBOX/local"
  PATH="$SANDBOX/bin:$PATH" CLASSIFIER="$classifier" EVENT=merge_group BASE="$base" HEAD=HEAD \
    REPO="$repo" LANES_FROM="$trusted" GITHUB_OUTPUT="$SANDBOX/action" "$action" \
    >"$SANDBOX/stdout" 2>"$SANDBOX/action-log" || { cat "$SANDBOX/action-log"; exit 1; }
  PATH="$SANDBOX/bin:$PATH" "$CHANGE_CLASS" --event merge_group --base "$base" --head HEAD \
    --repo "$repo" --lanes-from "$trusted" --output "$SANDBOX/local" \
    >"$SANDBOX/stdout" 2>"$SANDBOX/local-log" || { cat "$SANDBOX/local-log"; exit 1; }
  for lane in shell cargo web installed; do
    actual="$(verdict "$lane" "$SANDBOX/action")"
    if [ "$actual" != "${!lane}" ]; then cat "$SANDBOX/action-log" >&2; fi
    assert_eq "$label $lane" "${!lane}" "$actual"
    assert_eq "$label $lane local parity" "$actual" "$(verdict "$lane" "$SANDBOX/local")"
  done
  if [ "$label" = installed ]; then
    assert_eq "installed render class" "change_class=render" "$(sed -n '/^change_class=/p' "$SANDBOX/action")"
    assert_eq "installed render opens the global gate" "lanes=true" "$(sed -n '/^lanes=/p' "$SANDBOX/action")"
  fi
done <<'ROWS'
source|tools/input.sh|true|false|false|false
removed-source|tools/input.sh|true|false|false|false
shared-gate|tools/peer.sh|true|false|false|false
cargo-path-dependency|cargo/leaf/src/lib.rs|false|true|false|false
cargo-unread|cargo/spare/src/lib.rs|false|false|false|false
vitest-import|web/input.mjs|false|false|true|false
vitest-unread|web/spare.mjs|false|false|false|false
installed|.codex/skills/math/SKILL.md|true|false|false|true
unplaced-addition|unplaced.txt|false|true|true|false
reasoned-exception|external.settings|true|true|true|false
ROWS
report "derived lane reach"
