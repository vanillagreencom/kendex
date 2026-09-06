#!/usr/bin/env bash
# The render-only lane's decision table, offline: the real predicate behind
# the gh shim (lib/gh-shim.sh), fixtures from lib/selftest-fixtures.sh. A PR
# whose entire diff — the compare of its base tip against the head sha —
# sits under REVIEW_GATE_RENDER_PATHS approves with no review evidence;
# every refusal takes the normal gate path and is pinned
# by its REASON — a refusal for the wrong reason is a decision nothing here
# proved. Every approve is paired with the near-miss that must not.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
predicate="$(cd "$TEST_DIR/../scripts" && pwd)/review-predicate.sh"
[ -x "$predicate" ] || { echo "not executable: $predicate" >&2; exit 1; }

work="$(mktemp -d)"
[ -n "$work" ] || { echo "FATAL: mktemp -d returned an empty path" >&2; exit 1; }
trap 'rm -rf "$work"' EXIT
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
run() { # case-name, expected-verdict ("" = exit 2, no verdict), [stderr must contain], [stdout must contain]
  local name="$1" want="$2" reason="${3:-}" detail="${4:-}" want_exit=0 line rc=0 verdict
  [ -n "$want" ] || want_exit=2
  cases=$((cases + 1))
  # shellcheck disable=SC2086 # CFG_ARGS is the one word --check-config or nothing
  line="$(env ${CFG_BASHOPTS:+"BASHOPTS=$CFG_BASHOPTS"} \
    PATH="$shim:$PATH" GH_SHIM_FIXTURES="$fixtures" \
    REVIEW_GATE_SETTINGS_FILE=/dev/null \
    REVIEW_GATE_TRUSTED_STATUS_CONTEXTS="" REVIEW_GATE_COMMENT_REVIEWERS="" \
    REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS="" REVIEW_GATE_CARRY_FORWARD="$CFG_CARRY" \
    REVIEW_GATE_RENDER_PATHS="$CFG_RENDER_PATHS" \
    GH_REPO="owner/repo" PR_NUMBER=1 HEAD_SHA="$HEAD" PR_AUTHOR="$AUTHOR" \
    "$predicate" $CFG_ARGS 2>"$work/stderr")" || rc=$?
  verdict="${line#verdict=}"; verdict="${verdict%% *}"
  if [ "$rc" != "$want_exit" ]; then
    echo "FAIL  $name: exit $rc, wanted $want_exit" >&2
    sed 's/^/        /' "$work/stderr" >&2
    failures=$((failures + 1))
    return
  fi
  if [ "$want_exit" = "0" ] && [ -z "$CFG_ARGS" ] && [ "$verdict" != "$want" ]; then
    echo "FAIL  $name: verdict=$verdict, wanted $want" >&2
    sed 's/^/        /' "$work/stderr" >&2
    failures=$((failures + 1))
    return
  fi
  if [ -n "$reason" ] && ! grep -qF -- "$reason" "$work/stderr"; then
    echo "FAIL  $name: not for the reason under test ('$reason'):" >&2
    sed 's/^/        /' "$work/stderr" >&2
    failures=$((failures + 1))
    return
  fi
  case "$line" in
    *"$detail"*) ;;
    *)
      echo "FAIL  $name: verdict line lacks '$detail': $line" >&2
      failures=$((failures + 1))
      return
      ;;
  esac
  echo "ok    $name ($want)"
}
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
+after'
}
renamed() { # previous-filename, filename -> one renamed PR files[] entry
  jq -n --arg prev "$1" --arg fn "$2" '{filename:$fn,status:"renamed",previous_filename:$prev}'
}
lane_read_count() { grep -c "/compare/$BASE\.\.\." "$fixtures/.urls.log" 2>/dev/null || true; }
RENDER_SH="$(one_line ".agents/skills/hello/scripts/run.sh" modified)"
RENDER_CLAUDE="$(one_line ".claude/skills/hello/SKILL.md" added)"
RENDER_LOCK="$(one_line "kendex.lock.json" modified)"
RENDER_ROOT_MD="$(one_line "AGENTS.md" modified)"
CODE="$(one_line "src/main.rs" modified)"
DOCS="$(one_line "README.md" modified)"

