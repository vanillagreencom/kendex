#!/usr/bin/env bash
# Tests for the skill-load-check hook.
#
# The hook refuses a call a rule ties to a skill until the transcript of the
# agent making the call shows a Skill tool call whose skill input names that
# skill: a markdown edit inside a git work tree needs `docs-writing` and any
# other edit there `code-quality`, a linear.sh call the shell would run
# `linear`, and a repository appends rules of its own. Pinned here: the refusal and its value,
# the pass once the skill is loaded, and what the rule deliberately does not
# reach — the work tree's own tmp/, a path outside every work tree, and a
# session that turned the hook off. Pinned beside them, the precision the
# transcript read exists for: the skill's name in a system message, in a tool
# result or in a Skill call for another skill is not a load. A subagent's call
# is judged by its own transcript under the session's subagents/ directory,
# never by the session's load. Then the
# fail-closed edges — an unreadable payload, a missing target or transcript
# field, a transcript that is not there, a git that cannot answer, no jq.
#
# Fixtures are throwaway git repositories and hand-written transcripts under a
# HOME of their own.
#
# Every refusal opens with `skill-load-check: <key>=<value>`, and that
# line is the contract: the skill that is not loaded, or why the state could
# not be read, is the value. The path refused and the skill to load are
# pinned as themselves under it, and git's own words when it could not answer.
#
# HOOK_UNDER_TEST overrides the script under test for these assertions.
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which take precedence over `git -C` and
# would point the fixtures' git at the real repository.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/skill-load-check.sh}"
CARRIER="${CARRIER_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/skill-load-record.sh}"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)" || { echo "skill-load-check: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "skill-load-check: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "skill-load-check: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
BASH_BIN="$(command -v bash)"
ERR_FILE="$TMP_ROOT/stderr"
OUT_FILE="$TMP_ROOT/stdout"

fgit() {
  env HOME="$TMP_ROOT" git "$@"
}

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/src" "$REPO/tmp" "$REPO/crates/core/tmp"
fgit init -q "$REPO"
fgit -C "$REPO" config user.email t@example.com
fgit -C "$REPO" config user.name t
printf 'pub fn a() {}\n' >"$REPO/src/lib.rs"
fgit -C "$REPO" add -A
fgit -C "$REPO" commit -q -m init
SCRATCH="$TMP_ROOT/scratch"
mkdir -p "$SCRATCH"

# jq builds every fixture and payload below, so a value holding a quote, a
# backslash or a newline reaches the hook encoded the way the harness encodes
# it. Long flag names: this repository's pre-commit hook reads whitespace-
# separated words, and the short pair spells one it refuses.
JQ=(jq --null-input --compact-output)

# A transcript line: the assistant tool_use the harness records for a Skill
# call, built the way the harness builds it so a field this hook reads is
# never spelled by hand twice.
skill_call() { # SKILL -> one JSONL line
  "${JQ[@]}" --arg s "$1" \
    '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",name:"Skill",input:{skill:$s}}]}}'
}

# The transcripts the rows below name. NONE holds the skill's name everywhere
# but in a Skill call: the system message that lists the installed skills, a
# tool result that printed it, and a Skill call for a different skill.
LOADED_T="$TMP_ROOT/loaded.jsonl"
NONE_T="$TMP_ROOT/none.jsonl"
skill_call code-quality >"$LOADED_T"
{
  "${JQ[@]}" '{type:"system",content:"- code-quality: Load for any coding or development task"}'
  "${JQ[@]}" '{type:"user",message:{role:"user",content:[{type:"tool_result",content:"skills/code-quality/SKILL.md"}]}}'
  skill_call dev
} >"$NONE_T"

# run_tool TOOL FIELD VALUE TRANSCRIPT -> rc, stderr in $err
run_tool() {
  local tool="$1" field="$2" value="$3" transcript="$4"
  run_payload "$("${JQ[@]}" --arg t "$tool" --arg f "$field" --arg v "$value" --arg tr "$transcript" \
    '{tool_name: $t, tool_input: {($f): $v}, transcript_path: $tr}')"
}

# The rules a row appends to the default table, empty for the defaults alone,
# and the copy of the hook a row runs in place of HOOK, empty for HOOK itself.
RULES_UNDER_TEST=""
HOOK_AT=""
HOME_AT=""

# The payload reaches the hook on a here-string, never a pipe: a hook that
# exits before reading stdin — the off switch here, a no-op mutant under
# HOOK_UNDER_TEST — SIGPIPEs a writer on the other end, and the pipeline's
# 141 would stand where the hook's own status belongs.
run_payload() { # raw-json [PATH] -> rc, stderr in $err
  set +e
  if [ -n "${2:-}" ]; then
    env -i HOME="$TMP_ROOT" PWD="$TMP_ROOT" PATH="$2" ${RULES_UNDER_TEST:+"KENDEX_SKILL_LOAD_RULES=$RULES_UNDER_TEST"} \
      "$BASH_BIN" "$HOOK" >"$OUT_FILE" 2>"$ERR_FILE" <<<"$1"
  else
    env -i PATH="$PATH" HOME="${HOME_AT:-$TMP_ROOT}" \
      ${RULES_UNDER_TEST:+"KENDEX_SKILL_LOAD_RULES=$RULES_UNDER_TEST"} "$BASH_BIN" "${HOOK_AT:-$HOOK}" \
      >"$OUT_FILE" 2>"$ERR_FILE" <<<"$1"
  fi
  rc=$?
  set -e
  err="$(cat "$ERR_FILE")"
}

# shellcheck source=lib/assert.sh
. "$TEST_DIR/lib/assert.sh"

