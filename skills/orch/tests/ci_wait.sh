#!/usr/bin/env bash
# Regression tests for orch/scripts/ci-wait auth ladder.
#
# Covers vstack#19 plus the follow-up review:
#   1. stale GH_TOKEN + working keyring  -> sanitizer unsets, ci-wait passes
#   2. no env tokens + working keyring   -> no warning, ci-wait passes
#   3. stale GH_TOKEN + broken keyring + no .env.local bot token
#                                        -> exit 3 with "no working" diagnostic
#   4. stale GH_TOKEN + broken keyring + valid .env.local GH_BOT_TOKEN
#                                        -> bot-token fallback recovers
#   5. broken keyring + inherited valid GH_BOT_TOKEN + .env.local op:// token
#                                        -> inherited token wins, no op read
#   6. valid selected token + stale keyring auth status
#                                        -> token preflight wins once
#   7. no env token + hanging keyring auth
#                                        -> bounded failure, not hang
#
# Plus the deterministic-output contract (vstack#454): ci-wait must always
# emit a parseable result on stdout — pass/fail/timeout/error — and must
# report still-pending checks at the deadline as a timeout, never as
# success or silence (cases 10-14).
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

dump_stderr() {
  local file="$1"
  [[ -n "$file" && -f "$file" ]] || return 0
  printf '        stderr:\n'
  sed 's/^/          /' "$file"
}

assert_eq() {
  local got="$1" want="$2" name="$3" stderr_file="${4:-}"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
    dump_stderr "$stderr_file"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3" stderr_file="${4:-}"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
    dump_stderr "$stderr_file"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3" stderr_file="${4:-}"
  if grep -qF -- "$needle" <<<"$haystack"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        unwanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
    dump_stderr "$stderr_file"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  fi
}

mkdir -p "$TMP_ROOT/repo/.agents/skills" "$TMP_ROOT/bin"
ln -s "$REPO_ROOT/skills/orch" "$TMP_ROOT/repo/.agents/skills/orch"
git -C "$TMP_ROOT/repo" init -q
git -C "$TMP_ROOT/repo" config user.email test@example.com
git -C "$TMP_ROOT/repo" config user.name Test

# Parametrized `gh` stub.
#   _stub_auth_ok returns 0 iff the current invocation should succeed.
#     GH_TOKEN/GITHUB_TOKEN set    -> ok iff value matches STUB_GH_VALID_TOKEN
#     no env tokens                 -> ok iff STUB_GH_DENY_KEYRING != 1
#   All API endpoints (auth status, repo view, pr view, pr checks) gate on
#   _stub_auth_ok so a stale token surfaces as HTTP 401 the same way the
#   real `gh` does.
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

_stub_auth_ok() {
  local tok="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [[ -n "$tok" ]]; then
    [[ -n "${STUB_GH_VALID_TOKEN:-}" && "$tok" == "$STUB_GH_VALID_TOKEN" ]] && return 0
    return 1
  fi
  [[ "${STUB_GH_DENY_KEYRING:-0}" == "1" ]] && return 1
  return 0
}

