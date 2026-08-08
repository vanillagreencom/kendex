#!/usr/bin/env bash
# Behavioral tests for the SHIPPED skills/review-gate/scripts/review-writer.sh
# — the single writer, whose entire job is to converge the gate commit
# status to the predicate's verdict. Stubbed GitHub API, every leg driven
# offline.
#
# The writer no longer polices CI (that is branch protection's job — see the
# script header's adoption precondition), so there is no proof chain here to
# test: no rerun, no provenance marker, no attempt floor, no evidence
# ordering, no stall recovery. What remains is the decision table, the write
# discipline, and leg routing.
#
# Verdict -> status:
#   w1.  awaiting, no gate status            -> posts pending
#   w2.  awaiting, already pending w/ same   -> no-op: two evaluations leave
#        description                            ONE entry (idempotence)
#   w3.  changes-requested over a NEWER      -> posts failure directly —
#        success entry                          downward posts never defer
#   w4.  threads-open                        -> posts pending
#   w5.  approved, already success           -> no-op
#   w6.  approved, currently pending         -> posts success
#   w7.  approved, currently failure         -> posts success (a dismissed
#                                               objection reopens the gate)
# Write discipline (VST-65 ordering guard, success posts only):
#   w10. guard re-read shows a non-success   -> defers (exit 0, no POST)
#        entry at/after evaluated_at
#   w10b. same-second non-success write      -> still defers (>=, not >)
#   w10c. newer SUCCESS entry                -> ALSO defers: the description
#                                               carries the audit detail
#                                               (override reason), so a stale
#                                               run must not overwrite it
#   w11. guard re-read FAILS                 -> defers (fail-safe side)
#   w12. downward posts never consult it     -> failure posts over a newer
#                                               entry without deferring
# Fail loud, act never:
#   w21. predicate read failure              -> exit 1, NO POST
#   w22. status-history read failure         -> exit 1, NO POST
#   w23. PR_NUMBER without HEAD_SHA          -> exit 1 (recursive contract)
#   w24. unknown verdict                     -> exit 1, NO POST
# Leg routing (converge-all):
#   w25. WRITER_READ_ONLY=1 (fork            -> exit 0, posts nothing, never
#        pull_request_review no-op)             consults the predicate (a
#                                               broken predicate proves it)
#   w26. merge_group leg                     -> unconditional success post,
#                                               predicate never consulted
#   w27. schedule pass, two open PRs         -> converges BOTH heads
#   w28. one PR failing                      -> exit 1, other PR converged
#   w29. EVENT leg with no identifiers       -> ALSO enumerates every open
#                                               PR, so an evicted pending
#                                               run strands nothing
#   w30. zero open PRs / ghost author        -> clean pass
#   wp1-wp3. pagination merges               -> page-two PRs enumerate; a
#                                               page-two guard entry defers
# Template pins (tpl:*): grep-pins on review-gate-writer.yml for the
# workflow-level expressions offline runs cannot execute.
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
# STUB_EVIDENCE_AT is written to the REVIEW_GATE_EVIDENCE_AT_FILE seam.
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
if [[ -n "${REVIEW_GATE_EVIDENCE_AT_FILE:-}" ]]; then
  printf '%s\n' "${STUB_EVIDENCE_AT:-}" > "$REVIEW_GATE_EVIDENCE_AT_FILE"
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
#   STUB_OPEN_PRS       JSON array answered for pulls?state=open
#   STUB_POST_LOG       file collecting every status POST's args
#   (No runs/jobs/rerun stubs: the writer never touches those APIs.)
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -u
[[ "${1:-}" == "api" ]] || { echo "unexpected gh command: $*" >&2; exit 1; }
shift
args="$*"
case "$args" in
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
    # "emptybytes": a SUCCESSFUL call producing zero bytes — the broken-read
    # shape the writer must fail loud on, distinct from the empty page `[]`.
    if [[ "${STUB_GATE_HISTORY:-[]}" == "emptybytes" ]]; then exit 0; fi
    if [[ "${STUB_GATE_HISTORY:-[]}" == "whitespace" ]]; then printf '   \n'; exit 0; fi
    printf '%s\n' "${STUB_GATE_HISTORY:-[]}"
    if [[ -n "${STUB_GATE_HISTORY_PAGE2:-}" ]]; then printf '%s\n' "$STUB_GATE_HISTORY_PAGE2"; fi
    ;;
  *"pulls?state=open"*)
    if [[ "${STUB_OPEN_PRS:-[]}" == "fail" ]]; then
      echo "HTTP 500" >&2
      exit 1
    fi
    if [[ "${STUB_OPEN_PRS:-[]}" == "emptybytes" ]]; then exit 0; fi
    if [[ "${STUB_OPEN_PRS:-[]}" == "whitespace" ]]; then printf '   \n'; exit 0; fi
    printf '%s\n' "${STUB_OPEN_PRS:-[]}"
    if [[ -n "${STUB_OPEN_PRS_PAGE2:-}" ]]; then printf '%s\n' "$STUB_OPEN_PRS_PAGE2"; fi
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
# RECENT is five minutes ago: inside the stall bound (so markers dated with
# it exercise the WAITING path) but strictly BEFORE this run's evaluation
# instant, so it does not also trip the VST-65 ordering guard. Markers dated
# OLD are past the bound and exercise the self-heal path.
RECENT="$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -v-5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
LATE="2020-12-31T00:00:00Z"
FUTURE="2999-01-01T00:00:00Z"

