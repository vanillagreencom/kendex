#!/usr/bin/env bash
# Behavioral tests for the SHIPPED skills/review-gate/scripts/pr-watch.sh —
# the needs-attention reducer (vstack#1117). Stubbed gh + stubbed predicate,
# every reduction arm driven offline.
#
# Reduction table:
#   pw1.  approved + gate success + armed        -> silence, exit 0
#   pw2.  threads-open                           -> line + exit 1
#   pw3.  threads-open on a QUEUED PR            -> carries the dequeue note
#   pw4.  changes-requested                      -> line + exit 1
#   pw5.  approved + gate pending                -> gate-stale + exit 1
#   pw6.  gate-stale + --heal                    -> exactly ONE writer
#         (two stale PRs)                           dispatch per invocation
#   pw7.  approved + success + NOT armed         -> disarmed + exit 1
#   pw8.  approved + success + queued (unarmed)  -> silence (queue owns it)
#   pw9.  awaiting, head younger than threshold  -> silence, exit 0
#   pw10. awaiting, head older than threshold    -> awaiting-stale + exit 1
#   pw11. predicate failure                      -> error line + exit 2
#   pw12. zero-byte PR listing                   -> exit 2 (broken read,
#                                                   never "zero PRs")
#   pw13. --no-evaluate                          -> threads via direct read,
#                                                   no predicate consulted
#   pw14. explicit PR arg, closed PR             -> skipped silently
#   pw15. draft + approved + success + unarmed   -> no disarmed line
#   pw16. approved verdict + open threads        -> threads-open anyway
#         (the REVIEW_GATE_THREADS=off shape)       (direct read, both modes)
#   pw17. over 100 threads                       -> fail-closed attention
#   pw18. queue-membership read failure          -> error, exit 2 (never a
#                                                   silent "not queued")
#   pw19. cheap mode, unarmed success gate       -> disarmed still emitted
#   pw20. zero-exit predicate, garbage output    -> error, exit 2
#   pw21. old commit in a fresh PR               -> not stale (created_at
#                                                   floors the silence clock)
#   pw22. explicit PR arg answering junk         -> that PR's error line,
#                                                   remaining args processed
#   pw23. zero-byte gate-status read             -> error (broken read)
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
    if [[ "${STUB_QUEUE_ERRORS:-}" == "yes" ]]; then
      # gh --jq applies to the full envelope: an errors array beside partial
      # data must make the jq error() — emulate gh's behavior (nonzero, no
      # stdout) the way it fails on error().
      exit 1
    fi
    if [[ "${STUB_QUEUE_NULL_ENVELOPE:-}" == "yes" ]]; then
      # gh --jq evaluates server-side of the stub: emulate by failing the
      # jq the way gh does on an error() — nonzero with no output.
      exit 1
    fi
    if [[ "${STUB_QUEUED:-}" == "yes" ]]; then
      printf 'queued\n'
    elif [[ "${STUB_QUEUED_FLAG_ONLY:-}" == "yes" ]]; then
      # Transitional snapshot: isInMergeQueue true, entry null — must still
      # read as queued (the OR contract).
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
pr_row() { # number, [state], [armed], [draft], [created_at] -> one pulls-list row
  jq -n --argjson n "$1" --arg state "${2:-open}" --arg armed "${3:-armed}" --arg draft "${4:-false}" \
    --arg created "${5:-2026-01-01T00:00:00Z}" --arg head "$HEAD_A" \
    '{number:$n, state:$state, draft:($draft=="true"), head:{sha:$head}, user:{login:"author"},
      created_at:$created,
      auto_merge: (if $armed=="armed" then {merge_method:"merge"} else null end)}'
}

run_watch() { # env-tokens... [-- flags...]
  local envs=() flags=()
  local seen_sep=0
  for a in "$@"; do
    if [[ "$a" == "--" ]]; then seen_sep=1; continue; fi
    if [[ "$seen_sep" == "1" ]]; then flags+=("$a"); else envs+=("$a"); fi
  done
  (cd "$TMP_ROOT/cwd" \
    && PATH="$TMP_ROOT/bin:$PATH" \
       env GH_REPO=acme/widgets STUB_DISPATCH_LOG="$TMP_ROOT/dispatch.log" "${envs[@]}" \
       "$TMP_ROOT/scripts/pr-watch.sh" ${flags[@]+"${flags[@]}"} 2>&1)
}

echo "=== pr-watch reduction table ==="

