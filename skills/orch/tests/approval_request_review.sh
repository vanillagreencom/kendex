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
    echo '{"baseRefName":"feature/base","reviewDecision":"REVIEW_REQUIRED"}'
    ;;
  'api repos/consumer/repo/rules/branches/feature%2Fbase')
    printf '%s\n' "$PWD|$*" >> "$QUERY_LOG"
    echo '[{"type":"pull_request","parameters":{"required_approving_review_count":1}}]'
    ;;
  'pr edit')
    printf '%s\n' "$PWD|$*" >> "$REQUEST_LOG"
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

# write_settings FILE GATE COPILOT: COPILOT empty leaves PR_COPILOT_REQUESTS unset.
write_settings() {
  printf '[env]\nREVIEW_GATE_MODE = %s\n' "$2" > "$1"
  [[ -z "$3" ]] || printf 'PR_COPILOT_REQUESTS = "%s"\n' "$3" >> "$1"
}

run_action() { # SCRIPT REQUEST_EXIT ARGS...
  local script="$1" request_exit="$2"
  shift 2
  : > "$REQUEST_LOG"
  : > "$QUERY_LOG"
  : > "$EXECUTION_LOG"
  RC=0
  (cd -- "$TMP_ROOT/catalog" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT/home" \
    GH_TOKEN=github_pat_fixture GH_REPO=catalog/repo GITHUB_REPOSITORY=catalog/repo \
    REVIEW_GATE_MODE=enforce PR_REVIEW_GATE=review REVIEW_GATE_SETTINGS_FILE=/dev/null \
    QUERY_LOG="$QUERY_LOG" EXECUTION_LOG="$EXECUTION_LOG" REQUEST_LOG="$REQUEST_LOG" \
    REQUEST_EXIT="$request_exit" \
    bash "$script" 42 "$@" > "$OUT" 2> "$ERR") || RC=$?
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
# Columns: label~consumer gate~caller PR_COPILOT_REQUESTS~base PR_COPILOT_REQUESTS~gh pr edit exit~old~new~rc~stdout~requests~action (default --request-review)
for row in \
  'off-gate~"off"~~~0~if $REQUEST_REVIEW && [[ "$GATE_MODE" == approval ]]; then~if $REQUEST_REVIEW && [[ "$GATE_MODE" == approval || "$GATE_MODE" == off ]]; then~0~off~0' \
  'settings-failure~["off"]~~~0~policy=$(rg_setting REVIEW_GATE_MODE enforce) || return $?~policy=$(rg_setting REVIEW_GATE_MODE enforce) || policy=enforce~2~~0' \
  'unknown-policy~"junk"~~~0~*) approval_message policy-mode-invalid >&2; return 1 ;;~*) approval_message policy-mode-invalid >&2; return 0 ;;~2~~0' \
  'base-directory~"off"~~~0~  cd -- "$BASE_CHECKOUT"~  : # cd -- "$BASE_CHECKOUT"~0~off~0' \
  'stacked-base-execution~"enforce"~~~0~  policy=$(rg_setting REVIEW_GATE_MODE enforce)~  "$BASE_CHECKOUT/.agents/skills/orch/scripts/approval-wait" "$PR_NUM" --resolve-mode >&2; policy=$(rg_setting REVIEW_GATE_MODE enforce)~0~approval~1' \
  'stdout-isolation~"enforce"~~~0~gh pr edit "$PR_NUM" --repo "$REPO" --add-reviewer @copilot >&2~gh pr edit "$PR_NUM" --repo "$REPO" --add-reviewer @copilot~0~approval~1' \
  'copilot-off~"enforce"~off~~0~    if [[ "$COPILOT_REQUESTS" == off ]]; then~    if false; then~0~fallback cause=off~0' \
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

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
