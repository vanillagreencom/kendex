#!/usr/bin/env bash
# Tests for orch/scripts/ci-wait: the auth ladder (env token, keyring, bot
# token), the deterministic result contract (pass, fail, timeout, error, on
# stdout in both modes, pending at the deadline never silent), the no-checks
# registration grace, and the run correlations that keep a stale or
# superseded failure from ending a wait: latest run per workflow,
# approval-gated status replacement, superseded same-head runs the rollup
# omits, rerun attempts under an older run id, and the transient-failure
# retry over a log past the pipe buffer.
#
# One case per behaviour surface; shaped input is one table per case, one
# asserted row per shape. A row's `expect` names the fields it pins and
# `observe` reads exactly those, so a row fails on the field it names.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# The invoking shell's real auth env must not reach the cases below — the
# sanitizer cases assert on exactly the tokens each case injects.
unset GH_TOKEN GITHUB_TOKEN GH_BOT_TOKEN

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# The pass/fail counters and the assertion vocabulary every waiter suite shares.
# shellcheck source=lib/waiter-assertions.sh
source "$TEST_DIR/lib/waiter-assertions.sh"

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
    # superseded-failure correlation queries the head's Actions
    # runs. Record the query when asked so tests can prove head-sha scoping.
    if [[ "${2:-}" == repos/*/actions/runs* ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      if [[ -n "${STUB_ACTIONS_RUNS_QUERY_FILE:-}" ]]; then
        printf '%s' "$2" > "$STUB_ACTIONS_RUNS_QUERY_FILE"
      fi
      if [[ -n "${STUB_ACTIONS_RUNS_FIXTURE:-}" ]]; then
        cat "$STUB_ACTIONS_RUNS_FIXTURE"
      else
        echo '{"workflow_runs":[]}'
      fi
      exit 0
    fi
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
      # falls back to deriving owner/repo from the origin URL.
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
      # `--json headRefOid` asks for the head sha the superseded-
      # failure correlation scopes its Actions-runs query to.
      for _a in "$@"; do
        if [[ "$_a" == "headRefOid" ]]; then
          echo "${STUB_HEAD_SHA:-737bce791577e140436490e0fed5751bb5144a61}"
          exit 0
        fi
      done
      echo "CLEAN"
      exit 0
    fi
    if [[ "${2:-}" == "checks" ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      if [[ -n "${STUB_PR_CHECKS_FIXTURE:-}" ]]; then
        cat "$STUB_PR_CHECKS_FIXTURE"
        exit "${STUB_PR_CHECKS_EXIT:-0}"
      fi
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
      # an OLD superseded run (RUN_ID 29098545030) left several
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
      # Once the NEW run recreates a named job (Lint on
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
  run)
    _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
    # the staged failed-job log is replayed a line at a time so this
    # stub is a writer that BLOCKS on a full pipe, the way gh streams a log —
    # a reader closing early then kills it with SIGPIPE at the 64KB pipe
    # capacity. `cat` would not: reading a file it pushes several hundred KB
    # before it ever blocks, which would make the size the case needs a
    # property of coreutils rather than of the pipe.
    if [[ "${2:-}" == "view" ]]; then
      if [[ -n "${STUB_RUN_LOG_FILE:-}" ]]; then
        while IFS= read -r _line; do printf '%s\n' "$_line"; done < "$STUB_RUN_LOG_FILE"
        exit 0
      fi
      echo "no log staged" >&2
      exit 1
    fi
    if [[ "${2:-}" == "rerun" ]]; then
      if [[ -n "${STUB_RERUN_CALLS_FILE:-}" ]]; then
        printf '%s\n' "$*" >> "$STUB_RERUN_CALLS_FILE"
      fi
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
printf 'op called: %s\n' "\$*" >>"\${STUB_OP_CALLS_FILE:-$TMP_ROOT/op.calls}"
exit 1
EOF
chmod +x "$TMP_ROOT/bin/op"

# Virtual clock, on the same PATH as the gh stub: `date +%s` reads a file the
# `sleep` stub advances, so every poll budget below is spent in arithmetic
# rather than in real seconds. Rationale in lib/virtual-clock.sh, along with the
# escape hatch case 7 takes — its hanging-auth stub needs a real sleep, so it
# runs with STUB_CLOCK= and both stubs fall through to the real commands.
# shellcheck source=lib/virtual-clock.sh
source "$TEST_DIR/lib/virtual-clock.sh"
virtual_clock_install "$TMP_ROOT/bin" "$TMP_ROOT/clock"

# --- harness -----------------------------------------------------------------

FX="$REPO_ROOT/skills/orch/tests/fixtures/ci-wait"
INCIDENT_HEAD=e99849b1c72b1c082cf8325f316799e753f99561
DEFAULT_HEAD=737bce791577e140436490e0fed5751bb5144a61

# run_wait ENV ARGS... — runs ci-wait via the .agents symlink, exactly how
# production invokes it, in the fixture repo with the stub PATH. ENV is a
# comma-separated list of `env` arguments (assignments or `-u NAME`); every run
# gets its own count, capture and stderr files under $RUN, so no row reads
# another's polls or calls. Sets OUT and RC.
RUN_SEQ=0
run_wait() {
  local env_list="$1" env_args=()
  shift
  RUN="$TMP_ROOT/runs/$((++RUN_SEQ))"
  mkdir -p "$RUN"
  [[ -z "$env_list" ]] || IFS=',' read -ra env_args <<<"$env_list"
  set +e
  OUT=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" \
    env ${env_args[@]+"${env_args[@]}"} \
        STUB_GH_API_USER_COUNT_FILE="$RUN/api-user-calls" \
        STUB_PR_CHECKS_COUNT_FILE="$RUN/checks-polls" \
        STUB_REPO_ARG_FILE="$RUN/repo-arg" \
        STUB_ACTIONS_RUNS_QUERY_FILE="$RUN/runs-query" \
        STUB_RERUN_CALLS_FILE="$RUN/rerun-calls" \
        STUB_OP_CALLS_FILE="$RUN/op-calls" \
        .agents/skills/orch/scripts/ci-wait "$@" 2>"$RUN/stderr")
  RC=$?
  set -e
}

json() { jq -r "$1" <<<"$OUT" 2>/dev/null || echo UNPARSEABLE; }
needle() { printf '%s' "${1//+/ }"; }

# observe EXPECT — prints the run's value of every `name=` field EXPECT names,
# in EXPECT's order, so a row compares as one string. Plain names are JSON
# result fields; the derived names read the run's files or the output:
#   passed / failed / pending   the length of that checks array
#   check.<name>                the state of that check in any array, or
#                               absent (`+` in the name reads as a space, so
#                               an identifier's own underscores stay)
#   count.<name>                how many entries carry that name
#   out~<text>, stdout~<text>, stderr~<text>
#                               whether the JSON, stdout or stderr carries
#                               <text> (`+` reads as a space)
#   stdout / stderr             `line` when anything was printed, else `empty`
#   error_named                 whether the JSON error field is a non-empty string
#   api_user_calls              `gh api user` validations the stub served
#   checks_polls                `gh pr checks` reads the stub served
#   repo_arg                    the --repo slug ci-wait passed to gh pr
#   runs_head                   the head_sha the Actions-runs query scoped to
#   reruns                      run ids `gh run rerun` received, or none
#   op_calls                    `op` invocations, or none
observe() {
  local got="" token name value n
  for token in $1; do
    name="${token%%=*}"
    case "$name" in
      rc) value="$RC" ;;
      passed|failed|pending) value="$(json ".${name}_checks | length")" ;;
      check.*)
        n="$(needle "${name#check.}")"
        value="$(jq -r --arg n "$n" '[.passed_checks[]?, .pending_checks[]?, .failed_checks[]? | select(.name == $n)] | if length == 0 then "absent" else .[0].state end' <<<"$OUT" 2>/dev/null || echo UNPARSEABLE)"
        ;;
      count.*)
        n="$(needle "${name#count.}")"
        value="$(jq -r --arg n "$n" '[.passed_checks[]?, .pending_checks[]?, .failed_checks[]? | select(.name == $n)] | length' <<<"$OUT" 2>/dev/null || echo UNPARSEABLE)"
        ;;
      out~*|stdout~*) value="$(grep -qF -- "$(needle "${name#*~}")" <<<"$OUT" && echo true || echo false)" ;;
      stderr~*) value="$(grep -qF -- "$(needle "${name#stderr~}")" "$RUN/stderr" && echo true || echo false)" ;;
      stdout) value="$([[ -n "$OUT" ]] && echo line || echo empty)" ;;
      stderr) value="$([[ -s "$RUN/stderr" ]] && echo line || echo empty)" ;;
      error_named) value="$(json '(.error | type) == "string" and .error != ""')" ;;
      api_user_calls) value="$(cat "$RUN/api-user-calls" 2>/dev/null || echo 0)" ;;
      checks_polls) value="$(cat "$RUN/checks-polls" 2>/dev/null || echo 0)" ;;
      repo_arg) value="$(cat "$RUN/repo-arg" 2>/dev/null || echo none)" ;;
      runs_head) value="$(grep -o 'head_sha=[0-9a-f]*' "$RUN/runs-query" 2>/dev/null | head -1 | cut -d= -f2 || true)"; value="${value:-none}" ;;
      reruns) value="$(grep -o 'run rerun [0-9]*' "$RUN/rerun-calls" 2>/dev/null | awk '{print $3}' | paste -sd, - || true)"; value="${value:-none}" ;;
      op_calls) value="$(wc -l <"$RUN/op-calls" 2>/dev/null | tr -d ' ' || true)"; value="${value:-none}" ;;
      *) value="$(json ".$name")" ;;
    esac
    got="$got $name=$value"
  done
  printf '%s' "${got# }"
}

# stage SPEC — the repo-side fixture one row needs: `envlocal=<line>` writes
# that line to .env.local (`envlocal=` removes it), `origin=<url>` sets the
# origin remote. Several items separate with `;`. Every row's stage is applied
# from a clean repo.
stage() {
  local spec="$1" items item
  rm -f "$TMP_ROOT/repo/.env.local"
  git -C "$TMP_ROOT/repo" remote remove origin 2>/dev/null || true
  [[ -n "$spec" ]] || return 0
  IFS=';' read -ra items <<<"$spec"
  for item in "${items[@]}"; do
    case "$item" in
      envlocal=) ;;
      envlocal=*) printf '%s\n' "${item#envlocal=}" > "$TMP_ROOT/repo/.env.local" ;;
      origin=*) git -C "$TMP_ROOT/repo" remote add origin "${item#origin=}" ;;
      *) echo "stage: unknown item $item" >&2; exit 1 ;;
    esac
  done
}

# table DEFAULT_ARGS ROW... — one run and one assertion per row. A row is
# `label|stage|args|env|expect`; empty args mean DEFAULT_ARGS. Positional args
# are `<pr> <poll-interval> <budget-seconds>` plus flags, on the virtual clock.
table() {
  local default_args="$1" row label spec args env expect
  shift
  for row in "$@"; do
    IFS='|' read -r label spec args env expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    [[ -n "$args" ]] || args="$default_args"
    stage "$spec"
    # shellcheck disable=SC2086
    run_wait "$env" $args
    assert_eq "$(observe "$expect")" "$expect" "$label" "$RUN/stderr"
  done
}

JSON='1 1 30 --json'
JSON_SHORT='1 1 5 --json'

echo "=== the auth ladder: env token, keyring, bot token ==="
# A stale inherited token is unset with a warning and the keyring tried; with
# the keyring denied, .env.local's GH_BOT_TOKEN recovers; an inherited bot
# token wins over a project op:// reference without reading it; a valid
# selected token is validated once and ignores a stale keyring status.
table "$JSON" \
  'a stale GH_TOKEN is unset with a warning and the keyring works|||GH_TOKEN=bad-token|rc=0 verdict=pass stderr~unsetting+them=true' \
  'no env tokens: the keyring works with no warning||||rc=0 verdict=pass stderr~unsetting+them=false' \
  'stale token, keyring denied, no bot token: exit 3 with a named error|envlocal=||GH_TOKEN=bad-token,STUB_GH_DENY_KEYRING=1|rc=3 status=error error_named=true' \
  'stale token, keyring denied: .env.local GH_BOT_TOKEN recovers, each token validated once|envlocal=export GH_BOT_TOKEN=ghs_VALIDBOT123||GH_TOKEN=bad-token,STUB_GH_DENY_KEYRING=1,STUB_GH_VALID_TOKEN=ghs_VALIDBOT123|rc=0 verdict=pass api_user_calls=2' \
  'an inherited GH_BOT_TOKEN wins over the project op:// reference, which is never read|envlocal=export GH_BOT_TOKEN=op://vault/github/bot||GH_BOT_TOKEN=ghs_ENVBOT123,STUB_GH_DENY_KEYRING=1,STUB_GH_VALID_TOKEN=ghs_ENVBOT123|rc=0 verdict=pass op_calls=none' \
  'a valid selected token validates once and ignores a stale keyring status|||GH_TOKEN=ghs_VALIDUSER123,STUB_GH_VALID_TOKEN=ghs_VALIDUSER123,STUB_GH_AUTH_STATUS_FAIL=1|rc=0 verdict=pass stderr~unsetting+them=false api_user_calls=1'

# A hanging keyring auth is bounded: the one case off the virtual clock, since
# the hang is what is under test (STUB_CLOCK= sends the stub's sleep to the
# real one, leaving the preflight a wait to bound).
stage ""
RUN="$TMP_ROOT/runs/$((++RUN_SEQ))"; mkdir -p "$RUN"
set +e
# The 6s bound is a net under ci-wait's own KENDEX_GITHUB_AUTH_TIMEOUT, which
# is what the assertion reads. macOS ships no timeout(1) — it is coreutils —
# so on a host without one the case runs unbounded and a regression that did
# hang would be caught by the job's timeout-minutes instead of here.
bounded6() { # CMD... — run CMD under a 6s bound where the host has one
  if command -v timeout >/dev/null 2>&1; then
    timeout 6s "$@"
  else
    "$@"
  fi
}
OUT=$(bounded6 bash -c 'cd "$1" && PATH="$2:$PATH" STUB_CLOCK= KENDEX_GITHUB_AUTH_TIMEOUT=1 STUB_GH_AUTH_STATUS_SLEEP=1 .agents/skills/orch/scripts/ci-wait 1 1 30 --json' bash "$TMP_ROOT/repo" "$TMP_ROOT/bin" 2>"$RUN/stderr")
RC=$?
set -e
assert_eq "$(observe "rc=3 status=error")" "rc=3 status=error" "a hanging keyring auth is a bounded exit 3, not a hang" "$RUN/stderr"

echo "=== the verdict over the checks sequence ==="
# A pending exit code with valid JSON keeps polling; WAITING/REQUESTED/EXPECTED
# are pending even without a bucket; pending at the deadline is a timeout,
# never success or silence; no checks registered is pending inside the
# CI_WAIT_NO_CHECKS_GRACE window and an error past it; a settled failure is
# terminal; an auth failure is a parseable error object.
table "$JSON" \
  'a pending exit with valid JSON keeps polling|||STUB_PR_CHECKS_MODE=pending_once|rc=0 verdict=pass checks_polls=2' \
  "an EXPECTED check is pending until it clears||$JSON_SHORT|STUB_PR_CHECKS_MODE=expected_once|rc=0 verdict=pass checks_polls=2" \
  'a pass is complete with its checks listed||||rc=0 status=complete verdict=pass passed=1' \
  "checks still in progress at the deadline are a timeout||$JSON_SHORT|STUB_PR_CHECKS_MODE=pending_always|rc=1 status=timeout verdict=pending check.build=IN_PROGRESS" \
  'no checks registered past the grace window is a named error|||STUB_PR_CHECKS_MODE=empty,CI_WAIT_NO_CHECKS_GRACE=3|rc=1 status=error error_named=true' \
  "no checks registered inside the default grace window stays pending||$JSON_SHORT|STUB_PR_CHECKS_MODE=empty|rc=1 status=timeout verdict=pending" \
  'a settled failing check is a complete fail|||STUB_PR_CHECKS_MODE=failure|rc=1 status=complete verdict=fail check.build=FAILURE' \
  'an auth failure with --json is a parseable error object naming its cause|||GH_TOKEN=bad-token,STUB_GH_DENY_KEYRING=1|rc=3 status=error error_named=true'

echo "=== text mode prints a result line for every terminal status ==="
# The line beyond its leading words is not a contract anything parses; the
# leading words are text-only, so a JSON default flip fails these rows.
table '1 1 30' \
  'passed||||rc=0 stdout~CI+passed=true' \
  'failed|||STUB_PR_CHECKS_MODE=failure|rc=1 stdout~CI+failed=true' \
  'timeout||1 1 5|STUB_PR_CHECKS_MODE=pending_always|rc=1 stdout~CI+timeout=true' \
  'error|||STUB_PR_CHECKS_MODE=empty,CI_WAIT_NO_CHECKS_GRACE=3|rc=1 stdout~CI+error=true'

echo "=== the repo slug falls back to the origin URL without its .git suffix ==="
# When `gh repo view` answers empty, owner/repo comes from the origin URL; the
# stub rejects a `.git`-suffixed --repo the way gh does, so a pass proves the
# suffix was stripped and the path segment kept.
table "$JSON" \
  'an ssh origin ending in .git|origin=git@github.com:owner/repo.git||STUB_GH_REPO_VIEW_EMPTY=1|rc=0 verdict=pass repo_arg=owner/repo' \
  'an https origin ending in .git|origin=https://github.com/owner/repo.git||STUB_GH_REPO_VIEW_EMPTY=1|rc=0 verdict=pass repo_arg=owner/repo' \
  'an https origin without .git keeps its last segment|origin=https://github.com/owner/repo||STUB_GH_REPO_VIEW_EMPTY=1|rc=0 verdict=pass repo_arg=owner/repo'

echo "=== checks are scoped to the latest run per workflow ==="
# An older cancelled run's jobs are not current failures while the newer run
# has only its classifier pending; once the newer run recreates a job by name,
# that instance replaces the cancelled one.
table "$JSON" \
  "a superseded run's cancelled jobs are dropped, the current classifier stays pending||$JSON_SHORT|STUB_PR_CHECKS_MODE=superseded_pending|rc=1 status=timeout verdict=pending failed=0 check.Changes=IN_PROGRESS check.Lint=absent check.Linux+Integration=absent" \
  'a job the newer run recreated replaces the cancelled one by name|||STUB_PR_CHECKS_MODE=superseded_replaced|rc=0 verdict=pass failed=0 count.Lint=1 check.Lint=SUCCESS out~CANCELLED=false'

echo "=== approval-gated run and status correlation ==="
# A stale pre-approval CI Required failure stays pending while an approved
# run is active, is not superseded by a later all-skipped run, stays terminal
# with no fresh substantive run, fails at once when the approved run fails,
# waits for the replacement status, and passes once it is published.
table "$JSON" \
  "an active approved run keeps the stale failure pending; an all-skipped later run does not supersede||$JSON_SHORT|STUB_PR_CHECKS_FIXTURE=$FX/stale-preapproval-active-approved.json,STUB_PR_CHECKS_EXIT=8|rc=1 status=timeout verdict=pending failed=0 check.CI+Required=EXPECTED check.Build=IN_PROGRESS out~SKIPPED=false" \
  "no fresh substantive run: the pre-approval failure is terminal|||STUB_PR_CHECKS_FIXTURE=$FX/stale-preapproval-no-fresh-run.json,STUB_PR_CHECKS_EXIT=1|rc=1 status=complete verdict=fail check.CI+Required=FAILURE" \
  "a failed approved run fails at once|||STUB_PR_CHECKS_FIXTURE=$FX/stale-preapproval-fresh-failed.json,STUB_PR_CHECKS_EXIT=1|rc=1 status=complete verdict=fail check.Build=FAILURE" \
  "approved jobs passed but the aggregate lags: pending to the bounded timeout||$JSON_SHORT|STUB_PR_CHECKS_FIXTURE=$FX/stale-preapproval-status-lag.json,STUB_PR_CHECKS_EXIT=1|rc=1 status=timeout verdict=pending check.CI+Required=EXPECTED" \
  "the replacement status published against the approved run passes|||STUB_PR_CHECKS_FIXTURE=$FX/approved-status-replaced.json|rc=0 status=complete verdict=pass check.CI+Required=SUCCESS failed=0"

echo "=== a settled failure attributable only to superseded runs is correlated against the head's Actions runs ==="
# The rollup can omit a newer same-head run entirely; an active newer
# substantive run keeps the wait pending, a successful one discards the stale
# failures, a failed one or none at all stays terminal. The query scopes to
# the current head.
table "$JSON" \
  "an active newer sibling keeps the cancelled run's failure pending, queried for the head||$JSON_SHORT|STUB_PR_CHECKS_FIXTURE=$FX/cancelled-review-run-checks.json,STUB_PR_CHECKS_EXIT=1,STUB_ACTIONS_RUNS_FIXTURE=$FX/runs-newer-sibling-active.json|rc=1 status=timeout verdict=pending failed=0 check.CI+Required=EXPECTED check.CI+Gate+Publisher=EXPECTED runs_head=$DEFAULT_HEAD" \
  "a successful newer sibling discards the frozen failures and passes|||STUB_PR_CHECKS_FIXTURE=$FX/cancelled-review-run-status-replaced.json,STUB_PR_CHECKS_EXIT=1,STUB_ACTIONS_RUNS_FIXTURE=$FX/runs-newer-sibling-success.json|rc=0 status=complete verdict=pass failed=0 check.CI+Required=SUCCESS" \
  "a failed newer sibling is terminal at once|||STUB_PR_CHECKS_FIXTURE=$FX/cancelled-review-run-checks.json,STUB_PR_CHECKS_EXIT=1,STUB_ACTIONS_RUNS_FIXTURE=$FX/runs-newer-sibling-failure.json|rc=1 status=complete verdict=fail check.CI+Required=FAILURE" \
  "a cancelled run with no newer sibling fails closed|||STUB_PR_CHECKS_FIXTURE=$FX/cancelled-review-run-checks.json,STUB_PR_CHECKS_EXIT=1,STUB_ACTIONS_RUNS_FIXTURE=$FX/runs-cancelled-alone.json|rc=1 status=complete verdict=fail check.CI+Gate+Publisher=FAILURE"

echo "=== a rerun attempt under an older run id is current-head work ==="
# A rerun keeps its original run id and creation time, so no newer id exists;
# the in-flight attempt keeps the wait pending and its completed success
# supersedes through its fresher updated_at; a failed attempt is terminal by
# the same arm the failed newer sibling above proves.
RERUN="STUB_PR_CHECKS_EXIT=1,STUB_HEAD_SHA=$INCIDENT_HEAD"
table "$JSON" \
  "an in-flight attempt of an older run keeps the cancelled failure pending||$JSON_SHORT|STUB_PR_CHECKS_FIXTURE=$FX/rerun-attempt-checks.json,$RERUN,STUB_ACTIONS_RUNS_FIXTURE=$FX/runs-rerun-attempt-active.json|rc=1 status=timeout verdict=pending failed=0 check.CI+Required=EXPECTED check.CI+Gate+Publisher=EXPECTED runs_head=$INCIDENT_HEAD" \
  "a successful attempt supersedes through its fresher updated_at|||STUB_PR_CHECKS_FIXTURE=$FX/rerun-attempt-status-replaced.json,$RERUN,STUB_ACTIONS_RUNS_FIXTURE=$FX/runs-rerun-attempt-success.json|rc=0 status=complete verdict=pass failed=0 check.CI+Required=SUCCESS"

echo "=== the transient-failure retry reads a log past the pipe buffer ==="
# Under `gh ... | head -200`, head closing after its lines kills gh with
# SIGPIPE, pipefail promotes the 141, and the retry is dead for every log big
# enough to need it. Two sizes carry the case and both are asserted rather
# than assumed: the scanned window clears two 64KB pipe buffers, the log past
# it one more. The marker sits on the first line, where a runner-acquisition
# failure reports it. A genuine gh failure is still not transient.
transient_log="$TMP_ROOT/transient-log"
{
  printf 'The job was not acquired: rate limit exceeded, retrying in 30s\n'
  padding="$(printf 'x%.0s' {1..950})"
  for _i in $(seq 1 400); do
    printf '2026-09-02T10:00:00Z  compiling crate %s\n' "$padding"
  done
} > "$transient_log"
transient_window_bytes=$(head -n 200 "$transient_log" | wc -c)
transient_tail_bytes=$(($(wc -c <"$transient_log") - transient_window_bytes))
assert_le 131072 "$transient_window_bytes" "two pipe buffers fit inside the scanned window"
assert_le 65536 "$transient_tail_bytes" "one pipe buffer fits inside the log past the window"
table "$JSON" \
  "a transient marker in a large failed-job log reruns the failing run; the retried failure still settles terminal|||STUB_PR_CHECKS_FIXTURE=$FX/rerun-attempt-checks.json,$RERUN,STUB_ACTIONS_RUNS_FIXTURE=$FX/runs-rerun-attempt-failure.json,STUB_RUN_LOG_FILE=$transient_log|rc=1 verdict=fail reruns=29662812172" \
  "a gh failure reading the log is not transient: nothing is rerun|||STUB_PR_CHECKS_FIXTURE=$FX/rerun-attempt-checks.json,$RERUN,STUB_ACTIONS_RUNS_FIXTURE=$FX/runs-rerun-attempt-failure.json|rc=1 verdict=fail reruns=none"

echo "=== argument validation ends in the parser, before any gh call ==="
# The recording gh stub fails every call, so a case that reached auth or a
# poll reads as calls > 0. references/gates.md names each script's --help as
# its authoritative contract, so the help row pins the exit-code table, the
# no-CI route and the grace knob. The unknown flag follows complete
# positionals: in a positional slot it would be refused as a non-integer, the
# same exit, so only that shape proves the flag arm.
mkdir -p "$TMP_ROOT/argbin"
cat > "$TMP_ROOT/argbin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP_ROOT/argval-gh.calls"
exit 1
EOF
chmod +x "$TMP_ROOT/argbin/gh"
arg_rows=(
  '--help prints the routed contract and exits 0|--help|rc=0 stdout~Exit+codes:=true stdout~no-CI+route=true stdout~CI_WAIT_NO_CHECKS_GRACE=true gh_calls=0'
  '-h is the same|-h|rc=0 stdout~Exit+codes:=true gh_calls=0'
  'an unknown flag after complete positionals is refused in the parser|1 1 30 --nope|rc=2 stdout=empty stderr=line gh_calls=0'
  'a non-integer PR number is a usage error|abc|rc=2 stdout=empty stderr=line gh_calls=0'
  'a non-integer poll_interval is a usage error|1 abc 30|rc=2 stdout=empty stderr=line gh_calls=0'
  'a non-integer max_wait is a usage error|1 15 abc|rc=2 stdout=empty stderr=line gh_calls=0'
  'no arguments is a usage error||rc=2 stdout=empty stderr=line gh_calls=0'
)
for row in "${arg_rows[@]}"; do
  IFS='|' read -r label args expect <<<"$row"
  [[ -n "$expect" ]] || { printf 'args: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
  : > "$TMP_ROOT/argval-gh.calls"
  RUN="$TMP_ROOT/runs/$((++RUN_SEQ))"; mkdir -p "$RUN"
  set +e
  # shellcheck disable=SC2086
  OUT=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/argbin:$PATH" .agents/skills/orch/scripts/ci-wait $args 2>"$RUN/stderr")
  RC=$?
  set -e
  got="$(observe "${expect% gh_calls=*}") gh_calls=$(wc -l <"$TMP_ROOT/argval-gh.calls" | tr -d ' ')"
  assert_eq "$got" "$expect" "$label" "$RUN/stderr"
done

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