# pw1: healthy armed PR — silence.
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=approved detail=review evidence at head" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"success"}]')
rc=$?
set -e
assert_eq "$rc" "0" "pw1: healthy armed PR exits 0"
assert_eq "$out" "" "pw1: and prints nothing"

# pw2: threads-open.
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=threads-open detail=2 unresolved review threads")
rc=$?
set -e
assert_eq "$rc" "1" "pw2: threads-open exits 1"
assert_contains "$out" "threads-open" "pw2: kind emitted"
assert_contains "$out" "2 unresolved review threads" "pw2: predicate detail carried"

# pw3: threads on a queued PR carry the dequeue note.
set +e
out=$(run_watch STUB_QUEUED=yes STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=threads-open detail=1 unresolved review thread")
set -e
assert_contains "$out" "QUEUED: dequeue before pushing" "pw3: queued annotation present"

# pw4: changes-requested.
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=changes-requested detail=reviewer objects")
rc=$?
set -e
assert_eq "$rc" "1" "pw4: changes-requested exits 1"
assert_contains "$out" "changes-requested" "pw4: kind emitted"

# pw5: approved but the gate has not converged.
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=approved detail=review evidence at head" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"pending"}]')
rc=$?
set -e
assert_eq "$rc" "1" "pw5: gate-stale exits 1"
assert_contains "$out" "gate-stale" "pw5: kind emitted"
assert_contains "$out" "pending" "pw5: observed gate state named"

# pw6: --heal dispatches the writer exactly once across two stale PRs.
: > "$TMP_ROOT/dispatch.log"
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson a "$(pr_row 7)" --argjson b "$(pr_row 8)" '[$a,$b]')" \
  STUB_VERDICT_LINE="verdict=approved detail=review evidence at head" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"pending"}]' -- --heal)
set -e
assert_contains "$out" "heal-dispatched" "pw6: heal reported"
assert_eq "$(wc -l < "$TMP_ROOT/dispatch.log" | tr -d ' ')" "1" "pw6: exactly one writer dispatch"

# pw7: gate open, auto-merge not armed, not queued -> disarmed.
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7 open unarmed)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=approved detail=review evidence at head" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"success"}]')
rc=$?
set -e
assert_eq "$rc" "1" "pw7: disarmed exits 1"
assert_contains "$out" "disarmed" "pw7: kind emitted"

# pw8: same shape but QUEUED -> the queue owns the merge; silence.
set +e
out=$(run_watch STUB_QUEUED=yes STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7 open unarmed)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=approved detail=review evidence at head" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"success"}]')
rc=$?
set -e
assert_eq "$rc" "0" "pw8: queued unarmed success PR is healthy (exit 0)"
assert_not_contains "$out" "disarmed" "pw8: no disarmed line"

# pw9/pw10: awaiting inside vs past the quiet period.
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=awaiting detail=no evidence" \
  STUB_HEAD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" -- --awaiting-after 3600)
rc=$?
set -e
assert_eq "$rc" "0" "pw9: fresh awaiting head is healthy"
assert_eq "$out" "" "pw9: and silent"

set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=awaiting detail=no evidence" \
  STUB_HEAD_DATE="2026-01-01T00:00:00Z" -- --awaiting-after 60)
rc=$?
set -e
assert_eq "$rc" "1" "pw10: stale awaiting head exits 1"
assert_contains "$out" "awaiting-stale" "pw10: kind emitted"

# pw11: predicate failure is a loud error, exit 2.
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_PREDICATE_RC=2 STUB_VERDICT_LINE="unused")
rc=$?
set -e
assert_eq "$rc" "2" "pw11: predicate failure exits 2"
assert_contains "$out" "error" "pw11: error line emitted"

# pw12: a zero-byte listing is a broken read, never zero PRs.
set +e
out=$(run_watch STUB_OPEN_PRS="emptybytes" STUB_VERDICT_LINE="unused")
rc=$?
set -e
assert_eq "$rc" "2" "pw12: zero-byte PR listing exits 2"
assert_contains "$out" "broken read" "pw12: named as a broken read"

# pw13: --no-evaluate reads threads directly and never consults the predicate.
: > "$TMP_ROOT/predicate-calls"
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_UNRESOLVED=3 STUB_PREDICATE_CALLS="$TMP_ROOT/predicate-calls" \
  STUB_VERDICT_LINE="unused" -- --no-evaluate)
rc=$?
set -e
assert_eq "$rc" "1" "pw13: cheap mode reports threads"
assert_contains "$out" "3 unresolved review thread" "pw13: direct count carried"
assert_eq "$(wc -l < "$TMP_ROOT/predicate-calls" | tr -d ' ')" "0" "pw13: predicate never consulted"

