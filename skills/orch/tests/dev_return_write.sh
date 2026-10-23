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
# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
TMP_ROOT="$(mktemp -d)" || { echo "dev_return_write: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "dev_return_write: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "dev_return_write: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
# The mode a fix round runs is read from the project's settings, and orch-env
# reads the process environment first: a developer's own range command would
# otherwise decide the round-trip rows.
unset DEV_VALIDATE_RANGE_CMD ORCH_PR_ORDER
VRUN="$(validate_run_dir "$TMP_ROOT/validate-run" full)"
VRUN_RANGE="$(validate_run_dir "$TMP_ROOT/validate-run-range" range)"
VRUN_BAD="$(validate_run_dir "$TMP_ROOT/validate-run-bad" class)"
VRUN_FAILED="$(validate_run_dir "$TMP_ROOT/validate-run-failed" full 1)"
VRUN_UNFINISHED="$(validate_run_dir "$TMP_ROOT/validate-run-unfinished" full none)"
VRUN_CUT="$(validate_run_dir "$TMP_ROOT/validate-run-cut" full no-verdict)"
mkdir -p "$TMP_ROOT/validate-run-empty"

new_repo() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name Test
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" config gc.auto 0
  git -C "$dir" config maintenance.auto false
  git -C "$dir" commit -q --allow-empty -m base
  printf '%s' "$dir"
}

# The implement worktree: a three-line implementation on issue-776.
# The fix worktree: a delegated two-item round.
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
mkdir -p "$FW/.cache/tracker-fixture" "$TMP_ROOT/bin"
printf '[{"identifier":"issue-776","description":"**Expected delta**: 100 lines, 100 test lines"}]\n' \
  > "$FW/.cache/tracker-fixture/issues.json"
cat > "$TMP_ROOT/bin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
jq -r --arg id "issue-$3" '.[] | select(.identifier == $id) | .description' .cache/tracker-fixture/issues.json
SH
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"
env ORCH_STATE_DIR="$FW/tmp" "$ROUND_WRITE" --worktree "$FW" --issue issue-776 --round-id 7-7 \
  --item 1 "fix nil deref" "tools/guard on a staged render" --item 2 "review decision" "tools/guard on a staged render" >/dev/null
# Further fix rounds on the same worktree, one per fix row below, each bound
# to its own record. Every record's base is FIX_HEAD, where the runs start.
for rid in 9-9 14-15 17-17 43-43; do
  growth_round_write "$STATE" "$ROUND_WRITE" --worktree "$FW" --issue issue-776 --round-id "$rid" \
    --item 1 "fix finding" "tools/guard on a staged render" >/dev/null
done
growth_round_write "$STATE" "$ROUND_WRITE" --worktree "$FW" --issue issue-776 --round-id 41-41 --pr-open true \
  --item 1 "fix finding" "tools/guard on a staged render" >/dev/null
VRUN_FIX="$(round_run_dir "$TMP_ROOT/validate-run-fix" "$FW" issue-776 7-7)"
VRUN_FIX_9="$(round_run_dir "$TMP_ROOT/validate-run-fix-9" "$FW" issue-776 9-9)"
VRUN_FIX_14="$(round_run_dir "$TMP_ROOT/validate-run-fix-14" "$FW" issue-776 14-15)"
VRUN_FIX_RANGE="$(round_run_dir "$TMP_ROOT/validate-run-fix-range" "$FW" issue-776 17-17 range)"
VRUN_FIX_CI="$(round_run_dir "$TMP_ROOT/validate-run-fix-ci" "$FW" issue-776 41-41 ci)"
printf 'tree=%s\n' "$(git -C "$FW" rev-parse HEAD^{tree})" >> "$VRUN_FIX_CI/start"
VRUN_FIX_CLASS="$(round_run_dir "$TMP_ROOT/validate-run-fix-class" "$FW" issue-776 43-43)"
printf 'class-base=%s\n' "$FIX_HEAD" >> "$VRUN_FIX_CLASS/start"
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
  OUT=$(env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$PATH" HOME="$TMP_ROOT" LC_ALL=C \
    COMMIT_GUARDS_BYTE_CEILING_KB="${COMMIT_GUARDS_BYTE_CEILING_KB:-}" \
    COMMIT_GUARDS_BYTE_WARN_PCT="${COMMIT_GUARDS_BYTE_WARN_PCT:-}" \
    "$WRITE" ${args[@]+"${args[@]}"} 2>"$ERR")
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
    name="${token%=*}"
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
  local row label args expect fresh_issue independent=false
  if [[ "${1:-}" == --independent ]]; then independent=true; shift; fi
  for row in "$@"; do
    IFS='|' read -r label args expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    if [[ "$independent" == true && "$args" == *'--kind implement '* ]]; then
      fresh_issue="${args#*--issue }"; fresh_issue="${fresh_issue%% *}"
      args="${args/--issue $fresh_issue /--issue $fresh_issue-$((RUN_SEQ + 1)) }"
    fi
    # shellcheck disable=SC2086
    run $args
    assert_eq "$(observe "$expect")" "$expect" "$label" "$ERR"
  done
}

echo "=== a single implement record, complete by construction ==="
# The record carries every field the schema names, including its measured baseline.
init_growth_state "$STATE" "$WT" issue-776 "$RID"
run --worktree "$WT" --kind implement --issue issue-776 --round-id "$RID" --branch issue-776 --commit "$IMPL_HEAD" --validate pass --validate-run-dir "$VRUN" --qa-label needs-review
assert_eq "rc=$RC $OUT" "rc=0 $WT/tmp/dev-return-issue-776-$RID.json" "the writer exits 0 and prints the round-scoped artifact path" "$ERR"
assert_eq "$(rec -c '.')" "{\"schema_version\":1,\"round_id\":\"$RID\",\"kind\":\"implement\",\"issue\":\"issue-776\",\"branch\":\"issue-776\",\"commit\":\"$IMPL_HEAD\",\"validate\":\"pass\",\"validate_mode\":\"full\",\"validate_time\":{\"started_at\":\"2026-01-01T00:00:00Z\",\"ended_at\":\"2026-01-01T00:55:00Z\",\"seconds\":3300},\"validate_note\":null,\"qa_labels\":[\"needs-review\"],\"near_ceiling\":null,\"near_ceiling_error\":\"byte-ceiling not probed: no --near-ceiling-base\",\"summary_posted\":true,\"summary\":null,\"recovered_from\":null,\"bundled\":false,\"items\":[],\"validate_selection\":\"unreported\",\"baseline_lines\":3}" \
  "the record is the schema's shape with the measured baseline, the run's wall time, a numeric schema_version and no note" "$ERR"
assert_eq "$(env ORCH_STATE_DIR="$WT/tmp" "$CHECK" --worktree "$WT" --issue issue-776 --round-id "$RID" | jq -r '.reason')" "valid" \
  "the record round-trips through round-mode acceptance"

echo "=== the record's variable fields, one written artifact per row ==="
# No labels is an empty list; --no-summary is summary_posted false; a FAILING
# verdict is recorded verbatim; --summary-file and --summary embed the text
# without marking it posted; --recovered-text embeds a transcript's report and
# marks the record recovered; a fix carries its items with numeric n and the
# three decisions; a bundled implement aggregates labels; the note is the
# additive channel for a caveat the enumeration cannot express, present and
# null when omitted; leading-dash prose is a value unless it is this script's
# own flag; a successful write leaves no temp file behind.
table \
  "no labels, --no-summary and a FAILING verdict|--worktree $WT --kind implement --issue issue-100 --round-id 5-5 --branch b --commit %H --validate FAILING:+lint,build --no-summary|rc=0 written=yes .qa_labels|tojson=[] .summary_posted=false .validate=FAILING:+lint,build roundtrip=valid" \
  "--summary-file embeds the file and keeps summary_posted false|--worktree $WT --kind implement --issue issue-gh --round-id 6-6 --branch b --commit %H --validate pass --validate-run-dir $VRUN --no-summary --summary-file $SUMMARY_FILE|rc=0 .summary|split(\"\\n\")[0]=##+Completion+Summary .summary_posted=false" \
  "a fix carries its items, n numeric, and round-trips through the bound round|--worktree %FW --kind fix --issue issue-776 --round-id 7-7 --branch issue-776 --commit $FIX_HEAD --validate pass --validate-run-dir $VRUN_FIX --item 1 Applied fixed+nil+deref --item 2 Skipped contradicts+D010|rc=0 .kind=fix has:validate_class_base=false .items|length=2 .items[0].n|type=number .items[0].decision=Applied .items[1].decision=Skipped" \
  "a bundled implement aggregates its labels|--worktree $WT --kind implement --issue PROJ-100 --round-id 8-8 --branch feat/proj-100 --commit %H --validate pass --validate-run-dir $VRUN --bundled --item 1 Applied sub+A+done --item 2 Applied sub+B+done --qa-label needs-safety-audit --qa-label needs-review|rc=0 .bundled=true .items|length=2 .qa_labels|tojson=[\"needs-safety-audit\",\"needs-review\"] roundtrip=valid" \
  "a Blocked decision is accepted|--worktree %FW --kind fix --issue issue-776 --round-id 9-9 --branch b --commit c --validate pass --validate-run-dir $VRUN_FIX_9 --item 3 Blocked needs+API+design|rc=0 .items[0].decision=Blocked" \
  "--recovered-text embeds the report and records recovered_from|--worktree $WT --kind implement --issue issue-rec --round-id 15-15 --branch b --commit %H --validate pass --validate-run-dir $VRUN --recovered-text $SUMMARY_FILE|rc=0 .recovered_from=transcript .summary|split(\"\\n\")[0]=##+Completion+Summary roundtrip=valid" \
  "an inline --summary embeds the text|--worktree $WT --kind implement --issue issue-1236i --round-id 12-12 --branch b --commit %H --validate pass --validate-run-dir $VRUN --no-summary --summary inline+completion+summary|rc=0 .summary=inline+completion+summary roundtrip=valid" \
  "a --validate-note is recorded verbatim beside a strictly enumerated pass|--worktree $WT --kind implement --issue issue-note --round-id $RID --branch b --commit %H --validate pass --validate-run-dir $VRUN --validate-note 80/80+on+re-run;+first+run+flaked|rc=0 .validate=pass .validate_note=80/80+on+re-run;+first+run+flaked" \
  "a FAILING verdict carries a note too|--worktree $WT --kind implement --issue issue-failnote --round-id $RID --branch b --commit %H --validate FAILING:+lint --validate-note lint+fails+only+under+--release|rc=0 .validate=FAILING:+lint .validate_note=lint+fails+only+under+--release" \
  "a CI receipt expands a seven-character commit and round-trips|--worktree %FW --kind fix --issue issue-776 --round-id 41-41 --branch b --commit ${FIX_HEAD:0:7} --validate pass --validate-run-dir $VRUN_FIX_CI --item 1 Applied fixed|rc=0 .commit=$FIX_HEAD .commit|length=40 .validate_mode=ci roundtrip=valid" \
  "a range validation is recorded as the mode that ran|--worktree %FW --kind fix --issue issue-776 --round-id 17-17 --branch b --commit c --validate pass --validate-run-dir $VRUN_FIX_RANGE --item 1 Applied fixed|rc=0 .validate_mode=range" \
  "a FAILING result beside a run that passed, another gate failing, records the run's mode and wall time|--worktree $WT --kind implement --issue issue-gatefail --round-id 20-20 --branch b --commit %H --validate FAILING:+doc-limits --validate-run-dir $VRUN|rc=0 .validate=FAILING:+doc-limits .validate_mode=full .validate_time.seconds=3300" \
  "a FAILING result beside an unfinished run records the run's mode and no wall time|--worktree $WT --kind implement --issue issue-lost --round-id 21-21 --branch b --commit %H --validate FAILING:+lost --validate-run-dir $VRUN_UNFINISHED|rc=0 .validate=FAILING:+lost .validate_mode=full has:validate_time=true .validate_time|tojson=null roundtrip=valid" \
  "a FAILING result naming a failed run records the run's mode|--worktree $WT --kind implement --issue issue-failrun --round-id 19-19 --branch b --commit %H --validate FAILING:+lint --validate-run-dir $VRUN_FAILED|rc=0 .validate_mode=full" \
  "a no-verdict result beside a run the timeout ended records the run's mode and wall time|--worktree $WT --kind implement --issue issue-cut --round-id 22-22 --branch b --commit %H --validate no-verdict --validate-run-dir $VRUN_CUT --validate-note scoped+suites+green:+dev_return_write.sh|rc=0 .validate=no-verdict .validate_mode=full .validate_time.seconds=3300 .validate_note=scoped+suites+green:+dev_return_write.sh roundtrip=valid" \
  "a FAILING result beside a run the timeout ended is accepted|--worktree $WT --kind implement --issue issue-cutfail --round-id 23-23 --branch b --commit %H --validate FAILING:+lint --validate-run-dir $VRUN_CUT|rc=0 .validate=FAILING:+lint" \
  "a FAILING round with no run records a null mode and wall time|--worktree $WT --kind implement --issue issue-norun --round-id 18-18 --branch b --commit %H --validate FAILING:+DEV_VALIDATE_CMD|rc=0 has:validate_mode=true .validate_mode=null has:validate_time=true .validate_time|tojson=null roundtrip=valid" \
  "an omitted note is present and null|--worktree $WT --kind implement --issue issue-nonote --round-id $RID --branch b --commit %H --validate pass --validate-run-dir $VRUN|rc=0 has:validate_note=true .validate_note=null" \
  "a round that did not probe records null and the not-probed cause, never an empty list|--worktree $WT --kind implement --issue issue-nonear --round-id 16-16 --branch b --commit %H --validate pass --validate-run-dir $VRUN|rc=0 has:near_ceiling=true .near_ceiling|tojson=null .near_ceiling_error=byte-ceiling+not+probed:+no+--near-ceiling-base roundtrip=valid" \
  "a leading single-dash summary is a value|--worktree $WT --kind implement --issue issue-dash --round-id 13-13 --branch b --commit %H --validate pass --validate-run-dir $VRUN --summary -+close+as+duplicate+of+the+merged+fix --no-summary|rc=0 .summary=-+close+as+duplicate+of+the+merged+fix" \
  "double-dash prose that is not an own flag is a summary|--worktree $WT --kind implement --issue issue-ddash --round-id 14-14 --branch b --commit %H --validate pass --validate-run-dir $VRUN --summary --foo+is+a+flag+of+the+consuming+tool --no-summary|rc=0 .summary=--foo+is+a+flag+of+the+consuming+tool" \
  "double-dash prose is accepted as --item REASONING|--worktree %FW --kind fix --issue issue-776 --round-id 14-15 --branch b --commit c --validate pass --validate-run-dir $VRUN_FIX_14 --item 1 Skipped --force+would+be+needed|rc=0 .items[0].reasoning=--force+would+be+needed"
