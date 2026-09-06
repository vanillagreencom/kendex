#!/usr/bin/env bash
# Tests for dev-artifact-check: deterministic on-disk acceptance of a dev
# agent's completion JSON artifact in the orch dev-start / dev-fix /
# review-pr-comments workflows. Identity is by per-delegation ROUND ID, not
# mtime: the check resolves WT/tmp/dev-return-ISSUE-RID.json and requires the
# internal `.round_id` to match. The workflow and schema documents this
# contract is wired through are dev-artifact-check-wiring.test.sh.
#
# One case per behaviour surface; shaped input is one table per case, one
# asserted row per shape. A row's `expect` names the fields it pins and
# `observe` reads exactly those, so a row fails on the field it names.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
CHECK="$REPO_ROOT/skills/orch/scripts/dev-artifact-check"
STATE="$REPO_ROOT/skills/orch/scripts/workflow-state"
WRITE="$REPO_ROOT/skills/orch/scripts/dev-return-write"
ROUND_WRITE_BIN="$REPO_ROOT/skills/orch/scripts/dev-round-write"
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"
# shellcheck source=lib/waiter-assertions.sh
source "$TEST_DIR/lib/waiter-assertions.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

round_write() { growth_round_write "$STATE" "$ROUND_WRITE_BIN" "$@"; }

# new_repo NAME ISSUE ROUND — a committed git repo with growth state for ISSUE
# at ROUND; prints its path. `git -C` everywhere, so a case never cds.
new_repo() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name Test
  git -C "$d" config commit.gpgsign false
  git -C "$d" commit -q --allow-empty -m base
  init_growth_state "$STATE" "$d" "$2" "${3:-seed}" ${4:+"$4"} >/dev/null
  printf '%s' "$d"
}

# --- harness -----------------------------------------------------------------

# run_check ARGS... — runs the check; OUT is its JSON, RC its exit, ERR the
# stderr file.
RUN_SEQ=0
run_check() {
  RUN="$TMP_ROOT/runs/$((++RUN_SEQ))"
  mkdir -p "$RUN"
  ERR="$RUN/stderr"
  set +e
  OUT=$("$CHECK" "$@" 2>"$ERR")
  RC=$?
  set -e
}

json() { jq -r "$1" <<<"$OUT" 2>/dev/null || echo UNPARSEABLE; }

# observe EXPECT — prints the run's value of every `name=` field EXPECT names,
# in EXPECT's order. Plain names are JSON result fields (`files` compact);
#   rc              exit status
#   help_sections   which of the routed --help sections are present: gates
#                   (the ordering line), reasons (every ok=false reason the
#                   check emits), items (the --expect-items confinement)
observe() {
  local got="" token name value
  for token in $1; do
    name="${token%%=*}"
    case "$name" in
      rc) value="$RC" ;;
      files) value="$(json '.files | tojson')" ;;
      help_sections)
        value=""
        grep -q '^Gates ordered:' <<<"$OUT" && value="$value,gates"
        for r in commit_unresolvable unapproved_additions comparison_failed classifier_failed incomplete; do grep -qF -- "$r" <<<"$OUT" || value="$value,missing:$r"; done
        grep -qF -- '--expect-items (--file mode only)' <<<"$OUT" && value="$value,items"
        value="${value#,}"; value="${value:-none}"
        ;;
      *) value="$(json ".$name")" ;;
    esac
    got="$got $name=$value"
  done
  printf '%s' "${got# }"
}

# The round-mode fixture: a non-git worktree with workflow state for one issue
# and round, and two complete receipts (an implement one, a fix one with items
# 1 and 2) every table below reshapes with jq.
WT="$TMP_ROOT/wt"
mkdir -p "$WT/tmp"
ISSUE="issue-770"
R="1750000000-4242"
ARTIFACT="$WT/tmp/dev-return-$ISSUE-$R.json"
"$STATE" --state-dir "$WT/tmp" init "$ISSUE" --worktree "$WT" --branch test >/dev/null
export ORCH_STATE_DIR="$WT/tmp"
VALID_IMPL='{"schema_version":1,"round_id":"1750000000-4242","kind":"implement","issue":"issue-770","branch":"issue-770","commit":"abc123f","baseline_lines":1,"validate":"pass","qa_labels":["needs-review"],"summary_posted":true,"summary":null,"bundled":false,"items":[]}'
VALID_FIX='{"schema_version":1,"round_id":"1750000000-4242","kind":"fix","issue":"issue-770","branch":"issue-770","commit":"def456a","validate":"FAILING: lint","summary_posted":true,"summary":null,"bundled":false,"items":[{"n":1,"decision":"Applied","reasoning":"fixed nil deref"},{"n":2,"decision":"Skipped","reasoning":"contradicts D010"}]}'
ROUND_ARGS="--worktree $WT --issue $ISSUE --round-id $R"

