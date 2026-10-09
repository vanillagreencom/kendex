#!/usr/bin/env bash
# Review-gate validate — the organization-standard half. Shipped by the
# kendex review-gate skill, vendored at .agents/skills/review-gate/scripts/.
#
# READ-ONLY: every GitHub call below is a GET. It answers whether the
# repository's GitHub-side settings match the organization standard. The
# standard's values come from lib/standard.sh: the CI and gate contexts from
# ../standard.json, the app, environment and secret names, the required
# contexts and the bypass actors a ruleset holding one rule type alone may
# carry from the review-gate settings this repository declares. The rows
# that hold no value (rule sources, merge queue, approvals, stale-approval
# dismissal, thread resolution, Copilot review, no classic protection) are
# fixed here. Its subject is GitHub
# state, not the checkout, so CI does not run it: CI's token
# cannot read bypass actors, installations or secret names, and every such
# row would be unreadable there. The permission each row's reads need is in
# print_usage.
#
# Report protocol: ok/advisory/FAIL check=KEY value=VALUE, then indented
# explanation, the records rg_report in lib/diagnostics.sh prints. VALUE is
# the observed state; `unreadable` in it means a read failed, which is never
# a match. Human explanation is not parsed. Full contract: print_usage or --help.
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
Usage: validate-standard.sh [--environment-only | --help]   (no positional arguments)

Reports, read-only, whether THIS repository's GitHub settings match the
organization standard. standard.json in the skill holds the CI and gate
contexts. The organization's values are review-gate settings, resolved from
the current directory like every other: REVIEW_GATE_STANDARD_APP,
REVIEW_GATE_STANDARD_ENVIRONMENT and REVIEW_GATE_STANDARD_SECRETS. The
repository's own required contexts are REVIEW_GATE_STANDARD_CONTEXTS, and
the bypass actors its merge-queue and required-checks rulesets admit the
optional REVIEW_GATE_STANDARD_QUEUE_BYPASS and
REVIEW_GATE_STANDARD_CHECKS_BYPASS, each empty by default, read the same
way. The repository is the one `gh` resolves: GH_REPO when set, else the
checkout's remote.

--environment-only reports the environment policy and its secret names, and
reads neither REVIEW_GATE_STANDARD_APP, REVIEW_GATE_STANDARD_CONTEXTS, the
two bypass keys nor any ruleset. Refresh adoption reads its caller declaration
and uses the same environment judgments without this report mode.

One verdict line per row, ok, advisory or FAIL, VALUE being what was
observed. An advisory row departs from a requirement the 1.3.0 standard
added and reads as a match until 2.0: it fails nothing and leaves the exit
code alone, and the run prints one review-gate-warning=standard-advisory
line to stderr, VALUE the advisory rows, naming each row's new form. The
advisory rows are standard-ruleset-source, standard-required-approvals and
standard-stale-dismissal on any departure, and standard-required-contexts
where REVIEW_GATE_STANDARD_CONTEXTS is unset or empty and the default branch
does not require the standard's gate_context. An unreadable row is FAIL,
never advisory.

