#!/usr/bin/env bash
# fixtures/tier-model/kendex answers model words the way the kendex on PATH
# does: `kendex tier-model HARNESS --model WORD --json` in the two forms a
# launch asks it, Claude's managed read with no runtime context and the
# unsupported-list runtime context every other read carries, must read the
# same, word for word, in each field the reader of the answer acts on, so the
# suites that classify through the fixture judge the real answers. CI builds
# that kendex from this checkout, so the answers are core's as this tree
# holds them. Claude consumes the managed alias after the project override.
# A different provider refuses. Codex and Copilot retain the runtime default
# decision.
#
# No kendex on PATH skips the suite unless ORCH_REQUIRE_KENDEX is set.
# Inputs: skills/agent-runtime/, skills/agent-runtime/scripts/, skills/change-scope/references/,
# skills/change-scope/scripts/, skills/communication/references/reports.md, skills/mailbox/scripts/,
# skills/orch/runtime/, skills/orch/scripts/, skills/orch/tests/.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/lib/assertions.sh"
if ! command -v kendex >/dev/null 2>&1; then
  if [[ -n "${ORCH_REQUIRE_KENDEX:-}" ]]; then
    echo 'tier-model-fixture: kendex is not on PATH and ORCH_REQUIRE_KENDEX is set' >&2
    exit 2
  fi
  printf 'rowless: tier-model-fixture kendex=absent\n'
  exit 0
