#!/usr/bin/env bash
# Behavioral tests for the SHIPPED skills/review-gate/scripts/review-writer.sh
# — the v2 single-writer orchestration (Layer 1 of the plan's validation:
# stubbed GitHub API, every leg driven offline). Clones the
# approval-refire.test.sh harness: the writer runs against a STUBBED
# review-predicate.sh placed next to it plus a parametrized `gh` stub with
# POST/rerun logs.
#
# Single-head passes (the enumeration's recursive contract):
#   w1.  awaiting, no gate status            -> posts pending, no rerun
#   w2.  awaiting, already pending w/ same   -> no-op: two evaluations leave
#        description (second run)               ONE status entry (idempotence)
#   w3.  changes-requested with a NEWER      -> posts failure directly —
#        success entry in history               downward posts never defer
#   w4.  threads-open                        -> posts pending (downward path)
#   w5.  approved, current status success    -> no-op (no POST, no rerun)
#   w6.  approved, PRIOR success on the sha  -> direct success post through
#        (current pending)                      the guard, NO rerun
#   w7.  approved flip, no prior success,    -> reruns the head's completed
#        no evidence_at                         pull_request runs and posts
#                                               the provenance MARKER; NO
#                                               success (success-needs-proof)
#   w8.  marker-less completion (10a)        -> the completing attempt ran
#                                               gate-closed: proof rerun +
#                                               marker, NEVER success
#   w8b. marker + completed attempt >= 2     -> posts the FIRST success
#   w8c. same, on the schedule leg           -> the cron floor also posts it
#                                               (missed events converge)
#   w8d. marker + attempt still in flight    -> posts nothing, waits
#   w8e. marker + completed ATTEMPT-1 ONLY   -> keeps waiting (binding F3:
#                                               the marker is only posted
#                                               after a rerun was issued, so
#                                               proof completions have
#                                               attempt >= 2; an attempt-1
#                                               snapshot is a stale read)
#   w9.  awaiting on a completion pass       -> posts pending, never success
# Ordering fast path (binding F1: evidence_at):
#   f1a. approved, evidence_at BEFORE a      -> direct success, ZERO rerun
#        completed attempt's start, clean       (the carry-forward push cost
#        gate history                           requirement)
#   f1b. evidence_at AFTER the attempt       -> no direct success; proof
#        started (status-form late landing)     rerun + marker instead
#   f1c. no evidence_at line at all          -> never the fast path
#   f1d. qualifying attempt but a            -> no direct success (a closed
#        non-success gate entry at/after        verdict recorded after the
#        evidence_at                            evidence proves a
#                                               post-evidence live read still
#                                               refused; hardening beyond
#                                               F1's literal rule)
#   f1e. entry with MISSING created_at       -> blocks the fast path (cannot
#                                               be ordered)
#   f1f. the VST-65 guard applies to the     -> defers on a newer
#        fast-path post too                     non-success write
#   f1g. run_started_at == evidence_at       -> never certified (one-second
#        (equal-second boundary)                resolution cannot order it)
# VST-65 ordering guard on every success post:
#   w10. guard re-read shows a non-success   -> defers (exit 0, no POST)
#        entry at/after evaluated_at
#   w10b. same-second non-success write      -> still defers (>=, not >)
#   w11. guard re-read FAILS                 -> defers (fail-safe side)
#   w12. guard also protects the prior-      -> defers the fast-path post
#        success fast path
# Rerun disposition (stuck vs malfunction, ported semantics):
#   w13. rerun refusal (unqualified 4xx)     -> warns, exit 0, no POST
#   w14. throttled through the budget        -> exit 1 (malfunction red for
#                                               VST-36); gate left pending
#   w15. throttle clearing within budget     -> exit 0, rerun lands
#   w16. rerun 401                           -> exit 1 (malfunction)
#   w17. rerun 5xx                           -> exit 1 (malfunction), no POST
#   w18. run at MAX_ATTEMPTS cap             -> exit 0, no rerun, no POST
#                                               (cap exhaustion leaves the
#                                               gate pending)
#   w19. runs still in progress              -> exit 0, left to finish (the
#                                               completion leg converges)
#   w20. no completed runs                   -> exit 0, warns and waits for
#                                               the workflow_run leg
# Fail loud, act never:
#   w21. predicate read failure              -> exit 1, NO POST, NO rerun
#   w22. status-history read failure         -> exit 1, NO POST, NO rerun
#   w23. PR_NUMBER without HEAD_SHA          -> exit 1 (recursive contract)
# Leg routing (converge-all, binding F2):
#   w24. WRITER_READ_ONLY=1 (fork            -> exit 0, posts nothing, never
#        pull_request_review no-op)             consults the predicate (a
#                                               broken predicate proves it)
#   w25. merge_group leg                     -> unconditional success post,
#                                               predicate never consulted
#   w26. schedule pass, two open PRs         -> converges BOTH heads
#   w26b. schedule pass, approved heads      -> reruns + markers, never a
#                                               first success without proof
#   w27. one PR failing                      -> exit 1, other PR converged
#   w28. EVENT leg (workflow_run) with no    -> ALSO enumerates every open
#        identifiers                            PR — converge-all on every
#                                               leg, so evicted pending runs
#                                               strand nothing
#   w29. zero open PRs                       -> clean no-op pass
#   w26c. ghost-authored PR (user null)      -> converges with empty author
#   wp1-wp3. pagination merges               -> page-two PRs enumerate; a
#                                               page-two prior success
#                                               proves; a page-two guard
#                                               entry defers
# Template pins (tpl:*): grep-pins on review-gate-writer.yml for the
# workflow-level expressions offline runs cannot execute (F4's billing
# behavior is a Layer-2 sandbox observation: push/merge-group completions
# surface as SKIPPED writer runs).
# Settings:
#   w30. REVIEW_GATE_OVERRIDE_CONTEXT alias  -> exported to the predicate as
#                                               REVIEW_GATE_OUTAGE_CONTEXT;
#                                               absent key leaves the
#                                               predicate's own resolution
#                                               untouched
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
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        must not contain: %s\n' "$name" "$needle"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  fi
}

