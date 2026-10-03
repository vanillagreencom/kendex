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
# 1 of stderr or ->`. The controls at the end run these rows against mutants
# of the hook, one per rule, each of which must turn its row red.
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

# shellcheck source=lib/assert.sh
. "$TEST_DIR/lib/assert.sh"
# shellcheck source=lib/first-line.sh
. "$TEST_DIR/lib/first-line.sh"

fgit() {
  env HOME="$TMP_ROOT" git "$@"
}

# The payload readers but jq, for the row that runs the hook without one.
NO_JQ="$TMP_ROOT/no-jq"
mkdir -p "$NO_JQ"
ln -s -- "$(command -v cat)" "$NO_JQ/cat"

# A repository on main whose crates/core changed with neither of the two
# documents covering it, its AGENTS.md and an architecture topic: a stale set
# of two. The hooks sit where kendex renders them for Copilot at project
# scope, committed with the rest, so they are no change of their own; absent
# leaves lane-mail-check out. account puts both at global scope instead, in an
# account's hooks directory beside the <name>.json registry document only a
# copilot install leaves. Each repository is under WORLD, the scratch directory
# of one run of the rows, and INSTALLED names the doc-drift-check it runs.
REPO=""
INSTALLED=""
new_repo() { # NAME [absent|account]
  local hooks name
  REPO="$WORLD/repo.$1"
  hooks="$REPO/.github/hooks"
  [ "${2:-}" != account ] || hooks="$WORLD/cop-home.$1/.copilot-work/hooks"
  mkdir -p "$REPO/crates/core/src" "$REPO/docs/architecture" "$hooks"
  fgit init -q "$REPO"
  fgit -C "$REPO" symbolic-ref HEAD refs/heads/main
  fgit -C "$REPO" config user.email t@example.com
  fgit -C "$REPO" config user.name t
  printf '# root\n' >"$REPO/AGENTS.md"
  printf '# core\n' >"$REPO/crates/core/AGENTS.md"
  printf '# Core\n\nCovers: crates/core\n' >"$REPO/docs/architecture/core.md"
  printf 'pub fn a() {}\n' >"$REPO/crates/core/src/lib.rs"
  INSTALLED="$hooks/doc-drift-check.sh"
  cp "$HOOK" "$INSTALLED"
  [ "${2:-}" = absent ] || cp "$HOOKS/lane-mail-check.sh" "$hooks/lane-mail-check.sh"
  if [ "${2:-}" = account ]; then
    for name in doc-drift-check lane-mail-check; do
      printf '{"version":1,"hooks":{}}\n' >"$hooks/$name.json"
    done
  fi
  fgit -C "$REPO" add -A
  fgit -C "$REPO" commit -q -m init
  printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
}

run_stop() { # SESSION [ACTIVE] [PATH]
  local payload
  payload=$(jq -nc --arg s "$1" --arg cwd "$REPO" --arg t "$LEAD_TRANSCRIPT" --argjson a "${2:-false}" \
    '{sessionId:$s, timestamp:1, cwd:$cwd, transcriptPath:$t, stopReason:"end_turn", stop_hook_active:$a}')
  set +e
  (cd "$REPO" && env HOME="$TMP_ROOT" PATH="${3:-$PATH}" "$BASH_BIN" "$INSTALLED" <<<"$payload") \
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

# Each row is one stop in a repository of its own unless it names `same`,
# which stops again in the row above's.
copilot_rows() {
  local n=0 label world session active path want
  WORLD=$(mktemp -d "$TMP_ROOT/world.XXXXXX") || { echo "doc-drift-check-copilot: world=mktemp-failed" >&2; exit 1; }
  # The lead's transcript sits in the session-state directory named for the
  # lead's session; a subagent's stop names the same file under its own
  # session.
  LEAD_TRANSCRIPT="$WORLD/session-state/lead-1/events.jsonl"
  mkdir -p "${LEAD_TRANSCRIPT%/*}"
  : >"$LEAD_TRANSCRIPT"
  while IFS='|' read -r label world session active path want; do
    n=$((n + 1))
    case "$world" in
      same) ;;
      absent | account) new_repo "$n" "$world" ;;
      *) new_repo "$n" ;;
    esac
    case "$path" in all) path=$PATH ;; no-jq) path=$NO_JQ ;; esac
    run_stop "$session" "$active" "$path"
    assert_eq "$(verdict)" "$want" "$label"
  done <<'ROWS'
the lead's stop over stale documents is held with the block answer at exit 0|fresh|lead-1|false|all|rc=0 decision=block first=doc-drift-check: stale=2
the lead's next stop naming the same set passes|same|lead-1|false|all|rc=0 decision=- first=-
a custom subagent's stop, its own session naming the lead's transcript, passes|fresh|sub-1|false|all|rc=0 decision=- first=-
a stop the harness continued passes|fresh|lead-1|true|all|rc=0 decision=- first=-
with no lane-mail-check beside it, a subagent's stop is judged as the lead's|absent|sub-1|false|all|rc=0 decision=block first=doc-drift-check: stale=2
with jq off PATH the lead's stop is held with the block answer, built without jq|fresh|lead-1|false|no-jq|rc=0 decision=block first=doc-drift-check: missing-tools=jq
the lead's stop is held with the block answer at exit 0 from a global-scope install|account|lead-1|false|all|rc=0 decision=block first=doc-drift-check: stale=2
ROWS

  # The reason Copilot hands the lead is the text the stderr carries.
  new_repo reason
  run_stop lead-1
  assert_eq "$(jq -r '.reason' "$OUT_FILE" 2>/dev/null)" "$(cat "$ERR_FILE")" \
    "the block's reason is the refusal text, keyed line first"
}

echo "=== doc-drift-check on Copilot's agentStop ==="
copilot_rows

# --- controls ----------------------------------------------------------------
# Each rule a line planted in a copy of the hook undoes turns its row red: the
# install's answer shape, the answer built without jq, the caller's question,
# the camelCase session read, and each of the install's two harness reads.
if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  skill_load_control answer "$HOOK" '  if [ "$INSTALL" = copilot ]; then' \
    '    exit 2' HOOK copilot_rows \
    "the lead's stop over stale documents is held with the block answer at exit 0"
  skill_load_control answer-jq "$HOOK" '  if [ "$INSTALL" = copilot ]; then' \
    '    command -v jq >/dev/null 2>&1 || exit 2' HOOK copilot_rows \
    "with jq off PATH the lead's stop is held with the block answer, built without jq"
  skill_load_control caller "$HOOK" \
    '    CALLER=$(printf '"'%s'"' "$INPUT" | "$BASH" "$CALLER_JUDGE" caller 2>/dev/null) || CALLER=""' \
    '    CALLER=""' HOOK copilot_rows \
    "a custom subagent's stop, its own session naming the lead's transcript, passes"
  skill_load_control session "$HOOK" 'SESSION=${FIELDS%%"$TAB"*}' \
    "SESSION=\$(printf '%s' \"\$INPUT\" | jq -r '.session_id // \"\"')" HOOK copilot_rows \
    "the lead's next stop naming the same set passes"
  skill_load_control install-dir "$HOOK" '  */.github/hooks) INSTALL=copilot' \
    'INSTALL=""' HOOK copilot_rows \
    "the lead's stop over stale documents is held with the block answer at exit 0"
  skill_load_control install-registry "$HOOK" '[ -f "${BASH_SOURCE[0]%.sh}.json" ]; then INSTALL=copilot' \
    'INSTALL=""' HOOK copilot_rows \
    "the lead's stop is held with the block answer at exit 0 from a global-scope install"
fi

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
