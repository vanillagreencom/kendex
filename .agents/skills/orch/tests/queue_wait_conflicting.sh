#!/usr/bin/env bash
# Regression tests for queue-wait's `conflicting` verdict (KEN-837), split
# from queue_wait.sh at the seam its fixture stub draws (the poll/verdict
# suites and their sequenced stub live there).
#
# The failure this closes: a PR whose head conflicts with its base is armed
# and stays armed. Nothing ejects it, nothing disarms it, and the watch
# reported it "still queued, still progressing" until the deadline — the arm
# flag read as the merge verdict. GitHub's own `mergeable` says CONFLICTING
# from the first poll, and the fix is a restack, not another CI cycle.
#
# Covered:
#   1. CONFLICTING routes the conflicting verdict, cause base_conflict
#   2. it is confirmed across polls like every other terminal verdict
#   3. it outranks ejected, whose recovery would be a CI cycle
#   4. MERGEABLE and UNKNOWN route nothing
#   5. state is read first: a merged PR never reports conflicting
#   6. the human-readable line names the verdict and the remedy
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

dump_stderr() {
  local file="$1"
  [[ -n "$file" && -f "$file" ]] || return 0
  printf '        stderr:\n'
  sed 's/^/          /' "$file"
}

assert_eq() {
  local got="$1" want="$2" name="$3" stderr_file="${4:-}"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
    dump_stderr "$stderr_file"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3" stderr_file="${4:-}"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
    dump_stderr "$stderr_file"
  fi
}

# Whole-line match, for the --help rows below. Both `conflicting` and
# `base_conflict` occur in --help prose and in the cause list, so a substring
# assertion on either word passes with the verdict's own row deleted.
assert_matches() {
  local haystack="$1" pattern="$2" name="$3"
  if grep -qE -- "$pattern" <<<"$haystack"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted line matching: %s\n        in: %s\n' "$name" "$pattern" "$haystack"
  fi
}

mkdir -p "$TMP_ROOT/repo/.agents/skills" "$TMP_ROOT/bin" "$TMP_ROOT/seq"
ln -s "$REPO_ROOT/skills/orch" "$TMP_ROOT/repo/.agents/skills/orch"

# Sequenced `gh` stub, one poll per numbered fixture:
#   $STUB_SEQ_DIR/state-<n>.json   `pr view --json state,mergedAt,mergeable`
#                                  (matched EXACTLY: see _args_have below)
#   $STUB_SEQ_DIR/queue-<n>.json   queue-membership GraphQL body
# `<prefix>-last.json` serves every poll past the last numbered fixture.
# Review-thread reads answer with an empty set so the late-findings guard
# stays quiet; no case here exercises it.
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

_next() {
  local f="$STUB_SEQ_DIR/$1.count" n=0
  [[ -f "$f" ]] && n="$(cat "$f")"
  n=$((n + 1))
  printf '%s' "$n" > "$f"
  printf '%s' "$n"
}

_emit_fixture() {
  local prefix="$1" n="$2" f
  f="$STUB_SEQ_DIR/$prefix-$n.json"
  [[ -f "$f" ]] || f="$STUB_SEQ_DIR/$prefix-last.json"
  if [[ ! -f "$f" ]]; then
    printf 'stub: no fixture for %s-%s\n' "$prefix" "$n" >&2
    exit 1
  fi
  cat "$f"
  exit 0
}

_args_have_sub() {
  local needle="$1" a
  shift
  for a in "$@"; do
    [[ "$a" == *"$needle"* ]] && return 0
  done
  return 1
}

# Exact, for the field list itself. Every verdict here is routed off a field
# the query names, so a substring match would serve the fixture whatever was
# asked for and a dropped field would read as empty with the suite green.
_args_have() {
  local needle="$1" a
  shift
  for a in "$@"; do
    [[ "$a" == "$needle" ]] && return 0
  done
  return 1
}

