# shellcheck shell=bash
#
# The sequenced world queue_wait_confirmation.sh and queue_wait_conflicting.sh
# drive queue-wait in: a `gh` stub that answers one poll per numbered fixture,
# the virtual clock, and `run_queue_wait`. queue_wait.sh keeps its own, wider
# stub.
#
# Sourced, never run. The caller sets TEST_DIR, REPO_ROOT and TMP_ROOT first;
# sourcing builds $TMP_ROOT/repo with orch installed, puts the stub and the
# clock under $TMP_ROOT/bin, and defines new_case, write_fixture, the q_*
# queue bodies and run_queue_wait.
#
# The stub, one poll per numbered fixture:
#   $STUB_SEQ_DIR/state-<n>.json   `pr view --json state,mergedAt,mergeable`
#                                  (matched EXACTLY: see _args_have below)
#   $STUB_SEQ_DIR/queue-<n>.json   queue-membership GraphQL body
# `<prefix>-last.json` serves every poll past the last numbered fixture.
# Review-thread reads answer with an empty set so the late-findings guard
# stays quiet; no case exercises it. `gh pr checks` and the Actions-run read
# belong to the real ci-wait the failed-check probe delegates to:
# STUB_PR_CHECKS_MODE=failure is what lets that probe reach a verdict at all.
# STUB_QUEUE_DELAY makes the queue read itself cost that many seconds on the
# clock, the production condition under which a confirmation count outlasts
# the budget however short the gaps are made.

mkdir -p "$TMP_ROOT/repo/.agents/skills" "$TMP_ROOT/bin" "$TMP_ROOT/seq"
ln -s "$REPO_ROOT/skills/orch" "$TMP_ROOT/repo/.agents/skills/orch"

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

# Exact, for the field list itself. Every verdict is routed off a field the
# query names, so a substring match would serve the fixture whatever was
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
      [[ -n "${STUB_QUEUE_DELAY:-}" ]] && sleep "$STUB_QUEUE_DELAY"
      _emit_fixture queue "$(_next graphql)"
    fi
    if [[ "${2:-}" == "user" ]]; then echo "test-user"; exit 0; fi
    if [[ "${2:-}" == repos/*/actions/runs* ]]; then echo '{"workflow_runs":[]}'; exit 0; fi
    ;;
  pr)
    if [[ "${2:-}" == "view" ]]; then
      if _args_have "state,mergedAt,mergeable" "$@"; then
        _emit_fixture state "$(_next prview)"
      fi
      echo "CLEAN"
      exit 0
    fi
    if [[ "${2:-}" == "checks" ]]; then
      if [[ "${STUB_PR_CHECKS_MODE:-}" == "failure" ]]; then
        echo '[{"name":"build","state":"FAILURE"}]'
        exit 1
      fi
      echo '[{"name":"build","state":"SUCCESS"}]'
      exit 0
    fi
    ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$TMP_ROOT/bin/gh"

# Virtual clock, on the same PATH as the gh stub: `date +%s` reads a file the
# `sleep` stub advances, so a budget is spent in arithmetic rather than in
# real seconds, STUB_QUEUE_DELAY included. Rationale and the per-case escape
# hatch back to real time: lib/virtual-clock.sh.
# shellcheck source=virtual-clock.sh
source "$TEST_DIR/lib/virtual-clock.sh"
virtual_clock_install "$TMP_ROOT/bin" "$TMP_ROOT/clock"

SEQ_DIR=""
new_case() {
  SEQ_DIR="$TMP_ROOT/seq/$1"
  rm -rf -- "${SEQ_DIR:?}"
  mkdir -p "$SEQ_DIR"
}

write_fixture() { # <prefix> <n|last> <json>
  printf '%s' "$3" > "$SEQ_DIR/$1-$2.json"
}

q_in_queue='{"data":{"repository":{"pullRequest":{"id":"PR_node1","isInMergeQueue":true,"mergeQueueEntry":{"state":"QUEUED"},"autoMergeRequest":{"enabledAt":"2026-07-24T09:00:00Z"}}}}}'
q_out='{"data":{"repository":{"pullRequest":{"id":"PR_node1","isInMergeQueue":false,"mergeQueueEntry":null,"autoMergeRequest":null}}}}'
q_armed_only='{"data":{"repository":{"pullRequest":{"id":"PR_node1","isInMergeQueue":false,"mergeQueueEntry":null,"autoMergeRequest":{"enabledAt":"2026-07-24T09:00:00Z"}}}}}'

# run_queue_wait [ENV=VALUE...] -- ARG... — queue-wait from the fixture repo,
# on the stub PATH, with GH_REPO off so the stub's repository is the one read.
run_queue_wait() {
  local env_args=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    env_args+=("$1")
    shift
  done
  shift || true
  (cd "$TMP_ROOT/repo" \
    && PATH="$TMP_ROOT/bin:$PATH" \
       env -u GH_REPO STUB_SEQ_DIR="$SEQ_DIR" \
           QUEUE_WAIT_CONFIRM_POLLS=2 \
           QUEUE_WAIT_ARM_GRACE=120 \
           QUEUE_WAIT_PROBE_INTERVAL=0 \
           ${env_args[@]+"${env_args[@]}"} \
           .agents/skills/orch/scripts/queue-wait "$@")
}
