#!/usr/bin/env bash
# Execute the documented Codex round launch and completion poll against the
# production dev and reviewer artifact checkers. The injected clock reaches a five-minute
# receipt after the caller entered its wait. This proves the shell route and
# caller continuation; it does not prove that a Codex model follows the rule.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd -P)"
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/growth-state.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'codex_round_wait: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'codex_round_wait: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'codex_round_wait: scratch=resolve-failed' >&2; exit 1; }
caller_pid=""
cleanup() {
  local runner leader
  if [[ -n "$caller_pid" ]]; then kill -TERM "$caller_pid" 2>/dev/null || true; wait "$caller_pid" 2>/dev/null || true; fi
  for runner in "$TMP_ROOT"/*/wait.runner "$TMP_ROOT/process-work/tmp"/*/review.runner; do
    [[ -f "$runner" ]] || continue
    leader="$(pgrep -f "${runner%.runner} " || true)"
    [[ -z "$leader" || "$leader" == *$'\n'* ]] || "$SKILL_DIR/scripts/lib/job-unit.sh" stop-job "$runner" "$leader" "*${runner%.runner}*" >/dev/null 2>&1 || true
  done
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup EXIT
REAL_SLEEP="$(command -v sleep)"
REAL_DATE="$(command -v date)"
TIMEOUT="$(command -v timeout || command -v gtimeout)" || { echo 'rowless: codex_round_wait timeout=absent'; exit 0; }
command -v setsid >/dev/null || { echo 'rowless: codex_round_wait setsid=absent'; exit 0; }

awk '/^```sh$/ { active=1; blocks++; next } /^```$/ && active { active=0; next } active { print } END { if (blocks != 1 || active) exit 1 }' \
  "$SKILL_DIR/references/waiter-launch.md" > "$TMP_ROOT/launch.sh"
awk '/^## Delegated round wait$/ { section=1; next } /^## / && section { section=0 } section && /^```bash$/ { active=1; blocks++; next } /^```$/ && active { active=0; next } active { print } END { if (blocks != 1 || active) exit 1 }' \
  "$SKILL_DIR/references/codex-runtime.md" > "$TMP_ROOT/command"
awk '/^## Reviewer round wait$/ { section=1; next } /^## / && section { section=0 } section && /^```bash$/ { active=1; blocks++; next } /^```$/ && active { active=0; next } active { print } END { if (blocks != 1 || active) exit 1 }' \
  "$SKILL_DIR/references/codex-runtime.md" > "$TMP_ROOT/reviewer-command"
# The completion command has one owner. Execute it, rather than reproducing
# the poll in this fixture.
awk 'match($0, /foreground poll `[^`]+`/) { print substr($0, RSTART + 17, RLENGTH - 18); hits++ } END { if (hits != 1) exit 1 }' \
  "$SKILL_DIR/../reviewer/SKILL.md" > "$TMP_ROOT/poll"
mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/systemd-run" <<'SH'
#!/bin/sh
exit 1
SH
cat > "$TMP_ROOT/bin/date" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == +%s ]]; then cat "$ROUND_CASE/clock"; else exec "$REAL_DATE" "$@"; fi
SH
cat > "$TMP_ROOT/bin/sleep" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  5)
    : > "$ROUND_CASE/check-waiting"
    while [[ ! -f "$ROUND_CASE/release" ]]; do "$REAL_SLEEP" 0.01; done
    now="$(cat "$ROUND_CASE/clock")"
    now=$((now + 5))
    printf '%s\n' "$now" > "$ROUND_CASE/clock"
    if [[ "$now" -eq 300 && "$ROUND_LANDS" == yes ]]; then
      cp "$ROUND_CASE/receipt" "$ROUND_CASE/tmp/$ROUND_ARTIFACT"
    fi ;;
  30) : > "$ROUND_CASE/caller-waiting"; "$REAL_SLEEP" 0.01 ;;
  *) exec "$REAL_SLEEP" "$@" ;;
esac
SH
chmod +x "$TMP_ROOT/bin/"*
# Only the poll receives these PATHs, so its command lookup cannot find the
# other supported name elsewhere on the host.
for dependency in timeout gtimeout; do
  mkdir "$TMP_ROOT/$dependency-bin"
  ln -s "$(command -v sh)" "$TMP_ROOT/$dependency-bin/sh"
  ln -s "$TMP_ROOT/bin/sleep" "$TMP_ROOT/$dependency-bin/sleep"
  ln -s "$(command -v bash)" "$TMP_ROOT/$dependency-bin/bash"
  printf '#!%s\nexec %q "$@"\n' "$BASH" "$TIMEOUT" > "$TMP_ROOT/$dependency-bin/$dependency"
  chmod +x "$TMP_ROOT/$dependency-bin/$dependency"
