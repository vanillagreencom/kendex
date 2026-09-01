# shellcheck shell=bash
# Resolves SEALED: the committed refusal fixture at tools/tests/lib/sealed-bin.
# A suite appends it to PATH AFTER its own stub directory — the stubs answer
# while they exist, the seal refuses once the temp tree behind them is gone.
# Which names it covers, and why, are in that directory's `refuse`.
#
# Sourced rather than repeated. Three suites carried byte-identical copies of
# this block, and a rule spelled once per adopter is a rule the next adopter
# gets to forget.
#
# Relative first, so an exported tree that is no git checkout still runs these
# suites — the mutation harness extracts one with git archive. git's own failure
# must not become the caller's: in a non-git tree the substitution exits 128,
# and under set -e that would end the run before the named error below printed.
SEALED="$(cd "${BASH_SOURCE[0]%/*}/../../../.." && pwd)/tools/tests/lib/sealed-bin"
if [[ ! -x "$SEALED/gh" ]]; then
  SEALED="$(git -C "${BASH_SOURCE[0]%/*}" rev-parse --show-toplevel 2>/dev/null || true)/tools/tests/lib/sealed-bin"
fi
[[ -x "$SEALED/gh" ]] || { echo "${0##*/}: sealed-bin fixture is missing: $SEALED" >&2; exit 1; }