case "${1:-}" in
  auth)
    if [[ "${2:-}" == "status" ]]; then
      if [[ "${STUB_GH_AUTH_STATUS_SLEEP:-0}" == "1" ]]; then
        sleep 5
      fi
      if [[ "${STUB_GH_AUTH_STATUS_FAIL:-0}" == "1" ]]; then
        echo "keyring default failed" >&2
        exit 1
      fi
      if _stub_auth_ok; then
        echo "Logged in"
        exit 0
      fi
      echo "auth failed" >&2
      exit 1
    fi
    ;;
  api)
    if [[ "${2:-}" == "user" ]]; then
      if [[ -n "${STUB_GH_API_USER_COUNT_FILE:-}" ]]; then
        count=0
        if [[ -f "$STUB_GH_API_USER_COUNT_FILE" ]]; then
          count="$(cat "$STUB_GH_API_USER_COUNT_FILE")"
        fi
        count=$((count + 1))
        printf '%s' "$count" > "$STUB_GH_API_USER_COUNT_FILE"
      fi
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo "test-user"
      exit 0
    fi
    ;;
  repo)
    if [[ "${2:-}" == "view" ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      # Simulate `gh repo view --json nameWithOwner` returning empty so ci-wait
      # falls back to deriving owner/repo from the origin URL (vstack#476).
      [[ "${STUB_GH_REPO_VIEW_EMPTY:-0}" == "1" ]] && exit 0
      echo "owner/repo"
      exit 0
    fi
    ;;
  pr)
    # Capture the --repo slug ci-wait resolved and reject a stale ".git"
    # suffix the way real gh does ("Could not resolve to a Repository").
    _repo_arg=""
    _prev=""
    for _a in "$@"; do
      [[ "$_prev" == "--repo" ]] && _repo_arg="$_a"
      _prev="$_a"
    done
    if [[ -n "${STUB_REPO_ARG_FILE:-}" && -n "$_repo_arg" ]]; then
      printf '%s' "$_repo_arg" > "$STUB_REPO_ARG_FILE"
    fi
    if [[ -n "$_repo_arg" && "$_repo_arg" == *.git ]]; then
      echo "Could not resolve to a Repository with the name '$_repo_arg'." >&2
      exit 1
    fi
    if [[ "${2:-}" == "view" ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo "CLEAN"
      exit 0
    fi
    if [[ "${2:-}" == "checks" ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      if [[ "${STUB_PR_CHECKS_MODE:-}" == "pending_once" ]]; then
        count=0
        if [[ -f "${STUB_PR_CHECKS_COUNT_FILE:?}" ]]; then
          count="$(cat "$STUB_PR_CHECKS_COUNT_FILE")"
        fi
        count=$((count + 1))
        printf '%s' "$count" > "$STUB_PR_CHECKS_COUNT_FILE"
        if [[ "$count" -eq 1 ]]; then
          echo '[{"name":"build","state":"IN_PROGRESS"}]'
          exit 8
        fi
      fi
      if [[ "${STUB_PR_CHECKS_MODE:-}" == "expected_once" ]]; then
        count=0
        if [[ -f "${STUB_PR_CHECKS_COUNT_FILE:?}" ]]; then
          count="$(cat "$STUB_PR_CHECKS_COUNT_FILE")"
        fi
        count=$((count + 1))
        printf '%s' "$count" > "$STUB_PR_CHECKS_COUNT_FILE"
        if [[ "$count" -eq 1 ]]; then
          echo '[{"name":"build","state":"SUCCESS"},{"name":"required","state":"EXPECTED"}]'
          exit 8
        fi
      fi
      if [[ "${STUB_PR_CHECKS_MODE:-}" == "pending_always" ]]; then
        echo '[{"name":"build","state":"IN_PROGRESS"}]'
        exit 8
      fi
      if [[ "${STUB_PR_CHECKS_MODE:-}" == "empty" ]]; then
        echo '[]'
        exit 0
      fi
      # vstack#492: an OLD superseded run (RUN_ID 29098545030) left several
      # CANCELLED named jobs; the NEW authoritative run (RUN_ID 29099680623) on
      # the current head has only its classifier job IN_PROGRESS and has NOT yet
      # created Lint/Integration/etc. Scoping to the latest run per workflow must
      # drop the OLD canceled jobs so they are not reported as current failures.
      if [[ "${STUB_PR_CHECKS_MODE:-}" == "superseded_pending" ]]; then
        cat <<'JSON'
[
  {"name":"Lint","state":"CANCELLED","bucket":"cancel","link":"https://github.com/owner/repo/actions/runs/29098545030/job/101","workflow":"CI","startedAt":"2026-07-10T10:00:00Z","completedAt":"2026-07-10T10:00:30Z"},
  {"name":"Linux Integration","state":"CANCELLED","bucket":"cancel","link":"https://github.com/owner/repo/actions/runs/29098545030/job/102","workflow":"CI","startedAt":"2026-07-10T10:00:01Z","completedAt":"2026-07-10T10:00:31Z"},
  {"name":"macOS","state":"CANCELLED","bucket":"cancel","link":"https://github.com/owner/repo/actions/runs/29098545030/job/103","workflow":"CI","startedAt":"2026-07-10T10:00:02Z","completedAt":"2026-07-10T10:00:32Z"},
  {"name":"Windows","state":"CANCELLED","bucket":"cancel","link":"https://github.com/owner/repo/actions/runs/29098545030/job/104","workflow":"CI","startedAt":"2026-07-10T10:00:03Z","completedAt":"2026-07-10T10:00:33Z"},
  {"name":"Loom","state":"CANCELLED","bucket":"cancel","link":"https://github.com/owner/repo/actions/runs/29098545030/job/105","workflow":"CI","startedAt":"2026-07-10T10:00:04Z","completedAt":"2026-07-10T10:00:34Z"},
  {"name":"Bench (iai-callgrind)","state":"CANCELLED","bucket":"cancel","link":"https://github.com/owner/repo/actions/runs/29098545030/job/106","workflow":"CI","startedAt":"2026-07-10T10:00:05Z","completedAt":"2026-07-10T10:00:35Z"},
  {"name":"Changes","state":"IN_PROGRESS","bucket":"pending","link":"https://github.com/owner/repo/actions/runs/29099680623/job/201","workflow":"CI","startedAt":"2026-07-10T11:00:00Z","completedAt":""},
  {"name":"License Key Guard","state":"SUCCESS","bucket":"pass","link":"https://github.com/owner/repo/actions/runs/29099680623/job/202","workflow":"CI","startedAt":"2026-07-10T11:00:01Z","completedAt":"2026-07-10T11:00:20Z"}
]
JSON
        exit 8
      fi
      # vstack#492 (part 2): once the NEW run recreates a named job (Lint on
      # RUN_ID 29099680623, SUCCESS), that current-head instance must replace the
      # OLD run's CANCELLED "Lint" (RUN_ID 29098545030) by context name, leaving
      # no stale CANCELLED entry in failed_checks.
      if [[ "${STUB_PR_CHECKS_MODE:-}" == "superseded_replaced" ]]; then
        cat <<'JSON'
[
  {"name":"Lint","state":"CANCELLED","bucket":"cancel","link":"https://github.com/owner/repo/actions/runs/29098545030/job/101","workflow":"CI","startedAt":"2026-07-10T10:00:00Z","completedAt":"2026-07-10T10:00:30Z"},
  {"name":"Lint","state":"SUCCESS","bucket":"pass","link":"https://github.com/owner/repo/actions/runs/29099680623/job/201","workflow":"CI","startedAt":"2026-07-10T11:00:00Z","completedAt":"2026-07-10T11:05:00Z"},
  {"name":"Changes","state":"SUCCESS","bucket":"pass","link":"https://github.com/owner/repo/actions/runs/29099680623/job/202","workflow":"CI","startedAt":"2026-07-10T11:00:01Z","completedAt":"2026-07-10T11:00:20Z"}
]
JSON
        exit 0
      fi
      if [[ "${STUB_PR_CHECKS_MODE:-}" == "failure" ]]; then
        echo '[{"name":"build","state":"FAILURE"}]'
        exit 1
      fi
      echo '[{"name":"build","state":"SUCCESS"}]'
      exit 0
    fi
    ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$TMP_ROOT/bin/gh"

cat > "$TMP_ROOT/bin/op" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'op called: %s\n' "\$*" >>"$TMP_ROOT/op.calls"
exit 1
EOF
chmod +x "$TMP_ROOT/bin/op"

# Run ci-wait via the .agents symlink, exactly how it's invoked in
# production. `env "$@"` injects test-controlled env tokens / stub flags.
run_wait() {
  (cd "$TMP_ROOT/repo" \
    && PATH="$TMP_ROOT/bin:$PATH" \
       env "$@" .agents/skills/orch/scripts/ci-wait 1 1 30)
}

run_wait_short() {
  (cd "$TMP_ROOT/repo" \
    && PATH="$TMP_ROOT/bin:$PATH" \
       env "$@" .agents/skills/orch/scripts/ci-wait 1 1 5)
}

run_wait_json() {
  (cd "$TMP_ROOT/repo" \
    && PATH="$TMP_ROOT/bin:$PATH" \
       env "$@" .agents/skills/orch/scripts/ci-wait 1 1 30 --json)
}

run_wait_json_short() {
  (cd "$TMP_ROOT/repo" \
    && PATH="$TMP_ROOT/bin:$PATH" \
       env "$@" .agents/skills/orch/scripts/ci-wait 1 1 5 --json)
}

# jq field extractor for --json output assertions.
json_field() {
  jq -r "$2" <<<"$1" 2>/dev/null || echo "UNPARSEABLE"
}

echo "=== ci-wait auth handling ==="

# Case 1: stale GH_TOKEN inherited from caller; keyring works once unset.
stderr="$TMP_ROOT/case1.err"
set +e
output=$(run_wait GH_TOKEN=bad-token 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "case1: stale GH_TOKEN sanitized, ci-wait exits 0" "$stderr"
assert_contains "$output" "CI passed" "case1: ci-wait reaches CI passed"
assert_contains "$(cat "$stderr")" "unsetting them" "case1: stale-token warning on stderr"

# Case 2: no env tokens; keyring works directly.
stderr="$TMP_ROOT/case2.err"
set +e
output=$(run_wait 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "case2: keyring works without env tokens" "$stderr"
assert_contains "$output" "CI passed" "case2: ci-wait reaches CI passed"
assert_not_contains "$(cat "$stderr")" "unsetting them" "case2: sanitizer silent when no env tokens" "$stderr"

# Case 3: stale GH_TOKEN + keyring denied + no .env.local bot token.
rm -f "$TMP_ROOT/repo/.env.local"
stderr="$TMP_ROOT/case3.err"
set +e
output=$(run_wait GH_TOKEN=bad-token STUB_GH_DENY_KEYRING=1 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "3" "case3: no working auth path -> exit 3" "$stderr"
assert_contains "$(cat "$stderr")" "no working GitHub auth path" "case3: clear diagnostic on stderr"

# Case 4: stale GH_TOKEN + keyring denied + valid .env.local GH_BOT_TOKEN.
cat > "$TMP_ROOT/repo/.env.local" <<'ENVEOF'
export GH_BOT_TOKEN=ghs_VALIDBOT123
ENVEOF
stderr="$TMP_ROOT/case4.err"
api_count_file="$TMP_ROOT/case4-api-user-count"
set +e
output=$(run_wait GH_TOKEN=bad-token STUB_GH_DENY_KEYRING=1 STUB_GH_VALID_TOKEN=ghs_VALIDBOT123 STUB_GH_API_USER_COUNT_FILE="$api_count_file" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "case4: .env.local GH_BOT_TOKEN recovers" "$stderr"
assert_contains "$output" "CI passed" "case4: ci-wait reaches CI passed via bot-token fallback"
assert_eq "$(cat "$api_count_file")" "2" "case4: stale env and bot token are each validated once" "$stderr"
rm -f "$TMP_ROOT/repo/.env.local"

# Case 5: process env already has a resolved bot token; project op reference
# should not be read.
cat > "$TMP_ROOT/repo/.env.local" <<'ENVEOF'
export GH_BOT_TOKEN=op://vault/github/bot
ENVEOF
rm -f "$TMP_ROOT/op.calls"
stderr="$TMP_ROOT/case5.err"
set +e
output=$(run_wait GH_BOT_TOKEN=ghs_ENVBOT123 STUB_GH_DENY_KEYRING=1 STUB_GH_VALID_TOKEN=ghs_ENVBOT123 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "case5: inherited GH_BOT_TOKEN recovers without project secret load" "$stderr"
assert_contains "$output" "CI passed" "case5: ci-wait reaches CI passed via inherited bot token"
if [[ -e "$TMP_ROOT/op.calls" ]]; then
  assert_eq "$(cat "$TMP_ROOT/op.calls")" "" "case5: inherited GH_BOT_TOKEN does not call op" "$stderr"
else
  assert_eq "missing" "missing" "case5: inherited GH_BOT_TOKEN does not call op"
fi
rm -f "$TMP_ROOT/repo/.env.local"

# Case 6: a selected env token works for API calls while gh auth status would
# fail because of a stale keyring account.
stderr="$TMP_ROOT/case6.err"
api_count_file="$TMP_ROOT/case6-api-user-count"
set +e
output=$(run_wait GH_TOKEN=ghs_VALIDUSER123 STUB_GH_VALID_TOKEN=ghs_VALIDUSER123 STUB_GH_AUTH_STATUS_FAIL=1 STUB_GH_API_USER_COUNT_FILE="$api_count_file" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "case6: valid selected token ignores stale keyring status" "$stderr"
assert_contains "$output" "CI passed" "case6: ci-wait reaches CI passed via selected token"
assert_not_contains "$(cat "$stderr")" "unsetting them" "case6: selected token does not trigger sanitizer fallback" "$stderr"
assert_eq "$(cat "$api_count_file")" "1" "case6: selected token validates once at startup" "$stderr"

# Case 7: no env tokens and keyring auth hangs. The bounded auth preflight
# should return the normal no-working-auth diagnostic instead of hanging.
stderr="$TMP_ROOT/case7.err"
set +e
output=$(timeout 6s bash -c 'cd "$1" && PATH="$2:$PATH" VSTACK_GITHUB_AUTH_TIMEOUT=1 STUB_GH_AUTH_STATUS_SLEEP=1 .agents/skills/orch/scripts/ci-wait 1 1 30' bash "$TMP_ROOT/repo" "$TMP_ROOT/bin" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "3" "case7: hanging keyring auth exits 3" "$stderr"
assert_contains "$(cat "$stderr")" "no working GitHub auth path" "case7: hanging keyring auth reports no working path" "$stderr"

# Case 8: gh pr checks exits 8 while checks are pending but still prints valid
# JSON. ci-wait should treat the JSON as authoritative and keep polling.
stderr="$TMP_ROOT/case8.err"
checks_count_file="$TMP_ROOT/case8-checks-count"
set +e
output=$(run_wait STUB_PR_CHECKS_MODE=pending_once STUB_PR_CHECKS_COUNT_FILE="$checks_count_file" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "case8: pending checks exit code keeps polling" "$stderr"
assert_contains "$output" "CI passed" "case8: ci-wait reaches CI passed after pending checks"
assert_eq "$(cat "$checks_count_file")" "2" "case8: ci-wait polls again after pending JSON" "$stderr"

# Case 9: WAITING/REQUESTED/EXPECTED states must count as pending even when
# bucket is absent. Otherwise one success plus one expected required check can
# age through stale-check handling instead of polling.
stderr="$TMP_ROOT/case9.err"
checks_count_file="$TMP_ROOT/case9-checks-count"
set +e
output=$(run_wait_short STUB_PR_CHECKS_MODE=expected_once STUB_PR_CHECKS_COUNT_FILE="$checks_count_file" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "case9: EXPECTED checks are treated as pending" "$stderr"
assert_contains "$output" "CI passed" "case9: ci-wait reaches CI passed after expected check clears"
assert_eq "$(cat "$checks_count_file")" "2" "case9: ci-wait polls again after EXPECTED JSON" "$stderr"

echo "=== ci-wait output contract (vstack#454) ==="

# Case 10: --json pass. Result must be a parseable object with
# status=complete / verdict=pass.
stderr="$TMP_ROOT/case10.err"
set +e
output=$(run_wait_json 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "case10: json pass exits 0" "$stderr"
assert_eq "$(json_field "$output" '.status')" "complete" "case10: json status is complete" "$stderr"
assert_eq "$(json_field "$output" '.verdict')" "pass" "case10: json verdict is pass" "$stderr"
assert_eq "$(json_field "$output" '.passed_checks | length')" "1" "case10: json lists passed checks" "$stderr"

# Case 11: checks still IN_PROGRESS at the deadline must report a timeout,
# never exit 0 or stay silent (the vstack#454 defect).
stderr="$TMP_ROOT/case11.err"
set +e
output=$(run_wait_json_short STUB_PR_CHECKS_MODE=pending_always 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "case11: pending checks at deadline exit 1" "$stderr"
assert_eq "$(json_field "$output" '.status')" "timeout" "case11: json status is timeout" "$stderr"
assert_eq "$(json_field "$output" '.verdict')" "pending" "case11: json verdict is pending" "$stderr"
assert_eq "$(json_field "$output" '.pending_checks[0].name')" "build" "case11: json lists pending checks" "$stderr"

# Case 11b: same deadline scenario in text mode still emits a stdout result.
stderr="$TMP_ROOT/case11b.err"
set +e
output=$(run_wait_short STUB_PR_CHECKS_MODE=pending_always 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "case11b: text-mode timeout exits 1" "$stderr"
assert_contains "$output" "CI timeout" "case11b: text-mode timeout prints CI timeout on stdout"

# Case 12: no checks ever registered -> status=error with diagnostic, not
# a silent exit.
stderr="$TMP_ROOT/case12.err"
set +e
output=$(run_wait_json STUB_PR_CHECKS_MODE=empty 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "case12: no registered checks exit 1" "$stderr"
assert_eq "$(json_field "$output" '.status')" "error" "case12: json status is error" "$stderr"
assert_contains "$(json_field "$output" '.error')" "no CI checks" "case12: json error names the cause"

# Case 12b: same in text mode — stdout carries a CI error line.
stderr="$TMP_ROOT/case12b.err"
set +e
output=$(run_wait STUB_PR_CHECKS_MODE=empty 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "case12b: text-mode no-checks exit 1" "$stderr"
assert_contains "$output" "CI error" "case12b: text-mode no-checks prints CI error on stdout"

# Case 13: settled failing check -> status=complete / verdict=fail.
stderr="$TMP_ROOT/case13.err"
set +e
output=$(run_wait_json STUB_PR_CHECKS_MODE=failure 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "case13: failed checks exit 1" "$stderr"
assert_eq "$(json_field "$output" '.status')" "complete" "case13: json status is complete" "$stderr"
assert_eq "$(json_field "$output" '.verdict')" "fail" "case13: json verdict is fail" "$stderr"
assert_eq "$(json_field "$output" '.failed_checks[0].name')" "build" "case13: json lists failed checks" "$stderr"

# Case 14: auth failure with --json still yields a parseable error object.
rm -f "$TMP_ROOT/repo/.env.local"
stderr="$TMP_ROOT/case14.err"
set +e
output=$(run_wait_json GH_TOKEN=bad-token STUB_GH_DENY_KEYRING=1 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "3" "case14: json auth failure exits 3" "$stderr"
assert_eq "$(json_field "$output" '.status')" "error" "case14: json auth failure reports status error" "$stderr"
assert_contains "$(json_field "$output" '.error')" "auth" "case14: json auth failure names auth in error"

echo "=== ci-wait repo-slug fallback (vstack#476) ==="

# When `gh repo view --json nameWithOwner` returns empty (e.g. the transient
# unknown-merge-state path), ci-wait derives owner/repo from the origin URL.
# GNU sed / POSIX ERE has no non-greedy quantifier, so the old
# `[^/]+?(\.git)?$` pattern greedily kept the trailing ".git" and every
# subsequent `gh --repo owner/repo.git` call failed. The stub records the
# --repo slug and rejects any `*.git` value like real gh, so a clean pass
# proves the suffix was stripped. Covers SSH and HTTPS origins, with and
# without ".git".

# Case 15: SSH origin ending in .git.
git -C "$TMP_ROOT/repo" remote add origin git@github.com:owner/repo.git
stderr="$TMP_ROOT/case15.err"
repo_arg_file="$TMP_ROOT/case15-repo-arg"
set +e
output=$(run_wait STUB_GH_REPO_VIEW_EMPTY=1 STUB_REPO_ARG_FILE="$repo_arg_file" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "case15: ssh .git origin fallback exits 0" "$stderr"
assert_contains "$output" "CI passed" "case15: ci-wait reaches CI passed via ssh origin fallback"
assert_eq "$(cat "$repo_arg_file")" "owner/repo" "case15: --repo slug drops .git suffix (ssh)" "$stderr"

# Case 16: HTTPS origin ending in .git.
git -C "$TMP_ROOT/repo" remote set-url origin https://github.com/owner/repo.git
stderr="$TMP_ROOT/case16.err"
repo_arg_file="$TMP_ROOT/case16-repo-arg"
set +e
output=$(run_wait STUB_GH_REPO_VIEW_EMPTY=1 STUB_REPO_ARG_FILE="$repo_arg_file" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "case16: https .git origin fallback exits 0" "$stderr"
assert_contains "$output" "CI passed" "case16: ci-wait reaches CI passed via https origin fallback"
assert_eq "$(cat "$repo_arg_file")" "owner/repo" "case16: --repo slug drops .git suffix (https)" "$stderr"

# Case 17: HTTPS origin WITHOUT a .git suffix must still resolve cleanly and
# must not lose a trailing path segment.
git -C "$TMP_ROOT/repo" remote set-url origin https://github.com/owner/repo
stderr="$TMP_ROOT/case17.err"
repo_arg_file="$TMP_ROOT/case17-repo-arg"
set +e
output=$(run_wait STUB_GH_REPO_VIEW_EMPTY=1 STUB_REPO_ARG_FILE="$repo_arg_file" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "case17: https origin without .git exits 0" "$stderr"
assert_eq "$(cat "$repo_arg_file")" "owner/repo" "case17: --repo slug preserved without .git" "$stderr"

echo "=== ci-wait superseded-run scoping (vstack#492) ==="

# Case 18: an OLD canceled run's CANCELLED jobs must NOT be reported as current
# failures when the NEW authoritative run has only its classifier job pending and
# has not yet recreated those jobs. Scoping to the latest run per workflow drops
# the superseded run's checks, so the verdict is pending (waiting on "Changes"),
# never a false fail on the stale CANCELLED Lint/Integration/etc.
stderr="$TMP_ROOT/case18.err"
set +e
output=$(run_wait_json_short STUB_PR_CHECKS_MODE=superseded_pending 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "case18: superseded-run pending exits 1 (timeout)" "$stderr"
assert_eq "$(json_field "$output" '.status')" "timeout" "case18: json status is timeout" "$stderr"
assert_eq "$(json_field "$output" '.verdict')" "pending" "case18: verdict pending, not fail" "$stderr"
assert_eq "$(json_field "$output" '.failed_checks | length')" "0" "case18: no stale CANCELLED jobs in failed_checks" "$stderr"
assert_contains "$output" '"Changes"' "case18: current classifier job reported as pending" "$stderr"
assert_not_contains "$output" '"Lint"' "case18: superseded run's Lint dropped from output" "$stderr"
assert_not_contains "$output" '"Linux Integration"' "case18: superseded run's Integration dropped" "$stderr"

# Case 19: once the NEW run recreates a named job (Lint SUCCESS on the newest
# RUN_ID), that current-head instance replaces the OLD run's CANCELLED "Lint" by
# context name — no stale CANCELLED entry survives, verdict passes.
stderr="$TMP_ROOT/case19.err"
set +e
output=$(run_wait_json STUB_PR_CHECKS_MODE=superseded_replaced 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "case19: superseded-then-replaced exits 0" "$stderr"
assert_eq "$(json_field "$output" '.verdict')" "pass" "case19: verdict pass after replacement" "$stderr"
assert_eq "$(json_field "$output" '.failed_checks | length')" "0" "case19: no CANCELLED Lint in failed_checks" "$stderr"
assert_not_contains "$output" '"CANCELLED"' "case19: no stale CANCELLED state survives" "$stderr"
assert_eq "$(json_field "$output" '[.passed_checks[].name] | map(select(. == "Lint")) | length')" "1" "case19: exactly one current Lint instance kept" "$stderr"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