# Sandbox: the real writer + its real settings lib, next to a stubbed
# predicate.
mkdir -p "$TMP_ROOT/scripts/lib" "$TMP_ROOT/bin"
cp "$SKILL_ROOT/scripts/review-writer.sh" "$TMP_ROOT/scripts/"
cp "$SKILL_ROOT/scripts/lib/settings.sh" "$TMP_ROOT/scripts/lib/"
cat > "$TMP_ROOT/scripts/review-predicate.sh" <<'EOF'
#!/usr/bin/env bash
# Predicate stub: STUB_PREDICATE_RC != 0 simulates an evidence-read failure
# (no verdict); otherwise STUB_VERDICT_LINE is the authoritative verdict and
# STUB_EVIDENCE_AT (when set) is emitted as the additive evidence_at line.
# STUB_PREDICATE_FAIL_PR fails only that PR's evaluation (containment
# cases). STUB_PREDICATE_ENV_LOG records the outage-context env the writer
# hands down (the OVERRIDE_CONTEXT alias cases).
if [[ -n "${STUB_PREDICATE_ENV_LOG:-}" ]]; then
  printf 'OUTAGE=%s\n' "${REVIEW_GATE_OUTAGE_CONTEXT-<unset>}" >> "$STUB_PREDICATE_ENV_LOG"
fi
if [[ "${STUB_PREDICATE_RC:-0}" != "0" ]]; then
  echo "::error::stubbed predicate failure" >&2
  exit "${STUB_PREDICATE_RC}"
fi
if [[ -n "${STUB_PREDICATE_FAIL_PR:-}" && "${STUB_PREDICATE_FAIL_PR}" == "${PR_NUMBER:-}" ]]; then
  echo "::error::stubbed predicate failure for PR ${PR_NUMBER}" >&2
  exit 2
fi
printf '%s\n' "${STUB_VERDICT_LINE:?}"
if [[ -n "${STUB_EVIDENCE_AT:-}" ]]; then
  printf 'evidence_at=%s\n' "$STUB_EVIDENCE_AT"
fi
EOF
chmod +x "$TMP_ROOT/scripts/review-predicate.sh" "$TMP_ROOT/scripts/review-writer.sh"

