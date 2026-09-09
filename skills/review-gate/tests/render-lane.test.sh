#!/usr/bin/env bash
# The render-only lane's decision table, offline: the real predicate behind
# the gh shim (lib/gh-shim.sh), fixtures from lib/selftest-fixtures.sh. A PR
# whose entire diff — the compare of its base tip against the head sha —
# sits under REVIEW_GATE_RENDER_PATHS approves with no review evidence;
# every refusal takes the normal gate path and is pinned
# by its stable code and value. Every approve is paired with the near-miss that must not.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
predicate="$(cd "$TEST_DIR/../scripts" && pwd)/review-predicate.sh"
[ -x "$predicate" ] || { echo "not executable: $predicate" >&2; exit 1; }

work="$(mktemp -d)" || exit 1
[ -n "$work" ] || { echo "FATAL: mktemp -d returned an empty path" >&2; exit 1; }
trap 'rm -rf -- "${work:?}"' EXIT
HEAD='a1b2c3d4e5f60718293a4b5c6d7e8f9012345678'
OTHER='ffffffffffffffffffffffffffffffffffffffff'
BASE='0000000000000000000000000000000000000001'
AUTHOR='author-under-test'
fixtures="$work/fixtures"
shim="$work/bin"
mkdir -p "$fixtures" "$shim"
cp "$TEST_DIR/lib/gh-shim.sh" "$shim/gh"
chmod +x "$shim/gh"
# shellcheck source=lib/selftest-fixtures.sh
. "$TEST_DIR/lib/selftest-fixtures.sh"

CFG_RENDER_PATHS=".agents/*;.claude/*;AGENTS.md;kendex.lock.json"
CFG_CARRY=""
CFG_BASHOPTS=""
CFG_ARGS=""

cases=0
failures=0
reset() { # no evidence anywhere, no threads, the lane on over the issue's example set
  printf '[]\n' >"$fixtures/reviews.json"
  printf '[]\n' >"$fixtures/comments.json"
  printf '{"check_runs":[]}\n' >"$fixtures/checkruns.json"
  printf '[]\n' >"$fixtures/statuses.json"
  threads >"$fixtures/graphql.json"
  jq -n --arg a "$AUTHOR" --arg base "$BASE" '{user:{login:$a},base:{sha:$base}}' >"$fixtures/pull.json"
  rm -f "$fixtures"/.urls.log "$fixtures"/compare.json "$fixtures"/compare.page2.json
  unset GH_SHIM_FAIL GH_SHIM_EMPTY || true
  CFG_RENDER_PATHS=".agents/*;.claude/*;AGENTS.md;kendex.lock.json"
  CFG_CARRY=""
  CFG_BASHOPTS=""
  CFG_ARGS=""
}
one_line() { # filename, status -> one PR files[] entry with a one-line patch
  delta_file "$1" "$2" '@@ -1 +1 @@
-before
+after' | jq -c .
}
renamed() { # previous-filename, filename -> one renamed PR files[] entry
  jq -cn --arg prev "$1" --arg fn "$2" '{filename:$fn,status:"renamed",previous_filename:$prev}'
}
lane_read_count() { grep -c "/compare/$BASE\.\.\." "$fixtures/.urls.log" 2>/dev/null || true; }
RENDER_SH="$(one_line ".agents/skills/hello/scripts/run.sh" modified)"
RENDER_CLAUDE="$(one_line ".claude/skills/hello/SKILL.md" added)"
RENDER_LOCK="$(one_line "kendex.lock.json" modified)"
RENDER_ROOT_MD="$(one_line "AGENTS.md" modified)"
CODE="$(one_line "src/main.rs" modified)"
DOCS="$(one_line "README.md" modified)"

