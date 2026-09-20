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

predicate="$REPO/skills/review-gate/scripts/review-predicate.sh"
# shellcheck source=lib/selftest-fixtures.sh
. "$TEST_DIR/lib/selftest-fixtures.sh"
AUTHOR="author-under-test"
OTHER="ffffffffffffffffffffffffffffffffffffffff"
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
  case "$effect" in
    objection) reviews_set "$(review reviewer CHANGES_REQUESTED)" ;;
    thread) threads false >"$fixtures/graphql.json" ;;
    none) : ;;
    *) exit 1 ;;
  esac
  rc=0
  line="$(PATH="$shim:$PATH" GH_SHIM_FIXTURES="$fixtures" \
    REVIEW_GATE_SETTINGS_FILE=/dev/null REVIEW_GATE_DOCS_ONLY="$mode" \
    REVIEW_GATE_MODE=enforce REVIEW_GATE_THREADS=enforce \
    REVIEW_GATE_TRUSTED_STATUS_CONTEXTS="" REVIEW_GATE_COMMENT_REVIEWERS="" \
    REVIEW_GATE_CARRY_FORWARD="" REVIEW_GATE_RENDER_PATHS="" \
    REVIEW_GATE_API_RETRY_DELAY_SECONDS=0 \
    GH_REPO=owner/repo PR_NUMBER=1 HEAD_SHA="$head" PR_AUTHOR="$AUTHOR" \
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

