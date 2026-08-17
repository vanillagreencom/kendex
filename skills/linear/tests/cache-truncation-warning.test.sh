#!/usr/bin/env bash
# A truncated cache listing says so (vstack #1390 / VST-320).
#
# `cache issues list` slices to 75 rows by default; a bare array of exactly 75
# is indistinguishable from a complete result, so the slice must announce
# itself on stderr. Locks in:
#   A. >limit rows: stdout carries exactly the limit, stderr carries the
#      warning naming both counts.
#   B. --max: everything, no warning.
#   C. --limit N below the total warns; a listing within the limit does not.
#
# Fully offline — pure cache read, no curl needed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/.cache/linear"
git -C "$TMP_ROOT" init -q -b main
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
LINEAR="$TMP_ROOT/.agents/skills/linear/scripts/linear.sh"

cat >"$TMP_ROOT/.cache/linear/meta.json" <<'JSON'
{"synced_at":"2026-07-17T00:00:00+00:00"}
JSON

{
  for i in $(seq 1 80); do
    printf '{"id":"uuid-T-%s","identifier":"T-%s","title":"T-%s title","state":{"name":"Todo","type":"unstarted"},"labels":{"nodes":[]},"project":null,"archivedAt":null,"trashed":false}\n' "$i" "$i" "$i"
  done
} | jq -s '.' >"$TMP_ROOT/.cache/linear/issues.json"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

cd "$TMP_ROOT"

OUT="$("$LINEAR" cache issues list --no-project --format ids 2>"$TMP_ROOT/err")" || true
ERR="$(cat "$TMP_ROOT/err")"
[ "$(printf '%s\n' "$OUT" | wc -l)" -eq 75 ] && ok "default listing carries exactly 75 rows" || bad "default rows" "$(printf '%s' "$OUT" | wc -l)"
case "$ERR" in
  *"75 of 80"*) ok "the slice announces itself with both counts" ;;
  *) bad "truncation warning" "stderr: $ERR" ;;
esac

OUT="$("$LINEAR" cache issues list --no-project --max --format ids 2>"$TMP_ROOT/err")" || true
ERR="$(cat "$TMP_ROOT/err")"
[ "$(printf '%s\n' "$OUT" | wc -l)" -eq 80 ] && ok "--max returns everything" || bad "--max rows" "$(printf '%s' "$OUT" | wc -l)"
[ -z "$ERR" ] && ok "--max emits no warning" || bad "--max stderr" "$ERR"

OUT="$("$LINEAR" cache issues list --no-project --limit 10 --format ids 2>"$TMP_ROOT/err")" || true
ERR="$(cat "$TMP_ROOT/err")"
[ "$(printf '%s\n' "$OUT" | wc -l)" -eq 10 ] && ok "--limit 10 carries 10 rows" || bad "--limit rows" "$(printf '%s' "$OUT" | wc -l)"
case "$ERR" in
  *"10 of 80"*) ok "--limit below the total warns" ;;
  *) bad "--limit warning" "stderr: $ERR" ;;
esac

OUT="$("$LINEAR" cache issues list --no-project --limit 100 --format ids 2>"$TMP_ROOT/err")" || true
ERR="$(cat "$TMP_ROOT/err")"
[ -z "$ERR" ] && ok "a listing within the limit stays quiet" || bad "within-limit stderr" "$ERR"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
