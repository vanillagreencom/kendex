#!/usr/bin/env bash
# REVIEW_GATE_DOCS_ONLY delegates the PR diff to harness-ci's docs classifier.
# A true result can replace missing review evidence. Objections and unresolved
# threads still win, and a non-docs diff takes the normal evidence path.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
HARNESS_CI_DIR="$(cd "$SKILL_DIR/../harness-ci" && pwd)"
TMP="$(mktemp -d)"
[ -n "$TMP" ] || { echo "FATAL: mktemp -d returned an empty path" >&2; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT

REPO="$TMP/repo"
fixtures="$TMP/fixtures"
shim="$TMP/bin"
mkdir -p "$REPO/skills" "$fixtures" "$shim"
cp -R "$SKILL_DIR" "$REPO/skills/review-gate"
cp -R "$HARNESS_CI_DIR" "$REPO/skills/harness-ci"
cp "$TEST_DIR/lib/gh-shim.sh" "$shim/gh"
chmod +x "$shim/gh"

unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
git -C "$REPO" init -q
git -C "$REPO" config maintenance.auto false
git -C "$REPO" config user.name "review-gate tests"
git -C "$REPO" config user.email "tests@example.invalid"
mkdir -p "$REPO/src"
printf '%s\n' 'fn main() {}' >"$REPO/src/main.rs"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "base"
BASE="$(git -C "$REPO" rev-parse HEAD)"
printf '%s\n' '# Guide' >"$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m "docs"
DOCS_HEAD="$(git -C "$REPO" rev-parse HEAD)"
printf '%s\n' 'fn main() { println!("changed"); }' >"$REPO/src/main.rs"
git -C "$REPO" add src/main.rs
git -C "$REPO" commit -q -m "code"
CODE_HEAD="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q "$DOCS_HEAD"
printf '%s\n' '# Review policy' >"$REPO/AGENTS.md"
git -C "$REPO" add AGENTS.md
git -C "$REPO" commit -q -m "policy docs"
POLICY_HEAD="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q "$CODE_HEAD"

predicate="$REPO/skills/review-gate/scripts/review-predicate.sh"
# shellcheck source=lib/selftest-fixtures.sh
. "$TEST_DIR/lib/selftest-fixtures.sh"
AUTHOR="author-under-test"
OTHER="ffffffffffffffffffffffffffffffffffffffff"
base_env=""
cases=0
failures=0

reset_fixtures() { # HEAD
  HEAD="$1"
  printf '[]\n' >"$fixtures/reviews.json"
  printf '[]\n' >"$fixtures/comments.json"
  printf '{"check_runs":[]}\n' >"$fixtures/checkruns.json"
  printf '[]\n' >"$fixtures/statuses.json"
  threads >"$fixtures/graphql.json"
  jq -n --arg a "$AUTHOR" --arg base "$BASE" '{user:{login:$a},base:{sha:$base}}' >"$fixtures/pull.json"
  rm -f "$fixtures/.urls.log"
}

run_case() { # NAME MODE HEAD EFFECT WANT
  name="$1"
  mode="$2"
  head="$3"
  effect="$4"
  want="$5"
  reset_fixtures "$head"
  min_state=any
  carry_exclude=""
  shim_fail=""
  case "$effect" in
    objection) reviews_set "$(review reviewer CHANGES_REQUESTED)" ;;
    thread) threads false >"$fixtures/graphql.json" ;;
    suppressed)
      min_state=approved
      reviews_set "$(review reviewer COMMENTED "2026-01-01T00:00:00Z" "$head" $'### Suppressed comments (1)\n\n**docs/policy.md:9**\n* Blocking: hidden.')"
      ;;
    policy) carry_exclude='*AGENTS.md;CLAUDE.md' ;;
    reply)
      reviews_set "$(review reviewer COMMENTED "2026-01-01T00:00:00Z" "$head" "" 7)"
      shim_fail=review-comments
      ;;
    none) : ;;
    *) exit 1 ;;
  esac
  rc=0
  line="$(PATH="$shim:$PATH" GH_SHIM_FIXTURES="$fixtures" GH_SHIM_FAIL="$shim_fail" \
    REVIEW_GATE_SETTINGS_FILE=/dev/null REVIEW_GATE_DOCS_ONLY="$mode" \
    REVIEW_GATE_MODE=enforce REVIEW_GATE_THREADS=enforce \
    REVIEW_GATE_TRUSTED_STATUS_CONTEXTS="" REVIEW_GATE_COMMENT_REVIEWERS="" \
    REVIEW_GATE_REVIEW_OBJECT_MIN_STATE="$min_state" \
    REVIEW_GATE_CARRY_FORWARD="" REVIEW_GATE_CARRY_FORWARD_EXCLUDE="$carry_exclude" \
    REVIEW_GATE_RENDER_PATHS="" \
    REVIEW_GATE_API_RETRY_DELAY_SECONDS=0 \
    GH_REPO=owner/repo PR_NUMBER=1 HEAD_SHA="$head" PR_BASE_SHA="$base_env" PR_AUTHOR="$AUTHOR" \
    "$predicate" 2>"$TMP/stderr")" || rc=$?
  cases=$((cases + 1))
  if [ "$rc" = 0 ] && [ "$line" = "$want" ]; then
    printf 'ok    %s\n' "$name"
  else
    printf 'FAIL  %s: exit=%s stdout=%s\n' "$name" "$rc" "$line" >&2
    sed 's/^/      /' "$TMP/stderr" >&2
    failures=$((failures + 1))
  fi
}

