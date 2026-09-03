#!/usr/bin/env bash
# A relation write-through leaves the cached issue's team intact (KEN-1173).
#
# `cache_refresh_issues` re-fetches both sides of a relation and hands each node
# to `cache_upsert_issue`, which REPLACES the whole cached document. Its
# RefreshIssues query selected no `team { name }` while `sync_issues` and
# `ISSUE_RETURN_FIELDS` both do, so every issue touched by `issues add-relation`
# or `issues remove-relation` lost its team in the cache until the next full
# sync. That was invisible until `cache issues list --team X` started filtering:
# the refreshed rows then drop out of a team-scoped listing, and a short listing
# is indistinguishable from a complete one. The rows a relation write touches —
# blockers and blocked issues — are exactly what a team-scoped audit reads.
#
# The stub plays a GraphQL server: it returns a field only when the query
# selects it, so the query's own field list is what this proves.
#
# This locks in:
#   A. The refreshed row still carries its team.
#   B. `cache issues list --team KEN` still returns both refreshed issues.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

# GIT_DIR outranks -C, so where it is inherited the init below re-inits the
# ambient repository. All four go together, the house rule in .claude/CLAUDE.md.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/.cache/linear" "$TMP_ROOT/bin"
git -C "$TMP_ROOT" init -q -b main
if [[ ! -d "$TMP_ROOT/.git" ]]; then
  assert_stop "the fixture repository is the one git init created" \
    "no repository at $TMP_ROOT/.git: a git environment variable redirected git init"
fi

export LINEAR_CACHE_ROOT="$TMP_ROOT"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
LINEAR="$TMP_ROOT/.agents/skills/linear/scripts/linear.sh"

cat >"$TMP_ROOT/.cache/linear/meta.json" <<'JSON'
{"synced_at":"2026-07-17T00:00:00+00:00"}
JSON

cat >"$TMP_ROOT/.cache/linear/issues.json" <<'JSON'
[
  {"id":"uuid-KEN-1","identifier":"KEN-1","title":"one",
   "state":{"name":"Todo","type":"unstarted"},"labels":{"nodes":[]},
   "project":null,"team":{"name":"KEN"},"archivedAt":null,"trashed":false,
   "relations":{"nodes":[]},"inverseRelations":{"nodes":[]}},
  {"id":"uuid-KEN-2","identifier":"KEN-2","title":"two",
   "state":{"name":"Todo","type":"unstarted"},"labels":{"nodes":[]},
   "project":null,"team":{"name":"KEN"},"archivedAt":null,"trashed":false,
   "relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}
]
JSON

# The stub answers RefreshIssues from the query's own field list: `team` is in
# the response only when the query asked for it. A stub that always returned it
# would report a green suite whatever the query selects.
cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
query="$(jq -r '.query' <<<"$payload")"
variables="$(jq -c '.variables' <<<"$payload")"

case "$query" in
*"GetIssue"*)
  ref="$(jq -r '.id' <<<"$variables")"
  printf '{"data":{"issue":{"id":"uuid-%s"}}}___HTTP_CODE___200' "$ref"
  ;;
*"CreateRelation"*)
  printf '%s' '{"data":{"issueRelationCreate":{"success":true,"issueRelation":{"id":"rel-1","type":"related","issue":{"identifier":"KEN-1","title":"one"},"relatedIssue":{"identifier":"KEN-2","title":"two"}}}}}___HTTP_CODE___200'
  ;;
*"RefreshIssues"*)
  team_field=""
  case "$query" in
  *"team { name }"*) team_field=',"team":{"name":"KEN"}' ;;
  esac
  printf '{"data":{"issues":{"nodes":[{"id":"uuid-KEN-1","identifier":"KEN-1","title":"one","state":{"name":"Todo","type":"unstarted"},"labels":{"nodes":[]},"project":null,"archivedAt":null,"trashed":false,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}%s},{"id":"uuid-KEN-2","identifier":"KEN-2","title":"two","state":{"name":"Todo","type":"unstarted"},"labels":{"nodes":[]},"project":null,"archivedAt":null,"trashed":false,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}%s}]}}}___HTTP_CODE___200' \
    "$team_field" "$team_field"
  ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected query"}]}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$TMP_ROOT/bin/curl"

add_relation() {
  cd "$TMP_ROOT" && PATH="$TMP_ROOT/bin:$PATH" \
    LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=KEN \
    bash "$LINEAR" issues add-relation KEN-1 --related KEN-2
}

run_status rel_rc add_relation >/dev/null 2>&1
assert_eq "the relation write succeeds against the stub" "$rel_rc" 0

# --- A: the refreshed rows kept their team -----------------------------------
assert_eq "A: both refreshed rows still carry their team" \
  "$(jq -r '[.[] | .team.name // "MISSING"] | sort | join(",")' "$TMP_ROOT/.cache/linear/issues.json")" \
  "KEN,KEN"

# --- B: the team-scoped listing still returns them ---------------------------
listing="$(cd "$TMP_ROOT" && bash "$LINEAR" cache issues list --team KEN --max --format=ids 2>/dev/null)"
assert_eq "B: cache issues list --team KEN still returns both refreshed issues" \
  "$(printf '%s\n' "$listing" | sort | tr '\n' ',')" "KEN-1,KEN-2,"
