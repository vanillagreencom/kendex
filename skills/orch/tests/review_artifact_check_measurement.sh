#!/usr/bin/env bash
# Tests for review-artifact-check's MEASUREMENT gates: the zero_sample
# rejection, the perf-payload evidence requirement, the declared
# instrument-failure escape, and the rule that a gate which could not run is
# never read as a clean artifact. Split from review_artifact_check.sh, which
# owns location, freshness, and finding-shape acceptance.
#
# One table per gate, one asserted row per shape. A row's `expect` names the
# result fields it pins and `observe` reads exactly those, so a row fails on
# the field it names; a missing key reads ABSENT, so `null` means a real null.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
CHECK="$REPO_ROOT/skills/orch/scripts/review-artifact-check"
# shellcheck source=lib/waiter-assertions.sh
source "$TEST_DIR/lib/waiter-assertions.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

DELEG=1750000000
BEFORE=$((DELEG - 100))
AFTER=$((DELEG + 100))
LATER=$((DELEG + 200))
REAL_JQ="$(command -v jq)"
DECLARATION='"measurement_failed":"cargo-mutants selected 0 mutants for the changed file"'

# A jq that fails ONE content gate, and only for a file named torn-newest, so
# the glob rows exercise the gate's disposition rather than the per-file
# `.verdict` branch.
TORN_SHIM="$TMP_ROOT/jqshim-torn"
mkdir -p "$TORN_SHIM"
printf '#!/usr/bin/env bash\nprog=""; target=""\nfor a in "$@"; do\n  case "$a" in\n    *"gate:no-review"*) prog=1 ;;\n    *torn-newest*) target=1 ;;\n  esac\ndone\nif [ -n "$prog" ] && [ -n "$target" ]; then echo "jq: error: simulated torn read" >&2; exit 5; fi\nexec %s "$@"\n' "$REAL_JQ" > "$TORN_SHIM/jq"
chmod +x "$TORN_SHIM/jq"

# body NAME — the artifact bodies the glob rows stage, by name.
body() {
  case "$1" in
    measured) printf '{"agent":"r","verdict":"pass","summary":"mutation: killed 3/3; stability: 10/10 at 16 threads","blockers":[],"suggestions":[]}' ;;
    zeroed) printf '{"agent":"r","verdict":"pass","summary":"mutation: killed 0/0; stability: 0/0 at 16 threads"}' ;;
    decl_bad) printf '{"agent":"r","verdict":"pass","summary":"mutation: killed 0/0","blockers":[],"suggestions":[],"measurement_failed":"n/a"}' ;;
    clean) printf '{"agent":"r","verdict":"pass","summary":"clean","blockers":[],"suggestions":[],"qa_metadata":{}}' ;;
    *) echo "body: unknown name $1" >&2; exit 1 ;;
  esac
}

# --- harness -----------------------------------------------------------------

RUN_SEQ=0
fresh_run() {
  RUN="$TMP_ROOT/runs/$((++RUN_SEQ))"
  WT="$RUN/wt"
  mkdir -p "$WT/tmp"
  F="$WT/tmp/review-external-F.json"
  ERR="$RUN/stderr"
}

# run_check ARGS... — OUT is the JSON, RC the exit. %W, %F and %D in ARGS are
# the staged worktree, the --file target and the delegation boundary.
run_check() {
  local args=() a
  for a in "$@"; do a="${a//%W/$WT}"; a="${a//%F/$F}"; a="${a//%D/$DELEG}"; args+=("$a"); done
  set +e
  OUT=$("$CHECK" ${args[@]+"${args[@]}"} 2>"$ERR")
  RC=$?
  set -e
}

json() { jq -r "$@" <<<"$OUT" 2>/dev/null || echo UNPARSEABLE; }

