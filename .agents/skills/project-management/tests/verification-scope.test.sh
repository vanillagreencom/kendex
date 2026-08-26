#!/usr/bin/env bash
# Audit checks must search paths that exist. The resolver derives them from the
# repository — a narrow change set when one is known, otherwise every tracked
# source root — so no workflow assumes a repository-root src/, and each issue
# keeps its own scope so one issue's PR never decides another's verdict. This
# exercises the resolver against fixtures and pins the workflow's use of it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOLVER="$SKILL_DIR/scripts/verification-scope"
WORKFLOW="$SKILL_DIR/workflows/tpm-audit.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_jq() {
  local json="$1" expression="$2" description="$3"
  if ! jq -e "$expression" >/dev/null <<<"$json"; then
    fail "$description"
  fi
}

[[ -x "$RESOLVER" ]] || fail "verification-scope is not executable"

fixture="$(mktemp -d)"
docs_fixture="$(mktemp -d)"
history_fixture="$(mktemp -d)"
trap 'rm -rf "$fixture" "$docs_fixture" "$history_fixture"' EXIT

mkdir -p "$fixture/crate-a/src" "$fixture/crate-b/src" "$fixture/docs"
printf '[workspace]\nmembers = ["crate-a", "crate-b"]\n' >"$fixture/Cargo.toml"
printf 'pub fn alpha() {}\n' >"$fixture/crate-a/src/lib.rs"
printf 'fn main() {}\n' >"$fixture/crate-b/src/main.rs"
printf '# Audit notes\n' >"$fixture/docs/audit.md"
git -C "$fixture" init -q
git -C "$fixture" add .

repository_json="$($RESOLVER --worktree "$fixture")"
require_jq "$repository_json" '.mode == "repository"' \
  "repository fallback mode was not selected"
require_jq "$repository_json" '.source_roots == ["crate-a/src", "crate-b/src"]' \
  "multi-crate source roots were not discovered"
require_jq "$repository_json" '.verification_paths | index("src") | not' \
  "resolver invented a repository-root src directory"

changed_json="$($RESOLVER --worktree "$fixture" --changed-file crate-b/src/main.rs)"
require_jq "$changed_json" '.mode == "changed"' \
  "changed-file mode was not selected"
require_jq "$changed_json" '.source_roots == ["crate-b/src"]' \
  "changed-file mode did not narrow to the affected crate"
require_jq "$changed_json" '.verification_paths == ["crate-b/src/main.rs"]' \
  "changed-file verification path was not preserved"

# A multi-issue audit must retain an independent scope for each contract.
issue_a_json="$($RESOLVER --worktree "$fixture" --changed-file crate-a/src/lib.rs)"
issue_b_json="$($RESOLVER --worktree "$fixture" --changed-file crate-b/src/main.rs)"
issue_contexts="$(jq -n \
  --argjson issue_a "$issue_a_json" \
  --argjson issue_b "$issue_b_json" \
  '{"ISSUE-A": $issue_a, "ISSUE-B": $issue_b}')"
require_jq "$issue_contexts" \
  '.["ISSUE-A"].verification_paths == ["crate-a/src/lib.rs"]' \
  "first issue did not retain its own verification scope"
require_jq "$issue_contexts" \
  '.["ISSUE-B"].verification_paths == ["crate-b/src/main.rs"]' \
  "second issue did not retain its own verification scope"
require_jq "$issue_contexts" \
  '.["ISSUE-A"].verification_paths | index("crate-b/src/main.rs") | not' \
  "second issue verification scope leaked into the first issue"
require_jq "$issue_contexts" \
  '.["ISSUE-B"].verification_paths | index("crate-a/src/lib.rs") | not' \
  "first issue verification scope leaked into the second issue"

git -C "$fixture" config user.name "Verification Scope Test"
git -C "$fixture" config user.email "verification-scope@example.invalid"
git -C "$fixture" commit -qm "fixture: initial workspace"
base_ref="$(git -C "$fixture" rev-parse HEAD)"
printf 'pub fn beta() {}\n' >>"$fixture/crate-a/src/lib.rs"
git -C "$fixture" add crate-a/src/lib.rs
git -C "$fixture" commit -qm "fixture: change crate a"

base_json="$($RESOLVER --worktree "$fixture" --base-ref "$base_ref")"
require_jq "$base_json" '.mode == "changed"' \
  "base-ref mode did not resolve a changed scope"
