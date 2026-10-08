#!/usr/bin/env bash
# Tests for orch/scripts/ci-wait: the auth ladder (env token, keyring, bot
# token), the deterministic result contract (pass, fail, timeout, error, on
# stdout in both modes, pending at the deadline never silent), the no-checks
# registration grace, and the run correlations that keep an active run or
# unreadable head-run evidence from passing and keep a stale or
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
TMP_ROOT="$(mktemp -d)" || { echo 'ci_wait: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "ci_wait: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'ci_wait: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf "$TMP_ROOT"' EXIT

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"

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
    # A probe that charges the virtual clock, to prove the waiter counts it.
    if [[ "${2:-}" == repos/*/actions/workflows && -n "${STUB_PROBE_COST:-}" ]]; then
      sleep "$STUB_PROBE_COST"
    fi
    # Settled-verdict correlation queries the head's Actions
    # runs. Record the query when asked so tests can prove head-sha scoping.
    if [[ "${2:-}" == repos/*/actions/runs* ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      : > "$STUB_PR_CHECKS_COUNT_FILE.actions-read"
      if [[ -n "${STUB_ACTIONS_RUNS_QUERY_FILE:-}" ]]; then
        printf '%s' "$2" > "$STUB_ACTIONS_RUNS_QUERY_FILE"
      fi
      if [[ "${STUB_ACTIONS_RUNS_EXIT:-0}" != 0 ]]; then
        printf 'HTTP 403: Resource not accessible by integration\n' >&2
        echo '{"workflow_runs":[]}'
        exit "$STUB_ACTIONS_RUNS_EXIT"
      fi
      paginate=false
      slurp=false
      for arg in "$@"; do
        [[ "$arg" != --paginate ]] || paginate=true
        [[ "$arg" != --slurp ]] || slurp=true
      done
      fixture="${STUB_ACTIONS_RUNS_FIXTURE:-}"
      if [[ -n "${STUB_HEAD_DURING_ACTIONS:-}" ]]; then
        : > "$STUB_PR_CHECKS_COUNT_FILE.actions-pushed"
        if [[ "$2" == *"head_sha=$STUB_HEAD_DURING_ACTIONS&"* && -n "${STUB_ACTIONS_NEXT_HEAD_FIXTURE:-}" ]]; then
          fixture="$STUB_ACTIONS_NEXT_HEAD_FIXTURE"
        fi
      fi
      if [[ -n "${STUB_ACTIONS_RUNS_RELEASE_AFTER:-}" ]] && [[ "$(cat "$STUB_PR_CHECKS_COUNT_FILE")" -gt "$STUB_ACTIONS_RUNS_RELEASE_AFTER" ]]; then
        fixture="$STUB_ACTIONS_RUNS_RELEASE_FIXTURE"
      fi
      if [[ -n "$fixture" ]]; then
        pages=$(jq -c 'if type == "array" then . else [. + {total_count: (.workflow_runs | length)}] end' "$fixture")
      else
        pages='[{"total_count":0,"workflow_runs":[]}]'
      fi
      if ! $paginate || [[ "${STUB_ACTIONS_RUNS_LATE_EXIT:-0}" != 0 ]]; then
        pages=$(jq -c '.[0:1]' <<<"$pages")
      fi
      if $slurp; then
        printf '%s\n' "$pages"
      else
        jq -c '.[]' <<<"$pages"
      fi
      if $paginate && [[ "${STUB_ACTIONS_RUNS_LATE_EXIT:-0}" != 0 ]]; then
        printf 'HTTP 403: Resource not accessible by integration\n' >&2
        exit "$STUB_ACTIONS_RUNS_LATE_EXIT"
      fi
      exit 0
    fi
    if [[ -n "${STUB_REQUIRED_CONTEXT:-}" ]]; then
      if [[ "${2:-}" == repos/*/rules/branches/* ]]; then
        [[ "${STUB_REQUIRED_READ_EXIT:-0}" == 0 ]] || exit "$STUB_REQUIRED_READ_EXIT"
        printf 'ctx:%s\n' "$STUB_REQUIRED_CONTEXT"
        exit 0
      fi
      if [[ "${2:-}" == repos/*/branches/* ]]; then
        echo '{"protection":{"required_status_checks":{"contexts":[]}}}'
        exit 0
      fi
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
      echo "owner/repo"
      exit 0
    fi
    ;;
  pr)
    # Capture the --repo slug ci-wait resolved.
    _repo_arg=""
    _prev=""
    for _a in "$@"; do
      [[ "$_prev" == "--repo" ]] && _repo_arg="$_a"
      _prev="$_a"
    done
    if [[ -n "${STUB_REPO_ARG_FILE:-}" && -n "$_repo_arg" ]]; then
      printf '%s' "$_repo_arg" > "$STUB_REPO_ARG_FILE"
    fi
    if [[ "${2:-}" == "view" ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      # A checks sequence can move to another head after the first poll,
      # as GitHub does when a push lands while a waiter remains active.
      for _a in "$@"; do
        if [[ "$_a" == "headRefOid" ]]; then
          if [[ "${STUB_HEAD_AFTER_ACTIONS_EXIT:-0}" != 0 && -f "$STUB_PR_CHECKS_COUNT_FILE.actions-read" ]]; then
            printf 'HTTP 403: Resource not accessible by integration\n' >&2
            exit "$STUB_HEAD_AFTER_ACTIONS_EXIT"
          fi
          if [[ "${STUB_HEAD_EXIT:-0}" != 0 ]]; then
            printf 'HTTP 403: Resource not accessible by integration\n' >&2
            exit "$STUB_HEAD_EXIT"
          fi
          if [[ -n "${STUB_HEAD_DURING_CHECKS:-}" && -f "$STUB_PR_CHECKS_COUNT_FILE.pushed" ]]; then
            echo "$STUB_HEAD_DURING_CHECKS"
            exit 0
          fi
          if [[ -n "${STUB_HEAD_DURING_ACTIONS:-}" && -f "$STUB_PR_CHECKS_COUNT_FILE.actions-pushed" ]]; then
            echo "$STUB_HEAD_DURING_ACTIONS"
            exit 0
          fi
          if [[ -n "${STUB_NEXT_HEAD_SHA:-}" ]] && [[ "$(cat "$STUB_CLOCK")" -ge "$((STUB_RUN_STARTED + 30))" ]]; then
            echo "$STUB_NEXT_HEAD_SHA"
            exit 0
          fi
          echo "${STUB_HEAD_SHA:-737bce791577e140436490e0fed5751bb5144a61}"
          exit 0
        fi
        if [[ "$_a" == "baseRefName" && -n "${STUB_REQUIRED_CONTEXT:-}" ]]; then
          echo main
          exit 0
        fi
      done
      echo "CLEAN"
      exit 0
    fi
    if [[ "${2:-}" == "checks" ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      [[ -z "${STUB_HEAD_DURING_CHECKS:-}" ]] || : > "$STUB_PR_CHECKS_COUNT_FILE.pushed"
      if [[ -n "${STUB_CHECKS_AFTER_ACTIONS_FIXTURE:-}" && -f "$STUB_PR_CHECKS_COUNT_FILE.actions-read" ]]; then
        cat "$STUB_CHECKS_AFTER_ACTIONS_FIXTURE"
        exit 0
      fi
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
      # One rollup per poll, from STUB_PR_CHECKS_SEQUENCE: colon-separated
      # tokens (a row's env list separates on commas), the count file giving
      # the poll index, the last token repeating. `fail_rerun` phases on the
      # rerun the script itself requests rather than on the index, because the
      # retry path reads the rollup a second time through get_failed_run_id.
      if [[ -n "${STUB_PR_CHECKS_SEQUENCE:-}" ]]; then
        count=0
        if [[ -f "${STUB_PR_CHECKS_COUNT_FILE:?}" ]]; then
          count="$(cat "$STUB_PR_CHECKS_COUNT_FILE")"
        fi
        count=$((count + 1))
        printf '%s' "$count" > "$STUB_PR_CHECKS_COUNT_FILE"
        IFS=':' read -ra toks <<<"$STUB_PR_CHECKS_SEQUENCE"
        idx=$((count - 1))
        [[ "$idx" -lt "${#toks[@]}" ]] || idx=$((${#toks[@]} - 1))
        case "${toks[$idx]}" in
          green)   echo '[{"name":"build","state":"SUCCESS"}]'; exit 0 ;;
          green2)  echo '[{"name":"build","state":"SUCCESS"},{"name":"lint","state":"SUCCESS"}]'; exit 0 ;;
          mixed)   echo '[{"name":"build","state":"SUCCESS"},{"name":"docs","state":"SKIPPED"}]'; exit 0 ;;
          skipped) echo '[{"name":"build","state":"SKIPPED"}]'; exit 0 ;;
          pending) echo '[{"name":"build","state":"IN_PROGRESS"}]'; exit 8 ;;
          request) cat "$STUB_REQUEST_CHECK_FIXTURE"; exit 0 ;;
          empty)   echo '[]'; exit 0 ;;
          fail_rerun)
            [[ ! -s "${STUB_RERUN_CALLS_FILE:-/dev/null}" ]] || { echo '[{"name":"build","state":"SUCCESS"}]'; exit 0; }
            echo '[{"name":"build","state":"FAILURE","bucket":"fail","link":"https://github.com/owner/repo/actions/runs/29099680623/job/301","workflow":"CI","startedAt":"2026-07-10T11:00:00Z"}]'
            exit 1
            ;;
          *) printf 'unknown sequence token: %s\n' "${toks[$idx]}" >&2; exit 1 ;;
        esac
      fi
      if [[ "${STUB_PR_CHECKS_MODE:-}" == "pending_always" ]]; then
        echo '[{"name":"build","state":"IN_PROGRESS"}]'
        exit 8
      fi
      if [[ "${STUB_PR_CHECKS_MODE:-}" == "empty" ]]; then
        # A first read that charges the virtual clock before its answer.
        if [[ -n "${STUB_FIRST_CHECKS_COST:-}" && ! -f "${STUB_PR_CHECKS_COUNT_FILE:?}.charged" ]]; then
          : > "$STUB_PR_CHECKS_COUNT_FILE.charged"
          sleep "$STUB_FIRST_CHECKS_COST"
        fi
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
    env -u GH_REPO ${env_args[@]+"${env_args[@]}"} \
        STUB_GH_API_USER_COUNT_FILE="$RUN/api-user-calls" \
        STUB_RUN_STARTED="$(cat "$STUB_CLOCK")" \
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
#   mail                        the count on a `ci-wait: mail=` stdout line
#   mail_unreadable             the path on a `ci-wait: mail-unreadable=` line
#   stderr_first~<text>         whether stderr's first line is <text>
#   rollup.<name>               whether the JSON rollup_key names that check
#   lookup_http_status          upstream HTTP status preserved on stderr
observe() {
  local got="" token name value n
  for token in $1; do
    name="${token%=*}"
    case "$name" in
      rc) value="$RC" ;;
      passed|failed|pending) value="$(json ".${name}_checks | length")" ;;
      check.*)
        n="$(needle "${name#check.}")"
        value="$(jq -r --arg n "$n" '[.passed_checks[]?, .pending_checks[]?, .failed_checks[]? | select(.name == $n)] | if length == 0 then "absent" else .[0].state end' <<<"$OUT" 2>/dev/null || echo UNPARSEABLE)"
        ;;
      rollup.*)
        n="$(needle "${name#rollup.}")"
        value="$(jq -r --arg n "$n" '.rollup_key | fromjson | any(.[]; .name == $n)' <<<"$OUT" 2>/dev/null || echo UNPARSEABLE)"
        ;;
      count.*)
        n="$(needle "${name#count.}")"
        value="$(jq -r --arg n "$n" '[.passed_checks[]?, .pending_checks[]?, .failed_checks[]? | select(.name == $n)] | length' <<<"$OUT" 2>/dev/null || echo UNPARSEABLE)"
        ;;
      out~*|stdout~*) value="$(grep -qF -- "$(needle "${name#*~}")" <<<"$OUT" && echo true || echo false)" ;;
      stderr~*) value="$(grep -qF -- "$(needle "${name#stderr~}")" "$RUN/stderr" && echo true || echo false)" ;;
      stdout) value="$([[ -n "$OUT" ]] && echo line || echo empty)" ;;
      stderr) value="$([[ -s "$RUN/stderr" ]] && echo line || echo empty)" ;;
      lookup_http_status) value="$(sed -n 's/^HTTP \([0-9]*\):.*/\1/p' "$RUN/stderr" | sort -u)" ;;
      error_named) value="$(json '(.error | type) == "string" and .error != ""')" ;;
      api_user_calls) value="$(cat "$RUN/api-user-calls" 2>/dev/null || echo 0)" ;;
      checks_polls) value="$(cat "$RUN/checks-polls" 2>/dev/null || echo 0)" ;;
      repo_arg) value="$(cat "$RUN/repo-arg" 2>/dev/null || echo none)" ;;
      runs_head) value="$(grep -o 'head_sha=[0-9a-f]*' "$RUN/runs-query" 2>/dev/null | head -1 | cut -d= -f2 || true)"; value="${value:-none}" ;;
      reruns) value="$(grep -o 'run rerun [0-9]*' "$RUN/rerun-calls" 2>/dev/null | awk '{print $3}' | paste -sd, - || true)"; value="${value:-none}" ;;
      mail_unreadable) value="$(sed -n '1s/^ci-wait: mail-unreadable=//p' <<<"$OUT")" ;;
      stderr_first~*) value="$([[ "$(sed -n '1p' "$RUN/stderr")" == "$(needle "${name#stderr_first~}")" ]] && echo true || echo false)" ;;
      mail) value="$(sed -n '1s/^ci-wait: mail=\([0-9]*\)$/\1/p' <<<"$OUT")" ;;
      op_calls) value="$(wc -l <"$RUN/op-calls" 2>/dev/null | tr -d ' ' || true)"; value="${value:-none}" ;;
      *) value="$(json ".$name")" ;;
    esac
    got="$got $name=$value"
  done
  printf '%s' "${got# }"
}

