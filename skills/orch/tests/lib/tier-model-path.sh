# shellcheck shell=bash
# Puts fixtures/tier-model first on PATH, exported, for a suite whose launches
# classify model words: `kendex tier-model` then answers as kendex does
# whether or not a kendex is installed, and every other kendex call reaches
# the kendex the suite had. tier-model-fixture.sh holds the answers to a real
# kendex. Sourced, never run.
PATH="$(cd "${BASH_SOURCE[0]%/*}/../fixtures/tier-model" && pwd):$PATH" || exit 1
export PATH
