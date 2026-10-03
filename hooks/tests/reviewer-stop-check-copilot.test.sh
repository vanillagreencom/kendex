#!/usr/bin/env bash
# The reviewer-stop-check hook as Copilot runs it: installed under
# .github/hooks, registered on subagentStop, and handed that event's payload in
# the shape Copilot CLI 1.0.91 sent tools/harness-smoke's copilot
# event:subagentStop row: the lead's sessionId and transcriptPath, the
# subagent's own session as agentId, the custom agent's name as agentType, its
# reply as response, and no stop_hook_active. The worktree is read from the
# reply, since the lead's transcript holds every agent of the session, and a
# block is `decision: block` with the text as `reason` on stdout at exit 0,
# the answer Copilot holds a subagent on. With no stop_hook_active, every
# refusal once the agent id is read is recorded per agent, so the same
# subagent's next stop passes.
#
# A row is read as `rc=<status> decision=<stdout .decision or -> first=<line
# 1 of stderr or ->`. The controls at the end run these rows against mutants
# of the hook, one per rule, each of which must turn its row red.
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

# shellcheck source=lib/assert.sh
. "$TEST_DIR/lib/assert.sh"
# shellcheck source=lib/first-line.sh
. "$TEST_DIR/lib/first-line.sh"

fgit() {
  env HOME="$TMP_ROOT" git "$@"
}

# Every command the hook runs but jq, for the row that runs it without one.
NO_JQ="$TMP_ROOT/no-jq"
mkdir -p "$NO_JQ"
for tool in git cat grep tail mkdir; do
  ln -s -- "$(command -v "$tool")" "$NO_JQ/$tool"
done

# A reviewed repository with the hook installed where kendex renders it for
# Copilot at project scope, under WORLD, the scratch directory of one run of
# the rows. The hook runs from the repository root, as Copilot runs a
# project's hooks.
new_repo() { # NAME -> path
  local repo="$WORLD/repo.$1"
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

# The hook where kendex renders it for Copilot at global scope: in an account's
# hooks directory, beside the <name>.json registry document only a copilot
# install leaves.
new_account() { # -> path of the installed hook
  local hooks="$WORLD/cop-home/.copilot-work/hooks"
  mkdir -p "$hooks"
  cp "$HOOK" "$hooks/reviewer-stop-check.sh"
  printf '{"version":1,"hooks":{}}\n' >"$hooks/reviewer-stop-check.json"
  printf '%s' "$hooks/reviewer-stop-check.sh"
}

# run REPO AGENT_TYPE AGENT_ID RESPONSE [PATH] [HOOK] -> rc, stdout in
# OUT_FILE, stderr in ERR_FILE. HOOK defaults to the repository's project
# install. The transcript is the lead's, in the session-state directory named
# for the lead's session.
run_copilot() {
  local repo="$1" hook="${6:-$1/.github/hooks/reviewer-stop-check.sh}" payload
  payload=$(jq -nc --arg cwd "$repo" --arg t "$LEAD_TRANSCRIPT" --arg type "$2" --arg id "$3" --arg r "$4" \
    '{sessionId:"lead-1", timestamp:1, cwd:$cwd, transcriptPath:$t, agentId:$id, agentType:$type,
      agentName:$type, agentDisplayName:$type, response:$r, stopReason:"end_turn"}')
  set +e
  (cd "$repo" && env HOME="$TMP_ROOT" PATH="${5:-$PATH}" "$BASH_BIN" "$hook" <<<"$payload") \
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

copilot_rows() {
  local label repo type id reply path install want clean dirty none account marker
  WORLD=$(mktemp -d "$TMP_ROOT/world.XXXXXX") || { echo "reviewer-stop-check-copilot: world=mktemp-failed" >&2; exit 1; }
  LEAD_TRANSCRIPT="$WORLD/session-state/lead-1/events.jsonl"
  mkdir -p "${LEAD_TRANSCRIPT%/*}"
  clean="$(new_repo clean)"
  dirty="$(new_repo dirty)"
  printf 'probe\n' >"$dirty/probe.sh"
  none="$(new_repo none)"
  account="$(new_account)"
  # The lead's transcript names the dirty repository's artifact: a hook reading
  # it instead of the reply would block the clean review below.
  printf '{"type":"assistant.message","data":{"content":"File: %s/tmp/review-reviewer-other-20261002-090909.json"}}\n' "$dirty" \
    >"$LEAD_TRANSCRIPT"

  while IFS='|' read -r label repo type id reply path install want; do
    case "$repo" in clean) repo=$clean ;; dirty) repo=$dirty ;; none) repo=$none ;; esac
    case "$reply" in
      artifact) reply=$(reply_for "$repo") ;;
      bare) reply='Verdict: pass' ;;
      unreadable) reply='File: /nonexistent/wt/tmp/review-reviewer-test-1.json' ;;
    esac
    case "$path" in all) path=$PATH ;; no-jq) path=$NO_JQ ;; esac
    case "$install" in project) install="$repo/.github/hooks/reviewer-stop-check.sh" ;; account) install=$account ;; esac
    run_copilot "$repo" "$type" "$id" "$reply" "$path" "$install"
    assert_eq "$(verdict)" "${want//@REPO@/$repo}" "$label"
  done <<'ROWS'