# observe EXPECT — prints the run's value of every `name=` field EXPECT names,
# in EXPECT's order. Plain names are JSON result fields, their spaces printed
# as `+`; a key the result does not carry reads ABSENT. `+` reads as a space
# in a needle too, so a literal plus cannot be pinned; no field carries one.
#   rc               exit status
#   path             the reported path with the staged worktree's tmp/ prefix
#                    removed, or null; a path anywhere else prints whole and
#                    fails the row
#   detail~<text>    whether the detail names <text> (`+` reads as a space)
#   branch~<text>    the half of the detail before the em-dash: what the
#                    refusing branch found. The half after it is the shared
#                    requirement, which quotes the very tokens the branches
#                    match on, so a needle against the whole detail pins
#                    nothing; a detail whose branch half carries the
#                    requirement (the separator gone, so the split lands on
#                    the requirement's own em-dash) aborts the suite
#   bar~<text>       the half after the em-dash: the requirement
#   silenced~<text>  whether measurement_suppressed names <text>
observe() {
  local got="" token name value needle
  for token in $1; do
    name="${token%%=*}"
    case "$name" in
      rc) value="$RC" ;;
      path) value="$(json --arg tmp "$WT/tmp/" '.path | if . == null then "null" else ltrimstr($tmp) end')" ;;
      detail~*) needle="${name#detail~}"; value="$(json '.detail // ""' | grep -qF -- "${needle//+/ }" && echo true || echo false)" ;;
      branch~*|bar~*)
        json '.detail // "" | split(" — ")[0]' | grep -qF -- 'must name the instrument' && { printf 'observe: %s asked of a detail whose branch half carries the requirement: %s\n' "$name" "$(json '.detail')" >&2; exit 1; }
        needle="${name#*~}"
        if [[ "$name" == branch~* ]]; then value="$(json '.detail // "" | split(" — ")[0]' | grep -qF -- "${needle//+/ }" && echo true || echo false)"
        else value="$(json '.detail // "" | split(" — ")[1:] | join(" — ")' | grep -qF -- "${needle//+/ }" && echo true || echo false)"; fi ;;
      silenced~*) needle="${name#silenced~}"; value="$(json '.measurement_suppressed // ""' | grep -qF -- "${needle//+/ }" && echo true || echo false)" ;;
      *) value="$(json "if has(\"$name\") then .$name else \"ABSENT\" end")"; value="${value// /+}" ;;
    esac
    got="$got $name=$value"
  done
  printf '%s' "${got# }"
}

# file_table ROW... — one artifact, one --file run, one assertion per row:
# `label^body^expect`, `^` because bodies carry `|`; a body with a `^` of its
# own mis-splits into an expect no observer accepts, so the row fails loudly.
file_table() {
  local row label body expect
  for row in "$@"; do
    IFS='^' read -r label body expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'file_table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    fresh_run
    printf '%s' "$body" > "$F"
    run_check --file %F
    assert_eq "$(observe "$expect")" "$expect" "$label" "$ERR"
  done
}

# wrapped_table TEMPLATE ROW... — like file_table, the row's middle field
# substituted for %s in TEMPLATE (a JSON literal placed in a complete artifact).
wrapped_table() {
  local template="$1" row label literal expect
  shift
  for row in "$@"; do
    IFS='^' read -r label literal expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'wrapped_table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    fresh_run
    # shellcheck disable=SC2059
    printf "$template" "$literal" > "$F"
    run_check --file %F
    assert_eq "$(observe "$expect")" "$expect" "$label" "$ERR"
  done
}

# glob_table ROW... — a fresh worktree holding the `file@when=body` items the
# row stages (when one of before, after, later against the boundary), one run
# in glob mode for agent `r` under the jq the row names (real or torn), one
# assertion: `label^stage^jq^expect`.
glob_table() {
  local row label spec which expect items item file when name mtime
  for row in "$@"; do
    IFS='^' read -r label spec which expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'glob_table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    fresh_run
    IFS=';' read -ra items <<<"$spec"
    for item in "${items[@]}"; do
      file="${item%%@*}"; when="${item#*@}"; when="${when%%=*}"; name="${item#*=}"
      body "$name" > "$WT/tmp/review-r-$file.json"
      case "$when" in
        before) mtime=$BEFORE ;; after) mtime=$AFTER ;; later) mtime=$LATER ;;
        *) echo "glob_table: unknown time $when in $item" >&2; exit 1 ;;
      esac
      touch -d "@$mtime" "$WT/tmp/review-r-$file.json"
    done
    case "$which" in
      real) run_check %W r %D ;;
      torn) PATH="$TORN_SHIM:$PATH" run_check %W r %D ;;
      *) echo "glob_table: unknown jq $which" >&2; exit 1 ;;
    esac
    assert_eq "$(observe "$expect")" "$expect" "$label" "$ERR"
  done
}

