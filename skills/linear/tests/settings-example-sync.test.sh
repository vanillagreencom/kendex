#!/usr/bin/env bash
# The linear skill ships vstack.settings.toml.example so project installs merge
# its keys' defaults. This keeps that template in lockstep with the repo-root
# vstack.settings.toml.example: every key the skill template declares must exist
# in BOTH files with IDENTICAL default values, so the two places users learn the
# options can never drift.
#
# LINEAR_TEAM must stay empty in both: a non-empty placeholder would be a
# guessed team name, and a guessed name resolves inside whatever workspace the
# API key reaches.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_TEMPLATE="$SCRIPT_DIR/../vstack.settings.toml.example"
ROOT_TEMPLATE="$SCRIPT_DIR/../../../vstack.settings.toml.example"

fail=0

note_fail() {
  echo "FAIL: $1"
  fail=1
}

value_of() {
  # First uncommented assignment of key $2 in file $1, value only.
  sed -n "s/^$2 = \"\(.*\)\"$/\1/p" "$1" | head -1
}

[ -f "$SKILL_TEMPLATE" ] || {
  echo "FAIL: linear skill template missing"
  exit 1
}
grep -q '^\[env\]' "$SKILL_TEMPLATE" || note_fail "skill template declares [env]"

# Downstream installs ship the skill without the repo root template.
[ -f "$ROOT_TEMPLATE" ] || {
  echo "pass: settings-example-sync (no root template)"
  exit 0
}

keys="$(sed -n 's/^\([A-Z][A-Z0-9_]*\) = .*/\1/p' "$SKILL_TEMPLATE")"
[ -n "$keys" ] || note_fail "skill template declares at least one key"

for key in $keys; do
  if ! grep -q "^$key = " "$ROOT_TEMPLATE"; then
    note_fail "$key present in root template"
    continue
  fi
  skill_val="$(value_of "$SKILL_TEMPLATE" "$key")"
  root_val="$(value_of "$ROOT_TEMPLATE" "$key")"
  if [ "$skill_val" != "$root_val" ]; then
    note_fail "$key default drift: skill='$skill_val' root='$root_val'"
  fi
done

# The seeded target must never be a guessed team name.
for template in "$SKILL_TEMPLATE" "$ROOT_TEMPLATE"; do
  team_val="$(value_of "$template" "LINEAR_TEAM")"
  if [ -n "$team_val" ]; then
    note_fail "LINEAR_TEAM in $(basename "$(dirname "$template")")/$(basename "$template") seeds a team name ('$team_val'); it must be empty"
  fi
done

# An unedited seed must stay fail-closed, so the key has to carry the reason.
grep -B12 '^LINEAR_TEAM = ' "$SKILL_TEMPLATE" | grep -qi 'refuse' ||
  note_fail "LINEAR_TEAM in the skill template explains that writes refuse without it"

if [ "$fail" -ne 0 ]; then
  echo "settings-example-sync: FAIL"
  exit 1
fi
echo "pass: settings-example-sync"
