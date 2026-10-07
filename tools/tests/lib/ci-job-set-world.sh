#!/usr/bin/env bash
# The world both tools/ci-job-set suites start from: tools/ci-job-set run
# over this checkout or a fixture one, and the lane lines, records and
# runner lists either suite reads, some by one suite alone.
# tools/tests/ci-class-job-set.test.sh asserts those lines against the
# script; tools/tests/ci-aggregate.test.sh evaluates
# .github/workflows/skill-tests.yml against them. Sourced after the suite's
# `set -euo pipefail` and git-variable preamble; what a suite reads from here:
#   ROOT, JOB_SET, TMP       this checkout, the script, the suite's scratch
#   selection CLASS DOCS PATHS
#                            the lane lines, blank-separated, or the refusal
#                            key; SELECT_IN, SELECT_WITH, SELECT_EVENT,
#                            SELECT_PROOF and SELECT_ARG steer it (see
#                            below)
#   record EVENT CLASS DOCS PATH...
#                            a proving run's record, its lines joined with
#                            commas
#   lanes / measured         a measured row's lanes, and with its shards
#   ROSTER, ORCH             the whole shard roster, and orch's shards
#   QUEUE_ALL                the queue's three macOS shards, in order
#   LINUX, MACOS, BOTH       the runner lists, as ci-job-set spells them
#   ALL_ON, ALL_OFF, VERIFY_ROW, PROSE_ROW, CODE_ROW, UI_ROW,
#   ORCH_CODE_ROW, ORCH_PROOF_ROW, SOURCE_PROOF_ROW
#                            the rows, each described where it is set
#   queue_only_of PATH       the queue-only line harness-ci's change-class
#                            prints for a diff touching PATH alone
#   ok / bad / check         the tally in PASS and FAIL
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
JOB_SET="$ROOT/tools/ci-job-set"