# pw14: an explicitly named CLOSED PR is skipped silently.
set +e
out=$(run_watch STUB_PR_9="$(pr_row 9 closed)" STUB_VERDICT_LINE="unused" -- 9)
rc=$?
set -e
assert_eq "$rc" "0" "pw14: closed PR arg exits 0"
assert_eq "$out" "" "pw14: and prints nothing"

# pw15: drafts never get the disarmed nag (auto-merge cannot arm on drafts).
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7 open unarmed true)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=approved detail=review evidence at head" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"success"}]')
rc=$?
set -e
assert_eq "$rc" "0" "pw15: draft exits 0"
assert_not_contains "$out" "disarmed" "pw15: no disarmed line for drafts"

# pw16: threads are read DIRECTLY even in evaluate mode — a
# REVIEW_GATE_THREADS=off repo's predicate returns approved with threads
# open, and the watcher must still see them.
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_UNRESOLVED=2 \
  STUB_VERDICT_LINE="verdict=approved detail=review evidence at head" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"success"}]')
rc=$?
set -e
assert_eq "$rc" "1" "pw16: threads-off repo shape still reports threads"
assert_contains "$out" "threads-open" "pw16: kind emitted despite approved verdict"

# pw17: over 100 threads fails CLOSED as attention.
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_UNRESOLVED=100 STUB_THREADS_NEXTPAGE=true \
  STUB_VERDICT_LINE="verdict=approved detail=unused")
rc=$?
set -e
assert_eq "$rc" "1" "pw17: thread overflow exits 1"
assert_contains "$out" "overflow" "pw17: named as overflow (fail closed)"

# pw18: a failed queue-membership read is a loud error, never "not queued".
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_QUEUE_FAIL=yes STUB_VERDICT_LINE="verdict=approved detail=unused")
rc=$?
set -e
assert_eq "$rc" "2" "pw18: queue read failure exits 2"
assert_contains "$out" "merge-queue membership read failed" "pw18: error line names the read"

# pw19: cheap mode still emits disarmed (its documented second finding).
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7 open unarmed)" '[$r]')" \
  STUB_VERDICT_LINE="unused" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"success"}]' -- --no-evaluate)
rc=$?
set -e
assert_eq "$rc" "1" "pw19: cheap mode reports disarmed"
assert_contains "$out" "disarmed" "pw19: kind emitted"
assert_contains "$out" "UNCONFIRMED in cheap mode" "pw19: and never recommends arming unconfirmed"

# pw20: a zero-exit predicate with unrecognizable output is an error, never
# a healthy PR.
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="garbage output with no verdict")
rc=$?
set -e
assert_eq "$rc" "2" "pw20: malformed predicate output exits 2"
assert_contains "$out" "no recognizable verdict" "pw20: named as broken output"

# pw21: the awaiting clock floors at PR creation — a cherry-picked
# days-old commit in a freshly opened PR is NOT instantly stale.
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7 open armed false "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" '[$r]')" \
  STUB_VERDICT_LINE="verdict=awaiting detail=no evidence" \
  STUB_HEAD_DATE="2026-01-01T00:00:00Z" -- --awaiting-after 3600)
rc=$?
set -e
assert_eq "$rc" "0" "pw21: fresh PR with an old commit is not stale (created_at floor)"

# pw22: an explicitly named PR whose fetch returns junk is that PR's error
# line — the remaining arguments still process.
set +e
out=$(run_watch STUB_PR_5="not json at all" STUB_PR_6="$(pr_row 6 closed)" STUB_VERDICT_LINE="unused" -- 5 6)
rc=$?
set -e
assert_eq "$rc" "2" "pw22: junk PR response exits 2"
assert_contains "$out" "not a well-formed PR object" "pw22: error names the broken read"

# pw23: a zero-byte gate-status read is a broken read, never an empty set.
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=approved detail=review evidence at head" \
  STUB_GATE_HISTORY="emptybytes")
rc=$?
set -e
assert_eq "$rc" "2" "pw23: zero-byte gate read exits 2"
assert_contains "$out" "zero bytes" "pw23: named as a broken read"

# pw24: the INVERSE mismatch — awaiting verdict over a still-green gate
# (withdrawn evidence, merge-enabling) — is gate-stale and heals.
: > "$TMP_ROOT/dispatch.log"
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=awaiting detail=no evidence" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"success"}]' \
  STUB_HEAD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" -- --heal --awaiting-after 3600)
