#!/usr/bin/env bash
# skill-load-check on Copilot: the hook installed where kendex renders it for
# Copilot, `.github/hooks`, with the skill-load-record hook beside it, run with
# the camelCase payloads Copilot's hooks reference gives for preToolUse and
# postToolUse. The skill tool's own payload, `toolName` "skill" with the
# skill under `toolArgs.skill`, is the one Copilot CLI 1.0.88 sent in the
# probe KEN-1980 records; the reference does not list that tool. Every other
# harness's rows are skill-load-check.test.sh.
#
# Pinned: a Copilot agent is refused until a finished load of the skill is
# recorded under its own sessionId, a subagent apart from its parent; the
# carrier's matcher names `skill` as an alternative of its own; only a
# `skill` call whose toolResult.resultType is `success` records; the refusal
# is also Copilot's permissionDecision deny on stdout, its reason the stderr
# text; one skill's load clears no call that needs another; loads finishing
# at once all land; a stale record is pruned; each shell and edit tool
# Copilot's hooks reference lists for Bash, Write and Edit is judged from its
# own toolArgs, an apply_patch call by every file its patch names; a Copilot
# call reaching another harness's copy passes there under
# `harness=copilot`; a call needing a skill is refused where no carrier is
# installed; and the fail-closed edges of the record: an id or a record it
# cannot read, one it cannot write.
#
# HOOK_UNDER_TEST overrides the judge the rows install and CARRIER_UNDER_TEST
# the skill-load-record hook beside it, so a must-fail control reruns these
# assertions on a planted copy of either.
set -euo pipefail

unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/skill-load-check.sh}"
CARRIER="${CARRIER_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/skill-load-record.sh}"
LIBRARY="$(cd "$TEST_DIR/../.." && pwd)/skills/commit-guards/scripts/lib/command-position.sh"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)" || { echo "skill-load-check-copilot: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "skill-load-check-copilot: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "skill-load-check-copilot: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
BASH_BIN="$(command -v bash)"
ERR_FILE="$TMP_ROOT/stderr"
OUT_FILE="$TMP_ROOT/stdout"
JQ=(jq --null-input --compact-output)

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

# The repository the calls edit, with the commit-guards library a command is
# read with, and the Copilot install: the judge and its carrier side by side.
REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/src" "$REPO/.github/hooks" "$REPO/.claude/hooks" \
  "$REPO/.agents/skills/commit-guards/scripts/lib"
env HOME="$TMP_ROOT" git init -q "$REPO"
cp "$LIBRARY" "$REPO/.agents/skills/commit-guards/scripts/lib/command-position.sh"
JUDGE="$REPO/.github/hooks/skill-load-check.sh"
cp "$HOOK" "$JUDGE"
cp "$CARRIER" "$REPO/.github/hooks/skill-load-record.sh"
STATE_HOME="$TMP_ROOT/state"
RECORDS="$STATE_HOME/kendex/skill-load-check"

# One run of SCRIPT on PAYLOAD under a clean environment: rc, stderr in
# ERR_FILE, stdout in OUT_FILE. ENV entries replace the default HOME and
# XDG_STATE_HOME; `-` for an entry drops the variable.
run_at() { # SCRIPT PAYLOAD [NAME=VALUE|-NAME ...]
  local script="$1" payload="$2" home="HOME=$TMP_ROOT" xdg="XDG_STATE_HOME=$STATE_HOME" entry
  shift 2
  for entry in "$@"; do
    case "$entry" in
      -HOME) home="" ;;
      -XDG_STATE_HOME) xdg="" ;;
      HOME=*) home=$entry ;;
      XDG_STATE_HOME=*) xdg=$entry ;;
      *) echo "run_at: no environment entry named $entry" >&2; exit 2 ;;
    esac
  done
  set +e
  env -i PATH="$PATH" ${home:+"$home"} ${xdg:+"$xdg"} "$BASH_BIN" "$script" \
    >"$OUT_FILE" 2>"$ERR_FILE" <<<"$payload"
  rc=$?
  set -e
}