a reviewer whose reply names a clean worktree passes, whatever the lead's transcript names|clean|reviewer-test|sub-1|artifact|all|project|rc=0 decision=- first=-
a reviewer whose reply names a dirty worktree is held with the block answer at exit 0|dirty|reviewer-test|sub-2|artifact|all|project|rc=0 decision=block first=reviewer-stop-check: worktree=@REPO@
the same subagent's next stop passes|dirty|reviewer-test|sub-2|artifact|all|project|rc=0 decision=- first=-
another reviewer subagent over the same dirty worktree is held|dirty|reviewer-test|sub-3|artifact|all|project|rc=0 decision=block first=reviewer-stop-check: worktree=@REPO@
a reviewer whose reply names no artifact is held|none|reviewer-test|sub-4|bare|all|project|rc=0 decision=block first=reviewer-stop-check: artifact=missing
a subagent that is no reviewer passes over a dirty worktree|dirty|smoke-child|sub-5|artifact|all|project|rc=0 decision=- first=-
a reviewer whose reply names a worktree git cannot read is held|clean|reviewer-test|sub-7|unreadable|all|project|rc=0 decision=block first=reviewer-stop-check: git=rev-parse --show-toplevel
the same subagent's next stop over that unreadable worktree passes|clean|reviewer-test|sub-7|unreadable|all|project|rc=0 decision=- first=-
with jq off PATH a reviewer is held with the block answer, built without jq|dirty|reviewer-test|sub-8|artifact|no-jq|project|rc=0 decision=block first=reviewer-stop-check: missing-tools=jq
a reviewer over a dirty worktree is held with the block answer at exit 0 from a global-scope install|dirty|reviewer-test|sub-9|artifact|all|account|rc=0 decision=block first=reviewer-stop-check: worktree=@REPO@
ROWS

  # The reason Copilot hands the subagent is the text the stderr carries.
  run_copilot "$dirty" reviewer-test sub-6 "$(reply_for "$dirty")"
  assert_eq "$(jq -r '.reason' "$OUT_FILE" 2>/dev/null)" "$(cat "$ERR_FILE")" \
    "the block's reason is the refusal text, keyed line first"
  [ -e "$dirty/.git/kendex/reviewer-stop/sub-6" ] && marker=yes || marker=no
  assert_eq "marker=$marker" "marker=yes" "the block records the subagent's agentId under the reviewed repository"
}

echo "=== reviewer-stop-check on Copilot's subagentStop ==="
copilot_rows

# --- controls ----------------------------------------------------------------
# Each rule a line planted in a copy of the hook undoes turns its row red: the
# install's answer shape, the answer built without jq, the camelCase agent
# type and id reads, the reply as the artifact source, each of the install's
# two harness reads, and the per-agent record of every refusal.
if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  skill_load_control answer "$HOOK" '  if [ "$INSTALL" = copilot ]; then' \
    '    exit 2' HOOK copilot_rows \
    'a reviewer whose reply names a dirty worktree is held with the block answer at exit 0'
  skill_load_control answer-jq "$HOOK" '  if [ "$INSTALL" = copilot ]; then' \
    '    command -v jq >/dev/null 2>&1 || exit 2' HOOK copilot_rows \
    'with jq off PATH a reviewer is held with the block answer, built without jq'
  skill_load_control agent-type "$HOOK" 'AGENT_TYPE=${FIELDS%%"$TAB"*}' \
    "AGENT_TYPE=\$(printf '%s' \"\$INPUT\" | jq -r '.agent_type // \"\"')" HOOK copilot_rows \
    'a reviewer whose reply names a dirty worktree is held with the block answer at exit 0'
  skill_load_control agent-id "$HOOK" 'AGENT_ID=${REST%%"$TAB"*}' \
    "AGENT_ID=\$(printf '%s' \"\$INPUT\" | jq -r '.agent_id // \"\"')" HOOK copilot_rows \
    "the same subagent's next stop passes"
  skill_load_control reply "$HOOK" '  MENTIONS=$(grep -oE "$ARTIFACT_PATTERN" <<<"$REPLY" 2>&1)' \
    '  MENTIONS=$(grep -oE "$ARTIFACT_PATTERN" -- "$TRANSCRIPT" 2>&1)' HOOK copilot_rows \
    "a reviewer whose reply names a clean worktree passes, whatever the lead's transcript names"
  skill_load_control install-dir "$HOOK" '  */.github/hooks) INSTALL=copilot' \
    'INSTALL=""' HOOK copilot_rows \
    'a reviewer whose reply names a dirty worktree is held with the block answer at exit 0'
  skill_load_control install-registry "$HOOK" '[ -f "${BASH_SOURCE[0]%.sh}.json" ]; then INSTALL=copilot' \
    'INSTALL=""' HOOK copilot_rows \
    'a reviewer over a dirty worktree is held with the block answer at exit 0 from a global-scope install'
  skill_load_control every-refusal "$HOOK" '[ "$INSTALL" != copilot ] || MARK_EVERY_REFUSAL=1' \
    'MARK_EVERY_REFUSAL=0' HOOK copilot_rows \
    "the same subagent's next stop over that unreadable worktree passes"
fi

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
