#!/usr/bin/env bash
# The world the lane-mail suites share: the temp root, the assertions, a lane
# repository with the hook installed where kendex renders it, the payload
# runner, the real `lane-mail` sender, a peer repository sending into the
# lane's overseer mailbox, the tmux pane the fleet record names, and the
# overseer session with the judge beside it. lane-mail-check.test.sh,
# lane-mail-check-copilot.test.sh and lane-mail-check-overseer-tool.test.sh
# source it after `set -euo pipefail`; each counts into the PASS and FAIL set
# here and reports them itself.
# shellcheck disable=SC2034

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which take precedence over `git -C` and
# would configure the real repository.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/lane-mail-check.sh}"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd -P)"
LANE_MAIL="$REPO_ROOT/skills/orch/scripts/lane-mail"
# Canonical from the start: the hook resolves its own directory with pwd -P,
# and on a host whose temp root is a symlink — every macOS one, /var pointing
# at /private/var — a path this suite composed would name the link where the
# hook names the target.
TMP_ROOT="$(mktemp -d)" || { echo "lane-mail-world: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lane-mail-world: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lane-mail-world: scratch=resolve-failed" >&2; exit 1; }
# FAKE_WATCH is the stand-in watch process the overseer mailbox rows start.
trap '[ -z "${FAKE_WATCH:-}" ] || kill "$FAKE_WATCH" 2>/dev/null || :; chmod -R u+rwx -- "${TMP_ROOT:?}" 2>/dev/null || :; rm -rf -- "${TMP_ROOT:?}"' EXIT
ERR_FILE="$TMP_ROOT/stderr"
# Whether this world can hold two names differing only in case. On a
# case-insensitive filesystem, every macOS default one, the second name is the
# first directory, so the ambiguity the hook refuses cannot be built at all.
mkdir -p "$TMP_ROOT/case-probe/A"
CASE_SENSITIVE=1
[ ! -d "$TMP_ROOT/case-probe/a" ] || CASE_SENSITIVE=0
# Whether a mode-000 file can deny this reader. Root ignores the mode, so every
# row that seals a file and asserts the read failed reads a readable file there
# and fails on a world it was never written for. The sibling orch suites guard
# their permission fixtures the same way.
CAN_DENY_READS=1
[ "$(id -u)" -ne 0 ] || CAN_DENY_READS=0
# Which bash runs the hook: its shebang takes the first one on PATH, and the
# two versions differ on what a source it cannot parse does to the shell.
HOOK_BASH_MAJOR="$(bash -c 'printf %s "${BASH_VERSINFO[0]}"')"
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

