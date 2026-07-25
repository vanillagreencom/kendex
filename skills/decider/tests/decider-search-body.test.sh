#!/usr/bin/env bash
# Regression tests for body-scoped decision search (vstack#853).
#
# `decisions search` matched only the INDEX.md summary columns (decision,
# rationale, id), never the decision document itself. A keyword appearing
# prominently in a decision's prose but not in its one-line summary returned
# `[]` — indistinguishable from "no decision governs this area", the opposite of
# the truth. That silently passes the pre-mutation guards that call this search
# (orch review-pr § 1.1, dev-fix § 2, tpm-audit § 2, and the issue template).
#
# These tests pin the fix and, just as importantly, the ranking contract: body
# matches surface BELOW every summary match, so results that worked before keep
# their position and scores rather than being displaced by newly-found ones.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
DECISIONS="$SKILL_DIR/scripts/decisions"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/docs/decisions"

cat > "$REPO/docs/decisions/INDEX.md" <<'EOF'
| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|----|----------|----------|-----------|--------------|--------|------|
| 2026-01-01 | D027 | CC-1 | Performance measurement stack | Needs stable baselines | Never | Active | [D027](D027-perf.md) |
| 2026-01-02 | D046 | CC-2 | Dev surface feature gating | Keeps prod lean | Never | Active | [D046](D046-gating.md) |
| 2026-01-03 | D047 | CC-3 | Signature forgery guard | Prevents forgery | Never | Active | [D047](D047-forgery.md) |
EOF

# "hermetic" and "clippy" appear ONLY in prose — the exact shape from the report.
printf '# D027\n\nBenchmarks run in a hermetic sandbox to avoid host drift.\n' \
  > "$REPO/docs/decisions/D027-perf.md"
printf '# D046\n\nClippy lints are enforced on the dev surface.\n' \
  > "$REPO/docs/decisions/D046-gating.md"
# D047 mentions forgery in title, rationale AND body — used for the ranking test.
printf '# D047\n\nGuards against forgery of signatures.\n' \
  > "$REPO/docs/decisions/D047-forgery.md"

run_search() {
  (cd "$REPO" && DECISIONS_DIR="$REPO/docs/decisions" "$DECISIONS" search "$@" 2>/dev/null)
}

echo "=== a keyword that appears only in a decision body is found ==="

assert_eq "$(run_search hermetic | jq -r '[.[].id] | join(",")')" "D027" \
  "body-only keyword returns the governing decision"
assert_eq "$(run_search clippy | jq -r '[.[].id] | join(",")')" "D046" \
  "second body-only keyword returns its decision"

echo "=== summary matches keep priority over body matches ==="

# forgery is in D047's title (3) + rationale (1) + body (0.5).
assert_eq "$(run_search forgery | jq -r '.[0].score')" "4.5" \
  "summary weights unchanged; body adds a fractional bonus"
# A body-only hit scores below any summary hit, so it can never displace one.
assert_eq "$(run_search hermetic | jq -r '.[0].score')" "0.5" \
  "body-only match scores below rationale (1pt)"

echo "=== AND logic spans summary and body together ==="

# "performance" is in D027's title only; "hermetic" is in its body only.
assert_eq "$(run_search "performance hermetic" | jq -r '[.[].id] | join(",")')" "D027" \
  "one term in the summary and another in the body still satisfies AND"
assert_eq "$(run_search "hermetic gating" | jq -r 'length')" "0" \
  "AND still excludes when the terms live in different decisions"

echo "=== regex mode also reaches bodies ==="

assert_eq "$(run_search 'hermetic|clippy' | jq -r '[.[].id] | sort | join(",")')" "D027,D046" \
  "regex alternation matches body text in both decisions"

echo "=== a genuine miss is still an empty result ==="

assert_eq "$(run_search zzz-absent-token | jq -r 'length')" "0" \
  "unmatched keyword still returns an empty array"

echo "=== unindexed files in the directory cannot influence results ==="

printf 'hermetic stray note not linked from INDEX\n' > "$REPO/docs/decisions/STRAY.md"
assert_eq "$(run_search hermetic | jq -r '[.[].id] | join(",")')" "D027" \
  "a stray unindexed file adds no result"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
