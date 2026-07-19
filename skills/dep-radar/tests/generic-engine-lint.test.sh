#!/usr/bin/env bash
# Architecture-invariant lint: the dep-radar skill is the GENERIC engine.
# All repo-specific content (concrete package, binary, fork, and project
# names) lives in each repo's generated docs/dep-radar/inventory.md — never
# in the skill. The maintainer-approved draft originally named real packages
# and projects; this lint keeps them (and their kin) from creeping back in.
#
# Teeth: an offender injected into a copy of the doc must be flagged.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

# Concrete names that appeared in earlier drafts of this skill and must never
# appear in the generic skill docs (the tripwire for known offenders; new
# concrete names are still a review responsibility). Matched case-insensitively
# as whole words so e.g. "tao" cannot false-positive inside an unrelated word.
DENYLIST=(
  earendil
  pi-coding-agent
  wasapi
  wry
  tao
)

# scan <file> — prints "file: name" for every denylisted name found.
scan() {
  local f="$1" name
  for name in "${DENYLIST[@]}"; do
    if grep -qiw -- "$name" "$f"; then
      printf '%s: %s\n' "$f" "$name"
    fi
  done
}

echo "=== dep-radar generic-engine lint ==="

# --- Real docs must be free of concrete project/package names ---------------

DOCS=("$SKILL_DIR/SKILL.md" "$SKILL_DIR/README.md")
offenders=""
for doc in "${DOCS[@]}"; do
  out="$(scan "$doc")"
  [[ -n "$out" ]] && offenders+="$out"$'\n'
done
if [[ -z "$offenders" ]]; then
  pass "SKILL.md and README.md name no concrete packages/projects"
else
  fail "concrete names found in generic skill docs:"
  printf '%s' "$offenders" | sed 's/^/          /'
fi

# --- Teeth ------------------------------------------------------------------

SCRATCH="$TMP_ROOT/inject-pkg.md"
cp "$SKILL_DIR/SKILL.md" "$SCRATCH"
printf '\nRefresh the pinned @earendil-works/pi-coding-agent SDK.\n' >> "$SCRATCH"
if [[ -n "$(scan "$SCRATCH")" ]]; then
  pass "lint flags an injected concrete SDK package name"
else
  fail "lint MISSED an injected concrete SDK package name (no teeth)"
fi

SCRATCH="$TMP_ROOT/inject-fork.md"
cp "$SKILL_DIR/SKILL.md" "$SCRATCH"
printf '\nRebase the vendored tao fork onto upstream.\n' >> "$SCRATCH"
if [[ -n "$(scan "$SCRATCH")" ]]; then
  pass "lint flags an injected concrete vendored-fork name"
else
  fail "lint MISSED an injected concrete vendored-fork name (no teeth)"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
