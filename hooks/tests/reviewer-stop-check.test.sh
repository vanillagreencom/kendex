#!/usr/bin/env bash
# Tests for the reviewer-stop-check hook.
#
# The hook blocks a reviewer subagent's stop once when the worktree its
# transcript names through the artifact path holds paths the review left
# behind, when that artifact is absent or not JSON, or when the transcript
# names no artifact path at all. Pinned here: which payload field
# names the subagent's transcript, what names the worktree (the newest
# <dir>/tmp/review-*.json mention, in a Write call or a File: line), what
# counts as dirty (an attributed tracked edit, an untracked file, one inside
# an untracked directory), that untracked dirt before the transcript's first
# timestamp is the author's, the once-per-agent marker under the
# reviewed repository's git common dir, that a sibling worktree's dirt is
# not this worktree's, and the fail-closed edges — an unreadable payload,
# a transcript that cannot be read, a git that cannot answer, an agent_id not
# spelled in the alphabet the harness names subagents in.
#
# Fixtures are throwaway git repositories built under a HOME of their own.
#
# Every refusal opens with `reviewer-stop-check: <key>=<value>`, and that line
# is the contract: each condition is pinned by its key and value beside the
# exit status. The paths git status names, and git's own words when it could
# not answer, are pinned as themselves under it.
#
# HOOK_UNDER_TEST overrides the script under test so the must-fail controls
# (a no-op hook, an always-block hook) can be run against these same
# assertions.
set -euo pipefail
export MSYS=winsymlinks:nativestrict

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which take precedence over `git -C` and
# would point the fixtures' git at the real repository.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/reviewer-stop-check.sh}"