# stage SPEC — the repo-side fixture one row needs: `envlocal=<line>` writes
# that line to .env.local (`envlocal=` removes it). Several items separate
# with `;`. Every row's stage is applied from a clean repo.
stage() {
  local spec="$1" items item
  rm -f "$TMP_ROOT/repo/.env.local"
  [[ -n "$spec" ]] || return 0
  IFS=';' read -ra items <<<"$spec"
  for item in "${items[@]}"; do
    case "$item" in
      envlocal=) ;;
      envlocal=*) printf '%s\n' "${item#envlocal=}" > "$TMP_ROOT/repo/.env.local" ;;
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

# The poll interval and budget every row inherits. Both are spent on the
# virtual clock, so they are sized like production's rather than to save real
# seconds: the settled-check window below is wall-clock seconds, and a budget
# under it leaves a green PR unconfirmed at the deadline.
JSON='1 30 300 --json'
JSON_SHORT='1 1 5 --json'
# The script's own defaults for poll interval and budget: positional args
# omitted, so a row using this reads whatever ci-wait defaults to.
JSON_DEFAULTS='1 --json'

echo "=== the auth ladder: env token, keyring, bot token ==="
# A stale inherited token is unset with a warning and the keyring tried; with
# the keyring denied, .env.local's GH_BOT_TOKEN recovers; an inherited bot
# token wins over a project op:// reference without reading it; a valid
# selected token is validated once and ignores a stale keyring status.
table "$JSON" \
  'a stale GH_TOKEN is unset with a warning and the keyring works|||GH_TOKEN=bad-token|rc=0 verdict=pass stderr~ci-wait:+auth-fallback+source=keyring=true' \
  'no env tokens: the keyring works with no warning||||rc=0 verdict=pass stderr~ci-wait:+auth-fallback+source=keyring=false' \
  'stale token, keyring denied, no bot token: exit 3 with a named error|envlocal=||GH_TOKEN=bad-token,STUB_GH_DENY_KEYRING=1|rc=3 status=error error_named=true' \
  'stale token, keyring denied: .env.local GH_BOT_TOKEN recovers, each token validated once|envlocal=export GH_BOT_TOKEN=ghs_VALIDBOT123||GH_TOKEN=bad-token,STUB_GH_DENY_KEYRING=1,STUB_GH_VALID_TOKEN=ghs_VALIDBOT123|rc=0 verdict=pass api_user_calls=2' \
  'an inherited GH_BOT_TOKEN wins over the project op:// reference, which is never read|envlocal=export GH_BOT_TOKEN=op://vault/github/bot||GH_BOT_TOKEN=ghs_ENVBOT123,STUB_GH_DENY_KEYRING=1,STUB_GH_VALID_TOKEN=ghs_ENVBOT123|rc=0 verdict=pass op_calls=none' \
  'a valid selected token validates once and ignores a stale keyring status|||GH_TOKEN=ghs_VALIDUSER123,STUB_GH_VALID_TOKEN=ghs_VALIDUSER123,STUB_GH_AUTH_STATUS_FAIL=1|rc=0 verdict=pass stderr~ci-wait:+auth-fallback+source=keyring=false api_user_calls=1'

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
#
# The settled-check window is wall-clock seconds, so the three rows taking the
# script's own poll interval and budget are what a lane actually runs: a PR
# already green before the wait started completes, a pending one still waits,
# and a budget shorter than the window reports the unconfirmed green rollup as
# pending — "pass" is paired with status "complete" and nothing else.
table "$JSON" \
  'a pending exit with valid JSON keeps polling|||STUB_PR_CHECKS_MODE=pending_once|rc=0 verdict=pass checks_polls=2' \
  "an EXPECTED check is pending until it clears||$JSON_SHORT|STUB_PR_CHECKS_MODE=expected_once|rc=0 verdict=pass checks_polls=2" \
  'a pass is complete with its checks listed||||rc=0 status=complete verdict=pass passed=1' \
  "a PR already green at the script's own defaults completes, not times out||$JSON_DEFAULTS||rc=0 status=complete verdict=pass passed=1" \
  "a pending check at those defaults still waits to the deadline||$JSON_DEFAULTS|STUB_PR_CHECKS_MODE=pending_always|rc=1 status=timeout verdict=pending check.build=IN_PROGRESS" \
  'a green rollup the budget never confirmed is pending at the deadline, not pass||1 10 30 --json||rc=1 status=timeout verdict=pending passed=1 pending=0' \
  'a check registering late and settled restarts the window|||STUB_PR_CHECKS_SEQUENCE=green:green2|rc=0 status=complete verdict=pass passed=2 elapsed_seconds=120' \
  'a poll in no class breaks the streak the greens either side of it would share|||STUB_PR_CHECKS_SEQUENCE=green:skipped:green|rc=0 status=complete verdict=pass passed=1 elapsed_seconds=150' \
  'a check registering late as skipped is a different rollup and restarts the window|||STUB_PR_CHECKS_SEQUENCE=green:mixed|rc=0 status=complete verdict=pass passed=1 elapsed_seconds=120' \
  'the rollup key names a skipped check its classes drop|||STUB_PR_CHECKS_SEQUENCE=mixed|rc=0 verdict=pass check.docs=absent rollup.docs=true rollup.build=true' \
  "checks still in progress at the deadline are a timeout||$JSON_SHORT|STUB_PR_CHECKS_MODE=pending_always|rc=1 status=timeout verdict=pending check.build=IN_PROGRESS" \
  'no checks registered past the grace window is a named error|||STUB_PR_CHECKS_MODE=empty,CI_WAIT_NO_CHECKS_GRACE=3|rc=1 status=error error_named=true' \
  "no checks registered inside the default grace window stays pending||$JSON_SHORT|STUB_PR_CHECKS_MODE=empty|rc=1 status=timeout verdict=pending" \
  'a settled failing check is a complete fail|||STUB_PR_CHECKS_MODE=failure|rc=1 status=complete verdict=fail check.build=FAILURE' \
  'an auth failure with --json is a parseable error object naming its cause|||GH_TOKEN=bad-token,STUB_GH_DENY_KEYRING=1|rc=3 status=error error_named=true'