# The whole assertion: exit status and keyed first line, `-` being silence.
expect() { # RC FIRST LABEL
  assert_eq "RC=$RC first=$(first_line)" "RC=$1 first=$2" "$3"
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

# A lane in a worktree added from a main clone at MAIN, as `worktree create`
# makes one: the two share the common git directory the launch marker lives in.
MAIN=""
new_worktree_lane() { # NAME BRANCH
  REPORT_ITEM=""
  MAIN="$TMP_ROOT/$1-main"
  LANE="$TMP_ROOT/$1"
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q
  git -C "$MAIN" config gc.auto 0
  git -C "$MAIN" config maintenance.auto false
  git -C "$MAIN" checkout -q -b main
  git -C "$MAIN" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m base
  git -C "$MAIN" worktree add -q -b "$2" "$LANE"
  lay_out_lane "$2"
}

# The install and the launch record, on the repository LANE names.
lay_out_lane() { # BRANCH
  mkdir -p "$LANE/.agents/skills/orch" "$LANE/.claude/hooks" "$LANE/.claude/skills"
  ln -s -f -n "$REPO_ROOT/skills/orch/scripts" "$LANE/.agents/skills/orch/scripts"
  ln -s -f -n ../../.agents/skills/orch "$LANE/.claude/skills/orch"
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
# The account mark is never judged in that world, so the hook reports the gap
# and ends the turn. This is the whole of a passing turn end's stderr on a lane
# the marks are reached on, and `-` on one they are not.
GAP='lane-mail-check: account=unlisted'

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
    (cd "${CALL_DIR:-$LANE}" && env -u CLAUDE_CONFIG_DIR -u CLAUDE_PROJECT_DIR -u CODEX_HOME -u COPILOT_HOME -u LANE_MAIL_ITEM \
      -u ORCH_HANDOFF_CONTEXT_PCT -u ORCH_HANDOFF_HEADROOM_PCT -u ORCH_STATE_DIR \
      -u ORCH_OVERSEER_HEADROOM_PCT -u ORCH_OVERSEER_SUCCESSION -u TMUX -u TMUX_PANE \
      "LANES_HOME=$OFFLINE_HOME" "PI_CODING_AGENT_DIR=$OFFLINE_HOME/.pi/agent" \
      DISABLE_AUTO_COMPACT=1 DISABLE_COMPACT=0 "ORCH_COMPACTION_OVERRIDES=$CODEX_COMPACTION" "ORCH_LANES_FETCH_CMD=$NO_FETCH" ${CONTEXT_PCT_ENV:+"$CONTEXT_PCT_ENV"} \
      ${CALL_ENV[@]+"${CALL_ENV[@]}"} "$@" bash "$CASE_HOOK" ${ARM_ARGS[@]+"${ARM_ARGS[@]}"}) >"$TMP_ROOT/stdout" 2>"$ERR_FILE" || RC=$?
}

stop() { # [ENV=VAL...]
  run_payload '{"session_id":"s1","stop_hook_active":false}' "$@"
}

# The turn the harness continued because a stop hook blocked.
stop_active() { # [ENV=VAL...]
  run_payload '{"session_id":"s1","stop_hook_active":true}' "$@"
}

# A turn end whose payload names a transcript, as the harness writes one.
stop_at() { # TRANSCRIPT ACTIVE [ENV=VAL...]
  local path="$1" active="$2"
  shift 2
  run_payload "$(jq -nc --arg p "$path" --argjson a "$active" \
    '{session_id:"s1",stop_hook_active:$a,transcript_path:$p}')" "$@"
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

append_transcript() { # PATH TOKENS
  usage_line claude "$2" >> "$1"
}

# Everything a kendex install renders beside the mailbox reader, taken from the
# catalog itself rather than from a second list here: the handoff marks run
# three of these scripts and those scripts run others, so a case that plants
# its own reader plants the whole neighbourhood the way an install has it. The
# reader is the caller's to plant, and SKIP is the one script a case holes.
plant_siblings() { # SCRIPTS_DIR [SKIP]
  local entry name
  for entry in "$REPO_ROOT/skills/orch/scripts"/*; do
    name="${entry##*/}"
    [ "$name" != lane-mail ] || continue
    [ "$name" != "${2:-}" ] || continue
    ln -s -f -n "$entry" "$1/$name"
  done
}

# The real orch skill beside the hook, with SKIP left out: the walk finds this
# copy before the one under .agents, so a case can hole an install without
# touching anything else the lane carries.
plant_install() { # [SKIP]
  # Whatever stands there, a link new_lane made or an install an earlier call
  # planted, so a case can plant twice.
  rm -rf -- "${LANE:?}/.claude/skills/orch"
  mkdir -p "$LANE/.claude/skills/orch/scripts"
  ln -s -f -n "$REPO_ROOT/skills/orch/scripts/lane-mail" "$LANE/.claude/skills/orch/scripts/lane-mail"
  plant_siblings "$LANE/.claude/skills/orch/scripts" "${1:-}"
}

# The orch install the lane renders under .agents, which the hook finds from
# any hook directory in the lane, made a copy with SKIP left out: a script, or
# a library under lib/.
hole_install() { # SKIP
  local dir="$LANE/.agents/skills/orch/scripts" entry
  rm -f -- "${LANE:?}/.agents/skills/orch/scripts"
  mkdir -p "$dir"
  ln -s -f -n "$REPO_ROOT/skills/orch/scripts/lane-mail" "$dir/lane-mail"
  case "$1" in
    lib/*)
      plant_siblings "$dir" lib
      mkdir -p "$dir/lib"
      for entry in "$REPO_ROOT/skills/orch/scripts/lib"/*; do
        [ "lib/${entry##*/}" != "$1" ] || continue
        ln -s -f -n "$entry" "$dir/lib/${entry##*/}"
      done
      ;;
    *) plant_siblings "$dir" "$1" ;;
  esac
}