echo "=== zero_sample: a measurement that produced no samples is not a result ==="
# The gate reads the SAMPLE COUNT, never the result. A zero denominator or zero
# thread count means the instrument selected nothing; a zero numerator means it
# ran and everything failed, which is the finding the reviewer skill calls
# "never a pass" and must reach the orchestrator intact: the accepting rows
# fail under a numerator/denominator swap, which is what pins WHICH number the
# gate reads. Only the artifact's own carriers, .summary and .qa_metadata, are
# measurements; the same text quoted inside a finding is that finding's
# evidence. Whitespace between citation tokens is not one fixed spelling.
file_table \
  "a zero-mutant citation is refused, quoted, and told the declaration^{\"agent\":\"reviewer-test\",\"verdict\":\"pass\",\"summary\":\"validated: mutation: killed 0/0; stability: 10/10 at 16 threads\"}^rc=1 ok=false reason=zero_sample detail~killed+0/0=true detail~instrument+failure=true detail~measurement_failed=true" \
  "a zero-run stability citation is refused and quoted^{\"agent\":\"reviewer-test\",\"verdict\":\"pass\",\"summary\":\"mutation: killed 3/3; stability: 0/0 at 16 threads\"}^rc=1 reason=zero_sample detail~stability:+0/0=true" \
  "zero threads is the same instrument failure, named^{\"agent\":\"reviewer-test\",\"verdict\":\"pass\",\"summary\":\"mutation: killed 3/3; stability: 10/10 at 0 threads\"}^rc=1 reason=zero_sample detail~zero+threads=true" \
  "stability 0/10, ten measured runs none passed, stays valid^{\"agent\":\"reviewer-test\",\"verdict\":\"action_required\",\"summary\":\"concurrency-sensitive: mutation: killed 3/3; stability: 0/10 at 16 threads\"}^rc=0 reason=valid" \
  "mutation killed 0/3, three mutants none killed, stays valid^{\"agent\":\"reviewer-test\",\"verdict\":\"action_required\",\"summary\":\"mutant survived: mutation: killed 0/3; stability: 10/10 at 16 threads\"}^rc=0 reason=valid" \
  "a partial kill and partial stability stay valid^{\"agent\":\"reviewer-test\",\"verdict\":\"action_required\",\"summary\":\"mutation: killed 2/3; stability: 9/10 at 16 threads\"}^rc=0 reason=valid" \
  "a zeroed citation quoted in a blocker description is out of scope^{\"agent\":\"reviewer-test\",\"verdict\":\"action_required\",\"summary\":\"s\",\"blockers\":[{\"id\":1,\"title\":\"t\",\"location\":\"src/x.rs (\`f\`)\",\"description\":\"the fixture proves the gate rejects mutation: killed 0/0; stability: 0/0 at 16 threads\",\"recommendation\":\"r\",\"priority\":2,\"estimate\":2}],\"suggestions\":[],\"qa_metadata\":{}}^rc=0 reason=valid" \
  "a zeroed citation quoted in a suggestion is out of scope^{\"agent\":\"reviewer-test\",\"verdict\":\"pass\",\"summary\":\"s\",\"blockers\":[],\"suggestions\":[{\"id\":1,\"title\":\"t\",\"location\":\"tests/x.sh\",\"description\":\"the fixture uses mutation: killed 0/0 as its control\",\"recommendation\":\"r\",\"priority\":3,\"estimate\":1,\"category\":\"fix\"}],\"qa_metadata\":{}}^rc=0 reason=valid" \
  "a zeroed citation quoted in a question is out of scope^{\"agent\":\"reviewer-test\",\"verdict\":\"pass\",\"summary\":\"s\",\"blockers\":[],\"suggestions\":[],\"questions\":[{\"id\":1,\"location\":\"general\",\"question\":\"is mutation: killed 0/0 expected here?\",\"draft_response\":\"d\",\"source\":\"@x\",\"source_id\":\"1\",\"source_type\":\"inline\"}],\"qa_metadata\":{}}^rc=0 reason=valid" \
  "the same text in .summary is the artifact's own measurement, and the refusal points at the honest route^{\"agent\":\"reviewer-test\",\"verdict\":\"pass\",\"summary\":\"the fixture proves the gate rejects mutation: killed 0/0; stability: 0/0 at 16 threads\",\"blockers\":[],\"suggestions\":[],\"qa_metadata\":{}}^rc=1 reason=zero_sample detail~blocker+or+suggestion=true" \
  "a citation nested in qa_metadata is the artifact's own measurement^{\"agent\":\"reviewer-test\",\"verdict\":\"pass\",\"summary\":\"s\",\"blockers\":[],\"suggestions\":[],\"qa_metadata\":{\"test_qa\":{\"note\":\"mutation: killed 0/0\"}}}^rc=1 reason=zero_sample" \
  "a citation wrapped across a newline still counts^{\"agent\":\"reviewer-test\",\"verdict\":\"pass\",\"summary\":\"mutation: killed 0/\\n0; stability: 10/10 at 16 threads\"}^rc=1 reason=zero_sample" \
  "a newline after 'stability:' still counts^{\"agent\":\"reviewer-test\",\"verdict\":\"pass\",\"summary\":\"stability:\\n0/0 at 16 threads\"}^reason=zero_sample" \
  "a newline before a zero thread count still counts^{\"agent\":\"reviewer-test\",\"verdict\":\"pass\",\"summary\":\"stability: 10/10 at\\n0 threads\"}^reason=zero_sample" \
  "a nonzero mutation and stability citation stays valid^{\"agent\":\"reviewer-test\",\"verdict\":\"pass\",\"summary\":\"mutation: killed 3/3; stability: 10/10 at 16 threads\"}^rc=0 reason=valid measurement_failed=ABSENT measurement_suppressed=ABSENT" \
  "an artifact citing no measurement is untouched by the gate^{\"agent\":\"reviewer-quality\",\"verdict\":\"pass\",\"summary\":\"no measurement was needed for this domain\"}^rc=0 reason=valid"