rc=$?
set -e
assert_eq "$rc" "1" "pw24: stale-green over awaiting exits 1"
assert_contains "$out" "merge-enabling" "pw24: named as the dangerous direction"
assert_eq "$(wc -l < "$TMP_ROOT/dispatch.log" | tr -d ' ')" "1" "pw24: and it heals"

# pw25: ghost author (user: null) must not shift TSV columns — the PR still
# processes and its findings still emit.
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --arg head "$HEAD_A" '[{number:7, state:"open", draft:false, head:{sha:$head}, user:null, created_at:"2026-01-01T00:00:00Z", auto_merge:{merge_method:"merge"}}]')" \
  STUB_UNRESOLVED=1 STUB_VERDICT_LINE="verdict=approved detail=unused")
rc=$?
set -e
assert_eq "$rc" "2" "pw25: ghost-author PR reduces threads AND names the ghost (exit 2)"
assert_contains "$out" "threads-open" "pw25: its findings still emit"
assert_contains "$out" "deleted account" "pw25: alongside the named ghost error"

# pw26: a green gate over a standing objection reports both the objection
# and the stale gate.
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=changes-requested detail=reviewer objects" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"success"}]')
rc=$?
set -e
assert_eq "$rc" "1" "pw26: objection over green gate exits 1"
assert_contains "$out" "changes-requested" "pw26: objection emitted"
assert_contains "$out" "gate-stale" "pw26: stale green emitted too"

# pw27: a future-dated committer timestamp (author-controlled) is a loud
# error, never indefinite healthy silence.
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=awaiting detail=no evidence" \
  STUB_HEAD_DATE="2030-01-01T00:00:00Z" -- --awaiting-after 60)
rc=$?
set -e
assert_eq "$rc" "2" "pw27: future-dated head exits 2"
assert_contains "$out" "unprovable" "pw27: named as unprovable silence age"

# pw28: queued gate-stale lines carry the dequeue note.
set +e
out=$(run_watch STUB_QUEUED=yes STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=changes-requested detail=reviewer objects" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"success"}]')
set -e
assert_eq "$(grep -c "QUEUED: dequeue" <<<"$out")" "2" "pw28: both lines carry the dequeue note"

# pw29: unparsable timestamps are a loud error, never silent health.
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --arg head "$HEAD_A" '[{number:7, state:"open", draft:false, head:{sha:$head}, user:{login:"author"}, created_at:"garbage", auto_merge:{merge_method:"merge"}}]')" \
  STUB_VERDICT_LINE="verdict=awaiting detail=no evidence" \
  STUB_HEAD_DATE="also-garbage" -- --awaiting-after 60)
rc=$?
set -e
assert_eq "$rc" "2" "pw29: unparsable timestamps exit 2"
assert_contains "$out" "unparsable" "pw29: named as unparsable (broken read)"

# pw30: under REVIEW_GATE_THREADS=off, a green gate over open threads is
# the DESIGNED state — threads still report (triage is the agent's job)
# but no gate-stale, no heal dispatch.
: > "$TMP_ROOT/dispatch.log"
set +e
out=$(run_watch REVIEW_GATE_THREADS=off STUB_QUEUED=no STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_UNRESOLVED=2 STUB_VERDICT_LINE="verdict=approved detail=unused" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"success"}]' -- --heal)
rc=$?
set -e
assert_eq "$rc" "1" "pw30: threads still report under THREADS=off"
assert_contains "$out" "threads-open" "pw30: threads-open emitted"
assert_not_contains "$out" "gate-stale" "pw30: no false gate-stale"
assert_eq "$(wc -l < "$TMP_ROOT/dispatch.log" | tr -d ' ')" "0" "pw30: no writer dispatch"

# pw31: an invalid REVIEW_GATE_THREADS value refuses to reduce (config
# error, exit 2) instead of silently reading as enforced.
set +e
out=$(run_watch REVIEW_GATE_THREADS=of STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="unused")
rc=$?
set -e
assert_eq "$rc" "2" "pw31: invalid thread mode exits 2"
assert_contains "$out" "invalid REVIEW_GATE_THREADS" "pw31: named as config error"

# pw32: a FAILED dispatch still consumes the one heal attempt — no
# per-stale-PR retry storm during an outage.
: > "$TMP_ROOT/dispatch.log"
set +e
out=$(run_watch STUB_DISPATCH_FAIL=yes STUB_OPEN_PRS="$(jq -cn --argjson a "$(pr_row 7)" --argjson b "$(pr_row 8)" '[$a,$b]')" \
  STUB_VERDICT_LINE="verdict=approved detail=unused" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"pending"}]' -- --heal)