# Parametrized `gh` stub:
#   STUB_GATE_HISTORY   JSON array (newest first) answered for the
#                       projection read commits/<sha>/statuses; "fail" fails
#                       the read
#   STUB_GUARD_HISTORY  answered for the guard's RE-read (the per_page=100
#                       URL); defaults to STUB_GATE_HISTORY; "fail" fails
#                       only the re-read
#   STUB_RUNS_MODE      completed|proof_completed|in_progress|empty|
#                       high_attempt — the actions/runs?head_sha= listing.
#                       Attempt-1 rows carry run_started_at=RUN_START
#                       (2020-06-01) so evidence_at anchors can order
#                       against them.
#   STUB_OPEN_PRS       JSON array answered for pulls?state=open
#   STUB_POST_LOG       file collecting every status POST's args
#   STUB_RERUN_LOG      file collecting every rerun POST's run id
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -u
[[ "${1:-}" == "api" ]] || { echo "unexpected gh command: $*" >&2; exit 1; }
shift
args="$*"
case "$args" in
  *"/rerun"*)
    id="$(sed -n 's|.*actions/runs/\([0-9]*\)/rerun.*|\1|p' <<<"$args")"
    # STUB_RERUN_MODE: ok (default) | refuse (unqualified 403) | throttle
    # (403 + retry-after/x-ratelimit-remaining:0) | throttle_then_ok |
    # auth_error (401) | server_error (502). Non-ok modes log each attempt
    # to STUB_RERUN_ATTEMPT_LOG so retry bounds are assertable.
    mode="${STUB_RERUN_MODE:-ok}"
    if [[ "$mode" == "throttle_then_ok" ]]; then
      if [[ -s "${STUB_RERUN_ATTEMPT_LOG:-/dev/null}" ]]; then mode=ok; else mode=throttle; fi
    fi
    case "$mode" in
      ok)
        echo "rerun:$id" >> "${STUB_RERUN_LOG:?}"
        ;;
      refuse)
        echo "attempt:$id" >> "${STUB_RERUN_ATTEMPT_LOG:?}"
        printf 'HTTP/2.0 403 Forbidden\r\ncontent-type: application/json\r\n\r\n{"message":"This workflow run cannot be re-run"}\n'
        echo "gh: This workflow run cannot be re-run (HTTP 403)" >&2
        exit 1
        ;;
      throttle)
        echo "attempt:$id" >> "${STUB_RERUN_ATTEMPT_LOG:?}"
        printf 'HTTP/2.0 403 Forbidden\r\nretry-after: 1\r\nx-ratelimit-remaining: 0\r\n\r\n{"message":"You have exceeded a secondary rate limit."}\n'
        echo "gh: You have exceeded a secondary rate limit. (HTTP 403)" >&2
        exit 1
        ;;
      auth_error)
        echo "attempt:$id" >> "${STUB_RERUN_ATTEMPT_LOG:?}"
        printf 'HTTP/2.0 401 Unauthorized\r\ncontent-type: application/json\r\n\r\n{"message":"Bad credentials"}\n'
        echo "gh: Bad credentials (HTTP 401)" >&2
        exit 1
        ;;
      server_error)
        echo "attempt:$id" >> "${STUB_RERUN_ATTEMPT_LOG:?}"
        printf 'HTTP/2.0 502 Bad Gateway\r\n\r\n'
        echo "gh: HTTP 502" >&2
        exit 1
        ;;
      *) echo "unknown STUB_RERUN_MODE" >&2; exit 1 ;;
    esac
    ;;
  "-X POST "*"/statuses/"*)
    echo "post:$args" >> "${STUB_POST_LOG:?}"
    ;;
  *"/commits/"*"/statuses?per_page=100"*)
    # The VST-65 guard's re-read — distinguishable from the projection read
    # by its explicit per_page, so the two can fail independently.
    # STUB_GUARD_HISTORY_PAGE2 emits a second page (gh --paginate emits one
    # array per page, concatenated) so first-page-only merges are catchable.
    guard="${STUB_GUARD_HISTORY:-${STUB_GATE_HISTORY:-[]}}"
    if [[ "$guard" == "fail" ]]; then
      echo "HTTP 500" >&2
      exit 1
    fi
    printf '%s\n' "$guard"
    if [[ -n "${STUB_GUARD_HISTORY_PAGE2:-}" ]]; then printf '%s\n' "$STUB_GUARD_HISTORY_PAGE2"; fi
    ;;
  *"/commits/"*"/statuses"*)
    if [[ "${STUB_GATE_HISTORY:-[]}" == "fail" ]]; then
      echo "HTTP 500" >&2
      exit 1
    fi
    printf '%s\n' "${STUB_GATE_HISTORY:-[]}"
    if [[ -n "${STUB_GATE_HISTORY_PAGE2:-}" ]]; then printf '%s\n' "$STUB_GATE_HISTORY_PAGE2"; fi
    ;;
  *"pulls?state=open"*)
    if [[ "${STUB_OPEN_PRS:-[]}" == "fail" ]]; then
      echo "HTTP 500" >&2
      exit 1
    fi
    printf '%s\n' "${STUB_OPEN_PRS:-[]}"
    if [[ -n "${STUB_OPEN_PRS_PAGE2:-}" ]]; then printf '%s\n' "$STUB_OPEN_PRS_PAGE2"; fi
    ;;
  *"/actions/runs?"*)
    case "${STUB_RUNS_MODE:-completed}" in
      completed)
        echo '{"workflow_runs":[{"id":111,"name":"ci","status":"completed","conclusion":"success","event":"pull_request","run_attempt":1,"run_started_at":"2020-06-01T00:00:00Z"},{"id":222,"name":"push run","status":"completed","conclusion":"success","event":"push","run_attempt":1,"run_started_at":"2020-06-01T00:00:00Z"}]}' ;;
      proof_completed)
        echo '{"workflow_runs":[{"id":111,"name":"ci","status":"completed","conclusion":"success","event":"pull_request","run_attempt":2,"run_started_at":"2020-06-02T00:00:00Z"}]}' ;;
      in_progress)
        echo '{"workflow_runs":[{"id":111,"name":"ci","status":"in_progress","conclusion":null,"event":"pull_request","run_attempt":1,"run_started_at":"2020-06-01T00:00:00Z"}]}' ;;
      empty)
        echo '{"workflow_runs":[]}' ;;
      high_attempt)
        echo '{"workflow_runs":[{"id":111,"name":"ci","status":"completed","conclusion":"success","event":"pull_request","run_attempt":5,"run_started_at":"2020-06-01T00:00:00Z"}]}' ;;
      *) echo "unknown STUB_RUNS_MODE" >&2; exit 1 ;;
    esac
    ;;
  *)
    echo "unexpected gh api call: $args" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$TMP_ROOT/bin/gh"

# `date` shim: STUB_DATE_FIXED pins the writer's evaluated_at stamp so
# equal-second cases against a status entry's created_at are constructible;
# unset, the real date answers.
cat > "$TMP_ROOT/bin/date" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${STUB_DATE_FIXED:-}" ]]; then
  printf '%s\n' "$STUB_DATE_FIXED"
else
  exec /bin/date "$@"
fi
EOF
chmod +x "$TMP_ROOT/bin/date"

# run_writer [ENV=val ...] — runs the writer under the stubs in the
# single-head recursive contract (PR_NUMBER + HEAD_SHA set) with fresh
# POST/rerun logs; prints stdout+stderr, returns its exit code. EVENT_NAME
# defaults to pull_request_target; only merge_group changes behavior.
# Settings resolve from /dev/null (built-in defaults) unless a case
# overrides REVIEW_GATE_SETTINGS_FILE.
POST_LOG="$TMP_ROOT/post.log"
RERUN_LOG="$TMP_ROOT/rerun.log"
ATTEMPT_LOG="$TMP_ROOT/rerun-attempts.log"
run_writer() {
  : > "$POST_LOG"
  : > "$RERUN_LOG"
  : > "$ATTEMPT_LOG"
  env PATH="$TMP_ROOT/bin:$PATH" \
    GH_REPO=acme/widgets PR_NUMBER=7 HEAD_SHA=headsha PR_AUTHOR=pr-author \
    EVENT_NAME=pull_request_target \
    REVIEW_GATE_SETTINGS_FILE=/dev/null \
    STUB_POST_LOG="$POST_LOG" STUB_RERUN_LOG="$RERUN_LOG" \
    STUB_RERUN_ATTEMPT_LOG="$ATTEMPT_LOG" \
    "$@" bash "$TMP_ROOT/scripts/review-writer.sh" 2>&1
}

