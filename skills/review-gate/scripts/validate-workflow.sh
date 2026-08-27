#!/usr/bin/env bash
# Review-gate validate — the adopted-workflow half. Shipped by the kendex
# review-gate skill, vendored at .agents/skills/review-gate/scripts/.
# `validate.sh` runs this as its last group and folds the result into its
# own; it also stands alone for anyone changing only the workflow copy.
# Everything here reads .github/workflows/ and nothing else does — the seam
# the two files split on. Contract: print_usage below, or --help.
set -euo pipefail

print_usage() {
  cat <<'USAGE'
Usage: validate-workflow.sh [--help]   (no positional arguments)

Checks that THIS repository's adopted review-gate writer workflow still
carries the template's contract: exactly one tracked workflow EXECUTES
review-writer.sh; it wires every trigger the relay/converge split needs; its
relay's permissions are exactly actions:write, it checks nothing out, holds
no concurrency group and refuses the converge legs; its write job holds a
LITERAL single-writer group that does not cancel in progress; and every
checkout, one by one, pins the repository default branch with credentials
dropped.

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

# The field separator checkout_steps() emits, held in a variable so the
# reader never has to guess whether an indented literal is a tab.
TAB="$(printf '\t')"

PASS=0
FAILED=0
ok() { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
bad() { FAILED=$((FAILED + 1)); printf 'FAIL  %s\n' "$1"; }
note() { printf 'note  %s\n' "$1"; }

# grep exits 0/1 as a MEASUREMENT and anything higher as a read failure. This
# keeps that distinction: under errexit a bare no-match would kill the run,
# and a `|| true` would launder an unreadable file into "nothing matched".
first_match() { # ERE FILE — first matching line on stdout, empty when none
  local line rc=0
  line="$(grep -m1 -E -- "$1" "$2")" || rc=$?
  [ "$rc" -le 1 ] || die "$2: unreadable while reading /$1/ (grep exit $rc)"
  printf '%s' "$line"
}

# The writer is EXECUTED, at a command position, on its own line. The name
# also appears in this workflow's comments, its missing-file guard and that
# guard's error string, so matching the word finds files that run nothing —
# the relay among them, whose contract is that it runs no engine at all.
EXEC_WRITER_RE='^[[:space:]]*exec[[:space:]]+[^[:space:]]*review-writer\.sh[[:space:]]*$'

# A job's `permissions:` mapping, one "key: value" per line — what makes a
# CLOSED assertion possible, where a named-scope blocklist passes every scope
# nobody thought to name. "!scalar VALUE" reports the non-mapping spellings
# (`permissions: read-all`, `permissions: {}`), which are answers too.
job_permissions() { # BLOCK-FILE
  awk '
    {
      line = $0
      sub(/\r$/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == "") next
      match(line, /^[[:space:]]*/)
      ind = RLENGTH
      body = substr(line, ind + 1)
      if (body ~ /^#/) next
      if (inp) {
        if (ind > pind) { print body; next }
        inp = 0
      }
      if (body ~ /^permissions:/) {
        rest = body
        sub(/^permissions:[[:space:]]*/, "", rest)
        if (rest != "") { print "!scalar " rest; next }
        inp = 1
        pind = ind
      }
    }
  ' "$1"
}

# One record per checkout STEP: line, `ref:`, `persist-credentials:`. Per
# step, not per file — a file-wide count is satisfied by one good checkout
# while its sibling runs the event's own ref under a write-capable token.
checkout_steps() { # FILE — "LINE<TAB>REF<TAB>PERSIST-CREDENTIALS"
  awk '
    function flush() {
      if (instep) { printf "%d\t%s\t%s\n", sline, r, pc; instep = 0 }
      r = ""; pc = ""
    }
    {
      line = $0
      sub(/\r$/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == "") next
      match(line, /^[[:space:]]*/)
      ind = RLENGTH
      body = substr(line, ind + 1)
      if (instep && ind <= sind) flush()
      if (body ~ /^-[[:space:]]+uses:[[:space:]]*actions\/checkout/) {
        flush()
        instep = 1; sind = ind; sline = NR
        next
      }
      if (!instep || body ~ /^#/) next
      if (body ~ /^ref:/) { v = body; sub(/^ref:[[:space:]]*/, "", v); r = v }
      else if (body ~ /^persist-credentials:/) { v = body; sub(/^persist-credentials:[[:space:]]*/, "", v); pc = v }
    }
    END { flush() }
  ' "$1"
}

unquote() { # VALUE — surrounding whitespace and quotes removed
  printf '%s' "$1" | sed "s/^[[:space:]]*//;s/[[:space:]]*\$//;s/^[\"']//;s/[\"']\$//"
}

TMP="$(mktemp -d)" || die "could not create a scratch directory"
trap 'rm -rf "$TMP"' EXIT

rg_check_adopted_workflow() { # SCRATCH-DIR — verdict lines on stdout
  local tmp="$1"
  local adopted adopted_count relay writer queue key blk over relay_if missing
  local env_missing binding leg scope writer_if checkouts trigger wf perm_count
  local crec crest cline cref ccreds wgroup wcancel

  # TRACKED files only: Actions runs what is committed, so an untracked
  # workflow on someone's disk is not this repo's writer.
  adopted=""
  adopted_count=0
  while IFS= read -r wf; do
    [ -n "$wf" ] && [ -f "$wf" ] || continue
    grep -qE -- "$EXEC_WRITER_RE" "$wf" || continue
    adopted_count=$((adopted_count + 1))
    adopted="$wf"
  done <<EOF_WORKFLOWS
$(git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml')
EOF_WORKFLOWS

  if [ "$adopted_count" -eq 0 ]; then
    bad "no tracked workflow under .github/workflows/ EXECUTES review-writer.sh — nothing writes this repo's gate status; copy templates/review-gate-writer.yml in (references/adoption.md)"
  elif [ "$adopted_count" -gt 1 ]; then
    bad "$adopted_count tracked workflows execute review-writer.sh — the gate has exactly one writer by design; delete the copies that are not the adopted one"
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
        if job_permissions "$blk" | grep -qxF 'actions: write'; then
          relay="$blk"
        fi
        if job_permissions "$blk" | grep -qxF 'statuses: write' && grep -qE -- "$EXEC_WRITER_RE" "$blk"; then
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
      # CLOSED, not a blocklist: every entry other than `actions: write` is
      # over-scope, whatever it is named. Job-level permissions REPLACE the
      # workflow default, so this mapping is the whole scope.
      over=""
      perm_count=0
      while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        perm_count=$((perm_count + 1))
        case "$entry" in
          "actions: write") ;;
          *) over="${over:+$over; }$entry" ;;
        esac
      done <<EOF_RELAY_PERMS
$(job_permissions "$relay")
EOF_RELAY_PERMS
      if [ -n "$over" ]; then
        bad "the relay job's permissions are not exactly \`actions: write\` — it also holds: $over. Job-level permissions replace the workflow default, so this mapping is its complete scope"
      elif [ "$perm_count" -ne 1 ]; then
        bad "the relay job's permissions mapping has $perm_count entries where one is the contract (\`actions: write\`)"
      else
        ok "the relay job's permissions are exactly \`actions: write\` and nothing else"
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
      # The group name must be a LITERAL: an expression that varies per run
      # gives every run its own group, which is no throttle at all, spelled
      # to look like one.
      wgroup="$(first_match '^ +group: ' "$writer")"
      wgroup="$(unquote "${wgroup#*group:}")"
      wcancel="$(first_match '^ +cancel-in-progress: ' "$writer")"
      wcancel="$(unquote "${wcancel#*cancel-in-progress:}")"
      if [ -z "$wgroup" ]; then
        bad "the write job holds no concurrency \`group:\` — nothing keeps the gate to one writer"
      else
        case "$wgroup" in
          *'${{'*)
            bad "the write job's concurrency group '$wgroup' is computed per run — a group that varies by run gives every run its own group, so the single-writer throttle does not exist; the name must be a literal shared by every run"
            ;;
          *)
            ok "the write job's concurrency group is the literal '$wgroup', shared by every run"
            ;;
        esac
        fi
      if [ "$wcancel" = "false" ]; then
        ok "the write job's group does not cancel in progress"
      else
        bad "the write job's \`cancel-in-progress\` is '${wcancel:-<unset>}', not false — a pending writer run cancelled mid-write leaves the gate unconverged"
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

    # PER CHECKOUT, each named by its line. A file-wide count is satisfied by
    # one compliant checkout while its sibling runs the event's own ref, or
    # keeps the token on disk, in silence.
    checkouts=0
    while IFS= read -r crec; do
      [ -n "$crec" ] || continue
      checkouts=$((checkouts + 1))
      # Split by hand, NOT with IFS="$TAB": a tab is IFS whitespace, so `read`
      # collapses a run of them and an absent ref — the very case worth
      # reporting — would shift the credentials value into the ref field and
      # be reported as a wrong branch.
      cline="${crec%%"$TAB"*}"
      crest="${crec#*"$TAB"}"
      cref="$(unquote "${crest%%"$TAB"*}")"
      ccreds="$(unquote "${crest#*"$TAB"}")"
      if [ -z "$cref" ]; then
        bad "the checkout at $adopted:$cline pins no \`ref:\` — it takes the EVENT's own ref, which on a PR-attached or queue leg is code under review running with a write-capable token"
      else
        case "$cref" in
          '${{ github.event.repository.default_branch }}')
            ok "the checkout at $adopted:$cline pins the repository default branch"
            ;;
          *default_branch*'||'*)
            bad "the checkout at $adopted:$cline falls back to a hardcoded branch name ($cref) — the template carries no per-repo values; use \`\${{ github.event.repository.default_branch }}\` and let the guard step refuse an empty resolution"
            ;;
          *)
            bad "the checkout at $adopted:$cline pins '$cref', not \`\${{ github.event.repository.default_branch }}\` — the writer must run the DEFAULT-branch engine on every leg"
            ;;
        esac
        fi
      if [ "$ccreds" = "false" ]; then
        ok "the checkout at $adopted:$cline sets persist-credentials: false"
      else
        bad "the checkout at $adopted:$cline has persist-credentials: false missing (it is '${ccreds:-<unset>}') — a checkout keeping the write-capable token in .git/config is reachable by everything the job then runs"
        fi
    done <<EOF_CHECKOUTS
$(checkout_steps "$adopted")
EOF_CHECKOUTS
    if [ "$checkouts" -eq 0 ]; then
      bad "$adopted runs no checkout at all — the converge legs need the default-branch engine on disk to execute it"
    fi

    # Triggers. Losing one is silent: the leg stops converging and the cron
    # floor absorbs it until someone notices gates going stale.
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
