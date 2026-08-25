#!/usr/bin/env bash
# `scope_current_run` lived in TWO places — orch `ci-wait` and github
# `pr-merge.sh` — each carrying a comment that it must stay aligned with the
# other "byte-for-byte". Nothing enforced that, and they drifted: `ci-wait` grew
# substantive-run selection and stale-status rewriting (kendex#607) while
# `pr-merge.sh` kept the original max-run-id version (kendex#492). A merge gate
# and the waiter feeding it were then scoping the same rollup by different rules
# (kendex#876).
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

# A scan target is named by path, so a rename or a typo can point it at
# nothing — and `grep -q` on a missing file exits 2, which an `if` reads as
# "no match" and reports as a clean scan. Every scan therefore answers
# `missing` first, and the matchers tolerate any whitespace the language
# allows: jq accepts `def  bucket :` as readily as `def bucket:`, and bash
# accepts `scope_current_run ()`, so a matcher pinned to one spelling makes
# the guard's coverage a matter of formatting. Both holes fail open, and a
# fail-open guard reports nothing at all.
DRIFT_DEF_RE='def[[:space:]]+(bucket|runid)[[:space:]]*:'
SCOPE_FN_RE='^scope_current_run[[:space:]]*\(\)'

# missing | local | shared
scope_target_state() {
  [[ -f "$1" ]] || { printf 'missing\n'; return; }
  if grep -qE "$SCOPE_FN_RE" "$1"; then printf 'local\n'; else printf 'shared\n'; fi
}

# missing | absent | sources
lib_source_state() {
  [[ -f "$1" ]] || { printf 'missing\n'; return; }
  if grep -q 'ci-run-correlation.sh' "$1"; then printf 'sources\n'; else printf 'absent\n'; fi
}

# missing | drift | clean
local_defs_state() {
  [[ -f "$1" ]] || { printf 'missing\n'; return; }
  if grep -qE "$DRIFT_DEF_RE" "$1"; then printf 'drift\n'; else printf 'clean\n'; fi
}

missing_target() { fail "$1 is missing at $2 (scan target moved or the path is a typo)"; }

for script in "$REPO_ROOT/skills/orch/scripts/ci-wait" \
              "$REPO_ROOT/skills/github/scripts/commands/pr-merge.sh" \
              "$REPO_ROOT/skills/github/scripts/commands/ci-classify-refusal.sh"; do
  name="$(basename "$script")"
  case "$(scope_target_state "$script")" in
    missing) missing_target "$name" "$script" ;;
    local)   fail "$name defines its own scope_current_run (drift reintroduced — source the shared library instead)" ;;
    shared)  pass "$name does not define its own scope_current_run" ;;
  esac
  case "$(lib_source_state "$script")" in
    missing) missing_target "$name" "$script" ;;
    sources) pass "$name sources the shared library" ;;
    absent)  fail "$name sources the shared library" ;;
  esac
done

# The bucket taxonomy and run-id capture are exported as CI_RUN_JQ_DEFS; a
# consumer inlining its own `def bucket`/`def runid` copy is the same drift one
# layer down. Covers orch `ci-wait` as well as the GitHub commands.
for script in "$REPO_ROOT/skills/orch/scripts/ci-wait" \
              "$REPO_ROOT"/skills/github/scripts/commands/*.sh; do
  name="$(basename "$script")"
  case "$(local_defs_state "$script")" in
    missing) missing_target "$name" "$script" ;;
    drift)   fail "$name inlines its own def bucket/def runid (prepend CI_RUN_JQ_DEFS from the shared library instead)" ;;
    clean)   pass "$name has no local def bucket/def runid copy" ;;
  esac
done

echo "=== scan guards ==="

# The scans above are only worth their green when they go red on the things
# they exist to catch. Each state function is exercised against a fixture.
FIXTURES="$(mktemp -d)"
trap 'rm -rf "$FIXTURES"' EXIT

state_is() {
  local want="$1" got="$2" what="$3"
  if [[ "$got" == "$want" ]]; then pass "$what"; else fail "$what (got $got, want $want)"; fi
}

state_is missing "$(local_defs_state "$REPO_ROOT/skills/orch/scripts/ci-waitX")" \
  "a mistyped scan path reports missing, not clean"
state_is missing "$(scope_target_state "$REPO_ROOT/skills/orch/scripts/ci-waitX")" \
  "a mistyped scope-scan path reports missing, not shared"
state_is missing "$(lib_source_state "$REPO_ROOT/skills/orch/scripts/ci-waitX")" \
  "a mistyped library-source path reports missing, not absent"

printf 'def bucket:\n' > "$FIXTURES/plain.sh"
state_is drift "$(local_defs_state "$FIXTURES/plain.sh")" "a plain def bucket copy is caught"

printf 'def  bucket :\n' > "$FIXTURES/spaced.sh"
state_is drift "$(local_defs_state "$FIXTURES/spaced.sh")" "a whitespace-variant def bucket copy is caught"

printf '  def\trunid  :\n' > "$FIXTURES/tabbed.sh"
state_is drift "$(local_defs_state "$FIXTURES/tabbed.sh")" "a tab-separated def runid copy is caught"

printf 'source lib/ci-run-correlation.sh\n' > "$FIXTURES/clean.sh"
state_is clean "$(local_defs_state "$FIXTURES/clean.sh")" "a library-sourcing script scans clean"
state_is sources "$(lib_source_state "$FIXTURES/clean.sh")" "a library-sourcing script is seen sourcing it"
state_is shared "$(scope_target_state "$FIXTURES/clean.sh")" "a library-sourcing script defines no scope_current_run"

printf 'scope_current_run () {\n  :\n}\n' > "$FIXTURES/localfn.sh"
state_is local "$(scope_target_state "$FIXTURES/localfn.sh")" "a spaced scope_current_run definition is caught"

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

echo "=== kendex#876 reported shape ==="

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
# `pr-merge --check` while `ci-wait` — already rerun-aware via kendex#699 —
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
if [[ "$(jq -r "$CI_RUN_JQ_DEFS"'head_runs | join(",")' <<<"$OUT")" == "200" ]]; then
  pass "a status held EXPECTED keeps its retired run out of head_runs"
else
  fail "a status held EXPECTED keeps its retired run out of head_runs (got $(jq -c "$CI_RUN_JQ_DEFS"'head_runs' <<<"$OUT"))"
fi

echo "=== head_runs run scope ==="

# A custom commit status linking a run of its own is first-class scope: on a
# mixed head its run id appears BESIDE the workflow's, so a status failure's
# fail: line never cites a run head-run: omits.
MIXED='[
 {"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T10:00:00Z","link":"https://x/actions/runs/100/job/1"},
 {"name":"CI Required","state":"FAILURE","bucket":"fail","workflow":"","link":"https://x/actions/runs/200"}
]'
OUT="$(run_scope "$MIXED")"
if [[ "$(jq -r "$CI_RUN_JQ_DEFS"'head_runs | join(",")' <<<"$OUT")" == "100,200" ]]; then
  pass "a mixed head names the status-linked run beside the workflow run"
else
  fail "a mixed head names the status-linked run beside the workflow run (got $(jq -c "$CI_RUN_JQ_DEFS"'head_runs' <<<"$OUT"))"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