Each of REVIEW_GATE_STANDARD_APP, REVIEW_GATE_STANDARD_ENVIRONMENT and
REVIEW_GATE_STANDARD_SECRETS that no source sets reads the value
standard.json carried before 1.3.0, and the run prints one
review-gate-warning=standard-setting-unset line to stderr, VALUE the unset
keys. A key set empty still refuses.

  standard-ruleset-source           pull_request, deletion,
                                    non_fast_forward and a workflows rule
                                    requiring .github/workflows/request-copilot-review.yml
                                    from vanillagreencom/kendex (repository
                                    1190866154), at any ref and sha, each come
                                    from an organization ruleset, and every
                                    effective default-branch rule comes from
                                    one, except required_status_checks and
                                    merge_queue, which come from a repository
                                    ruleset only. VALUE is the source types the
                                    rules come from; an advisory value lists
                                    each departure, SOURCE:ID:TYPE for a rule from
                                    a source its type may not use and
                                    missing:TYPE for a type no organization
                                    ruleset holds, or none for no rule
  standard-merge-queue              the default branch requires the merge queue
  standard-required-contexts        the required contexts are exactly the
                                    REVIEW_GATE_STANDARD_CONTEXTS list, and
                                    the standard's gate_context is not among
                                    them. VALUE is the required contexts; an
                                    advisory value is undeclared:CONTEXTS
                                    (the list is unset or empty), and a
                                    FAIL value may be gate-required:CONTEXTS,
                                    whatever the list holds
  standard-required-approvals       an organization ruleset's pull-request
                                    rule requires at least 1 approval. VALUE
                                    is the highest count such a rule
                                    requires, or absent
  standard-stale-dismissal          an organization ruleset's pull-request
                                    rule dismisses stale approvals on push.
                                    VALUE is true, false or absent
  standard-conversation-resolution  a pull-request rule requires every review
                                    thread resolved
  standard-copilot-review           a native rule requests a Copilot review,
                                    or an organization workflows rule pins
                                    vanillagreencom/kendex (repository
                                    1190866154), path
                                    .github/workflows/request-copilot-review.yml,
                                    ref refs/heads/main and a full commit SHA
  standard-bypass-actors            every bypass actor of a ruleset behind
                                    those rules is one the standard admits
                                    there: on a ruleset whose rules are
                                    merge_queue alone, an entry of
                                    REVIEW_GATE_STANDARD_QUEUE_BYPASS; on one
                                    whose rules are required_status_checks
                                    alone, an entry of
                                    REVIEW_GATE_STANDARD_CHECKS_BYPASS; on any
                                    other, none. An entry is TYPE:ID:MODE,
                                    GitHub's actor_type, actor_id and
                                    bypass_mode. VALUE is the count of actors,
                                    or on a FAIL each departure as
                                    RULESET=TYPE:ID:MODE
  standard-classic-protection       the default branch has no classic branch
                                    protection beside the rulesets
  standard-ci-context               an Actions job named the standard's
                                    ci_context ran for the pull request the
                                    default branch's head merged, on its
                                    pull_request leg and on its merge_group
                                    leg. VALUE is the pull_request leg's job
                                    names; a FAIL value is one of
                                    ci-context-missing:LEG:JOBS (LEG ran no
                                    such job; JOBS is what ran, or none),
                                    merge-group-unobserved:JOBS (the
                                    pull_request leg ran CI and the head did
                                    not come through the merge queue),
                                    no-associated-pull-request or unreadable
  standard-app                      REVIEW_GATE_STANDARD_APP is installed on every
                                    repository of the organization
  standard-environment              REVIEW_GATE_STANDARD_ENVIRONMENT exists
                                    and deploys from the default branch only
  standard-environment-secrets      that environment holds every secret
                                    REVIEW_GATE_STANDARD_SECRETS names
                                    (names only)
  standard-secrets-outside          no other secret carries one of those names:
                                    repository Actions secrets, every
                                    organization Actions secret (shared with
                                    this repository or not), repository and
                                    organization Dependabot secrets, and
                                    every other environment of the repository

A failed read reports its row as FAIL with `unreadable` in the value, never
as a match. The permission each row's reads need, as GitHub App permissions:
  ruleset-source, merge-queue,      the branch's rules: Metadata read
  required-contexts, required-
  approvals, stale-dismissal,
  conversation-resolution,
  copilot-review
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
  ci-context                        the default branch's head commit:
                                    Contents read; its pull requests: Pull
                                    requests read; the workflow runs on each
                                    leg and their jobs: Actions read
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
bypass-actors, classic-protection, ci-context and app as unreadable, and the
Dependabot scopes of secrets-outside as unreadable.

Exit codes:
  0  every row matched or reported advisory
  1  at least one FAIL line
  2  the check could not run at all (bad arguments, jq missing, a missing
     or malformed standard.json, a standard setting set empty, the
     repository itself could not be read)
USAGE
}

if [ "$#" -eq 1 ] && { [ "$1" = "--help" ] || [ "$1" = "-h" ]; }; then
  print_usage
  exit 0