# Each row supplies the diff, settings and any endpoint override. JSON stays
# compact so filenames with control characters retain their actual value.
rows="$(cat <<EOF
all render paths|[$RENDER_SH,$RENDER_CLAUDE,$RENDER_LOCK,$RENDER_ROOT_MD]|approved|||||||||render:4|1
later comparison page|[$RENDER_SH,$RENDER_LOCK]|approved||||||{"status":"ahead","commits":[]}|||render:2|
rename inside set|[$(renamed '.agents/skills/hello/scripts/run.sh' '.agents/skills/hello/scripts/start.sh')]|approved|||||||||render:1|
removed render|[$(one_line '.agents/skills/hello/scripts/run.sh' removed)]|approved|||||||||render:1|
code beside renders|[$RENDER_SH,$CODE]|awaiting|||||||render-outside-path|src/main.rs||
README beside renders|[$RENDER_SH,$DOCS]|awaiting|||||||render-outside-path|README.md||
rename from outside|[$(renamed 'src/main.rs' '.agents/skills/hello/scripts/run.sh')]|awaiting|||||||render-outside-path|src/main.rs||
rename source missing|[$(one_line '.agents/skills/hello/scripts/run.sh' renamed)]|awaiting|||||||render-rename-source|$BASE...$HEAD||
different tree|[$RENDER_SH]|awaiting|.agents/skills/other/*||||||render-outside-path|.agents/skills/hello/scripts/run.sh||
inherited nocasematch|[$(one_line '.AGENTS/skills/hello/scripts/run.sh' modified)]|awaiting|||nocasematch||||render-outside-path|.AGENTS/skills/hello/scripts/run.sh||
base read fails|[$RENDER_SH]|awaiting||||fail:pull|||render-base-read|1||
base sha incomplete|[$RENDER_SH]|awaiting||||base:abc123|||render-base-sha|abc123||
comparison read fails|[$RENDER_SH]|awaiting||||fail:compare|||render-compare-read|$BASE...$HEAD||
comparison empty read|[$RENDER_SH]|awaiting||||empty:compare|||render-compare-empty|$BASE...$HEAD||
comparison pages malformed|{"message":"Not Found"}|awaiting||||raw|||render-compare-pages|$BASE...$HEAD||
empty diff|[]|awaiting|||||||render-empty-diff|$BASE...$HEAD||
comparison file cap|$(jq -cn '[range(300) | {filename:".agents/skills/hello/f\(.)",status:"modified"}]')|awaiting|||||||render-file-cap|$BASE...$HEAD||
control character name|[$(one_line $'.agents/skills/hello/run.sh\n.agents/skills/evil.sh' modified)]|awaiting|||||||render-control-name|$BASE...$HEAD||
empty filename|[{"filename":"","status":"modified"}]|awaiting|||||||render-name-empty|$BASE...$HEAD||
standing objection|[$RENDER_SH]|changes-requested|||||objection|||||
unresolved thread|[$RENDER_SH]|threads-open|||||thread|||||
head evidence|[$RENDER_SH,$CODE]|approved|||||review||||reviewed|0
carried evidence|[$DOCS]|approved||docs|||ancestor||||carried|0
lane disabled|[$RENDER_SH]|awaiting|OFF|||||||||0
wildcard-only entry|[$RENDER_SH]|error|.agents/*;*||||||predicate-path-literal|REVIEW_GATE_RENDER_PATHS:*||
unsupported pattern|[$RENDER_SH]|error|.agents/[a]*||||||predicate-pattern|REVIEW_GATE_RENDER_PATHS:.agents/[a]*||
config wildcard-only|[]|error|*/*||||config||predicate-path-literal|REVIEW_GATE_RENDER_PATHS:*/*||
config valid|[]|config|||||config|||||
EOF
)" || exit 1
# name|files|verdict|paths|carry|bashopts|read fault|evidence|page2|code|value|protocol|compare count
while IFS='|' read -r name files want paths carry opts fault evidence page2 code value protocol reads; do
  reset
  [ -z "$paths" ] || CFG_RENDER_PATHS="$paths"
  [ "$paths" != OFF ] || CFG_RENDER_PATHS=""
  CFG_CARRY="$carry"; CFG_BASHOPTS="$opts"
  if [ "$fault" = raw ]; then printf '%s\n' "$files" >"$fixtures/compare.json"; else compare_fix ahead "$files"; fi
  [ -z "$page2" ] || printf '%s\n' "$page2" >"$fixtures/compare.page2.json"
  case "$fault" in
    fail:*) export GH_SHIM_FAIL="${fault#fail:}" ;;
    empty:*) export GH_SHIM_EMPTY="${fault#empty:}" ;;
    base:*) jq -n --arg a "$AUTHOR" --arg base "${fault#base:}" '{user:{login:$a},base:{sha:$base}}' >"$fixtures/pull.json" ;;
    ''|raw) : ;;
    *) exit 1 ;;
  esac
  case "$evidence" in
    objection) reviews_set "$(review reviewer CHANGES_REQUESTED)" ;;
    thread) threads false >"$fixtures/graphql.json" ;;
    review) reviews_set "$(review reviewer APPROVED)" ;;
    ancestor) reviews_set "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" ;;
    config) CFG_ARGS=--check-config ;;
    '') : ;;
    *) exit 1 ;;
  esac
  rc=0
  # shellcheck disable=SC2086 # CFG_ARGS is --check-config or empty.
  line="$(env ${CFG_BASHOPTS:+"BASHOPTS=$CFG_BASHOPTS"} PATH="$shim:$PATH" GH_SHIM_FIXTURES="$fixtures" \
    REVIEW_GATE_SETTINGS_FILE=/dev/null REVIEW_GATE_TRUSTED_STATUS_CONTEXTS="" REVIEW_GATE_COMMENT_REVIEWERS="" \
    REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS="" REVIEW_GATE_CARRY_FORWARD="$CFG_CARRY" \
    REVIEW_GATE_RENDER_PATHS="$CFG_RENDER_PATHS" GH_REPO=owner/repo PR_NUMBER=1 HEAD_SHA="$HEAD" PR_AUTHOR="$AUTHOR" \
    "$predicate" $CFG_ARGS 2>"$work/stderr")" || rc=$?
  want_exit=0; [ "$want" != error ] || want_exit=2
  case "$want" in
    error) expected="" ;;
    config) expected='review-gate-notice=predicate-config value=valid' ; line="${line%%$'\n'*}" ;;
    awaiting) expected="verdict=awaiting detail=no review evidence at $HEAD yet" ;;
    changes-requested) expected='verdict=changes-requested detail=standing review changes requested (persists across pushes until re-approval or dismissal)' ;;
    threads-open) expected='verdict=threads-open detail=1 unresolved review thread(s)' ;;
    approved)
      case "$protocol" in
        render:*) expected="verdict=approved detail=render-only diff (${protocol#render:} file(s) under REVIEW_GATE_RENDER_PATHS); no review evidence required" ;;
        reviewed) expected='verdict=approved detail=reviewed at head with no unresolved threads' ;;
        carried) expected="verdict=approved detail=review evidence at $OTHER carried to head across a carry-safe delta (docs)" ;;
        *) exit 1 ;;
      esac ;;
    *) exit 1 ;;
  esac
  diagnostic_ok=1
  if [ -n "$code" ]; then
    printf -v quoted '%q' "$value"
    kind=notice; [ "$want" != error ] || kind=error
    grep -qxF "review-gate-$kind=$code value=$quoted" "$work/stderr" || diagnostic_ok=0
  fi
  reads_ok=1
  if [ -n "$reads" ]; then
    read_count="$(lane_read_count)"
    [ "$read_count" = "$reads" ] || reads_ok=0
    if [ "$reads" = 1 ]; then grep -qxF "/repos/owner/repo/compare/$BASE...$HEAD?per_page=100" "$fixtures/.urls.log" || {
      # The shim records gh's endpoint argument without normalizing a leading slash.
      grep -qxF "repos/owner/repo/compare/$BASE...$HEAD?per_page=100" "$fixtures/.urls.log" || reads_ok=0
    }; fi
  fi
  cases=$((cases + 1))
  if [ "$rc" = "$want_exit" ] && [ "$line" = "$expected" ] && [ "$diagnostic_ok" = 1 ] && [ "$reads_ok" = 1 ]; then
    echo "ok    $name"
  else
    echo "FAIL  $name: exit=$rc stdout=$line code=$code value=$value reads=${read_count:-}" >&2
    failures=$((failures + 1))
  fi
done <<<"$rows"
[ "$cases" -gt 0 ] || exit 1
printf 'render-lane: %s cases, %s failures\n' "$cases" "$failures"
[ "$failures" = 0 ]
