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
echo '{"synced_at":"2026-08-12T00:00:00+00:00"}' >"$TMP_ROOT/.cache/linear/meta.json"

run_list() { (cd "$TMP_ROOT" && bash "$LINEAR" cache issues list --max "$@"); }

# Truncated mid-object: valid JSON prefix, unparseable whole — the shape a cache
# write interrupted partway through leaves behind.
printf '%s' '[{"id":"uuid-CC-1","identifier":"CC-1","title":"t"' >"$TMP_ROOT/.cache/linear/issues.json"

corrupt_rc=0
corrupt_out="$(run_list --format=ids 2>&1)" || corrupt_rc=$?
corrupt_stdout_rc=0
corrupt_stdout="$(run_list --format=ids 2>/dev/null)" || corrupt_stdout_rc=$?
assert_ne "the stdout-only read of a corrupt cache also fails" "$corrupt_stdout_rc" 0

assert_ne "a corrupt issues.json exits nonzero" "$corrupt_rc" 0
assert_contains "the error names cache corruption" "$corrupt_out" "corrupt"
assert_eq "corruption puts nothing on stdout" "$corrupt_stdout" ""
assert_not "corruption is not reported as an empty result set" \
  grep -qx '\[\]' <<<"$corrupt_out"

# Control: a well-formed cache still reads normally, so the guard is not simply
# refusing every read.
printf '%s' '[{"id":"uuid-CC-1","identifier":"CC-1","title":"t","state":{"name":"Todo","type":"unstarted"},"labels":{"nodes":[]},"project":null,"archivedAt":null,"trashed":false}]' \
  >"$TMP_ROOT/.cache/linear/issues.json"

good_rc=0
good_out="$(run_list --format=ids 2>&1)" || good_rc=$?

assert_eq "a well-formed cache read still exits zero" "$good_rc" 0
assert_eq "a well-formed cache still reads normally" "$good_out" "CC-1"