AWAITING="verdict=awaiting detail=awaiting a non-author review for headsha"
APPROVED="verdict=approved detail=reviewed at head with no unresolved threads"
CR="verdict=changes-requested detail=standing review changes requested (persists across pushes until re-approval or dismissal)"
THREADS="verdict=threads-open detail=2 unresolved review thread(s)"

# created_at anchors: OLD predates every stub run's start (RUN_START =
# 2020-06-01) and every evaluation instant; LATE lands after RUN_START but
# before now; FUTURE postdates every evaluation instant.
OLD="2020-01-01T00:00:00Z"
LATE="2020-12-31T00:00:00Z"
FUTURE="2999-01-01T00:00:00Z"

echo "=== downward transitions are direct posts, idempotent, never deferred ==="

rc=0; out=$(run_writer STUB_VERDICT_LINE="$AWAITING" STUB_GATE_HISTORY='[]') || rc=$?
assert_eq "$rc" "0" "w1: awaiting exits 0"
assert_contains "$(cat "$POST_LOG")" "state=pending" "w1: awaiting posts pending"
assert_contains "$(cat "$POST_LOG")" "context=Review gate" "w1: post carries the default gate context"
assert_eq "$(( $(wc -l < "$RERUN_LOG") ))" "0" "w1: no rerun on a downward transition"

out=$(run_writer STUB_VERDICT_LINE="$AWAITING" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"pending","description":"awaiting a non-author review for headsha","created_at":"'"$OLD"'"}]')
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w2: second evaluation of an unchanged state posts nothing (one entry total)"
assert_contains "$out" "nothing to do" "w2: reports the no-op"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$CR" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"success","description":"ok","created_at":"'"$FUTURE"'"}]') || rc=$?
assert_eq "$rc" "0" "w3: changes-requested exits 0"
assert_contains "$(cat "$POST_LOG")" "state=failure" "w3: posts failure over a newer success — downward posts never defer"
assert_not_contains "$out" "deferring" "w3: no deferral on the downward path"
assert_eq "$(( $(wc -l < "$RERUN_LOG") ))" "0" "w3: no rerun on changes-requested"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$THREADS" STUB_GATE_HISTORY='[]') || rc=$?
assert_eq "$rc" "0" "w4: threads-open exits 0"
assert_contains "$(cat "$POST_LOG")" "state=pending" "w4: threads-open posts pending"

echo "=== upward flip: success needs proof ==="

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"success","description":"ok","created_at":"'"$OLD"'"}]') || rc=$?
assert_eq "$rc" "0" "w5: approved with current success exits 0"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w5: current success posts nothing"
assert_eq "$(( $(wc -l < "$RERUN_LOG") ))" "0" "w5: current success reruns nothing"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"pending","description":"x","created_at":"'"$OLD"'"},{"context":"Review gate","state":"success","description":"ok","created_at":"'"$OLD"'"}]') || rc=$?
assert_eq "$rc" "0" "w6: prior-success fast path exits 0"
assert_contains "$(cat "$POST_LOG")" "state=success" "w6: prior success on the sha allows a direct success post"
assert_eq "$(( $(wc -l < "$RERUN_LOG") ))" "0" "w6: proof fast path never reruns"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY='[]' \
  EVENT_NAME=pull_request_review STUB_RUNS_MODE=completed) || rc=$?
assert_eq "$rc" "0" "w7: first approved flip exits 0"
assert_eq "$(cat "$RERUN_LOG")" "rerun:111" "w7: reruns the completed pull_request run only (never the push run)"
assert_not_contains "$(cat "$POST_LOG")" "state=success" "w7: no direct success without proof"
assert_contains "$(cat "$POST_LOG")" "proof CI attempt re-running" "w7: posts the provenance marker after issuing the rerun"

# 10a pin: a completion with NO provenance marker is the PRE-approval
# attempt finishing after approval landed mid-flight — its heavy jobs ran
# gate-closed, so the writer must issue the proof rerun, never success.
rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY='[]' \
  EVENT_NAME=workflow_run STUB_RUNS_MODE=completed) || rc=$?
assert_eq "$rc" "0" "w8/10a: marker-less completion exits 0"
assert_not_contains "$(cat "$POST_LOG")" "state=success" "w8/10a: marker-less completion NEVER posts success (heavy jobs ran gate-closed)"
assert_eq "$(cat "$RERUN_LOG")" "rerun:111" "w8/10a: marker-less completion issues the proof rerun instead"
assert_contains "$(cat "$POST_LOG")" "proof CI attempt re-running" "w8/10a: and records the marker"

MARKER_ENTRY='{"context":"Review gate","state":"pending","description":"approved: proof CI attempt re-running; success posts on its completion","created_at":"'"$OLD"'"}'
rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY="[$MARKER_ENTRY]" \
  EVENT_NAME=workflow_run STUB_RUNS_MODE=proof_completed) || rc=$?
assert_eq "$rc" "0" "w8b: marker + completed proof attempt exits 0"
assert_contains "$(cat "$POST_LOG")" "state=success" "w8b: first success posts on the marked completion"
assert_eq "$(( $(wc -l < "$RERUN_LOG") ))" "0" "w8b: no second rerun on the marked completion"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY="[$MARKER_ENTRY]" \
  EVENT_NAME=schedule STUB_RUNS_MODE=proof_completed) || rc=$?
assert_contains "$(cat "$POST_LOG")" "state=success" "w8c: the cron floor also posts the marked success (missed events converge)"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY="[$MARKER_ENTRY]" \
  EVENT_NAME=workflow_run STUB_RUNS_MODE=in_progress) || rc=$?
assert_eq "$rc" "0" "w8d: marker with the proof attempt still in flight exits 0"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w8d: nothing posts while the proof attempt runs"

