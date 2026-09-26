#!/usr/bin/env bash
# The fake `gh` the selftest and the suites beside it put on PATH: it answers
# every `gh api` read from fixture files under GH_SHIM_FIXTURES and applies
# any --jq filter with real jq, so review-predicate.sh runs unmodified.
# Dispatch is by request shape (the endpoint path, or GraphQL); the switches
# GH_SHIM_FAIL, GH_SHIM_FAIL_TIMES and GH_SHIM_EMPTY drive the fail-loud
# paths, and <name>.page2.json models a second page, filtered by --jq as
# real gh filters each page. A ruleset read is served from
# org-ruleset-<id>.json through the organization endpoint and
# ruleset-<id>.json through the repository one, an environment's secrets from
# environment-secrets-<name>.json, and a workflow run's jobs from
# jobs-<run id>.json, so each can carry its own answer. A
# repos/OWNER/NAME/... read is served from the directory
# repos/OWNER/NAME/ under the fixtures when that directory exists, so one
# world can hold several repositories.
# Every read's URL is appended to .urls.log so a case can pin read shapes.
# A write (`gh api -X METHOD` other than GET, or `gh secret set`) reads no
# fixture: it appends one line to .writes.log, `METHOD URL BODY` or
# `secret-set repo=R env=E name=N value=V` with BODY and V %q-escaped, and
# GH_SHIM_FAIL=METHOD:NAME or GH_SHIM_FAIL=secret-set fails it.
set -euo pipefail
if [ "${1:-}" = secret ]; then
  [ "${2:-}" = set ] || { printf 'gh-shim-error=secret-verb value=%q\n' "${2:-}" >&2; exit 90; }
  secret_name="${3:-}"; secret_env=""; secret_repo=""
  shift 3
  while [ $# -gt 0 ]; do
    case "$1" in
      --env) shift; secret_env="$1" ;;
      --repo) shift; secret_repo="$1" ;;
      *) printf 'gh-shim-error=secret-flag value=%q\n' "$1" >&2; exit 90 ;;
    esac
    shift
  done
  secret_value="$(cat)"
  if [ "${GH_SHIM_FAIL:-}" = secret-set ]; then
    printf 'gh-shim-error=api value=%q\n' secret-set >&2
    exit 1
  fi
  printf 'secret-set repo=%s env=%s name=%s value=%q\n' "$secret_repo" "$secret_env" "$secret_name" "$secret_value" >>"$GH_SHIM_FIXTURES/.writes.log"
  exit 0
fi
url=""; filter=""; paginate=0; graphql_page2=0; graphql_after=""; method=""; input=""; fields=""
while [ $# -gt 0 ]; do
  case "$1" in
    api|--slurp) ;;
    --paginate) paginate=1 ;;
    -X|--method) shift; method="$1" ;;
    --input) shift; input="$1" ;;
    -f|-F)
      shift
      fields="${fields:+$fields }$1"
      # A cursor variable marks a follow-up thread page: serve the page-2
      # fixture (when present) so pagination is exercised for real. The
      # cursor VALUE is kept so cursor-keyed fixtures
      # (graphql.cursor-<value>.json) can drive an arbitrarily deep walk —
      # the page-budget bound cannot be proven with a single follow-up page.
      case "$1" in
        after=*)
          graphql_page2=1
          graphql_after="${1#after=}"
          # Cursor-keyed fixtures embed the cursor in a pathname, so the
          # namespace is enforced, not assumed: every cursor this suite
          # authors is [A-Za-z0-9_-]. Anything else would silently fall
          # back to the page-2/default fixture and a case could claim a
          # deep walk it never drove — refuse loudly instead.
          # Empty is refused with the same teeth: an empty after= cannot
          # select a cursor fixture and would silently fall through to the
          # page-2/default fixture — the false coverage this guard exists
          # to prevent.
          case "$graphql_after" in
            '' | *[!A-Za-z0-9_-]*)
              printf 'gh-shim-error=cursor value=%q\n' "$graphql_after" >&2
              exit 92
              ;;
          esac
          ;;
      esac
      ;;
    --jq) shift; filter="$1" ;;
    graphql) url="graphql" ;;
    *) [ -z "$url" ] && url="$1" ;;
  esac
  shift
