#!/usr/bin/env bash
# The critical-path-deny hook: in a launched lane it answers the prompt Claude
# Code's critical-path check shows for a Bash call with deny and the rewrite,
# and everywhere else, and for every other prompt, it returns no decision.
# The payloads are the three Claude Code 2.1.288 was measured sending
# (fixtures/critical-path-deny-claude-2.1.288.jsonl: the main session's
# critical-path prompt, an ask-rule prompt, a subagent's critical-path prompt),
# and the lane is the one the orch skill's real `lane-marker` writes. Each row
# asserts the exit status, the decision on stdout and the keyed first line of
# stderr. HOOK_UNDER_TEST overrides the hook copy the controls at the end run.
set -euo pipefail

unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$(cd "$TEST_DIR/.." && pwd)"
HOOK="${HOOK_UNDER_TEST:-$HOOKS/critical-path-deny.sh}"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd -P)"
FIXTURE="$TEST_DIR/fixtures/critical-path-deny-claude-2.1.288.jsonl"
TMP_ROOT="$(mktemp -d)" || { echo "critical-path-deny: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "critical-path-deny: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "critical-path-deny: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
ERR_FILE="$TMP_ROOT/stderr"
OUT_FILE="$TMP_ROOT/stdout"
PASS=0
FAIL=0

# shellcheck source=lib/assert.sh
. "$TEST_DIR/lib/assert.sh"
# shellcheck source=lib/first-line.sh
. "$TEST_DIR/lib/first-line.sh"

# The measured payloads, by line, and four built from them: the critical-path
# prompt on a command holding no rm text and on another tool, the ask-rule
# prompt on the critical-path command, as an ask rule matching rm shows it,
# and the critical-path command offering an allow rule, as an ordinary rm
# prompt does (the addRules entry the hooks reference shows for one).
payload() { # main|ask|sub|norm|edit|askrm|suggest|junk
  local line
  case "$1" in
    main) line=1 ;;
    ask) line=2 ;;
    sub) line=3 ;;
    norm) payload main | jq -c '.tool_input.command = "echo scratch"'; return ;;
    edit) payload main | jq -c '.tool_name = "Edit"'; return ;;
    askrm) payload ask | jq -c --argjson main "$(payload main)" '.tool_input.command = $main.tool_input.command'; return ;;
    suggest)
      payload main | jq -c '.permission_suggestions = [{type: "addRules", rules: [{toolName: "Bash", ruleContent: .tool_input.command}], behavior: "allow", destination: "localSettings"}]'
      return
      ;;
    junk) printf '{not json'; return ;;
  esac
  sed -n "${line}p" "$FIXTURE"
}

# A repository on branch ken-1 with the hook and lane-mail-check under
# .claude/hooks, as a Claude Code project install renders them. SHAPE:
#   lane      launched: `lane-marker` wrote the marker and the mailbox
#   plain     no launch reached it
#   nojudge   launched, with no lane-mail-check beside the hook
#   badjudge  launched, with a lane-mail-check that writes `boom` and exits 3
#   markerdir launched, with a directory where the launch marker stands, which
#             lane-mail-check reports with no answer
LANE=""
world() { # NAME SHAPE
  LANE="$TMP_ROOT/$1"
  mkdir -p "$LANE/.claude/hooks"
  git -C "$LANE" init -q
  git -C "$LANE" checkout -q -b ken-1
  git -C "$LANE" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m base
  cp "$HOOK" "$LANE/.claude/hooks/critical-path-deny.sh"
  cp "$HOOKS/lane-mail-check.sh" "$LANE/.claude/hooks/lane-mail-check.sh"
  [ "$2" = plain ] || "$REPO_ROOT/skills/orch/scripts/lane-marker" "$LANE" KEN-1
  case "$2" in
    nojudge) rm -f -- "$LANE/.claude/hooks/lane-mail-check.sh" ;;
    badjudge) printf '#!/usr/bin/env bash\necho boom >&2\nexit 3\n' > "$LANE/.claude/hooks/lane-mail-check.sh" ;;
    markerdir) rm -f -- "$LANE/.git/lane-mail/ken-1"; mkdir -- "$LANE/.git/lane-mail/ken-1" ;;
  esac
}

RC=0
run() { # PAYLOAD-NAME
  RC=0
  payload "$1" |
    (cd "$LANE" && env -u LANE_MAIL_ITEM "CLAUDE_PROJECT_DIR=$LANE" bash "$LANE/.claude/hooks/critical-path-deny.sh") \
      >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?
}

# What stdout decided: the decision's behavior and its message's first line,
# `none` for no output, `unread` for output that is no decision.
decision() {
  [ -s "$OUT_FILE" ] || { echo none; return; }
  jq -r '.hookSpecificOutput | select(.hookEventName == "PermissionRequest")
    | "\(.decision.behavior) \(.decision.message | split("\n")[0])"' "$OUT_FILE" 2>/dev/null || echo unread
}