run_case "none approves a docs-only diff" none "$DOCS_HEAD" none \
  "verdict=approved detail=docs-only diff (REVIEW_GATE_DOCS_ONLY=none); no review evidence required"
run_case "bot keeps review evidence mandatory" bot "$DOCS_HEAD" none \
  "verdict=awaiting detail=no review evidence at $DOCS_HEAD yet"
run_case "none keeps code on the normal path" none "$CODE_HEAD" none \
  "verdict=awaiting detail=no review evidence at $CODE_HEAD yet"
run_case "an unresolved thread still blocks" none "$DOCS_HEAD" thread \
  "verdict=threads-open detail=1 unresolved review thread(s)"
run_case "a standing objection still blocks" none "$DOCS_HEAD" objection \
  "verdict=changes-requested detail=standing review changes requested (persists across pushes until re-approval or dismissal)"
run_case "a current-head suppressed finding still blocks" none "$DOCS_HEAD" suppressed \
  "verdict=suppressed-findings detail=1 suppressed finding(s) in a review body, carried by no thread: docs/policy.md:9"
run_case "a bodyless reply beside the waiver needs no review-comment read" none "$DOCS_HEAD" reply \
  "verdict=approved detail=docs-only diff (REVIEW_GATE_DOCS_ONLY=none); no review evidence required"
run_case "ordinary docs keep the waiver with policy exclusions configured" none "$DOCS_HEAD" policy \
  "verdict=approved detail=docs-only diff (REVIEW_GATE_DOCS_ONLY=none); no review evidence required"
run_case "a policy instruction needs review" none "$POLICY_HEAD" policy \
  "verdict=awaiting detail=no review evidence at $POLICY_HEAD yet"

# Must-fail control: a mutant that skips suppressed findings only while the
# docs waiver is active produces approval for the same fixture.
mutant="$REPO/skills/review-gate/scripts/review-predicate-mutant.sh"
sed 's/elif \[ -n "$supp_detail" \]; then/elif [ "$docs_only" = "0" ] \&\& [ -n "$supp_detail" ]; then/' \
  "$predicate" >"$mutant"
chmod +x "$mutant"
live_predicate="$predicate"
predicate="$mutant"
run_case "must-fail mutant exposes the suppressed branch" none "$DOCS_HEAD" suppressed \
  "verdict=approved detail=docs-only diff (REVIEW_GATE_DOCS_ONLY=none); no review evidence required"
predicate="$live_predicate"

# The writer's trusted default branch can advance after a PR forks. Its
# depth-one checkout already holds the base endpoint, but the shallow boundary
# hides the common ancestor required by the classifier's three-dot diff.
git -C "$REPO" checkout -q -b advanced-base "$BASE"
printf '%s\n' 'fn base_advanced() {}' >"$REPO/src/base.rs"
git -C "$REPO" add src/base.rs
git -C "$REPO" commit -q -m "advance base"
ADVANCED_BASE="$(git -C "$REPO" rev-parse HEAD)" || exit 1
REMOTE="$TMP/remote.git"
git clone -q --bare "$REPO" "$REMOTE"
git -C "$REMOTE" update-ref refs/pull/1/head "$DOCS_HEAD"

ADVANCED_SHALLOW="$TMP/advanced-shallow"
git clone -q --depth 1 "file://$REMOTE" "$ADVANCED_SHALLOW"
advanced_before="$(git -C "$ADVANCED_SHALLOW" rev-parse HEAD)" || exit 1
advanced_shallow_state="$(git -C "$ADVANCED_SHALLOW" rev-parse --is-shallow-repository)" || exit 1
if [ "$advanced_before" != "$ADVANCED_BASE" ] \
   || [ "$advanced_shallow_state" != "true" ] \
   || git -C "$ADVANCED_SHALLOW" cat-file -e "${DOCS_HEAD}^{commit}" 2>/dev/null; then
  printf '%s\n' "FATAL: advanced-base fixture is not a depth-one writer checkout" >&2
  exit 1
