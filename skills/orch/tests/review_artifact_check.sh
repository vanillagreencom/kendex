#!/usr/bin/env bash
# Tests for review-artifact-check: deterministic on-disk acceptance of
# reviewer JSON artifacts in the orch review-pr workflow. Glob mode resolves
# WT/tmp/review-<agent>-*.json against a delegation boundary; --file mode
# validates one path, with an optional boundary. The measurement gate and the
# selective jq shim are review_artifact_check_measurement.sh; the channel and
# item-schema surfaces have their own suites beside it.
#
# One case per behaviour surface; shaped input is one table per case, one
# asserted row per shape. A row stages its own worktree and artifacts; its
# `expect` names the fields it pins and `observe` reads exactly those, so a
# row fails on the field it names.
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
LATER2=$((DELEG + 300))

# body NAME — the artifact bodies the rows stage, by name.
body() {
  case "$1" in
    pass) printf '{"verdict":"pass","items":[]}' ;;
    action) printf '{"verdict":"action_required","items":[{"category":"fix"}]}' ;;
    noverdict) printf '{"items":[]}' ;;
    notjson) printf 'not json' ;;
    noreview) printf '{"verdict":"pass","summary":"No review was actually performed","qa_metadata":{"review_performed":false,"reason":"no_scope_provided"}}' ;;
    noreview_reason) printf '{"verdict":"pass","qa_metadata":{"reason":"no_scope_provided"}}' ;;
    noreview_flag) printf '{"verdict":"pass","blockers":[],"suggestions":[],"qa_metadata":{"review_performed":false}}' ;;
    qa_ok) printf '{"verdict":"pass","blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}' ;;
    qa_ok_noq) printf '{"verdict":"pass","blockers":[],"suggestions":[],"qa_metadata":{}}' ;;
    performed) printf '{"verdict":"pass","blockers":[],"suggestions":[],"qa_metadata":{"review_performed":true}}' ;;
    qa_inc) printf '{"verdict":"pass","summary":"truncated","qa_metadata":{}}' ;;
    qa_inc_agent) printf '{"agent":"external-codex","timestamp":"2026-07-18T00:00:00Z","verdict":"pass","summary":"looks fine","qa_metadata":{}}' ;;
    inc_type) printf '{"verdict":"pass","blockers":"none","suggestions":[],"qa_metadata":{}}' ;;
    inc_sugg) printf '{"verdict":"pass","blockers":[],"qa_metadata":{}}' ;;
    inc_blk) printf '{"verdict":"pass","suggestions":[],"qa_metadata":{}}' ;;
    issue_bad) printf '{"agent":"reviewer-arch","verdict":"pass","blockers":[],"suggestions":[{"title":"Two resolvers coexist","location":"/abs/instrument_link.rs (instrument_name)","detail":"...","severity":"low"}],"qa_metadata":{"arch_review":{"overall_score":8.4,"pass":true}}}' ;;
    compliant) printf '{"verdict":"action_required","blockers":[{"id":1,"title":"t","location":"src/x.rs (`f`)","description":"d","recommendation":"r","priority":1,"estimate":2}],"suggestions":[{"id":1,"title":"t","location":"src/y.rs (`g`)","description":"d","recommendation":"r","priority":3,"estimate":2,"category":"fix"}],"qa_metadata":{}}' ;;
    nocat) printf '{"verdict":"pass","blockers":[],"suggestions":[{"id":1,"title":"t","location":"l","description":"d","recommendation":"r","priority":3,"estimate":2}],"qa_metadata":{}}' ;;
    badcatval) printf '{"verdict":"pass","blockers":[],"suggestions":[{"id":1,"title":"t","location":"l","description":"d","recommendation":"r","priority":3,"estimate":2,"category":"low"}],"qa_metadata":{}}' ;;
    badblk) printf '{"verdict":"action_required","blockers":[{"id":1,"title":"t","location":"l","recommendation":"r","priority":1,"estimate":2}],"suggestions":[],"qa_metadata":{}}' ;;
    okblk) printf '{"verdict":"action_required","blockers":[{"id":1,"title":"t","location":"l","description":"d","recommendation":"r","priority":1,"estimate":2}],"suggestions":[],"qa_metadata":{}}' ;;
    badpri) printf '{"verdict":"pass","blockers":[],"suggestions":[{"id":1,"title":"t","location":"l","description":"d","recommendation":"r","priority":5,"estimate":2,"category":"fix"}],"qa_metadata":{}}' ;;
    badest) printf '{"verdict":"pass","blockers":[],"suggestions":[{"id":1,"title":"t","location":"l","description":"d","recommendation":"r","priority":2,"estimate":"2","category":"fix"}],"qa_metadata":{}}' ;;
    badblkpri) printf '{"verdict":"action_required","blockers":[{"id":1,"title":"t","location":"l","description":"d","recommendation":"r","priority":0,"estimate":3}],"suggestions":[],"qa_metadata":{}}' ;;
    okbound) printf '{"verdict":"pass","blockers":[],"suggestions":[{"id":1,"title":"t","location":"l","description":"d","recommendation":"r","priority":4,"estimate":5,"category":"fix"}],"qa_metadata":{}}' ;;
    noqa_bad) printf '{"verdict":"pass","suggestions":[{"title":"t","location":"l"}]}' ;;
    null_blockers) printf '{"verdict":"pass","blockers":null,"suggestions":[],"qa_metadata":{}}' ;;
    obj_blockers) printf '{"verdict":"pass","blockers":{},"suggestions":[],"qa_metadata":{}}' ;;
    str_blockers) printf '{"verdict":"pass","blockers":"none","suggestions":[],"qa_metadata":{}}' ;;
    num_blockers) printf '{"verdict":"pass","blockers":3,"suggestions":[],"qa_metadata":{}}' ;;
    null_sugg) printf '{"verdict":"pass","blockers":[],"suggestions":null,"qa_metadata":{}}' ;;
    str_sugg) printf '{"verdict":"pass","blockers":[],"suggestions":"x","qa_metadata":{}}' ;;
    chain_noverdict) printf '{"agent":"r","summary":"no verdict field"}' ;;
    chain_noreview) printf '{"verdict":"pass","qa_metadata":{"review_performed":false}}' ;;
    chain_item) printf '{"verdict":"pass","blockers":[],"suggestions":[{"title":"t"}],"qa_metadata":{}}' ;;
    chain_decl) printf '{"verdict":"pass","blockers":[],"suggestions":[],"measurement_failed":"n/a"}' ;;
    chain_zero) printf '{"verdict":"pass","summary":"mutation: killed 0/0","blockers":[],"suggestions":[],"qa_metadata":{}}' ;;
    item_bad) printf '{"verdict":"pass","blockers":[],"suggestions":[{"title":"t","location":"l","detail":"x","severity":"low"}],"qa_metadata":{}}' ;;
    item_ok) printf '{"verdict":"pass","blockers":[],"suggestions":[{"id":1,"title":"t","location":"l","description":"d","recommendation":"r","priority":3,"estimate":2,"category":"issue","impact":"nightly importers hit it on every run"}],"qa_metadata":{}}' ;;
    *) echo "body: unknown name $1" >&2; exit 1 ;;
  esac
}

