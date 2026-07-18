#!/usr/bin/env bash
# Regression test for the reviewer skill's backtick-search guidance (vstack#668).
# During an orch review cycle, reviewer-doc ran a read-only rg search whose
# pattern contained a literal backtick; the harness command-shape guard rejected
# the command before execution — a backtick anywhere in a command reads as
# command-substitution shape, and inside double quotes the substitution would be
# real. The rejecting guard is harness-side, not a vstack hook, so the fix is
# guidance: SKILL.md § Harness-Safe Shell prescribes the `\x60` hex-escape
# pattern shape, which matches a backtick without one appearing in the command.
#
# Three parts:
#   a. Doc — SKILL.md must prescribe the `\x60` shape (example line and the
#      `[\x60]` bracket-expression form), and no fenced ```bash / ```sh block in
#      the reviewer docs may contain a literal backtick byte. This check is
#      deliberately byte-level, unlike the quote-stripping harness-safe-shell
#      lint: coarse shape classifiers flag the byte regardless of quoting, so
#      prescribed commands must not contain one at all.
#   b. Behavioral — the prescribed '\x60...\x60' pattern must match
#      backtick-bearing text exactly like the literal-backtick pattern would,
#      proving it is a drop-in replacement with zero result drift.
#   c. Hook passthrough — vstack's own PreToolUse:Bash hooks must pass both the
#      incident shape and the prescribed shape (exit 0); they were empirically
#      cleared as the rejecting guard and must never become it. The teeth stay:
#      block-bare-cd still rejects a genuine bare `cd` with exit 2.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

# scan_backtick_bytes <file>
# Emits "file:lineno: line" for every literal backtick byte inside a fenced
# ```bash / ```sh block. Prose and inline code are excluded (the guidance text
# itself necessarily mentions backticks), but command blocks must be clean even
# inside quotes — see the byte-level rationale in the header.
scan_backtick_bytes() {
  awk -v f="$1" '
    /^[[:space:]]*```/ {
      if (infence == 0) {
        infence = 1
        lang = $0
        sub(/^[[:space:]]*```/, "", lang)
        gsub(/[[:space:]]/, "", lang)
        iscmd = (lang == "bash" || lang == "sh") ? 1 : 0
      } else {
        infence = 0
        iscmd = 0
      }
      next
    }
    (infence && iscmd && index($0, "`") > 0) { printf "%s:%d: %s\n", f, NR, $0 }
  ' "$1"
}

echo "=== reviewer backtick-search guidance ==="

# --- Part a: doc -----------------------------------------------------------

# a.1 — the prescribed example command must be present verbatim.
if grep -qF "rg -n '\\x60vstack refresh\\x60' skills/" "$SKILL_DIR/SKILL.md"; then
  pass "SKILL.md prescribes the \\x60 hex-escape example command"
else
  fail "SKILL.md is missing the prescribed \\x60 example command"
fi

# a.2 — the bracket-expression form must be documented.
if grep -qF '[\x60]' "$SKILL_DIR/SKILL.md"; then
  pass "SKILL.md documents the [\\x60] bracket-expression form"
else
  fail "SKILL.md is missing the [\\x60] bracket-expression form"
fi

