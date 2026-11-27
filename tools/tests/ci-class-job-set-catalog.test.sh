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

# CLASS|PATHS|CATALOG[|SMOKE], SMOKE CATALOG where absent. Catalog
# paths alone do not affect the smoke test's own fixture.
# The merge group alone: ci-class-job-set-events' parity rows hold the pull
# request's selection equal to it.
catalog_rows() { # SCRIPT
  local class path selected smoke
  while IFS='|' read -r class path selected smoke; do
    check "catalog inputs: $class $path" "catalog=$selected
smoke=${smoke:-$selected}" "$(catalog_bits "$(SELECT_IN="$READ_WORLD" SELECT_WITH="$1" SELECT_EVENT=merge_group selection "$class" false "$(printf '%s\n' $path)")")"
  done <<ROWS
trivial|README.md|false
standard|README.md|false
render|.agents/skills/orch/SKILL.md|false
micro|$UI_ONLY|false
micro|crates/app/src/editor.rs|false
micro|crates/app/tests/integration.rs|false
micro|crates/core/tests/integration.rs|false
micro|crates/cli/tests/integration.rs|false
trivial|skills/orch/SKILL.md|true|false
render|skills/orch/SKILL.md|true|false
micro|agents/runtime.md|true|false
standard|skills/orch/SKILL.md kendex-local.toml|true|false
micro|hooks/guard.sh|true|false
micro|commands/run.md|true|false
micro|mcp/docs.toml|true|false
micro|output-styles/plain.md|true|false
micro|pi-extensions/pi-hooks/README.md|true|false
micro|plugins/tool/skills/tool/SKILL.md|true|false
micro|.claude-plugin/marketplace.json|true|false
micro|kendex.toml|true|false
micro|.gitignore|true|false
micro|.gitattributes|true|false
micro|.gitmodules|true|false
micro|tools/catalog-release-check|true|false
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
needle='  catalog_input && catalog=true'
replacement='  catalog_input && catalog=false'
[ "$(grep -cxF -- "$needle" "$JOB_SET")" -eq 1 ] || exit 1
NEEDLE="$needle" REPLACEMENT="$replacement" awk '$0 == ENVIRON["NEEDLE"] { print ENVIRON["REPLACEMENT"]; next } { print }' "$JOB_SET" >"$catalog_copy"
! cmp -s "$JOB_SET" "$catalog_copy" || exit 1
chmod +x "$catalog_copy"
if (PASS=0 FAIL=0; catalog_rows "$catalog_copy" >"$TMP/catalog-control-inputs"; [ "$FAIL" -eq 0 ]); then
  bad "must-fail: inputs inverse leaves catalog selection green"
else
  ok "must-fail: inputs inverse fails catalog selection"
fi

# Skill text: a world whose head commit edits each file below in place since
# its base, adds one skill Markdown file and removes another.
TEXT_WORLD="$TMP/text-world"
cp -R "$READ_WORLD" "$TEXT_WORLD"
text_git() { git -C "$TEXT_WORLD" -c user.email=ci-job-set@example.invalid -c user.name=ci-job-set "$@"; }
mkdir -p "$TEXT_WORLD/skills/orch/references" "$TEXT_WORLD/skills/orch/workflows" "$TEXT_WORLD/skills/group/nested"
for file in skills/orch/SKILL.md skills/orch/README.md skills/orch/references/r.md skills/orch/workflows/w.md \
  skills/orch/gone.md skills/group/nested/SKILL.md skills/group/nested/README.md skills/notes.md kendex.toml; do
  printf 'base\n' >"$TEXT_WORLD/$file"
done
text_git add -A
text_git commit -q -m base
TEXT_BASE="$(text_git rev-parse HEAD)"
for file in skills/orch/SKILL.md skills/orch/README.md skills/orch/references/r.md skills/orch/workflows/w.md \
  skills/group/nested/README.md skills/notes.md kendex.toml; do
  printf 'head\n' >>"$TEXT_WORLD/$file"
done
printf 'new\n' >"$TEXT_WORLD/skills/orch/references/new.md"
text_git rm -q skills/orch/gone.md
text_git add -A
text_git commit -q -m head

# BASE|PATHS|CATALOG, every row micro at the merge group; BASE `base` is
# TEXT_BASE, `-` unset and `unread` a commit the world does not hold. Smoke
# stays false throughout: no row reaches its fixture.
text_rows() { # SCRIPT
  local base path selected change_base
  while IFS='|' read -r base path selected; do
    case "$base" in base) change_base=$TEXT_BASE ;; unread) change_base=0123456789abcdef0123456789abcdef01234567 ;; *) change_base="" ;; esac
    check "skill text: $base $path" "catalog=$selected
smoke=false" "$(catalog_bits "$(CHANGE_BASE="$change_base" SELECT_IN="$TEXT_WORLD" SELECT_WITH="$1" SELECT_EVENT=merge_group selection micro false "$(printf '%s\n' $path)")")"
  done <<'ROWS'
