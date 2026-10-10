#!/usr/bin/env bash
# copilot-lane-context/extension.mjs, the Copilot extension open-terminal
# installs in a Copilot fleet lane's COPILOT_HOME: run under node against a
# fake @github/copilot-sdk/extension that joins a session named s1, delivers
# the `session.usage_info` events a row lists and records what the extension
# writes to the session timeline, beside a fake lane-mail-check hook that
# records each run. What the real hook does with a reading is
# hooks/tests/lane-mail-usage.test.sh's.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
EXTENSION="$SCRIPTS_DIR/copilot-lane-context/extension.mjs"
TMP_ROOT="$(mktemp -d)" || { echo "copilot-lane-context: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "copilot-lane-context: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "copilot-lane-context: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

command -v node >/dev/null 2>&1 || { echo "copilot-lane-context: node is required to run the extension" >&2; exit 1; }

# The fake SDK, resolved the way node resolves a bare specifier: from the
# node_modules above the directory each case's copy of the extension sits in.
SDK="$TMP_ROOT/ext/node_modules/@github/copilot-sdk"
mkdir -p "$SDK"
printf '{"name":"@github/copilot-sdk","type":"module","exports":{"./extension":"./extension.mjs"}}\n' > "$SDK/package.json"
cat > "$SDK/extension.mjs" <<'SDK'
import { appendFileSync, readFileSync } from "node:fs";
// FAKE_EVENTS: a JSON array of {after_ms, agentId?, data}, each delivered that
// long after the join. FAKE_LOG: one JSON line per timeline write.
export async function joinSession() {
  let handler = null;
  const session = {
    sessionId: "s1",
    on(type, h) { if (type === "session.usage_info") handler = h; return () => {}; },
    async log(message, options) {
      appendFileSync(process.env.FAKE_LOG, JSON.stringify({ message, level: options?.level ?? null }) + "\n");
    },
  };
  for (const e of JSON.parse(readFileSync(process.env.FAKE_EVENTS, "utf8"))) {
    setTimeout(() => handler?.({ type: "session.usage_info", agentId: e.agentId, data: e.data }), e.after_ms);
  }
  return session;
}
SDK

# The session: a repository the extension runs in, and the Copilot home.
REPO="$TMP_ROOT/repo"
COP_HOME="$TMP_ROOT/copilot-home"
USER_HOME="$TMP_ROOT/user-home"
git init -q "$REPO"
git -C "$REPO" config gc.auto 0
git -C "$REPO" config maintenance.auto false
mkdir -p "$USER_HOME"

# The hook each run records: its scope, argument, directory, stdin, and
# whether session s1's pending marker stood as it started, one TAB line per
# run. FAKE_HOOK_SLEEP holds a run in flight, FAKE_HOOK_EXIT and
# FAKE_HOOK_STDERR are what it answers.
FAKE_HOOK="$TMP_ROOT/fake-hook.sh"
cat > "$FAKE_HOOK" <<'HOOK'
#!/usr/bin/env bash
payload=$(cat)
marker=unmarked
[ ! -e "$HOME/.cache/lane-mail/copilot-usage/s1" ] || marker=marked
printf '%s\t%s\t%s\t%s\t%s\n' "${BASH_SOURCE[0]%/*}" "$1" "$PWD" "$payload" "$marker" >> "$FAKE_HOOK_LOG"
[ "${FAKE_HOOK_SLEEP:-0}" = 0 ] || exec sleep "$FAKE_HOOK_SLEEP"
[ -z "${FAKE_HOOK_STDERR:-}" ] || printf '%s\n' "$FAKE_HOOK_STDERR" >&2
exit "${FAKE_HOOK_EXIT:-0}"
HOOK
chmod +x "$FAKE_HOOK"

# hooks_in DIR [NAMES] — DIR as a Copilot hook scope holding NAMES, each
# `<name>.sh` beside `<name>.json`; `sh-only` leaves the documents out.
hooks_in() { # DIR [NAMES|sh-only]
  local name names="${2:-lane-mail-check lane-mail-compact lane-mail-start}" json=1
  [[ "$names" != sh-only ]] || { names="lane-mail-check lane-mail-compact lane-mail-start"; json=0; }
  mkdir -p "$1"
  for name in $names; do
    cp "$FAKE_HOOK" "$1/$name.sh"
    [[ "$json" -eq 0 ]] || printf '{}\n' > "$1/$name.json"
  done
}
clear_scopes() { rm -rf -- "${REPO:?}/.github" "${REPO:?}/tmp" "${COP_HOME:?}" "${USER_HOME:?}/.copilot"; }

# run_ext NAME EVENTS [ENV=VAL...] — the extension, or EXT's copy, joined to
# a session delivering EVENTS; HOOK_RUNS and TIMELINE hold what it did, and
# PENDING whether s1's pending marker stands once it exits.
PENDING_MARKER="$USER_HOME/.cache/lane-mail/copilot-usage/s1"
run_ext() { # NAME EVENTS [ENV=VAL...]
  local name="$1" events="$2" dir="$TMP_ROOT/ext/$1"
  shift 2
  mkdir -p "$dir"
  cp "${EXT:-$EXTENSION}" "$dir/extension.mjs"
  printf '%s\n' "$events" > "$dir/events.json"
  : > "$dir/hook.log"
  : > "$dir/timeline.log"
  rm -rf -- "${USER_HOME:?}/.cache"
  RC=0
  (cd "$REPO" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$PATH" HOME="$USER_HOME" COPILOT_HOME="$COP_HOME" \
    FAKE_EVENTS="$dir/events.json" FAKE_LOG="$dir/timeline.log" FAKE_HOOK_LOG="$dir/hook.log" "$@" \
    node "$dir/extension.mjs") >"$dir/out" 2>&1 || RC=$?
  HOOK_RUNS="$(cat "$dir/hook.log")"
  TIMELINE="$(jq -r '"\(.level) \(.message | split("\n")[0])"' "$dir/timeline.log")"
  PENDING=unmarked
  [[ ! -e "$PENDING_MARKER" ]] || PENDING=marked
}
# One event's JSON: TOKENS in context against LIMIT, AFTER ms in, from AGENT.
event() { # AFTER TOKENS LIMIT [AGENT]
  jq -nc --argjson a "$1" --argjson t "$2" --argjson l "$3" --arg g "${4:-}" \
    '{after_ms:$a, data:{currentTokens:$t, tokenLimit:$l, messagesLength:2, isInitial:false}}
     + (if $g == "" then {} else {agentId:$g} end)'
}
events() { printf '[%s]' "$(IFS=,; echo "$*")"; }
# The payload a run handed the hook, as `tokens/limit`, one per run.
run_tokens() { printf '%s\n' "$HOOK_RUNS" | awk -F'\t' 'NF { print $4 }' | jq -r '"\(.current_tokens)/\(.token_limit)"' | paste -sd' ' -; }
# The marker each run found as it started, one per run.
run_marks() { printf '%s\n' "$HOOK_RUNS" | awk -F'\t' 'NF { print $5 }' | paste -sd' ' -; }
run_scope() { printf '%s\n' "$HOOK_RUNS" | awk -F'\t' 'NF { print $1 }' | sort -u | paste -sd' ' -; }

echo "=== a root reading reaches the hook ==="
clear_scopes
hooks_in "$REPO/.github/hooks"
run_ext root "$(events "$(event 0 1200 64000)" "$(event 50 1300 64000 sub-1)")"
assert_eq "rc=$RC runs=$(printf '%s\n' "$HOOK_RUNS" | wc -l | tr -d ' ') timeline=${TIMELINE:-none}" "rc=0 runs=1 timeline=none" \
  "the root agent's reading runs the hook once and a subagent's runs nothing"
IFS=$'\t' read -r scope arm dir payload _ <<<"$HOOK_RUNS"
assert_eq "$scope|$arm|$dir|$payload" \
  "$REPO/.github/hooks|usage|$REPO|{\"session_id\":\"s1\",\"cwd\":\"$REPO\",\"current_tokens\":1200,\"token_limit\":64000}" \
  "the hook in the project scope runs as usage in the session's directory, handed its id, directory and reading"

echo "=== the hook scope is the one the session loads ==="
# `label|project|global|want`: what each scope holds, and the scope run.
while IFS='|' read -r label project global want; do
  clear_scopes
  [[ "$project" == - ]] || hooks_in "$REPO/.github/hooks" "${project/both/}"
  [[ "$global" == - ]] || hooks_in "$COP_HOME/hooks" "${global/both/}"
  run_ext scope "$(events "$(event 0 10 100)")"
  assert_eq "$(run_scope)" "${want//@/$REPO}" "$label"
done <<ROWS
the project scope wins where both hold the hooks|both|both|@/.github/hooks
a project scope holding lane-mail-check alone gives way to the global one|lane-mail-check|both|$COP_HOME/hooks
a project scope without lane-mail-start gives way to the global one|lane-mail-check lane-mail-compact|both|$COP_HOME/hooks
a project scope with no registry documents gives way to the global one|sh-only|both|$COP_HOME/hooks
ROWS
clear_scopes
hooks_in "$USER_HOME/.copilot/hooks"
run_ext default-home "$(events "$(event 0 10 100)")" COPILOT_HOME=
assert_eq "$(run_scope)" "$USER_HOME/.copilot/hooks" "with COPILOT_HOME empty the global scope is the home's own .copilot"

# The same worlds asked of lib/lane-context.sh's lane_context_copilot_hooks,
# the rule's owner: the two spellings answer alike, `none` where neither scope
# holds every hook; a comma stands for a space in a world's names.
lib_scope() { bash -c 'source "$1/lib/lane-context.sh"; lane_context_copilot_hooks "$2" "$3" || echo none' _ "$SCRIPTS_DIR" "$REPO" "$COP_HOME"; }
ext_scope() {
  run_ext agree "$(events "$(event 0 10 100)")"
  if [[ -n "$HOOK_RUNS" ]]; then run_scope; else echo none; fi
}
for world in both:both both:- lane-mail-check:both sh-only:both -:both -:- lane-mail-check:lane-mail-compact -:sh-only \
  lane-mail-check,lane-mail-compact:both lane-mail-check,lane-mail-compact:-; do
  clear_scopes
  project="${world%%:*}" global="${world#*:}" project="${project//,/ }"
  [[ "$project" == - ]] || hooks_in "$REPO/.github/hooks" "${project/both/}"
  [[ "$global" == - ]] || hooks_in "$COP_HOME/hooks" "${global/both/}"
  assert_eq "$(ext_scope)" "$(lib_scope)" "the extension and the library pick one scope for project=$project global=$global"
done

# The directory the extension leaves its marker in, asked of
# lib/lane-context.sh's lane_context_copilot_pending_dir, the spelling
# open-terminal's launch gate makes, and found where a run that exits 2 leaves
# the extension's marker standing: the two name one directory under HOME.
lib_pending() { HOME="$USER_HOME" bash -c 'source "$1/lib/lane-context.sh"; lane_context_copilot_pending_dir' _ "$SCRIPTS_DIR"; }
ext_pending() {
  run_ext pending-dir "$(events "$(event 0 10 100)")" FAKE_HOOK_EXIT=2
  find "$USER_HOME" -type f -name s1 -exec dirname {} \; | paste -sd' ' -
}
clear_scopes
hooks_in "$REPO/.github/hooks"
assert_eq "$(ext_pending)" "$(lib_pending)" "the extension and the library name one pending directory"

echo "=== every gap is written to the timeline once ==="
MISSING="warning kendex-lane-context: hooks-missing=$REPO/.github/hooks,$COP_HOME/hooks"
# With no scope holding the hooks, two readings run nothing. A session that
# can be a fleet session, by the inputs lane-mail-check's session gate starts
# from, is told once; any other is no lane and hears nothing.
# `label|mailbox root|env|timeline`
while IFS='|' read -r label mailroot envs want; do
  clear_scopes
  [[ "$mailroot" == - ]] || mkdir -p "$REPO/tmp/lane-mail"
  # shellcheck disable=SC2086
  run_ext no-scope "$(events "$(event 0 10 100)" "$(event 20 11 100)")" $envs
  assert_eq "runs=${HOOK_RUNS:-none} timeline=${TIMELINE:-none}" "runs=none timeline=$want" "$label"
done <<ROWS
a session naming its lane item is told, naming both scopes|-|LANE_MAIL_ITEM=KEN-1|$MISSING
a session in a tmux pane is told|-|TMUX=/tmp/tmux-1/default,1,0 TMUX_PANE=%1|$MISSING
a session whose checkout holds a lane mailbox root is told|root||$MISSING
a session with none of them is no fleet session and hears nothing|-||none
a tmux session naming no pane is none either|-|TMUX=/tmp/tmux-1/default,1,0|none
ROWS
clear_scopes
hooks_in "$REPO/.github/hooks"
run_ext hook-gap "$(events "$(event 0 10 100)" "$(event 50 11 100)")" FAKE_HOOK_EXIT=2 \
  "FAKE_HOOK_STDERR=lane-mail-check: context-unrecorded=/box/context.json
the cause"
assert_eq "runs=$(run_tokens) timeline=$TIMELINE" \
  "runs=10/100 11/100 timeline=warning lane-mail-check: context-unrecorded=/box/context.json" \
  "a hook refusing twice at exit 2 writes its keyed line to the timeline once"
assert_eq "$(jq -r .message "$TMP_ROOT/ext/hook-gap/timeline.log")" \
  "lane-mail-check: context-unrecorded=/box/context.json
the cause" "the warning carries the hook's whole stderr"
run_ext hook-silent "$(events "$(event 0 10 100)")" FAKE_HOOK_EXIT=3
assert_eq "$TIMELINE" "warning kendex-lane-context: usage-exit=3" "a hook exiting 3 with no words is named by its status"
run_ext unreadable "$(events '{"after_ms":0,"data":{"currentTokens":"many","tokenLimit":100}}' '{"after_ms":10,"data":{"currentTokens":5}}')"
assert_eq "runs=${HOOK_RUNS:-none} timeline=$TIMELINE" "runs=none timeline=warning kendex-lane-context: reading=unreadable" \
  "readings with no whole figures run nothing and write one warning"

echo "=== one run in flight, the newest reading queued ==="
# The hook sleeps a second, the real wait that holds its run in flight while
# three more readings land 100 ms apart.
run_ext bound "$(events "$(event 0 1 100)" "$(event 100 2 100)" "$(event 200 3 100)" "$(event 300 4 100)")" FAKE_HOOK_SLEEP=1
assert_eq "$(run_tokens)" "1/100 4/100" "readings landing while a run is in flight replace one another, and the last runs next"
# The bound, shortened in a private copy so a real wait of under a second
# reaches it: a hook that outlives it is stopped and named.
cp "$EXTENSION" "$TMP_ROOT/short-bound.mjs"
mutate_file "$TMP_ROOT/short-bound.mjs" 'const HOOK_TIMEOUT_MS = 30000;' 'const HOOK_TIMEOUT_MS = 300;'
EXT="$TMP_ROOT/short-bound.mjs" run_ext timeout "$(events "$(event 0 1 100)")" FAKE_HOOK_SLEEP=5
assert_eq "$TIMELINE" "warning kendex-lane-context: usage-signal=SIGTERM" "a hook that outlives the bound is stopped and named"

echo "=== a reading handed on stands pending until it is recorded ==="
# An unreadable root reading landing 500 ms in: after a run that exits at
# once, and during one the hook's one-second sleep holds in flight.
UNREADABLE_LATE='{"after_ms":500,"data":{"currentTokens":"many","tokenLimit":100}}'
# `label|hook env|readings|marker at each run|marker after`
while IFS='|' read -r label envs readings want_runs want_after; do
  clear_scopes
  hooks_in "$REPO/.github/hooks"
  case "$readings" in
    one) evs="$(events "$(event 0 10 100)")" ;;
    queued) evs="$(events "$(event 0 1 100)" "$(event 100 2 100)")" ;;
    unreadable-after) evs="$(events "$(event 0 1 100)" "$UNREADABLE_LATE")" ;;
  esac
  # shellcheck disable=SC2086
  run_ext pending "$evs" $envs
  assert_eq "marks=$(run_marks) after=$PENDING" "marks=$want_runs after=$want_after" "$label"