# --- harness -----------------------------------------------------------------

# stage SPEC — a fresh worktree for one row with the artifacts SPEC names:
# `;`-separated `file@when=body` items, file a name under tmp/ (`F` is the
# --file target review-external-F.json), when one of before, at, after, later,
# later2 (the mtime against the delegation boundary) or none. Sets WT and F.
RUN_SEQ=0
stage() {
  local spec="$1" items item file when name mtime
  RUN="$TMP_ROOT/runs/$((++RUN_SEQ))"
  WT="$RUN/wt"
  mkdir -p "$WT/tmp"
  F="$WT/tmp/review-external-F.json"
  [[ -n "$spec" ]] || return 0
  IFS=';' read -ra items <<<"$spec"
  for item in "${items[@]}"; do
    file="${item%%@*}"; when="${item#*@}"; when="${when%%=*}"; name="${item#*=}"
    [[ "$file" != F ]] || file="review-external-F"
    body "$name" > "$WT/tmp/$file.json"
    case "$when" in
      before) mtime=$BEFORE ;; at) mtime=$DELEG ;; after) mtime=$AFTER ;; later) mtime=$LATER ;; later2) mtime=$LATER2 ;;
      none) continue ;;
      *) echo "stage: unknown time $when in $item" >&2; exit 1 ;;
    esac
    touch -d "@$mtime" "$WT/tmp/$file.json"
  done
}

