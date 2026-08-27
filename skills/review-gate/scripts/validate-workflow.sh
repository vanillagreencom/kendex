#!/usr/bin/env bash
# Review-gate validate — the adopted-workflow half. Shipped by the kendex
# review-gate skill and vendored into consumers at
# .agents/skills/review-gate/scripts/.
#
# `validate.sh` runs this as its last group and folds the result into its
# own; it also stands alone for anyone changing only the workflow copy.
# Everything here reads .github/workflows/ and nothing else does, which is
# the seam the two files are split on.
#
# The authoritative contract is print_usage below: run with --help.
set -euo pipefail

print_usage() {
  cat <<'USAGE'
Usage: validate-workflow.sh [--help]   (no positional arguments)

Checks that THIS repository's adopted review-gate writer workflow still
carries the template's contract: exactly one tracked workflow runs
review-writer.sh; it wires every trigger the relay/converge split needs; its
relay holds actions:write and nothing else, checks nothing out, holds no
concurrency group and refuses the converge legs; its write job holds the
single-writer group; and every checkout pins the repository default branch
with credentials dropped and no hardcoded fallback.

Output: one verdict line per check (ok / FAIL / note).

Exit codes:
  0  every check held
  1  at least one FAIL line
  2  the check could not run at all (bad arguments, not a git repository)
USAGE
}

if [ "$#" -eq 1 ] && { [ "$1" = "--help" ] || [ "$1" = "-h" ]; }; then
  print_usage
  exit 0
fi
if [ "$#" -gt 0 ]; then
  echo "validate-workflow.sh: unknown argument list ($# argument(s), first: '${1}') — no positional arguments (run --help)" >&2
  exit 2
fi

die() { # MESSAGE — the check could not run at all
  echo "::error::review-gate validate-workflow: $1" >&2
  exit 2
}

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" ||
  die "not inside a git repository — there is no tracked workflow set to read"
[ -n "$REPO_ROOT" ] || die "git named no repository root"
cd "$REPO_ROOT" || die "could not enter the repository root $REPO_ROOT"

