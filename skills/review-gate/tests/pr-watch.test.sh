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
  exit 0
fi
[[ "$cmd" == "api" ]] || { echo "unexpected gh command: $cmd $args" >&2; exit 1; }
case "$args" in
  graphql*mergeQueueEntry*)
    if [[ "${STUB_QUEUED:-}" == "yes" ]]; then
      echo '{"data":{"repository":{"pullRequest":{"mergeQueueEntry":{"position":1}}}}}' \
        | jq -r 'if .data.repository.pullRequest.mergeQueueEntry == null then "" else " (QUEUED: dequeue before pushing)" end'
    else
      printf '\n'
    fi
    ;;
  graphql*reviewThreads*)
    printf '%s\n' "${STUB_UNRESOLVED:-0}"
    ;;
  *"pulls?state=open"*)
    if [[ "${STUB_OPEN_PRS:-[]}" == "emptybytes" ]]; then exit 0; fi
    printf '%s\n' "${STUB_OPEN_PRS:-[]}"
    ;;
  *pulls/*)
    n="${args##*pulls/}"
    var="STUB_PR_${n%% *}"
    if [[ -z "${!var:-}" ]]; then echo "HTTP 404" >&2; exit 1; fi
    printf '%s\n' "${!var}"
    ;;
  *"/statuses?per_page=100"*)
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
pr_row() { # number, [state], [armed], [draft] -> one pulls-list row
  jq -n --argjson n "$1" --arg state "${2:-open}" --arg armed "${3:-armed}" --arg draft "${4:-false}" \
    --arg head "$HEAD_A" \
    '{number:$n, state:$state, draft:($draft=="true"), head:{sha:$head}, user:{login:"author"},
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

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
