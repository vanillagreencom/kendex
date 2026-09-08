#!/usr/bin/env bash
# Audit checks must search paths that exist. The resolver derives them from the
# repository: a narrow change set when one is known, otherwise every tracked
# source root. The workflow therefore needs no repository-root src/ assumption.
#
# The markdown checks at the tail pin structure only. Runtime rows separately
# prove repository discovery and the exclusion of vendored .agents/ renders.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOLVER="$SKILL_DIR/scripts/verification-scope"
WORKFLOW="$SKILL_DIR/workflows/tpm-audit.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -x "$RESOLVER" ]] || fail "verification-scope is not executable"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/verification-scope-test.XXXXXX")" \
  || fail "could not create test scratch directory"
trap 'rm -rf -- "$scratch"' EXIT

case_root=""
case_base_ref=""
case_corrupt_index=""

setup_fixture() {
  local fixture_kind="$1" case_name="$2"

  case_root="$scratch/$case_name"
  case_base_ref=""
  case_corrupt_index=""
  mkdir -p "$case_root"

  case "$fixture_kind" in
    workspace|workspace-history|corrupt-index)
      mkdir -p "$case_root/crate-a/src" "$case_root/crate-b/src" \
        "$case_root/docs"
      printf '[workspace]\nmembers = ["crate-a", "crate-b"]\n' \
        >"$case_root/Cargo.toml"
      printf 'pub fn alpha() {}\n' >"$case_root/crate-a/src/lib.rs"
      printf 'fn main() {}\n' >"$case_root/crate-b/src/main.rs"
      printf '# Audit notes\n' >"$case_root/docs/audit.md"
      git -C "$case_root" init -q
      git -C "$case_root" add .
      if [[ "$fixture_kind" == "workspace-history" ]]; then
        git -C "$case_root" config user.name "Verification Scope Test"
        git -C "$case_root" config user.email \
          "verification-scope@example.invalid"
        git -C "$case_root" commit -qm "fixture: initial workspace"
        case_base_ref="$(git -C "$case_root" rev-parse HEAD)"
        printf 'pub fn beta() {}\n' >>"$case_root/crate-a/src/lib.rs"
        git -C "$case_root" add crate-a/src/lib.rs
        git -C "$case_root" commit -qm "fixture: change crate a"
      elif [[ "$fixture_kind" == "corrupt-index" ]]; then
        case_corrupt_index="$case_root/corrupt-index"
        printf 'invalid index\n' >"$case_corrupt_index"
      fi
      ;;
    documentation)
      printf '# Documentation repository\n' >"$case_root/README.md"
      git -C "$case_root" init -q
      git -C "$case_root" add README.md
      ;;
    disconnected-history)
      mkdir -p "$case_root/src"
      printf 'fn main() {}\n' >"$case_root/src/main.rs"
      git -C "$case_root" init -q
      git -C "$case_root" config user.name "Verification Scope Test"
      git -C "$case_root" config user.email \
        "verification-scope@example.invalid"
      git -C "$case_root" add src/main.rs
      git -C "$case_root" commit -qm "fixture: first history"
      case_base_ref="$(git -C "$case_root" rev-parse HEAD)"
      git -C "$case_root" checkout -q --orphan disconnected
      git -C "$case_root" rm -q -rf .
      mkdir -p "$case_root/src"
      printf 'fn disconnected() {}\n' >"$case_root/src/disconnected.rs"
      git -C "$case_root" add src/disconnected.rs
      git -C "$case_root" commit -qm "fixture: disconnected history"
      ;;
    render-repository)
      mkdir -p "$case_root/src" \
        "$case_root/.agents/skills/alpha/scripts" \
        "$case_root/.agents/skills/beta/scripts"
      printf 'fn main() {}\n' >"$case_root/src/main.rs"
      printf '#!/usr/bin/env bash\ntrue\n' \
        >"$case_root/.agents/skills/alpha/scripts/alpha.sh"
      printf '#!/usr/bin/env bash\ntrue\n' \
        >"$case_root/.agents/skills/beta/scripts/beta.sh"
      git -C "$case_root" init -q
      git -C "$case_root" add .
      ;;
    *)
      fail "$case_name: unknown fixture kind $fixture_kind"
      ;;
  esac
}

success_failures=0
success_rows_executed=0

require_success_result() {
  local case_name="$1" json="$2" expression="$3" description="$4"

  if ! jq -e "$expression" >/dev/null <<<"$json"; then
    echo "FAIL: $case_name: $description" >&2
    success_failures=$((success_failures + 1))
  fi
}