assert_eq "$(find "$WT/tmp" -maxdepth 1 -name '.dev-return-*' | wc -l | tr -d ' ')" "0" "a successful write leaves no temp file behind"
assert_eq "$("$CHECK" --worktree "$FW" --issue issue-776 --round-id 7-7 --expect-items-from-round | jq -r '.reason')" "valid" "the fix record round-trips through the bound round's authorization"

assert_eq "$("$CHECK" --worktree "$FW" --issue issue-776 --round-id 41-41 --expect-items-from-round | jq -r '.reason')" "valid" "the full-ID CI receipt passes round acceptance"
WRITE_LIVE="$WRITE"
WRITE="$(mutant_scripts short-commit-mutant dev-return-write)/dev-return-write" || exit 1
mutate_file "$WRITE" 'rev-parse --verify "$commit^{commit}"' 'rev-parse --verify --short=7 "$commit^{commit}"'
table "control: storing the short commit refuses the CI receipt|--worktree %FW --kind fix --issue issue-776 --round-id 41-41 --branch b --commit ${FIX_HEAD:0:7} --validate pass --validate-run-dir $VRUN_FIX_CI --item 1 Applied fixed|rc=0 .commit=${FIX_HEAD:0:7}"
CHECK_RC=0
CHECK_OUT="$("$CHECK" --worktree "$FW" --issue issue-776 --round-id 41-41 --expect-items-from-round 2>/dev/null)" || CHECK_RC=$?
assert_eq "$CHECK_RC $(jq -r '.reason' <<<"$CHECK_OUT")" "1 ci_head_mismatch" "the reader rejects the short-ID round"
WRITE="$WRITE_LIVE"
table "CI refuses a tree as a commit|--worktree %FW --kind fix --issue issue-776 --round-id 41-41 --branch b --commit $FIX_HEAD^{tree} --validate pass --validate-run-dir $VRUN_FIX_CI --item 1 Applied fixed|rc=2 written=no stderr~dev-return-write:+ci-contents-mismatch=true"

# The runner's snapshot may precede the workflow commit. A CI receipt binds
# that existing snapshot to committed contents, not just an ancestor HEAD.
CW="$(new_repo ci-contents)"
init_growth_state "$STATE" "$CW" issue-3231 pending 100
mkdir -p "$CW/.cache/tracker-fixture"
printf '[{"identifier":"issue-3231","description":"**Expected delta**: 100 lines, 100 test lines"}]\n' > "$CW/.cache/tracker-fixture/issues.json"
printf '.cache/\n' >> "$(git -C "$CW" rev-parse --path-format=absolute --git-path info/exclude)"
growth_round_write "$STATE" "$ROUND_WRITE" --worktree "$CW" --issue issue-3231 --round-id pending \
  --item 1 'committed edits' 'current branch publication' >/dev/null
CRUN="$(round_run_dir "$TMP_ROOT/ci-contents-run" "$CW" issue-3231 pending ci)"
printf 'tree=%s\n' "$(git -C "$CW" rev-parse HEAD^{tree})" >> "$CRUN/start"
printf 'later edit\n' > "$CW/later.txt"
git -C "$CW" add later.txt
git -C "$CW" commit -q -m later
CHEAD="$(git -C "$CW" rev-parse HEAD)"
table "pending CI cannot name changed contents|--worktree $CW --kind fix --issue issue-3231 --round-id pending --branch b --commit $CHEAD --validate pass --validate-run-dir $CRUN --item 1 Applied done|rc=2 written=no stderr~dev-return-write:+ci-contents-mismatch=true"
WRITE_LIVE="$WRITE"
WRITE="$(mutant_scripts ci-contents-mutant dev-return-write)/dev-return-write" || exit 1
mutate_file "$WRITE" '[[ -n "$run_tree" && "$run_tree" == "$commit_tree" ]]' 'true'
table "control: dropping the snapshot comparison accepts stale pending contents|--worktree $CW --kind fix --issue issue-3231 --round-id pending --branch b --commit $CHEAD --validate pass --validate-run-dir $CRUN --item 1 Applied done|rc=0 .validate_mode=ci"
WRITE="$WRITE_LIVE"

echo "=== reported lanes reach the receipt ==="
VRUN_LANES="$(validate_run_dir "$TMP_ROOT/validate-run-lanes" full)"
printf 'validate: lanes=lint,test selection=subset\n' > "$VRUN_LANES/log"
LANE_ARGS="--worktree $WT --kind implement --issue issue-lanes --round-id 25-25 --branch b --commit $IMPL_HEAD --validate pass --validate-run-dir $VRUN_LANES"
table "reported lanes and selection|$LANE_ARGS|rc=0 .validate_mode=full .validate_lanes=lint,test .validate_selection=subset roundtrip=valid"
LANE_WRITE="$(mutant_scripts lanes-mutant dev-return-write)/dev-return-write" || exit 1
mutate_file "$LANE_WRITE" 'lanes=*) validate_lanes="${field#*=}" ;;' 'lanes=*) validate_lanes="" ;;'
WRITE_SHIPPED="$WRITE"
WRITE="$LANE_WRITE"
table "control: dropping lanes reds the receipt assertion|$LANE_ARGS|rc=0 has:validate_lanes=false .validate_selection=subset"
WRITE="$WRITE_SHIPPED"

echo "=== a class read from the round base reaches the receipt ==="
# A full run in a project with no range command, whose class dev-validate-run
# read from the round base: submit must not reuse it as the branch's.
CLASS_ARGS="--worktree %FW --kind fix --issue issue-776 --round-id 43-43 --branch b --commit $FIX_HEAD --validate pass --validate-run-dir $VRUN_FIX_CLASS --item 1 Applied fixed"
table "a full pass judged from the round base records that base|$CLASS_ARGS|rc=0 .validate_mode=full .validate_class_base=$FIX_HEAD roundtrip=valid"
CLASS_WRITE="$(mutant_scripts class-base-mutant dev-return-write)/dev-return-write" || exit 1
mutate_file "$CLASS_WRITE" 'class-base=*) validate_class_base="${field#*=}" ;;' 'class-base=*) validate_class_base="" ;;'
WRITE="$CLASS_WRITE"
table "control: dropping the class base records the round's full pass as the branch's|$CLASS_ARGS|rc=0 .validate_mode=full has:validate_class_base=false"
WRITE="$WRITE_SHIPPED"
# Beside the class base the receipt carries what the command covered, which
# submit reads: its whole battery reuses, a subset never does.
printf 'validate: lanes=lint,test selection=battery\n' > "$VRUN_FIX_CLASS/log"
table "a full pass whose command ran its whole battery carries battery beside the class base|$CLASS_ARGS|rc=0 .validate_mode=full .validate_selection=battery .validate_class_base=$FIX_HEAD roundtrip=valid"
printf 'validate: lanes=lint selection=subset\n' > "$VRUN_FIX_CLASS/log"
table "a full pass whose command stood lanes down carries subset beside the class base|$CLASS_ARGS|rc=0 .validate_mode=full .validate_selection=subset .validate_class_base=$FIX_HEAD roundtrip=valid"
rm -- "${VRUN_FIX_CLASS:?}/log"