assert_contains() {
  local got="$1" needle="$2" name="$3"
  if [[ "$got" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected to contain: %s\n        got:      %s\n' "$name" "$needle" "$got"
  fi
}

# The first-line reader. This suite's runs vary the tool, the path and the
# transcript rather than one command, which the shared table's modes do not
# express, so `first_line` and `cause_below` are the half of that library it
# uses.
# shellcheck source=lib/first-line.sh
. "$TEST_DIR/lib/first-line.sh"

REFUSAL="skill-load-check: unloaded=code-quality"

echo "skill-load-check: an edit in a repository is refused until the skill is loaded"
# One row per edit tool, each with the field that tool's payload carries. The
# transcript holds every mention of the skill that is not a load, so a row
# that passed here would be a read matching the name rather than the call.
while IFS='|' read -r tool field; do
  [ -n "$tool" ] || continue
  run_tool "$tool" "$field" "$REPO/src/lib.rs" "$NONE_T"
  assert_eq "rc=$rc first=$(first_line)" "rc=2 first=$REFUSAL" \
    "$tool is refused, the skill that is not loaded its value"
done <<'ROWS'
Edit|file_path
MultiEdit|file_path
Write|file_path
NotebookEdit|notebook_path
ROWS
run_tool Edit file_path "$REPO/src/lib.rs" "$NONE_T"
assert_contains "$err" "$REPO/src/lib.rs" "the refusal names the path it refused"
assert_contains "$err" "skill: code-quality" "the refusal names the load that would pass it"
run_tool Write file_path "$REPO/new/dir/probe.sh" "$NONE_T"
assert_eq "$rc" 2 "a new file under directories that do not exist yet is judged by the nearest existing ancestor"
run_tool Write file_path "$REPO/crates/core/tmp/notes.md" "$NONE_T"
assert_eq "$rc" 2 "a tmp/ that is not the work tree's own is not scratch"
# Which tools reach this hook is the frontmatter matcher's answer, rendered
# into the harness's registration; the script does not restate that list, so
# every call delivered to it is judged by its path alone.
run_tool Read file_path "$REPO/src/lib.rs" "$NONE_T"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=$REFUSAL" \
  "a call is judged by its path, whatever tool the matcher delivered"

echo "skill-load-check: the load passes it"
run_tool Edit file_path "$REPO/src/lib.rs" "$LOADED_T"
assert_eq "rc=$rc first=$(first_line)" "rc=0 first=-" "a Skill call for code-quality passes the edit, silently"
MIXED_T="$TMP_ROOT/mixed.jsonl"
cat "$NONE_T" "$LOADED_T" >"$MIXED_T"
run_tool Edit file_path "$REPO/src/lib.rs" "$MIXED_T"
assert_eq "$rc" 0 "the load is found among the mentions that are not loads"
# The harness writes the transcript as the session runs, so the last line can
# be half-written when the hook reads it. That line is skipped; the load above
# it still answers.
printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_' >>"$MIXED_T"
run_tool Edit file_path "$REPO/src/lib.rs" "$MIXED_T"
assert_eq "$rc" 0 "a half-written last line is skipped rather than taken for the whole file"
TRUNCATED_T="$TMP_ROOT/truncated.jsonl"
cat "$NONE_T" >"$TRUNCATED_T"
printf '%s' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"code-qual' >>"$TRUNCATED_T"
run_tool Edit file_path "$REPO/src/lib.rs" "$TRUNCATED_T"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=$REFUSAL" \
  "a half-written Skill call is not a load"
# Pi records a skill load in its session file as a toolCall of its `read`
# tool on the skill's SKILL.md, the path absolute or relative, and the read's
# outcome as a later toolResult under the same toolCallId, isError true when
# it failed. A row's result is `ok`, `error` or `none` (never written); the
# result's text never names the skill, as a real file body need not. A
# `batch-ok` or `batch-error` row is the read inside a tool_batch call beside
# a failed sibling read, so the batch's own isError is true either way and the
# read's status in the batch result's `nestedCalls` record is the outcome.
# Every batch result carries the `kendexOutputPolicySanitized` mark
# pi-output-policy's default mode leaves on a batch whose read item is over its
# details string cap, as a skill file is. The rows that must refuse an ok read:
# `batch-truncated`, whose `details.items` entry is `truncated` true, as
# tool_batch's cap sets it; `batch-policy-cut`, whose entry is whole but whose
# `details` carry the `kendexOutputPolicy` entry pi-output-policy writes when
# it cuts the batch text; `batch-no-item`, with no entry for the read, as
# pi-output-policy's details cap leaves the items past its budget;
# `batch-grep`, an ok grep of the path in place of the read, its sibling a
# failed read of the same path; and four whose sibling names the read's own
# path, since entries join the read by path alone: `batch-beside-failed` and
# `batch-beside-grep`, a whole read beside a failed read or a whole grep, and
# `batch-cut-beside-failed` and `batch-cut-beside-grep`, the same with the read
# cut. A cut-beside row fails two clauses, so no one-clause control reddens it;
# the batch-join control, which lets each clause pass on any entry of the path,
# does. Pi's nested status and name are those of the call and outcome tool_batch
# writes an entry's isError and toolName from, so every row the nested clauses
# refuse an entry clause refuses too, and no row isolates them.
PI_T="$TMP_ROOT/pi-session.jsonl"
pi_read_row() { # WANT PATH RESULT [TARGET]
  local want="$1" path="$2" result="$3" target="${4:-src/lib.rs}" tool status cut item policy sibling
  {
    case "$result" in
      ok | error | none)
        "${JQ[@]}" --arg p "$path" \
          '{type:"message",message:{role:"assistant",content:[{type:"toolCall",id:"call-1",name:"read",arguments:{path:$p}}]}}'
        ;;
    esac
    case "$result" in
      ok | error)
        "${JQ[@]}" --argjson e "$([ "$result" = error ] && echo true || echo false)" \
          '{type:"message",message:{role:"toolResult",toolCallId:"call-1",toolName:"read",isError:$e,content:[{type:"text",text:"file body"}]}}'
        ;;
      none) ;;
      batch-*)
        tool=read status=ok cut=false item=true policy=false sibling=missing.md sibling_tool=read sibling_status=error
        case "$result" in
          batch-ok) ;;
          batch-error) status=error ;;
          batch-truncated) cut=true ;;
          batch-policy-cut) policy=true ;;
          batch-no-item) item=false ;;
          batch-grep) tool=grep sibling="$path" ;;
          batch-beside-failed) sibling="$path" ;;
          batch-beside-grep) sibling="$path" sibling_tool=grep sibling_status=ok ;;
          batch-cut-beside-failed) cut=true sibling="$path" ;;
          batch-cut-beside-grep) cut=true sibling="$path" sibling_tool=grep sibling_status=ok ;;
          *) printf 'an unknown result word builds no transcript: %s\n' "$result" >&2; exit 2 ;;
        esac
        "${JQ[@]}" --arg t "$tool" --arg p "$path" --arg s "$status" --arg st "$sibling_tool" \
          --arg sib "$sibling" --arg ss "$sibling_status" --argjson c "$cut" --argjson i "$item" --argjson pc "$policy" \
          'def call($t; $p; $s; $c): {tool:$t,args:((if $t == "grep" then {pattern:"Tests"} else {} end) + {path:$p}),status:$s,truncated:$c};
          [call($t; $p; $s; $c), call($st; $sib; $ss; false)] as $calls
          | ([$calls[] | select(.status == "error")] | length) as $failed
          | {type:"message",message:{role:"assistant",content:[{type:"toolCall",id:"call-1",name:"tool_batch",arguments:{calls:[$calls[] | {tool,args}]}}]}},
            ({failed:$failed,succeeded:(2 - $failed),total:2,
              items:[$calls | to_entries[] | select(.key > 0 or $i)
                | {args:.value.args,index:.key,isError:(.value.status == "error"),
                    resultText:(if .value.status == "error" then "ENOENT" else "file body" end),toolName:.value.tool,truncated:.value.truncated}],
              kendexOutputPolicySanitized:{policyMode:"balanced",reason:"details payload exceeded inline budget"}}
            + (if $pc then {kendexOutputPolicy:[{reason:"max-text-block",shownRange:"lines 1-197",truncated:true}]} else {} end)
            | {type:"message",message:{role:"toolResult",toolCallId:"call-1",toolName:"tool_batch",isError:($failed > 0),
                content:[{type:"text",text:"batch_succeeded=\(2 - $failed) batch_total=2"}],details:.,
                nestedCalls:{calls:[$calls | to_entries[] | {id:"call-1/\(.key + 1)",name:.value.tool,arguments:.value.args,status:.value.status}
                  + (if .value.status == "error" then {error:"ENOENT"} else {} end)],complete:true}}})'
        ;;
      *) printf 'an unknown result word builds no transcript: %s\n' "$result" >&2; exit 2 ;;
    esac
  } >"$PI_T"
  run_tool Write file_path "$REPO/${target:-src/lib.rs}" "$PI_T"
  assert_eq "rc=$rc first=$(first_line)" "$want" "a Pi read of $path, result $result"
}
pi_markdown_row() {
  pi_read_row 'rc=2 first=skill-load-check: unloaded=docs-writing' \
    .agents/skills/docs-writing/SKILL.md none README.md
}
pi_markdown_row
while IFS='|' read -r want path result target; do
  [ -n "$want" ] || continue
  pi_read_row "$want" "$path" "$result" "$target"
