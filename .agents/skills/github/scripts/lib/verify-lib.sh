#!/bin/bash
# Cross-PR verification: merge simulation + auto-detected build/test
# Usage: verify-lib.sh verify_prs [PR_NUM...]
#
# Auto-detects project type and runs appropriate build/test commands.
# Override with GH_VERIFY_CMD env var or a verify.sh in project root.

set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"

# Colors for progress output (stderr)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Global state
VERIFY_DIR=""
TEMP_BRANCH=""
START_TIME=""
STEP=0
TOTAL_STEPS=4
RESULTS_JSON=""

init_results() {
    RESULTS_JSON=$(jq -n '{
        mode: "verify",
        verified_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
        duration_seconds: 0,
        prs: [],
        merge: { success: false, conflicts: [] },
        builds: {},
        tests: {},
        can_batch_merge: false,
        issues: [],
        merge_order: [],
        detected_stacks: []
    }')
}

progress() {
    local msg="$1"
    ((STEP++)) || true
    echo -e "${BLUE}[$STEP/$TOTAL_STEPS]${NC} $msg" >&2
}

progress_ok() { echo -e "  ${GREEN}✓${NC} $1" >&2; }
progress_fail() { echo -e "  ${RED}✗${NC} $1" >&2; }
progress_skip() { echo -e "  ${YELLOW}⊘${NC} $1" >&2; }

add_issue() {
    local severity="$1" type="$2" description="$3" recommendation="${4:-}"
    RESULTS_JSON=$(echo "$RESULTS_JSON" | jq \
        --arg sev "$severity" --arg type "$type" \
        --arg desc "$description" --arg rec "$recommendation" \
        '.issues += [{severity: $sev, type: $type, description: $desc, recommendation: $rec}]')
}

update_result() {
    local path="$1" value="$2"
    RESULTS_JSON=$(echo "$RESULTS_JSON" | jq "$path = $value")
}

cleanup() {
    local exit_code=$?
    cd "$PROJECT_ROOT" 2>/dev/null || true
    if [ -n "$VERIFY_DIR" ] && [ -d "$VERIFY_DIR" ]; then
        git worktree remove "$VERIFY_DIR" --force 2>/dev/null || rm -rf "$VERIFY_DIR"
    fi
    if [ -n "$TEMP_BRANCH" ]; then
        git branch -D "$TEMP_BRANCH" 2>/dev/null || true
    fi
    exit $exit_code
}

output_results() {
    local end_time duration all_builds_ok all_tests_ok can_merge
    end_time=$(date +%s)
    duration=$((end_time - START_TIME))

    all_builds_ok=$(echo "$RESULTS_JSON" | jq '[.builds[]] | all(.success)')
    all_tests_ok=$(echo "$RESULTS_JSON" | jq '[.tests[]] | if length == 0 then true else all(.success) end')
    can_merge=$(echo "$RESULTS_JSON" | jq --argjson b "$all_builds_ok" --argjson t "$all_tests_ok" \
        '.merge.success and $b and $t')

    RESULTS_JSON=$(echo "$RESULTS_JSON" | jq \
        --argjson dur "$duration" --argjson cm "$can_merge" \
        '.duration_seconds = $dur | .can_batch_merge = $cm')
    echo "$RESULTS_JSON"
}

# ── Stack Detection ──────────────────────────────────────────────────

detect_package_manager() {
    local dir="$1"
    if [ -f "$dir/pnpm-lock.yaml" ]; then echo "pnpm"
    elif [ -f "$dir/bun.lockb" ] || [ -f "$dir/bun.lock" ]; then echo "bun"
    elif [ -f "$dir/yarn.lock" ]; then echo "yarn"
    else echo "npm"
    fi
}

