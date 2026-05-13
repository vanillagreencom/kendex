#!/usr/bin/env bash
# Static check: every OpenCode entry point in open-terminal must carry
# FLIGHTDECK_MANAGED=1 (directly or via FLIGHTDECK_PANE_ENV /
# flightdeck_pane_env_str). This catches refactors that move OpenCode
# spawn logic out of an env-decorated path. The authoritative process
# env for OpenCode is the `opencode serve` process — tool calls
# executed via run --attach inherit from it — but we belt-and-braces
# also decorate run --attach itself and the attach TUI.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
SRC="$SKILL_DIR/scripts/open-terminal"

PASS=0; FAIL=0
assert_match() {
  local name="$1" pattern="$2"
  if grep -nE -- "$pattern" "$SRC" >/dev/null 2>&1; then
    PASS=$((PASS+1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL+1)); printf '  FAIL  %s\n        pattern: %s\n' "$name" "$pattern"
  fi
}

echo "=== OpenCode entry points carry FLIGHTDECK_MANAGED=1 ==="

# Step 0: opencode serve (long-lived server, authoritative process env).
assert_match "opencode serve carries FLIGHTDECK_MANAGED=1" \
  'FLIGHTDECK_MANAGED=1[[:space:]]+setsid[[:space:]]+nohup[[:space:]]+"\$bin"[[:space:]]+serve'

# Step 1: opencode run --attach bootstrap (create_oc_session).
assert_match "create_oc_session: opencode run --attach carries FLIGHTDECK_MANAGED=1" \
  'FLIGHTDECK_MANAGED=1[[:space:]]+timeout[^"]*"\$bin"[[:space:]]+run[[:space:]]+--attach'

# Step 2: fire-and-forget orchestration kickoff.
assert_match "fire_orchestration_async: opencode run --attach carries FLIGHTDECK_MANAGED=1" \
  'FLIGHTDECK_MANAGED=1[[:space:]]+setsid[[:space:]]+nohup[[:space:]]+"\$bin"[[:space:]]+run[[:space:]]+--attach'

# Step 3: attach TUI sent via tmux send-keys uses flightdeck_pane_env_str.
assert_match "attach TUI uses flightdeck_pane_env_str" \
  'attach_cmd=\$\(printf[^"]*"%s %s attach[^"]*"[[:space:]]+"\$\(flightdeck_pane_env_str\)"'

# Helper sanity: the decoration arrays exist and include FLIGHTDECK_MANAGED=1.
assert_match "FLIGHTDECK_PANE_ENV defined" \
  '^FLIGHTDECK_PANE_ENV=\(env FLIGHTDECK_MANAGED=1\)'
assert_match "FLIGHTDECK_PI_PANE_ENV defined" \
  '^FLIGHTDECK_PI_PANE_ENV=\(env FLIGHTDECK_MANAGED=1 FLIGHTDECK_CHILD_PANE=1\)'

# Defence against bare `opencode serve` / `opencode run --attach` lines
# without FLIGHTDECK_MANAGED= prefix anywhere on the same logical line.
# Looks for any opencode subcommand spawn that doesn't have the prefix
# within ~80 chars before it. Tolerates the documentation comments by
# excluding any line starting with `#`.
bad=$(grep -nE '"\$bin"[[:space:]]+(serve|run[[:space:]]+--attach)' "$SRC" \
      | grep -v '^[^:]*:[[:space:]]*#' \
      | awk -F: '{print}' \
      | while IFS= read -r line; do
          # `line` is like "412:  ( cd \"$wt_path\" && FLIGHTDECK_MANAGED=1 ..."
          payload="${line#*:}"
          if ! grep -qE 'FLIGHTDECK_MANAGED=1' <<<"$payload"; then
            printf '%s\n' "$line"
          fi
        done)
if [[ -z "$bad" ]]; then
  PASS=$((PASS+1)); printf '  ok    no bare opencode serve / run --attach (all are FLIGHTDECK_MANAGED-decorated)\n'
else
  FAIL=$((FAIL+1)); printf '  FAIL  bare opencode invocation(s) without FLIGHTDECK_MANAGED=1:\n%s\n' "$bad"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
