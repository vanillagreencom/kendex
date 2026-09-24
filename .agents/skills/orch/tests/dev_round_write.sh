#!/usr/bin/env bash
# Tests for dev-round-write: the orchestrator-side writer that persists a fix
# round's delegated item set to the round-scoped record
# ([WORKTREE]/tmp/dev-round-[ISSUE_ID]-[ROUND_ID].json) at delegation time,
# with the round token in the filename AND as the internal round_id. Without
# it the delegated set exists only in the orchestrator's context: a respawned
# dev agent cannot write a truthful completion artifact, and
# dev-artifact-check --expect-items-from-round has no on-disk source of truth.
# The checker's additions classifier and its round-mode wait are
# dev-artifact-check-additions.sh; the workflow documents that carry the
# writer's command are dev-round-write-wiring.test.sh.
#
# One case per behaviour surface; shaped input is one table per case, one
# asserted row per shape. A row's `expect` names the fields it pins and
# `observe` reads exactly those, so a row fails on the field it names.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
STATE="$REPO_ROOT/skills/orch/scripts/workflow-state"
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"
# shellcheck source=lib/waiter-assertions.sh
source "$TEST_DIR/lib/waiter-assertions.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/linear/scripts" "$TMP_ROOT/bin"
# The size owner reads the issue through its sibling Linear CLI. This stand-in
# supplies the same raw cache row on Bash 3.2 test runners.
cat > "$TMP_ROOT/linear/scripts/linear.sh" <<'SH'
#!/usr/bin/env bash
set -eu
row="$(jq -c --arg id "$4" '.[] | select(.identifier == $id)' .cache/linear/issues.json)"
[[ -n "$row" ]] || exit 1
jq -n --argjson issue "$row" '{issue: $issue}'
SH
cat > "$TMP_ROOT/bin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
jq -r --arg id "issue-$3" '.[] | select(.identifier == $id) | .description' .cache/linear/issues.json
SH
chmod +x "$TMP_ROOT/linear/scripts/linear.sh" "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"
LIVE_SCRIPTS="$(copy_scripts live)"
WRITE_BIN="$LIVE_SCRIPTS/dev-round-write"
RETURN_WRITE="$LIVE_SCRIPTS/dev-return-write"
CHECK="$LIVE_SCRIPTS/dev-artifact-check"

write_allowance() {
  local repo="$1" issue="$2" line="$3"
  mkdir -p "$repo/.cache/linear"
  if [[ ! -f "$repo/.cache/linear/issues.json" ]]; then
    printf '[]\n' > "$repo/.cache/linear/issues.json"
  fi
  jq --arg id "$issue" --arg body "$line" \
    '[.[] | select(.identifier != $id)] + [{identifier: $id, description: $body}]' \
    "$repo/.cache/linear/issues.json" > "$repo/.cache/linear/next.json"
  mv "$repo/.cache/linear/next.json" "$repo/.cache/linear/issues.json"
}

# new_repo NAME ISSUE... — a committed git repo with growth state for each
# ISSUE; prints its path.
new_repo() {
  local d="$TMP_ROOT/$1" issue
  shift
  mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name Test
  git -C "$d" config commit.gpgsign false
  git -C "$d" commit -q --allow-empty -m base
  printf '.cache/\n' >> "$(git -C "$d" rev-parse --path-format=absolute --git-path info/exclude)"
  for issue in "$@"; do
    init_growth_state "$STATE" "$d" "$issue" seed 1000000 >/dev/null
    write_allowance "$d" "$issue" '**Expected delta**: 1000000 lines, 1000000 test lines'
  done
  printf '%s' "$d"
}

# --- harness -----------------------------------------------------------------

# run_write ARGS... — runs the writer through growth-state's wrapper (which
# stamps the round id the writer checks); OUT is the printed record path, RC
# the exit, ERR the stderr file.
RUN_SEQ=0
run_write() {
  RUN="$TMP_ROOT/runs/$((++RUN_SEQ))"
  mkdir -p "$RUN"
  ERR="$RUN/stderr"
  set +e
  OUT=$(growth_round_write "$STATE" "$WRITE_BIN" "$@" 2>"$ERR")
  RC=$?
  set -e
}

# rec EXPR — a jq read of the record at OUT.
rec() { jq -r "$1" "$OUT" 2>/dev/null || echo UNPARSEABLE; }