echo "=== downward transitions are direct posts, idempotent, never deferred ==="

rc=0; out=$(run_writer STUB_VERDICT_LINE="$AWAITING" STUB_GATE_HISTORY='[]') || rc=$?
assert_eq "$rc" "0" "w1: awaiting exits 0"
assert_contains "$(cat "$POST_LOG")" "state=pending" "w1: awaiting posts pending"
assert_contains "$(cat "$POST_LOG")" "context=Review gate" "w1: post carries the default gate context"
assert_eq "$(( $(wc -l < "$RERUN_LOG") ))" "0" "w1: no rerun on a downward transition"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$AWAITING" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"pending","description":"awaiting a non-author review for headsha","created_at":"'"$OLD"'"}]') || rc=$?
assert_eq "$rc" "0" "w2: the idempotent no-op exits 0"
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

echo "=== approved converges to success ==="

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"success","description":"reviewed at head with no unresolved threads","created_at":"'"$OLD"'"}]') || rc=$?
assert_eq "$rc" "0" "w5: approved with the same success entry exits 0"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w5: unchanged success posts nothing (idempotent)"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"pending","description":"awaiting a non-author review for headsha","created_at":"'"$OLD"'"}]') || rc=$?
assert_eq "$rc" "0" "w6: approved over pending exits 0"
assert_contains "$(cat "$POST_LOG")" "state=success" "w6: a reviewed head opens the gate"
assert_eq "$(( $(wc -l < "$RERUN_LOG") ))" "0" "w6: the writer never re-runs CI (branch protection owns that)"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"failure","description":"standing review changes requested","created_at":"'"$OLD"'"}]') || rc=$?
assert_contains "$(cat "$POST_LOG")" "state=success" "w7: a dismissed objection reopens the gate"

echo "=== VST-65 ordering guard (success posts only) ==="

PENDING_OLD='[{"context":"Review gate","state":"pending","description":"awaiting a non-author review for headsha","created_at":"'"$OLD"'"}]'

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY="$PENDING_OLD" \
  STUB_GUARD_HISTORY='[{"context":"Review gate","state":"pending","description":"newer writer run","created_at":"'"$FUTURE"'"}]') || rc=$?
assert_eq "$rc" "0" "w10: stale success defers with exit 0"
assert_contains "$out" "deferring the success post" "w10: names the deferral"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w10: deferred success posts nothing"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY="$PENDING_OLD" \
  STUB_DATE_FIXED="2026-06-15T12:00:00Z" \
  STUB_GUARD_HISTORY='[{"context":"Review gate","state":"pending","description":"same-second write","created_at":"2026-06-15T12:00:00Z"}]') || rc=$?
