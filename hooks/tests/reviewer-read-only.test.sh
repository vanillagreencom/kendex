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
# HOOK_UNDER_TEST overrides the script under test so the must-fail controls
# (a no-op hook, an always-refuse hook) can be run against these same
# assertions.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/reviewer-read-only.sh}"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
BASH_BIN="$(command -v bash)"

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

# A JSON string, escaped the way the harness sends it.
json_str() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# run AGENT_TYPE TOOL FIELD VALUE -> rc, stderr in $err. An empty AGENT_TYPE
# omits the field, as the main session's payload does.
run_tool() {
  local agent="$1" tool="$2" field="$3" value="$4" payload
  if [ -n "$agent" ]; then
    payload=$(printf '{"agent_type":"%s","tool_name":"%s","tool_input":{"%s":"%s"}}' \
      "$agent" "$tool" "$field" "$(json_str "$value")")
  else
    payload=$(printf '{"tool_name":"%s","tool_input":{"%s":"%s"}}' \
      "$tool" "$field" "$(json_str "$value")")
  fi
  run_payload "$payload"
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
  assert_eq "$rc" 2 "a reviewer's $tool is refused"
done
run_tool reviewer-correctness Edit file_path "$REPO/src/lib.rs"
assert_contains "$err" "a reviewer edits nothing" "the refusal names the rule"
assert_contains "$err" "tmp/review-reviewer-correctness-" "the refusal names the one path a reviewer writes"
assert_not_contains "$err" "bypass" "never suggests bypassing"
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
assert_eq "$rc" 2 "a Write onto a tracked file is refused"
assert_contains "$err" "$REPO/src/lib.rs" "the refusal names the path"
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
  assert_eq "$rc" 2 "refused: $cmd"
done
run_tool reviewer-security Bash command 'git commit -m x'
assert_contains "$err" "commits and pushes nothing" "the refusal names the rule"
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
assert_eq "$rc" 2 "a truncated JSON payload refuses rather than skipping the guard"
assert_contains "$err" "not valid JSON" "the parse refusal names the cause"
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
assert_eq "$rc" 2 "a git failure that is not 'not a git repository' refuses the write"
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
assert_eq "$rc" 2 "no jq refuses rather than guessing at the payload, whoever the agent is"
assert_contains "$err" "required to read the hook payload" "the refusal names what is missing"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