done <<ROWS
rc=0 first=-|/home/u/.pi/agent/skills/code-quality/SKILL.md|ok
rc=0 first=-|code-quality/SKILL.md|ok
rc=2 first=$REFUSAL|/home/u/.pi/agent/skills/code-quality/SKILL.md|error
rc=2 first=$REFUSAL|/home/u/.pi/agent/skills/code-quality/SKILL.md|none
rc=2 first=$REFUSAL|.agents/skills/not-code-quality/SKILL.md|ok
rc=2 first=$REFUSAL|.agents/skills/code-quality/references/rules.md|ok
rc=0 first=-|.agents/skills/docs-writing/SKILL.md|ok|README.md
ROWS
pi_batch_rows() {
  pi_read_row 'rc=0 first=-' .agents/skills/code-quality/SKILL.md batch-ok
  pi_read_row "rc=2 first=$REFUSAL" .agents/skills/code-quality/SKILL.md batch-error
  pi_read_row "rc=2 first=$REFUSAL" .agents/skills/code-quality/SKILL.md batch-truncated
  pi_read_row "rc=2 first=$REFUSAL" .agents/skills/code-quality/SKILL.md batch-policy-cut
  pi_read_row "rc=2 first=$REFUSAL" .agents/skills/code-quality/SKILL.md batch-no-item
  pi_read_row "rc=2 first=$REFUSAL" .agents/skills/code-quality/SKILL.md batch-grep
  pi_read_row "rc=2 first=$REFUSAL" .agents/skills/code-quality/SKILL.md batch-beside-failed
  pi_read_row "rc=2 first=$REFUSAL" .agents/skills/code-quality/SKILL.md batch-beside-grep
  pi_read_row "rc=2 first=$REFUSAL" .agents/skills/code-quality/SKILL.md batch-cut-beside-failed
  pi_read_row "rc=2 first=$REFUSAL" .agents/skills/code-quality/SKILL.md batch-cut-beside-grep
  pi_read_row "rc=2 first=$REFUSAL" README.md batch-ok
}
pi_batch_rows

