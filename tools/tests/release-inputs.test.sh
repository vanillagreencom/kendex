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

assert_eq "$(triggers "$WF")" $'push\nworkflow_dispatch' triggers
expr="$(job_ifs "$WF" | awk -F '\t' '$1 == "build" { print $2 }')"
[ -n "$expr" ]
needs="$(job_needs "$WF" | awk -F '\t' '$1 == "build" { print $2 }')"
producer="$(awk '
  /^  [A-Za-z0-9_-]+:/ { prepare = ($1 == "prepare:") }
  prepare && /^      - / { id = "" }
  prepare && /^        id: / { id = $2 }
  prepare && /^        run: tools\/release-inputs / { print id }
' "$WF")"
[ -n "$producer" ]
binding="$(awk '
  /^  [A-Za-z0-9_-]+:/ { prepare = ($1 == "prepare:"); outputs = 0 }
  prepare && /^    [^ ]/ { outputs = ($1 == "outputs:") }
  outputs && /^      build: / { sub(/^      build: \$\{\{ /, ""); sub(/ \}\}$/, ""); print }
' "$WF")"
[ -n "$binding" ]
targets="$(awk '/^  build:/ { active=1 } /^  publish:/ { active=0 } active && /^            target:/ { print $2 }' "$WF" | LC_ALL=C sort)"
assert_eq "$targets" $'aarch64-apple-darwin\naarch64-unknown-linux-gnu\nx86_64-apple-darwin\nx86_64-pc-windows-msvc\nx86_64-unknown-linux-gnu' targets

git init --quiet "$TMP_ROOT/repo"
cd -- "$TMP_ROOT/repo"
printf base > seed
git add seed
git -c core.hooksPath=/dev/null commit --quiet -m base
base="$(git rev-parse HEAD)"

selected() { # TOOL EVENT BEFORE AFTER
  local output steps published ctx
  output="$("$BASH" "$1" "$2" "$3" "$4")" || return
  case "$output" in build=true|build=false) ;; *) return 2 ;; esac
  steps="$(jq -cn --arg id "$producer" --arg build "${output#build=}" '{steps: {($id): {outputs: {build: $build}}}}')" || return
  published="$(python3 "$GH_EVAL" value "$steps" "$binding")" || return
  ctx="$(jq -cn --argjson build "$published" '{needs: {prepare: {result: "success", outputs: {build: ($build // "")}}}}')" || return
  printf 'build\t%s\t%s\n' "$needs" "$expr" | python3 "$GH_EVAL" jobs "$ctx"
}

assert_selected() { # CASE EXPECTED EVENT BEFORE AFTER
  local actual status=0
  actual="$(selected "$TOOL" "$3" "$4" "$5")" || status=$?
  if [ "$status" -ne 0 ]; then
    printf 'FAIL %s: release selection exited %s\n' "$1" "$status" >&2
    return "$status"
  fi
  assert_eq "$actual" "$2" "$1"
}

# Each path is a separate push; the multi-commit row below also catches a
# HEAD^ shortcut that would miss an earlier release-input commit in the push.
while IFS='|' read -r path expected; do
  mkdir -p "$(dirname -- "$path")"
  printf changed > "$path"
  git add -- "$path"
  git -c core.hooksPath=/dev/null commit --quiet -m fixture
  head="$(git rev-parse HEAD)"
  assert_selected "$path" "$expected" push "$base" "$head"
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
assert_selected multi-commit build push "$before" "$head"
before=$head
git mv crates/core/src/lib.rs moved.rs
git -c core.hooksPath=/dev/null commit --quiet -am move
head="$(git rev-parse HEAD)"
assert_selected rename-out build push "$before" "$head"
assert_selected unknown-base build push 0000000000000000000000000000000000000000 "$head"
assert_selected dispatch build workflow_dispatch '' "$head"
assert_selected empty-diff '' push "$head" "$head"

printf 'pass: %s   fail: 0\n' "$PASS"
