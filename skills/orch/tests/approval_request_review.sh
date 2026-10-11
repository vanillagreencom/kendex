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
  'auth status'|'api user') exit 0 ;;
  'repo view') echo consumer/repo ;;
  'pr view')
    printf '%s\n' "$PWD|$*" >> "$QUERY_LOG"
    if [[ "$*" == *'--json state,isDraft,headRefOid'* ]]; then
      [[ "${HEAD_READ_FAIL:-false}" != true ]] || exit 1
      [[ "${HEAD_READ_FAIL_AFTER_READY:-false}" != true || ! -s "$TRANSITION_LOG" ]] || exit 1
      draft=false
      [[ ! -f "$DRAFT_FILE" ]] || draft="$(cat "$DRAFT_FILE")"
      head=current-head
      [[ ! -f "$HEAD_FILE" ]] || head="$(cat "$HEAD_FILE")"
      jq -cn --argjson draft "$draft" --arg head "$head" '{state:"OPEN",isDraft:$draft,headRefOid:$head}'
    else
      echo '{"baseRefName":"feature/base","reviewDecision":"REVIEW_REQUIRED"}'
    fi
    ;;
  'pr ready')
    printf 'ready\n' >> "$TRANSITION_LOG"
    [[ "${READY_EXIT:-0}" == 0 ]] || exit "$READY_EXIT"
    printf 'false\n' > "$DRAFT_FILE"
    [[ "${MOVE_READY_HEAD:-false}" != true ]] || printf 'new-head\n' > "$HEAD_FILE"
    ;;
  'api repos/consumer/repo/rules/branches/feature%2Fbase')
    printf '%s\n' "$PWD|$*" >> "$QUERY_LOG"
    echo '[{"type":"pull_request","parameters":{"required_approving_review_count":1}}]'
    ;;
  'api repos/consumer/repo/pulls/42')
    [[ "$PULL_JSON" != fail ]] || exit 1
    printf '%s\n' "$PULL_JSON"
    ;;
  'pr edit')
    printf '%s\n' "$PWD|$*" >> "$REQUEST_LOG"
    printf 'request head=%s draft=%s\n' "$(cat "$HEAD_FILE" 2>/dev/null || echo current-head)" "$(cat "$DRAFT_FILE" 2>/dev/null || echo false)" >> "$TRANSITION_LOG"
    [[ "$REQUEST_EXIT" == 0 ]] || exit "$REQUEST_EXIT"
    echo 'https://github.com/consumer/repo/pull/42'
    ;;
  *) printf 'gh: unexpected argv=%s\n' "$*" >&2; exit 9 ;;
esac
EOF
chmod +x "$BASE/.agents/skills/orch/scripts/approval-wait" "$TMP_ROOT/bin/gh"
RUN="$REPO_ROOT/skills/orch/scripts/approval-wait"
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
  (cd -- "$TMP_ROOT/catalog" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT/home" \
    GH_TOKEN=github_pat_fixture GH_REPO=catalog/repo GITHUB_REPOSITORY=catalog/repo \
    REVIEW_GATE_MODE=enforce PR_REVIEW_GATE=review REVIEW_GATE_SETTINGS_FILE=/dev/null \
    QUERY_LOG="$QUERY_LOG" EXECUTION_LOG="$EXECUTION_LOG" REQUEST_LOG="$REQUEST_LOG" \
    DRAFT_FILE="$DRAFT_FILE" HEAD_FILE="$HEAD_FILE" TRANSITION_LOG="$TRANSITION_LOG" \
    ORCH_STATE_DIR="$TMP_ROOT/state" REVIEW_BASE_FIXTURE="$BASE" \
    REQUEST_EXIT="$request_exit" PULL_JSON="$PULL_JSON" ${RUN_ENV[@]+"${RUN_ENV[@]}"} \
    "$BASH" "$script" 42 "$@" > "$OUT" 2> "$ERR") || RC=$?
  REQUESTS="$(wc -l < "$REQUEST_LOG" | tr -d ' ')"
}