# run_check ARGS... — runs the check with %W, %F and %D in ARGS replaced by
# the staged worktree, the --file target and the delegation boundary; OUT is
# the JSON, RC the exit, ERR the stderr file.
run_check() {
  local args=() a
  for a in "$@"; do a="${a//%W/$WT}"; a="${a//%F/$F}"; a="${a//%D/$DELEG}"; args+=("$a"); done
  ERR="$RUN/stderr"
  set +e
  OUT=$("$CHECK" ${args[@]+"${args[@]}"} 2>"$ERR")
  RC=$?
  set -e
}

json() { jq -r "$@" <<<"$OUT" 2>/dev/null || echo UNPARSEABLE; }

# observe EXPECT — prints the run's value of every `name=` field EXPECT names,
# in EXPECT's order. Plain names are JSON result fields, a key the result does
# not carry reads ABSENT;
#   rc              exit status
#   path            the reported path with the staged worktree's tmp/ prefix
#                   removed, or null; a path anywhere else prints whole and
#                   fails the row
#   detail~<text>   whether the detail names <text> (`+` reads as a space):
#                   the detail is what the rejected reviewer acts on, and
#                   which shape it saw lives nowhere else
#   detail_present  whether a detail is a non-empty string
#   stdout~<text>   whether stdout carries <text>
#   stderr          `line` when anything was written there, else `empty`
observe() {
  local got="" token name value needle
  for token in $1; do
    name="${token%%=*}"
    case "$name" in
      rc) value="$RC" ;;
      path) value="$(json --arg tmp "$WT/tmp/" '.path | if . == null then "null" else ltrimstr($tmp) end')" ;;
      detail~*) needle="${name#detail~}"; value="$(json '.detail // ""' | grep -qF -- "${needle//+/ }" && echo true || echo false)" ;;
      detail_present) value="$(json '(.detail | type) == "string" and .detail != ""')" ;;
      stdout~*) needle="${name#stdout~}"; value="$(grep -qF -- "${needle//+/ }" <<<"$OUT" && echo true || echo false)" ;;
      stderr) value="$([[ -s "$ERR" ]] && echo line || echo empty)" ;;
      *) value="$(json "if has(\"$name\") then .$name else \"ABSENT\" end")" ;;
    esac
    got="$got $name=$value"
  done
  printf '%s' "${got# }"
}

# table ROW... — one staged worktree, one run and one assertion per row:
# `label|stage|args|expect`.
table() {
  local row label spec args expect
  for row in "$@"; do
    IFS='|' read -r label spec args expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    stage "$spec"
    # shellcheck disable=SC2086
    run_check $args
    assert_eq "$(observe "$expect")" "$expect" "$label" "$ERR"
  done
}

GLOB='%W reviewer-quality %D'
Q=review-reviewer-quality

