#!/usr/bin/env bash
# The issues sync pulls each issue's comments inline. Asking for `comments {
# nodes }` with no page size takes Linear's default connection page and drops
# the remainder with no signal — the per-issue comment file that lands in the
# cache looks complete either way, and every reader downstream (tpm-audit's
# § 1.4.1 read included) treats it as the whole thread.
#
# Locks in:
#   A. the query asks for a page size and for pageInfo on the comments
#      connection, so a full page is detectable at all;
#   B. extract_comments names the issues whose page came back full;
#   C. a normal sync stays silent, and the comment files it writes are
#      unaffected by the extra pageInfo field.
#
# Fully offline: extract_comments is called directly on fixture nodes, no
# GraphQL and no network.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SYNC="$SKILL_DIR/scripts/commands/sync.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

# --- A. the query can tell a full page from a complete one ------------------

comments_query="$(grep -F 'comments(' "$SYNC" || true)"
case "$comments_query" in
  *"first:"*) ok "the comments connection asks for an explicit page size" ;;
  *) bad "comments page size" "no comments(first: N) in sync.sh" ;;
esac
case "$comments_query" in
  *"pageInfo"*"hasNextPage"*) ok "the comments connection asks for hasNextPage" ;;
  *) bad "comments pageInfo" "line: ${comments_query:-<none>}" ;;
esac

# --- B/C. extract_comments over fixture nodes -------------------------------

# sync.sh sources the skill's libs and self-executes only when run as a
# command; sourced with no arguments it just defines its functions.
export CACHE_DIR="$TMP_ROOT/cache"
mkdir -p "$CACHE_DIR/comments"
# shellcheck disable=SC1090
source "$SYNC"

node() { # node <identifier> <hasNextPage>
  printf '{"identifier":"%s","comments":{"pageInfo":{"hasNextPage":%s},"nodes":[{"id":"c-%s","body":"b","createdAt":"2026-01-01","updatedAt":"2026-01-01","user":{"name":"n"}}]}}' \
    "$1" "$2" "$1"
}

{ node T-1 false; echo; node T-2 true; echo; node T-3 true; echo; } \
  | jq -s '.' >"$TMP_ROOT/full.json"
extract_comments "$TMP_ROOT/full.json" 2>"$TMP_ROOT/err"
ERR="$(cat "$TMP_ROOT/err")"
case "$ERR" in
  *"T-2"*"T-3"*) ok "a full comment page names every short issue" ;;
  *) bad "truncation warning" "stderr: ${ERR:-<empty>}" ;;
esac
case "$ERR" in
  *"T-1"*) bad "truncation warning" "named T-1, whose page was complete" ;;
  *) ok "an issue whose page was complete is not named" ;;
esac

{ node U-1 false; echo; node U-2 false; echo; } | jq -s '.' >"$TMP_ROOT/clean.json"
extract_comments "$TMP_ROOT/clean.json" 2>"$TMP_ROOT/err"
ERR="$(cat "$TMP_ROOT/err")"
[ -z "$ERR" ] && ok "a complete pull says nothing" || bad "clean sync stderr" "$ERR"

# The extra pageInfo field must not leak into the per-issue comment files the
# cache readers parse.
if [ "$(jq -r 'type' "$CACHE_DIR/comments/U-1.json")" = "array" ] \
  && [ "$(jq -r '.[0].id' "$CACHE_DIR/comments/U-1.json")" = "c-U-1" ]; then
  ok "the comment file is still the bare node array"
else
  bad "comment file shape" "$(cat "$CACHE_DIR/comments/U-1.json")"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
