#!/usr/bin/env bash
# Contract test for the QA-signal step: signals derive from the final code,
# live in the completion artifact, involve no tracker mutation, and are never
# silently dropped.
#
# What this pins is the three QA signal VALUES and the absence of the retired
# tracker mutation. review-bots.md: a token pin establishes that a structural
# element is present, never that a behavioral claim written in prose is true.
# So these rules have no lint: that signals are recorded in the artifact and
# not the tracker, that a triggered signal is never silently dropped, that
# `none` is an explicit answer rather than a default, and that feature-gated
# work is exempt from the perf signal.
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
require_absent 'label-add [PR_OR_ISSUE] [QA_LABEL] --required' 'the tracker label mutation is retired from the QA step'

printf 'all pass\n'
