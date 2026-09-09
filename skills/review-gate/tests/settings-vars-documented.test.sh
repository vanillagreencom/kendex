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
count=0
bad() { printf 'test-failure=%s value=%q\n' "$1" "$2" >&2; fail=1; }

# Shared by the forbidden-assignment guard below and its failing-direction
# self-check, so the self-check exercises the real matcher, not a copy.
forbidden_assignment_matches() { # key, file
  grep -qE "^[[:space:]]*(\"?${1}\"?|'${1}')[[:space:]]*=" "$2"
}

vars="$(grep -rhoE 'REVIEW_GATE_[A-Z_]+' \
  "$SKILL_DIR/scripts" "$SKILL_DIR/templates" | sort -u)"
[ -n "$vars" ] || { bad variable-extractor empty; exit 1; }

for v in $vars; do
  count=$((count + 1))
  observed=""
  if ! grep -q "$v" "$SKILL_DIR/SKILL.md" "$SKILL_DIR/references/adoption.md" "$SKILL_DIR/references/settings.md"; then
    observed="undocumented"
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
        observed="$observed forbidden-assignment"
      fi
      ;;
    # A GitHub REPOSITORY VARIABLE, read by a workflow expression before any
    # checkout exists — so the settings file cannot supply it and an
    # assignment there would advertise a knob that resolves to nothing.
    # Documented with the check_run opt-in it belongs to.
    REVIEW_GATE_CHECK_RUN_NAME)
      if ! grep -q "$v" "$SKILL_DIR/references/adoption.md"; then
        observed="$observed adoption-missing"
      fi
      if forbidden_assignment_matches "$v" "$EXAMPLE"; then
        observed="$observed forbidden-assignment"
      fi
      ;;
    *)
      if ! grep -q "^$v = " "$EXAMPLE"; then
        observed="$observed example-missing"
      fi ;;
  esac
  [ -z "$observed" ] || bad variable-contract "$v:$observed"
done

# Reverse direction: every key the example documents must be real — either
# read by the scripts or an explicitly wiring-level key named in SKILL.md.
example_keys="$(sed -n 's/^\(REVIEW_GATE_[A-Z_]*\) = .*/\1/p' "$EXAMPLE")"
[ -n "$example_keys" ] || { bad example-extractor empty; exit 1; }
for key in $example_keys; do
  count=$((count + 1))
  if ! grep -qx "$key" <<<"$vars" && ! grep -q "$key" "$SKILL_DIR/SKILL.md" "$SKILL_DIR/references/settings.md"; then
    bad example-key "$key"
  fi
done

# Failing-direction self-check: the forbidden-assignment guard above only
# ever runs against examples where the keys are absent, so it would stay
# green even if the matcher stopped recognizing assignments. Prove each
# TOML spelling actually trips the matcher.
matcher_fixture="$(mktemp)" || { bad matcher-fixture mktemp; exit 1; }
trap 'rm -f -- "${matcher_fixture:?}"' EXIT
while IFS='|' read -r want spelling; do
  count=$((count + 1))
  printf '%s\n' "$spelling" >"$matcher_fixture"
  got=absent
  if forbidden_assignment_matches "REVIEW_GATE_SETTINGS_FILE" "$matcher_fixture"; then got=assigned; fi
  [ "$got" = "$want" ] || bad assignment-matcher "$spelling"
done <<'SPELLINGS'
assigned|REVIEW_GATE_SETTINGS_FILE = "x"
assigned|REVIEW_GATE_SETTINGS_FILE="x"
assigned|"REVIEW_GATE_SETTINGS_FILE" = "x"
assigned|'REVIEW_GATE_SETTINGS_FILE' = "x"
assigned|   REVIEW_GATE_SETTINGS_FILE = "x"
absent|# REVIEW_GATE_SETTINGS_FILE = "x"
absent|REVIEW_GATE_SETTINGS_FILE_EXTRA = "x"
absent|REVIEW_GATE_SETTINGS_FILE overrides the file path in tests
SPELLINGS

if [ "$fail" -ne 0 ]; then
  exit 1
fi
printf 'test-pass=settings-vars-documented value=%s\n' "$count"
