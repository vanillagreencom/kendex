#!/usr/bin/env bash
# The doc-drift-check hook as Copilot runs it: installed under .github/hooks
# beside the lane-mail-check hook, registered on agentStop, and handed that
# event's payload in the shape Copilot CLI 1.0.91 sent tools/harness-smoke's
# copilot event:agentStop row: the session as sessionId, stop_hook_active, and
# a transcriptPath that names the lead's transcript at the lead's stop and at
# a custom subagent's, whose sessionId is its own. Whose stop it is, is the
# lane-mail-check hook's caller answer: a subagent's stop passes, and a stop
# that hook cannot name is judged as the lead's. A block is `decision: block`
# with the text as `reason` on stdout at exit 0, the answer Copilot holds a
# turn on.
#
# A row is read as `rc=<status> decision=<stdout .decision or -> first=<line
# 1 of stderr or ->`. The controls at the end run this suite against mutants of
# the hook, one per rule, each of which must turn its row red.
#
# HOOK_UNDER_TEST overrides the doc-drift-check script the fixture installs.
set -euo pipefail

unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$(cd "$TEST_DIR/.." && pwd)"
HOOK="${HOOK_UNDER_TEST:-$HOOKS/doc-drift-check.sh}"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)" || { echo "doc-drift-check-copilot: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "doc-drift-check-copilot: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "doc-drift-check-copilot: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
BASH_BIN="$(command -v bash)"
ERR_FILE="$TMP_ROOT/stderr"
OUT_FILE="$TMP_ROOT/stdout"

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$label" "$want" "$got"
  fi
}

# shellcheck source=lib/first-line.sh
. "$TEST_DIR/lib/first-line.sh"

fgit() {
  env HOME="$TMP_ROOT" git "$@"
}

# A repository on main whose crates/core changed with neither of the two
# documents covering it, its AGENTS.md and an architecture topic: a stale set
# of two. The hooks sit where kendex renders them for Copilot, committed with
# the rest, so they are no change of their own; JUDGE=absent leaves
# lane-mail-check out.
REPO=""
new_repo() { # NAME [absent]
  REPO="$TMP_ROOT/repo.$1"
  mkdir -p "$REPO/crates/core/src" "$REPO/docs/architecture" "$REPO/.github/hooks"
  fgit init -q "$REPO"
  fgit -C "$REPO" symbolic-ref HEAD refs/heads/main
  fgit -C "$REPO" config user.email t@example.com
  fgit -C "$REPO" config user.name t
  printf '# root\n' >"$REPO/AGENTS.md"
  printf '# core\n' >"$REPO/crates/core/AGENTS.md"
  printf '# Core\n\nCovers: crates/core\n' >"$REPO/docs/architecture/core.md"
  printf 'pub fn a() {}\n' >"$REPO/crates/core/src/lib.rs"
  cp "$HOOK" "$REPO/.github/hooks/doc-drift-check.sh"
  [ "${2:-}" = absent ] || cp "$HOOKS/lane-mail-check.sh" "$REPO/.github/hooks/lane-mail-check.sh"
  fgit -C "$REPO" add -A
  fgit -C "$REPO" commit -q -m init
  printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
}

# The lead's transcript sits in the session-state directory named for the
# lead's session; a subagent's stop names the same file under its own session.
LEAD_TRANSCRIPT="$TMP_ROOT/session-state/lead-1/events.jsonl"
mkdir -p "${LEAD_TRANSCRIPT%/*}"
: >"$LEAD_TRANSCRIPT"

run_stop() { # SESSION [ACTIVE]
  local payload
  payload=$(jq -nc --arg s "$1" --arg cwd "$REPO" --arg t "$LEAD_TRANSCRIPT" --argjson a "${2:-false}" \
    '{sessionId:$s, timestamp:1, cwd:$cwd, transcriptPath:$t, stopReason:"end_turn", stop_hook_active:$a}')
  set +e
  (cd "$REPO" && env HOME="$TMP_ROOT" "$BASH_BIN" "$REPO/.github/hooks/doc-drift-check.sh" <<<"$payload") \
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

echo "=== doc-drift-check on Copilot's agentStop ==="
# Each row is one stop in a repository of its own unless it names `same`,
# which stops again in the row above's.
n=0
while IFS='|' read -r label world session active want; do
  n=$((n + 1))
  case "$world" in
    same) ;;
    absent) new_repo "$n" absent ;;
    *) new_repo "$n" ;;
  esac
  run_stop "$session" "$active"
  assert_eq "$(verdict)" "$want" "$label"
done <<'ROWS'
the lead's stop over stale documents is held with the block answer at exit 0|fresh|lead-1|false|rc=0 decision=block first=doc-drift-check: stale=2
the lead's next stop naming the same set passes|same|lead-1|false|rc=0 decision=- first=-
a custom subagent's stop, its own session naming the lead's transcript, passes|fresh|sub-1|false|rc=0 decision=- first=-
a stop the harness continued passes|fresh|lead-1|true|rc=0 decision=- first=-
with no lane-mail-check beside it, a subagent's stop is judged as the lead's|absent|sub-1|false|rc=0 decision=block first=doc-drift-check: stale=2
ROWS

# The reason Copilot hands the lead is the text the stderr carries.
new_repo reason
run_stop lead-1
assert_eq "$(jq -r '.reason' "$OUT_FILE" 2>/dev/null)" "$(cat "$ERR_FILE")" \
  "the block's reason is the refusal text, keyed line first"

# --- controls ----------------------------------------------------------------
# Each rule removed from a copy of the hook turns its row red: the install's
# answer shape, the caller's question, the camelCase session read, and the
# install's harness read.
if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  c=0
  while IFS='@' read -r old new row; do
    c=$((c + 1))
    MUTANT="$TMP_ROOT/mutant-$c.sh"
    cp "$HOOK" "$MUTANT"
    assert_eq "$(grep -c -x -F -- "$old" "$MUTANT")" "1" "control $c finds: $old"
    OLD="$old" NEW="$new" perl -i -pe 's/^\Q$ENV{OLD}\E$/$ENV{NEW}/' "$MUTANT"
    assert_eq "$(grep -c -x -F -- "$old" "$MUTANT")" "0" "control $c removed it"
    CONTROL_OUT="$(HOOK_UNDER_TEST="$MUTANT" "$BASH_BIN" "${BASH_SOURCE[0]}" 2>&1 || true)"
    assert_eq "$(grep -c -x -F -- "  FAIL  $row" <<<"$CONTROL_OUT")" "1" "control $c: without it, '$row' fails"
  done <<'CONTROLS'
  if [ "$INSTALL" = copilot ] && command -v jq >/dev/null 2>&1; then@  if false; then@the lead's stop over stale documents is held with the block answer at exit 0
  [ "$CALLER" != subagent ] || exit 0@  :@a custom subagent's stop, its own session naming the lead's transcript, passes
  [str(if .session_id != null then .session_id else .sessionId end),@  [str(.session_id),@the lead's next stop naming the same set passes
  */.github/hooks) INSTALL=copilot ;;@  */.github/hooks-never) INSTALL=copilot ;;@the lead's stop over stale documents is held with the block answer at exit 0
CONTROLS
fi

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
