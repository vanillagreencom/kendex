#!/usr/bin/env bash
# Regression lint for vstack#641. During an orch dev-fix cycle the generated
# delegation guidance told a specialist to run `decisions issue CC-125` — an
# action the decider CLI rejects; the supported issue lookup is
# `decisions search --issue CC-125`. The orch dev-fix workflow now gathers
# decision context itself (§ 2 step 4) and hands resolved IDs/paths plus the
# exact supported command to the specialist, so nothing is left to improvise.
#
# This lint scans the orch SKILL.md and workflows/*.md (every line — prose,
# inline code, and fenced blocks alike, since guidance text is what agents
# relay) and FAILS if any line uses an unsupported issue-lookup shape:
#   - `decisions issue <ID>` / `decisions issues <ID>` (the reported miss)
#   - `decisions show --issue` (near-miss: `show` is not an action)
# It also asserts the dev-fix delegation source carries the supported
# `decisions search --issue` form, so the guidance can't silently drop it.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

# scan_bad_lookup <file>
# Emits one "file:line: ..." row per line using an unsupported issue-lookup
# shape. `decisions search --issue` never matches — `search` sits between the
# two tokens — so the supported form and this lint coexist freely.
scan_bad_lookup() {
  grep -nE 'decisions[[:space:]]+(issues?([^a-zA-Z0-9_-]|$)|show[[:space:]]+--issue)' "$1" \
    | sed "s|^|$1:|" || true
}

echo "=== orch decider issue-lookup syntax lint (vstack#641) ==="

# --- Part a: the real orch docs must be clean ------------------------------
DOCS=("$SKILL_DIR/SKILL.md" "$SKILL_DIR"/workflows/*.md)
offenders=""
for doc in "${DOCS[@]}"; do
  out="$(scan_bad_lookup "$doc")"
  [[ -n "$out" ]] && offenders+="$out"$'\n'
done
if [[ -z "$offenders" ]]; then
  pass "orch docs never use an unsupported decisions issue-lookup shape"
else
  fail "orch docs use unsupported decisions issue-lookup shapes:"
  printf '%s' "$offenders" | sed 's/^/          /'
fi

# --- Part b: dev-fix delegation guidance carries the supported form --------
if grep -q 'decisions search --issue' "$SKILL_DIR/workflows/dev-fix.md"; then
  pass "dev-fix workflow carries the supported 'decisions search --issue' lookup"
else
  fail "dev-fix workflow lost the supported 'decisions search --issue' lookup"
fi

# --- Part c: the lint has teeth --------------------------------------------

# inject_line <descriptor> <line> → prints scratch-file path.
# Appends <line> to a scratch copy of a real, now-clean workflow doc under
# $TMP_ROOT (removed by the EXIT trap). The base doc has zero offenders, so
# any offender reported comes from the injected line alone.
inject_line() {
  local scratch="$TMP_ROOT/inject-$1.md"
  cp "$SKILL_DIR/workflows/dev-fix.md" "$scratch"
  printf '\n%s\n' "$2" >> "$scratch"
  printf '%s' "$scratch"
}

# c.1 — the reported miss IS flagged.
if [[ -n "$(scan_bad_lookup "$(inject_line miss 'Check decisions: run `decisions issue CC-125` first.')")" ]]; then
  pass "lint flags the unsupported 'decisions issue <ID>' shape"
else
  fail "lint MISSED the unsupported 'decisions issue <ID>' shape (no teeth)"
fi

# c.2 — near-miss variants ARE flagged.
if [[ -n "$(scan_bad_lookup "$(inject_line plural 'Run `decisions issues CC-125`.')")" ]]; then
  pass "lint flags the 'decisions issues <ID>' near-miss"
else
  fail "lint MISSED the 'decisions issues <ID>' near-miss (no teeth)"
fi
if [[ -n "$(scan_bad_lookup "$(inject_line show 'Run `decisions show --issue CC-125`.')")" ]]; then
  pass "lint flags the 'decisions show --issue' near-miss"
else
  fail "lint MISSED the 'decisions show --issue' near-miss (no teeth)"
fi

# c.3 — the supported form is NOT flagged.
if [[ -z "$(scan_bad_lookup "$(inject_line ok 'Run `.agents/skills/decider/scripts/decisions search --issue CC-125`.')")" ]]; then
  pass "lint accepts the supported 'decisions search --issue' form"
else
  fail "lint false-flagged the supported 'decisions search --issue' form"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
