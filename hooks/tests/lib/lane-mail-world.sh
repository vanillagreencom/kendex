#!/usr/bin/env bash
# The world the lane-mail suites share: the temp root, the assertions, a lane
# repository with the hook installed where kendex renders it, the payload
# runner, the tmux pane the fleet record names, and the
# overseer session. lane-mail-compact.test.sh and lane-mail-usage.test.sh
# source it after `set -euo pipefail`; each counts into the PASS and FAIL set
# here and reports them itself.
# shellcheck disable=SC2034

# A suite runs with no environment but HOME, PATH, TMPDIR, the runtime cache
# and the hook it is told to run, as `env -i` starts it: an orch, harness,
# mailbox or git variable the caller carries would point the hook, `lane-mail`
# and the runtime at the caller's own records, and GIT_DIR would configure the
# real repository. The suite restarts once in that environment, so its own
# setup runs there too.
if [ "${LANE_MAIL_WORLD:-}" != started ]; then
  exec env -i "HOME=$HOME" "PATH=$PATH" ${TMPDIR+"TMPDIR=$TMPDIR"} ${HOOK_UNDER_TEST+"HOOK_UNDER_TEST=$HOOK_UNDER_TEST"} \
    ${AGENT_RUNTIME_CACHE+"AGENT_RUNTIME_CACHE=$AGENT_RUNTIME_CACHE"} \
    LANE_MAIL_WORLD=started \
    "$BASH" "${BASH_SOURCE[${#BASH_SOURCE[@]}-1]}" "$@"
fi

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/lane-mail-check.sh}"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd -P)"
LANE_MAIL="$REPO_ROOT/skills/mailbox/scripts/lane-mail"
# The runtime the hook writes and judges through is the built one, found in
# the cache scripts/setup fills for this checkout's sources, whatever HOME a
# row runs the hook under.
AGENT_RUNTIME_CACHE="$(bash -c '. "$1"; agent_runtime_cache' _ "$REPO_ROOT/skills/agent-runtime/scripts/lib/key.sh")" \
  || { echo "lane-mail-world: runtime-cache=unresolved" >&2; exit 1; }
export AGENT_RUNTIME_CACHE
# The overseer's own marks are the runtime's `marks` verb, planted below; kendex classifies its
# entries' models; the orch fixture answers that read whether or not a kendex
# is installed.
# shellcheck source=../../../skills/orch/tests/lib/tier-model-path.sh
. "$REPO_ROOT/skills/orch/tests/lib/tier-model-path.sh"
# Canonical from the start: the hook resolves its own directory with pwd -P,
# and on a host whose temp root is a symlink — every macOS one, /var pointing
# at /private/var — a path this suite composed would name the link where the
# hook names the target.
TMP_ROOT="$(mktemp -d)" || { echo "lane-mail-world: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lane-mail-world: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lane-mail-world: scratch=resolve-failed" >&2; exit 1; }
# Every hook run's own scratch under the root the exit trap removes: a row
# that kills the hook before its trap runs leaves its directory here.
mkdir -p "$TMP_ROOT/tmp"
export TMPDIR="$TMP_ROOT/tmp"
trap 'chmod -R u+rwx -- "${TMP_ROOT:?}" 2>/dev/null || :; rm -rf -- "${TMP_ROOT:?}"' EXIT
ERR_FILE="$TMP_ROOT/stderr"
PASS=0
FAIL=0