PASS=0
FAIL=0
# Physical, not as mktemp spelled it: git reports a canonical
# --show-toplevel, so on a host whose temp root is a symlink (macOS, where
# /var is /private/var) a logical fixture path would never equal the value the
# hook prints.
TMP_ROOT="$(mktemp -d)" || { echo "reviewer-stop-check: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "reviewer-stop-check: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "reviewer-stop-check: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
BASH_BIN="$(command -v bash)"
ERR_FILE="$TMP_ROOT/stderr"
# The hook runs from a directory that is not a repository, as a session
# elsewhere would: the reviewed worktree comes from the transcript alone.
RUN_DIR="$TMP_ROOT/cwd"
mkdir -p "$RUN_DIR"

fgit() {
  env HOME="$TMP_ROOT" git "$@"
}

new_repo() {
  local repo="$TMP_ROOT/repo.$1"
  mkdir -p "$repo/src"
  fgit init -q "$repo"
  fgit -C "$repo" config user.email t@example.com
  fgit -C "$repo" config user.name t
  fgit -C "$repo" config gc.auto 0
  fgit -C "$repo" config maintenance.auto false
  printf 'pub fn a() {}\n' >"$repo/src/lib.rs"
  printf 'tmp/\n' >"$repo/.gitignore"
  fgit -C "$repo" add -A
  fgit -C "$repo" commit -q -m init
  printf '%s' "$repo"
}

# A transcript naming REPO's artifact the way the harness records a Write
# call and the return message: JSON lines, the path inside a JSON string. The
# artifact is written as the Write call would have. Its first entry carries no
# timestamp, so the review's start is unknown and every untracked path counts.
transcript_for() { # REPO [AGENT] -> path
  local repo="$1" agent="${2:-reviewer-test}" t="$TMP_ROOT/transcript.$$.$RANDOM.jsonl"
  mkdir -p "$repo/tmp"
  printf '{}\n' >"$repo/tmp/review-$agent-20260903-101010.json"
  {
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s/tmp/review-%s-20260903-101010.json","content":"{}"}}]}}\n' "$repo" "$agent"
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":"Verdict: pass\\nFile: %s/tmp/review-%s-20260903-101010.json\\n"}]}}\n' "$repo" "$agent"
  } >"$t"
  printf '%s' "$t"
}

# Claude Code records the calling assistant and its tool result separately.
edit_in() { # TRANSCRIPT PATH [TOOL] [ERROR] [RESULT_ID]
  jq -nc --arg path "$2" --arg tool "${3:-Edit}" \
    '{type:"assistant",message:{content:[{type:"tool_use",id:"edit-1",name:$tool,input:{file_path:$path}}]}}' >>"$1"
  jq -nc --argjson error "${4:-false}" --arg id "${5:-edit-1}" \
    '{type:"user",message:{content:[{type:"tool_result",tool_use_id:$id,is_error:$error,content:"result"}]}}' >>"$1"
}

# run TRANSCRIPT [AGENT_TYPE] [AGENT_ID] [ACTIVE] -> rc, stderr in $err
run_hook() {
  local transcript="$1" agent="${2:-reviewer-test}" id="${3:-a1}" active="${4:-false}"
  set +e
  ( cd "$RUN_DIR" && env HOME="$TMP_ROOT" "$BASH_BIN" "$HOOK" \
    <<<"{\"session_id\":\"s1\",\"hook_event_name\":\"SubagentStop\",\"agent_type\":\"$agent\",\"agent_id\":\"$id\",\"transcript_path\":\"$transcript\",\"stop_hook_active\":$active}" ) \
    >/dev/null 2>"$TMP_ROOT/stderr"
  rc=$?
  set -e
  err="$(cat "$TMP_ROOT/stderr")"
}

run_payload() { # raw-json [PATH] -> rc, stderr in $err
  set +e
  if [ -n "${2:-}" ]; then
    ( cd "$RUN_DIR" && printf '%s' "$1" | env -i HOME="$TMP_ROOT" PWD="$RUN_DIR" PATH="$2" "$BASH_BIN" "$HOOK" ) \
      >/dev/null 2>"$TMP_ROOT/stderr"
  else
    ( cd "$RUN_DIR" && printf '%s' "$1" | env HOME="$TMP_ROOT" "$BASH_BIN" "$HOOK" ) \
      >/dev/null 2>"$TMP_ROOT/stderr"
  fi
  rc=$?
  set -e
  err="$(cat "$TMP_ROOT/stderr")"
}

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

assert_contains() {
  local got="$1" needle="$2" name="$3"
  if [[ "$got" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected to contain: %s\n        got:      %s\n' "$name" "$needle" "$got"
  fi
}

assert_not_contains() {
  local got="$1" needle="$2" name="$3"
  if [[ "$got" != *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected not to contain: %s\n        got:      %s\n' "$name" "$needle" "$got"
  fi
}

# The first-line reader. This suite's runs vary the transcript and the
# repository rather than one command, which the shared table's modes do not
# express, so `first_line` is the half of that library it uses.
# shellcheck source=lib/first-line.sh
. "$TEST_DIR/lib/first-line.sh"

echo "reviewer-stop-check: a clean reviewed worktree passes"
REPO="$(new_repo clean)"
T="$(transcript_for "$REPO")"
run_hook "$T"
assert_eq "$rc" 0 "a clean tree exits 0"
assert_eq "$err" "" "a clean tree, whose ignored tmp/ holds the artifact, prints nothing"

echo "reviewer-stop-check: agents that are not reviewers pass"
REPO="$(new_repo other)"
printf 'probe\n' >"$REPO/probe.txt"
T="$(transcript_for "$REPO" generalist)"
run_hook "$T" generalist
assert_eq "$rc" 0 "a generalist's stop passes whatever the tree holds"
run_payload "{\"agent_id\":\"a1\",\"transcript_path\":\"$T\"}"
assert_eq "$rc" 0 "a payload with no agent_type passes"

echo "reviewer-stop-check: an untracked probe blocks once"
REPO="$(new_repo probe)"
T="$(transcript_for "$REPO")"
printf 'probe\n' >"$REPO/probe.sh"
run_hook "$T" reviewer-test a1
assert_eq "$rc" 2 "blocks on an untracked file"
assert_contains "$err" "?? probe.sh" "names the untracked file"
assert_eq "$(first_line)" "reviewer-stop-check: worktree=$REPO" "the value is the reviewed worktree"
[ -e "$REPO/.git/kendex/reviewer-stop/a1" ] && marker=yes || marker=no
assert_eq "$marker" yes "the block records the agent under the reviewed repository's git common dir"
run_hook "$T" reviewer-test a1
assert_eq "$rc" 0 "a second stop of the same subagent passes"
run_hook "$T" reviewer-test a2
assert_eq "$rc" 2 "another subagent over the same dirty tree blocks"
run_hook "$T" reviewer-test a3 true
assert_eq "$rc" 0 "stop_hook_active true passes outright"
[ -e "$REPO/.git/kendex/reviewer-stop/a3" ] && marker=yes || marker=no
assert_eq "$marker" no "a stop_hook_active pass records nothing"
rm -f "$REPO/probe.sh"
run_hook "$T" reviewer-test a4
assert_eq "$rc" 0 "the tree cleaned, a fresh subagent passes"

echo "reviewer-stop-check: every kind of dirt is named"
REPO="$(new_repo dirt)"
T="$(transcript_for "$REPO")"
printf 'pub fn b() {}\n' >>"$REPO/src/lib.rs"
edit_in "$T" "$REPO/src/lib.rs"
run_hook "$T" reviewer-test b1
assert_eq "$rc" 2 "a modified tracked file blocks"
assert_contains "$err" " M src/lib.rs" "names the modified file"
fgit -C "$REPO" checkout -q -- src/lib.rs
mkdir -p "$REPO/fixtures/new"
printf 'x\n' >"$REPO/fixtures/new/case.txt"
run_hook "$T" reviewer-test b2
assert_eq "$rc" 2 "a file inside a new directory blocks"
assert_contains "$err" "?? fixtures/new/case.txt" "names the file, not only its directory"
rm -rf "$REPO/fixtures"
printf 'staged\n' >"$REPO/staged.txt"
fgit -C "$REPO" add staged.txt
edit_in "$T" "$REPO/staged.txt" Write
run_hook "$T" reviewer-test b3
assert_eq "$rc" 2 "a staged file blocks"
assert_contains "$err" "A  staged.txt" "names the staged file"

echo "reviewer-stop-check: the newest artifact mention names the worktree"
REPO_A="$(new_repo a)"
REPO_B="$(new_repo b)"
printf 'probe\n' >"$REPO_A/probe.txt"
T="$TMP_ROOT/transcript.two.jsonl"
{
  printf '{"text":"File: %s/tmp/review-reviewer-test-20260903-101010.json"}\n' "$REPO_A"
  printf '{"text":"File: %s/tmp/review-reviewer-test-20260903-101011.json"}\n' "$REPO_B"
} >"$T"
mkdir -p "$REPO_B/tmp"
printf '{}\n' >"$REPO_B/tmp/review-reviewer-test-20260903-101011.json"
run_hook "$T" reviewer-test c1
assert_eq "$rc" 0 "the newest mention is the reviewed worktree, and it is clean"
printf 'probe\n' >"$REPO_B/probe.txt"
run_hook "$T" reviewer-test c2
assert_eq "$rc" 2 "dirt in the newest-mentioned worktree blocks"
assert_eq "$(first_line)" "reviewer-stop-check: worktree=$REPO_B" "and the value is that worktree"
assert_not_contains "$err" "$REPO_A" "and not the earlier one"

echo "reviewer-stop-check: a linked worktree is judged on its own"
REPO="$(new_repo linked)"
LINKED="$TMP_ROOT/linked"
fgit -C "$REPO" worktree add -q "$LINKED" -b linked
printf 'main dirt\n' >"$REPO/dirt.txt"
T="$(transcript_for "$LINKED")"
run_hook "$T" reviewer-test d1
assert_eq "$rc" 0 "dirt in the main worktree does not block a review of the linked one"
printf 'probe\n' >"$LINKED/probe.txt"
run_hook "$T" reviewer-test d2
assert_eq "$rc" 2 "dirt in the linked worktree blocks"
[ -e "$REPO/.git/kendex/reviewer-stop/d2" ] && marker=yes || marker=no
assert_eq "$marker" yes "the marker lives under the common dir the worktrees share"

echo "reviewer-stop-check: a transcript naming no artifact blocks once"
REPO="$(new_repo noart)"
T="$TMP_ROOT/transcript.noart.jsonl"
printf '{"text":"I looked at %s/src/lib.rs and found nothing."}\n' "$REPO" >"$T"
# The marker for an unknown worktree goes under the repository the hook
# runs in.
RUN_REPO="$(new_repo runrepo)"
set +e
( cd "$RUN_REPO" && env HOME="$TMP_ROOT" "$BASH_BIN" "$HOOK" \
  <<<"{\"agent_type\":\"reviewer-test\",\"agent_id\":\"e1\",\"transcript_path\":\"$T\"}" ) \
  >/dev/null 2>"$TMP_ROOT/stderr"
rc=$?
set -e
err="$(cat "$TMP_ROOT/stderr")"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=reviewer-stop-check: artifact=missing" "no artifact path blocks"
assert_contains "$err" "tmp/review-reviewer-test-" "and the refusal names the path shape the contract wants"
[ -e "$RUN_REPO/.git/kendex/reviewer-stop/e1" ] && marker=yes || marker=no
assert_eq "$marker" yes "the block is recorded under the repository the hook runs in"
set +e
( cd "$RUN_REPO" && env HOME="$TMP_ROOT" "$BASH_BIN" "$HOOK" \
  <<<"{\"agent_type\":\"reviewer-test\",\"agent_id\":\"e1\",\"transcript_path\":\"$T\"}" ) \
  >/dev/null 2>"$TMP_ROOT/stderr"
rc=$?
set -e
assert_eq "$rc" 0 "a second stop of that subagent passes"
run_hook "$T" reviewer-test e2
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=reviewer-stop-check: git=rev-parse --git-common-dir" \
  "outside any repository the block cannot be recorded and the probe is the value"

echo "reviewer-stop-check: the marker cannot be recorded"
# A git directory the hook may read and not write: mkdir and the redirection
# both fail there, and each writes its own diagnostic, so this is the row that
# holds the keyed line first on that path.
REPO="$(new_repo unwritable)"
T="$(transcript_for "$REPO")"
: >"$REPO/probe.sh"
chmod -w "$REPO/.git"
run_hook "$T" reviewer-test m1
chmod +w "$REPO/.git"
assert_eq "rc=$rc first=$(first_line) cause=$(cause_below)" \
  "rc=2 first=reviewer-stop-check: marker=$REPO/.git/kendex/reviewer-stop/m1 cause=present" \
  "a marker it cannot record refuses, the value is the path, and mkdir's words are under it"

echo "reviewer-stop-check: a payload or transcript it cannot read refuses"
REPO="$(new_repo bad)"
T="$(transcript_for "$REPO")"
run_payload '{"agent_type":"reviewer-test","agent_id":"f1"'
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=reviewer-stop-check: payload=invalid-json" \
  "a truncated JSON payload refuses"
run_payload "{\"agent_type\":\"reviewer-test\",\"agent_id\":\"f1\",\"transcript_path\":\"$TMP_ROOT/absent.jsonl\"}"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=reviewer-stop-check: transcript=unreadable" \
  "a transcript that does not exist refuses"
run_payload "{\"agent_type\":\"reviewer-test\",\"agent_id\":\"f1\"}"
assert_eq "$rc" 2 "no transcript_path refuses"
run_payload "{\"agent_type\":\"reviewer-test\",\"agent_id\":\"../x\",\"transcript_path\":\"$T\"}"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=reviewer-stop-check: agent-id=invalid" \
  "an agent_id that is not a name refuses"
# The id is judged as the payload holds it, so no spelling outside the
# alphabet reaches the marker path whatever the encoding between. This row
# pins that refusal rather than a defect the old hook had: @tsv escaped a NUL
# to a backslash and a zero, and the old shell-side test refused that for the
# backslash.
run_payload "{\"agent_type\":\"reviewer-test\",\"agent_id\":\"a1\\u0000a2\",\"transcript_path\":\"$T\"}"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=reviewer-stop-check: agent-id=invalid" \
  "an agent_id carrying a NUL refuses"
# `..` names the marker directory's parent, which exists once a first block
# has recorded the directory, so an id the alphabet let through reads as this
# subagent's own recorded block and passes a dirty worktree's stop unchecked.
REPO_DOTS="$(new_repo dots)"
T_DOTS="$(transcript_for "$REPO_DOTS")"
printf 'probe\n' >"$REPO_DOTS/probe.txt"
run_hook "$T_DOTS" reviewer-test k1
assert_eq "$rc" 2 "a first block records the marker directory"
run_payload "{\"agent_type\":\"reviewer-test\",\"agent_id\":\"..\",\"transcript_path\":\"$T_DOTS\"}"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=reviewer-stop-check: agent-id=invalid" \
  "an agent_id of .. refuses rather than reading the marker directory's parent as a recorded block"
assert_eq "$(ls -A "$REPO_DOTS/.git/kendex/reviewer-stop")" "k1" "and records no marker of its own"
run_payload "{\"agent_type\":\"reviewer-test\",\"transcript_path\":\"$T\"}"
assert_eq "$rc" 2 "no agent_id refuses"
T2="$TMP_ROOT/transcript.gone.jsonl"
printf '{"text":"File: %s/gone/tmp/review-reviewer-test-20260903-101010.json"}\n' "$TMP_ROOT" >"$T2"
run_hook "$T2" reviewer-test f2
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=reviewer-stop-check: git=rev-parse --show-toplevel" \
  "an artifact path whose worktree is not a repository refuses, the probe its value"

echo "reviewer-stop-check: git cannot answer what changed"
REPO="$(new_repo brokengit)"
T="$(transcript_for "$REPO")"
BROKEN_BIN="$TMP_ROOT/brokengit"
mkdir -p "$BROKEN_BIN"
REAL_GIT="$(command -v git)"
cat >"$BROKEN_BIN/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "status" ]; then
    echo "fatal: unable to read index" >&2
    exit 128
  fi
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$BROKEN_BIN/git"
set +e
( cd "$RUN_DIR" && env HOME="$TMP_ROOT" PATH="$BROKEN_BIN:$PATH" "$BASH_BIN" "$HOOK" \
  <<<"{\"agent_type\":\"reviewer-test\",\"agent_id\":\"g1\",\"transcript_path\":\"$T\"}" ) \
  >/dev/null 2>"$TMP_ROOT/stderr"
rc=$?
set -e
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=reviewer-stop-check: git=status" \
  "an unreadable status blocks rather than passing, the probe its value"
assert_contains "$(cat "$TMP_ROOT/stderr")" "unable to read index" "carries git's own failure"

echo "reviewer-stop-check: the payload names the subagent's transcript"
# Claude Code and Codex send the subagent's transcript as
# agent_transcript_path beside the parent session's transcript_path; a payload
# without that key names the subagent's as transcript_path alone. In every row
# the parent's transcript names a clean worktree, so the transcript the hook
# read is the one its first line follows from.
FIELD_DIRTY="$(new_repo field-dirty)"
printf 'probe\n' >"$FIELD_DIRTY/probe.sh"
FIELD_CLEAN="$(new_repo field-clean)"
# The marker for the row naming no artifact goes under the repository the hook
# runs in.
FIELD_RUN="$(new_repo field-run)"
FIELD_PARENT="$(transcript_for "$FIELD_CLEAN")"
FIELD_CHILD="$(transcript_for "$FIELD_DIRTY")"
FIELD_NOART="$TMP_ROOT/transcript.field-noart.jsonl"
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}\n' >"$FIELD_NOART"
# A Codex rollout line naming the dirty worktree's artifact, as a Codex
# reviewer's final message carries it.
FIELD_ROLLOUT="$TMP_ROOT/rollout.field-child.jsonl"
printf '{}\n' >"$FIELD_DIRTY/tmp/review-reviewer-test-20261002-101010.json"
jq -n -c --arg text "Verdict: pass
File: $FIELD_DIRTY/tmp/review-reviewer-test-20261002-101010.json" \
  '{type:"response_item",payload:{type:"message",role:"assistant",
    content:[{type:"output_text",text:$text}]}}' >"$FIELD_ROLLOUT"

# A row is `label|shape|subagent transcript|expected`:
#   shape       codex: Codex 0.160.0's SubagentStop fields; claude: Claude
#               Code's; transcript-only: a payload carrying transcript_path
#               and no agent_transcript_path key
#   transcript  the subagent's own: rollout, child (dirty), noart, or null
FIELD_ROWS="\
a Codex payload reads agent_transcript_path, not the parent's transcript_path|codex|rollout|rc=2 first=reviewer-stop-check: worktree=$FIELD_DIRTY
a Claude Code payload reads agent_transcript_path, not the parent's transcript_path|claude|child|rc=2 first=reviewer-stop-check: worktree=$FIELD_DIRTY
a Claude Code subagent naming no artifact blocks, though the parent's transcript names one|claude|noart|rc=2 first=reviewer-stop-check: artifact=missing
a null agent_transcript_path refuses rather than reading the parent's transcript_path|codex|null|rc=2 first=reviewer-stop-check: transcript=unreadable
a payload without agent_transcript_path reads transcript_path|transcript-only|child|rc=2 first=reviewer-stop-check: worktree=$FIELD_DIRTY
"

field_payload() { # SHAPE SUBAGENT-TRANSCRIPT ID -> the payload text
  local child
  case "$2" in
    rollout) child="$FIELD_ROLLOUT" ;;
    child) child="$FIELD_CHILD" ;;
    noart) child="$FIELD_NOART" ;;
    null) child="" ;;
    *) printf 'field rows: no transcript named %s\n' "$2" >&2; exit 2 ;;
  esac
  case "$1" in
    codex)
      jq -n -c --arg id "$3" --arg parent "$FIELD_PARENT" --arg child "$child" --arg cwd "$FIELD_RUN" \
        '{session_id:"019a",transcript_path:$parent,cwd:$cwd,hook_event_name:"SubagentStop",
          permission_mode:"default",turn_id:"t1",agent_id:$id,agent_type:"reviewer-test",
          agent_transcript_path:(if $child == "" then null else $child end),
          stop_hook_active:false,last_assistant_message:"Verdict: pass",model:"gpt-6.1"}'
      ;;
    claude)
      jq -n -c --arg id "$3" --arg parent "$FIELD_PARENT" --arg child "$child" --arg cwd "$FIELD_RUN" \
        '{session_id:"s1",transcript_path:$parent,cwd:$cwd,permission_mode:"default",
          hook_event_name:"SubagentStop",stop_hook_active:false,agent_id:$id,
          agent_type:"reviewer-test",agent_transcript_path:$child,
          last_assistant_message:"Verdict: pass"}'
      ;;
    transcript-only)
      jq -n -c --arg id "$3" --arg child "$child" --arg cwd "$FIELD_RUN" \
        '{session_id:"s1",transcript_path:$child,cwd:$cwd,hook_event_name:"SubagentStop",
          agent_id:$id,agent_type:"reviewer-test",stop_hook_active:false}'
      ;;
    *) printf 'field rows: no shape named %s\n' "$1" >&2; exit 2 ;;
  esac
}