fi
ENVIRONMENT_ONLY=0
if [ "${1:-}" = --environment-only ]; then
  ENVIRONMENT_ONLY=1
  shift
fi
if [ "$#" -gt 0 ]; then
  rg_message error unknown-arguments "$#" "validate-standard.sh: unknown argument list ($# argument(s), first: '${1}') — no positional arguments (run --help)" >&2
  exit 2
fi

die() { # CODE VALUE MESSAGE
  rg_message error "$@" >&2
  exit 2
}

[ -r "$SCRIPT_DIR/lib/settings.sh" ] || die settings-load "$SCRIPT_DIR/lib/settings.sh" "could not load the settings library"
. "$SCRIPT_DIR/lib/settings.sh" || exit 2
if [ ! -r "$SCRIPT_DIR/lib/standard.sh" ] || ! . "$SCRIPT_DIR/lib/standard.sh" 2>/dev/null; then
  die standard-lib-load "$SCRIPT_DIR/lib/standard.sh" "could not load the standard library"
fi
if [ "$ENVIRONMENT_ONLY" -eq 1 ]; then
  rg_standard_load "$SCRIPT_DIR/../standard.json" environment || exit 2
else
  rg_standard_load "$SCRIPT_DIR/../standard.json" full || exit 2
fi

SCRATCH="$(mktemp -d)" || die scratch "${TMPDIR:-/tmp}" "could not create a scratch directory"
trap 'rm -rf -- "$SCRATCH"' EXIT

# READ_OUT holds stdout; a failed read sets READ_ERR to gh's first stderr
# line. Both belong to the latest call only, so a caller that reads in a
# loop records READ_ERR per read inside the loop.
READ_OUT=""
READ_ERR=""
read_api() { # ENDPOINT FILTER [--paginate]
  local rc attempt=0 delay=1 error retryable
  READ_ERR=""
  while :; do
    rc=0
    READ_OUT="$(gh api ${3:+"$3"} "$1" --jq "$2" </dev/null 2>"$SCRATCH/err")" || rc=$?
    [ "$rc" -eq 0 ] && { READ_ERR=""; return 0; }
    if ! READ_ERR="$(sed -n '1p' "$SCRATCH/err")" || [ -z "$READ_ERR" ]; then
      READ_ERR="gh exited $rc"
    fi
    error="$(cat "$SCRATCH/err")" || return 1
    retryable=0
    # gh api --jq filters HTTP response data, not local CLI errors.
    # --include adds HTTP status and headers to the data stdout stream,
    # but has no headers when a connection gets no HTTP answer.
    # CLI exit codes do not identify HTTP status, so stderr supplies the
    # required HTTP and connection failure classification while keeping
    # READ_OUT as the filtered data callers consume.
    # gh's HTTP status takes precedence over its connection diagnostics.
    # Local jq, authentication and usage errors cannot recover by waiting.
    if [[ "$error" =~ HTTP[[:space:]]+([0-9][0-9][0-9]) ]]; then
      case "${BASH_REMATCH[1]}" in
        500|502|503|504) retryable=1 ;;
      esac
    else
      case "$error" in
        *'error connecting to '*|*'Get "https://'*'": '*|*'Get "http://'*'": '*) retryable=1 ;;
      esac
    fi
    [ "$retryable" -eq 1 ] && [ "$attempt" -lt 2 ] || return 1
    sleep "$delay" || return 1
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
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
# A row whose requirement the 1.3.0 standard added reports a departure as
# advisory, which fails nothing; the run's one standard-advisory warning
# names each such row's NEW_FORM. Compatibility read, floor 1.3.0, removed
# at 2.0, when each caller goes back to bad: no setting turns it off.
ADVISED=""
ADVISED_FORMS=""
advise() { # CHECK VALUE MESSAGE NEW_FORM
  ADVISED="${ADVISED:+$ADVISED,}$1"
  ADVISED_FORMS="${ADVISED_FORMS:+$ADVISED_FORMS
}$1: $4"
  rg_report advisory "$1" "$2" "$3"
}

