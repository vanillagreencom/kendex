#!/usr/bin/env bash
# Tests for the CI ci class job set catalog contract.
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which would resolve ROOT to the hook's
# repository instead of this one.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ci-job-set-world.sh
. "$TEST_DIR/lib/ci-job-set-world.sh"

source "$TEST_DIR/lib/ci-job-set-case.sh"

catalog_bits() { # SELECTION — only the two independently selected jobs
  printf '%s\n' "$1" | tr ' ' '\n' | grep -E '^(catalog|smoke)='
}
catalog_rows() { # SCRIPT — every row must agree on both events
  local class path selected event
  while IFS='|' read -r class path selected; do
    for event in pull_request merge_group; do
      check "catalog inputs: $event $class $path" "catalog=$selected
smoke=$selected" "$(catalog_bits "$(SELECT_IN="$READ_WORLD" SELECT_WITH="$1" SELECT_EVENT="$event" selection "$class" false "$path")")"
    done
  done <<ROWS
trivial|README.md|false
standard|README.md|false
render|.agents/skills/orch/SKILL.md|false
micro|$UI_ONLY|false
micro|crates/app/src/editor.rs|false
micro|crates/app/tests/integration.rs|false
micro|crates/core/tests/integration.rs|false
micro|crates/cli/tests/integration.rs|false
trivial|skills/orch/SKILL.md|true
render|skills/orch/SKILL.md|true
micro|agents/runtime.md|true
micro|hooks/guard.sh|true
micro|commands/run.md|true
micro|mcp/docs.toml|true
micro|output-styles/plain.md|true
micro|pi-extensions/pi-hooks/README.md|true
micro|plugins/tool/skills/tool/SKILL.md|true
micro|.claude-plugin/marketplace.json|true
micro|kendex.toml|true
micro|.gitignore|true
micro|.gitattributes|true
micro|.gitmodules|true
micro|tools/catalog-release-check|true
micro|crates/core/src/render/agent.rs|true
micro|crates/cli/tests/cli_smoke.rs|true
micro|crates/test_util.rs|true
micro|crates/app/Cargo.toml|true
micro|Cargo.toml|true
micro|Cargo.lock|true
micro|rust-toolchain.toml|true
micro|.cargo/config.toml|true
micro|.github/workflows/skill-tests.yml|true
micro|tools/guard|true
ROWS
}
catalog_rows "$JOB_SET"
check "compiled catalog prose selects both jobs" 'catalog=true
smoke=true' "$(catalog_bits "$(SELECT_IN="$READ_WORLD" selection trivial true docs/a.md)")"
# Plant the inverse of the inputs rule. The assertions remain the same as the
# positive table; the copy must fail at least one of them.
mkdir -p "$TMP/catalog/tools"
cp -R "$ROOT/tools/lib" "$TMP/catalog/tools/lib"
cp "$ROOT/tools/macos-test-contracts" "$ROOT/tools/macos-test-contracts.json" "$TMP/catalog/tools/"
cp "$ROOT/tools/rust-reads" "$TMP/catalog/tools/rust-reads"
catalog_copy="$TMP/catalog/tools/ci-job-set"
needle='  any "$CATALOG_INPUTS|$LANE_SOURCES" && catalog=true'
replacement='  any "$CATALOG_INPUTS|$LANE_SOURCES" && catalog=false'
[ "$(grep -cxF -- "$needle" "$JOB_SET")" -eq 1 ] || exit 1
NEEDLE="$needle" REPLACEMENT="$replacement" awk '$0 == ENVIRON["NEEDLE"] { print ENVIRON["REPLACEMENT"]; next } { print }' "$JOB_SET" >"$catalog_copy"
! cmp -s "$JOB_SET" "$catalog_copy" || exit 1
chmod +x "$catalog_copy"
if (PASS=0 FAIL=0; catalog_rows "$catalog_copy" >"$TMP/catalog-control-inputs"; [ "$FAIL" -eq 0 ]); then
  bad "must-fail: inputs inverse leaves catalog selection green"
else
  ok "must-fail: inputs inverse fails catalog selection"
fi

# The shard selection in a fixture world, where every reader is planted, so
# each list is the projection of the whole reach:
#   worktree's script sources github's lib; harness-ci's script sources
#   orch's lib; neither package holds a suite;
#   commit-guards' suites run preflight and read docs/guard/refs.md;
#   a tools/ suite reads kendex.settings.toml and names atomic-install.sh and
#   README.md; hooks/ suites read crates/demo/src/discover.rs and
#   docs/x/policy.md; a Pi package's suite runs tools/demo-tool;
#   skills/AGENTS.md and docs/cite.md cite a shard; orch's Rust target rows
#   reads assets/rust-read.json.
# A path no suite and no target can depend on runs no shard; a hook beside
# the reach runs node and harness-smoke; a build input runs the checkout's
# consumer shards whole.
# tools/shipped-refs reads dependencies.required through
# lib/skill-requirements.awk: external commands, agent lists and hook lists
# add no required skill edge.
required_edge="$(printf 'doc-limits\tcommit-guards')"
check "required, optional, agents, hooks and commands retain only the required skill edge" "$required_edge" \
  "$(awk -f "$ROOT/tools/lib/skill-requirements.awk" "$SEL_WORLD/skills/doc-limits/SKILL.md")"