require_jq "$base_json" '.changed_files == ["crate-a/src/lib.rs"]' \
  "base-ref mode did not preserve the branch change set"
require_jq "$base_json" '.source_roots == ["crate-a/src"]' \
  "base-ref mode did not narrow to the changed crate"

docs_json="$($RESOLVER --worktree "$fixture" --changed-file docs/audit.md)"
require_jq "$docs_json" '.mode == "docs-only"' \
  "documentation-only change was not classified"
require_jq "$docs_json" '.code_verification_required == false' \
  "documentation-only audit still requires code verification"
require_jq "$docs_json" '.source_roots == []' \
  "documentation-only audit invented source roots"

if "$RESOLVER" --worktree "$fixture" --docs-only \
  --changed-file crate-a/src/lib.rs >/dev/null 2>&1; then
  fail "--docs-only accepted a source file"
fi
if "$RESOLVER" --worktree "$fixture" \
  --changed-file ../outside.rs >/dev/null 2>&1; then
  fail "resolver accepted a path outside the worktree"
fi

printf '# Documentation repository\n' >"$docs_fixture/README.md"
git -C "$docs_fixture" init -q
git -C "$docs_fixture" add README.md
if no_source_output="$($RESOLVER --worktree "$docs_fixture" 2>&1)"; then
  fail "repository fallback succeeded without tracked source roots"
fi
if [[ "$no_source_output" != *"no tracked source roots found"* ]]; then
  fail "repository fallback did not explain the missing source scope"
fi

mkdir -p "$history_fixture/src"
printf 'fn main() {}\n' >"$history_fixture/src/main.rs"
git -C "$history_fixture" init -q
git -C "$history_fixture" config user.name "Verification Scope Test"
git -C "$history_fixture" config user.email "verification-scope@example.invalid"
git -C "$history_fixture" add src/main.rs
git -C "$history_fixture" commit -qm "fixture: first history"
disconnected_base="$(git -C "$history_fixture" rev-parse HEAD)"
git -C "$history_fixture" checkout -q --orphan disconnected
git -C "$history_fixture" rm -q -rf .
mkdir -p "$history_fixture/src"
printf 'fn disconnected() {}\n' >"$history_fixture/src/disconnected.rs"
git -C "$history_fixture" add src/disconnected.rs
git -C "$history_fixture" commit -qm "fixture: disconnected history"
if disconnected_output="$($RESOLVER --worktree "$history_fixture" \
  --base-ref "$disconnected_base" 2>&1)"; then
  fail "base-ref mode accepted disconnected histories"
fi
if [[ "$disconnected_output" != *"git diff failed for base ref"* ]]; then
  fail "disconnected-history failure did not identify git diff"
fi

corrupt_index="$docs_fixture/corrupt-index"
printf 'invalid index\n' >"$corrupt_index"
if producer_output="$(GIT_INDEX_FILE="$corrupt_index" \
  "$RESOLVER" --worktree "$fixture" 2>&1)"; then
  fail "repository discovery ignored a git ls-files producer failure"
fi
if [[ "$producer_output" != *"git ls-files failed"* ]]; then
  fail "producer failure did not identify git ls-files"
fi

if grep -Fq '${WORKTREE:-.}/src/' "$WORKFLOW"; then
  fail "tpm-audit still hardcodes a repository-root src directory"
fi
grep -Eq 'never assumed|Never substitute `\[WORKTREE\]/src`' "$WORKFLOW" \
  || fail "tpm-audit lost the no-assumed-repository-root-src rule"
grep -Fq 'scripts/verification-scope' "$WORKFLOW" \
  || fail "tpm-audit does not invoke verification-scope"
grep -Fq 'docs-only' "$WORKFLOW" \
  || fail "tpm-audit does not document the docs-only path"
grep -Fq 'verification_paths' "$WORKFLOW" \
  || fail "tpm-audit does not consume resolved verification paths"
grep -Fq 'VERIFICATION_CONTEXTS[ISSUE_KEY]' "$WORKFLOW" \
  || fail "tpm-audit does not retain verification context per issue"
grep -Fq "reuse another issue's linked PR" "$WORKFLOW" \
  || fail "tpm-audit does not prohibit cross-issue verification scope reuse"

echo "all pass"
