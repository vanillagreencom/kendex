#!/usr/bin/env bash
# Tests for the reviewer-stop-check hook on Codex.
#
# Codex 0.160.0's SubagentStop payload names the parent thread's rollout as
# `transcript_path` and the subagent's own as `agent_transcript_path`, which
# may be null (Codex hooks reference). The hook reads the second where its
# install directory is Codex's: `.codex/hooks` at project scope, or
# `$CODEX_HOME/hooks` at global scope. Every case here gives the two fields
# rollouts naming different worktrees, one dirty and one clean, so the field
# the hook read is the worktree its refusal names. reviewer-stop-check.test.sh
# holds every rule that does not depend on the harness.
#
# HOOK_UNDER_TEST overrides the script under test; the must-fail controls at
# the end run these rows against a copy with one Codex arm planted out.
set -euo pipefail

unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/reviewer-stop-check.sh}"
TMP_ROOT="$(mktemp -d)" || { echo "reviewer-stop-check-codex: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "reviewer-stop-check-codex: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "reviewer-stop-check-codex: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
BASH_BIN="$(command -v bash)"
ERR_FILE="$TMP_ROOT/stderr"
PASS=0
FAIL=0
# shellcheck source=lib/assert.sh
. "$TEST_DIR/lib/assert.sh"
# shellcheck source=lib/first-line.sh
. "$TEST_DIR/lib/first-line.sh"

new_repo() { # NAME -> path
  local repo="$TMP_ROOT/repo.$1"
  mkdir -p "$repo"
  env -i PATH="$PATH" HOME="$TMP_ROOT" git init -q "$repo"
  printf 'tmp/\n' >"$repo/.gitignore"
  env -i PATH="$PATH" HOME="$TMP_ROOT" git -C "$repo" add -A
  env -i PATH="$PATH" HOME="$TMP_ROOT" git -C "$repo" \
    -c user.email=t@example.com -c user.name=t commit -q -m init
  printf '%s' "$repo"
}

# A Codex rollout whose last assistant message returns REPO's review artifact.
rollout_for() { # REPO NAME -> path
  local t="$TMP_ROOT/$2.jsonl"
  jq -n -c --arg text "Verdict: pass
File: $1/tmp/review-reviewer-test-20261002-101010.json" \
    '{type:"response_item",payload:{type:"message",role:"assistant",
      content:[{type:"output_text",text:$text}]}}' >"$t"
  printf '%s' "$t"
}

DIRTY="$(new_repo dirty)"
printf 'probe\n' >"$DIRTY/probe.sh"
CLEAN="$(new_repo clean)"
CHILD_ROLLOUT="$(rollout_for "$DIRTY" child)"
PARENT_ROLLOUT="$(rollout_for "$CLEAN" parent)"
# The project the hook runs in, where kendex installs its Codex copy, and a
# Codex home whose directory name says nothing about Codex.
PROJECT="$(new_repo project)"
CODEX_ACCOUNT="$TMP_ROOT/accounts/one"

# run INSTALL_DIR AGENT_ID AGENT_TRANSCRIPT [ENV=VAL...] — the hook copied
# into INSTALL_DIR and run there as Codex runs it, from the project, with
# the payload Codex sends a reviewer subagent's stop. AGENT_TRANSCRIPT `null`
# is the field as Codex serializes a thread with no rollout.
run() {
  local dir="$1" id="$2" agent_transcript="$3" payload
  shift 3
  mkdir -p "$dir"
  cp -- "$HOOK" "$dir/reviewer-stop-check.sh"
  payload=$(jq -n -c --arg id "$id" --arg parent "$PARENT_ROLLOUT" --arg child "$agent_transcript" \
    --arg cwd "$PROJECT" '{session_id:"019a",transcript_path:$parent,cwd:$cwd,
      hook_event_name:"SubagentStop",permission_mode:"default",turn_id:"t1",
      agent_id:$id,agent_type:"reviewer-test",
      agent_transcript_path:(if $child == "null" then null else $child end),
      stop_hook_active:false,last_assistant_message:"Verdict: pass",model:"gpt-6.1"}')
  set +e
  (cd -- "$PROJECT" && env -i PATH="$PATH" HOME="$TMP_ROOT" "$@" \
    "$BASH_BIN" "$dir/reviewer-stop-check.sh" <<<"$payload") >/dev/null 2>"$ERR_FILE"
  rc=$?
  set -e
}

codex_rows() {
  run "$PROJECT/.codex/hooks" p1 "$CHILD_ROLLOUT"
  assert_eq "rc=$rc first=$(first_line)" "rc=2 first=reviewer-stop-check: worktree=$DIRTY" \
    "a project Codex install reads the subagent's own rollout"
  run "$CODEX_ACCOUNT/hooks" g1 "$CHILD_ROLLOUT" CODEX_HOME="$CODEX_ACCOUNT"
  assert_eq "rc=$rc first=$(first_line)" "rc=2 first=reviewer-stop-check: worktree=$DIRTY" \
    "a global install under CODEX_HOME reads the subagent's own rollout"
  run "$PROJECT/.codex/hooks" n1 null
  assert_eq "rc=$rc first=$(first_line)" "rc=2 first=reviewer-stop-check: transcript=unreadable" \
    "a null agent_transcript_path refuses"
}

echo "=== reviewer-stop-check: codex ==="
codex_rows
# The same payload reaching a copy installed for another harness reads
# transcript_path, as Claude Code's SubagentStop is read.
run "$PROJECT/.claude/hooks" c1 "$CHILD_ROLLOUT"
assert_eq "rc=$rc first=$(first_line)" "rc=0 first=-" \
  "a Claude install reads transcript_path, here the parent's clean worktree"

# --- controls -----------------------------------------------------------------
# Each Codex arm reassigned to the field every other harness reads, in a copy:
# exactly the rows that arm decides fail. The project arm also decides the
# null row, which then reads the parent's rollout and passes.
control() { # NAME OLD NEW FAILED-ROW...
  local name="$1" old="$2" new="$3" mutant="$TMP_ROOT/$1.sh" out row
  shift 3
  assert_eq "$(grep -c -F -- "$old" "$HOOK")" "1" "control $name finds its arm"
  OLD="$old" NEW="$new" perl -pe 's/\Q$ENV{OLD}\E/$ENV{NEW}/' -- "$HOOK" >"$mutant"
  assert_eq "$(grep -c -F -- "$old" "$mutant")" "0" "control $name planted its defect"
  out="$(HOOK_UNDER_TEST="$mutant" "$BASH_BIN" "${BASH_SOURCE[0]}" 2>&1 || true)"
  assert_eq "$(grep -c '^  FAIL  ' <<<"$out" || true)" "$#" "control $name: $# rows fail"
  for row in "$@"; do
    assert_eq "$(grep -c -F -x "  FAIL  $row" <<<"$out" || true)" "1" "control $name: '$row' fails"
  done
}
if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  control project-arm '*/.codex/hooks) TRANSCRIPT_FIELD=agent_transcript_path' \
    '*/.codex/hooks) TRANSCRIPT_FIELD=transcript_path' \
    "a project Codex install reads the subagent's own rollout" \
    "a null agent_transcript_path refuses"
  control global-arm '"${CODEX_HOME%/}/hooks" ]; then' '"${CODEX_HOME%/}/never" ]; then' \
    "a global install under CODEX_HOME reads the subagent's own rollout"
fi

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