# receipt_table ROW... — one artifact shape, one run, one assertion per row:
# `label^base^jq^args^expect` (the separator is ^ so a jq filter may carry a
# pipe). base is impl or fix (or raw: the jq field is written verbatim, or
# none: no artifact), jq reshapes it, args are the check's (empty means round
# mode against the fixture worktree, `-` means no arguments at all).
receipt_table() {
  local row label base filter args expect
  for row in "$@"; do
    IFS='^' read -r label base filter args expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'receipt_table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    rm -f "$ARTIFACT"
    case "$base" in
      impl) printf '%s' "$VALID_IMPL" | jq -c "${filter:-.}" > "$ARTIFACT" ;;
      fix) printf '%s' "$VALID_FIX" | jq -c "${filter:-.}" > "$ARTIFACT" ;;
      raw) printf '%s' "$filter" > "$ARTIFACT" ;;
      none) ;;
      *) echo "receipt_table: unknown base $base in $row" >&2; exit 1 ;;
    esac
    [[ -n "$args" ]] || args="$ROUND_ARGS"
    [[ "$args" != "-" ]] || args=""
    # shellcheck disable=SC2086
    run_check $args
    assert_eq "$(observe "$expect")" "$expect" "$label" "$ERR"
  done
}

echo "=== round mode: identity by round id, then the scalar gates ==="
# The artifact is resolved at WT/tmp/dev-return-ISSUE-RID.json and its internal
# round_id must match; a wrong requested round is another path. Every required
# scalar is type-strict, kind is an enum, and a fix receipt without a
# delegated set to check against refuses rather than falling back.
receipt_table \
  "no artifact at the round path is missing^none^^^rc=1 ok=false path=null reason=missing" \
  "a complete implement receipt is valid at its path^impl^^^rc=0 ok=true path=$ARTIFACT reason=valid" \
  "a fix receipt with no delegated set refuses instead of a weaker rule^fix^^^rc=2" \
  "a different requested round resolves a different path^impl^^--worktree $WT --issue $ISSUE --round-id 9999-0^reason=missing" \
  "an internal round_id that differs is a copied file^impl^.round_id=\"OTHER-1\"^^reason=invalid" \
  "not JSON^raw^not json^^reason=invalid" \
  "a missing kind^impl^del(.kind)^^reason=invalid" \
  "an out-of-domain kind^impl^.kind=\"review\"^^reason=invalid" \
  "a numeric issue^impl^.issue=123^^reason=invalid" \
  "an empty branch^impl^.branch=\"\"^^reason=invalid" \
  "an array commit^impl^.commit=[\"x\"]^^reason=invalid" \
  "a boolean validate^impl^.validate=true^^reason=invalid" \
  "a missing round_id^impl^del(.round_id)^^reason=invalid" \
  "a missing schema_version^impl^del(.schema_version)^^reason=invalid" \
  "a string schema_version^impl^.schema_version=\"1\"^^reason=invalid" \
  "a bundled implement with no items is incomplete^impl^.bundled=true^^reason=incomplete" \
  "a single implement tolerates empty items^impl^^^reason=valid"

