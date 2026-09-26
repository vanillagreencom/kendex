#!/usr/bin/env bash
# Review-gate validate — the organization-standard half. Shipped by the
# kendex review-gate skill, vendored at .agents/skills/review-gate/scripts/.
#
# READ-ONLY: every GitHub call below is a GET. It answers whether the
# repository's GitHub-side settings match the organization standard. The
# standard's values (required contexts, app, environment, secret names)
# live in ../standard.json; the rows that hold no value (organization
# source, merge queue, thread resolution, Copilot review, no classic
# protection, zero bypass actors) are fixed here. Its subject is GitHub
# state, not the checkout, so validate.sh does not run it: CI's token
# cannot read bypass actors, installations or secret names, and every such
# row would be unreadable there. The permission each row's reads need is in
# print_usage.
#
# Report protocol: ok/FAIL check=KEY value=VALUE, then indented
# explanation, the same records validate.sh prints. VALUE is the observed
# state; `unreadable` in it means a read failed, which is never a match.
# Human explanation is not parsed. Full contract: print_usage or --help.
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
Usage: validate-standard.sh [--help]   (no positional arguments)

Reports, read-only, whether THIS repository's GitHub settings match the
organization standard. standard.json in the skill holds its values. The
repository is the one `gh` resolves: GH_REPO when set, else the checkout's
remote.

One verdict line per row, VALUE being what was observed:
  standard-ruleset-source           every effective default-branch rule comes
                                    from an organization ruleset
  standard-merge-queue              the default branch requires the merge queue
  standard-required-contexts        the required contexts are exactly the
                                    standard's required_contexts
  standard-conversation-resolution  a pull-request rule requires every review
                                    thread resolved
  standard-copilot-review           a rule requests a Copilot review
  standard-bypass-actors            no ruleset behind those rules has a bypass
                                    actor
  standard-classic-protection       the default branch has no classic branch
                                    protection beside the rulesets
  standard-app                      the standard's app is installed on every
                                    repository of the organization
  standard-environment              the standard's environment exists and
                                    deploys from the default branch only
  standard-environment-secrets      that environment holds every secret the
                                    standard names (names only)
  standard-secrets-outside          no other secret carries one of those names:
                                    repository Actions secrets, every
                                    organization Actions secret (shared with
                                    this repository or not), repository and
                                    organization Dependabot secrets, and
                                    every other environment of the repository

A failed read reports its row as FAIL with `unreadable` in the value, never
as a match. The permission each row's reads need, as GitHub App permissions:
  ruleset-source, merge-queue,      the branch's rules: Metadata read
  required-contexts, conversation-
  resolution, copilot-review
  bypass-actors                     each ruleset, read where it lives
                                    (orgs/OWNER/rulesets/ID for an
                                    organization ruleset,
                                    repos/OWNER/NAME/rulesets/ID for a
                                    repository ruleset): the bypass_actors
                                    field is returned only to a caller with write
                                    access to the ruleset (Administration
                                    write where the ruleset lives, the
                                    organization's for an organization
                                    ruleset); a withheld field is unreadable
  classic-protection                the branch: Contents read
  app                               the organization's installations:
                                    organization Administration read
  environment                       environments and branch policies:
                                    Actions read
  environment-secrets               the environment's secret names:
                                    Environments read
  secrets-outside                   repository Actions secret names:
                                    Secrets read; organization Actions
                                    secret names: organization Secrets read;
                                    repository Dependabot secret names:
                                    Dependabot secrets read; organization
                                    Dependabot secret names: organization
                                    Dependabot secrets read; other
                                    environments' secret names: Environments
                                    read (and Actions read to list them)
A token holding only repository Administration, Metadata, Actions,
Environments and Secrets read plus organization Secrets read reads
bypass-actors, classic-protection and app as unreadable, and the Dependabot
scopes of secrets-outside as unreadable.

Exit codes:
  0  every row matched
  1  at least one FAIL line
  2  the check could not run at all (bad arguments, a missing or malformed
     standard.json, the repository itself could not be read)
USAGE
}

if [ "$#" -eq 1 ] && { [ "$1" = "--help" ] || [ "$1" = "-h" ]; }; then
  print_usage
  exit 0
fi
if [ "$#" -gt 0 ]; then
  rg_message error unknown-arguments "$#" "validate-standard.sh: unknown argument list ($# argument(s), first: '${1}') — no positional arguments (run --help)" >&2
  exit 2
fi

die() { # CODE VALUE MESSAGE
  rg_message error "$@" >&2
  exit 2
}

if [ ! -r "$SCRIPT_DIR/lib/standard.sh" ] || ! . "$SCRIPT_DIR/lib/standard.sh" 2>/dev/null; then
  die standard-lib-load "$SCRIPT_DIR/lib/standard.sh" "could not load the standard library"