echo "=== a render-only diff approves on the diff alone ==="

reset
compare_fix ahead "[$RENDER_SH,$RENDER_CLAUDE,$RENDER_LOCK,$RENDER_ROOT_MD]"
run "every file under the set, no review rows — approved on the diff" approved "" "render-only diff (4 file(s) under REVIEW_GATE_RENDER_PATHS)"
if [ "$(grep -c "/compare/$BASE\.\.\.$HEAD" "$fixtures/.urls.log")" != "1" ]; then
  echo "FAIL  the diff read is not the base-tip...HEAD_SHA comparison (a read unbound from the head would classify a later push):" >&2
  sed 's/^/        /' "$fixtures/.urls.log" >&2
  failures=$((failures + 1))
fi

reset
compare_fix ahead "[$RENDER_SH,$RENDER_LOCK]"
printf '{"status":"ahead","commits":[]}\n' >"$fixtures/compare.page2.json"
run "a two-page comparison classifies page one's files — later pages carry commits only" approved "" "(2 file(s)"

reset
compare_fix ahead "[$(renamed ".agents/skills/hello/scripts/run.sh" ".agents/skills/hello/scripts/start.sh")]"
run "a rename wholly inside the set approves" approved

reset
compare_fix ahead "[$(one_line ".agents/skills/hello/scripts/run.sh" removed)]"
run "a removed render file is still a render file" approved

echo "=== any file outside the set takes the normal path ==="

reset
compare_fix ahead "[$RENDER_SH,$CODE]"
run "one code file beside the renders refuses the whole diff" awaiting "'src/main.rs' is outside REVIEW_GATE_RENDER_PATHS"

reset
compare_fix ahead "[$RENDER_SH,$DOCS]"
run "a README beside the renders refuses — the set judges only what it names" awaiting "'README.md' is outside REVIEW_GATE_RENDER_PATHS"

reset
compare_fix ahead "[$(renamed "src/main.rs" ".agents/skills/hello/scripts/run.sh")]"
run "a rename INTO the set from outside refuses — the source was never covered" awaiting "'src/main.rs' is outside REVIEW_GATE_RENDER_PATHS"

reset
compare_fix ahead "[$(one_line ".agents/skills/hello/scripts/run.sh" renamed)]"
run "status renamed with no source name refuses" awaiting "a rename without a source name"

reset
CFG_RENDER_PATHS=".agents/skills/other/*"
compare_fix ahead "[$RENDER_SH]"
run "a set naming a different tree refuses" awaiting "is outside REVIEW_GATE_RENDER_PATHS"

reset
CFG_BASHOPTS=nocasematch
compare_fix ahead "[$(one_line ".AGENTS/skills/hello/scripts/run.sh" modified)]"
run "an inherited nocasematch never widens the set — a case-folded path refuses" awaiting "is outside REVIEW_GATE_RENDER_PATHS"

echo "=== a diff that cannot be enumerated takes the normal path ==="

reset
compare_fix ahead "[$RENDER_SH]"
GH_SHIM_FAIL=pull
export GH_SHIM_FAIL
run "the PR read fails — no base sha, normal path, no verdict lost to exit 2" awaiting "could not read PR #1 for its base sha"

reset
compare_fix ahead "[$RENDER_SH]"
jq -n --arg a "$AUTHOR" '{user:{login:$a},base:{sha:"abc123"}}' >"$fixtures/pull.json"
run "a PR read without a full base sha refuses — the comparison must bind two shas" awaiting "carries no full base sha"

reset
compare_fix ahead "[$RENDER_SH]"
GH_SHIM_FAIL=compare
export GH_SHIM_FAIL
run "the comparison read fails — normal path, no verdict lost to exit 2" awaiting "could not read the comparison $BASE...$HEAD"