# The repository's own reader: it touches MARKER, so a run of it is visible.
plant_reader() { # MARKER
  rm -f "$LANE/.claude/skills/orch" "$LANE/.agents/skills/orch/scripts"
  mkdir -p "$LANE/.agents/skills/orch/scripts"
  printf '#!/bin/sh\ntouch %s\n' "$1" > "$LANE/.agents/skills/orch/scripts/lane-mail"
  chmod +x "$LANE/.agents/skills/orch/scripts/lane-mail"
  plant_siblings "$LANE/.agents/skills/orch/scripts"
}

# The real reader behind one planted shell line that runs first, so a case can
# break one verb and keep every other one: the line decides on "$1".
wrap_reader() { # LINE
  rm -f -- "${LANE:?}/.agents/skills/orch/scripts"
  mkdir -p "$LANE/.agents/skills/orch/scripts"
  plant_siblings "$LANE/.agents/skills/orch/scripts"
  printf '#!/usr/bin/env bash\n%s\nexec %q "$@"\n' "$1" "$LANE_MAIL" > "$LANE/.agents/skills/orch/scripts/lane-mail"
  chmod +x "$LANE/.agents/skills/orch/scripts/lane-mail"
}

send() { # ITEM TEXT [--re MSGID]
  ITEM="$1"
  printf '%s\n' "$2" > "$TMP_ROOT/msg.txt"
  shift 2
  (cd "$LANE" && "$LANE_MAIL" send --item "$ITEM" --root "$LANE" "${@:---directive}" --file "$TMP_ROOT/msg.txt")
}

# --- the overseer's identity -----------------------------------------------
# What establishes an overseer is the pane: `oversee-watch` records the
# overseer's tmux server and pane in the fleet state, and a session whose own
# pane key is that pair is that overseer. The tmux stub below is the one read
# that asks — the server a pane belongs to, which the orch library pairs with
# $TMUX_PANE.
TMUX_BIN="$TMP_ROOT/tmux-bin"
mkdir -p "$TMUX_BIN"
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
  *) printf '%s\n' "$TMUX_SERVER_ID" ;;
esac
TMUXSTUB
chmod +x "$TMUX_BIN/tmux"

OVERSEER_PANE=%9
OVERSEER_SERVER=7000
OVERSEER_SERVER_START=1790000000

