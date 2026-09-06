#!/usr/bin/env bash
# Behavioural tests for the shipped skills/review-gate/scripts/pr-watch.sh,
# the needs-attention reducer: stubbed gh and stubbed predicate, every
# reduction arm driven offline. The output contract is the tab-separated
# finding line --help states, `<pr> <head-8> <kind> <detail>`, so the kind
# column and the exit status are what rows pin; a detail word is pinned only
# where it alone tells one error shape from another.
#
# One case per behaviour surface; shaped input is one table per case, one
# asserted row per shape. A row's `expect` names the fields it pins and
# `observe` reads exactly those, so a row fails on the field it names.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        must not contain: %s\n' "$name" "$needle"
  else
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  fi
}

# Sandbox: the real pr-watch + real settings lib + a stubbed predicate.
mkdir -p "$TMP_ROOT/scripts/lib" "$TMP_ROOT/bin" "$TMP_ROOT/cwd"
cp "$SKILL_ROOT/scripts/pr-watch.sh" "$TMP_ROOT/scripts/"
cp "$SKILL_ROOT/scripts/lib/settings.sh" "$TMP_ROOT/scripts/lib/"
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

# One orch workflow-state file per size fixture, the shape branch-size-check
# writes: the record under `pr.size_check`, keyed by the lane's own branch and
# bound to the head it measured. A null allowance is the `allowance_missing`
# verdict, which the check emits for an issue that states no expected delta.
size_state() { # dir, branch, head_sha, production_lines, allowance-or-null, [verdict]
  mkdir -p "$1"
  jq -n --arg branch "$2" --arg head "$3" --argjson prod "$4" --argjson allow "$5" \
    --arg verdict "${6:-}" \
    '{issue_id:"KEN-1", branch:$branch, worktree:"/wt",
      pr:{baseline_lines:100,
          size_check:{base_sha:"0000000000000000000000000000000000000000", head_sha:$head,
                      production_lines:$prod, test_lines:40, mirror_lines:0,
                      production_allowance:$allow, test_allowance:null,
                      verdict:(if $verdict != "" then $verdict
                               elif $allow == null then "allowance_missing"
                               else "pass" end),
                      reason:""}}}' > "$1/workflow-state-KEN-1.json"
}
SD_CURRENT="$TMP_ROOT/state/current"; size_state "$SD_CURRENT" lane "$HEAD_A" 214 250
SD_STALE="$TMP_ROOT/state/stale";     size_state "$SD_STALE"   lane "$HEAD_B" 214 250
SD_NOALLOW="$TMP_ROOT/state/noallow"; size_state "$SD_NOALLOW" lane "$HEAD_A" 214 null
SD_OTHER="$TMP_ROOT/state/other";     size_state "$SD_OTHER"   other-lane "$HEAD_A" 214 250
# A stated allowance of zero is a real number, not an absent line: the check's
# delta grammar accepts `0 lines`, which is how a test-only issue states its
# production budget. Past it, and past a test allowance the production ratio
# says nothing about, the verdict is the only signal. `workflow-state init`
# with no --branch records the empty string, so an empty head ref must never
# be allowed to key the lookup.
SD_ZERO="$TMP_ROOT/state/zero";           size_state "$SD_ZERO"      lane "$HEAD_A"   5   0 production_over
SD_TESTSOVER="$TMP_ROOT/state/testsover"; size_state "$SD_TESTSOVER" lane "$HEAD_A" 214 250 tests_over
SD_NOBRANCH="$TMP_ROOT/state/nobranch";   size_state "$SD_NOBRANCH"  ""   "$HEAD_A" 214 250

