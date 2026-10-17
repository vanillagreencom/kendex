#!/usr/bin/env bash
# Tests for the reviewer-read-only hook.
#
# For a subagent whose agent_type starts with `reviewer-` the hook refuses
# every Edit, MultiEdit and NotebookEdit; a Write inside a git work tree
# unless it is the artifact, <dir>/tmp/review-*.json; and a Bash command
# running a Git write or discard verb. Pinned here: every other agent passes,
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
TMP_ROOT="$(mktemp -d)" || { echo "reviewer-read-only: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "reviewer-read-only: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "reviewer-read-only: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
BASH_BIN="$(command -v bash)"
ERR_FILE="$TMP_ROOT/stderr"

fgit() {
  env HOME="$TMP_ROOT" git "$@"
}

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/src"
fgit init -q "$REPO"
fgit -C "$REPO" config gc.auto 0
fgit -C "$REPO" config maintenance.auto false
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

# shellcheck source=lib/assert.sh
. "$TEST_DIR/lib/assert.sh"

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
assert_eq "$rc" 0 "a Write naming no file_path warns"
run_payload '{"agent_type":"reviewer-test","tool_name":"Write","tool_input":{"file_path":7}}'
assert_eq "$rc" 0 "a file_path that is not a string warns"

echo "reviewer-read-only: a reviewer commits and pushes nothing"
for cmd in 'git commit -m x' 'git push' 'git push origin HEAD' "git -C $REPO commit -am x" \
  'git --no-pager commit' 'git -c user.name=t commit -m x' 'cd /x && git commit -q; echo done' \
  'git add -A && git commit -m "probe"' 'git push --force-with-lease'; do
  run_tool reviewer-security Bash command "$cmd"
  assert_eq "rc=$rc first=$(first_line)" "rc=2 first=reviewer-read-only: refused=git-write" "refused: $cmd"
done
discard_rows() {
  local agent cmd other
  while IFS='|' read -r agent cmd; do
    run_tool "$agent" Bash command "$cmd"
    assert_eq "rc=$rc first=$(first_line)" "rc=2 first=reviewer-read-only: refused=git-discard" "refused for $agent: $cmd"
    for other in dev ''; do
      run_tool "$other" Bash command "$cmd"
      assert_eq "$rc" 0 "passes for agent '$other': $cmd"
    done
  done <<'ROWS'
reviewer-correctness|git checkout -- tools/ht-tools/src/main.rs
reviewer-correctness-ken-4159|git checkout -- tools/ht-tools/src/main.rs
reviewer-security|git checkout -- p
reviewer-security|git checkout HEAD -- p
reviewer-security|git -C d restore p
reviewer-security|git stash
reviewer-security|git stash pop
reviewer-security|git stash list
reviewer-security|git clean -fd
reviewer-security|git reset --hard
reviewer-security|git switch main
reviewer-security|cd x && git checkout -q .
ROWS
}
discard_rows

if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  skill_load_control checkout-allowed "$HOOK" \
    '    if printf '\''%s\n'\'' "$COMMAND" | grep -E -- "$GIT_DISCARD" >/dev/null; then' \
    '      case "$COMMAND" in *checkout*) exit 0 ;; esac' HOOK discard_rows \
    'refused for reviewer-correctness: git checkout -- tools/ht-tools/src/main.rs' \
    'refused for reviewer-correctness-ken-4159: git checkout -- tools/ht-tools/src/main.rs'
fi

for cmd in 'git checkout-index' 'git log --grep=stash' 'git diff' 'git log --oneline -5' "git -C $REPO diff origin/main...HEAD" 'git cat-file commit HEAD' \
  'git commit-tree HEAD^{tree}' 'git status --porcelain' 'git show HEAD --stat' 'git log --grep=commit' \
  'echo committed' 'grep -rn "git push" docs/' 'git rev-list --count HEAD' 'git worktree list'; do
  run_tool reviewer-security Bash command "$cmd"
  assert_eq "$rc" 0 "passes: $cmd"
done
run_payload '{"agent_type":"reviewer-security","tool_name":"Bash","tool_input":{}}'
assert_eq "$rc" 0 "a Bash payload naming no command passes"
run_payload '{"agent_type":"reviewer-security","tool_name":"Bash","tool_input":{"command":["git","commit"]}}'
assert_eq "$rc" 0 "a command that is not a string warns"

echo "reviewer-read-only: a payload it cannot read refuses"
run_payload '{"agent_type":"reviewer-test","tool_name":"Edit"'
assert_eq "rc=$rc first=$(first_line)" "rc=0 first=reviewer-read-only: payload=invalid-json" \
  "a truncated JSON payload refuses rather than skipping the guard"
run_payload '{"agent_type":["reviewer-test"],"tool_name":"Edit"}'
assert_eq "$rc" 0 "an agent_type that is not a string warns"
run_payload '{"agent_type":"reviewer-test","tool_name":false}'
assert_eq "$rc" 0 "a tool_name that is not a string warns"
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
assert_eq "rc=$rc first=$(first_line)" "rc=0 first=reviewer-read-only: git=unreadable" \
  "a git failure that is not 'not a git repository' refuses the write"
assert_contains "$(cat "$TMP_ROOT/stderr")" "unable to read the repository configuration" "carries git's own failure"

echo "reviewer-read-only: without the tools it runs"
# One world per declared dependency, each holding every other tool and not
# that one: the refusal names the missing tool and nothing is judged without
# it. A row per tool is what keeps the inventory honest — an absent grep does
# not stall this hook, it passes the call through.
# The shared payload runner measures the hook, not an early-closing pipe.
. "$TEST_DIR/lib/payload-rows.sh"
PAYLOAD_ROOT="$TMP_ROOT"
PAYLOAD_PREFIX='reviewer-read-only: '
PAYLOAD_BASH="$BASH_BIN"
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
    got=$(payload_run "$HOOK" "$PWD" "$bin" '{"agent_type":"generalist","tool_name":"Edit","tool_input":{"file_path":"x"}}')
    assert_eq "$got" "rc=0 first=missing-tools=$tool" \
      "without $tool the call warns, and the value names it"
    assert_eq "$(grep -cF -- "$PAYLOAD_PREFIX" "$TMP_ROOT/stderr")" 1 "without $tool warns once"
  done
  # A world holding none of them: the value is the whole list, in check order.
  # A row per tool cannot see an accumulator that overwrites instead of
  # appending, because only one name is ever missing in one.
  bin="$TMP_ROOT/without-everything"
  rm -rf -- "$bin"
  mkdir -p "$bin"
  got=$(payload_run "$HOOK" "$PWD" "$bin" '{"agent_type":"generalist","tool_name":"Edit","tool_input":{"file_path":"x"}}')
  assert_eq "$got" "rc=0 first=missing-tools=${1// /,}" \
    "with none of them the value is the whole list, in check order"
  assert_eq "$(grep -cF -- "$PAYLOAD_PREFIX" "$TMP_ROOT/stderr")" 1 "without all tools warns once"
  [ "$((PASS + FAIL))" -gt "$before" ] || { echo "tools: no row was asserted" >&2; exit 2; }
}
tools_table "jq git cat grep dirname"

echo
echo "pass: $PASS   fail: $FAIL"
[ "$FAIL" -eq 0 ]
