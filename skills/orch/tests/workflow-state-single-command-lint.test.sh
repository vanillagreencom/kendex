#!/usr/bin/env bash
# Regression lint for vstack#526 (a recurrence of the #369/#510 command-shape
# class). Under Codex `approval=never`, a batch of several newline-separated (or
# `;`-separated) commands in ONE tool call is rejected purely for its
# multi-command shape — no redirection, substitution, or pipeline required. The
# orch workflow docs used to present `workflow-state` operations as fenced
# ```bash blocks that stacked two or three `workflow-state` commands, which
# invited an agent to run them as one rejected batch.
#
# `workflow-state` already supports single-command combined forms, so no script
# change is needed:
#   - `get '{...}'`        — one jq object collapses several reads into one call
#   - `update '... | ...'` — one piped jq expression applies several writes atomically
# Every fenced command block must therefore carry AT MOST ONE `workflow-state`
# invocation. Operations that genuinely can't collapse (`set-git-head`/`set-now`,
# a read mixed with a write, a `// empty` default that would collapse a combined
# object, a per-item loop) live in separate one-command blocks.
#
# This lint scans ONLY fenced ```bash / ```sh blocks in the orch SKILL.md and
# workflows/*.md and FAILS if any single block contains two or more
# `workflow-state` helper invocations (lines matching `scripts/workflow-state `,
# the helper path). Prose, inline `code`, and ```json output blocks are never
# scanned. Scope is `workflow-state` specifically — the helper reported in #526 —
# to stay deterministic; it does not attempt to lint every helper.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

# scan_ws_blocks <file>
# Emits one "file:blockline: N workflow-state invocations ..." line for every
# fenced ```bash / ```sh block that stacks two or more `workflow-state` helper
# invocations. A `workflow-state` invocation is any line containing the helper
# path token `scripts/workflow-state ` (with its trailing space); a single
# combined `get '{...}'` or `update '... | ...'` line contains that token exactly
# once and so counts as one. Lines outside a bash/sh fence — prose, inline code,
# ```json blocks — are never scanned, so surrounding text can mention the helper
# freely.
scan_ws_blocks() {
  awk -v f="$1" '
    /^[[:space:]]*```/ {
      if (infence == 0) {
        infence = 1
        lang = $0
        sub(/^[[:space:]]*```/, "", lang)
        gsub(/[[:space:]]/, "", lang)
        iscmd = (lang == "bash" || lang == "sh") ? 1 : 0
        count = 0
        lines = ""
        blockstart = NR
      } else {
        if (iscmd && count >= 2)
          printf "%s:%d: %d workflow-state invocations in one fenced block (lines:%s )\n", \
                 f, blockstart, count, lines
        infence = 0
        iscmd = 0
      }
      next
    }
    (infence && iscmd) {
      if (index($0, "scripts/workflow-state ") > 0) {
        count++
        lines = lines " " NR
      }
    }
  ' "$1"
}

echo "=== orch workflow-state single-command lint ==="

# --- Part a: the real orch docs must be clean ------------------------------
DOCS=("$SKILL_DIR/SKILL.md" "$SKILL_DIR"/workflows/*.md)
offenders=""
for doc in "${DOCS[@]}"; do
  out="$(scan_ws_blocks "$doc")"
  [[ -n "$out" ]] && offenders+="$out"$'\n'
done
if [[ -z "$offenders" ]]; then
  pass "orch command blocks carry at most one workflow-state invocation each"
  echo "  all pass"
else
  fail "fenced bash blocks stack multiple workflow-state invocations:"
  printf '%s' "$offenders" | sed 's/^/          /'
fi

# --- Part b: the lint has teeth --------------------------------------------

# inject_block <descriptor> <body> → prints scratch-file path.
# Appends a fenced ```bash block containing <body> (printf %b, so embedded \n
# splits it into multiple command lines) to a scratch copy of a real, now-clean
# workflow doc under $TMP_ROOT (removed by the EXIT trap). The base doc has zero
# offenders, so any offender reported comes from the injected block alone.
inject_block() {
  local scratch="$TMP_ROOT/inject-$1.md"
  cp "$SKILL_DIR/workflows/review-pr.md" "$scratch"
  printf '\n```bash\n%b\n```\n' "$2" >> "$scratch"
  printf '%s' "$scratch"
}

# b.1 — two workflow-state lines in one block ARE flagged.
TWO_CMD='.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] .cycles\n.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] .team_name'
if [[ -n "$(scan_ws_blocks "$(inject_block two "$TWO_CMD")")" ]]; then
  pass "lint flags a fenced block with two workflow-state invocations"
else
  fail "lint MISSED a two-command workflow-state block (no teeth)"
fi

# b.2 — a single combined `get '{...}'` line (reads many fields) is NOT flagged.
ONE_GET=".agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '{cycles: (.cycles // 0), fixed_items: (.fixed_items // []), escalated_items: (.escalated_items // [])}'"
if [[ -z "$(scan_ws_blocks "$(inject_block oneget "$ONE_GET")")" ]]; then
  pass "lint accepts a single combined 'get {...}' invocation"
else
  fail "lint false-flagged a single combined 'get {...}' invocation"
fi

# b.3 — a single combined `update '... | ...'` line (many mutations, one call) is NOT flagged.
ONE_UPDATE=".agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '.review_agents = [] | .review_agent_ids = {} | .review_agent_runtime_types = {}'"
if [[ -z "$(scan_ws_blocks "$(inject_block oneupd "$ONE_UPDATE")")" ]]; then
  pass "lint accepts a single combined 'update ... | ...' invocation"
else
  fail "lint false-flagged a single combined 'update ... | ...' invocation"
fi

# b.4 — two workflow-state tokens inside a ```json (non-command) block are NOT
# flagged: fenced-block scoping means only bash/sh command blocks are scanned.
JSON_SCRATCH="$TMP_ROOT/inject-json.md"
cp "$SKILL_DIR/workflows/review-pr.md" "$JSON_SCRATCH"
printf '\n```json\n{"a": ".agents/skills/orch/scripts/workflow-state get x",\n "b": ".agents/skills/orch/scripts/workflow-state get y"}\n```\n' >> "$JSON_SCRATCH"
if [[ -z "$(scan_ws_blocks "$JSON_SCRATCH")" ]]; then
  pass "lint ignores workflow-state tokens inside a json block (bash/sh scoping)"
else
  fail "lint false-flagged workflow-state tokens in a non-command json block"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
