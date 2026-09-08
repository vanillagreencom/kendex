#!/usr/bin/env bash
# Tests for the reviewer-stop-check hook.
#
# The hook blocks a reviewer subagent's stop once when the worktree its
# transcript names through the artifact path is not clean, or when the
# transcript names no artifact path at all. Pinned here: what names the
# worktree (the newest <dir>/tmp/review-*.json mention, in a Write call or
# a File: line), what counts as dirty (a modified tracked file, an untracked
# file, one inside an untracked directory), the once-per-agent marker under the
# reviewed repository's git common dir, that a sibling worktree's dirt is
# not this worktree's, and the fail-closed edges — an unreadable payload,
# a transcript that cannot be read, a git that cannot answer.
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

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which take precedence over `git -C` and
# would point the fixtures' git at the real repository.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/reviewer-stop-check.sh}"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
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
  printf 'pub fn a() {}\n' >"$repo/src/lib.rs"
  printf 'tmp/\n' >"$repo/.gitignore"
  fgit -C "$repo" add -A
  fgit -C "$repo" commit -q -m init
  printf '%s' "$repo"
}

# A transcript naming REPO's artifact the way the harness records a Write
# call and the return message: JSON lines, the path inside a JSON string.
transcript_for() { # REPO [AGENT] -> path
  local repo="$1" agent="${2:-reviewer-test}" t="$TMP_ROOT/transcript.$$.$RANDOM.jsonl"
  {
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s/tmp/review-%s-20260903-101010.json","content":"{}"}}]}}\n' "$repo" "$agent"
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":"Verdict: pass\\nFile: %s/tmp/review-%s-20260903-101010.json\\n"}]}}\n' "$repo" "$agent"
  } >"$t"
  printf '%s' "$t"
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
assert_eq "$err" "" "a clean tree prints nothing"
mkdir -p "$REPO/tmp"
printf '{}' >"$REPO/tmp/review-reviewer-test-20260903-101010.json"
run_hook "$T"
assert_eq "$rc" 0 "the artifact itself, under the ignored tmp/, is not dirt"

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

echo "reviewer-stop-check: without jq"
NOJQ_BIN="$TMP_ROOT/nojq"
mkdir -p "$NOJQ_BIN"
for tool in cat sed grep tail dirname git; do
  real="$(type -P "$tool" 2>/dev/null || true)"
  [ -n "$real" ] && [ -x "$real" ] || continue
  ln -sf "$real" "$NOJQ_BIN/$tool"
done
run_payload "{\"agent_type\":\"generalist\",\"agent_id\":\"h1\",\"transcript_path\":\"$T\"}" "$NOJQ_BIN"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=reviewer-stop-check: missing-tools=jq" \
  "no jq refuses rather than guessing at the payload, and names it"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