echo "=== glob mode resolves the newest fresh artifact of the agent ==="
# Another agent's file does not count; an artifact older than the boundary is
# stale; a fresh one without a verdict is invalid and named; a fresh valid one
# wins over stale and invalid siblings; a newest-but-unparseable file falls
# back to an older fresh valid one.
table \
  "no artifact at all is missing||$GLOB|rc=1 ok=false path=null reason=missing" \
  "another agent's fresh artifact does not count|review-reviewer-arch-1@after=pass|$GLOB|rc=1 reason=missing" \
  "an artifact older than the boundary is stale and named|$Q-1@before=pass|$GLOB|rc=1 ok=false path=$Q-1.json reason=stale" \
  "an mtime equal to the boundary is fresh in glob mode too|$Q-1@at=pass|$GLOB|rc=0 ok=true reason=valid" \
  "a fresh artifact without a verdict is invalid and named|$Q-1@before=pass;$Q-2@after=noverdict|$GLOB|rc=1 path=$Q-2.json reason=invalid" \
  "a fresh valid artifact wins over stale and invalid siblings|$Q-1@before=pass;$Q-2@after=noverdict;$Q-3@later=action|$GLOB|rc=0 ok=true path=$Q-3.json reason=valid" \
  "a newest unparseable file falls back to the older fresh valid one|$Q-3@later=action;$Q-4@later2=notjson|$GLOB|rc=0 ok=true path=$Q-3.json reason=valid"

echo "=== file mode validates one path, the boundary optional ==="
# Without a boundary the mtime is ignored; with one, glob mode's freshness
# gate applies with >= semantics; existence is checked before freshness and
# freshness before the verdict.
table \
  "a valid file|F@none=pass|--file %F|rc=0 ok=true path=review-external-F.json reason=valid" \
  "an old mtime validates without a boundary|F@before=pass|--file %F|rc=0 ok=true reason=valid" \
  "an mtime before the boundary is stale|F@before=pass|--file %F %D|rc=1 ok=false path=review-external-F.json reason=stale" \
  "an mtime after the boundary is fresh|F@after=pass|--file %F %D|rc=0 ok=true reason=valid" \
  "an mtime equal to the boundary is fresh|F@at=pass|--file %F %D|reason=valid" \
  "fresh but without a verdict is invalid|F@after=noverdict|--file %F %D|rc=1 reason=invalid" \
  "a missing file with a boundary is missing|F@none=pass|--file %W/tmp/nope.json %D|rc=1 reason=missing" \
  "a missing file|F@none=pass|--file %W/tmp/nope.json|rc=1 ok=false path=null reason=missing" \
  "a file without a verdict is invalid and named|F@none=noverdict|--file %F|rc=1 path=review-external-F.json reason=invalid"

echo "=== a self-reported no-review artifact is refused, and terminally ==="
# review_performed=false, or a no-review reason alone, is an admission
# whatever the verdict (no qa_metadata at all keeps the existence-plus-verdict
# tolerance the file-mode table proves); an empty qa_metadata with the arrays,
# or review_performed=true, validates. In glob mode the refusal is terminal: no_review is the
# reviewer's self-report about THIS run, so an older fresh sibling does not
# rescue it; a STALE no-review artifact does not block a fresh valid one.
E=review-reviewer-ext
table \
  "review_performed=false|F@after=noreview|--file %F|rc=1 ok=false path=review-external-F.json reason=no_review" \
  "a no-review reason alone|F@none=noreview_reason|--file %F|rc=1 reason=no_review" \
  "review_performed=false alone, arrays present, is still no_review|F@none=noreview_flag|--file %F|rc=1 reason=no_review" \
  "empty qa_metadata with the arrays validates|F@none=qa_ok|--file %F|reason=valid" \
  "review_performed=true validates|F@none=performed|--file %F|reason=valid" \
  "glob: a fresh no-review artifact is refused and named|$E-1@after=noreview|%W reviewer-ext %D|rc=1 path=$E-1.json reason=no_review" \
  "glob: terminal, an older fresh valid sibling does not rescue it|$E-0@after=qa_ok_noq;$E-1@later=noreview|%W reviewer-ext %D|rc=1 path=$E-1.json reason=no_review" \
  "glob control: a stale no-review artifact does not block a fresh valid one|$E-0@after=qa_ok_noq;$E-1@before=noreview|%W reviewer-ext %D|rc=0 path=$E-0.json reason=valid"