# The launch home the fleet record's `.overseer.home` names for the overseer
# session, which the transcript ownership gate holds the payload's transcript to.
# OVERSEER_HOME_DIR by default, a claude config dir whose projects tree the
# owned transcript below sits under; a row naming a codex home passes its own.
# START is the `server_start` the record binds its server by, this fixture's
# server's by default, and `none` for a record carrying no start.
OVERSEER_HOME_DIR="$TMP_ROOT/overseer-home"
record_overseer() { # PANE SERVER [HOME] [START]
  local record home="${3:-$OVERSEER_HOME_DIR}"
  record="$(jq -nc --arg s "$2" --arg p "$1" --arg h "$home" --arg start "${4:-$OVERSEER_SERVER_START}" \
    '{server: $s, pane: $p, window: "@7", home: $h, launch_line: "claude -n overseer"}
     + (if $start == "none" then {} else {server_start: ($start | tonumber)} end)')"
  (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" \
    set oversee overseer "$record" >/dev/null)
}

# The environment a session inside the overseer's own pane carries.
overseer_env() { # [PANE]
  printf '%s\n' "PATH=$TMUX_BIN:$PATH" "TMUX=fake" "TMUX_PANE=${1:-$OVERSEER_PANE}" \
    "TMUX_SERVER_ID=$OVERSEER_SERVER" "TMUX_SERVER_START=$OVERSEER_SERVER_START"
}

# `lane-mail peer send --repo` from another repository's checkout into the
# overseer mailbox of the checkout LANE names; the reader notice the send
# writes on stderr lands in peer.err.
PEER_SENDER="$TMP_ROOT/peer-sender"
mkdir -p "$PEER_SENDER"
git -C "$PEER_SENDER" init -q
git -C "$PEER_SENDER" config gc.auto 0
git -C "$PEER_SENDER" config maintenance.auto false
git -C "$PEER_SENDER" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m base
peer_send() { # TEXT
  printf '%s\n' "$1" > "$TMP_ROOT/peer.txt"
  (cd "$PEER_SENDER" && "$LANE_MAIL" peer send --repo "$LANE" --file "$TMP_ROOT/peer.txt" >/dev/null 2>"$TMP_ROOT/peer.err")
}
# The overseer mailbox's unread lines carrying TEXT, read without moving the
# cursor: what the hook left for another reader.
overseer_unread() { # TEXT
  (cd "$LANE" && "$LANE_MAIL" inbox --item overseer --root "$LANE" --peek) | grep -cF -- "$1" || :
}

# Every keyed value the run wrote, in order, each under its own English: the
# leading run keyed_block reads stops at the first explanation, and the idle
# refusal follows the marks' reports.
hook_keys() {
  sed -n 's/^lane-mail-check: \([a-z-]*=[^ ]*\).*/\1/p' "$ERR_FILE" | paste -sd';' -
}

# A copy of the hook with one constant rewritten, so a row can reach a bound
# the shipped value would make it wait for. The rewrite is asserted, never
# assumed. This is a fixture, not a control: it plants no defect.
VARIANT_PATH=""
variant() { # NAME SED-ARGUMENT...
  VARIANT_PATH="$TMP_ROOT/$1.sh"
  local name="$1"
  shift
  sed "$@" "$HOOK" > "$VARIANT_PATH"
  assert_eq "$(cmp -s "$VARIANT_PATH" "$HOOK" && echo same || echo differs)" "differs" \
    "the $name copy really differs from the hook"
}

# --- the overseer -----------------------------------------------------------
# The judge, and the whole of what this hook reads about an overseer's marks.
# It records its argv, so a row can pin that the hook asked for the judgement
# and nothing else, and answers from files a row writes: `out` its keyed line,
# `rc` its exit status, `err` its own words, `hang` a read that outlasts the
# hook's ceiling. Its own behaviour is oversee_succeed.sh's subject.
JUDGE_DIR="$TMP_ROOT/judge"
mkdir -p "$JUDGE_DIR"
plant_judge() {
  plant_install oversee-succeed
  cat > "$LANE/.claude/skills/orch/scripts/oversee-succeed" <<JUDGE
#!/bin/sh
printf '%s\n' "\$*" >> "$JUDGE_DIR/args"
# stdout is handed away before the wait: the hook reads this in a command
# substitution, which stays open while any writer holds that pipe, so a sleep
# left behind by the ceiling would outlast the kill.
[ ! -f "$JUDGE_DIR/hang" ] || { exec 1>/dev/null; sleep 120; }
[ ! -f "$JUDGE_DIR/err" ] || cat "$JUDGE_DIR/err" >&2
[ ! -f "$JUDGE_DIR/out" ] || cat "$JUDGE_DIR/out"
exit "\$(cat "$JUDGE_DIR/rc" 2>/dev/null || echo 0)"
JUDGE
  chmod +x "$LANE/.claude/skills/orch/scripts/oversee-succeed"
  rm -f -- "${JUDGE_DIR:?}/args" "${JUDGE_DIR:?}/out" "${JUDGE_DIR:?}/err" \
    "${JUDGE_DIR:?}/rc" "${JUDGE_DIR:?}/hang"
}
judge_says() { printf '%s\n' "$1" > "$JUDGE_DIR/out"; }
judge_calls() { [ -f "$JUDGE_DIR/args" ] && wc -l < "$JUDGE_DIR/args" | tr -d ' ' || echo 0; }
judge_argv() { cat "$JUDGE_DIR/args" 2>/dev/null || true; }

CONTEXT_MARK_LINE="oversee-succeed: mark-reached kind=context value=612000 mark=500000 succession=on headroom=80"
# The same crossing with the succession the operator turned off, which the
# judgement reports on its own line and this hook reads nowhere else.
OFF_MARK_LINE="oversee-succeed: mark-reached kind=context value=612000 mark=500000 succession=off headroom=80"
OFF_HEADROOM_LINE="oversee-succeed: mark-reached kind=headroom value=4 mark=10 succession=off account=eclaude resets=2026-07-27T06:00:00Z"
HEADROOM_MARK_LINE="oversee-succeed: mark-reached kind=headroom value=4 mark=10 succession=on account=eclaude resets=2026-07-27T06:00:00Z"
RATE_MARK_LINE="oversee-succeed: mark-reached kind=rate value=30 mark=30 succession=on account=eclaude"
QUALIFYING_MARK_LINE="oversee-succeed: mark-reached kind=qualifying value=1 mark=1 succession=on headroom=unreadable"
BELOW_MARK_LINE="oversee-succeed: context-below-mark tokens=100000 mark=500000 headroom=80"

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

# The record that ends an overseer's refusal, written on the fleet's own item.
# It names the session that wrote it in both of the two names this hook reads,
# the payload's id and the pane key, and a row supplies another value for
# whichever name it is about.
record_overseer_handoff() { # [SESSION_ID] [PANE_KEY]
  local record
  record="$(jq -nc --arg s "${1:-s1}" --arg k "${2:-$OVERSEER_SERVER $OVERSEER_PANE}" \
    '{written_at:"2026-09-20T06:20:00Z",handoff_file:"tmp/handoffs/OVERSEER-HANDOFF.md",
      pane_key:$k,session_id:$s}')"
  (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" set oversee handoff \
    "$record" >/dev/null)
}

# The workflow-state of the install new_overseer planted, or of the one DIR
# names, replaced by one that runs the real script for every verb but the one
# MODE fails: `path` for path-fails, `update` for update-fails,
# `handoff-standing` for standing-fails, none for delegate. Each run appends
# its verb to STATE_LOG, so a row can count what the hook asked. The real one
# is run by its own path, so it sources its own libraries whatever the
# install holds.
STATE_LOG="$TMP_ROOT/state-verbs"
state_stub() { # path-fails|update-fails|standing-fails|delegate [DIR]
  local dir="${2:-$LANE/.claude/skills/orch/scripts}"
  rm -f -- "${dir:?}/workflow-state" "$STATE_LOG"
  {
    printf '#!/bin/sh\n'
    printf 'printf "%%s\\n" "$1" >> %q\n' "$STATE_LOG"
    case "$1" in
      path-fails) printf '[ "$1" != path ] || { echo "workflow-state: lock-failed lock-file=x" >&2; exit 3; }\n' ;;
      update-fails) printf '[ "$1" != update ] || { echo "workflow-state: lock-failed lock-file=x" >&2; exit 1; }\n' ;;
      standing-fails) printf '[ "$1" != handoff-standing ] || { echo "workflow-state: lock-failed lock-file=x" >&2; exit 3; }\n' ;;
    esac
    printf 'exec %q "$@"\n' "$REPO_ROOT/skills/orch/scripts/workflow-state"
  } > "$dir/workflow-state"
  chmod +x "$dir/workflow-state"
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

