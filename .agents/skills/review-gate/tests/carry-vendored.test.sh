#!/usr/bin/env bash
# The vendored carry class's decision table, offline: the real predicate
# behind the gh shim (tests/lib/gh-shim.sh), fixtures from
# tests/lib/selftest-fixtures.sh. Every approve is paired with the
# near-miss that must not, and every refusal is pinned by its REASON — a
# refusal for the wrong reason is a decision nothing here proved.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$TEST_DIR/../scripts" && pwd)"
predicate="$SCRIPTS/review-predicate.sh"
[ -x "$predicate" ] || { echo "not executable: $predicate" >&2; exit 1; }

work="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 1; }
[ -n "$work" ] || { echo "FATAL: mktemp -d returned an empty path" >&2; exit 1; }
trap 'rm -rf "$work"' EXIT
HEAD='a1b2c3d4e5f60718293a4b5c6d7e8f9012345678'
OTHER='ffffffffffffffffffffffffffffffffffffffff'
AUTHOR='author-under-test'
fixtures="$work/fixtures"
shim="$work/bin"
mkdir -p "$fixtures" "$shim"
cp "$TEST_DIR/lib/gh-shim.sh" "$shim/gh"
chmod +x "$shim/gh"
# shellcheck source=lib/selftest-fixtures.sh
. "$TEST_DIR/lib/selftest-fixtures.sh"

LOCK=".kendex-lock.json"
RENDER=".agents/skills/hello/SKILL.md"
SCRIPT=".agents/skills/hello/scripts/run.sh"
OLD_HASH="$(sha256_of "old render")"
NEW_HASH="$(sha256_of "new render")"
CFG_CARRY="vendored"
CFG_CARRY_EXCLUDE=""

