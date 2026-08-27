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
carries the template's contract.

Every assertion reads an EXTRACTED BLOCK — the `on:` mapping, one job's
mapping, one step — and never the whole file. That is the difference between
asking "does the workflow do this?" and "does this text appear somewhere?": a
comment, a job renamed after the trigger it replaced, or a second copy of a
role all satisfy the second question and none of them satisfy the first.

What it asserts:

  roles     exactly one relay, one write job and one merge-group job. A
            count other than one is a failure, not a job picked from the
            duplicates.
  relay     permissions exactly `actions: write` and nothing else; no
            checkout step; no concurrency group; an `if:` excluding all
            three converge and queue legs; every `env:` binding the step
            reads; DISPATCH_REF pinned to the default branch.
  engine    each privileged job checks out, and every checkout is preceded
            in that same job by the guard step that refuses an empty
            default branch with a nonzero exit; each checkout pins the
            default-branch expression and drops its credentials.
  writer    a LITERAL single-writer concurrency group that does not cancel
            in progress, admitting the two converge legs only.
  triggers  every leg the relay/converge split needs, read from the `on:`
            mapping, with the activity types each typed trigger needs.

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

TMP="$(mktemp -d)" || die "could not create a scratch directory"
trap 'rm -rf "$TMP"' EXIT

# ============================== the spine ==================================
#
# Four primitives. Every check is a question asked of a block one of these
# returned, which is what keeps text found elsewhere in the file from
# answering it.

block_under() { # FILE KEY-ERE — the lines nested under the first matching key
  awk -v key="$2" '
    !seen {
      if ($0 ~ /^[[:space:]]*#/) next
      if ($0 ~ key) { match($0, /^[[:space:]]*/); base = RLENGTH; seen = 1 }
      next
    }
    {
      line = $0
      sub(/\r$/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == "") next
      match(line, /^[[:space:]]*/)
      if (RLENGTH <= base) exit
      print line
    }
  ' "$1"
}

min_indent() { # BLOCK-FILE — shallowest indent over non-comment lines, or -1
  awk '
    { l = $0; sub(/[[:space:]]+$/, "", l) }
    l == "" { next }
    { match(l, /^[[:space:]]*/); b = substr(l, RLENGTH + 1) }
    b ~ /^#/ { next }
    { if (m == "" || RLENGTH + 0 < m + 0) m = RLENGTH }
    END { if (m == "") m = -1; print m }
  ' "$1"
}

# Immediate children of a mapping, each written to its own block file. This
# is the primitive the whole file turns on: `jobs:` gives one file per job,
# `on:` one per trigger, and both are then asked their own questions.
split_children() { # BLOCK-FILE DEST PREFIX — writes DEST/PREFIX<key>, DEST/PREFIXkeys
  local m
  m="$(min_indent "$1")"
  [ "$m" -ge 0 ] || return 0
  awk -v m="$m" -v dest="$2" -v pfx="$3" '
    { l = $0; sub(/[[:space:]]+$/, "", l) }
    l == "" { next }
    { match(l, /^[[:space:]]*/); ind = RLENGTH; b = substr(l, ind + 1) }
    b ~ /^#/ { next }
    ind == m + 0 && b ~ /^["'"'"']?[A-Za-z0-9_.-]+["'"'"']?[[:space:]]*:/ {
      k = b
      sub(/[[:space:]]*:.*$/, "", k)
      gsub(/["'"'"']/, "", k)
      cur = dest "/" pfx k
      printf "" >> cur
      print k >> (dest "/" pfx "keys")
      next
    }
    cur != "" { print l >> cur }
  ' "$1"
}

# The scalar after KEY: among a block's immediate children. The key must be
# followed directly by its colon, which is the shape every workflow key in
# this contract has.
key_value() { # BLOCK-FILE KEY — the value, or empty
  local m
  m="$(min_indent "$1")"
  [ "$m" -ge 0 ] || return 0
  awk -v m="$m" -v k="$2" '
    { l = $0; sub(/[[:space:]]+$/, "", l) }
    l == "" { next }
    { match(l, /^[[:space:]]*/); if (RLENGTH + 0 != m + 0) next
      b = substr(l, RLENGTH + 1)
      if (b ~ /^#/) next
      if (index(b, k ":") != 1) next
      v = substr(b, length(k) + 2)
      sub(/^[[:space:]]*/, "", v)
      print v
      exit }
  ' "$1"
}

# Steps are a SEQUENCE, so they need their own splitter: the `- ` marker is
# rewritten to two spaces so every key in a step sits at one indent and the
# three primitives above work on it unchanged.
split_steps() { # JOB-BLOCK-FILE DEST — writes DEST/step.N, DEST/step.count
  local sb="$2/steps.block" m
  block_under "$1" '^[[:space:]]*steps:[[:space:]]*$' >"$sb"
  m="$(min_indent "$sb")"
  if [ "$m" -lt 0 ]; then
    printf '0' >"$2/step.count"
    return 0
  fi
  awk -v m="$m" -v dest="$2" '
    { l = $0; sub(/[[:space:]]+$/, "", l) }
    l == "" { next }
    { match(l, /^[[:space:]]*/); ind = RLENGTH; b = substr(l, ind + 1) }
    ind == m + 0 && b ~ /^-[[:space:]]/ {
      n++
      cur = dest "/step." n
      print substr(l, 1, ind) "  " substr(l, ind + 3) >> cur
      next
    }
    cur != "" { print l >> cur }
    END { printf "%d", n + 0 > (dest "/step.count") }
  ' "$sb"
}

unquote() { # VALUE — surrounding whitespace, and a MATCHED quote pair, removed
  local v
  v="$(printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  # A pair, never one end: stripping a lone trailing quote turns
  # `github.event_name == 'merge_group'` into a value that matches nothing.
  case "$v" in
    '"'?*'"') v="${v#\"}"; v="${v%\"}" ;;
    "'"?*"'") v="${v#\'}"; v="${v%\'}" ;;
  esac
  printf '%s' "$v"
}

