#!/usr/bin/env bash
# fixtures/tier-model/kendex answers model words the way the kendex on PATH
# does: for claude, codex and copilot, what lib/overseer-launch.sh §
# ol_model_class reads through each, the class, the model a launch runs, the
# old-id status and kendex's warning, must match word for word, so the suites
# that classify through the fixture judge the real answers. CI builds that
# kendex from this checkout, so the answers are core's as this tree holds them.
# A project `model-classes.standard` override changes neither answer: claude's
# family alias comes from the rank form, which applies no override, and codex
# takes the harness default (tmp/proposal-KEN-3372-core-word-answer.md tracks
# the core answer that would apply it).
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
# class override stands between core and the answer, then from a project
# whose kendex.toml overrides the standard class.
mkdir -p "$TMP_ROOT/home" "$TMP_ROOT/cwd" "$TMP_ROOT/project/.claude"
printf 'schema = 7\n[model-classes]\nstandard = "openai/gpt-6.2-sol"\n' >"$TMP_ROOT/project/kendex.toml"
answers() { # BIN_DIR_OR_EMPTY DIR HARNESS WORD...
  # shellcheck disable=SC2016 # expanded by the inner shell
  (cd "$2" && HOME="$TMP_ROOT/home" XDG_CONFIG_HOME="$TMP_ROOT/home/.config" PATH="${1:+$1:}$PATH" bash -c '
    set -euo pipefail
    source "$1"
    harness="$2"
    shift 2
    for word in "$@"; do
      rc=0
      ol_model_class "$harness" "$word" 2>/dev/null || rc=$?
      printf "%s|%s|%s|%s|%s\n" "$word" "$rc" "$OL_CLASS" "$OL_CLASS_MODEL" "$OL_CLASS_WARNING"
    done' _ "$LIB" "$3" "${@:4}")
}
WORDS=(top standard light fast Opus fable SONNET haiku claude-opus-5-5 gpt-6.1-sol 'opus[1m]' codex:opus)
for dir in cwd project; do
  for harness in claude codex copilot; do
    real="$(answers "" "$TMP_ROOT/$dir" "$harness" "${WORDS[@]}")" || { fail "real kendex answers $harness in $dir"; continue; }
    fixture="$(answers "$FIXTURE" "$TMP_ROOT/$dir" "$harness" "${WORDS[@]}")" || { fail "the fixture answers $harness in $dir"; continue; }
    assert_eq "$fixture" "$real" "the fixture's $harness answers are the real kendex's in $dir"
  done
done
# The ruled answers themselves, which the fixture and kendex agreeing on
# another answer would not catch: claude's standard class runs Opus under the
# override, codex's the native default, and an exact id stands as written.
assert_eq "$(answers "" "$TMP_ROOT/project" claude standard claude-opus-5-5 | cut -d'|' -f1-4)" \
  $'standard|0|standard|opus\nclaude-opus-5-5|2||claude-opus-5-5' \
  "claude standard runs opus under a standard override, and an exact id stands"
assert_eq "$(answers "" "$TMP_ROOT/project" codex standard | cut -d'|' -f1-4)" 'standard|0|standard|' \
  "codex standard runs the native default under a standard override"

# Control: a fixture copy with one alias changed must fail the comparison.
mkdir -p "$TMP_ROOT/mutant"
cp "$FIXTURE/kendex" "$TMP_ROOT/mutant/kendex"
python3 - "$TMP_ROOT/mutant/kendex" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
old = 'aliases=(fable opus sonnet haiku)'
assert text.count(old) == 1
path.write_text(text.replace(old, 'aliases=(fable opusx sonnet haiku)'))
PY
if [[ "$(answers "$TMP_ROOT/mutant" "$TMP_ROOT/cwd" claude standard)" != "$(answers "" "$TMP_ROOT/cwd" claude standard)" ]]; then
  pass "control: a changed fixture alias fails the comparison"
else
  fail "control: a changed fixture alias still matches the real kendex"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