fi
TMP_ROOT="$(mktemp -d)" || { echo 'tier-model-fixture: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "tier-model-fixture: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'tier-model-fixture: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
FIXTURE="$TEST_DIR/fixtures/tier-model"
# The fixture answering as the real kendex would compare it with itself.
if [[ "$(command -v kendex)" -ef "$FIXTURE/kendex" ]]; then
  echo 'tier-model-fixture: the kendex on PATH is the fixture itself' >&2
  exit 2
fi

# Read from an empty directory under an empty home, so no project or personal
# class override stands between core and the answer, then from a project
# whose kendex.toml overrides the standard class.
mkdir -p "$TMP_ROOT/home" "$TMP_ROOT/cwd" "$TMP_ROOT/anthropic/.claude" "$TMP_ROOT/openai/.claude"
printf 'schema = 7\n[model-classes]\nstandard = "anthropic/claude-haiku-5-5"\n' >"$TMP_ROOT/anthropic/kendex.toml"
printf 'schema = 7\n[model-classes]\nstandard = "openai/gpt-6.2-sol"\n' >"$TMP_ROOT/openai/kendex.toml"
# answers BIN_DIR_OR_EMPTY DIR HARNESS FORM WORD...: one line per WORD,
# `word|exit` where kendex refused it, else
# `word|exit|tag|class|selector|unverified|old_id|warning`: the request's tag
# and class; for a class, the native selector a managed read launches, whether
# a runtime-context read left the model list unverified, and the warning; for
# an exact id, whether Claude deprecates it. FORM is `managed`, the read with
# no runtime context, or `context`, the read under the unsupported model list.
answers() {
  local override="" word rc out context="" fields
  local -a form=()
  case "${2##*/}" in
    anthropic) override=anthropic/claude-haiku-5-5 ;;
    openai) override=openai/gpt-6.2-sol ;;
  esac
  if [[ "$4" == context ]]; then
    printf -v context '{"protocol":"model-resolution-v1","harness":"%s","account":"unpicked","host":"unpicked","providers":[],"currentProvider":null,"models":{"tag":"unsupported","source":"orch-launch"},"default":{"tag":"native-default"},"capacity":[],"rejected":[]}' "$3"
    form=(--runtime-context-json "$context")
  fi
  for word in "${@:5}"; do
    rc=0
    out="$(cd "$2" && HOME="$TMP_ROOT/home" XDG_CONFIG_HOME="$TMP_ROOT/home/.config" KENDEX_TEST_STANDARD_OVERRIDE="$override" \
      PATH="${1:+$1:}$PATH" kendex tier-model "$3" --model "$word" --json ${form[@]+"${form[@]}"} 2>/dev/null)" || rc=$?
    if (( rc != 0 )); then
      printf '%s|%s\n' "$word" "$rc"
      continue
    fi
    fields="$(jq -r --arg harness "$3" --arg form "$4" '
      def coded($code): any(.resolution.diagnostics[]?; .code == $code);
      if .protocol == "model-resolution-v1" and (.request.tag | type) == "string" then
        if .request.tag == "class" then
          [.request.tag, .request.class // "",
           (if $form == "managed" then .resolution.native_selector // "" else "" end),
           ($form == "context" and .resolution.tag == "harness-default" and coded("model-availability-unknown")),
           false, .warning // ""]
        else [.request.tag, "", "", false, ($harness == "claude" and coded("old-id")), ""] end
        | map(tostring) | join("|")
      else "no-answer" end' <<<"$out" 2>/dev/null)" || fields=unparsed
    printf '%s|%s|%s\n' "$word" "$rc" "$fields"
  done
}
WORDS=(top standard light fast Opus fable SONNET haiku claude-opus-5-5 gpt-6.1-sol codex:opus)
for dir in cwd anthropic openai; do
  for read in claude:managed claude:context codex:context copilot:context; do
    harness="${read%%:*}" form="${read#*:}"
    real="$(answers "" "$TMP_ROOT/$dir" "$harness" "$form" "${WORDS[@]}")" || { fail "real kendex answers $read in $dir"; continue; }
    fixture="$(answers "$FIXTURE" "$TMP_ROOT/$dir" "$harness" "$form" "${WORDS[@]}")" || { fail "the fixture answers $read in $dir"; continue; }
    assert_eq "$fixture" "$real" "the fixture's $read answers are the real kendex's in $dir"
  done
done
# The ruled answers themselves, which the fixture and kendex agreeing on
# another answer would not catch: Claude's standard class runs Haiku under an
# Anthropic override; another provider refuses. Codex's runs the native
# default, its model list unverified; each class's warning names the model it
# runs; an exact id stands as written, deprecated on claude alone; the
# runtime-context read of a Claude word classifies it whatever the override.
selected() { sed -n 's/^\([^|]*\)|.* selected=\([^ ]*\) .*/\1 \2/p'; }
assert_eq "$(answers "" "$TMP_ROOT/anthropic" claude managed standard claude-opus-5-5 | cut -d'|' -f1-7)" \
  $'standard|0|class|standard|haiku|false|false\nclaude-opus-5-5|0|exact|||false|true' \
  "claude standard runs the overridden managed alias, and an exact id stands, deprecated"
assert_eq "$(answers "" "$TMP_ROOT/openai" claude managed standard)" 'standard|1' \
  "a cross-provider override refuses the Claude class"
assert_eq "$(answers "" "$TMP_ROOT/openai" codex context standard gpt-6.1-sol | cut -d'|' -f1-7)" \
  $'standard|0|class|standard||true|false\ngpt-6.1-sol|0|exact|||false|false' \
  "codex standard runs the native default under a standard override, and a codex exact id stands"
assert_eq "$(answers "" "$TMP_ROOT/anthropic" claude managed standard | selected)|$(answers "" "$TMP_ROOT/openai" codex context standard | selected)" \
  'standard haiku|standard native-default' \
  "a class's warning names the model it runs"
assert_eq "$(answers "" "$TMP_ROOT/openai" claude context opus | cut -d'|' -f1-4)" 'opus|0|class|standard' \
  "the runtime-context read classifies a Claude word despite a cross-provider class override"

# Control: a fixture copy with one alias changed must fail the comparison.
mkdir -p "$TMP_ROOT/mutant"
cp "$FIXTURE/kendex" "$TMP_ROOT/mutant/kendex"
python3 - "$TMP_ROOT/mutant/kendex" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
old = 'standard) selector=opus ;;'
assert text.count(old) == 1
changed = text.replace(old, 'standard) selector=opusx ;;')
assert changed != text
path.write_text(changed)
PY
if [[ "$(answers "$TMP_ROOT/mutant" "$TMP_ROOT/cwd" claude managed standard)" != "$(answers "" "$TMP_ROOT/cwd" claude managed standard)" ]]; then
  pass "control: a changed fixture alias fails the comparison"
else
  fail "control: a changed fixture alias still matches the real kendex"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
