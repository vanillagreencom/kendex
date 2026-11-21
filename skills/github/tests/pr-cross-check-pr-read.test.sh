#!/usr/bin/env bash
# pr-cross-check's per-PR read: the answer is `gh pr view`'s stdout alone,
# so a hint gh writes to stderr on a successful read (gh 2.105.0, cli/cli#15077)
# leaves the verdict intact, and a failed read is a pr_fetch_failed issue whose
# description carries the failed command's diagnostic.
#
# PR 1 always answers a valid object beside the hint. A row stages PR 2 as
# `label^status^stderr^stdout^prs^issues^diagnostic`, fields separated by `^`:
#   status, stderr, stdout  what PR 2's `gh pr view` exits with and writes
#   prs                     the checked PR numbers the verdict lists
#   issues                  the verdict's issue types
#   diagnostic              text a pr_fetch_failed description carries, `-`
#                           when the verdict holds no such issue
set -euo pipefail

# The lib derives PROJECT_ROOT through git at source time.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_ROOT="$(mktemp -d)" || { echo "pr-cross-check-pr-read: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "pr-cross-check-pr-read: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "pr-cross-check-pr-read: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

PASS=0
FAIL=0

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

# shellcheck source=lib/gh-stub.sh
. "$TEST_DIR/lib/gh-stub.sh"
# shellcheck source=lib/mutant-copy.sh
. "$TEST_DIR/lib/mutant-copy.sh"
GH_STUB_DIR="$TMP_ROOT/gh-stub" gh_stub_install "$TMP_ROOT/bin"

# gh 2.105.0's `gh pr view` opens this block on stderr on a successful read.
HINT='hint: if you need to wait for this pull request to be reviewed, merged, or closed'
pr_json() {
  jq -nc --argjson n "$1" '{number: $n, headRefName: "b\($n)", baseRefName: "main",
    mergeable: "MERGEABLE", files: [{path: "src/only-\($n).rs"}]}'
}
PR2="$(pr_json 2)"

ROWS="\
a success hint on stderr leaves the verdict intact^0^$HINT^$PR2^1,2^^-
a failed read is a fetch issue carrying gh's diagnostic^1^HTTP 502: Bad Gateway^-^1^pr_fetch_failed^HTTP 502: Bad Gateway
"

# run SCRIPT STATUS STDERR STDOUT — the verdict as `prs=… issues=… diagnostic=…`,
# or the failure's exit status and stderr.
run() {
  local script="$1" status="$2" stderr="$3" stdout="$4" out rc=0
  gh_stub_reset
  gh_stub_fail "pr-view:view 1 --json" 0 "$HINT" "$(pr_json 1)"
  [[ "$stdout" != - ]] || stdout=""
  gh_stub_fail "pr-view:view 2 --json" "$status" "$stderr" "$stdout"
  out="$(PATH="$TMP_ROOT/bin:$PATH" bash "$script" 1 2 --json 2>"$TMP_ROOT/err")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    printf 'rc=%s err=%s' "$rc" "$(tr '\n' ' ' <"$TMP_ROOT/err")"
    return
  fi
  jq -r '"prs=\(.prs | map(.number) | map(tostring) | join(","))"
    + " issues=\(.issues | map(.type) | join(","))"
    + " diagnostic=\([.issues[] | select(.type == "pr_fetch_failed") | .description] | join(" "))"' <<<"$out"
}

echo "=== per-PR read ==="
while IFS='^' read -r label status stderr stdout want_prs want_issues want_diag; do
  [[ -n "$label" ]] || continue
  got="$(run "$TEST_DIR/../scripts/commands/pr-cross-check.sh" "$status" "$stderr" "$stdout")"
  diag="${got#* diagnostic=}"
  carried=-
  [[ "$want_diag" == - || "$diag" != *"$want_diag"* ]] || carried="$want_diag"
  [[ "$want_diag" != - || -z "$diag" ]] || carried="$diag"
  assert_eq "${got%% diagnostic=*} diagnostic=$carried" \
    "prs=$want_prs issues=$want_issues diagnostic=$want_diag" "$label"
done <<<"$ROWS"

echo "=== must-fail control: the read merges stderr into the answer ==="
mutant="$(mutant_copy_edit "$TMP_ROOT/merged-stderr" \
  "    if ! { diagnostic=\$(json_or_default '' object gh pr view \"\$pr_num\" --json number,headRefName,files,mergeable,baseRefName 2>&1 >&3); } 3>&1; then" \
  "    if ! diagnostic=\$(gh pr view \"\$pr_num\" --json number,headRefName,files,mergeable,baseRefName 2>&1) || ! printf '%s\\n' \"\$diagnostic\"; then" \
  commands/pr-cross-check.sh)"
got="$(run "$mutant" 0 "$HINT" "$PR2")"
case "$got" in
rc=*) assert_eq merged-read-fails merged-read-fails "control: a merged read aborts the verdict" ;;
*) assert_eq "$got" "rc=<nonzero>" "control: a merged read aborts the verdict" ;;
esac

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
