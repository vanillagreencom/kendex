#!/usr/bin/env bash
# approval-wait's request action delegates to the consumer's installed mode
# resolver. The resolver is a dependency fixture, not the function under test.
# GitHub's request endpoint records actual mutations, including must-fail
# controls that bypass the off gate or ignore a failed resolver.
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
printf '[env]\nREVIEW_GATE_MODE = "off"\n' > "$BASE/kendex.settings.toml"

# The consumer installed resolver can differ from the catalog version. This
# fixture reads its own settings through the shipped settings reader. Its
# stdout and exit status are the dependency's documented enum protocol.
cat > "$BASE/.agents/skills/orch/scripts/approval-wait" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 2 && $1 == 42 && $2 == --resolve-mode ]]
printf '%s\n' "$PWD|$*" >> "$RESOLVE_LOG"
case "$RESOLVER_REPLY" in
  settings)
    mode="$("$SETTINGS_READER" REVIEW_GATE_MODE enforce)"
    case "$mode" in
      off) echo off ;;
      enforce) echo approval ;;
      *) exit 2 ;;
    esac
    ;;
  failed) echo approval; exit 7 ;;
  junk) echo junk ;;
  empty) : ;;
  *) exit 2 ;;
esac
EOF
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  'auth status') exit 0 ;;
  'repo view') echo consumer/repo ;;
  'pr edit')
    printf '%s\n' "$PWD|$*" >> "$REQUEST_LOG"
    exit "$REQUEST_EXIT"
    ;;
  *) printf 'gh: unexpected argv=%s\n' "$*" >&2; exit 9 ;;
esac
EOF
chmod +x "$BASE/.agents/skills/orch/scripts/approval-wait" "$TMP_ROOT/bin/gh"
RUN="$REPO_ROOT/skills/orch/scripts/approval-wait"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"
REQUEST_LOG="$TMP_ROOT/requests"
RESOLVE_LOG="$TMP_ROOT/resolutions"

# Child environment is explicit. Catalog settings and repository overrides
# must not defeat the consumer base's policy.
run_action() { # SCRIPT REPLY REQUEST_EXIT ARGS...
  local script="$1" reply="$2" request_exit="$3"
  shift 3
  : > "$REQUEST_LOG"
  : > "$RESOLVE_LOG"
  RC=0
  (cd -- "$TMP_ROOT/catalog" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT/home" \
    GH_REPO=catalog/repo GITHUB_REPOSITORY=catalog/repo REVIEW_GATE_MODE=enforce PR_REVIEW_GATE=review \
    RESOLVE_LOG="$RESOLVE_LOG" REQUEST_LOG="$REQUEST_LOG" REQUEST_EXIT="$request_exit" \
    RESOLVER_REPLY="$reply" SETTINGS_READER="$REPO_ROOT/skills/orch/scripts/orch-env" \
    bash "$script" 42 "$@" > "$OUT" 2> "$ERR") || RC=$?
  REQUESTS="$(wc -l < "$REQUEST_LOG" | tr -d ' ')"
}

for row in \
  'first request|off|settings|0|0|off|0' \
  'repeated request|off|settings|0|0|off|0' \
  'enabled request|enforce|settings|0|0|approval|1' \
  'failed resolver|off|failed|0|2||0' \
  'unknown mode|off|junk|0|2||0' \
  'empty mode|off|empty|0|2||0' \
  'failed GitHub request|enforce|settings|8|8||1'; do
  IFS='|' read -r label setting reply request_exit want_rc want_out want_requests <<< "$row"
  printf '[env]\nREVIEW_GATE_MODE = "%s"\n' "$setting" > "$BASE/kendex.settings.toml"
  run_action "$RUN" "$reply" "$request_exit" --request-review --base-checkout "$BASE"
  assert_eq "$RC|$(cat "$OUT")|$REQUESTS" "$want_rc|$want_out|$want_requests" "$label" "$ERR"
  assert_eq "$(cat "$RESOLVE_LOG")" "$BASE|42 --resolve-mode" "$label resolves in the consumer base" "$ERR"
done
assert_eq "$(cat "$REQUEST_LOG")" "$BASE|pr edit 42 --repo consumer/repo --add-reviewer @copilot" \
  'the request names the consumer repository, not the inherited catalog' "$ERR"

printf '[env]\nREVIEW_GATE_MODE = "off"\n' > "$BASE/kendex.settings.toml"
run_action "$RUN" settings 0 --resolve-mode --base-checkout "$BASE"
assert_eq "$RC|$(cat "$OUT")|$REQUESTS" '0|off|0' 'base mode resolution never requests a review' "$ERR"
run_action "$RUN" settings 0 --request-review
assert_eq "$RC|$REQUESTS" '2|0' 'a request with no consumer base is refused' "$ERR"
run_action "$RUN" settings 0 --request-review --base-checkout "$TMP_ROOT/missing"
assert_eq "$RC|$REQUESTS" '2|0' 'an unavailable consumer base is refused' "$ERR"

# Each control keeps the production guard text and removes its behavior.
# The same behavioral expectations above must turn red on the private copy.
for row in \
  'off-gate~settings~if $REQUEST_REVIEW && [[ "$GATE_MODE" == approval ]]; then~if $REQUEST_REVIEW && [[ "$GATE_MODE" == approval || "$GATE_MODE" == off ]]; then~0~off~0' \
  'resolver-failure~failed~"$BASE_CHECKOUT/.agents/skills/orch/scripts/approval-wait" "$PR_NUM" --resolve-mode) || return $?~"$BASE_CHECKOUT/.agents/skills/orch/scripts/approval-wait" "$PR_NUM" --resolve-mode) || :~2~~0' \
  'unknown-mode~junk~*) approval_message base-mode-invalid >&2; return 1 ;;~*) approval_message base-mode-invalid >&2; return 0 ;;~2~~0' \
  'base-directory~settings~  cd -- "$BASE_CHECKOUT"~  : # cd -- "$BASE_CHECKOUT"~0~off~0'; do
  IFS='~' read -r label reply old new want_rc want_out want_requests <<< "$row"
  scripts="$(mutant_scripts "$label/orch" approval-wait)"
  ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/$label/github"
  mutate_file "$scripts/approval-wait" "$old" "$new"
  run_action "$scripts/approval-wait" "$reply" 0 --request-review --base-checkout "$BASE"
  if [[ "$RC|$(cat "$OUT")|$REQUESTS" == "$want_rc|$want_out|$want_requests" ]]; then
    fail "$label control did not turn its behavioral assertion red"
  else
    pass "$label control turns its behavioral assertion red"
  fi
done

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