echo "=== the no-checks grace is the default the settings template declares ==="
# The Customize view shows the template's value as the default, so the grace
# ci-wait resolves for an unset, empty or non-numeric key is that value; an
# explicit whole number, leading zero included, is taken as given in base 10.
# The budget outlasts any of them, so elapsed_seconds on the no-checks error
# is the grace it resolved, at an interval that divides the grace and at the production one that does
# not. The grace runs from the wait's start, and the probe's seconds count
# against it: a 100-second first read and a 50-second probe at a 400-second
# interval end a 600-second grace at 600, where a grace counted from the first
# empty answer ends at 700 and one that skips the probe at 650. At the
# production interval and budget, a first read that took time still ends in
# the no-checks error at the deadline rather than a pending timeout. Checks
# that registered and then vanished start a fresh grace at the first empty
# answer after them.
GRACE_DECLARED=$(sed -n 's/^CI_WAIT_NO_CHECKS_GRACE = "\([0-9]*\)"$/\1/p' "$REPO_ROOT/skills/orch/kendex.settings.toml.example")
[[ -n "$GRACE_DECLARED" ]] || { echo "the settings template declares no CI_WAIT_NO_CHECKS_GRACE default" >&2; exit 1; }
table '1 30 3600 --json' \
  "an unset grace waits the declared default|||-u,CI_WAIT_NO_CHECKS_GRACE,STUB_PR_CHECKS_MODE=empty|rc=1 status=error elapsed_seconds=${GRACE_DECLARED}" \
  "a grace ending on the budget's deadline is the no-checks error, not a timeout||1 180 ${GRACE_DECLARED} --json|-u,CI_WAIT_NO_CHECKS_GRACE,STUB_PR_CHECKS_MODE=empty|rc=1 status=error elapsed_seconds=${GRACE_DECLARED}" \
  "a grace ending past the budget's deadline stays a pending timeout at the deadline||1 180 $((GRACE_DECLARED - 10)) --json|-u,CI_WAIT_NO_CHECKS_GRACE,STUB_PR_CHECKS_MODE=empty|rc=1 status=timeout verdict=pending elapsed_seconds=$((GRACE_DECLARED - 10))" \
  "an unset grace at the production interval waits the declared default||1 180 3600 --json|-u,CI_WAIT_NO_CHECKS_GRACE,STUB_PR_CHECKS_MODE=empty|rc=1 status=error elapsed_seconds=${GRACE_DECLARED}" \
  "an empty grace waits the declared default|||STUB_PR_CHECKS_MODE=empty,CI_WAIT_NO_CHECKS_GRACE=|rc=1 status=error elapsed_seconds=${GRACE_DECLARED}" \
  "a non-numeric grace waits the declared default|||STUB_PR_CHECKS_MODE=empty,CI_WAIT_NO_CHECKS_GRACE=abc|rc=1 status=error elapsed_seconds=${GRACE_DECLARED}" \
  'an explicit grace is taken as given|||STUB_PR_CHECKS_MODE=empty,CI_WAIT_NO_CHECKS_GRACE=90|rc=1 status=error elapsed_seconds=90' \
  'a leading-zero grace is read in base 10|||STUB_PR_CHECKS_MODE=empty,CI_WAIT_NO_CHECKS_GRACE=090|rc=1 status=error elapsed_seconds=90' \
  "a slow first read and probe spend the grace from the wait's start||1 400 3600 --json|-u,CI_WAIT_NO_CHECKS_GRACE,STUB_PR_CHECKS_MODE=empty,STUB_FIRST_CHECKS_COST=100,STUB_PROBE_COST=50|rc=1 status=error elapsed_seconds=${GRACE_DECLARED}" \
  "a first read that took time at the production interval and budget is the no-checks error||1 180 ${GRACE_DECLARED} --json|-u,CI_WAIT_NO_CHECKS_GRACE,STUB_PR_CHECKS_MODE=empty,STUB_FIRST_CHECKS_COST=5|rc=1 status=error elapsed_seconds=${GRACE_DECLARED}" \
  'checks that vanish start a fresh grace at the first empty answer after them|||STUB_PR_CHECKS_SEQUENCE=pending:empty,CI_WAIT_NO_CHECKS_GRACE=90|rc=1 status=error elapsed_seconds=120'

