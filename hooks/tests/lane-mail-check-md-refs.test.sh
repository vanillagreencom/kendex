#!/usr/bin/env bash
# kendex ships lane-mail-check to these consumer destinations. The catalog's
# skills/ tree can resolve a source-only citation that an install cannot.
set -euo pipefail

# shellcheck source=lib/lane-mail-world.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/lane-mail-world.sh"

echo "=== lane-mail-check: consumer references ==="

CONSUMER="$TMP_ROOT/consumer"
mkdir -p "$CONSUMER/.agents/skills/orch/references"
git -C "$CONSUMER" init -q
git -C "$CONSUMER" config gc.auto 0
git -C "$CONSUMER" config maintenance.auto false
cp "$REPO_ROOT/skills/orch/references/oversee-events.md" \
  "$CONSUMER/.agents/skills/orch/references/oversee-events.md"

# GitHub's hook directory is install-only in this catalog; the other rows
# scan the tracked renders, not a second copy of the source.
for destination in .claude/hooks .codex/hooks .github/hooks .pi/kendex/hooks; do
  source_hook="$REPO_ROOT/$destination/lane-mail-check.sh"
  [ "$destination" != .github/hooks ] || source_hook="$HOOK"
  mkdir -p "$CONSUMER/$destination"
  cp "$source_hook" "$CONSUMER/$destination/lane-mail-check.sh"
done
git -C "$CONSUMER" add -A
assert_eq "$([ -e "$CONSUMER/skills" ] && echo present || echo absent)" absent \
  "the consumer carries no catalog source tree"

# The control plants the old citation in fixture copies only. Both rows use
# the real md-refs scanner; sources=4 proves it scans every destination.
for row in clean:0:0 old-citation:1:4; do
  if [ "${row%%:*}" = old-citation ]; then
    for destination in .claude/hooks .codex/hooks .github/hooks .pi/kendex/hooks; do
      printf '\n# skills/orch/references/oversee-events.md § Judgement rules\n' \
        >> "$CONSUMER/$destination/lane-mail-check.sh"
    done
    git -C "$CONSUMER" add -A
  fi
  rc=0
  output="$(cd "$CONSUMER" && env -i PATH="$PATH" HOME="$TMP_ROOT" LC_ALL=C \
    COMMIT_GUARDS_SETTINGS_FILE=/dev/null COMMIT_GUARDS_MD_EXCLUDES=tools/md-excludes \
    COMMIT_GUARDS_MD_REFS_PATHS='docs/*.md' \
    COMMIT_GUARDS_MD_REFS_SOURCE_PATHS='.claude/hooks/*.sh .codex/hooks/*.sh .github/hooks/*.sh .pi/kendex/hooks/*.sh' \
    "$REPO_ROOT/skills/commit-guards/scripts/md-refs" --all 2>&1)" || rc=$?
  expected="${row#*:}"
  summary="$(grep '^md-refs: summary=' <<< "$output")" || { printf '%s\n' "$output"; exit 1; }
  assert_eq "rc=$rc ${summary%% decisions=*}" \
    "rc=${expected%%:*} md-refs: summary=violations=${expected#*:} references=${expected#*:} markdown=0 sources=4" \
    "${row%%:*}: md-refs judges every consumer hook"
done

printf '\n=== %s passed, %s failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]