echo "=== the Apple gate: a triggered pass carries the mac run test line ==="
# AW's main holds the mac-run workflow, an Xcode project, a Package.swift naming
# neither platform and ios/Moved.swift. Each trigger is one commit off main: apple_commit PATH
# [CONTENT] writes PATH, or deletes it with no CONTENT, and prints the commit.
AW="$(new_repo apple-wt)"
mkdir -p "$AW/.github/workflows" "$AW/ios" "$AW/App.xcodeproj" "$AW/App" "$AW/AppTests"
mkdir -p "$AW/linux-package/Sources/LinuxUtility"
printf 'name: mac-run\n' > "$AW/.github/workflows/mac-run.yml"
printf 'let package = Package(platforms: [.tvOS(.v17)])\n' > "$AW/Package.swift"
printf 'moved\n' > "$AW/ios/Moved.swift"
printf 'source\n' > "$AW/App/Greeting.swift"
printf 'test\n' > "$AW/AppTests/GreetingTests.swift"
cat > "$AW/linux-package/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "LinuxUtility", targets: [.target(name: "LinuxUtility")])
SWIFT
printf 'public let message = "base"\n' > "$AW/linux-package/Sources/LinuxUtility/LinuxEntry.swift"
cat > "$AW/App.xcodeproj/project.pbxproj" <<'PBX'
// !$*UTF8*$!
{
  objects = {
    SOURCE = {isa = PBXFileReference; path = Greeting.swift; sourceTree = "<group>"; };
    TEST = {
      isa = PBXFileReference;
      name = "GreetingTests.swift";
      path = ../External/TestBody.swift;
      sourceTree = "<group>";
    };
    SYNC = {
      isa = PBXFileSystemSynchronizedRootGroup;
      explicitFileTypes = {};
      path = "Features";
      sourceTree = "<group>";
    };
    RELATIVE = {isa = PBXFileReference; path = "../Assets/Shared"; sourceTree = "<group>"; };
    GROUP = {isa = PBXGroup; path = Tools; sourceTree = "<group>"; };
  };
}
PBX
git -C "$AW" add .github Package.swift ios App.xcodeproj App AppTests linux-package
git -C "$AW" commit -q -m workflow
apple_commit() {
  git -C "$AW" checkout -q --detach main &&
    if [[ $# -eq 2 ]]; then
      mkdir -p "$AW/$(dirname "$1")" && printf '%s\n' "$2" > "$AW/$1" && git -C "$AW" add -- "$1"
    else
      git -C "$AW" rm -q -- "$1"
    fi &&
    git -C "$AW" commit -q -m "$1" &&
    git -C "$AW" rev-parse HEAD
}
A_PLAIN="$(apple_commit notes.txt plain)" || exit 1
A_SOURCE="$(apple_commit App/Greeting.swift changed)" || exit 1
A_TEST="$(apple_commit AppTests/GreetingTests.swift changed)" || exit 1
A_SYNC="$(apple_commit Features/New.swift added)" || exit 1
A_RELATIVE="$(apple_commit Assets/new.txt added)" || exit 1
A_UNRELATED="$(apple_commit Tools/notes.txt unrelated)" || exit 1
A_LINUX_SOURCE="$(apple_commit linux-package/Sources/LinuxUtility/LinuxEntry.swift 'public let message = "changed"')" || exit 1
A_XCODEPROJ="$(apple_commit App.xcodeproj/project.pbxproj objects)" || exit 1
A_XCWORKSPACE="$(apple_commit App.xcworkspace/contents.xcworkspacedata workspace)" || exit 1
A_IOS="$(apple_commit ios/App.swift app)" || exit 1
A_MACOS="$(apple_commit apps/macos/App.swift app)" || exit 1
A_PKG_IOS="$(apple_commit Package.swift 'let package = Package(platforms: [.iOS(.v17)])')" || exit 1
A_PKG_MACOS="$(apple_commit pkg/Package.swift 'let package = Package(platforms: [.macOS(.v14)])')" || exit 1
A_PKG_NEITHER="$(apple_commit pkg/Package.swift 'let package = Package(platforms: [.watchOS(.v10)])')" || exit 1
A_PKG_DELETED="$(apple_commit Package.swift)" || exit 1
A_MOVED="$(git -C "$AW" checkout -q --detach main && mkdir -p "$AW/src" && git -C "$AW" mv ios/Moved.swift src/Moved.swift &&
  git -C "$AW" commit -q -m move && git -C "$AW" rev-parse HEAD)" || exit 1
git -C "$AW" checkout -q main
# A fix round on AW, delegated at main, whose fix is a non-Apple path.
init_growth_state "$STATE" "$AW" issue-777 31-31
mkdir -p "$AW/.cache/tracker-fixture"
printf '[{"identifier":"issue-777","description":"**Expected delta**: 100 lines, 100 test lines"}]\n' \
  > "$AW/.cache/tracker-fixture/issues.json"
growth_round_write "$STATE" "$ROUND_WRITE" --worktree "$AW" --issue issue-777 --round-id 31-31 \
  --item 1 "fix finding" "tools/guard on a staged render" >/dev/null
VRUN_AFIX="$(round_run_dir "$TMP_ROOT/validate-run-afix" "$AW" issue-777 31-31)"
AFIX="--worktree $AW --kind fix --issue issue-777 --round-id 31-31 --branch b --commit $A_PLAIN --validate pass --validate-run-dir $VRUN_AFIX --item 1 Applied x"
AW_ARGS="--worktree $AW --kind implement --issue issue-apple --round-id 30-30 --branch b"
AP="$AW_ARGS --validate pass --validate-run-dir $VRUN"
APN="$AP --no-labels"
MAC_NOTE="mac+run+test:+pass+run=4242"
APPLE_ROWS=(
  "the ios label|$AP --commit $A_PLAIN --label ios|rc=2 written=no stderr~dev-return-write:+mac-run-missing+label=ios+validate=pass=true"
  "the macos label among others|$AP --commit $A_PLAIN --label skills --label macos|rc=2 written=no stderr~dev-return-write:+mac-run-missing+label=macos+validate=pass=true"
  "a fix receipt for a label-only item|$AFIX --label ios|rc=2 written=no stderr~dev-return-write:+mac-run-missing+label=ios+validate=pass=true"
  "an omitted label declaration|$AP --commit $A_PLAIN|rc=2 written=no stderr~dev-return-write:+labels-undeclared+path=$AW+base=refs/heads/main=true"
  "a label beside --no-labels|$AP --commit $A_PLAIN --label skills --no-labels|rc=2 written=no stderr~dev-return-write:+labels-conflict+labels=skills=true"
  "an .xcodeproj path|$APN --commit $A_XCODEPROJ|rc=2 written=no stderr~dev-return-write:+mac-run-missing+path=App.xcodeproj/project.pbxproj=true"
  "an .xcworkspace path|$APN --commit $A_XCWORKSPACE|rc=2 written=no stderr~dev-return-write:+mac-run-missing+path=App.xcworkspace/contents.xcworkspacedata=true"
  "an ios/ path|$APN --commit $A_IOS|rc=2 written=no stderr~dev-return-write:+mac-run-missing+path=ios/App.swift=true"
  "a nested macos/ path|$APN --commit $A_MACOS|rc=2 written=no stderr~dev-return-write:+mac-run-missing+path=apps/macos/App.swift=true"
  "a move out of ios/|$APN --commit $A_MOVED|rc=2 written=no stderr~dev-return-write:+mac-run-missing+path=ios/Moved.swift=true"
  "an Xcode source-only change|$APN --commit $A_SOURCE|rc=2 written=no stderr~dev-return-write:+mac-run-missing+path=App/Greeting.swift=true"
  "an Xcode test-only change selected by name|$APN --commit $A_TEST|rc=2 written=no stderr~dev-return-write:+mac-run-missing+path=AppTests/GreetingTests.swift=true"
  "a synchronized Xcode folder member|$APN --commit $A_SYNC|rc=2 written=no stderr~dev-return-write:+mac-run-missing+path=Features/New.swift=true"
  "a relative reference directory component|$APN --commit $A_RELATIVE|rc=2 written=no stderr~dev-return-write:+mac-run-missing+path=Assets/new.txt=true"
  "an unrelated group name|$APN --commit $A_UNRELATED|rc=0 written=yes .validate_note=null"
  "a Linux package source-only change|$APN --commit $A_LINUX_SOURCE|rc=0 written=yes .validate_note=null"
  "a Package.swift naming .iOS|$APN --commit $A_PKG_IOS|rc=2 written=no stderr~dev-return-write:+mac-run-missing+path=Package.swift=true"
  "a nested Package.swift naming .macOS|$APN --commit $A_PKG_MACOS|rc=2 written=no stderr~dev-return-write:+mac-run-missing+path=pkg/Package.swift=true"
  "a no-verdict is held as a pass is|$AW_ARGS --commit $A_PLAIN --label ios --validate no-verdict --validate-run-dir $VRUN_CUT --validate-note scoped+suites+green|rc=2 written=no stderr~dev-return-write:+mac-run-missing+label=ios+validate=no-verdict=true"
  "a pass line without its run id is no record|$APN --commit $A_IOS --validate-note mac+run+test:+pass|rc=2 written=no stderr~dev-return-write:+mac-run-missing+path=ios/App.swift=true"
  "text before the pass line on its line is no record|$APN --commit $A_IOS --validate-note scoped+suites+green:+x.sh;+$MAC_NOTE|rc=2 written=no stderr~dev-return-write:+mac-run-missing+path=ios/App.swift=true"
  "text after the run id is no record|$APN --commit $A_IOS --validate-note $MAC_NOTE+then+more|rc=2 written=no stderr~dev-return-write:+mac-run-missing+path=ios/App.swift=true"
  "a Package.swift naming neither platform|$APN --commit $A_PKG_NEITHER|rc=0 written=yes .validate_note=null"
  "a deleted Package.swift names no platform|$APN --commit $A_PKG_DELETED|rc=0 written=yes .validate_note=null"
  "the recorded pass line is accepted and round-trips|$APN --commit $A_IOS --validate-note $MAC_NOTE|rc=0 .validate_note|sub(\"=\";\":\")=${MAC_NOTE/=/:} roundtrip=valid"
  "a FAILING mac run test needs no pass line and no labels|$AW_ARGS --commit $A_IOS --validate FAILING:+mac+run+test|rc=0 .validate=FAILING:+mac+run+test roundtrip=valid"
)
table --independent "${APPLE_ROWS[@]}"

# Consumer settings bind another workflow and replace the default labels.
# run invokes the writer from this checkout, so these rows also prove that
# --worktree, rather than the caller's repository, owns the settings read.
CW="$(new_repo apple-configured)"
mkdir -p "$CW/.github/workflows" "$CW/App.xcodeproj" "$CW/App"
printf 'name: apple-run\n' > "$CW/.github/workflows/apple-run.yml"
cp "$AW/App.xcodeproj/project.pbxproj" "$CW/App.xcodeproj/project.pbxproj"
printf 'source\n' > "$CW/App/Greeting.swift"
git -C "$CW" add .
git -C "$CW" commit -q -m base-project
C_PLAIN="$(git -C "$CW" rev-parse HEAD)"
git -C "$CW" switch -q -c work
printf 'changed\n' > "$CW/App/Greeting.swift"
git -C "$CW" add App/Greeting.swift
git -C "$CW" commit -q -m source
C_SOURCE="$(git -C "$CW" rev-parse HEAD)"
printf '[env]\nORCH_APPLE_WORKFLOW = ".github/workflows/apple-run.yml"\nORCH_APPLE_LABELS = "apple-mobile apple-desktop"\n' > "$CW/kendex.settings.toml"
CP="--worktree $CW --kind implement --issue issue-apple --round-id 30-30 --branch b --validate pass --validate-run-dir $VRUN"
table \
  "a configured workflow with an unlabeled Xcode source change|$CP --commit $C_SOURCE --no-labels|rc=2 written=no stderr~dev-return-write:+mac-run-missing+path=App/Greeting.swift=true" \
  "a configured label from the space-separated set|$CP --commit $C_PLAIN --label apple-desktop|rc=2 written=no stderr~dev-return-write:+mac-run-missing+label=apple-desktop=true" \
  "a default label outside the configured set|$CP --commit $C_PLAIN --label ios|rc=0 written=yes .validate_note=null"
# Fix receipts skip the implement growth measurement's earlier settings read.
printf '[env]\nORCH_APPLE_WORKFLOW = false\n' > "$FW/kendex.settings.toml"
table "a settings read failure refuses the receipt|--worktree %FW --kind fix --issue issue-776 --round-id 9-9 --branch b --commit $FIX_HEAD --validate pass --validate-run-dir $VRUN_FIX_9 --no-labels --item 3 Blocked x|rc=2 written=no stderr~dev-return-write:+unreadable-setting+setting=ORCH_APPLE_WORKFLOW=true"
rm -- "$FW/kendex.settings.toml"
# Each project is private to its row: unsupported names must not arm the
# neutral fixture used to prove unrelated and Linux source exclusions.
ESCAPE_ROWS=(
  'a quoted object kind and literal Unicode name|"PBXFileReference"|path|Café.swift|App/Café.swift|path=App/Café.swift'
  'an unsupported file path escape|PBXFileReference|path|Caf\U00e9.swift|App/Café.swift|project=App.xcodeproj/project.pbxproj'
  'an unsupported file name escape|PBXFileReference|name|Caf\U00e9.swift|App/Café.swift|project=App.xcodeproj/project.pbxproj'
  'an unsupported synchronized path escape|PBXFileSystemSynchronizedRootGroup|path|Caf\U00e9|Café/New.swift|project=App.xcodeproj/project.pbxproj'
  'an unsupported synchronized name escape|PBXFileSystemSynchronizedRootGroup|name|Caf\U00e9|Café/New.swift|project=App.xcodeproj/project.pbxproj'
  'an escaped quote reference|PBXFileReference|path|Quoted\"Name.swift|App/Quoted"Name.swift|path=App/Quoted"Name.swift'
  'an escaped backslash reference|PBXFileReference|path|Literal\\Name.swift|App/Literal\Name.swift|path=App/Literal\Name.swift'
  'a literal backslash before U|PBXFileReference|path|Caf\\U00e9.swift|App/Caf\U00e9.swift|path=App/Caf\U00e9.swift'
  'an unrelated edit beside quote and backslash pairs|PBXFileReference|path|Quoted\"And\\Name.swift|notes.txt|none'
  'an unrelated edit beside a literal backslash before U|PBXFileReference|path|Caf\\U00e9.swift|notes.txt|none'
  'an unrelated shell script escape|PBXShellScriptBuildPhase|shellScript|printf \"done\n\"|notes.txt|none'
  'unrelated group metadata escapes|PBXGroup|path|Caf\U00e9|notes.txt|none'
)
ESCAPE_CONTROL_ARGS=""
escape_index=0
for row in "${ESCAPE_ROWS[@]}"; do
  IFS='|' read -r label object_kind field spelling changed_path cause <<<"$row"
  escape_index=$((escape_index + 1))
  EW="$(new_repo "apple-escape-$escape_index")"
  mkdir -p "$EW/.github/workflows" "$EW/App.xcodeproj" "$EW/$(dirname "$changed_path")"
  printf 'name: mac-run\n' > "$EW/.github/workflows/mac-run.yml"
  printf '{ objects = { REF = { %s = "%s"; isa = %s; }; }; }\n' "$field" "$spelling" "$object_kind" \
    > "$EW/App.xcodeproj/project.pbxproj"
  printf 'base\n' > "$EW/$changed_path"
  git -C "$EW" add -- .github App.xcodeproj "$changed_path"
  git -C "$EW" commit -q -m project
  git -C "$EW" switch -q -c work
  printf 'changed\n' > "$EW/$changed_path"
  git -C "$EW" add -- "$changed_path"
  git -C "$EW" commit -q -m source
  E_HEAD="$(git -C "$EW" rev-parse HEAD)"
  E_ARGS="--worktree $EW --kind implement --issue issue-apple-escape --round-id 30-30 --branch b --commit $E_HEAD --no-labels --validate pass --validate-run-dir $VRUN"
  if [[ "$cause" == none ]]; then
    expect="rc=0 written=yes .validate_note=null"
  else
    expect="rc=2 written=no stderr~dev-return-write:+mac-run-missing+$cause=true"
  fi
  table "$label|$E_ARGS|$expect"
  if [[ "$object_kind/$field/$spelling" == 'PBXFileReference/path/Caf\U00e9.swift' ]]; then
    ESCAPE_CONTROL_ARGS="$E_ARGS"
  fi
done
[[ -n "$ESCAPE_CONTROL_ARGS" ]] || exit 1
# An incomplete Git object store can list a committed project without reading it.
UW="$(new_repo apple-unreadable)"
mkdir -p "$UW/.github/workflows" "$UW/App.xcodeproj"
printf 'name: mac-run\n' > "$UW/.github/workflows/mac-run.yml"
printf '{ objects = {}; }\n' > "$UW/App.xcodeproj/project.pbxproj"
git -C "$UW" add .github App.xcodeproj
git -C "$UW" commit -q -m project
git -C "$UW" switch -q -c work
printf 'unrelated\n' > "$UW/notes.txt"
git -C "$UW" add notes.txt
git -C "$UW" commit -q -m notes
U_HEAD="$(git -C "$UW" rev-parse HEAD)"
U_BLOB="$(git -C "$UW" rev-parse HEAD:App.xcodeproj/project.pbxproj)"
rm -- "$UW/.git/objects/${U_BLOB:0:2}/${U_BLOB:2}"
table "a present unreadable project requires Mac proof|--worktree $UW --kind implement --issue issue-apple --round-id 30-30 --branch b --commit $U_HEAD --no-labels --validate pass --validate-run-dir $VRUN|rc=2 written=no stderr~dev-return-write:+mac-run-missing+project=App.xcodeproj/project.pbxproj=true"
# A no-verdict note names its scoped suites and the pass line, one per line.
run --worktree "$AW" --kind implement --issue issue-apple-note --round-id 30-30 --branch b --commit "$A_IOS" --no-labels \
  --validate no-verdict --validate-run-dir "$VRUN_CUT" --validate-note $'scoped suites green: x.sh\nmac run test: pass run=4242'
assert_eq "$(observe "rc=0 roundtrip=valid")" "rc=0 roundtrip=valid" "a pass line below the scoped suites is found" "$ERR"
# A git failure inside the gate refuses on its own key. A fix receipt's
# commit is never measured, so an unresolvable one reaches the gate here, with
# the workflow on FW's main for the length of the row.
mkdir -p "$FW/.github/workflows"
printf 'name: mac-run\n' > "$FW/.github/workflows/mac-run.yml"
git -C "$FW" add .github
git -C "$FW" commit -q -m workflow
table "a commit git cannot diff|--worktree %FW --kind fix --issue issue-776 --round-id 9-9 --branch b --commit c --validate pass --validate-run-dir $VRUN_FIX_9 --no-labels --item 3 Blocked x|rc=2 written=no stderr~dev-return-write:+apple-git-failed+path=$FW+commit=c=true"
git -C "$FW" reset -q --hard "$FIX_HEAD"

# Non-Apple items: the receipt is byte-equal to the one a writer without the
# gate writes, for an item with no trigger in AW, and in NW, whose main holds
# no workflow, for a triggered item, for one declaring no labels, and for a
# branch that adds the workflow beside an ios/ path.
GATELESS="$(mutant_scripts gateless-mutant dev-return-write)/dev-return-write" || exit 1
mutate_file "$GATELESS" $'apple_armed=""\nif [[ "$validate" != FAILING:* ]]; then' $'apple_armed=""\nif false; then'
NW="$(new_repo apple-unarmed)"
git -C "$NW" switch -q -c work
mkdir -p "$NW/ios" "$NW/.github/workflows"
printf 'app\n' > "$NW/ios/App.swift"
git -C "$NW" add ios
git -C "$NW" commit -q -m ios
NW_HEAD="$(git -C "$NW" rev-parse HEAD)"
printf 'name: mac-run\n' > "$NW/.github/workflows/mac-run.yml"
git -C "$NW" add .github
git -C "$NW" commit -q -m workflow
NW_WORKFLOW_HEAD="$(git -C "$NW" rev-parse HEAD)"
NWP="--worktree $NW --kind implement --issue issue-apple --round-id 30-30 --branch b --validate pass --validate-run-dir $VRUN"
byte_equal_rows() {
  local row label args shipped
  for row in \
    "an item with no trigger beside the workflow|$AP --commit $A_PLAIN --label skills" \
    "a triggered item without the workflow|$NWP --commit $NW_HEAD --label macos" \
    "an omitted label declaration without the workflow|$NWP --commit $NW_HEAD" \
    "a branch adding the workflow beside an ios/ path|$NWP --commit $NW_WORKFLOW_HEAD --no-labels"; do
    IFS='|' read -r label args <<<"$row"
    args="${args/--issue issue-apple /--issue issue-apple-$((RUN_SEQ + 1)) }"
    # shellcheck disable=SC2086
    run $args
    shipped="$(cat -- "$OUT" 2>/dev/null)" || shipped="rc=$RC"
    WRITE="$GATELESS"
    # shellcheck disable=SC2086
    run $args
    WRITE="$WRITE_SHIPPED"
    assert_eq "$shipped" "$(cat -- "$OUT")" "$label: the receipt is byte-equal to a gateless writer's" "$ERR"
  done
}
WRITE_SHIPPED="$WRITE"
byte_equal_rows

# One control per rule: each mutant disables one rule of the gate. In OLD and
# NEW, \| is a literal bar and \n a newline.
APPLE_CONTROLS=(
  "workflow binding|APPLE_WORKFLOW=\"\$(cd -- \"\$worktree\" && \"\$SCRIPT_DIR/orch-env\" ORCH_APPLE_WORKFLOW \"\$APPLE_WORKFLOW\")\"|APPLE_WORKFLOW=\"\$APPLE_WORKFLOW\"|$CP --commit $C_SOURCE --no-labels|rc=0 written=yes .validate_note=null"
  "label binding|IFS=' ' read -r -a APPLE_LABELS <<<\"\$apple_labels\"|:|$CP --commit $C_PLAIN --label apple-desktop|rc=0 written=yes .validate_note=null"
  "labels|if [[ \"\$label\" == \"\$apple\" ]]; then|if false; then|$AP --commit $A_PLAIN --label ios|rc=0"
  "labels on a fix receipt|if [[ \"\$label\" == \"\$apple\" ]]; then|if false; then|$AFIX --label ios|rc=0"
  "label declaration|if [[ \"\$no_labels\" == false ]] && (( \${#labels[@]} == 0 )); then|if false; then|$AP --commit $A_PLAIN|rc=0"
  "label conflict|if [[ \"\$no_labels\" == true ]] && (( \${#labels[@]} > 0 )); then|if false; then|$AP --commit $A_PLAIN --label skills --no-labels|rc=0"
  "directory globs|if [[ \"\$segment\" == \$glob ]]; then|if false; then|$APN --commit $A_IOS|rc=0"
  "Xcode source names|if [[ -n \"\$member\" && \"\$segment\" == \"\$member\" ]]; then|if [[ -n \"\$member\" && \"\$segment\" == \"\$member\" ]] && false; then|$APN --commit $A_SOURCE|rc=0"
  "Xcode test names|if [[ -n \"\$member\" && \"\$segment\" == \"\$member\" ]]; then|if [[ -n \"\$member\" && \"\$segment\" == \"\$member\" ]] && false; then|$APN --commit $A_TEST|rc=0"
  "Linux source exclusion|if [[ -n \"\$member\" && \"\$segment\" == \"\$member\" ]]; then|if [[ -n \"\$member\" && \"\$segment\" == \"\$member\" ]] \|\| [[ \"\$path\" == *.swift ]]; then|$APN --commit $A_LINUX_SOURCE|rc=2 written=no stderr~dev-return-write:+mac-run-missing+path=linux-package/Sources/LinuxUtility/LinuxEntry.swift=true"
  "unsupported input escapes|if escaped not in (chr(34), chr(92)):|if escaped not in (chr(34), chr(92)) and False:|$ESCAPE_CONTROL_ARGS|rc=0 written=yes .validate_note=null"
  "renamed paths|--name-only --no-renames -z|--name-only -z|$APN --commit $A_MOVED|rc=0"
  "manifest platforms|if LC_ALL=C grep -Eq -- \"\$APPLE_MANIFEST_PLATFORMS\" <<<\"\$manifest\"; then|if false; then|$APN --commit $A_PKG_IOS|rc=0"
  "deleted manifest|[[ -n \"\$listed\" ]] \|\| continue|[[ -n \"\$listed\" ]] \|\| true|$APN --commit $A_PKG_DELETED|rc=2"
  "pass record|then mac_run_recorded=true; fi|then mac_run_recorded=false; fi|$APN --commit $A_IOS --validate-note $MAC_NOTE|rc=2"
  "record start anchor|MAC_RUN_PASS='^mac|MAC_RUN_PASS='mac|$APN --commit $A_IOS --validate-note scoped+suites+green:+x.sh;+$MAC_NOTE|rc=0"
  "record end anchor|[^[:space:]]+\$'|[^[:space:]]+'|$APN --commit $A_IOS --validate-note $MAC_NOTE+then+more|rc=0"
  "FAILING exemption|apple_armed=\"\"\nif [[ \"\$validate\" != FAILING:* ]]; then|apple_armed=\"\"\nif true; then|$AW_ARGS --commit $A_IOS --no-labels --validate FAILING:+mac+run+test|rc=2"
  "workflow precondition|if [[ -n \"\$apple_armed\" ]]; then|if [[ -n \"\$APPLE_WORKFLOW\" ]]; then|$NWP --commit $NW_HEAD --label macos|rc=2"
  "workflow on the base branch|--name-only \"\$apple_base_ref\" -- \"\$APPLE_WORKFLOW\"|--name-only \"\$commit\" -- \"\$APPLE_WORKFLOW\"|$NWP --commit $NW_WORKFLOW_HEAD --no-labels|rc=2"
)
for control in "${APPLE_CONTROLS[@]}"; do
  IFS='|' read -r name old new args expect <<<"${control//\\|/$'\x1f'}"
  old="${old//$'\x1f'/|}"; new="${new//$'\x1f'/|}"
  old="${old//\\n/$'\n'}"; new="${new//\\n/$'\n'}"
  CONTROL_WRITE="$(mutant_scripts "apple-${name// /-}-mutant" dev-return-write)/dev-return-write" || exit 1
  mutate_file "$CONTROL_WRITE" "$old" "$new"
  WRITE="$CONTROL_WRITE"
  table --independent "control: without the $name rule the row's outcome flips|$args|$expect"
  WRITE="$WRITE_SHIPPED"
done

echo "=== --near-ceiling-base runs the installed lane and records what it could answer ==="
# probe_wt NAME SIZE... — a worktree on branch `work` over `main` that adds one
# binary per SIZE in bytes, with the real byte-ceiling lane installed where a
# consumer repository renders it. Under a 1 KB ceiling a 950-byte file is 92
# percent of it and a 2000-byte file is over it, which makes the lane exit 1.
probe_wt() {
  local dir size
  dir="$(new_repo "$1")"
  shift
  git -C "$dir" switch -q -c work
  for size in "$@"; do
    head -c "$size" /dev/zero > "$dir/f$size.bin"
  done
  git -C "$dir" add .
  git -C "$dir" commit -q -m work
  mkdir -p "$dir/.agents/skills/commit-guards"
  ln -s "$REPO_ROOT/skills/commit-guards/scripts" "$dir/.agents/skills/commit-guards/scripts"
  printf '%s' "$dir"
}
NEAR_WT="$(probe_wt probe-near 950)"
OVER_WT="$(probe_wt probe-over 950 2000)"
NEAR_LINE="byte-ceiling: near-ceiling=f950.bin:950:1024:92"
# A lane present but not runnable, and a dangling link at or above it, are
# broken installs: each records null, never the empty list an absent lane gets.
NOEXEC_WT="$(new_repo probe-noexec)"
mkdir -p "$NOEXEC_WT/.agents/skills/commit-guards/scripts"
printf '#!/bin/sh\n' > "$NOEXEC_WT/.agents/skills/commit-guards/scripts/byte-ceiling"
DANGLE_WT="$(new_repo probe-dangle)"
mkdir -p "$DANGLE_WT/.agents/skills/commit-guards/scripts"
ln -s "$TMP_ROOT/nowhere" "$DANGLE_WT/.agents/skills/commit-guards/scripts/byte-ceiling"
PARENT_WT="$(new_repo probe-parent)"
mkdir -p "$PARENT_WT/.agents/skills"
ln -s "$TMP_ROOT/nowhere" "$PARENT_WT/.agents/skills/commit-guards"
export COMMIT_GUARDS_BYTE_CEILING_KB=1 COMMIT_GUARDS_BYTE_WARN_PCT=90
PROBE_ARGS="--kind fix --round-id 17-17 --branch work --commit c --validate FAILING:probe --item 1 Applied probed"
for row in \
  "exit 0 records the near-ceiling line|$NEAR_WT|main|[\"$NEAR_LINE\"]|null" \
  "exit 1 records the near-ceiling line and not the oversized one|$OVER_WT|main|[\"$NEAR_LINE\"]|null" \
  "exit 2 on a ref that names no commit records null and the lane's key|$NEAR_WT|nope|null|\"byte-ceiling exit 2: byte-ceiling: base-ref=nope\"" \
  "an absent lane is a repository with no byte ceiling: an empty list and no error|$WT|main|[]|null" \
  "a lane without the execute bit records null and the path|$NOEXEC_WT|main|null|\"byte-ceiling not executable: $NOEXEC_WT/.agents/skills/commit-guards/scripts/byte-ceiling\"" \
  "a dangling link at the lane records null and the path|$DANGLE_WT|main|null|\"byte-ceiling not executable: $DANGLE_WT/.agents/skills/commit-guards/scripts/byte-ceiling\"" \
  "a dangling link above the lane records null and the link|$PARENT_WT|main|null|\"byte-ceiling broken link: $PARENT_WT/.agents/skills/commit-guards\""; do
  IFS='|' read -r label wt ref near error <<<"$row"
  # shellcheck disable=SC2086
  run --worktree "$wt" --issue "issue-probe-$((RUN_SEQ + 1))" $PROBE_ARGS --near-ceiling-base "$ref"
  assert_eq "rc=$RC $(rec -c '[.near_ceiling, .near_ceiling_error]')" "rc=0 [$near,$error]" "$label" "$ERR"
done
unset COMMIT_GUARDS_BYTE_CEILING_KB COMMIT_GUARDS_BYTE_WARN_PCT

echo "=== a fix receipt names only a run its own round started ==="
# The implement round's full run starts before the implement commit, and the
# fix round is delegated at that commit, where its range run starts. The
# implement run is still on disk and in the dev agent's context; a receipt
# naming it would record a full pass for a commit only the range run judged.
# A fix round that commits nothing leaves the next round delegated at the same
# base, a minute later here, and its own run is refused for that next round.
BW="$(new_repo bind-wt)"
IMPL_BASE="$(git -C "$BW" rev-parse HEAD)"
VRUN_IMPL="$(validate_run_dir "$TMP_ROOT/validate-run-implement" full 0 "$IMPL_BASE")"
printf 'feature\n' > "$BW/feature.txt"
git -C "$BW" add feature.txt
git -C "$BW" commit -q -m implementation
ROUND_BASE="$(git -C "$BW" rev-parse HEAD)"
init_growth_state "$STATE" "$BW" issue-776 21-21
mkdir -p "$BW/.cache/tracker-fixture"
cp "$FW/.cache/tracker-fixture/issues.json" "$BW/.cache/tracker-fixture/issues.json"
env ORCH_STATE_DIR="$BW/tmp" "$ROUND_WRITE" --worktree "$BW" --issue issue-776 --round-id 21-21 \
  --item 1 "fix finding" "tools/guard on a staged render" >/dev/null
VRUN_BOUND="$(round_run_dir "$TMP_ROOT/validate-run-bound" "$BW" issue-776 21-21 range)"
ROUND_DELEGATED="$(jq -r '.delegated_at' "$BW/tmp/dev-round-issue-776-21-21.json")"
env ORCH_STATE_DIR="$BW/tmp" "$ROUND_WRITE" --worktree "$BW" --issue issue-776 --round-id 23-23 \
  --item 1 "fix finding" "tools/guard on a staged render" >/dev/null
NEXT_RECORD="$BW/tmp/dev-round-issue-776-23-23.json"
jq --argjson at "$(( ROUND_DELEGATED + 60 ))" '.delegated_at = $at' "$NEXT_RECORD" > "$NEXT_RECORD.next"
mv "$NEXT_RECORD.next" "$NEXT_RECORD"
VRUN_NOHEAD="$(validate_run_dir "$TMP_ROOT/validate-run-nohead" range)"
VRUN_BADHEAD="$(validate_run_dir "$TMP_ROOT/validate-run-badhead" range 0 0000000000000000000000000000000000000000 "$ROUND_DELEGATED")"
NEXT_ARGS="--kind fix --issue issue-776 --round-id 23-23 --branch b --commit $ROUND_BASE --validate pass --item 1 Applied fixed"
# A rebase mid-round replays the round's work onto a new parent, so the HEAD a
# later run starts at no longer contains the round's base, and dev-validate-run
# records that base as orphaned. REBASED is that HEAD: the base's tree on a
# commit that does not descend from it.
REBASED="$(git -C "$BW" commit-tree -p "$IMPL_BASE" -m rebased "$ROUND_BASE^{tree}")"
orphaned_run_dir() { # DIR ORPHANED START — a range run at REBASED recording ORPHANED
  validate_run_dir "$1" range 0 "$REBASED" "$3" >/dev/null
  printf 'validate-base-orphaned=%s\n' "$2" >> "$1/start"
  printf '%s\n' "$1"
}
VRUN_ORPHANED="$(orphaned_run_dir "$TMP_ROOT/validate-run-orphaned" "$ROUND_BASE" "$ROUND_DELEGATED")"
VRUN_ORPHANED_OTHER="$(orphaned_run_dir "$TMP_ROOT/validate-run-orphaned-other" "$IMPL_BASE" "$ROUND_DELEGATED")"
VRUN_ORPHANED_EARLY="$(orphaned_run_dir "$TMP_ROOT/validate-run-orphaned-early" "$ROUND_BASE" "$(( ROUND_DELEGATED - 1 ))")"
# The bound record under fresh round ids, its base intact and its delegation
# time absent or not a number: dev-round-write wrote no delegated_at before
# the time binding, so a round delegated across the change holds one.
jq '.round_id = "24-24" | del(.delegated_at)' "$BW/tmp/dev-round-issue-776-21-21.json" > "$BW/tmp/dev-round-issue-776-24-24.json"
jq '.round_id = "25-25" | .delegated_at |= tostring' "$BW/tmp/dev-round-issue-776-21-21.json" > "$BW/tmp/dev-round-issue-776-25-25.json"
UNTIMED_ARGS="--kind fix --issue issue-776 --round-id 24-24 --branch b --commit $ROUND_BASE --validate pass --item 1 Applied fixed --validate-run-dir $VRUN_BOUND"
STRING_TIME_ARGS="--kind fix --issue issue-776 --round-id 25-25 --branch b --commit $ROUND_BASE --validate pass --item 1 Applied fixed --validate-run-dir $VRUN_BOUND"
BIND_ARGS="--kind fix --issue issue-776 --round-id 21-21 --branch b --commit $ROUND_BASE --validate pass --item 1 Applied fixed"
BIND_ROWS=(
  "the implement round's full run is refused, naming the run, its HEAD and the round's base|--worktree $BW $BIND_ARGS --validate-run-dir $VRUN_IMPL|rc=2 written=no stderr~dev-return-write:+run-off-round+run-dir=$VRUN_IMPL+head=$IMPL_BASE+base-sha=$ROUND_BASE=true"
  "the round's own range run is accepted and recorded as range|--worktree $BW $BIND_ARGS --validate-run-dir $VRUN_BOUND|rc=0 .validate_mode=range"
  "the round's own run after a rebase left its base off the branch is accepted, the base recorded as orphaned|--worktree $BW $BIND_ARGS --validate-run-dir $VRUN_ORPHANED|rc=0 .validate_mode=range"
  "a rebased run whose orphaned base is another round's is refused, naming its HEAD and the round's base|--worktree $BW $BIND_ARGS --validate-run-dir $VRUN_ORPHANED_OTHER|rc=2 written=no stderr~dev-return-write:+run-off-round+run-dir=$VRUN_ORPHANED_OTHER+head=$REBASED+base-sha=$ROUND_BASE=true"
  "a rebased run recording the round's base but started before the round is refused on the time|--worktree $BW $BIND_ARGS --validate-run-dir $VRUN_ORPHANED_EARLY|rc=2 written=no stderr~dev-return-write:+run-before-round+run-dir=$VRUN_ORPHANED_EARLY+start=$(( ROUND_DELEGATED - 1 ))+delegated-at=$ROUND_DELEGATED=true"
  "the previous round's run at the same base is refused for the next round, naming both times|--worktree $BW $NEXT_ARGS --validate-run-dir $VRUN_BOUND|rc=2 written=no stderr~dev-return-write:+run-before-round+run-dir=$VRUN_BOUND+start=$ROUND_DELEGATED+delegated-at=$(( ROUND_DELEGATED + 60 ))=true"
  "a run that records no HEAD is refused on its own key|--worktree $BW $BIND_ARGS --validate-run-dir $VRUN_NOHEAD|rc=2 written=no stderr~dev-return-write:+run-headless+run-dir=$VRUN_NOHEAD=true"
  "a HEAD git cannot resolve is refused on its own key|--worktree $BW $BIND_ARGS --validate-run-dir $VRUN_BADHEAD|rc=2 written=no stderr~dev-return-write:+ancestry-unreadable+run-dir=$VRUN_BADHEAD=true"
  "a fix round with no round record is refused|--worktree $BW --kind fix --issue issue-776 --round-id 22-22 --branch b --commit $ROUND_BASE --validate pass --item 1 Applied fixed --validate-run-dir $VRUN_BOUND|rc=2 written=no stderr~dev-return-write:+round-record-unreadable+path=$BW/tmp/dev-round-issue-776-22-22.json=true"
  "a round record with a base and no delegation time is refused|--worktree $BW $UNTIMED_ARGS|rc=2 written=no stderr~dev-return-write:+round-record-unreadable+path=$BW/tmp/dev-round-issue-776-24-24.json=true"
  "a round record whose delegation time is a string is refused|--worktree $BW $STRING_TIME_ARGS|rc=2 written=no stderr~dev-return-write:+round-record-unreadable+path=$BW/tmp/dev-round-issue-776-25-25.json=true"
)
table "${BIND_ROWS[@]}"
rm -f "$BW/tmp/dev-return-issue-776-21-21.json"
# The suite's one must-fail control: a writer that never binds the run
# records the implement round's full pass for the fix commit.
BIND_WRITE="$(mutant_scripts bind-mutant dev-return-write)/dev-return-write" || exit 1
mutate_file "$BIND_WRITE" 'if [[ "$kind" == "fix" && -n "$run_ref" ]]; then' 'if false; then'
WRITE_SHIPPED="$WRITE"
WRITE="$BIND_WRITE"
table \
  "control: without the binding the implement round's full run is recorded for the fix|--worktree $BW $BIND_ARGS --validate-run-dir $VRUN_IMPL|rc=0 .validate_mode=full"
WRITE="$WRITE_SHIPPED"

echo "=== guarded restack binds the delegated base to the run history ==="
# KEN-2156: merge-pr-restack validates from origin/main, which is still an
# ancestor. dev-validate-run therefore records no orphan for the round base.
# worktree's append_rebase_hop owns these map rows; worktree-push consumes
# the same ordered hops. Completion reads them without consuming the file.
git -C "$BW" update-ref refs/remotes/origin/main "$IMPL_BASE"
REBASED_NEXT="$(git -C "$BW" commit-tree -p "$IMPL_BASE" -m restacked-again "$ROUND_BASE^{tree}")" || exit 1
REBASED_CHILD="$(git -C "$BW" commit-tree -p "$REBASED" -m later-work "$ROUND_BASE^{tree}")" || exit 1
RESTACK_RUN="$(validate_run_dir "$TMP_ROOT/validate-run-restack" range 0 "$REBASED" "$ROUND_DELEGATED")" || exit 1
RESTACK_NEXT_RUN="$(validate_run_dir "$TMP_ROOT/validate-run-restack-next" range 0 "$REBASED_NEXT" "$ROUND_DELEGATED")" || exit 1
RESTACK_CHILD_RUN="$(validate_run_dir "$TMP_ROOT/validate-run-restack-child" range 0 "$REBASED_CHILD" "$ROUND_DELEGATED")" || exit 1
RESTACK_EARLY_RUN="$(validate_run_dir "$TMP_ROOT/validate-run-restack-early" range 0 "$REBASED" "$(( ROUND_DELEGATED - 1 ))")" || exit 1
for dir in "$RESTACK_RUN" "$RESTACK_NEXT_RUN" "$RESTACK_CHILD_RUN" "$RESTACK_EARLY_RUN"; do
  printf 'validate-base=%s\n' "$IMPL_BASE" >> "$dir/start"
done
RESTACK_MAP="$(git -C "$BW" rev-parse --git-path kendex-rebase-map)" || exit 1
[[ "$RESTACK_MAP" == /* ]] || RESTACK_MAP="$BW/$RESTACK_MAP"
RESTACK_ARGS="--kind fix --issue issue-776 --round-id 21-21 --branch b --commit $REBASED --validate pass --item 1 Applied restacked"
for row in \
  "KEN-2156 range from origin/main binds through the recorded restack|matching|$RESTACK_RUN|rc=0 .validate_mode=range" \
  "no map cannot bind the rewritten head|missing|$RESTACK_RUN|rc=2 written=no stderr~dev-return-write:+run-off-round=true" \
  "a map for another base cannot bind this round|other-base|$RESTACK_RUN|rc=2 written=no stderr~dev-return-write:+run-off-round=true" \
  "a map to another head cannot bind this run|other-head|$RESTACK_RUN|rc=2 written=no stderr~dev-return-write:+run-off-round=true" \
  "a descendant of the mapped base binds the round|matching|$RESTACK_CHILD_RUN|rc=0 .validate_mode=range" \
  "a dropped round base cannot bind a run|dropped|$RESTACK_RUN|rc=2 written=no stderr~dev-return-write:+run-off-round=true" \
  "a pending rewrite is not a completed guarded restack|pending|$RESTACK_RUN|rc=2 written=no stderr~dev-return-write:+run-off-round=true" \
  "ordered hops move the delegated base to the final head|two-hops|$RESTACK_NEXT_RUN|rc=0 .validate_mode=range" \
  "rows inside one hop compare against the starting base|one-hop|$RESTACK_RUN|rc=0 .validate_mode=range" \
  "an incomplete hop cannot bind a run|empty-hop|$RESTACK_RUN|rc=2 written=no stderr~dev-return-write:+run-off-round=true" \
  "a matching map does not admit a run before delegation|matching|$RESTACK_EARLY_RUN|rc=2 written=no stderr~dev-return-write:+run-before-round=true"; do
  IFS='|' read -r label shape dir expect <<<"$row"
  rm -f -- "$BW/tmp/dev-return-issue-776-21-21.json" "$RESTACK_MAP"
  case "$shape" in
    missing) ;;
    other-base) printf 'rebase-hop:\nrebase-map: %s %s\n' "$IMPL_BASE" "$REBASED" > "$RESTACK_MAP" ;;
    other-head) printf 'rebase-hop:\nrebase-map: %s %s\n' "$ROUND_BASE" "$REBASED_NEXT" > "$RESTACK_MAP" ;;
    dropped) printf 'rebase-hop:\nrebase-map: %s dropped\n' "$ROUND_BASE" > "$RESTACK_MAP" ;;
    *)
      printf 'rebase-hop:\nrebase-map: %s %s\n' "$ROUND_BASE" "$REBASED" > "$RESTACK_MAP"
      case "$shape" in
        matching) ;;
        pending) printf 'rebase-unmapped: %s\n' "$REBASED" >> "$RESTACK_MAP" ;;
        two-hops) printf 'rebase-hop:\nrebase-map: %s %s\n' "$REBASED" "$REBASED_NEXT" >> "$RESTACK_MAP" ;;
        one-hop) printf 'rebase-map: %s %s\n' "$REBASED" "$REBASED_NEXT" >> "$RESTACK_MAP" ;;
        empty-hop) printf 'rebase-hop:\n' >> "$RESTACK_MAP" ;;
        *) printf 'unknown restack shape: %s\n' "$shape" >&2; exit 1 ;;
      esac
      ;;
  esac
  map_before="$(cat -- "$RESTACK_MAP" 2>/dev/null)" || map_before=missing
  # shellcheck disable=SC2086
  run --worktree "$BW" $RESTACK_ARGS --validate-run-dir "$dir"
  assert_eq "$(observe "$expect")" "$expect" "$label" "$ERR"
  map_after="$(cat -- "$RESTACK_MAP" 2>/dev/null)" || map_after=missing
  assert_eq "$map_after" "$map_before" "$label leaves the map unchanged"
done
# Each mutant changes only the map binding rule. The first restores the
# pre-fix refusal. The second treats any mapped target as a matching HEAD.
for control in refuse mismatch; do
  CONTROL_WRITE="$(mutant_scripts "restack-$control-mutant" dev-return-write)/dev-return-write" || exit 1
  case "$control" in
    refuse)
      mutate_file "$CONTROL_WRITE" '        [[ "$mapped_base" =~ ^[0-9a-f]+$ ]] \' '        [[ "$mapped_base" =~ ^[0-9a-f]+$ ]] && false \'
      printf 'rebase-hop:\nrebase-map: %s %s\n' "$ROUND_BASE" "$REBASED" > "$RESTACK_MAP"
      expect="rc=2 written=no stderr~dev-return-write:+run-off-round=true"
      ;;
    mismatch)
      mutate_file "$CONTROL_WRITE" 'git -C "$worktree" merge-base --is-ancestor "$mapped_base" "$run_head" 2>/dev/null || ancestry=$?' 'true'
      printf 'rebase-hop:\nrebase-map: %s %s\n' "$ROUND_BASE" "$REBASED_NEXT" > "$RESTACK_MAP"
      expect="rc=0 .validate_mode=range"
      ;;
  esac
  rm -f -- "$BW/tmp/dev-return-issue-776-21-21.json"
  WRITE="$CONTROL_WRITE"
  table "control: restack $control changes the binding result|--worktree $BW $RESTACK_ARGS --validate-run-dir $RESTACK_RUN|$expect"
  WRITE="$WRITE_SHIPPED"
done
# This control changes the shared owner's row comparison, not either caller.
# A one-hop map must not chain its first result through another row.
SHARED_SCRIPTS="$(mutant_scripts shared-hop-mutant lib/rebase-map.sh)" || exit 1
mutate_file "$SHARED_SCRIPTS/lib/rebase-map.sh" \
  'if ($e.key | startswith($sha))' 'if (. as $current | $e.key | startswith($current))'
printf 'rebase-hop:\nrebase-map: %s %s\nrebase-map: %s %s\n' \
  "$ROUND_BASE" "$REBASED" "$REBASED" "$REBASED_NEXT" > "$RESTACK_MAP"
# jq visits keys in insertion order; the first mapping is the round base.
rm -f -- "$BW/tmp/dev-return-issue-776-21-21.json"
WRITE="$SHARED_SCRIPTS/dev-return-write"
# shellcheck disable=SC2086
table "control: chaining rows in the shared owner rejects the one-hop run|--worktree $BW $RESTACK_ARGS --validate-run-dir $RESTACK_RUN|rc=2 written=no stderr~dev-return-write:+run-off-round=true"
WRITE="$WRITE_SHIPPED"
rm -f -- "$RESTACK_MAP"

echo "=== a foreground validation record stands in for a run directory ==="
# A project whose policy forbids dev-validate-run names its own foreground run
# by a record file. foreground_record NAME [KEY=VALUE | -KEY | +LINE]... writes
# a passing full record at the implement head, 00:00 to 00:55, of a lint,test
# subset: KEY=VALUE replaces that key, -KEY drops it and +LINE appends LINE.
foreground_record() {
  local file="$TMP_ROOT/records/$1" line arg kept lines=()
  shift
  mkdir -p "$TMP_ROOT/records"
  for line in validate-mode=full "head=$IMPL_HEAD" started-at=2026-01-01T00:00:00Z \
    ended-at=2026-01-01T00:55:00Z exit=0 selection=subset lanes=lint,test; do
    kept="$line"
    for arg in "$@"; do
      case "$arg" in
        "-${line%%=*}") kept="" ;;
        "${line%%=*}="*) kept="$arg" ;;
      esac
    done
    [[ -z "$kept" ]] || lines+=("$kept")
  done
  for arg in "$@"; do
    case "$arg" in +*) lines+=("${arg#+}") ;; esac
  done
  printf '%s\n' ${lines[@]+"${lines[@]}"} > "$file"
  printf '%s\n' "$file"
}
utc_at() { jq -nr --argjson t "$1" '$t | todate'; }
FG_OK="$(foreground_record ok)"
FG_FAILED="$(foreground_record failed exit=1)"
FG_HOST="$(foreground_record host exit=3 +verdict=no-verdict)"
FG_MEASUREMENT="$(foreground_record measurement exit=77 +verdict=no-verdict)"
FG_HOST_UNMARKED="$(foreground_record host-unmarked exit=3)"
FG_MEASUREMENT_UNMARKED="$(foreground_record measurement-unmarked exit=77)"
FG_MEASUREMENT_BEFORE="$(cat -- "$FG_MEASUREMENT")"
FG_UNREPORTED="$(foreground_record unreported selection=unreported -lanes)"
FG_BATTERY="$(foreground_record battery selection=battery)"
FG_UNREPORTED_LANES="$(foreground_record unreported-lanes selection=unreported)"
FG_SUBSET_NOLANES="$(foreground_record subset-nolanes -lanes)"
FG_BACKWARDS="$(foreground_record backwards ended-at=2025-12-31T23:59:59Z)"
FG_DUPLICATE="$(foreground_record duplicate "+exit=1")"
FG_UNKNOWN="$(foreground_record unknown "+unknown=pass")"
FG_VERDICT="$(foreground_record bad-verdict "+verdict=pass")"
FG_BARE="$(foreground_record bare -lanes +lanes)"
FG_HEAD="$(foreground_record bad-head head=HEAD)"
FG_MODE="$(foreground_record bad-mode validate-mode=ci)"
FG_TIME="$(foreground_record bad-time started-at=2026-01-01)"
FG_HOUR="$(foreground_record bad-hour started-at=2026-01-01T25:00:00Z)"
FG_EXIT="$(foreground_record bad-exit exit=x)"
FG_LANES="$(foreground_record bad-lanes lanes=lint,)"
FG_ARGS="--worktree $WT --kind implement --issue issue-fg --round-id 40-40 --branch b --commit $IMPL_HEAD"
FG_FAIL="--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c"
FOREGROUND_ROWS=(
  "a passing record writes the run's mode, wall time and lanes and round-trips|$FG_ARGS --validate pass --validate-record $FG_OK|rc=0 .validate=pass .validate_mode=full .validate_time.started_at=2026-01-01T00:00:00Z .validate_time.seconds=3300 .validate_selection=subset .validate_lanes=lint,test roundtrip=valid"
  "an unreported selection writes no lanes|$FG_ARGS --validate pass --validate-record $FG_UNREPORTED|rc=0 .validate_selection=unreported has:validate_lanes=false roundtrip=valid"
  "a battery selection writes it with its lanes|$FG_ARGS --validate pass --validate-record $FG_BATTERY|rc=0 .validate_selection=battery .validate_lanes=lint,test roundtrip=valid"
  "a FAILING result beside a failed record|$FG_ARGS --validate FAILING:+scripts/validate --validate-record $FG_FAILED|rc=0 .validate=FAILING:+scripts/validate .validate_mode=full roundtrip=valid"
  "an explicit host no-verdict keeps its mode, timing and note and round-trips|$FG_ARGS --validate no-verdict --validate-record $FG_HOST --validate-note host+unavailable;+scoped+suites+green:+dev_return_write.sh|rc=0 .validate=no-verdict .validate_mode=full .validate_time.seconds=3300 .validate_note=host+unavailable;+scoped+suites+green:+dev_return_write.sh roundtrip=valid"
  "the explicit marker carries an unavailable measurement without relabeling it pass|$FG_ARGS --validate no-verdict --validate-record $FG_MEASUREMENT --validate-note measurement+unavailable;+scoped+suites+green:+dev_return_write.sh|rc=0 .validate=no-verdict .validate_selection=subset .validate_lanes=lint,test roundtrip=valid"
  "an unmarked unavailable-host exit remains FAILING|$FG_FAIL --validate no-verdict --validate-record $FG_HOST_UNMARKED --validate-note scoped|rc=2 written=no stderr~dev-return-write:+validate-disagrees+validate=no-verdict+run=FAILING=true"
  "an unmarked measurement exit remains FAILING|$FG_ARGS --validate FAILING:+scripts/validate --validate-record $FG_MEASUREMENT_UNMARKED|rc=0 .validate=FAILING:+scripts/validate roundtrip=valid"
  "a pass against a marked no-verdict is refused|$FG_FAIL --validate pass --validate-record $FG_HOST|rc=2 written=no stderr~dev-return-write:+validate-disagrees+validate=pass+run=no-verdict=true"
  "a marked no-verdict without scoped-suite evidence is refused|$FG_FAIL --validate no-verdict --validate-record $FG_HOST|rc=2 written=no stderr~dev-return-write:+required+option=--validate-note+validate=no-verdict=true"
  "a marked no-verdict with an empty evidence note is refused|$FG_FAIL --validate no-verdict --validate-record $FG_HOST --validate-note SPACES|rc=2 written=no stderr~dev-return-write:+empty-text+option=--validate-note=true"
  "a pass beside a nonzero exit|$FG_FAIL --validate pass --validate-record $FG_FAILED|rc=2 written=no stderr~dev-return-write:+validate-disagrees+validate=pass+run=FAILING=true"
  "no-verdict beside a record, which states no timeout|$FG_FAIL --validate no-verdict --validate-note scoped --validate-record $FG_OK|rc=2 written=no stderr~dev-return-write:+validate-disagrees+validate=no-verdict+run=pass=true"
  "a record beside a run directory|$FG_FAIL --validate pass --validate-run-dir $VRUN --validate-record $FG_OK|rc=2 written=no stderr~dev-return-write:+validate-source-conflict+options=--validate-run-dir,--validate-record=true"
  "a record path that names no file|$FG_FAIL --validate pass --validate-record $TMP_ROOT/records/none|rc=2 written=no stderr~dev-return-write:+validate-record-unreadable+path=$TMP_ROOT/records/none=true"
  "a key given twice|$FG_FAIL --validate pass --validate-record $FG_DUPLICATE|rc=2 written=no stderr~dev-return-write:+validate-record-line+path=$FG_DUPLICATE+line=8=true"
  "a key the grammar lacks|$FG_FAIL --validate pass --validate-record $FG_UNKNOWN|rc=2 written=no stderr~dev-return-write:+validate-record-line+path=$FG_UNKNOWN+line=8=true"
  "a verdict value the grammar lacks|$FG_FAIL --validate pass --validate-record $FG_VERDICT|rc=2 written=no stderr~dev-return-write:+validate-record-value+path=$FG_VERDICT+field=verdict+value=pass=true"
  "a line with no value|$FG_FAIL --validate pass --validate-record $FG_BARE|rc=2 written=no stderr~dev-return-write:+validate-record-line+path=$FG_BARE+line=7=true"
  "a head that is not 40 hex|$FG_FAIL --validate pass --validate-record $FG_HEAD|rc=2 written=no stderr~dev-return-write:+validate-record-value+path=$FG_HEAD+field=head+value=HEAD=true"
  "a mode no foreground run has|$FG_FAIL --validate pass --validate-record $FG_MODE|rc=2 written=no stderr~dev-return-write:+validate-record-value+path=$FG_MODE+field=validate-mode+value=ci=true"
  "a time with no clock|$FG_FAIL --validate pass --validate-record $FG_TIME|rc=2 written=no stderr~dev-return-write:+validate-record-value+path=$FG_TIME+field=started-at+value=2026-01-01=true"
  "an hour out of range|$FG_FAIL --validate pass --validate-record $FG_HOUR|rc=2 written=no stderr~dev-return-write:+validate-record-value+path=$FG_HOUR+field=started-at,ended-at=true"
  "an exit that is no status|$FG_FAIL --validate pass --validate-record $FG_EXIT|rc=2 written=no stderr~dev-return-write:+validate-record-value+path=$FG_EXIT+field=exit+value=x=true"
  "an empty lane name|$FG_FAIL --validate pass --validate-record $FG_LANES|rc=2 written=no stderr~dev-return-write:+validate-record-value+path=$FG_LANES+field=lanes+value=lint,=true"
  "lanes beside an unreported selection|$FG_FAIL --validate pass --validate-record $FG_UNREPORTED_LANES|rc=2 written=no stderr~dev-return-write:+validate-record-lanes+path=$FG_UNREPORTED_LANES+selection=unreported=true"
  "a subset with no lanes|$FG_FAIL --validate pass --validate-record $FG_SUBSET_NOLANES|rc=2 written=no stderr~dev-return-write:+validate-record-lanes+path=$FG_SUBSET_NOLANES+selection=subset=true"
  "a run that ends before it starts|$FG_FAIL --validate pass --validate-record $FG_BACKWARDS|rc=2 written=no stderr~dev-return-write:+validate-record-time+path=$FG_BACKWARDS=true"
)
# Each required field, dropped alone, is refused on its own name.
for field in validate-mode head started-at ended-at exit selection; do
  dropped="$(foreground_record "no-$field" "-$field")"
  FOREGROUND_ROWS+=("a record with no $field|$FG_FAIL --validate pass --validate-record $dropped|rc=2 written=no stderr~dev-return-write:+validate-record-missing+path=$dropped+field=$field=true")
done
table --independent "${FOREGROUND_ROWS[@]}"
assert_eq "$(cat -- "$FG_MEASUREMENT")" "$FG_MEASUREMENT_BEFORE" "recording no-verdict keeps the raw exit 77 and the foreground record bytes"

# A fix receipt binds the record's head and start time to its round as it
# binds a run directory's.
FG_BOUND="$(foreground_record fix-bound "head=$ROUND_BASE" "started-at=$(utc_at "$ROUND_DELEGATED")" "ended-at=$(utc_at "$(( ROUND_DELEGATED + 60 ))")")"
FG_EARLY="$(foreground_record fix-early "head=$ROUND_BASE" "started-at=$(utc_at "$(( ROUND_DELEGATED - 1 ))")" "ended-at=$(utc_at "$(( ROUND_DELEGATED + 60 ))")")"
FG_OFF="$(foreground_record fix-off "head=$IMPL_BASE" "started-at=$(utc_at "$ROUND_DELEGATED")" "ended-at=$(utc_at "$(( ROUND_DELEGATED + 60 ))")")"
FG_RESTACK="$(foreground_record fix-restack "head=$REBASED_CHILD" "started-at=$(utc_at "$ROUND_DELEGATED")" "ended-at=$(utc_at "$(( ROUND_DELEGATED + 60 ))")")"
printf 'rebase-hop:\nrebase-map: %s %s\n' "$ROUND_BASE" "$REBASED" > "$RESTACK_MAP"
table \
  "a fix record at a descendant of the mapped base is accepted|--worktree $BW $RESTACK_ARGS --validate-record $FG_RESTACK|rc=0 .validate_mode=full .validate_time.seconds=60" \
  "a fix record started at the round base once the round was delegated is accepted|--worktree $BW $BIND_ARGS --validate-record $FG_BOUND|rc=0 .validate_mode=full .validate_time.seconds=60" \
  "a fix record started before the round was delegated is refused|--worktree $BW $BIND_ARGS --validate-record $FG_EARLY|rc=2 written=no stderr~dev-return-write:+run-before-round+validate-record=$FG_EARLY+start=$(( ROUND_DELEGATED - 1 ))+delegated-at=$ROUND_DELEGATED=true" \
  "a fix record whose head lacks the round base is refused|--worktree $BW $BIND_ARGS --validate-record $FG_OFF|rc=2 written=no stderr~dev-return-write:+run-off-round+validate-record=$FG_OFF+head=$IMPL_BASE+base-sha=$ROUND_BASE=true"
RECORD_RESTACK_WRITE="$(mutant_scripts record-restack-mutant dev-return-write)/dev-return-write" || exit 1
mutate_file "$RECORD_RESTACK_WRITE" 'git -C "$worktree" merge-base --is-ancestor "$mapped_base" "$run_head" 2>/dev/null || ancestry=$?' '[[ "$mapped_base" == "$run_head" ]] || ancestry=$?'
WRITE="$RECORD_RESTACK_WRITE"
table "control: exact equality refuses the restacked fix record|--worktree $BW $RESTACK_ARGS --validate-record $FG_RESTACK|rc=2 written=no stderr~dev-return-write:+run-off-round=true"
WRITE="$WRITE_SHIPPED"
rm -f -- "$RESTACK_MAP"
rm -f -- "$BW/tmp/dev-return-issue-776-21-21.json"
WRITE="$BIND_WRITE"
table "control: without the binding a record from before the round is recorded for the fix|--worktree $BW $BIND_ARGS --validate-record $FG_EARLY|rc=0 .validate_mode=full"
WRITE="$WRITE_SHIPPED"
rm -f -- "$BW/tmp/dev-return-issue-776-21-21.json"

# One control per record rule: each mutant disables one, and its row's
# refusal turns into a written receipt. In OLD and NEW, \| is a literal bar.
FOREGROUND_CONTROLS=(
  "required fields|for key in validate-mode head started-at ended-at exit selection; do|for key in; do|$FG_ARGS --validate pass --validate-record $TMP_ROOT/records/no-head|rc=0 written=yes"
  "verdict from the exit status|run_verdict=\"\$(validation_verdict \"guard-exit=\$exit_status at=\$validate_ended_at\$marker\")\"|run_verdict=pass|$FG_ARGS --validate pass --validate-record $FG_FAILED|rc=0 written=yes"
  "explicit no-verdict marker|marker=\" \$line\"|marker=\"\"|$FG_ARGS --validate no-verdict --validate-record $FG_HOST --validate-note scoped|rc=2 written=no stderr~dev-return-write:+validate-disagrees+validate=no-verdict+run=FAILING=true"
  "one source|if [[ \"\$validate_run_dir_given\" == \"true\" && \"\$validate_record_given\" == \"true\" ]]; then|if false; then|$FG_ARGS --validate pass --validate-run-dir $VRUN --validate-record $FG_OK|rc=0 written=yes"
  "key given once|[[ \"\$line\" == *=* && \"\$seen\" != *\" \$key \"* ]]|[[ \"\$line\" == *=* ]]|$FG_ARGS --validate FAILING:+x --validate-record $FG_DUPLICATE|rc=0 written=yes"
  "known keys|*) die validate-record-line \"path=\$path\" \"line=\$line_no\" ;;|*) ;;|$FG_ARGS --validate pass --validate-record $FG_UNKNOWN|rc=0 written=yes"
  "value grammar|[[ \"\$3\" =~ \$4 ]] \|\| die validate-record-value|true \|\| die validate-record-value|$FG_ARGS --validate pass --validate-record $FG_HEAD|rc=0 written=yes"
  "line shape|value=\"\${line#*=}\"|value=\"\${line#*=}\"; [[ \"\$line\" == *=* ]] \|\| line=\"\$line=\"|$FG_ARGS --validate pass --validate-record $FG_BARE|rc=0 written=yes"
  "lanes pairing|if [[ \"\$validate_selection\" == unreported ]]; then|if false; then|$FG_ARGS --validate pass --validate-record $FG_UNREPORTED_LANES|rc=0 written=yes"
  "lanes required|[[ -n \"\$validate_lanes\" ]] \|\| die|true \|\| die|$FG_ARGS --validate pass --validate-record $FG_SUBSET_NOLANES|rc=0 written=yes"
  "calendar validity|\|\| die validate-record-value \"path=\$path\" \"field=started-at,ended-at\"|\|\| true \|\| die validate-record-value \"path=\$path\" \"field=started-at,ended-at\"|$FG_ARGS --validate pass --validate-record $FG_HOUR|rc=0 written=yes"
  "time order|(( ended >= started ))|true|$FG_ARGS --validate pass --validate-record $FG_BACKWARDS|rc=0 written=yes"
)
for control in "${FOREGROUND_CONTROLS[@]}"; do
  IFS='|' read -r name old new args expect <<<"${control//\\|/$'\x1f'}"
  old="${old//$'\x1f'/|}"; new="${new//$'\x1f'/|}"
  CONTROL_WRITE="$(mutant_scripts "record-${name// /-}-mutant" dev-return-write)/dev-return-write" || exit 1
  mutate_file "$CONTROL_WRITE" "$old" "$new"
  WRITE="$CONTROL_WRITE"
  table --independent "control: without the $name rule the row's refusal becomes a receipt|$args|$expect"
  WRITE="$WRITE_SHIPPED"
done
# The battery selection's control runs the other way: with battery outside the
# grammar the record that reports it is refused.
BATTERY_WRITE="$(mutant_scripts record-battery-mutant dev-return-write)/dev-return-write" || exit 1
mutate_file "$BATTERY_WRITE" "'^(all|subset|battery|unreported)\$'" "'^(all|subset|unreported)\$'"
WRITE="$BATTERY_WRITE"
table "control: without battery in the grammar its record is refused|$FG_FAIL --validate pass --validate-record $FG_BATTERY|rc=2 written=no stderr~dev-return-write:+validate-record-value+path=$FG_BATTERY+field=selection+value=battery=true"
WRITE="$WRITE_SHIPPED"

echo "=== every refusal exits 2 on its own guard and writes nothing ==="
# Every value-taking flag refuses a missing value and an option token in its
# place (an argc-only check would record `--no-summary` as the deliverable);
# single-valued flags refuse duplicates rather than last-win; both summary
# sources at once, or an explicitly empty --summary-file, are a config error
# and never a silent no-op; an empty or whitespace note or summary is refused
# rather than stored. Every implement row's commit `c` is unresolvable, so the
# stderr clause is what proves the row's own guard fired.
table \
  "a bad --kind|--worktree $WT --kind review --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN|rc=2 stderr~dev-return-write:+invalid-kind+value=review=true" \
  "a pass with no run directory|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass|rc=2 stderr~dev-return-write:+required+options=--validate-run-dir,--validate-record+validate=pass=true" \
  "a run directory whose mode is outside the three|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN_BAD|rc=2 stderr~dev-return-write:+run-record-unreadable+path=$VRUN_BAD+cause=dev-validate-run:+record-unreadable+path=$VRUN_BAD/start+validate-mode=class=true" \
  "a run directory with no start record|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $TMP_ROOT/validate-run-empty|rc=2 stderr~dev-return-write:+run-record-unreadable+path=$TMP_ROOT/validate-run-empty+cause=dev-validate-run:+no-run+path=$TMP_ROOT/validate-run-empty/start=true" \
  "a pass naming a run that failed|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN_FAILED|rc=2 stderr~dev-return-write:+validate-disagrees+validate=pass+run=FAILING=true" \
  "a pass naming a run the timeout ended|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN_CUT|rc=2 stderr~dev-return-write:+validate-disagrees+validate=pass+run=no-verdict=true" \
  "no-verdict naming a run that failed|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate no-verdict --validate-run-dir $VRUN_FAILED|rc=2 stderr~dev-return-write:+validate-disagrees+validate=no-verdict+run=FAILING=true" \
  "no-verdict naming a run that passed|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate no-verdict --validate-run-dir $VRUN|rc=2 stderr~dev-return-write:+validate-disagrees+validate=no-verdict+run=pass=true" \
  "no-verdict with no note naming the scoped suites|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate no-verdict --validate-run-dir $VRUN_CUT|rc=2 stderr~dev-return-write:+required+option=--validate-note+validate=no-verdict=true" \
  "no-verdict with no run directory|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate no-verdict|rc=2 stderr~dev-return-write:+required+options=--validate-run-dir,--validate-record+validate=no-verdict=true" \
  "a pass naming a run with no verdict yet|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN_UNFINISHED|rc=2 stderr~dev-return-write:+validate-disagrees+validate=pass+run=unfinished=true" \
  "a missing --round-id|--worktree $WT --kind implement --issue i --branch b --commit c --validate pass --validate-run-dir $VRUN|rc=2 stderr~dev-return-write:+required+option=--round-id=true" \
  "a missing --issue|--worktree $WT --kind implement --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN|rc=2 stderr~dev-return-write:+required+option=--issue=true" \
  "a value flag with no value at the end|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate|rc=2 stderr~dev-return-write:+missing-value+option=--validate=true" \
  "a missing --worktree|--kind implement --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN|rc=2 stderr~dev-return-write:+required+option=--worktree=true" \
  "a nonexistent --worktree: the writer's own guard, not the base resolver's|--worktree $TMP_ROOT/nope --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN|rc=2 stderr~dev-return-write:+not-directory+path=$TMP_ROOT/nope=true" \
  "a bad --validate|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate weird|rc=2 stderr~dev-return-write:+invalid-validate+value=weird=true" \
  "a verdict that only begins with pass, note and all|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass_with_notes --validate-note explained|rc=2 stderr~dev-return-write:+invalid-validate+value=pass_with_notes=true" \
  "a path-unsafe --issue|--worktree $WT --kind implement --issue a/b --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN|rc=2 stderr~dev-return-write:+invalid-id+option=--issue+value=a/b=true" \
  "a path-traversal --round-id|--worktree $WT --kind implement --issue i --round-id .. --branch b --commit c --validate pass --validate-run-dir $VRUN|rc=2 stderr~dev-return-write:+invalid-id+option=--round-id+value=..=true" \
  "a missing --summary-file|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN --summary-file $TMP_ROOT/nope.md|rc=2 stderr~dev-return-write:+missing-file+path=$TMP_ROOT/nope.md=true" \
  "a bad --item DECISION|--worktree $WT --kind fix --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN --item 1 Fixed x|rc=2 stderr~dev-return-write:+item-decision+value=Fixed=true" \
  "an empty --item REASONING|--worktree $WT --kind fix --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN --item 1 Applied EMPTY|rc=2 stderr~dev-return-write:+item-empty+item=1=true" \
  "a non-numeric --item N|--worktree $WT --kind fix --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN --item x Applied x|rc=2 stderr~dev-return-write:+item-number+value=x=true" \
  "--item with too few arguments|--worktree $WT --kind fix --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN --item 1 Applied|rc=2 stderr~dev-return-write:+item-arguments+count=2=true" \
  "a fix with no --item|--worktree $WT --kind fix --issue issue-noitems --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN|rc=2 stderr~dev-return-write:+missing-items+kind=fix+bundled=false+count=0=true" \
  "a bundled implement with no --item|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN --bundled|rc=2 stderr~dev-return-write:+missing-items+kind=implement+bundled=true+count=0=true" \
  "an unknown argument|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN --frobnicate|rc=2 stderr~dev-return-write:+unknown-argument+argument=--frobnicate=true" \
  "both --summary and --summary-file|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN --summary inline --summary-file $SUMMARY_FILE|rc=2 stderr~dev-return-write:+summary-conflict+options=--summary,--summary-file=true" \
  "--summary plus an empty --summary-file value: presence, not content|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN --summary inline --summary-file EMPTY|rc=2 stderr~dev-return-write:+summary-conflict+options=--summary,--summary-file=true" \
  "--recovered-text beside --summary-file: one summary source|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN --summary-file $SUMMARY_FILE --recovered-text $SUMMARY_FILE|rc=2 stderr~dev-return-write:+summary-conflict+options=--summary,--summary-file,--recovered-text=true" \
  "a missing --recovered-text|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN --recovered-text $TMP_ROOT/gone.md|rc=2 stderr~dev-return-write:+missing-file+path=$TMP_ROOT/gone.md=true" \
  "an explicitly empty --summary-file alone|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN --summary-file EMPTY|rc=2 stderr~dev-return-write:+required+option=--summary-file=true" \
  "a whitespace-only --summary: an empty deliverable is not a record|--worktree $WT --kind implement --issue issue-blanksum --round-id $RID --branch b --commit %H --validate pass --validate-run-dir $VRUN --summary SPACES|rc=2 stderr~dev-return-write:+empty-text+option=--summary=true" \
  "--summary with no value|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN --summary|rc=2 stderr~dev-return-write:+missing-value+option=--summary=true" \
  "--summary followed by another flag: an option token is not a value|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN --summary --no-summary|rc=2 stderr~dev-return-write:+flag-value+option=--summary+value=--no-summary=true" \
  "--summary-file followed by another flag|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN --summary-file --no-summary|rc=2 stderr~dev-return-write:+flag-value+option=--summary-file+value=--no-summary=true" \
  "--branch followed by another flag|--worktree $WT --kind implement --issue i --round-id $RID --branch --commit c --validate pass --validate-run-dir $VRUN|rc=2 stderr~dev-return-write:+flag-value+option=--branch+value=--commit=true" \
  "--validate-note followed by another flag|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN --validate-note --qa-label needs-review|rc=2 stderr~dev-return-write:+flag-value+option=--validate-note+value=--qa-label=true" \
  "--item REASONING as an option token|--worktree $WT --kind fix --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN --item 1 Applied --bundled|rc=2 stderr~dev-return-write:+item-flag+item=1+value=--bundled=true" \
  "a duplicate --summary|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN --summary first --summary second|rc=2 stderr~dev-return-write:+duplicate+option=--summary=true" \
  "a duplicate --summary-file|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN --summary-file $SUMMARY_FILE --summary-file $SUMMARY_FILE|rc=2 stderr~dev-return-write:+duplicate+option=--summary-file=true" \
  "a duplicate --branch|--worktree $WT --kind implement --issue i --round-id $RID --branch b --branch b2 --commit c --validate pass --validate-run-dir $VRUN|rc=2 stderr~dev-return-write:+duplicate+option=--branch=true" \
  "a duplicate --validate|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN --validate pass --validate-run-dir $VRUN|rc=2 stderr~dev-return-write:+duplicate+option=--validate=true" \
  "an empty --commit|--worktree $WT --kind implement --issue i --round-id $RID --branch b --validate pass --validate-run-dir $VRUN --commit EMPTY|rc=2 stderr~dev-return-write:+required+option=--commit=true" \
  "a whitespace-only --validate-note|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN --validate-note SPACES|rc=2 stderr~dev-return-write:+empty-text+option=--validate-note=true" \
  "--validate-note with no value|--worktree $WT --kind implement --issue i --round-id $RID --branch b --commit c --validate pass --validate-run-dir $VRUN --validate-note|rc=2 stderr~dev-return-write:+missing-value+option=--validate-note=true"
assert_eq "$([[ -f "$WT/tmp/dev-return-issue-noitems-$RID.json" ]] && echo yes || echo no)" "no" "a rejected invocation writes no artifact at the target path"

echo "=== immutable same-round recovery receipts ==="
# The writer and checker consume native --record evidence, as the other receipt
# cases do. Focused proof and duration admission remain workflow judgments.
for recovery_case in implement-pass implement-failed implement-foreground implement-interrupted fix-pass fix-no-run fix-foreground fix-interrupted fix-unproved; do
  recovery_kind=${recovery_case%%-*}
  recovery_result=${recovery_case#*-}
  RW="$(new_repo "recovery-$recovery_case")"
  git -C "$RW" switch -q -c recovery
  printf '[env]\nDEV_VALIDATE_RANGE_CMD = "true"\nORCH_PR_ORDER = "review-first"\n' > "$RW/kendex.settings.toml"
  git -C "$RW" add kendex.settings.toml
  git -C "$RW" commit -q -m implementation
  RH="$(git -C "$RW" rev-parse HEAD)"
  RT="$(git -C "$RW" rev-parse HEAD^{tree})"
  init_growth_state "$STATE" "$RW" issue-4503 recovery 100
  extra=(); check_extra=(); native_mode=full
  if [[ "$recovery_kind" == fix ]]; then
    mkdir -p "$RW/.cache/tracker-fixture"
    printf '[{"identifier":"issue-4503","description":"**Expected delta**: 100 lines, 100 test lines"}]\n' > "$RW/.cache/tracker-fixture/issues.json"
    growth_round_write "$STATE" "$ROUND_WRITE" --worktree "$RW" --issue issue-4503 --round-id recovery \
      --item 1 'repair validation' 'native receipts' >/dev/null
    extra=(--item 1 Applied repaired); check_extra=(--expect-items-from-round); native_mode=range
  fi
  started="$(date +%s)"
  old_run="$(validate_run_dir "$RW/tmp/failed-run" "$native_mode" 1 "$RH" "$started")"
  new_run="$(validate_run_dir "$RW/tmp/recovery-run" "$native_mode" 0 "$RH" "$((started + 2))")"
  for native_run in "$old_run" "$new_run"; do
    offset=0; [[ "$native_run" == "$old_run" ]] || offset=2
    printf 'tree=%s\nclass-base=%s\n' "$RT" "$RH" >> "$native_run/start"
    jq -nr --argjson start "$((started + offset))" \
      '"started-at=\($start|todate)\nended-at=\($start+1|todate)\nseconds=1"' > "$native_run/timing"
  done
  base_args=(--worktree "$RW" --kind "$recovery_kind" --issue issue-4503 --round-id recovery --branch recovery --commit "$RH")
  original_source=(--validate-run-dir "$old_run")
  # Required pre-run checks can fail before the writer has native evidence.
  if [[ "$recovery_result" == no-run ]]; then original_source=(); fi
  if [[ "$recovery_result" == foreground ]]; then
    sed '/^class-base=/d' "$old_run/start" > "$RW/tmp/foreground-start"
    cp "$RW/tmp/foreground-start" "$old_run/start"
  fi
  run "${base_args[@]}" --validate 'FAILING: scoped' ${original_source[@]+"${original_source[@]}"} ${extra[@]+"${extra[@]}"}
  assert_eq "$RC" 0 "$recovery_case failed original is written" "$ERR"
  original="$OUT"; cp "$original" "$RW/tmp/original-bytes"
  run "${base_args[@]}" --validate pass --validate-run-dir "$new_run" ${extra[@]+"${extra[@]}"}
  assert_eq "$RC" 2 "$recovery_case refuses same-path overwrite" "$ERR"
  verdict=pass; accepted=accept; expected_mode="$native_mode"; expected_base="$RH"
  result_source=(--validate-run-dir "$new_run")
  case "$recovery_result" in
    failed) verdict='FAILING: scoped'; accepted=retry; printf 'guard-exit=1 at=2026-01-01T00:55:00Z\n' > "$new_run/exit" ;;
    unproved) verdict=no-verdict; printf 'guard-exit=124 at=2026-01-01T00:55:00Z verdict=no-verdict\n' > "$new_run/exit" ;;
    foreground)
      fg_recovery="$(foreground_record recovery "validate-mode=$native_mode" "head=$RH" "started-at=$(utc_at "$((started + 2))")" "ended-at=$(utc_at "$((started + 3))")")"
      result_source=(--validate-record "$fg_recovery"); expected_base="" ;;
    interrupted)
      verdict='FAILING: interrupted-foreground'; accepted=retry; result_source=(); expected_mode=""; expected_base=""
      fg_recovery="$(foreground_record interrupted "validate-mode=$native_mode" "head=$RH" "started-at=$(utc_at "$((started + 2))")" -ended-at -exit -selection -lanes)"
      cp "$fg_recovery" "$RW/tmp/unfinished-record-bytes"
      run "${base_args[@]}" --recovery --validate "$verdict" --validate-note recovery --validate-record "$fg_recovery" ${extra[@]+"${extra[@]}"}
      assert_eq "$RC" 2 "$recovery_case refuses unfinished evidence as a completed record" "$ERR" ;;
  esac
  run "${base_args[@]}" --recovery --validate "$verdict" --validate-note recovery ${result_source[@]+"${result_source[@]}"} ${extra[@]+"${extra[@]}"}
  assert_eq "$RC $(rec '.round_id') $(rec '.commit') $(rec '.recovery_of')" \
    "0 recovery $RH ${original##*/}" "$recovery_case keeps the real round and implementation commit" "$ERR"
  companion="$OUT"
  cmp -s "$original" "$RW/tmp/original-bytes" && unchanged=true || unchanged=false
  assert_eq "$unchanged" true "$recovery_case preserves the failed bytes"
  selected="$(env ORCH_STATE_DIR="$RW/tmp" "$CHECK" --worktree "$RW" --issue issue-4503 --round-id recovery ${check_extra[@]+"${check_extra[@]}"})"
  assert_eq "$(jq -r '[.verdict,.path,.validate_mode,.validate_class_base] | join(" ")' <<<"$selected")" \
    "$accepted $companion $expected_mode $expected_base" "$recovery_case acceptance selects the terminal result"
  assert_eq "$("$CHECK" --file "$companion" | jq -r '.validate')" "$verdict" "$recovery_case submit reads the selected result"
  assert_eq "$("$CHECK" --file "$original" | jq -r '.validate')" 'FAILING: scoped' "$recovery_case failed original stays readable"
  state_file="$RW/tmp/workflow-state-issue-4503.json"
  scoped_count=1
  scoped_receipts="[\"${original##*/}\"]"
  if [[ "$recovery_result" == failed ]]; then
    scoped_count=2; scoped_receipts="[\"${original##*/}\",\"${companion##*/}\"]"
  fi
  assert_eq "$("$STATE" --state-dir "$RW/tmp" findings query issue-4503 | jq -c '.classes[] | select(.class.check == "scoped") | [.observed_count, (.sources | map(.receipt))]')" \
    "[$scoped_count,$scoped_receipts]" "$recovery_case counts failed original and recovery by their distinct receipt sources"
  expected_stages="[[\"${original##*/}\",$started,$((started + 1))],[\"${companion##*/}\",$((started + 2)),$((started + 3))]]"
  expected_durations="[[\"recovery\",\"${original##*/}\",1],[\"recovery\",\"${companion##*/}\",1]]"
  if [[ "$recovery_result" == no-run ]]; then
    expected_stages="[[\"${companion##*/}\",$((started + 2)),$((started + 3))]]"
    expected_durations="[[\"recovery\",\"${companion##*/}\",1]]"
  fi
  if [[ "$recovery_result" == interrupted ]]; then
    assert_eq "$(jq -c '[.validate_mode,.validate_time,has("validate_class_base")]' "$companion")" \
      '[null,null,false]' "$recovery_case preserves unavailable proof without inventing mode, base or timing"
    cmp -s "$fg_recovery" "$RW/tmp/unfinished-record-bytes" && unchanged=true || unchanged=false
    assert_eq "$unchanged" true "$recovery_case preserves its unfinished foreground record"
    expected_stages="[[\"${original##*/}\",$started,$((started + 1))]]"
    expected_durations="[[\"recovery\",\"${original##*/}\",1]]"
  fi
  assert_eq "$(jq -c '[.stages[] | select(.kind == "validate" and .round_id == "recovery") | [.receipt,.start,.end]]' "$state_file")" \
    "$expected_stages" "$recovery_case retains each receipt validation stage"
  assert_eq "$(jq -c '[.validate_rounds[] | [.round_id,.receipt,.seconds]]' "$state_file")" \
    "$expected_durations" "$recovery_case retains each receipt duration"
  first_timing="$(jq -c '{stages,validate_rounds,finding_occurrences}' "$state_file")"
  env ORCH_STATE_DIR="$RW/tmp" "$CHECK" --worktree "$RW" --issue issue-4503 --round-id recovery ${check_extra[@]+"${check_extra[@]}"} >/dev/null
  assert_eq "$(jq -c '{stages,validate_rounds,finding_occurrences}' "$state_file")" "$first_timing" "$recovery_case reread is idempotent"
  run "${base_args[@]}" --recovery --validate "$verdict" --validate-note recovery ${result_source[@]+"${result_source[@]}"} ${extra[@]+"${extra[@]}"}
  assert_eq "$RC" 2 "$recovery_case refuses another terminal companion" "$ERR"
  if [[ "$recovery_case" == implement-interrupted ]]; then
    rm -f -- "${companion:?}"
    run "${base_args[@]}" --recovery --validate "$verdict"
    assert_eq "$RC" 2 'interrupted recovery requires a note explaining unavailable evidence' "$ERR"
    WRITE="$(mutant_scripts recovery-interrupted-mutant dev-return-write)/dev-return-write" || exit 1
    mutate_file "$WRITE" '[[ "$validate" == FAILING:* && -n "$validate_note" ]]' 'false'
    run "${base_args[@]}" --recovery --validate "$verdict" --validate-note recovery
    assert_eq "$RC" 2 'control: requiring completed evidence rejects the interrupted terminal result' "$ERR"
    WRITE="$WRITE_SHIPPED"
  fi
done

# Invalid native bindings and parents reach the real writer before publication.
# Keep one last fix fixture; remove only its companion for independent inputs.
cp "$companion" "$RW/tmp/valid-companion"
for defect in tree missing-tree mode base parent-pass parent-malformed; do
  rm -f -- "${companion:?}"
  cp "$RW/tmp/original-bytes" "$original"
  cp "$new_run/start" "$RW/tmp/start-good"
  case "$defect" in
    tree) sed 's/^tree=.*/tree=0000000000000000000000000000000000000000/' "$RW/tmp/start-good" > "$new_run/start" ;;
    missing-tree) sed '/^tree=/d' "$RW/tmp/start-good" > "$new_run/start" ;;
    mode) sed 's/^validate-mode=.*/validate-mode=full/' "$RW/tmp/start-good" > "$new_run/start" ;;
    base) sed 's/^class-base=.*/class-base=0000000000000000000000000000000000000000/' "$RW/tmp/start-good" > "$new_run/start" ;;
    parent-pass) jq '.validate="pass"' "$RW/tmp/original-bytes" > "$original" ;;
    parent-malformed) jq 'del(.validate_time)' "$RW/tmp/original-bytes" > "$original" ;;
  esac
  run "${base_args[@]}" --recovery --validate no-verdict --validate-note recovery --validate-run-dir "$new_run" ${extra[@]+"${extra[@]}"}
  assert_eq "$RC $(test -e "$companion" && echo exists || echo absent)" '2 absent' "$defect refuses recovery publication" "$ERR"
  cp "$RW/tmp/start-good" "$new_run/start"