echo "=== text mode prints a result line for every terminal status ==="
# The line beyond its leading words is not a contract anything parses; the
# leading words are text-only, so a JSON default flip fails these rows.
table '1 30 300' \
  'passed||||rc=0 stdout~ci-wait:+passed+pr=1+repo=owner/repo=true' \
  'failed|||STUB_PR_CHECKS_MODE=failure|rc=1 stdout~ci-wait:+failed+pr=1+repo=owner/repo=true' \
  'timeout||1 1 5|STUB_PR_CHECKS_MODE=pending_always|rc=1 stdout~ci-wait:+timeout+elapsed=5+verdict=pending+repo=owner/repo=true' \
  'error|||STUB_PR_CHECKS_MODE=empty,CI_WAIT_NO_CHECKS_GRACE=3|rc=1 stdout~ci-wait:+error+pr=1+repo=owner/repo=true'

echo "=== the verdict names the repository it read ==="
# The resolution ladder is lib/gh-repo.sh's, and gh-repo-resolve.test.sh holds
# its rows. These hold ci-wait's own use of it: the slug GH_REPO names is the
# repository the verdict carries and the one `gh --repo` gets, over the
# checkout `gh repo view` answers for, and a value the resolver refuses is
# ci-wait's repo-shape error, with the result's repo left empty so nothing
# reads an unvalidated candidate as the repository the verdict is about.
table "$JSON" \
  'GH_REPO names the repository, over the checkout gh repo view answers for|||GH_REPO=other/elsewhere|rc=0 verdict=pass repo=other/elsewhere repo_arg=other/elsewhere' \
  'a GH_REPO that is not owner/name is refused|||GH_REPO=elsewhere|rc=1 status=error error_named=true repo= stderr~ci-wait:+repo-shape+repo=elsewhere=true repo_arg=none'

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