# a.3 — no fenced command block in the reviewer docs carries a backtick byte.
DOCS=("$SKILL_DIR/SKILL.md" "$SKILL_DIR"/workflows/*.md)
offenders=""
for doc in "${DOCS[@]}"; do
  out="$(scan_backtick_bytes "$doc")"
  [ -n "$out" ] && offenders="$offenders$out"$'\n'
done
if [ -z "$offenders" ]; then
  pass "reviewer command blocks contain no literal backtick bytes"
else
  fail "literal backtick bytes found in reviewer command blocks:"
  printf '%s' "$offenders" | sed 's/^/          /'
fi

# a.4 — the byte scan has teeth: an injected backtick in a fenced bash block
# must be flagged even when single-quoted (quoting does not clear the byte).
SCRATCH="$TMP_ROOT/inject-backtick.md"
cp "$SKILL_DIR/SKILL.md" "$SCRATCH"
printf '\n```bash\nrg -n '\''`vstack refresh`'\'' skills/\n```\n' >> "$SCRATCH"
if [ -n "$(scan_backtick_bytes "$SCRATCH")" ]; then
  pass "byte scan flags an injected single-quoted backtick in a command block"
else
  fail "byte scan MISSED an injected backtick (no teeth)"
fi

# --- Part b: behavioral ----------------------------------------------------

if command -v rg > /dev/null 2>&1; then
  FIXTURE="$TMP_ROOT/fixture.md"
  printf 'Run `vstack refresh` after install.\nNo inline code on this line.\n' > "$FIXTURE"

  ESCAPED_PATTERN='\x60vstack refresh\x60'
  LITERAL_PATTERN='`vstack refresh`'
  set +e
  escaped_out="$(rg -n "$ESCAPED_PATTERN" "$FIXTURE")"
  escaped_code=$?
  literal_out="$(rg -n "$LITERAL_PATTERN" "$FIXTURE")"
  literal_code=$?
  class_out="$(rg -n '[\x60]' "$FIXTURE")"
  class_code=$?
  set -e

  if [ "$escaped_code" -eq 0 ] && [ "${escaped_out%%:*}" = "1" ]; then
    pass "'\\x60...\\x60' pattern matches the backtick-bearing line"
  else
    fail "'\\x60...\\x60' pattern did not match (code=$escaped_code, out='$escaped_out')"
  fi

  if [ "$literal_code" -eq 0 ] && [ "$escaped_out" = "$literal_out" ]; then
    pass "escaped and literal-backtick patterns return identical matches (drop-in replacement)"
  else
    fail "escaped/literal pattern drift (escaped='$escaped_out', literal='$literal_out')"
  fi

  if [ "$class_code" -eq 0 ] && [ "${class_out%%:*}" = "1" ]; then
    pass "'[\\x60]' bracket expression matches the backtick-bearing line only"
  else
    fail "'[\\x60]' bracket expression did not match line 1 (code=$class_code, out='$class_out')"
  fi
else
  pass "rg not installed — behavioral checks skipped"
fi

# --- Part c: hook passthrough ----------------------------------------------

HOOKS_DIR="$(cd "$SKILL_DIR/../.." && pwd)/hooks"
if [ -d "$HOOKS_DIR" ] && command -v jq > /dev/null 2>&1; then
  # run_hook <hook> <command> → exit code of the hook fed a PreToolUse payload.
  run_hook() {
    local payload
    payload=$(jq -cn --arg c "$2" '{tool_name:"Bash",tool_input:{command:$c}}')
    printf '%s' "$payload" | bash "$HOOKS_DIR/$1" > /dev/null 2>&1
  }

  INCIDENT_CMD='rg -n "`vstack refresh`" skills/'
  SAFE_CMD="rg -n '\\x60vstack refresh\\x60' skills/"

  for hook in block-bare-cd.sh pre-commit-check.sh; do
    for cmd in "$INCIDENT_CMD" "$SAFE_CMD"; do
      set +e
      run_hook "$hook" "$cmd"
      code=$?
      set -e
      if [ "$code" -eq 0 ]; then
        pass "$hook passes: $cmd"
      else
        fail "$hook rejected a read-only search (exit=$code): $cmd"
      fi
    done
  done

  set +e
  bare_err="$(jq -cn --arg c 'cd /tmp' '{tool_name:"Bash",tool_input:{command:$c}}' | bash "$HOOKS_DIR/block-bare-cd.sh" 2>&1)"
  bare_code=$?
  set -e
  if [ "$bare_code" -eq 2 ] && printf '%s' "$bare_err" | grep -q "Bare 'cd'"; then
    pass "block-bare-cd still rejects a bare cd with exit 2 (teeth unchanged)"
  else
    fail "block-bare-cd teeth check failed (code=$bare_code, err='$bare_err')"
  fi
else
  pass "hooks dir or jq unavailable — hook passthrough skipped (standalone skill install)"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
