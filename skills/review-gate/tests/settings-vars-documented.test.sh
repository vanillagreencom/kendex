#!/usr/bin/env bash
# Doc-contract lint: every REVIEW_GATE_* variable the engine's scripts or
# templates reference must be documented — in SKILL.md (or
# references/adoption.md) for readers, and in the skill's
# kendex.settings.toml.example for installers. A knob that exists only in
# code is a knob nobody can find.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
EXAMPLE="$SKILL_DIR/kendex.settings.toml.example"

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
  # LIST-endpoint status snapshot in from a converge-style caller). The absence is the contract: an
  # assignment in the example would advertise a per-invocation seam as a
  # repo setting, so it must FAIL here.
  case "$v" in
    REVIEW_GATE_SETTINGS_FILE|REVIEW_GATE_STATUS_SNAPSHOT_FILE)
      # Whitespace/quote-tolerant: any TOML spelling of an assignment for
      # this name must fail, not just the canonical `KEY = ` shape.
      if forbidden_assignment_matches "$v" "$EXAMPLE"; then
        echo "FAIL: $v is an env-only per-invocation seam but is assigned in $EXAMPLE"
        fail=1
      fi
      continue ;;
    # A GitHub REPOSITORY VARIABLE, read by a workflow expression before any
    # checkout exists — so the settings file cannot supply it and an
    # assignment there would advertise a knob that resolves to nothing.
    # Documented with the check_run opt-in it belongs to.
    REVIEW_GATE_CHECK_RUN_NAME)
      if ! grep -q "$v" "$SKILL_DIR/references/adoption.md"; then
        echo "FAIL: $v (repository variable) must stay documented in references/adoption.md"
        fail=1
      fi
      if forbidden_assignment_matches "$v" "$EXAMPLE"; then
        echo "FAIL: $v is a repository variable, not a settings key, but is assigned in $EXAMPLE"
        fail=1
      fi
      continue ;;
  esac
  if ! grep -q "^$v = " "$EXAMPLE"; then
    echo "FAIL: $v missing from the skill's kendex.settings.toml.example"
    fail=1
  fi
done

# Reverse direction: every key the example documents must be real — either
# read by the scripts or an explicitly wiring-level key named in SKILL.md.
for key in $(sed -n 's/^\(REVIEW_GATE_[A-Z_]*\) = .*/\1/p' "$EXAMPLE"); do
  if ! printf '%s\n' "$vars" | grep -qx "$key" && ! grep -q "$key" "$SKILL_DIR/SKILL.md" "$SKILL_DIR/references/settings.md"; then
    echo "FAIL: $key is documented in the example but neither read by scripts nor described in SKILL.md/references/settings.md"
    fail=1
  fi
done

# Failing-direction self-check: the forbidden-assignment guard above only
# ever runs against examples where the keys are absent, so it would stay
# green even if the matcher stopped recognizing assignments. Prove each
# TOML spelling actually trips the matcher (kendex#1086).
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

# And the reverse direction: spellings that are NOT assignments of the key
# must NOT match — an over-broad matcher would flag innocent example text
# (kendex#1092).
while IFS= read -r spelling; do
  printf '%s\n' "$spelling" >"$matcher_fixture"
  if forbidden_assignment_matches "REVIEW_GATE_SETTINGS_FILE" "$matcher_fixture"; then
    echo "FAIL: forbidden-assignment matcher falsely matched: $spelling"
    fail=1
  fi
done <<'NON_MATCHING'
# REVIEW_GATE_SETTINGS_FILE = "x"
REVIEW_GATE_SETTINGS_FILE_EXTRA = "x"
REVIEW_GATE_SETTINGS_FILE overrides the file path in tests
NON_MATCHING
rm -f "$matcher_fixture"

if [ "$fail" -ne 0 ]; then
  echo "settings-vars-documented: FAIL"
  exit 1
fi
echo "pass: settings-vars-documented"