echo "=== settled green checks respect the required set and current-head CI ==="
# GitHub can register only request-copilot-review's successful check while
# the new head's workflow is active, including a push or manual dry run
# from publish-homebrew.yml. The budget exceeds the
# stale window, both without visible progress and after an older head showed
# progress. Completed CI releases the hold; an unreadable read cannot do so.
# Separate pull_request workflows can finish a required build while optional
# docs still runs. A known required set completes; a failed protection read
# falls back to every check and the current-head Actions hold.
NEXT_HEAD=d049a699ebe08c6b639fdc19855a7152ae768084
REQUEST="STUB_PR_CHECKS_FIXTURE=$FX/request-only-checks.json,STUB_HEAD_SHA=$NEXT_HEAD"
ACTIVE="STUB_ACTIONS_RUNS_FIXTURE=$FX/runs-request-only-active.json"
jq '.workflow_runs[0].status = "queued"' "$FX/runs-request-only-active.json" > "$TMP_ROOT/runs-request-only-queued.json"
jq '.workflow_runs[0].status = "completed" | .workflow_runs[0].conclusion = "success"' "$FX/runs-request-only-active.json" > "$TMP_ROOT/runs-request-only-completed.json"
jq '.workflow_runs[0].event = "push" | .workflow_runs[0].status = "queued"' "$FX/runs-request-only-active.json" > "$TMP_ROOT/runs-request-only-push-queued.json"
jq '.workflow_runs[0].event = "push"' "$FX/runs-request-only-active.json" > "$TMP_ROOT/runs-request-only-push-active.json"
jq '.workflow_runs[0].event = "workflow_dispatch" | .workflow_runs[0].status = "queued"' "$FX/runs-request-only-active.json" > "$TMP_ROOT/runs-request-only-manual-queued.json"
jq '.workflow_runs[0].event = "workflow_dispatch"' "$FX/runs-request-only-active.json" > "$TMP_ROOT/runs-request-only-manual-active.json"
jq '.workflow_runs[0].event = "workflow_dispatch"' "$TMP_ROOT/runs-request-only-completed.json" > "$TMP_ROOT/runs-request-only-manual-completed.json"
printf '{"workflow_runs":null}\n' > "$TMP_ROOT/runs-unreadable.json"
jq '.workflow_runs[0].name = "Docs"' "$FX/runs-request-only-active.json" > "$TMP_ROOT/runs-optional-docs.json"
printf '[{"name":"build","state":"SUCCESS","bucket":"pass"},{"name":"docs","state":"IN_PROGRESS","bucket":"pending"}]\n' > "$TMP_ROOT/required-build-optional-docs.json"
OPTIONAL="STUB_ACTIONS_RUNS_FIXTURE=$TMP_ROOT/runs-optional-docs.json,STUB_HEAD_SHA=$NEXT_HEAD"
table "$JSON" \
  "an unchanged request-only rollup stays pending beyond the stale window|||$REQUEST,$ACTIVE|rc=1 status=timeout verdict=pending check.request=SUCCESS check.current-head+Actions=EXPECTED failed=0 elapsed_seconds=300 runs_head=$NEXT_HEAD" \
  "a queued substantive run also holds the request-only rollup|||$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$TMP_ROOT/runs-request-only-queued.json|rc=1 status=timeout verdict=pending check.request=SUCCESS check.current-head+Actions=EXPECTED" \
  "a queued push run holds the request-only rollup|||$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$TMP_ROOT/runs-request-only-push-queued.json|rc=1 status=timeout verdict=pending check.request=SUCCESS check.current-head+Actions=EXPECTED elapsed_seconds=300" \
  "an in-progress push run holds the request-only rollup|||$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$TMP_ROOT/runs-request-only-push-active.json|rc=1 status=timeout verdict=pending check.request=SUCCESS check.current-head+Actions=EXPECTED elapsed_seconds=300" \
  "a queued manual run holds the request-only rollup|||$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$TMP_ROOT/runs-request-only-manual-queued.json|rc=1 status=timeout verdict=pending check.request=SUCCESS check.current-head+Actions=EXPECTED elapsed_seconds=300" \
  "an in-progress manual run holds the request-only rollup|||$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$TMP_ROOT/runs-request-only-manual-active.json|rc=1 status=timeout verdict=pending check.request=SUCCESS check.current-head+Actions=EXPECTED elapsed_seconds=300" \
  "a completed manual run releases the request-only rollup|||$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$TMP_ROOT/runs-request-only-manual-completed.json|rc=0 status=complete verdict=pass check.request=SUCCESS pending=0 elapsed_seconds=90" \
  "progress on the old head cannot pass request-only checks on the new head|||STUB_PR_CHECKS_SEQUENCE=pending:request,STUB_REQUEST_CHECK_FIXTURE=$FX/request-only-checks.json,STUB_HEAD_SHA=$DEFAULT_HEAD,STUB_NEXT_HEAD_SHA=$NEXT_HEAD,$ACTIVE|rc=1 status=timeout verdict=pending check.request=SUCCESS check.current-head+Actions=EXPECTED elapsed_seconds=300 runs_head=$NEXT_HEAD" \
  "completed substantive CI releases the request-only rollup after confirmation|||$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$TMP_ROOT/runs-request-only-completed.json|rc=0 status=complete verdict=pass check.request=SUCCESS pending=0" \
  "CI completing during the wait starts a fresh confirmation window|||STUB_PR_CHECKS_SEQUENCE=request,STUB_REQUEST_CHECK_FIXTURE=$FX/request-only-checks.json,STUB_HEAD_SHA=$NEXT_HEAD,$ACTIVE,STUB_ACTIONS_RUNS_RELEASE_AFTER=2,STUB_ACTIONS_RUNS_RELEASE_FIXTURE=$TMP_ROOT/runs-request-only-completed.json|rc=0 status=complete verdict=pass pending=0 elapsed_seconds=150" \
  "progress on the old head needs confirmation on a request-only new head|||STUB_PR_CHECKS_SEQUENCE=pending:request,STUB_REQUEST_CHECK_FIXTURE=$FX/request-only-checks.json,STUB_NEXT_HEAD_SHA=$NEXT_HEAD|rc=0 status=complete verdict=pass elapsed_seconds=120" \
  "a new head restarts even an unchanged green rollup|||STUB_PR_CHECKS_SEQUENCE=green,STUB_NEXT_HEAD_SHA=$NEXT_HEAD|rc=0 status=complete verdict=pass elapsed_seconds=120" \
  "the new head can register and finish during confirmation|||STUB_PR_CHECKS_SEQUENCE=pending:request:pending:green,STUB_REQUEST_CHECK_FIXTURE=$FX/request-only-checks.json,STUB_NEXT_HEAD_SHA=$NEXT_HEAD|rc=0 status=complete verdict=pass elapsed_seconds=90" \
  "same-head progress still completes immediately|||STUB_PR_CHECKS_SEQUENCE=pending:green|rc=0 status=complete verdict=pass elapsed_seconds=30" \
  "a push during the check request discards the unbound snapshot|||STUB_PR_CHECKS_SEQUENCE=green,STUB_HEAD_DURING_CHECKS=$NEXT_HEAD|rc=0 status=complete verdict=pass elapsed_seconds=120" \
  "a known required build passes while optional docs is active||$JSON --required-only|STUB_REQUIRED_CONTEXT=build,STUB_PR_CHECKS_FIXTURE=$TMP_ROOT/required-build-optional-docs.json,$OPTIONAL|rc=0 status=complete verdict=pass check.build=SUCCESS check.docs=absent check.current-head+Actions=absent pending=0 rollup.build=true rollup.docs=false elapsed_seconds=90" \
  "a known required build still needs a readable head||$JSON --required-only|STUB_REQUIRED_CONTEXT=build,STUB_PR_CHECKS_FIXTURE=$TMP_ROOT/required-build-optional-docs.json,$OPTIONAL,STUB_HEAD_EXIT=1|rc=1 status=timeout verdict=pending check.build=absent check.docs=absent check.current-head+Actions=EXPECTED runs_head=none lookup_http_status=403" \
  "an unreadable required set keeps the Actions hold||$JSON --required-only|STUB_REQUIRED_CONTEXT=build,STUB_REQUIRED_READ_EXIT=1,$OPTIONAL|rc=1 status=timeout verdict=pending check.build=SUCCESS check.current-head+Actions=EXPECTED runs_head=$NEXT_HEAD elapsed_seconds=300" \
  "a missing required build stays pending with only the request check visible||$JSON --required-only|STUB_REQUIRED_CONTEXT=build,$REQUEST,$OPTIONAL|rc=1 status=timeout verdict=pending check.build+(missing)=EXPECTED check.request=absent" \
  "a failed Actions read with a green-looking response stays pending|||$REQUEST,STUB_ACTIONS_RUNS_EXIT=1|rc=1 status=timeout verdict=pending check.current-head+Actions=EXPECTED stderr~ci-wait:+actions-read-failed=true lookup_http_status=403" \
  "an unreadable Actions array stays pending|||$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$TMP_ROOT/runs-unreadable.json|rc=1 status=timeout verdict=pending check.current-head+Actions=EXPECTED stderr~ci-wait:+actions-response-invalid=true" \
  "a failed head read preserves its cause and stays pending|||$REQUEST,STUB_HEAD_EXIT=1|rc=1 status=timeout verdict=pending check.current-head+Actions=EXPECTED runs_head=none stderr~ci-wait:+head-read-failed=true lookup_http_status=403" \
  "an unreadable head stays pending|||STUB_PR_CHECKS_FIXTURE=$FX/request-only-checks.json,STUB_HEAD_SHA=unknown|rc=1 status=timeout verdict=pending check.current-head+Actions=EXPECTED runs_head=none stderr~ci-wait:+head-response-invalid=true"

