#!/usr/bin/env bash
# The live `issues get` names the GitHub issues Linear's GitHub sync links an
# issue to, as github_sync; the cache read, which stores no sync, names none.
# Consumer: skills/orch/workflows/oversee.md § Outside contributions matches
# github_sync against the watch's `outside-contribution <repo>#<N>` key.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

# GIT_DIR outranks -C, so where it is inherited `git -C "$TMP_ROOT" init` below
# re-inits the ambient repository. All four go, per skills/AGENTS.md.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin" "$TMP_ROOT/.cache/linear"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
git -C "$TMP_ROOT" init -q -b main
git -C "$TMP_ROOT" config gc.auto 0
git -C "$TMP_ROOT" config maintenance.auto false
export LINEAR_CACHE_ROOT="$TMP_ROOT"
# Both reads assert the safe object; an inherited LINEAR_FORMAT would change it.
export LINEAR_FORMAT=safe

base='{"id":"issue-1","identifier":"KEN-1","title":"mirror","description":"","state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":null,"projectMilestone":null,"cycle":null,"parent":null,"team":{"name":"Kendex"},"labels":{"nodes":[]},"priority":0,"estimate":null,"sortOrder":0,"url":"","createdAt":"","updatedAt":"","archivedAt":null,"trashed":false,"children":{"nodes":[]},"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}'
printf '[%s]\n' "$base" >"$TMP_ROOT/.cache/linear/issues.json"
printf '[]\n' >"$TMP_ROOT/.cache/linear/projects.json"
printf '[]\n' >"$TMP_ROOT/.cache/linear/cycles.json"
printf '{"synced_at":"%s"}\n' "$(date -Iseconds)" >"$TMP_ROOT/.cache/linear/meta.json"

# The API stub answers every issue(id:) query with FIXTURE, and with an error
# when the query does not ask for syncedWith, as Linear leaves out a field
# nobody asked for.
cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
query="$(jq -r '.query' <<<"$payload")"
issue="$FIXTURE"
[[ "$query" == *syncedWith* ]] || issue="$(jq -c 'del(.syncedWith)' <<<"$issue")"
printf '%s___HTTP_CODE___200' "$(jq -cn --argjson issue "$issue" '{data:{issue:$issue}}')"
SH
chmod +x "$TMP_ROOT/bin/curl"

LINEAR="$TMP_ROOT/.agents/skills/linear/scripts/linear.sh"
run_live() {
  local fixture="$1"
  shift
  (cd "$TMP_ROOT" && PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY_OVERRIDE=test-token \
    FIXTURE="$fixture" bash "$LINEAR" "$@")
}

# Shaped input: what syncedWith carries, and the github_sync the live read
# prints for it. A non-GitHub sync carries no GitHub fields.
while IFS='|' read -r label synced expected; do
  fixture="$(jq -c --argjson s "$synced" '. + {syncedWith: $s}' <<<"$base")"
  assert_jq "$label" "$(run_live "$fixture" issues get KEN-1)" ".github_sync == $expected"
done <<'ROWS'
a synced mirror names its GitHub issue|[{"metadata":{"owner":"vanillagreencom","repo":"kendex","number":3130}}]|["vanillagreencom/kendex#3130"]
a mixed-case sync names its GitHub issue lowercased|[{"metadata":{"owner":"Acme","repo":"Tool","number":12}}]|["acme/tool#12"]
an issue with no sync names none|[]|[]
a sync to another service names none|[{"metadata":{}},{"metadata":null}]|[]
ROWS

assert_jq "the cache read, which stores no sync, prints no github_sync" \
  "$(cd "$TMP_ROOT" && bash "$LINEAR" cache issues get KEN-1)" 'has("github_sync") | not'
