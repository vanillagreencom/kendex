#!/usr/bin/env bash
# Regression lint for VST-34. .github/instructions/skills-and-agents.instructions.md
# bans issue-number citations (`kendex#NNN`, bare `(#NNN)`) in instruction-flow
# skill/agent markdown — the always-loaded SKILL.md and agent-definition files
# an agent actually parses to act, as opposed to human-facing README.md,
# DEVELOPMENT.md, and on-demand workflows/*.md. `skills/*/schemas/*.md`
# reference docs are the one carve-out (established convention: they carry
# issue provenance).
#
# This lint scans every `skills/*/SKILL.md` and repo-root `agents/*.md` for:
#   - `kendex#[0-9]+`               (the explicit-repo citation form)
#   - a bare parenthetical `(#[0-9]+)`   (the bare-issue citation form)
# A parenthetical is required for the bare form so a hex color like
# `#000000` (digits only, no parens) never false-positives — the digit
# count is not load-bearing for that, so short citations like `(#42)` are
# still caught.
#
# Teeth: an offender injected into a copy of a scanned file must be flagged.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

# scan <file> — prints "file:line: match" for every citation violation.
scan() {
  local f="$1" hit
  hit="$(grep -noE 'kendex#[0-9]+|\(#[0-9]+\)' "$f" 2>/dev/null || true)"
  [[ -z "$hit" ]] && return 0
  while IFS=: read -r line match; do
    printf '%s:%s: %s\n' "$f" "$line" "$match"
  done <<< "$hit"
}

list_files() {
  [[ -d "$REPO_ROOT/skills" ]] && find "$REPO_ROOT/skills" -maxdepth 2 -name 'SKILL.md'
  [[ -d "$REPO_ROOT/agents" ]] && find "$REPO_ROOT/agents" -maxdepth 1 -name '*.md'
  return 0
}

echo "=== issue-citation lint (skill/agent always-loaded markdown) ==="

if [[ ! -d "$REPO_ROOT/skills" && ! -d "$REPO_ROOT/agents" ]]; then
  echo "FAIL  neither $REPO_ROOT/skills nor $REPO_ROOT/agents exists — nothing to scan" >&2
  exit 2
fi

offenders=""
while IFS= read -r f; do
  out="$(scan "$f")"
  if [[ -n "$out" ]]; then
    offenders+="$out"$'\n'
  fi
done < <(list_files)

if [[ -z "$offenders" ]]; then
  pass "no issue-number citations in SKILL.md / agents/*.md"
else
  fail "issue-number citations found in always-loaded skill/agent markdown:"
  printf '%s' "$offenders" | sed 's/^/          /'
fi

# --- Teeth ------------------------------------------------------------------

SCRATCH="$TMP_ROOT/inject-kendex-cite.md"
cp "$REPO_ROOT/skills/orch/SKILL.md" "$SCRATCH"
printf '\nAlways ask before merge (kendex#944).\n' >> "$SCRATCH"
if [[ -n "$(scan "$SCRATCH")" ]]; then
  pass "lint flags an injected kendex#NNN citation"
else
  fail "lint MISSED an injected kendex#NNN citation (no teeth)"
fi

SCRATCH="$TMP_ROOT/inject-bare-cite.md"
cp "$REPO_ROOT/skills/orch/SKILL.md" "$SCRATCH"
printf '\nSame command-shape class as before (#714).\n' >> "$SCRATCH"
if [[ -n "$(scan "$SCRATCH")" ]]; then
  pass "lint flags an injected bare (#NNN) citation"
else
  fail "lint MISSED an injected bare (#NNN) citation (no teeth)"
fi

SCRATCH="$TMP_ROOT/inject-short-bare-cite.md"
cp "$REPO_ROOT/skills/orch/SKILL.md" "$SCRATCH"
printf '\nSame command-shape class as before (#42).\n' >> "$SCRATCH"
if [[ -n "$(scan "$SCRATCH")" ]]; then
  pass "lint flags an injected short bare (#N) citation"
else
  fail "lint MISSED an injected short bare (#N) citation (no teeth)"
fi

SCRATCH="$TMP_ROOT/hex-color-false-positive.md"
cp "$REPO_ROOT/skills/orch/SKILL.md" "$SCRATCH"
printf '\nThe default canvas is near-black, not pure #000000.\n' >> "$SCRATCH"
if [[ -z "$(scan "$SCRATCH")" ]]; then
  pass "lint does not false-positive on a bare hex color"
else
  fail "lint false-positived on a bare hex color (#000000)"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
