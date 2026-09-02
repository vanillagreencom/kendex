#!/usr/bin/env bash
# Regression test: a project name that matches both a canceled and a live
# project must resolve to the live one (KEN-1022).
#
# Linear keeps a canceled project under the name a live one reuses, and the
# name query returns both in no fixed order. resolve_project_id took nodes[0],
# so `issues create --project "<name>"` landed the issue in whichever the API
# happened to list first — silently, since a create carrying a valid project id
# succeeds either way. The fixture lists the canceled twin first, which is the
# order the old code got wrong.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

# GIT_DIR outranks -C, so where it is inherited `git -C "$TMP_ROOT" init` below
# re-inits the ambient repository and leaves no fixture repo at all. Git sets it
# for a hook run in a linked worktree; a hook in the main checkout gets
# GIT_INDEX_FILE instead. Reaching the developer's real cache needs GIT_WORK_TREE
# or core.worktree inherited as well, so all four go, which is the house rule in
# .claude/CLAUDE.md. Unsetting at suite scope covers git and the CLI alike.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin" "$TMP_ROOT/.cache/linear"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
# Isolate CACHE_DIR resolution (git rev-parse --show-toplevel) to this
# throwaway root so cache writes from `issues create` stay out of the real
# project's `.cache/linear` (kendex#43).
git -C "$TMP_ROOT" init -q -b main
# Proof the isolation held. Without the unset the line above re-inits the
# ambient repository and leaves no fixture repo behind, and a run that goes on
# from there is writing somewhere nobody sandboxed, so this stops the suite
# rather than recording a failure and continuing.
if [[ ! -d "$TMP_ROOT/.git" ]]; then
  assert_stop "the fixture repository is the one git init created" \
    "no repository at $TMP_ROOT/.git: a git environment variable redirected git init"
fi

cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
query="$(jq -r '.query' <<<"$payload")"
printf '%s\n' "$payload" >> "${CURL_PAYLOAD_LOG:?}"

case "$query" in
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"nodes":[{"id":"team-uuid"}]}}}___HTTP_CODE___200'
  ;;
*"projects(filter:"*)
  printf '%s' '{"data":{"projects":{"nodes":[{"id":"dead-uuid","state":"canceled"},{"id":"live-uuid","state":"backlog"}]}}}___HTTP_CODE___200'
  ;;
*"issueLabels(filter:"*)
  printf '%s' '{"data":{"issueLabels":{"nodes":[{"id":"label-uuid"}]}}}___HTTP_CODE___200'
  ;;
*"issueCreate(input:"*)
  printf '%s' '{"data":{"issueCreate":{"success":true,"issue":{"id":"child-uuid","identifier":"CC-900","title":"t","description":"d","state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":{"id":"live-uuid","name":"Dup"},"projectMilestone":null,"cycle":null,"parent":null,"team":{"name":"Claude"},"labels":{"nodes":[{"name":"agent:rust"}]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/test/issue/CC-900","createdAt":"2026-09-02T00:00:00Z","updatedAt":"2026-09-02T00:00:00Z","archivedAt":null,"trashed":null,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}}}}___HTTP_CODE___200'
  ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected query"}]}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$TMP_ROOT/bin/curl"

PAYLOAD_LOG="$TMP_ROOT/payloads.jsonl"
: >"$PAYLOAD_LOG"

run_create() {
  (
    cd "$TMP_ROOT" && \
    PATH="$TMP_ROOT/bin:$PATH" \
      LINEAR_API_KEY_OVERRIDE=test-token \
      CURL_PAYLOAD_LOG="$PAYLOAD_LOG" \
      bash "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" issues create \
        --title t \
        --team Claude \
        --project Dup \
        --labels agent:rust \
        --priority 3 \
        --description d
  ) >"$TMP_ROOT/create.out" 2>"$TMP_ROOT/create.err"
}

rc=0
run_status rc run_create

assert_eq "issues create succeeds when a canceled project shares the name (canceled-first)" \
  "$rc" 0

assert "the issueCreate payload carries the live project id, not the canceled one (canceled-first)" \
  jq -s -e 'any(.[]; (.query | contains("issueCreate")) and .variables.input.projectId == "live-uuid")' \
  "$PAYLOAD_LOG" >/dev/null