# --- fixtures ----------------------------------------------------------------
# Open-PR listings: number 7 armed, unarmed, unarmed draft, armed draft, two
# armed PRs, one created now, a ghost author, an unparsable creation time.
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
OLD='2026-01-01T00:00:00Z'
P7="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')"
P7U="$(jq -cn --argjson r "$(pr_row 7 open unarmed)" '[$r]')"
P7UD="$(jq -cn --argjson r "$(pr_row 7 open unarmed true)" '[$r]')"
P7UNOREF="$(jq -cn --argjson r "$(pr_row 7 open unarmed | jq 'del(.head.ref)')" '[$r]')"
P7AD="$(jq -cn --argjson r "$(pr_row 7 open armed true)" '[$r]')"
P78="$(jq -cn --argjson a "$(pr_row 7)" --argjson b "$(pr_row 8)" '[$a,$b]')"
P7NEW="$(jq -cn --argjson r "$(pr_row 7 open armed false "$NOW")" '[$r]')"
P7GHOST="$(jq -cn --arg head "$HEAD_A" '[{number:7, state:"open", draft:false, head:{sha:$head}, user:null, created_at:"2026-01-01T00:00:00Z", auto_merge:{merge_method:"merge"}}]')"
P7BADTIMES="$(jq -cn --arg head "$HEAD_A" '[{number:7, state:"open", draft:false, head:{sha:$head}, user:{login:"author"}, created_at:"garbage", auto_merge:{merge_method:"merge"}}]')"
P7BADCREATED="$(jq -cn --argjson r "$(pr_row 7 open armed false garbage)" '[$r]')"
# Explicit-argument fetches.
PR9CLOSED="$(pr_row 9 closed | jq -c .)"
PR9BOGUS="$(pr_row 9 bogus | jq -c .)"
PR9PARTIAL="$(jq -cn --arg head "$HEAD_A" '{number:9, state:"open", head:{sha:$head}, user:{login:"author"}}')"
PR9NONSHA="$(jq -cn '{number:9, state:"open", draft:false, head:{sha:"main"}, user:{login:"author"}, created_at:"2026-01-01T00:00:00Z", auto_merge:null}')"
PR9EMPTYARM="$(jq -cn --arg head "$HEAD_A" '{number:9, state:"open", draft:false, head:{sha:$head}, user:{login:"author"}, created_at:"2026-01-01T00:00:00Z", auto_merge:{}}')"
# Gate-status histories and predicate verdict lines.
G_OK='[{"context":"Review gate","state":"success"}]'
G_PENDING='[{"context":"Review gate","state":"pending"}]'
G_NULL='[{"context":"Review gate","state":null}]'
G_BOGUS='[{"context":"Review gate","state":"bogus"}]'
V_APPROVED='verdict=approved detail=review evidence at head'
V_THREADS1='verdict=threads-open detail=1 unresolved review threads'
V_THREADS2='verdict=threads-open detail=2 unresolved review threads'
V_CHANGES='verdict=changes-requested detail=reviewer objects'
V_AWAITING='verdict=awaiting detail=no evidence'
V_OFF='verdict=approved detail=review gate disabled by settings (REVIEW_GATE_MODE=off)'
V_UNTRACKED='verdict=untracked-claim detail=1 tracking claim naming no issue'
V_UNREASONED='verdict=unreasoned-decline detail=1 decline naming no mechanism'
V_GARBAGE='garbage output with no verdict'
# Raw reviewThreads bodies: a cursor that never advances, page one of two
# (both resolved), page two with one open or one resolved thread, and the
# malformed shapes.
T_STUCK='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"CUR1"},"nodes":[{"isResolved":false}]}}}}}'
T_PAGE1='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"CUR1"},"nodes":[{"isResolved":true},{"isResolved":true}]}}}}}'
T_PAGE2_OPEN='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":false}]}}}}}'
T_PAGE2_RESOLVED='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":true}]}}}}}'
T_NULLNODE='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":null}]}}}}}'
T_BADPAGEINFO='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":null},"nodes":[]}}}}}'
T_NONARRAY='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":{"item":{"isResolved":true}}}}}}}'

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
#   detail~<word>    whether any output names <word>: the one word that
#                    tells two error shapes apart when kind and exit agree
#   help_sections    the --help sections present, of usage, kinds (the
#                    untracked-claim and unreasoned-decline kinds) and exits
observe() {
  local got="" token name value
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
      detail~*) value="$(grep -qF -- "${name#detail~}" <<<"$OUT" && echo true || echo false)" ;;
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
      help_sections)
        value=""
        grep -q '^Usage: pr-watch.sh' <<<"$OUT" && value="$value,usage"
        grep -q 'untracked-claim' <<<"$OUT" && grep -q 'unreasoned-decline' <<<"$OUT" && value="$value,kinds"
        grep -q 'GLOBAL failures' <<<"$OUT" && value="$value,exits"
        value="${value#,}"; value="${value:-none}"
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