echo "=== file mode: the items gate and the exact delegated set ==="
# A fix or bundled receipt needs a non-empty, well-formed items[]; a scalar
# fault outranks an items fault; --expect-items is exact set coverage,
# order-independent, and applies the enum and reasoning rules to a matching
# set; a duplicate n does not cover a distinct set.
FILE_ARGS="--file $ARTIFACT"
receipt_table \
  "items missing^fix^del(.items)^$FILE_ARGS^reason=incomplete" \
  "items empty^fix^.items=[]^$FILE_ARGS^reason=incomplete" \
  "items not an array^fix^.items=\"nope\"^$FILE_ARGS^reason=incomplete" \
  "an item without reasoning^fix^.items=[{\"n\":1,\"decision\":\"Applied\"}]^$FILE_ARGS^reason=incomplete" \
  "an item with empty reasoning^fix^.items=[{\"n\":1,\"decision\":\"Applied\",\"reasoning\":\"\"}]^$FILE_ARGS^reason=incomplete" \
  "an out-of-enum decision^fix^.items=[{\"n\":1,\"decision\":\"Nope\",\"reasoning\":\"x\"}]^$FILE_ARGS^reason=incomplete" \
  "a non-numeric item n^fix^.items=[{\"n\":\"1\",\"decision\":\"Applied\",\"reasoning\":\"x\"}]^$FILE_ARGS^reason=incomplete" \
  "an invalid scalar beats incomplete items^fix^del(.commit) | .items=[]^$FILE_ARGS^reason=invalid" \
  "expect 1,2 matches exactly^fix^^$FILE_ARGS --expect-items 1,2^reason=valid" \
  "expect 2,1 is order-independent^fix^^$FILE_ARGS --expect-items 2,1^reason=valid" \
  "expect 1,2,3 with 3 missing^fix^^$FILE_ARGS --expect-items 1,2,3^reason=incomplete" \
  "expect 1 with an extra 2 present^fix^^$FILE_ARGS --expect-items 1^reason=incomplete" \
  "a duplicate n=1 does not cover {1,2}^fix^.items=[{\"n\":1,\"decision\":\"Applied\",\"reasoning\":\"a\"},{\"n\":1,\"decision\":\"Skipped\",\"reasoning\":\"b\"}]^$FILE_ARGS --expect-items 1,2^reason=incomplete" \
  "expect-items rejects an empty reasoning on a matching set^fix^.items=[{\"n\":1,\"decision\":\"Applied\",\"reasoning\":\"\"},{\"n\":2,\"decision\":\"Skipped\",\"reasoning\":\"b\"}]^$FILE_ARGS --expect-items 1,2^reason=incomplete" \
  "expect-items rejects an out-of-enum decision on a matching set^fix^.items=[{\"n\":1,\"decision\":\"Nope\",\"reasoning\":\"a\"},{\"n\":2,\"decision\":\"Skipped\",\"reasoning\":\"b\"}]^$FILE_ARGS --expect-items 1,2^reason=incomplete" \
  "a valid implement at an explicit path^impl^^$FILE_ARGS^rc=0 reason=valid" \
  "a matching --round-id in file mode^impl^^$FILE_ARGS --round-id $R^reason=valid" \
  "a mismatched --round-id in file mode^impl^^$FILE_ARGS --round-id NOPE-1^reason=invalid" \
  "a missing file^none^^--file $WT/tmp/nope.json^rc=1 reason=missing"

echo "=== usage errors end in the parser ==="
receipt_table \
  "a bare positional call^impl^^$WT $ISSUE 1750000000^rc=2" \
  "round mode without --round-id^impl^^--worktree $WT --issue $ISSUE^rc=2" \
  "round mode without --worktree^impl^^--issue $ISSUE --round-id $R^rc=2" \
  "a path-unsafe --issue^impl^^--worktree $WT --issue a/b --round-id $R^rc=2" \
  "a path-traversal --issue^impl^^--worktree $WT --issue .. --round-id $R^rc=2" \
  "a path-traversal --round-id^impl^^--worktree $WT --issue $ISSUE --round-id ..^rc=2" \
  "a malformed --expect-items^fix^^$FILE_ARGS --expect-items 1,x^rc=2" \
  "a nonexistent worktree^impl^^--worktree $TMP_ROOT/does-not-exist --issue $ISSUE --round-id $R^rc=2" \
  "--file with no path^impl^^--file^rc=2" \
  "an unknown argument^impl^^$ROUND_ARGS --bogus^rc=2" \
  "no mode at all^impl^^-^rc=2" \
  "-h prints usage^impl^^-h^rc=0" \
  "--help is the routed contract: gate order, every ok=false reason, the item-list confinement^impl^^--help^rc=0 help_sections=gates,items" \
  "a non-integer --wait^impl^^$FILE_ARGS --wait nope^rc=2" \
  "a zero --interval^impl^^$FILE_ARGS --wait 5 --interval 0^rc=2"

