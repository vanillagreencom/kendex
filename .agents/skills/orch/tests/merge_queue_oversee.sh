#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo/.agents/skills" "$TMP/bin"
ln -s "$ORCH" "$TMP/repo/.agents/skills/orch"
git -C "$TMP/repo" init -q

# The shared `gh` fake. The source tree is found through git rather than a
# relative hop, so this file works unchanged from skills/ and from the
# .agents/ render beside it; a consuming repo carries the render but runs no
# suite from it (.github/workflows/skill-tests.yml proves them at the source).
# shellcheck source=../../../tools/tests/lib/gh-stub.sh
. "$(git -C "$TEST_DIR" rev-parse --show-toplevel)/tools/tests/lib/gh-stub.sh"
GH_STUB_DIR="$TMP/gh-stub" gh_stub_install "$TMP/bin"
gh_stub_answer auth-status logged-in
gh_stub_answer pr-list '[]'

cat > "$TMP/bin/pr-watch" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TMP/bin/event" <<'EOF'
#!/usr/bin/env bash
[[ "${*: -1}" == KEN-829 ]] || exit 1
printf 'ready KEN-829 WATCH-123\n'
EOF
chmod +x "$TMP/bin/pr-watch" "$TMP/bin/event"

run_watch() {
  local script="$1"
  (cd "$TMP/repo" && PATH="$TMP/bin:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN \
    OVERSEE_WATCH_PR_WATCH="$TMP/bin/pr-watch" OVERSEE_WATCH_MERGE_QUEUE_WATCH="$TMP/bin/event" \
    "$script" --interval 0 --max-loops 1 --repo owner/repo --item KEN-829)
}

out=$(run_watch "$ORCH/scripts/oversee-watch")
[[ "$out" == "EVENT merge-verdict KEN-829 WATCH-123" ]] || {
  printf 'FAIL: oversee-watch did not forward lifecycle event: %s\n' "$out" >&2; exit 1;
}

mkdir -p "$TMP/skills/orch"
cp -R "$ORCH/scripts" "$TMP/skills/orch/"
ln -s "$(cd "$ORCH/.." && pwd)/github" "$TMP/skills/github"
count=$(grep -Fxc '  check_merge_lifecycle' "$TMP/skills/orch/scripts/oversee-watch")
[[ "$count" -eq 1 ]] || { echo 'FAIL: lifecycle invocation count changed' >&2; exit 1; }
sed -i.bak 's/^  check_merge_lifecycle$/  : # check_merge_lifecycle/' "$TMP/skills/orch/scripts/oversee-watch"
rm -f "$TMP/skills/orch/scripts/oversee-watch.bak"
printf '\ncheck_merge_lifecycle\n' >> "$TMP/skills/orch/scripts/oversee-watch"
mutant=$(run_watch "$TMP/skills/orch/scripts/oversee-watch")
[[ "$mutant" == EVENT\ heartbeat* ]] || {
  printf 'FAIL: unreachable EOF decoy revived lifecycle event: %s\n' "$mutant" >&2; exit 1;
}
echo 'merge-queue-oversee: pass'
