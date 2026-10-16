#!/usr/bin/env bash
# fixtures/tier-model/kendex answers the class table the way the kendex on
# PATH does: for claude, codex and copilot, the ladder
# lib/overseer-launch.sh § ol_class_ladder reads through each must match
# rank for rank, so the suites that read classes through the fixture judge
# the real table's rows. CI builds that kendex from this checkout, so the
# rows are TIERS (crates/core/src/harness/models.rs) as this tree holds it.
#
# No kendex on PATH skips the suite unless ORCH_REQUIRE_KENDEX is set.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/lib/assertions.sh"
if ! command -v kendex >/dev/null 2>&1; then
  if [[ -n "${ORCH_REQUIRE_KENDEX:-}" ]]; then
    echo 'tier-model-fixture: kendex is not on PATH and ORCH_REQUIRE_KENDEX is set' >&2
    exit 2
  fi
  printf 'tier-model-fixture: kendex=absent\n'
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  exit 0
fi
TMP_ROOT="$(mktemp -d)" || { echo 'tier-model-fixture: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "tier-model-fixture: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'tier-model-fixture: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
LIB="$TEST_DIR/../scripts/lib/overseer-launch.sh"
FIXTURE="$TEST_DIR/fixtures/tier-model"
# The fixture answering as the real kendex would compare it with itself.
if [[ "$(command -v kendex)" -ef "$FIXTURE/kendex" ]]; then
  echo 'tier-model-fixture: the kendex on PATH is the fixture itself' >&2
  exit 2
fi

# Read from an empty directory under an empty home, so no project or personal
# class override stands between the table and the answer.
mkdir -p "$TMP_ROOT/home" "$TMP_ROOT/cwd"
ladder() { # BIN_DIR_OR_EMPTY HARNESS
  # shellcheck disable=SC2016 # expanded by the inner shell
  (cd "$TMP_ROOT/cwd" && HOME="$TMP_ROOT/home" XDG_CONFIG_HOME="$TMP_ROOT/home/.config" PATH="${1:+$1:}$PATH" bash -c 'set -euo pipefail; source "$1"; ol_class_ladder "$2"; printf "%s" "$OL_LADDER"' _ "$LIB" "$2")
}

for harness in claude codex copilot; do
  real="$(ladder "" "$harness")" || { fail "real kendex answers the $harness ladder"; continue; }
  fixture="$(ladder "$FIXTURE" "$harness")" || { fail "the fixture answers the $harness ladder"; continue; }
  assert_eq "$fixture" "$real" "the fixture's $harness ladder is the real table's"
  # A ladder read that stopped at its first rank would compare one class alone.
  [[ "$(grep -c . <<<"$real")" -ge 2 ]] && pass "the real $harness ladder has rows past the first" \
    || fail "the real $harness ladder has rows past the first"
done

# Control: a fixture copy with one model changed must fail the comparison.
mkdir -p "$TMP_ROOT/mutant"
cp "$FIXTURE/kendex" "$TMP_ROOT/mutant/kendex"
python3 - "$TMP_ROOT/mutant/kendex" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
old = 'gpt-6.1-sol'
assert text.count(old) == 1
path.write_text(text.replace(old, 'gpt-6.1-solx'))
PY
if [[ "$(ladder "$TMP_ROOT/mutant" codex)" != "$(ladder "" codex)" ]]; then
  pass "control: a changed fixture row fails the comparison"
else
  fail "control: a changed fixture row still matches the real table"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
