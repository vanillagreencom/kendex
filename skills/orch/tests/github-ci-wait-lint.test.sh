#!/usr/bin/env bash
# Regression lint for vstack#662. A managed orchestration handoff told an
# agent to run `github.sh ci-wait 296 --json` — but the github router has no
# `ci-wait` command; CI waiting is the orch skill's script
# `.agents/skills/orch/scripts/ci-wait <PR_NUMBER> [interval] [max_wait]
# [--json]`. No canonical doc carried the bad form — the orch SKILL.md Codex
# guidance named `ci-wait` bare, with no path, so an orchestrator relaying it
# next to `github.sh` commands could resolve it to the wrong wrapper. The
# guidance now carries the exact orch path, and the github SKILL.md states
# there is no CI wait command in `github.sh`.
#
# This lint scans the orch, dev, and github doc trees (every line — prose,
# inline code, and fenced blocks alike, since guidance text is what agents
# relay; dev and github are required orch dependencies, so both are present
# wherever orch is installed) and FAILS if any line invokes ci-wait through
# github.sh:
#   - `github.sh ci-wait ...` (the reported miss, with or without `-C <path>`)
#   - `github.sh ciwait` / `github.sh ci_wait` (near-misses)
# It also asserts the docs that state the CI-wait obligation still carry the
# supported orch path, so the guidance can't silently drop it.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
SKILLS_ROOT="$(cd "$SKILL_DIR/.." && pwd)"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

# scan_bad_ci_wait <file>
# Emits one "file:line: ..." row per line that routes ci-wait through
# github.sh. The supported `.agents/skills/orch/scripts/ci-wait` form never
# matches — `github.sh` never precedes it.
scan_bad_ci_wait() {
  grep -nE 'github\.sh[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?ci[-_]?wait' "$1" \
    | sed "s|^|$1:|" || true
}

echo "=== github.sh ci-wait routing lint (vstack#662) ==="

# --- Part a: orch, dev, and github docs must be clean ----------------------
offenders=""
for skill in orch dev github; do
  while IFS= read -r -d '' doc; do
    out="$(scan_bad_ci_wait "$doc")"
    [[ -n "$out" ]] && offenders+="$out"$'\n'
  done < <(find "$SKILLS_ROOT/$skill" -maxdepth 2 -type f -name '*.md' -not -path '*/tests/*' -print0)
done
if [[ -z "$offenders" ]]; then
  pass "orch/dev/github docs never route ci-wait through github.sh"
else
  fail "docs route ci-wait through github.sh (use .agents/skills/orch/scripts/ci-wait):"
  printf '%s' "$offenders" | sed 's/^/          /'
fi

# --- Part b: the obligation-stating docs carry the supported form ----------
if grep -q '\.agents/skills/orch/scripts/ci-wait' "$SKILL_DIR/workflows/submit-pr.md"; then
  pass "submit-pr workflow carries the orch ci-wait path"
else
  fail "submit-pr workflow lost the orch ci-wait path"
fi
if grep -q '\.agents/skills/orch/scripts/ci-wait' "$SKILL_DIR/SKILL.md"; then
  pass "orch SKILL.md harness guidance carries the orch ci-wait path"
else
  fail "orch SKILL.md harness guidance lost the orch ci-wait path"
fi
if grep -q '\.agents/skills/orch/scripts/ci-wait' "$SKILLS_ROOT/github/SKILL.md"; then
  pass "github SKILL.md points CI waiting at the orch ci-wait script"
else
  fail "github SKILL.md lost the pointer to the orch ci-wait script"
fi

# --- Part c: the lint has teeth --------------------------------------------

# inject_line <descriptor> <line> → prints scratch-file path.
# Appends <line> to a scratch copy of a real, now-clean workflow doc under
# $TMP_ROOT (removed by the EXIT trap). The base doc has zero offenders, so
# any offender reported comes from the injected line alone.
inject_line() {
  local scratch="$TMP_ROOT/inject-$1.md"
  cp "$SKILL_DIR/workflows/submit-pr.md" "$scratch"
  printf '\n%s\n' "$2" >> "$scratch"
  printf '%s' "$scratch"
}

# c.1 — the reported miss IS flagged.
if [[ -n "$(scan_bad_ci_wait "$(inject_line miss 'Run `.agents/skills/github/scripts/github.sh ci-wait 296 --json` to wait.')")" ]]; then
  pass "lint flags 'github.sh ci-wait'"
else
  fail "lint MISSED 'github.sh ci-wait' (no teeth)"
fi

# c.2 — near-miss variants ARE flagged.
if [[ -n "$(scan_bad_ci_wait "$(inject_line joined 'Run `./github.sh ciwait 296`.')")" ]]; then
  pass "lint flags the 'github.sh ciwait' near-miss"
else
  fail "lint MISSED the 'github.sh ciwait' near-miss (no teeth)"
fi
if [[ -n "$(scan_bad_ci_wait "$(inject_line underscore 'Run `github.sh ci_wait 296`.')")" ]]; then
  pass "lint flags the 'github.sh ci_wait' near-miss"
else
  fail "lint MISSED the 'github.sh ci_wait' near-miss (no teeth)"
fi
if [[ -n "$(scan_bad_ci_wait "$(inject_line cflag 'Run `github.sh -C [WT_PATH] ci-wait 296`.')")" ]]; then
  pass "lint flags 'github.sh -C <path> ci-wait'"
else
  fail "lint MISSED 'github.sh -C <path> ci-wait' (no teeth)"
fi

# c.3 — supported and legitimate forms are NOT flagged.
if [[ -z "$(scan_bad_ci_wait "$(inject_line ok 'Run `.agents/skills/orch/scripts/ci-wait 296 --json` to wait.')")" ]]; then
  pass "lint accepts the supported orch ci-wait path"
else
  fail "lint false-flagged the supported orch ci-wait path"
fi
if [[ -z "$(scan_bad_ci_wait "$(inject_line cilogs 'Run `.agents/skills/github/scripts/github.sh ci-logs 296` for failure logs.')")" ]]; then
  pass "lint accepts the real 'github.sh ci-logs' command"
else
  fail "lint false-flagged the real 'github.sh ci-logs' command"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
