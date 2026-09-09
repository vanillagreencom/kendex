#!/usr/bin/env bash
# The vendored carry class's decision table, offline: the real predicate
# behind the gh shim (lib/gh-shim.sh), fixtures from lib/selftest-fixtures.sh.
# A delta file under a path the repository committed in
# REVIEW_GATE_VENDORED_PATHS carries whatever its extension; trust is the
# committed set, never the bytes. Every approve is paired with the near-miss
# that must not, and every refusal is pinned by its REASON — a refusal for
# the wrong rule is a decision nothing here proved.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
predicate="$(cd "$TEST_DIR/../scripts" && pwd)/review-predicate.sh"
[ -x "$predicate" ] || { echo "not executable: $predicate" >&2; exit 1; }

work="$(mktemp -d)" || exit 1
[ -n "$work" ] || { echo "FATAL: mktemp -d returned an empty path" >&2; exit 1; }
trap 'rm -rf -- "${work:?}"' EXIT
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
CFG_BASHOPTS=""

cases=0
failures=0
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
  CFG_BASHOPTS=""
}
one_line() { # filename, status -> one compare files[] entry with a one-line patch
  delta_file "$1" "$2" '@@ -1 +1 @@
-before
+after' | jq -c .
}
renamed() { # previous-filename, filename -> one renamed compare files[] entry
  jq -cn --arg prev "$1" --arg fn "$2" --arg patch '@@ -1 +1 @@
-before
+after' '{filename:$fn,status:"renamed",previous_filename:$prev,patch:$patch}'
}
RENDER_SH="$(one_line ".agents/skills/hello/scripts/run.sh" modified)"
RENDER_TOML="$(one_line ".agents/skills/hello/kendex.settings.toml.example" added)"
RENDER_JSON="$(one_line ".agents/skills/hello/schema.json" removed)"
CODE="$(one_line "src/main.rs" modified)"
DOCS="$(one_line "README.md" modified)"