echo "=== the reduction over verdict, gate state, arming and queue membership ==="
# A healthy PR is silence. Threads are read directly in both modes, so a
# repo whose predicate ignores them still reports them; a verdict and a gate
# state that disagree are gate-stale in either direction and --heal
# dispatches the writer once per invocation, a failed dispatch included.
# Every finding is its own line, none eats another, and duplicates dedupe.
table \
  "approved, gate success, armed: silence||STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=0 kinds=none" \
  "threads-open carries the count||STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_THREADS2|rc=1 kinds=threads-open threads=2" \
  "threads-open on a queued PR carries the dequeue note||STUB_QUEUED=yes;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_THREADS1|rc=1 kinds=threads-open queued_notes=1" \
  "changes-requested||STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_CHANGES|rc=1 kinds=changes-requested" \
  "approved over a pending gate is gate-stale||STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_PENDING|rc=1 kinds=gate-stale" \
  "--heal dispatches the writer once across two stale PRs|--heal|STUB_OPEN_PRS=$P78;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_PENDING|rc=1 kinds=gate-stale,heal-dispatched,gate-stale dispatches=1" \
  "a failed dispatch still consumes the one attempt|--heal|STUB_DISPATCH_FAIL=yes;STUB_OPEN_PRS=$P78;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_PENDING|rc=2 kinds=gate-stale,error,gate-stale dispatches=1" \
  "awaiting over a green gate is gate-stale and heals|--heal --awaiting-after 3600|STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_GATE_HISTORY=$G_OK;STUB_HEAD_DATE=$NOW|rc=1 kinds=gate-stale,heal-dispatched dispatches=1" \
  "an objection over a green gate reports both||STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_CHANGES;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=changes-requested,gate-stale" \
  "queued lines all carry the dequeue note||STUB_QUEUED=yes;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_CHANGES;STUB_GATE_HISTORY=$G_OK|rc=1 queued_notes=2" \
  "approved, gate success, not armed, not queued: disarmed||STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed" \
  "the same shape queued: the queue owns the merge||STUB_QUEUED=yes;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=0 kinds=none" \
  "a draft never gets the disarmed nag||STUB_OPEN_PRS=$P7UD;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=0 kinds=none" \
  "threads are read directly even under an approved verdict||STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=2;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=threads-open,gate-stale threads=2" \
  "open threads do not suppress a standing objection||STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=1;STUB_VERDICT_LINE=$V_CHANGES|rc=1 kinds=threads-open,changes-requested" \
  "the predicate's duplicate threads-open verdict dedupes||STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=1;STUB_VERDICT_LINE=$V_THREADS1|rc=1 kinds=threads-open" \
  "the predicate's paging-race threads verdict heals a green gate|--heal|STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=0;STUB_VERDICT_LINE=$V_THREADS1;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=threads-open,gate-stale,heal-dispatched dispatches=1" \
  "cheap mode reports threads by direct read and never consults the predicate|--no-evaluate|STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=3;STUB_VERDICT_LINE=unused|rc=1 kinds=threads-open threads=3 predicate_calls=0" \
  "cheap mode still emits disarmed|--no-evaluate|STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=unused;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed" \
  "cheap mode fires the threads-driven gate-stale and heals|--no-evaluate --heal|STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=1;STUB_VERDICT_LINE=unused;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=threads-open,gate-stale,heal-dispatched dispatches=1" \
  "REVIEW_GATE_THREADS=off: threads report, a green gate over them is designed|--heal|REVIEW_GATE_THREADS=off;STUB_QUEUED=no;STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=2;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=threads-open dispatches=0" \
  "REVIEW_GATE_MODE=off: the same|--heal|REVIEW_GATE_MODE=off;STUB_QUEUED=no;STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=2;STUB_VERDICT_LINE=$V_OFF;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=threads-open dispatches=0" \
  "REVIEW_GATE_THREADS=off: open threads do not eat the disarmed finding||REVIEW_GATE_THREADS=off;STUB_OPEN_PRS=$P7U;STUB_UNRESOLVED=2;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=threads-open,disarmed"