# Binding finding F3: between the rerun POST being accepted and the runs API
# listing the new attempt, a concurrent pass can see marker + only the
# completed gate-closed attempt 1. Certifying it would green the gate over
# skipped heavy jobs — the proof completion always has run_attempt >= 2.
rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY="[$MARKER_ENTRY]" \
  EVENT_NAME=workflow_run STUB_RUNS_MODE=completed) || rc=$?
assert_eq "$rc" "0" "w8e: marker + attempt-1-only snapshot exits 0"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w8e: attempt-1-only snapshot never posts success (stale runs read)"
assert_eq "$(( $(wc -l < "$RERUN_LOG") ))" "0" "w8e: and never re-issues the rerun (the marker says one is underway)"
assert_contains "$out" "only attempt-1 completions" "w8e: says why it waits"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$AWAITING" STUB_GATE_HISTORY='[]' \
  EVENT_NAME=workflow_run) || rc=$?
assert_eq "$rc" "0" "w9: completion pass with an unapproved head exits 0"
assert_contains "$(cat "$POST_LOG")" "state=pending" "w9: unapproved completion posts pending"
assert_not_contains "$(cat "$POST_LOG")" "state=success" "w9: success only when the predicate approves at head"

echo "=== ordering fast path (binding F1: evidence_at) ==="

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_EVIDENCE_AT="$OLD" \
  STUB_GATE_HISTORY='[]' STUB_RUNS_MODE=completed) || rc=$?
assert_eq "$rc" "0" "f1a: ordered evidence exits 0"
assert_contains "$(cat "$POST_LOG")" "state=success" "f1a: attempt started after the evidence -> direct success"
assert_eq "$(( $(wc -l < "$RERUN_LOG") ))" "0" "f1a: ZERO reruns (the carry-forward push burns heavy CI once)"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_EVIDENCE_AT="$LATE" \
  STUB_GATE_HISTORY='[]' STUB_RUNS_MODE=completed) || rc=$?
assert_eq "$rc" "0" "f1b: late-landing evidence exits 0"
assert_not_contains "$(cat "$POST_LOG")" "state=success" "f1b: evidence created after the attempt started never certifies it (the F1 unsafe-shortcut case)"
assert_eq "$(cat "$RERUN_LOG")" "rerun:111" "f1b: the proof rerun runs instead"
assert_contains "$(cat "$POST_LOG")" "proof CI attempt re-running" "f1b: with its marker"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" \
  STUB_GATE_HISTORY='[]' STUB_RUNS_MODE=completed) || rc=$?
assert_not_contains "$(cat "$POST_LOG")" "state=success" "f1c: no evidence_at line -> never the fast path"
assert_eq "$(cat "$RERUN_LOG")" "rerun:111" "f1c: rerun path instead"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_EVIDENCE_AT="$OLD" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"pending","description":"2 unresolved review thread(s)","created_at":"2020-03-01T00:00:00Z"}]' \
  STUB_RUNS_MODE=completed) || rc=$?
assert_eq "$rc" "0" "f1d: post-evidence closed verdict exits 0"
assert_not_contains "$(cat "$POST_LOG")" "state=success" "f1d: a non-success gate entry after evidence_at blocks the fast path (a post-evidence live read still refused)"
assert_eq "$(cat "$RERUN_LOG")" "rerun:111" "f1d: rerun path instead"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_EVIDENCE_AT="$OLD" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"pending","description":"unknown age"}]' \
  STUB_RUNS_MODE=completed) || rc=$?
assert_not_contains "$(cat "$POST_LOG")" "state=success" "f1e: an entry with no created_at cannot be ordered and blocks the fast path"
assert_eq "$(cat "$RERUN_LOG")" "rerun:111" "f1e: rerun path instead"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_EVIDENCE_AT="$OLD" \
  STUB_GATE_HISTORY='[]' STUB_RUNS_MODE=completed \
  STUB_GUARD_HISTORY='[{"context":"Review gate","state":"pending","description":"newer writer run","created_at":"'"$FUTURE"'"}]') || rc=$?
assert_eq "$rc" "0" "f1f: guarded fast path exits 0"
assert_contains "$out" "deferring the success post" "f1f: the VST-65 guard protects the ordering fast path too"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "f1f: deferred fast path posts nothing"

# Equal-second boundary: one-second timestamp resolution cannot order an
# attempt whose run_started_at EQUALS evidence_at, so it must never be
# certified (strict >; falling to the rerun path is the fail-safe side).
rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_EVIDENCE_AT="2020-06-01T00:00:00Z" \
  STUB_GATE_HISTORY='[]' STUB_RUNS_MODE=completed) || rc=$?
assert_eq "$rc" "0" "f1g: equal-second evidence exits 0"
assert_not_contains "$(cat "$POST_LOG")" "state=success" "f1g: run_started_at == evidence_at cannot be ordered -> never certified"
assert_eq "$(cat "$RERUN_LOG")" "rerun:111" "f1g: proof rerun instead"

echo "=== VST-65 ordering guard on every success post ==="

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY="[$MARKER_ENTRY]" \
  EVENT_NAME=workflow_run STUB_RUNS_MODE=proof_completed \
  STUB_GUARD_HISTORY='[{"context":"Review gate","state":"pending","description":"newer writer run","created_at":"'"$FUTURE"'"}]') || rc=$?
assert_eq "$rc" "0" "w10: stale success defers with exit 0"
assert_contains "$out" "deferring the success post" "w10: names the deferral"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w10: deferred success posts nothing"