echo "=== the writers round-trip and the persisted round record is the delegated set ==="
# dev-return-write's output validates in round mode and file mode; with
# --expect-items-from-round the delegated set comes from the record
# dev-round-write persisted, the record is not consumed by a check, and a
# record that is missing, another round's, another issue's, malformed or
# empty means the set cannot be established: exit 2, never a weaker gate.
RT="$(new_repo rt issue-9 5-6)"
RT_HEAD="$(git -C "$RT" rev-parse HEAD)"
rt_impl="$("$WRITE" --worktree "$RT" --kind implement --issue issue-9 --round-id 5-6 --branch b --commit "$RT_HEAD" --validate pass)"
assert_eq "$([[ -f "$rt_impl" ]] && echo yes || echo no)" "yes" "the writer produced the round-scoped implement artifact"
ORCH_STATE_DIR="$RT/tmp" run_check --worktree "$RT" --issue issue-9 --round-id 5-6
assert_eq "$(observe "reason=valid")" "reason=valid" "the writer's implement output round-trips as valid" "$ERR"
assert_eq "$("$STATE" --state-dir "$RT/tmp" get issue-9 .pr.baseline_lines)" "1" "the baseline has one authoritative workflow-state value"
"$WRITE" --worktree "$RT" --kind fix --issue issue-9 --round-id 7-8 --branch b --commit c --validate pass --item 1 Applied a --item 2 Skipped b >/dev/null
run_check --file "$RT/tmp/dev-return-issue-9-7-8.json" --expect-items 1,2
assert_eq "$(observe "reason=valid")" "reason=valid" "the writer's fix output round-trips through file-mode --expect-items" "$ERR"

RR="$(new_repo rr issue-9 seed 1000000)"
RR_HEAD="$(git -C "$RR" rev-parse HEAD)"
round_write --worktree "$RR" --issue issue-9 --round-id 7-8 \
  --item 1 "fix nil deref" "src/parse.rs on a config a shipped writer emits" --item 2 "cover expiry" "tests/auth.rs expiry case" >/dev/null
"$WRITE" --worktree "$RR" --kind fix --issue issue-9 --round-id 7-8 --branch b --commit "$RR_HEAD" --validate pass --item 1 Applied a --item 2 Skipped b >/dev/null
run_check --worktree "$RR" --issue issue-9 --round-id 7-8 --expect-items-from-round
assert_eq "$(observe "reason=valid")" "reason=valid" "an artifact covering the persisted round set is valid" "$ERR"
run_check --worktree "$RR" --issue issue-9 --round-id 7-8 --expect-items-from-round
assert_eq "$(observe "reason=valid")" "reason=valid" "the record is not consumed: a repeat check stays valid" "$ERR"
"$WRITE" --worktree "$RR" --kind fix --issue issue-9 --round-id 8-9 --branch b --commit "$RR_HEAD" --validate pass --item 1 Applied a >/dev/null
round_write --worktree "$RR" --issue issue-9 --round-id 8-9 \
  --item 1 "fix nil deref" "src/parse.rs on a config a shipped writer emits" --item 2 "cover expiry" "tests/auth.rs expiry case" >/dev/null
run_check --worktree "$RR" --issue issue-9 --round-id 8-9 --expect-items-from-round
assert_eq "$(observe "reason=incomplete")" "reason=incomplete" "an artifact missing a persisted delegated item is incomplete" "$ERR"
run_check --worktree "$RR" --issue issue-9 --round-id 9-9 --expect-items-from-round
assert_eq "$(observe "rc=2")" "rc=2" "no round record: the set cannot be established" "$ERR"
# Round records that prove nothing about the set: `label|round|record json`.
record_rows=(
  "another round's record|10-10|{schema_version:2,round_id:\"OTHER-1\",issue:\"issue-9\",base_sha:\$base,adds:[],items:[{n:1,text:\"t\"}]}"
  "an empty item set|11-11|{schema_version:2,round_id:\"11-11\",issue:\"issue-9\",base_sha:\$base,adds:[],items:[]}"
  "an unparseable record|12-12|not json"
  "another issue's record|13-13|{schema_version:2,round_id:\"13-13\",issue:\"issue-OTHER\",base_sha:\$base,adds:[],items:[{n:1,text:\"t\"}]}"
  "a record missing schema_version|14-14|{round_id:\"14-14\",issue:\"issue-9\",base_sha:\$base,adds:[],items:[{n:1,text:\"t\"}]}"
  "an empty item text|15-15|{schema_version:2,round_id:\"15-15\",issue:\"issue-9\",base_sha:\$base,adds:[],items:[{n:1,text:\"\"}]}"
)
for row in "${record_rows[@]}"; do
  IFS='|' read -r label rid record <<<"$row"
  if [[ "$record" == "not json" ]]; then printf 'not json' > "$RR/tmp/dev-round-issue-9-$rid.json"
  else jq -n --arg base "$RR_HEAD" "$record" > "$RR/tmp/dev-round-issue-9-$rid.json"; fi
  run_check --worktree "$RR" --issue issue-9 --round-id "$rid" --expect-items-from-round
  assert_eq "$(observe "rc=2")" "rc=2" "$label refuses to establish the set" "$ERR"
