#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/event" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${*: -1}" == KEN-829 ]] || exit 1
printf 'ready KEN-829 WATCH-123\n'
EOF
chmod +x "$TMP/event"

out=$( (
  SCRIPT_DIR="$ORCH/scripts"
  PROJECT_ROOT="$TMP"
  WORK_DIR="$TMP"
  ITEMS=(KEN-829)
  OVERSEE_WATCH_MERGE_QUEUE_WATCH="$TMP/event"
  pr_watch_context() { :; }
  die() { echo "$*" >&2; exit 2; }
  source "$ORCH/scripts/lib/merge-queue-events.sh"
  check_merge_lifecycle
) )

[[ "$out" == "EVENT merge-verdict KEN-829 WATCH-123" ]] || {
  printf 'FAIL: lifecycle event was not forwarded: %s\n' "$out" >&2
  exit 1
}
grep -Fxq '  check_merge_lifecycle' "$ORCH/scripts/oversee-watch" || {
  echo 'FAIL: oversee-watch does not invoke the lifecycle event check' >&2
  exit 1
}
echo 'merge-queue-oversee: pass'
