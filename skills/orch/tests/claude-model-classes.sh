#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"
ROOT="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)" || exit 1
PLUGIN="$ROOT/skills/orch/scripts/claude-model-classes"
if ! command -v claude >/dev/null 2>&1; then
  printf 'claude-model-classes: native-kit=unsupported\n'
  printf 'pass: %s fail: %s\n' "$PASS" "$FAIL"
  exit 0
fi
version="$(claude --version)" || exit 1
printf 'claude-model-classes: version=%s\n' "$version"
claude plugin validate --strict "$PLUGIN"
claude plugin test "$PLUGIN"
pass 'native callback structure and behavior'
printf 'pass: %s fail: %s\n' "$PASS" "$FAIL"