echo "=== perf payload: evidence is required, absence is not detected shape by shape ==="
# Every spelling of "produced nothing" is refused, or emitting less becomes the
# cheapest way past the gate; several shapes are refused by DIFFERENT branches,
# so each row pins the branch's detail beside the shared reason. One real
# measured value is enough, in either container.
wrapped_table '{"agent":"reviewer-perf","verdict":"pass","summary":"s","blockers":[],"suggestions":[],"qa_metadata":{"perf_qa":%s}}' \
  "percentiles missing entirely^{\"regression_pct\":0,\"regressions\":[],\"platform\":\"linux\",\"baseline_sha\":\"abc\"}^reason=zero_sample detail~declares+no+percentiles+block=true" \
  "percentiles null^{\"percentiles\":null}^reason=zero_sample detail~declares+no+percentiles+block=true" \
  "percentiles an empty object^{\"percentiles\":{}}^reason=zero_sample detail~percentiles+is+empty=true" \
  "percentiles an empty array^{\"percentiles\":[]}^reason=zero_sample detail~percentiles+is+empty=true" \
  "percentiles all zero numbers^{\"percentiles\":{\"p50\":0,\"p99\":0}}^reason=zero_sample detail~no+measured+value+above+zero=true" \
  "percentiles zero-valued strings^{\"percentiles\":{\"p50\":\"0ms\",\"p99\":\"0ms\"}}^reason=zero_sample detail~no+measured+value+above+zero=true" \
  "percentiles null leaves^{\"percentiles\":{\"p50\":null,\"p99\":null}}^reason=zero_sample detail~no+measured+value+above+zero=true" \
  "percentiles a bare string^{\"percentiles\":\"none recorded\"}^reason=zero_sample detail~neither+an+object+nor+an+array=true" \
  "perf_qa itself not an object^\"benchmarks ran\"^reason=zero_sample detail~perf_qa+is+not+an+object=true" \
  "one real number among zeros is accepted^{\"percentiles\":{\"p50\":0,\"p99\":4.2}}^ok=true reason=valid" \
  "a populated array is accepted^{\"percentiles\":[1.5,2.5]}^ok=true reason=valid" \
  "no perf_qa payload at all is accepted^null^ok=true reason=valid"