DENY='deny critical-path-deny: refused=critical-path-removal'
rows() {
  local name shape load want label
  while IFS='|' read -r name shape load want label; do
    [ -n "$name" ] || continue
    world "$name" "$shape"
    run "$load"
    assert_eq "RC=$RC decision=$(decision) first=$(first_line) cause=$(cause_below)" \
      "${want//@LANE@/$LANE}" "$label"
  done <<ROWS
main|lane|main|RC=0 decision=$DENY first=- cause=absent|the main session's critical-path prompt in a launched lane is denied with the rewrite
sub|lane|sub|RC=0 decision=$DENY first=- cause=absent|a subagent's critical-path prompt in a launched lane is denied with the rewrite
ask|lane|ask|RC=0 decision=none first=- cause=absent|an ask-rule prompt in a launched lane is left standing
norm|lane|norm|RC=0 decision=none first=- cause=absent|a prompt with an empty suggestion list on a command holding no rm is left standing
askrm|lane|askrm|RC=0 decision=none first=- cause=absent|an ask-rule prompt on an rm command in a launched lane is left standing
suggest|lane|suggest|RC=0 decision=none first=- cause=absent|an rm prompt offering an allow rule in a launched lane is left standing
edit|lane|edit|RC=0 decision=none first=- cause=absent|a prompt for another tool is left standing
outside|plain|main|RC=0 decision=none first=- cause=absent|a critical-path prompt outside a lane is left standing
junk|lane|junk|RC=0 decision=none first=critical-path-deny: payload=invalid-json cause=present|a payload that is no JSON is reported and the prompt left standing
nojudge|nojudge|main|RC=0 decision=none first=critical-path-deny: judge=@LANE@/.claude/hooks/lane-mail-check.sh cause=present|a lane-mail-check missing from beside the hook is reported and the prompt left standing
badjudge|badjudge|main|RC=0 decision=none first=critical-path-deny: lane=exit-3 cause=present|a lane-mail-check that cannot answer is reported and the prompt left standing
markerdir|markerdir|main|RC=0 decision=none first=critical-path-deny: lane=empty cause=present|a lane-mail-check that answers nothing is reported and the prompt left standing
ROWS
}
rows

world deny_text lane
run main
assert_eq "$(jq -r '.hookSpecificOutput.decision.message' "$OUT_FILE" | grep -c -F -e '"${DIR:?}"/*' -e "tmp/ and run that file")" 2 \
  "the deny message gives both rewrites: the guarded expansion and the script file under the lane's tmp/"
world judge_cause badjudge
run main
assert_eq "$(grep -c -x boom "$ERR_FILE")" 1 "what lane-mail-check wrote is replayed under the keyed line"

# The must-fail controls, each a mutant copy run through the same rows: one per
# rule of the critical-path match and of the lane gate, one for the deny, and
# one for each lane-mail-check failure reported as a gap, a failed exit and an
# empty answer. Skipped when this run is itself a control.
if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  control() { # NAME SED-ARGUMENT FAILED-ROW
    local mutant="$TMP_ROOT/$1.sh" out
    sed -e "$2" "$HOOKS/critical-path-deny.sh" > "$mutant"
    assert_eq "$(cmp -s "$mutant" "$HOOKS/critical-path-deny.sh" && echo same || echo differs)" differs \
      "control: the $1 mutant really differs from the hook"
    out="$(HOOK_UNDER_TEST="$mutant" bash "${BASH_SOURCE[0]}" 2>&1 || true)"
    assert_eq "$(grep -Fxc -e "  FAIL  $3" <<<"$out" || true)" 1 "control $1: $3"
  }
  # The deny never written: the prompt is not answered.
  control unanswered 's/^  0:lane) ;;$/  0:lane) exit 0 ;;/' \
    "a subagent's critical-path prompt in a launched lane is denied with the rewrite"
  # The lane gate dropped: a prompt outside a lane is denied.
  control ungated 's/^  0:none) exit 0 ;;$/  0:none) ;;/' \
    "a critical-path prompt outside a lane is left standing"
  # Another tool's prompt no longer excluded: an Edit prompt is denied.
  control toolless 's/if \.tool_name == "Bash"/if true/' \
    "a prompt for another tool is left standing"
  # The suggestion list's presence no longer required: an ask rule is denied.
  control listless 's/(\.permission_suggestions | type) == "array"/true/' \
    "an ask-rule prompt on an rm command in a launched lane is left standing"
  # The suggestion list's emptiness no longer required: an ordinary rm prompt
  # is denied.
  control offered 's/(\.permission_suggestions | length) == 0/true/' \
    "an rm prompt offering an allow rule in a launched lane is left standing"
  # The rm text no longer required: any empty-list prompt is denied.
  control rmless 's/contains("rm")/contains("")/' \
    "a prompt with an empty suggestion list on a command holding no rm is left standing"
  # A judge that cannot answer passed in silence.
  control silent 's/^  \*) report lane "exit-\$JUDGE_RC" "\$(cat -- "\$ERR_FILE")" ;;$/  *) exit 0 ;;/' \
    "a lane-mail-check that cannot answer is reported and the prompt left standing"
  # A judge that answered nothing passed in silence.
  control mute 's/^  0:) report lane empty "\$(cat -- "\$ERR_FILE")" ;;$/  0:) exit 0 ;;/' \
    "a lane-mail-check that answers nothing is reported and the prompt left standing"
fi

printf '\n=== %s passed, %s failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
