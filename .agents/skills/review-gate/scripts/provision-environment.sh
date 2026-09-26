#!/usr/bin/env bash
# Review-gate provision — the owner-run write half of the organization
# standard. Shipped by the kendex review-gate skill, vendored at
# .agents/skills/review-gate/scripts/.
#
# It converges the standard's environment (standard.json: its name and
# secret names) in every repository of one organization: the environment
# exists, deploys from the repository's default branch only, and holds each
# secret the standard names. Creating an environment needs Administration
# write and setting an environment secret needs Environments write, which no
# lane credential may hold, so this runs from the organization owner's own
# machine under the owner's `gh` credential and never in CI or on a lane
# host. validate-standard.sh is the read-only half that reports the result.
#
# A secret is set only where the environment lacks its name: GitHub never
# returns a secret's value, so a present name is current. A re-run changes
# nothing in a repository already provisioned and provisions a new one.
#
# Report protocol, one record per repository on stdout:
#   provision repo=OWNER/NAME result=RESULT
# then one `  step=STEP value=VALUE` line per step taken (or planned, under
# --dry-run), in order, and on a failure one indented line of explanation.
# RESULT and STEP are the words print_usage lists; VALUE is %q-escaped. A
# last `provision-total repositories=N changed=N current=N failed=N` line
# counts the records. Human explanation is not parsed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || {
  printf 'review-gate-error=script-directory value=%q\n' "${BASH_SOURCE[0]}" >&2
  exit 2
}
if [ ! -r "$SCRIPT_DIR/lib/diagnostics.sh" ]; then
  printf 'review-gate-error=diagnostics-load value=%q\n%s\n' "$SCRIPT_DIR/lib/diagnostics.sh" 'Could not load the diagnostics library.' >&2
  exit 2
fi
. "$SCRIPT_DIR/lib/diagnostics.sh" 2>/dev/null || {
  printf 'review-gate-error=diagnostics-load value=%q\n%s\n' "$SCRIPT_DIR/lib/diagnostics.sh" 'Could not load the diagnostics library.' >&2
  exit 2
}

print_usage() {
  cat <<'USAGE'
Usage: provision-environment.sh --org ORG [--dry-run]
       provision-environment.sh --help

Creates or corrects the organization standard's environment (standard.json
in the skill names it and its secrets) in every repository of ORG that is
not archived. ORG must have the standard's app installed on all of its
repositories, the installation validate-standard.sh's standard-app row
requires; any other installation is refused, since this command cannot
list a selection. The repository list must hold as many repositories,
archived ones included, as the organization reports owning; a credential
that sees fewer is refused before any write.

Per repository it:
  - creates the environment where it is absent, deploying from custom
    branch policies;
  - switches an existing environment that deploys from every branch, or
    from protected branches, to custom branch policies, unless it carries a
    protection rule besides its branch policy (required reviewers, a wait
    timer): the switch could drop that rule, so the repository fails and
    the owner switches it by hand;
  - leaves exactly one branch policy, the repository's default branch,
    deleting any other;
  - sets each standard secret the environment lacks by name. A present
    secret is never rewritten; to replace a value, delete that secret in
    GitHub and run this again.

Secret values come from the environment of this command: each secret the
standard names is read from the variable of the same name, for example
  FLEET_GH_APP_ID=123456 \
  FLEET_GH_APP_PRIVATE_KEY="$(cat app.private-key.pem)" \
  provision-environment.sh --org my-org
A run that is not --dry-run refuses before any write when one is unset or
empty.

--dry-run  reads everything and writes nothing: each repository's record
           names the steps a run would take. No secret value is needed.

Credential: the `gh` login of the organization owner, on the owner's own
machine; never a lane's or CI's token. The organization's private
repository count is returned to an owner only. As GitHub App or
fine-grained permissions it needs organization Administration read (the
installation), repository Metadata read (the repositories), Actions read
(the environments and their branch policies), Administration write (the
environment and its branch policies) and Environments write (its secrets).