# The fleet record for this pane rewritten with the pane and server alone,
# plus FIELDS: no server start, no home and no harness unless FIELDS names
# them, the shape a writer from before those were recorded left; and one
# field of the record as it now stands, `none` where it names none.
startless_record() { # [FIELDS_JSON] — the pane and server alone, plus FIELDS
  local fields="${1:-}"
  [ -n "$fields" ] || fields='{}'
  (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" set oversee overseer \
    "$(jq -nc --arg s "$OVERSEER_SERVER" --arg p "$OVERSEER_PANE" --argjson f "$fields" \
      '{server:$s,pane:$p,window:"@7",launch_line:"claude -n overseer"} + $f')" >/dev/null)
}
recorded_field() { # FIELD
  (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" get oversee ".overseer.$1 // \"none\"")
}

# The lane-mail-deliver and lane-mail-halt hooks, which run the judge beside
# them, installed with it.
install_arms() { # [JUDGE]
  install_hook "$TEST_DIR/../lane-mail-deliver.sh" "$LANE/.claude/hooks/lane-mail-deliver.sh"
  install_hook "$TEST_DIR/../lane-mail-halt.sh" "$LANE/.claude/hooks/lane-mail-halt.sh"
  install_hook "${1:-$HOOK}" "$LANE/.claude/hooks/lane-mail-check.sh"
}

# The event a deliver run's JSON names and the first line of the context it
# carries; `-` for no output.
context_line() {
  [ -s "$TMP_ROOT/stdout" ] || { echo -; return; }
  jq -r '"\(.hookSpecificOutput.hookEventName) \(.hookSpecificOutput.additionalContext | split("\n")[0])"' "$TMP_ROOT/stdout"
}

mutant() { # NAME SED-ARGUMENT... — MUTANT_SOURCE names a file other than the hook
  MUTANT_PATH="$TMP_ROOT/$1.sh"
  local name="$1" source="${MUTANT_SOURCE:-$HOOK}"
  shift
  sed "$@" "$source" > "$MUTANT_PATH"
  assert_eq "$(cmp -s "$MUTANT_PATH" "$source" && echo same || echo differs)" "differs" \
    "control: the $name mutant really differs from the hook"
}