assert_eq() { # GOT WANT LABEL
  if [[ "$1" == "$2" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$3"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$3" "$2" "$1"
  fi
}

# shellcheck source=lib/first-line.sh
. "$TEST_DIR/lib/first-line.sh"

# A lane: a git repository on a branch named for its item, carrying the layout
# a kendex project install renders, so the hook resolves its reader the way an
# installed one does. CASE_HOOK is the copy a case runs.
LANE=""
CASE_HOOK=""

install_hook() { # SOURCE DEST
  mkdir -p "${2%/*}"
  cp "$1" "$2"
  chmod +x "$2"
  CASE_HOOK="$2"
}

new_lane() { # NAME BRANCH
  REPORT_ITEM=""
  LANE="$TMP_ROOT/$1"
  mkdir -p "$LANE"
  git -C "$LANE" init -q
  git -C "$LANE" config gc.auto 0
  git -C "$LANE" config maintenance.auto false
  git -C "$LANE" checkout -q -b "$2"
  git -C "$LANE" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m base
  lay_out_lane "$2"
}

# The install and the launch record, on the repository LANE names. The orch
# scripts directory is a link, as a case that replaces it expects, to a
# directory beside it holding the scripts one link each (plant_siblings),
# the shipped wrapper among them over the runtime sources linked beside
# it. The directory sits under the same `orch`, so a script's
# `../../mailbox` resolves as the install's does.
lay_out_lane() { # BRANCH
  local scripts="$LANE/.agents/skills/orch/.scripts"
  mkdir -p "$LANE/.agents/skills/orch" "$LANE/.claude/hooks" "$LANE/.claude/skills" "$scripts"
  mkdir -p "$LANE/.agents/skills/mailbox"
  ln -s -f -n "$REPO_ROOT/skills/mailbox/scripts" "$LANE/.agents/skills/mailbox/scripts"
  plant_siblings "$scripts"
  ln -s -f -n "$scripts" "$LANE/.agents/skills/orch/scripts"
  ln -s -f -n ../../.agents/skills/orch "$LANE/.claude/skills/orch"
  ln -s -f -n ../../.agents/skills/mailbox "$LANE/.claude/skills/mailbox"
  install_hook "$HOOK" "$LANE/.claude/hooks/lane-mail-check.sh"
  mark_lane "$1"
}

# The marker a launcher writes: the lane's root, named for the item in lower
# case under the common git directory.
mark_lane() { # ITEM
  local common
  common="$(git -C "$LANE" rev-parse --path-format=absolute --git-common-dir)"
  mkdir -p "$common/lane-mail"
  git -C "$LANE" rev-parse --show-toplevel > "$common/lane-mail/$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
}

# Every launch marker gone, as in a repository no launch ever reached.
unmark_lanes() {
  local common
  common="$(git -C "$LANE" rev-parse --path-format=absolute --git-common-dir)"
  rm -rf -- "${common:?}/lane-mail"
}

# Most cases request 50 percent; the independent token cap still applies.
# Adapter rows use the package default across their different windows.
CONTEXT_PCT_ENV=ORCH_HANDOFF_CONTEXT_PCT=50

# The world a case runs in unless it names another: a home with no lane in it,
# so the handoff marks' account read answers `no configured lane of this
# harness` without reaching the network, and a fetch stub that fails if one
# ever is discovered. The developer's own lane variables and handoff settings
# are cleared rather than inherited, so a case's world is only what it sets.
OFFLINE_HOME="$TMP_ROOT/offline-home"
NO_FETCH="$TMP_ROOT/no-fetch"
mkdir -p "$OFFLINE_HOME/.pi/agent"
printf '%s\n' '{"compaction":{"enabled":false}}' > "$OFFLINE_HOME/.pi/agent/settings.json"
CODEX_COMPACTION='{"harness":"codex","settings":{"model_auto_compact_token_limit":"9223372036854775807","model_auto_compact_token_limit_scope":"body_after_prefix","model_post_turn_compact_threshold_percent":"0"}}'
printf '#!/bin/sh\nexit 1\n' > "$NO_FETCH"
chmod +x "$NO_FETCH"

# A notice the lane sends through the real `lane-mail notice`, as a working
# lane reports a step before its turn ends, so the idle judge reads a send
# this turn. Each carries its own words, so a row reads which report the
# outbound file holds; lane-mail does not deduplicate a notice.
REPORTS=0
report() { # ITEM
  REPORTS=$((REPORTS + 1))
  printf 'step %s done\n' "$REPORTS" > "$TMP_ROOT/report.txt"
  (cd "$LANE" && "$LANE_MAIL" notice --item "$1" --root "$LANE" --file "$TMP_ROOT/report.txt" >/dev/null)
}
# The item whose lane reports a step before every turn end run_payload makes,
# empty for a lane that sends nothing. new_lane clears it; a suite sets it for
# rows that judge something other than the idle judge on a fresh turn end.
REPORT_ITEM=""

RC=0
# The judge's argument, empty for the turn-end run the harness makes.
ARM_ARGS=()
# The directory the call is made from, the lane's own unless a case names
# another: a lane runs its post-merge steps from the main clone. CALL_ENV is
# what the harness running that call sets, such as the directory it started in.
CALL_DIR=""
CALL_ENV=()
# The user home a Copilot run keeps its lead records under, and the records
# themselves: a suite driving Copilot payloads names this home in CALL_ENV, so
# no run writes the developer's own cache.
COP_HOME="$TMP_ROOT/copilot-user"
COP_LEADS="$COP_HOME/.cache/lane-mail/copilot-leads"
mkdir -p "$COP_HOME"
cop_clear_leads() {
  rm -rf -- "${COP_HOME:?}/.cache"
}
# SESSION's sessionStart, run through JUDGE's start arm, which records the
# session as a Copilot lead: what a lead's own start writes.
cop_lead_start() { # JUDGE SESSION
  local judge="$CASE_HOOK"
  CASE_HOOK="$1"
  ARM_ARGS=(start)
  run_payload "$(jq -nc --arg s "$2" '{sessionId:$s, timestamp:1, cwd:"/w", source:"new"}')"
  ARM_ARGS=()
  CASE_HOOK="$judge"
  assert_eq "RC=$RC lead=$([ -f "$COP_LEADS/$2" ] && echo recorded || echo none)" "RC=0 lead=recorded" \
    "the start of $2 records it as a Copilot lead"
}
run_payload() { # RAW-JSON [ENV=VAL...]
  local payload="$1"
  shift
  if [ -n "$REPORT_ITEM" ] && [ "${#ARM_ARGS[@]}" -eq 0 ]; then report "$REPORT_ITEM"; fi
  RC=0
  : > "$ERR_FILE"
  printf '%s' "$payload" |
    (cd "${CALL_DIR:-$LANE}" && env "LANES_HOME=$OFFLINE_HOME" "PI_CODING_AGENT_DIR=$OFFLINE_HOME/.pi/agent" \
      DISABLE_AUTO_COMPACT=1 DISABLE_COMPACT=0 "ORCH_COMPACTION_OVERRIDES=$CODEX_COMPACTION" "ORCH_LANES_FETCH_CMD=$NO_FETCH" ${CONTEXT_PCT_ENV:+"$CONTEXT_PCT_ENV"} \
      ${CALL_ENV[@]+"${CALL_ENV[@]}"} "$@" bash "$CASE_HOOK" ${ARM_ARGS[@]+"${ARM_ARGS[@]}"}) >"$TMP_ROOT/stdout" 2>"$ERR_FILE" || RC=$?
}

stop() { # [ENV=VAL...]
  run_payload '{"session_id":"s1","stop_hook_active":false}' "$@"
}

# One assistant line carrying the usage the harness recorded for it, in the
# spelling that harness writes usage in; the context is its input tokens plus
# the cache the prompt was read from, and every spelling below sums to TOKENS.
# A real transcript grows one line at a time, so a row that turns on WHICH
# usage line the hook reads writes the first and appends the rest.
#
#   claude  Claude Code's own line: input_tokens beside its two cache counts
#           and output_tokens, on a model whose tier runs a 1M window.
#   sonnet  the same line on claude-sonnet-4-6, a model whose window the claude
#           adapter leaves unnamed.
#   pi      Pi's session entry, `appendMessage` in @earendil-works/pi-coding-agent,
#           carrying the `Usage` of @earendil-works/pi-ai: input, output,
#           cacheRead, cacheWrite, totalTokens and cost, none of them spelled
#           the way Claude Code spells them, on model m of the pi-claude
#           provider, whose account is a Claude seat.
#   codex   Codex's rollout: the turn context naming the model, then the
#           token count naming the tokens the last response left in a 258400
#           window.
#   unread  a usage object carrying no spelling the claude adapter reads, which
#           is what the hook must report rather than sum to zero. TOKENS is
#           what a lane would be past its mark by if the figure could be read.
usage_line() { # SPELLING TOKENS
  case "$1" in
    claude | sonnet)
      jq -nc --argjson t "$2" --arg m "$([ "$1" = claude ] && echo claude-opus-5-5 || echo claude-sonnet-4-6)" \
        '{type:"assistant",message:{model:$m,usage:{input_tokens:1,cache_read_input_tokens:($t - 8),cache_creation_input_tokens:0,output_tokens:7}}}'
      ;;
    codex)
      jq -nc '{type:"turn_context",payload:{model:"gpt-6-astra"}}'
      jq -nc --argjson t "$2" \
        '{type:"event_msg",payload:{type:"token_count",info:{last_token_usage:{input_tokens:($t - 7),output_tokens:7,total_tokens:$t},model_context_window:258400}}}'
      ;;
    pi)
      jq -nc --argjson t "$2" \
        '{type:"message",id:"e1",parentId:null,timestamp:"2026-09-19T00:00:00Z",
          message:{role:"assistant",provider:"pi-claude",model:"m",stopReason:"stop",
                   usage:{input:1,output:7,cacheRead:($t - 8),cacheWrite:0,
                          totalTokens:$t,cost:{total:0}}}}'
      ;;
    unread)
      jq -nc --argjson t "$2" \
        '{type:"assistant",message:{usage:{prompt_tokens:$t,completion_tokens:7}}}'
      ;;
    *) printf 'usage_line: no such spelling: %s\n' "$1" >&2; return 1 ;;
  esac
}