# The writer is EXECUTED, at a command position, on its own line. The name
# also appears in this workflow's comments, its missing-file guard and that
# guard's error string, so matching the word finds files that run nothing —
# the relay among them, whose contract is that it runs no engine at all.
EXEC_WRITER_RE='^[[:space:]]*exec[[:space:]]+[^[:space:]]*review-writer\.sh[[:space:]]*$'
DEFAULT_BRANCH_EXPR='${{ github.event.repository.default_branch }}'

# ========================= find the adopted copy ===========================

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
  printf '\n'
  exit 1
fi
if [ "$adopted_count" -gt 1 ]; then
  bad "$adopted_count tracked workflows execute review-writer.sh — the gate has exactly one writer by design; delete the copies that are not the adopted one"
  printf '\n'
  exit 1
fi
ok "one adopted writer workflow: $adopted"

# ============================ role discovery ===============================

block_under "$adopted" '^jobs:[[:space:]]*$' >"$TMP/jobs.block"
split_children "$TMP/jobs.block" "$TMP" "job."

relay=""
relay_name=""
relay_n=0
writer=""
writer_name=""
writer_n=0
queue=""
queue_name=""
queue_n=0

if [ -f "$TMP/job.keys" ]; then
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    blk="$TMP/job.$key"
    [ -f "$blk" ] || continue
    mkdir -p "$TMP/steps.$key"
    split_steps "$blk" "$TMP/steps.$key"
    block_under "$blk" '^[[:space:]]*permissions:' >"$TMP/perms.$key"
    if [ "$(unquote "$(key_value "$TMP/perms.$key" actions)")" = "write" ]; then
      relay_n=$((relay_n + 1))
      relay="$blk"
      relay_name="$key"
    fi
    # Executing the engine is what makes a job a converge leg — asked of its
    # STEPS, so a job that only names the script is not one.
    if grep -rqE -- "$EXEC_WRITER_RE" "$TMP/steps.$key" 2>/dev/null; then
      if unquote "$(key_value "$blk" if)" | grep -qF "== 'merge_group'"; then
        queue_n=$((queue_n + 1))
        queue="$blk"
        queue_name="$key"
      else
        writer_n=$((writer_n + 1))
        writer="$blk"
        writer_name="$key"
      fi
    fi
  done <"$TMP/job.keys"