# Equality deferral: created_at and evaluated_at have one-second resolution,
# so a non-success write within the evaluation second compares EQUAL and
# must still defer (`>=`, not `>`). STUB_DATE_FIXED pins evaluated_at.
rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY="[$MARKER_ENTRY]" \
  EVENT_NAME=workflow_run STUB_RUNS_MODE=proof_completed \
  STUB_DATE_FIXED="2026-06-15T12:00:00Z" \
  STUB_GUARD_HISTORY='[{"context":"Review gate","state":"pending","description":"same-second write","created_at":"2026-06-15T12:00:00Z"}]') || rc=$?
assert_eq "$rc" "0" "w10b: same-second non-success write exits 0"
assert_contains "$out" "deferring the success post" "w10b: equality defers (one-second resolution)"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w10b: no post on the equal-second boundary"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY="[$MARKER_ENTRY]" \
  EVENT_NAME=workflow_run STUB_RUNS_MODE=proof_completed STUB_GUARD_HISTORY=fail) || rc=$?
assert_eq "$rc" "0" "w11: failed guard re-read defers with exit 0 (fail-safe side)"
assert_contains "$out" "deferring the success post" "w11: names the deferral"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w11: no post on an unreadable re-read"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"pending","description":"x","created_at":"'"$OLD"'"},{"context":"Review gate","state":"success","description":"ok","created_at":"'"$OLD"'"}]' \
  STUB_GUARD_HISTORY='[{"context":"Review gate","state":"failure","description":"newer","created_at":"'"$FUTURE"'"}]') || rc=$?
assert_eq "$rc" "0" "w12: guarded fast path exits 0"
assert_contains "$out" "deferring the success post" "w12: the prior-success fast path defers to a newer non-success write"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w12: deferred fast path posts nothing"

echo "=== rerun POST: stuck vs malfunction, throttle vs refusal (VST-36) ==="

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY='[]' \
  STUB_RERUN_MODE=refuse) || rc=$?
assert_eq "$rc" "0" "w13: rerun refusal (unqualified 4xx) exits 0 — stuck, not malfunction"
assert_contains "$out" "cannot be advanced by the writer" "w13: names the stuck outcome"
assert_eq "$(grep -c 'attempt:111' "$ATTEMPT_LOG")" "1" "w13: a refusal is never retried (each retry feeds the same limit)"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w13: gate left as found (pending)"

set +e
out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY='[]' \
  STUB_RERUN_MODE=throttle)
rc=$?
set -e
assert_eq "$rc" "1" "w14: throttled through the default single-attempt budget exits 1"
assert_contains "$out" "throttled" "w14: a throttled 403 is named throttle, never stuck"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w14: cap exhaustion leaves the gate pending (no post)"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY='[]' \
  STUB_RERUN_MODE=throttle_then_ok REVIEW_GATE_API_ATTEMPTS=2 REVIEW_GATE_API_RETRY_DELAY_SECONDS=0) || rc=$?
assert_eq "$rc" "0" "w15: a throttle clearing within the budget exits 0"
assert_eq "$(cat "$RERUN_LOG")" "rerun:111" "w15: the rerun eventually lands"

set +e
out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY='[]' \
  STUB_RERUN_MODE=auth_error)
rc=$?
set -e
assert_eq "$rc" "1" "w16: a rerun 401 exits 1 (malfunction — bad credentials stop every head)"
assert_contains "$out" "malfunction" "w16: a 401 is named malfunction, not a per-run refusal"

set +e
out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY='[]' \
  STUB_RERUN_MODE=server_error)
rc=$?
set -e
assert_eq "$rc" "1" "w17: a rerun 5xx exits 1 (malfunction)"
assert_contains "$out" "malfunction" "w17: names the malfunction"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w17: never a status write on the failure path"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY='[]' \
  STUB_RUNS_MODE=high_attempt) || rc=$?
assert_eq "$rc" "0" "w18: attempt cap exits 0"
assert_eq "$(( $(wc -l < "$RERUN_LOG") ))" "0" "w18: run at MAX_ATTEMPTS is left alone"
assert_contains "$out" "cap 5" "w18: warns about the cap"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w18: gate stays pending at the cap"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY='[]' \
  STUB_RUNS_MODE=in_progress) || rc=$?
assert_eq "$rc" "0" "w19: in-progress head exits 0"
assert_eq "$(( $(wc -l < "$RERUN_LOG") ))" "0" "w19: in-progress run is left to finish"
assert_contains "$out" "still in progress" "w19: says why"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY='[]' \
  STUB_RUNS_MODE=empty) || rc=$?
assert_eq "$rc" "0" "w20: a head with no completed pull_request runs exits 0 (waits, not stuck)"
assert_contains "$out" "no completed pull_request runs" "w20: says why"
assert_contains "$out" "workflow_run completion leg" "w20: names the leg that will converge it"

echo "=== fail loud, act never ==="

set +e
out=$(run_writer STUB_PREDICATE_RC=2 STUB_GATE_HISTORY='[]')
rc=$?
set -e
assert_eq "$rc" "1" "w21: predicate failure exits 1"
assert_eq "$(( $(wc -l < "$POST_LOG") ))$(( $(wc -l < "$RERUN_LOG") ))" "00" "w21: no POST and no rerun on predicate failure"

set +e
out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY=fail)
rc=$?
set -e
assert_eq "$rc" "1" "w22: status-history read failure exits 1"
assert_eq "$(( $(wc -l < "$POST_LOG") ))$(( $(wc -l < "$RERUN_LOG") ))" "00" "w22: no action on history read failure"

set +e
out=$(env -u HEAD_SHA PATH="$TMP_ROOT/bin:$PATH" \
  GH_REPO=acme/widgets PR_NUMBER=7 EVENT_NAME=pull_request_target \
  REVIEW_GATE_SETTINGS_FILE=/dev/null \
  STUB_POST_LOG="$POST_LOG" STUB_RERUN_LOG="$RERUN_LOG" \
  STUB_VERDICT_LINE="$AWAITING" bash "$TMP_ROOT/scripts/review-writer.sh" 2>&1)
