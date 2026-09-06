#!/usr/bin/env bash
# Tests for dev-return-write: the deterministic writer for a dev agent's
# round-scoped completion artifact ([WORKTREE]/tmp/dev-return-[ISSUE_ID]-[ROUND_ID].json).
# Running the writer instead of hand-authoring the JSON makes the receipt
# well-formed and complete by construction: every artifact it emits round-trips
# through dev-artifact-check as valid, and every bad invocation exits 2 on the
# guard it names, writing nothing.
#
# One run and one comparison per row. `observe` reads exactly the fields the
# row's expect names; a refusal row pins the stderr clause only its guard
# emits, since an implement row's unresolvable commit would otherwise exit 2
# on the growth measurement whatever the row's own guard did.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
WRITE="$REPO_ROOT/skills/orch/scripts/dev-return-write"
CHECK="$REPO_ROOT/skills/orch/scripts/dev-artifact-check"
ROUND_WRITE="$REPO_ROOT/skills/orch/scripts/dev-round-write"
STATE="$REPO_ROOT/skills/orch/scripts/workflow-state"
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"
# shellcheck source=lib/waiter-assertions.sh
source "$TEST_DIR/lib/waiter-assertions.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

new_repo() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name Test
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" commit -q --allow-empty -m base
  printf '%s' "$dir"
}

# The implement worktree: a three-line implementation on issue-776, later grown
# by two lines. The fix worktree: a delegated two-item round.
WT="$(new_repo wt)"
git -C "$WT" switch -q -c issue-776
printf 'one\ntwo\nthree\n' > "$WT/implementation.txt"
git -C "$WT" add implementation.txt
git -C "$WT" commit -q -m implementation
IMPL_HEAD="$(git -C "$WT" rev-parse HEAD)"
HEAD="$IMPL_HEAD"
RID="1750000000-99"
FW="$(new_repo fix-wt)"
FIX_HEAD="$(git -C "$FW" rev-parse HEAD)"
init_growth_state "$STATE" "$FW" issue-776 7-7 100
env ORCH_STATE_DIR="$FW/tmp" "$ROUND_WRITE" --worktree "$FW" --issue issue-776 --round-id 7-7 \
  --item 1 "fix nil deref" "tools/guard on a staged render" --item 2 "review decision" "tools/guard on a staged render" >/dev/null
printf '## Completion Summary\n- did the thing\n' > "$TMP_ROOT/summary.md"
SUMMARY_FILE="$TMP_ROOT/summary.md"

# run ARGS... — one writer run; OUT is the printed path, RC the exit, ERR the
# stderr file. In ARGS `+` reads as a space, EMPTY as an empty argument, SPACES
# as three spaces, %H as the implement worktree's head, %FW as the fix worktree.
RUN_SEQ=0
run() {
  local args=() a
  for a in "$@"; do
    a="${a//+/ }"; a="${a//%H/$HEAD}"; a="${a//%FW/$FW}"
    case "$a" in EMPTY) a="" ;; SPACES) a="   " ;; esac
    args+=("$a")
  done
  RUN="$TMP_ROOT/runs/$((++RUN_SEQ))"
  mkdir -p "$RUN"
  ERR="$RUN/stderr"
  set +e
  OUT=$("$WRITE" ${args[@]+"${args[@]}"} 2>"$ERR")
  RC=$?
  set -e
}

rec() { jq -r "$@" "$OUT" 2>/dev/null || echo UNPARSEABLE; }

