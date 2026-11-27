#!/usr/bin/env bash
# The world both tools/ci-job-set suites start from: tools/ci-job-set run
# over this checkout or a fixture one, and the lane lines and runner lists
# either suite reads, some by one suite alone.
# tools/tests/ci-class-job-set.test.sh asserts those lines against the
# script; tools/tests/ci-aggregate.test.sh evaluates
# .github/workflows/skill-tests.yml against them; tools/tests/ci-reach.test.sh
# reads ROOT, TMP and the tally alone. Sourced after the suite's
# `set -euo pipefail` and git-variable preamble; what a suite reads from here:
#   ROOT, JOB_SET, TMP       this checkout, the script, the suite's scratch
#   selection CLASS DOCS PATHS
#                            the lane lines, blank-separated, or the refusal
#                            key; SELECT_IN, SELECT_WITH, SELECT_EVENT
#                            and SELECT_ARG steer it (see below)
#   lanes / measured         a measured row's lanes, and with its shards
#   ROSTER, ORCH             the whole shard roster, and orch's shards
#   QUEUE_ALL                the whole macOS-capable roster, in order
#   macos_shards SHARDS       SHARDS less the selector's Linux-only shards
#   LINUX, BOTH              the runner lists, as ci-job-set spells them
#   ALL_ON, ALL_OFF, VERIFY_ROW, PROSE_ROW, CODE_ROW, UI_ROW,
#   ORCH_CODE_ROW
#                            the rows, each described where it is set
#   queue_only_of PATH       the queue-only line harness-ci's change-class
#                            prints for a diff touching PATH alone
#   ok / bad / check         the tally in PASS and FAIL
#   row_spawn / rows_join    rows run beside each other, and their tally
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
JOB_SET="$ROOT/tools/ci-job-set"

TMP="$(mktemp -d)" || { echo "suite: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP && ! -L $TMP ]] || { echo "suite: scratch=not-a-directory" >&2; exit 1; }
TMP="$(cd -- "$TMP" && pwd -P)" || { echo "suite: scratch=resolve-failed" >&2; exit 1; }
trap 'rows_reap; rm -rf -- "${TMP:?}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { # DESC EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

# Each tools/ci-job-set call reads the whole checkout on one core, so a
# suite of a hundred calls in line outlasts its shard. Rows that write no
# file another row reads run beside each other, as many as there are
# cores: row_spawn starts COMMAND in the background with its own output and
# tally, and rows_join waits for every row spawned, prints each one's lines
# in spawn order and adds its tally to PASS and FAIL. A row that stops
# before its tally stops the suite, as it would have in line. Inside a row
# ROW_TAG names its own scratch files, empty outside one.
ROW_JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null)" || ROW_JOBS=1
case "$ROW_JOBS" in '' | *[!0-9]* | 0) ROW_JOBS=1 ;; esac
ROW_TAG=""
ROW_PIDS=()
ROW_STATUS=()
ROW_FIRST=0 ROW_NEXT=0 ROW_REAPED=0
row_wait() { # the oldest row still running
  local status=0
  wait "${ROW_PIDS[ROW_REAPED]}" || status=$?
  ROW_STATUS[ROW_REAPED]=$status
  ROW_REAPED=$((ROW_REAPED + 1))
}
rows_reap() {
  while [ "$ROW_REAPED" -lt "$ROW_NEXT" ]; do row_wait; done
}
row_spawn() { # COMMAND [ARG...]
  local n=$ROW_NEXT
  [ $((n - ROW_REAPED)) -lt "$ROW_JOBS" ] || row_wait
  (
    PASS=0 FAIL=0 ROW_TAG=".row$n"
    "$@"
    printf '%s %s\n' "$PASS" "$FAIL" >"$TMP/row$n.tally"
  ) >"$TMP/row$n.out" 2>&1 &
  ROW_PIDS[n]=$!
  ROW_NEXT=$((n + 1))
}
rows_join() {
  local n pass fail
  rows_reap
  for ((n = ROW_FIRST; n < ROW_NEXT; n++)); do
    cat "$TMP/row$n.out"
    if [ "${ROW_STATUS[n]}" -ne 0 ] || ! read -r pass fail <"$TMP/row$n.tally"; then
      echo "suite: row=$n status=${ROW_STATUS[n]} cause=untallied" >&2
      exit 1
    fi
    PASS=$((PASS + pass)) FAIL=$((FAIL + fail))
  done
  ROW_FIRST=$ROW_NEXT
}