echo "=== the latest Actions workflow outcome decides a green rollup ==="
jq '.workflow_runs[0].conclusion = "failure"' "$TMP_ROOT/runs-request-only-completed.json" > "$TMP_ROOT/runs-request-only-failed.json"
jq '.workflow_runs += [.workflow_runs[0] + {id: (.workflow_runs[0].id + 1), conclusion: "success"}]' "$TMP_ROOT/runs-request-only-failed.json" > "$TMP_ROOT/runs-request-newer-success.json"
jq '.workflow_runs += [.workflow_runs[0] + {id: (.workflow_runs[0].id + 1), workflow_id: (.workflow_runs[0].workflow_id + 1), conclusion: "success"}]' "$TMP_ROOT/runs-request-only-failed.json" > "$TMP_ROOT/runs-request-other-workflow-success.json"
jq '.workflow_runs += [.workflow_runs[0] + {id: (.workflow_runs[0].id + 1), conclusion: "skipped"}]' "$TMP_ROOT/runs-request-only-failed.json" > "$TMP_ROOT/runs-request-newer-skipped.json"
table "$JSON" \
  "a failed latest run fails even when the rollup carries only the review request|||$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$TMP_ROOT/runs-request-only-failed.json|rc=1 status=complete verdict=fail check.Actions+run+37737962683=FAILURE elapsed_seconds=0" \
  "a newer successful run replaces the earlier failure|||$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$TMP_ROOT/runs-request-newer-success.json|rc=0 status=complete verdict=pass failed=0 elapsed_seconds=90" \
  "a newer successful workflow cannot erase another workflow's failure|||$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$TMP_ROOT/runs-request-other-workflow-success.json|rc=1 status=complete verdict=fail check.Actions+run+37737962683=FAILURE" \
  "a later skipped dispatch cannot erase a substantive failure|||$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$TMP_ROOT/runs-request-newer-skipped.json|rc=1 status=complete verdict=fail check.Actions+run+37737962683=FAILURE" \
  "a successful rerun with the older run id replaces the failed newer dispatch|||$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$FX/runs-rerun-attempt-success.json|rc=0 status=complete verdict=pass failed=0 elapsed_seconds=90" \
  "a failed latest rerun stays terminal|||$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$FX/runs-rerun-attempt-failure.json|rc=1 status=complete verdict=fail check.Actions+run+29662588017=FAILURE"

echo "=== Actions confirmation discards a moved or unreadable head ==="
# Acknowledgements in the gh stub place a remote push, or a failed head read,
# inside the Actions request. The response still belongs to the prior head.
ACTION_PUSH="STUB_HEAD_DURING_ACTIONS=$NEXT_HEAD,STUB_ACTIONS_NEXT_HEAD_FIXTURE=$FX/runs-request-only-active.json"
FAILED_ROLLUP="STUB_PR_CHECKS_FIXTURE=$FX/cancelled-review-run-checks.json,STUB_PR_CHECKS_EXIT=1,STUB_ACTIONS_RUNS_FIXTURE=$FX/runs-newer-sibling-failure.json,STUB_CHECKS_AFTER_ACTIONS_FIXTURE=$FX/request-only-checks.json"
table "$JSON" \
  "a push during green Actions confirmation cannot pass old-head progress|||STUB_PR_CHECKS_SEQUENCE=pending:green,$ACTION_PUSH|rc=1 status=timeout verdict=pending failed=0 check.current-head+Actions=EXPECTED elapsed_seconds=300 runs_head=$NEXT_HEAD" \
  "a push during failed Actions confirmation cannot end on the old failure|||$FAILED_ROLLUP,$ACTION_PUSH|rc=1 status=timeout verdict=pending failed=0 check.current-head+Actions=EXPECTED elapsed_seconds=300 runs_head=$NEXT_HEAD" \
  "a push during green Actions failure lookup cannot end on that old failure|||STUB_PR_CHECKS_SEQUENCE=request,STUB_REQUEST_CHECK_FIXTURE=$FX/request-only-checks.json,STUB_ACTIONS_RUNS_FIXTURE=$TMP_ROOT/runs-request-only-failed.json,$ACTION_PUSH|rc=1 status=timeout verdict=pending failed=0 check.current-head+Actions=EXPECTED elapsed_seconds=300" \
  "unreadable post-Actions head discards green progress and the rollup|||STUB_PR_CHECKS_SEQUENCE=pending:green,STUB_HEAD_AFTER_ACTIONS_EXIT=1|rc=1 status=timeout verdict=pending failed=0 passed=0 pending=1 check.current-head+Actions=EXPECTED elapsed_seconds=300 lookup_http_status=403" \
  "unreadable post-Actions head discards a failed rollup|||$FAILED_ROLLUP,STUB_HEAD_AFTER_ACTIONS_EXIT=1|rc=1 status=timeout verdict=pending failed=0 passed=0 pending=1 check.current-head+Actions=EXPECTED elapsed_seconds=300 lookup_http_status=403" \
  "a completed new head needs its own confirmation after an Actions push|||STUB_PR_CHECKS_SEQUENCE=pending:green,STUB_HEAD_DURING_ACTIONS=$NEXT_HEAD|rc=0 status=complete verdict=pass elapsed_seconds=150"

echo "=== every Actions page must finish before a green rollup passes ==="
# GitHub returns at most 100 runs per page and caps head_sha searches at
# 1,000 results. A completed first page cannot prove later work finished.
jq -s '
  .[0].workflow_runs[0] as $completed
  | [{total_count: 101, workflow_runs: [range(100) as $i | $completed + {id: ($completed.id + $i + 1)}]},
     {total_count: 101, workflow_runs: .[1].workflow_runs}]
' "$TMP_ROOT/runs-request-only-completed.json" "$FX/runs-request-only-active.json" > "$TMP_ROOT/runs-pages-active.json"
jq '.[1].workflow_runs[0].status = "completed" | .[1].workflow_runs[0].conclusion = "success"' "$TMP_ROOT/runs-pages-active.json" > "$TMP_ROOT/runs-pages-completed.json"
jq '.[0:1]' "$TMP_ROOT/runs-pages-completed.json" > "$TMP_ROOT/runs-pages-incomplete.json"
jq '.[1].workflow_runs = null' "$TMP_ROOT/runs-pages-completed.json" > "$TMP_ROOT/runs-pages-malformed.json"
jq '.[0].total_count = 102' "$TMP_ROOT/runs-pages-completed.json" > "$TMP_ROOT/runs-pages-changed-total.json"
jq '
  .[0].workflow_runs[0] as $completed
  | [range(10) as $page | {total_count: 1000,
      workflow_runs: [range(100) as $i | $completed + {id: ($completed.id + $page * 100 + $i)}]}]
' "$TMP_ROOT/runs-pages-completed.json" > "$TMP_ROOT/runs-pages-cap.json"
jq 'map(.total_count = 1001)' "$TMP_ROOT/runs-pages-cap.json" > "$TMP_ROOT/runs-pages-over-cap.json"
jq '.[9].workflow_runs = .[9].workflow_runs[0:99] | map(.total_count = 999)' "$TMP_ROOT/runs-pages-cap.json" > "$TMP_ROOT/runs-pages-below-cap.json"
table "$JSON" \
  "an active run on a later page holds request-only checks|||$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$TMP_ROOT/runs-pages-active.json|rc=1 status=timeout verdict=pending check.current-head+Actions=EXPECTED" \
  "completed later-page work releases request-only checks|||$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$TMP_ROOT/runs-pages-completed.json|rc=0 status=complete verdict=pass pending=0" \
  "a later-page read failure preserves its cause and holds the first page|||$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$TMP_ROOT/runs-pages-completed.json,STUB_ACTIONS_RUNS_LATE_EXIT=1|rc=1 status=timeout verdict=pending check.current-head+Actions=EXPECTED lookup_http_status=403" \
  "an incomplete run list holds completed first-page work|||$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$TMP_ROOT/runs-pages-incomplete.json|rc=1 status=timeout verdict=pending check.current-head+Actions=EXPECTED" \
  "a malformed later page cannot release the hold|||$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$TMP_ROOT/runs-pages-malformed.json|rc=1 status=timeout verdict=pending check.current-head+Actions=EXPECTED" \
  "a changing total across pages keeps completed work unconfirmed|||$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$TMP_ROOT/runs-pages-changed-total.json|rc=1 status=timeout verdict=pending check.current-head+Actions=EXPECTED" \
  "the filtered-search cap keeps completed pages pending|||$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$TMP_ROOT/runs-pages-cap.json|rc=1 status=timeout verdict=pending check.current-head+Actions=EXPECTED" \
  "a total above the cap keeps completed pages pending|||$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$TMP_ROOT/runs-pages-over-cap.json|rc=1 status=timeout verdict=pending check.current-head+Actions=EXPECTED" \
  "a complete list below the cap passes without an argument-size limit|||$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$TMP_ROOT/runs-pages-below-cap.json|rc=0 status=complete verdict=pass pending=0" \
  "known required checks pass without reading capped optional runs||$JSON --required-only|STUB_REQUIRED_CONTEXT=build,STUB_PR_CHECKS_FIXTURE=$TMP_ROOT/required-build-optional-docs.json,STUB_ACTIONS_RUNS_FIXTURE=$TMP_ROOT/runs-pages-cap.json|rc=0 verdict=pass pending=0 runs_head=none"

