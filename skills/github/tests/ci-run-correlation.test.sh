#!/usr/bin/env bash
# `scope_current_run` lived in TWO places — orch `ci-wait` and github
# `pr-merge.sh` — each carrying a comment that it must stay aligned with the
# other "byte-for-byte". Nothing enforced that, and they drifted: `ci-wait` grew
# substantive-run selection and stale-status rewriting (vstack#607) while
# `pr-merge.sh` kept the original max-run-id version (vstack#492). A merge gate
# and the waiter feeding it were then scoping the same rollup by different rules
# (vstack#876).
#
# These tests (a) pin the shared implementation's behaviour and (b) fail if
# either script grows a local copy again, so the drift cannot silently return.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
LIB="$REPO_ROOT/skills/github/scripts/lib/ci-run-correlation.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

[[ -f "$LIB" ]] || { echo "FATAL: shared library missing at $LIB"; exit 1; }
# shellcheck source=../scripts/lib/ci-run-correlation.sh
source "$LIB"

echo "=== single implementation ==="

for script in "$REPO_ROOT/skills/orch/scripts/ci-wait" \
              "$REPO_ROOT/skills/github/scripts/commands/pr-merge.sh"; do
  name="$(basename "$script")"
  if grep -qE '^scope_current_run\(\)' "$script"; then
    fail "$name defines its own scope_current_run (drift reintroduced — source the shared library instead)"
  else
    pass "$name does not define its own scope_current_run"
  fi
  if grep -q 'ci-run-correlation.sh' "$script"; then
    pass "$name sources the shared library"
  else
    fail "$name sources the shared library"
  fi
done

echo "=== scoping behaviour ==="

run_scope() { scope_current_run <<<"$1"; }
names_of() { jq -r '[.[] | .name] | sort | join(",")' <<<"$1"; }

# An approval-gated repo can dispatch an all-SKIPPED no-op run AFTER the
# substantive one. The newer run must not win just because its id is higher.
NOOP='[
 {"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T10:00:00Z","link":"https://x/actions/runs/100/job/1"},
 {"name":"build","state":"SKIPPED","bucket":"skipping","workflow":"CI","startedAt":"2026-07-26T10:06:00Z","link":"https://x/actions/runs/200/job/2"}
]'
OUT="$(run_scope "$NOOP")"
if [[ "$(jq -r '.[0].link' <<<"$OUT")" == *"/runs/100/"* ]] && [[ "$(jq 'length' <<<"$OUT")" == 1 ]]; then
  pass "a later all-skipped run does not supersede the substantive one"
else
  fail "a later all-skipped run does not supersede the substantive one (got $OUT)"
fi

# Checks with no parseable run id are always kept, deduped by name on startedAt.
NORUN='[
 {"name":"external","state":"SUCCESS","bucket":"pass","workflow":"","startedAt":"2026-07-26T10:00:00Z","link":""},
 {"name":"external","state":"FAILURE","bucket":"fail","workflow":"","startedAt":"2026-07-26T10:09:00Z","link":""}
]'
OUT="$(run_scope "$NORUN")"
if [[ "$(jq 'length' <<<"$OUT")" == 1 ]] && [[ "$(jq -r '.[0].state' <<<"$OUT")" == "FAILURE" ]]; then
  pass "run-less checks dedupe by name keeping the latest startedAt"
else
  fail "run-less checks dedupe by name keeping the latest startedAt (got $OUT)"
fi

# Distinct workflows are never collapsed into one another.
TWO='[
 {"name":"a","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T10:00:00Z","link":"https://x/actions/runs/100/job/1"},
 {"name":"b","state":"SUCCESS","bucket":"pass","workflow":"Guard","startedAt":"2026-07-26T10:00:00Z","link":"https://x/actions/runs/50/job/2"}
]'
OUT="$(run_scope "$TWO")"
[[ "$(names_of "$OUT")" == "a,b" ]] \
  && pass "distinct workflows are both preserved" \
  || fail "distinct workflows are both preserved (got $(names_of "$OUT"))"

echo "=== vstack#876 reported shape ==="