assert_eq "$rc" "0" "w10b: same-second non-success write exits 0"
assert_contains "$out" "deferring the success post" "w10b: equality defers (one-second resolution)"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w10b: no post on the equal-second boundary"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY="$PENDING_OLD" \
  STUB_GUARD_HISTORY='[{"context":"Review gate","state":"success","description":"operator override (ctx) : real reason","created_at":"'"$FUTURE"'"}]') || rc=$?
assert_eq "$rc" "0" "w10c: a newer SUCCESS entry also defers (exit 0)"
assert_contains "$out" "deferring the success post" "w10c: names the deferral"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w10c: the stale run must not overwrite the newer success's description"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY="$PENDING_OLD" \
  STUB_GUARD_HISTORY=fail) || rc=$?
assert_eq "$rc" "0" "w11: failed guard re-read defers with exit 0 (fail-safe side)"
assert_contains "$out" "deferring the success post" "w11: names the deferral"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w11: no post on an unreadable re-read"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$CR" STUB_GATE_HISTORY="$PENDING_OLD" \
  STUB_GUARD_HISTORY='[{"context":"Review gate","state":"pending","description":"newer","created_at":"'"$FUTURE"'"}]') || rc=$?
assert_contains "$(cat "$POST_LOG")" "state=failure" "w12: downward posts never consult the guard"
assert_not_contains "$out" "deferring" "w12: and never defer"

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

# A SUCCESSFUL read that produced zero bytes is a broken read, not an empty
# page (`[]`) — slurped silently it would misread current state (here) or
# report a green zero-PR convergence (w22c below).
set +e
out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY=emptybytes)
rc=$?
set -e
assert_eq "$rc" "1" "w22b: zero-byte status-history read exits 1"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w22b: no POST past a zero-byte read"

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
  STUB_GATE_HISTORY='[]') || rc=$?
assert_eq "$rc" "0" "w27b: all-PRs approved pass exits 0"
assert_eq "$(grep -c 'state=success' "$POST_LOG")" "2" "w27b: both approved heads open"
assert_eq "$(( $(wc -l < "$RERUN_LOG") ))" "0" "w27b: and the writer re-runs nothing"

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

# w22c: the empty-page case above is exactly why zero BYTES must fail loud —
# the two are adjacent shapes with opposite meanings (`[]` = truly no open
# PRs; nothing at all = a broken read that would strand every gate green).
rc=0; out=$(run_writer_all workflow_run STUB_VERDICT_LINE="$APPROVED" STUB_OPEN_PRS=emptybytes 2>&1) || rc=$?
assert_eq "$rc" "1" "w22c: zero-byte open-PR listing exits 1"
assert_contains "$out" "zero bytes" "w22c: names the broken read"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w22c: posts nothing on a broken listing"

# The two adjacent shapes the -z guard cannot see: whitespace-only slurps to
# [] and an error-object page to {} — both used to read as "zero open PRs"
# and exit green.
rc=0; out=$(run_writer_all workflow_run STUB_VERDICT_LINE="$APPROVED" STUB_OPEN_PRS=whitespace 2>&1) || rc=$?
assert_eq "$rc" "1" "w22d: whitespace-only open-PR listing exits 1"
assert_contains "$out" "not arrays" "w22d: names the shape violation"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w22d: posts nothing"

rc=0; out=$(run_writer_all workflow_run STUB_VERDICT_LINE="$APPROVED" STUB_OPEN_PRS='{"message":"Server Error"}' 2>&1) || rc=$?
assert_eq "$rc" "1" "w22e: an error-object page exits 1"
assert_contains "$out" "not arrays" "w22e: names the shape violation"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w22e: posts nothing"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY='{"message":"Server Error"}' 2>&1) || rc=$?
assert_eq "$rc" "1" "w22f: an error-object status page exits 1"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w22f: no post past a malformed status page"

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
assert_contains "$(cat "$POST_LOG")" "state=success" "wp2: the projection merges every page before deciding"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"pending","description":"awaiting a non-author review for headsha","created_at":"'"$OLD"'"}]' \
  STUB_GUARD_HISTORY='[]' \
  STUB_GUARD_HISTORY_PAGE2='[{"context":"Review gate","state":"failure","description":"newer","created_at":"'"$FUTURE"'"}]') || rc=$?
