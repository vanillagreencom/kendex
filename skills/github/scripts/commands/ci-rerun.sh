#!/bin/bash
# Rerun a pull request's failed Actions run once, when its failed log names
# a transient runner failure.
# Usage: ci-rerun <PR_NUMBER> [--required-only] [--repo OWNER/REPO]
#
# The run is the first red check of the pull request's CURRENT run per
# workflow that links an Actions run, scoped by the shared
# scope_current_run, so a superseded run is never rerun. Under
# --required-only only a check the base branch requires counts, read from
# the same requirement evidence pr-merge --check classifies under
# (required_contexts); a required workflow that evidence reports failed
# names its bound run itself, and that run is taken before the rollup is
# read. The log is that run's failed-job log, `gh run view --log-failed`,
# judged on its first 200 lines against the pattern list in this file. A
# match is followed by one `gh run rerun RUN --failed`.
#
# This verb reruns what it is asked, on every call: the caller keeps the
# once-per-head rule in its own record, written before this verb runs.
#
# Output (stdout, one keyed line):
#   rerun run=<id> pattern=<text>  the run was rerun; <text> is the pattern
#                                  its log matched
#   no-rerun cause=<word>          nothing was rerun, because:
#     no-failed-run                no red check of the current run links an
#                                  Actions run; under --required-only, no
#                                  required workflow failed and no red the
#                                  base branch requires links one
#     not-transient                the log's first 200 lines name no pattern
#     log-unread                   gh could not read the log; an unreadable
#                                  log is not evidence of anything
#     checks-unread                gh pr checks answered no check array
#     requirements-unread          the required set could not be read
#   A gh diagnostic behind an unread answer is on stderr, prefixed
#   `ci-rerun:`.
#
# Exit codes:
#   0   a keyed line was printed
#   1   gh refused the rerun itself; stderr carries {"error": "<its line>"}
#   2   usage error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib/json-error.sh
source "$SCRIPT_DIR/../lib/json-error.sh"
# Shared with pr-merge.sh and ci-classify-refusal.sh, so this rerun and the
# merge gate cannot disagree about which run is current or which checks the
# base requires.
# shellcheck source=../lib/ci-run-correlation.sh
source "$SCRIPT_DIR/../lib/ci-run-correlation.sh"

# Log text that names a runner or network failure rather than the change
# under test, so a rerun can pass without a fix.
TRANSIENT_PATTERNS=(
  "another process is currently installing"
  "Could not install"
  "Installation failed"
  "network timeout"
  "runner error"
  "ETIMEDOUT"
  "ECONNRESET"
  "rate limit"
)
LOG_WINDOW_LINES=200

# The leading comment block is the contract, printed by shape rather than by
# line number so --help cannot drift as that block grows.
show_help() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

pr_num=""
repo=""
required_only=false
while [ $# -gt 0 ]; do
  case "$1" in
  --help | -h)
    show_help
    exit 0
    ;;
  --required-only)
    required_only=true
    shift
    ;;
  --repo)
    if [ -z "${2:-}" ]; then
      echo "Error: --repo requires OWNER/REPO" >&2
      exit 2
    fi
    repo="$2"
    shift 2
    ;;
  -*)
    echo "Error: Unknown option: $1" >&2
    exit 2
    ;;
  *)
    if [[ "$1" =~ ^[0-9]+$ ]] && [ -z "$pr_num" ]; then
      pr_num="$1"
      shift
    else
      echo "Error: expected exactly one numeric PR number, got: $1" >&2
      exit 2
    fi
    ;;
  esac
done

if [ -z "$pr_num" ]; then
  echo "Error: PR number required" >&2
  exit 2
fi

repo_arg=()
if [ -n "$repo" ]; then
  repo_arg=(--repo "$repo")
fi

# first_line FILE — the first non-blank line of a captured stderr, for a
# diagnostic that names what gh said.
first_line() {
  sed -n '/[^[:space:]]/{p;q;}' "$1" | tr -d '\r'
}

requirements='[]'
if [ "$required_only" = true ]; then
  requirements=$(required_contexts "$pr_num" "$repo") || requirements='{"state":"unreadable","contexts":[]}'
  if [ "$(jq -r '.state' <<<"$requirements")" = unreadable ]; then
    echo "no-rerun cause=requirements-unread"
    exit 0
  fi
fi

# A failed required workflow names the run itself: required_contexts binds
# the workflow's latest attempt on this head and answers its id in
# failed_runs whatever the visible rollup shows, since the workflow can fail
# while every job it registered is green. That bound run is taken before
# the rollup is read, never a job link from a second read of it.
run_id=""
if [ "$required_only" = true ]; then
  run_id=$(jq -r 'select(.state == "failed") | .failed_runs[0] // empty' <<<"$requirements")
fi

# Otherwise the first red of the current run: the scoping orders run-linked
# checks before run-less ones, so an empty id says no red of the current
# run links an Actions run. A scoping that fails leaves the rollup unread
# for this purpose.
if [ -z "$run_id" ]; then
  if ! checks=$(fetch_checks_rollup "$pr_num" "$repo"); then
    echo "no-rerun cause=checks-unread"
    exit 0
  fi
  if ! run_id=$(scope_current_run "$requirements" <<<"$checks" |
    jq -r --argjson req "$requirements" "$CI_RUN_JQ_DEFS"'
      [.[] | select(red and required_only($req)) | runid] | first // empty'); then
    printf 'ci-rerun: checks-unread: the rollup could not be scoped\n' >&2
    echo "no-rerun cause=checks-unread"
    exit 0
  fi
fi
if [ -z "$run_id" ]; then
  echo "no-rerun cause=no-failed-run"
  exit 0
fi

gh_err="$(mktemp "${TMPDIR:-/tmp}/ci-rerun.XXXXXX")" || {
  github_error "could not create a temporary file"
  exit 1
}
trap 'rm -f "$gh_err"' EXIT

# The log is captured whole and windowed in-shell, and grep reads a
# here-string, which has no producer to signal: `gh | head -200` SIGPIPEs gh
# past the 64KB pipe buffer, and pipefail reports that 141 as a read that
# failed.
if ! full_log=$(gh run view "$run_id" ${repo_arg[@]+"${repo_arg[@]}"} --log-failed 2>"$gh_err"); then
  printf 'ci-rerun: log-unread run=%s: %s\n' "$run_id" "$(first_line "$gh_err")" >&2
  echo "no-rerun cause=log-unread"
  exit 0
fi
logs=$(head -n "$LOG_WINDOW_LINES" <<<"$full_log")

matched=""
for pattern in "${TRANSIENT_PATTERNS[@]}"; do
  if grep -qiF -e "$pattern" <<<"$logs"; then
    matched="$pattern"
    break
  fi
done
if [ -z "$matched" ]; then
  echo "no-rerun cause=not-transient"
  exit 0
fi

if ! gh run rerun "$run_id" ${repo_arg[@]+"${repo_arg[@]}"} --failed >/dev/null 2>"$gh_err"; then
  github_error "gh run rerun $run_id refused: $(first_line "$gh_err")"
  exit 1
fi
echo "rerun run=$run_id pattern=$matched"