# Columns: label|action|consumer gate|caller PR_COPILOT_REQUESTS|base PR_COPILOT_REQUESTS|gh pr edit exit|rc|stdout|requests|stderr line the caller copies into its notice
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
assert_eq "$(cat "$REQUEST_LOG")" "$BASE|pr edit 42 --repo consumer/repo --add-reviewer @copilot" \
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
# The publication command supplies these arguments; run its real owner.
ready_doc_args() { # DOC
  local line field
  READY_ARGS=()
  line="$(awk '/^[[:space:]]*\*\*Push-first ready head/ {ready=1} ready && /^[[:space:]]*env .*approval-wait \[PR_NUMBER\] --request-review/ {print; exit}' "$1")"
  [[ -n "$line" ]] || return 1
  line="$(sed 's/^.*approval-wait \[PR_NUMBER\] //' <<<"$line")"
  for field in $line; do
    [[ "$field" != '[REVIEW_BASE_CHECKOUT]' ]] || field="$BASE"
    READY_ARGS+=("$field")
  done
}
READY_ARGS=()
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
mutate_file "$TMP_ROOT/submit-mutant.md" '--request-review --mark-ready --base-checkout' '--request-review --base-checkout'
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
STATE="$REPO_ROOT/skills/orch/scripts/workflow-state"
"$STATE" --state-dir "$TMP_ROOT/state" init KEN-3231 --worktree "$TMP_ROOT/catalog" >/dev/null
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
ln -s "$REPO_ROOT/skills/review-gate" "$TMP_ROOT/review-gate"
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/github"
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

# Columns: label~consumer gate~caller PR_COPILOT_REQUESTS~base PR_COPILOT_REQUESTS~gh pr edit exit~old~new~rc~stdout~requests~action (default --request-review)
for row in \
  'off-gate~"off"~~~0~if $REQUEST_REVIEW && [[ "$answer" == approval ]]; then~if $REQUEST_REVIEW && [[ "$answer" == approval || "$GATE_MODE" == off ]]; then~0~off~0' \
  'settings-failure~["off"]~~~0~policy=$(rg_setting REVIEW_GATE_MODE enforce) || return $?~policy=$(rg_setting REVIEW_GATE_MODE enforce) || policy=enforce~2~~0~--resolve-mode' \
  'unknown-policy~"junk"~~~0~*) approval_message policy-mode-invalid >&2; return 1 ;;~*) approval_message policy-mode-invalid >&2; return 0 ;;~2~~0' \
  'base-directory~"off"~~~0~  cd -- "$BASE_CHECKOUT"~  : # cd -- "$BASE_CHECKOUT"~0~off~0' \
  'stacked-base-execution~"enforce"~~~0~  policy=$(rg_setting REVIEW_GATE_MODE enforce)~  "$BASE_CHECKOUT/.agents/skills/orch/scripts/approval-wait" "$PR_NUM" --resolve-mode >&2; policy=$(rg_setting REVIEW_GATE_MODE enforce)~0~approval~1' \
  'stdout-isolation~"enforce"~~~0~gh pr edit "$PR_NUM" --repo "$REPO" --add-reviewer @copilot >&2~gh pr edit "$PR_NUM" --repo "$REPO" --add-reviewer @copilot~0~approval~1' \
  'copilot-off~"enforce"~off~~0~    elif [[ "$COPILOT_REQUESTS" == off ]]; then~    elif false; then~0~fallback cause=off~0' \
  'refused-request~"enforce"~~~8~--add-reviewer @copilot >&2 || request_rc=$?~--add-reviewer @copilot >&2 || exit $?~0~fallback cause=refused exit=8~1' \
  'caller-setting~"enforce"~~off~0~COPILOT_REQUESTS="$("$SCRIPT_DIR/orch-env" PR_COPILOT_REQUESTS on)" || exit 2~COPILOT_REQUESTS="$(cd -- "$BASE_CHECKOUT" && "$SCRIPT_DIR/orch-env" PR_COPILOT_REQUESTS on)" || exit 2~0~approval~1' \
  'copilot-setting-invalid~"enforce"~junk~~0~*) approval_message copilot-requests-invalid >&2; exit 2 ;;~*) ;;~2~~0' \
  'copilot-setting-unreadable~"enforce"~\"off~~0~PR_COPILOT_REQUESTS on)" || exit 2~PR_COPILOT_REQUESTS on)" || COPILOT_REQUESTS=on~2~~0' \
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