# name|files|verdict|carry|paths|exclude|bashopts|evidence|code|value
rows="$(cat <<EOF
shell TOML JSON|[$RENDER_SH,$RENDER_TOML,$RENDER_JSON]|approved|||||||
docs beside render|[$RENDER_SH,$DOCS]|approved|docs;vendored||||||
second path entry|[$RENDER_SH]|approved||.claude/skills/*;.agents/*|||||
README outside class|[$RENDER_SH,$DOCS]|awaiting|||||||
code outside class|[$RENDER_SH,$CODE]|awaiting|||||||
class disabled|[$RENDER_SH]|awaiting|docs||||||
different tree|[$RENDER_SH]|awaiting||.agents/skills/other/*|||||
excluded path|[$RENDER_SH]|awaiting|||.agents/skills/hello/*|||predicate-carry-excluded|.agents/skills/hello/scripts/run.sh
control character destination|[$(one_line $'.agents/skills/hello/run.sh\n.agents/skills/evil.sh' modified)]|awaiting||||||predicate-carry-control-name|$OTHER...$HEAD
rename inside set|[$(renamed '.agents/skills/hello/scripts/run.sh' '.agents/skills/hello/scripts/start.sh')]|approved|||||||
rename from outside|[$(renamed 'src/main.rs' '.agents/skills/hello/scripts/run.sh')]|awaiting|||||||
rename from excluded|[$(renamed '.agents/skills/hello/AGENTS.md' '.agents/skills/hello/scripts/run.sh')]|awaiting|||.agents/skills/hello/AGENTS.md|||predicate-carry-excluded|.agents/skills/hello/AGENTS.md
control character source|[$(renamed $'.agents/skills/hello/ru\nn.sh' '.agents/skills/hello/scripts/run.sh')]|awaiting||||||predicate-carry-control-name|$OTHER...$HEAD
rename source absent|[$(one_line '.agents/skills/hello/scripts/run.sh' renamed)]|awaiting|||||||
rename source null|[$(one_line '.agents/skills/hello/scripts/run.sh' renamed | jq -c '.previous_filename = null')]|awaiting|||||||
inherited nocasematch|[$(one_line '.AGENTS/skills/hello/scripts/run.sh' modified)]|awaiting||||nocasematch|||
standing objection|[$RENDER_SH]|changes-requested|||||objection||
no ancestor evidence|[$RENDER_SH]|awaiting|||||none||
empty set|[$RENDER_SH]|error||OFF||||predicate-vendored-empty|
wildcard-only entry|[$RENDER_SH]|error||.agents/*;*||||predicate-path-literal|REVIEW_GATE_VENDORED_PATHS:*
only wildcards|[$RENDER_SH]|error||**||||predicate-path-literal|REVIEW_GATE_VENDORED_PATHS:**
wildcards and separator|[$RENDER_SH]|error||*/*||||predicate-path-literal|REVIEW_GATE_VENDORED_PATHS:*/*
wildcards and dot|[$RENDER_SH]|error||*.*||||predicate-path-literal|REVIEW_GATE_VENDORED_PATHS:*.*
multi-segment glob|[$(one_line 'skills/hello/scripts/run.sh' modified)]|approved||skills/*/scripts/*|||||
unsupported spelling while disabled|[$DOCS]|error|docs|.agents/[a]*||||predicate-pattern|REVIEW_GATE_VENDORED_PATHS:.agents/[a]*
empty set while disabled|[$DOCS]|approved|docs|OFF|||||
EOF
)" || exit 1
while IFS='|' read -r name files want carry paths exclude opts evidence code value; do
  reset
  [ -z "$carry" ] || CFG_CARRY="$carry"
  [ -z "$paths" ] || CFG_VENDORED_PATHS="$paths"
  [ "$paths" != OFF ] || CFG_VENDORED_PATHS=""
  CFG_CARRY_EXCLUDE="$exclude"; CFG_BASHOPTS="$opts"
  compare_fix ahead "$files"
  case "$evidence" in
    objection) reviews_set "$(review reviewer CHANGES_REQUESTED '2026-01-02T00:00:00Z' "$OTHER")" ;;
    none) reviews_set ;;
    '') : ;;
    *) exit 1 ;;
  esac
  rc=0
  line="$(env ${CFG_BASHOPTS:+"BASHOPTS=$CFG_BASHOPTS"} PATH="$shim:$PATH" GH_SHIM_FIXTURES="$fixtures" \
    REVIEW_GATE_SETTINGS_FILE=/dev/null REVIEW_GATE_TRUSTED_STATUS_CONTEXTS="" REVIEW_GATE_COMMENT_REVIEWERS="" \
    REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS="" REVIEW_GATE_CARRY_FORWARD="$CFG_CARRY" \
    REVIEW_GATE_CARRY_FORWARD_EXCLUDE="$CFG_CARRY_EXCLUDE" REVIEW_GATE_VENDORED_PATHS="$CFG_VENDORED_PATHS" \
    GH_REPO=owner/repo PR_NUMBER=1 HEAD_SHA="$HEAD" PR_AUTHOR="$AUTHOR" "$predicate" 2>"$work/stderr")" || rc=$?
  want_exit=0; [ "$want" != error ] || want_exit=2
  case "$want" in
    error) expected="" ;;
    awaiting) expected="verdict=awaiting detail=no review evidence at $HEAD yet" ;;
    approved) expected="verdict=approved detail=review evidence at $OTHER carried to head across a carry-safe delta ($CFG_CARRY)" ;;
    changes-requested) expected='verdict=changes-requested detail=standing review changes requested (persists across pushes until re-approval or dismissal)' ;;
    *) exit 1 ;;
  esac
  diagnostic_ok=1
  if [ -n "$code" ]; then
    printf -v quoted '%q' "$value"
    kind=notice; [ "$want" != error ] || kind=error
    grep -qxF "review-gate-$kind=$code value=$quoted" "$work/stderr" || diagnostic_ok=0
  fi
  cases=$((cases + 1))
  if [ "$rc" = "$want_exit" ] && [ "$line" = "$expected" ] && [ "$diagnostic_ok" = 1 ]; then
    echo "ok    $name"
  else
    echo "FAIL  $name: exit=$rc stdout=$line code=$code value=$value" >&2
    failures=$((failures + 1))
  fi
done <<<"$rows"
[ "$cases" -gt 0 ] || exit 1
printf 'vendored-class: %s cases, %s failures\n' "$cases" "$failures"
[ "$failures" = 0 ]