done
# The count-vs-set hint diagnoses a TYPED --expect-items count; a set read from
# the record cannot be that misuse, so the from-round path never emits it even
# when the shapes coincide (the inline form is the control).
"$WRITE" --worktree "$RR" --kind fix --issue issue-9 --round-id 16-16 --branch b --commit "$RR_HEAD" --validate pass --item 1 Applied a --item 2 Applied b --item 3 Applied c >/dev/null
run_check --file "$RR/tmp/dev-return-issue-9-16-16.json" --expect-items 3
assert_eq "$([[ "$(json .hint)" != null ]] && echo fires || echo silent)" "fires" "control: file-mode --expect-items 3 against items 1..3 fires the count-vs-set hint" "$ERR"
round_write --worktree "$RR" --issue issue-9 --round-id 16-16 --item 3 "only item three" "tools/guard on a staged render" >/dev/null
run_check --worktree "$RR" --issue issue-9 --round-id 16-16 --expect-items-from-round
assert_eq "$(observe "reason=incomplete hint=null")" "reason=incomplete hint=null" "from-round never emits the hint and still reports incomplete" "$ERR"
run_check --worktree "$RR" --issue issue-9 --round-id 7-8 --expect-items 1,2
assert_eq "$(observe "rc=2")" "rc=2" "round mode refuses the weaker --expect-items list" "$ERR"
run_check --file "$RR/tmp/dev-return-issue-9-7-8.json" --expect-items-from-round
assert_eq "$(observe "rc=2")" "rc=2" "file mode has no record to read from" "$ERR"

echo "=== a fix round cannot add unlisted machinery ==="
# Every protected-path addition the round's record did not name refuses the
# round with its files; additions the record names pass; a move is not an
# addition; a probe git cannot run is its own refusal, and a copy of the
# check that misroutes it reports the misroute.
AD="$(new_repo adds issue-826 seed 1000000)"
round_write --worktree "$AD" --issue issue-826 --round-id 1-1 --item 1 "fix finding" "tools/guard on a staged render" >/dev/null
mkdir -p "$AD/.agents/skills/orch/scripts" "$AD/crates/new-parser" "$AD/helpers" "$AD/pkg/test_helpers" \
  "$AD/skills/orch/scripts" "$AD/src" "$AD/test/support" "$AD/tools" "$AD/ui/src/test"
newline_path=$'tools/new\nline'
for f in .agents/skills/orch/scripts/installed-check crates/new-parser/lib.rs helpers/root-helper.ts pkg/test_helpers/nested.ts \
  skills/orch/scripts/new-check src/test_utils.rs test/support/root-support.sh tools/new-tool "$newline_path" ui/src/test/round-helper.ts; do
  printf 'added\n' > "$AD/$f"
  git -C "$AD" add "$f"
done
git -C "$AD" commit -q -m additions
"$WRITE" --worktree "$AD" --kind fix --issue issue-826 --round-id 1-1 --branch b --commit "$(git -C "$AD" rev-parse HEAD)" --validate pass --item 1 Applied done >/dev/null
run_check --worktree "$AD" --issue issue-826 --round-id 1-1 --expect-items-from-round
ADDS_EXPECT="rc=1 ok=false verdict=retry path=$AD/tmp/dev-return-issue-826-1-1.json reason=unapproved_additions files=[\".agents/skills/orch/scripts/installed-check\",\"crates/new-parser/lib.rs\",\"helpers/root-helper.ts\",\"pkg/test_helpers/nested.ts\",\"skills/orch/scripts/new-check\",\"src/test_utils.rs\",\"test/support/root-support.sh\",\"tools/new\\nline\",\"tools/new-tool\",\"ui/src/test/round-helper.ts\"]"
assert_eq "$(observe "$ADDS_EXPECT")" "$ADDS_EXPECT" "unlisted protected additions refuse the round, route to retry and name every file" "$ERR"