echo "=== a qa-shaped artifact must carry the finding arrays ==="
# Declaring qa_metadata requires blockers[] and suggestions[] (questions[] is
# not required); a mistyped array is as lost as a missing one. In glob mode
# the refusal is terminal, and a STALE incomplete artifact does not block a
# fresh complete one. A prefix truncation never reaches this gate: it is not
# JSON, so every one is invalid first.
I=review-reviewer-inc
table \
  "qa-shaped without the arrays is incomplete and named|F@none=qa_inc_agent|--file %F|rc=1 ok=false path=review-external-F.json reason=incomplete" \
  "a non-array blockers|F@none=inc_type|--file %F|rc=1 reason=incomplete" \
  "missing suggestions alone|F@none=inc_sugg|--file %F|rc=1 reason=incomplete" \
  "questions[] is not required|F@none=qa_ok_noq|--file %F|reason=valid" \
  "glob: a fresh qa-shaped incomplete artifact is refused and named|$I-1@after=qa_inc|%W reviewer-inc %D|rc=1 path=$I-1.json reason=incomplete" \
  "glob: terminal, an older fresh complete sibling does not rescue it|$I-0@after=qa_ok_noq;$I-1@later=qa_inc|%W reviewer-inc %D|rc=1 path=$I-1.json" \
  "glob control: a stale incomplete artifact does not block a fresh complete one|$I-0@after=qa_ok_noq;$I-1@before=qa_inc|%W reviewer-inc %D|rc=0 path=$I-0.json"
trunc_src='{"agent":"r","verdict":"pass","summary":"s","blockers":[{"id":1,"title":"t","location":"l","description":"d","recommendation":"r","priority":1,"estimate":1}],"suggestions":[],"qa_metadata":{"x":1}}'
trunc_bad=""
stage ""
for pct in 20 40 60 80 90 95 99; do
  printf '%s' "${trunc_src:0:$(( ${#trunc_src} * pct / 100 ))}" > "$WT/tmp/trunc-$pct.json"
  run_check --file "$WT/tmp/trunc-$pct.json"
  [[ "$(json .reason)" == "invalid" ]] || trunc_bad="$trunc_bad ${pct}%:$(json .reason)"
done
assert_eq "$trunc_bad" "" "every prefix truncation is rejected as invalid before any content gate"