echo "=== the disarmed line carries the submit-size record ==="
# branch-size-check records the branch's measured size at submit, keyed by the
# lane's branch and bound to the head it compared; the reducer reads that
# record and never re-measures. Both disarmed paths carry it, a record of any
# other head reads stale rather than as this head's size, and a state
# directory holding only another lane's record leaves this one unavailable.
table \
  "the evaluated disarmed line carries the counts and their ratio||ORCH_STATE_DIR=$SD_CURRENT;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed size=214/250/85%@aaaaaaaa" \
  "cheap mode's disarmed line carries the same annotation|--no-evaluate|ORCH_STATE_DIR=$SD_CURRENT;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=unused;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed size=214/250/85%@aaaaaaaa" \
  "a record of another head reads stale, never as this head's size||ORCH_STATE_DIR=$SD_STALE;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed size=stale@bbbbbbbb" \
  "another lane's record leaves this branch unavailable||ORCH_STATE_DIR=$SD_OTHER;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed size=unavailable" \
  "no state directory at all is unavailable||ORCH_STATE_DIR=$TMP_ROOT/state/absent;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed size=unavailable" \
  "a record stating no allowance reports the count and no ratio||ORCH_STATE_DIR=$SD_NOALLOW;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed size=214/none@aaaaaaaa" \
  "a stated allowance of zero is reported as the number it is||ORCH_STATE_DIR=$SD_ZERO;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed size=5/0@aaaaaaaa!production_over" \
  "a test-allowance breach is named, not hidden by a clean ratio||ORCH_STATE_DIR=$SD_TESTSOVER;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed size=214/250/85%@aaaaaaaa!tests_over" \
  "a PR row with no head ref keys nothing and reads unavailable||ORCH_STATE_DIR=$SD_NOBRANCH;STUB_OPEN_PRS=$P7UNOREF;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed size=unavailable"

echo "=== must-fail controls for the surfaces above ==="
# Each control fails against a copy of the reducer with the one expression it
# depends on removed: the call at each disarmed site, the head binding that
# makes a record current, the branch binding that makes it this lane's, and
# the guard that stops an empty branch from keying the lookup at all.
mutant_watch() { # label, sed-expr, anchor — points WATCH_BIN at the mutated copy
  local dir="$TMP_ROOT/mutants/$1"
  mkdir -p "$dir/lib"
  cp "$TMP_ROOT/scripts/pr-watch.sh" "$TMP_ROOT/scripts/review-predicate.sh" "$dir/"
  cp "$TMP_ROOT/scripts/lib/settings.sh" "$dir/lib/"
  chmod +x "$dir/pr-watch.sh" "$dir/review-predicate.sh"
  assert_eq "$(grep -Fc -- "$3" "$dir/pr-watch.sh")" "1" "mutant $1: its anchor stands once in the live script"
  sed -i.bak "$2" "$dir/pr-watch.sh"
  assert_eq "$(grep -Fc -- "$3" "$dir/pr-watch.sh")" "0" "mutant $1: the anchor is gone from the copy"
  WATCH_BIN="$dir/pr-watch.sh"
}
LIVE_WATCH="$WATCH_BIN"

mutant_watch evaluated-call 's|(re-arm)$(size_note "$head_ref" "$head")|(re-arm)|' '(re-arm)$(size_note'
table "must-fail: without the evaluated site's call that line carries no size||ORCH_STATE_DIR=$SD_CURRENT;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed size=none"