done
cp "$TMP_ROOT/poll" "$TMP_ROOT/timeout-only-poll"
mutate_file "$TMP_ROOT/timeout-only-poll" \
  'command -v timeout || command -v gtimeout' 'command -v timeout'
cat > "$TMP_ROOT/caller.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cd "$ROUND_CASE"
command="$(cat "$ROUND_SOURCE/$ROUND_COMMAND")"
command="${command//\[RUN_DIR\]/$ROUND_CASE}"
command="${command//\[WORKTREE_PATH\]/$ROUND_CASE}"
command="${command//\[ISSUE_ID\]/issue-3409}"
command="${command//\[DEV_ROUND_ID\]/round-1}"
command="${command//\[AGENT\]/reviewer-correctness}"
command="${command//\[REVIEW_DELEGATED_AT\]/0}"
command="${command//\[SECS\]/600}"
"$BASH" -c "$command"
poll="$(cat "$ROUND_SOURCE/$ROUND_POLL_SOURCE")"
poll="${poll//\[RUN_DIR\]/$ROUND_CASE}"
PATH="$ROUND_POLL_PATH" "$BASH" -c "$poll"
code="$(cat "$ROUND_CASE/wait.exit")"
[[ "$code" == 0 || "$code" == 1 ]] || exit "$code"
sed '1d' "$ROUND_CASE/wait.log" | jq -r "$ROUND_RESULT" > "$ROUND_CASE/continued"
SH
cp "$TMP_ROOT/caller.sh" "$TMP_ROOT/old-turn-end.sh"
mutate_file "$TMP_ROOT/old-turn-end.sh" \
  'PATH="$ROUND_POLL_PATH" "$BASH" -c "$poll"' 'exit 0
PATH="$ROUND_POLL_PATH" "$BASH" -c "$poll"'

await_file() {
  local i
  for ((i=0; i<2000; i++)); do
    if [[ "${2:-}" == nonempty ]]; then
      [[ ! -s "$1" ]] || return 0
    else
      [[ ! -s "$1" && ! -f "$1" ]] || return 0
    fi
    "$REAL_SLEEP" 0.01
  done
  printf 'codex_round_wait: marker-timeout path=%s\n' "$1" >&2
  return 1
}

if [[ "${CODEX_ROUND_WAIT_ONLY:-}" != process ]]; then
while IFS='|' read -r name kind caller dependency poll_source lands elapsed verdict continuation expected_rc; do
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/tmp" "$case_dir/.agents/skills"
  ln -s "$SKILL_DIR" "$case_dir/.agents/skills/orch"
  cp "$TMP_ROOT/launch.sh" "$case_dir/launch.sh"
  printf '0\n' > "$case_dir/clock"
  case "$kind" in
    dev)
      command_source=command artifact=dev-return-issue-3409-round-1.json result_filter=.verdict
      printf '%s\n' '{"schema_version":1,"round_id":"round-1","kind":"implement","issue":"issue-3409","branch":"fixture","commit":"abc123f","baseline_lines":1,"validate":"pass","validate_mode":"full","validate_time":{"started_at":"2026-01-01T00:00:00Z","ended_at":"2026-01-01T00:05:00Z","seconds":300},"qa_labels":[],"summary_posted":true,"summary":null,"bundled":false,"items":[]}' > "$case_dir/receipt" ;;
    reviewer)
      command_source=reviewer-command artifact=review-reviewer-correctness-delayed.json result_filter=.reason
      git -C "$case_dir" init -q
      git -C "$case_dir" config gc.auto 0
      git -C "$case_dir" config maintenance.auto false
      git -C "$case_dir" -c user.name=Test -c user.email=test@example.com -c core.hooksPath=/dev/null commit -q --allow-empty -m fixture
      head="$(git -C "$case_dir" rev-parse HEAD)"
      jq -n --arg head "$head" '{verdict:"pass",head:$head,dirty_paths:[],blockers:[],suggestions:[],questions:[]}' > "$case_dir/receipt"
      "$SKILL_DIR/scripts/workflow-state" --state-dir "$case_dir/tmp" init issue-3409 --worktree "$case_dir" --branch fixture >/dev/null ;;
    *) echo "codex_round_wait: kind=$kind" >&2; exit 1 ;;
  esac
  env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TMP_ROOT/bin:$PATH" HOME="$HOME" ROUND_CASE="$case_dir" ROUND_LANDS="$lands" \
    ORCH_STATE_DIR="$case_dir/tmp" ROUND_COMMAND="$command_source" ROUND_ARTIFACT="$artifact" ROUND_RESULT="$result_filter" \
    ROUND_SOURCE="$TMP_ROOT" REAL_SLEEP="$REAL_SLEEP" REAL_DATE="$REAL_DATE" \
    ROUND_POLL_PATH="$TMP_ROOT/$dependency-bin" ROUND_POLL_SOURCE="$poll_source" \
    "$TIMEOUT" 60 "$BASH" "$TMP_ROOT/$caller.sh" > "$case_dir/caller.log" 2>&1 &
  caller_pid=$!
  await_file "$case_dir/check-waiting"
  if [[ "$caller" == caller && "$expected_rc" == 0 ]]; then
    await_file "$case_dir/caller-waiting"
  else
    caller_rc=0
    wait "$caller_pid" || caller_rc=$?
    assert_eq "$caller_rc" "$expected_rc" "$name: caller exit" "$case_dir/caller.log"
    caller_pid=""
  fi
  : > "$case_dir/release"
  if [[ -n "$caller_pid" ]]; then
    caller_rc=0
    wait "$caller_pid" || caller_rc=$?
    caller_pid=""
    assert_eq "$caller_rc" "$expected_rc" "$name: caller exit" "$case_dir/caller.log"
  fi
  await_file "$case_dir/wait.exit"
  got_continuation=absent
  [[ ! -f "$case_dir/continued" ]] || got_continuation="$(cat "$case_dir/continued")"
  got_verdict="$(sed '1d' "$case_dir/wait.log" | jq -r "$result_filter")"
  assert_eq "$(cat "$case_dir/clock")|$got_verdict|$got_continuation" \
    "$elapsed|$verdict|$continuation" "$name" "$case_dir/caller.log"
