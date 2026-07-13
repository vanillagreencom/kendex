#!/usr/bin/env bash
# Regression test for the reviewer skill's "Harness-Safe Shell" rule (vstack#510,
# a recurrence of #369). Under Codex `approval=never`, a required read-only
# validation such as `jq -e <filter> <file> >/dev/null` is rejected because the
# *shape* (output redirection) is classified as approval-required — not because
# of access. The rule must therefore forbid redirection/substitution/composition
# in prescribed command examples, and must prescribe the redirection-free
# `jq -e <filter> <file>` form (exit status IS the check).
#
# Two parts:
#   a. Doc lint  — scan ONLY fenced ```bash / ```sh command blocks in the
#      reviewer SKILL.md and workflows/*.md for Codex-hostile shapes. Prose and
#      inline `code` (including the rule text that necessarily quotes the very
#      tokens it forbids) are excluded, so the rule cannot flag itself.
#   b. Behavioral — prove the prescribed redirection-free predicate
#      `jq -e . <file>` works by exit status alone.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

# scan_cmd_blocks <file>
# Emits "file:lineno: [reason] line" for every Codex-hostile shape found inside a
# fenced ```bash / ```sh block. Lines outside such blocks (prose, inline code,
# ```json output blocks) are never scanned, so the rule describing `>/dev/null`
# does not trip the lint.
scan_cmd_blocks() {
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
    (infence && iscmd) {
      reason = ""
      if ($0 ~ />\/dev\/null/)                     reason = "redirect-to-/dev/null"
      else if ($0 ~ /([[:space:]]>>?|[0-9]>|&>)/)  reason = "output/error redirection"
      else if ($0 ~ /\$\(/)                        reason = "command substitution $("
      else if ($0 ~ / && /)                        reason = "&& composition"
      else if ($0 ~ / \|\| /)                      reason = "|| composition"
      if (reason != "") printf "%s:%d: [%s] %s\n", f, NR, reason, $0
    }
  ' "$1"
}

echo "=== reviewer harness-safe-shell lint ==="

# --- Part a: doc lint ------------------------------------------------------

# a.1 — the real reviewer docs must contain zero offending shapes.
DOCS=("$SKILL_DIR/SKILL.md" "$SKILL_DIR"/workflows/*.md)
offenders=""
for doc in "${DOCS[@]}"; do
  out="$(scan_cmd_blocks "$doc")"
  [[ -n "$out" ]] && offenders+="$out"$'\n'
done
if [[ -z "$offenders" ]]; then
  pass "reviewer command blocks are free of Codex-hostile shapes"
  echo "  all pass"
else
  fail "Codex-hostile shapes found in reviewer command blocks:"
  printf '%s' "$offenders" | sed 's/^/          /'
fi

# a.2 — the lint has teeth: an injected `>/dev/null` inside a fenced bash block
# must be flagged.
SCRATCH_CMD="$TMP_ROOT/inject-cmd.md"
cp "$SKILL_DIR/workflows/review.md" "$SCRATCH_CMD"
printf '\n```bash\njq -e . tmp/review-x.json >/dev/null\n```\n' >> "$SCRATCH_CMD"
if [[ -n "$(scan_cmd_blocks "$SCRATCH_CMD")" ]]; then
  pass "lint flags an injected >/dev/null in a fenced command block"
else
  fail "lint MISSED an injected >/dev/null (no teeth)"
fi

# a.3 — the lint is correctly scoped: the same token in prose / inline code must
# NOT be flagged (this is what lets the rule quote `>/dev/null` safely).
SCRATCH_PROSE="$TMP_ROOT/inject-prose.md"
cp "$SKILL_DIR/workflows/review.md" "$SCRATCH_PROSE"
printf '\nThis prose mentions `jq -e . file >/dev/null` and `$(cmd)` inline and must not be flagged.\n' >> "$SCRATCH_PROSE"
if [[ -z "$(scan_cmd_blocks "$SCRATCH_PROSE")" ]]; then
  pass "lint ignores forbidden tokens in prose / inline code (fenced-block scoping)"
else
  fail "lint false-flagged a forbidden token that appeared only in prose"
fi

# --- Part b: behavioral ----------------------------------------------------

# The prescribed redirection-free predicate `jq -e . <file>` must validate a JSON
# artifact by exit status alone — no `>/dev/null` needed.
GOOD_JSON="$TMP_ROOT/review-sample.json"
printf '{"verdict":"pass","blockers":[],"suggestions":[]}\n' > "$GOOD_JSON"
set +e
good_out="$(jq -e . "$GOOD_JSON")"
good_code=$?
set -e
if [[ "$good_code" -eq 0 && -n "$good_out" ]]; then
  pass "redirection-free 'jq -e . <file>' exits 0 on valid JSON (parsed output is harmless)"
else
  fail "redirection-free jq predicate did not exit 0 on valid JSON (code=$good_code)"
fi

# Exit status IS the check: invalid JSON makes the same bare predicate fail,
# so no redirection is ever required to observe the result.
BAD_JSON="$TMP_ROOT/review-bad.json"
printf 'not-json' > "$BAD_JSON"
set +e
bad_err="$(jq -e . "$BAD_JSON" 2>&1)"
bad_code=$?
set -e
if [[ "$bad_code" -ne 0 ]]; then
  pass "redirection-free 'jq -e . <file>' exits nonzero on invalid JSON"
else
  fail "jq predicate unexpectedly exited 0 on invalid JSON"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
