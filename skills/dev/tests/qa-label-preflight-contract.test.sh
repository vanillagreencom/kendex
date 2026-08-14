#!/usr/bin/env bash
# Contract test for the QA-signal step: signals derive from the final code,
# live in the completion artifact, involve no tracker mutation, and are never
# silently dropped.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW="$TEST_DIR/../workflows/dev-implement.md"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

require_text() {
    local needle="$1" description="$2"
    if ! grep -Fq -- "$needle" "$WORKFLOW"; then
        fail "$description"
    fi
    printf 'ok - %s\n' "$description"
}

require_absent() {
    local needle="$1" description="$2"
    if grep -Fq -- "$needle" "$WORKFLOW"; then
        fail "$description"
    fi
    printf 'ok - %s\n' "$description"
}

require_text '`needs-safety-audit`' 'safety QA signal remains documented'
require_text '`needs-perf-test`' 'performance QA signal remains documented'
require_text '`needs-review`' 'review QA signal remains documented'
require_text 'not a tracker' 'signals are recorded in the artifact, not the tracker'
require_text 'never silently dropped' 'workflow prohibits silently dropping a signal'
require_text '`none` is an explicit answer' 'none is an evaluated answer, not a default'
require_text 'does not take `needs-perf-test`' 'feature-gated work stays exempt from the perf signal'
require_absent 'label-add [PR_OR_ISSUE] [QA_LABEL] --required' 'the tracker label mutation is retired from the QA step'

printf 'all pass\n'
