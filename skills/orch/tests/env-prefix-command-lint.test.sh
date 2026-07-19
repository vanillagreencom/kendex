#!/usr/bin/env bash
# Regression lint for vstack#714 (a recurrence of the #369/#510/#526
# command-shape class). Under Codex `approval=never`, an env-assignment
# prefix (`VAR=value cmd args`, e.g. `LC_ALL=C tools/test-ci-changes`) is
# rejected purely for its prefix shape — the inner command is irrelevant.
# The canonical normalization (orch SKILL.md § Harness-Safe Shell) happens
# where a required command is ACCEPTED into the workflow: confirm the
# ambient environment satisfies the precondition (`printenv VAR`, `locale`),
# then run the bare command unchanged. The docs must therefore never present
# an env-prefixed command inside a fenced ```bash / ```sh block.
#
# This lint scans ONLY fenced bash/sh blocks in the orch and dev skill docs
# (SKILL.md and workflows/*.md) and FAILS on any non-comment command line
# whose first token is an env assignment with an unquoted value followed by
# a command word. Deliberately NOT flagged, to stay deterministic:
#   - plain variable assignments with no following command (`FOO=bar`)
#   - assignments with quoted values (`KEYWORDS="a b"` — a value, not a prefix)
#   - comment lines and prose/inline-code mentions outside bash/sh fences
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

# scan_env_prefix <file>
# Emits one "file:line: ..." line for every command line inside a fenced
# ```bash / ```sh block whose first token is `NAME=value` with an unquoted,
# non-empty value, followed by whitespace and more content — the
# env-assignment-prefix shape Codex approval=never rejects. Comment lines
# and lines outside bash/sh fences are never scanned.
scan_env_prefix() {
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
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^#/) next
      if (match(line, /^[A-Za-z_][A-Za-z0-9_]*=/)) {
        rest = substr(line, RLENGTH + 1)
        first = substr(rest, 1, 1)
        if (first != "\"" && first != sq) {
          if (rest ~ /^[^ \t]+[ \t]+[^ \t]/)
            printf "%s:%d: env-assignment prefix in fenced command: %s\n", f, NR, line
        }
      }
    }
  ' "$1"
}

echo "=== orch/dev env-assignment-prefix command lint ==="

# --- Part a: the real orch and dev docs must be clean ----------------------
DOCS=(
  "$SKILLS_ROOT/orch/SKILL.md"
  "$SKILLS_ROOT"/orch/workflows/*.md
  "$SKILLS_ROOT/dev/SKILL.md"
  "$SKILLS_ROOT"/dev/workflows/*.md
)
offenders=""
for doc in "${DOCS[@]}"; do
  out="$(scan_env_prefix "$doc")"
  [[ -n "$out" ]] && offenders+="$out"$'\n'
done
if [[ -z "$offenders" ]]; then
  pass "orch/dev fenced command blocks carry no env-assignment prefixes"
else
  fail "fenced command blocks carry env-assignment prefixes:"
  printf '%s' "$offenders" | sed 's/^/          /'
fi

# --- Part b: the lint has teeth --------------------------------------------

# inject_block <descriptor> <body> → prints scratch-file path.
# Appends a fenced ```bash block containing <body> (printf %b, so embedded \n
# splits it into multiple command lines) to a scratch copy of a real,
# now-clean workflow doc under $TMP_ROOT (removed by the EXIT trap). The base
# doc has zero offenders, so any offender reported comes from the injected
# block alone.
inject_block() {
  local scratch="$TMP_ROOT/inject-$1.md"
  cp "$SKILLS_ROOT/orch/workflows/review-pr.md" "$scratch"
  printf '\n```bash\n%b\n```\n' "$2" >> "$scratch"
  printf '%s' "$scratch"
}

# b.1 — the reported offender shape IS flagged.
if [[ -n "$(scan_env_prefix "$(inject_block prefix 'LC_ALL=C tools/test-ci-changes')")" ]]; then
  pass "lint flags an env-assignment-prefixed command"
else
  fail "lint MISSED an env-assignment-prefixed command (no teeth)"
fi

# b.2 — the normalized form (precondition check, then bare command) is NOT flagged.
if [[ -z "$(scan_env_prefix "$(inject_block normalized 'locale\ntools/test-ci-changes')")" ]]; then
  pass "lint accepts the normalized precondition-then-bare-command form"
else
  fail "lint false-flagged the normalized form"
fi

# b.3 — a plain assignment with no following command is NOT flagged.
if [[ -z "$(scan_env_prefix "$(inject_block assign 'RESULT=ok')")" ]]; then
  pass "lint accepts a plain variable assignment"
else
  fail "lint false-flagged a plain variable assignment"
fi

# b.4 — an assignment with a quoted value (a value, not a prefix) is NOT flagged.
if [[ -z "$(scan_env_prefix "$(inject_block quoted 'KEYWORDS="inner exception|fallback"')")" ]]; then
  pass "lint accepts an assignment with a quoted value"
else
  fail "lint false-flagged an assignment with a quoted value"
fi

# b.5 — a comment line carrying the prefix shape is NOT flagged.
if [[ -z "$(scan_env_prefix "$(inject_block comment '# LC_ALL=C tools/test-ci-changes')")" ]]; then
  pass "lint ignores comment lines inside fenced blocks"
else
  fail "lint false-flagged a comment line"
fi

# b.6 — prose mentions outside a bash/sh fence are NOT scanned.
PROSE_SCRATCH="$TMP_ROOT/inject-prose.md"
cp "$SKILLS_ROOT/orch/workflows/review-pr.md" "$PROSE_SCRATCH"
printf '\nNever delegate `LC_ALL=C tools/test-ci-changes` verbatim.\n' >> "$PROSE_SCRATCH"
if [[ -z "$(scan_env_prefix "$PROSE_SCRATCH")" ]]; then
  pass "lint ignores env-prefix mentions in prose (fence scoping)"
else
  fail "lint false-flagged a prose mention outside a fence"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