# observe EXPECT — prints the run's value of every `name=` field EXPECT names,
# in EXPECT's order (`+` reads as a space in a needle and in a jq path, so a
# path cannot carry arithmetic or a literal plus, and a value's spaces print
# as `+`):
#   rc              exit status
#   written         `yes` when stdout names an existing file
#   stderr~<text>   whether stderr carries <text>
#   roundtrip       dev-artifact-check --file's reason for the written artifact
#   has:<key>       whether the record carries <key>
#   <jq path>       the path's value in the record (`.summary|split("\n")[0]`
#                   style filters allowed; a missing file reads UNPARSEABLE)
observe() {
  local got="" token name value needle
  set -f
  for token in $1; do
    name="${token%%=*}"
    case "$name" in
      rc) value="$RC" ;;
      written) value="$([[ -n "$OUT" && -f "$OUT" ]] && echo yes || echo no)" ;;
      stderr~*) needle="${name#stderr~}"; value="$(grep -qF -- "${needle//+/ }" "$ERR" && echo true || echo false)" ;;
      roundtrip) value="$("$CHECK" --file "$OUT" 2>/dev/null | jq -r '.reason' 2>/dev/null || echo UNPARSEABLE)" ;;
      has:*) value="$(rec "has(\"${name#has:}\")")" ;;
      *) value="$(rec "${name//+/ }")"; value="${value// /+}" ;;
    esac
    got="$got $name=$value"
  done
  set +f
  printf '%s' "${got# }"
}

# table ROW... — `label|args|expect`, one run and one assertion per row.
table() {
  local row label args expect
  for row in "$@"; do
    IFS='|' read -r label args expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    # shellcheck disable=SC2086
    run $args
    assert_eq "$(observe "$expect")" "$expect" "$label" "$ERR"
  done
}

echo "=== a single implement record, complete by construction ==="
# The record carries every field the schema names, the measured baseline
# included, without mutating workflow state; orchestrator acceptance records
# the baseline once and a later round preserves it.
init_growth_state "$STATE" "$WT" issue-776 "$RID"
run --worktree "$WT" --kind implement --issue issue-776 --round-id "$RID" --branch issue-776 --commit "$IMPL_HEAD" --validate pass --qa-label needs-review
assert_eq "rc=$RC $OUT" "rc=0 $WT/tmp/dev-return-issue-776-$RID.json" "the writer exits 0 and prints the round-scoped artifact path" "$ERR"
assert_eq "$(rec -c '.')" "{\"schema_version\":1,\"round_id\":\"$RID\",\"kind\":\"implement\",\"issue\":\"issue-776\",\"branch\":\"issue-776\",\"commit\":\"$IMPL_HEAD\",\"validate\":\"pass\",\"validate_note\":null,\"qa_labels\":[\"needs-review\"],\"summary_posted\":true,\"summary\":null,\"bundled\":false,\"items\":[],\"baseline_lines\":3}" \
  "the record is the schema's shape with the measured baseline, a numeric schema_version and no note" "$ERR"
assert_eq "$("$STATE" --state-dir "$WT/tmp" get issue-776 '.pr.baseline_lines // "null"')" "null" "the developer-side writer does not mutate workflow state"
assert_eq "$(env ORCH_STATE_DIR="$WT/tmp" "$CHECK" --worktree "$WT" --issue issue-776 --round-id "$RID" | jq -r '.reason'),$("$STATE" --state-dir "$WT/tmp" get issue-776 .pr.baseline_lines)" "valid,3" \
  "the record round-trips through round-mode acceptance, which records the baseline"
printf 'four\nfive\n' >> "$WT/implementation.txt"
git -C "$WT" add implementation.txt
git -C "$WT" commit -q -m growth
HEAD="$(git -C "$WT" rev-parse HEAD)"
run --worktree "$WT" --kind implement --issue issue-776 --round-id later --branch issue-776 --commit "$HEAD" --validate pass
env ORCH_STATE_DIR="$WT/tmp" "$CHECK" --worktree "$WT" --issue issue-776 --round-id later >/dev/null
assert_eq "rc=$RC baseline=$("$STATE" --state-dir "$WT/tmp" get issue-776 .pr.baseline_lines)" "rc=0 baseline=3" "a later round writes and preserves the first baseline" "$ERR"

