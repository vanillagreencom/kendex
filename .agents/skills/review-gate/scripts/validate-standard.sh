#!/usr/bin/env bash
# Review-gate validate — the organization-standard half. Shipped by the
# kendex review-gate skill, vendored at .agents/skills/review-gate/scripts/.
#
# READ-ONLY: every GitHub call below is a GET. It answers whether the
# repository's GitHub-side settings match the standard in ../standard.json,
# the one place the standard's values live: the default branch's effective
# rules, the rulesets' bypass actors, the lanes app installation, and the
# environment that holds the app secrets. Its subject is GitHub state, not
# the checkout, so validate.sh does not run it: CI's token cannot read
# bypass actors, installations or secret names, and every row would be
# unreadable there.
#
# Report protocol: ok/FAIL check=KEY value=VALUE, then indented
# explanation, the same records validate.sh prints. VALUE is the observed
# state; `unreadable` in it means the read failed, which is never a match.
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
organization standard in the skill's standard.json. The repository is the
one `gh` resolves: GH_REPO when set, else the checkout's remote.

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
  standard-app                      the standard's app is installed on every
                                    repository of the organization
  standard-environment              the standard's environment exists and
                                    deploys from the default branch only
  standard-environment-secrets      that environment holds every secret the
                                    standard names (names only)
  standard-secrets-outside          no repository or organization secret
                                    visible here carries one of those names

A failed read reports its rows as FAIL with `unreadable` in the value, never
as a match. Bypass actors, installations and secret names need a token with
repository administration read, organization administration read and
secrets read.

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

STANDARD="$SCRIPT_DIR/../standard.json"
[ -r "$STANDARD" ] || die standard-missing "$STANDARD" "the standard manifest is missing or unreadable — re-run \`kendex refresh\`"
jq -e '
  (.required_contexts | type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
  and (.app | type == "string" and length > 0)
  and (.environment | type == "string" and length > 0)
  and (.environment_secrets | type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
' "$STANDARD" >/dev/null 2>&1 ||
  die standard-malformed "$STANDARD" "the standard manifest does not parse, or lacks a non-empty required_contexts, app, environment or environment_secrets"
std() { jq -r "$1" "$STANDARD"; }
WANT_CONTEXTS="$(std '.required_contexts | unique | join(";")')" || die standard-read "$STANDARD" "could not read required_contexts"
WANT_APP="$(std '.app')" || die standard-read "$STANDARD" "could not read app"
WANT_ENV="$(std '.environment')" || die standard-read "$STANDARD" "could not read environment"
WANT_SECRETS="$(std '.environment_secrets | unique | .[]')" || die standard-read "$STANDARD" "could not read environment_secrets"

SCRATCH="$(mktemp -d)" || die scratch "${TMPDIR:-/tmp}" "could not create a scratch directory"
trap 'rm -rf -- "$SCRATCH"' EXIT

# READ_OUT holds stdout; a failed read leaves READ_ERR naming gh's first
# stderr line so the row says why it could not answer.
READ_OUT=""
READ_ERR=""
read_api() { # ENDPOINT FILTER [--paginate]
  local rc=0
  READ_ERR=""
  READ_OUT="$(gh api ${3:+"$3"} "$1" --jq "$2" 2>"$SCRATCH/err")" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  if ! READ_ERR="$(sed -n '1p' "$SCRATCH/err")" || [ -z "$READ_ERR" ]; then
    READ_ERR="gh exited $rc"
  fi
  return 1
}
uri() { jq -rn --arg v "$1" '$v | @uri'; }
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

PASS=0
FAILED=0
ok() { PASS=$((PASS + 1)); rg_report ok "$@"; }
bad() { FAILED=$((FAILED + 1)); rg_report FAIL "$@"; }

# ------------------------------------------------------ default branch ---

RULE_ROWS="standard-ruleset-source standard-merge-queue standard-required-contexts standard-conversation-resolution standard-copilot-review standard-bypass-actors"
RULES=""
if read_api "repos/$FULL/rules/branches/$(uri "$BRANCH")" '.[] | @json' --paginate &&
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

  # The list is returned only to a token with administration read; without
  # it the field is absent, which is unreadable and never zero.
  actors=0
  unreadable=""
  ids="$(rules '[.[].ruleset_id | select(. != null) | tostring] | unique | .[]')"
  for id in $ids; do
    if read_api "repos/$FULL/rulesets/$id" 'if has("bypass_actors") then (.bypass_actors | length | tostring) else "absent" end' &&
      [ "$READ_OUT" != absent ]; then
      actors=$((actors + READ_OUT))
    else
      unreadable="${unreadable:+$unreadable,}$id"
    fi
  done
  if [ -n "$unreadable" ]; then
    bad standard-bypass-actors "unreadable:$unreadable" "the bypass actors of ruleset(s) $unreadable could not be read${READ_ERR:+ ($READ_ERR)}; a token with repository administration read sees them"
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

ENV_URI="$(uri "$WANT_ENV")"
ENV_PRESENT=unknown
if read_api "repos/$FULL/environments" ".environments[] | select(.name == $(jq_string "$WANT_ENV")) | .deployment_branch_policy | @json" --paginate; then
  policy="$READ_OUT"
  case "$policy" in
    "") ENV_PRESENT=no; bad standard-environment absent "the environment $WANT_ENV does not exist" ;;
    null) ENV_PRESENT=yes; bad standard-environment unrestricted "$WANT_ENV deploys from every branch; the standard allows the default branch only" ;;
    *)
      ENV_PRESENT=yes
      kind="$(jq -r 'if .custom_branch_policies == true and .protected_branches == false then "custom" elif .protected_branches == true then "protected-branches" else "malformed" end' <<<"$policy" 2>/dev/null)" || kind=malformed
      if [ "$kind" != custom ]; then
        bad standard-environment "$kind" "$WANT_ENV does not deploy from a custom branch policy; the standard allows the default branch only"
      elif read_api "repos/$FULL/environments/$ENV_URI/deployment-branch-policies" '.branch_policies[] | "\(.type // "branch"):\(.name)"' --paginate; then
        observed="custom:$(printf '%s' "$READ_OUT" | tr '\n' ',')"
        if [ "$READ_OUT" = "branch:$BRANCH" ]; then
          ok standard-environment "$observed" "$WANT_ENV deploys from $BRANCH only"
        else
          bad standard-environment "$observed" "$WANT_ENV deploys from these branch policies; the standard allows branch:$BRANCH only"
        fi
      else
        bad standard-environment unreadable "the branch policies of $WANT_ENV could not be read: $READ_ERR"
      fi
      ;;
  esac
