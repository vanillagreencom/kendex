#!/usr/bin/env bash
# Regression lint for vstack#721 (same command-shape class as #714's
# env-prefix lint). Under Codex `approval=never`, a literal backtick anywhere
# in a command is classified as command substitution and rejected before it
# runs — even a read-only `rg`/`grep` search over Markdown inline code, and
# even inside double quotes (where the substitution would be real). The
# canonical rule (reviewer SKILL.md § Harness-Safe Shell) is to write the
# pattern with the regex hex escape `\x60` in single quotes, in regex mode.
# The orch/dev docs must therefore never present a command containing a
# literal backtick inside a fenced ```bash / ```sh block.
#
# This lint scans ONLY fenced bash/sh blocks in the orch and dev skill docs
# (SKILL.md and workflows/*.md) and FAILS on any non-comment command line
# containing a literal backtick. Deliberately NOT flagged, to stay
# deterministic:
#   - the safe hex-escape form (`\x60` — no backtick character present)
#   - comment lines inside fences
#   - prose/inline-code backticks outside bash/sh fences (Markdown docs are
#     full of them; only fenced command lines are agent-runnable shapes)
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

# scan_backtick <file>
# Emits one "file:line: ..." line for every non-comment command line inside a
# fenced ```bash / ```sh block that contains a literal backtick character —
# the shape Codex approval=never rejects as command substitution. Comment
# lines and lines outside bash/sh fences are never scanned.
scan_backtick() {
  awk -v f="$1" -v bt='`' '
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
    (infence && iscmd) {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^#/) next
      if (index(line, bt) > 0)
        printf "%s:%d: literal backtick in fenced command: %s\n", f, NR, line
    }
  ' "$1"
}

echo "=== orch/dev literal-backtick command lint ==="

# --- Part a: the real orch and dev docs must be clean ----------------------
DOCS=(
  "$SKILLS_ROOT/orch/SKILL.md"
  "$SKILLS_ROOT"/orch/workflows/*.md
  "$SKILLS_ROOT/dev/SKILL.md"
  "$SKILLS_ROOT"/dev/workflows/*.md
)
offenders=""
for doc in "${DOCS[@]}"; do
  out="$(scan_backtick "$doc")"
  [[ -n "$out" ]] && offenders+="$out"$'\n'
done
if [[ -z "$offenders" ]]; then
  pass "orch/dev fenced command blocks carry no literal backticks"
else
  fail "fenced command blocks carry literal backticks:"
  printf '%s' "$offenders" | sed 's/^/          /'
fi

# --- Part b: the lint has teeth --------------------------------------------

# inject_block <descriptor> <body> → prints scratch-file path.
# Appends a fenced ```bash block containing <body> verbatim (printf %s — no
# escape expansion, so a \x60 in the body stays the two characters backslash
# and x, never a real backtick) to a scratch copy of a real, now-clean
# workflow doc under $TMP_ROOT (removed by the EXIT trap). The base doc has
# zero offenders, so any offender reported comes from the injected block.
inject_block() {
  local scratch="$TMP_ROOT/inject-$1.md"
  cp "$SKILLS_ROOT/orch/workflows/review-pr.md" "$scratch"
  printf '\n```bash\n' >> "$scratch"
  printf '%s\n' "$2" >> "$scratch"
  printf '```\n' >> "$scratch"
  printf '%s' "$scratch"
}

# b.1 — the reported offender shape (literal backticks in a quoted search
# pattern) IS flagged.
if [[ -n "$(scan_backtick "$(inject_block offender 'rg -n "`vstack refresh`" skills/')")" ]]; then
  pass "lint flags a command carrying literal backticks"
else
  fail "lint MISSED a command carrying literal backticks (no teeth)"
fi

# b.2 — the canonical safe form (hex escape, no backtick character) is NOT
# flagged.
if [[ -z "$(scan_backtick "$(inject_block safe "rg -n '\\x60vstack refresh\\x60' skills/")")" ]]; then
  pass "lint accepts the canonical \\x60 hex-escape form"
else
  fail "lint false-flagged the canonical \\x60 hex-escape form"
fi

# b.3 — a comment line carrying a backtick is NOT flagged.
if [[ -z "$(scan_backtick "$(inject_block comment '# never run rg -n "`vstack refresh`"')")" ]]; then
  pass "lint ignores comment lines inside fenced blocks"
else
  fail "lint false-flagged a comment line"
fi

# b.4 — inline-code backticks in prose outside a bash/sh fence are NOT
# scanned (Markdown docs are full of them).
PROSE_SCRATCH="$TMP_ROOT/inject-prose.md"
cp "$SKILLS_ROOT/orch/workflows/review-pr.md" "$PROSE_SCRATCH"
printf '\nNever search for `vstack refresh` with a literal backtick.\n' >> "$PROSE_SCRATCH"
if [[ -z "$(scan_backtick "$PROSE_SCRATCH")" ]]; then
  pass "lint ignores inline-code backticks in prose (fence scoping)"
else
  fail "lint false-flagged prose outside a fence"
fi

# b.5 — backticks inside a non-command fence (e.g. ```markdown) are NOT
# scanned; only bash/sh fences are agent-runnable command shapes.
NONCMD_SCRATCH="$TMP_ROOT/inject-noncmd.md"
cp "$SKILLS_ROOT/orch/workflows/review-pr.md" "$NONCMD_SCRATCH"
printf '\n```markdown\nUse `vstack refresh` after merging.\n```\n' >> "$NONCMD_SCRATCH"
if [[ -z "$(scan_backtick "$NONCMD_SCRATCH")" ]]; then
  pass "lint ignores backticks in non-command fences"
else
  fail "lint false-flagged a non-command fence"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