echo "=== the declaration: top-level, substantive, and mechanically visible ==="
# The escape must not require adopting the qa shape (following the rejection's
# own instruction dead-ended in a second refusal), must not be satisfiable by
# any single character, and must not read as a plain green: its reason is what
# an orchestrator branches on. The rejection branches OVERLAP (a null token is
# also short, bare punctuation is also short), so each refusing row pins the
# branch half of the detail; a refused declaration is never echoed as a real
# one. The declaration is read in ONE place, so the echo and the decision agree
# either side of the 20-character, 3-word bar.
wrapped_table '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/0","blockers":[],"suggestions":[],"measurement_failed":%s}' \
  "a declaration is accepted as undermeasured, never plain valid, and echoed^\"cargo-mutants selected 0 mutants for the changed file\"^rc=0 ok=true reason=valid_undermeasured measurement_failed=cargo-mutants+selected+0+mutants+for+the+changed+file" \
  "a single period^\".\"^reason=invalid_declaration measurement_failed=ABSENT branch~punctuation+only=true bar~name+the+instrument=true" \
  "n/a^\"n/a\"^reason=invalid_declaration measurement_failed=ABSENT branch~null+token=true" \
  "N/A with punctuation^\"N/A.\"^reason=invalid_declaration branch~null+token=true" \
  "none^\"none\"^reason=invalid_declaration branch~null+token=true" \
  "unknown^\"unknown\"^reason=invalid_declaration branch~null+token=true" \
  "unavailable^\"unavailable\"^reason=invalid_declaration branch~null+token=true" \
  "tbd^\"tbd\"^reason=invalid_declaration branch~null+token=true" \
  "bare punctuation^\"---\"^reason=invalid_declaration branch~punctuation+only=true" \
  "long bare punctuation^\"---------------------------\"^reason=invalid_declaration branch~punctuation+only=true" \
  "whitespace only^\"   \"^reason=invalid_declaration branch~is+blank=true" \
  "one long word^\"instrumentfailedbadly\"^reason=invalid_declaration branch~is+1+word(s)=true" \
  "two words past the length floor: only the word bar refuses it^\"cargo-mutants produced-no-samples-at-all\"^reason=invalid_declaration branch~is+2+word(s)=true" \
  "three words past the floor^\"cargo-mutants selected zero-mutants\"^reason=valid_undermeasured" \
  "three tiny words: only the length bar refuses them^\"a b c\"^reason=invalid_declaration branch~is+5+characters=true" \
  "a boolean^true^reason=invalid_declaration branch~must+be+a+string=true" \
  "a number^0^reason=invalid_declaration branch~must+be+a+string=true" \
  "an object^{\"why\":\"broke\"}^reason=invalid_declaration branch~must+be+a+string=true" \
  "an array^[\"broke\"]^reason=invalid_declaration branch~must+be+a+string=true" \
  "null is no declaration, and the zero citation stands^null^reason=zero_sample" \
  "19 characters, 3 words: one short of the bar, refused on its own terms and not echoed^\"aa bbbb ccccccccccc\"^reason=invalid_declaration measurement_failed=ABSENT" \
  "20 characters, 3 words: exactly the bar, and the echo agrees^\"aa bbbb cccccccccccc\"^reason=valid_undermeasured measurement_failed=aa+bbbb+cccccccccccc"

