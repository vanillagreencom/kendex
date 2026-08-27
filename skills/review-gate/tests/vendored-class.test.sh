#!/usr/bin/env bash
# The vendored carry class's decision table, offline: the real predicate
# behind the gh shim (lib/gh-shim.sh), fixtures from lib/selftest-fixtures.sh.
# A delta file under a path the repository committed in
# REVIEW_GATE_VENDORED_PATHS carries whatever its extension; trust is the
# committed set, never the bytes. Every approve is paired with the near-miss
# that must not, and every refusal is pinned by its REASON — a refusal for
# the wrong reason is a decision nothing here proved.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
predicate="$(cd "$TEST_DIR/../scripts" && pwd)/review-predicate.sh"
[ -x "$predicate" ] || { echo "not executable: $predicate" >&2; exit 1; }

work="$(mktemp -d)"
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

CFG_CARRY="vendored"
CFG_VENDORED_PATHS=".agents/*"
CFG_CARRY_EXCLUDE=""

cases=0
failures=0
run() { # case-name, expected-verdict ("" = exit 2, no verdict), [stderr must contain]
  local name="$1" want="$2" reason="${3:-}" want_exit=0 line rc=0 verdict
  [ -n "$want" ] || want_exit=2
  cases=$((cases + 1))
  line="$(PATH="$shim:$PATH" GH_SHIM_FIXTURES="$fixtures" \
    REVIEW_GATE_SETTINGS_FILE=/dev/null \
    REVIEW_GATE_TRUSTED_STATUS_CONTEXTS="" REVIEW_GATE_COMMENT_REVIEWERS="" \
    REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS="" \
    REVIEW_GATE_CARRY_FORWARD="$CFG_CARRY" REVIEW_GATE_CARRY_FORWARD_EXCLUDE="$CFG_CARRY_EXCLUDE" \
    REVIEW_GATE_VENDORED_PATHS="$CFG_VENDORED_PATHS" \
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
reset() { # a reviewed ancestor, nothing at head, the class on over .agents/*
  printf '[]\n' >"$fixtures/comments.json"
  printf '{"check_runs":[]}\n' >"$fixtures/checkruns.json"
  printf '[]\n' >"$fixtures/statuses.json"
  threads >"$fixtures/graphql.json"
  jq -n --arg a "$AUTHOR" '{user:{login:$a}}' >"$fixtures/pull.json"
  rm -f "$fixtures"/.urls.log
  reviews_set "$(review "reviewer" APPROVED "2026-01-01T00:00:00Z" "$OTHER")"
  CFG_CARRY="vendored"
  CFG_VENDORED_PATHS=".agents/*"
  CFG_CARRY_EXCLUDE=""
}
one_line() { # filename, status -> one compare files[] entry with a one-line patch
  delta_file "$1" "$2" '@@ -1 +1 @@
-before
+after'
}
RENDER_SH="$(one_line ".agents/skills/hello/scripts/run.sh" modified)"
RENDER_TOML="$(one_line ".agents/skills/hello/kendex.settings.toml.example" added)"
RENDER_JSON="$(one_line ".agents/skills/hello/schema.json" removed)"
CODE="$(one_line "src/main.rs" modified)"
DOCS="$(one_line "README.md" modified)"

echo "=== a render under the committed set carries ==="

reset
compare_fix ahead "[$RENDER_SH,$RENDER_TOML,$RENDER_JSON]"
run "shell modified, TOML added, JSON removed under the set — carries, whatever the extension or status" approved

reset
CFG_CARRY="docs;vendored"
compare_fix ahead "[$RENDER_SH,$DOCS]"
run "a render delta beside an unlisted README carries with docs on too" approved

reset
CFG_VENDORED_PATHS=".claude/skills/*;.agents/*"
compare_fix ahead "[$RENDER_SH]"
run "any entry of the set matches — the second one here" approved

echo "=== outside the set, or the class off, nothing rides ==="

reset
compare_fix ahead "[$RENDER_SH,$DOCS]"
run "the same README refuses when only vendored is on — the set judges its own paths alone" awaiting

reset
compare_fix ahead "[$RENDER_SH,$CODE]"
run "one code file outside the set refuses the whole delta" awaiting

reset
CFG_CARRY="docs"
compare_fix ahead "[$RENDER_SH]"
run "the class off: a path set alone enables nothing" awaiting

reset
CFG_VENDORED_PATHS=".agents/skills/other/*"
compare_fix ahead "[$RENDER_SH]"
run "a set naming a different tree does not match" awaiting

echo "=== the deny list and the boundaries hold ==="

reset
CFG_CARRY_EXCLUDE=".agents/skills/hello/*"
compare_fix ahead "[$RENDER_SH]"
run "an exclusion on the same path outranks the class" awaiting "matched by REVIEW_GATE_CARRY_FORWARD_EXCLUDE"

reset
compare_fix ahead "[$(one_line ".agents/skills/hello/run.sh
.agents/skills/evil.sh" modified)]"
run "a filename with a control character refuses — line-based matching cannot be proven" awaiting "control characters"

reset
reviews_set "$(review "reviewer" CHANGES_REQUESTED "2026-01-02T00:00:00Z" "$OTHER")"
compare_fix ahead "[$RENDER_SH]"
run "carried evidence never outranks a standing changes-requested" changes-requested

reset
reviews_set
compare_fix ahead "[$RENDER_SH]"
run "no ancestor evidence: nothing to carry, the class is never a waiver" awaiting

echo "=== configuration errors, never a wider class ==="

reset
CFG_VENDORED_PATHS=""
compare_fix ahead "[$RENDER_SH]"
run "the class enabled over an empty set exits 2" "" "names no path"

reset
CFG_VENDORED_PATHS=".agents/*;*"
compare_fix ahead "[$RENDER_SH]"
run "an entry of wildcards alone exits 2" "" "wildcards alone"

reset
CFG_VENDORED_PATHS="**"
compare_fix ahead "[$RENDER_SH]"
run "a set that is only wildcards exits 2" "" "wildcards alone"

reset
CFG_CARRY="docs"
CFG_VENDORED_PATHS=".agents/[a]*"
compare_fix ahead "[$DOCS]"
run "a rejected glob spelling exits 2 even with the class off" "" "REVIEW_GATE_VENDORED_PATHS pattern"

reset
CFG_CARRY="docs"
CFG_VENDORED_PATHS=""
compare_fix ahead "[$DOCS]"
run "an empty set with the class off is no error — docs still carries" approved

if [ "$failures" -ne 0 ]; then
  echo "vendored-class: $failures of $cases case(s) FAILED" >&2
  exit 1
fi
echo "vendored-class: $cases case(s), all pass"