mutant_watch cheap-call 's|before re-arming$(size_note "$head_ref" "$head")|before re-arming|' 'before re-arming$(size_note'
table "must-fail: without the cheap site's call that line carries no size|--no-evaluate|ORCH_STATE_DIR=$SD_CURRENT;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=unused;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed size=none"

mutant_watch head-binding 's#map(select(.head_sha == $head)) | first#first#' 'map(select(.head_sha == $head)) | first'
table "must-fail: without the head binding the old record reads as current||ORCH_STATE_DIR=$SD_STALE;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed size=214/250/85%@bbbbbbbb"

mutant_watch branch-binding 's#(.branch? // "") == $branch#true#' '(.branch? // "") == $branch'
table "must-fail: without the branch binding another lane's record is reported||ORCH_STATE_DIR=$SD_OTHER;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed size=214/250/85%@aaaaaaaa"

mutant_watch empty-branch-guard 's#if \[ -n "$branch" \]; then#if true; then#' 'if [ -n "$branch" ]; then'
table "must-fail: without the empty-branch guard a branchless lane's record is reported||ORCH_STATE_DIR=$SD_NOBRANCH;STUB_OPEN_PRS=$P7UNOREF;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed size=214/250/85%@aaaaaaaa"

WATCH_BIN="$LIVE_WATCH"

echo "=== the predicate's disposition verdicts reach the reducer ==="
# The two thread-disposition verdicts the predicate can return, driven through
# the reducer arm that consumes each. unreasoned-decline.test.sh decides both
# terms and stops at the count; these rows are the other half — the verdict
# named in the kind column, the attention exit, the stale-green companion a
# green gate over either verdict earns, and the writer dispatch --heal makes
# of it. A presence grep on the arm stood in for these rows until the suite
# they belong beside stopped being size-capped; a grep passes on a branch
# nothing runs.
table \
  "unreasoned-decline is its own kind and its own attention||STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_UNREASONED;STUB_GATE_HISTORY=$G_PENDING|rc=1 kinds=unreasoned-decline" \
  "a green gate over it is gate-stale and --heal dispatches the writer at it|--heal|STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_UNREASONED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=unreasoned-decline,gate-stale,heal-dispatched dispatches=1" \
  "untracked-claim is its own kind and its own attention||STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_UNTRACKED;STUB_GATE_HISTORY=$G_PENDING|rc=1 kinds=untracked-claim" \
  "a green gate over it is gate-stale and heals the same way|--heal|STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_UNTRACKED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=untracked-claim,gate-stale,heal-dispatched dispatches=1"

# The rows above read a kind column, and a column can be right for the wrong
# reason: the predicate's verdict word is in the stubbed input, so a reducer
# that echoed its input would satisfy them. With the kind the unreasoned arm
# emits misspelled, the first row must read the misspelling and nothing else
# about the run may move.
mutant_watch emitted-kind 's| unreasoned-decline "$detail$queued"| unreasoned-declined "$detail$queued"|' ' unreasoned-decline "$detail$queued"'
table "must-fail: with the emitted kind misspelled the row reads the misspelling||STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_UNREASONED;STUB_GATE_HISTORY=$G_PENDING|rc=1 kinds=unreasoned-declined"
WATCH_BIN="$LIVE_WATCH"