# Detect all build/test stacks in the project.
# Each detection returns: name, build_cmd, test_cmd, cwd (relative to verify dir)
detect_stacks() {
    local dir="$1"
    local stacks=()

    # Rust: workspace and single crate build and test identically from the root.
    if [ -f "$dir/Cargo.toml" ]; then
        stacks+=("rust|cargo build --release|cargo test --release|.")
    else
        # Check for Cargo.toml in immediate subdirs (monorepo without workspace)
        for sub in "$dir"/*/Cargo.toml; do
            [ -f "$sub" ] || continue
            local subdir
            subdir=$(dirname "$sub")
            local reldir="${subdir#"$dir"/}"
            stacks+=("rust:$reldir|cargo build --release|cargo test --release|$reldir")
        done
    fi

    # Node.js
    if [ -f "$dir/package.json" ]; then
        local pm
        pm=$(detect_package_manager "$dir")
        local has_build has_test
        has_build=$(jq -r '.scripts.build // empty' "$dir/package.json" 2>/dev/null)
        has_test=$(jq -r '.scripts.test // empty' "$dir/package.json" 2>/dev/null)
        local build_cmd="${pm} run build"
        local test_cmd="${pm} run test"
        [ -z "$has_build" ] && build_cmd=""
        [ -z "$has_test" ] && test_cmd=""
        if [ -n "$build_cmd" ] || [ -n "$test_cmd" ]; then
            stacks+=("node:$pm|${build_cmd}|${test_cmd}|.")
        fi
    fi

    # Go
    if [ -f "$dir/go.mod" ]; then
        stacks+=("go|go build ./...|go test ./...|.")
    fi

    # Python
    if [ -f "$dir/pyproject.toml" ] || [ -f "$dir/setup.py" ] || [ -f "$dir/setup.cfg" ]; then
        local test_cmd="python -m pytest"
        [ -f "$dir/tox.ini" ] && test_cmd="tox"
        stacks+=("python||${test_cmd}|.")
    fi

    # Makefile fallback (only if no other stack detected)
    if [ ${#stacks[@]} -eq 0 ] && [ -f "$dir/Makefile" ]; then
        local has_build has_test
        has_build=$(grep -q '^build:' "$dir/Makefile" 2>/dev/null && echo "yes" || echo "")
        has_test=$(grep -q '^test:' "$dir/Makefile" 2>/dev/null && echo "yes" || echo "")
        local build_cmd="" test_cmd=""
        [ -n "$has_build" ] && build_cmd="make build"
        [ -n "$has_test" ] && test_cmd="make test"
        if [ -n "$build_cmd" ] || [ -n "$test_cmd" ]; then
            stacks+=("make|${build_cmd}|${test_cmd}|.")
        fi
    fi

    printf '%s\n' "${stacks[@]}"
}

# Run a single stack's build and test commands
run_stack() {
    local stack_spec="$1"
    local verify_dir="$2"

    local name build_cmd test_cmd cwd
    IFS='|' read -r name build_cmd test_cmd cwd <<< "$stack_spec"

    local work_dir="$verify_dir"
    [ "$cwd" != "." ] && work_dir="$verify_dir/$cwd"

    # Build
    if [ -n "$build_cmd" ]; then
        local start_time end_time duration output
        start_time=$(date +%s)
        if output=$(cd "$work_dir" && eval "$build_cmd" 2>&1); then
            end_time=$(date +%s)
            duration=$((end_time - start_time))
            RESULTS_JSON=$(echo "$RESULTS_JSON" | jq \
                --arg name "$name" --argjson dur "$duration" \
                '.builds[$name] = {success: true, duration_seconds: $dur, error: null}')
            progress_ok "$name build (${duration}s)"
        else
            end_time=$(date +%s)
            duration=$((end_time - start_time))
            # `grep -m 5` caps the summary and `tr` reads to EOF, so no stage
            # closes on a writer: `| head -5` SIGPIPEs grep, and the 141
            # pipefail puts on this unguarded assignment kills the branch
            # wherever errexit is live (KEN-1143). `|| true` covers a no-match,
            # which is a blank summary and not a failure to record one.
            local error_summary
            error_summary=$(grep -m 5 -E "^error|^Error|FAILED" <<<"$output" | tr '\n' ' ' || true)
            RESULTS_JSON=$(echo "$RESULTS_JSON" | jq \
                --arg name "$name" --argjson dur "$duration" --arg err "$error_summary" \
                '.builds[$name] = {success: false, duration_seconds: $dur, error: $err}')
            add_issue "high" "${name}_build_failed" "$name build failed: $error_summary"
            progress_fail "$name build (${duration}s)"
            return 1
        fi
    fi

    # Test
    if [ -n "$test_cmd" ]; then
        local start_time end_time duration output
        start_time=$(date +%s)
        if output=$(cd "$work_dir" && eval "$test_cmd" 2>&1); then
            end_time=$(date +%s)
            duration=$((end_time - start_time))
            RESULTS_JSON=$(echo "$RESULTS_JSON" | jq \
                --arg name "$name" --argjson dur "$duration" \
                '.tests[$name] = {success: true, duration_seconds: $dur, error: null}')
            progress_ok "$name tests (${duration}s)"
        else
            end_time=$(date +%s)
            duration=$((end_time - start_time))
            # Same SIGPIPE shape as the build branch above, same fix.
            local error_summary
            error_summary=$(grep -m 5 -E "^failures:|FAILED|^error|^FAIL" <<<"$output" | tr '\n' ' ' || true)
            RESULTS_JSON=$(echo "$RESULTS_JSON" | jq \
                --arg name "$name" --argjson dur "$duration" --arg err "$error_summary" \
                '.tests[$name] = {success: false, duration_seconds: $dur, error: $err}')
            add_issue "high" "${name}_tests_failed" "$name tests failed: $error_summary"
            progress_fail "$name tests (${duration}s)"
            return 1
        fi
    fi
}

# ── Stale Worktree Cleanup ───────────────────────────────────────────

cleanup_stale_verifications() {
    for wt in /tmp/gh-verify-*; do
        [ -d "$wt" ] || continue
        if [ "$(find "$wt" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
            git worktree remove "$wt" --force 2>/dev/null || rm -rf "$wt"
        fi
    done
}

# ── Main: Merge Simulation + Build/Test ──────────────────────────────

verify_prs() {
    local pr_nums=("$@")

    if [ ${#pr_nums[@]} -lt 2 ]; then
        jq -n '{mode: "verify", error: "Need at least 2 PRs for verification", can_batch_merge: false}'
        exit 1
    fi

    cleanup_stale_verifications

    START_TIME=$(date +%s)
    TEMP_BRANCH="verify/cross-check-$$"
    VERIFY_DIR="/tmp/gh-verify-$$"

    trap cleanup EXIT INT TERM
    init_results

    RESULTS_JSON=$(echo "$RESULTS_JSON" | jq --argjson order \
        "$(printf '%s\n' "${pr_nums[@]}" | jq -R . | jq -s 'map(tonumber)')" \
        '.merge_order = $order')

    # Phase 1: Create verification worktree
    progress "Creating verification worktree..."

    local default_branch
    default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || true
    default_branch="${default_branch:-main}"

    git fetch origin "$default_branch" --quiet 2>/dev/null || true

    if ! git worktree add "$VERIFY_DIR" -b "$TEMP_BRANCH" "origin/$default_branch" --quiet 2>/dev/null; then
        add_issue "high" "worktree_failed" "Failed to create verification worktree"
        output_results
        exit 1
    fi

    cd "$VERIFY_DIR"
    progress_ok "Worktree created"

    # Phase 2: Merge PRs sequentially
    progress "Merging PRs sequentially..."

    local all_merged=true
    for pr_num in "${pr_nums[@]}"; do
        echo -e "  Merging PR #$pr_num..." >&2

        if ! gh pr checkout "$pr_num" --detach 2>/dev/null; then
            add_issue "high" "checkout_failed" "Failed to checkout PR #$pr_num"
            all_merged=false
            break
        fi

        if ! git merge FETCH_HEAD --no-edit -m "Merge PR #$pr_num for verification" 2>/dev/null; then
            # Captured whole, then windowed in-shell, for the reason the two
            # summary branches above carry (KEN-1143): `| head -10` closing on
            # git leaves a 141 on an assignment errexit takes the branch down
            # for, and this branch is the one that reports the conflict.
            local conflicts conflict_files diff_status=0
            conflicts=$(git diff --name-only --diff-filter=U 2>/dev/null) || diff_status=$?
            if [ "$diff_status" -gt 1 ]; then
                conflict_files="could not list conflicted paths (git diff exited $diff_status)"
            else
                conflict_files=$(head -n 10 <<<"$conflicts" | tr '\n' ', ' | sed 's/,$//')
            fi
            add_issue "high" "merge_conflict" "PR #$pr_num conflicts: $conflict_files" "Merge earlier PRs first, then rebase #$pr_num"
            git merge --abort 2>/dev/null || true
            all_merged=false
            break
        fi

        RESULTS_JSON=$(echo "$RESULTS_JSON" | jq --argjson num "$pr_num" '.prs += [{number: $num, merged: true}]')
        progress_ok "PR #$pr_num merged"
    done

    update_result '.merge.success' "$all_merged"

    if [ "$all_merged" != "true" ]; then
        echo -e "\n${RED}Merge simulation failed — skipping build/test${NC}" >&2
        output_results
        exit 0
    fi

    # Phase 3: Detect and run stacks
    progress "Detecting project stacks..."

    # Check for explicit override first
    if [ -n "${GH_VERIFY_CMD:-}" ]; then
        progress_ok "Using GH_VERIFY_CMD override"
        local start_time end_time duration
        start_time=$(date +%s)
        if output=$(eval "$GH_VERIFY_CMD" 2>&1); then
            end_time=$(date +%s)
            duration=$((end_time - start_time))
            RESULTS_JSON=$(echo "$RESULTS_JSON" | jq --argjson dur "$duration" \
                '.builds["custom"] = {success: true, duration_seconds: $dur, error: null}')
            progress_ok "Custom verify (${duration}s)"
        else
            end_time=$(date +%s)
            duration=$((end_time - start_time))
            local error_summary
            error_summary=$(echo "$output" | tail -5 | tr '\n' ' ')
            RESULTS_JSON=$(echo "$RESULTS_JSON" | jq --argjson dur "$duration" --arg err "$error_summary" \
                '.builds["custom"] = {success: false, duration_seconds: $dur, error: $err}')
            add_issue "high" "custom_verify_failed" "Custom verify failed: $error_summary"
            progress_fail "Custom verify (${duration}s)"
        fi
        output_results
        exit 0
    fi

    # Check for project-level verify.sh
    if [ -f "$VERIFY_DIR/verify.sh" ]; then
        progress_ok "Found verify.sh in project root"
        local start_time end_time duration
        start_time=$(date +%s)
        if output=$(cd "$VERIFY_DIR" && bash verify.sh 2>&1); then
            end_time=$(date +%s)
            duration=$((end_time - start_time))
            RESULTS_JSON=$(echo "$RESULTS_JSON" | jq --argjson dur "$duration" \
                '.builds["custom"] = {success: true, duration_seconds: $dur, error: null}')
            progress_ok "verify.sh (${duration}s)"
        else
            end_time=$(date +%s)
            duration=$((end_time - start_time))
            local error_summary
            error_summary=$(echo "$output" | tail -5 | tr '\n' ' ')
            RESULTS_JSON=$(echo "$RESULTS_JSON" | jq --argjson dur "$duration" --arg err "$error_summary" \
                '.builds["custom"] = {success: false, duration_seconds: $dur, error: $err}')
            add_issue "high" "verify_script_failed" "verify.sh failed: $error_summary"
            progress_fail "verify.sh (${duration}s)"
        fi
        output_results
        exit 0
    fi

    # Auto-detect
    local stacks
    stacks=$(detect_stacks "$VERIFY_DIR")

    if [ -z "$stacks" ]; then
        progress_skip "No build system detected — merge-only verification"
        output_results
        exit 0
    fi

    local stack_names=()
    while IFS= read -r stack_spec; do
        [ -z "$stack_spec" ] && continue
        local name
        name="${stack_spec%%|*}"
        stack_names+=("$name")
    done <<< "$stacks"

    RESULTS_JSON=$(echo "$RESULTS_JSON" | jq --argjson stacks "$(printf '%s\n' "${stack_names[@]}" | jq -R . | jq -s .)" \
        '.detected_stacks = $stacks')

    progress_ok "Detected: ${stack_names[*]}"

    # Phase 4: Build and test each stack
    progress "Building and testing..."

    while IFS= read -r stack_spec; do
        [ -z "$stack_spec" ] && continue
        run_stack "$stack_spec" "$VERIFY_DIR" || true  # Continue other stacks on failure
    done <<< "$stacks"

    echo -e "\n${GREEN}✓ Verification complete${NC}" >&2
    output_results
}

# Entry point. Guarded the way commands/ci-logs.sh guards its own, so a suite can
# source this file for one function instead of driving verify_prs end to end;
# pr-cross-check.sh only ever execs it, so dispatch is unchanged.
#
# The sourcing contract: this file sets `errexit`, `nounset` and `pipefail` on
# the sourcing shell, and at source time resolves PROJECT_ROOT through git and
# assigns RESULTS_JSON, VERIFY_DIR, TEMP_BRANCH, START_TIME, STEP, TOTAL_STEPS
# and RED/GREEN/YELLOW/BLUE/NC. Beyond those, the functions keep no `local`
# discipline, so a sourcer must not rely on ANY unprefixed name surviving a
# call to one — including ordinary lowercase names a driver reaches for.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        verify_prs)
            shift
            verify_prs "$@"
            ;;
        *)
            echo "Usage: verify-lib.sh verify_prs [PR_NUM...]" >&2
            exit 1
            ;;
    esac
fi