rc=$?
set -e
assert_eq "$rc" "1" "w23: PR_NUMBER without HEAD_SHA exits 1 (recursive contract)"

echo "=== leg routing: converge-all on every leg ==="

# A broken predicate (RC=2) proves these legs never consult it: if the
# guard regressed and the predicate ran, the exit code would flip to 1.
rc=0; out=$(run_writer STUB_PREDICATE_RC=2 WRITER_READ_ONLY=1) || rc=$?
assert_eq "$rc" "0" "w24: fork pull_request_review (read-only token) exits 0"
assert_contains "$out" "no-op" "w24: names the no-op"
assert_eq "$(( $(wc -l < "$POST_LOG") ))$(( $(wc -l < "$RERUN_LOG") ))" "00" "w24: read-only run posts and reruns nothing"

rc=0; out=$(run_writer STUB_PREDICATE_RC=2 EVENT_NAME=merge_group) || rc=$?
assert_eq "$rc" "0" "w25: merge_group leg exits 0"
assert_contains "$(cat "$POST_LOG")" "state=success" "w25: merge-group sha gets the unconditional success"
assert_contains "$(cat "$POST_LOG")" "merge-queue entry" "w25: post says why"
assert_eq "$(( $(wc -l < "$RERUN_LOG") ))" "0" "w25: queue leg never reruns"

# Converge-all enumeration (binding F2: EVERY leg, not just
# schedule/dispatch). `env -u` scrubs the single-PR identifiers so the
# top-level invocation enumerates.
run_writer_all() {
  : > "$POST_LOG"
  : > "$RERUN_LOG"
  : > "$ATTEMPT_LOG"
  local event="$1"; shift
  local -a runner=()
  command -v timeout >/dev/null 2>&1 && runner=(timeout 90)
  env -u PR_NUMBER -u HEAD_SHA -u PR_AUTHOR \
    PATH="$TMP_ROOT/bin:$PATH" \
    GH_REPO=acme/widgets EVENT_NAME="$event" \
    REVIEW_GATE_SETTINGS_FILE=/dev/null \
    STUB_POST_LOG="$POST_LOG" STUB_RERUN_LOG="$RERUN_LOG" \
    STUB_RERUN_ATTEMPT_LOG="$ATTEMPT_LOG" \
    "$@" "${runner[@]+"${runner[@]}"}" bash "$TMP_ROOT/scripts/review-writer.sh" 2>&1
}

OPEN2='[{"number":7,"head":{"sha":"sha7"},"user":{"login":"alice"}},{"number":8,"head":{"sha":"sha8"},"user":{"login":"bob"}}]'

rc=0; out=$(run_writer_all schedule STUB_VERDICT_LINE="$AWAITING" STUB_OPEN_PRS="$OPEN2" \
  STUB_GATE_HISTORY='[]') || rc=$?
assert_eq "$rc" "0" "w26: all-PRs pass over two PRs exits 0"
assert_contains "$out" "converging 2 open PR(s)" "w26: reports the enumeration"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "2" "w26: one post per open PR"
assert_contains "$(cat "$POST_LOG")" "statuses/sha7" "w26: converged PR #7's head"
assert_contains "$(cat "$POST_LOG")" "statuses/sha8" "w26: converged PR #8's head"

rc=0; out=$(run_writer_all schedule STUB_VERDICT_LINE="$APPROVED" STUB_OPEN_PRS="$OPEN2" \
  STUB_GATE_HISTORY='[]' STUB_RUNS_MODE=completed) || rc=$?
assert_eq "$rc" "0" "w26b: all-PRs approved pass exits 0"
assert_eq "$(grep -c 'rerun:111' "$RERUN_LOG")" "2" "w26b: the pass reruns approved heads"
assert_not_contains "$(cat "$POST_LOG")" "state=success" "w26b: never a first success without the marker"
assert_eq "$(grep -c 'proof CI attempt re-running' "$POST_LOG")" "2" "w26b: each rerun head gets its provenance marker"

set +e
out=$(run_writer_all schedule STUB_VERDICT_LINE="$AWAITING" STUB_OPEN_PRS="$OPEN2" \
  STUB_GATE_HISTORY='[]' STUB_PREDICATE_FAIL_PR=7)
rc=$?
set -e
assert_eq "$rc" "1" "w27: one failing PR fails the pass"
assert_contains "$out" "convergence failed for PR #7" "w27: names the failing PR"
assert_contains "$(cat "$POST_LOG")" "statuses/sha8" "w27: the other PR is still converged"

# Binding F2's teeth: an EVENT leg (here workflow_run) also enumerates every
# open PR — the payload sha is deliberately unused, so a pending run evicted
# by a burst strands nothing (whichever run survives converges everyone).
rc=0; out=$(run_writer_all workflow_run STUB_VERDICT_LINE="$AWAITING" STUB_OPEN_PRS="$OPEN2" \
  STUB_GATE_HISTORY='[]') || rc=$?
assert_eq "$rc" "0" "w28: event leg exits 0"
assert_contains "$out" "converging 2 open PR(s)" "w28: event legs converge ALL open PRs, not the payload head"
assert_contains "$(cat "$POST_LOG")" "statuses/sha7" "w28: converged PR #7"
assert_contains "$(cat "$POST_LOG")" "statuses/sha8" "w28: converged PR #8"