echo "skill-load-check: each default rule refuses until its skill is loaded"
# A transcript holding every mention of a skill that is not a load, then one
# Skill call per skill named.
loads() { # FILE SKILL...
  local file="$1"
  shift
  cp "$NONE_T" "$file"
  for skill in "$@"; do
    skill_call "$skill" >>"$file"
  done
}
DOCS_T="$TMP_ROOT/docs.jsonl"
LINEAR_T="$TMP_ROOT/linear.jsonl"
CQ_ICED_T="$TMP_ROOT/cq-iced.jsonl"
loads "$DOCS_T" docs-writing
loads "$LINEAR_T" linear
loads "$CQ_ICED_T" code-quality iced-rs
run_bash() { # COMMAND TRANSCRIPT -> rc, stderr in $err
  run_payload "$("${JQ[@]}" --arg c "$1" --arg tr "$2" '{tool_name:"Bash",tool_input:{command:$c},transcript_path:$tr}')"
}
# label|mode|subject|transcript|rules|rc and first line. An edit's subject is a
# path under the fixture repository, a command's the command; rules `-` is the
# default table alone. A field holds no `|`.
rule_table() { # ROWS
  local label mode subject transcript rules want before=$((PASS + FAIL))
  while IFS='|' read -r label mode subject transcript rules want; do
    [ -n "$label" ] || continue
    [ "$rules" != - ] || rules=""
    RULES_UNDER_TEST=$rules
    case "$mode" in
      edit) run_tool Edit file_path "$REPO/$subject" "$transcript" ;;
      bash) run_bash "$subject" "$transcript" ;;
      *) echo "rule_table: no mode named $mode" >&2; exit 2 ;;
    esac
    RULES_UNDER_TEST=""
    assert_eq "rc=$rc first=$(first_line)" "$want" "$label"
  done <<<"$1"
  [ "$((PASS + FAIL))" -gt "$before" ] || { echo "rule_table: no row was asserted" >&2; exit 2; }
}
LINEAR_CALL='.agents/skills/linear/scripts/linear.sh issues list --state Todo'
markdown_row() {
  rule_table "a markdown edit without docs-writing refuses, naming it|edit|docs/guide.md|$LOADED_T|-|rc=2 first=skill-load-check: unloaded=docs-writing"
}
markdown_rows() {
  markdown_row
  pi_markdown_row
}
markdown_row
rule_table "\
a markdown edit with docs-writing loaded and code-quality not passes|edit|docs/guide.md|$DOCS_T|-|rc=0 first=-
a source edit with docs-writing loaded and code-quality not refuses, naming code-quality|edit|src/lib.rs|$DOCS_T|-|rc=2 first=skill-load-check: unloaded=code-quality
a linear.sh read without linear refuses, naming it|bash|$LINEAR_CALL|$NONE_T|-|rc=2 first=skill-load-check: unloaded=linear
the same call inside a quoted string is no command|bash|echo \"run $LINEAR_CALL\"|$NONE_T|-|rc=0 first=-
a closing parenthesis inside an earlier quoted string opens no command position for the next|bash|echo \"pass (CI).\" \"run $LINEAR_CALL\"|$NONE_T|-|rc=0 first=-
an unquoted separator after a quoted string still starts a command|bash|echo \"pass (CI).\" ; $LINEAR_CALL|$NONE_T|-|rc=2 first=skill-load-check: unloaded=linear
linear.sh as another command's argument is judged as the command it may be|bash|echo /tmp/linear.sh|$NONE_T|-|rc=2 first=skill-load-check: unloaded=linear
reading the script is judged as the command it may be|bash|cat .agents/skills/linear/scripts/linear.sh|$NONE_T|-|rc=2 first=skill-load-check: unloaded=linear
linear.sh behind a launcher word without linear refuses, naming it|bash|env $LINEAR_CALL|$NONE_T|-|rc=2 first=skill-load-check: unloaded=linear
linear.sh run by a shell word without linear refuses, naming it|bash|bash $LINEAR_CALL|$NONE_T|-|rc=2 first=skill-load-check: unloaded=linear
linear.sh behind a shell option and its value without linear refuses|bash|bash -o posix $LINEAR_CALL|$NONE_T|-|rc=2 first=skill-load-check: unloaded=linear
linear.sh behind a shell's shopt option and its value without linear refuses|bash|bash -O extglob $LINEAR_CALL|$NONE_T|-|rc=2 first=skill-load-check: unloaded=linear
linear.sh after an assignment without linear refuses, naming it|bash|LINEAR_TEAM=KEN $LINEAR_CALL|$NONE_T|-|rc=2 first=skill-load-check: unloaded=linear
a command no rule names passes before any transcript is read|bash|ls -la|$TMP_ROOT/no-such-transcript|-|rc=0 first=-
a rule the repository appends refuses until its skill is loaded|edit|crates/ui/src/view.rs|$LOADED_T|crates/ui/**/*.rs=iced-rs|rc=2 first=skill-load-check: unloaded=iced-rs
and passes once it is|edit|crates/ui/src/view.rs|$CQ_ICED_T|crates/ui/**/*.rs=iced-rs|rc=0 first=-
a command rule the repository appends refuses until its skill is loaded|bash|tools/deploy --prod|$NONE_T|bash:[[:space:]/]deploy[[:space:]]=release|rc=2 first=skill-load-check: unloaded=release
"

# One edit's load answers every later edit: the hook reads what was loaded,
# never what it passed before.
run_tool Edit file_path "$REPO/src/lib.rs" "$LOADED_T"
FIRST_RC=$rc
run_tool Write file_path "$REPO/src/other.rs" "$LOADED_T"
assert_eq "first=$FIRST_RC second=$rc" "first=0 second=0" \
  "a second edit after one load passes, with no second load recorded"
