#!/usr/bin/env bash
# Whether a branch that does not contain its base needs a rebase before it is
# pushed or reviewed. A base whose merge queue rebuilds every group on the
# current base, and whose rules demand no up-to-date branch, needs the branch
# only to merge cleanly onto it; every other base needs the branch to contain
# it. `worktree push` and orch's `base-freshness` both ask here, so the push
# and the review gate cannot read one branch two ways.
#
# Sourced by scripts/worktree and by orch/scripts/base-freshness. Needs git,
# and gh and jq for the rules read; either one missing reads `unverified`.

# Sets BASE_POLICY to the merge rule GitHub reports for BRANCH, from the
# effective branch rules (organization and repository rulesets together):
#   queue       a merge_queue rule, and no required_status_checks rule that
#               demands an up-to-date branch
#   strict      a required_status_checks rule demands an up-to-date branch
#   no-queue    no merge_queue rule
#   unverified  the read failed
# A definite answer is kept in the checkout's own git dir as
# `kendex-base-policy`, keyed by BRANCH, so a checkout reads GitHub once. An
# unverified read is not kept, and a cache that cannot be written only costs
# the next call another read. The repository is the one gh resolves from WT:
# an inherited GH_REPO or GITHUB_REPOSITORY outranks the working directory for
# gh, so both come off, or another repository's policy would stand for this
# checkout's base.
base_policy_read() { # WT BRANCH
  local wt="$1" branch="$2" cache="" line="" uri="" rules=""
  BASE_POLICY=unverified
  cache="$(git -C "$wt" rev-parse --git-path kendex-base-policy 2>/dev/null)" || cache=""
  [[ -z "$cache" || "$cache" == /* ]] || cache="$wt/$cache"
  if [[ -n "$cache" && -f "$cache" ]] && IFS= read -r line <"$cache"; then
    case "$line" in
      "$branch queue" | "$branch strict" | "$branch no-queue")
        BASE_POLICY="${line##* }"
        return 0
        ;;
    esac
  fi
  command -v gh >/dev/null 2>&1 || return 0
  uri="$(jq -rn --arg v "$branch" '$v | @uri' 2>/dev/null)" || return 0
  rules="$(cd -- "$wt" && env -u GH_REPO -u GITHUB_REPOSITORY gh api "repos/{owner}/{repo}/rules/branches/$uri" --paginate \
    --jq '.[] | select(.type == "merge_queue" or .type == "required_status_checks") | "\(.type) \(.parameters.strict_required_status_checks_policy // false)"' 2>/dev/null)" \
    || return 0
  case $'\n'"$rules"$'\n' in
    *$'\nrequired_status_checks true\n'*) BASE_POLICY=strict ;;
    *$'\nmerge_queue '*) BASE_POLICY=queue ;;
    *) BASE_POLICY=no-queue ;;
  esac
  [[ -z "$cache" ]] || printf '%s %s\n' "$branch" "$BASE_POLICY" 2>/dev/null >"$cache" || true
}

# Sets BASE_READING to what the branch at WT's HEAD needs against BASE_REF,
# the remote-tracking ref of BRANCH, and BASE_POLICY as base_policy_read left
# it (empty when the branch already contains the base and no read ran):
#   contained       BASE_REF is already in the branch
#   merges-cleanly  queue policy, and a trial merge onto BASE_REF is clean
#   conflicts       queue policy, and that trial merge conflicts
#   trial-failed    queue policy, and the trial merge could not run
#   behind          any other policy
# Only contained and merges-cleanly let the branch go without a rebase.
base_reading() { # WT BRANCH BASE_REF
  local wt="$1" branch="$2" base_ref="$3" rc=0
  BASE_POLICY=""
  if git -C "$wt" merge-base --is-ancestor "$base_ref" HEAD 2>/dev/null; then
    BASE_READING=contained
    return 0
  fi
  base_policy_read "$wt" "$branch"
  if [[ "$BASE_POLICY" != queue ]]; then
    BASE_READING=behind
    return 0
  fi
  git -C "$wt" merge-tree --write-tree "$base_ref" HEAD >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) BASE_READING=merges-cleanly ;;
    1) BASE_READING=conflicts ;;
    *) BASE_READING=trial-failed ;;
  esac
}
