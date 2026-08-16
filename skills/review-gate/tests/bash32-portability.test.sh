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
# shard. Discovery is `find`, and the scan below is plain `grep -nE` one
# file at a time: `--include`/`--exclude`/`-H` are all outside POSIX grep,
# and a lint whose job is protecting BSD userland must not itself depend on
# an extension it cannot exercise in CI.
sh_files=()
while IFS= read -r f; do
  sh_files[${#sh_files[@]}]="$f"
done < <(find "$SCRIPTS_DIR" "$TEST_DIR" -type f -name '*.sh' | LC_ALL=C sort)
if [ "${#sh_files[@]}" -eq 0 ]; then
  echo "FAIL: no shell files found under $SCRIPTS_DIR or $TEST_DIR" >&2
  exit 1
fi

nl='
'
violations=""
for f in ${sh_files[@]+"${sh_files[@]}"}; do
  # This file is skipped: it carries every pattern above as data.
  if [ "${f##*/}" = "$SELF" ]; then
    continue
  fi
  hits="$(grep -nE "$PATTERN" "$f" || true)"
  if [ -n "$hits" ]; then
    violations="$violations$(printf '%s\n' "$hits" | sed "s|^|$f:|")$nl"
  fi
done
if [[ -n "$violations" ]]; then
  echo "Bash 4+ constructs found in review-gate scripts/tests (must run under Bash 3.2):" >&2
  printf '%s' "$violations" >&2
  exit 1
fi

# Syntax-check every shipped script and suite while we are here — the same
# discovered set, this file included.
fail=0
for f in ${sh_files[@]+"${sh_files[@]}"}; do
  if ! bash -n "$f"; then
    echo "FAIL: bash -n $f"
    fail=1
  fi
done
[ "$fail" -eq 0 ] || exit 1

echo "pass: bash32-portability"