done <<ROWS
a run that exits 0 finds the marker standing and removes it|FAKE_HOOK_EXIT=0|one|marked|unmarked
a run that exits 2 leaves the marker standing|FAKE_HOOK_EXIT=2|one|marked|marked
a run that exits 0 with a reading queued behind it leaves the marker for that reading|FAKE_HOOK_SLEEP=1|queued|marked marked|unmarked
an unreadable root reading after a recorded one leaves the marker standing|FAKE_HOOK_EXIT=0|unreadable-after|marked|marked
an unreadable root reading landing while a run is in flight leaves the marker past that run's exit 0|FAKE_HOOK_SLEEP=1|unreadable-after|marked|marked
ROWS
# The bound shortened as above: a run stopped by it leaves the marker.
EXT="$TMP_ROOT/short-bound.mjs" run_ext pending-timeout "$(events "$(event 0 1 100)")" FAKE_HOOK_SLEEP=5
assert_eq "after=$PENDING" "after=marked" "a run stopped at the bound leaves the marker standing"
# A cache the marker directory cannot be made under: the reading still runs,
# and the gap is named.
clear_scopes
hooks_in "$REPO/.github/hooks"
mkdir -p "$TMP_ROOT/blocked-home"
: > "$TMP_ROOT/blocked-home/.cache"
run_ext pending-unwritten "$(events "$(event 0 10 100)")" HOME="$TMP_ROOT/blocked-home"
assert_eq "runs=$(run_tokens) timeline=$TIMELINE" \
  "runs=10/100 timeline=warning kendex-lane-context: pending-unwritten=$TMP_ROOT/blocked-home/.cache/lane-mail/copilot-usage/s1" \
  "a marker that cannot be written is named, and the reading is still handed on"

