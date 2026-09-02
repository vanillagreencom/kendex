#!/usr/bin/env bash
# Regression test: local cache queries must not resolve LINEAR_API_KEY/op://.
# Cache reads are documented as no-API operations, so they must work even when
# 1Password auth is unavailable. Live/API commands must still attempt auth.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

assert_tmpdir tmp

mkdir -p "$tmp/.agents/skills" "$tmp/.cache/linear" "$tmp/bin"
git -C "$tmp" init -q -b main

# This root's own cache is the subject, so it replaces the assert lib's default
# sandbox — still scratch, so the exit verdict's containment check holds.
export LINEAR_CACHE_ROOT="$tmp"
cp -R "$SKILL_DIR" "$tmp/.agents/skills/linear"

export OP_SENTINEL="$tmp/op-invocations.txt"
cat > "$tmp/bin/op" <<'SH'
#!/usr/bin/env bash
echo "op invoked: $*" >> "${OP_SENTINEL:?}"
echo "fake op failure" >&2
exit 1
SH
chmod +x "$tmp/bin/op"

cat > "$tmp/.cache/linear/meta.json" <<'JSON'
{"synced_at":"2026-05-30T00:00:00+00:00"}
JSON

cat > "$tmp/.cache/linear/projects.json" <<'JSON'
[
  {
    "id": "project-1",
    "name": "Authless Cache Project",
    "description": "",
    "content": "",
    "state": "started",
    "progress": 0.5,
    "health": "on-track",
    "sortOrder": 1,
    "teams": {"nodes": []},
    "labels": {"nodes": []}
  }
]
JSON

cat > "$tmp/.cache/linear/issues.json" <<'JSON'
[
  {
    "id": "issue-uuid-1",
    "identifier": "AUTH-1",
    "title": "Cache auth regression",
    "description": "",
    "state": {"name": "Todo", "type": "unstarted"},
    "labels": {"nodes": []},
    "project": {"id": "project-1", "name": "Authless Cache Project"},
    "parent": null,
    "projectMilestone": null,
    "cycle": null,
    "relations": {"nodes": []},
    "inverseRelations": {"nodes": []},
    "archivedAt": null,
    "trashed": false
  }
]
JSON

cat > "$tmp/.cache/linear/labels.json" <<'JSON'
[
  {
    "id": "label-group-1",
    "name": "Agent",
    "color": "#9C27B0",
    "description": "Agent group",
    "isGroup": true,
    "team": {"name": "Claude"},
    "parent": null
  },
  {
    "id": "label-child-1",
    "name": "agent:test",
    "color": "#9C27B0",
    "description": "Test agent",
    "isGroup": false,
    "team": {"name": "Claude"},
    "parent": {"name": "Agent"}
  }
]
JSON

err="$tmp/stderr.txt"
RUN_OUT=""

run_cache_read() {
  local label="$1"
  shift
  rm -f "$OP_SENTINEL"
  : > "$err"

  local rc=0
  RUN_OUT=$(cd "$tmp" && PATH="$tmp/bin:$PATH" LINEAR_API_KEY='op://vault/item/field' \
    bash "$tmp/.agents/skills/linear/scripts/linear.sh" "$@" 2>"$err") || rc=$?

  assert_eq "$label: exits zero without auth" "$rc" 0
  assert_not "$label: attempts no 1Password resolution" test -e "$OP_SENTINEL"
  assert_not "$label: emits no auth error" \
    grep -qiE 'Failed to resolve LINEAR_API_KEY|1Password|op CLI' "$err"
}

run_cache_read "cache issues list help" cache issues list --help
help_out="$RUN_OUT"
assert_contains "cache issues list --help prints cache help" \
  "$help_out" 'Linear Cache Query - Read from local cache'
assert_not "cache issues list --help prints help, not JSON query output" \
  jq -e . <<<"$help_out"

run_cache_read "cache projects list" cache projects list --format=safe
projects_out="$RUN_OUT"
assert_jq "cache projects list reads the cached project" \
  "$projects_out" '.[0].name == "Authless Cache Project"'

run_cache_read "cache issues list" cache issues list --state "Backlog,Todo,In Progress" --max --format=safe
issues_out="$RUN_OUT"
assert_jq "cache issues list reads the cached issue" "$issues_out" '.[0].id == "AUTH-1"'

run_cache_read "cache labels list" cache labels list --format=safe
labels_out="$RUN_OUT"
assert_jq "cache labels list exposes is_group on a group label" \
  "$labels_out" '.[] | select(.name == "Agent" and .is_group == true)'
assert_jq "cache labels list reports a child label's parent" \
  "$labels_out" '.[] | select(.name == "agent:test" and .parent == "Agent" and .is_group == false)'

rm -f "$OP_SENTINEL"
: > "$err"
auth_rc=0
(cd "$tmp" && PATH="$tmp/bin:$PATH" LINEAR_API_KEY='op://vault/item/field' \
  bash "$tmp/.agents/skills/linear/scripts/linear.sh" auth-check >/dev/null 2>"$err") || auth_rc=$?

assert_ne "auth-check fails when the op resolver cannot answer" "$auth_rc" 0
assert "auth-check does attempt 1Password resolution" test -s "$OP_SENTINEL"
assert_file_contains "auth-check invokes op with the configured reference" \
  "$OP_SENTINEL" 'op invoked: read op://vault/item/field'
assert_file_contains "auth-check names the failed 1Password resolution" \
  "$err" 'Failed to resolve LINEAR_API_KEY from 1Password'