echo "=== the thread walk is paged, summed and bounded ==="
# Over 100 threads, a cursor that never advances, or more than 20 advancing
# pages fail closed as overflow attention; a thread on page two is counted;
# resolved history across pages, 20 pages included, is healthy. Open threads
# under an approved verdict also make the (absent or green) gate stale.
table \
  "over 100 threads is overflow||STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=100;STUB_THREADS_NEXTPAGE=true;STUB_VERDICT_LINE=$V_APPROVED|rc=1 kinds=threads-open,gate-stale threads=overflow" \
  "a cursor that never advances is overflow at the bound||STUB_OPEN_PRS=$P7;STUB_THREADS_RAW=$T_STUCK;STUB_VERDICT_LINE=$V_APPROVED|rc=1 kinds=threads-open,gate-stale threads=overflow" \
  "an unresolved thread on page two is counted||STUB_OPEN_PRS=$P7;STUB_THREADS_RAW=$T_PAGE1;STUB_THREADS_PAGE2=$T_PAGE2_OPEN;STUB_VERDICT_LINE=$V_APPROVED|rc=1 kinds=threads-open,gate-stale threads=1" \
  "resolved history across pages is healthy||STUB_OPEN_PRS=$P7;STUB_THREADS_RAW=$T_PAGE1;STUB_THREADS_PAGE2=$T_PAGE2_RESOLVED;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=0 kinds=none" \
  "25 advancing resolved pages breach the budget: overflow||STUB_OPEN_PRS=$P7;STUB_THREADS_PAGES=25;STUB_VERDICT_LINE=$V_APPROVED|rc=1 kinds=threads-open,gate-stale threads=overflow" \
  "exactly 20 advancing resolved pages are healthy||STUB_OPEN_PRS=$P7;STUB_THREADS_PAGES=20;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=0 kinds=none"

echo "=== the reviewer-silence clock ==="
# Awaiting is stale only past the quiet period, measured from the newest of
# the head commit, the PR's creation, and a readiness, reopen or re-review
# event; drafts are never nagged. PR_REVIEW_WAIT_SECS drives the same clock
# as --awaiting-after, and a zero-padded value is judged by magnitude.
table \
  "a head younger than the threshold is silent|--awaiting-after 3600|STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$NOW|rc=0 kinds=none" \
  "a head older than the threshold is awaiting-stale|--awaiting-after 60|STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=1 kinds=awaiting-stale" \
  "PR_REVIEW_WAIT_SECS drives the same clock||PR_REVIEW_WAIT_SECS=60;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=1 kinds=awaiting-stale" \
  "a zero-padded --awaiting-after is judged by magnitude|--awaiting-after 0000000000060|STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=1 kinds=awaiting-stale" \
  "an old commit in a fresh PR is not stale: creation floors the clock|--awaiting-after 3600|STUB_OPEN_PRS=$P7NEW;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=0 kinds=none" \
  "an old draft is not awaiting-stale|--awaiting-after 60|STUB_OPEN_PRS=$P7AD;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=0 kinds=none" \
  "a fresh ready_for_review restarts the quiet period|--awaiting-after 3600|STUB_READY_AT=$NOW;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=0 kinds=none" \
  "a fresh reopen restarts the quiet period|--awaiting-after 3600|STUB_REOPENED_AT=$NOW;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=0 kinds=none" \
  "a fresh re-review request restarts the quiet period|--awaiting-after 3600|STUB_REREQUEST_AT=$NOW;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=0 kinds=none"

echo "=== a head that moves or a PR that changes mid-reduction ==="
# The just-in-time recheck: a moved head is attention, a disarm is caught, a
# close silences the re-arm nudge, a draft conversion skips only the nudge.
table \
  "a head that moved during the reduction is head-moved||STUB_HEAD_AFTER=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=head-moved" \
  "a mid-reduction disarm is caught||STUB_ARMED_AFTER=false;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed" \
  "a mid-reduction close gets no re-arm nudge||STUB_CLOSED_AFTER=yes;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=0 kinds=none" \
  "a mid-reduction draft conversion skips only the nudge|--heal --awaiting-after 3600|STUB_DRAFT_AFTER=yes;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=$V_AWAITING;STUB_GATE_HISTORY=$G_OK;STUB_HEAD_DATE=$NOW|rc=1 kinds=gate-stale,heal-dispatched"