write_transcript() { # PATH TOKENS
  usage_line claude "$2" > "$1"
}

# Everything a kendex install renders beside the mailbox reader, taken from the
# catalog itself rather than from a second list here: the handoff marks run
# three of these scripts and those scripts run others, so a case that plants
# its own reader plants the whole neighbourhood the way an install has it. The
# reader is the caller's to plant, and SKIP is the one script a case holes.
plant_siblings() { # SCRIPTS_DIR [SKIP]
  local mailbox="${1%/orch/*}/mailbox/scripts"
  mkdir -p "$mailbox"
  [ -e "$mailbox/lib" ] || ln -s "$REPO_ROOT/skills/mailbox/scripts/lib" "$mailbox/lib"
  [ -e "$mailbox/lane-mail" ] || ln -s "$REPO_ROOT/skills/mailbox/scripts/lane-mail" "$mailbox/lane-mail"
  local entry name
  for entry in "$REPO_ROOT/skills/orch/scripts"/*; do
    name="${entry##*/}"
    [ "$name" != lane-mail ] || continue
    [ "$name" != "${2:-}" ] || continue
    ln -s -f -n "$entry" "$1/$name"
  done
  # The hook runs the shipped wrapper, which builds its key from the sources
  # beside its directory and runs the binary the cache holds for them: this
  # checkout's runtime sources, linked where an install lays them, select
  # the binary setup built into AGENT_RUNTIME_CACHE.
  local package="${1%/*}"
  [ -e "$package/runtime" ] || ln -s "$REPO_ROOT/skills/orch/runtime" "$package/runtime"
  [ -e "${package%/*}/agent-runtime" ] || ln -s "$REPO_ROOT/skills/agent-runtime" "${package%/*}/agent-runtime"
}