mkdir -p "$ROOT/tmp"
TMP="$(mktemp -d)" || { echo "suite: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP && ! -L $TMP ]] || { echo "suite: scratch=not-a-directory" >&2; exit 1; }
TMP="$(cd -- "$TMP" && pwd -P)" || { echo "suite: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { # DESC EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

# ci-job-set reads the Rust source of the checkout it runs in: this one,
# unless SELECT_IN names another; SELECT_WITH names a copy to run instead.
# SELECT_EVENT is the event, pull_request unless set, and SELECT_PROOF the
# proving run's record, none unless set. SELECT_ARG is the one argument
# passed, none unless set; the workflow's changes job passes --event-parity.
selection() { # CLASS DOCS_ONLY PATHS — the lane lines, blank-separated, or the refusal key
  local class="$1" docs="$2" paths="$3" out="$TMP/selection" status=0 arg="${SELECT_ARG:-}"
  : >"$out"
  (cd "${SELECT_IN:-$ROOT}" && CHANGE_CLASS="$class" DOCS_ONLY="$docs" CHANGED_PATHS="$paths" \
    EVENT="${SELECT_EVENT-pull_request}" PROOF_RECORD="${SELECT_PROOF:-}" \
    PATCH_ID="${SELECT_PATCH_ID:-}" MACOS_PROOF_RECORD="${SELECT_MACOS_PROOF:-}" \
    GITHUB_OUTPUT="$out" "${SELECT_WITH:-$JOB_SET}" ${arg:+"$arg"} 2>"$TMP/selection-err") || status=$?
  if [ "$status" -ne 0 ]; then
    printf 'exit=%s %s' "$status" \
      "$(sed -n 's/^ci-job-set: cause=//p' "$TMP/selection-err" | head -1)"
    return 0
  fi
  tr '\n' ' ' <"$out" | sed 's/ $//'
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

# The record is the change-class action's: the run's event, class, docs
# verdict and paths, over which ci-job-set's own rules say what that run ran.
record() { # EVENT CLASS DOCS PATH... — a proving run's record, its lines joined with commas
  local event="$1" class="$2" docs="$3" path
  shift 3
  printf 'tree=t1,workflow=.github/workflows/skill-tests.yml,event=%s,change_class=%s,docs_only=%s,covers=all' \
    "$event" "$class" "$docs"
  for path in "$@"; do printf ',changed_path=%s' "$path"; done
}

# The whole shard roster, in the matrix's order.
ROSTER='["review-gate","orch-terminal","orch-oversee","orch-oversee-succeed","orch-state","orch-rest","guards-scans","guards-commit","guards-hooks","guards-tools","guards-tools-tail","linear","linear-controls","worktree","rest","slack","node","pi-claude-bridge"]'
ORCH='"orch-terminal","orch-oversee","orch-oversee-succeed","orch-state","orch-rest"'
# The shards a merge group runs on macOS, the whole queue_macos_shards list.
QUEUE_ALL='["orch-terminal","orch-oversee-succeed","guards-tools"]'
# The runner lists the shell shards expand on, as ci-job-set spells them.
LINUX='["ubuntu-latest"]'
MACOS='["macos-latest"]'
BOTH='["ubuntu-latest","macos-latest"]'
ALL_OFF="shell_shards=false shell_os=[] ui=false bot_instructions=false cargo_linux=false cargo_macos=false cargo_lint=false cargo_windows=false cargo_windows_check=false shards=[] queue_macos_shards=[]"
ALL_ON="shell_shards=true shell_os=$BOTH ui=true bot_instructions=true cargo_linux=true cargo_macos=true cargo_lint=true cargo_windows=true cargo_windows_check=true shards=$ROSTER queue_macos_shards=$QUEUE_ALL"
# `render` and `trivial` run the one verify job.
VERIFY_ROW="shell_shards=false shell_os=[] ui=false bot_instructions=true cargo_linux=false cargo_macos=false cargo_lint=false cargo_windows=false cargo_windows_check=false shards=[] queue_macos_shards=[]"
# Every measured class runs cargo_linux and bot_instructions. The shell
# shards run per package, on the runners LEGS names: none, linux, both, or
# macos alone where a proof stood the Linux legs down; the platform lanes
# stand down only on an all-prose diff, the macOS legs also where no shard
# runs, the compile lanes where no build input changed, and ui off ui/.
lanes() { # LEGS UI PLATFORM BUILD — a measured row's lanes
  local shell=true os
  case "$1" in
    none) shell=false os='[]' ;;
    linux) os="$LINUX" ;;
    both) os="$BOTH" ;;
    macos) os="$MACOS" ;;
    *) echo "no legs named $1" >&2; exit 1 ;;
  esac
  printf 'shell_shards=%s shell_os=%s ui=%s bot_instructions=true cargo_linux=true cargo_macos=%s cargo_lint=%s cargo_windows=%s cargo_windows_check=%s' \
    "$shell" "$os" "$2" "$3" "$4" "$3" "$4"
}
measured() { # LEGS UI PLATFORM BUILD SHARDS QUEUE — one measured row
  printf '%s shards=%s queue_macos_shards=%s' "$(lanes "$1" "$2" "$3" "$4")" "$5" "$6"
}
# The selections tools/tests/ci-aggregate.test.sh evaluates the workflow
# against, on either event.
PROSE_ROW="$(measured none false false false '[]' '[]')"
CODE_ROW="$(measured none false true false '[]' '[]')"
UI_ROW="$(measured none true true false '[]' '[]')"
ORCH_SHARDS="[$ORCH,\"guards-scans\",\"rest\"]"
ORCH_CODE_ROW="$(measured both false true false "$ORCH_SHARDS" '["orch-terminal","orch-oversee-succeed"]')"
# Two proof selections over this tree: a merge group of an orch code diff
# whose tree proof is a pull request run over orch's prose alone, and one
# of a .github prose diff whose pull request ran over the same paths.
# Groups ignore both tree proofs and retain their integrated lanes.
# tools/tests/ci-class-job-set.test.sh holds each to what the selection must
# be.
ORCH_PROOF_ROW="$(SELECT_EVENT=merge_group SELECT_PROOF="$(record pull_request micro false skills/orch/SKILL.md | tr ',' '\n')" selection micro false skills/orch/scripts/lanes)"
SOURCE_PROOF_ROW="$(SELECT_EVENT=merge_group SELECT_PROOF="$(record pull_request micro false .github/AGENTS.md skills/orch/scripts/lanes | tr ',' '\n')" selection micro false "$(printf '%s\n' .github/AGENTS.md skills/orch/scripts/lanes)")"

PATCH_PROOF_ROW="$(SELECT_EVENT=merge_group SELECT_PATCH_ID=p1 SELECT_MACOS_PROOF="$(record pull_request micro false skills/orch/scripts/lanes | tr ',' '\n')
patch_id=p1
macos_patch=true" selection micro false skills/orch/scripts/lanes)"