# Each control edits a private script copy. The same pending assertion must
# reject its false pass, proving later-page work, incomplete totals and the
# endpoint cap each hold the verdict independently.
# Splice literal text: Bash 3.2 keeps replacement quotes in ${var/pat/rep}.
control_source=$(cat "$REPO_ROOT/skills/orch/scripts/ci-wait")
control_rows=(
  'later-page work~[$runs[] | {id, event, status, conclusion, workflow_id, run_attempt, updated_at}]~[$runs[0:100][] | {id, event, status, conclusion, workflow_id, run_attempt, updated_at}]~runs-pages-active.json'
  'incomplete totals~select(all(.[]; .total_count == ($runs | length)))~select(true)~runs-pages-incomplete.json'
  'the endpoint cap~select(($runs | length) < 1000)~select(true)~runs-pages-cap.json'
)
mkdir -p "$TMP_ROOT/control/skills/orch/scripts"
ln -s "$REPO_ROOT/skills/orch/scripts/lib" "$TMP_ROOT/control/skills/orch/scripts/lib"
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/control/skills/github"
for row in "${control_rows[@]}"; do
  IFS='~' read -r label match replacement fixture <<<"$row"
  [[ "$control_source" == *"$match"* && "${control_source#*"$match"}" != *"$match"* ]] || { echo 'ci_wait: control-match=invalid' >&2; exit 1; }
  mutant="${control_source%%"$match"*}$replacement${control_source#*"$match"}"
  [[ "$mutant" != "$control_source" ]] || { echo 'ci_wait: control-edit=unchanged' >&2; exit 1; }
  printf '%s\n' "$mutant" > "$TMP_ROOT/control/skills/orch/scripts/ci-wait"
  chmod +x "$TMP_ROOT/control/skills/orch/scripts/ci-wait"
  rm "$TMP_ROOT/repo/.agents/skills/orch"
  ln -s "$TMP_ROOT/control/skills/orch" "$TMP_ROOT/repo/.agents/skills/orch"
  # shellcheck disable=SC2086
  run_wait "$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$TMP_ROOT/$fixture" $JSON
  assert_eq "$(observe 'rc=0 verdict=pass')" 'rc=0 verdict=pass' "control bypasses $label through the real entry point" "$RUN/stderr"
  set +e
  ( FAIL=0; assert_eq "$(observe 'rc=1 verdict=pending')" 'rc=1 verdict=pending' "$label"; [[ "$FAIL" -eq 0 ]] ) > "$TMP_ROOT/control/assertion.log"
  control_rc=$?
  set -e
  assert_eq "$control_rc" 1 "the pending assertion rejects the $label control"
  rm "$TMP_ROOT/repo/.agents/skills/orch"
  ln -s "$REPO_ROOT/skills/orch" "$TMP_ROOT/repo/.agents/skills/orch"
done

echo "=== controls reject progress carry-over and false Actions conclusions ==="
head_reset='if [ -z "$checks_head" ] || [ "$checks_head" != "$confirmation_head" ]; then'
control_rows=(
  "head progress~$head_reset~if false; then~STUB_PR_CHECKS_SEQUENCE=pending:request,STUB_REQUEST_CHECK_FIXTURE=$FX/request-only-checks.json,STUB_NEXT_HEAD_SHA=$NEXT_HEAD~rc=0 verdict=pass elapsed_seconds=120"
  "head window~$head_reset~if false; then~STUB_PR_CHECKS_SEQUENCE=green,STUB_NEXT_HEAD_SHA=$NEXT_HEAD~rc=0 verdict=pass elapsed_seconds=120"
  "same-head completion~if [ \"\$seen_in_progress\" = true ]; then~if [ \"\$seen_in_progress\" = false ]; then~STUB_PR_CHECKS_SEQUENCE=pending:green~rc=0 verdict=pass elapsed_seconds=30"
  "snapshot head~[ \"\$before_checks_head\" != \"\$checks_head\" ]~false~STUB_PR_CHECKS_SEQUENCE=green,STUB_HEAD_DURING_CHECKS=$NEXT_HEAD~rc=0 verdict=pass elapsed_seconds=120"
  "failed Actions outcome~select((.conclusion // \"\") | IN(\"success\", \"neutral\", \"skipped\") | not)~select(false)~$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$TMP_ROOT/runs-request-only-failed.json~rc=1 verdict=fail elapsed_seconds=0"
  "newer successful run~max_by([(.updated_at // \"\"), .id]))) as \$latest~min_by([(.updated_at // \"\"), .id]))) as \$latest~$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$TMP_ROOT/runs-request-newer-success.json~rc=0 verdict=pass elapsed_seconds=90"
  "rerun activity~max_by([(.updated_at // \"\"), .id]))) as \$latest~max_by(.id))) as \$latest~$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$FX/runs-rerun-attempt-success.json~rc=0 verdict=pass elapsed_seconds=90"
  "failed rerun identity~(map(select(.conclusion != \"skipped\"))) as \$substantive~(map(select(.conclusion != \"skipped\" and (((.run_attempt // 1) > 1 and .conclusion == \"failure\") | not)))) as \$substantive~$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$FX/runs-rerun-attempt-failure.json~rc=1 status=complete verdict=fail check.Actions+run+29662588017=FAILURE~~rc=1 status=complete verdict=fail check.Actions+run+29662812172=CANCELLED check.Actions+run+29662588017=absent"
  "separate workflow outcomes~group_by(.workflow_id)~group_by(null)~$REQUEST,STUB_ACTIONS_RUNS_FIXTURE=$TMP_ROOT/runs-request-other-workflow-success.json~rc=1 status=complete verdict=fail check.Actions+run+37737962683=FAILURE~~rc=0 status=complete verdict=pass failed=0"
  "required head binding~if [ -z \"\$checks_head\" ] || ! \$REQUIRED_ONLY || [ \"\$REQUIRED_CONTEXTS\" = '[]' ]; then~if ! \$REQUIRED_ONLY || [ \"\$REQUIRED_CONTEXTS\" = '[]' ]; then~STUB_REQUIRED_CONTEXT=build,STUB_PR_CHECKS_FIXTURE=$TMP_ROOT/required-build-optional-docs.json,$OPTIONAL,STUB_HEAD_EXIT=1~rc=1 status=timeout verdict=pending check.build=absent check.docs=absent check.current-head+Actions=EXPECTED runs_head=none lookup_http_status=403~$JSON --required-only~rc=1 status=timeout verdict=pending check.build=SUCCESS check.current-head+Actions=absent pending=0"
  "green Actions push~[ \"\$after_actions_head\" != \"\$checks_head\" ]~false~STUB_PR_CHECKS_SEQUENCE=pending:green,$ACTION_PUSH~rc=1 status=timeout verdict=pending failed=0 check.current-head+Actions=EXPECTED elapsed_seconds=300~~rc=0 status=complete verdict=pass elapsed_seconds=30"
  "failed Actions push~[ \"\$after_actions_head\" != \"\$checks_head\" ]~false~$FAILED_ROLLUP,$ACTION_PUSH~rc=1 status=timeout verdict=pending failed=0 check.current-head+Actions=EXPECTED elapsed_seconds=300~~rc=1 status=complete verdict=fail elapsed_seconds=0"
  "unreadable green Actions head~after_actions_head=\$(read_checks_head) || after_actions_head=\"\"~after_actions_head=\$(read_checks_head) || after_actions_head=\"\$checks_head\"~STUB_PR_CHECKS_SEQUENCE=pending:green,STUB_HEAD_AFTER_ACTIONS_EXIT=1~rc=1 status=timeout verdict=pending failed=0 passed=0 pending=1 check.current-head+Actions=EXPECTED elapsed_seconds=300~~rc=0 status=complete verdict=pass elapsed_seconds=30"
  "unreadable failed Actions head~after_actions_head=\$(read_checks_head) || after_actions_head=\"\"~after_actions_head=\$(read_checks_head) || after_actions_head=\"\$checks_head\"~$FAILED_ROLLUP,STUB_HEAD_AFTER_ACTIONS_EXIT=1~rc=1 status=timeout verdict=pending failed=0 passed=0 pending=1 check.current-head+Actions=EXPECTED elapsed_seconds=300~~rc=1 status=complete verdict=fail elapsed_seconds=0"
)
for row in "${control_rows[@]}"; do
  IFS='~' read -r label match replacement env expect args mutant_expect <<<"$row"
  [[ "$control_source" == *"$match"* && "${control_source#*"$match"}" != *"$match"* ]] || { echo 'ci_wait: control-match=invalid' >&2; exit 1; }
  mutant="${control_source%%"$match"*}$replacement${control_source#*"$match"}"
  [[ "$mutant" != "$control_source" ]] || { echo 'ci_wait: control-edit=unchanged' >&2; exit 1; }
  printf '%s\n' "$mutant" > "$TMP_ROOT/control/skills/orch/scripts/ci-wait"
  chmod +x "$TMP_ROOT/control/skills/orch/scripts/ci-wait"
  rm "$TMP_ROOT/repo/.agents/skills/orch"
  ln -s "$TMP_ROOT/control/skills/orch" "$TMP_ROOT/repo/.agents/skills/orch"
  # shellcheck disable=SC2086
  run_wait "$env" ${args:-$JSON}
  if [[ -n "$mutant_expect" ]]; then
    assert_eq "$(observe "$mutant_expect")" "$mutant_expect" "control reaches $label through the real entry point" "$RUN/stderr"
  fi
  actual=$(observe "$expect")
  set +e
  ( FAIL=0; assert_eq "$actual" "$expect" "$label"; [[ "$FAIL" -eq 0 ]] ) > "$TMP_ROOT/control/assertion.log"
  control_rc=$?
  set -e
  assert_eq "$control_rc" 1 "the contract assertion rejects the $label control" "$TMP_ROOT/control/assertion.log"
  rm "$TMP_ROOT/repo/.agents/skills/orch"
  ln -s "$REPO_ROOT/skills/orch" "$TMP_ROOT/repo/.agents/skills/orch"