done <<'ROWS'
delayed-round-same-turn|dev|caller|timeout|poll|yes|300|accept|accept|0
delayed-round-gtimeout-only|dev|caller|gtimeout|poll|yes|300|accept|accept|0
deadline-same-turn|dev|caller|timeout|poll|no|600|wait|wait|0
control-old-turn-end-stalls|dev|old-turn-end|timeout|poll|yes|300|accept|absent|0
control-timeout-only-refuses|dev|caller|gtimeout|timeout-only-poll|yes|300|accept|absent|127
delayed-reviewer-same-turn|reviewer|caller|timeout|poll|yes|300|valid|valid|0
delayed-reviewer-gtimeout-only|reviewer|caller|gtimeout|poll|yes|300|valid|valid|0
reviewer-table-row-same-turn|reviewer|caller|timeout|poll|no|600|missing|missing|0
control-reviewer-old-turn-end-stalls|reviewer|old-turn-end|timeout|poll|yes|300|valid|absent|0
ROWS
fi

if [[ -z "${CODEX_ROUND_WAIT_ONLY:-}" || "$CODEX_ROUND_WAIT_ONLY" == process ]]; then
  # Execute the source command boundary, not a second command model. The
  # controlled executable receives the installed complete role and workflow
  # plus the review-pr delegation. This proves transport, not model obedience
  # to the workflow's panel selection, continuation or deadline instructions.
  runtime="${CODEX_RUNTIME_UNDER_TEST:-$SKILL_DIR/references/codex-runtime.md}"
  awk '/^## Process-owned reviewers$/ { section=1; next } /^## / && section { section=0 }
    section && /^```bash$/ { active=1; next } /^```$/ && active { active=0; next }
    active && /exec codex exec / { print; hits++ } END { if (hits != 1 || active) exit 1 }' \
    "$runtime" > "$TMP_ROOT/process-launch"
  awk '/^## Process-owned reviewers$/ { section=1; next } /^## / && section { section=0 }
    section && /^```bash$/ { active=1; next } /^```$/ && active { active=0; next }
    active && /exec .*review-artifact-check --file/ { print; hits++ } END { if (hits != 1 || active) exit 1 }' \
    "$runtime" > "$TMP_ROOT/process-collect"
  cat > "$TMP_ROOT/bin/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
jq -nc --args '$ARGS.positional' -- "$@" >> "$PROCESS_JOB/invocations"
printf '%s\n' "$CODEX_HOME" > "$PROCESS_JOB/account"
pwd -P > "$PROCESS_JOB/cwd"
cat > "$PROCESS_JOB/received"
last=''
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == --output-last-message ]]; then last="$2"; shift; fi
  shift