run_bash "$LINEAR_CALL" "$LINEAR_T"
FIRST_RC=$rc
run_bash '.agents/skills/linear/scripts/linear.sh issues add-relation KEN-1 --blocks KEN-2' "$LINEAR_T"
assert_eq "first=$FIRST_RC second=$rc" "first=0 second=0" \
  "a second linear.sh call after one load passes, with no second load recorded"

echo "skill-load-check: a rule it cannot read refuses every call"
while IFS='|' read -r label entry; do
  [ -n "$label" ] || continue
  RULES_UNDER_TEST=$entry
  run_tool Edit file_path "$REPO/src/lib.rs" "$LOADED_T"
  RULES_UNDER_TEST=""
  assert_eq "rc=$rc first=$(first_line)" "rc=2 first=skill-load-check: malformed-rule=$entry" "$label"
done <<'ROWS'
an entry with no = refuses|crates/ui/**/*.rs
an entry whose skill is not a name refuses|crates/ui/**/*.rs=iced rs
an entry whose regex does not compile refuses|bash:(deploy=release
ROWS

echo "skill-load-check: a command it cannot read refuses"
run_payload "$("${JQ[@]}" --arg tr "$NONE_T" '{tool_name:"Bash",tool_input:{},transcript_path:$tr}')"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=skill-load-check: payload=no-command" \
  "a Bash payload naming no command refuses, and names that"
# The hook alone, with no commit-guards install within reach of it.
missing_library_row() {
  local HOOK_AT="$TMP_ROOT/lone/hooks/skill-load-check.sh" tool
mkdir -p "$TMP_ROOT/lone/hooks"
cp "$HOOK" "$HOOK_AT"
run_bash "$LINEAR_CALL" "$LINEAR_T"
assert_eq "rc=$rc first=$(first_line)" \
  "rc=0 first=skill-load-check: missing-library=commit-guards/scripts/lib/command-position.sh" \
  "without the command library a Bash call passes with the library gap first"
assert_eq "$(jq -r '.hookSpecificOutput.hookEventName' <"$OUT_FILE")" PreToolUse \
  "the library gap uses the pre-tool context event"
assert_eq "$(jq -r '.hookSpecificOutput.additionalContext' <"$OUT_FILE")" "$err" \
  "the library gap and repair reach the model as the same keyed message"
while IFS= read -r tool; do
  run_tool "$tool" file_path "$REPO/src/lib.rs" "$NONE_T"
  assert_eq "rc=$rc first=$(first_line)" "rc=2 first=$REFUSAL" \
    "$tool still refuses an unloaded skill without the command library"
done <<'ROWS'
Edit
Write
ROWS
}
missing_library_row
# A global Pi install sits four directories under the home, and a harness root
# a setting relocated sits outside it; both find the library in the home's
# shared tree.
mkdir -p "$TMP_ROOT/home/.agents/skills/commit-guards/scripts/lib" \
  "$TMP_ROOT/home/.pi/agent/kendex/hooks" "$TMP_ROOT/relocated/codex/hooks"
cp "$(cd "$TEST_DIR/../.." && pwd)/skills/commit-guards/scripts/lib/command-position.sh" \
  "$TMP_ROOT/home/.agents/skills/commit-guards/scripts/lib/command-position.sh"
while IFS='|' read -r label at; do
  [ -n "$label" ] || continue
  cp "$HOOK" "$TMP_ROOT/$at/skill-load-check.sh"
  HOOK_AT="$TMP_ROOT/$at/skill-load-check.sh"
  HOME_AT="$TMP_ROOT/home"
  run_bash "$LINEAR_CALL" "$LINEAR_T"
  HOOK_AT=""
  HOME_AT=""
  assert_eq "rc=$rc first=$(first_line)" "rc=0 first=-" "$label"
done <<'ROWS'
a global Pi install four directories under the home finds the library in the home's shared tree|home/.pi/agent/kendex/hooks
a harness root relocated out of the home finds the library in the home's shared tree|relocated/codex/hooks
ROWS

echo "skill-load-check: a subagent's call is judged by its own transcript"
# The harness names the session's transcript in transcript_path whichever
# agent made the call, and adds agent_id only for a subagent, whose tool calls
# it records in `<session>/subagents/agent-<agent_id>.jsonl`. Each world is a
# session transcript and one subagent's beside it, with the load in only one.
SUBAGENT_ID=adev-generalist-5f867e9826a04a12
subagent_world() { # NAME SESSION-FIXTURE SUBAGENT-FIXTURE
  mkdir -p "$TMP_ROOT/$1/subagents"
  cp "$2" "$TMP_ROOT/$1.jsonl"
  cp "$3" "$TMP_ROOT/$1/subagents/agent-$SUBAGENT_ID.jsonl"
}
run_subagent() { # SESSION-TRANSCRIPT AGENT-ID -> rc, stderr in $err
  run_payload "$("${JQ[@]}" --arg p "$REPO/src/lib.rs" --arg tr "$1" --arg a "$2" \
    '{tool_name:"Edit",tool_input:{file_path:$p},transcript_path:$tr,agent_id:$a}')"
}
subagent_world session-unloaded "$NONE_T" "$LOADED_T"
subagent_world session-loaded "$LOADED_T" "$NONE_T"
run_subagent "$TMP_ROOT/session-unloaded.jsonl" "$SUBAGENT_ID"
assert_eq "rc=$rc first=$(first_line)" "rc=0 first=-" \
  "a subagent that loaded the skill passes, though the session did not"
# The harness may also write a subagent's transcript one directory below
# subagents/.
mkdir -p "$TMP_ROOT/session-nested/subagents/workers"
cp "$NONE_T" "$TMP_ROOT/session-nested.jsonl"
cp "$LOADED_T" "$TMP_ROOT/session-nested/subagents/workers/agent-$SUBAGENT_ID.jsonl"
run_subagent "$TMP_ROOT/session-nested.jsonl" "$SUBAGENT_ID"
assert_eq "rc=$rc first=$(first_line)" "rc=0 first=-" \
  "a subagent transcript one directory below subagents/ is found, and its load passes"
run_subagent "$TMP_ROOT/session-loaded.jsonl" "$SUBAGENT_ID"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=$REFUSAL" \
  "a subagent that did not load the skill is refused, though the session did"
run_subagent "$TMP_ROOT/session-loaded.jsonl" a7ce49cf892d6e2f5
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=skill-load-check: transcript=unreadable" \
  "an agent_id with no transcript of its own refuses, though the session loaded the skill"
# A NUL is dropped when the shell reads the id, and what remains here is the
# loaded subagent's own id: the id is judged before it names a file.
run_payload "$("${JQ[@]}" --arg p "$REPO/src/lib.rs" --arg tr "$TMP_ROOT/session-unloaded.jsonl" --arg a "$SUBAGENT_ID" \
  '{tool_name:"Edit",tool_input:{file_path:$p},transcript_path:$tr,agent_id:($a[:8] + ([0] | implode) + $a[8:])}')"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=skill-load-check: payload=invalid-agent-id" \
  "an agent_id holding a NUL refuses, though the id without it names a subagent that loaded the skill"

echo "skill-load-check: what the rule does not reach"
run_tool Write file_path "$REPO/tmp/commit-msg.txt" "$NONE_T"
assert_eq "rc=$rc first=$(first_line)" "rc=0 first=-" "the work tree's own tmp/ is scratch and passes"
run_tool Write file_path "$REPO/tmp/deeper/status.md" "$TMP_ROOT/no-such-transcript"
assert_eq "$rc" 0 "tmp/ passes before the transcript is read at all"
run_tool Write file_path "$SCRATCH/probe.sh" "$NONE_T"
assert_eq "$rc" 0 "a path outside every work tree passes"
run_tool Write file_path "$SCRATCH/deeper/not/yet/probe.sh" "$NONE_T"
assert_eq "$rc" 0 "a path outside every work tree, under directories that do not exist yet, passes"
set +e
env -i HOME="$TMP_ROOT" PATH="" KENDEX_SKILL_LOAD_HOOK=off "$BASH_BIN" "$HOOK" \
  >/dev/null 2>"$ERR_FILE" <<<"$("${JQ[@]}" --arg p "$REPO/src/lib.rs" --arg tr "$NONE_T" \
    '{tool_name:"Edit",tool_input:{file_path:$p},transcript_path:$tr}')"
rc=$?
set -e
assert_eq "rc=$rc first=$(first_line)" "rc=0 first=-" \
  "the off switch passes before the tools it would need are looked for"

echo "skill-load-check: a state it cannot read refuses"
run_payload '{"tool_name":"Edit","tool_input":{"file_path":"x"}'
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=skill-load-check: payload=invalid-json" \
  "a truncated JSON payload refuses rather than skipping the guard"
run_payload '["Edit"]'
assert_eq "$rc" 2 "a payload that is not an object refuses"
run_payload "$("${JQ[@]}" --arg tr "$NONE_T" '{tool_name:"Edit",tool_input:{content:"x"},transcript_path:$tr}')"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=skill-load-check: payload=no-file-path" \
  "a payload naming no target path refuses, and names that"
run_payload "$("${JQ[@]}" --arg tr "$NONE_T" '{tool_name:"Edit",tool_input:{file_path:7},transcript_path:$tr}')"
assert_eq "$rc" 2 "a file_path that is not a string refuses"
run_payload "$("${JQ[@]}" --arg p "$REPO/src/lib.rs" '{tool_name:"Edit",tool_input:{file_path:$p}}')"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=skill-load-check: payload=no-transcript" \
  "a payload naming no transcript refuses, and names that"
run_payload "$("${JQ[@]}" --arg p "$REPO/src/lib.rs" '{tool_name:"Edit",tool_input:{file_path:$p},transcript_path:[]}')"
assert_eq "$rc" 2 "a transcript_path that is not a string refuses"
run_tool Edit file_path "$REPO/src/lib.rs" "$TMP_ROOT/no-such-transcript"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=skill-load-check: transcript=unreadable" \
  "a transcript that is not there refuses, and names it"
run_tool Edit file_path "$REPO/src/lib.rs" "$TMP_ROOT"
assert_eq "$rc" 2 "a transcript_path naming a directory refuses"

# pi-hooks/extensions/vocab.ts::claudeSessionFields omits transcript_path
# when SessionManager.getSessionFile() is undefined (--no-session). Unlike
# that omission, a present but invalid value is a malformed payload.
mkdir -p "$TMP_ROOT/.pi/kendex/hooks"
pi_session_row() { # LABEL FIELDS WANT
  local label="$1" fields="$2" want="$3" HOOK_AT="$TMP_ROOT/.pi/kendex/hooks/skill-load-check.sh"
  cp -- "$HOOK" "$HOOK_AT"
  run_payload "$("${JQ[@]}" --arg p "$REPO/README.md" --argjson f "$fields" \
    '{tool_name:"Write",tool_input:{file_path:$p},session_id:"pi-session"} + $f')"
  assert_eq "rc=$rc first=$(first_line)" "$want" "$label"
}
pi_nonpersistent_row() {
  pi_session_row 'Pi nonpersistent session' '{}' 'rc=0 first=skill-load-check: gap=nonpersistent-pi'
}
pi_nonpersistent_row
while IFS='|' read -r label fields want; do
  [ -n "$label" ] || continue
  pi_session_row "$label" "$fields" "$want"
done <<'ROWS'
Pi null transcript|{"transcript_path":null}|rc=2 first=skill-load-check: payload=no-transcript
Pi malformed transcript|{"transcript_path":[]}|rc=2 first=skill-load-check: payload=no-transcript
Pi empty transcript|{"transcript_path":""}|rc=2 first=skill-load-check: payload=no-transcript
Pi unreadable persistent transcript|{"transcript_path":"/no-such-session.jsonl"}|rc=2 first=skill-load-check: transcript=unreadable
Pi malformed nonpersistent agent|{"agent_id":[]}|rc=2 first=skill-load-check: payload=invalid-agent-id
ROWS
HOOK_AT=""

echo "skill-load-check: git cannot say where the path is"
BROKEN_BIN="$TMP_ROOT/brokengit"
mkdir -p "$BROKEN_BIN"
cat >"$BROKEN_BIN/git" <<'EOF'
#!/usr/bin/env bash
echo "fatal: unable to read the repository configuration" >&2
exit 128
EOF
chmod +x "$BROKEN_BIN/git"
set +e
env HOME="$TMP_ROOT" PATH="$BROKEN_BIN:$PATH" "$BASH_BIN" "$HOOK" \
  >/dev/null 2>"$ERR_FILE" <<<"$("${JQ[@]}" --arg p "$SCRATCH/probe.sh" --arg tr "$NONE_T" \
    '{tool_name:"Write",tool_input:{file_path:$p},transcript_path:$tr}')"
rc=$?
set -e
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=skill-load-check: git=unreadable" \
  "a git failure that is not 'not a git repository' refuses the edit"
assert_eq "$(cause_below)" present "the refusal carries git's own failure under the keyed line"
assert_contains "$(cat "$ERR_FILE")" "unable to read the repository configuration" "and it is git's words"

echo "skill-load-check: without the tools it runs"
# One world per declared dependency, each holding every other tool and not
# that one: the refusal names the missing tool and nothing is judged without
# it. A row per tool is what keeps the inventory honest — an absent grep does
# not stall this hook, it makes the transcript read empty, which is the
# unloaded answer arrived at without reading anything.
tools_table() { # TOOLS
  local tool other bin real before=$((PASS + FAIL))
  for tool in $1; do
    bin="$TMP_ROOT/without-$tool"
    rm -rf -- "$bin"
    mkdir -p "$bin"
    for other in $1; do
      [ "$other" != "$tool" ] || continue
      real="$(type -P "$other" 2>/dev/null || true)"
      [ -n "$real" ] && [ -x "$real" ] || continue
      ln -sf "$real" "$bin/$other"
    done
    run_payload '{"tool_name":"Edit","tool_input":{"file_path":"x"},"transcript_path":"y"}' "$bin"
    assert_eq "rc=$rc first=$(first_line)" "rc=2 first=skill-load-check: missing-tools=$tool" \
      "without $tool the call is refused, and the value names it"
  done
  # A world holding none of them: the value is the whole list, in check order.
  # A row per tool cannot see an accumulator that overwrites instead of
  # appending, because only one name is ever missing in one.
  bin="$TMP_ROOT/without-everything"
  rm -rf -- "$bin"
  mkdir -p "$bin"
  run_payload '{"tool_name":"Edit","tool_input":{"file_path":"x"},"transcript_path":"y"}' "$bin"
  assert_eq "rc=$rc first=$(first_line)" "rc=2 first=skill-load-check: missing-tools=${1// /,}" \
    "with none of them the value is the whole list, in check order"
  [ "$((PASS + FAIL))" -gt "$before" ] || { echo "tools: no row was asserted" >&2; exit 2; }
}
tools_table "jq git cat grep dirname"

# The current engine scopes companion requirements by harness. The released
# engines do not, so the catalog proof must run their actual planner.
RELEASE_HOME="$TMP_ROOT/release-home"
mkdir -p "$RELEASE_HOME/.local/bin"
env -i PATH="$RELEASE_HOME/.local/bin:$PATH" HOME="$RELEASE_HOME" \
  XDG_DATA_HOME="$RELEASE_HOME/data" sh "$TEST_DIR/../../install.sh" \
  --version v1.3.0 --cli-only >"$TMP_ROOT/install.log" 2>&1 || {
    cat "$TMP_ROOT/install.log" >&2
    exit 1
  }
RELEASED="$RELEASE_HOME/.local/bin/kendex"
release_version=$(env -i PATH="$PATH" HOME="$RELEASE_HOME" "$RELEASED" --version)
assert_eq "$release_version" 'kendex 1.3.0' 'catalog hook proof uses released v1.3.0'
RECORDER_HARNESSES='["claude", "codex", "pi", "copilot"]'

released_hook_rows() {
  local world catalog project home tool judge recorder status
  world=$(mktemp -d "$TMP_ROOT/catalog.XXXXXX") || exit 1
  catalog="$world/catalog"
  project="$world/project"
  home="$world/home"
  mkdir -p "$catalog/hooks" "$catalog/skills/commit-guards" "$project/.agents" "$home"
  cp -- "$HOOK" "$catalog/hooks/skill-load-check.sh"
  cp -- "$CARRIER" "$catalog/hooks/skill-load-record.sh"
  printf 'is_source_catalog = true\n' >"$catalog/kendex.toml"
  printf '%s\n' '---' 'name: commit-guards' 'description: Fixture skill' '---' \
    >"$catalog/skills/commit-guards/SKILL.md"
  cat >"$project/kendex.toml" <<EOF
schema = 6
[sources.cat]
path = "$catalog"
[install]
harnesses = ["claude", "codex", "pi", "copilot"]
method = "copy"
[hooks.skill-load-check]
source = "cat"
harnesses = ["claude", "codex", "pi", "copilot"]
[hooks.skill-load-record]
source = "cat"
harnesses = $RECORDER_HARNESSES
EOF
  status=0
  (cd -- "$project" && env -i PATH="$PATH" HOME="$home" \
    XDG_CONFIG_HOME="$home/config" XDG_DATA_HOME="$home/data" XDG_CACHE_HOME="$home/cache" \
    KENDEX_REAL_HOME=1 KENDEX_UI=plain "$RELEASED" apply --scope project --yes) \
    >"$world/apply.log" 2>&1 || status=$?
  while IFS='|' read -r tool judge recorder; do
    assert_eq "status=$status judge=$([ -f "$project/$judge" ] && echo present || echo absent) recorder=$([ -f "$project/$recorder" ] && echo present || echo absent)" \
      'status=0 judge=present recorder=present' "released planner retains the hook pair on $tool"
  done <<'TOOLS'
claude|.claude/hooks/skill-load-check.sh|.claude/hooks/skill-load-record.sh
codex|.codex/hooks/skill-load-check.sh|.codex/hooks/skill-load-record.sh
pi|.pi/kendex/hooks/skill-load-check.sh|.pi/kendex/hooks/skill-load-record.sh
copilot|.github/hooks/skill-load-check.sh|.github/hooks/skill-load-record.sh
TOOLS
}
released_hook_rows
skill_load_control released-companion "$CARRIER" \
  '# harnesses: [claude, codex, pi, copilot, opencode, cursor]' \
  '# harnesses: [copilot]' CARRIER released_hook_rows \
  'released planner retains the hook pair on claude' \
  'released planner retains the hook pair on codex' \
  'released planner retains the hook pair on pi'

# Keep the positive expectation independent of the declaration under test.
# This control restores the local opt-out, not the catalog header restriction.
control_status=0
(
  PASS=0
  FAIL=0
  RECORDER_HARNESSES='["copilot"]'
  released_hook_rows
  [ "$FAIL" -eq 0 ]
) >"$TMP_ROOT/local-restriction.log" 2>&1 || control_status=$?
assert_eq "$control_status" 1 'control local-restriction: the old declaration turns the suite red'
for tool in claude codex pi; do
  control_matches=$(grep -Fxc -e "  FAIL  released planner retains the hook pair on $tool" \
    -- "$TMP_ROOT/local-restriction.log") || {
    control_status=$?
    [ "$control_status" -eq 1 ] || exit "$control_status"
  }
  assert_eq "$control_matches" 1 "control local-restriction: $tool loses its hook pair"
done

skill_load_control markdown "$HOOK" 'require() { # SKILL' \
  '  [ "$1" != docs-writing ] || return 0' HOOK markdown_rows \
  'a markdown edit without docs-writing refuses, naming it' \
  'a Pi read of .agents/skills/docs-writing/SKILL.md, result none'
skill_load_control batch-read "$HOOK" '      | select(.name == "read" and .status == "ok")' \
  '      | empty' HOOK pi_batch_rows 'a Pi read of .agents/skills/code-quality/SKILL.md, result batch-ok'
skill_load_control batch-path "$HOOK" '      | select(all($named[]; .toolName == "read" and .isError == false and .truncated == false))' \
  '      | "code-quality/SKILL.md"' HOOK pi_batch_rows 'a Pi read of README.md, result batch-ok'
skill_load_control batch-truncated "$HOOK" '      | [$items[] | select(.args | objects | .path == $path)' \
  '        | .truncated = false' HOOK pi_batch_rows 'a Pi read of .agents/skills/code-quality/SKILL.md, result batch-truncated'
skill_load_control batch-is-error "$HOOK" '      | [$items[] | select(.args | objects | .path == $path)' \
  '        | .isError = false' HOOK pi_batch_rows 'a Pi read of .agents/skills/code-quality/SKILL.md, result batch-beside-failed'
skill_load_control batch-tool "$HOOK" '      | [$items[] | select(.args | objects | .path == $path)' \
  '        | .toolName = "read"' HOOK pi_batch_rows 'a Pi read of .agents/skills/code-quality/SKILL.md, result batch-beside-grep'
skill_load_control batch-join "$HOOK" '      | [$items[] | select(.args | objects | .path == $path)] as $named' \
  '      | [$named[0] | objects | {toolName:(if any($named[]; .toolName == "read") then "read" else "" end),
          isError:all($named[]; .isError), truncated:all($named[]; .truncated)}] as $named' HOOK pi_batch_rows \
  'a Pi read of .agents/skills/code-quality/SKILL.md, result batch-beside-failed' \
  'a Pi read of .agents/skills/code-quality/SKILL.md, result batch-beside-grep' \
  'a Pi read of .agents/skills/code-quality/SKILL.md, result batch-cut-beside-failed' \
  'a Pi read of .agents/skills/code-quality/SKILL.md, result batch-cut-beside-grep'
skill_load_control batch-policy-cut "$HOOK" '      (.details | objects' \
  '        | del(.kendexOutputPolicy)' HOOK pi_batch_rows 'a Pi read of .agents/skills/code-quality/SKILL.md, result batch-policy-cut'
skill_load_control batch-item "$HOOK" '      | select($named != []' \
  '        or true' HOOK pi_batch_rows 'a Pi read of .agents/skills/code-quality/SKILL.md, result batch-no-item'
skill_load_control nonpersistent "$HOOK" 'notice() { # KEY VALUE [CAUSE]' \
  '  [ "$1" != gap ] || refuse "$@"' HOOK pi_nonpersistent_row 'Pi nonpersistent session'
skill_load_control missing-library "$HOOK" 'notice() { # KEY VALUE [CAUSE]' \
  '  [ "$1" != missing-library ] || refuse "$@"' HOOK missing_library_row \
  'without the command library a Bash call passes with the library gap first'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