# One unrelated suite from each shard whose workflow steps use checkout kendex.
checkout_suites_skipped() {
  jq '(["refresh/tests/refresh-report.test.sh", "skills/orch/tests/one_job.sh",
        "skills/project-management/tests/verification-scope.test.sh", "skills/jarvis/tests/task.test.sh"] - .) | 4 - length'
}

# ci-job-set reads the Rust source of the checkout it runs in: this one,
# unless SELECT_IN names another; SELECT_WITH names a copy to run instead.
# SELECT_EVENT is the event, pull_request unless set. SELECT_ARG is the
# arguments passed, blank-separated, none unless set; the workflow's changes
# job passes --event-parity --runtime-publish. The `cargo_linux_matrix=` and
# `jobs=` lines are left out unless SELECT_CARGO_MATRIX or SELECT_JOBS is
# true.
selection() { # CLASS DOCS_ONLY PATHS — the lane lines, blank-separated, or the refusal key
  local class="$1" docs="$2" paths="$3" out="$TMP/selection$ROW_TAG" err="$TMP/selection-err$ROW_TAG" status=0 arg="${SELECT_ARG:-}"
  : >"$out"
  # shellcheck disable=SC2086 # one argument per word
  (cd "${SELECT_IN:-$ROOT}" && CHANGE_CLASS="$class" DOCS_ONLY="$docs" CHANGED_PATHS="$paths" \
    EVENT="${SELECT_EVENT-pull_request}" GITHUB_OUTPUT="$out" "${SELECT_WITH:-$JOB_SET}" $arg 2>"$err") || status=$?
  if [ "$status" -ne 0 ]; then
    printf 'exit=%s %s' "$status" \
      "$(sed -n 's/^ci-job-set: cause=//p' "$err" | head -1)"
    return 0
  fi
  local drop=""
  [ "${SELECT_CARGO_MATRIX:-}" = true ] || drop='/^cargo_linux_matrix=/d;'
  [ "${SELECT_JOBS:-}" = true ] || drop="$drop/^jobs=/d;"
  sed "$drop" "$out" | tr '\n' ' ' | sed 's/ $//'
}

# The classifier this checkout ships, run over a fixture repository whose one
# commit past an empty base touches PATH alone. Prints the value of its
# `queue-only:` line; prints nothing where the fixture or the run failed.
queue_only_of() { # PATH
  local repo base
  repo="$(mktemp -d "$TMP/queue.XXXXXX")" || return 1
  git -C "$repo" init -q -b main || return 1
  git -C "$repo" -c user.email=ci-job-set@example.invalid -c user.name=ci-job-set \
    commit -q --allow-empty -m base || return 1
  base="$(git -C "$repo" rev-parse HEAD)" || return 1
  mkdir -p -- "$repo/$(dirname -- "$1")" && printf 'x\n' >"$repo/$1" || return 1
  git -C "$repo" add -A || return 1
  git -C "$repo" -c user.email=ci-job-set@example.invalid -c user.name=ci-job-set \
    commit -q -m head || return 1
  "$ROOT/skills/harness-ci/scripts/change-class" --repo "$repo" --event pull_request \
    --base "$base" --head HEAD 2>"$repo.err" >/dev/null || return 1
  sed -n 's/^queue-only: //p' "$repo.err"
}