case "${1:-}" in
  auth) [[ "${2:-}" == "status" ]] && { echo "Logged in"; exit 0; } ;;
  repo) [[ "${2:-}" == "view" ]] && { echo "owner/repo"; exit 0; } ;;
  api)
    if [[ "${2:-}" == "graphql" ]]; then
      if _args_have_sub "reviewThreads" "$@"; then
        echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
        exit 0
      fi
      _emit_fixture queue "$(_next graphql)"
    fi
    if [[ "${2:-}" == "user" ]]; then echo "test-user"; exit 0; fi
    ;;
  pr)
    if [[ "${2:-}" == "view" ]]; then
      if _args_have "state,mergedAt,mergeable" "$@"; then
        _emit_fixture state "$(_next prview)"
      fi
      echo "CLEAN"
      exit 0
    fi
    ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$TMP_ROOT/bin/gh"

SEQ_DIR=""
new_case() {
  SEQ_DIR="$TMP_ROOT/seq/$1"
  rm -rf -- "${SEQ_DIR:?}"
  mkdir -p "$SEQ_DIR"
}

write_fixture() { # <prefix> <n|last> <json>
  printf '%s' "$3" > "$SEQ_DIR/$1-$2.json"
}

pr_state() { # <state> <mergeable>
  printf '{"state":"%s","mergedAt":%s,"mergeable":"%s"}' \
    "$1" "$([[ "$1" == "MERGED" ]] && echo '"2026-07-24T10:00:00Z"' || echo null)" "$2"
}

q_in_queue='{"data":{"repository":{"pullRequest":{"id":"PR_node1","isInMergeQueue":true,"mergeQueueEntry":{"state":"QUEUED"},"autoMergeRequest":{"enabledAt":"2026-07-24T09:00:00Z"}}}}}'
q_out='{"data":{"repository":{"pullRequest":{"id":"PR_node1","isInMergeQueue":false,"mergeQueueEntry":null,"autoMergeRequest":null}}}}'
q_armed_only='{"data":{"repository":{"pullRequest":{"id":"PR_node1","isInMergeQueue":false,"mergeQueueEntry":null,"autoMergeRequest":{"enabledAt":"2026-07-24T09:00:00Z"}}}}}'

run_queue_wait() {
  local env_args=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    env_args+=("$1")
    shift
  done
  shift || true
  (cd "$TMP_ROOT/repo" \
    && PATH="$TMP_ROOT/bin:$PATH" \
       env STUB_SEQ_DIR="$SEQ_DIR" \
           QUEUE_WAIT_CONFIRM_POLLS=2 \
           QUEUE_WAIT_ARM_GRACE=120 \
           QUEUE_WAIT_PROBE_INTERVAL=0 \
           "${env_args[@]}" \
           .agents/skills/orch/scripts/queue-wait "$@")
}

echo "=== queue-wait conflicting verdict (KEN-837) ==="

# --- 1. an armed, queued PR whose head conflicts with the base -------------
# The shape that used to run out the clock as "still queued, still
# progressing": nothing ejects it and nothing disarms it.
new_case conflicting
write_fixture state last "$(pr_state OPEN CONFLICTING)"
write_fixture queue last "$q_in_queue"
err="$TMP_ROOT/e1"
out="$(run_queue_wait -- 1 1 20 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "1" "conflicting exits 1" "$err"
assert_eq "$(jq -r .verdict <<<"$out")" "conflicting" "CONFLICTING routes the conflicting verdict" "$err"
assert_eq "$(jq -r .status <<<"$out")" "complete" "conflicting is a complete status, not a timeout" "$err"
assert_eq "$(jq -r .cause <<<"$out")" "base_conflict" "conflicting names its cause" "$err"

# --- 2. confirmed across polls, like every other terminal verdict ----------
# A single CONFLICTING read between two clean ones is GitHub recomputing, not
# a conflict: at a two-poll confirmation it never reaches a verdict, and the
# wait keeps running rather than sending a lane into a restack it does not
# need. QUEUE_WAIT_CONFIRM_POLLS is passed here rather than inherited, so a
# change to run_queue_wait's shared default cannot quietly void the case.
new_case conflicting_blip
write_fixture state 1 "$(pr_state OPEN MERGEABLE)"
write_fixture state 2 "$(pr_state OPEN CONFLICTING)"
write_fixture state last "$(pr_state OPEN MERGEABLE)"
write_fixture queue last "$q_in_queue"
err="$TMP_ROOT/e2"
out="$(run_queue_wait QUEUE_WAIT_CONFIRM_POLLS=2 -- 1 1 4 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$(jq -r .verdict <<<"$out")" "queued" "a one-poll CONFLICTING blip is not a conflict" "$err"