done
case "$url" in
  *"/check-runs"*) name=checkruns ;;
  *"/compare/"*) name=compare ;;
  *"/reviews"*)  name=reviews ;;
  *"/statuses"*) name=statuses ;;
  *"/status"*)   name=status ;;
  *"/issues/"*"/comments"*) name=comments ;;
  graphql)       name=graphql ;;
  *"/pulls/"*)   name=pull ;;
  *"/rules/branches/"*) name=rules ;;
  "repos/"*"/branches/"*) name=branch ;;
  "orgs/"*"/rulesets/"*) name="org-ruleset-${url##*/}" ;;
  *"/rulesets/"*) name="ruleset-${url##*/}" ;;
  "orgs/"*"/installations") name=installations ;;
  "orgs/"*"/repos"*) name=organization-repositories ;;
  *"/deployment-branch-policies") name=branch-policies ;;
  *"/deployment-branch-policies/"*) name=branch-policy ;;
  *"/environments/"*"/secrets")
    environment="${url#*/environments/}"
    name="environment-secrets-${environment%/secrets}"
    ;;
  "orgs/"*"/dependabot/secrets") name=organization-dependabot-secrets ;;
  "repos/"*"/dependabot/secrets") name=dependabot-secrets ;;
  *"/environments") name=environments ;;
  *"/environments/"*) name=environment ;;
  *"/actions/organization-secrets") name=organization-secrets ;;
  "orgs/"*"/actions/secrets") name=organization-actions-secrets ;;
  *"/actions/secrets") name=repository-secrets ;;
  "repos/{owner}/{repo}") name=repository ;;
  "orgs/"*)
    case "${url#orgs/}" in
      */*) printf 'gh-shim-error=request value=%q\n' "$url" >&2; exit 90 ;;
    esac
    name=organization
    ;;
  *"/pulls?"*) name=pulls ;;
  *"/actions/runs/"*"/jobs"*)
    run="${url#*/actions/runs/}"
    name="jobs-${run%%/*}"
    ;;
  *"/actions/runs?"*) name=workflow-runs ;;
  *) printf 'gh-shim-error=request value=%q\n' "$url" >&2; exit 90 ;;
esac
if [ -n "$method" ] && [ "$method" != GET ]; then
  body="$fields"
  [ "$input" != - ] || body="$(cat)"
  if [ "${GH_SHIM_FAIL:-}" = "$method:$name" ]; then
    printf 'gh-shim-error=api value=%q\n' "$method:$name" >&2
    exit 1
  fi
  printf '%s %s %q\n' "$method" "$url" "$body" >>"$GH_SHIM_FIXTURES/.writes.log"
  exit 0
fi
echo "$url" >>"$GH_SHIM_FIXTURES/.urls.log"
fixtures="$GH_SHIM_FIXTURES"
case "$url" in
  repos/*/*/*)
    repo_path="${url#repos/}"
    repo_owner="${repo_path%%/*}"
    repo_path="${repo_path#*/}"
    repo_dir="$GH_SHIM_FIXTURES/repos/$repo_owner/${repo_path%%/*}"
    [ ! -d "$repo_dir" ] || fixtures="$repo_dir"
    ;;
esac
if [ -n "${GH_SHIM_FAIL:-}" ] && [ "$GH_SHIM_FAIL" = "$name" ]; then
  if [ -n "${GH_SHIM_FAIL_TIMES:-}" ]; then
    count=0
    counter="$GH_SHIM_FIXTURES/.failcount.$name"
    [ -f "$counter" ] && count="$(cat "$counter")"
    if [ "$count" -lt "$GH_SHIM_FAIL_TIMES" ]; then
      echo $((count + 1)) >"$counter"
      printf 'gh-shim-error=api value=%q\n' "$name:$((count + 1))/$GH_SHIM_FAIL_TIMES" >&2
      exit 1
    fi
  else
    printf 'gh-shim-error=api value=%q\n' "$name" >&2
    exit 1
  fi
fi
if [ -n "${GH_SHIM_EMPTY:-}" ] && [ "$GH_SHIM_EMPTY" = "$name" ]; then
  exit 0
fi
file="$fixtures/$name.json"
if [ "$name" = "graphql" ] && [ -n "$graphql_after" ] && [ -f "$fixtures/graphql.cursor-$graphql_after.json" ]; then
  # Cursor-keyed page: the fixture named by the requested cursor wins, so a
  # case can lay out a distinct advancing page per cursor and walk the full
  # page budget. Falls through to the single page-2 fixture when absent —
  # the two-page pattern's shape.
  file="$fixtures/graphql.cursor-$graphql_after.json"
elif [ "$name" = "graphql" ] && [ "$graphql_page2" = "1" ] && [ -f "$fixtures/graphql.page2.json" ]; then
  file="$fixtures/graphql.page2.json"
elif [ "$name" = "graphql" ] && [ -n "$graphql_after" ]; then
  # A follow-up request with NEITHER a cursor-keyed fixture NOR a page-2
  # fixture would silently re-serve page one — a deep-walk case missing one
  # of its files (a valid-looking cursor with a fixture gap) must refuse,
  # not fabricate coverage.
  printf 'gh-shim-error=page value=%q\n' "$graphql_after" >&2
  exit 93
fi
[ -f "$file" ] || { printf 'gh-shim-error=fixture value=%q\n' "$file" >&2; exit 91; }
if [ -n "$filter" ]; then jq -r "$filter" <"$file"; else cat "$file"; fi
if [ "$paginate" = "1" ] && [ -f "$fixtures/$name.page2.json" ]; then
  if [ -n "$filter" ]; then jq -r "$filter" <"$fixtures/$name.page2.json"; else cat "$fixtures/$name.page2.json"; fi
fi