# The payloads, as the reference shapes them. ARGS is the toolArgs value.
pre() { # SESSION TOOL ARGS-JSON
  "${JQ[@]}" --arg s "$1" --arg t "$2" --argjson a "$3" --arg cwd "$REPO" \
    '{sessionId:$s, timestamp:1, cwd:$cwd, toolName:$t, toolArgs:$a}'
}
SUCCESS='{"resultType":"success","textResultForLlm":"Skill loaded successfully."}'
post() { # SESSION TOOL ARGS-JSON [RESULT-JSON]
  "${JQ[@]}" --arg s "$1" --arg t "$2" --argjson a "$3" --arg cwd "$REPO" \
    --argjson r "${4:-$SUCCESS}" \
    '{sessionId:$s, timestamp:1, cwd:$cwd, toolName:$t, toolArgs:$a, toolResult:$r}'
}
edit_of() { # SESSION [PATH] -> an edit of a source file
  pre "$1" edit "$("${JQ[@]}" --arg p "${2:-$REPO/src/lib.rs}" '{path:$p, old_str:"a", new_str:"b"}')"
}
load() { # SESSION SKILL [ENV...] -> run the carrier on a successful load
  local session="$1" skill="$2"
  shift 2
  run_at "$REPO/.github/hooks/skill-load-record.sh" \
    "$(post "$session" skill "$("${JQ[@]}" --arg s "$skill" '{skill:$s}')")" "$@"
}
LINEAR_CALL='.agents/skills/linear/scripts/linear.sh issues list --state Todo'

echo "=== skill-load-check: copilot ==="

echo "an agent is refused until its own finished load is recorded"
run_at "$JUDGE" "$(edit_of lead)"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=skill-load-check: unloaded=code-quality" \
  "an edit before any load is refused, the skill its value"
assert_eq "$(jq -r '.permissionDecision' <"$OUT_FILE")" deny \
  "the refusal is also Copilot's permissionDecision deny on stdout"
assert_eq "$(jq -r '.permissionDecisionReason' <"$OUT_FILE")" "$(cat "$ERR_FILE")" \
  "and its reason is the refusal's own text, the keyed line first"
run_at "$JUDGE" "$(pre lead create "$("${JQ[@]}" --arg p "$REPO/new/probe.rs" '{path:$p, file_text:"x"}')")"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=skill-load-check: unloaded=code-quality" \
  "a create of a new file reads its target from toolArgs.path too"
while IFS='|' read -r label shape; do
  [ -n "$label" ] || continue
  args=$("${JQ[@]}" --arg c "$LINEAR_CALL" '{command:$c, description:"list"}')
  [ "$shape" = object ] || args=$(jq -c 'tojson' <<<"$args")
  run_at "$JUDGE" "$(pre lead bash "$args")"
  assert_eq "rc=$rc first=$(first_line)" "rc=2 first=skill-load-check: unloaded=linear" "$label"
done <<'ROWS'
a linear.sh command in toolArgs as an object is refused until linear loads|object
a linear.sh command in toolArgs as one JSON string is refused the same|string
ROWS
load lead code-quality
assert_eq "rc=$rc first=$(first_line) out=$(cat "$OUT_FILE")" "rc=0 first=- out=" \
  "a finished load is recorded silently"
run_at "$JUDGE" "$(edit_of lead)"
assert_eq "rc=$rc first=$(first_line) out=$(cat "$OUT_FILE")" "rc=0 first=- out=" \
  "the same agent's edit passes once its load is recorded"
# The record is read for the skill the call needs, not for any load at all.
run_at "$JUDGE" "$(pre lead bash "$("${JQ[@]}" --arg c "$LINEAR_CALL" '{command:$c}')")"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=skill-load-check: unloaded=linear" \
  "its linear.sh call is still refused: code-quality is not linear"
run_at "$JUDGE" "$(edit_of lead "$REPO/README.md")"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=skill-load-check: unloaded=docs-writing" \
  "and so is its edit of a markdown file"