fi
rg_standard_load "$SCRIPT_DIR/../standard.json" || exit 2

SCRATCH="$(mktemp -d)" || die scratch "${TMPDIR:-/tmp}" "could not create a scratch directory"
trap 'rm -rf -- "$SCRATCH"' EXIT

# READ_OUT holds stdout; a failed read sets READ_ERR to gh's first stderr
# line. Both belong to the latest call only, so a caller that reads in a
# loop records READ_ERR per read inside the loop.
READ_OUT=""
READ_ERR=""
read_api() { # ENDPOINT FILTER [--paginate]
  local rc=0
  READ_ERR=""
  READ_OUT="$(gh api ${3:+"$3"} "$1" --jq "$2" </dev/null 2>"$SCRATCH/err")" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  if ! READ_ERR="$(sed -n '1p' "$SCRATCH/err")" || [ -z "$READ_ERR" ]; then
    READ_ERR="gh exited $rc"
  fi
  return 1
}
jq_string() { jq -n --arg v "$1" '$v'; }

read_api "repos/{owner}/{repo}" '[.full_name, .default_branch] | @tsv' ||
  die repository-read "${GH_REPO:-}" "could not read the repository: $READ_ERR"
FULL="${READ_OUT%%	*}"
BRANCH="${READ_OUT#*	}"
case "$FULL" in
  */*) ;;
  *) die repository-read "$READ_OUT" "the repository read named no OWNER/NAME" ;;
esac
[ -n "$BRANCH" ] && [ "$BRANCH" != "$READ_OUT" ] ||
  die repository-read "$READ_OUT" "the repository read named no default branch"
OWNER="${FULL%%/*}"
BRANCH_URI="$(rg_uri "$BRANCH")"

PASS=0
FAILED=0
ok() { PASS=$((PASS + 1)); rg_report ok "$@"; }
bad() { FAILED=$((FAILED + 1)); rg_report FAIL "$@"; }

# ------------------------------------------------------ default branch ---

RULE_ROWS="standard-ruleset-source standard-merge-queue standard-required-contexts standard-conversation-resolution standard-copilot-review standard-bypass-actors"
RULES=""
if read_api "repos/$FULL/rules/branches/$BRANCH_URI" '.[] | @json' --paginate &&
  RULES="$(printf '%s' "$READ_OUT" | jq -s '.' 2>/dev/null)" &&
  jq -e 'all(.[]; type == "object" and (.type | type) == "string")' >/dev/null 2>&1 <<<"$RULES"; then
  # RULES already parsed as an array of rule objects, so a failed query
  # here is this script's own fault.
  rules() { jq -r "$1" <<<"$RULES" || die rules-query "$1" "jq could not evaluate a query over the parsed rules"; }

  sources="$(rules 'if length == 0 then "none" else ([.[] | select(.ruleset_source_type != "Organization") | "\(.ruleset_source_type):\(.ruleset_id)"] | unique | join(",")) end')"
  case "$sources" in
    "") ok standard-ruleset-source Organization "every rule on $BRANCH comes from an organization ruleset" ;;
    none) bad standard-ruleset-source none "no ruleset applies to $BRANCH" ;;
    *) bad standard-ruleset-source "$sources" "rules on $BRANCH come from rulesets that are not the organization's; the standard deletes each per-repository ruleset" ;;
  esac

  if [ "$(rules 'any(.[]; .type == "merge_queue")')" = true ]; then
    ok standard-merge-queue present "$BRANCH requires the merge queue"
  else
    bad standard-merge-queue absent "$BRANCH has no merge-queue rule"
  fi

  if contexts="$(rules '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]?.context] | unique | join(";")')" &&
    [ "$contexts" = "$WANT_CONTEXTS" ]; then
    ok standard-required-contexts "$contexts" "$BRANCH requires exactly the standard's contexts"
  else
    bad standard-required-contexts "$contexts" "$BRANCH requires these contexts; the standard requires exactly: $WANT_CONTEXTS"
  fi

  if [ "$(rules 'any(.[]; .type == "pull_request" and .parameters.required_review_thread_resolution == true)')" = true ]; then
    ok standard-conversation-resolution true "$BRANCH requires every review thread resolved"
  else
    bad standard-conversation-resolution false "no pull-request rule on $BRANCH requires review threads resolved"
  fi

  if [ "$(rules 'any(.[]; .type == "copilot_code_review")')" = true ]; then
    ok standard-copilot-review present "$BRANCH requests a Copilot review"
  else
    bad standard-copilot-review absent "no rule on $BRANCH requests a Copilot review"
  fi

  # GitHub returns bypass_actors only to a caller with write access to the
  # ruleset and omits the field otherwise, so a missing field is
  # unreadable and never zero. Each ruleset is read at the level that owns
  # it: an organization owner sees an organization ruleset's actors through
  # the organization endpoint, not through the repository one.
  actors=0
  unreadable=""
  causes=""
  owned="$(rules '[.[] | select(.ruleset_id != null) | "\(.ruleset_source_type) \(.ruleset_id)"] | unique | .[]')"
  while read -r source id; do
    [ -n "$id" ] || continue
    case "$source" in
      Organization) endpoint="orgs/$OWNER/rulesets/$id" ;;
      Repository) endpoint="repos/$FULL/rulesets/$id" ;;
      *)
        unreadable="${unreadable:+$unreadable,}$id"
        causes="${causes:+$causes
}$id: source $source has no ruleset read here"
        continue
        ;;
    esac
    if ! read_api "$endpoint" 'if has("bypass_actors") then (.bypass_actors | length | tostring) else "withheld" end'; then
      unreadable="${unreadable:+$unreadable,}$id"
      causes="${causes:+$causes
}$id: $READ_ERR"
    elif [ "$READ_OUT" = withheld ]; then
      unreadable="${unreadable:+$unreadable,}$id"
      causes="${causes:+$causes
}$id: bypass_actors withheld, which GitHub does without write access to the ruleset"
    else
      actors=$((actors + READ_OUT))
    fi
  done <<EOF_OWNED
$owned
EOF_OWNED
  if [ -n "$unreadable" ]; then
    bad standard-bypass-actors "unreadable:$unreadable" "the bypass actors of these rulesets could not be read:
$causes"
  elif [ "$actors" -eq 0 ]; then
    ok standard-bypass-actors 0 "no ruleset on $BRANCH has a bypass actor"
  else
    bad standard-bypass-actors "$actors" "rulesets on $BRANCH carry $actors bypass actor(s); the standard has none"
  fi
else
  why="${READ_ERR:-the response is not an array of rule objects}"
  for check in $RULE_ROWS; do
    bad "$check" unreadable "the effective rules of $BRANCH could not be read: $why"
  done
fi

# The rules endpoint answers for rulesets only. Classic protection is a
# second, independent route: its own required contexts, and an admin merge
# when it does not enforce admins.
if read_api "repos/$FULL/branches/$BRANCH_URI" '.protection.enabled | if type == "boolean" then (if . then "on" else "off" end) else error("protection.enabled is not a boolean") end'; then
  case "$READ_OUT" in
    off) ok standard-classic-protection off "$BRANCH has no classic branch protection" ;;
    on) bad standard-classic-protection on "$BRANCH has classic branch protection beside the rulesets; the standard holds every rule in the organization rulesets, so remove it" ;;
    *) bad standard-classic-protection unreadable "the branch read answered neither on nor off" ;;
  esac
else
  bad standard-classic-protection unreadable "the branch $BRANCH could not be read: $READ_ERR"
fi

# ------------------------------------------------------------- the app ---

if read_api "orgs/$OWNER/installations" ".installations[] | select(.app_slug == $(jq_string "$WANT_APP")) | .repository_selection" --paginate; then
  case "$READ_OUT" in
    all) ok standard-app all "$WANT_APP is installed on every repository of $OWNER" ;;
    "") bad standard-app absent "$WANT_APP is not installed in $OWNER" ;;
    *) bad standard-app "$READ_OUT" "$WANT_APP is installed on a selection of repositories; the standard installs it on all of them" ;;
  esac
else
  bad standard-app unreadable "the installations of $OWNER could not be read: $READ_ERR"
fi

# --------------------------------------------------------- environment ---

ENV_URI="$(rg_uri "$WANT_ENV")"
# The environment rows' one remedy: no lane credential may create an
# environment or write its secrets, so the owner converges it.
PROVISION="The organization owner converges it from their own machine: scripts/provision-environment.sh --org $OWNER in this skill"
# ENVS is the environments list as one JSON array, or empty when the read
# failed; every environment row and the other-environment scopes below
# branch on it.
ENVS=""
ENVS_ERR=""
if read_api "repos/$FULL/environments" '.environments[] | @json' --paginate &&
  ENVS="$(printf '%s' "$READ_OUT" | jq -s '.' 2>/dev/null)" &&
  jq -e 'all(.[]; type == "object" and (.name | type) == "string")' >/dev/null 2>&1 <<<"$ENVS"; then
  :
else
  ENVS=""
  ENVS_ERR="${READ_ERR:-the response is not a list of named environments}"
fi

ENV_PRESENT=unknown
if [ -n "$ENVS" ]; then
  policy="$(jq -r --arg n "$WANT_ENV" 'map(select(.name == $n)) | if length == 0 then "" else (.[0].deployment_branch_policy | @json) end' <<<"$ENVS")" ||
    die environments-query "$WANT_ENV" "jq could not evaluate a query over the parsed environments"
  case "$policy" in
    "") ENV_PRESENT=no; bad standard-environment absent "the environment $WANT_ENV does not exist. $PROVISION" ;;
    null) ENV_PRESENT=yes; bad standard-environment unrestricted "$WANT_ENV deploys from every branch; the standard allows the default branch only. $PROVISION" ;;
    *)
      ENV_PRESENT=yes
      kind="$(jq -r 'if .custom_branch_policies == true and .protected_branches == false then "custom" elif .protected_branches == true then "protected-branches" else "malformed" end' <<<"$policy" 2>/dev/null)" || kind=malformed
      if [ "$kind" != custom ]; then
        bad standard-environment "$kind" "$WANT_ENV does not deploy from a custom branch policy; the standard allows the default branch only. $PROVISION"
      elif read_api "repos/$FULL/environments/$ENV_URI/deployment-branch-policies" '.branch_policies[] | "\(.type // "branch"):\(.name)"' --paginate; then
        observed="custom:$(printf '%s' "$READ_OUT" | tr '\n' ',')"
        if [ "$READ_OUT" = "branch:$BRANCH" ]; then
          ok standard-environment "$observed" "$WANT_ENV deploys from $BRANCH only"
        else
          bad standard-environment "$observed" "$WANT_ENV deploys from these branch policies; the standard allows branch:$BRANCH only. $PROVISION"
        fi
      else
        bad standard-environment unreadable "the branch policies of $WANT_ENV could not be read: $READ_ERR"
      fi
      ;;
  esac
else
  bad standard-environment unreadable "the environments could not be read: $ENVS_ERR"
fi

case "$ENV_PRESENT" in
  yes)
    if read_api "repos/$FULL/environments/$ENV_URI/secrets" '.secrets[].name' --paginate; then
      listed="$READ_OUT"
      held="$(rg_standard_held "$listed" | paste -sd ';' -)"
      if missing="$(rg_standard_missing "$listed" | paste -sd ';' -)" && [ -z "$missing" ]; then
        ok standard-environment-secrets "$held" "$WANT_ENV holds every secret the standard names"
      else
        bad standard-environment-secrets "$held" "$WANT_ENV lacks: $missing. $PROVISION"
      fi
    else
      bad standard-environment-secrets unreadable "the secrets of $WANT_ENV could not be read: $READ_ERR"
    fi
    ;;
  no) bad standard-environment-secrets absent "the environment $WANT_ENV does not exist, so it holds no secret. $PROVISION" ;;
  unknown) bad standard-environment-secrets unreadable "the environments could not be read, so $WANT_ENV's secrets were not asked for" ;;
esac

# A secret of the same name anywhere else is readable by a workflow on a
# branch the environment's policy excludes, which is what that policy
# exists to prevent. Each scope is one LABEL<TAB>ENDPOINT line. The
# organization scopes read the organization-wide lists: a secret shared
# only with other repositories is still outside the environment.
scopes="repository	repos/$FULL/actions/secrets
organization	orgs/$OWNER/actions/secrets
dependabot	repos/$FULL/dependabot/secrets
dependabot-organization	orgs/$OWNER/dependabot/secrets"
outside=""
unreadable=""
causes=""
if [ -n "$ENVS" ]; then
  others="$(jq -r --arg n "$WANT_ENV" '.[] | select(.name != $n) | .name' <<<"$ENVS")" ||
    die environments-query "$WANT_ENV" "jq could not evaluate a query over the parsed environments"
  while IFS= read -r env_name; do
    [ -n "$env_name" ] || continue
    scopes="$scopes
environment:$env_name	repos/$FULL/environments/$(rg_uri "$env_name")/secrets"
  done <<EOF_OTHERS
$others
EOF_OTHERS
else
  unreadable="environments"
  causes="environments: $ENVS_ERR"
fi
while IFS='	' read -r label endpoint; do
  if read_api "$endpoint" '.secrets[].name' --paginate; then
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      outside="${outside:+$outside;}$label:$name"
    done <<EOF_HELD
$(rg_standard_held "$READ_OUT")
EOF_HELD
  else
    unreadable="${unreadable:+$unreadable,}$label"
    causes="${causes:+$causes
}$label: $READ_ERR"
  fi
done <<EOF_SCOPES
$scopes
EOF_SCOPES
if [ -n "$unreadable" ]; then
  bad standard-secrets-outside "unreadable:$unreadable" "these secret-name reads failed${outside:+ (found outside $WANT_ENV so far: $outside)}:
$causes"
elif [ -z "$outside" ]; then
  ok standard-secrets-outside none "no secret outside $WANT_ENV carries a name the standard keeps there"
else
  bad standard-secrets-outside "$outside" "these secrets sit outside $WANT_ENV, readable by a workflow on a branch its policy excludes. Move each into $WANT_ENV and declare that environment on every job that reads it, then delete these copies"
fi

[ "$FAILED" -eq 0 ] || exit 1
exit 0
