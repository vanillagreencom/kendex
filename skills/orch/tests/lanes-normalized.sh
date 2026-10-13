#!/usr/bin/env bash
# Surface: normalized usage-cache records. Inputs: the production lanes reader
# and a counting endpoint. The helper controls login and reset failures.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_TMP="${TMPDIR:-$TEST_DIR/../../../tmp}"
mkdir -p "$SUITE_TMP"
TMP_ROOT="$(mktemp -d "$SUITE_TMP/lanes-normalized.XXXXXX")" || { printf '%s\n' 'lanes-normalized: scratch=mktemp-failed' >&2; exit 1; }
[[ -d "$TMP_ROOT" && ! -L "$TMP_ROOT" ]] || { printf '%s\n' 'lanes-normalized: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { printf '%s\n' 'lanes-normalized: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
export COST_CLAIM_PID="${BASHPID:-$$}"
python3 -B "$TEST_DIR/lib/lanes-normalized-cases.py" "$TMP_ROOT" "$TEST_DIR/../scripts/lanes" "$BASH" "${1:-}"