# --- 3. it outranks ejected ------------------------------------------------
# A conflicting PR that also left the queue is not a CI problem: routing it
# to `ejected` sends the caller into ci-fix for a failure CI never had.
new_case conflicting_outranks_ejected
write_fixture state last "$(pr_state OPEN CONFLICTING)"
write_fixture queue 1 "$q_in_queue"
write_fixture queue last "$q_out"
err="$TMP_ROOT/e3"
out="$(run_queue_wait -- 1 1 20 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$(jq -r .verdict <<<"$out")" "conflicting" "a conflicting PR out of the queue is conflicting, not ejected" "$err"
assert_eq "$(jq -r .was_in_merge_queue <<<"$out")" "true" "the queue memory it outranks is still recorded" "$err"

# --- 4. every other mergeable value routes nothing -------------------------
# UNKNOWN is what GitHub reports while it recomputes; routing on it would
# restack a branch that merges fine.
new_case mergeable_unknown
write_fixture state last "$(pr_state OPEN UNKNOWN)"
write_fixture queue last "$q_armed_only"
err="$TMP_ROOT/e4"
out="$(run_queue_wait -- 1 1 3 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$(jq -r .verdict <<<"$out")" "queued" "UNKNOWN mergeable routes nothing" "$err"

new_case mergeable_clean
write_fixture state last "$(pr_state OPEN MERGEABLE)"
write_fixture queue 1 "$q_armed_only"
write_fixture queue last "$q_out"
err="$TMP_ROOT/e4b"
out="$(run_queue_wait -- 1 1 20 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$(jq -r .verdict <<<"$out")" "disarmed" "a MERGEABLE PR still routes disarm on its own signal" "$err"

# --- 5. state is read first ------------------------------------------------
# `mergeable` settles at a stale value once a PR merges; the merged exit must
# never lose to it.
new_case merged_beats_mergeable
write_fixture state last "$(pr_state MERGED CONFLICTING)"
write_fixture queue last "$q_in_queue"
err="$TMP_ROOT/e5"
out="$(run_queue_wait -- 1 1 10 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "a merged PR still exits 0" "$err"
assert_eq "$(jq -r .verdict <<<"$out")" "merged" "a merged PR is merged whatever mergeable says" "$err"

# --- 6. the human-readable line ------------------------------------------
new_case conflicting_text
write_fixture state last "$(pr_state OPEN CONFLICTING)"
write_fixture queue last "$q_in_queue"
err="$TMP_ROOT/e6"
out="$(run_queue_wait -- 1 1 20 --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_contains "$out" "conflicting" "the plain line names the verdict" "$err"
assert_contains "$out" "restacked" "the plain line names the remedy" "$err"

# The --help heredoc is the semantics reference other documents point at
# instead of restating a verdict list, so deleting a row here strands them.
# The row assertion is anchored on the row, so deleting it cannot pass on the
# word appearing in the prose above. The ranking is a sentence, matched
# against a whitespace-flattened copy: it wraps mid-clause in the heredoc,
# and anchoring on a wrap point would break on any reflow of a rule that
# survived it.
help_out="$(run_queue_wait -- --help 2>/dev/null)"
help_flat="$(tr '\n' ' ' <<<"$help_out" | tr -s ' ')"
assert_matches "$help_out" '^  conflicting mergeable == "CONFLICTING": the head conflicts with the base\.$' \
  "--help carries the conflicting verdict as a row of its § Verdicts block"
assert_matches "$help_flat" 'this outranks ejected and disarmed — the fix is a restack, not a CI cycle\.' \
  "the row states the ranking that keeps a conflict out of the recovery cycle"
assert_matches "$help_out" '# only when known: base_conflict \|$' \
  "--help carries its cause in the cause list, not only in prose"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