echo "=== must-fail controls ==="
# ext_ctrl NAME OLD NEW — a private copy of the extension with OLD made NEW,
# in EXT.
ext_ctrl() { # NAME OLD NEW
  cp "$EXTENSION" "$TMP_ROOT/$1.mjs"
  mutate_file "$TMP_ROOT/$1.mjs" "$2" "$3"
  EXT="$TMP_ROOT/$1.mjs"
}
clear_scopes
hooks_in "$REPO/.github/hooks"
ext_ctrl agent-ctrl '  if (event.agentId) return;' ''
EXT="$EXT" run_ext agent-ctrl "$(events "$(event 0 1200 64000)" "$(event 50 1300 64000 sub-1)")"
assert_eq "$(run_tokens)" "1200/64000 1300/64000" "control: without the agent rule a subagent's reading runs the hook"
ext_ctrl arm-ctrl '"lane-mail-check.sh"), "usage"]' '"lane-mail-check.sh")]'
EXT="$EXT" run_ext arm-ctrl "$(events "$(event 0 1200 64000)")"
assert_eq "$(awk -F'\t' '{ print ($2 == "" ? "none" : $2) }' <<<"$HOOK_RUNS")" "none" \
  "control: without its argument the hook is run as a turn end"
ext_ctrl bound-ctrl '  if (running || queued === null) return;' '  if (queued === null) return;'
EXT="$EXT" run_ext bound-ctrl "$(events "$(event 0 1 100)" "$(event 100 2 100)" "$(event 200 3 100)" "$(event 300 4 100)")" FAKE_HOOK_SLEEP=1
assert_eq "$(run_tokens)" "1/100 2/100 3/100 4/100" "control: without the bound every reading runs a hook of its own"
ext_ctrl exit-ctrl '    } else if (code !== 0) {' '    } else if (false) {'
EXT="$EXT" run_ext exit-ctrl "$(events "$(event 0 10 100)")" FAKE_HOOK_EXIT=2 "FAKE_HOOK_STDERR=lane-mail-check: x=y"
assert_eq "${TIMELINE:-none}" "none" "control: without the exit rule a refusing hook reaches no timeline"
ext_ctrl once-ctrl '  if (logged.has(first)) return;' ''
clear_scopes
EXT="$EXT" run_ext once-ctrl "$(events "$(event 0 10 100)" "$(event 20 11 100)")" LANE_MAIL_ITEM=KEN-1
assert_eq "$(printf '%s\n' "$TIMELINE" | wc -l | tr -d ' ')" "2" "control: without the once rule every reading repeats its gap"
ext_ctrl json-ctrl '  return HOOKS.every((name) => existsSync(join(dir, `${name}.sh`)) && existsSync(join(dir, `${name}.json`)));' \
  '  return HOOKS.every((name) => existsSync(join(dir, `${name}.sh`)));'