cases=0
failures=0
run() { # case-name, expected-verdict ("" = exit 2, no verdict), [stderr must contain]
  local name="$1" want="$2" reason="${3:-}" want_exit=0 line rc verdict
  [ -n "$want" ] || want_exit=2
  cases=$((cases + 1))
  rc=0
  line="$(PATH="$shim:$PATH" GH_SHIM_FIXTURES="$fixtures" \
    REVIEW_GATE_SETTINGS_FILE=/dev/null \
    REVIEW_GATE_TRUSTED_STATUS_CONTEXTS="" REVIEW_GATE_COMMENT_REVIEWERS="" \
    REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS="" REVIEW_GATE_API_RETRY_DELAY_SECONDS=0 \
    REVIEW_GATE_CARRY_FORWARD="$CFG_CARRY" REVIEW_GATE_CARRY_FORWARD_EXCLUDE="$CFG_CARRY_EXCLUDE" \
    GH_REPO="owner/repo" PR_NUMBER=1 HEAD_SHA="$HEAD" PR_AUTHOR="$AUTHOR" \
    "$predicate" 2>"$work/stderr")" || rc=$?
  verdict="${line#verdict=}"; verdict="${verdict%% *}"
  if [ "$rc" != "$want_exit" ]; then
    echo "FAIL  $name: exit $rc, wanted $want_exit" >&2
    sed 's/^/        /' "$work/stderr" >&2
    failures=$((failures + 1))
    return
  fi
  if [ "$want_exit" = "0" ] && [ "$verdict" != "$want" ]; then
    echo "FAIL  $name: verdict=$verdict, wanted $want" >&2
    sed 's/^/        /' "$work/stderr" >&2
    failures=$((failures + 1))
    return
  fi
  if [ -n "$reason" ] && ! grep -qF -- "$reason" "$work/stderr"; then
    echo "FAIL  $name: refused, but not for the reason under test ('$reason'):" >&2
    sed 's/^/        /' "$work/stderr" >&2
    failures=$((failures + 1))
    return
  fi
  echo "ok    $name ($want)"
}
reset() { # a reviewed ancestor, nothing at head, the vendored class on
  printf '[]\n' >"$fixtures/comments.json"
  printf '{"check_runs":[]}\n' >"$fixtures/checkruns.json"
  printf '[]\n' >"$fixtures/statuses.json"
  threads >"$fixtures/graphql.json"
  jq -n --arg a "$AUTHOR" '{user:{login:$a}}' >"$fixtures/pull.json"
  rm -f "$fixtures"/blob-*.json "$fixtures"/blobs.errors.json "$fixtures"/.failcount.* "$fixtures"/.urls.log
  unset GH_SHIM_FAIL GH_SHIM_EMPTY
  reviews_set "$(review "reviewer" APPROVED "2026-01-01T00:00:00Z" "$OTHER")"
  CFG_CARRY="vendored"
  CFG_CARRY_EXCLUDE=""
}
delta() { # [filename status]... -> compare.json, ahead, with a one-line patch each
  local files="[]" fn st
  while [ $# -gt 0 ]; do
    fn="$1"; st="$2"; shift 2
    files="$(jq -c --argjson f "$(delta_file "$fn" "$st" '@@ -1 +1 @@
-before
+after')" '. + [$f]' <<<"$files")"
  done
  compare_fix ahead "$files"
}
refresh() { # the genuine shape: the lock and the render move together
  lock_fix "$OTHER" "$RENDER=$OLD_HASH"
  lock_fix "$HEAD" "$RENDER=$NEW_HASH"
  blob "$HEAD" "$RENDER" "new render"
  delta "$RENDER" modified "$LOCK" modified
}

echo "=== the genuine render carries ==="

reset; refresh
run "a kendex refresh — lock and render, bytes as recorded — carries" approved

reset; refresh
CFG_CARRY="docs;vendored"
delta "$RENDER" modified "$LOCK" modified "README.md" modified
run "a refresh beside an unrecorded README carries with docs on too" approved

reset; refresh
delta "$RENDER" modified "$LOCK" modified "README.md" modified
run "the same README refuses when only 'vendored' is on — the class judges recorded paths alone" awaiting

reset
lock_fix "$OTHER"
lock_fix "$HEAD" "$RENDER=$NEW_HASH" "$SCRIPT=$(sha256_of "exit 0")"
blob "$HEAD" "$RENDER" "new render"
blob "$HEAD" "$SCRIPT" "exit 0"
delta "$RENDER" added "$SCRIPT" added "$LOCK" modified
run "a first install — files added, every one recorded and proven — carries" approved

reset
blob_absent "$OTHER" "$LOCK"
lock_fix "$HEAD" "$RENDER=$NEW_HASH"
blob "$HEAD" "$RENDER" "new render"
delta "$RENDER" added "$LOCK" added
run "adoption: no lock at the carry base, lock and files added and proven at head, carries" approved

reset
lock_fix "$OTHER" "$RENDER=$OLD_HASH"
lock_fix "$HEAD"
delta "$RENDER" removed "$LOCK" modified
run "a removal the lock records — recorded at base, gone from both at head — carries" approved

reset
lock_fix "$OTHER" "$RENDER=$OLD_HASH"
lock_fix "$HEAD" "$RENDER=$OLD_HASH"
delta "$LOCK" modified
run "a lock-only delta that records no new bytes (metadata) carries" approved

echo "=== a hand-edit never carries, whatever its extension ==="

reset; refresh
CFG_CARRY="docs;vendored"
blob "$HEAD" "$RENDER" "hand-edited render"
run "recorded .md whose bytes are not the record refuses with docs on" awaiting "is not the render the kendex lock records"

reset
lock_fix "$OTHER" "$RENDER=$OLD_HASH"
lock_fix "$HEAD" "$RENDER=$OLD_HASH"
blob "$HEAD" "$RENDER" "hand-edited render"
CFG_CARRY="docs;vendored"
delta "$RENDER" modified
run "recorded .md changed with the lock untouched refuses — the record still names the old bytes" awaiting "is not the render the kendex lock records"

reset
lock_fix "$OTHER" "$SCRIPT=$(sha256_of "exit 0")"
lock_fix "$HEAD" "$SCRIPT=$(sha256_of "exit 0")"
blob "$HEAD" "$SCRIPT" "exit 1"
CFG_CARRY="comments;vendored"
delta "$SCRIPT" modified
run "a recorded script changed by hand refuses (never falls through to 'comments')" awaiting "is not the render the kendex lock records"

echo "=== the lock cannot vouch for bytes the delta did not carry ==="

reset
lock_fix "$OTHER" "$RENDER=$OLD_HASH"
lock_fix "$HEAD" "$RENDER=$NEW_HASH"
delta "$LOCK" modified
run "a lock recording a new hash for a file the delta never touched refuses" awaiting "which this delta did not write"

reset
lock_fix "$OTHER"
lock_fix "$HEAD" "$RENDER=$NEW_HASH" "$SCRIPT=$(sha256_of "exit 0")"
blob "$HEAD" "$RENDER" "new render"
delta "$RENDER" added "$LOCK" modified
run "a lock newly recording two files while the delta adds one refuses" awaiting "which this delta did not write"

reset
lock_fix "$OTHER" "$RENDER=$OLD_HASH"
lock_fix "$HEAD" "$RENDER=$OLD_HASH"
delta "$RENDER" removed
run "a recorded file removed while the lock still records it refuses" awaiting "is recorded at head but removed"

reset
lock_fix "$OTHER" "$RENDER=$OLD_HASH"
lock_fix "$HEAD"
blob "$HEAD" "$RENDER" "new render"
delta "$RENDER" modified "$LOCK" modified
run "a file recorded at base, changed at head, and dropped from the record refuses" awaiting "with no record"

reset
lock_fix "$OTHER" "$RENDER=$OLD_HASH"
blob_absent "$HEAD" "$LOCK"
delta "$RENDER" removed "$LOCK" removed
run "the lock deleted at head refuses — an uninstall is not a render" awaiting "the kendex lock is gone at head"

reset
lock_fix "$OTHER" "$RENDER=$OLD_HASH"
lock_fix "$HEAD" "$RENDER=$NEW_HASH"
blob "$HEAD" "$RENDER" "new render"
compare_fix ahead "[$(jq -n --arg fn "$RENDER" '{filename:$fn,previous_filename:".agents/skills/old/SKILL.md",status:"renamed",patch:"@@ -1 +1 @@\n-a\n+b"}'),$(delta_file "$LOCK" modified '@@ -1 +1 @@
-a
+b')]"
run "a rename onto a recorded path refuses" awaiting "is a rename or copy of a recorded path"

echo "=== what GitHub cannot serve whole proves nothing ==="

reset; refresh
blob_shape "$HEAD" "$RENDER" '{"text":null,"isBinary":true,"isTruncated":false,"byteSize":10}'
run "a binary blob at a recorded path refuses" awaiting "is not a text blob"

reset; refresh
blob_shape "$HEAD" "$RENDER" "$(jq -n '{text:"new render",isBinary:false,isTruncated:true,byteSize:("new render"|utf8bytelength)}')"
run "a truncated blob refuses" awaiting "is not a text blob"

reset; refresh
blob_shape "$HEAD" "$RENDER" '{"text":"new render","isBinary":false,"isTruncated":false,"byteSize":9999}'
run "a text whose byte length is not the object's refuses" awaiting "is not a text blob"

reset; refresh
blob_absent "$HEAD" "$RENDER"
run "a recorded path with no object at head refuses" awaiting "is not a text blob"

reset; refresh
blob "$HEAD" "$LOCK" "not a lock at all"
run "a head lock that is not JSON refuses" awaiting "the kendex lock at head cannot be read as a lock"

reset; refresh
blob "$OTHER" "$LOCK" "{ not json"
run "a base lock that exists but cannot be read refuses" awaiting "the kendex lock at the carry base cannot be read as a lock"

reset; refresh
blob "$HEAD" "$LOCK" "$(jq -n --arg p "$RENDER" --arg a "$NEW_HASH" --arg b "$OLD_HASH" \
  '{version:5,entries:{"skill:hello:claude":{renderedFiles:{($p):$a}},"skill:hello:codex":{renderedFiles:{($p):$b}}}}')"
run "two entries recording one path with different bytes is a lock that cannot be read" awaiting "cannot be read as a lock"

echo "=== fail loud, and the other rules still hold ==="

reset; refresh
export GH_SHIM_FAIL=blobs
run "a failed blob read is exit 2, never a guessed carry" ""

reset; refresh
export GH_SHIM_EMPTY=blobs
run "a zero-byte blob producer is exit 2" ""

reset; refresh
printf '{"errors":[{"message":"nope"}],"data":null}\n' >"$fixtures/blobs.errors.json"
run "a GraphQL error envelope is exit 2, never read as objects absent" ""

reset; refresh
printf '{"version":5}\n' >"$fixtures/blob-$HEAD-${LOCK//\//__}.json"
run "an object that is not a Blob at the lock path is a lock that cannot be read" awaiting "cannot be read as a lock"

reset; refresh
CFG_CARRY_EXCLUDE=".agents/*"
run "an exclusion glob outranks the vendored class" awaiting "matched by REVIEW_GATE_CARRY_FORWARD_EXCLUDE"

reset; refresh
CFG_CARRY="docs"
run "the class off: a refresh refuses (the lock is not docs)" awaiting

reset; refresh
CFG_CARRY="vendorred"
run "a misspelt class is a config error" ""

reset; refresh
reviews_set "$(review "reviewer" CHANGES_REQUESTED "2026-01-02T00:00:00Z" "$OTHER")"
run "carried evidence never outranks a standing changes-requested" changes-requested

reset; refresh
reviews_set
run "no ancestor evidence: nothing to carry, the class is never a waiver" awaiting

reset
lock_fix "$OTHER" "$RENDER=$OLD_HASH"
lock_fix "$HEAD" "$RENDER=$NEW_HASH"
blob "$HEAD" "$RENDER" "new render"
delta "$RENDER" modified "$LOCK" modified
run "reads: two lock objects and one file batch" approved
graphql_reads="$(grep -c '^graphql$' "$fixtures/.urls.log" || true)"
if [ "$graphql_reads" != "4" ]; then
  echo "FAIL  reads: expected exactly 4 GraphQL calls (threads, lock@head, lock@base, one file batch), got:" >&2
  cat "$fixtures/.urls.log" >&2
  failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
  echo "carry-vendored: $failures of $cases case(s) FAILED" >&2
  exit 1
fi
echo "carry-vendored: $cases case(s), all pass"
