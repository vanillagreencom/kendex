#!/usr/bin/env bash
# `cleanup --targets-only`: reclaim regenerable build output while the worktree,
# its branch and every source file stay where they are.
#
# Build output is written by a compiler or a package manager and holds no user
# work, so the uncommitted-work refusal that protects the removal path protects
# nothing here and is not made. That refusal is precisely why the large
# worktrees on a busy machine were unreclaimable: the trees holding the output
# are the ones someone is still using. Every other refusal the removal path
# makes still holds here — a session's guard lease, a live build holding the
# directory, a symlinked or shared output path, a HEAD that moved mid-run.
#
# This library owns the mode's flags, their validation, the sweep over
# worktrees and the lease. scripts/worktree-output-prune owns the layout table,
# the locking and every deletion, and emits the records rendered here; its
# header states that protocol. Sourced by scripts/worktree after
# lib/messages.sh, whose worktree_message is the only place a record is
# formatted.

OUTPUT_PRUNE_ENGINE="$SCRIPT_DIR/worktree-output-prune"

OUTPUT_PRUNE_MODE=false
OUTPUT_PRUNE_APPLY=false
# A unit whose newest artifact is younger than this survives the sweep, so a
# warm cache a paused lane is about to resume on is not thrown away.
OUTPUT_PRUNE_DAYS=7
# The last flag seen that only the targets-only mode accepts, so validation can
# name the one the operator passed.
OUTPUT_PRUNE_MODE_FLAG=""
OUTPUT_PRUNE_SHIFT=1

# Accept one argument of the targets-only mode, setting OUTPUT_PRUNE_SHIFT to
# the number of arguments consumed. Returns 1 without a message when the
# argument belongs to no flag here, leaving the caller's parser to judge it.
output_prune_parse_flag() {
  OUTPUT_PRUNE_SHIFT=1
  case "$1" in
    --targets-only) OUTPUT_PRUNE_MODE=true ;;
    --apply)
      OUTPUT_PRUNE_APPLY=true
      OUTPUT_PRUNE_MODE_FLAG="--apply"
      ;;
    --older-than-days)
      OUTPUT_PRUNE_MODE_FLAG="--older-than-days"
      if [[ $# -lt 2 ]]; then
        worktree_message cleanup-days-required "--older-than-days" "Error: --older-than-days requires a value" >&2
        exit 1
      fi
      # 10# forces base ten: bash reads a leading zero as octal, so a plain
      # comparison errors on 08 instead of answering, and an erroring guard
      # reads as an accepted value.
      if ! [[ "$2" =~ ^[0-9]{1,6}$ ]] || [[ "$((10#$2))" -lt 1 ]]; then
        worktree_message cleanup-days-invalid "$2" "Error: --older-than-days must be a positive integer of at most 6 digits" >&2
        exit 1
      fi
      OUTPUT_PRUNE_DAYS="$2"
      OUTPUT_PRUNE_SHIFT=2
      ;;
    *) return 1 ;;
  esac
  return 0
}

# The cross-flag rules, one each way. --apply and --older-than-days mean nothing
# outside the targets-only mode. The removal path's lease flags mean nothing
# inside it: a claimed worktree is a live session whichever sweep is running, so
# this mode never releases a lease and the TTL that measures a stale one has
# nothing to measure. Accepting either silently is the option ignored without a
# word that this refusal exists to end.
output_prune_validate() {
  if [[ "$OUTPUT_PRUNE_MODE" != true && -n "$OUTPUT_PRUNE_MODE_FLAG" ]]; then
    worktree_message cleanup-targets-flag-orphan "$OUTPUT_PRUNE_MODE_FLAG" "Error: $OUTPUT_PRUNE_MODE_FLAG is only valid with --targets-only" >&2
    exit 1
  fi
  if [[ "$OUTPUT_PRUNE_MODE" == true && -n "$CLEANUP_LEASE_FLAG" ]]; then
    worktree_message cleanup-targets-lease-flag "$CLEANUP_LEASE_FLAG" "Error: --targets-only never releases a session guard lease, so it cannot take $CLEANUP_LEASE_FLAG" >&2
    exit 1
  fi
}

# Render the engine's report for one worktree, reading the newline-terminated,
# tab-separated records its header documents. A path carrying a newline is the
# engine's to refuse, not this delimiter's to survive: it keeps such a unit
# unpruned as reason=unreportable-unit-name. The engine names the stream for each record, so
# a record kind it gains needs no change here and none can be dropped for want
# of a name. An unrecognized stream word is therefore unreachable from the
# engine shipped beside this file: report it and fail rather than drop a record,
# which on an apply would hide a deletion.
output_prune_render() {
  local wt="$1" report="$2" record="" stream="" key="" value=""
  [[ -n "$report" ]] || return 0
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    stream="${record%%$'\t'*}"
    record="${record#*$'\t'}"
    key="${record%%$'\t'*}"
    value="${record#*$'\t'}"
    case "$stream" in
      out) worktree_message "output-prune-$key" "worktree=$wt $value" ;;
      err) worktree_message "output-prune-$key" "worktree=$wt $value" >&2 ;;
      *)
        worktree_message output-prune-record-unroutable "worktree=$wt stream=$stream" "Error: the prune engine named a stream this version of worktree does not know: $stream" >&2
        return 1
        ;;
    esac
  done <<<"$report"
  return 0
}