# observe EXPECT — prints the run's value of every `name=` field EXPECT names,
# in EXPECT's order:
#   rc               exit status
#   out              the printed path, or empty
#   written          whether a file exists at the printed path
#   stderr~<text>    whether stderr carries <text> (`+` reads as a space)
#   <jq path>        a read of the record at the printed path, e.g.
#                    `.schema_version`, `.items|length`, `[.items[].n]`;
#                    `+` reads as a space
observe() {
  local got="" token name value needle
  for token in $1; do
    name="${token%=*}"
    case "$name" in
      rc) value="$RC" ;;
      out) value="$OUT" ;;
      written) value="$([[ -n "$OUT" && -f "$OUT" ]] && echo yes || echo no)" ;;
      stderr~*) needle="${name#stderr~}"; value="$(grep -qF -- "${needle//+/ }" "$ERR" && echo true || echo false)" ;;
      *) value="$(rec "$name")" ;;
    esac
    got="$got $name=$value"
  done
  printf '%s' "${got# }"
}

# table ROW... — one run and one assertion per row: `label|args|expect`.
# Args split on spaces; inside an arg `+` reads as a space, `EMPTY` as the
# empty string and `SPACES` as three spaces.
table() {
  local row label args expect a argv
  for row in "$@"; do
    IFS='|' read -r label args expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    argv=()
    for a in $args; do
      case "$a" in EMPTY) a="" ;; SPACES) a="   " ;; *) a="${a//+/ }" ;; esac
      argv+=("$a")
    done
    run_write ${argv[@]+"${argv[@]}"}
    assert_eq "$(observe "$expect")" "$expect" "$label" "$ERR"
  done
}

WT="$(new_repo wt issue-1230 i)"
BASE_SHA="$(git -C "$WT" rev-parse HEAD)"
RID="1750000000-77"
# A reach the writer accepts: a command a person runs.
OK_REACH="tools/guard on a staged .agents render"
OKR="tools/guard+on+a+staged+.agents+render"
ADDS="crates/parser/src/lib.rs skills/orch/scripts/new-check"
ITEM1='#1 | security-review | src/auth.rs
Description: "token refresh races"
Recommendation: "serialize refresh behind the existing lock"'
ITEM2='#2 | test-review | tests/auth.rs
Description: "no coverage for expired token"
Recommendation: "add expiry regression test"'
REACH1='a second session refreshing the same account through src/auth.rs'
REACH2='tests/auth.rs expired-token case'

echo "=== a two-item round record, immutable once stamped ==="
# The record is the whole authorization (nothing is written outside the
# worktree); an identical re-invocation is an idempotent retry, a different
# set under the same round id is refused with the original intact, and a
# fresh round id writes a distinct file beside the prior round's.
run_write --worktree "$WT" --issue issue-1230 --round-id "$RID" --item 1 "$ITEM1" "$REACH1" --item 2 "$ITEM2" "$REACH2" --adds "$ADDS"
FIRST="$OUT"
E="rc=0 out=$WT/tmp/dev-round-issue-1230-$RID.json written=yes .schema_version=2 .schema_version|type=number .round_id=$RID .issue=issue-1230 .base_sha=$BASE_SHA .adds|tojson=[\"crates/parser/src/lib.rs\",\"skills/orch/scripts/new-check\"] .items|length=2 .items[0].n=1 .items[0].n|type=number"
assert_eq "$(observe "$E")" "$E" "the record carries the round token, the normalized issue, HEAD as base_sha, the adds list and one numbered item per --item" "$ERR"
assert_eq "$(rec '.items[1].text')" "$ITEM2" "an item's formatted block is preserved verbatim, multi-line" "$ERR"
assert_eq "$([[ -e "$WT/.git/kendex" ]] && echo yes || echo no)" "no" "nothing is written outside the worktree"
run_write --worktree "$WT" --issue issue-1230 --round-id "$RID" --item 1 "$ITEM1" "$REACH1" --item 2 "$ITEM2" "$REACH2" --adds "$ADDS"
assert_eq "$(observe "rc=0 out=$FIRST [.items[].n]|tojson=[1,2]")" "rc=0 out=$FIRST [.items[].n]|tojson=[1,2]" "an identical re-invocation is idempotent: same path, record unchanged" "$ERR"
run_write --worktree "$WT" --issue issue-1230 --round-id "$RID" --item 3 replacement "$OK_REACH"
OUT="$FIRST"
assert_eq "$(observe "rc=2 [.items[].n]|tojson=[1,2]")" "rc=2 [.items[].n]|tojson=[1,2]" "a different set under the same round id is refused and the original stands" "$ERR"
run_write --worktree "$WT" --issue issue-1230 --round-id 2-2 --item 1 "next round" "$OK_REACH"
assert_eq "$([[ "$OUT" != "$FIRST" && -f "$FIRST" && -f "$OUT" ]] && echo yes || echo no)" "yes" "a new round id writes a distinct record without clobbering the prior round's"