round_write --worktree "$AD" --issue issue-826 --round-id 2-2 --item 1 "fix finding" "tools/guard on a staged render" \
  --adds "crates/allowed/lib.rs skills/orch/scripts/allowed-check tools/allowed;still-data ui/src/test/allowed-helper.ts" >/dev/null
mkdir -p "$AD/crates/allowed"
for f in crates/allowed/lib.rs skills/orch/scripts/allowed-check "tools/allowed;still-data" ui/src/test/allowed-helper.ts; do
  printf 'allowed\n' > "$AD/$f"
  git -C "$AD" add "$f"
done
git -C "$AD" commit -q -m allowed-additions
"$WRITE" --worktree "$AD" --kind fix --issue issue-826 --round-id 2-2 --branch b --commit "$(git -C "$AD" rev-parse HEAD)" --validate pass --item 1 Applied done >/dev/null
run_check --worktree "$AD" --issue issue-826 --round-id 2-2 --expect-items-from-round
assert_eq "$(observe "reason=valid")" "reason=valid" "each addition the round named is accepted" "$ERR"

printf 'move me\n' > "$AD/ordinary.txt"
git -C "$AD" add ordinary.txt
git -C "$AD" commit -q -m pre-move
round_write --worktree "$AD" --issue issue-826 --round-id 3-3 --item 1 "move existing file" "tools/guard on a staged render" >/dev/null
git -C "$AD" mv ordinary.txt tools/moved.txt
git -C "$AD" commit -q -m move
"$WRITE" --worktree "$AD" --kind fix --issue issue-826 --round-id 3-3 --branch b --commit "$(git -C "$AD" rev-parse HEAD)" --validate pass --item 1 Applied done >/dev/null
run_check --worktree "$AD" --issue issue-826 --round-id 3-3 --expect-items-from-round
assert_eq "$(observe "reason=valid")" "reason=valid" "a moved file is not an addition" "$ERR"

# A probe git cannot run is its own refusal, never a file list: the shim fails
# every `git diff`, on the live-base round above so the probe is reached.
GIT_SHIM="$TMP_ROOT/git-shim"
mkdir -p "$GIT_SHIM"
cat > "$GIT_SHIM/git" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  [[ "$arg" == "diff" ]] && exit 42
done
exec "$REAL_GIT" "$@"
EOF
chmod +x "$GIT_SHIM/git"
REAL_GIT="$(command -v git)"
REAL_GIT="$REAL_GIT" PATH="$GIT_SHIM:$PATH" run_check --worktree "$AD" --issue issue-826 --round-id 3-3 --expect-items-from-round
assert_eq "$(observe "rc=1 reason=comparison_failed")" "rc=1 reason=comparison_failed" "a failed snapshot probe refuses acceptance with its own reason" "$ERR"
# Control: a copy of the check that misroutes the failure reports the misroute;
# the copy takes the whole scripts directory because the check sources a lib.
MUTANT_SCRIPTS="$TMP_ROOT/mutant-scripts"
mkdir -p "$MUTANT_SCRIPTS"
cp -R "$REPO_ROOT/skills/orch/scripts" "$MUTANT_SCRIPTS/"
ROUTING_MUTANT="$MUTANT_SCRIPTS/scripts/dev-artifact-check"
sed -i.bak 's/emit false "$file" "comparison_failed"/emit false "$file" "unapproved_additions"/' "$ROUTING_MUTANT"
chmod +x "$ROUTING_MUTANT"
set +e
OUT="$(REAL_GIT="$REAL_GIT" PATH="$GIT_SHIM:$PATH" "$ROUTING_MUTANT" --worktree "$AD" --issue issue-826 --round-id 3-3 --expect-items-from-round 2>/dev/null)"; RC=$?
set -e
assert_eq "$(observe "reason=unapproved_additions")" "reason=unapproved_additions" "control: the routing mutant reports the reason its mutation names"

