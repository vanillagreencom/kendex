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
# The real path classifier decides whether the predicate prepares sources. It
# runs behind a wrapper that refuses GitHub credentials, as the stubs do.
cp "$SKILL_DIR/../harness-ci/scripts/harness-only" "$REPO/.agents/skills/harness-ci/scripts/harness-only.real"
cat >"$REPO/.agents/skills/harness-ci/scripts/harness-only" <<'PATHS'
#!/usr/bin/env bash
[ -z "${GH_TOKEN+x}" ] && [ -z "${GITHUB_TOKEN+x}" ] && [ -z "${GH_CONFIG_DIR+x}" ] ||
  { echo "path classifier received GitHub credentials" >&2; exit 2; }
exec "$(dirname "$0")/harness-only.real" "$@"
PATHS
chmod +x "$REPO/.agents/skills/harness-ci/scripts/harness-only"
cp "$TEST_DIR/lib/gh-shim.sh" "$BIN/gh"
cat >"$BIN/kendex" <<'KENDEX'
#!/usr/bin/env bash
# The two calls source preparation makes, both without GitHub credentials.
# STUB_SOURCE_COUNT is how many sources the judged manifest declares, which is
# what the predicate caps; STUB_REFRESH_RC is the refresh's exit, 124 being the
# status a passed deadline returns. Every call is logged to STUB_KENDEX_LOG.
[ -z "${GH_TOKEN+x}" ] && [ -z "${GITHUB_TOKEN+x}" ] && [ -z "${GH_CONFIG_DIR+x}" ] ||
  { echo "source preparation received GitHub credentials" >&2; exit 2; }
printf '%s\n' "$*" >>"$STUB_KENDEX_LOG"
case "$*" in
  "source list")
    n=0
    while [ "$n" -lt "${STUB_SOURCE_COUNT:-1}" ]; do
      n=$((n + 1))
      printf 'project  source-%s  ref  [1 package(s)]\n' "$n"
    done
    ;;
  "source refresh") exit "${STUB_REFRESH_RC:-0}" ;;
  *) echo "unexpected kendex call: $*" >&2; exit 2 ;;
esac
KENDEX
chmod +x "$BIN/gh" "$BIN/kendex"
git -C "$REPO" init -q
git -C "$REPO" config maintenance.auto false
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@example.invalid
# HEAD changes a product file; RENDER changes only a file the committed
# inventory lists as generated.
printf 'base\n' >"$REPO/app.txt"
printf 'base\n' >"$REPO/gen.txt"
printf '["gen.txt"]\n' >"$REPO/.kendex-generated.json"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m base
BASE="$(git -C "$REPO" rev-parse HEAD)"
printf 'head\n' >"$REPO/app.txt"
git -C "$REPO" add app.txt
git -C "$REPO" commit -q -m head
HEAD="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q --detach "$BASE"
printf 'render\n' >"$REPO/gen.txt"
git -C "$REPO" add gen.txt
git -C "$REPO" commit -q -m render
RENDER="$(git -C "$REPO" rev-parse HEAD)"
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
  : >"$TMP/kendex.calls"
}

run_predicate() { # head, class, [VAR=value ...]
  local head="$1" class="$2"
  shift 2
  STUB_CLASS="$class" STUB_KENDEX_LOG="$TMP/kendex.calls" PATH="$BIN:$PATH" GH_SHIM_FIXTURES="$FIXTURES" \
    REVIEW_GATE_SETTINGS_FILE=/dev/null REVIEW_GATE_CLASS_POLICY="$ACTIVE" REVIEW_GATE_MODE=enforce \
    REVIEW_GATE_TRUSTED_STATUS_CONTEXTS="" REVIEW_GATE_COMMENT_REVIEWERS="" \
    REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS="" REVIEW_GATE_CARRY_FORWARD="" \
    REVIEW_GATE_RENDER_PATHS="" REVIEW_GATE_DOCS_ONLY=bot \
    GH_TOKEN=writer-token GITHUB_TOKEN=writer-token GH_CONFIG_DIR="$TMP/gh-config" \
    GH_REPO=owner/repo PR_NUMBER=1 HEAD_SHA="$head" PR_AUTHOR="$AUTHOR" \
    env ${@+"$@"} "$PREDICATE" 2>"$TMP/stderr"
}

run_gate() { # class, mode
  run_predicate "$HEAD" "$1" REVIEW_GATE_MODE="$2"
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

# Only the render proof reads prepared sources, so only a diff of generated
# paths alone prepares them. A product diff resolves its class with no kendex
# call even where the manifest is past the cap and the refresh would overrun;
# a diff of generated paths alone is the inverse, and the bounds below run on it.
while IFS='|' read -r label head stub_env want_calls; do
  [ -n "$label" ] || continue
  reset
  set +e
  # shellcheck disable=SC2086
  out="$(run_predicate "$head" micro $stub_env)"
  rc=$?
  set -e
  assert_eq "$rc:$out" "0:verdict=approved detail=change class micro requires no review evidence or thread wait" \
    "$label resolves its class"
  assert_eq "$(tr '\n' ',' <"$TMP/kendex.calls")" "$want_calls" "$label makes exactly these kendex calls"
done <<PREPARE
a product diff past both bounds|$HEAD|STUB_SOURCE_COUNT=99 STUB_REFRESH_RC=124|
a diff of generated paths alone|$RENDER|STUB_SOURCE_COUNT=1|source list,source refresh,
PREPARE

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

# Source preparation is bounded because the judged manifest chooses how much
# work it asks for. Either bound refuses THIS pull request's classification and
# writes no verdict, which leaves its status for the next pass.
while IFS='|' read -r label stub_env key value; do
  [ -n "$label" ] || continue
  reset
  set +e
  # shellcheck disable=SC2086
  out="$(run_predicate "$RENDER" render $stub_env)"
  rc=$?
  set -e
  assert_eq "$rc" "2" "$label refuses"
  assert_eq "$([ -z "$out" ] && echo empty || echo lines)" "empty" "$label writes no verdict"
  assert_eq "$(grep -Fxc "review-gate-error=$key value=$value" "$TMP/stderr")" "1" "$label is named by its own key and value"
  assert_eq "$(grep -c 'review-gate-error=predicate-policy-resolve' "$TMP/stderr")" "1" \
    "$label reaches the caller as predicate-policy-resolve"
done <<BOUNDS
a manifest past the source cap|STUB_SOURCE_COUNT=99|predicate-policy-sources|99/12
a refresh past its deadline|STUB_REFRESH_RC=124|predicate-policy-refresh-deadline|1/45s
BOUNDS

printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
