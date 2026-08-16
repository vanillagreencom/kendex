#!/usr/bin/env bash
# The review-gate scripts run on consumer CI images and on macOS system Bash
# 3.2, so shipped scripts may not use Bash 4+ builtins or syntax
# (mapfile/readarray, associative arrays, automatic FD-allocation
# redirections, case-conversion expansions). The suites that drive those
# scripts are scanned too: a Bash 4 construct breaks a test run on macOS
# system bash exactly as it breaks a script, and CI is Linux/Bash 5, so
# nothing else catches it.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"
SELF="${BASH_SOURCE[0]##*/}"

PATTERN='mapfile|readarray|declare -A|declare -gA|local -A'
PATTERN="$PATTERN"'|(^|[^$])\{[A-Za-z_][A-Za-z0-9_]*\}[<>]'
PATTERN="$PATTERN"'|\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,,|\^\^)'
# BSD dirname/basename can reject the `--` end-of-options marker; use
# parameter expansion (or a path that cannot start with '-') instead.
PATTERN="$PATTERN"'|(dirname|basename) +--( |$)'
# `"${@}"` is NOT `"$@"`: with no positional parameters and `set -u`, Bash
# 3.2.57 aborts on the braced spelling with `@: unbound variable` while the
# bare one expands to nothing. Same guard shape as an empty array —
# `${@+"$@"}` — or just write `"$@"`.
PATTERN="$PATTERN"'|\$\{@\}'

# Shell files only — a fixture or data file under either directory is not
# code this lint speaks for, and a false positive here reds a required
# shard. This file is skipped too: it carries every pattern above as data.
violations="$(grep -rnE --include='*.sh' --exclude="$SELF" "$PATTERN" "$SCRIPTS_DIR" "$TEST_DIR" || true)"
if [[ -n "$violations" ]]; then
  echo "Bash 4+ constructs found in review-gate scripts/tests (must run under Bash 3.2):" >&2
  printf '%s\n' "$violations" >&2
  exit 1
fi

# Syntax-check every shipped script and suite while we are here.
fail=0
for f in "$SCRIPTS_DIR"/*.sh "$SCRIPTS_DIR"/lib/*.sh "$TEST_DIR"/*.sh; do
  if ! bash -n "$f"; then
    echo "FAIL: bash -n $f"
    fail=1
  fi
done
[ "$fail" -eq 0 ] || exit 1

echo "pass: bash32-portability"
