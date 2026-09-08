#!/usr/bin/env bash
# Tests for the reviewer-read-only hook.
#
# For a subagent whose agent_type starts with `reviewer-` the hook refuses
# every Edit, MultiEdit and NotebookEdit; a Write inside a git work tree
# unless it is the artifact, <dir>/tmp/review-*.json; and a Bash command
# running `git commit` or `git push`. Pinned here: every other agent passes,
# a Write outside any repository passes (a reviewer's controls live under
# its own mktemp -d), a read-only git verb passes, and the fail-closed
# edges — an unreadable payload, a path that is not a string, a git that
# cannot answer, no jq.
#
# Fixtures are throwaway git repositories built under a HOME of their own.
#
# Every refusal opens with `reviewer-read-only: <key>=<value>`, and that line
# is the contract: the tool call it refused, or the path it would not have
# written, is the value. The artifact path a reviewer may write, and git's own
# words when it could not answer, are pinned as themselves under it.
#
# HOOK_UNDER_TEST overrides the script under test so the must-fail controls
# (a no-op hook, an always-refuse hook) can be run against these same
# assertions.
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which take precedence over `git -C` and
# would point the fixtures' git at the real repository.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/reviewer-read-only.sh}"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
BASH_BIN="$(command -v bash)"
ERR_FILE="$TMP_ROOT/stderr"

fgit() {
  env HOME="$TMP_ROOT" git "$@"
}

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/src"
fgit init -q "$REPO"
fgit -C "$REPO" config user.email t@example.com
fgit -C "$REPO" config user.name t
printf 'pub fn a() {}\n' >"$REPO/src/lib.rs"
fgit -C "$REPO" add -A
fgit -C "$REPO" commit -q -m init
SCRATCH="$TMP_ROOT/scratch"
mkdir -p "$SCRATCH"

# run AGENT_TYPE TOOL FIELD VALUE -> rc, stderr in $err. An empty AGENT_TYPE
# omits the field, as the main session's payload does. jq encodes the value
# the way the harness does, so a path or command holding a quote, a
# backslash or a newline reaches the hook as JSON.
run_tool() {
  local agent="$1" tool="$2" field="$3" value="$4"
  run_payload "$(jq -nc --arg a "$agent" --arg t "$tool" --arg f "$field" --arg v "$value" \
    '(if $a == "" then {} else {agent_type: $a} end) + {tool_name: $t, tool_input: {($f): $v}}')"
}