for list in agents hooks; do
  needle="/^  $list:/ { next }"
  [ "$(grep -cxF -- "$needle" "$ROOT/tools/lib/skill-requirements.awk")" -eq 1 ] || exit 1
  awk -v needle="$needle" '$0 != needle' "$ROOT/tools/lib/skill-requirements.awk" >"$TMP/rule/tools/lib/skill-requirements.awk"
  ! cmp -s "$ROOT/tools/lib/skill-requirements.awk" "$TMP/rule/tools/lib/skill-requirements.awk" || exit 1
  got="$(awk -f "$TMP/rule/tools/lib/skill-requirements.awk" "$SEL_WORLD/skills/doc-limits/SKILL.md")"
  [ "$got" != "$required_edge" ] && ok "must-fail: dropping the $list skip fails the required-edge row" || \
    bad "must-fail: dropping the $list skip leaves the required-edge row green"
done
cp "$ROOT/tools/lib/skill-requirements.awk" "$TMP/rule/tools/lib/skill-requirements.awk"
# PATH|SHARDS, every row micro and not docs-only.
world_rows=0
while IFS='|' read -r path expected; do
  world_rows=$((world_rows + 1))
  check "world selection over '$path'" "$expected" \
    "$(SELECT_IN="$SEL_WORLD" selection micro false "$path" | field shards)"
done <<ROWS
skills/price-handling/scripts/x|["guards-scans"]
skills/github/scripts/lib/gh-auth.sh|["guards-scans"]
skills/orch/scripts/lib/kendex-env.sh|["orch-rest","guards-scans"]
skills/preflight/scripts/preflight|["guards-scans","guards-commit","guards-commit-tail","guards-hooks","guards-hooks-tail"]
kendex.settings.toml|["guards-tools","guards-tools-tail"]
install.sh|[]
README.md|[]
crates/demo/src/discover.rs|["refresh","orch-rest","guards-hooks","guards-hooks-tail","rest","jarvis"]
.claude/hooks/lane-mail-check|["guards-hooks","guards-hooks-tail","guards-tools","guards-tools-tail","node"]
.pi/kendex/hooks/lane-mail-check|["guards-hooks","guards-hooks-tail","guards-tools","guards-tools-tail","node"]
hooks/block-bare-cd.sh|["guards-scans","guards-hooks","guards-hooks-tail","guards-tools","guards-tools-tail","node"]
docs/x/policy.md|["guards-hooks","guards-hooks-tail"]
docs/guard/refs.md|["guards-commit","guards-commit-tail","guards-hooks","guards-hooks-tail"]
tools/demo-tool|["guards-scans","guards-tools","guards-tools-tail","node"]
skills/AGENTS.md|["guards-scans","guards-tools","guards-tools-tail"]
docs/cite.md|["guards-tools","guards-tools-tail"]
kendex.toml|[]
agents/reviewer.md|[]
.kendex-lock.json|[]
skills/CLAUDE.md|["guards-scans"]
refresh/runner.sh|["guards-scans"]
ROWS
# A Rust target of a runtime is no shell suite: a path only it reads runs
# that target and the orch-rest leg that runs it, and a path nothing reads
# runs neither.
# PATH|SHARDS RUST TARGETS, every row micro and not docs-only.
while IFS='|' read -r path expected; do
  world_rows=$((world_rows + 1))
  got="$(SELECT_IN="$SEL_WORLD" selection micro false "$path")"
  check "world Rust targets over '$path'" "$expected" "$(field shards <<<"$got") $(field rust_targets <<<"$got")"
done <<'ROWS'
assets/rust-read.json|["orch-rest"] ["orch/rows"]
assets/unread.json|[] []
ROWS
[ "$world_rows" -ge 20 ] || { echo "the world table read $world_rows rows" >&2; exit 1; }

# Each refusal the shard selection makes, from a planted copy beside the
# real reach.
cp "$ROOT/tools/guard" "$TMP/rule/tools/guard"
# EDIT#PATH#EXPECTED — a copy of the script with a planted fault. Fields split
# on `#`, since an edit spells `$@`.
while IFS='#' read -r edit path expected; do
  sed "$edit" "$JOB_SET" >"$TMP/rule/tools/ci-job-set"
  chmod +x "$TMP/rule/tools/ci-job-set"
  cmp -s "$JOB_SET" "$TMP/rule/tools/ci-job-set" && { bad "the planted fault changed nothing: $edit"; continue; }
  check "a planted fault is refused: $expected" "$expected" \
    "$(SELECT_IN="$SEL_WORLD" SELECT_WITH="$TMP/rule/tools/ci-job-set" selection micro false "$path")"
done <<'ROWS'
s/skills\/commit-guards) want_shard guards-commit /skills\/commit-guards) want_shard guards-commi /#skills/preflight/scripts/preflight#exit=2 shard-undeclared shard=guards-commi
s/grep -qE -- "\$SHARD_CITATION"/grep --no-such-option -qE -- "$SHARD_CITATION"/#docs/cite.md#exit=2 citation-read-failed
ROWS

# A reach that cannot be read runs every shard, every suite and every
# target: the copy asks a guard that is not there.
sed 's|"$TOOLS_DIR/guard" --suite-reach|"$TOOLS_DIR/no-guard" --suite-reach|' "$JOB_SET" >"$TMP/rule/tools/ci-job-set"
chmod +x "$TMP/rule/tools/ci-job-set"
if cmp -s "$JOB_SET" "$TMP/rule/tools/ci-job-set"; then
  bad "the unread-reach copy changed nothing"
else
  got="$(SELECT_IN="$SEL_WORLD" SELECT_WITH="$TMP/rule/tools/ci-job-set" selection micro false skills/price-handling/scripts/x)"
  check "an unread reach runs every shard, suite and target" "$ROSTER [] [\"orch/*\"]" \
    "$(field shards <<<"$got") $(field skipped_suites <<<"$got") $(field rust_targets <<<"$got")"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
