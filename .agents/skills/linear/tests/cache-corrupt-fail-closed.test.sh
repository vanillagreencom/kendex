#!/usr/bin/env bash
# A corrupt cache file fails loudly; it never reports as an empty cache.
#
# cache_jq_file distinguishes an absent file (cold cache — the default is the
# truthful answer) from a present-but-unparseable one (corrupt). Returning the
# same empty default for both would hand every caller "no results" for a broken
# cache, and audits reading that as real would silently under-report.
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
echo '{"synced_at":"2026-08-12T00:00:00+00:00"}' >"$TMP_ROOT/.cache/linear/meta.json"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; [[ -n "${2:-}" ]] && printf '        %s\n' "$2" >&2; }

run_list() { (cd "$TMP_ROOT" && bash "$LINEAR" cache issues list --max "$@"); }

# Truncated mid-object: valid JSON prefix, unparseable whole — the shape a cache
# write interrupted partway through leaves behind.
printf '%s' '[{"id":"uuid-CC-1","identifier":"CC-1","title":"t"' >"$TMP_ROOT/.cache/linear/issues.json"

corrupt_out="$(run_list --format=ids 2>&1 || true)"
if run_list --format=ids >/dev/null 2>&1; then
  fail "a corrupt issues.json should not exit 0" "$corrupt_out"
else
  pass "a corrupt issues.json exits nonzero"
fi
if grep -q 'corrupt' <<<"$corrupt_out"; then
  pass "the error names cache corruption"
else
  fail "the error does not name corruption" "$corrupt_out"
fi
if [[ -z "$(run_list --format=ids 2>/dev/null || true)" ]] && ! grep -qx '\[\]' <<<"$corrupt_out"; then
  pass "corruption is not reported as an empty result set"
else
  fail "corruption degenerated into an empty result set" "$corrupt_out"
fi

# Control: a well-formed cache still reads normally, so the guard is not simply
# refusing every read.
printf '%s' '[{"id":"uuid-CC-1","identifier":"CC-1","title":"t","state":{"name":"Todo","type":"unstarted"},"labels":{"nodes":[]},"project":null,"archivedAt":null,"trashed":false}]' \
  >"$TMP_ROOT/.cache/linear/issues.json"
if [[ "$(run_list --format=ids 2>/dev/null)" == "CC-1" ]]; then
  pass "a well-formed cache still reads normally"
else
  fail "the guard broke a well-formed cache read" "$(run_list --format=ids 2>&1 || true)"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