# Prune build output from each named worktree. Every worktree either reports
# what it pruned or names the reason it was kept; nothing passes silently.
# Returns 1 only when an inspection could not complete — a worktree kept for a
# stated reason is a result, not a failure, exactly as it is on the removal path.
output_prune_sweep() {
  local failed=false wt="" head="" rc=0 report="" owner="" claimed=false
  local -a engine_args=()
  if [[ ! -x "$OUTPUT_PRUNE_ENGINE" ]]; then
    worktree_message output-prune-engine-missing "$OUTPUT_PRUNE_ENGINE" "Error: the prune engine is missing or not executable; nothing was inspected." >&2
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    worktree_message output-prune-python-missing python3 "Error: --targets-only needs python3 on PATH; nothing was inspected." >&2
    return 1
  fi
  # The lease is the only ownership gate over this delete — the removal path
  # has a merged-branch proof behind the same gate and this mode has none — so
  # an unreadable guard is a refusal, not an absent lease. The preview runs
  # without it because it writes nothing.
  if [[ "$OUTPUT_PRUNE_APPLY" == true ]] && ! session_guard_available; then
    worktree_message output-prune-guard-unavailable "$SESSION_GUARD" "Error: --apply claims each worktree through the session guard, which is missing or not executable; nothing was inspected. Drop --apply to preview, which writes nothing." >&2
    return 1
  fi
  for wt in "$@"; do
    # The prune is pinned to this commit: a checkout swapped under it is a
    # different repository, and the engine refuses when HEAD no longer matches.
    # A detached HEAD is pinnable and therefore in scope, unlike removal, which
    # needs a branch to prove merged.
    head=""
    if ! head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || [[ -z "$head" ]]; then
      worktree_message output-prune-head-unreadable "worktree=$wt" "Skipped (git could not read HEAD, so the prune has no commit to pin to): $wt" >&2
      failed=true
      continue
    fi
    # No owner identity is derived: a lease blocks this sweep whether it is
    # ours or another session's, so the branch the removal path reads for its
    # identity would change no answer here.
    cleanup_probe_lease "$wt"
    case "$CLEANUP_LEASE_STATE" in
      none) ;;
      held)
        worktree_message output-prune-lease-blocked "worktree=$wt state=held" "Skipped (a session holds a guard lease, so a build may be running here): $wt" >&2
        continue
        ;;
      unmanaged)
        worktree_message output-prune-lease-blocked "worktree=$wt state=unmanaged" "Skipped (locked outside the session guard): $wt" >&2
        continue
        ;;
      *)
        worktree_message output-prune-lease-blocked "worktree=$wt state=unreadable" "Skipped (session guard state could not be read, exit $CLEANUP_LEASE_RC): $wt" >&2
        failed=true
        continue
        ;;
    esac
    # Hold the lease for the duration of the deletion, so a session claiming
    # this worktree mid-prune is made to wait rather than starting a build into
    # a directory being emptied. A preview writes nothing and takes no lease.
    claimed=false
    owner="output-prune-$$"
    if [[ "$OUTPUT_PRUNE_APPLY" == true ]]; then
      if ! "$SESSION_GUARD" claim "$wt" --owner "$owner" >/dev/null 2>&1; then
        worktree_message output-prune-claim-failed "worktree=$wt" "Skipped (could not claim the worktree for the duration of the prune): $wt" >&2
        failed=true
        continue
      fi
      claimed=true
    fi
    engine_args=(--worktree "$wt" --head "$head" --older-than-days "$OUTPUT_PRUNE_DAYS")
    if [[ "$OUTPUT_PRUNE_APPLY" == true ]]; then
      engine_args+=(--apply)
    fi
    # The report is captured, not piped: the engine's exit status is this
    # worktree's verdict, and a pipeline would hide it.
    report=""
    rc=0
    report="$("$OUTPUT_PRUNE_ENGINE" "${engine_args[@]}")" || rc=$?
    output_prune_render "$wt" "$report" || failed=true
    case "$rc" in
      0) ;;
      # The engine's own `incomplete` record named the cause; a second record
      # here would restate it.
      1) failed=true ;;
      6)
        worktree_message output-prune-head-moved "worktree=$wt" "Skipped (HEAD moved while the prune was running; nothing was removed): $wt" >&2
        ;;
      *)
        worktree_message output-prune-engine-failed "worktree=$wt exit=$rc" "Error: the prune engine exited $rc, a status this version of worktree does not define. Any records above it are what it had already done, so under --apply treat this worktree as possibly part-pruned and inspect it: $wt" >&2
        failed=true
        ;;
    esac
    if [[ "$claimed" == true ]]; then
      if ! "$SESSION_GUARD" release "$wt" --owner "$owner" >/dev/null 2>&1; then
        worktree_message output-prune-lease-stranded "worktree=$wt owner=$owner" "Error: the prune finished but its cleanup lease could not be released. This mode never takes --stale, so clear it with: $SESSION_GUARD release \"$wt\" --force" >&2
        failed=true
      fi
    fi
  done
  [[ "$failed" == false ]]
}