echo "=== explicit PR arguments ==="
# A fixture whose predicate line is `unused` ends in an error line of its own
# once the schema boundary is passed, so each boundary row pins the word only
# the boundary emits.
table \
  "a closed PR is skipped silently|9|STUB_PR_9=$PR9CLOSED;STUB_VERDICT_LINE=unused|rc=0 kinds=none" \
  "a zero-padded argument normalizes|09|STUB_PR_9=$PR9CLOSED;STUB_VERDICT_LINE=unused|rc=0 kinds=none" \
  "a junk response is that PR's error line and the rest still process|5 6|STUB_PR_5=not json at all;STUB_PR_6=$(pr_row 6 closed | jq -c .);STUB_VERDICT_LINE=unused|rc=2 kinds=error detail~well-formed=true" \
  "a response describing a different PR fails the binding check|9|STUB_PR_9=$(pr_row 7 | jq -c .);STUB_VERDICT_LINE=unused|rc=2 kinds=error detail~well-formed=true" \
  "a state outside the open or closed enum is malformed, never a skip|9|STUB_PR_9=$PR9BOGUS;STUB_VERDICT_LINE=unused|rc=2 kinds=error detail~enum=true" \
  "a PR object missing reducer fields is malformed|9|STUB_PR_9=$PR9PARTIAL;STUB_VERDICT_LINE=unused|rc=2 kinds=error detail~well-formed=true" \
  "a non-sha initial head is malformed|9|STUB_PR_9=$PR9NONSHA;STUB_VERDICT_LINE=unused|rc=2 kinds=error detail~well-formed=true" \
  "an empty auto_merge object is malformed, never silently armed|9|STUB_PR_9=$PR9EMPTYARM;STUB_VERDICT_LINE=unused|rc=2 kinds=error detail~well-formed=true"

echo "=== a broken read is an error, never health ==="
# Exit 2 with an error line; the word pinned is the one that tells the shape
# apart from its neighbours with the same kind and exit. The queue read's
# envelope and errors[] guards live inside `gh api --jq`, which the stub
# never runs, so one failed-read row is all the stub can drive there.
table \
  "predicate failure||STUB_OPEN_PRS=$P7;STUB_PREDICATE_RC=2;STUB_VERDICT_LINE=unused|rc=2 kinds=error detail~predicate=true" \
  "a zero-exit predicate with no recognizable verdict||STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_GARBAGE|rc=2 kinds=error detail~verdict=true" \
  "a zero-byte PR listing||STUB_OPEN_PRS=emptybytes;STUB_VERDICT_LINE=unused|rc=2 kinds=none detail~zero=true" \
  "a non-object listing element||STUB_OPEN_PRS=[42];STUB_VERDICT_LINE=unused|rc=2 kinds=none detail~malformed=true" \
  "an empty-object listing element||STUB_OPEN_PRS=[{}];STUB_VERDICT_LINE=unused|rc=2 kinds=none detail~malformed=true" \
  "a ghost author reduces threads and names the ghost||STUB_OPEN_PRS=$P7GHOST;STUB_UNRESOLVED=1;STUB_VERDICT_LINE=$V_APPROVED|rc=2 kinds=threads-open,error detail~deleted=true" \
  "a ghost author with nothing else to report names the cause||STUB_OPEN_PRS=$P7GHOST;STUB_VERDICT_LINE=unused|rc=2 kinds=error detail~deleted=true" \
  "a failed queue-membership read||STUB_OPEN_PRS=$P7;STUB_QUEUE_FAIL=yes;STUB_VERDICT_LINE=$V_APPROVED|rc=2 kinds=error detail~merge-queue=true" \
  "a zero-byte gate-status read||STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=emptybytes|rc=2 kinds=error detail~zero=true" \
  "a matching gate row without a state||STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_NULL|rc=2 kinds=error detail~malformed=true" \
  "a gate row with a state outside the enum||STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_BOGUS|rc=2 kinds=error detail~malformed=true" \
  "a null isResolved node||STUB_OPEN_PRS=$P7;STUB_THREADS_RAW=$T_NULLNODE;STUB_VERDICT_LINE=unused|rc=2 kinds=error detail~malformed=true" \
  "malformed pagination metadata is an error, never overflow||STUB_OPEN_PRS=$P7;STUB_THREADS_RAW=$T_BADPAGEINFO;STUB_VERDICT_LINE=unused|rc=2 kinds=error detail~pagination=true" \
  "a non-array nodes container||STUB_OPEN_PRS=$P7;STUB_THREADS_RAW=$T_NONARRAY;STUB_VERDICT_LINE=unused|rc=2 kinds=error detail~malformed=true" \
  "a zero-byte thread read||STUB_OPEN_PRS=$P7;STUB_THREADS_RAW=emptybytes;STUB_VERDICT_LINE=unused|rc=2 kinds=error detail~zero=true" \
  "a future-dated committer timestamp is unprovable silence|--awaiting-after 60|STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=2030-01-01T00:00:00Z|rc=2 kinds=error detail~unprovable=true" \
  "unparsable timestamps|--awaiting-after 60|STUB_OPEN_PRS=$P7BADTIMES;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=also-garbage|rc=2 kinds=error detail~unparsable=true" \
  "an unparsable creation timestamp|--awaiting-after 60|STUB_OPEN_PRS=$P7BADCREATED;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=2 kinds=error detail~unparsable=true" \
  "a head commit without a committer date|--awaiting-after 60|STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=null|rc=2 kinds=error detail~committer=true" \
  "a timeline failure while confirming staleness|--awaiting-after 60|STUB_TIMELINE_FAIL=yes;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=2 kinds=error" \
  "a zero-byte timeline response|--awaiting-after 60|STUB_TIMELINE_EMPTYBYTES=yes;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=2 kinds=error detail~zero=true" \
  "an unparsable readiness timestamp|--awaiting-after 60|STUB_READY_AT=garbage-timestamp;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=2 kinds=error" \
  "a future-dated timeline event|--awaiting-after 60|STUB_READY_AT=2030-01-01T00:00:00Z;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=2 kinds=error detail~unprovable=true" \
  "a recheck returning no usable sha||STUB_HEAD_AFTER=null;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=2 kinds=error detail~usable=true" \
  "a non-sha recheck value is a broken read, never head-moved||STUB_HEAD_AFTER=42;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=2 kinds=error"