Output: one `provision repo=OWNER/NAME result=RESULT` record per
repository. RESULT is created, updated, current or failed, and under
--dry-run would-create, would-update, current or failed. Under it, one
`  step=STEP value=VALUE` line per step, in order:
  create-environment  VALUE the environment, created on custom policies
  switch-policy       VALUE every-branch or protected-branches, the policy
                      switched to custom policies
  keep-only-policy    VALUE branch:BRANCH (--dry-run after switch-policy,
                      whose policies cannot be read before the switch)
  delete-policy       VALUE TYPE:NAME, a branch policy deleted
  add-policy          VALUE branch:BRANCH, the default branch added
  set-secret          VALUE the secret name set
A failed record ends with one indented line naming the cause. The last line
is `provision-total repositories=N changed=N current=N failed=N`.

Exit codes:
  0  every repository is provisioned (or, under --dry-run, was read)
  1  at least one repository failed; the others were still provisioned
  2  nothing was attempted (bad arguments, a missing secret value, jq
     missing, a missing or malformed standard.json, the installation, the
     organization or the repositories could not be read, the app not
     installed on all repositories, a repository list shorter than the
     organization's count, or no repository that is not archived)
USAGE
}

die() { # CODE VALUE MESSAGE
  rg_message error "$@" >&2
  exit 2
}

ORG=""
DRY_RUN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help | -h)
      print_usage
      exit 0
      ;;
    --org)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die org-missing "" "--org needs the organization's login"
      ORG="$2"
      shift
      ;;
    --dry-run) DRY_RUN=1 ;;
    *) die unknown-argument "$1" "provision-environment.sh: unknown argument (run --help)" ;;
  esac
  shift
done
[ -n "$ORG" ] || die org-missing "" "--org names the organization to provision (run --help)"

if [ ! -r "$SCRIPT_DIR/lib/standard.sh" ] || ! . "$SCRIPT_DIR/lib/standard.sh" 2>/dev/null; then
  die standard-lib-load "$SCRIPT_DIR/lib/standard.sh" "could not load the standard library"
fi
rg_standard_load "$SCRIPT_DIR/../standard.json" || exit 2

if [ "$DRY_RUN" -eq 0 ]; then
  for name in $WANT_SECRETS; do
    [ -n "${!name:-}" ] || die secret-value-missing "$name" "set $name to the value the $WANT_ENV environment's secret of that name must hold, or pass --dry-run"
  done
fi

SCRATCH="$(mktemp -d)" || die scratch "${TMPDIR:-/tmp}" "could not create a scratch directory"
trap 'rm -rf -- "$SCRATCH"' EXIT

# Runs `gh ARGS...` on the caller's stdin, keeping stdout in GH_OUT; a
# failure sets GH_ERR to gh's first stderr line, or its exit status when it
# printed none.
GH_OUT=""
GH_ERR=""
gh_run() { # ARGS...
  local rc=0
  GH_ERR=""
  GH_OUT="$(gh "$@" 2>"$SCRATCH/err")" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  if ! GH_ERR="$(sed -n '1p' "$SCRATCH/err")" || [ -z "$GH_ERR" ]; then
    GH_ERR="gh exited $rc"
  fi
  return 1
}

ORG_URI="$(rg_uri "$ORG")"
ENV_URI="$(rg_uri "$WANT_ENV")"

gh_run api "orgs/$ORG_URI/installations" --paginate --jq ".installations[] | select(.app_slug == $(jq -n --arg v "$WANT_APP" '$v')) | .repository_selection" ||
  die installation-read "$ORG" "the app installations of $ORG could not be read: $GH_ERR"
case "$GH_OUT" in
  all) ;;
  "") die app-absent "$WANT_APP" "$WANT_APP is not installed in $ORG; install it on all repositories, then run this again" ;;
  *) die app-selection "$GH_OUT" "$WANT_APP is installed on a selection of $ORG's repositories; the standard installs it on all of them, the only installation this command can enumerate" ;;
esac