fi

# COUNTED, never "last one wins". A second job in a role is not a duplicate
# of the one that was inspected: it is an uninspected job holding the same
# powers, which is the whole reason to count.
role_ok() { # NAME COUNT — 0 when exactly one job holds the role
  case "$2" in
    1) return 0 ;;
    0) bad "$adopted has no $1 job — see this tool's --help for what identifies one" ;;
    *) bad "$adopted has $2 $1 jobs where the contract is exactly one — the extra job holds the same powers and nothing below inspects it" ;;
  esac
  return 1
}

if [ "$relay_n" -eq 0 ]; then
  bad "$adopted has no job holding \`actions: write\` — the relay is what every PR-attached leg runs, and without it those events reach the gate only on the cron floor"
elif [ "$relay_n" -gt 1 ]; then
  bad "$adopted has $relay_n jobs holding \`actions: write\` where the contract is exactly one relay — an extra dispatch-capable job is uninspected by everything below"
else
  ok "exactly one relay job ($relay_name), identified by its permissions mapping"
fi
role_ok "write" "$writer_n" && ok "exactly one write job ($writer_name), identified by the step that executes the engine" || :
role_ok "merge-group" "$queue_n" && ok "exactly one merge-group job ($queue_name), posting the gate context on queue shas" || :

# ============================== the relay ==================================

relay_if=""
if [ "$relay_n" -eq 1 ]; then
  relay_if="$(unquote "$(key_value "$relay" if)")"

  # CLOSED, not a blocklist: every entry other than `actions: write` is
  # over-scope, whatever it is named. Job-level permissions REPLACE the
  # workflow default, so this mapping is the relay's whole scope.
  over=""
  split_children "$TMP/perms.$relay_name" "$TMP" "relayperm."
  if [ -f "$TMP/relayperm.keys" ]; then
    while IFS= read -r pkey; do
      [ -n "$pkey" ] || continue
      [ "$pkey" = "actions" ] && continue
      over="${over:+$over; }$pkey: $(unquote "$(key_value "$TMP/perms.$relay_name" "$pkey")")"
    done <"$TMP/relayperm.keys"
  fi
  if [ -n "$over" ]; then
    bad "the relay job's permissions are not exactly \`actions: write\` — it also holds: $over. Job-level permissions replace the workflow default, so this mapping is its complete scope"
  else
    ok "the relay job's permissions are exactly \`actions: write\` and nothing else"
  fi

  if grep -rqE '^ *uses:.*actions/checkout' "$TMP/steps.$relay_name" 2>/dev/null; then
    bad "the relay job checks out code — it runs on pull_request_target, where a checkout puts PR-controlled code under a write-capable token; the relay must check nothing out"
  else
    ok "the relay job checks nothing out"
  fi

  if [ -n "$(key_value "$relay" concurrency)$(block_under "$relay" '^[[:space:]]*concurrency:')" ]; then
    bad "the relay job holds a concurrency group — an evictable relay leaves a CANCELLED check on the PR head, pinning the PR at UNSTABLE; the group belongs on the write job alone"
  else
    ok "the relay job holds no concurrency group (it can never be evicted)"
  fi

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

  block_under "$relay" '^[[:space:]]*env:' >"$TMP/relay.env"
  env_missing=""
  for binding in GH_REPO DISPATCH_REF WORKFLOW_REF EVENT_NAME CHECK_NAME; do
    [ -n "$(key_value "$TMP/relay.env" "$binding")" ] ||
      env_missing="${env_missing:+$env_missing }$binding"
  done
  if [ -n "$env_missing" ]; then
    bad "the relay job's \`env:\` block lost: $env_missing — the step defaults every read, so a dropped binding is not a red run; it is a leg that silently stops converging"
  else
    ok "the relay job's \`env:\` block carries every binding the step reads"
  fi
  # DISPATCH_REF's VALUE, not its presence: it is the one expression deciding
  # which ENGINE the converge pass runs, and github.ref here is the PR's base
  # branch on the pull_request_target leg.
  dref="$(unquote "$(key_value "$TMP/relay.env" DISPATCH_REF)")"
  if [ "$dref" = "$DEFAULT_BRANCH_EXPR" ]; then
    ok "the relay dispatches onto the repository default branch"
  else
    bad "the relay's DISPATCH_REF is '${dref:-<unset>}', not \`$DEFAULT_BRANCH_EXPR\` — the converge pass would run whatever engine lives on that ref"
  fi