hooks_in "$REPO/.github/hooks" sh-only
hooks_in "$COP_HOME/hooks"
EXT="$EXT" run_ext json-ctrl "$(events "$(event 0 10 100)")"
assert_eq "$(run_scope)" "$REPO/.github/hooks" "control: without the registry rule a scope Copilot does not load is run"
ext_ctrl project-ctrl '  if (root !== null) scopes.push' '  if (false) scopes.push'
clear_scopes
hooks_in "$REPO/.github/hooks"
hooks_in "$COP_HOME/hooks"
EXT="$EXT" run_ext project-ctrl "$(events "$(event 0 10 100)")"
assert_eq "$(run_scope)" "$COP_HOME/hooks" "control: without the project scope the global one is run over it"
ext_ctrl start-ctrl 'const HOOKS = ["lane-mail-check", "lane-mail-compact", "lane-mail-start"];' \
  'const HOOKS = ["lane-mail-check", "lane-mail-compact"];'
clear_scopes
hooks_in "$REPO/.github/hooks" "lane-mail-check lane-mail-compact"
hooks_in "$COP_HOME/hooks"
EXT="$EXT" run_ext start-ctrl "$(events "$(event 0 10 100)")"
assert_eq "$(run_scope)" "$REPO/.github/hooks" "control: without lane-mail-start in the set a scope that cannot record the lead is run"

