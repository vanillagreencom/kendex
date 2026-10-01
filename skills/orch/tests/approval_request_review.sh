#!/usr/bin/env bash
# Exercise the trusted request owner. Consumer code is an execution tripwire.
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
    [[ "$NATIVE_REPLY" != base-failed ]] || exit 7
    printf '{"baseRefName":"feature/base","reviewDecision":"%s"}\n' "$NATIVE_DECISION"
    ;;
  'api repos/consumer/repo/rules/branches/feature%2Fbase')
    printf '%s\n' "$PWD|$*" >> "$QUERY_LOG"
    [[ "$NATIVE_REPLY" != rules-failed ]] || exit 7
    printf '[{"type":"pull_request","parameters":{"required_approving_review_count":%s}}]\n' "$NATIVE_REQUIRED"
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

run_action() { # SCRIPT NATIVE_REPLY REQUEST_EXIT ARGS...
  local script="$1" reply="$2" request_exit="$3"
  shift 3
  : > "$REQUEST_LOG"
  : > "$QUERY_LOG"
  : > "$EXECUTION_LOG"
  RC=0
  (cd -- "$TMP_ROOT/catalog" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT/home" \
    GH_TOKEN=github_pat_fixture GH_REPO=catalog/repo GITHUB_REPOSITORY=catalog/repo \
    REVIEW_GATE_MODE=enforce PR_REVIEW_GATE=review REVIEW_GATE_SETTINGS_FILE=/dev/null \
    QUERY_LOG="$QUERY_LOG" EXECUTION_LOG="$EXECUTION_LOG" REQUEST_LOG="$REQUEST_LOG" \
    REQUEST_EXIT="$request_exit" NATIVE_REPLY="$reply" NATIVE_REQUIRED="${REQUIRED:-1}" \
    NATIVE_DECISION="${DECISION-REVIEW_REQUIRED}" \
    bash "$script" 42 "$@" > "$OUT" 2> "$ERR") || RC=$?
  REQUESTS="$(wc -l < "$REQUEST_LOG" | tr -d ' ')"
}

for row in \
  'disabled request|off|ok|1|REVIEW_REQUIRED|0|0|off|0' \
  'enabled request|enforce|ok|1|REVIEW_REQUIRED|0|0|approval|1' \
  'native gate absent|enforce|ok|0||0|0|off|0' \
  'failed base query|enforce|base-failed|1|REVIEW_REQUIRED|0|2||0' \
  'failed rules query|enforce|rules-failed|1|REVIEW_REQUIRED|0|2||0' \
  'unknown policy|junk|ok|1|REVIEW_REQUIRED|0|2||0' \
  'empty policy||ok|1|REVIEW_REQUIRED|0|2||0' \
  'failed GitHub request|enforce|ok|1|REVIEW_REQUIRED|8|8||1'; do
  IFS='|' read -r label setting reply REQUIRED DECISION request_exit want_rc want_out want_requests <<< "$row"
  printf '[env]\nREVIEW_GATE_MODE = "%s"\n' "$setting" > "$BASE/kendex.settings.toml"
  run_action "$RUN" "$reply" "$request_exit" --request-review --base-checkout "$BASE"
  assert_eq "$RC|$(cat "$OUT")|$REQUESTS" "$want_rc|$want_out|$want_requests" "$label" "$ERR"
  assert_eq "$(cat "$EXECUTION_LOG")" '' "$label never executes stacked-base code" "$ERR"
done
assert_eq "$(cat "$REQUEST_LOG")" "$BASE|pr edit 42 --repo consumer/repo --add-reviewer @copilot" \
  'the request names the consumer repository, not the inherited catalog' "$ERR"
assert_contains "$(cat "$QUERY_LOG")" "$BASE|api repos/consumer/repo/rules/branches/feature%2Fbase --paginate" \
  'the trusted native owner reads stacked-base rules from the consumer directory' "$ERR"

printf '[env]\nREVIEW_GATE_MODE = "off"\n' > "$BASE/kendex.settings.toml"
run_action "$RUN" ok 0 --resolve-mode --base-checkout "$BASE"
assert_eq "$RC|$(cat "$OUT")|$REQUESTS" '0|off|0' 'base mode resolution honors disabled policy beside required approval' "$ERR"
assert_eq "$(cat "$QUERY_LOG")|$(cat "$EXECUTION_LOG")" '|' 'off reads no native gate and executes no base code' "$ERR"
for action in --request-review --resolve-mode; do
  for context in '' "$TMP_ROOT/missing"; do
    base_args=()
    [[ -z "$context" ]] || base_args=(--base-checkout "$context")
    run_action "$RUN" ok 0 "$action" ${base_args[@]+"${base_args[@]}"}
    assert_eq "$RC|$(cat "$OUT")|$REQUESTS|$(cat "$QUERY_LOG")|$(cat "$EXECUTION_LOG")" '2||0||' "$action refuses unavailable context [$context] before native reads" "$ERR"
  done
done
printf '[env]\nREVIEW_GATE_MODE = ["off"]\n' > "$BASE/kendex.settings.toml"
run_action "$RUN" ok 0 --request-review --base-checkout "$BASE"
assert_eq "$RC|$(cat "$OUT")|$REQUESTS" '2||0' 'a settings-reader failure authorizes no request' "$ERR"

for row in \
  'off-gate~off~if $REQUEST_REVIEW && [[ "$GATE_MODE" == approval ]]; then~if $REQUEST_REVIEW && [[ "$GATE_MODE" == approval || "$GATE_MODE" == off ]]; then~0~off~0' \
  'settings-failure~malformed~policy=$(rg_setting REVIEW_GATE_MODE enforce) || return $?~policy=$(rg_setting REVIEW_GATE_MODE enforce) || policy=enforce~2~~0' \
  'unknown-policy~junk~*) approval_message policy-mode-invalid >&2; return 1 ;;~*) approval_message policy-mode-invalid >&2; return 0 ;;~2~~0' \
  'base-directory~off~  cd -- "$BASE_CHECKOUT"~  : # cd -- "$BASE_CHECKOUT"~0~off~0' \
  'stacked-base-execution~enforce~  policy=$(rg_setting REVIEW_GATE_MODE enforce)~  "$BASE_CHECKOUT/.agents/skills/orch/scripts/approval-wait" "$PR_NUM" --resolve-mode >&2; policy=$(rg_setting REVIEW_GATE_MODE enforce)~0~approval~1' \
  'stdout-isolation~enforce~gh pr edit "$PR_NUM" --repo "$REPO" --add-reviewer @copilot >&2~gh pr edit "$PR_NUM" --repo "$REPO" --add-reviewer @copilot~0~approval~1'; do
  IFS='~' read -r label setting old new want_rc want_out want_requests <<< "$row"
  if [[ "$setting" == malformed ]]; then
    printf '[env]\nREVIEW_GATE_MODE = ["off"]\n' > "$BASE/kendex.settings.toml"
  else
    printf '[env]\nREVIEW_GATE_MODE = "%s"\n' "$setting" > "$BASE/kendex.settings.toml"
  fi
  scripts="$(mutant_scripts "$label/orch" approval-wait)"
  ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/$label/github"
  ln -s "$REPO_ROOT/skills/review-gate" "$TMP_ROOT/$label/review-gate"
  mutate_file "$scripts/approval-wait" "$old" "$new"
  run_action "$scripts/approval-wait" ok 0 --request-review --base-checkout "$BASE"
  if [[ "$RC|$(cat "$OUT")|$REQUESTS|$(cat "$EXECUTION_LOG")" == "$want_rc|$want_out|$want_requests|" ]]; then
    fail "$label control did not turn its behavioral assertion red"
  else
    pass "$label control turns its behavioral assertion red"
  fi
done

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
