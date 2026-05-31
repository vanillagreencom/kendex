#!/usr/bin/env bash
# Regression test: local cache queries must not resolve LINEAR_API_KEY/op://.
# Cache reads are documented as no-API operations, so they must work even when
# 1Password auth is unavailable. Live/API commands must still attempt auth.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/.agents/skills" "$tmp/.cache/linear" "$tmp/bin"
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

  set +e
  RUN_OUT=$(PATH="$tmp/bin:$PATH" LINEAR_API_KEY='op://vault/item/field' \
    bash "$tmp/.agents/skills/linear/scripts/linear.sh" "$@" 2>"$err")
  local rc=$?
  set -e

  if (( rc != 0 )); then
    echo "FAIL $label exited $rc: $(cat "$err")"
    exit 1
  fi

  if [[ -e "$OP_SENTINEL" ]]; then
    echo "FAIL $label attempted 1Password resolution: $(cat "$OP_SENTINEL")"
    exit 1
  fi

  if grep -qiE 'Failed to resolve LINEAR_API_KEY|1Password|op CLI' "$err"; then
    echo "FAIL $label emitted auth error: $(cat "$err")"
    exit 1
  fi
}

run_cache_read "cache projects list" cache projects list --format=safe
projects_out="$RUN_OUT"
if ! echo "$projects_out" | jq -e '.[0].name == "Authless Cache Project"' >/dev/null; then
  echo "FAIL cache projects list returned unexpected output: $projects_out"
  exit 1
fi

run_cache_read "cache issues list" cache issues list --state "Backlog,Todo,In Progress" --max --format=safe
issues_out="$RUN_OUT"
if ! echo "$issues_out" | jq -e '.[0].id == "AUTH-1"' >/dev/null; then
  echo "FAIL cache issues list returned unexpected output: $issues_out"
  exit 1
fi

run_cache_read "cache labels list" cache labels list --format=safe
labels_out="$RUN_OUT"
if ! echo "$labels_out" | jq -e '.[] | select(.name == "Agent" and .is_group == true)' >/dev/null; then
  echo "FAIL cache labels list did not expose is_group=true: $labels_out"
  exit 1
fi
if ! echo "$labels_out" | jq -e '.[] | select(.name == "agent:test" and .parent == "Agent" and .is_group == false)' >/dev/null; then
  echo "FAIL cache labels list returned unexpected child label output: $labels_out"
  exit 1
fi

rm -f "$OP_SENTINEL"
: > "$err"
set +e
PATH="$tmp/bin:$PATH" LINEAR_API_KEY='op://vault/item/field' \
  bash "$tmp/.agents/skills/linear/scripts/linear.sh" auth-check >/dev/null 2>"$err"
auth_rc=$?
set -e

if (( auth_rc == 0 )); then
  echo "FAIL auth-check unexpectedly succeeded with fake op resolver"
  exit 1
fi

if [[ ! -s "$OP_SENTINEL" ]]; then
  echo "FAIL auth-check did not attempt 1Password resolution"
  exit 1
fi

if ! grep -q 'op invoked: read op://vault/item/field' "$OP_SENTINEL"; then
  echo "FAIL auth-check invoked op with unexpected args: $(cat "$OP_SENTINEL")"
  exit 1
fi

if ! grep -q 'Failed to resolve LINEAR_API_KEY from 1Password' "$err"; then
  echo "FAIL auth-check emitted unexpected stderr: $(cat "$err")"
  exit 1
fi

echo "all pass"