echo "=== a qa-shaped artifact must carry usable finding items, and the detail says which ==="
# Items need id, title, location, description, recommendation, priority
# (1..4) and estimate (1..5), suggestions also category in {fix, issue}; the
# detail names the first offending item and field. Artifacts without
# qa_metadata keep the tolerant shape. A missing array, a null one and a
# wrong-typed one are three different things the agent did and the detail
# says which, and what an empty review writes. Every rejection in the chain
# names its cause. In glob mode a malformed-item artifact is refused
# terminally, and a STALE one does not block a fresh well-formed one.
T=review-reviewer-item
table \
  "the issue's malformed suggestion is incomplete, the detail names the item and the missing category|F@none=issue_bad|--file %F|rc=1 ok=false path=review-external-F.json reason=incomplete detail~suggestions[0]=true detail~missing/invalid+id,+description,+recommendation,+priority,+estimate,+category=true" \
  "a fully compliant artifact is valid and carries no detail key|F@none=compliant|--file %F|ok=true reason=valid detail=ABSENT" \
  "a suggestion missing only category|F@none=nocat|--file %F|rc=1 reason=incomplete detail~missing/invalid+category=true" \
  "a category outside fix and issue|F@none=badcatval|--file %F|rc=1 reason=incomplete" \
  "a blocker missing a base field, named|F@none=badblk|--file %F|rc=1 reason=incomplete detail~blockers[0]=true detail~missing/invalid+description=true" \
  "a blocker without category is valid|F@none=okblk|--file %F|reason=valid" \
  "a priority outside 1..4, named|F@none=badpri|--file %F|rc=1 reason=incomplete detail~missing/invalid+priority=true" \
  "a string estimate, named|F@none=badest|--file %F|rc=1 reason=incomplete detail~missing/invalid+estimate(not+1..5)=true" \
  "a blocker priority below the range, named on its array|F@none=badblkpri|--file %F|rc=1 detail~blockers[0]=true" \
  "the boundary values priority 4 and estimate 5 are valid|F@none=okbound|--file %F|reason=valid" \
  "malformed items without qa_metadata stay tolerant|F@none=noqa_bad|--file %F|reason=valid" \
  "arrays lost: the detail names both arrays as absent and the exempt shape|F@none=qa_inc|--file %F|ok=false reason=incomplete detail~blockers[]+is+absent=true detail~suggestions[]+is+absent=true detail~no+qa_metadata=true" \
  "a null blockers is reported as null, and what an empty review writes|F@none=null_blockers|--file %F|rc=1 reason=incomplete detail~blockers[]+is+null=true detail~writes+[]=true" \
  "a missing blockers is reported as absent, and the present suggestions is not|F@none=inc_blk|--file %F|rc=1 reason=incomplete detail~blockers[]+is+absent=true detail~suggestions[]+is+absent=false" \
  "an object blockers is reported by type|F@none=obj_blockers|--file %F|rc=1 reason=incomplete detail~blockers[]+is+object,+not+an+array=true detail~writes+[]=true" \
  "a string blockers is reported by type|F@none=str_blockers|--file %F|rc=1 reason=incomplete detail~blockers[]+is+string,+not+an+array=true detail~writes+[]=true" \
  "a number blockers is reported by type|F@none=num_blockers|--file %F|rc=1 reason=incomplete detail~blockers[]+is+number,+not+an+array=true detail~writes+[]=true" \
  "a null suggestions is reported on its own|F@none=null_sugg|--file %F|detail~suggestions[]+is+null=true" \
  "a wrong-typed suggestions is reported on its own|F@none=str_sugg|--file %F|detail~suggestions[]+is+string,+not+an+array=true" \
  "chain: a missing verdict names its cause|F@none=chain_noverdict|--file %F|ok=false detail_present=true" \
  "chain: a no-review admission names its cause|F@none=chain_noreview|--file %F|ok=false detail_present=true" \
  "chain: a malformed finding item names its cause|F@none=chain_item|--file %F|ok=false detail_present=true" \
  "chain: a bad measurement declaration names its cause|F@none=chain_decl|--file %F|ok=false detail_present=true" \
  "chain: a zero-sample measurement names its cause|F@none=chain_zero|--file %F|ok=false detail_present=true" \
  "glob missing names the glob that matched nothing||%W ghost-agent 0|reason=missing detail~review-ghost-agent-=true" \
  "glob stale names the mtime against the boundary|review-staleonly-1@before=pass|%W staleonly %D|reason=stale detail~predates+the+boundary=true" \
  "file missing names the path||--file %W/definitely-not-here.json|reason=missing detail~no+file+at=true" \
  "file stale names the mtime against the boundary|F@before=pass|--file %F %D|reason=stale detail~predates+the+boundary=true" \
  "glob: a fresh malformed-item artifact is refused and named|$T-1@after=item_bad|%W reviewer-item %D|rc=1 path=$T-1.json reason=incomplete detail~suggestions[0]=true" \
  "glob: terminal, an older fresh well-formed sibling does not rescue it|$T-0@after=item_ok;$T-1@later=item_bad|%W reviewer-item %D|rc=1 path=$T-1.json reason=incomplete" \
  "glob control: a stale malformed-item artifact does not block a fresh well-formed one|$T-0@after=item_ok;$T-1@before=item_bad|%W reviewer-item %D|rc=0 path=$T-0.json"

