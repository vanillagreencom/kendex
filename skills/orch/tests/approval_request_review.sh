#!/usr/bin/env bash
# Action routing; native-resolution shapes live in approval_wait.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$TEST_DIR/../../.." && pwd -P)"
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/growth-state.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'approval_request_review: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "approval_request_review: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'approval_request_review: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/home" "$TMP_ROOT/catalog" "$TMP_ROOT/consumer base/.agents/skills/orch/scripts"
BASE="$TMP_ROOT/consumer base"
git -C "$BASE" init -q
git -C "$BASE" config gc.auto 0
git -C "$BASE" config maintenance.auto false
git -C "$BASE" remote add origin https://github.com/consumer/repo.git
printf '[env]\nREVIEW_GATE_MODE = "enforce"\n' > "$TMP_ROOT/catalog/kendex.settings.toml"
cat > "$BASE/.agents/skills/orch/scripts/approval-wait" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$GH_TOKEN" >> "$EXECUTION_LOG"
echo off
EOF
printf 'printf "%%s\\n" "$GH_TOKEN" >> "$EXECUTION_LOG"\n' > "$BASE/.env.local"
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  'auth status'|'api user') exit "${AUTH_EXIT:-0}" ;;
  'repo view')
    [[ "${DENY_GRAPHQL:-false}" != true ]] || { echo 'HTTP 403: Forbidden' >&2; exit 1; }
    echo consumer/repo
    ;;
  'pr view')
    [[ "${DENY_GRAPHQL:-false}" != true ]] || { echo 'HTTP 403: Forbidden' >&2; exit 1; }
    printf '%s\n' "$PWD|$*" >> "$QUERY_LOG"
    if [[ "$*" == *'--json state,isDraft'* ]]; then
      [[ "${HEAD_READ_FAIL:-false}" != true ]] || exit 1
      [[ "${HEAD_READ_FAIL_AFTER_READY:-false}" != true || ! -s "$TRANSITION_LOG" ]] || exit 1
      draft=false
      [[ ! -f "$DRAFT_FILE" ]] || draft="$(cat "$DRAFT_FILE")"
      head=current-head
      [[ ! -f "$HEAD_FILE" ]] || head="$(cat "$HEAD_FILE")"
      view="$(jq -cn --argjson draft "$draft" --arg head "$head" --arg state "${PR_STATE:-OPEN}" '{state:$state,isDraft:$draft,headRefOid:$head}')"
      if [[ "$*" == *'--jq'* ]]; then
        jq -r "${!#}" <<<"$view"
      else
        printf '%s\n' "$view"
      fi
    else
      echo '{"baseRefName":"feature/base","reviewDecision":"REVIEW_REQUIRED"}'
    fi
    ;;
  'pr ready')
    printf 'ready\n' >> "$TRANSITION_LOG"
    [[ "${CLOUD_DIRTY_BASE:-false}" != true ]] || touch "$PWD/cloud-cleanup-blocker"
    [[ "${READY_EXIT:-0}" == 0 ]] || exit "$READY_EXIT"
    printf 'false\n' > "$DRAFT_FILE"
    [[ "${MOVE_READY_HEAD:-false}" != true ]] || printf 'new-head\n' > "$HEAD_FILE"
    ;;
  'api repos/consumer/repo/rules/branches/feature%2Fbase')
    printf '%s\n' "$PWD|$*" >> "$QUERY_LOG"
    printf '[{"type":"pull_request","parameters":{"required_approving_review_count":%s}}]\n' "${REQUIRED_APPROVALS:-1}"
    ;;
  'api repos/consumer/repo/branches/feature%2Fbase')
    echo '{"protection":{"enabled":false}}'
    ;;
  'api repos/consumer/repo/pulls/42')
    [[ "$PULL_JSON" != fail ]] || exit 1
    [[ "${BASE_READ_FAIL:-false}" != true ]] || { echo 'HTTP 403: Forbidden' >&2; exit 1; }
    [[ "${HEAD_READ_FAIL:-false}" != true ]] || exit 1
    [[ "${HEAD_READ_FAIL_AFTER_READY:-false}" != true || ! -s "$TRANSITION_LOG" ]] || exit 1
    draft=false
    [[ ! -f "$DRAFT_FILE" ]] || draft="$(cat "$DRAFT_FILE")"
    head=current-head
    [[ ! -f "$HEAD_FILE" ]] || head="$(cat "$HEAD_FILE")"
    jq -c --argjson draft "$draft" --arg sha "$head" --arg state "${PR_STATE:-open}" \
      '. + {base:{ref:"feature/base"},state:($state|ascii_downcase),draft:$draft} | .head.sha=$sha' <<<"$PULL_JSON"
    ;;
  api\ repos/consumer/repo/commits/*/check-runs*)
    [[ "${CHECKS_FAIL:-false}" != true ]] || exit 1
    printf '%s\n' "$CHECKS_JSON"
    ;;
  'api repos/consumer/repo/issues/42/timeline?per_page=100')
    [[ "${TIMELINE_FAIL:-false}" != true ]] || exit 1
    printf '%s\n' "$TIMELINE_JSON"
    ;;
  'api repos/consumer/repo/pulls/42/reviews')
    [[ "${REVIEWS_FAIL:-false}" != true ]] || exit 1
    printf '%s\n' "$REVIEWS_JSON"
    ;;
  'api repos/consumer/repo/pulls/42/requested_reviewers'|'pr edit')
    if [[ "$1" == pr && "${DENY_GRAPHQL:-false}" == true ]]; then echo 'HTTP 403: Forbidden' >&2; exit 1; fi
    printf '%s\n' "$PWD|$*" >> "$REQUEST_LOG"
    printf 'request head=%s draft=%s\n' "$(cat "$HEAD_FILE" 2>/dev/null || echo current-head)" "$(cat "$DRAFT_FILE" 2>/dev/null || echo false)" >> "$TRANSITION_LOG"
    [[ "$REQUEST_EXIT" == 0 ]] || exit "$REQUEST_EXIT"
    echo 'https://github.com/consumer/repo/pull/42'
    ;;
  'api graphql') echo 'HTTP 403: Forbidden' >&2; exit 1 ;;
  *) printf 'gh: unexpected argv=%s\n' "$*" >&2; exit 9 ;;
esac
EOF
chmod +x "$BASE/.agents/skills/orch/scripts/approval-wait" "$TMP_ROOT/bin/gh"
RUN="$REPO_ROOT/skills/orch/scripts/approval-wait"
STATE="$REPO_ROOT/skills/orch/scripts/workflow-state"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"
REQUEST_LOG="$TMP_ROOT/requests"
QUERY_LOG="$TMP_ROOT/queries"
EXECUTION_LOG="$TMP_ROOT/executions"
DRAFT_FILE="$TMP_ROOT/draft"
HEAD_FILE="$TMP_ROOT/head"
TRANSITION_LOG="$TMP_ROOT/transitions"

# write_settings FILE GATE COPILOT [REFRESH]: COPILOT empty leaves
# PR_COPILOT_REQUESTS unset; REFRESH is extra [env] lines, ';'-separated.
write_settings() {
  printf '[env]\nREVIEW_GATE_MODE = %s\n' "$2" > "$1"
  [[ -z "$3" ]] || printf 'PR_COPILOT_REQUESTS = "%s"\n' "$3" >> "$1"
  [[ -z "${4:-}" ]] || tr ';' '\n' <<<"$4" >> "$1"
}
ORDINARY_PULL='{"head":{"ref":"feature/work"},"user":{"login":"someone","type":"User"}}'
PULL_JSON="$ORDINARY_PULL"
RUN_ENV=()

run_action() { # SCRIPT REQUEST_EXIT ARGS...
  local script="$1" request_exit="$2"
  shift 2
  : > "$REQUEST_LOG"
  : > "$QUERY_LOG"
  : > "$EXECUTION_LOG"
  : > "$TRANSITION_LOG"
  RC=0
  (cd -- "${ACTION_CWD:-$TMP_ROOT/catalog}" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT/home" \
    GH_TOKEN=github_pat_fixture GH_REPO=catalog/repo GITHUB_REPOSITORY=catalog/repo \
    REVIEW_GATE_MODE=enforce PR_REVIEW_GATE=review REVIEW_GATE_SETTINGS_FILE=/dev/null \
    QUERY_LOG="$QUERY_LOG" EXECUTION_LOG="$EXECUTION_LOG" REQUEST_LOG="$REQUEST_LOG" \
    DRAFT_FILE="$DRAFT_FILE" HEAD_FILE="$HEAD_FILE" TRANSITION_LOG="$TRANSITION_LOG" \
    ORCH_STATE_DIR="$TMP_ROOT/state" REVIEW_BASE_FIXTURE="$BASE" \
    CHECKS_JSON='[{"check_runs":[]}]' TIMELINE_JSON='[[]]' REVIEWS_JSON='[]' \
    REQUEST_EXIT="$request_exit" PULL_JSON="$PULL_JSON" ${RUN_ENV[@]+"${RUN_ENV[@]}"} \
    "$BASH" "$script" 42 "$@" > "$OUT" 2> "$ERR") || RC=$?
  REQUESTS="$(wc -l < "$REQUEST_LOG" | tr -d ' ')"
}

# Columns: label|action|consumer gate|caller PR_COPILOT_REQUESTS|base PR_COPILOT_REQUESTS|request exit|rc|stdout|requests|stderr line the caller copies into its notice
for row in \
  'disabled request|--request-review|"off"|||0|0|off|0|' \
  'disabled resolution|--resolve-mode|"off"|||0|0|off|0|' \
  'enabled request|--request-review|"enforce"|||0|0|approval|1|' \
  'unknown policy|--request-review|"junk"|||0|2||0|' \
  'empty policy|--request-review|""|||0|2||0|' \
  'unreadable policy|--request-review|["off"]|||0|2||0|' \
  'refused GitHub request|--request-review|"enforce"|||8|0|fallback cause=refused exit=8|1|approval-wait: copilot-request-refused pr=42 repo=consumer/repo exit=8' \
  'Copilot requests off|--request-review|"enforce"|off||0|0|fallback cause=off|0|' \
  'Copilot requests off on an off gate|--request-review|"off"|off||0|0|off|0|' \
  'Copilot requests off at resolution|--resolve-mode|"enforce"|off||0|0|approval|0|' \
  'unknown Copilot request setting at resolution|--resolve-mode|"enforce"|junk||0|0|approval|0|' \
  'base checkout cannot turn Copilot requests off|--request-review|"enforce"||off|0|0|approval|1|' \
  'unknown Copilot request setting|--request-review|"enforce"|junk||0|2||0|' \
  'unreadable Copilot request setting|--request-review|"enforce"|\"off||0|2||0|'; do
  IFS='|' read -r label action setting caller_copilot base_copilot request_exit want_rc want_out want_requests want_err <<< "$row"
  write_settings "$BASE/kendex.settings.toml" "$setting" "$base_copilot"
  write_settings "$TMP_ROOT/catalog/kendex.settings.toml" '"enforce"' "$caller_copilot"
  run_action "$RUN" "$request_exit" "$action" --base-checkout "$BASE"
  assert_eq "$RC|$(cat "$OUT")|$REQUESTS|$(cat "$EXECUTION_LOG")" "$want_rc|$want_out|$want_requests|" "$label without base execution" "$ERR"
  [[ "$setting" != '"off"' ]] || assert_eq "$(cat "$QUERY_LOG")" '' "$label reads no native gate" "$ERR"
  [[ -z "$want_err" ]] || assert_contains "$(cat "$ERR")" "$want_err" "$label names its cause on stderr" "$ERR"
done
write_settings "$TMP_ROOT/catalog/kendex.settings.toml" '"enforce"' ''
write_settings "$BASE/kendex.settings.toml" '"enforce"' ''
run_action "$RUN" 0 --request-review --base-checkout "$BASE"
assert_eq "$(cat "$REQUEST_LOG")" "$BASE|api repos/consumer/repo/pulls/42/requested_reviewers --method POST -f reviewers[]=copilot-pull-request-reviewer[bot]" \
  'the request names the consumer repository, not the inherited catalog' "$ERR"
assert_contains "$(cat "$QUERY_LOG")" "$BASE|api repos/consumer/repo/rules/branches/feature%2Fbase --paginate" \
  'the trusted native owner reads stacked-base rules from the consumer directory' "$ERR"

for action in --request-review --resolve-mode; do
  for context in '' "$TMP_ROOT/missing"; do
    base_args=()
    [[ -z "$context" ]] || base_args=(--base-checkout "$context")
    run_action "$RUN" 0 "$action" ${base_args[@]+"${base_args[@]}"}
    assert_eq "$RC|$(cat "$OUT")|$REQUESTS|$(cat "$QUERY_LOG")|$(cat "$EXECUTION_LOG")" '2||0||' "$action refuses unavailable context [$context] before native reads" "$ERR"
  done
done
# submit-pr produces --mark-ready only after internal review passes. The
# real request owner holds the draft until that command and confirms its head.
write_settings "$TMP_ROOT/catalog/kendex.settings.toml" '"enforce"' ''
write_settings "$BASE/kendex.settings.toml" '"enforce"' ''
# REST reads and requests do not need GraphQL. The ready command is an
# upstream GraphQL mutation with no REST equivalent; this fixture allows it
# explicitly, and a separate row proves its refusal stops the request.
for row in \
  'REST request after ready|false|1|false|0|0|approval|1|false|request head=current-head draft=false|' \
  'REST reads around ready mutation|true|1|false|0|0|approval|1|false|ready,request head=current-head draft=false|' \
  'REST off mode|true|0|false|0|0|off|0|false|ready|' \
  'REST base refusal|true|1|true|0|2||0|true||base-unreadable' \
  'ready mutation refusal|true|1|false|1|2||0|true|ready|ready-failed'; do
  IFS='|' read -r label draft required failed ready_exit want_rc want_out requests want_draft transitions diagnostic <<<"$row"
  printf '%s\n' "$draft" > "$DRAFT_FILE"
  printf 'current-head\n' > "$HEAD_FILE"
  RUN_ENV=(DENY_GRAPHQL=true "REQUIRED_APPROVALS=$required" "BASE_READ_FAIL=$failed" "READY_EXIT=$ready_exit")
  run_action "$RUN" 0 --request-review --mark-ready --base-checkout "$BASE"
  assert_eq "$RC|$(cat "$OUT")|$REQUESTS|$(cat "$DRAFT_FILE")|$(paste -sd, "$TRANSITION_LOG")" \
    "$want_rc|$want_out|$requests|$want_draft|$transitions" "$label" "$ERR"
  [[ -z "$diagnostic" ]] || assert_contains "$(cat "$ERR")" "approval-wait: $diagnostic pr=42 repo=consumer/repo" "$label key" "$ERR"
  [[ "$diagnostic" != ready-failed ]] || assert_contains "$(cat "$ERR")" 'operation=markPullRequestReadyForReview' "$label operation" "$ERR"
done
# The old gate read still reaches base-unreadable under the identical fixture.
scripts="$(mutant_scripts rest-base-control approval-wait)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/github"
ln -s "$REPO_ROOT/skills/review-gate" "$TMP_ROOT/review-gate"
mutate_file "$scripts/approval-wait" 'base_json=$(gh api "repos/$REPO/pulls/$PR_NUM"' \
  'base_json=$(gh pr view "$PR_NUM" --repo "$REPO" --json baseRefName,reviewDecision'
printf 'true\n' > "$DRAFT_FILE"
RUN_ENV=(DENY_GRAPHQL=true)
run_action "$scripts/approval-wait" 0 --request-review --mark-ready --base-checkout "$BASE"
assert_eq "$RC|$(cat "$OUT")|$REQUESTS|$(cat "$DRAFT_FILE")" '2||0|true' 'control: old gate read blocks draft completion' "$ERR"
assert_contains "$(cat "$ERR")" 'approval-wait: base-unreadable pr=42 repo=consumer/repo' 'control: old gate refusal key' "$ERR"
scripts="$(mutant_scripts rest-refusal-control approval-wait)" || exit 1
mutate_file "$scripts/approval-wait" 'base_json=$(gh api "repos/$REPO/pulls/$PR_NUM" 2>"$GH_ERR_FILE")' \
  'base_json=$(gh api "repos/$REPO/pulls/$PR_NUM" 2>"$GH_ERR_FILE" || printf '\''{"base":{"ref":"feature/base"}}'\'')'
RUN_ENV=(DENY_GRAPHQL=true BASE_READ_FAIL=true)
run_action "$scripts/approval-wait" 0 --request-review --mark-ready --base-checkout "$BASE"
assert_not_contains "$(cat "$ERR")" 'approval-wait: base-unreadable ' 'control: defaulting failed REST base read breaks its refusal' "$ERR"
assert_contains "$(cat "$ERR")" 'approval-wait: request-head-unreadable ' 'control: failed base read reaches the later head read' "$ERR"
scripts="$(mutant_scripts ready-refusal-control approval-wait)" || exit 1
mutate_file "$scripts/approval-wait" 'gh pr ready "$PR_NUM" --repo "$REPO" >&2 || { approval_message ready-failed >&2; exit 2; }' \
  'gh pr ready "$PR_NUM" --repo "$REPO" >&2 || : # { approval_message ready-failed >&2; exit 2; }'
RUN_ENV=(DENY_GRAPHQL=true READY_EXIT=1)
run_action "$scripts/approval-wait" 0 --request-review --mark-ready --base-checkout "$BASE"
assert_not_contains "$(cat "$ERR")" 'approval-wait: ready-failed ' 'control: ignoring ready refusal drops its mutation cause' "$ERR"
assert_contains "$(cat "$ERR")" 'approval-wait: ready-head-moved ' 'control: ignoring ready refusal reaches the later head guard' "$ERR"
RUN_ENV=()
rm -- "$DRAFT_FILE" "$HEAD_FILE"
# The publication command supplies these arguments; run its real owner.
ready_doc_args() { # DOC
  local line field
  READY_ARGS=()
  line="$(awk '/^[[:space:]]*\*\*Push-first ready head/ {ready=1} ready && /^[[:space:]]*env .*approval-wait \[PR_NUMBER\] --request-review/ {print; exit}' "$1")"
  [[ -n "$line" ]] || return 1
  line="$(sed 's/^.*approval-wait \[PR_NUMBER\] //' <<<"$line")"
  for field in $line; do
    [[ "$field" != '[REVIEW_BASE_CHECKOUT]' ]] || field="$BASE"
    [[ "$field" != '[ISSUE_ID]' ]] || field=KEN-3231
    READY_ARGS+=("$field")
  done
}
READY_ARGS=()
"$STATE" --state-dir "$TMP_ROOT/state" init KEN-3231 --worktree "$TMP_ROOT/catalog" >/dev/null
ready_doc_args "$REPO_ROOT/skills/orch/workflows/submit-pr.md" || exit 1
for row in \
  'draft held|true|no|0|false|false|0|fallback cause=draft|0|none' \
  'ready transition|true|yes|0|false|false|0|approval|1|ready,request head=current-head draft=false' \
  'already ready without request|false|yes|0|false|false|0|approval|1|request head=current-head draft=false' \
  'ready failed|true|yes|8|false|false|2||0|ready' \
  'ready head changed|true|yes|0|true|false|2||0|ready' \
  'head unreadable|true|yes|0|false|true|2||0|none'; do
  IFS='|' read -r label draft mark ready_exit moved unread want_rc want_out requests transitions <<<"$row"
  printf '%s\n' "$draft" > "$DRAFT_FILE"
  printf 'current-head\n' > "$HEAD_FILE"
  args=(--request-review --base-checkout "$BASE")
  [[ "$mark" == no ]] || args=("${READY_ARGS[@]}")
  RUN_ENV=("READY_EXIT=$ready_exit" "MOVE_READY_HEAD=$moved" "HEAD_READ_FAIL=$unread")
  run_action "$RUN" 0 "${args[@]}"
  actual="$(paste -sd, "$TRANSITION_LOG")"
  assert_eq "$RC|$(cat "$OUT")|$REQUESTS|${actual:-none}" "$want_rc|$want_out|$requests|$transitions" "$label" "$ERR"
done
RUN_ENV=()
# Removing the producer's ready flag makes the same publication command fail
# to produce the ready request. This control exercises the script, not prose.
cp "$REPO_ROOT/skills/orch/workflows/submit-pr.md" "$TMP_ROOT/submit-mutant.md"
mutate_file "$TMP_ROOT/submit-mutant.md" '--request-review --mark-ready --item' '--request-review --item'
ready_doc_args "$TMP_ROOT/submit-mutant.md" || exit 1
printf 'true\n' > "$DRAFT_FILE"
printf 'current-head\n' > "$HEAD_FILE"
run_action "$RUN" 0 "${READY_ARGS[@]}"
assert_eq "$RC|$(cat "$OUT")|$REQUESTS" '0|fallback cause=draft|0' \
  'control: removing the publication flag breaks its ready request'
ready_doc_args "$REPO_ROOT/skills/orch/workflows/submit-pr.md" || exit 1
# Drive submit's real record comparison and the real request owner.
PUBLICATION_SCRIPT="$TMP_ROOT/publication.sh"
code="$(awk '/^[[:space:]]*COPILOT_REQUESTED_HEAD=/ {take=1} take {print} take && /^[[:space:]]*fi$/ {exit}' "$REPO_ROOT/skills/orch/workflows/submit-pr.md")"
[[ -n "$code" ]] || exit 1
code="${code//.agents\/skills\/orch\/scripts\//$REPO_ROOT/skills/orch/scripts/}"
code="${code//\[PR_NUMBER\]/42}"
code="${code//\[ISSUE_ID\]/KEN-3231}"
code="${code//\[HEAD_SHA\]/current-head}"
code="${code//\[REVIEW_BASE_CHECKOUT\]/\"\$REVIEW_BASE_FIXTURE\"}"
printf 'set -euo pipefail\n%s\n' "$code" > "$PUBLICATION_SCRIPT"
"$STATE" --state-dir "$TMP_ROOT/state" set KEN-3231 pr_order push-first-returned >/dev/null
printf 'true\n' > "$DRAFT_FILE"
printf 'current-head\n' > "$HEAD_FILE"
RUN_ENV=(HEAD_READ_FAIL_AFTER_READY=true)
run_action "$PUBLICATION_SCRIPT" 0
assert_eq "$RC|$REQUESTS|$(cat "$DRAFT_FILE")|$("$STATE" --state-dir "$TMP_ROOT/state" get KEN-3231 '.pr_approval.copilot_rerequest_head // empty')" \
  '2|0|false|' 'a failed read after ready leaves an unrecorded ready head' "$ERR"
RUN_ENV=()
run_action "$PUBLICATION_SCRIPT" 0
assert_eq "$RC|$(cat "$OUT")|$REQUESTS|$(cat "$TRANSITION_LOG")" '0|approval|1|request head=current-head draft=false' \
  'submit retries the already ready head through the real request owner' "$ERR"
"$STATE" --state-dir "$TMP_ROOT/state" update KEN-3231 '.pr_approval.copilot_rerequest_head = "current-head"' >/dev/null
"$STATE" --state-dir "$TMP_ROOT/state" set KEN-3231 pr_order push-first-pushed >/dev/null
run_action "$PUBLICATION_SCRIPT" 0
assert_eq "$RC|$REQUESTS|$(cat "$TRANSITION_LOG")" '0|0|' 'submit skips the recorded request head' "$ERR"
cp "$PUBLICATION_SCRIPT" "$TMP_ROOT/publication-mutant.sh"
mutate_file "$TMP_ROOT/publication-mutant.sh" 'if [[ "$COPILOT_REQUESTED_HEAD" != "current-head" ]]; then' 'if true; then'
run_action "$TMP_ROOT/publication-mutant.sh" 0
assert_eq "$REQUESTS" 1 'control: ignoring the request record duplicates the ready head request' "$ERR"
# GitHub produces queued/running checks, timeline-only requests and submitted
# head reviews. approval is the request answer consumed by submit-pr and the
# review workflow; stderr records the cause and head for the caller's log.
CHECK_ACTIVE='[{"check_runs":[{"name":"copilot-pull-request-reviewer","status":"in_progress","id":7,"started_at":null}]}]'
TIMELINE_PENDING='[[{"event":"review_requested","id":8,"created_at":"2026-10-10T07:04:13Z","requested_reviewer":{"login":"copilot-pull-request-reviewer[bot]"}}]]'
HEAD_REVIEW='[{"user":{"login":"copilot-pull-request-reviewer[bot]"},"commit_id":"current-head","state":"APPROVED","body":"Reviewed."}]'
ERROR_REVIEW='[{"user":{"login":"copilot-pull-request-reviewer[bot]"},"commit_id":"current-head","state":"COMMENTED","body":"Copilot encountered an error and was unable to review this pull request."}]'
# Execute the completion commands delivered to the cloud session. Its base
# checkout carries enforcing policy while the item tree tries to turn it off.
CLOUD_ORIGIN="$TMP_ROOT/cloud-origin"
ACTION_CWD="$TMP_ROOT/cloud"
git init -q "$CLOUD_ORIGIN"
git -C "$CLOUD_ORIGIN" config gc.auto 0
git -C "$CLOUD_ORIGIN" config maintenance.auto false
git -C "$CLOUD_ORIGIN" config user.email test@example.com
git -C "$CLOUD_ORIGIN" config user.name test
git -C "$CLOUD_ORIGIN" checkout -q -b main
cp -R "$BASE/.agents" "$CLOUD_ORIGIN/.agents"
write_settings "$CLOUD_ORIGIN/kendex.settings.toml" '"enforce"' ''
git -C "$CLOUD_ORIGIN" add .
git -C "$CLOUD_ORIGIN" commit -qm base
git clone -q "$CLOUD_ORIGIN" "$ACTION_CWD"
git -C "$ACTION_CWD" config gc.auto 0
git -C "$ACTION_CWD" config maintenance.auto false
git -C "$ACTION_CWD" checkout -q -b item
write_settings "$ACTION_CWD/kendex.settings.toml" '"off"' ''
mkdir -p "$ACTION_CWD/tmp"
cloud_script() { # LIB [ERREXIT]
  local words block
  words="$(env -i PATH="$PATH" "$BASH" -uc 'source "$1"; printf "%s" "$LAUNCH_SESSION_TEXT"' _ "$1")"
  block="$(awk '/^\($/ || /^git fetch origin \[BASE\]$/ {take=1} take {print} take && (/^\)$/ || /^git worktree remove tmp\/review-base$/) {exit}' <<<"$words")"
  block="${block//.agents\/skills\/orch\/scripts\/approval-wait/$RUN}"
  block="${block//\[PR_NUMBER\]/42}"
  block="${block//\[BASE\]/main}"
  printf 'set -uo pipefail\n%s\n%s\n' "${2:+set -e}" "${block:-:}" > "$TMP_ROOT/cloud-complete.sh"
}
for row in \
  'cloud marks ready|strict|true|0|0|false|0|1|ready,request head=current-head draft=false|0' \
  'person already marked ready|strict|false|0|0|false|0|1|request head=current-head draft=false|0' \
  'authentication failure with errexit|strict|true|1|0|false|3|0||0' \
  'authentication failure without errexit||true|1|0|false|3|0||0' \
  'ready failure with errexit|strict|true|0|8|false|2|0|ready|0' \
  'ready failure without errexit||true|0|8|false|2|0|ready|0' \
  'cleanup failure with errexit|strict|true|0|0|true|128|1|ready,request head=current-head draft=false|128' \
  'cleanup failure without errexit||true|0|0|true|128|1|ready,request head=current-head draft=false|128' \
  'request and cleanup failure with errexit|strict|true|0|8|true|2|0|ready|128' \
  'request and cleanup failure without errexit||true|0|8|true|2|0|ready|128'; do
  IFS='|' read -r label errexit draft auth_exit ready_exit dirty want_rc requests transitions cleanup_exit <<<"$row"
  cloud_script "$REPO_ROOT/skills/orch/scripts/lib/lane-launch.sh" "$errexit"
  printf '%s\n' "$draft" > "$DRAFT_FILE"
  printf 'current-head\n' > "$HEAD_FILE"
  RUN_ENV=("AUTH_EXIT=$auth_exit" "READY_EXIT=$ready_exit" "CLOUD_DIRTY_BASE=$dirty")
  run_action "$TMP_ROOT/cloud-complete.sh" 0
  assert_eq "$RC|$REQUESTS|$(paste -sd, "$TRANSITION_LOG")|$(cat "$EXECUTION_LOG")" "$want_rc|$requests|$transitions|" "$label preserves the request result" "$ERR"
  if [[ "$cleanup_exit" == 0 ]]; then
    assert_not_contains "$(git -C "$ACTION_CWD" worktree list --porcelain)" 'tmp/review-base' "$label removes its temporary base checkout"
  else
    assert_contains "$(cat "$ERR")" "cloud-completion: base-cleanup-failed exit=$cleanup_exit" "$label reports cleanup failure separately"
    assert_contains "$(git -C "$ACTION_CWD" worktree list --porcelain)" 'tmp/review-base' "$label retains the checkout Git refused to remove"
  fi
  [[ ! -d "$ACTION_CWD/tmp/review-base" ]] || git -C "$ACTION_CWD" worktree remove --force tmp/review-base
done
RUN_ENV=()
# The emitted commands own cleanup and preserve its two independent results.
# Each control changes a disposable source copy and runs the real request owner.
for row in \
  'cloud-request-cleanup|cloud_request_status=$?|exit "$?" # cloud_request_status=$?|strict|1|false|3|yes|no' \
  'cloud-request-result|exit "$cloud_request_status"|exit "$cloud_cleanup_status"||1|false|0|no|no' \
  'cloud-cleanup-report|  printf "%s\n" "cloud-completion: base-cleanup-failed exit=$cloud_cleanup_status" >&2|  : # printf "%s\n" "cloud-completion: base-cleanup-failed exit=$cloud_cleanup_status" >&2|strict|0|true|128|yes|no'; do
  IFS='|' read -r label old new errexit auth_exit dirty want_rc registered diagnostic <<<"$row"
  scripts="$(mutant_scripts "$label" lib/lane-launch.sh)" || exit 1
  mutate_file "$scripts/lib/lane-launch.sh" "$old" "$new"
  cloud_script "$scripts/lib/lane-launch.sh" "$errexit"
  printf 'true\n' > "$DRAFT_FILE"
  printf 'current-head\n' > "$HEAD_FILE"
  RUN_ENV=("AUTH_EXIT=$auth_exit" "CLOUD_DIRTY_BASE=$dirty")
  run_action "$TMP_ROOT/cloud-complete.sh" 0
  actual_registered=no
  [[ ! -d "$ACTION_CWD/tmp/review-base" ]] || actual_registered=yes
  actual_diagnostic=no
  [[ "$(cat "$ERR")" != *'cloud-completion: base-cleanup-failed'* ]] || actual_diagnostic=yes
  assert_eq "$RC|$actual_registered|$actual_diagnostic" "$want_rc|$registered|$diagnostic" "$label control breaks its failure handling" "$ERR"
  [[ "$actual_registered" == no ]] || git -C "$ACTION_CWD" worktree remove --force tmp/review-base
done
RUN_ENV=()
for row in \
  'cloud-ready|--request-review --mark-ready|--request-review|true' \
  'cloud-policy|--base-checkout tmp/review-base|--base-checkout .|false'; do
  IFS='|' read -r label old new draft <<<"$row"
  scripts="$(mutant_scripts "$label" lib/lane-launch.sh)" || exit 1
  mutate_file "$scripts/lib/lane-launch.sh" "$old" "$new"
  cloud_script "$scripts/lib/lane-launch.sh"
  printf 'true\n' > "$DRAFT_FILE"
  run_action "$TMP_ROOT/cloud-complete.sh" 0
  assert_eq "$RC|$REQUESTS|$(cat "$DRAFT_FILE")" "0|0|$draft" "$label control breaks the completion request" "$ERR"
done
unset ACTION_CWD
rm -- "$DRAFT_FILE" "$HEAD_FILE"
# A cloud session outside orch can leave a ready PR with only the skipped
# request run from its draft opening. Execute the landing workflow's commands.
landing_script() { # DOC [REQUEST SCRIPTS]
  local block scripts="${2:-$REPO_ROOT/skills/orch/scripts}"
  block="$(awk '
    /^[[:space:]]*```bash/ {inside=1; block=""; next}
    /^[[:space:]]*```/ && inside {
      if (index(block, "MERGE_PR_OPEN_READY=")) {printf "%s", block; exit}
      inside=0
    }
    inside && /github.sh pr-merge \[PR_NUMBER\] --check/ {exit}
    inside {block=block $0 ORS}
  ' "$1")"
  block="${block//.agents\/skills\/orch\/scripts\//$scripts/}"
  block="${block//\[PR_NUMBER\]/42}"
  block="${block//\[STATE_KEY\]/KEN-landing}"
  block="${block//\[REVIEW_BASE_CHECKOUT\]/\"\$REVIEW_BASE_FIXTURE\"}"
  printf 'set -euo pipefail\n%s\n' "${block:-:}" > "$TMP_ROOT/landing.sh"
}
SKIPPED_REQUEST='[{"check_runs":[{"id":9,"name":"Request Copilot review","status":"completed","conclusion":"skipped","started_at":"2026-10-11T07:25:19Z"}]}]'
"$STATE" --state-dir "$TMP_ROOT/state" init KEN-landing --worktree "$TMP_ROOT/catalog" >/dev/null
landing_script "$REPO_ROOT/skills/orch/workflows/merge-pr.md"
for row in \
  "ready cloud PR with skipped opening run|OPEN|false|$SKIPPED_REQUEST|[]|false|0|1" \
  "ready cloud PR with active Copilot work|OPEN|false|$CHECK_ACTIVE|[]|false|0|0" \
  "ready cloud PR with a Copilot review|OPEN|false|$SKIPPED_REQUEST|$HEAD_REVIEW|false|0|0" \
  "ready cloud PR with a human approval|OPEN|false|$SKIPPED_REQUEST|${HEAD_REVIEW/copilot-pull-request-reviewer\[bot\]/colleague}|false|0|1" \
  "draft cloud PR|OPEN|true|$SKIPPED_REQUEST|[]|false|0|0" \
  "closed cloud PR|CLOSED|false|$SKIPPED_REQUEST|[]|false|0|0" \
  "merged cloud PR|MERGED|false|$SKIPPED_REQUEST|[]|false|0|0" \
  "unreadable cloud PR|OPEN|false|$SKIPPED_REQUEST|[]|true|1|0"; do
  IFS='|' read -r label state draft checks reviews unread want_rc requests <<<"$row"
  printf '%s\n' "$draft" > "$DRAFT_FILE"
  printf 'current-head\n' > "$HEAD_FILE"
  RUN_ENV=("PR_STATE=$state" "CHECKS_JSON=$checks" "REVIEWS_JSON=$reviews" "HEAD_READ_FAIL=$unread")
  run_action "$TMP_ROOT/landing.sh" 0
  assert_eq "$RC|$REQUESTS" "$want_rc|$requests" "$label requests before landing waits" "$ERR"
done
RUN_ENV=()
# The error wait writes this record before requesting and retains it after
# retry or fallback. A landing restart must not restart that finished route.
for row in \
  'current-head|requested|0' \
  'current-head|fallback|0' \
  'earlier-head|requested|1' \
  'earlier-head|fallback|1'; do
  IFS='|' read -r saved_head outcome requests <<<"$row"
  "$STATE" --state-dir "$TMP_ROOT/state" update KEN-landing --arg head "$saved_head" --arg outcome "$outcome" \
    '.pr_approval.copilot_error_retries = {($head): {review_id: "10", outcome: $outcome}}' >/dev/null
  saved="$("$STATE" --state-dir "$TMP_ROOT/state" get KEN-landing '.pr_approval.copilot_error_retries')"
  RUN_ENV=("CHECKS_JSON=$SKIPPED_REQUEST" "REVIEWS_JSON=$ERROR_REVIEW ${HEAD_REVIEW/copilot-pull-request-reviewer\[bot\]/colleague}")
  for pass_number in first repeated; do
    run_action "$TMP_ROOT/landing.sh" 0
    assert_eq "$RC|$REQUESTS" "0|$requests" "$pass_number landing preserves $outcome at $saved_head" "$ERR"
    assert_eq "$("$STATE" --state-dir "$TMP_ROOT/state" get KEN-landing '.pr_approval.copilot_error_retries')" "$saved" \
      "$pass_number landing preserves its saved error outcome" "$ERR"
  done
done
"$STATE" --state-dir "$TMP_ROOT/state" update KEN-landing 'del(.pr_approval.copilot_error_retries)' >/dev/null
RUN_ENV=()
run_action "$RUN" 0 --request-review --item KEN-missing-state --base-checkout "$BASE"
assert_eq "$RC|$REQUESTS|$(cat "$OUT")" '2|0|' 'a request cannot ignore unreadable item state' "$ERR"
scripts="$(mutant_scripts request-error-outcome approval-wait)" || exit 1
# shellcheck disable=SC2016
mutate_file "$scripts/approval-wait" '    if [[ -n "$ITEM" ]] && ! $retry_claimed; then' \
  '    if false && [[ -n "$ITEM" ]] && ! $retry_claimed; then'
landing_script "$REPO_ROOT/skills/orch/workflows/merge-pr.md" "$scripts"
for outcome in requested fallback; do
  "$STATE" --state-dir "$TMP_ROOT/state" update KEN-landing --arg outcome "$outcome" \
    '.pr_approval.copilot_error_retries = {"current-head": {review_id: "10", outcome: $outcome}}' >/dev/null
  RUN_ENV=("CHECKS_JSON=$SKIPPED_REQUEST" "REVIEWS_JSON=$ERROR_REVIEW")
  run_action "$TMP_ROOT/landing.sh" 0
  assert_eq "$RC|$REQUESTS" '0|1' "control: ignoring $outcome repeats the finished error request" "$ERR"
done
"$STATE" --state-dir "$TMP_ROOT/state" update KEN-landing 'del(.pr_approval.copilot_error_retries)' >/dev/null
RUN_ENV=()
scripts="$(mutant_scripts request-error-state-read approval-wait)" || exit 1
# shellcheck disable=SC2016
mutate_file "$scripts/approval-wait" 'get "$ITEM" '\''.pr_approval.copilot_error_retries // {}'\'')' \
  'get "$ITEM" '\''.pr_approval.copilot_error_retries // {}'\'' || printf '\''{}\n'\'')'
run_action "$scripts/approval-wait" 0 --request-review --item KEN-missing-state --base-checkout "$BASE"
assert_eq "$RC|$REQUESTS" '0|1' 'control: substituting empty state requests without reading its item' "$ERR"
cp "$REPO_ROOT/skills/orch/workflows/merge-pr.md" "$TMP_ROOT/landing-mutant.md"
mutate_file "$TMP_ROOT/landing-mutant.md" 'if [[ "$MERGE_PR_OPEN_READY" == true ]]; then' 'if false && [[ "$MERGE_PR_OPEN_READY" == true ]]; then'
landing_script "$TMP_ROOT/landing-mutant.md"
printf 'false\n' > "$DRAFT_FILE"
RUN_ENV=("CHECKS_JSON=$SKIPPED_REQUEST")
run_action "$TMP_ROOT/landing.sh" 0
assert_eq "$RC|$REQUESTS" '0|0' 'control: bypassing the landing request breaks the skipped opening row' "$ERR"
RUN_ENV=()
rm -- "$DRAFT_FILE" "$HEAD_FILE"
# GitHub dismisses the previous review when another Copilot request starts.
DISMISSED_THEN_ERROR="${HEAD_REVIEW/APPROVED/DISMISSED}"$'\n'"$ERROR_REVIEW"
scripts="$(mutant_scripts request-head-work approval-wait)" || exit 1
mutate_file "$scripts/approval-wait" '    request_runs=$(orch_copilot_check_runs' $'    if false; then\n    request_runs=$(orch_copilot_check_runs'
mutate_file "$scripts/approval-wait" $'    fi\n    request_rc=0' $'    fi\n    fi\n    request_rc=0'
# Columns: label~checks~timeline~reviews~failure env~rc~requests~cause
for row in \
  "running check~$CHECK_ACTIVE~[[]]~[]~~0~0~existing-run" \
  "queued check~${CHECK_ACTIVE/in_progress/queued}~[[]]~[]~~0~0~existing-run" \
  "pending timeline request~[{\"check_runs\":[]}]~$TIMELINE_PENDING~[]~~0~0~existing-run" \
  "approved head review~[{\"check_runs\":[]}]~[[]]~$HEAD_REVIEW~~0~0~existing-review" \
  "commented head review~[{\"check_runs\":[]}]~[[]]~${HEAD_REVIEW/APPROVED/COMMENTED}~~0~0~existing-review" \
  "changes requested head review~[{\"check_runs\":[]}]~[[]]~${HEAD_REVIEW/APPROVED/CHANGES_REQUESTED}~~0~0~existing-review" \
  "dismissed head review~[{\"check_runs\":[]}]~[[]]~${HEAD_REVIEW/APPROVED/DISMISSED}~~0~0~existing-review" \
  "completed human head review~[{\"check_runs\":[]}]~[[]]~${HEAD_REVIEW/copilot-pull-request-reviewer\[bot\]/colleague}~~0~1~" \
  "earlier head review~[{\"check_runs\":[]}]~[[]]~${HEAD_REVIEW/current-head/earlier-head}~~0~1~" \
  "error head review~[{\"check_runs\":[]}]~[[]]~$ERROR_REVIEW~~0~1~" \
  "dismissed error review~[{\"check_runs\":[]}]~[[]]~${ERROR_REVIEW/COMMENTED/DISMISSED}~~0~1~" \
  "dismissed success then error~[{\"check_runs\":[]}]~[[]]~${DISMISSED_THEN_ERROR//$'\n'/ }~~0~1~" \
  "error then completed review~[{\"check_runs\":[]}]~[[]]~$ERROR_REVIEW $HEAD_REVIEW~~0~0~existing-review" \
  "active work beside the latest error~$CHECK_ACTIVE~[[]]~${DISMISSED_THEN_ERROR//$'\n'/ }~~0~0~existing-run" \
  'no Copilot work~[{"check_runs":[]}]~[[]]~[]~~0~1~' \
  'failed check read~[{"check_runs":[]}]~[[]]~[]~CHECKS_FAIL=true~2~0~request-checks-unreadable' \
  'failed reviews read~[{"check_runs":[]}]~[[]]~[]~REVIEWS_FAIL=true~2~0~request-reviews-unreadable' \
  'failed timeline read~[{"check_runs":[]}]~[[]]~[]~TIMELINE_FAIL=true~2~0~request-checks-unreadable' \
  "failed reviews read with active work~$CHECK_ACTIVE~[[]]~[]~REVIEWS_FAIL=true~2~0~request-reviews-unreadable"; do
  IFS='~' read -r label checks timeline reviews failure want_rc want_requests cause <<<"$row"
  RUN_ENV=("CHECKS_JSON=$checks" "TIMELINE_JSON=$timeline" "REVIEWS_JSON=$reviews")
  [[ -z "$failure" ]] || RUN_ENV+=("$failure")
  run_action "$RUN" 0 --request-review --base-checkout "$BASE"
  want_out=approval
  [[ "$want_rc" == 0 ]] || want_out=''
  assert_eq "$RC|$(cat "$OUT")|$REQUESTS" "$want_rc|$want_out|$want_requests" "$label" "$ERR"
  [[ -z "$cause" ]] || assert_eq "$(cat "$ERR")" "approval-wait: $cause head=current-head" "$label cause and head" "$ERR"
  [[ "$label" != 'completed human head review' ]] || assert_not_contains "$(cat "$ERR")" \
    'approval-wait: existing-review ' "$label keeps the Copilot request" "$ERR"
  if [[ "$cause" == existing-* ]]; then
    run_action "$scripts/approval-wait" 0 --request-review --base-checkout "$BASE"
    assert_eq "$RC|$(cat "$OUT")|$REQUESTS" '0|approval|1' "$label control reaches the duplicate request" "$ERR"
  fi
done
# Each exception and failed source keeps its own control. All use the real
# request owner with private defects; the stub supplies only GitHub evidence.
for row in \
  'earlier-head~| map(select(.user.login == $reviewer and .commit_id == $head~| map(select(.user.login == $reviewer~earlier~0|approval|0' \
  'error-review~then false else any(.[];~then true else any(.[];~error~0|approval|0' \
  'latest-error~if $latest.state == "COMMENTED" and~if false and $latest.state == "COMMENTED" and~mixed~0|approval|0' \
  'reviewer-identity~| map(select(.user.login == $reviewer and~| map(select((.user.login == $reviewer or true) and~human~0|approval|0' \
  'checks-failure~request_runs=$(orch_copilot_check_runs "$REPO" "$request_head" "$PR_NUM" 2>"$GH_ERR_FILE")~request_runs=$(orch_copilot_check_runs "$REPO" "$request_head" "$PR_NUM" 2>"$GH_ERR_FILE") || request_runs="[]"~checks~0|approval|1' \
  'reviews-failure~request_reviews=$(gh api "repos/$REPO/pulls/$PR_NUM/reviews" --paginate 2>"$GH_ERR_FILE")~request_reviews=$(gh api "repos/$REPO/pulls/$PR_NUM/reviews" --paginate 2>"$GH_ERR_FILE") || request_reviews="[]"~reviews~0|approval|1'; do
  IFS='~' read -r label old new fixture want <<<"$row"
  scripts="$(mutant_scripts "$label-work" approval-wait)" || exit 1
  mutate_file "$scripts/approval-wait" "$old" "$new"
  case "$fixture" in
    earlier) RUN_ENV=("REVIEWS_JSON=${HEAD_REVIEW/current-head/earlier-head}") ;;
    error) RUN_ENV=("REVIEWS_JSON=$ERROR_REVIEW") ;;
    mixed) RUN_ENV=("REVIEWS_JSON=$DISMISSED_THEN_ERROR") ;;
    human) RUN_ENV=("REVIEWS_JSON=${HEAD_REVIEW/copilot-pull-request-reviewer\[bot\]/colleague}") ;;
    checks) RUN_ENV=(CHECKS_FAIL=true) ;;
    reviews) RUN_ENV=(REVIEWS_FAIL=true) ;;
  esac
  run_action "$scripts/approval-wait" 0 --request-review --base-checkout "$BASE"
  assert_eq "$RC|$(cat "$OUT")|$REQUESTS" "$want" "$label control breaks its request rule" "$ERR"
done
RUN_ENV=()
# Controls retain the matched behavior text, so each guard's reachable defect
# changes its own observation rather than merely removing an assertion.
scripts="$(mutant_scripts draft-request approval-wait)" || exit 1
mutate_file "$scripts/approval-wait" $'if [[ "$request_draft" == true ]]; then\n        printf' $'if false; then\n        printf'
printf 'true\n' > "$DRAFT_FILE"
run_action "$scripts/approval-wait" 0 --request-review --base-checkout "$BASE"
assert_eq "$REQUESTS" 1 'control: a draft bypass breaks the no-draft-request row' "$ERR"
scripts="$(mutant_scripts ready-head approval-wait)" || exit 1
mutate_file "$scripts/approval-wait" '&& "$request_head" == "$ready_head"' '&& true'
printf 'true\n' > "$DRAFT_FILE"
RUN_ENV=(MOVE_READY_HEAD=true)
run_action "$scripts/approval-wait" 0 --request-review --mark-ready --base-checkout "$BASE"
assert_eq "$REQUESTS" 1 'control: ignoring the moved head breaks the head-confirmation row' "$ERR"
RUN_ENV=()
scripts="$(mutant_scripts ready-recovery approval-wait)" || exit 1
mutate_file "$scripts/approval-wait" 'if $MARK_READY; then' $'if $MARK_READY; then\n    read_request_head || exit 2\n    if [[ "$request_draft" == false ]]; then printf "approval\\n"; exit 0; fi'
printf 'false\n' > "$DRAFT_FILE"
run_action "$scripts/approval-wait" 0 --request-review --mark-ready --base-checkout "$BASE"
assert_eq "$REQUESTS" 0 'control: treating ready as requested breaks recovery' "$ERR"
write_settings "$BASE/kendex.settings.toml" '"enforce"' '' 'REVIEW_GATE_REFRESH_REVIEW = "junk"'
printf 'true\n' > "$DRAFT_FILE"
run_action "$RUN" 0 --request-review --mark-ready --base-checkout "$BASE"
assert_eq "$RC|$REQUESTS|$(cat "$DRAFT_FILE")|$(cat "$TRANSITION_LOG")" '2|0|true|' \
  'an unreadable refresh policy refuses before the ready transition' "$ERR"
scripts="$(mutant_scripts ready-policy approval-wait)" || exit 1
mutate_file "$scripts/approval-wait" '[[ "$refresh_rc" -le 1 ]] || exit 2' '[[ "$refresh_rc" -le 1 ]] || :'
run_action "$scripts/approval-wait" 0 --request-review --mark-ready --base-checkout "$BASE"
assert_eq "$(cat "$DRAFT_FILE")" false 'control: ignoring the refresh failure crosses the ready transition' "$ERR"
write_settings "$BASE/kendex.settings.toml" '"enforce"' ''
rm -f -- "${DRAFT_FILE:?}" "${HEAD_FILE:?}"

# Columns: label~consumer gate~caller PR_COPILOT_REQUESTS~base PR_COPILOT_REQUESTS~request exit~old~new~rc~stdout~requests~action (default --request-review)
for row in \
  'off-gate~"off"~~~0~if $REQUEST_REVIEW && [[ "$answer" == approval ]]; then~if $REQUEST_REVIEW && [[ "$answer" == approval || "$GATE_MODE" == off ]]; then~0~off~0' \
  'settings-failure~["off"]~~~0~policy=$(rg_setting REVIEW_GATE_MODE enforce) || return $?~policy=$(rg_setting REVIEW_GATE_MODE enforce) || policy=enforce~2~~0~--resolve-mode' \
  'unknown-policy~"junk"~~~0~*) approval_message policy-mode-invalid >&2; return 1 ;;~*) approval_message policy-mode-invalid >&2; return 0 ;;~2~~0' \
  'base-directory~"off"~~~0~  cd -- "$BASE_CHECKOUT"~  : # cd -- "$BASE_CHECKOUT"~0~off~0' \
  'stacked-base-execution~"enforce"~~~0~  policy=$(rg_setting REVIEW_GATE_MODE enforce)~  "$BASE_CHECKOUT/.agents/skills/orch/scripts/approval-wait" "$PR_NUM" --resolve-mode >&2; policy=$(rg_setting REVIEW_GATE_MODE enforce)~0~approval~1' \
  'stdout-isolation~"enforce"~~~0~-f "reviewers[]=${COPILOT_REVIEWER}[bot]" >&2~-f "reviewers[]=${COPILOT_REVIEWER}[bot]"~0~approval~1' \
  'copilot-off~"enforce"~off~~0~    elif [[ "$COPILOT_REQUESTS" == off ]]; then~    elif false; then~0~fallback cause=off~0' \
  'refused-request~"enforce"~~~8~-f "reviewers[]=${COPILOT_REVIEWER}[bot]" >&2 || request_rc=$?~-f "reviewers[]=${COPILOT_REVIEWER}[bot]" >&2 || exit $?~0~fallback cause=refused exit=8~1' \
  'caller-setting~"enforce"~~off~0~COPILOT_REQUESTS="$("$SCRIPT_DIR/orch-env" PR_COPILOT_REQUESTS on)" || return 2~COPILOT_REQUESTS="$(cd -- "$BASE_CHECKOUT" && "$SCRIPT_DIR/orch-env" PR_COPILOT_REQUESTS on)" || return 2~0~approval~1' \
  'copilot-setting-invalid~"enforce"~junk~~0~*) approval_message copilot-requests-invalid >&2; return 2 ;;~*) ;;~2~~0' \
  'copilot-setting-unreadable~"enforce"~\"off~~0~PR_COPILOT_REQUESTS on)" || return 2~PR_COPILOT_REQUESTS on)" || COPILOT_REQUESTS=on~2~~0' \
  'copilot-setting-at-resolution~"enforce"~junk~~0~if $REQUEST_REVIEW || [[ -n "$ITEM" ]]; then~if true; then~0~approval~0~--resolve-mode'; do
  IFS='~' read -r label setting caller_copilot base_copilot request_exit old new want_rc want_out want_requests action <<< "$row"
  write_settings "$BASE/kendex.settings.toml" "$setting" "$base_copilot"
  write_settings "$TMP_ROOT/catalog/kendex.settings.toml" '"enforce"' "$caller_copilot"
  scripts="$(mutant_scripts "$label/orch" approval-wait)"
  ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/$label/github"
  ln -s "$REPO_ROOT/skills/review-gate" "$TMP_ROOT/$label/review-gate"
  mutate_file "$scripts/approval-wait" "$old" "$new"
  run_action "$scripts/approval-wait" "$request_exit" "${action:---request-review}" --base-checkout "$BASE"
  if [[ "$RC|$(cat "$OUT")|$REQUESTS|$(cat "$EXECUTION_LOG")" == "$want_rc|$want_out|$want_requests|" ]]; then
    fail "$label control did not turn its behavioral assertion red"
  else
    pass "$label control turns its behavioral assertion red"
  fi
done

# The consumer's declared refresh identity takes the overseer route with no
# Copilot request (KEN-3338); every other head and consumer keeps its route.
REFRESH_PULL='{"head":{"ref":"kendex/refresh"},"user":{"login":"lanes-app[bot]","type":"Bot"}}'
DECLARED='REVIEW_GATE_REFRESH_REVIEW = "overseer";REVIEW_GATE_REFRESH_BRANCH = "kendex/refresh";REVIEW_GATE_REFRESH_AUTHOR = "lanes-app[bot]"'
refresh_case() { # GATE CALLER_COPILOT BASE_REFRESH PULL [ENV...]
  write_settings "$BASE/kendex.settings.toml" "$1" '' "$3"
  write_settings "$TMP_ROOT/catalog/kendex.settings.toml" '"enforce"' "$2"
  PULL_JSON="$4"
  shift 4
  RUN_ENV=("$@")
}
# Columns: label~consumer gate~caller PR_COPILOT_REQUESTS~base refresh lines~pull~caller env~rc~stdout~requests
for row in \
  "declared refresh head~\"enforce\"~~$DECLARED~$REFRESH_PULL~~0~fallback cause=refresh~0" \
  "declared refresh head with Copilot requests off~\"enforce\"~off~$DECLARED~$REFRESH_PULL~~0~fallback cause=refresh~0" \
  "declared refresh head on an off gate~\"off\"~~$DECLARED~$REFRESH_PULL~~0~off~0" \
  "ordinary head under the refresh policy~\"enforce\"~~$DECLARED~$ORDINARY_PULL~~0~approval~1" \
  "refresh branch from another author~\"enforce\"~~$DECLARED~${REFRESH_PULL/lanes-app/another}~~0~approval~1" \
  "refresh author as a user~\"enforce\"~~$DECLARED~${REFRESH_PULL/\"Bot\"/\"User\"}~~0~approval~1" \
  "refresh author on another branch~\"enforce\"~~$DECLARED~${REFRESH_PULL/kendex\/refresh/kendex\/refresh-extra}~~0~approval~1" \
  "consumer without the refresh policy~\"enforce\"~~~$REFRESH_PULL~~0~approval~1" \
  "consumer keeping the Copilot route~\"enforce\"~~${DECLARED/overseer/copilot}~$REFRESH_PULL~~0~approval~1" \
  "caller environment cannot declare the consumer route~\"enforce\"~~~$REFRESH_PULL~REVIEW_GATE_REFRESH_REVIEW=overseer~0~approval~1" \
  "unknown refresh route~\"enforce\"~~${DECLARED/overseer/junk}~$REFRESH_PULL~~2~~0" \
  "overseer route without a branch~\"enforce\"~~${DECLARED/kendex\/refresh/}~$REFRESH_PULL~~2~~0" \
  "overseer route without an author~\"enforce\"~~${DECLARED/lanes-app\[bot\]/}~$REFRESH_PULL~~2~~0" \
  "unreadable pull request~\"enforce\"~~$DECLARED~fail~~2~~0"; do
  IFS='~' read -r label setting caller_copilot base_refresh pull run_env want_rc want_out want_requests <<< "$row"
  refresh_case "$setting" "$caller_copilot" "$base_refresh" "$pull" ${run_env:+"$run_env"}
  run_action "$RUN" 0 --request-review --base-checkout "$BASE"
  assert_eq "$RC|$(cat "$OUT")|$REQUESTS" "$want_rc|$want_out|$want_requests" "$label" "$ERR"
done
# Columns: label~base refresh lines~pull~caller env~old~new~rc~stdout~requests~mutant rc~mutant stdout~mutant requests
for row in \
  "refresh-route~$DECLARED~$REFRESH_PULL~~    if [[ \"\$refresh_rc\" -eq 0 ]]; then~    if false; then~0~fallback cause=refresh~0~0~approval~1" \
  "refresh-branch~$DECLARED~${REFRESH_PULL/kendex\/refresh/product}~~'.head.ref == \$branch and ~'~0~approval~1~0~fallback cause=refresh~0" \
  "refresh-author~$DECLARED~${REFRESH_PULL/lanes-app/another}~~ and .user.login == \$author~~0~approval~1~0~fallback cause=refresh~0" \
  "refresh-type~$DECLARED~${REFRESH_PULL/\"Bot\"/\"User\"}~~ and .user.type == \"Bot\"'~'~0~approval~1~0~fallback cause=refresh~0" \
  "refresh-caller-env~~$REFRESH_PULL~REVIEW_GATE_REFRESH_REVIEW=overseer;REVIEW_GATE_REFRESH_BRANCH=kendex/refresh;REVIEW_GATE_REFRESH_AUTHOR=lanes-app[bot]~  unset REVIEW_GATE_REFRESH_REVIEW REVIEW_GATE_REFRESH_BRANCH REVIEW_GATE_REFRESH_AUTHOR~  :~0~approval~1~0~fallback cause=refresh~0" \
  "refresh-identity-unset~${DECLARED/kendex\/refresh/}~$REFRESH_PULL~~  if [[ -z \"\$refresh_branch\" || -z \"\$refresh_author\" ]]; then~  if [[ -z \"\$refresh_branch\" || -z \"\$refresh_author\" ]] && false; then~2~~0~0~approval~1"; do
  IFS='~' read -r label base_refresh pull run_env old new want_rc want_out want_requests mutant_rc mutant_out mutant_requests <<< "$row"
  IFS=';' read -r -a env_items <<< "$run_env"
  refresh_case '"enforce"' '' "$base_refresh" "$pull" ${env_items[@]+"${env_items[@]}"}
  scripts="$(mutant_scripts "$label/orch" approval-wait)"
  ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/$label/github"
  ln -s "$REPO_ROOT/skills/review-gate" "$TMP_ROOT/$label/review-gate"
  mutate_file "$scripts/approval-wait" "$old" "$new"
  run_action "$scripts/approval-wait" 0 --request-review --base-checkout "$BASE"
  assert_eq "$RC|$(cat "$OUT")|$REQUESTS" "$mutant_rc|$mutant_out|$mutant_requests" "$label control reaches its changed behavior" "$ERR"
  if [[ "$RC|$(cat "$OUT")|$REQUESTS" == "$want_rc|$want_out|$want_requests" ]]; then
    fail "$label control did not turn its behavioral assertion red"
  else
    pass "$label control turns its behavioral assertion red"
  fi
done

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