echo "=== the escape suppresses one gate, wherever its block sits ==="
# The declaration's blast radius would be a consequence of statement order:
# hoisting its block to the first step once turned `review_performed: false`
# into an accepted valid_undermeasured. The radius is stated as behaviour, one
# gate the declaration does not suppress per row, and the one it does. The
# tolerant shape (no qa_metadata) can adopt the escape without adding the
# arrays. A declaration covers whatever the measurement gate would have said,
# a perf payload the named instrument has nothing to do with included; doing
# so invisibly is the defect, so the result records what it silenced, the
# finding and not the remedy text of a rejection that did not happen.
file_table \
  "the tolerant shape adopts the escape without adding qa_metadata^{\"agent\":\"reviewer-test\",\"verdict\":\"pass\",\"summary\":\"mutation: killed 0/0\",$DECLARATION}^rc=0 reason=valid_undermeasured" \
  "a declaration also covers an empty perf payload^{\"agent\":\"reviewer-perf\",\"verdict\":\"action_required\",\"summary\":\"s\",\"blockers\":[],\"suggestions\":[],\"measurement_failed\":\"the bench runner emitted no samples for any lane\",\"qa_metadata\":{\"perf_qa\":{\"percentiles\":{}}}}^reason=valid_undermeasured" \
  "a declaration does not suppress the no-review gate^{\"verdict\":\"pass\",\"summary\":\"mutation: killed 0/0\",\"blockers\":[],\"suggestions\":[],$DECLARATION,\"qa_metadata\":{\"review_performed\":false,\"reason\":\"no_scope_provided\"}}^reason=no_review" \
  "a declaration does not suppress the finding-item gate^{\"verdict\":\"pass\",\"summary\":\"mutation: killed 0/0\",\"blockers\":[],\"suggestions\":[{\"title\":\"t\",\"detail\":\"d\"}],$DECLARATION,\"qa_metadata\":{}}^reason=incomplete" \
  "a declaration does not suppress the qa-shape gate^{\"verdict\":\"pass\",\"summary\":\"mutation: killed 0/0\",$DECLARATION,\"qa_metadata\":{}}^reason=incomplete" \
  "a declaration does not suppress the missing-verdict gate^{\"agent\":\"r\",\"summary\":\"mutation: killed 0/0\",$DECLARATION}^reason=invalid" \
  "control: the zero-sample gate is the one it replaces^{\"verdict\":\"pass\",\"summary\":\"mutation: killed 0/0\",\"blockers\":[],\"suggestions\":[],$DECLARATION,\"qa_metadata\":{}}^reason=valid_undermeasured" \
  "the result names the perf measurement a mutation declaration silenced^{\"agent\":\"reviewer-perf\",\"verdict\":\"pass\",\"summary\":\"s\",\"blockers\":[],\"suggestions\":[],$DECLARATION,\"qa_metadata\":{\"perf_qa\":{\"percentiles\":{\"p50\":0,\"p99\":0}}}}^rc=0 reason=valid_undermeasured silenced~percentiles+carries+no+measured+value+above+zero=true" \
  "the result names the citation a declaration silenced, finding not remedy^{\"agent\":\"reviewer-test\",\"verdict\":\"pass\",\"summary\":\"mutation: killed 0/0\",\"blockers\":[],\"suggestions\":[],$DECLARATION}^silenced~killed+0/0=true silenced~measurement_failed=false" \
  "control: a declaration with nothing to silence records nothing and is still undermeasured^{\"agent\":\"reviewer-test\",\"verdict\":\"pass\",\"summary\":\"mutation: killed 3/3; stability: 10/10 at 16 threads\",\"blockers\":[],\"suggestions\":[],$DECLARATION}^reason=valid_undermeasured measurement_suppressed=ABSENT"

