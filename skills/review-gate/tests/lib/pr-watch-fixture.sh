#!/usr/bin/env bash
# Neutral offline watcher world shared by the reduction and input suites.
set -euo pipefail

SKILL_ROOT="$(cd "$TEST_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

# Sandbox: the real pr-watch + real settings lib + a stubbed predicate.
mkdir -p "$TMP_ROOT/scripts/lib" "$TMP_ROOT/bin" "$TMP_ROOT/cwd"
cp "$SKILL_ROOT/scripts/pr-watch.sh" "$TMP_ROOT/scripts/"
cp "$SKILL_ROOT/scripts/lib/settings.sh" "$SKILL_ROOT/scripts/lib/diagnostics.sh" "$TMP_ROOT/scripts/lib/"
cat > "$TMP_ROOT/scripts/review-predicate.sh" <<'EOF'
#!/usr/bin/env bash
# Stub: STUB_PREDICATE_RC != 0 simulates a read failure; else
# STUB_VERDICT_LINE is the verdict. STUB_PREDICATE_CALLS counts invocations.
if [[ -n "${STUB_PREDICATE_CALLS:-}" ]]; then echo x >> "$STUB_PREDICATE_CALLS"; fi
if [[ "${STUB_PREDICATE_RC:-0}" != "0" ]]; then
  echo "::error::stubbed predicate failure" >&2
  exit "${STUB_PREDICATE_RC}"
fi
printf '%s\n' "${STUB_VERDICT_LINE:?}"
EOF
chmod +x "$TMP_ROOT/scripts/review-predicate.sh" "$TMP_ROOT/scripts/pr-watch.sh"

# Parametrized gh stub:
#   STUB_OPEN_PRS       array for pulls?state=open ("emptybytes" = broken read)
#   STUB_PR_<N>         object for pulls/<N> (explicit-arg fetches)
#   STUB_QUEUED         "yes" -> every mergeQueueEntry read answers a position
#   STUB_UNRESOLVED     count for the graphql reviewThreads read
#   STUB_GATE_HISTORY   array for commits/<sha>/statuses
#   STUB_HEAD_DATE      commit.committer.date for commits/<sha>
#   STUB_DISPATCH_LOG   file collecting workflow-run dispatches
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -u
cmd="${1:-}"
shift || true
args="$*"
if [[ "$cmd" == "workflow" ]]; then
  echo "dispatch:$args" >> "${STUB_DISPATCH_LOG:?}"
  if [[ "${STUB_DISPATCH_FAIL:-}" == "yes" ]]; then exit 1; fi
  exit 0