run_at "$JUDGE" "$(pre lead apply_patch "$(jq -c -n --arg p "*** Begin Patch
*** Update File: $REPO/src/lib.rs
@@
-a
+b
*** Add File: $REPO/NOTES.md
+x
*** End Patch" '$p')")"
assert_eq "rc=$rc first=$(first_line) named=$(sed -n '2,3p' "$ERR_FILE" | paste -sd ' ' -)" \
  "rc=2 first=skill-load-check: unloaded=docs-writing named=$REPO/src/lib.rs $REPO/NOTES.md" \
  "a patch is judged by each file it names: the source file is cleared, the markdown file is not, and the refusal names both"
load lead linear
run_at "$JUDGE" "$(pre lead bash "$("${JQ[@]}" --arg c "$LINEAR_CALL" '{command:$c}')")"
assert_eq "rc=$rc first=$(first_line)" "rc=0 first=-" \
  "once it loads linear, its linear.sh call passes"

echo "a subagent is judged by its own sessionId"
run_at "$JUDGE" "$(edit_of child)"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=skill-load-check: unloaded=code-quality" \
  "a child's edit is refused though its parent loaded the skill"
load child code-quality
run_at "$JUDGE" "$(edit_of child)"
assert_eq "rc=$rc" "rc=0" "and passes once the child loads it"

echo "the carrier's matcher reaches Copilot's skill tool as written"
# kendex 1.2.0 renders a matcher alternative it does not map as written, and
# Copilot anchors the pattern, so there only an alternative spelled `skill`
# fires on the tool the load payloads name. Every other row runs the carrier
# directly and never reads its matcher.
matcher=$(sed -n 's/^# matcher: //p' "$CARRIER")
named=absent
case "|$matcher|" in *"|skill|"*) named=present ;; esac
assert_eq "skill=$named" "skill=present" \
  "skill-load-record's matcher names skill as an alternative of its own"

echo "only a finished, successful skill load records"
# label|tool|args|result: each a finished call that is not a successful load
# of code-quality, on a fresh agent whose edit must stay refused.
# Each record run is also silent: a row that fails to record by erroring out
# is not a row that judged the call no load.
N=0
while IFS='|' read -r label tool args result; do
  [ -n "$label" ] || continue
  N=$((N + 1))
  run_at "$REPO/.github/hooks/skill-load-record.sh" "$(post "not-$N" "$tool" "$args" "$result")"
  record="record=$rc first=$(first_line)"
  run_at "$JUDGE" "$(edit_of "not-$N")"
  assert_eq "$record rc=$rc first=$(first_line)" \
    "record=0 first=- rc=2 first=skill-load-check: unloaded=code-quality" "$label"
done <<'ROWS'
a load whose resultType is failure records nothing|skill|{"skill":"code-quality"}|{"resultType":"failure","textResultForLlm":"Skill \"code-quality\" loaded successfully."}
a load whose resultType is denied records nothing|skill|{"skill":"code-quality"}|{"resultType":"denied","textResultForLlm":"x"}
a load with no toolResult object records nothing|skill|{"skill":"code-quality"}|"success"
a manual view of the skill's SKILL.md is no load|view|{"path":"/r/.agents/skills/code-quality/SKILL.md"}|{"resultType":"success","textResultForLlm":"body"}
ROWS
[ "$N" -eq 4 ] || { echo "only-success: rows asserted: $N" >&2; exit 2; }

echo "loads that finish at once all land"
SKILLS="code-quality docs-writing linear iced-rs dev orch reviewer github"
PIDS=""
for skill in $SKILLS; do
  env -i PATH="$PATH" HOME="$TMP_ROOT" XDG_STATE_HOME="$STATE_HOME" "$BASH_BIN" \
    "$REPO/.github/hooks/skill-load-record.sh" \
    <<<"$(post parallel skill "$("${JQ[@]}" --arg s "$skill" '{skill:$s}')")" &
  PIDS="$PIDS $!"
done
for pid in $PIDS; do wait "$pid"; done
assert_eq "$(sort <"$RECORDS/parallel" | tr '\n' ' ')" "$(printf '%s\n' $SKILLS | sort | tr '\n' ' ')" \
  "each of eight concurrent loads is one whole line of the record"

