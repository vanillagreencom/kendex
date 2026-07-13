#!/usr/bin/env bash
# Regression test for the reviewer skill's "Harness-Safe Shell" rule (vstack#510,
# a recurrence of #369). Under Codex `approval=never`, a required read-only
# validation such as `jq -e <filter> <file> >/dev/null` is rejected because the
# *shape* (output redirection) is classified as approval-required — not because
# of access. The rule must therefore forbid redirection/substitution/composition
# in prescribed command examples, and must prescribe the redirection-free
# `jq -e <filter> <file>` form (exit status IS the check).
#
# Redirection was the first shape to bite, but the rule forbids the whole family
# of harness-hostile shapes — redirection, `$(...)`, backticks, `&&`, `||`,
# pipelines (`|`), statement separators (`;`), and inline conditionals
# (`if ...; then ... fi`, `[[ ... ]] && ...`). The lint must catch every one, or a
# reintroduced `if [[ ... ]]; then` (the exact shape removed from review.md in
# #510/#512) — or a pipe/semicolon/backtick — would slip past silently (#513).
#
# Two parts:
#   a. Doc lint  — scan ONLY fenced ```bash / ```sh command blocks in the
#      reviewer SKILL.md and workflows/*.md for every Codex-hostile shape above.
#      Prose and inline `code` (including the rule text that necessarily quotes
#      the very tokens it forbids) are excluded, so the rule cannot flag itself.
#      Quoted substrings are shell-SAFE and are stripped before testing, so a
#      `jq '.a | .b'` filter's quote-internal pipe is not a false positive.
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
# ```json output blocks) are never scanned, so the SKILL.md rule text that quotes
# the very tokens it forbids (`>/dev/null`, `|`, `;`, backticks, ...) cannot trip
# the lint.
#
# Detects the full set of shapes the Harness-Safe Shell rule forbids
# (SKILL.md § Harness-Safe Shell): redirection (`>/dev/null`, `>`, `>>`, `2>`,
# `&>`), command substitution `$(...)`, backticks, `&&`, `||`, plumbing
# pipelines (`|`), statement separators (`;`), and inline conditional /
# test-and-run shapes (`if ...; then`, `[[ ... ]]`, standalone `fi`).
#
# Quoted substrings are shell-SAFE and must not false-positive: a `jq '.a | .b'`
# filter's `|` lives inside single quotes and is jq-internal, not a shell
# pipeline. So each line is first quote-stripped — double-quoted `"..."` then
# single-quoted '...' substrings are removed — and the shell-level shapes are
# tested on the stripped remainder (the original line is still what gets
# reported). Limitation: the strip is a pragmatic per-line gsub that removes
# `"[^"]*"` / `'[^']*'`; it does not model escaped quotes (`\"`), quote nesting,
# or quotes spanning multiple lines. That is sufficient for the reviewer docs'
# real command lines (and the jq-filter case) but is not a full shell parser.
scan_cmd_blocks() {
  # sq holds a single-quote char so the awk program (itself single-quoted for the
  # shell) can build the '...'-stripping regex without shell-quoting gymnastics.
  awk -v f="$1" -v sq="'" '
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
      # Strip quoted substrings so quote-internal tokens (e.g. a jq filter pipe)
      # are not treated as shell operators. Double quotes first, then single.
      stripped = $0
      gsub(/"[^"]*"/, "", stripped)
      gsub(sq "[^" sq "]*" sq, "", stripped)

      # A bare pipeline is a `|` that is not part of `||`; remove `||` first, then
      # look for any remaining `|`. `||` composition is reported on its own below,
      # so this never double-reports `||` as a pipeline.
      nopipe = stripped
      gsub(/\|\|/, "", nopipe)
      barepipe = (nopipe ~ /\|/)

      # Inline conditional / test-and-run: leading/word `if`, the `then`/`fi`
      # keywords as standalone words, or `[[` / `]]` test brackets. Word-boundary
      # guards keep substrings like "diff"/"config" from matching `if`/`fi`.
      inlinecond = (stripped ~ /(^|[^[:alnum:]_])if[[:space:]]/) ||
                   (stripped ~ /(^|[^[:alnum:]_])then([^[:alnum:]_]|$)/) ||
                   (stripped ~ /(^|[^[:alnum:]_])fi([^[:alnum:]_]|$)/) ||
                   (stripped ~ /\[\[/) ||
                   (stripped ~ /\]\]/)

      reason = ""
      if      (stripped ~ />\/dev\/null/)               reason = "redirect-to-/dev/null"
      else if (stripped ~ /([[:space:]]>>?|[0-9]>|&>)/) reason = "output/error redirection"
      else if (stripped ~ /\$\(/)                       reason = "command substitution $("
      else if (index(stripped, "`") > 0)                reason = "backtick command substitution"
      else if (stripped ~ /&&/)                         reason = "&& composition"
      else if (stripped ~ /\|\|/)                       reason = "|| composition"
      else if (barepipe)                                reason = "plumbing pipeline |"
      else if (inlinecond)                              reason = "inline conditional / test-and-run"
      else if (stripped ~ /;/)                          reason = "statement separator ;"
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

# inject_block <descriptor> <command-line> → prints scratch-file path.
# Appends a fenced ```bash block containing <command-line> to a scratch copy of
# review.md under $TMP_ROOT (cleaned by the EXIT trap), so each shape is proven
# against a real fenced block without disturbing the tracked docs.
inject_block() {
  local scratch="$TMP_ROOT/inject-$1.md"
  cp "$SKILL_DIR/workflows/review.md" "$scratch"
  printf '\n```bash\n%s\n```\n' "$2" >> "$scratch"
  printf '%s' "$scratch"
}

# a.4 — each newly-detected shape, injected into a fenced block, must be flagged.

# pipeline
if [[ -n "$(scan_cmd_blocks "$(inject_block pipe 'foo | bar')")" ]]; then
  pass "lint flags an injected pipeline 'foo | bar'"
else
  fail "lint MISSED an injected pipeline (no teeth for |)"
fi

# statement separator
if [[ -n "$(scan_cmd_blocks "$(inject_block semicolon 'cmd_a; cmd_b')")" ]]; then
  pass "lint flags an injected statement separator 'cmd_a; cmd_b'"
else
  fail "lint MISSED an injected statement separator (no teeth for ;)"
fi

# backtick command substitution
if [[ -n "$(scan_cmd_blocks "$(inject_block backtick 'x=`date`')")" ]]; then
  pass "lint flags an injected backtick substitution 'x=\`date\`'"
else
  fail "lint MISSED an injected backtick substitution (no teeth for backticks)"
fi

# inline conditional / test-and-run (the exact #510/#512 shape)
if [[ -n "$(scan_cmd_blocks "$(inject_block ifthen 'if [[ -n "$X" ]]; then run; fi')")" ]]; then
  pass "lint flags an injected inline conditional 'if [[ ... ]]; then ... fi'"
else
  fail "lint MISSED an injected inline conditional (no teeth for if/[[/then/fi)"
fi

# a.5 — false-positive guard: a jq filter's internal pipe lives inside single
# quotes and is shell-SAFE. A naive scanner that greps a bare `|` WOULD flag it
# (asserted below to prove the guard is non-trivial); ours must not, because it
# strips quoted substrings before testing.
JQ_LINE="jq '.a | .b' file.json"
JQ_SCRATCH="$(inject_block jqpipe "$JQ_LINE")"
jq_out="$(scan_cmd_blocks "$JQ_SCRATCH")"
if printf '%s\n' "$JQ_LINE" | grep -qE '[|]'; then naive_flags=1; else naive_flags=0; fi
if [[ "$naive_flags" -eq 1 && -z "$jq_out" ]]; then
  pass "quoted jq pipe is NOT flagged (naive bare-| scan would false-positive; quote-strip prevents it)"
else
  fail "quoted-pipe guard failed (naive_flags=$naive_flags, scanner_out='$jq_out')"
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