run_in() { # DIR PAYLOAD -> rc, stderr in $err
  set +e
  ( cd "$1" && env HOME="$TMP_ROOT" "$BASH_BIN" "$HOOK" <<<"$2" ) >/dev/null 2>"$TMP_ROOT/stderr"
  rc=$?
  set -e
  err="$(cat "$TMP_ROOT/stderr")"
}

# field_rows TAG: TAG keeps each run's agent ids apart, so a marker an earlier
# run recorded never passes a later run's stop.
field_rows() {
  local tag="$1" row label shape child want n=0 before=$((PASS + FAIL))
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS='|' read -r label shape child want <<<"$row"
    n=$((n + 1))
    run_in "$FIELD_RUN" "$(field_payload "$shape" "$child" "$tag$n")"
    assert_eq "rc=$rc first=$(first_line)" "$want" "$label"
  done <<<"$FIELD_ROWS"
  [ "$((PASS + FAIL))" -gt "$before" ] || { echo "field rows: no row was asserted" >&2; exit 2; }
}

field_rows f

# Must-fail controls: a rule's line planted in a copy, ROWS (a function taking
# the agent-id tag) run against it, and exactly the named rows turn red.
rows_control() { # ROWS NAME OLD NEW FAILED-ROW...
  local rows="$1" name="$2" old="$3" new="$4" mutant="$TMP_ROOT/control-$2.sh" log status row
  shift 4
  assert_eq "$(grep -c -F -- "$old" "$HOOK")" "1" "control $name finds the rule"
  OLD="$old" NEW="$new" perl -pe 's/\Q$ENV{OLD}\E/$ENV{NEW}/' -- "$HOOK" >"$mutant"
  assert_eq "$(grep -c -F -- "$old" "$mutant")" "0" "control $name planted its defect"
  log="$TMP_ROOT/control-$name.log"
  set +e
  (
    PASS=0
    FAIL=0
    HOOK="$mutant"
    "$rows" "$name"
    [ "$FAIL" -eq 0 ]
  ) >"$log" 2>&1
  status=$?
  set -e
  assert_eq "$status" 1 "control $name: the planted hook turns the rows red"
  assert_eq "$(grep -c '^  FAIL  ' -- "$log" || true)" "$#" "control $name: $# rows fail"
  for row in "$@"; do
    assert_eq "$(grep -c -F -x -- "  FAIL  $row" "$log" || true)" "1" "control $name: '$row' fails"
  done
}
# Reading transcript_path alone reds every row that carries the key; a
# swapped branch reds all of them.
SELECTION='if has("agent_transcript_path") then "agent_transcript_path" else "transcript_path" end'
rows_control field_rows transcript-path-only "$SELECTION" '"transcript_path"' \
  "a Codex payload reads agent_transcript_path, not the parent's transcript_path" \
  "a Claude Code payload reads agent_transcript_path, not the parent's transcript_path" \
  "a Claude Code subagent naming no artifact blocks, though the parent's transcript names one" \
  "a null agent_transcript_path refuses rather than reading the parent's transcript_path"
