#!/usr/bin/env bash
# The engine's core test: run the offline selftest end-to-end (it is
# self-contained by design — gh shim + fixtures, no network) and prove both
# of its layers:
#   1. with no repo settings, the full decision table passes on the built-in
#      defaults;
#   2. with a repo-configured trust surface (different bot, different
#      contexts, non-default floor/skip patterns/trust list), the configured
#      layer regenerates its approve/near-miss battery from THOSE values —
#      a repo trusting a different bot tests its own config, not defaults.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELFTEST="$(cd "$TEST_DIR/../scripts" && pwd)/review-predicate-selftest.sh"

fail=0
note() { echo "FAIL: $1"; fail=1; }

[ -x "$SELFTEST" ] || { echo "FAIL: not executable: $SELFTEST"; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- layer 1: built-in defaults (no settings file resolvable) ---------------
mkdir -p "$work/defaults"
if ! (cd "$work/defaults" && "$SELFTEST") >"$work/defaults.out" 2>&1; then
  cat "$work/defaults.out"
  note "selftest failed under built-in defaults"
fi
default_cases="$(sed -n 's/^review-predicate selftest: \([0-9]*\) case(s), all pass$/\1/p' "$work/defaults.out")"
if [ -z "$default_cases" ] || [ "$default_cases" -lt 50 ]; then
  note "expected >=50 default cases with a pass summary, got '${default_cases:-none}'"
fi
grep -q "rate-limited 'pass' check-run is NOT evidence" "$work/defaults.out" \
  || note "rate-limited-pass fixture case missing"
grep -q "approval NOT superseded by a later COMMENTED" "$work/defaults.out" \
  || note "approval non-supersession case missing"
grep -q "UNTRUSTED login's review is not evidence" "$work/defaults.out" \
  || note "review-object trust-list case missing"

# --- layer 2: the selftest must exercise CONFIGURED values ------------------
mkdir -p "$work/configured"
cat >"$work/configured/vstack.settings.toml" <<'EOF'
[env]
REVIEW_GATE_TRUSTED_STATUS_CONTEXTS = "Acme Review; Beta Scan"
REVIEW_GATE_CHECKRUN_SKIP_PATTERNS = "quota exceeded"
REVIEW_GATE_COMMENT_REVIEWERS = "acme-reviewer[bot]:Analysis (clean) for commit"
REVIEW_GATE_SHA_PREFIX_FLOOR = "9"
REVIEW_GATE_OUTAGE_CONTEXT = "acme-outage"
REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS = "acme-reviewer[bot];human-lead"
REVIEW_GATE_REVIEW_OBJECT_MIN_STATE = "approved"
EOF
if ! (cd "$work/configured" && "$SELFTEST") >"$work/configured.out" 2>&1; then
  cat "$work/configured.out"
  note "selftest failed under a configured trust surface"
fi
configured_cases="$(sed -n 's/^review-predicate selftest: \([0-9]*\) case(s), all pass$/\1/p' "$work/configured.out")"
if [ -z "$configured_cases" ] || [ "$configured_cases" -le "${default_cases:-0}" ]; then
  note "configured run should add cases beyond the default run (default=${default_cases:-?}, configured=${configured_cases:-none})"
fi
# The battery must be generated FROM the configured values: each configured
# context and the configured comment reviewer must appear as case subjects,
# including their near-misses.
grep -q '\[Acme Review\] clean commit status at head' "$work/configured.out" \
  || note "configured context 'Acme Review' not exercised"
grep -q '\[Beta Scan\] check-run under a DIFFERENT name' "$work/configured.out" \
  || note "configured context 'Beta Scan' near-miss not exercised"
grep -q "\[acme-reviewer\[bot\]\] SAME BODY, wrong author" "$work/configured.out" \
  || note "configured comment reviewer near-miss battery not exercised"
grep -q "success check-run but output says 'quota exceeded'" "$work/configured.out" \
  || note "configured skip pattern not exercised"
grep -q "login outside the repo trust list is not evidence" "$work/configured.out" \
  || note "configured review-object trust list near-miss not exercised"
grep -q "outage attestation (acme-outage)" "$work/configured.out" \
  || note "configured outage context not exercised"

if [ "$fail" -ne 0 ]; then
  echo "review-predicate-selftest.test: FAIL"
  exit 1
fi
echo "pass: review-predicate-selftest ($default_cases default / $configured_cases configured cases)"