echo "=== --items-file: the harness-safe route for shell-hostile item text ==="
# Real review blocks carry backticks and quotes, which Codex rejects in a
# command even single-quoted, so the orchestrator writes the JSON with the
# harness file tool and passes one path. Each row writes its own file and
# takes its own round id.
ITEMS="$TMP_ROOT/items.json"
# `label^items json^round^expect` (the separator is ^ so item text and jq
# paths may carry a pipe).
items_rows=(
  'the file item numbers are recorded and each element is n, text, reach^[{"n":1,"text":"#1 | fix `parse()` — do not touch '"'"'raw'"'"' mode","reach":"parse() on a config a shipped writer emits"},{"n":4,"text":"#4 | second item","reach":"tools/guard on a staged render"}]^3-3^rc=0 [.items[].n]|tojson=[1,4] .items[0]|keys_unsorted|tojson=["n","text","reach"]'
  'extra keys in an element are dropped^[{"n":1,"text":"t","reach":"tools/guard on a staged render","extra":"x"}]^4-4^rc=0 .items[0]|keys_unsorted|tojson=["n","text","reach"]'
  'an unparseable file^not json^5-1^rc=2'
  'a non-array top level^{"n":1,"text":"t","reach":"tools/guard on a staged render"}^5-2^rc=2'
  'an empty array^[]^5-3^rc=2'
  'an element without text^[{"n":1,"reach":"tools/guard on a staged render"}]^5-4^rc=2'
  'a non-integer n^[{"n":1.5,"text":"t","reach":"tools/guard on a staged render"}]^5-5^rc=2'
  'a negative n^[{"n":-1,"text":"t","reach":"tools/guard on a staged render"}]^5-6^rc=2'
  'a duplicate n: a set, not a list^[{"n":1,"text":"a","reach":"tools/guard on a staged render"},{"n":1,"text":"b","reach":"tools/guard on a staged render"}]^5-7^rc=2'
  'whitespace-only text^[{"n":1,"text":"   ","reach":"tools/guard on a staged render"}]^5-8^rc=2'
  'an element without reach^[{"n":1,"text":"t"}]^62-1^rc=2'
  'an element with a whitespace-only reach^[{"n":1,"text":"t","reach":"   "}]^62-2^rc=2'
  'an element whose reach is only a review thread^[{"n":1,"text":"t","reach":"Copilot thread"}]^62-3^rc=2'
)
for row in "${items_rows[@]}"; do
  IFS='^' read -r label json rid expect <<<"$row"
  [[ -n "$expect" ]] || { printf 'items: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
  printf '%s' "$json" > "$ITEMS"
  run_write --worktree "$WT" --issue i --round-id "$rid" --items-file "$ITEMS"
  assert_eq "$(observe "$expect")" "$expect" "--items-file: $label" "$ERR"
done
assert_eq "$(jq -r '.items[0].text' "$WT/tmp/dev-round-i-3-3.json")" '#1 | fix `parse()` — do not touch '"'"'raw'"'"' mode' "--items-file preserves backticks, quotes and pipes in item text verbatim"
printf '%s' '[{"n":1,"text":"t","reach":"tools/guard on a staged render"}]' > "$ITEMS"
run_write --worktree "$WT" --issue i --round-id 5-9 --items-file "$ITEMS" --item 1 t "$OK_REACH"
assert_eq "$(observe "rc=2")" "rc=2" "--items-file with --item is refused: one item source" "$ERR"
run_write --worktree "$WT" --issue i --round-id 5-10 --items-file "$TMP_ROOT/nope.json"
assert_eq "$(observe "rc=2")" "rc=2" "--items-file with a nonexistent path is refused" "$ERR"

echo "=== the reach bar: an item names the producer that reaches the finding ==="
# A fix round that answers a review thread rather than a producer patches a
# shape a bot typed as if a user had reached it: no reach, an empty one, or
# one on the refusal list is a `Declined:` reply, and writes nothing. Each row
# takes its own round id so an accepted write cannot shadow a later refusal
# behind the immutability arm.
table \
  "no reach at all|--worktree $WT --issue i --round-id 60-1 --item 1 text|rc=2" \
  "an empty reach|--worktree $WT --issue i --round-id 60-2 --item 1 text EMPTY|rc=2" \
  "a whitespace-only reach|--worktree $WT --issue i --round-id 60-3 --item 1 text SPACES|rc=2" \
  "a reach naming only a review thread|--worktree $WT --issue i --round-id 60-4 --item 1 text Copilot+thread|rc=2" \
  "a reach naming a review-thread node id|--worktree $WT --issue i --round-id 60-5 --item 1 text PRRT_kwDOAbc123|rc=2"
assert_eq "$(find "$WT/tmp" -maxdepth 1 -name 'dev-round-i-60-*.json' | wc -l | tr -d ' ')" "0" "a refused reach writes no record"
run_write --worktree "$WT" --issue issue-1230 --round-id 61-61 --item 1 text "kendex refresh in a linked worktree"
E='rc=0 .items[0]|keys_unsorted|tojson=["n","text","reach"]'
assert_eq "$(observe "$E") reach=$(rec .items[0].reach)" "$E reach=kendex refresh in a linked worktree" "a reach naming a command a person runs is accepted and recorded verbatim beside n and text" "$ERR"
# Control: with check_reach neutered the same value is accepted, so the
# refusals above come from the live check and not another arm. The mutation is
# asserted to have landed before the run that depends on it.
REACH_MUTANT="$(copy_scripts reach-mutant)/dev-round-write"
awk '{ print } /^check_reach\(\) \{$/ { print "  return 0  # MUTATED" }' "$WRITE_BIN" > "$REACH_MUTANT"
chmod +x "$REACH_MUTANT"
assert_eq "$(grep -Fc -- "return 0  # MUTATED" "$REACH_MUTANT")" "1" "control: the reach mutation landed in the copy"
set +e
growth_round_write "$STATE" "$REACH_MUTANT" --worktree "$WT" --issue issue-1230 --round-id 63-63 --item 1 text "Copilot thread" >/dev/null 2>&1; mutant_rc=$?
set -e
assert_eq "$mutant_rc" "0" "control: a writer whose refusal list never fires accepts the thread reach"

echo "=== usage errors exit 2 and write nothing ==="
# Every --item and --adds row takes the same round id: each fails before a
# write, so the immutability arm never stands in for the validation.
NOHEAD="$TMP_ROOT/no-head"; mkdir -p "$NOHEAD"
table \
  "no --item: an empty delegated set is not a fix round|--worktree $WT --issue i --round-id 1-1|rc=2" \
  "missing --worktree|--issue i --round-id 1-1 --item 1 t $OKR|rc=2" \
  "a nonexistent --worktree|--worktree $TMP_ROOT/nope --issue i --round-id 1-1 --item 1 t $OKR|rc=2" \
  "a worktree with no HEAD commit|--worktree $NOHEAD --issue i --round-id 1-1 --item 1 t $OKR|rc=2 stderr~dev-round-write:+missing-head+worktree=$NOHEAD=true" \
  "missing --issue|--worktree $WT --round-id 1-1 --item 1 t $OKR|rc=2" \
  "missing --round-id|--worktree $WT --issue i --item 1 t $OKR|rc=2" \
  "a path-unsafe --issue|--worktree $WT --issue a/b --round-id 1-1 --item 1 t $OKR|rc=2 stderr~dev-round-write:+invalid-id+arg1=--issue+arg2=a/b=true" \
  "a path-traversal --round-id|--worktree $WT --issue i --round-id .. --item 1 t $OKR|rc=2" \
  "a non-numeric --item N|--worktree $WT --issue i --round-id 1-1 --item x t $OKR|rc=2" \
  "a leading-zero --item N is not a canonical integer|--worktree $WT --issue i --round-id 1-1 --item 01 t $OKR|rc=2" \
  "an empty --item TEXT|--worktree $WT --issue i --round-id 1-1 --item 1 EMPTY $OKR|rc=2" \
  "a whitespace-only --item TEXT|--worktree $WT --issue i --round-id 1-1 --item 1 SPACES $OKR|rc=2" \
  "an --item TEXT that is one of the writer's own flags: a forgotten value|--worktree $WT --issue i --round-id 1-1 --item 1 --worktree $OKR|rc=2 stderr~dev-round-write:+text-flag+text=--worktree+n=1=true" \
  "--item with too few arguments|--worktree $WT --issue i --round-id 1-1 --item 1|rc=2" \
  "a duplicate item number: a set, not a list|--worktree $WT --issue i --round-id 1-1 --item 1 a $OKR --item 1 b $OKR|rc=2" \
  "a duplicate --issue: no silent last-wins|--worktree $WT --issue i --issue j --round-id 1-1 --item 1 t $OKR|rc=2 stderr~dev-round-write:+duplicate+arg1=--issue=true" \
  "an unknown argument|--worktree $WT --issue i --round-id 1-1 --item 1 t $OKR --bogus|rc=2"
assert_eq "$([[ -f "$WT/tmp/dev-round-i-1-1.json" ]] && echo yes || echo no)" "no" "failed invocations write nothing"
run_write -h
assert_eq "$(observe "rc=0")" "rc=0" "-h prints usage and exits 0" "$ERR"

echo "=== the writer refuses to place a record over a symlink ==="
# The writer half only: dev_round_gate.sh owns the reader's symlink refusal.
LINKED_MAIN="$(new_repo linked-main)"
LINKED="$TMP_ROOT/linked-wt"
git -C "$LINKED_MAIN" worktree add -q -b linked "$LINKED"
init_growth_state "$STATE" "$LINKED" issue-826 seed 1000000 >/dev/null
write_allowance "$LINKED" issue-826 '**Expected delta**: 1000000 lines, 1000000 test lines'
run_write --worktree "$LINKED" --issue issue-826 --round-id 30-30 --item 1 linked "$OK_REACH"
assert_eq "$(observe "rc=0 written=yes") main_side=$([[ -e "$LINKED_MAIN/.git/kendex" ]] && echo yes || echo no)" "rc=0 written=yes main_side=no" "a linked worktree keeps its round record in its own tmp/" "$ERR"
SYMLINK_RECORD="$LINKED/tmp/dev-round-issue-826-31-31.json"
run_write --worktree "$LINKED" --issue issue-826 --round-id 31-31 --item 1 symlink "$OK_REACH"
cp "$SYMLINK_RECORD" "$TMP_ROOT/symlink-target.json"
rm -f "$SYMLINK_RECORD"
ln -s "$TMP_ROOT/symlink-target.json" "$SYMLINK_RECORD"
run_write --worktree "$LINKED" --issue issue-826 --round-id 31-31 --item 1 symlink "$OK_REACH"
assert_eq "$(observe "rc=2")" "rc=2" "a record path that is a symlink is refused" "$ERR"
rm -f "$SYMLINK_RECORD"

echo "=== fix rounds record size without refusing ==="
GW="$(new_repo growth-wt KEN-GROWTH)"
git -C "$GW" switch -q -c growth
printf 'one\ntwo\nthree\nfour\nfive\n' > "$GW/change.txt"
mkdir -p "$GW/tests"
printf 'one\ntwo\n' > "$GW/tests/new.sh"
git -C "$GW" add change.txt tests/new.sh
git -C "$GW" commit -q -m implementation
size_rows=(
  'pass|**Expected delta**: 5 lines, 2 test lines|0|pass|5|2'
  'production|**Expected delta**: 4 lines, 2 test lines|0|over|4|2'
  'test|**Expected delta**: 5 lines, 1 test line|0|over|5|1'
  'both|**Expected delta**: 4 lines, 1 test line|0|over|4|1'
  'unsized|No size field here.|0|allowance_missing|null|null'
  'malformed|**Expected delta**: about 4 lines|3|||'
)
for row in "${size_rows[@]}"; do
  IFS='|' read -r label line code verdict allowance test_allowance <<<"$row"
  write_allowance "$GW" KEN-GROWTH "$line"
  run_write --worktree "$GW" --issue KEN-GROWTH --round-id "$label" --item 1 size "$OK_REACH"
  if [[ "$code" == 0 ]]; then
    E="rc=0 written=yes .size_check.verdict=$verdict .size_check.production_lines=5 .size_check.test_lines=2 .size_check.production_allowance=$allowance .size_check.test_allowance=$test_allowance"
  else
    E="rc=3 written=no stderr~branch-size-check:+invalid-delta+issue=KEN-GROWTH=true"
  fi
  assert_eq "$(observe "$E")" "$E" "$label records the measured verdict or reports malformed input" "$ERR"
  if [[ "$code" == 0 && "$RC" == 0 ]]; then
    assert_eq "$(rec '.size_check')" "$("$STATE" --state-dir "$GW/tmp" get KEN-GROWTH '.pr.size_check')" "$label keeps the same report in the round and workflow state"
  fi
done

# Restore a refusal for measured over and unsized results in the writer.
MUTANT_SCRIPTS="$(copy_scripts size-refusal-mutant)"
MUTANT_WRITE="$MUTANT_SCRIPTS/dev-round-write"
assert_eq "$(grep -Fc 'if (( measured != 0 )); then' "$MUTANT_WRITE")" "1" "control finds the result handler"
sed -i.bak '/^if (( measured != 0 )); then/i\
[[ "$BRANCH_ALLOWANCE_STATUS" == pass ]] || exit 3
' "$MUTANT_WRITE"
assert_eq "$([[ ! -L "$MUTANT_WRITE" ]] && ! cmp -s "$MUTANT_WRITE" "$WRITE_BIN" && echo changed)" "changed" "control changes the private writer"
LIVE_WRITE="$WRITE_BIN"
WRITE_BIN="$MUTANT_WRITE"
for row in 'over|**Expected delta**: 4 lines' 'missing|No size field.'; do
  IFS='|' read -r label line <<<"$row"
  write_allowance "$GW" KEN-GROWTH "$line"
  run_write --worktree "$GW" --issue KEN-GROWTH --round-id "control-$label" --item 1 size "$OK_REACH"
  assert_eq "$(observe 'rc=3 written=no')" 'rc=3 written=no' "control: $label refuses the report-and-continue case" "$ERR"
done
WRITE_BIN="$LIVE_WRITE"

echo "=== a pr-N key stamps its round and the checker reads it back ==="
# A pull request with no issue id keys its state pr-N (review-pr-comments.md
# § 1). No tracker holds that key, so the branch measures under
# allowance_missing and the round still stamps.
PRW="$(new_repo pr-wt)"
init_growth_state "$STATE" "$PRW" pr-51 51-1 >/dev/null
run_write --worktree "$PRW" --issue pr-51 --round-id 51-1 --item 1 "pr key round" "$OK_REACH"
E="rc=0 written=yes .issue=pr-51 .size_check.verdict=allowance_missing .size_check.production_allowance=null"
assert_eq "$(observe "$E")" "$E" "a round under a pr-N key stamps with the measured allowance_missing verdict" "$ERR"
"$RETURN_WRITE" --worktree "$PRW" --kind fix --issue pr-51 --round-id 51-1 --branch main \
  --commit "$(git -C "$PRW" rev-parse HEAD)" --validate pass --item 1 Applied done >/dev/null
set +e
"$CHECK" --worktree "$PRW" --issue pr-51 --round-id 51-1 --expect-items-from-round >/dev/null 2>&1
pr_check_rc=$?
set -e
assert_eq "$pr_check_rc" "0" "dev-artifact-check reads the pr-N round back"
run_write --worktree "$PRW" --issue pr/51 --round-id 51-2 --item 1 "outside the grammar" "$OK_REACH"
E="rc=2 stderr~dev-round-write:+invalid-id+arg1=--issue+arg2=pr/51=true"
assert_eq "$(observe "$E")" "$E" "a key outside the path-safe grammar is still refused" "$ERR"

echo "=== a record the reader cannot use fails acceptance closed ==="
# A record removed after delegation, a non-string base_sha, an empty path
# component in adds, and a whitespace path the delegation cannot express each
# refuse the check with exit 2, never a weaker gate.
record_rows=(
  'a missing record|6-6|delete'
  'a non-string base_sha|8-8|.base_sha = 42'
  'an empty path component in adds|9-9|.adds = ["tools/"]'
  'a whitespace path the delegation cannot express|10-10|.adds = ["tools/one path"]'
)
for row in "${record_rows[@]}"; do
  IFS='|' read -r label rid filter <<<"$row"
  run_write --worktree "$WT" --issue issue-1230 --round-id "$rid" --item 1 schema "$OK_REACH"
  record="$WT/tmp/dev-round-issue-1230-$rid.json"
  # The row damages a record that exists; a failed setup write would leave
  # the reader refusing an absent record for every filter alike.
  [[ "$RC" -eq 0 && -f "$record" ]] || { printf 'record row %s: the setup write failed (rc=%s)\n' "$label" "$RC" >&2; cat "$ERR" >&2; exit 1; }
  if [[ "$filter" == delete ]]; then rm -f "$record"; else jq "$filter" "$record" > "$TMP_ROOT/edited.json" && mv "$TMP_ROOT/edited.json" "$record"; fi
  set +e
  "$CHECK" --worktree "$WT" --issue issue-1230 --round-id "$rid" --expect-items-from-round >/dev/null 2>&1; rc=$?
  set -e
  assert_eq "$rc" "2" "$label fails acceptance closed"
done

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