reset
compare_fix ahead "[$RENDER_SH]"
GH_SHIM_EMPTY=compare
export GH_SHIM_EMPTY
run "a zero-byte comparison read is a broken read, not an empty diff" awaiting "produced zero bytes"

reset
printf '{"message":"Not Found"}\n' >"$fixtures/compare.json"
run "page one without a files array refuses as malformed" awaiting "malformed compare pages"

reset
compare_fix ahead "[]"
run "an empty diff has nothing to classify" awaiting "an empty diff (zero files)"

reset
compare_fix ahead "$(jq -n '[range(300) | {filename:".agents/skills/hello/f\(.)", status:"modified"}]')"
run "a list at the compare API's 300-entry cap cannot be proven complete" awaiting "at the compare API cap of 300 entries"

reset
compare_fix ahead "[$(one_line ".agents/skills/hello/run.sh
.agents/skills/evil.sh" modified)]"
run "a filename with a control character refuses — line-based matching cannot be proven" awaiting "control characters"

reset
compare_fix ahead "[$(jq -n '{filename:"", status:"modified"}')]"
run "a file without a name refuses" awaiting "a file without a name"

echo "=== the lane substitutes for evidence and nothing else ==="

reset
reviews_set "$(review "reviewer" CHANGES_REQUESTED)"
compare_fix ahead "[$RENDER_SH]"
run "a standing changes-requested outranks a render-only diff" changes-requested

reset
threads false >"$fixtures/graphql.json"
compare_fix ahead "[$RENDER_SH]"
run "an unresolved thread holds a render-only diff at threads-open" threads-open

reset
reviews_set "$(review "reviewer" APPROVED)"
compare_fix ahead "[$RENDER_SH,$CODE]"
run "evidence at head approves as reviewed, and the lane is never consulted" approved "" "reviewed at head"
if [ "$(lane_read_count)" != "0" ]; then
  echo "FAIL  evidence at head: the lane's comparison was read $(lane_read_count) time(s); a reviewed head pays no diff read" >&2
  failures=$((failures + 1))
fi

reset
CFG_CARRY="docs"
reviews_set "$(review "reviewer" APPROVED "2026-01-01T00:00:00Z" "$OTHER")"
compare_fix ahead "[$DOCS]"
run "a carry that opens the evidence term approves as carried, and the lane is never consulted" approved "" "carried to head"
if [ "$(lane_read_count)" != "0" ]; then
  echo "FAIL  carried: the lane's comparison was read $(lane_read_count) time(s); an opened evidence term reads no diff" >&2
  failures=$((failures + 1))
fi

reset
CFG_RENDER_PATHS=""
compare_fix ahead "[$RENDER_SH]"
run "an empty set is the lane off — the same render diff awaits review" awaiting
if [ "$(lane_read_count)" != "0" ]; then
  echo "FAIL  lane off: the lane's comparison was read $(lane_read_count) time(s); an empty set reads nothing" >&2
  failures=$((failures + 1))
fi

echo "=== configuration errors, never a wider set ==="

reset
CFG_RENDER_PATHS=".agents/*;*"
compare_fix ahead "[$RENDER_SH]"
run "an entry of wildcards alone exits 2" "" "REVIEW_GATE_RENDER_PATHS entry '*' names no literal path text"

reset
CFG_RENDER_PATHS=".agents/[a]*"
compare_fix ahead "[$RENDER_SH]"
run "a rejected glob spelling exits 2" "" "REVIEW_GATE_RENDER_PATHS pattern"

reset
CFG_RENDER_PATHS="*/*"
CFG_ARGS="--check-config"
run "--check-config refuses the same set without a PR" "" "names no literal path text"

reset
CFG_ARGS="--check-config"
run "--check-config accepts the issue's example set" "configuration is valid" "" "configuration is valid"

if [ "$failures" -ne 0 ]; then
  echo "render-lane: $failures of $cases case(s) FAILED" >&2
  exit 1
fi
echo "render-lane: $cases case(s), all pass"