rc=$?
set -e
assert_eq "$rc" "2" "pw32: failed dispatch exits 2"
assert_eq "$(wc -l < "$TMP_ROOT/dispatch.log" | tr -d ' ')" "1" "pw32: exactly one dispatch ATTEMPT"

# pw33: under THREADS=off, open threads do not eat the disarmed finding —
# one line per finding, both emit.
set +e
out=$(run_watch REVIEW_GATE_THREADS=off STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7 open unarmed)" '[$r]')" \
  STUB_UNRESOLVED=2 STUB_VERDICT_LINE="verdict=approved detail=unused" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"success"}]')
rc=$?
set -e
assert_eq "$rc" "1" "pw33: exits 1"
assert_contains "$out" "threads-open" "pw33: threads reported"
assert_contains "$out" "disarmed" "pw33: disarmed also reported"

# pw34: drafts get no reviewer-silence alerts (mismatch checks still run).
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7 open armed true)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=awaiting detail=no evidence" \
  STUB_HEAD_DATE="2026-01-01T00:00:00Z" -- --awaiting-after 60)
rc=$?
set -e
assert_eq "$rc" "0" "pw34: old draft is not awaiting-stale"
assert_eq "$out" "" "pw34: and silent"

# pw35: open threads do not suppress a standing objection — both lines.
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_UNRESOLVED=1 STUB_VERDICT_LINE="verdict=changes-requested detail=reviewer objects")
rc=$?
set -e
assert_eq "$rc" "1" "pw35: exits 1"
assert_contains "$out" "threads-open" "pw35: threads reported"
assert_contains "$out" "changes-requested" "pw35: objection reported too"

# pw35b: the predicate's duplicate threads-open verdict dedupes.
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_UNRESOLVED=1 STUB_VERDICT_LINE="verdict=threads-open detail=1 unresolved review threads")
set -e
assert_eq "$(grep -c "threads-open" <<<"$out")" "1" "pw35b: one threads-open line, not two"

# pw36: the predicate paging-race threads path heals a green gate too.
: > "$TMP_ROOT/dispatch.log"
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_UNRESOLVED=0 STUB_VERDICT_LINE="verdict=threads-open detail=1 unresolved review threads" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"success"}]' -- --heal)
rc=$?
set -e
assert_eq "$rc" "1" "pw36: race-path threads exit 1"
assert_contains "$out" "gate-stale" "pw36: stale green reported"
assert_eq "$(wc -l < "$TMP_ROOT/dispatch.log" | tr -d ' ')" "1" "pw36: and heals"

# pw37: a null isResolved node is malformed, never counted as resolved.
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_THREADS_RAW='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":null}]}}}}}' \
  STUB_VERDICT_LINE="unused")
rc=$?
set -e
assert_eq "$rc" "2" "pw37: malformed thread node exits 2"
assert_contains "$out" "malformed" "pw37: named as malformed"

# pw38: a malformed listing element fails the row projection loudly.
set +e
out=$(run_watch STUB_OPEN_PRS='[42]' STUB_VERDICT_LINE="unused")
rc=$?
set -e
assert_eq "$rc" "2" "pw38: malformed listing element exits 2"
assert_contains "$out" "malformed" "pw38: named as a malformed listing"

# pw39: an object-shaped malformed element (missing required fields) fails
# the projection deterministically instead of misparsing the TSV loop.
set +e
out=$(run_watch STUB_OPEN_PRS='[{}]' STUB_VERDICT_LINE="unused")
rc=$?
set -e
assert_eq "$rc" "2" "pw39: empty-object element exits 2"
assert_contains "$out" "malformed" "pw39: named as a malformed listing"

# pw40: malformed pagination metadata is an error, never overflow attention.
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_THREADS_RAW='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":null},"nodes":[]}}}}}' \
  STUB_VERDICT_LINE="unused")
rc=$?
set -e
assert_eq "$rc" "2" "pw40: malformed pageInfo exits 2"
assert_contains "$out" "pagination metadata malformed" "pw40: named precisely"

# pw41: a malformed queue envelope is an error, never silently unqueued.
set +e
out=$(run_watch STUB_QUEUE_NULL_ENVELOPE=yes STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="unused")
rc=$?
set -e
assert_eq "$rc" "2" "pw41: malformed queue envelope exits 2"
assert_contains "$out" "merge-queue membership" "pw41: named"

