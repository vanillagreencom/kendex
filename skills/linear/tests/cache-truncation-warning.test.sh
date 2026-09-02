#!/usr/bin/env bash
# A truncated cache listing says so (kendex #1390 / VST-320).
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
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/.cache/linear"
git -C "$TMP_ROOT" init -q -b main

# This root's own cache is the subject, so it replaces the assert lib's default
# sandbox — still scratch, so the exit verdict's containment check holds.
export LINEAR_CACHE_ROOT="$TMP_ROOT"
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

cd "$TMP_ROOT"

# list_ids VARPREFIX WANT_RC ARGS... — run the listing, leaving <prefix>_out
# and <prefix>_err holding stdout and stderr. WANT_RC is asserted rather than
# swallowed: a listing that printed the right rows and then exited nonzero is a
# regression this suite would otherwise report as green.
list_ids() {
  local prefix="$1" want_rc="$2" out rc=0
  shift 2
  out="$("$LINEAR" cache issues list --no-project --format ids "$@" 2>"$TMP_ROOT/err")" || rc=$?
  printf -v "${prefix}_out" '%s' "$out"
  printf -v "${prefix}_err" '%s' "$(cat "$TMP_ROOT/err")"

  assert_eq "$prefix listing exits $want_rc" "$rc" "$want_rc"
}

# --- A: the default slice announces itself ------------------------------------
list_ids def 0
assert_eq "default listing carries exactly 75 rows" \
  "$(printf '%s\n' "$def_out" | wc -l | tr -d ' ')" "75"
assert_contains "the slice announces itself with both counts" "$def_err" "75 of 80"

# --- B: --max returns everything, silently ------------------------------------
list_ids max 0 --max
assert_eq "--max returns everything" \
  "$(printf '%s\n' "$max_out" | wc -l | tr -d ' ')" "80"
assert_eq "--max emits no warning" "$max_err" ""

# --- C: --limit below the total warns, within it does not ---------------------
list_ids ten 0 --limit 10
assert_eq "--limit 10 carries 10 rows" \
  "$(printf '%s\n' "$ten_out" | wc -l | tr -d ' ')" "10"
assert_contains "--limit below the total warns" "$ten_err" "10 of 80"

list_ids wide 0 --limit 100
assert_eq "a listing within the limit carries every row" \
  "$(printf '%s\n' "$wide_out" | wc -l | tr -d ' ')" "80"
assert_eq "a listing within the limit stays quiet" "$wide_err" ""

# --- D: an overflowing --limit is a config error, not a silent clamp ----------
list_ids overflow 1 --limit 9223372036854775808
assert_contains "an overflowing --limit is a loud config error" "$overflow_err" "9 digits"
