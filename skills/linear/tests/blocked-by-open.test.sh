#!/usr/bin/env bash
# Safe issue output keeps completed blocking relations as history while
# identifying only blockers that still prevent dispatch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
git -C "$TMP_ROOT" init -q -b main

cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '%s' '{"data":{"issue":{"id":"issue-1","identifier":"KEN-1","title":"dependent","description":"","state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":null,"projectMilestone":null,"cycle":null,"parent":null,"team":{"name":"Kendex"},"labels":{"nodes":[]},"priority":0,"estimate":null,"sortOrder":0,"url":"","createdAt":"","updatedAt":"","archivedAt":null,"trashed":false,"children":{"nodes":[]},"relations":{"nodes":[]},"inverseRelations":{"nodes":[{"id":"rel-open","type":"blocks","issue":{"id":"issue-2","identifier":"KEN-2","title":"open","state":{"name":"In Progress","type":"started"}}},{"id":"rel-done","type":"blocks","issue":{"id":"issue-3","identifier":"KEN-3","title":"done","state":{"name":"Done","type":"completed"}}},{"id":"rel-canceled","type":"blocks","issue":{"id":"issue-4","identifier":"KEN-4","title":"canceled","state":{"name":"Canceled","type":"canceled"}}}]}}}}___HTTP_CODE___200'
SH
chmod +x "$TMP_ROOT/bin/curl"

LINEAR="$TMP_ROOT/.agents/skills/linear/scripts/linear.sh"
out="$(cd "$TMP_ROOT" && PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY_OVERRIDE=test-token bash "$LINEAR" issues get KEN-1 --format=safe)"

assert_jq "issues get keeps every blocker but marks only nonterminal blockers open" \
  "$out" '.blocked_by == ["KEN-2", "KEN-3", "KEN-4"] and .blocked_by_open == ["KEN-2"]'