rows_control field_rows swapped "$SELECTION" \
  'if has("agent_transcript_path") then "transcript_path" else "agent_transcript_path" end' \
  "a Codex payload reads agent_transcript_path, not the parent's transcript_path" \
  "a Claude Code payload reads agent_transcript_path, not the parent's transcript_path" \
  "a Claude Code subagent naming no artifact blocks, though the parent's transcript names one" \
  "a null agent_transcript_path refuses rather than reading the parent's transcript_path" \
  "a payload without agent_transcript_path reads transcript_path"

echo "reviewer-stop-check: the artifact, not its mention"
# A row is `label|artifact|expected`: the transcript names the artifact path in
# every row, over a clean worktree; the artifact file is what varies.
ARTIFACT_ROWS="\
a readable artifact passes|json|rc=0 first=-
a mentioned artifact that does not exist blocks|absent|rc=2 first=reviewer-stop-check: artifact=unreadable
an empty artifact blocks|empty|rc=2 first=reviewer-stop-check: artifact=unreadable
an artifact that is not JSON blocks|garbage|rc=2 first=reviewer-stop-check: artifact=unreadable
"
artifact_rows() { # TAG
  local tag="$1" row label kind want repo t file n=0 before=$((PASS + FAIL))
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS='|' read -r label kind want <<<"$row"
    n=$((n + 1))
    repo="$(new_repo "artifact-$tag$n")"
    t="$(transcript_for "$repo")"
    file="$repo/tmp/review-reviewer-test-20260903-101010.json"
    case "$kind" in
      json) ;;
      absent) rm -f -- "${file:?}" ;;
      empty) : >"$file" ;;
      garbage) printf '{"verdict":"pass"} trailing\n' >"$file" ;;
      *) printf 'artifact rows: no kind named %s\n' "$kind" >&2; exit 2 ;;
    esac
    run_hook "$t" reviewer-test "$tag$n"
    assert_eq "rc=$rc first=$(first_line)" "$want" "$label"
  done <<<"$ARTIFACT_ROWS"
  [ "$((PASS + FAIL))" -gt "$before" ] || { echo "artifact rows: no row was asserted" >&2; exit 2; }
}
artifact_rows art
# The block is recorded like any other: the same subagent's next stop passes.
REPO="$(new_repo artifact-once)"
T="$(transcript_for "$REPO")"
: >"$REPO/tmp/review-reviewer-test-20260903-101010.json"
run_hook "$T" reviewer-test once1
assert_eq "$rc" 2 "an unreadable artifact blocks the first stop"
run_hook "$T" reviewer-test once1
assert_eq "$rc" 0 "a second stop of a subagent held on its artifact passes"
rows_control artifact_rows artifact-unchecked \
  'jq -s '\''if length == 0 then error("no JSON value") else empty end'\'' "$ARTIFACT" 2>&1' 'true' \
  "a mentioned artifact that does not exist blocks" \
  "an empty artifact blocks" \
  "an artifact that is not JSON blocks"

