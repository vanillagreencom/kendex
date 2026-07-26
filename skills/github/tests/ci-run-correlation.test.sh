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

echo "=== vstack#876 reported shape (documents CURRENT behaviour, not a fix) ==="

# The reported rollup: a completed substantive run whose required aggregate
# passed, plus a SECOND same-head run of the same workflow whose jobs came back
# as zero-second failures/cancellations.
#
# Scoping alone does NOT drop that second run: a run full of failures counts as
# substantive (it has non-skipped checks), so it wins on run id. `pr-merge
# --check` therefore still reports ci_failed while the required aggregate is
# green — which is exactly the disagreement #876 describes, and it is NOT
# resolved by unifying the scoping. This assertion exists so that is recorded as
# known behaviour rather than assumed fixed; a change that makes the second run
# lose should update this test deliberately.
DUP='[
 {"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T10:00:00Z","link":"https://x/actions/runs/30201726860/job/1"},
 {"name":"CI Required","state":"SUCCESS","bucket":"pass","workflow":"","startedAt":"2026-07-26T10:05:00Z","link":"https://x/actions/runs/30201726860"},
 {"name":"CI Gate Publisher","state":"FAILURE","bucket":"fail","workflow":"CI","startedAt":"2026-07-26T10:06:00Z","link":"https://x/actions/runs/30201902682/job/9"},
 {"name":"build","state":"CANCELLED","bucket":"cancel","workflow":"CI","startedAt":"2026-07-26T10:06:00Z","link":"https://x/actions/runs/30201902682/job/10"}
]'
OUT="$(run_scope "$DUP")"
if jq -e '[.[] | select(.state == "FAILURE" or .state == "CANCELLED")] | length == 2' >/dev/null <<<"$OUT"; then
  pass "the second same-head run's failures still survive scoping (#876 remains open)"
else
  fail "the second same-head run's failures still survive scoping (#876 remains open)"
fi
if jq -e '[.[] | select(.name == "CI Required" and .state == "SUCCESS")] | length == 1' >/dev/null <<<"$OUT"; then
  pass "the required aggregate stays green alongside those failures"
else
  fail "the required aggregate stays green alongside those failures"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
