#!/usr/bin/env bash
# The world the lane-mail suites share: the temp root, the assertions, a lane
# repository with the hook installed where kendex renders it, the payload
# runner and the real `lane-mail` sender. lane-mail-check.test.sh and
# lane-mail-check-copilot.test.sh source it after `set -euo pipefail`; each
# counts into the PASS and FAIL set here and reports them itself.
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
TMP_ROOT="$(cd -- "$(mktemp -d)" && pwd -P)"
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
  LANE="$TMP_ROOT/$1"
  mkdir -p "$LANE"
  git -C "$LANE" init -q
  git -C "$LANE" checkout -q -b "$2"
  git -C "$LANE" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m base
  lay_out_lane "$2"
}

# A lane in a worktree added from a main clone at MAIN, as `worktree create`
# makes one: the two share the common git directory the launch marker lives in.
MAIN=""
new_worktree_lane() { # NAME BRANCH
  MAIN="$TMP_ROOT/$1-main"
  LANE="$TMP_ROOT/$1"
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q
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

RC=0
# The judge's argument, empty for the turn-end run the harness makes.
ARM_ARGS=()
# The directory the call is made from, the lane's own unless a case names
# another: a lane runs its post-merge steps from the main clone. CALL_ENV is
# what the harness running that call sets, such as the directory it started in.
CALL_DIR=""
CALL_ENV=()
run_payload() { # RAW-JSON [ENV=VAL...]
  local payload="$1"
  shift
  RC=0
  : > "$ERR_FILE"
  printf '%s' "$payload" |
    (cd "${CALL_DIR:-$LANE}" && env -u CLAUDE_CONFIG_DIR -u CLAUDE_PROJECT_DIR -u CODEX_HOME -u LANE_MAIL_ITEM \
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
#   sonnet  the same line on a model whose window the claude adapter leaves
#           unnamed.
#   pi      Pi's session entry, `appendMessage` in @earendil-works/pi-coding-agent,
#           carrying the `Usage` of @earendil-works/pi-ai: input, output,
#           cacheRead, cacheWrite, totalTokens and cost, none of them spelled
#           the way Claude Code spells them.
#   codex   Codex's rollout: the turn context naming the model, then the
#           token count naming the tokens the last response left in a 258400
#           window.
#   unread  a usage object carrying no spelling the claude adapter reads, which
#           is what the hook must report rather than sum to zero. TOKENS is
#           what a lane would be past its mark by if the figure could be read.
usage_line() { # SPELLING TOKENS
  case "$1" in
    claude | sonnet)
      jq -nc --argjson t "$2" --arg m "$([ "$1" = claude ] && echo claude-opus-5-5 || echo claude-sonnet-5)" \
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
          message:{role:"assistant",model:"m",stopReason:"stop",
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

# The repository's own reader: it touches MARKER, so a run of it is visible.
plant_reader() { # MARKER
  rm -f "$LANE/.claude/skills/orch" "$LANE/.agents/skills/orch/scripts"
  mkdir -p "$LANE/.agents/skills/orch/scripts"
  printf '#!/bin/sh\ntouch %s\n' "$1" > "$LANE/.agents/skills/orch/scripts/lane-mail"
  chmod +x "$LANE/.agents/skills/orch/scripts/lane-mail"
  plant_siblings "$LANE/.agents/skills/orch/scripts"
}

send() { # ITEM TEXT [--re MSGID]
  ITEM="$1"
  printf '%s\n' "$2" > "$TMP_ROOT/msg.txt"
  shift 2
  (cd "$LANE" && "$LANE_MAIL" send --item "$ITEM" --root "$LANE" "${@:---directive}" --file "$TMP_ROOT/msg.txt")
}

mutant() { # NAME SED-ARGUMENT... — MUTANT_SOURCE names a file other than the hook
  MUTANT_PATH="$TMP_ROOT/$1.sh"
  local name="$1" source="${MUTANT_SOURCE:-$HOOK}"
  shift
  sed "$@" "$source" > "$MUTANT_PATH"
  assert_eq "$(cmp -s "$MUTANT_PATH" "$source" && echo same || echo differs)" "differs" \
    "control: the $name mutant really differs from the hook"
}