echo "reviewer-stop-check: only paths the review changed block"
# The author leaves a modified tracked file, an untracked file, a staged new
# file and a deleted tracked file. The review starts at the next whole second,
# the dated transcript's first entry, since a change time cannot be set back
# and the hook compares whole seconds; then the reviewer acts. A row is
# `label|transcript|act|expected|named`: transcript `dated` (Claude Code's
# prompt first, at the start), `codex` (a `session_meta` first), `toolfirst`
# (a completed tool call first, stamped at the start) or `undated`; act
# `none`, `probe` (creates a file), `chmod` (a tracked file's mode, its content
# and mtime untouched), `stage` (git add of the author's modified file) or
# `move` (mv of the author's untracked file, which keeps its mtime); named is
# the status line the refusal must carry, or `-`.
START_ROWS="\
dirt the author left before the review passes|dated|none|rc=0 first=-|-
a probe the reviewer created blocks over the author's dirt|dated|probe|rc=2 first=reviewer-stop-check: worktree=@REPO@|?? probe.sh
a mode change without actor evidence passes|dated|chmod|rc=0 first=-|-
an index change without actor evidence passes|dated|stage|rc=0 first=-|-
the reviewer moving the author's file blocks though its mtime is old|dated|move|rc=2 first=reviewer-stop-check: worktree=@REPO@|?? notes-moved.txt
a Codex session_meta dates the start, and the author's dirt passes|codex|none|rc=0 first=-|-
a completed tool call first gives no start, and the author's dirt blocks|toolfirst|none|rc=2 first=reviewer-stop-check: worktree=@REPO@|-
with no dated first entry the author's dirt blocks|undated|none|rc=2 first=reviewer-stop-check: worktree=@REPO@|-
"
fs_now() { # -> the change time a write stamps now
  touch -- "$TMP_ROOT/clock"
  stat -c %Z -- "$TMP_ROOT/clock" 2>/dev/null || stat -f %c -- "$TMP_ROOT/clock"
}
start_rows() { # TAG
  local tag="$1" row label dated act want named repo t t0 start first n=0 before=$((PASS + FAIL))
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS='|' read -r label dated act want named <<<"$row"
    n=$((n + 1))
    repo="$(new_repo "start-$tag$n")"
    mkdir -p "$repo/tools"
    printf 'pub fn gone() {}\n' >"$repo/src/gone.rs"
    printf 'echo run\n' >"$repo/tools/run.sh"
    fgit -C "$repo" add src/gone.rs tools/run.sh
    fgit -C "$repo" commit -q -m author
    printf 'pub fn b() {}\n' >>"$repo/src/lib.rs"
    printf 'notes\n' >"$repo/author-notes.txt"
    printf 'staged\n' >"$repo/author-staged.txt"
    fgit -C "$repo" add author-staged.txt
    rm -f -- "${repo:?}/src/gone.rs"
    # A clean tracked file whose mtime no longer matches its index entry: an
    # ordinary git status would refresh that entry and rewrite the index, the
    # author's staged path then reading as staged during the review.
    touch -t 201001010000 "$repo/tools/run.sh"
    t="$(transcript_for "$repo")"
    # The start is read off the filesystem's own clock, which stamps change
    # times from a coarse clock that can trail date's by milliseconds: the
    # author's changes are at or before t0, every later change at or after
    # the start.
    t0=$(fs_now)
    start=$t0
    while [ "$start" -le "$t0" ]; do start=$(fs_now); done
    case "$dated" in
      dated) first='{"type":"user","timestamp":"@TS@","message":{"role":"user","content":"Review the diff."}}' ;;
      codex) first='{"timestamp":"@TS@","type":"session_meta","payload":{"id":"019a"}}' ;;
      toolfirst) first='{"timestamp":"@TS@","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","name":"exec"}}' ;;
      undated) first='' ;;
      *) printf 'start rows: no transcript named %s\n' "$dated" >&2; exit 2 ;;
    esac
    if [ -n "$first" ]; then
      { printf '%s\n' "${first//@TS@/$(jq -nr --argjson t "$start" '$t | todate')}"; cat -- "$t"; } >"$t.dated"
      t="$t.dated"
    fi
    case "$act" in
      none) ;;
      probe) printf 'probe\n' >"$repo/probe.sh" ;;
      chmod) chmod +x "$repo/tools/run.sh" ;;
      stage) fgit -C "$repo" add src/lib.rs ;;
      move) mv -- "$repo/author-notes.txt" "$repo/notes-moved.txt" ;;
      *) printf 'start rows: no act named %s\n' "$act" >&2; exit 2 ;;
    esac
    run_hook "$t" reviewer-test "$tag$n"
    assert_eq "rc=$rc first=$(first_line)" "${want//@REPO@/$repo}" "$label"
    if [ "$named" != - ] && [ "$dated" = dated ]; then
      assert_contains "$err" "$named" "$label, naming the reviewer's path"
      assert_not_contains "$err" " D src/gone.rs" "$label, and not the author's deletion"
    fi
  done <<<"$START_ROWS"
  [ "$((PASS + FAIL))" -gt "$before" ] || { echo "start rows: no row was asserted" >&2; exit 2; }
}
start_rows st
# Untracked paths still use the start and change times. Tracked files never
# take actor evidence from either the file's clock or the index's clock.
rows_control start_rows start-ignored '[ "$t" -ge "$START" ]' 'true' \
  "dirt the author left before the review passes" \
  "a mode change without actor evidence passes" \
  "an index change without actor evidence passes" \
  "a Codex session_meta dates the start, and the author's dirt passes"