echo "=== configuration errors refuse to reduce ==="
table \
  "a non-numeric PR_REVIEW_WAIT_SECS||PR_REVIEW_WAIT_SECS=90s;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=2 kinds=none detail~PR_REVIEW_WAIT_SECS=true" \
  "a PR_REVIEW_WAIT_SECS past the integer range||PR_REVIEW_WAIT_SECS=99999999999999999999;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=2 kinds=none detail~range=true" \
  "an --awaiting-after past the integer range|--awaiting-after 99999999999999999999|STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=2 kinds=none detail~range=true" \
  "an invalid REVIEW_GATE_THREADS||REVIEW_GATE_THREADS=of;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=unused|rc=2 kinds=none detail~REVIEW_GATE_THREADS=true" \
  "an invalid REVIEW_GATE_MODE||REVIEW_GATE_MODE=offf;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=unused|rc=2 kinds=none detail~REVIEW_GATE_MODE=true" \
  "an explicitly empty REVIEW_GATE_CONTEXT, in cheap mode too|--no-evaluate|REVIEW_GATE_CONTEXT=;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=unused|rc=2 kinds=none detail~REVIEW_GATE_CONTEXT=true"

echo "=== --help answers before the GH_REPO requirement ==="
# The contract callers route to: readable with no environment at all, against
# the shipped script, with no gh and no predicate behind it.
set +e
OUT=$(cd "$TMP_ROOT" && env -u GH_REPO "$SKILL_ROOT/scripts/pr-watch.sh" --help 2>&1); RC=$?
set -e
assert_eq "$(observe "rc=0 help_sections=usage,kinds,exits")" "rc=0 help_sections=usage,kinds,exits" "--help exits 0 with GH_REPO unset and carries the routed sections"
set +e
OUT=$(cd "$TMP_ROOT" && env -u GH_REPO "$SKILL_ROOT/scripts/pr-watch.sh" -h 2>&1); RC=$?
set -e
assert_eq "$(observe "rc=0 help_sections=usage,kinds,exits")" "rc=0 help_sections=usage,kinds,exits" "-h is the same"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