done
[[ -n "$last" ]] || exit 63
printf 'Verdict: pass\nFile: %s\n' "$PROCESS_ARTIFACT" > "$last"
case "$PROCESS_RESULT" in
  valid | nonzero) cp "$PROCESS_JOB/receipt" "$PROCESS_ARTIFACT" ;;
  invalid) printf '{"verdict":' > "$PROCESS_ARTIFACT" ;;
  missing) ;;
  *) exit 64 ;;
esac
[[ "$PROCESS_RESULT" != nonzero ]] || exit 7
SH
  chmod +x "$TMP_ROOT/bin/codex"
  process_work="$TMP_ROOT/process-work"
  mkdir -p "$process_work/.agents/skills" "$process_work/tmp" "$TMP_ROOT/process-account"
  ln -s "$SKILL_DIR" "$process_work/.agents/skills/orch"
  git -C "$process_work" init -q
  git -C "$process_work" config gc.auto 0
  git -C "$process_work" config maintenance.auto false
  git -C "$process_work" -c user.name=Test -c user.email=test@example.com -c core.hooksPath=/dev/null commit -q --allow-empty -m fixture
  process_head="$(git -C "$process_work" rev-parse HEAD)"
  "$SKILL_DIR/scripts/workflow-state" --state-dir "$process_work/tmp" init process-4642 --worktree "$process_work" --branch fixture >/dev/null
  source_repo="$(cd "$SKILL_DIR/../.." && pwd -P)"
  while IFS='|' read -r domain result expected_exit expected_ok expected_reason; do
    [[ -z "${CODEX_PROCESS_RESULT_ONLY:-}" || "$CODEX_PROCESS_RESULT_ONLY" == "$result" ]] || continue
    job="$process_work/tmp/$domain-$result"
    mkdir "$job"
    cp "$TMP_ROOT/launch.sh" "$job/launch.sh"
    artifact="$("$SKILL_DIR/scripts/review-artifact-check" --path "$process_work" "$domain")"
    [[ ! -e "$artifact" ]] || rm -- "$artifact"
    jq -nc --arg agent "$domain" --arg head "$process_head" \
      '{agent:$agent,verdict:"pass",head:$head,dirty_paths:[],blockers:[],suggestions:[],questions:[]}' > "$job/receipt"
    # The generated role contains consumer instructions absent from its catalog
    # source. Universal newlines normalize checked-out TOML and Markdown.
    python3 - "$source_repo" "$SKILL_DIR" "$domain" "$process_work" "$artifact" "$process_head" "$job/delegation.md" <<'PY'
import pathlib, sys, tomllib
repo, skill, domain, worktree, artifact, head, output = sys.argv[1:]
role = tomllib.loads((pathlib.Path(repo) / '.codex/agents' / (domain + '.toml')).read_text())['developer_instructions']
workflow = (pathlib.Path(skill).parent / 'reviewer/workflows/review.md').read_text()
review = (pathlib.Path(skill) / 'workflows/review-pr.md').read_text()
start = review.index('<delegation_format>')
end = review.index('</delegation_format>', start) + len('</delegation_format>')
delegation = review[start:end]
for key, value in {
    '[WORKTREE_PATH]': worktree, '[BRANCH]': 'fixture', '[ARTIFACT_PATH]': artifact,
    '[DIFF_RANGE, or unavailable for a missing fix boundary]': head + '...' + head,
    '[For each verified decision: "- [DECISION_ID]: [ONE_LINE_SUMMARY] — [DECISION_FILE_PATH]"]': '- Fixture decision: retain the exact assigned artifact.',
    '[For each decision whose path failed verification: "- decision index lookup failed for [DECISION_ID]"]': '',
    '[If none: "- No linked decisions found."]': '',
    '[For each fixed_item: "[LOCATION] | [DESCRIPTION] — fixed in [COMMIT_SHA]"; an entry whose commit is a `dropped:<sha>` marker prints "recorded, then dropped in a rebase" in place of the sha]': 'file:1 | fixed fixture finding — fixed in ' + head,
    '[For each escalated_item: "[LOCATION] | [DESCRIPTION] — [REASON]"]': 'file:2 | retained fixture finding — tracked',
    '[For each declined_item: "[LOCATION] | [DESCRIPTION] — [REASON]"]': 'file:3 | suppressed fixture finding — no reachable defect',
    '[PRIOR_REPORT_PATH]': worktree + '/tmp/prior.json', '[N]': '1',
    '<if re-review cycle>': '', '<if this reviewer session was recreated fresh>': '', '</if>': '',
}.items():
    delegation = delegation.replace(key, value)