fi
[[ "$cmd" == "api" ]] || { echo "unexpected gh command: $cmd $args" >&2; exit 1; }
case "$args" in
  graphql*mergeQueueEntry*)
    if [[ "${STUB_QUEUE_FAIL:-}" == "yes" ]]; then
      echo "HTTP 500" >&2
      exit 1
    fi
    if [[ "${STUB_QUEUED:-}" == "yes" ]]; then
      printf 'queued\n'
    else
      printf 'unqueued\n'
    fi
    ;;
  graphql*reviewThreads*)
    if [[ "${STUB_THREADS_FAIL:-}" == "yes" ]]; then
      echo "HTTP 500" >&2
      exit 1
    fi
    if [[ "${STUB_THREADS_RAW:-}" == "emptybytes" ]]; then exit 0; fi
    if [[ -n "${STUB_THREADS_PAGES:-}" ]]; then
      # Deep-walk mode: serve STUB_THREADS_PAGES distinct ADVANCING pages
      # (all resolved), cursor CURn requesting page n+1, terminal page
      # final. The single-PAGE2 shape below cannot reach the page budget —
      # its second read never advances — so the 20-page bound needs pages
      # that genuinely differ per cursor.
      page=1
      if [[ "$args" == *"after=CUR"* ]]; then
        page="${args##*after=CUR}"
        page="${page%% *}"
        page=$((page + 1))
      fi
      if (( page < STUB_THREADS_PAGES )); then
        jq -n --arg c "CUR$page" \
          '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:true,endCursor:$c}, nodes:[{isResolved:true}]}}}}}'
      else
        jq -n '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:false}, nodes:[{isResolved:true}]}}}}}'
      fi
      exit 0
    fi
    if [[ "$args" == *"after="* && -n "${STUB_THREADS_PAGE2:-}" ]]; then
      # Cursor-dependent page: a call passing the after= CLI variable
      # (`-f after=CURSOR` — the watcher sends the cursor as a GraphQL
      # variable, never interpolated) gets page two, so tests prove the
      # walk advances instead of refetching page one.
      printf '%s\n' "$STUB_THREADS_PAGE2"
      exit 0
    fi
    if [[ -n "${STUB_THREADS_RAW:-}" ]]; then
      printf '%s\n' "$STUB_THREADS_RAW"
      exit 0
    fi
    n="${STUB_UNRESOLVED:-0}"
    next="${STUB_THREADS_NEXTPAGE:-false}"
    jq -n --argjson n "$n" --argjson next "$next" \
      '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:$next}, nodes:[range($n) | {isResolved:false}]}}}}}'
    ;;
  *"pulls?state=open"*)
    if [[ "${STUB_OPEN_PRS:-[]}" == "fail" ]]; then
      echo "HTTP 500" >&2
      exit 1
    fi
    if [[ "${STUB_OPEN_PRS:-[]}" == "emptybytes" ]]; then exit 0; fi
    printf '%s\n' "${STUB_OPEN_PRS:-[]}"
    ;;
  *pulls/*)
    n="${args##*pulls/}"
    n="${n%% *}"
    var="STUB_PR_${n}"
    if [[ -n "${!var:-}" ]]; then
      pr_row_json="${!var}"
    elif [[ -n "${STUB_OPEN_PRS:-}" && "${STUB_OPEN_PRS}" != "emptybytes" ]]; then
      pr_row_json="$(jq -e --argjson n "$n" '.[] | select((.number? // null) == $n)' <<<"$STUB_OPEN_PRS")" || { echo "HTTP 404" >&2; exit 1; }
    else
      echo "HTTP 404" >&2
      exit 1
    fi
    if [[ "$args" == *"--jq .head.sha"* ]]; then
      # The recheck read: STUB_HEAD_AFTER simulates a mid-reduction push.
      if [[ -n "${STUB_HEAD_AFTER:-}" ]]; then
        printf '%s\n' "$STUB_HEAD_AFTER"
      else
        jq -r '.head.sha' <<<"$pr_row_json"
      fi
    else
      # Row fetches: STUB_ARMED_AFTER flips auto_merge from the SECOND
      # fetch of a number (the just-in-time ownership recheck), via a
      # per-number counter.
      if [[ "${STUB_DRAFT_AFTER:-}" == "yes" && -n "${STUB_PR_CALLS_DIR:-}" ]]; then
        cf="$STUB_PR_CALLS_DIR/$n"
        if [[ -f "$cf" ]]; then
          jq '.draft = true' <<<"$pr_row_json"
        else
          : > "$cf"
          printf '%s\n' "$pr_row_json"
        fi
      elif [[ "${STUB_CLOSED_AFTER:-}" == "yes" && -n "${STUB_PR_CALLS_DIR:-}" ]]; then
        cf="$STUB_PR_CALLS_DIR/$n"
        if [[ -f "$cf" ]]; then
          jq '.state = "closed"' <<<"$pr_row_json"
        else
          : > "$cf"
          printf '%s\n' "$pr_row_json"
        fi
      elif [[ -n "${STUB_ARMED_AFTER:-}" && -n "${STUB_PR_CALLS_DIR:-}" ]]; then
        cf="$STUB_PR_CALLS_DIR/$n"
        if [[ -f "$cf" ]]; then
          if [[ "$STUB_ARMED_AFTER" == "false" ]]; then
            jq '.auto_merge = null' <<<"$pr_row_json"
          else
            jq '.auto_merge = {merge_method:"merge"}' <<<"$pr_row_json"
          fi
        else
          : > "$cf"
          printf '%s\n' "$pr_row_json"
        fi
      else
        printf '%s\n' "$pr_row_json"
      fi
    fi
    ;;
  *"/timeline?per_page=100"*)
    if [[ "${STUB_TIMELINE_FAIL:-}" == "yes" ]]; then
      echo "HTTP 500" >&2
      exit 1
    fi
    if [[ "${STUB_TIMELINE_EMPTYBYTES:-}" == "yes" ]]; then exit 0; fi
    if [[ -n "${STUB_REREQUEST_AT:-}" ]]; then
      jq -n --arg at "$STUB_REREQUEST_AT" '[{event:"review_requested", created_at:$at}]'
    elif [[ -n "${STUB_REOPENED_AT:-}" ]]; then
      jq -n --arg at "$STUB_REOPENED_AT" '[{event:"reopened", created_at:$at}]'
    elif [[ -n "${STUB_READY_AT:-}" ]]; then
      jq -n --arg at "$STUB_READY_AT" '[{event:"ready_for_review", created_at:$at}]'
    else
      printf '[]\n'
    fi
    ;;
  *"/statuses?per_page=100"*)
    if [[ "${STUB_GATE_HISTORY:-[]}" == "emptybytes" ]]; then exit 0; fi
    printf '%s\n' "${STUB_GATE_HISTORY:-[]}"
    ;;
  *commits/*)
    printf '%s\n' "${STUB_HEAD_DATE:-2026-01-01T00:00:00Z}"
    ;;
  *)
    echo "unexpected gh api: $args" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$TMP_ROOT/bin/gh"

HEAD_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HEAD_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
pr_row() { # number, [state], [armed], [draft], [created_at] -> one pulls-list row
  jq -n --argjson n "$1" --arg state "${2:-open}" --arg armed "${3:-armed}" --arg draft "${4:-false}" \
    --arg created "${5:-2026-01-01T00:00:00Z}" --arg head "$HEAD_A" \
    '{number:$n, state:$state, draft:($draft=="true"), head:{sha:$head, ref:"lane"}, user:{login:"author"},
      created_at:$created,
      auto_merge: (if $armed=="armed" then {merge_method:"merge"} else null end)}'
}


REAL_DATE="$(command -v date)"
WATCH_NOW="$(date +%s)"
export REAL_DATE WATCH_NOW
cat > "$TMP_ROOT/bin/date" <<'EOF'
#!/usr/bin/env bash
if [ "$*" = "+%s" ]; then printf '%s\n' "$WATCH_NOW"; exit 0; fi
exec "$REAL_DATE" "$@"
EOF
chmod +x "$TMP_ROOT/bin/date"
FUTURE_EPOCH="$(date -u -d '2030-01-01T00:00:00Z' +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' '2030-01-01T00:00:00Z' +%s)"
FUTURE_SKEW=$((FUTURE_EPOCH - WATCH_NOW))
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

OLD='2026-01-01T00:00:00Z'
P7="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')"
G_OK='[{"context":"Review gate","state":"success"}]'
G_PENDING='[{"context":"Review gate","state":"pending"}]'
V_APPROVED='verdict=approved detail=review evidence at head'
V_AWAITING='verdict=awaiting detail=no evidence'

# --- harness -----------------------------------------------------------------

# run_watch ENV FLAGS... — runs the sandboxed pr-watch with the stub PATH and
# GH_REPO set; ENV is a semicolon-separated list of `env` arguments (JSON
# values carry commas). Every run gets its own dispatch log, per-number fetch
# counter and predicate-call log under $RUN. OUT is stdout and stderr
# together, the way the scheduler sees it; RC the exit status.
RUN_SEQ=0
WATCH_BIN="$TMP_ROOT/scripts/pr-watch.sh"   # a mutant row swaps this
run_watch() {
  local env_list="$1" env_args=()
  shift
  [[ -z "$env_list" ]] || IFS=';' read -ra env_args <<<"$env_list"
  RUN="$TMP_ROOT/runs/$((++RUN_SEQ))"
  mkdir -p "$RUN/prcalls"
  : > "$RUN/dispatch.log"
  : > "$RUN/predicate-calls"
  set +e
  OUT=$(cd "$TMP_ROOT/cwd" && PATH="$TMP_ROOT/bin:$PATH" \
    env GH_REPO=acme/widgets STUB_DISPATCH_LOG="$RUN/dispatch.log" \
        STUB_PR_CALLS_DIR="$RUN/prcalls" STUB_PREDICATE_CALLS="$RUN/predicate-calls" \
        ${env_args[@]+"${env_args[@]}"} "$WATCH_BIN" "$@" 2>&1)
  RC=$?
  set -e
}

# observe EXPECT — prints the run's value of every `name=` field EXPECT names,
# in EXPECT's order:
#   rc               exit status
#   kinds            the kind column of every finding line, in order, or none
#                    (the tab-separated output is the contract --help states)
#   threads          the count a threads-open line reports, or `overflow`
#   queued_notes     finding lines carrying the queued dequeue note
#   dispatches       writer dispatch attempts the stub received
#   predicate_calls  predicate invocations
#   protocol         whole stdout record, tabs as ~, spaces as +, lines as ;
#   error_payload    complete error TSV record when attention precedes it
#   diagnostic       exact global refusal record, spaces as +
observe() {
  local got="" token name value field_sep='~'
  for token in $1; do
    name="${token%%=*}"
    case "$name" in
      rc) value="$RC" ;;
      kinds) value="$(awk -F'\t' 'NF >= 3 {print $3}' <<<"$OUT" | paste -sd, - || true)"; value="${value:-none}" ;;
      threads)
        if grep -q 'threads-open.*overflow' <<<"$OUT"; then value=overflow
        else value="$(grep -o '[0-9]* unresolved review thread' <<<"$OUT" | head -1 | grep -o '^[0-9]*' || true)"; value="${value:-none}"; fi
        ;;
      queued_notes) value="$(grep -c 'QUEUED: dequeue' <<<"$OUT" || true)" ;;
      dispatches) value="$(wc -l <"$RUN/dispatch.log" | tr -d ' ')" ;;
      predicate_calls) value="$(wc -l <"$RUN/predicate-calls" | tr -d ' ')" ;;
      protocol)
        value="${OUT//$'\t'/$field_sep}"
        value="${value//$'\n'/;}"
        value="${value// /+}" ;;
      diagnostic)
        value="$(sed -n '/^review-gate-/p' <<<"$OUT")"
        value="${value// /+}" ;;
      error_payload)
        value="$(awk -F'\t' '$3 == "error" {print}' <<<"$OUT")"
        value="${value//$'\t'/$field_sep}"
        value="${value// /+}" ;;
      size)
        # The disarmed line's size annotation reduced to the fields the
        # contract names — the counts and their ratio, the measured head,
        # or the one word a stale or missing record answers with.
        local line
        line="$(grep -o 'disarmed.*' <<<"$OUT" | head -1 || true)"
        if [[ "$line" != *"— size "* ]]; then value=none
        elif [[ "$line" == *"size unavailable"* ]]; then value=unavailable
        elif [[ "$line" =~ size\ stale:\ the\ recorded\ measurement\ is\ of\ ([0-9a-f]{8}) ]]; then
          value="stale@${BASH_REMATCH[1]}"
        elif [[ "$line" =~ size\ ([0-9]+)\ of\ ([0-9]+)\ production\ lines\ added\ \(([0-9]+)%\ of\ the\ allowance\),\ measured\ at\ ([0-9a-f]{8}) ]]; then
          value="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/${BASH_REMATCH[3]}%@${BASH_REMATCH[4]}"
        elif [[ "$line" =~ size\ ([0-9]+)\ of\ ([0-9]+)\ production\ lines\ added,\ measured\ at\ ([0-9a-f]{8}) ]]; then
          value="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}@${BASH_REMATCH[3]}"
        elif [[ "$line" =~ size\ ([0-9]+)\ production\ lines\ added,\ no\ allowance\ stated,\ measured\ at\ ([0-9a-f]{8}) ]]; then
          value="${BASH_REMATCH[1]}/none@${BASH_REMATCH[2]}"
        else value=unparsed; fi
        # The verdict rides the same line and is matched last, after the
        # counts above have been read out of BASH_REMATCH.
        if [[ "$line" =~ submit\ recorded\ ([a-z_]+) ]]; then value="$value!${BASH_REMATCH[1]}"; fi
        ;;
      *) value=UNKNOWN_FIELD ;;
    esac
    got="$got $name=$value"
  done
  printf '%s' "${got# }"
}

# table ROW... — one run and one assertion per row: `label|flags|env|expect`.
table() {
  local row label flags env expect
  for row in "$@"; do
    IFS='|' read -r label flags env expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    # shellcheck disable=SC2086
    run_watch "$env" $flags
    assert_eq "$(observe "$expect")" "$expect" "$label"
  done
}