run_success_case() {
  local case_name="$1" fixture_kind="$2" invocation="$3"
  local expression="$4" description="$5" result

  setup_fixture "$fixture_kind" "$case_name"
  case "$invocation" in
    repository)
      result="$($RESOLVER --worktree "$case_root")"
      ;;
    changed-a)
      result="$($RESOLVER --worktree "$case_root" \
        --changed-file crate-a/src/lib.rs)"
      ;;
    changed-b)
      result="$($RESOLVER --worktree "$case_root" \
        --changed-file crate-b/src/main.rs)"
      ;;
    base-ref)
      result="$($RESOLVER --worktree "$case_root" \
        --base-ref "$case_base_ref")"
      ;;
    changed-documentation)
      result="$($RESOLVER --worktree "$case_root" \
        --changed-file docs/audit.md)"
      ;;
    explicit-render)
      result="$($RESOLVER --worktree "$case_root" \
        --changed-file .agents/skills/alpha/scripts/alpha.sh)"
      ;;
    *)
      fail "$case_name: unknown success invocation $invocation"
      ;;
  esac
  require_success_result \
    "$case_name" "$result" "$expression" "$description"
}

while IFS='^' read -r case_name fixture_kind invocation expression description; do
  run_success_case \
    "$case_name" "$fixture_kind" "$invocation" "$expression" "$description"
  success_rows_executed=$((success_rows_executed + 1))
done <<'SUCCESS_ROWS'
repository-multicrate^workspace^repository^.mode == "repository" and (.source_roots == ["crate-a/src", "crate-b/src"]) and (.verification_paths == ["crate-a/src", "crate-b/src"]) and (.verification_paths | index("src") | not)^repository mode did not return the exact multi-crate scope
changed-crate-a^workspace^changed-a^.verification_paths == ["crate-a/src/lib.rs"] and (.verification_paths | index("crate-b/src/main.rs") | not)^changed crate A did not retain its independent exact scope
changed-crate-b^workspace^changed-b^.mode == "changed" and (.source_roots == ["crate-b/src"]) and (.verification_paths == ["crate-b/src/main.rs"]) and (.verification_paths | index("crate-a/src/lib.rs") | not)^changed crate B did not retain its independent exact scope
base-ref-crate-a^workspace-history^base-ref^.mode == "changed" and (.changed_files == ["crate-a/src/lib.rs"]) and (.source_roots == ["crate-a/src"]) and (.verification_paths == ["crate-a/src/lib.rs"])^base-ref mode did not return the exact changed crate scope
changed-documentation^workspace^changed-documentation^.mode == "docs-only" and (.code_verification_required == false) and (.source_roots == []) and (.verification_paths == ["docs/audit.md"])^documentation mode did not return the exact documentation scope
repository-excludes-renders^render-repository^repository^.source_roots == ["src"] and (.verification_paths == ["src"]) and (.verification_paths | map(startswith(".agents/")) | any | not)^repository discovery did not return the exact non-render scope
explicit-render-path^render-repository^explicit-render^.verification_paths == [".agents/skills/alpha/scripts/alpha.sh"]^explicit render path was not preserved exactly
SUCCESS_ROWS

[[ "$success_rows_executed" -gt 0 ]] \
  || fail "SUCCESS_ROWS executed no assertion rows"
if [[ "$success_failures" -ne 0 ]]; then
  exit 1
fi

refusal_failures=0
refusal_rows_executed=0

record_refusal_failure() {
  local case_name="$1" description="$2" status="$3"
  local expected_status="$4" expected_key="$5" expected_value="$6" output="$7"

  echo "FAIL: $case_name: $description" >&2
  echo "  status: $status; expected: $expected_status" >&2
  echo "  expected first-line fields: $expected_key $expected_value" >&2
  if [[ "$output" != *"$expected_key"* || "$output" != *"$expected_value"* ]]; then
    echo "  actual output: $output" >&2
  fi
  refusal_failures=$((refusal_failures + 1))
}