echo "the record is private to the user"
assert_eq "$(ls -ld "$RECORDS" | cut -c1-10) $(ls -l "$RECORDS/lead" | cut -c1-10)" \
  "drwx------ -rw-------" "the record directory and file are the user's alone"
load home-only code-quality -XDG_STATE_HOME
assert_eq "rc=$rc file=$([ -f "$TMP_ROOT/.local/state/kendex/skill-load-check/home-only" ] && echo yes || echo no)" \
  "rc=0 file=yes" "with XDG_STATE_HOME unset the record is under HOME's .local/state"

echo "a record untouched for 30 days is pruned"
: >"$RECORDS/ended"
touch -t 202001010000 "$RECORDS/ended"
touch -t 202001010000 "$RECORDS/lead"
load lead code-quality
assert_eq "ended=$([ -e "$RECORDS/ended" ] && echo kept || echo pruned) lead=$([ -e "$RECORDS/lead" ] && echo kept || echo pruned)" \
  "ended=pruned lead=kept" "a stale record goes; the one just written is renewed and stays"

echo "a Copilot call reaching another harness's copy passes there under its own key"
cp "$HOOK" "$REPO/.claude/hooks/skill-load-check.sh"
run_at "$REPO/.claude/hooks/skill-load-check.sh" "$(edit_of cross)"
assert_eq "rc=$rc first=$(first_line) out=$(cat "$OUT_FILE")" "rc=0 first=skill-load-check: harness=copilot out=" \
  "the camelCase payload passes a Claude copy, named as a Copilot call left to the Copilot copy"
run_at "$REPO/.claude/hooks/skill-load-check.sh" "$("${JQ[@]}" --arg p "$REPO/src/lib.rs" \
  '{hook_event_name:"PreToolUse", session_id:"cross", timestamp:"2026-09-28T00:00:00Z", cwd:"/w", tool_name:"Edit", tool_input:{path:$p}}')"
assert_eq "rc=$rc first=$(first_line)" "rc=0 first=skill-load-check: harness=copilot" \
  "and so does the snake_case one Copilot sends a .claude/settings.json hook"
# A global Copilot install sits under COPILOT_HOME, spelled however the
# operator likes, and is known by its registry document beside the script.
mkdir -p "$TMP_ROOT/anyhome/hooks"
cp "$HOOK" "$TMP_ROOT/anyhome/hooks/skill-load-check.sh"
cp "$CARRIER" "$TMP_ROOT/anyhome/hooks/skill-load-record.sh"
run_at "$TMP_ROOT/anyhome/hooks/skill-load-check.sh" "$(edit_of global)"
assert_eq "rc=$rc first=$(first_line)" "rc=0 first=skill-load-check: harness=copilot" \
  "a copy with no registry document beside it is no Copilot install"
: >"$TMP_ROOT/anyhome/hooks/skill-load-check.json"
run_at "$TMP_ROOT/anyhome/hooks/skill-load-check.sh" "$(edit_of global)"
assert_eq "rc=$rc first=$(first_line) decision=$(jq -r '.permissionDecision' <"$OUT_FILE")" \
  "rc=2 first=skill-load-check: unloaded=code-quality decision=deny" \
  "the same copy with its registry document beside it judges the call"

echo "a judge with no carrier refuses what needs a skill; a carrier with no judge is reported"
mkdir -p "$TMP_ROOT/lone/.github/hooks"
cp "$HOOK" "$TMP_ROOT/lone/.github/hooks/skill-load-check.sh"
run_at "$TMP_ROOT/lone/.github/hooks/skill-load-check.sh" "$(edit_of lone)"
assert_eq "rc=$rc first=$(first_line) decision=$(jq -r '.permissionDecision' <"$OUT_FILE")" \
  "rc=2 first=skill-load-check: carrier=$TMP_ROOT/lone/.github/hooks/skill-load-record.sh decision=deny" \
  "a judge with no carrier beside it refuses a call that needs a skill, naming the carrier"
