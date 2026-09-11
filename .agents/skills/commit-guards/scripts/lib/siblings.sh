# shellcheck shell=bash
# Sibling gate resolution, and the doc-limits lane both hook chains run.
#
# Sibling gates resolve against the JUDGED work tree first: the shim may exec
# a hook lane from a shared install in another checkout (linked worktrees
# share one hooks directory), whose branch state must not decide which gates
# exist for the tree being judged — and a re-vendored copy in that tree gates
# it, not the install it replaces. The roots mirror the shim's rediscovery
# list, which covers a consumer's .agents/skills shape and kendex's own
# skills/ layout; the install beside the calling script serves only a tree
# carrying no copy.
#
# One copy because two hooks call it. pre-commit runs the doc-limits lane over
# the staged snapshot; pre-push runs it over the pushed tree, which that
# hook's own index-drift refusal has already held equal to HEAD. A second
# spelling in either hook would be a twin, and the two would drift apart on
# the first change to the re-vendor rule.
#
# Sourced, never executed — strict on its own terms rather than its caller's,
# like the other libraries beside it. gg_message, gg_fail and gg_project_root
# resolve at call time, so the caller's own bootstrap order is free.
set -euo pipefail

# shellcheck source=skill-roots.sh
source "${BASH_SOURCE[0]%/*}/skill-roots.sh"

# The roots gg_resolve_sibling walked, for a skip to name. A diagnostic that
# lists one of two searched places is worse than none: it sends the reader to
# the directory that was never the problem.
gg_searched_roots() { # SCRIPTS-DIR
  local project=""
  gg_project_root project "$1" || project=""
  [ "$project" = "$PWD" ] && project=""
  case "$project" in
    "") printf '%s' "$PWD" ;;
    *) printf '%s and %s' "$PWD" "$project" ;;
  esac
}

gg_resolve_sibling() { # SCRIPTS-DIR SKILL — skill directory on stdout; 1 when no side carries it
  local scripts="$1" skill="$2" base="" dir="" root="" project=""
  # The judged tree first, then the project this copy is installed under.
  # That order is the re-vendor rule: a tree carrying its own copy of a gate
  # gates its own commit or push with it, so $PWD outranks everything.
  #
  # The project root is the addition. git runs a hook from the work-tree top
  # level, which is the project root only when the two are the same
  # directory; where a kendex project sits below it the siblings are beside
  # THIS copy and nowhere near $PWD, and a sibling that failed was a gate
  # reporting nothing while the chain exited 0.
  gg_project_root project "$scripts" || project=""
  [ "$project" = "$PWD" ] && project=""
  for root in "$PWD" "$project"; do
    [ -n "$root" ] || continue
    for base in $GG_SKILL_ROOTS; do
      dir="$root/$base/$skill"
      if [ -e "$dir" ] || [ -L "$dir" ]; then
        printf '%s\n' "$dir"
        return 0
      fi
    done
  done
  dir="$scripts/../../$skill"
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    printf '%s\n' "$dir"
    return 0
  fi
  return 1
}

# The doc-limits lane, announced here and folded by the caller's own
# aggregator. Whether the SKILL is present decides, not whether its script
# happens to be runnable: a present skill with a missing, dangling or
# unexecutable script is a broken install, and a chain must never pass by
# losing a gate. -L catches a dangling symlink, which -e reports as absent.
gg_doc_limits_lane() { # SCRIPTS-DIR — 0 clean or skipped, 1 violations, 2 could not complete
  local scripts="$1" skill="" lane="" out="" status=0
  if ! skill="$(gg_resolve_sibling "$scripts" doc-limits)"; then
    gg_message lane-absent "doc-limits roots=$(gg_searched_roots "$scripts") skills=$GG_SKILL_ROOTS fallback=$scripts/../../doc-limits" "=== $GG_CHECK: doc-limits not installed — skipped (no doc-limits skill under $(gg_searched_roots "$scripts") ($GG_SKILL_ROOTS), nor at $scripts/../../doc-limits)"
    return 0
  fi
  lane="$skill/scripts/doc-limits"
  [ -x "$lane" ] || gg_fail lane-missing "$lane" "the doc-limits skill is installed at $skill but $lane is missing or not executable — reinstall it"
  gg_message step doc-limits "=== $GG_CHECK: doc-limits (document byte ceilings)"
  out="$("$lane" --staged 2>&1)" || status=$?
  [ -n "$out" ] && printf '%s\n' "$out"
  case "$status" in
    0) return 0 ;;
    1) return 1 ;;
  esac
  gg_message step-incomplete "doc-limits:$status" "$GG_CHECK: step 'doc-limits' did not complete (exit $status)"
  return 2
}