done
cp "$RW/tmp/original-bytes" "$original"
WRITE="$(mutant_scripts recovery-tree-mutant dev-return-write)/dev-return-write" || exit 1
mutate_file "$WRITE" '[[ "$run_tree" =~ ^[0-9a-f]{40}$ && "$run_tree" == "$(git -C "$worktree" rev-parse "$commit^{tree}")" ]]' 'true'
cp "$new_run/start" "$RW/tmp/start-good"
sed 's/^tree=.*/tree=0000000000000000000000000000000000000000/' "$RW/tmp/start-good" > "$new_run/start"
run "${base_args[@]}" --recovery --validate no-verdict --validate-note recovery --validate-run-dir "$new_run" ${extra[@]+"${extra[@]}"}
assert_eq "$RC" 0 'control: omitting the native snapshot comparison admits changed contents' "$ERR"
rm -f -- "${companion:?}"
cp "$RW/tmp/start-good" "$new_run/start"
WRITE="$WRITE_SHIPPED"
for defect in json parent identity missing-marker; do
  case "$defect" in
    json) printf 'invalid' > "$companion" ;;
    parent) jq '.recovery_of="other.json"' "$RW/tmp/valid-companion" > "$companion" ;;
    identity) jq '.round_id="other"' "$RW/tmp/valid-companion" > "$companion" ;;
    missing-marker) jq 'del(.recovery_of)' "$RW/tmp/valid-companion" > "$companion" ;;
  esac
  selected="$($CHECK --worktree "$RW" --issue issue-4503 --round-id recovery --expect-items-from-round)" && rc=0 || rc=$?
  assert_eq "$rc $(jq -r '[.reason,.path] | join(" ")' <<<"$selected")" "1 invalid $companion" "$defect companion refuses without falling back"
done
# A control changes only the executable parent guard. The focused invalid-parent
# row must change its result, proving the new checker instrument observes it.
CONTROL_CHECK="$(mutant_scripts recovery-parent-mutant dev-artifact-check)/dev-artifact-check" || exit 1
mutate_file "$CONTROL_CHECK" '.recovery_of == $parent and ($original[0] as $p' 'true and ($original[0] as $p'
jq '.recovery_of="other.json"' "$RW/tmp/valid-companion" > "$companion"
assert_eq "$("$CONTROL_CHECK" --worktree "$RW" --issue issue-4503 --round-id recovery --expect-items-from-round | jq -r '.reason')" valid \
  'control: ignoring the parent identity admits the invalid companion'

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
