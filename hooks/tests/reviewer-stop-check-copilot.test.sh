#!/usr/bin/env bash
# The reviewer-stop-check hook as Copilot runs it: installed under
# .github/hooks, registered on subagentStop, and handed that event's payload in
# the shape Copilot CLI 1.0.91 sent tools/harness-smoke's copilot
# event:subagentStop row: the lead's sessionId and transcriptPath, the
# subagent's own session as agentId, the custom agent's name as agentType, its
# reply as response, and no stop_hook_active. The worktree is read from the
# reply, since the lead's transcript holds every agent of the session, and a
# block is `decision: block` with the text as `reason` on stdout at exit 0,
# the answer Copilot holds a subagent on.
#
# A row is read as `rc=<status> decision=<stdout .decision or -> first=<line
# 1 of stderr or ->`. The controls at the end run this suite against mutants of
# the hook, one per rule, each of which must turn its row red.
#
# HOOK_UNDER_TEST overrides the script the fixture installs.
set -euo pipefail

unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/reviewer-stop-check.sh}"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)" || { echo "reviewer-stop-check-copilot: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "reviewer-stop-check-copilot: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "reviewer-stop-check-copilot: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
BASH_BIN="$(command -v bash)"
ERR_FILE="$TMP_ROOT/stderr"
OUT_FILE="$TMP_ROOT/stdout"

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

# shellcheck source=lib/first-line.sh
. "$TEST_DIR/lib/first-line.sh"

fgit() {
  env HOME="$TMP_ROOT" git "$@"
}

# A reviewed repository with the hook installed where kendex renders it for
# Copilot. The hook runs from the repository root, as Copilot runs a project's
# hooks.
new_repo() { # NAME -> path
  local repo="$TMP_ROOT/repo.$1"
  mkdir -p "$repo/src" "$repo/.github/hooks"
  fgit init -q "$repo"
  fgit -C "$repo" config user.email t@example.com
  fgit -C "$repo" config user.name t
  printf 'pub fn a() {}\n' >"$repo/src/lib.rs"
  printf 'tmp/\n' >"$repo/.gitignore"
  cp "$HOOK" "$repo/.github/hooks/reviewer-stop-check.sh"
  fgit -C "$repo" add -A
  fgit -C "$repo" commit -q -m init
  printf '%s' "$repo"
}

# The lead's transcript, in the session-state directory named for the lead's
# session. LEAD_NAMES, where set, is a worktree whose artifact the lead's
# transcript mentions, as a lead that ran another reviewer would hold.
LEAD_TRANSCRIPT="$TMP_ROOT/session-state/lead-1/events.jsonl"
mkdir -p "${LEAD_TRANSCRIPT%/*}"

# run REPO AGENT_TYPE AGENT_ID RESPONSE -> rc, stdout in OUT_FILE, stderr in ERR_FILE
run_copilot() {
  local repo="$1" payload
  payload=$(jq -nc --arg cwd "$repo" --arg t "$LEAD_TRANSCRIPT" --arg type "$2" --arg id "$3" --arg r "$4" \
    '{sessionId:"lead-1", timestamp:1, cwd:$cwd, transcriptPath:$t, agentId:$id, agentType:$type,
      agentName:$type, agentDisplayName:$type, response:$r, stopReason:"end_turn"}')
  set +e
  (cd "$repo" && env HOME="$TMP_ROOT" "$BASH_BIN" "$repo/.github/hooks/reviewer-stop-check.sh" <<<"$payload") \
    >"$OUT_FILE" 2>"$ERR_FILE"
  rc=$?
  set -e
}
verdict() {
  local decision
  decision=$(jq -r '.decision // "-"' "$OUT_FILE" 2>/dev/null) || decision=unparseable
  [ -s "$OUT_FILE" ] || decision=-
  printf 'rc=%s decision=%s first=%s' "$rc" "$decision" "$(first_line)"
}
reply_for() { # REPO
  printf 'Verdict: pass\nFile: %s/tmp/review-reviewer-test-20261002-101010.json\n' "$1"
}

echo "=== reviewer-stop-check on Copilot's subagentStop ==="
CLEAN="$(new_repo clean)"
DIRTY="$(new_repo dirty)"
printf 'probe\n' >"$DIRTY/probe.sh"
NONE="$(new_repo none)"
# The lead's transcript names the dirty repository's artifact: a hook reading
# it instead of the reply would block the clean review below.
printf '{"type":"assistant.message","data":{"content":"File: %s/tmp/review-reviewer-other-20261002-090909.json"}}\n' "$DIRTY" \
  >"$LEAD_TRANSCRIPT"

while IFS='|' read -r label repo type id reply want; do
  case "$repo" in clean) repo=$CLEAN ;; dirty) repo=$DIRTY ;; none) repo=$NONE ;; esac
  case "$reply" in artifact) reply=$(reply_for "$repo") ;; bare) reply='Verdict: pass' ;; esac
  run_copilot "$repo" "$type" "$id" "$reply"
  assert_eq "$(verdict)" "${want//@REPO@/$repo}" "$label"