fi

# ===================== the privileged jobs' checkouts ======================

# Asked PER JOB and PER STEP, in order. A workflow-wide count is satisfied by
# one compliant checkout in one job while another job checks out the event's
# ref, or keeps the write-capable token on disk, with nothing said.
guard_step() { # STEP-FILE — 0 when this step is the complete fail-closed guard
  local run
  [ "$(unquote "$(key_value "$1" env)")" = "" ] || :
  block_under "$1" '^[[:space:]]*env:' >"$TMP/step.env"
  [ "$(unquote "$(key_value "$TMP/step.env" DEFAULT_BRANCH)")" = "$DEFAULT_BRANCH_EXPR" ] || return 1
  run="$(block_under "$1" '^[[:space:]]*run:')"
  # The refusal is the point, not the mention: the emptiness test AND a
  # nonzero exit. A guard whose `exit 1` was deleted reports the fault and
  # then checks the unpinned ref out anyway.
  printf '%s' "$run" | grep -qF -- '-z "${DEFAULT_BRANCH' || return 1
  printf '%s' "$run" | grep -qE -- '^[[:space:]]*exit[[:space:]]+[1-9]' || return 1
  return 0
}

check_privileged_job() { # JOB-NAME JOB-BLOCK
  local name="$1" blk="$2" dir="$TMP/steps.$1" count i step uses ref creds
  local checkouts=0 guards_before=0
  count="$(cat "$dir/step.count" 2>/dev/null || printf '0')"
  i=0
  while [ "$i" -lt "$count" ]; do
    i=$((i + 1))
    step="$dir/step.$i"
    [ -f "$step" ] || continue
    if guard_step "$step"; then
      guards_before=$((guards_before + 1))
      continue
    fi
    uses="$(unquote "$(key_value "$step" uses)")"
    case "$uses" in
      actions/checkout*) ;;
      *) continue ;;
    esac
    checkouts=$((checkouts + 1))
    if [ "$guards_before" -eq 0 ]; then
      bad "the checkout in job '$name' (step $i) runs without the guard step that refuses an empty \`github.event.repository.default_branch\` with a nonzero exit — an empty resolution reaches actions/checkout's own fallback, the EVENT's ref, in silence"
    else
      ok "the checkout in job '$name' (step $i) is preceded by the fail-closed default-branch guard"
    fi
    block_under "$step" '^[[:space:]]*with:' >"$TMP/step.with"
    ref="$(unquote "$(key_value "$TMP/step.with" ref)")"
    creds="$(unquote "$(key_value "$TMP/step.with" persist-credentials)")"
    if [ -z "$ref" ]; then
      bad "the checkout in job '$name' (step $i) pins no \`ref:\` — it takes the EVENT's own ref, which on a PR-attached or queue leg is code under review running with a write-capable token"
    elif [ "$ref" = "$DEFAULT_BRANCH_EXPR" ]; then
      ok "the checkout in job '$name' (step $i) pins the repository default branch"
    else
      case "$ref" in
        *default_branch*'||'*)
          bad "the checkout in job '$name' (step $i) falls back to a hardcoded branch name ($ref) — the template carries no per-repo values; use \`$DEFAULT_BRANCH_EXPR\` and let the guard step refuse an empty resolution"
          ;;
        *)
          bad "the checkout in job '$name' (step $i) pins '$ref', not \`$DEFAULT_BRANCH_EXPR\` — the writer must run the DEFAULT-branch engine on every leg"
          ;;
      esac
    fi
    if [ "$creds" = "false" ]; then
      ok "the checkout in job '$name' (step $i) sets persist-credentials: false"
    else
      bad "the checkout in job '$name' (step $i) has persist-credentials: false missing (it is '${creds:-<unset>}') — a checkout keeping the write-capable token in .git/config is reachable by everything the job then runs"
    fi
  done
  if [ "$checkouts" -eq 0 ]; then
    bad "job '$name' runs the engine but checks nothing out — it has no default-branch tree to execute, and an absent checkout must never read as a satisfied guard"
  fi
}