# The reported rollup, with the run ids and job `startedAt` values taken from
# the real head (vanillagreencom/hyprtrade#419 @ 1d9b5e7):
#
#   run 30201902682  pull_request_review, attempt 1, CANCELLED by concurrency
#                    jobs 12:21:43-12:21:56 — the "zero-second failures"
#   run 30201726860  pull_request, attempt 2 (a RERUN), SUCCESS
#                    jobs 12:22:07-12:23:31, `CI Required` published 12:28:48
#
# The rerun carries the LOWER run id because a new attempt reuses the original
# run's id, so max-run-id picked the cancelled run and leaked its artifacts into
# `pr-merge --check` while `ci-wait` — already rerun-aware via vstack#699 —
# reported pass. Ranking on when the checks actually ran resolves that: the
# rerun's jobs start after the cancelled run's.
DUP='[
 {"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T12:22:11Z","link":"https://x/actions/runs/30201726860/job/1"},
 {"name":"CI Gate Publisher","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T12:23:26Z","link":"https://x/actions/runs/30201726860/job/2"},
 {"name":"CI Required","state":"SUCCESS","bucket":"pass","workflow":"","startedAt":"2026-07-26T12:28:48Z","link":"https://x/actions/runs/30201726860"},
 {"name":"CI Gate Publisher","state":"FAILURE","bucket":"fail","workflow":"CI","startedAt":"2026-07-26T12:21:56Z","link":"https://x/actions/runs/30201902682/job/9"},
 {"name":"build","state":"CANCELLED","bucket":"cancel","workflow":"CI","startedAt":"2026-07-26T12:21:45Z","link":"https://x/actions/runs/30201902682/job/10"}
]'
OUT="$(run_scope "$DUP")"
if jq -e '[.[] | select(.state == "FAILURE" or .state == "CANCELLED")] | length == 0' >/dev/null <<<"$OUT"; then
  pass "the cancelled duplicate run's failures are scoped out (#876)"
else
  fail "the cancelled duplicate run's failures are scoped out (#876) (got $OUT)"
fi
if jq -e '[.[] | select(.name == "CI Required" and .state == "SUCCESS")] | length == 1' >/dev/null <<<"$OUT"; then
  pass "the required aggregate stays green and is not rewritten"
else
  fail "the required aggregate stays green and is not rewritten (got $OUT)"
fi
if jq -e 'all(.[]; (.link | test("/runs/30201902682/") | not))' >/dev/null <<<"$OUT"; then
  pass "no check from the cancelled run reaches the merge gate"
else
  fail "no check from the cancelled run reaches the merge gate (got $OUT)"
fi

echo "=== rank ordering guardrails ==="

# Fail-closed must survive the switch away from run-id order. A newer run that
# is still QUEUED has no usable timestamp; it must NOT lose to a completed older
# run, or a merge could proceed while replacement work is in flight.
QUEUED='[
 {"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T10:00:00Z","link":"https://x/actions/runs/100/job/1"},
 {"name":"build","state":"QUEUED","bucket":"pending","workflow":"CI","startedAt":"0001-01-01T00:00:00Z","link":"https://x/actions/runs/200/job/2"}
]'
OUT="$(run_scope "$QUEUED")"
if [[ "$(jq -r '.[0].link' <<<"$OUT")" == *"/runs/200/"* ]] && [[ "$(jq 'length' <<<"$OUT")" == 1 ]]; then
  pass "a queued newer run with no timestamp still wins (run-id fallback)"
else
  fail "a queued newer run with no timestamp still wins (run-id fallback) (got $OUT)"
fi

# A genuinely later run that failed is still a failure — time ordering must not
# become a way for an older green run to mask a real regression.
LATERFAIL='[
 {"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T10:00:00Z","link":"https://x/actions/runs/100/job/1"},
 {"name":"build","state":"FAILURE","bucket":"fail","workflow":"CI","startedAt":"2026-07-26T10:30:00Z","link":"https://x/actions/runs/200/job/2"}
]'
OUT="$(run_scope "$LATERFAIL")"
if [[ "$(jq -r '.[0].state' <<<"$OUT")" == "FAILURE" ]] && [[ "$(jq 'length' <<<"$OUT")" == 1 ]]; then
  pass "a later failing run stays terminal"
else
  fail "a later failing run stays terminal (got $OUT)"
fi

# The stale-aggregate rewrite follows the same ordering as run selection.
STALE='[
 {"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T10:00:00Z","link":"https://x/actions/runs/100/job/1"},
 {"name":"CI Required","state":"SUCCESS","bucket":"pass","workflow":"","startedAt":"2026-07-26T10:01:00Z","link":"https://x/actions/runs/100"},
 {"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T10:30:00Z","link":"https://x/actions/runs/200/job/2"}
]'
OUT="$(run_scope "$STALE")"
if jq -e '[.[] | select(.name == "CI Required" and .state == "EXPECTED")] | length == 1' >/dev/null <<<"$OUT"; then
  pass "an aggregate pointing at a superseded run is held pending"
else
  fail "an aggregate pointing at a superseded run is held pending (got $OUT)"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