rows_control start_rows start-all-old '[ "$t" -ge "$START" ]' 'false' \
  "a probe the reviewer created blocks over the author's dirt" \
  "a probe the reviewer created blocks over the author's dirt, naming the reviewer's path" \
  "the reviewer moving the author's file blocks though its mtime is old" \
  "the reviewer moving the author's file blocks though its mtime is old, naming the reviewer's path"
# Any first entry taken as the start reds the tool-call row.
rows_control start_rows launch-record-unchecked \
  '| select(.type == "session_meta" or (.type == "user" and ([.message.content | arrays | .[] | .type?] | index("tool_result") | not)))' \
  '' \
  "a completed tool call first gives no start, and the author's dirt blocks"
rows_control start_rows mtime 'stat -c %Z "$1" 2>/dev/null || stat -f %c "$1" 2>/dev/null' \
  'stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null' \
  "the reviewer moving the author's file blocks though its mtime is old" \
  "the reviewer moving the author's file blocks though its mtime is old, naming the reviewer's path"

echo "reviewer-stop-check: tracked edits need the reviewer's own successful call"
actor_rows() { # TAG
  local tag="$1" label kind want repo t path state event move n=0 artifact before=$((PASS + FAIL))
  while IFS='|' read -r label kind want; do
    n=$((n + 1))
    repo="$(new_repo "actor-$tag$n")"
    t="$(transcript_for "$repo")"
    artifact="$repo/tmp/review-reviewer-test-20260903-101010.json"
    path="$repo/src/lib.rs"
    # The launch precedes both the reviewer's calls and the other agent's
    # edits. No clock delay is needed: any later ctime would be blamed by the
    # old rule, whereas this rule uses the calling agent's tool results.
    jq -nc --arg cwd "$repo" '{type:"session_meta",timestamp:"2000-01-01T00:00:00Z",payload:{cwd:$cwd}}' >"$t.launch"
    cat -- "$t" >>"$t.launch"
    t="$t.launch"
    case "$kind" in
      read) edit_in "$t" "$path" Read ;;
      other) edit_in "$t" "$repo/src/other.rs" ;;
      failed) edit_in "$t" "$path" Edit true ;;
      pending)
        # A result for another call cannot complete this mutation call.
        edit_in "$t" "$path" Edit false another-call
        ;;
      edit | staged | deleted) edit_in "$t" "$path" ;;
      write) edit_in "$t" "$path" Write ;;
      multi) edit_in "$t" "$path" MultiEdit ;;
      notebook)
        path="$repo/src/notebook.ipynb"
        printf '{}\n' >"$path"
        fgit -C "$repo" add src/notebook.ipynb
        fgit -C "$repo" commit -q -m notebook
        jq -nc --arg path "$path" '{type:"assistant",message:{content:[{type:"tool_use",id:"edit-1",name:"NotebookEdit",input:{notebook_path:$path}}]}}' >>"$t"
        jq -nc '{type:"user",message:{content:[{type:"tool_result",tool_use_id:"edit-1",is_error:false,content:"result"}]}}' >>"$t"
        ;;
      artifact | unignored-report)
        edit_in "$t" "$artifact" Write
        if [ "$kind" = unignored-report ]; then printf '# no ignored paths\n' >"$repo/.gitignore"; fi
        ;;
      quoted)
        path="$repo/src/a\"b.rs"
        printf 'before\n' >"$path"
        fgit -C "$repo" add -- "$path"
        fgit -C "$repo" commit -q -m quoted
        edit_in "$t" "$path"
        ;;
      codex | codex-failed | codex-pending | codex-move*)
        state=completed event=item_completed move=""
        [ "$kind" != codex-failed ] || state=failed
        if [ "$kind" = codex-pending ]; then event=item_started; state=""; fi
        case "$kind" in
          codex-move) move="$repo/src/moved.rs" ;;
          codex-move-quoted) path="$repo/src/quote\"old.rs"; move="$repo/src/quote\"new.rs" ;;
          codex-move-backslash) path="$repo/src/back\\old.rs"; move="$repo/src/back\\new.rs" ;;
          codex-move-arrow) move="$repo/src/name -> moved.rs" ;;
          codex-move-newline) path="$repo/src/old"$'\n'; move="$repo/src/new"$'\n' ;;
          codex-move-control) path="$repo/src/old"$'\a'; move="$repo/src/new"$'\a' ;;
        esac
        if [ "$path" != "$repo/src/lib.rs" ]; then
          fgit -C "$repo" mv -- src/lib.rs "${path#"$repo/"}"
          fgit -C "$repo" commit -q -m rename-input
        fi
        jq -nc --arg path "$path" --arg state "$state" --arg event "$event" --arg move "$move" \
          '{type:"event_msg",payload:{type:$event,item:{type:"FileChange",id:"patch-1",status:(if $state == "" then null else $state end),
            changes:{($path):{type:"update",unified_diff:"",move_path:(if $move == "" then null else $move end)}}}}}' >>"$t"
        if [ -n "$move" ]; then mv -- "$path" "$move"; path="$move"; fi
        ;;
      *) echo "actor rows: unknown kind=$kind" >&2; exit 2 ;;
    esac
    if [ "$kind" = deleted ]; then rm -- "$path"; else printf 'changed\n' >>"$path"; fi
    if [ "$kind" = staged ]; then fgit -C "$repo" add src/lib.rs; fi
    case "$kind" in
      codex-move*)
        fgit -C "$repo" add -A
        assert_eq "$(fgit -C "$repo" status --porcelain -z | jq -Rs '.[0:2] | contains("R")')" true \
          "$label is a tracked rename"
        ;;
    esac
    run_hook "$t" reviewer-test "$tag$n"
    assert_eq "rc=$rc first=$(first_line)" "${want//@REPO@/$repo}" "$label"
    assert_eq "$(cat -- "$artifact")" '{}' "$label keeps the required report"
  done <<'ROWS'