# The real orch skill beside the hook, with SKIP left out: the walk finds this
# copy before the one under .agents, so a case can hole an install without
# touching anything else the lane carries.
plant_install() { # [SKIP]
  # Whatever stands there, a link new_lane made or an install an earlier call
  # planted, so a case can plant twice.
  rm -rf -- "${LANE:?}/.claude/skills/orch"
  mkdir -p "$LANE/.claude/skills/orch/scripts"
  rm -rf -- "${LANE:?}/.claude/skills/mailbox"
  mkdir -p "$LANE/.claude/skills/mailbox/scripts"
  ln -s "$REPO_ROOT/skills/mailbox/scripts/lib" "$LANE/.claude/skills/mailbox/scripts/lib"
  ln -s -f -n "$REPO_ROOT/skills/mailbox/scripts/lane-mail" "$LANE/.claude/skills/mailbox/scripts/lane-mail"
  plant_siblings "$LANE/.claude/skills/orch/scripts" "${1:-}"
}

# --- the overseer's identity -----------------------------------------------
# These neutral records name an already-bound native session s1. Initial
# binding cases clear it before the matching native caller runs.
# The tmux stub below reads the overseer's server and pane, one part of its
# identity. It is the one read
# that asks — the server a pane belongs to, which the orch library pairs with
# $TMUX_PANE.
TMUX_BIN="$TMP_ROOT/tmux-bin"
mkdir -p "$TMUX_BIN"
# This suite owns the shell until its fixtures and hook calls finish.
TMUX_PANE_PID=$$
export TMUX_PANE_PID
cat > "$TMUX_BIN/tmux" <<'TMUXSTUB'
#!/bin/sh
# `display-message -p -t <pane> '#{pid}'`, and `'#{pid} #{start_time}'` for
# the server's start the orch lib/tmux-server.sh reads, and nothing else:
# TMUX_SERVER_ID is what this fixture's server answers and TMUX_SERVER_START
# when it started, and no value at all is a pane tmux cannot resolve, which is
# every session outside a live server.
[ -n "${TMUX_SERVER_ID:-}" ] || { echo "can't find pane" >&2; exit 1; }
case "$*" in
  *'#{start_time}'*)
    [ -n "${TMUX_SERVER_START:-}" ] || { echo "can't find pane" >&2; exit 1; }
    printf '%s %s\n' "$TMUX_SERVER_ID" "$TMUX_SERVER_START" ;;
  *'#{window_id}'*) printf '%s\n' '@7' ;;
  *'#{pane_current_path}'*) pwd -P ;;
  *'#{pane_current_command}'*) printf '%s\n' claude ;;
  *'#{pane_pid}'*) printf '%s\n' "$TMUX_PANE_PID" ;;
  *) printf '%s\n' "$TMUX_SERVER_ID" ;;