run_at "$TMP_ROOT/lone/.github/hooks/skill-load-check.sh" "$(edit_of lone "$TMP_ROOT/outside/notes.rs")"
assert_eq "rc=$rc first=$(first_line)" "rc=0 first=-" \
  "and passes one that needs none, an edit outside every work tree"
mkdir -p "$TMP_ROOT/orphan/.github/hooks"
cp "$CARRIER" "$TMP_ROOT/orphan/.github/hooks/skill-load-record.sh"
run_at "$TMP_ROOT/orphan/.github/hooks/skill-load-record.sh" \
  "$(post orphan skill '{"skill":"code-quality"}')"
assert_eq "rc=$rc first=$(first_line) context=$(jq -r '.additionalContext | split("\n")[0]' <"$OUT_FILE")" \
  "rc=0 first=skill-load-record: judge=$TMP_ROOT/orphan/.github/hooks/skill-load-check.sh context=skill-load-record: judge=$TMP_ROOT/orphan/.github/hooks/skill-load-check.sh" \
  "a carrier with no judge beside it names the judge, to the model too, and passes"

echo "each tool the matcher names is judged from its own toolArgs"
# label|tool|toolArgs JSON|expected: each on an agent that loaded nothing.
patch_of() { # HEADER-LINES -> the patch text, the file lines given
  printf '*** Begin Patch\n%s\n@@\n+x\n*** End Patch\n' "$1"
}
N=0
while IFS='|' read -r label tool args want; do
  [ -n "$label" ] || continue
  N=$((N + 1))
  args=${args//@REPO@/$REPO}
  run_at "$JUDGE" "$(pre "tool-$N" "$tool" "$args")"
  assert_eq "rc=$rc first=$(first_line)" "$want" "$label"
done <<ROWS
a powershell call naming linear.sh is judged as a command|powershell|$("${JQ[@]}" --arg c "$LINEAR_CALL" '{command:$c}')|rc=2 first=skill-load-check: unloaded=linear
a str_replace_editor call is judged by its path|str_replace_editor|{"command":"str_replace","path":"@REPO@/src/lib.rs","old_str":"a","new_str":"b"}|rc=2 first=skill-load-check: unloaded=code-quality
an apply_patch whose toolArgs are the patch itself is judged by its Update File line|apply_patch|$(patch_of "*** Update File: @REPO@/src/lib.rs" | jq -R -s -c .)|rc=2 first=skill-load-check: unloaded=code-quality
an apply_patch carrying the patch as input is judged by its Add File line|apply_patch|$(patch_of "*** Add File: @REPO@/docs/new.md" | jq -R -s -c '{input:.}')|rc=2 first=skill-load-check: unloaded=docs-writing
an apply_patch carrying the patch as one JSON string is judged by its Delete File line|apply_patch|$(patch_of "*** Delete File: @REPO@/src/old.rs" | jq -R -s -c '{patch:.} | tojson')|rc=2 first=skill-load-check: unloaded=code-quality
a patch moving scratch into the tree is judged by its Move to line|apply_patch|$(patch_of "*** Update File: @REPO@/tmp/a.rs
*** Move to: @REPO@/src/a.rs" | jq -R -s -c .)|rc=2 first=skill-load-check: unloaded=code-quality
a patch is judged by every file, not its last|apply_patch|$(patch_of "*** Update File: @REPO@/src/lib.rs
*** Add File: @REPO@/tmp/s.rs" | jq -R -s -c .)|rc=2 first=skill-load-check: unloaded=code-quality
a file outside every work tree clears no other file|apply_patch|$(patch_of "*** Add File: $TMP_ROOT/outside/n.rs
*** Update File: @REPO@/src/lib.rs" | jq -R -s -c .)|rc=2 first=skill-load-check: unloaded=code-quality
a patch given as the toolArgs string is read as written, its last line a path too|apply_patch|$(printf '*** Begin Patch\n*** Update File: @REPO@/docs/guide.md' | jq -R -s -c .)|rc=2 first=skill-load-check: unloaded=docs-writing
a patch touching only the tree's tmp/ needs no skill|apply_patch|$(patch_of "*** Add File: @REPO@/tmp/scratch.rs" | jq -R -s -c .)|rc=0 first=-
a patch naming no file is refused, its target unknown|apply_patch|$(patch_of "no header" | jq -R -s -c .)|rc=2 first=skill-load-check: payload=no-file-path
an apply_patch whose toolArgs hold no patch is refused the same|apply_patch|{"input":7}|rc=2 first=skill-load-check: payload=no-file-path
ROWS
[ "$N" -eq 12 ] || { echo "tool rows asserted: $N" >&2; exit 2; }

echo "an identity or a record it cannot read refuses"
# label|session JSON value
while IFS='|' read -r label session; do
  [ -n "$label" ] || continue
  payload=$(edit_of placeholder | jq -c --argjson s "$session" '.sessionId = $s')
  run_at "$JUDGE" "$payload"
  assert_eq "rc=$rc first=$(first_line)" "rc=2 first=skill-load-check: payload=invalid-session-id" \
    "a check whose sessionId is $label refuses"
  run_at "$REPO/.github/hooks/skill-load-record.sh" \
    "$(post placeholder skill '{"skill":"code-quality"}' | jq -c --argjson s "$session" '.sessionId = $s')"
  assert_eq "rc=$rc first=$(first_line) context=$(jq -r '.additionalContext | split("\n")[0]' <"$OUT_FILE")" \
    "rc=0 first=skill-load-check: payload=invalid-session-id context=skill-load-check: payload=invalid-session-id" \
    "a load whose sessionId is $label records nothing and tells the model"
done <<'ROWS'
a path|"../lead"
empty|""
a number|7
absent|null
ROWS
run_at "$REPO/.github/hooks/skill-load-record.sh" "$(post lead skill '{"skill":"../../etc"}')"
assert_eq "rc=$rc first=$(first_line)" "rc=0 first=skill-load-check: payload=invalid-skill" \
  "a load naming no skill in the rule alphabet records nothing, and names that"
mkdir -p "$RECORDS/dir-session"
run_at "$JUDGE" "$(edit_of dir-session)"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=skill-load-check: state=unreadable" \
  "a record that is not a file refuses"
run_at "$JUDGE" "$(edit_of lead)" -HOME -XDG_STATE_HOME
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=skill-load-check: state=unlocatable" \
  "with neither XDG_STATE_HOME nor HOME the record cannot be found, and the call refuses"
run_at "$JUDGE" "$(edit_of lead)" XDG_STATE_HOME=relative/state -HOME
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=skill-load-check: state=unlocatable" \
  "a relative XDG_STATE_HOME with no HOME names no record either"
: >"$TMP_ROOT/blocked"
load lead code-quality XDG_STATE_HOME="$TMP_ROOT/blocked"
assert_eq "rc=$rc first=$(first_line) cause=$(cause_below) context=$(jq -r '.additionalContext | split("\n")[0]' <"$OUT_FILE")" \
  "rc=0 first=skill-load-check: state=unwritable cause=present context=skill-load-check: state=unwritable" \
  "a record that cannot be written is reported to the model with the cause, and the tool is not refused"

echo "without the tools a record run needs"
tools_row() { # TOOL
  local tool="$1" bin="$TMP_ROOT/without-$1" other real
  mkdir -p "$bin"
  for other in jq cat mkdir find; do
    [ "$other" != "$tool" ] || continue
    real="$(type -P "$other")" || { echo "tools: $other is not on PATH" >&2; exit 2; }
    ln -sf "$real" "$bin/$other"
  done
  set +e
  env -i PATH="$bin" HOME="$TMP_ROOT" XDG_STATE_HOME="$STATE_HOME" "$BASH_BIN" \
    "$REPO/.github/hooks/skill-load-record.sh" >"$OUT_FILE" 2>"$ERR_FILE" \
    <<<"$(post tools skill '{"skill":"code-quality"}')"
  rc=$?
  set -e
  assert_eq "rc=$rc first=$(first_line)" "rc=0 first=skill-load-check: missing-tools=$tool" \
    "a record run without $tool records nothing, and the value names it"
}
for tool in jq cat mkdir find; do tools_row "$tool"; done

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
