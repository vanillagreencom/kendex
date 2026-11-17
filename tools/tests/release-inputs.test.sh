#!/usr/bin/env bash
# Inputs: tools/release-inputs .github/workflows/release.yml skills/harness-ci/tests/lib/*
# The workflow's build condition consumes the real selector's output on real
# git diffs. This proves selection, not execution of the five native builds.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "$TEST_DIR/../.." && pwd -P)"
# shellcheck source=../../skills/harness-ci/tests/lib/workflow.sh
. "$ROOT/skills/harness-ci/tests/lib/workflow.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'release-inputs.test: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'release-inputs.test: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'release-inputs.test: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=0
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
WF="$ROOT/.github/workflows/release.yml"
TOOL="$ROOT/tools/release-inputs"
PASS=0

assert_eq() {
  [ "$1" = "$2" ] || { printf 'FAIL %s: expected [%s], got [%s]\n' "$3" "$2" "$1" >&2; return 1; }
  PASS=$((PASS + 1))
}

# Hold the workflow wiring as well as its evaluated condition: an unconnected
# selector would correctly answer false while GitHub still built every target.
for line in \
  '      build: ${{ steps.inputs.outputs.build }}' \
  '          EVENT_NAME: ${{ github.event_name }}' \
  '          PUSH_BEFORE: ${{ github.event.before }}' \
  '        run: tools/release-inputs "$EVENT_NAME" "$PUSH_BEFORE" "$GITHUB_SHA" >> "$GITHUB_OUTPUT"'; do
  grep -Fx -- "$line" "$WF" >/dev/null
done
assert_eq "$(triggers "$WF")" $'push\nworkflow_dispatch' triggers
expr="$(job_ifs "$WF" | awk -F '\t' '$1 == "build" { print $2 }')"
[ -n "$expr" ]
targets="$(awk '/^  build:/ { active=1 } /^  publish:/ { active=0 } active && /^            target:/ { print $2 }' "$WF" | LC_ALL=C sort)"
assert_eq "$targets" $'aarch64-apple-darwin\naarch64-unknown-linux-gnu\nx86_64-apple-darwin\nx86_64-pc-windows-msvc\nx86_64-unknown-linux-gnu' targets

git init --quiet "$TMP_ROOT/repo"
cd -- "$TMP_ROOT/repo"
printf base > seed
git add seed
git -c core.hooksPath=/dev/null commit --quiet -m base
base="$(git rev-parse HEAD)"

selected() { # TOOL EVENT BEFORE AFTER
  local output ctx
  output="$("$BASH" "$1" "$2" "$3" "$4")"
  case "$output" in build=true|build=false) ;; *) return 2 ;; esac
  ctx="$(jq -cn --arg build "${output#build=}" '{needs: {prepare: {result: "success", outputs: {build: $build}}}}')"
  printf 'build\tprepare\t%s\n' "$expr" | gh_eval jobs "$ctx"
}

# Each path is a separate push; the multi-commit row below also catches a
# HEAD^ shortcut that would miss an earlier release-input commit in the push.
while IFS='|' read -r path expected; do
  mkdir -p "$(dirname -- "$path")"
  printf changed > "$path"
  git add -- "$path"
  git -c core.hooksPath=/dev/null commit --quiet -m fixture
  head="$(git rev-parse HEAD)"
  assert_eq "$(selected "$TOOL" push "$base" "$head")" "$expected" "$path"
  base=$head
done <<'CASES'
.kendex-lock.json|
skills/example/SKILL.md|
docs/architecture/updates.md|
crates/core/src/lib.rs|build
Cargo.toml|build
Cargo.lock|build
ui/src/main.tsx|build
.cargo/config.toml|build
rust-toolchain.toml|build
docs/authoring/README.md|build
.github/workflows/release.yml|build
tools/release-inputs|build
tools/release-digests|build
tools/release-installer-check.ps1|build
tools/apt-install|build
CASES

before=$head
printf next >> Cargo.toml
git -c core.hooksPath=/dev/null commit --quiet -am release-input
printf next >> .kendex-lock.json
git -c core.hooksPath=/dev/null commit --quiet -am lock
head="$(git rev-parse HEAD)"
assert_eq "$(selected "$TOOL" push "$before" "$head")" build multi-commit
before=$head
git mv crates/core/src/lib.rs moved.rs
git -c core.hooksPath=/dev/null commit --quiet -am move
head="$(git rev-parse HEAD)"
assert_eq "$(selected "$TOOL" push "$before" "$head")" build rename-out
assert_eq "$(selected "$TOOL" push 0000000000000000000000000000000000000000 "$head" 2>/dev/null)" build unknown-base
assert_eq "$(selected "$TOOL" workflow_dispatch '' "$head")" build dispatch

# A disposable source control retains the skip branch but makes its answer
# wrong. The lock-only probe must reject that selector through the job gate.
python3 - "$TOOL" "$TMP_ROOT/mutant" <<'PY'
import pathlib
import sys
source = pathlib.Path(sys.argv[1]).read_text()
assert source.count('build=false') == 1
mutant = source.replace('build=false', 'build=true')
assert mutant != source
pathlib.Path(sys.argv[2]).write_text(mutant)
PY
assert_eq "$(selected "$TOOL" push "$head" "$head")" '' empty-diff
if assert_eq "$(selected "$TMP_ROOT/mutant" push "$head" "$head")" '' control >"$TMP_ROOT/control.log" 2>&1; then
  echo 'FAIL: must-fail control was accepted' >&2
  exit 1
fi
printf 'ok: release input selection and must-fail control\n'
printf 'pass: %s   fail: 0\n' "$PASS"
