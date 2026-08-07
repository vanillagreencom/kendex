#!/usr/bin/env bash
# Doc-contract lint: every REVIEW_GATE_* variable the engine's scripts or
# templates reference must be documented — in SKILL.md (or
# references/adoption.md) for readers, and in the skill's
# vstack.settings.toml.example for installers. A knob that exists only in
# code is a knob nobody can find.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"

fail=0

# Shared by the forbidden-assignment guard below and its failing-direction
# self-check, so the self-check exercises the real matcher, not a copy.
forbidden_assignment_matches() { # key, file
  grep -qE "^[[:space:]]*(\"?${1}\"?|'${1}')[[:space:]]*=" "$2"
}

vars="$(grep -rhoE 'REVIEW_GATE_[A-Z_]+' \
  "$SKILL_DIR/scripts" "$SKILL_DIR/templates" | sort -u)"
[ -n "$vars" ] || { echo "FAIL: no REVIEW_GATE_* variables found in scripts/"; exit 1; }

for v in $vars; do
  if ! grep -q "$v" "$SKILL_DIR/SKILL.md" "$SKILL_DIR/references/adoption.md" "$SKILL_DIR/references/settings.md"; then
    echo "FAIL: $v is read by the engine but documented in none of SKILL.md, references/adoption.md, references/settings.md"
    fail=1
  fi
  # Env-only per-invocation seams, not settings keys — they must not appear
  # as settings assignments (REVIEW_GATE_SETTINGS_FILE overrides the file
  # path in tests; REVIEW_GATE_STATUS_SNAPSHOT_FILE hands one head's
  # combined-status snapshot in from a converge-style caller). The absence
  # is the contract: an assignment in either example would advertise a
  # per-invocation seam as a repo setting, so it must FAIL here.
  case "$v" in
    REVIEW_GATE_SETTINGS_FILE|REVIEW_GATE_STATUS_SNAPSHOT_FILE)
      for example in "$SKILL_DIR/vstack.settings.toml.example" \
                     "$SKILL_DIR/../../vstack.settings.toml.example"; do
        [ -f "$example" ] || continue
        # Whitespace/quote-tolerant: any TOML spelling of an assignment for
        # this name must fail, not just the canonical `KEY = ` shape.
        if forbidden_assignment_matches "$v" "$example"; then
          echo "FAIL: $v is an env-only per-invocation seam but is assigned in $example"
          fail=1
        fi
      done
      continue ;;
  esac
  if ! grep -q "^$v = " "$SKILL_DIR/vstack.settings.toml.example"; then
    echo "FAIL: $v missing from the skill's vstack.settings.toml.example"
    fail=1
  fi
done

# Reverse direction: every key the example documents must be real — either
# read by the scripts or an explicitly wiring-level key named in SKILL.md.
for key in $(sed -n 's/^\(REVIEW_GATE_[A-Z_]*\) = .*/\1/p' "$SKILL_DIR/vstack.settings.toml.example"); do
  if ! printf '%s\n' "$vars" | grep -qx "$key" && ! grep -q "$key" "$SKILL_DIR/SKILL.md" "$SKILL_DIR/references/settings.md"; then
    echo "FAIL: $key is documented in the example but neither read by scripts nor described in SKILL.md/references/settings.md"
    fail=1
  fi
done

# Failing-direction self-check: the forbidden-assignment guard above only
# ever runs against examples where the keys are absent, so it would stay
# green even if the matcher stopped recognizing assignments. Prove each
# TOML spelling actually trips the matcher (vstack#1086).
matcher_fixture="$(mktemp)"
while IFS= read -r spelling; do
  printf '%s\n' "$spelling" >"$matcher_fixture"
  if ! forbidden_assignment_matches "REVIEW_GATE_SETTINGS_FILE" "$matcher_fixture"; then
    echo "FAIL: forbidden-assignment matcher misses spelling: $spelling"
    fail=1
  fi
done <<'SPELLINGS'
REVIEW_GATE_SETTINGS_FILE = "x"
REVIEW_GATE_SETTINGS_FILE="x"
"REVIEW_GATE_SETTINGS_FILE" = "x"
'REVIEW_GATE_SETTINGS_FILE' = "x"
   REVIEW_GATE_SETTINGS_FILE = "x"
SPELLINGS
rm -f "$matcher_fixture"

if [ "$fail" -ne 0 ]; then
  echo "settings-vars-documented: FAIL"
  exit 1
fi
echo "pass: settings-vars-documented"