esac
TMUXSTUB
chmod +x "$TMUX_BIN/tmux"

OVERSEER_PANE=%9
# The server is this suite's parent, as a tmux server is the parent of its
# pane's shell, here this suite's shell: the rows writer's top-level read
# walks the real process table up to this pid, so a hook a child of this
# shell runs, as a harness in the pane would, is that pane's top level.
OVERSEER_SERVER=$PPID
OVERSEER_SERVER_START=1790000000

# The launch home the fleet record's `.overseer.home` names for the overseer
# session, which the transcript ownership gate holds the payload's transcript to.
# OVERSEER_HOME_DIR by default, a claude config dir whose projects tree the
# owned transcript below sits under; a row naming a codex home passes its own.
# START is the `server_start` the record binds its server by, this fixture's
# server's by default, and `none` for a record carrying no start. The harness
# identity is this suite's own shell, as a registration records the harness
# in its pane: the controller's status read takes its liveness from that
# process and asks no pane of the stand-in. The record names the socket its
# server answers on, which the tmux stand-in answers on, so a status read
# that names no socket of its own binds the recorded pane.
OVERSEER_HOME_DIR="$TMP_ROOT/overseer-home"
record_overseer() { # PANE SERVER [HOME] [START]
  local record started home="${3:-$OVERSEER_HOME_DIR}"
  started="$(ps -o lstart= -p "$TMUX_PANE_PID")" || return 1
  record="$(jq -nc --arg s "$2" --arg p "$1" --arg h "$home" --arg start "${4:-$OVERSEER_SERVER_START}" \
    --arg pid "$TMUX_PANE_PID" --arg started "lstart:$started" --arg socket "$TMP_ROOT/tmux-server" \
    '{server: $s, pane: $p, window: "@7", home: $h, session_id:"s1", launch_line: "claude -n overseer",
      harness_pid: $pid, harness_start: $started, server_socket: $socket}
     + (if $start == "none" then {} else {server_start: ($start | tonumber)} end)')"
  (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" \
    set oversee overseer "$record" >/dev/null)
}