# The whole shard roster, in the matrix's order.
ROSTER='["review-gate","refresh","orch-state","orch-rest","guards-scans","guards-commit","guards-commit-tail","guards-hooks","guards-hooks-tail","guards-tools","guards-tools-tail","linear","linear-controls","worktree","worktree-restack","rest","jarvis","slack","mailbox","node","pi-claude-bridge"]'
ORCH='"orch-state","orch-rest"'
# The expected queue list comes from each row's shards, with the platform
# exclusions held to the workflow by orch-shard-partition.test.sh.
macos_shards() { # SHARDS: the macOS-capable members in the same order
  local excluded
  excluded="$("$ROOT/tools/macos-test-contracts" --linux-only-shards | jq -Rc 'split(" ")')" || return 1
  jq -ce --argjson excluded "$excluded" '[.[] | select(. as $shard | $excluded | index($shard) | not)]' <<<"$1"
}
QUEUE_ALL="$(macos_shards "$ROSTER")"
# The runner lists the shell shards expand on, as ci-job-set spells them.
LINUX='["ubuntu-latest"]'
BOTH='["ubuntu-latest","macos-latest"]'
ALL_OFF="shell_shards=false shell_os=[] ui=false bot_instructions=false cargo_linux=false cargo_macos=false cargo_lint=false cargo_windows=false cargo_windows_check=false catalog=false smoke=false shards=[] queue_macos_shards=[] skipped_suites=[]"
ALL_ON="shell_shards=true shell_os=$BOTH ui=true bot_instructions=true cargo_linux=true cargo_macos=true cargo_lint=true cargo_windows=true cargo_windows_check=true catalog=true smoke=true shards=$ROSTER queue_macos_shards=$QUEUE_ALL skipped_suites=[] rust_targets=[\"agent-runtime/*\",\"orch/*\"]"
# `render` and `trivial` run the one verify job and skip every suite, none
# in the fixture checkouts the row is read in.
VERIFY_ROW="shell_shards=false shell_os=[] ui=false bot_instructions=true cargo_linux=false cargo_macos=false cargo_lint=false cargo_windows=false cargo_windows_check=false catalog=false smoke=false shards=[] queue_macos_shards=[] skipped_suites=[] rust_targets=[]"
# Every measured class runs cargo_linux and bot_instructions. The shell
# shards run per package, on the runners LEGS names: none, linux or both;
# the platform lanes stand down only on an all-prose or skill Markdown
# diff, the macOS legs
# also where no shard runs, the compile lanes where no build input changed,
# and ui off ui/.
lanes() { # LEGS UI PLATFORM BUILD [CATALOG] — a measured row's lanes
  local shell=true os
  case "$1" in
    none) shell=false os='[]' ;;
    linux) os="$LINUX" ;;
    both) os="$BOTH" ;;
    *) echo "no legs named $1" >&2; exit 1 ;;
  esac
  printf 'shell_shards=%s shell_os=%s ui=%s bot_instructions=true cargo_linux=true cargo_macos=%s cargo_lint=%s cargo_windows=%s cargo_windows_check=%s catalog=%s smoke=%s' \
    "$shell" "$os" "$2" "$3" "$4" "$3" "$4" "${5:-$4}" "${5:-$4}"
}
measured() { # LEGS UI PLATFORM BUILD SHARDS QUEUE [CATALOG [RUST]] — one measured row, in a world with no suite
  printf '%s shards=%s queue_macos_shards=%s skipped_suites=[] rust_targets=%s' "$(lanes "$1" "$2" "$3" "$4" "${7:-$4}")" "$5" "$6" "${8:-[]}"
}
# The selections tools/tests/ci-aggregate.test.sh evaluates the workflow
# against.
PROSE_ROW="$(measured none false false false '[]' '[]')"
CODE_ROW="$(measured none false true false '[]' '[]')"
UI_ROW="$(measured none true true false '[]' '[]')"
ORCH_SHARDS="[$ORCH,\"guards-scans\",\"rest\"]"
ORCH_CODE_ROW="$(measured both false true false "$ORCH_SHARDS" "$(macos_shards "$ORCH_SHARDS")" true '["orch/lib"]')"