echo "=== a rebase stops the gate rather than misattributing to it ==="
# base_sha still resolves after a restack, so comparing against it would read
# the base branch's whole advance as this round's additions: refused, naming
# nothing. A round delegated after the restack has a live base and is gated.
RB="$(new_repo rebase issue-944 seed 1000000)"
git -C "$RB" checkout -q -b feature
printf 'branch work\n' > "$RB/branch.md"
git -C "$RB" add branch.md
git -C "$RB" commit -q -m branch-work
round_write --worktree "$RB" --issue issue-944 --round-id 1-1 --item 1 "fix finding" "tools/guard on a staged render" >/dev/null
git -C "$RB" checkout -q main
mkdir -p "$RB/crates/upstream"
printf 'upstream\n' > "$RB/crates/upstream/lib.rs"
git -C "$RB" add crates/upstream/lib.rs
git -C "$RB" commit -q -m upstream-advance
git -C "$RB" checkout -q feature
git -C "$RB" rebase -q main >/dev/null
"$WRITE" --worktree "$RB" --kind fix --issue issue-944 --round-id 1-1 --branch feature --commit "$(git -C "$RB" rev-parse HEAD)" --validate pass --item 1 Applied done >/dev/null
run_check --worktree "$RB" --issue issue-944 --round-id 1-1 --expect-items-from-round
assert_eq "$(observe "ok=false verdict=retry reason=additions_unattributable files=[]")" "ok=false verdict=retry reason=additions_unattributable files=[]" "an orphaned base refuses the round and names no file" "$ERR"
# Control: without the stop the round is billed the file main merged, which
# also proves the fixture orphans that base.
STOP_MUTANT="$MUTANT_SCRIPTS/scripts/dev-artifact-check"
cp "$CHECK" "$STOP_MUTANT"
assert_eq "$(grep -cF 'if ! git -C "$repo" merge-base --is-ancestor "$base_sha" HEAD >/dev/null 2>&1; then' "$STOP_MUTANT")" "1" "control finds exactly one orphaned-base stop to remove"
sed -i.bak 's/if ! git -C "\$repo" merge-base --is-ancestor "\$base_sha" HEAD >\/dev\/null 2>&1; then/if false; then/' "$STOP_MUTANT"
chmod +x "$STOP_MUTANT"
set +e
OUT="$("$STOP_MUTANT" --worktree "$RB" --issue issue-944 --round-id 1-1 --expect-items-from-round 2>/dev/null)"; RC=$?
set -e
assert_eq "$(observe 'files=["crates/upstream/lib.rs"]')" 'files=["crates/upstream/lib.rs"]' "control: without the stop the round is billed main's addition"
round_write --worktree "$RB" --issue issue-944 --round-id 2-2 --item 1 "fix finding" "tools/guard on a staged render" >/dev/null
mkdir -p "$RB/tools"
printf 'round machinery\n' > "$RB/tools/round-tool"
git -C "$RB" add tools/round-tool
git -C "$RB" commit -q -m round-addition
"$WRITE" --worktree "$RB" --kind fix --issue issue-944 --round-id 2-2 --branch feature --commit "$(git -C "$RB" rev-parse HEAD)" --validate pass --item 1 Applied done >/dev/null
run_check --worktree "$RB" --issue issue-944 --round-id 2-2 --expect-items-from-round
assert_eq "$(observe 'reason=unapproved_additions files=["tools/round-tool"]')" 'reason=unapproved_additions files=["tools/round-tool"]' "a round whose base survived the restack is gated on its own addition alone" "$ERR"