echo "=== usage errors ==="
table \
  "missing arguments|F@none=pass|%W reviewer-quality|rc=2" \
  "a non-numeric delegated_at|F@none=pass|%W reviewer-quality not-a-number|rc=2" \
  "a nonexistent worktree||%W/does-not-exist reviewer-quality %D|rc=2" \
  "--file with no path||--file|rc=2" \
  "--file with a non-numeric boundary|F@none=pass|--file %F not-a-number|rc=2" \
  "--file with too many arguments|F@none=pass|--file %F %D extra-arg|rc=2" \
  "a non-integer --wait|F@none=pass|%W waitrev 0 --wait nope|rc=2" \
  "the bare three-positional contract still validates|review-waitrev-1@after=qa_ok|%W waitrev 0|rc=0"

echo "=== --wait blocks until an artifact lands or the deadline ==="
# A valid artifact landing after about two seconds ends a 20-second wait with
# its verdict; nothing landed at the deadline is missing, exit 1; a STALE
# prior-round artifact keeps the wait polling for the fresh one rather than
# ending it instantly.
stage ""
start_epoch="$(date +%s)"
( sleep 2; body qa_ok > "$WT/tmp/review-waitrev-20260101-000001.json" ) &
writer_pid=$!
run_check %W waitrev 0 --wait 20 --interval 1
wait "$writer_pid" 2>/dev/null || true
elapsed=$(( $(date +%s) - start_epoch ))
assert_eq "$(observe "rc=0 ok=true") early=$([[ "$elapsed" -lt 15 ]] && echo true || echo false)" "rc=0 ok=true early=true" "--wait returns the landed artifact before the deadline (${elapsed}s)" "$ERR"
stage ""
run_check %W ghostrev 0 --wait 2 --interval 1
assert_eq "$(observe "rc=1 reason=missing")" "rc=1 reason=missing" "--wait at the deadline with nothing landed is missing" "$ERR"
stage "review-cyc-20200101-000000@before=qa_ok"
now_epoch="$(date +%s)"
( sleep 2; body qa_ok > "$WT/tmp/review-cyc-20990101-000000.json" ) &
writer_pid=$!
run_check %W cyc "$now_epoch" --wait 20 --interval 1
elapsed=$(( $(date +%s) - now_epoch ))
wait "$writer_pid" 2>/dev/null || true
assert_eq "$(observe "ok=true") polled=$([[ "$elapsed" -ge 1 && "$elapsed" -lt 15 ]] && echo true || echo false)" "ok=true polled=true" "--wait polls past a stale prior-round artifact to the fresh one, neither instantly nor to the deadline (${elapsed}s)" "$ERR"

echo "=== -h and --help answer before any temp-file initialization ==="
# The heredoc is the contract's sole home; the dispatch runs before the gates
# lib is sourced, so --help prints under an unusable TMPDIR too.
stage ""
run_check --help
assert_eq "$(observe "rc=0 stderr=empty stdout~Usage:=true stdout~zero_sample=true stdout~measurement_failed=true")" "rc=0 stderr=empty stdout~Usage:=true stdout~zero_sample=true stdout~measurement_failed=true" "--help exits 0 on stdout alone with the reason vocabulary and the declaration contract"
run_check -h
assert_eq "$(observe "rc=0 stdout~Usage:=true")" "rc=0 stdout~Usage:=true" "-h prints usage"
TMPDIR="$TMP_ROOT/does-not-exist/nope" run_check --help
assert_eq "$(observe "rc=0 stdout~Usage:=true")" "rc=0 stdout~Usage:=true" "--help still prints the contract under an unusable TMPDIR"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