PASS=0
FAILED=0
ok() { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
bad() { FAILED=$((FAILED + 1)); printf 'FAIL  %s\n' "$1"; }
note() { printf 'note  %s\n' "$1"; }

# grep exits 0/1 as MEASUREMENTS and anything higher as a read failure. Both
# helpers keep that distinction: under errexit a bare `grep -c` with no match
# would kill the run, and a `|| true` would launder an unreadable file into a
# count of zero.
count_matches() { # ERE FILE — match count on stdout
  local n rc=0
  n="$(grep -cE -- "$1" "$2")" || rc=$?
  [ "$rc" -le 1 ] || die "$2: unreadable while counting /$1/ (grep exit $rc)"
  printf '%s' "$n"
}

first_match() { # ERE FILE — first matching line on stdout, empty when none
  local line rc=0
  line="$(grep -m1 -E -- "$1" "$2")" || rc=$?
  [ "$rc" -le 1 ] || die "$2: unreadable while reading /$1/ (grep exit $rc)"
  printf '%s' "$line"
}

TMP="$(mktemp -d)" || die "could not create a scratch directory"
trap 'rm -rf "$TMP"' EXIT

rg_check_adopted_workflow() { # SCRATCH-DIR — verdict lines on stdout
  local tmp="$1"
  local adopted adopted_count relay writer queue key blk over relay_if missing
  local env_missing binding leg scope writer_if checkouts creds trigger wf

  # TRACKED files only: GitHub Actions runs what is committed, so an untracked
  # workflow on someone's disk is not this repo's writer.
  adopted=""
  adopted_count=0
  while IFS= read -r wf; do
    [ -n "$wf" ] && [ -f "$wf" ] || continue
    grep -q 'review-writer\.sh' "$wf" || continue
    adopted_count=$((adopted_count + 1))
    adopted="$wf"
  done <<EOF_WORKFLOWS
$(git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml')
EOF_WORKFLOWS

  if [ "$adopted_count" -eq 0 ]; then
    bad "no tracked workflow under .github/workflows/ runs review-writer.sh — nothing writes this repo's gate status; copy templates/review-gate-writer.yml in (references/adoption.md)"
  elif [ "$adopted_count" -gt 1 ]; then
    bad "$adopted_count tracked workflows run review-writer.sh — the gate has exactly one writer by design; delete the copies that are not the adopted one"
  else
    ok "one adopted writer workflow: $adopted"

    # Job blocks, split by the two-space key under `jobs:`. Everything below
    # asks its question of ONE job, because the same text means opposite
    # things in the relay and in the write job.
    awk -v dest="$tmp" '
      injobs == 0 && $0 ~ /^jobs:[[:space:]]*$/ { injobs = 1; next }
      injobs == 0 { next }
      /^[^ \t#]/ { injobs = 0; cur = ""; next }
      /^  [A-Za-z0-9_-]+:[ \t]*$/ {
        key = $0
        sub(/^  /, "", key)
        sub(/:[ \t]*$/, "", key)
        cur = dest "/job." key
        print key >> (dest "/job.keys")
        printf "" >> cur
        next
      }
      cur != "" { print >> cur }
    ' "$adopted"

    # Identified by what each job HOLDS, never by its key: a repo may rename a
    # job, and a check that silently found no job would pass every assertion
    # it was supposed to make about it.
    relay=""
    writer=""
    queue=""
    if [ -f "$tmp/job.keys" ]; then
      while IFS= read -r key; do
        [ -n "$key" ] || continue
        blk="$tmp/job.$key"
        [ -f "$blk" ] || continue
        if grep -qE '^ +actions: +write' "$blk"; then
          relay="$blk"
        fi
        if grep -qE '^ +statuses: +write' "$blk" && grep -q 'review-writer\.sh' "$blk"; then
          if grep -qF "github.event_name == 'merge_group'" "$blk"; then
            queue="$blk"
          else
            writer="$blk"
          fi
        fi
      done <"$tmp/job.keys"
    fi

    if [ -z "$relay" ]; then
      bad "$adopted has no job holding \`actions: write\` — the relay is what every PR-attached leg runs, and without it those events reach the gate only on the cron floor"
    else
      ok "the relay job is present (the only job holding actions: write)"
      over=""
      for scope in statuses contents issues checks pull-requests; do
        if grep -qE "^ +$scope: " "$relay"; then
          over="${over:+$over }$scope"
        fi
      done
      if [ -n "$over" ]; then
        bad "the relay job holds permission(s) beyond actions:write: $over — its complete scope is actions:write, and it is the one job PR-attached events reach"
      else
        ok "the relay job holds actions:write and no other permission"
      fi
      if grep -qE '^ +- uses: actions/checkout' "$relay"; then
        bad "the relay job checks out code — it runs on pull_request_target, where a checkout puts PR-controlled code under a write-capable token; the relay must check nothing out"
      else
        ok "the relay job checks nothing out"
      fi
      if grep -qE '^ +concurrency:' "$relay"; then
        bad "the relay job holds a concurrency group — an evictable relay leaves a CANCELLED check on the PR head, pinning the PR at UNSTABLE; the group belongs on the write job alone"
      else
        ok "the relay job holds no concurrency group (it can never be evicted)"
      fi
      relay_if="$(first_match '^ +if: ' "$relay")"
      if [ -z "$relay_if" ]; then
        bad "the relay job has no \`if:\` — it would run on the converge legs too, and this workflow dispatches ITSELF, so a self-dispatch loop would have no throttle"
      else
        missing=""
        for leg in merge_group workflow_dispatch schedule; do
          case "$relay_if" in
            *"!= '$leg'"*) ;;
            *) missing="${missing:+$missing }$leg" ;;
          esac
        done
        if [ -n "$missing" ]; then
          bad "the relay job's \`if:\` no longer excludes: $missing — a converge leg reaching the relay dispatches this workflow into itself, and the relay holds no concurrency group to throttle the loop"
        else
          ok "the relay job's \`if:\` excludes every converge and queue leg"
        fi
      fi
      env_missing=""
      for binding in GH_REPO DISPATCH_REF WORKFLOW_REF EVENT_NAME CHECK_NAME; do
        grep -qE "^ +$binding: " "$relay" || env_missing="${env_missing:+$env_missing }$binding"
      done
      if [ -n "$env_missing" ]; then
        bad "the relay job's \`env:\` block lost: $env_missing — the step defaults every read, so a dropped binding is not a red run; it is a leg that silently stops converging"
      else
        ok "the relay job's \`env:\` block carries every binding the step reads"
      fi
    fi

    if [ -z "$writer" ]; then
      bad "$adopted has no converge job holding \`statuses: write\` and running review-writer.sh — nothing evaluates the gate"
    else
      ok "the write job is present (statuses: write, runs review-writer.sh)"
      if grep -qE '^ +group: ' "$writer" && grep -qE '^ +cancel-in-progress: +false' "$writer"; then
        ok "the write job holds the single-writer concurrency group with cancel-in-progress: false"
      else
        bad "the write job's concurrency group is missing or cancels in progress — the gate's one writer must hold a single non-cancelling group"
      fi
      writer_if="$(first_match '^ +if: ' "$writer")"
      for leg in workflow_dispatch schedule; do
        case "$writer_if" in
          *"== '$leg'"*) ;;
          *) bad "the write job's \`if:\` no longer admits '$leg' — that converge leg would stop running the engine" ;;
        esac
      done
      for leg in pull_request_target pull_request_review status check_run; do
        case "$writer_if" in
          *"== '$leg'"*)
            bad "the write job's \`if:\` admits the PR-attached leg '$leg' — those legs relay; a PR-attached run holding the writer group puts eviction marks back into PR check rollups"
            ;;
        esac
      done
    fi

    if [ -z "$queue" ]; then
      bad "$adopted has no merge_group job posting the gate context — queue entries would sit without the required status and never merge"
    else
      ok "the merge-group job posts the gate context on queue shas"
    fi

    # Every checkout in the file, whichever job it sits in.
    if grep -qE "^ +ref: .*default_branch \|\|" "$adopted"; then
      bad "a checkout ref falls back to a hardcoded branch name — the template carries no per-repo values; use \`\${{ github.event.repository.default_branch }}\` and let the guard step refuse an empty resolution"
    else
      ok "no checkout ref carries a hardcoded default-branch fallback"
    fi
    # Anchored on the STEP, not the word: both strings also appear in this
    # file's own commentary, and counting those would compare prose to prose.
    checkouts="$(count_matches '^ +- uses: actions/checkout' "$adopted")"
    creds="$(count_matches '^ +persist-credentials: false' "$adopted")"
    if [ "$checkouts" -gt 0 ] && [ "$creds" -ge "$checkouts" ]; then
      ok "every checkout drops its credentials ($checkouts checkout(s))"
    else
      bad "$adopted has $checkouts checkout(s) but $creds \`persist-credentials: false\` — a checkout keeping the write-capable token in .git/config is reachable by everything the job then runs"
    fi
    if grep -qE "^ +ref: .*github\.event\.repository\.default_branch" "$adopted"; then
      ok "checkouts pin the repository default branch"
    else
      bad "no checkout pins \`github.event.repository.default_branch\` — the writer must run the DEFAULT-branch engine on every leg, never the event's own ref"
    fi

    # Triggers. Losing one is silent: the leg simply stops converging, and the
    # cron floor absorbs it until someone notices gates going stale.
    for trigger in pull_request_target pull_request_review status merge_group schedule workflow_dispatch; do
      if grep -qE "^  $trigger:" "$adopted"; then
        ok "trigger '$trigger' is wired"
      else
        bad "trigger '$trigger' is missing from \`on:\` — that leg no longer converges the gate (workflow_dispatch is also the relay's dispatch target: without it every event-fast path is gone)"
      fi
    done
    if grep -qE '^  status: *\{\}' "$adopted"; then
      ok "the status trigger carries no state or context filter"
    else
      bad "the status trigger is filtered — every status STATE must converge (a success→pending/failure transition is a withdrawal), and a context-name list silently strands any reviewer it misses"
    fi
    if grep -qE '^  check_run:' "$adopted"; then
      if grep -qF 'vars.REVIEW_GATE_CHECK_RUN_NAME' "$adopted"; then
        note "the check_run opt-in is enabled — set the repository variable REVIEW_GATE_CHECK_RUN_NAME to the reviewer's check name, or the trigger relays nothing"
      else
        bad "the check_run trigger is enabled but the relay's \`if:\` does not read vars.REVIEW_GATE_CHECK_RUN_NAME — every CI job completion in the repo would relay, and the relay coalesces nothing"
      fi
    fi
  fi

}

rg_check_adopted_workflow "$TMP"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