[ "$writer_n" -eq 1 ] && check_privileged_job "$writer_name" "$writer"
[ "$queue_n" -eq 1 ] && check_privileged_job "$queue_name" "$queue"

# ============================ the write job ================================

if [ "$writer_n" -eq 1 ]; then
  block_under "$writer" '^[[:space:]]*concurrency:' >"$TMP/writer.concurrency"
  # The group name must be a LITERAL: an expression varying per run gives
  # every run its own group — no throttle, spelled to look like one.
  wgroup="$(unquote "$(key_value "$TMP/writer.concurrency" group)")"
  wcancel="$(unquote "$(key_value "$TMP/writer.concurrency" cancel-in-progress)")"
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

  writer_if="$(unquote "$(key_value "$writer" if)")"
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

# ============================== the triggers ===============================

# Read from the `on:` MAPPING, not from the file. A job renamed `schedule`
# satisfies a whole-file grep for a trigger that was deleted.
block_under "$adopted" '^"?on"?:' >"$TMP/on.block"
split_children "$TMP/on.block" "$TMP" "on."

has_trigger() { # NAME
  [ -f "$TMP/on.keys" ] && grep -qxF -- "$1" "$TMP/on.keys"
}

for trigger in pull_request_target pull_request_review status merge_group schedule workflow_dispatch; do
  if has_trigger "$trigger"; then
    ok "trigger '$trigger' is wired"
  else
    bad "trigger '$trigger' is missing from \`on:\` — that leg no longer converges the gate (workflow_dispatch is also the relay's dispatch target: without it every event-fast path is gone)"
  fi
done

# Activity types, not just the trigger key. `types: [opened]` leaves every
# push and reopen converging on the cron floor instead of event-fast.
assert_types() { # TRIGGER REQUIRED...
  local trig="$1" types missing=""
  shift
  has_trigger "$trig" || return 0
  types="$(key_value "$TMP/on.$trig" types)"
  if [ -z "$types" ]; then
    bad "trigger '$trig' declares no \`types:\` — GitHub's default set is narrower than this contract needs ($*)"
    return 0
  fi
  for want in "$@"; do
    case "$types" in
      *"$want"*) ;;
      *) missing="${missing:+$missing }$want" ;;
    esac
  done
  if [ -n "$missing" ]; then
    bad "trigger '$trig' is missing activity type(s): $missing — those transitions stop requesting a converge pass and wait for the cron floor"
  else
    ok "trigger '$trig' carries every activity type the split needs"
  fi
}

assert_types pull_request_target opened synchronize reopened
assert_types pull_request_review submitted dismissed

if has_trigger status; then
  if [ -n "$(cat "$TMP/on.status" 2>/dev/null)" ]; then
    bad "the status trigger is filtered — every status STATE must converge (a success→pending/failure transition is a withdrawal), and a context-name list silently strands any reviewer it misses"
  else
    ok "the status trigger carries no state or context filter"
  fi
fi

if has_trigger schedule; then
  if grep -qE '^[[:space:]]*-[[:space:]]*cron:' "$TMP/on.schedule" 2>/dev/null; then
    ok "the schedule trigger declares a cron floor"
  else
    bad "the schedule trigger declares no \`cron:\` — the floor for transitions GitHub emits no event for is gone"
  fi
fi

if has_trigger check_run; then
  # Asked of the relay's OWN if: expression. A comment naming the variable
  # satisfies a whole-file grep while every CI completion relays.
  case "$relay_if" in
    *vars.REVIEW_GATE_CHECK_RUN_NAME*)
      note "the check_run opt-in is enabled — set the repository variable REVIEW_GATE_CHECK_RUN_NAME to the reviewer's check name, or the trigger relays nothing"
      ;;
    *)
      bad "the check_run trigger is enabled but the relay's \`if:\` does not read vars.REVIEW_GATE_CHECK_RUN_NAME — every CI job completion in the repo would relay, and the relay coalesces nothing"
      ;;
  esac
fi

printf '\n'
if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