assert not any(marker in delegation for marker in ('[For each', '[WORKTREE_PATH]', '[ARTIFACT_PATH]'))
pathlib.Path(output).write_text('DELEGATION:\n' + role + '\n' + workflow + '\n' + delegation + '\n')
PY
    launch="$(cat "$TMP_ROOT/process-launch")"
    launch="${launch//\[JOB_DIR\]/$job}"
    process_flags='--model gpt-6.1-sol -c model_reasoning_effort=high --dangerously-bypass-approvals-and-sandbox'
    launch="${launch//\[CURRENT_REVIEW_MODEL_EFFORT_AND_PERMISSION_FLAGS\]/$process_flags}"
    (cd "$process_work" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT" CODEX_HOME="$TMP_ROOT/process-account" \
      PROCESS_JOB="$job" PROCESS_ARTIFACT="$artifact" PROCESS_RESULT="$result" \
      "$TIMEOUT" 60 "$BASH" -c "$launch") > "$job/launch.log" 2>&1
    await_file "$job/review.exit" nonempty
    assert_eq "$(cat "$job/review.exit")" "$expected_exit" "process $domain $result: terminal exit"
    assert_eq "$(wc -l < "$job/invocations" | tr -d ' ')" 1 "process $domain $result: one job"
    assert_eq "$(jq -c '.' "$job/invocations")" \
      "[\"exec\",\"--ephemeral\",\"--model\",\"gpt-6.1-sol\",\"-c\",\"model_reasoning_effort=high\",\"--dangerously-bypass-approvals-and-sandbox\",\"--output-last-message\",\"$job/last-message.md\",\"-\"]" \
      "process $domain $result: native exec instead of attached launch"
    assert_eq "$(cat "$job/account")|$(cat "$job/cwd")" "$TMP_ROOT/process-account|$process_work" \
      "process $domain $result: account and owned worktree"
    cmp -s "$job/delegation.md" "$job/received" && pass "process $domain $result: complete prompt and exact artifact delivered" \
      || fail "process $domain $result: complete prompt and exact artifact delivered"
    collect="$(cat "$TMP_ROOT/process-collect")"
    collect="${collect//\[JOB_DIR\]/$job}"
    collect="${collect//\[ASSIGNED_ARTIFACT_PATH\]/$artifact}"
    collect="${collect//\[WORKTREE_PATH\]/$process_work}"
    collect="${collect//\[CHECK_BOUNDARY\]/0}"
    collect="${collect//\[ISSUE_ID\]/process-4642}"
    rc=0
    (cd "$process_work" && ORCH_STATE_DIR="$process_work/tmp" "$TIMEOUT" 60 "$BASH" -c "$collect") \
      > "$job/collection.json" 2> "$job/collection.err" || rc=$?
    if [[ "$result" == nonzero ]]; then
      assert_eq "$rc:$(wc -c < "$job/collection.json" | tr -d ' ')" '1:0' \
        "process $domain $result: failed execution supplies no acceptance"
    else
      assert_eq "$(jq -r '[.ok,.reason] | @tsv' "$job/collection.json")" \
        "$expected_ok"$'\t'"$expected_reason" "process $domain $result: exact artifact acceptance"
    fi
  done <<'ROWS'
reviewer-correctness|valid|0|true|valid
reviewer-error|valid|0|true|valid
reviewer-correctness|nonzero|7|false|unread
reviewer-error|missing|0|false|missing
reviewer-correctness|invalid|0|false|invalid
ROWS
  if [[ -z "${CODEX_RUNTIME_UNDER_TEST:-}" ]]; then
    cp "$runtime" "$TMP_ROOT/process-exit-control.md"
    mutate_file "$TMP_ROOT/process-exit-control.md" 'case "$code" in 0)' 'case "$code" in *)'
    rc=0
    CODEX_RUNTIME_UNDER_TEST="$TMP_ROOT/process-exit-control.md" CODEX_ROUND_WAIT_ONLY=process CODEX_PROCESS_RESULT_ONLY=nonzero \
      "$TIMEOUT" 60 "$BASH" "$0" > "$TMP_ROOT/process-exit-control.log" 2>&1 || rc=$?
    assert_eq "$rc" 1 'control: nonzero process execution cannot accept its valid artifact' "$TMP_ROOT/process-exit-control.log"
    assert_eq "$(grep -c -F 'FAIL  process reviewer-correctness nonzero: failed execution supplies no acceptance' "$TMP_ROOT/process-exit-control.log" || true)" 1 \
      'control: exit refusal assertion detects the planted defect'
  fi
fi
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
