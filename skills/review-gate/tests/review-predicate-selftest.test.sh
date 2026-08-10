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
grep -q "publisher filter set: github-actions-minted trusted status is not evidence" "$work/defaults.out" \
  || note "status publisher-filter near-miss case missing"
grep -q "publisher filter set: github-actions-minted outage attestation is not evidence" "$work/defaults.out" \
  || note "outage publisher-filter near-miss case missing"
grep -q "publisher filter unset: github-actions-minted status counts" "$work/defaults.out" \
  || note "publisher-filter default-unchanged case missing"
grep -q "publisher filter set: an outage attestation with NO creator login is not evidence" "$work/defaults.out" \
  || note "outage creator-less case missing (outage read is a separate jq implementation)"
grep -q "publisher filter unset: github-actions-minted outage attestation counts" "$work/defaults.out" \
  || note "outage default-unchanged case missing (outage read is a separate jq implementation)"

# --- layer 1b: the committed-mode-typo guard must itself be falsifiable -----
# The selftest validates the repo's ACTIVE REVIEW_GATE_MODE standalone (a
# committed typo fails the suite pre-merge). Prove the guard fires: a
# planted invalid mode must fail the suite naming the key — otherwise
# deleting the guard would leave everything green.
mkdir -p "$work/modetypo"
if (cd "$work/modetypo" && REVIEW_GATE_MODE=offf "$SELFTEST") >"$work/modetypo.out" 2>&1; then
  note "selftest passed with a planted invalid REVIEW_GATE_MODE — the committed-typo guard no longer fires"
else
  grep -q "REVIEW_GATE_MODE" "$work/modetypo.out"     || note "the planted-invalid-mode failure does not name REVIEW_GATE_MODE"
fi

# --- layer 2: the selftest must exercise CONFIGURED values ------------------
mkdir -p "$work/configured"
cat >"$work/configured/vstack.settings.toml" <<'EOF'
[env]
REVIEW_GATE_TRUSTED_STATUS_CONTEXTS = "Acme Review; Beta Scan"
REVIEW_GATE_CHECKRUN_SKIP_PATTERNS = "quota exceeded"
REVIEW_GATE_COMMENT_REVIEWERS = "acme-reviewer[bot]:Analysis (clean) for commit"
REVIEW_GATE_SHA_PREFIX_FLOOR = "9"
REVIEW_GATE_OUTAGE_CONTEXT = "acme-outage"
REVIEW_GATE_STATUS_PUBLISHER_REJECT = "github-actions[bot]"
REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS = "acme-reviewer[bot];human-lead"
REVIEW_GATE_REVIEW_OBJECT_MIN_STATE = "approved"
REVIEW_GATE_THREADS = "off"
REVIEW_GATE_API_ATTEMPTS = "2"
REVIEW_GATE_CARRY_FORWARD = "docs"
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
grep -q '\[Acme Review\] status minted by a rejected publisher is not evidence' "$work/configured.out" \
  || note "configured publisher reject-list near-miss not exercised"
grep -q "outage attestation from a rejected publisher is not evidence" "$work/configured.out" \
  || note "configured outage publisher reject-list near-miss not exercised"
grep -q "configured: threads=off" "$work/configured.out" \
  || note "configured threads=off posture not exercised"
grep -q "configured: a transient read failure survives the repo's retry budget" "$work/configured.out" \
  || note "configured retry budget not exercised"
grep -q "configured: unresolved thread fails closed" "$work/defaults.out" \
  || note "default threads=enforce posture not exercised"
grep -q "configured: carry-forward (docs) — identical tree carries" "$work/configured.out" \
  || note "configured carry-forward posture not exercised"
grep -q "carry off (default): the same docs delta does NOT carry" "$work/defaults.out" \
  || note "carry-forward off-default near-miss missing"

# --- layer 2b: EVERY committed carry-exclude glob is exercised --------------
# One battery case per committed glob — a later typo'd addition must not
# hide behind an earlier glob's green — and a leading-'/' glob (which can
# never match a repository-relative compare filename) must FAIL the suite,
# not skip silently.
mkdir -p "$work/excludes"
# BSD/macOS sed has no \n replacement extension — build fixtures with
# grep -v + printf instead.
grep -v '^REVIEW_GATE_CARRY_FORWARD = ' "$work/configured/vstack.settings.toml" \
  >"$work/excludes/vstack.settings.toml"
printf 'REVIEW_GATE_CARRY_FORWARD = "docs"\nREVIEW_GATE_CARRY_FORWARD_EXCLUDE = "*AGENTS.md;guides/*"\n' \
  >>"$work/excludes/vstack.settings.toml"
if ! (cd "$work/excludes" && "$SELFTEST") >"$work/excludes.out" 2>&1; then
  cat "$work/excludes.out"
  note "selftest failed under a committed carry-exclude list"
fi
grep -q "carry-exclude — '\*AGENTS.md' matches" "$work/excludes.out" \
  || note "committed glob '*AGENTS.md' not exercised"
grep -q "carry-exclude — 'guides/\*' matches" "$work/excludes.out" \
  || note "committed glob 'guides/*' not exercised (every glob must probe, not just the first)"
grep -q "outside every committed glob and still carries" "$work/excludes.out" \
  || note "committed exclude-free carry case not exercised"

# One combined FAILING run pins BOTH guards (each fixture run replays the
# full decision table, so failure cases share a run): a leading-'/' glob can
# never match a repository-relative compare filename (dead anchoring), and a
# '*' exclusion swallowing every carry-class probe path means the enabled
# class can never apply (over-broad).
mkdir -p "$work/deadglob"
grep -v '^REVIEW_GATE_CARRY_FORWARD = ' "$work/configured/vstack.settings.toml" \
  >"$work/deadglob/vstack.settings.toml"
printf 'REVIEW_GATE_CARRY_FORWARD = "docs"\nREVIEW_GATE_CARRY_FORWARD_EXCLUDE = "/docs/*;*"\n' \
  >>"$work/deadglob/vstack.settings.toml"
if (cd "$work/deadglob" && "$SELFTEST") >"$work/deadglob.out" 2>&1; then
  note "selftest passed with dead ('/docs/*') and over-broad ('*') carry-excludes — the guards no longer fire"
else
  grep -q "leading '/'" "$work/deadglob.out" \
    || note "the dead-glob failure does not explain the leading-'/' anchoring"
  grep -q "can never apply" "$work/deadglob.out" \
    || note "the over-broad failure does not explain that the carry class is dead"
fi

if [ "$fail" -ne 0 ]; then
  echo "review-predicate-selftest.test: FAIL"
  exit 1
fi
echo "pass: review-predicate-selftest ($default_cases default / $configured_cases configured cases)"