clear_scopes
hooks_in "$REPO/.github/hooks"
ext_ctrl pending-dir-ctrl 'const PENDING_DIR = join(homedir(), ".cache", "lane-mail", "copilot-usage");' \
  'const PENDING_DIR = join(homedir(), ".cache", "lane-mail", "copilot-usage-x");'
assert_eq "$(EXT="$EXT" ext_pending)" "$(lib_pending)-x" "control: an extension naming another directory is told apart from the library's"
ext_ctrl mark-ctrl '  markPending();' ''
EXT="$EXT" run_ext mark-ctrl "$(events "$(event 0 10 100)")"
assert_eq "$(run_marks)" "unmarked" "control: without the marker a reading's run starts with nothing pending"
ext_ctrl clear-ctrl '      clearPending();' ''
EXT="$EXT" run_ext clear-ctrl "$(events "$(event 0 10 100)")"
assert_eq "$PENDING" "marked" "control: without the removal a recorded reading stays pending"
ext_ctrl failed-ctrl '    } else if (seq === latest) {' '    } if (seq === latest) {'
EXT="$EXT" run_ext failed-ctrl "$(events "$(event 0 10 100)")" FAKE_HOOK_EXIT=2
assert_eq "$PENDING" "unmarked" "control: removed whatever the run did, a failed reading is cleared"
ext_ctrl notdir-ctrl '    if (error.code === "ENOTDIR") return;' ''
EXT="$EXT" run_ext notdir-ctrl "$(events "$(event 0 10 100)")" HOME="$TMP_ROOT/blocked-home"
assert_eq "$(printf '%s\n' "$TIMELINE" | grep -c 'pending-unremoved=' || true)" "1" \
  "control: without the no-directory rule a marker never written is reported as one left standing"