# The environment-only report excludes unrelated owner-only reads.
if [ "$ENVIRONMENT_ONLY" -eq 0 ]; then
# ------------------------------------------------------ default branch ---

RULE_ROWS="standard-ruleset-source standard-merge-queue standard-required-contexts standard-required-approvals standard-stale-dismissal standard-conversation-resolution standard-copilot-review standard-bypass-actors"
RULES=""
if read_api "repos/$FULL/rules/branches/$BRANCH_URI" '.[] | @json' --paginate &&
  RULES="$(printf '%s' "$READ_OUT" | jq -s '.' 2>/dev/null)" &&
  jq -e 'all(.[]; type == "object" and (.type | type) == "string")' >/dev/null 2>&1 <<<"$RULES"; then
  # RULES already parsed as an array of rule objects, so a failed query
  # here is this script's own fault.
  # The organization ruleset requests the Copilot review through kendex's
  # workflow (references/automatic-review.md). The source row judges the
  # workflow's identity, its repository and path, because the owner re-pins
  # the sha on each workflow change; the review row also requires the pin.
  # An unrelated required workflow satisfies neither.
  rules() {
    jq -r 'def kendex_review_entry:
        .repository_id == 1190866154
        and .path == ".github/workflows/request-copilot-review.yml";
      def kendex_review_workflow:
      .type == "workflows"
      and .ruleset_source_type == "Organization"
      and any(.parameters.workflows[]?; kendex_review_entry);
      def kendex_copilot_workflow:
      kendex_review_workflow
      and any(.parameters.workflows[]?;
        kendex_review_entry
        and .ref == "refs/heads/main"
        and (.sha | if type == "string" then test("^[0-9a-f]{40}$") else false end));
      '"$1" <<<"$RULES" || die rules-query "$1" "jq could not evaluate a query over the parsed rules"
  }

  # The organization ruleset holds the review, deletion and force-push rules
  # every repository shares. A repository keeps its own required checks and
  # merge queue in its own rulesets and nowhere else, an organization ruleset
  # included. Any other source for a rule is a departure, and so is a shared
  # rule no organization ruleset holds.
  SOURCE_FORM="pull_request, deletion, non_fast_forward and a workflows rule requiring vanillagreencom/kendex's .github/workflows/request-copilot-review.yml from an organization ruleset, and required_status_checks and merge_queue from a repository ruleset"
  departures="$(rules 'if length == 0 then "none" else (
    [.[] | select(if .type == "required_status_checks" or .type == "merge_queue" then .ruleset_source_type != "Repository" else .ruleset_source_type != "Organization" end) | "\(.ruleset_source_type):\(.ruleset_id):\(.type)"]
    + (["pull_request", "deletion", "non_fast_forward"] - [.[] | select(.ruleset_source_type == "Organization") | .type] | map("missing:\(.)"))
    + (if any(.[]; kendex_review_workflow) then [] else ["missing:workflows"] end)
    | unique | join(",")) end')"
  case "$departures" in
    "") ok standard-ruleset-source "$(rules '[.[].ruleset_source_type] | unique | join(",")')" "$BRANCH takes its shared rules from an organization ruleset, and only its required checks and merge queue from a repository ruleset" ;;
    none) advise standard-ruleset-source none "no ruleset applies to $BRANCH" "$SOURCE_FORM" ;;
    *) advise standard-ruleset-source "$departures" "these rules on $BRANCH depart from the standard's sources: $SOURCE_FORM" "$SOURCE_FORM" ;;
  esac

  if [ "$(rules 'any(.[]; .type == "merge_queue")')" = true ]; then
    ok standard-merge-queue present "$BRANCH requires the merge queue"
  else
    bad standard-merge-queue absent "$BRANCH has no merge-queue rule"
  fi

  contexts="$(rules '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]?.context] | unique | join(";")')"
  gated="$(jq -r --arg gate "$WANT_GATE" 'any(.[]; .type == "required_status_checks" and any(.parameters.required_status_checks[]?; .context == $gate))' <<<"$RULES")" ||
    die rules-query gate-context "jq could not evaluate a query over the parsed rules"
  # A required gate context fails whatever the list holds, so the undeclared
  # advisory never stands in for it.
  if [ "$gated" = true ]; then
    bad standard-required-contexts "gate-required:$contexts" "$BRANCH requires $WANT_GATE, which the standard's approval rule replaces. While the writer runs, $WANT_GATE stays required: remove it from the required contexts in the ruleset edit that precedes disabling the writer, never before, and never list it in REVIEW_GATE_STANDARD_CONTEXTS: .agents/skills/review-gate/references/adoption.md § Repo-side wiring"
  elif [ -z "$WANT_CONTEXTS" ]; then
    advise standard-required-contexts "undeclared:$contexts" "this repository declares no REVIEW_GATE_STANDARD_CONTEXTS, so $BRANCH's required contexts have nothing to match; set it in the [env] table of kendex.settings.toml to the contexts $BRANCH should require" "REVIEW_GATE_STANDARD_CONTEXTS in the [env] table of kendex.settings.toml"
  elif [ "$contexts" = "$WANT_CONTEXTS" ]; then
    ok standard-required-contexts "$contexts" "$BRANCH requires exactly the contexts this repository declares"
  else
    bad standard-required-contexts "$contexts" "$BRANCH requires these contexts; REVIEW_GATE_STANDARD_CONTEXTS declares exactly: $WANT_CONTEXTS"
  fi

  # GitHub enforces the strictest of several pull-request rules, so the
  # highest count and any dismissal decide. A repository ruleset's rule is
  # the ruleset-source row's departure and counts for nothing here.
  approvals="$(rules '[.[] | select(.type == "pull_request" and .ruleset_source_type == "Organization") | .parameters.required_approving_review_count] | if length == 0 then "absent" else (max | tostring) end')"
  case "$approvals" in
    "" | *[!0-9]* | 0) advise standard-required-approvals "$approvals" "no organization pull-request rule on $BRANCH requires an approval; the standard requires at least 1" "an organization ruleset whose pull-request rule requires 1 approval" ;;
    *) ok standard-required-approvals "$approvals" "$BRANCH requires $approvals approval(s) from an organization ruleset" ;;
  esac

  # A failed query exits with the refusal rules printed, rather than reading
  # as a departure, which is advisory and fails nothing.
  stale="$(rules '[.[] | select(.type == "pull_request" and .ruleset_source_type == "Organization") | .parameters.dismiss_stale_reviews_on_push] | if length == 0 then "absent" elif any(.[]; . == true) then "true" else "false" end')" || exit 2
  if [ "$stale" = true ]; then
    ok standard-stale-dismissal true "$BRANCH dismisses a stale approval on push"
  else
    advise standard-stale-dismissal "$stale" "no organization pull-request rule on $BRANCH dismisses a stale approval on push, so an approval outlives the head it approved" "an organization ruleset whose pull-request rule dismisses stale approvals on push"
  fi

  if [ "$(rules 'any(.[]; .type == "pull_request" and .parameters.required_review_thread_resolution == true)')" = true ]; then
    ok standard-conversation-resolution true "$BRANCH requires every review thread resolved"
  else
    bad standard-conversation-resolution false "no pull-request rule on $BRANCH requires review threads resolved"
  fi

  if [ "$(rules 'any(.[]; .type == "copilot_code_review" or kendex_copilot_workflow)')" = true ]; then
    ok standard-copilot-review present "$BRANCH requests a Copilot review"
  else
    bad standard-copilot-review absent "no native rule or pinned kendex review workflow on $BRANCH requests a Copilot review"
  fi

  # GitHub returns bypass_actors only to a caller with write access to the
  # ruleset and omits the field otherwise, so a missing field is
  # unreadable and never zero. Each ruleset is read at the level that owns
  # it: an organization owner sees an organization ruleset's actors through
  # the organization endpoint, not through the repository one. A ruleset
  # whose rules on the branch are merge_queue alone may carry the actors
  # REVIEW_GATE_STANDARD_QUEUE_BYPASS admits, and one whose rules are
  # required_status_checks alone those REVIEW_GATE_STANDARD_CHECKS_BYPASS
  # admits: bypassing either skips only the queue or only the checks, while
  # every other rule stays on a ruleset nobody bypasses. Any other actor on
  # any ruleset is a departure.
  actors=0
  unadmitted=""
  unreadable=""
  causes=""
  owned="$(rules '[.[] | select(.ruleset_id != null) | "\(.ruleset_source_type) \(.ruleset_id)"] | unique | .[]')"
  while read -r source id; do
    [ -n "$id" ] || continue
    case "$id" in
      *[!0-9]*)
        unreadable="${unreadable:+$unreadable,}$id"
        causes="${causes:+$causes
}$id: not a ruleset id"
        continue
        ;;
    esac
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
    if ! read_api "$endpoint" 'if has("bypass_actors") then "actors:" + (.bypass_actors | map("\(.actor_type):\(.actor_id // ""):\(.bypass_mode // "always")") | join(";")) else "withheld" end'; then
      unreadable="${unreadable:+$unreadable,}$id"
      causes="${causes:+$causes
}$id: $READ_ERR"
      continue
    elif [ "$READ_OUT" = withheld ]; then
      unreadable="${unreadable:+$unreadable,}$id"
      causes="${causes:+$causes
}$id: bypass_actors withheld, which GitHub does without write access to the ruleset"
      continue
    fi
    case "$(rules "[.[] | select(.ruleset_id == $id) | .type] | unique | join(\",\")")" in
      merge_queue) admitted="$WANT_QUEUE_BYPASS" ;;
      required_status_checks) admitted="$WANT_CHECKS_BYPASS" ;;
      *) admitted="" ;;
    esac
    listed="$(rg_pack "${READ_OUT#actors:}" ';')" ||
      die rules-query "$id" "could not split the bypass actors of this ruleset"
    while IFS= read -r actor; do
      [ -n "$actor" ] || continue
      actors=$((actors + 1))
      grep -qxF -- "$actor" <<<"$admitted" || unadmitted="${unadmitted:+$unadmitted,}$id=$actor"
    done <<<"$listed"
  done <<EOF_OWNED
$owned
EOF_OWNED
  if [ -n "$unreadable" ]; then
    bad standard-bypass-actors "unreadable:$unreadable" "the bypass actors of these rulesets could not be read:
$causes"
  elif [ -n "$unadmitted" ]; then
    bad standard-bypass-actors "$unadmitted" "these bypass actors, as RULESET=TYPE:ID:MODE, are ones the standard does not admit on that ruleset; a ruleset holding merge_queue alone admits REVIEW_GATE_STANDARD_QUEUE_BYPASS, one holding required_status_checks alone REVIEW_GATE_STANDARD_CHECKS_BYPASS, and any other none"
  else
    ok standard-bypass-actors "$actors" "every bypass actor on $BRANCH's rulesets is one the standard admits there"
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
    on) bad standard-classic-protection on "$BRANCH has classic branch protection beside the rulesets; the standard holds every rule in rulesets, the shared rules in the organization's and the required checks and merge queue in the repository's, so remove it" ;;
    *) bad standard-classic-protection unreadable "the branch read answered neither on nor off" ;;
  esac