run_refusal_case() {
  local case_name="$1" fixture_kind="$2" invocation="$3"
  local expected_status="$4" expected_key="$5" expected_value="$6" description="$7"
  local output status matches first_line

  setup_fixture "$fixture_kind" "$case_name"
  case "$invocation" in
    forced-docs-code)
      if output="$($RESOLVER --worktree "$case_root" --docs-only \
        --changed-file crate-a/src/lib.rs 2>&1)"; then
        status=0
      else
        status=$?
      fi
      ;;
    outside-worktree)
      if output="$($RESOLVER --worktree "$case_root" \
        --changed-file ../outside.rs 2>&1)"; then
        status=0
      else
        status=$?
      fi
      ;;
    repository-without-source)
      if output="$($RESOLVER --worktree "$case_root" 2>&1)"; then
        status=0
      else
        status=$?
      fi
      ;;
    disconnected-base)
      if output="$($RESOLVER --worktree "$case_root" \
        --base-ref "$case_base_ref" 2>&1)"; then
        status=0
      else
        status=$?
      fi
      ;;
    corrupt-index)
      if output="$(GIT_INDEX_FILE="$case_corrupt_index" \
        "$RESOLVER" --worktree "$case_root" 2>&1)"; then
        status=0
      else
        status=$?
      fi
      ;;
    *)
      fail "$case_name: unknown refusal invocation $invocation"
      ;;
  esac

  matches=true
  first_line="${output%%$'\n'*}"
  [[ "$status" -eq "$expected_status" ]] || matches=false
  [[ "$first_line" == *"$expected_key"* ]] || matches=false
  [[ "$first_line" == *"$expected_value"* ]] || matches=false
  if [[ "$matches" != true ]]; then
    record_refusal_failure "$case_name" "$description" "$status" \
      "$expected_status" "$expected_key" "$expected_value" "$output"
  fi
}

while IFS='^' read -r case_name fixture_kind invocation expected_status \
  expected_key expected_value description; do
  run_refusal_case "$case_name" "$fixture_kind" "$invocation" \
    "$expected_status" "$expected_key" "$expected_value" "$description"
  refusal_rows_executed=$((refusal_rows_executed + 1))
done <<'REFUSAL_ROWS'
forced-docs-rejects-code^workspace^forced-docs-code^1^error=docs-only-nondoc^path=crate-a/src/lib.rs^forced docs mode did not reject source code with the exact refusal status
outside-worktree-path^workspace^outside-worktree^1^error=path-escape^path=../outside.rs^resolver did not reject an outside path with the exact refusal status
repository-without-source^documentation^repository-without-source^1^error=source-roots-empty^count=0^repository fallback did not return its exact status and source-scope diagnostic
disconnected-base-history^disconnected-history^disconnected-base^1^error=git-command-failed^operation=diff^base-ref mode did not return its exact status and disconnected-history diagnostic
ls-files-producer-failure^corrupt-index^corrupt-index^1^error=git-command-failed^operation=ls-files^repository discovery did not return its exact status and producer diagnostic
REFUSAL_ROWS

[[ "$refusal_rows_executed" -gt 0 ]] \
  || fail "REFUSAL_ROWS executed no assertion rows"
if [[ "$refusal_failures" -ne 0 ]]; then
  exit 1
fi

run_structural_case() {
  local case_name="$1" expectation="$2" subject_key="$3"
  local needle="$4" description="$5" subject

  case "$subject_key" in
    workflow) subject="$WORKFLOW" ;;
    resolver) subject="$RESOLVER" ;;
    *) fail "$case_name: unknown structural subject $subject_key" ;;
  esac

  case "$expectation" in
    present)
      grep -Fq -- "$needle" "$subject" || fail "$case_name: $description"
      ;;
    absent)
      if grep -Fq -- "$needle" "$subject"; then
        fail "$case_name: $description"
      fi
      ;;
    *)
      fail "$case_name: unknown structural expectation $expectation"
      ;;
  esac
}

structural_rows_executed=0

while IFS='^' read -r case_name expectation subject_key needle description; do
  run_structural_case \
    "$case_name" "$expectation" "$subject_key" "$needle" "$description"
  structural_rows_executed=$((structural_rows_executed + 1))
done <<'STRUCTURAL_ROWS'
workflow-no-hardcoded-src^absent^workflow^${WORKTREE:-.}/src/^tpm-audit still hardcodes a repository-root src directory
workflow-resolver-route^present^workflow^scripts/verification-scope^tpm-audit does not invoke verification-scope
resolver-render-marker^present^resolver^.agents/^verification-scope lost the vendored-render marker
workflow-docs-mode^present^workflow^docs-only^tpm-audit does not document the docs-only path
workflow-path-field^present^workflow^verification_paths^tpm-audit does not consume resolved verification paths
workflow-issue-placeholder^present^workflow^VERIFICATION_CONTEXTS[ISSUE_KEY]^tpm-audit does not retain verification context per issue
STRUCTURAL_ROWS

[[ "$structural_rows_executed" -gt 0 ]] \
  || fail "STRUCTURAL_ROWS executed no assertion rows"
echo "all pass"