echo "=== glob mode: terminal rejections, and the one fallback ==="
# zero_sample and invalid_declaration are TERMINAL: recording the rejection
# and walking on handed the reviewer an older sibling and called it valid, and
# the reviewer's own prescribed self-check uses boundary 0, which makes every
# prior artifact fresh. Terminal refuses THIS run, not the agent forever: a
# stale rejected artifact does not block a fresh measured one. "The gate could
# not run" is the one content rejection an older sibling may answer, because
# reviewer artifacts are written non-atomically and a torn read fails jq on
# THAT file; alone it is still a rejection, and with real jq the newest
# artifact answers for itself.
glob_table \
  "a fresh zero-sample artifact is refused and named, not rescued by an older sibling^ok@after=measured;bad@later=zeroed^real^rc=1 reason=zero_sample path=review-r-bad.json" \
  "a stale zero-sample artifact does not block a fresh measured one^ok@after=measured;bad@before=zeroed^real^rc=0 path=review-r-ok.json" \
  "a fresh invalid declaration is refused and named, not rescued by an older sibling^ok@after=measured;bad@later=decl_bad^real^rc=1 reason=invalid_declaration path=review-r-bad.json" \
  "a stale invalid declaration does not block a fresh measured one^ok@after=measured;bad@before=decl_bad^real^rc=0 path=review-r-ok.json" \
  "a gate that could not run falls back to the intact sibling^ok@after=measured;torn-newest@later=clean^torn^rc=0 ok=true path=review-r-ok.json" \
  "control: with real jq the newest artifact answers for itself^ok@after=measured;torn-newest@later=clean^real^rc=0 path=review-r-torn-newest.json"

# The torn artifact ALONE is rejected: the fallback is a real answer, not an
# absence of gating.
fresh_run
body clean > "$WT/tmp/review-r-torn-newest.json"
PATH="$TORN_SHIM:$PATH" run_check --file "$WT/tmp/review-r-torn-newest.json"
assert_eq "$(observe "rc=1 reason=invalid")" "rc=1 reason=invalid" "a gate that could not run rejects the artifact on its own" "$ERR"

echo "=== the fail-closed default behind the fallback rule ==="
# The predicate protects a gate included later that forgets to classify
# itself; every gate present does, so no artifact reaches the default and it is
# asserted directly. Run in a child shell: sourcing the lib here would install
# its own EXIT trap over this suite's and leak $TMP_ROOT.
for row in "torn_write|fallback" "terminal|terminal" "|terminal" "typo_write|terminal"; do
  IFS='|' read -r disposition want <<<"$row"
  got="$(bash -c '
    source "$1/skills/orch/scripts/lib/review-artifact-gates.sh"
    review_artifact_disposition="$2"
    if disposition_allows_fallback; then echo fallback; else echo terminal; fi
  ' _ "$REPO_ROOT" "$disposition" 2>/dev/null || echo "predicate exited $?")"
  assert_eq "$got" "$want" "disposition '${disposition:-unset}' -> $want"
done

echo "=== the rejection reason is documented where reviewers read the rules ==="
finding_schema="$REPO_ROOT/skills/reviewer/schemas/review-finding.md"
[[ -f "$finding_schema" ]] || { echo "review-finding.md is gone; the rows below pin nothing" >&2; exit 1; }
for token in zero_sample measurement_failed; do
  assert_eq "$(grep -qF -- "$token" "$finding_schema" && echo yes || echo no)" "yes" "review-finding.md names $token"
done

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