else
  bad standard-classic-protection unreadable "the branch $BRANCH could not be read: $READ_ERR"
fi

# ---------------------------------------------------------- CI context ---

# Every repository under the standard reports the aggregate CI context on
# the pull_request and merge_group legs. What its ruleset requires is
# .agents/skills/review-gate/references/adoption.md
# § Repo-side wiring. An Actions job reports its
# name as a check context on the commit it ran for. The pull request the
# default branch's head merged holds the head where the pull_request leg ran.
# The merge_group leg ran on the head itself, which the merge queue merged;
# a head that did not come through the queue has none, and the leg stays
# unconfirmed rather than read from another commit. Commit statuses are not
# read: the CI context is an Actions job, and statuses need a permission the
# standard's app does not hold.

# The names of the jobs that ran on SHA for EVENT, one per line, sorted and
# unique, in LEG_JOBS; LEG_RUNS counts the runs. A failed read returns 1
# with READ_ERR naming it.
LEG_JOBS=""
LEG_RUNS=0
leg_jobs() { # SHA EVENT
  local runs run_id names=""
  LEG_JOBS=""
  LEG_RUNS=0
  read_api "repos/$FULL/actions/runs?head_sha=$1&event=$2&per_page=100" '.workflow_runs[].id' --paginate ||
    { READ_ERR="the $2 runs on $1: $READ_ERR"; return 1; }
  runs="$READ_OUT"
  while IFS= read -r run_id; do
    [ -n "$run_id" ] || continue
    LEG_RUNS=$((LEG_RUNS + 1))
    read_api "repos/$FULL/actions/runs/$run_id/jobs?per_page=100" '.jobs[].name' --paginate ||
      { READ_ERR="the jobs of $2 run $run_id: $READ_ERR"; return 1; }
    names="${names:+$names
}$READ_OUT"
  done <<EOF_RUNS