done

echo "=== a settled failure attributable only to superseded runs is correlated against the head's Actions runs ==="
# The rollup can omit a newer same-head run entirely; an active newer
# substantive run keeps the wait pending, a successful one discards the stale
# failures, a failed one or none at all stays terminal. The query scopes to
# the current head.
table "$JSON" \
  "an active newer sibling keeps the cancelled run's failure pending, queried for the head||$JSON_SHORT|STUB_PR_CHECKS_FIXTURE=$FX/cancelled-review-run-checks.json,STUB_PR_CHECKS_EXIT=1,STUB_ACTIONS_RUNS_FIXTURE=$FX/runs-newer-sibling-active.json|rc=1 status=timeout verdict=pending failed=0 check.CI+Required=EXPECTED check.CI+Gate+Publisher=EXPECTED runs_head=$DEFAULT_HEAD" \
  "a required failure still waits for active replacement work||$JSON_SHORT --required-only|STUB_REQUIRED_CONTEXT=CI Required,STUB_PR_CHECKS_FIXTURE=$FX/cancelled-review-run-checks.json,STUB_PR_CHECKS_EXIT=1,STUB_ACTIONS_RUNS_FIXTURE=$FX/runs-newer-sibling-active.json|rc=1 status=timeout verdict=pending failed=0 check.CI+Required=EXPECTED runs_head=$DEFAULT_HEAD" \
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
  "a gh failure reading the log is not transient: nothing is rerun|||STUB_PR_CHECKS_FIXTURE=$FX/rerun-attempt-checks.json,$RERUN,STUB_ACTIONS_RUNS_FIXTURE=$FX/runs-rerun-attempt-failure.json|rc=1 verdict=fail reruns=none" \
  "a rerun restarts the settled-check window: the greens before it carry nothing|||STUB_PR_CHECKS_SEQUENCE=green:green:green:fail_rerun,STUB_RUN_LOG_FILE=$transient_log|rc=0 status=complete verdict=pass reruns=29099680623 elapsed_seconds=190"

echo "=== unread lane mail ends the wait early ==="
# A directive the virtual clock's first sleep delivers to the lane's mailbox;
# the poll interval equals the budget, so a wait that does not watch the
# mailbox inside its sleep reaches the deadline instead.
table "$JSON" \
  "a directive written mid-wait returns the keyed line with exit 5||1 30 30 --json --item KEN-1|STUB_PR_CHECKS_MODE=pending_always,STUB_MAIL_TO=$TMP_ROOT/repo/tmp/lane-mail/KEN-1/to-lane.jsonl|rc=5 mail=1"
# A line already in the mailbox is the baseline, never mail. A mailbox that
# exists but cannot be read ends the wait on the mail route; chmod hides a file
# from any user but root, and the suite runs as neither root nor in a container.
MAILBOX="$TMP_ROOT/repo/tmp/lane-mail"
mkdir -p "$MAILBOX/KEN-4" "$MAILBOX/KEN-5"
printf '{"kind":"answer"}\n' > "$MAILBOX/KEN-4/to-lane.jsonl"
: > "$MAILBOX/KEN-5/to-lane.jsonl"
chmod 000 "$MAILBOX/KEN-5/to-lane.jsonl"
MAILBOX_REAL="$(cd "$MAILBOX" && pwd -P)"
table "$JSON" \
  "a line in the mailbox before the wait never takes the mail exit||1 30 30 --json --item KEN-4|STUB_PR_CHECKS_MODE=pending_always|rc=1 status=timeout mail=" \
  "a mailbox that cannot be read ends the wait with its keyed line||1 30 30 --json --item KEN-5|STUB_PR_CHECKS_MODE=pending_always|rc=5 mail_unreadable=$MAILBOX_REAL/KEN-5/to-lane.jsonl"
chmod 600 "$MAILBOX/KEN-5/to-lane.jsonl"

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
  '--item without a value is refused in the parser|1 1 30 --item|rc=2 stdout=empty stderr_first~ci-wait:+missing-item+option=--item=true gh_calls=0'
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