# pw42: a non-array nodes container is malformed, never zero threads.
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_THREADS_RAW='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":{"item":{"isResolved":true}}}}}}}' \
  STUB_VERDICT_LINE="unused")
rc=$?
set -e
assert_eq "$rc" "2" "pw42: non-array nodes container exits 2"
assert_contains "$out" "malformed" "pw42: named as malformed"

# pw43: a zero-byte thread response is a broken read, never zero threads.
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_THREADS_RAW="emptybytes" STUB_VERDICT_LINE="unused")
rc=$?
set -e
assert_eq "$rc" "2" "pw43: zero-byte thread read exits 2"
assert_contains "$out" "zero bytes" "pw43: named as a broken read"

# pw44: an explicitly empty gate context is a config error in every mode.
set +e
out=$(run_watch REVIEW_GATE_CONTEXT= STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="unused" -- --no-evaluate)
rc=$?
set -e
assert_eq "$rc" "2" "pw44: empty gate context exits 2"
assert_contains "$out" "REVIEW_GATE_CONTEXT is explicitly empty" "pw44: named as config error"

# pw45: a matching gate row without a state is malformed, never absent.
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=approved detail=unused" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":null}]')
rc=$?
set -e
assert_eq "$rc" "2" "pw45: null-state gate row exits 2"
assert_contains "$out" "malformed" "pw45: named as malformed"

# pw46: a ghost-author PR with nothing else to report names the cause
# precisely (the predicate cannot evaluate it) instead of a generic error.
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --arg head "$HEAD_A" '[{number:7, state:"open", draft:false, head:{sha:$head}, user:null, created_at:"2026-01-01T00:00:00Z", auto_merge:{merge_method:"merge"}}]')" \
  STUB_VERDICT_LINE="unused")
rc=$?
set -e
assert_eq "$rc" "2" "pw46: ghost author exits 2"
assert_contains "$out" "deleted account" "pw46: cause named"