# The repository list shows only what the credential can see, so a
# credential narrowed to some repositories lists a subset with no error. The
# organization's own count, archived repositories included, is the bound it
# must reach; GitHub returns total_private_repos to an owner only.
gh_run api "orgs/$ORG_URI" --jq 'if (.public_repos | type) == "number" and (.total_private_repos | type) == "number" then .public_repos + .total_private_repos else "unreadable" end' ||
  die organization-read "$ORG" "the organization $ORG could not be read: $GH_ERR"
case "$GH_OUT" in
  "" | *[!0-9]*) die organization-count "$ORG" "$ORG reported no repository count; GitHub returns the private count to an organization owner only, so run this under the owner's credential" ;;
esac
OWNED="$GH_OUT"

gh_run api "orgs/$ORG_URI/repos?per_page=100" --paginate --jq '.[] | [.full_name, .default_branch, (.archived | tostring)] | @tsv' ||
  die repositories-read "$ORG" "the repositories of $ORG could not be read: $GH_ERR"
LISTED=0
REPOS=""
while IFS='	' read -r full branch archived; do
  [ -n "$full" ] || continue
  LISTED=$((LISTED + 1))
  [ "$archived" = true ] || REPOS="${REPOS:+$REPOS
}$full	$branch"
done <<EOF_LISTED
$GH_OUT
EOF_LISTED
[ "$LISTED" -ge "$OWNED" ] ||
  die repositories-partial "$LISTED/$OWNED" "the credential lists $LISTED of the $OWNED repositories $ORG owns; a token limited to some repositories hides the rest, so run this under the owner's credential over all of them"
[ -n "$REPOS" ] || die repositories-none "$ORG" "$ORG has no repository that is not archived, so there is nothing to provision"

# ------------------------------------------------------------- steps ---

# STEPS holds the step lines of what was done (or, under --dry-run, would
# be) in the current repository; CAUSE is set by the step or read that
# failed there.
STEPS=""
CAUSE=""
step() { # STEP VALUE WRITER ARGS...
  local key="$1" value="$2" line
  shift 2
  if [ "$DRY_RUN" -eq 0 ] && ! "$@"; then
    CAUSE="$key $value: $GH_ERR"
    return 1
  fi
  line="$(printf '  step=%s value=%q' "$key" "$value")"
  STEPS="${STEPS:+$STEPS
}$line"
}

put_environment() { # FULL
  gh_run api -X PUT "repos/$1/environments/$ENV_URI" --input - \
    <<<'{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}'
}
add_branch_policy() { # FULL BRANCH
  gh_run api -X POST "repos/$1/environments/$ENV_URI/deployment-branch-policies" -f "name=$2" -f type=branch
}
delete_branch_policy() { # FULL ID
  gh_run api -X DELETE "repos/$1/environments/$ENV_URI/deployment-branch-policies/$2"
}
# The value goes on stdin, never in argv, where another process could read it.
set_secret() { # FULL NAME
  local rc=0 name="$2"
  GH_ERR=""
  printf '%s' "${!name}" | gh secret set "$name" --env "$WANT_ENV" --repo "$1" >/dev/null 2>"$SCRATCH/err" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  if ! GH_ERR="$(sed -n '1p' "$SCRATCH/err")" || [ -z "$GH_ERR" ]; then
    GH_ERR="gh exited $rc"
  fi
  return 1
}

# Converges the branch policies of an environment already on custom
# policies to the default branch alone.
converge_branch_policies() { # FULL BRANCH
  local id type name have=0 policies
  if ! gh_run api "repos/$1/environments/$ENV_URI/deployment-branch-policies" --paginate --jq '.branch_policies[] | [.id, (.type // "branch"), .name] | @tsv'; then
    CAUSE="the branch policies of $WANT_ENV could not be read: $GH_ERR"
    return 1
  fi
  policies="$GH_OUT"
  while IFS='	' read -r id type name; do
    [ -n "$id" ] || continue
    if [ "$type" = branch ] && [ "$name" = "$2" ]; then
      have=1
    else
      step delete-policy "$type:$name" delete_branch_policy "$1" "$id" </dev/null || return 1
    fi
  done <<EOF_POLICIES
$policies
EOF_POLICIES
  [ "$have" -eq 1 ] || step add-policy "branch:$2" add_branch_policy "$1" "$2"
}