assert_eq "$rc" "0" "wp3: paginated guard re-read exits 0"
assert_contains "$out" "deferring the success post" "wp3: a newer non-success entry on page two still defers (no first-page-only fail-open)"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "wp3: no post past the paginated guard"

echo "=== settings: the writer never rewrites the override context ==="

# The OVERRIDE_CONTEXT alias lives in review-predicate.sh (so EVERY live gate
# read honors it, not just this writer — pre-PR review finding 4); the
# writer must not export a competing REVIEW_GATE_OUTAGE_CONTEXT on top of it.
ENV_LOG="$TMP_ROOT/predicate-env.log"
cat > "$TMP_ROOT/override-settings.toml" <<'EOF'
REVIEW_GATE_OVERRIDE_CONTEXT = "ops-override"
EOF
: > "$ENV_LOG"
rc=0; out=$(run_writer STUB_VERDICT_LINE="$AWAITING" STUB_GATE_HISTORY='[]' \
  REVIEW_GATE_SETTINGS_FILE="$TMP_ROOT/override-settings.toml" \
  STUB_PREDICATE_ENV_LOG="$ENV_LOG") || rc=$?
assert_eq "$rc" "0" "w30: override-context settings file exits 0"
assert_contains "$(cat "$ENV_LOG")" "OUTAGE=<unset>" "w30: the writer leaves the override alias entirely to the predicate (one mechanism, honored by every reader)"

: > "$ENV_LOG"
rc=0; out=$(run_writer STUB_VERDICT_LINE="$AWAITING" STUB_GATE_HISTORY='[]' \
  STUB_PREDICATE_ENV_LOG="$ENV_LOG") || rc=$?
assert_eq "$rc" "0" "w30b: absent override key exits 0"
assert_contains "$(cat "$ENV_LOG")" "OUTAGE=<unset>" "w30b: absent key leaves the predicate's own resolution untouched"

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
# Every status STATE converges (no state filter of ANY spelling): under
# newest-row evidence semantics a success→pending/failure transition is a
# withdrawal and must close the gate event-fast. Two teeth: the write
# job's if: is pinned as the complete exact line (an equivalent filter
# cannot hide in a rewrite), and any `github.event.state` reference at
# all fails (catches quote variants and inverted filters alike). Grep's
# exit code is branched explicitly — 1 is the passing absence; anything
# else (2 = read error) fails rather than laundering into a pass.
# Scoped to the write job's block (it is the template's last job): a
# template-wide search could be satisfied by a condition on some other job.
write_block="$(sed -n '/^  write:/,$p' "$TEMPLATE")"
if grep -qF -- "    if: github.event_name != 'merge_group'" <<<"$write_block"; then
  PASS=$((PASS + 1)); printf '  ok    %s\n' "tpl: the write job's if: is exactly the merge_group exclusion"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "tpl: the write job's if: is exactly the merge_group exclusion"
fi
rc=0; grep -qF -- "github.event.state" "$TEMPLATE" || rc=$?
case "$rc" in
  1) PASS=$((PASS + 1)); printf '  ok    %s\n' "tpl: no status state filter of any spelling" ;;
  0) FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "tpl: a status state filter returned — withdrawals would wait for the cron floor" ;;
  *) FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "tpl: the template could not be read (grep error)" ;;
esac
pin "cancel-in-progress: false" "tpl: pending writer runs are never cancelled mid-write"
pin "group: review-gate-writer" "tpl: single writer concurrency group"
pin "github.event.pull_request.head.repo.full_name != github.repository" "tpl: fork pull_request_review read-only flag"
pin "if: failure() || cancelled()" "tpl: VST-36 escalation covers timeout-cancelled jobs"
pin "persist-credentials: false" "tpl: checkouts drop credentials"
if grep -qF -- "actions: write" "$TEMPLATE"; then
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "tpl: template must NOT request actions:write (the writer never re-runs CI)"
else
  PASS=$((PASS + 1)); printf '  ok    %s\n' "tpl: no actions:write — the writer never re-runs CI"
fi
pin 'ref: ${{ github.event.repository.default_branch }}' "tpl: engine runs from the default branch"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