# pw47: a head that moves during the reduction is attention, not silence.
set +e
out=$(run_watch STUB_HEAD_AFTER="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
  STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=approved detail=review evidence at head" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"success"}]')
rc=$?
set -e
assert_eq "$rc" "1" "pw47: moved head exits 1"
assert_contains "$out" "head-moved" "pw47: kind emitted"

# pw48: GraphQL errors beside partial queue data are a loud error.
set +e
out=$(run_watch STUB_QUEUE_ERRORS=yes STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="unused")
rc=$?
set -e
assert_eq "$rc" "2" "pw48: queue errors envelope exits 2"

# pw49: a response describing a DIFFERENT PR fails the binding check.
set +e
out=$(run_watch STUB_PR_9="$(pr_row 7)" STUB_VERDICT_LINE="unused" -- 9)
rc=$?
set -e
assert_eq "$rc" "2" "pw49: mismatched PR number exits 2"
assert_contains "$out" "not a well-formed PR object" "pw49: fails the binding check"

# pw50: zero-padded explicit args normalize (09 -> 9).
set +e
out=$(run_watch STUB_PR_9="$(pr_row 9 closed)" STUB_VERDICT_LINE="unused" -- 09)
rc=$?
set -e
assert_eq "$rc" "0" "pw50: zero-padded arg fetches and reduces (closed = silent 0)"

# pw51: a recheck returning no usable sha is a loud error.
set +e
out=$(run_watch STUB_HEAD_AFTER="null" \
  STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=approved detail=review evidence at head" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"success"}]')
rc=$?
set -e
assert_eq "$rc" "2" "pw51: null recheck sha exits 2"
assert_contains "$out" "no usable sha" "pw51: named"

# pw52: a fresh ready_for_review event restarts the quiet period for a
# just-readied long-lived draft.
set +e
out=$(run_watch STUB_READY_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=awaiting detail=no evidence" \
  STUB_HEAD_DATE="2026-01-01T00:00:00Z" -- --awaiting-after 3600)
rc=$?
set -e
assert_eq "$rc" "0" "pw52: fresh readiness restarts the quiet period"
assert_not_contains "$out" "awaiting-stale" "pw52: no stale alert"

# pw53: a timeline failure while confirming staleness fails loud, never a
# stale alert on unconfirmed data.
set +e
out=$(run_watch STUB_TIMELINE_FAIL=yes \
  STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=awaiting detail=no evidence" \
  STUB_HEAD_DATE="2026-01-01T00:00:00Z" -- --awaiting-after 60)
rc=$?
set -e
assert_eq "$rc" "2" "pw53: timeline failure exits 2"
assert_not_contains "$out" "awaiting-stale" "pw53: no stale alert on unconfirmed data"

# pw54: a non-sha recheck value is a broken read, never head-moved.
set +e
out=$(run_watch STUB_HEAD_AFTER="42" \
  STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=approved detail=review evidence at head" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"success"}]')
rc=$?
set -e
assert_eq "$rc" "2" "pw54: non-sha recheck exits 2"
assert_contains "$out" "non-sha value" "pw54: named"
assert_not_contains "$out" "head-moved" "pw54: never head-moved"

# pw55: a zero-byte timeline response is a broken read.
set +e
out=$(run_watch STUB_TIMELINE_EMPTYBYTES=yes \
  STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=awaiting detail=no evidence" \
  STUB_HEAD_DATE="2026-01-01T00:00:00Z" -- --awaiting-after 60)
rc=$?
set -e
assert_eq "$rc" "2" "pw55: zero-byte timeline exits 2"
assert_contains "$out" "zero bytes" "pw55: named"

# pw56: a fresh reopen restarts the quiet period like readiness does.
set +e
out=$(run_watch STUB_REOPENED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=awaiting detail=no evidence" \
  STUB_HEAD_DATE="2026-01-01T00:00:00Z" -- --awaiting-after 3600)
rc=$?
set -e
assert_eq "$rc" "0" "pw56: fresh reopen restarts the quiet period"

# pw57: an unparsable readiness timestamp fails loud, never a stale alert.
set +e
out=$(run_watch STUB_READY_AT="garbage-timestamp" \
  STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=awaiting detail=no evidence" \
  STUB_HEAD_DATE="2026-01-01T00:00:00Z" -- --awaiting-after 60)
rc=$?
set -e
assert_eq "$rc" "2" "pw57: unparsable readiness timestamp exits 2"
assert_not_contains "$out" "awaiting-stale" "pw57: no stale alert"

# pw58: a fresh re-review request restarts the quiet period (no nudge loop).
set +e
out=$(run_watch STUB_REREQUEST_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=awaiting detail=no evidence" \
  STUB_HEAD_DATE="2026-01-01T00:00:00Z" -- --awaiting-after 3600)
rc=$?
set -e
assert_eq "$rc" "0" "pw58: fresh re-review request restarts the quiet period"

# pw59: a future-dated timeline event is unprovable, never silent health.
set +e
out=$(run_watch STUB_READY_AT="2030-01-01T00:00:00Z" \
  STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=awaiting detail=no evidence" \
  STUB_HEAD_DATE="2026-01-01T00:00:00Z" -- --awaiting-after 60)
rc=$?
set -e
assert_eq "$rc" "2" "pw59: future-dated timeline event exits 2"
assert_contains "$out" "unprovable" "pw59: named"

# pw60: a state outside the open|closed enum is malformed, never a skip.
set +e
out=$(run_watch STUB_PR_9="$(pr_row 9 bogus)" STUB_VERDICT_LINE="unused" -- 9)
rc=$?
set -e
assert_eq "$rc" "2" "pw60: bogus state exits 2"
assert_contains "$out" "outside the open|closed enum" "pw60: named"

# pw61: a PR response missing reducer-load-bearing fields (draft /
# auto_merge / created_at) fails the well-formed check.
set +e
out=$(run_watch STUB_PR_9="$(jq -cn --arg head "$HEAD_A" '{number:9, state:"open", head:{sha:$head}, user:{login:"author"}}')" STUB_VERDICT_LINE="unused" -- 9)
rc=$?
set -e
assert_eq "$rc" "2" "pw61: partial PR object exits 2"
assert_contains "$out" "not a well-formed PR object" "pw61: named"

# pw62: an initial head that is not a 40-hex sha fails the schema boundary.
set +e
out=$(run_watch STUB_PR_9="$(jq -cn '{number:9, state:"open", draft:false, head:{sha:"main"}, user:{login:"author"}, created_at:"2026-01-01T00:00:00Z", auto_merge:null}')" STUB_VERDICT_LINE="unused" -- 9)
rc=$?
set -e
assert_eq "$rc" "2" "pw62: non-sha initial head exits 2"
assert_contains "$out" "not a well-formed PR object" "pw62: named"

# pw63: a head commit without a committer date is a broken read.
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=awaiting detail=no evidence" \
  STUB_HEAD_DATE="null" -- --awaiting-after 60)
rc=$?
set -e
assert_eq "$rc" "2" "pw63: missing committer date exits 2"
assert_contains "$out" "no usable committer date" "pw63: named"

# pw64: a mid-reduction disarm (queue ejection shape) is caught by the
# just-in-time ownership recheck — never a healthy exit 0.
mkdir -p "$TMP_ROOT/prcalls"; rm -f "$TMP_ROOT/prcalls"/*
set +e
out=$(run_watch STUB_ARMED_AFTER=false STUB_PR_CALLS_DIR="$TMP_ROOT/prcalls" \
  STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=approved detail=review evidence at head" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"success"}]')
rc=$?
set -e
assert_eq "$rc" "1" "pw64: mid-reduction disarm exits 1"
assert_contains "$out" "disarmed" "pw64: kind emitted"

# pw65: a PR that closed mid-reduction gets no re-arm nudge — silence.
# (Shim: STUB_ARMED_AFTER machinery reuses the per-number counter; here we
# hand-serve a closed row on the second fetch via STUB_CLOSED_AFTER.)
mkdir -p "$TMP_ROOT/prcalls"; rm -f "$TMP_ROOT/prcalls"/*
set +e
out=$(run_watch STUB_CLOSED_AFTER=yes STUB_PR_CALLS_DIR="$TMP_ROOT/prcalls" \
  STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7 open unarmed)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=approved detail=review evidence at head" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"success"}]')
rc=$?
set -e
assert_eq "$rc" "0" "pw65: mid-reduction close exits 0"
assert_not_contains "$out" "disarmed" "pw65: no re-arm nudge for a completed PR"

# pw66: a bogus commit-status state is malformed, never absent or stale.
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=approved detail=unused" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"bogus"}]')
rc=$?
set -e
assert_eq "$rc" "2" "pw66: bogus status state exits 2"
assert_contains "$out" "valid error|failure|pending|success state" "pw66: named"

# pw67: a to-draft conversion mid-reduction skips only the re-arm nudge —
# verdict reductions still run (the stale-green mismatch still heals).
mkdir -p "$TMP_ROOT/prcalls"; rm -f "$TMP_ROOT/prcalls"/*
: > "$TMP_ROOT/dispatch.log"
set +e
out=$(run_watch STUB_DRAFT_AFTER=yes STUB_PR_CALLS_DIR="$TMP_ROOT/prcalls" \
  STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7 open unarmed)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=awaiting detail=no evidence" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"success"}]' \
  STUB_HEAD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" -- --heal --awaiting-after 3600)
rc=$?
set -e
assert_eq "$rc" "1" "pw67: to-draft conversion still reduces the verdict"
assert_contains "$out" "gate-stale" "pw67: stale green still reported"
assert_not_contains "$out" "disarmed" "pw67: but no re-arm nudge"

# pw68: an unparsable creation timestamp is a broken read, never a skipped
# floor that false-alerts staleness.
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7 open armed false garbage)" '[$r]')" \
  STUB_VERDICT_LINE="verdict=awaiting detail=no evidence" \
  STUB_HEAD_DATE="2026-01-01T00:00:00Z" -- --awaiting-after 60)
rc=$?
set -e
assert_eq "$rc" "2" "pw68: unparsable created_at exits 2"
assert_contains "$out" "creation timestamp unparsable" "pw68: named"

# pw69: an empty auto_merge object is malformed, never silently armed.
set +e
out=$(run_watch STUB_PR_9="$(jq -cn --arg head "$HEAD_A" '{number:9, state:"open", draft:false, head:{sha:$head}, user:{login:"author"}, created_at:"2026-01-01T00:00:00Z", auto_merge:{}}')" STUB_VERDICT_LINE="unused" -- 9)
rc=$?
set -e
assert_eq "$rc" "2" "pw69: empty auto_merge object exits 2"
assert_contains "$out" "not a well-formed PR object" "pw69: named"

# pw70: cheap mode fires the threads-driven gate-stale (documented form).
: > "$TMP_ROOT/dispatch.log"
set +e
out=$(run_watch STUB_OPEN_PRS="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')" \
  STUB_UNRESOLVED=1 STUB_VERDICT_LINE="unused" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"success"}]' -- --no-evaluate --heal)
rc=$?
set -e
assert_eq "$rc" "1" "pw70: cheap-mode threads over green gate exits 1"
assert_contains "$out" "gate-stale" "pw70: threads-driven gate-stale fires"
assert_eq "$(wc -l < "$TMP_ROOT/dispatch.log" | tr -d ' ')" "1" "pw70: and heals"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
