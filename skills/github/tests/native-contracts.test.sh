#!/usr/bin/env bash
# Surface: real request-pipe closure and bounded native child cleanup.
# Inputs: pr-merge.test.sh, pr-view.test.sh and their script/fixture inputs.
# The full Linux suites call these same cases and assertions.
set -euo pipefail
TEST_DIR="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)"
fail=0
for suite in pr-merge pr-view; do
  if ! "$BASH" "$TEST_DIR/$suite.test.sh" --native; then
    printf 'native-contracts: failed=%s\n' "$suite" >&2
    fail=1
  fi
done
exit "$fail"