a concurrent tracked edit passes for a read-only reviewer|read|rc=0 first=-
a concurrent tracked edit passes when the reviewer edited a different path|other|rc=0 first=-
a failed edit cannot attribute another agent's tracked edit|failed|rc=0 first=-
an unmatched tool result cannot attribute another agent's tracked edit|pending|rc=0 first=-
a successful reviewer Edit blocks its tracked path|edit|rc=2 first=reviewer-stop-check: worktree=@REPO@
a successful reviewer Write blocks its tracked path|write|rc=2 first=reviewer-stop-check: worktree=@REPO@
a successful reviewer MultiEdit blocks its tracked path|multi|rc=2 first=reviewer-stop-check: worktree=@REPO@
a successful reviewer NotebookEdit blocks its tracked path|notebook|rc=2 first=reviewer-stop-check: worktree=@REPO@
an attributed staged edit blocks|staged|rc=2 first=reviewer-stop-check: worktree=@REPO@
an attributed deletion blocks|deleted|rc=2 first=reviewer-stop-check: worktree=@REPO@
an attributed quoted path blocks|quoted|rc=2 first=reviewer-stop-check: worktree=@REPO@
a completed Codex file change blocks|codex|rc=2 first=reviewer-stop-check: worktree=@REPO@
a failed Codex file change cannot attribute another agent's edit|codex-failed|rc=0 first=-
a pending Codex file change cannot attribute another agent's edit|codex-pending|rc=0 first=-
a completed Codex move blocks|codex-move|rc=2 first=reviewer-stop-check: worktree=@REPO@
a completed Codex move with quoted names blocks|codex-move-quoted|rc=2 first=reviewer-stop-check: worktree=@REPO@
a completed Codex move with backslashes blocks|codex-move-backslash|rc=2 first=reviewer-stop-check: worktree=@REPO@
a completed Codex move with an arrow in its destination blocks|codex-move-arrow|rc=2 first=reviewer-stop-check: worktree=@REPO@
a completed Codex move with final newlines blocks|codex-move-newline|rc=2 first=reviewer-stop-check: worktree=@REPO@
a completed Codex move with Git control escapes blocks|codex-move-control|rc=2 first=reviewer-stop-check: worktree=@REPO@
writing the required report cannot attribute another agent's edit|artifact|rc=0 first=-
the required report passes even when Git does not ignore it|unignored-report|rc=0 first=-
ROWS
  [ "$((PASS + FAIL))" -gt "$before" ] || { echo "actor rows: no row was asserted" >&2; exit 2; }
}
actor_rows actor
# Git's display row has two quoted names for a rename. Treating that whole
# row as JSON, then splitting on an arrow, loses the literal destination.
rows_control actor_rows display-path-decoded \
  '.path + "/"' '(.line[3:] | if startswith("\"") then (try fromjson catch "") else . end | split(" -> ") | last) + "/"' \
  "a completed Codex move with quoted names blocks" \
  "a completed Codex move with backslashes blocks" \
  "a completed Codex move with an arrow in its destination blocks" \
  "a completed Codex move with final newlines blocks" \
  "a completed Codex move with Git control escapes blocks"
rows_control actor_rows every-tracked-path \
  'any(.[]; . == $path or ($row.submodule and startswith($path + "/")))' 'true' \
  "a concurrent tracked edit passes for a read-only reviewer" \
  "a concurrent tracked edit passes when the reviewer edited a different path" \
  "a failed edit cannot attribute another agent's tracked edit" \
  "an unmatched tool result cannot attribute another agent's tracked edit" \
  "a failed Codex file change cannot attribute another agent's edit" \
  "a pending Codex file change cannot attribute another agent's edit" \
  "writing the required report cannot attribute another agent's edit" \
  "the required report passes even when Git does not ignore it"
rows_control actor_rows report-counts-as-probe \
  '[ "$identity" != "$ARTIFACT_ID" ] || return 1' ':' \
  "the required report passes even when Git does not ignore it"
rows_control actor_rows failed-edit-counts \
  '.type == "tool_result" and .is_error != true' '.type == "tool_result"' \
  "a failed edit cannot attribute another agent's tracked edit"
rows_control actor_rows unmatched-call-counts \
  'select(.id as $id | $claude_ok | index($id))' 'select(true)' \
  "a failed edit cannot attribute another agent's tracked edit" \
  "an unmatched tool result cannot attribute another agent's tracked edit"
rows_control actor_rows read-counts-as-edit \
  'select(.name == "Write" or .name == "Edit" or .name == "MultiEdit" or .name == "NotebookEdit")' 'select(true)' \
  "a concurrent tracked edit passes for a read-only reviewer"
rows_control actor_rows own-edit-ignored \
  'any(.[]; . == $path or ($row.submodule and startswith($path + "/")))' 'false' \
  "a successful reviewer Edit blocks its tracked path" \
  "a successful reviewer Write blocks its tracked path" \
  "a successful reviewer MultiEdit blocks its tracked path" \
  "a successful reviewer NotebookEdit blocks its tracked path" \
  "an attributed staged edit blocks" \
  "an attributed deletion blocks" \
  "an attributed quoted path blocks" \
  "a completed Codex file change blocks" \
  "a completed Codex move blocks" \
  "a completed Codex move with quoted names blocks" \
  "a completed Codex move with backslashes blocks" \
  "a completed Codex move with an arrow in its destination blocks" \
  "a completed Codex move with final newlines blocks" \
  "a completed Codex move with Git control escapes blocks"
rows_control actor_rows failed-codex-counts \
  '.type == "FileChange" and .status == "completed"' '.type == "FileChange"' \
  "a failed Codex file change cannot attribute another agent's edit"