$runs
EOF_RUNS
  LEG_JOBS="$(printf '%s\n' "$names" | LC_ALL=C sort -u | sed '/^$/d')" ||
    die ci-context-names "$1" "could not list the job names read for $1"
}
leg_list() { # JOBS — the job names as one VALUE field, or none
  local list
  list="$(printf '%s\n' "$1" | paste -sd ';' -)" || die ci-context-names join "could not join the job names read for the CI context"
  printf '%s\n' "${list:-none}"
}

ci_context_row() {
  local head merged number pr_sha pr_jobs pr_list
  if ! read_api "repos/$FULL/commits/$BRANCH_URI" '.sha'; then
    bad standard-ci-context unreadable "the head commit of $BRANCH could not be read: $READ_ERR"
    return 0
  fi
  head="$READ_OUT"
  case "$head" in
    "" | *[!0123456789abcdef]*)
      bad standard-ci-context unreadable "the head of $BRANCH is not a commit sha: $head"
      return 0
      ;;
  esac
  if ! read_api "repos/$FULL/commits/$head/pulls" \
    "map(select(.merged_at != null and .base.ref == $(jq_string "$BRANCH"))) | if length == 0 then \"\" else (.[0] | \"\\(.number) \\(.head.sha)\") end"; then
    bad standard-ci-context unreadable "the pull requests of $head, the head of $BRANCH, could not be read: $READ_ERR"
    return 0
  fi
  merged="$READ_OUT"
  if [ -z "$merged" ]; then
    bad standard-ci-context no-associated-pull-request "$head, the head of $BRANCH, belongs to no pull request merged into $BRANCH, so no commit shows which contexts $FULL's CI reports"
    return 0
  fi
  number="${merged%% *}"
  pr_sha="${merged#* }"
  case "$pr_sha" in
    "" | *[!0123456789abcdef]*)
      bad standard-ci-context unreadable "the head of pull request #$number is not a commit sha: $merged"
      return 0
      ;;
  esac

  if ! leg_jobs "$pr_sha" pull_request; then
    bad standard-ci-context unreadable "$READ_ERR"
    return 0
  fi
  pr_jobs="$LEG_JOBS"
  pr_list="$(leg_list "$pr_jobs")"
  if ! grep -qxF -- "$WANT_CI" <<<"$pr_jobs"; then
    bad standard-ci-context "ci-context-missing:pull_request:$pr_list" "$FULL reported no $WANT_CI job for pull request #$number on its head $pr_sha, and the standard has every repository report $WANT_CI on the pull_request and merge_group legs. Give the job that aggregates every lane the name $WANT_CI: .agents/skills/harness-ci/references/wiring.md § The CI context"
    return 0
  fi

  if ! leg_jobs "$head" merge_group; then
    bad standard-ci-context unreadable "$READ_ERR"
    return 0
  fi
  if [ "$LEG_RUNS" -eq 0 ]; then
    bad standard-ci-context "merge-group-unobserved:$pr_list" "$FULL reported $WANT_CI for pull request #$number on $pr_sha. No merge_group run ran on $head, the head of $BRANCH, so the head did not come through the merge queue, and the merge_group leg is unconfirmed until the next merge through the queue."
  elif ! grep -qxF -- "$WANT_CI" <<<"$LEG_JOBS"; then
    bad standard-ci-context "ci-context-missing:merge_group:$(leg_list "$LEG_JOBS")" "$FULL reported no $WANT_CI job for the merge group on $head, the head of $BRANCH, and the standard has every repository report $WANT_CI on the pull_request and merge_group legs: .agents/skills/harness-ci/references/wiring.md § The CI context"
  else
    ok standard-ci-context "$pr_list" "$FULL reported $WANT_CI for pull request #$number on $pr_sha and for its merge group on $head"
  fi
}
ci_context_row

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
  policy_data="$(jq -n --argjson environments "$ENVS" '{environments: $environments}')" ||
    die environments-query "$WANT_ENV" "could not encode the environment data"
  judgment="$(python3 "$SCRIPT_DIR/lib/environment.py" policy "$BRANCH" "$WANT_ENV" <<<"$policy_data")" ||
    die environments-query "$WANT_ENV" "could not judge the environment data"
  ENV_PRESENT="$(jq -r .present <<<"$judgment")"
  cause="$(jq -r .cause <<<"$judgment")" ||
    die environments-query "$WANT_ENV" "could not decode the environment judgment"
  if [ "$cause" = pending ]; then
    if read_api "repos/$FULL/environments/$ENV_URI/deployment-branch-policies" '.branch_policies[] | @json' --paginate &&
        policies="$(printf '%s' "$READ_OUT" | jq -s '.')"; then
      policy_data="$(jq --argjson policies "$policies" '. + {policies: $policies}' <<<"$policy_data")"
      judgment="$(python3 "$SCRIPT_DIR/lib/environment.py" policy "$BRANCH" "$WANT_ENV" <<<"$policy_data")" ||
        die environments-query "$WANT_ENV" "could not judge the branch-policy data"
      cause="$(jq -r .cause <<<"$judgment")" ||
        die environments-query "$WANT_ENV" "could not decode the branch-policy judgment"
    else
      cause=read
    fi
  fi
  observed="$(jq -r .value <<<"$judgment")"
  case "$cause" in
    '') ok standard-environment "$observed" "$WANT_ENV deploys from $BRANCH only" ;;
    read) bad standard-environment unreadable "the branch policies of $WANT_ENV could not be read: $READ_ERR" ;;
    *) bad standard-environment "$observed" "$WANT_ENV must exist and allow the default branch only. $PROVISION" ;;
  esac
else
  bad standard-environment unreadable "the environments could not be read: $ENVS_ERR"
fi

case "$ENV_PRESENT" in
  yes)
    if read_api "repos/$FULL/environments/$ENV_URI/secrets" '.secrets[] | @json' --paginate &&
        secrets="$(printf '%s' "$READ_OUT" | jq -s '.')"; then
      judgment="$(python3 "$SCRIPT_DIR/lib/environment.py" secrets "$WANT_SECRETS" <<<"$secrets")" ||
        die environments-query "$WANT_ENV" "could not judge the secret-name data"
      held="$(jq -r .held <<<"$judgment")"
      missing="$(jq -r .missing <<<"$judgment")"
      if [ "$(jq -r .cause <<<"$judgment")" = '' ]; then
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

if [ "$ENVIRONMENT_ONLY" -eq 1 ]; then
  [ "$FAILED" -eq 0 ]
  exit
fi

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

if [ -n "$ADVISED" ]; then
  rg_message warning standard-advisory "$ADVISED" "these rows depart from requirements the 1.3.0 standard added and read as advisory until 2.0, when they fail; each row's new form:
$ADVISED_FORMS" >&2
fi
[ "$FAILED" -eq 0 ] || exit 1
exit 0