# Sets STEPS and CAUSE for one repository and prints its record.
CHANGED=0
CURRENT=0
FAILED=0
provision() { # FULL BRANCH
  local full="$1" branch="$2" environment kind rules created=0 listed="" name result
  STEPS=""
  CAUSE=""
  if ! gh_run api "repos/$full/environments" --paginate --jq ".environments[] | select(.name == $(jq -n --arg v "$WANT_ENV" '$v')) | @json"; then
    CAUSE="the environments could not be read: $GH_ERR"
  else
    environment="$GH_OUT"
    case "$environment" in
      "")
        created=1
        step create-environment "$WANT_ENV" put_environment "$full" &&
          step add-policy "branch:$branch" add_branch_policy "$full" "$branch" || true
        ;;
      *)
        kind="$(jq -r '.deployment_branch_policy | if . == null then "every-branch" elif .custom_branch_policies == true and .protected_branches == false then "custom" else "protected-branches" end' <<<"$environment" 2>/dev/null)" ||
          kind=unparsed
        case "$kind" in
          custom) converge_branch_policies "$full" "$branch" || true ;;
          every-branch | protected-branches)
            # The switch PUTs the environment with its branch policy alone;
            # a protection rule it does not carry could be dropped.
            rules="$(jq -r '[.protection_rules[]? | .type | select(. != "branch_policy")] | unique | join(",")' <<<"$environment" 2>/dev/null)" ||
              rules=unparsed
            if [ -n "$rules" ]; then
              CAUSE="$WANT_ENV deploys from $kind and carries protection rules ($rules) a switch to custom branch policies could drop; switch it to branch:$branch by hand"
            elif step switch-policy "$kind" put_environment "$full"; then
              if [ "$DRY_RUN" -eq 1 ]; then
                step keep-only-policy "branch:$branch" true
              else
                converge_branch_policies "$full" "$branch" || true
              fi
            fi
            ;;
          *) CAUSE="the environment $WANT_ENV did not parse: $environment" ;;
        esac
        if [ -z "$CAUSE" ]; then
          if gh_run api "repos/$full/environments/$ENV_URI/secrets" --paginate --jq '.secrets[].name'; then
            listed="$GH_OUT"
          else
            CAUSE="the secrets of $WANT_ENV could not be read: $GH_ERR"
          fi
        fi
        ;;
    esac
    if [ -z "$CAUSE" ]; then
      while IFS= read -r name; do
        [ -n "$name" ] || continue
        step set-secret "$name" set_secret "$full" "$name" || break
      done <<EOF_MISSING
$(rg_standard_missing "$listed")
EOF_MISSING
    fi
  fi

  if [ -n "$CAUSE" ]; then
    result=failed
    FAILED=$((FAILED + 1))
  elif [ -z "$STEPS" ]; then
    result=current
    CURRENT=$((CURRENT + 1))
  else
    if [ "$DRY_RUN" -eq 1 ]; then
      [ "$created" -eq 1 ] && result=would-create || result=would-update
    else
      [ "$created" -eq 1 ] && result=created || result=updated
    fi
    CHANGED=$((CHANGED + 1))
  fi
  printf 'provision repo=%q result=%s\n' "$full" "$result"
  if [ -n "$STEPS" ]; then
    printf '%s\n' "$STEPS"
  fi
  if [ -n "$CAUSE" ]; then
    printf '  %s\n' "$CAUSE"
  fi
}

TOTAL=0
while IFS='	' read -r full branch; do
  [ -n "$full" ] || continue
  TOTAL=$((TOTAL + 1))
  provision "$full" "$branch" </dev/null
done <<EOF_REPOS
$REPOS
EOF_REPOS

printf 'provision-total repositories=%s changed=%s current=%s failed=%s\n' "$TOTAL" "$CHANGED" "$CURRENT" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