echo "=== the record's variable fields, one written artifact per row ==="
# No labels is an empty list; --no-summary is summary_posted false; a FAILING
# verdict is recorded verbatim; --summary-file and --summary embed the text
# without marking it posted; a fix carries its items with numeric n and the
# three decisions; a bundled implement aggregates labels; the note is the
# additive channel for a caveat the enumeration cannot express, present and
# null when omitted; leading-dash prose is a value unless it is this script's
# own flag; a successful write leaves no temp file behind.
table \
  "no labels, --no-summary and a FAILING verdict|--worktree $WT --kind implement --issue issue-100 --round-id 5-5 --branch b --commit %H --validate FAILING:+lint,build --no-summary|rc=0 written=yes .qa_labels|tojson=[] .summary_posted=false .validate=FAILING:+lint,build roundtrip=valid" \
  "--summary-file embeds the file and keeps summary_posted false|--worktree $WT --kind implement --issue issue-gh --round-id 6-6 --branch b --commit %H --validate pass --no-summary --summary-file $SUMMARY_FILE|rc=0 .summary|split(\"\\n\")[0]=##+Completion+Summary .summary_posted=false" \
  "a fix carries its items, n numeric, and round-trips through the bound round|--worktree %FW --kind fix --issue issue-776 --round-id 7-7 --branch issue-776 --commit $FIX_HEAD --validate pass --item 1 Applied fixed+nil+deref --item 2 Skipped contradicts+D010|rc=0 .kind=fix .items|length=2 .items[0].n|type=number .items[1].decision=Skipped" \
  "a bundled implement aggregates its labels|--worktree $WT --kind implement --issue PROJ-100 --round-id 8-8 --branch feat/proj-100 --commit %H --validate pass --bundled --item 1 Applied sub+A+done --item 2 Applied sub+B+done --qa-label needs-safety-audit --qa-label needs-review|rc=0 .bundled=true .items|length=2 .qa_labels|tojson=[\"needs-safety-audit\",\"needs-review\"] roundtrip=valid" \
  "a Blocked decision is accepted|--worktree $WT --kind fix --issue issue-b --round-id 9-9 --branch b --commit c --validate pass --item 3 Blocked needs+API+design|rc=0 .items[0].decision=Blocked" \
  "an inline --summary embeds the text|--worktree $WT --kind implement --issue issue-1236i --round-id 12-12 --branch b --commit %H --validate pass --no-summary --summary inline+completion+summary|rc=0 .summary=inline+completion+summary roundtrip=valid" \
  "a --validate-note is recorded verbatim beside a strictly enumerated pass|--worktree $WT --kind implement --issue issue-note --round-id $RID --branch b --commit %H --validate pass --validate-note 80/80+on+re-run;+first+run+flaked|rc=0 .validate=pass .validate_note=80/80+on+re-run;+first+run+flaked" \
  "a FAILING verdict carries a note too|--worktree $WT --kind implement --issue issue-failnote --round-id $RID --branch b --commit %H --validate FAILING:+lint --validate-note lint+fails+only+under+--release|rc=0 .validate=FAILING:+lint .validate_note=lint+fails+only+under+--release" \
  "an omitted note is present and null|--worktree $WT --kind implement --issue issue-nonote --round-id $RID --branch b --commit %H --validate pass|rc=0 has:validate_note=true .validate_note=null" \
  "a leading single-dash summary is a value|--worktree $WT --kind implement --issue issue-dash --round-id 13-13 --branch b --commit %H --validate pass --summary -+close+as+duplicate+of+the+merged+fix --no-summary|rc=0 .summary=-+close+as+duplicate+of+the+merged+fix" \
  "double-dash prose that is not an own flag is a summary|--worktree $WT --kind implement --issue issue-ddash --round-id 14-14 --branch b --commit %H --validate pass --summary --foo+is+a+flag+of+the+consuming+tool --no-summary|rc=0 .summary=--foo+is+a+flag+of+the+consuming+tool" \
  "double-dash prose is accepted as --item REASONING|--worktree $WT --kind fix --issue issue-ddash2 --round-id 14-15 --branch b --commit c --validate pass --item 1 Skipped --force+would+be+needed|rc=0 .items[0].reasoning=--force+would+be+needed"