# --- the overseer -----------------------------------------------------------
# The files a row writes for the overseer's marks judge: `out` its reply.
JUDGE_DIR="$TMP_ROOT/judge"
mkdir -p "$JUDGE_DIR"
plant_judge() { # [SCRIPTS_DIR]
  [ -n "${1:-}" ] || plant_install
  rm -f -- "${JUDGE_DIR:?}/args" "${JUDGE_DIR:?}/out" "${JUDGE_DIR:?}/err" \
    "${JUDGE_DIR:?}/rc" "${JUDGE_DIR:?}/hang"
}
# The marks verb's replies, each captured for the inputs the fixture records.
MARKS_REPLIES="$TEST_DIR/fixtures/marks-replies.json"
marks_reply() { # SHAPE
  jq -ce --arg shape "$1" '.[$shape].reply | objects' "$MARKS_REPLIES"
}

BELOW_MARK_LINE=$(marks_reply below)

# An overseer session: a repository on a branch no mailbox is named for, so the
# lane rules find nothing, with the orch install and the judge beside the hook
# and a fleet state whose `.overseer` names this pane.
new_overseer() { # NAME [PANE] [SERVER]
  new_lane "$1" main
  unmark_lanes
  plant_judge
  (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" init oversee >/dev/null)
  record_overseer "${2:-$OVERSEER_PANE}" "${3:-$OVERSEER_SERVER}"
}

# session-rows reads ancestry through ps. This table names one top-level
# harness under the fixture's pane, and delegates all other process queries.
wake_row_process_table() {
  local executable
  executable=$(command -v ps) || return 1
  {
    printf '#!/bin/sh\n'
    printf 'if [ "$1" = -o ] && [ "$2" = ppid= ]; then printf "%%s claude\\n" %s; exit 0; fi\n' "$OVERSEER_SERVER"
    printf 'exec %q "$@"\n' "$executable"
  } > "$TMUX_BIN/ps"
  chmod +x "$TMUX_BIN/ps"
}

# The overseer's own native transcript: the claude file the payload's session
# s1 owns under OVERSEER_HOME_DIR, the shape lib/adapters/claude.sh names, so
# the ownership gate reads it as this session's own, into TRANSCRIPT, which
# the overseer rows write and read as the lane rows do their own flat one. It
# holds OVERSEER_CONTEXT, the reading as the judge takes it.
OVERSEER_CONTEXT=600000:1000000
overseer_transcript() {
  TRANSCRIPT="$OVERSEER_HOME_DIR/projects/repo/s1.jsonl"
  mkdir -p "$(dirname "$TRANSCRIPT")"
  write_transcript "$TRANSCRIPT" "${OVERSEER_CONTEXT%%:*}"
}

# The lane-mail-deliver and lane-mail-halt hooks, which run the judge beside
# them, installed with it.
install_arms() { # [JUDGE]
  install_hook "$TEST_DIR/../lane-mail-deliver.sh" "$LANE/.claude/hooks/lane-mail-deliver.sh"
  install_hook "$TEST_DIR/../lane-mail-halt.sh" "$LANE/.claude/hooks/lane-mail-halt.sh"
  install_hook "${1:-$HOOK}" "$LANE/.claude/hooks/lane-mail-check.sh"
}

mutant() { # NAME SED-ARGUMENT... — MUTANT_SOURCE names a file other than the hook
  MUTANT_PATH="$TMP_ROOT/$1.sh"
  local name="$1" source="${MUTANT_SOURCE:-$HOOK}"
  shift
  sed "$@" "$source" > "$MUTANT_PATH"
  assert_eq "$(cmp -s "$MUTANT_PATH" "$source" && echo same || echo differs)" "differs" \
    "control: the $name mutant really differs from the hook"
}