echo "=== the recorded commit must name a real object in the worktree's repo ==="
# A fabricated sha is commit_unresolvable; an orphaned-but-real one is valid
# with a warning; the scalar gate outranks the commit gates, which outrank
# incomplete items; a non-git worktree and file mode skip the commit gates.
GW="$TMP_ROOT/gitwt"
mkdir -p "$GW/tmp"
git -C "$GW" init -q -b main
git -C "$GW" config user.email test@example.com
git -C "$GW" config user.name Test
git -C "$GW" config commit.gpgsign false
git -C "$GW" commit -q --allow-empty -m base
git -C "$GW" commit -q --allow-empty -m orphan-me
ORPHAN_SHA="$(git -C "$GW" rev-parse HEAD)"
git -C "$GW" reset -q --hard HEAD~1
HEAD_SHA="$(git -C "$GW" rev-parse HEAD)"
FAKE_SHA="${HEAD_SHA:0:8}00000000000000000000000000000000"
GART="$GW/tmp/dev-return-$ISSUE-$R.json"
# `label^jq on the implement receipt^args^expect`
commit_rows=(
  "a reachable HEAD commit^.commit=\"$HEAD_SHA\"^--worktree $GW --issue $ISSUE --round-id $R^rc=0 reason=valid warning=null"
  "a fabricated sha^.commit=\"$FAKE_SHA\"^--worktree $GW --issue $ISSUE --round-id $R^rc=1 ok=false reason=commit_unresolvable"
  "an orphaned but real commit is valid with a warning^.commit=\"$ORPHAN_SHA\"^--worktree $GW --issue $ISSUE --round-id $R^rc=0 ok=true reason=valid warning=commit_unreachable"
  "a missing commit is the scalar gate first^del(.commit)^--worktree $GW --issue $ISSUE --round-id $R^reason=invalid"
  "commit_unresolvable beats bundled incompleteness^.commit=\"$FAKE_SHA\" | .bundled=true | .items=[]^--worktree $GW --issue $ISSUE --round-id $R^reason=commit_unresolvable"
  "file mode skips the commit gates^.commit=\"$FAKE_SHA\"^--file $GART^reason=valid"
)
for row in "${commit_rows[@]}"; do
  IFS='^' read -r label filter args expect <<<"$row"
  printf '%s' "$VALID_IMPL" | jq -c "$filter" > "$GART"
  # shellcheck disable=SC2086
  run_check $args
  assert_eq "$(observe "$expect")" "$expect" "$label" "$ERR"
done
receipt_table \
  "a non-git worktree skips the commit gates^impl^^^reason=valid warning=null"

echo "=== the validation note reaches the orchestrator ==="
# The check's output is what orch accepts on, so a qualifier stored in the
# artifact is echoed; the note is optional beside the required verdict, and a
# wrong-typed or empty note is a malformed receipt.
NOTE="80/80-on-rerun,first-run-flaked-on-release-tests"
receipt_table \
  "a validate_note is echoed with the verdict^impl^.validate_note=\"$NOTE\"^$FILE_ARGS^reason=valid validate=pass validate_note=$NOTE" \
  "no validate_note key is still valid and reports null^impl^^$FILE_ARGS^reason=valid validate_note=null" \
  "an empty validate_note is invalid^impl^.validate_note=\"\"^$FILE_ARGS^reason=invalid" \
  "a numeric validate_note is invalid^impl^.validate_note=42^$FILE_ARGS^reason=invalid" \
  "a boolean validate_note is invalid^impl^.validate_note=true^$FILE_ARGS^reason=invalid" \
  "an array validate_note is invalid^impl^.validate_note=[]^$FILE_ARGS^reason=invalid" \
  "a missing artifact reports null qualifiers^none^^--file $WT/tmp/nope.json^validate=null validate_note=null"

echo "=== --wait blocks until an artifact lands or the deadline ==="
# An (invalid) receipt landing after about two seconds ends a 20-second wait
# with that artifact's verdict, so closure never depends on a message; no
# artifact at the deadline is verdict wait, exit 1, the deadline honoured.
WAITD="$TMP_ROOT/waitwt"
mkdir -p "$WAITD"
start_epoch="$(date +%s)"
( sleep 2; printf '{"bad":true}' > "$WAITD/landing.json" ) &
writer_pid=$!
run_check --file "$WAITD/landing.json" --wait 20 --interval 1
wait "$writer_pid" 2>/dev/null || true
elapsed=$(( $(date +%s) - start_epoch ))
assert_eq "$(observe "verdict=retry") early=$([[ "$elapsed" -lt 15 ]] && echo true || echo false)" "verdict=retry early=true" "--wait returns the landed artifact's verdict before the deadline (${elapsed}s)" "$ERR"
start_epoch="$(date +%s)"
run_check --file "$WAITD/never.json" --wait 2 --interval 1
elapsed=$(( $(date +%s) - start_epoch ))
assert_eq "$(observe "rc=1 verdict=wait") held=$([[ "$elapsed" -ge 2 ]] && echo true || echo false)" "rc=1 verdict=wait held=true" "--wait holds to its deadline and returns verdict wait (${elapsed}s)" "$ERR"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
