#!/usr/bin/env bash
# Active class policy integration through the real review predicate.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "$2"; }
assert_eq() {
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3" "expected [$2], got [$1]"; fi
}

REPO="$TMP/repo"
FIXTURES="$TMP/fixtures"
BIN="$TMP/bin"
mkdir -p "$REPO/.agents/skills" "$FIXTURES" "$BIN"
cp -R "$SKILL_DIR" "$REPO/.agents/skills/review-gate"
mkdir -p "$REPO/.agents/skills/harness-ci/scripts"
cat >"$REPO/.agents/skills/harness-ci/scripts/change-class" <<'CLASSIFIER'
#!/usr/bin/env bash
# The shipped classifier's shape as review-policy reads it: a class on stdout
# and, on stderr, the class line whose measured= marker says whether a rule
# earned that class or the classifier fell back to standard.
[ -z "${GH_TOKEN+x}" ] && [ -z "${GITHUB_TOKEN+x}" ] && [ -z "${GH_CONFIG_DIR+x}" ] ||
  { echo "classifier received GitHub credentials" >&2; exit 2; }
printf 'class: class=%s measured=%s cause=stub\n' "$STUB_CLASS" "${STUB_MEASURED:-true}" >&2
printf 'change_class=%s\n' "$STUB_CLASS"
CLASSIFIER
chmod +x "$REPO/.agents/skills/harness-ci/scripts/change-class"
cp "$TEST_DIR/lib/gh-shim.sh" "$BIN/gh"
cat >"$BIN/kendex" <<'KENDEX'
#!/usr/bin/env bash
[ "$*" = "source refresh" ] || { echo "unexpected kendex call: $*" >&2; exit 2; }
[ -z "${GH_TOKEN+x}" ] && [ -z "${GITHUB_TOKEN+x}" ] && [ -z "${GH_CONFIG_DIR+x}" ] ||
  { echo "source refresh received GitHub credentials" >&2; exit 2; }
KENDEX
chmod +x "$BIN/gh" "$BIN/kendex"
git -C "$REPO" init -q
git -C "$REPO" config maintenance.auto false
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@example.invalid
printf 'base\n' >"$REPO/app.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m base
BASE="$(git -C "$REPO" rev-parse HEAD)"
printf 'head\n' >"$REPO/app.txt"
git -C "$REPO" add app.txt
git -C "$REPO" commit -q -m head
HEAD="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q --detach "$BASE"

# shellcheck source=lib/selftest-fixtures.sh
. "$TEST_DIR/lib/selftest-fixtures.sh"
AUTHOR=author-under-test
ACTIVE='render:none;trivial:none;micro:none;small:bot;standard:current'
PREDICATE="$REPO/.agents/skills/review-gate/scripts/review-predicate.sh"

reset() {
  printf '[]\n' >"$FIXTURES/reviews.json"
  printf '[]\n' >"$FIXTURES/comments.json"
  printf '{"check_runs":[]}\n' >"$FIXTURES/checkruns.json"
  printf '[]\n' >"$FIXTURES/statuses.json"
  fixtures="$FIXTURES" threads >"$FIXTURES/graphql.json"
  jq -n --arg a "$AUTHOR" --arg base "$BASE" '{user:{login:$a},base:{sha:$base}}' >"$FIXTURES/pull.json"
  rm -f "$FIXTURES/.urls.log"
}

run_gate() { # class, mode
  STUB_CLASS="$1" PATH="$BIN:$PATH" GH_SHIM_FIXTURES="$FIXTURES" \
    REVIEW_GATE_SETTINGS_FILE=/dev/null REVIEW_GATE_CLASS_POLICY="$ACTIVE" REVIEW_GATE_MODE="$2" \
    REVIEW_GATE_TRUSTED_STATUS_CONTEXTS="" REVIEW_GATE_COMMENT_REVIEWERS="" \
    REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS="" REVIEW_GATE_CARRY_FORWARD="" \
    REVIEW_GATE_RENDER_PATHS="" REVIEW_GATE_DOCS_ONLY=bot \
    GH_TOKEN=writer-token GITHUB_TOKEN=writer-token GH_CONFIG_DIR="$TMP/gh-config" \
    GH_REPO=owner/repo PR_NUMBER=1 HEAD_SHA="$HEAD" PR_AUTHOR="$AUTHOR" \
    "$PREDICATE" 2>"$TMP/stderr"
}

while IFS='|' read -r class mode evidence want detail; do
  reset
  if [ "$evidence" = review ]; then
    fixtures="$FIXTURES" reviews_set "$(review reviewer APPROVED)"
  elif [ "$evidence" = late ]; then
    fixtures="$FIXTURES" reviews_set "$(review reviewer CHANGES_REQUESTED)"
    fixtures="$FIXTURES" threads false >"$FIXTURES/graphql.json"
  fi
  out="$(run_gate "$class" "$mode")"
  assert_eq "$out" "verdict=$want detail=$detail" "$class with $evidence evidence under $mode"
  if [ "$class" = render ] && [ "$evidence" = late ]; then
    if grep -Eq '/reviews|graphql' "$FIXTURES/.urls.log"; then
      bad "render ignores a late bot result and thread" "$(cat "$FIXTURES/.urls.log")"
    else
      ok "render ignores a late bot result and thread"
    fi
  fi
done <<ROWS
render|enforce|late|approved|change class render requires no review evidence or thread wait
trivial|enforce|none|approved|change class trivial requires no review evidence or thread wait
micro|enforce|none|approved|change class micro requires no review evidence or thread wait
small|enforce|none|awaiting|no review evidence at $HEAD yet
small|off|none|awaiting|no review evidence at $HEAD yet
small|enforce|review|approved|reviewed at head with no unresolved threads
standard|enforce|none|awaiting|no review evidence at $HEAD yet
standard|off|none|approved|review gate disabled by settings (REVIEW_GATE_MODE=off)
ROWS

# Must-fail inverse: removing the early approval must fail an exempt class.
count="$(grep -Fc '    none)' "$PREDICATE" || true)"
assert_eq "$count" "1" "control has one no-review predicate branch"
sed 's/^    none)$/    required)/' "$PREDICATE" >"$TMP/predicate-mutant"
cat "$TMP/predicate-mutant" >"$PREDICATE"
reset
set +e
out="$(run_gate render enforce)"
rc=$?
set -e
if [ "$rc" -eq 0 ] && [ "$out" = 'verdict=approved detail=change class render requires no review evidence or thread wait' ]; then
  bad "must-fail: render must bypass review reads" "$out"
else
  ok "must-fail: removing the exemption fails the render contract"
fi

printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