done <<'ROWS'
a reviewer whose reply names a clean worktree passes, whatever the lead's transcript names|clean|reviewer-test|sub-1|artifact|rc=0 decision=- first=-
a reviewer whose reply names a dirty worktree is held with the block answer at exit 0|dirty|reviewer-test|sub-2|artifact|rc=0 decision=block first=reviewer-stop-check: worktree=@REPO@
the same subagent's next stop passes|dirty|reviewer-test|sub-2|artifact|rc=0 decision=- first=-
another reviewer subagent over the same dirty worktree is held|dirty|reviewer-test|sub-3|artifact|rc=0 decision=block first=reviewer-stop-check: worktree=@REPO@
a reviewer whose reply names no artifact is held|none|reviewer-test|sub-4|bare|rc=0 decision=block first=reviewer-stop-check: artifact=missing
a subagent that is no reviewer passes over a dirty worktree|dirty|smoke-child|sub-5|artifact|rc=0 decision=- first=-
ROWS

# The reason Copilot hands the subagent is the text the stderr carries.
run_copilot "$DIRTY" reviewer-test sub-6 "$(reply_for "$DIRTY")"
assert_eq "$(jq -r '.reason' "$OUT_FILE" 2>/dev/null)" "$(cat "$ERR_FILE")" \
  "the block's reason is the refusal text, keyed line first"
[ -e "$DIRTY/.git/kendex/reviewer-stop/sub-6" ] && marker=yes || marker=no
assert_eq "marker=$marker" "marker=yes" "the block records the subagent's agentId under the reviewed repository"

# --- controls ----------------------------------------------------------------
# Each rule removed from a copy of the hook turns its row red: the install's
# answer shape, the camelCase agent type and id reads, the reply as the artifact source,
# and the install's harness read.
if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  n=0
  while IFS='@' read -r old new row; do
    n=$((n + 1))
    MUTANT="$TMP_ROOT/mutant-$n.sh"
    cp "$HOOK" "$MUTANT"
    assert_eq "$(grep -c -x -F -- "$old" "$MUTANT")" "1" "control $n finds: $old"
    OLD="$old" NEW="$new" perl -i -pe 's/^\Q$ENV{OLD}\E$/$ENV{NEW}/' "$MUTANT"
    assert_eq "$(grep -c -x -F -- "$old" "$MUTANT")" "0" "control $n removed it"
    CONTROL_OUT="$(HOOK_UNDER_TEST="$MUTANT" "$BASH_BIN" "${BASH_SOURCE[0]}" 2>&1 || true)"
    assert_eq "$(grep -c -x -F -- "  FAIL  $row" <<<"$CONTROL_OUT")" "1" "control $n: without it, '$row' fails"
  done <<'CONTROLS'
  if [ "$INSTALL" = copilot ] && command -v jq >/dev/null 2>&1; then@  if false; then@a reviewer whose reply names a dirty worktree is held with the block answer at exit 0
  [str(either(.agent_type; .agentType)),@  [str(.agent_type),@a reviewer whose reply names a dirty worktree is held with the block answer at exit 0
   (str(either(.agent_id; .agentId)) | if . != "" and gsub("[A-Za-z0-9_-]"; "") == "" then . else "" end),@   (str(.agent_id) | if . != "" and gsub("[A-Za-z0-9_-]"; "") == "" then . else "" end),@the same subagent's next stop passes
  MENTIONS=$(grep -oE "$ARTIFACT_PATTERN" <<<"$REPLY" 2>&1)@  MENTIONS=$(grep -oE "$ARTIFACT_PATTERN" -- "$TRANSCRIPT" 2>&1)@a reviewer whose reply names a clean worktree passes, whatever the lead's transcript names
  */.github/hooks) INSTALL=copilot ;;@  */.github/hooks-never) INSTALL=copilot ;;@a reviewer whose reply names a dirty worktree is held with the block answer at exit 0
CONTROLS
fi

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