rc=0; out=$(run_writer_all workflow_run STUB_VERDICT_LINE="$APPROVED" STUB_OPEN_PRS='[]') || rc=$?
assert_eq "$rc" "0" "w29: zero open PRs exits 0"
assert_contains "$out" "converging 0 open PR(s)" "w29: names the empty pass"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w29: posts nothing (a superseded sha's completion converges nothing, naturally)"

# A ghost-authored PR (user serialized null) enumerates with an empty
# author; the predicate resolves the real author itself downstream.
rc=0; out=$(run_writer_all schedule STUB_VERDICT_LINE="$AWAITING" \
  STUB_OPEN_PRS='[{"number":9,"head":{"sha":"sha9"},"user":null}]' \
  STUB_GATE_HISTORY='[]') || rc=$?
assert_eq "$rc" "0" "w26c: ghost-authored PR exits 0"
assert_contains "$(cat "$POST_LOG")" "statuses/sha9" "w26c: ghost-authored PR still converges (empty PR_AUTHOR handed down)"

echo "=== pagination merges (one array per page; page limits strand state) ==="

rc=0; out=$(run_writer_all schedule STUB_VERDICT_LINE="$AWAITING" \
  STUB_OPEN_PRS='[{"number":7,"head":{"sha":"sha7"},"user":{"login":"alice"}}]' \
  STUB_OPEN_PRS_PAGE2='[{"number":8,"head":{"sha":"sha8"},"user":{"login":"bob"}}]' \
  STUB_GATE_HISTORY='[]') || rc=$?
assert_eq "$rc" "0" "wp1: paginated enumeration exits 0"
assert_contains "$out" "converging 2 open PR(s)" "wp1: PRs beyond page one are enumerated (never stranded)"
assert_contains "$(cat "$POST_LOG")" "statuses/sha8" "wp1: the page-two PR is converged"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"pending","description":"x","created_at":"'"$OLD"'"}]' \
  STUB_GATE_HISTORY_PAGE2='[{"context":"Review gate","state":"success","description":"ok","created_at":"'"$OLD"'"}]') || rc=$?
assert_eq "$rc" "0" "wp2: paginated projection exits 0"
assert_contains "$(cat "$POST_LOG")" "state=success" "wp2: a prior success on page two still proves the approved attempt"
assert_eq "$(( $(wc -l < "$RERUN_LOG") ))" "0" "wp2: and spares the rerun"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY="[$MARKER_ENTRY]" \
  EVENT_NAME=workflow_run STUB_RUNS_MODE=proof_completed \
  STUB_GUARD_HISTORY='[]' \
  STUB_GUARD_HISTORY_PAGE2='[{"context":"Review gate","state":"failure","description":"newer","created_at":"'"$FUTURE"'"}]') || rc=$?
assert_eq "$rc" "0" "wp3: paginated guard re-read exits 0"
assert_contains "$out" "deferring the success post" "wp3: a newer non-success entry on page two still defers (no first-page-only fail-open)"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "wp3: no post past the paginated guard"

echo "=== settings: the OVERRIDE_CONTEXT alias (Change 2) ==="

ENV_LOG="$TMP_ROOT/predicate-env.log"
cat > "$TMP_ROOT/override-settings.toml" <<'EOF'
REVIEW_GATE_OVERRIDE_CONTEXT = "ops-override"
EOF
: > "$ENV_LOG"
rc=0; out=$(run_writer STUB_VERDICT_LINE="$AWAITING" STUB_GATE_HISTORY='[]' \
  REVIEW_GATE_SETTINGS_FILE="$TMP_ROOT/override-settings.toml" \
  STUB_PREDICATE_ENV_LOG="$ENV_LOG") || rc=$?
assert_eq "$rc" "0" "w30: override-context settings file exits 0"
assert_contains "$(cat "$ENV_LOG")" "OUTAGE=ops-override" "w30: OVERRIDE_CONTEXT is exported to the predicate as REVIEW_GATE_OUTAGE_CONTEXT"

: > "$ENV_LOG"
rc=0; out=$(run_writer STUB_VERDICT_LINE="$AWAITING" STUB_GATE_HISTORY='[]' \
  STUB_PREDICATE_ENV_LOG="$ENV_LOG") || rc=$?
assert_eq "$rc" "0" "w30b: absent override key exits 0"
assert_contains "$(cat "$ENV_LOG")" "OUTAGE=<unset>" "w30b: absent key leaves the predicate's own outage resolution untouched"

echo "=== workflow template pins (review-gate-writer.yml) ==="

# Grep-pins on the shipped template (precedent: workflow-eviction-routing
# pins approval-rerun.yml). Runtime behavior of workflow-level expressions
# is offline-untestable — the job-level if: evaluates on GitHub — so F4's
# billing behavior is asserted in Layer 2 (the sandbox observes push/
# merge-group completions as SKIPPED writer runs); these pins keep the
# expressions from being silently dropped or reworded.
TEMPLATE="$SKILL_ROOT/templates/review-gate-writer.yml"
pin() { # needle, name
  if grep -qF -- "$1" "$TEMPLATE"; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$2"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        missing from template: %s\n' "$2" "$1"
  fi
}
pin "github.event.workflow_run.event == 'pull_request'" "tpl: F4 workflow_run pull_request-only job filter"
pin "github.event.state == 'success'" "tpl: status events act on success state only"
pin "github.event_name != 'merge_group'" "tpl: the write job excludes the merge_group event"
pin "cancel-in-progress: false" "tpl: pending writer runs are never cancelled mid-write"
pin "group: review-gate-writer" "tpl: single writer concurrency group"
pin "github.event.pull_request.head.repo.full_name != github.repository" "tpl: fork pull_request_review read-only flag"
pin "if: failure() || cancelled()" "tpl: VST-36 escalation covers timeout-cancelled jobs"
pin "persist-credentials: false" "tpl: checkouts drop credentials"
pin 'ref: ${{ github.event.repository.default_branch }}' "tpl: engine runs from the default branch"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