ext_ctrl queued-ctrl '    } else if (seq === latest) {' '    } else {'
EXT="$EXT" run_ext queued-ctrl "$(events "$(event 0 1 100)" "$(event 100 2 100)")" FAKE_HOOK_SLEEP=1
assert_eq "$(run_marks)" "marked unmarked" "control: removed with a reading queued, the queued reading runs unmarked"
ext_ctrl unread-mark-ctrl '  if (scope === null) return;' '  if (scope === null || !readable) return;'
EXT="$EXT" run_ext unread-mark-ctrl "$(events "$(event 0 1 100)" "$UNREADABLE_LATE")"
assert_eq "$PENDING" "unmarked" "control: the reading check ahead of the marker leaves an unreadable reading unmarked"
ext_ctrl latest-ctrl '    } else if (seq === latest) {' '    } else if (queued === null) {'
EXT="$EXT" run_ext latest-ctrl "$(events "$(event 0 1 100)" "$UNREADABLE_LATE")" FAKE_HOOK_SLEEP=1
assert_eq "$PENDING" "unmarked" "control: removed by any run with nothing queued, an unreadable reading in flight is cleared"

ext_ctrl fleet-ctrl '    if (!fleetSession(root)) return null;' '    if (false) return null;'
clear_scopes
EXT="$EXT" run_ext fleet-ctrl "$(events "$(event 0 10 100)")"
assert_eq "${TIMELINE:-none}" "$MISSING" "control: without the fleet-session rule a session that is no lane is told its hooks are missing"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