# Codex FileChange names the file it changed. Git names physical checkout
# paths and collapses submodule descendants to the tracked gitlink entry.
path_rows() { # TAG
  local tag="$1" label kind want repo t path alias seed artifact n=0 before=$((PASS + FAIL))
  while IFS='|' read -r label kind want; do
    n=$((n + 1))
    repo="$(new_repo "paths-$tag$n")"
    path="$repo/src/lib.rs"
    t="$(transcript_for "$repo")"
    artifact="$repo/tmp/review-reviewer-test-20260903-101010.json"
    case "$kind" in
      alias*)
        alias="$TMP_ROOT/alias-$tag$n"
        if [ "$kind" = alias-dot-parent ]; then ln -s -- "$repo/src" "$alias"
        else ln -s -- "$repo" "$alias"; fi
        [ -L "$alias" ] || { echo "path rows: symlink=not-created" >&2; exit 2; }
        path="$alias/src/lib.rs"
        case "$kind" in
          alias-artifact) t="$(transcript_for "$alias")"; path="$repo/src/lib.rs" ;;
          alias-other) path="$alias/src/other.rs" ;;
          alias-dot-parent) path="$alias/../src/lib.rs" ;;
        esac
        ;;
      module*)
        seed="$(new_repo "seed-$tag$n")"
        fgit -C "$repo" -c protocol.file.allow=always submodule add -q "$seed" module
        printf 'module-extra/\n' >>"$repo/.gitignore"
        fgit -C "$repo" add -A
        fgit -C "$repo" commit -q -m module
        path="$repo/module/src/lib.rs"
        case "$kind" in
          module-other) path="$repo/src/other.rs" ;;
          module-prefix)
            mkdir -p "$repo/module-extra/src"
            path="$repo/module-extra/src/lib.rs"
            printf 'changed\n' >"$path"
            ;;
          module-alias)
            alias="$TMP_ROOT/alias-$tag$n"
            ln -s -- "$repo" "$alias"
            [ -L "$alias" ] || { echo "path rows: symlink=not-created" >&2; exit 2; }
            path="$alias/module/src/lib.rs"
            ;;
        esac
        ;;
      ordinary-parent) path="$repo/src" ;;
      ordinary-child)
        rm -- "$repo/src/lib.rs"
        mkdir -p "$repo/src/lib.rs"
        printf 'src/lib.rs/\n' >>"$repo/.gitignore"
        fgit -C "$repo" add .gitignore
        fgit -C "$repo" commit -q -m ignore-probe
        path="$repo/src/lib.rs/probe"
        printf 'changed\n' >"$path"
        ;;
      *) echo "path rows: unknown kind=$kind" >&2; exit 2 ;;
    esac
    jq -nc --arg path "$path" \
      '{type:"event_msg",payload:{type:"item_completed",item:{type:"FileChange",id:"patch-1",status:"completed",
        changes:{($path):{type:"update",unified_diff:"",move_path:null}}}}}' >>"$t"
    case "$kind" in
      alias-deleted) rm -- "$repo/src/lib.rs" ;;
      alias-deleted-directory) rm -rf -- "$repo/src" ;;
      module-deleted) rm -- "$repo/module/src/lib.rs" ;;
      module-removed)
        fgit -C "$repo" rm -q -f module
        ;;
      module*) printf 'changed\n' >>"$repo/module/src/lib.rs" ;;
      ordinary-child) ;;
      *) printf 'changed\n' >>"$repo/src/lib.rs" ;;
    esac
    run_hook "$t" reviewer-test "$tag$n"
    assert_eq "rc=$rc first=$(first_line)" "${want//@REPO@/$repo}" "$label"
    assert_eq "$(cat -- "$artifact")" '{}' "$label keeps the required report"
  done <<'ROWS'
a checkout alias identifies the same tracked file|alias|rc=2 first=reviewer-stop-check: worktree=@REPO@
an artifact through a checkout alias identifies the same tracked file|alias-artifact|rc=2 first=reviewer-stop-check: worktree=@REPO@
a checkout alias retains a deleted tracked file|alias-deleted|rc=2 first=reviewer-stop-check: worktree=@REPO@
a checkout alias retains a deleted parent directory|alias-deleted-directory|rc=2 first=reviewer-stop-check: worktree=@REPO@
a parent component after a directory alias keeps physical meaning|alias-dot-parent|rc=2 first=reviewer-stop-check: worktree=@REPO@
a checkout alias keeps another tracked file distinct|alias-other|rc=0 first=-
a submodule descendant identifies the tracked submodule|module|rc=2 first=reviewer-stop-check: worktree=@REPO@
a deleted submodule descendant identifies the tracked submodule|module-deleted|rc=2 first=reviewer-stop-check: worktree=@REPO@
a removed submodule retains descendant attribution|module-removed|rc=2 first=reviewer-stop-check: worktree=@REPO@
a checkout alias identifies a submodule descendant|module-alias|rc=2 first=reviewer-stop-check: worktree=@REPO@
another path does not identify a dirty submodule|module-other|rc=0 first=-
a shared name prefix does not identify a dirty submodule|module-prefix|rc=0 first=-
an ordinary parent directory does not identify a dirty file|ordinary-parent|rc=0 first=-
an ordinary child path does not identify a deleted tracked file|ordinary-child|rc=0 first=-
ROWS
  [ "$((PASS + FAIL))" -gt "$before" ] || { echo "path rows: no row was asserted" >&2; exit 2; }
}
path_rows paths
rows_control path_rows logical-ancestors \
  'physical=$(cd -P -- "$ancestor" 2>/dev/null && printf '\''%s/'\'' "$PWD") || return 1' \
  'physical="${ancestor%/}/"' \
  "a checkout alias identifies the same tracked file" \
  "a checkout alias retains a deleted tracked file" \
  "a checkout alias retains a deleted parent directory" \
  "a parent component after a directory alias keeps physical meaning" \
  "a checkout alias identifies a submodule descendant"
rows_control path_rows submodule-descendant-ignored \
  '$row.submodule and startswith($path + "/")' 'false' \
  "a submodule descendant identifies the tracked submodule" \
  "a deleted submodule descendant identifies the tracked submodule" \
  "a removed submodule retains descendant attribution" \
  "a checkout alias identifies a submodule descendant"
rows_control path_rows ordinary-descendant-counts \
  '$row.submodule and startswith($path + "/")' 'startswith($path + "/")' \
  "an ordinary child path does not identify a deleted tracked file"
rows_control path_rows submodule-prefix-counts \
  'startswith($path + "/")' 'startswith($path)' \
  "a shared name prefix does not identify a dirty submodule"

echo "reviewer-stop-check: without jq"
# One world per declared dependency, each holding every other tool and not
# that one: the refusal names the missing tool and nothing is judged without
# it. A row per tool is what keeps the inventory honest — an absent tail does
# not stall this hook, it passes the call through.
tools_table() { # TOOLS
  local tool other bin before=$((PASS + FAIL))
  for tool in $1; do
    bin="$TMP_ROOT/without-$tool"
    rm -rf -- "$bin"
    mkdir -p "$bin"
    for other in $1; do
      [ "$other" != "$tool" ] || continue
      real="$(type -P "$other" 2>/dev/null || true)"
      [ -n "$real" ] && [ -x "$real" ] || continue
      ln -sf "$real" "$bin/$other"
    done
    run_payload '{"agent_type":"generalist","agent_id":"h1","transcript_path":"/nonexistent"}' "$bin"
    assert_eq "rc=$rc first=$(first_line)" "rc=2 first=reviewer-stop-check: missing-tools=$tool" \
      "without $tool the call is refused, and the value names it"
  done
  # A world holding none of them: the value is the whole list, in check order.
  # A row per tool cannot see an accumulator that overwrites instead of
  # appending, because only one name is ever missing in one.
  bin="$TMP_ROOT/without-everything"
  rm -rf -- "$bin"
  mkdir -p "$bin"
  run_payload '{"agent_type":"generalist","agent_id":"h1","transcript_path":"/nonexistent"}' "$bin"
  assert_eq "rc=$rc first=$(first_line)" "rc=2 first=reviewer-stop-check: missing-tools=${1// /,}" \
    "with none of them the value is the whole list, in check order"
  [ "$((PASS + FAIL))" -gt "$before" ] || { echo "tools: no row was asserted" >&2; exit 2; }
}
tools_table "jq git cat grep tail stat mkdir"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