base|skills/orch/README.md|false
base|skills/orch/references/r.md|false
base|skills/orch/workflows/w.md|false
base|skills/group/nested/README.md|false
base|skills/orch/README.md skills/orch/references/r.md|false
base|skills/orch/SKILL.md|true
base|skills/orch/README.md skills/orch/SKILL.md|true
base|kendex.toml|true
base|skills/orch/README.md kendex.toml|true
base|skills/orch/references/new.md|true
base|skills/orch/gone.md|true
base|skills/notes.md|true
-|skills/orch/README.md|true
unread|skills/orch/README.md|true
ROWS
}
text_rows "$JOB_SET"
# Each planted fault leaves at least one row above red: the narrowing gone,
# SKILL.md counted as skill text, and one skill text path excusing the other
# catalog inputs of its change.
while IFS='#' read -r label needle replacement; do
  [ "$(grep -cxF -- "$needle" "$JOB_SET")" -eq 1 ] || { bad "must-fail $label: no single edit site"; continue; }
  NEEDLE="$needle" REPLACEMENT="$replacement" awk '$0 == ENVIRON["NEEDLE"] { print ENVIRON["REPLACEMENT"]; next } { print }' "$JOB_SET" >"$catalog_copy"
  if cmp -s "$JOB_SET" "$catalog_copy"; then
    bad "must-fail $label: the copy changed nothing"
    continue
  fi
  chmod +x "$catalog_copy"
  if (PASS=0 FAIL=0; text_rows "$catalog_copy" >"$TMP/text-control"; [ "$FAIL" -eq 0 ]); then
    bad "must-fail: $label leaves skill text selection green"
  else
    ok "must-fail: $label fails skill text selection"
  fi
done <<'ROWS'
narrowing removed#  catalog_input && catalog=true#  any "$CATALOG_INPUTS|$LANE_SOURCES" && catalog=true
SKILL.md as text#    [[ $path =~ $PROSE && $path != */SKILL.md ]] || continue#    [[ $path =~ $PROSE ]] || continue
text excuses others#    [[ $SKILL_TEXT == *$'\n'"$path"$'\n'* ]] || return 0#    [[ $SKILL_TEXT == *$'\n'?* ]] || return 0
ROWS

# The shard selection in a fixture world, where every reader is planted, so
# each list is the projection of the whole reach:
#   worktree's script sources github's lib; harness-ci's script sources
#   orch's lib; neither package holds a suite;
#   commit-guards' suites run preflight and read docs/guard/refs.md;
#   a tools/ suite reads kendex.settings.toml and names atomic-install.sh and
#   README.md; hooks/ suites read crates/demo/src/discover.rs and
#   docs/x/policy.md; a Pi package's suite runs tools/demo-tool;
#   orch's Rust target rows
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
install.sh|$ROSTER
README.md|$ROSTER
crates/demo/src/discover.rs|["refresh","orch-rest","guards-hooks","guards-hooks-tail","rest","jarvis"]
.claude/hooks/lane-mail-check|["guards-hooks","guards-hooks-tail","guards-tools","guards-tools-tail","node"]
.pi/kendex/hooks/lane-mail-check|["guards-hooks","guards-hooks-tail","guards-tools","guards-tools-tail","node"]
hooks/block-bare-cd.sh|["guards-scans","guards-hooks","guards-hooks-tail","guards-tools","guards-tools-tail","node"]
docs/x/policy.md|["guards-hooks","guards-hooks-tail"]
docs/guard/refs.md|["guards-commit","guards-commit-tail","guards-hooks","guards-hooks-tail"]
tools/demo-tool|["guards-scans","guards-tools","guards-tools-tail","node"]
skills/AGENTS.md|$ROSTER
docs/cite.md|$ROSTER
kendex.toml|$ROSTER
agents/reviewer.md|$ROSTER
.kendex-lock.json|[]
skills/CLAUDE.md|$ROSTER
refresh/runner.sh|$ROSTER
ROWS
# A Pi source may contain a substring without reading a path by that name.
incidental="artifact-${TMP##*/}"
printf 'const buildLabel = "prefix-%s-suffix";\n' "$incidental" >>"$SEL_WORLD/pi-extensions/pi-demo/tests/demo.test.ts"
printf 'new checkout input\n' >"$SEL_WORLD/$incidental"
git -C "$SEL_WORLD" add -- "$incidental" pi-extensions/pi-demo/tests/demo.test.ts
got="$(SELECT_IN="$SEL_WORLD" SELECT_CARGO_MATRIX=true selection micro false "$incidental")"
check "an unrelated Pi substring cannot place a novel basename" "$ROSTER [] [\"orch/*\"] null" \
  "$(field shards <<<"$got") $(field skipped_suites <<<"$got") $(field rust_targets <<<"$got") $(field cargo_linux_matrix <<<"$got")"

# A Rust target of a runtime is no shell suite: a path only it reads runs
# that target and the orch-rest leg that runs it. An unplaced path keeps all.
# PATH|SHARDS RUST TARGETS, every row micro and not docs-only.
while IFS='|' read -r path expected; do
  world_rows=$((world_rows + 1))
  got="$(SELECT_IN="$SEL_WORLD" selection micro false "$path")"
  check "world Rust targets over '$path'" "$expected" "$(field shards <<<"$got") $(field rust_targets <<<"$got")"
done <<ROWS
assets/rust-read.json|["orch-rest"] ["orch/rows"]
assets/unread.json|$ROSTER ["orch/*"]
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