run_payload() { # raw-json [PATH] -> rc, stderr in $err
  set +e
  if [ -n "${2:-}" ]; then
    printf '%s' "$1" | env -i HOME="$TMP_ROOT" PWD="$TMP_ROOT" PATH="$2" "$BASH_BIN" "$HOOK" \
      >/dev/null 2>"$TMP_ROOT/stderr"
  else
    printf '%s' "$1" | env HOME="$TMP_ROOT" "$BASH_BIN" "$HOOK" >/dev/null 2>"$TMP_ROOT/stderr"
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

# The first-line reader. This suite's runs vary the agent, the tool and the
# path rather than one command, which the shared table's modes do not express,
# so `first_line` is the half of that library it uses.
# shellcheck source=lib/first-line.sh
. "$TEST_DIR/lib/first-line.sh"

ARTIFACT="$REPO/tmp/review-reviewer-test-20260903-101010.json"

echo "reviewer-read-only: agents that are not reviewers pass"
run_tool generalist Edit file_path "$REPO/src/lib.rs"
assert_eq "$rc" 0 "a generalist's Edit passes"
run_tool "" Edit file_path "$REPO/src/lib.rs"
assert_eq "$rc" 0 "a payload with no agent_type passes"
run_tool "" Bash command 'git commit -m x'
assert_eq "$rc" 0 "the main session's git commit passes"
run_tool dev Bash command 'git push origin HEAD'
assert_eq "$rc" 0 "a dev agent's git push passes"
run_tool reviewer Edit file_path "$REPO/src/lib.rs"
assert_eq "$rc" 0 "an agent named reviewer with no hyphenated domain is not a reviewer-* agent"

echo "reviewer-read-only: a reviewer edits nothing"
for tool in Edit MultiEdit NotebookEdit; do
  run_tool reviewer-correctness "$tool" file_path "$REPO/src/lib.rs"
  assert_eq "rc=$rc first=$(first_line)" "rc=2 first=reviewer-read-only: refused=$tool" \
    "a reviewer's $tool is refused, the call its value"
done
run_tool reviewer-correctness Edit file_path "$REPO/src/lib.rs"
assert_contains "$err" "tmp/review-reviewer-correctness-" "the refusal names the one path a reviewer writes"
run_tool reviewer-correctness Edit file_path "$SCRATCH/note.txt"
assert_eq "$rc" 2 "an Edit outside any repository is refused too: a reviewer never edits"

echo "reviewer-read-only: a reviewer writes the artifact and nothing else in a repository"
run_tool reviewer-test Write file_path "$ARTIFACT"
assert_eq "$rc" 0 "the artifact path passes before tmp/ exists"
mkdir -p "$REPO/tmp"
run_tool reviewer-test Write file_path "$ARTIFACT"
assert_eq "$rc" 0 "the artifact path passes once tmp/ exists"
run_tool reviewer-test Write file_path "$REPO/tmp/review-reviewer-test-codebase-20260903-101010.json"
assert_eq "$rc" 0 "the codebase-review artifact path passes"
run_tool reviewer-test Write file_path "$REPO/src/lib.rs"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=reviewer-read-only: path=$REPO/src/lib.rs" \
  "a Write onto a tracked file is refused, the path its value"
assert_contains "$err" "mktemp -d" "the refusal says where a control belongs"
run_tool reviewer-test Write file_path "$REPO/probe.sh"
assert_eq "$rc" 2 "a new file at the repository root is refused"
run_tool reviewer-test Write file_path "$REPO/new/dir/probe.sh"
assert_eq "$rc" 2 "a new file under directories that do not exist yet is judged by the nearest existing ancestor"
run_tool reviewer-test Write file_path "$REPO/review-reviewer-test-20260903-101010.json"
assert_eq "$rc" 2 "the artifact name outside a tmp/ directory is not the artifact"
run_tool reviewer-test Write file_path "$REPO/tmp/notes.md"
assert_eq "$rc" 2 "a file under tmp/ that is not review-*.json is refused"
run_tool reviewer-test Write file_path "$SCRATCH/fixture.rs"
assert_eq "$rc" 0 "a Write outside any repository passes"
run_tool reviewer-test Write file_path "$SCRATCH/deeper/not/yet/fixture.rs"
assert_eq "$rc" 0 "a Write under directories that do not exist yet, outside any repository, passes"
run_payload '{"agent_type":"reviewer-test","tool_name":"Write","tool_input":{"content":"x"}}'
assert_eq "$rc" 2 "a Write naming no file_path is refused"
run_payload '{"agent_type":"reviewer-test","tool_name":"Write","tool_input":{"file_path":7}}'
assert_eq "$rc" 2 "a file_path that is not a string is refused"

echo "reviewer-read-only: a reviewer commits and pushes nothing"
for cmd in 'git commit -m x' 'git push' 'git push origin HEAD' "git -C $REPO commit -am x" \
  'git --no-pager commit' 'git -c user.name=t commit -m x' 'cd /x && git commit -q; echo done' \
  'git add -A && git commit -m "probe"' 'git push --force-with-lease'; do
  run_tool reviewer-security Bash command "$cmd"
  assert_eq "rc=$rc first=$(first_line)" "rc=2 first=reviewer-read-only: refused=git-write" "refused: $cmd"
done
for cmd in 'git log --oneline -5' "git -C $REPO diff origin/main...HEAD" 'git cat-file commit HEAD' \
  'git commit-tree HEAD^{tree}' 'git status --porcelain' 'git show HEAD --stat' 'git log --grep=commit' \
  'echo committed' 'grep -rn "git push" docs/' 'git rev-list --count HEAD' 'git worktree list'; do
  run_tool reviewer-security Bash command "$cmd"
  assert_eq "$rc" 0 "passes: $cmd"
done
run_payload '{"agent_type":"reviewer-security","tool_name":"Bash","tool_input":{}}'
assert_eq "$rc" 0 "a Bash payload naming no command passes"
run_payload '{"agent_type":"reviewer-security","tool_name":"Bash","tool_input":{"command":["git","commit"]}}'
assert_eq "$rc" 2 "a command that is not a string is refused"

echo "reviewer-read-only: a payload it cannot read refuses"
run_payload '{"agent_type":"reviewer-test","tool_name":"Edit"'
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=reviewer-read-only: payload=invalid-json" \
  "a truncated JSON payload refuses rather than skipping the guard"
run_payload '{"agent_type":["reviewer-test"],"tool_name":"Edit"}'
assert_eq "$rc" 2 "an agent_type that is not a string refuses"
run_payload '{"agent_type":"reviewer-test","tool_name":false}'
assert_eq "$rc" 2 "a tool_name that is not a string refuses"
run_payload '{"agent_type":"reviewer-test","tool_name":"Read","tool_input":{"file_path":"x"}}'
assert_eq "$rc" 0 "a tool the hook does not judge passes"

echo "reviewer-read-only: git cannot say where a path is"
BROKEN_BIN="$TMP_ROOT/brokengit"
mkdir -p "$BROKEN_BIN"
cat >"$BROKEN_BIN/git" <<EOF
#!/usr/bin/env bash
echo "fatal: unable to read the repository configuration" >&2
exit 128
EOF
chmod +x "$BROKEN_BIN/git"
set +e
printf '{"agent_type":"reviewer-test","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$SCRATCH/fixture.rs" \
  | env HOME="$TMP_ROOT" PATH="$BROKEN_BIN:$PATH" "$BASH_BIN" "$HOOK" >/dev/null 2>"$TMP_ROOT/stderr"
rc=$?
set -e
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=reviewer-read-only: git=unreadable" \
  "a git failure that is not 'not a git repository' refuses the write"
assert_contains "$(cat "$TMP_ROOT/stderr")" "unable to read the repository configuration" "carries git's own failure"

echo "reviewer-read-only: without the tools that read the payload"
NOJQ_BIN="$TMP_ROOT/nojq"
mkdir -p "$NOJQ_BIN"
for tool in cat sed grep dirname git; do
  real="$(type -P "$tool" 2>/dev/null || true)"
  [ -n "$real" ] && [ -x "$real" ] || continue
  ln -sf "$real" "$NOJQ_BIN/$tool"
done
run_payload '{"agent_type":"generalist","tool_name":"Edit","tool_input":{"file_path":"x"}}' "$NOJQ_BIN"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=reviewer-read-only: missing-tools=jq" \
  "no jq refuses rather than guessing at the payload, whoever the agent is, and names it"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
