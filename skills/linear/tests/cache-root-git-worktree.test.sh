#!/usr/bin/env bash
# Regression for vstack#779: cache and attachment paths must come from the
# authoritative git worktree root, not the logical spelling used to reach the
# installed skill. A symlinked checkout path makes `pwd` and `git rev-parse`
# disagree lexically; the cache must use the git root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

REAL_ROOT="$TMP_ROOT/real/project"
LINK_ROOT="$TMP_ROOT/link/project"
mkdir -p "$REAL_ROOT/.agents/skills" "$REAL_ROOT/.cache/linear"
git -C "$REAL_ROOT" init -q -b main
ln -s "$SKILL_DIR" "$REAL_ROOT/.agents/skills/linear"
mkdir -p "$TMP_ROOT/link"
ln -s "$TMP_ROOT/real/project" "$LINK_ROOT"

cat >"$REAL_ROOT/.cache/linear/meta.json" <<'JSON'
{"synced_at":"2026-07-22T00:00:00+00:00"}
JSON

cat >"$REAL_ROOT/.cache/linear/issues.json" <<'JSON'
[
  {
    "id": "issue-uuid-1",
    "identifier": "CC-779",
    "title": "Cache root regression",
    "description": "",
    "state": {"name": "Todo", "type": "unstarted"},
    "labels": {"nodes": []},
    "project": null,
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

mkdir -p "$REAL_ROOT/.cache/linear/attachments/files"
printf 'attachment\n' >"$REAL_ROOT/.cache/linear/attachments/files/cc-779.txt"
cat >"$REAL_ROOT/.cache/linear/attachments/manifest.json" <<JSON
{
  "https://uploads.linear.app/test/cc-779.txt": {
    "local_path": "$REAL_ROOT/.cache/linear/attachments/files/cc-779.txt",
    "filename": "cc-779.txt",
    "content_type": "text/plain",
    "size": 11,
    "source": "CC-779",
    "context": "description",
    "downloaded_at": "2026-07-22T00:00:00+00:00"
  }
}
JSON

assert_cache_and_attachment_roots() {
  local linear="$1" label="$2" out=""
  out="$(cd "$LINK_ROOT" && bash "$linear" cache issues get CC-779 --with-bundle --format=safe 2>/dev/null)"
  if ! jq -e --arg attach "$REAL_ROOT/.cache/linear/attachments/files/cc-779.txt" \
    '.id == "CC-779" and .attachments[0].local_path == $attach' \
    >/dev/null 2>&1 <<<"$out"; then
    echo "FAIL $label did not read cache and attachments from physical git root: $out"
    exit 1
  fi
}

assert_cache_and_attachment_roots "$LINK_ROOT/.agents/skills/linear/scripts/linear.sh" "logical installed invocation"
assert_cache_and_attachment_roots "$SKILL_DIR/scripts/linear.sh" "canonical source-path invocation"

if ! (cd "$LINK_ROOT" && bash -u -c 'source "$1"; : "$_CACHE_LIB_DIR"; declare -F cache_refresh_issues >/dev/null' _ "$SKILL_DIR/scripts/lib/cache.sh"); then
  echo "FAIL cache library did not retain its own source directory for write-through refreshes"
  exit 1
fi

EMPTY_REAL="$TMP_ROOT/empty-real/project"
EMPTY_LINK="$TMP_ROOT/empty-link/project"
mkdir -p "$EMPTY_REAL/.agents/skills" "$TMP_ROOT/empty-link"
git -C "$EMPTY_REAL" init -q -b main
ln -s "$SKILL_DIR" "$EMPTY_REAL/.agents/skills/linear"
ln -s "$EMPTY_REAL" "$EMPTY_LINK"
assert_missing_cache_diagnostic() {
  local linear="$1" label="$2" err="" rc=0
  set +e
  err="$(cd "$EMPTY_LINK" && bash "$linear" cache issues list 2>&1 >/dev/null)"
  rc=$?
  set -e

  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL $label missing cache unexpectedly succeeded"
    exit 1
  fi

  if ! jq -e --arg cache_dir "$EMPTY_REAL/.cache/linear" --arg meta "$EMPTY_REAL/.cache/linear/meta.json" \
    '.error == "No cache found. Run: linear.sh sync" and .cache_dir == $cache_dir and .meta_path == $meta' \
    >/dev/null 2>&1 <<<"$err"; then
    echo "FAIL $label missing-cache diagnostic did not name the physical cache path: $err"
    exit 1
  fi
}

assert_missing_cache_diagnostic "$EMPTY_LINK/.agents/skills/linear/scripts/linear.sh" "logical installed invocation"
assert_missing_cache_diagnostic "$SKILL_DIR/scripts/linear.sh" "canonical source-path invocation"

echo "all pass"