assert_eq "$(find "$WT/tmp" -maxdepth 1 -name '.dev-return-*' | wc -l | tr -d ' ')" "0" "a successful write leaves no temp file behind"
assert_eq "$("$CHECK" --worktree "$FW" --issue issue-776 --round-id 7-7 --expect-items-from-round | jq -r '.reason')" "valid" "the fix record round-trips through the bound round's authorization"

echo "=== every refusal exits 2 on its own guard and writes nothing ==="
# Every value-taking flag refuses a missing value and an option token in its
# place (an argc-only check would record `--no-summary` as the deliverable);
# single-valued flags refuse duplicates rather than last-win; both summary
# sources at once, or an explicitly empty --summary-file, are a config error
# and never a silent no-op; an empty or whitespace note or summary is refused
# rather than stored. Every implement row's commit `c` is unresolvable, so the
# stderr clause is what proves the row's own guard fired.
table \
  "a bad --kind|--worktree $WT --kind review --issue i --round-id $RID --branch b --commit c --validate pass|rc=2 stderr~--kind+must+be+implement+or+fix=true" \
  "a missing --round-id|--worktree $WT --kind implement --issue i --branch b --commit c --validate pass|rc=2 stderr~--round-id+is+required=true" \
  "a missing --issue|--worktree $WT --kind implement --round-id $RID --branch b --commit c --validate pass|rc=2 stderr~--issue+is+required=true" \
  "a value flag with no value at the end|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate|rc=2 stderr~--validate+requires+a+value=true" \
  "a missing --worktree|--kind implement --issue i --round-id $RID --branch b --commit c --validate pass|rc=2 stderr~--worktree+is+required=true" \
  "a nonexistent --worktree: the writer's own guard, not the base resolver's|--worktree $TMP_ROOT/nope --kind implement --issue i --round-id $RID --branch b --commit c --validate pass|rc=2 stderr~--worktree+path=true" \
  "a bad --validate|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate weird|rc=2 stderr~--validate+must+be+'pass'+or+begin+with+'FAILING:'=true" \
  "a verdict that only begins with pass, note and all|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass_with_notes --validate-note explained|rc=2 stderr~--validate+must+be+'pass'+or+begin+with+'FAILING:'=true" \
  "a path-unsafe --issue|--worktree $WT --kind implement --issue a/b --round-id $RID --branch b --commit c --validate pass|rc=2 stderr~--issue+'a/b'+must+match=true" \
  "a path-traversal --issue|--worktree $WT --kind implement --issue .. --round-id $RID --branch b --commit c --validate pass|rc=2 stderr~--issue+'..'+must+match=true" \
  "a path-unsafe --round-id|--worktree $WT --kind implement --issue i --round-id a/../b --branch b --commit c --validate pass|rc=2 stderr~--round-id+'a/../b'+must+match=true" \
  "a path-traversal --round-id|--worktree $WT --kind implement --issue i --round-id .. --branch b --commit c --validate pass|rc=2 stderr~--round-id+'..'+must+match=true" \
  "a missing --summary-file|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --summary-file $TMP_ROOT/nope.md|rc=2 stderr~does+not+exist=true" \
  "a bad --item DECISION|--worktree $WT --kind fix --issue i --round-id $RID --branch b --commit c --validate pass --item 1 Fixed x|rc=2 stderr~--item+DECISION+must+be+Applied=true" \
  "an empty --item REASONING|--worktree $WT --kind fix --issue i --round-id $RID --branch b --commit c --validate pass --item 1 Applied EMPTY|rc=2 stderr~REASONING+must+be+non-empty=true" \
  "a non-numeric --item N|--worktree $WT --kind fix --issue i --round-id $RID --branch b --commit c --validate pass --item x Applied x|rc=2 stderr~--item+N+must+be+a+non-negative+integer=true" \
  "--item with too few arguments|--worktree $WT --kind fix --issue i --round-id $RID --branch b --commit c --validate pass --item 1 Applied|rc=2 stderr~--item+requires+exactly+3+arguments=true" \
  "a fix with no --item|--worktree $WT --kind fix --issue issue-noitems --round-id $RID --branch b --commit c --validate pass|rc=2 stderr~at+least+one+--item+is+required=true" \
  "a bundled implement with no --item|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --bundled|rc=2 stderr~at+least+one+--item+is+required=true" \
  "an unknown argument|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --frobnicate|rc=2 stderr~unknown+argument:+--frobnicate=true" \
  "both --summary and --summary-file|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --summary inline --summary-file $SUMMARY_FILE|rc=2 stderr~mutually+exclusive=true" \
  "--summary plus an empty --summary-file value: presence, not content|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --summary inline --summary-file EMPTY|rc=2 stderr~mutually+exclusive=true" \
  "an explicitly empty --summary-file alone|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --summary-file EMPTY|rc=2 stderr~--summary-file+requires+a+non-empty+path=true" \
  "a whitespace-only --summary: an empty deliverable is not a record|--worktree $WT --kind implement --issue issue-blanksum --round-id $RID --branch b --commit %H --validate pass --summary SPACES|rc=2 stderr~--summary+must+contain+non-whitespace=true" \
  "--summary with no value|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --summary|rc=2 stderr~--summary+requires+a+value=true" \
  "--summary followed by another flag: an option token is not a value|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --summary --no-summary|rc=2 stderr~--summary+requires+a+value,+got+flag+'--no-summary'=true" \
  "--summary-file followed by another flag|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --summary-file --no-summary|rc=2 stderr~--summary-file+requires+a+value,+got+flag+'--no-summary'=true" \
  "--branch followed by another flag|--worktree $WT --kind implement --issue i --round-id $RID --branch --commit c --validate pass|rc=2 stderr~--branch+requires+a+value,+got+flag+'--commit'=true" \
  "--validate-note followed by another flag|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --validate-note --qa-label needs-review|rc=2 stderr~--validate-note+requires+a+value,+got+flag+'--qa-label'=true" \
  "--item REASONING as an option token|--worktree $WT --kind fix --issue i --round-id $RID --branch b --commit c --validate pass --item 1 Applied --bundled|rc=2 stderr~REASONING+must+be+text,+got+flag+'--bundled'=true" \
  "a duplicate --summary|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --summary first --summary second|rc=2 stderr~--summary+supplied+more+than+once=true" \
  "a duplicate --summary-file|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --summary-file $SUMMARY_FILE --summary-file $SUMMARY_FILE|rc=2 stderr~--summary-file+supplied+more+than+once=true" \
  "a duplicate --branch|--worktree $WT --kind implement --issue i --round-id $RID --branch b --branch b2 --commit c --validate pass|rc=2 stderr~--branch+supplied+more+than+once=true" \
  "a duplicate --validate|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --validate pass|rc=2 stderr~--validate+supplied+more+than+once=true" \
  "an empty --commit|--worktree $WT --kind implement --issue i --round-id $RID --branch b --validate pass --commit EMPTY|rc=2 stderr~--commit+is+required=true" \
  "a whitespace-only --validate-note|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --validate-note SPACES|rc=2 stderr~--validate-note+must+contain+non-whitespace=true" \
  "--validate-note with no value|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --validate-note|rc=2 stderr~--validate-note+requires+a+value=true"
assert_eq "$([[ -f "$WT/tmp/dev-return-issue-noitems-$RID.json" ]] && echo yes || echo no)" "no" "a rejected invocation writes no artifact at the target path"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