else
  bad standard-environment unreadable "the environments could not be read: $READ_ERR"
fi

case "$ENV_PRESENT" in
  yes)
    if read_api "repos/$FULL/environments/$ENV_URI/secrets" '.secrets[].name' --paginate; then
      held=""
      missing=""
      for name in $WANT_SECRETS; do
        if grep -qxF -- "$name" <<<"$READ_OUT"; then
          held="${held:+$held;}$name"
        else
          missing="${missing:+$missing;}$name"
        fi
      done
      if [ -z "$missing" ]; then
        ok standard-environment-secrets "$held" "$WANT_ENV holds every secret the standard names"
      else
        bad standard-environment-secrets "$held" "$WANT_ENV lacks: $missing"
      fi
    else
      bad standard-environment-secrets unreadable "the secrets of $WANT_ENV could not be read: $READ_ERR"
    fi
    ;;
  no) bad standard-environment-secrets absent "the environment $WANT_ENV does not exist, so it holds no secret" ;;
  unknown) bad standard-environment-secrets unreadable "the environments could not be read, so $WANT_ENV's secrets were not asked for" ;;
esac

# A secret of the same name outside the environment is readable by any
# workflow on any branch, which is what the environment's branch policy
# exists to prevent.
outside=""
unreadable=""
for scope in repository organization; do
  case "$scope" in
    repository) endpoint="repos/$FULL/actions/secrets" ;;
    organization) endpoint="repos/$FULL/actions/organization-secrets" ;;
  esac
  if read_api "$endpoint" '.secrets[].name' --paginate; then
    for name in $WANT_SECRETS; do
      if grep -qxF -- "$name" <<<"$READ_OUT"; then
        outside="${outside:+$outside;}$scope:$name"
      fi
    done
  else
    unreadable="${unreadable:+$unreadable,}$scope"
  fi
done
if [ -n "$unreadable" ]; then
  bad standard-secrets-outside "unreadable:$unreadable" "the $unreadable secret names could not be read: $READ_ERR"
elif [ -z "$outside" ]; then
  ok standard-secrets-outside none "no repository or organization secret visible here carries a name the standard keeps in $WANT_ENV"
else
  bad standard-secrets-outside "$outside" "these secrets sit outside $WANT_ENV, readable by a workflow on any branch; delete them"
fi

[ "$FAILED" -eq 0 ] || exit 1
exit 0