fi
predicate="$ADVANCED_SHALLOW/skills/review-gate/scripts/review-predicate.sh"
base_env="$ADVANCED_BASE"
run_case "an advanced shallow base resolves a fork PR head" none "$DOCS_HEAD" none \
  "verdict=approved detail=docs-only diff (REVIEW_GATE_DOCS_ONLY=none); no review evidence required"
cases=$((cases + 1))
advanced_after="$(git -C "$ADVANCED_SHALLOW" rev-parse HEAD)" || exit 1
advanced_status="$(git -C "$ADVANCED_SHALLOW" status --short)" || exit 1
if [ "$advanced_after" = "$advanced_before" ] && [ -z "$advanced_status" ]; then
  printf '%s\n' "ok    fork classification keeps the trusted checkout"
else
  printf '%s\n' "FAIL  fork classification changed the trusted checkout" >&2
  failures=$((failures + 1))
fi

# Must-fail control: the endpoint-only implementation sees the shallow base
# object, skips its history, and cannot classify the forked docs head.
MUTANT_SHALLOW="$TMP/mutant-shallow"
git clone -q --depth 1 "file://$REMOTE" "$MUTANT_SHALLOW"
predicate="$MUTANT_SHALLOW/skills/review-gate/scripts/review-predicate.sh"
mutant="$MUTANT_SHALLOW/skills/review-gate/scripts/review-predicate-mutant.sh"
mutant_anchor='  if [ "$shallow" = "true" ]; then'
mutant_count="$(awk -v anchor="$mutant_anchor" '$0 == anchor { count++ } END { print count + 0 }' "$predicate")" || exit 1
if [ "$mutant_count" != 1 ]; then
  printf 'FATAL: shallow-history mutant anchor count=%s\n' "$mutant_count" >&2
  exit 1
fi
awk -v anchor="$mutant_anchor" '{ if ($0 == anchor) print "  if false; then"; else print }' \
  "$predicate" >"$mutant" || exit 1
if cmp -s "$predicate" "$mutant"; then
  printf '%s\n' "FATAL: shallow-history mutant did not change the predicate" >&2
  exit 1
fi
chmod +x "$mutant"
predicate="$mutant"
run_case "must-fail: endpoint-only fetch cannot classify an advanced-base fork" none "$DOCS_HEAD" none \
  "verdict=awaiting detail=no review evidence at $DOCS_HEAD yet"

# Retain the missing-endpoint path. This checkout initially holds neither the
# older base nor the pull-request head.
MISSING_SHALLOW="$TMP/missing-shallow"
git clone -q --depth 1 "file://$REMOTE" "$MISSING_SHALLOW"
predicate="$MISSING_SHALLOW/skills/review-gate/scripts/review-predicate.sh"
base_env="$BASE"
run_case "a shallow checkout resolves missing endpoints" none "$DOCS_HEAD" none \
  "verdict=approved detail=docs-only diff (REVIEW_GATE_DOCS_ONLY=none); no review evidence required"
predicate="$live_predicate"
base_env=""

rc=0
line="$(REVIEW_GATE_SETTINGS_FILE=/dev/null REVIEW_GATE_DOCS_ONLY=invalid \
  "$predicate" --check-config 2>"$TMP/stderr")" || rc=$?
cases=$((cases + 1))
if [ "$rc" = 2 ] && [ -z "$line" ] \
   && grep -qxF 'review-gate-error=predicate-docs-only value=invalid' "$TMP/stderr"; then
  printf '%s\n' "ok    invalid policy fails configuration"
else
  printf 'FAIL  invalid policy: exit=%s stdout=%s\n' "$rc" "$line" >&2
  failures=$((failures + 1))
fi

chmod -x "$REPO/skills/harness-ci/scripts/harness-only"
rc=0
line="$(REVIEW_GATE_SETTINGS_FILE=/dev/null REVIEW_GATE_DOCS_ONLY=none \
  "$predicate" --check-config 2>"$TMP/stderr")" || rc=$?
cases=$((cases + 1))
if [ "$rc" = 2 ] && [ -z "$line" ] \
   && grep -q '^review-gate-error=predicate-docs-classifier value=' "$TMP/stderr"; then
  printf '%s\n' "ok    missing shared classifier fails configuration"
else
  printf 'FAIL  missing classifier: exit=%s stdout=%s\n' "$rc" "$line" >&2
  failures=$((failures + 1))
fi

printf 'docs-only-lane: %s cases, %s failures\n' "$cases" "$failures"
[ "$failures" = 0 ]
