#!/usr/bin/env bash
# settings-example-sync.test.sh is the only review-gate suite whose entire
# body is cross-file comparison, so a run that made no comparison at all
# still exits 0. These are its controls: the suite is driven against planted
# fixtures and its verdict, its counts and its skip lines are asserted, so a
# green run can never be confused with an unmeasured one.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE="$TEST_DIR/settings-example-sync.test.sh"
SKILL_TEMPLATE="$TEST_DIR/../vstack.settings.toml.example"
ROOT_TEMPLATE="$TEST_DIR/../../../vstack.settings.toml.example"

fail=0
note() { echo "FAIL: $1"; fail=1; }
ok() { echo "  ok    $1"; }

for f in "$SUITE" "$SKILL_TEMPLATE" "$ROOT_TEMPLATE"; do
  [ -f "$f" ] || { echo "FAIL: fixture source missing: $f"; exit 1; }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# fixture NAME — a tree the suite resolves exactly as it resolves the real
# one: <root>/skills/review-gate/tests/<suite> beside the skill template,
# three levels under the root template. Echoes the tree's root.
fixture() {
  local fx="$work/$1"
  rm -rf "$fx"
  mkdir -p "$fx/skills/review-gate/tests"
  cp "$SUITE" "$fx/skills/review-gate/tests/"
  cp "$SKILL_TEMPLATE" "$fx/skills/review-gate/"
  cp "$ROOT_TEMPLATE" "$fx/"
  echo "$fx"
}

# run_fixture ROOT — the suite under ROOT; stdout+stderr to $ROOT.out, exit
# status echoed.
run_fixture() {
  local rc=0
  bash "$1/skills/review-gate/tests/settings-example-sync.test.sh" >"$1.out" 2>&1 || rc=$?
  echo "$rc"
}

expect_rc() {
  [ "$2" = "$3" ] || note "$1: expected exit $3, got $2"
}

expect_out() {
  grep -qF "$3" "$1.out" || {
    cat "$1.out"
    note "$(basename "$1"): expected output to contain '$3' ($2)"
  }
}

expect_no_out() {
  if grep -qF "$3" "$1.out"; then
    cat "$1.out"
    note "$(basename "$1"): output must NOT contain '$3' ($2)"
  fi
}

# --- control: in sync, everything present -> pass, with counts ------------
fx="$(fixture insync)"
rc="$(run_fixture "$fx")"
expect_rc insync "$rc" 0
expect_out "$fx" "the verdict" "pass: settings-example-sync"
expect_out "$fx" "every comparison ran" "56 passed, 0 failed, 0 skipped"
ok "in-sync templates pass, and the run reports the count it measured"

# --- must-fail control: root template ABSENT ------------------------------
# The defect this file exists for: the absent-root guard used to end the RUN
# with status 0, printing nothing, while all 17 key comparisons went
# unmade. An absent root is skippable downstream, so the verdict may stay
# green — but only as counted, printed skips, and only with the skill-side
# assertions still measured.
fx="$(fixture noroot)"
rm -f "$fx/vstack.settings.toml.example"
rc="$(run_fixture "$fx")"
expect_rc noroot "$rc" 0
expect_out "$fx" "skips are printed" "  skip  REVIEW_GATE_MODE cross-template comparison"
expect_out "$fx" "skips are counted, skill side still measured" "22 passed, 0 failed, 17 skipped"
expect_no_out "$fx" "an unmeasured run must never report a clean one" "0 skipped"
[ -s "$fx.out" ] || note "noroot: the suite produced no output at all"
ok "an absent root template is a counted, printed skip — never a silent green run"

# --- must-fail control: root present but DRIFTED --------------------------
fx="$(fixture drift)"
sed -i.bak 's/^REVIEW_GATE_MODE = "enforce"$/REVIEW_GATE_MODE = "warn"/' "$fx/vstack.settings.toml.example"
rm -f "$fx/vstack.settings.toml.example.bak"
rc="$(run_fixture "$fx")"
expect_rc drift "$rc" 1
expect_out "$fx" "the drift is named" "REVIEW_GATE_MODE default drift: skill='enforce' root='warn'"
expect_out "$fx" "the verdict" "settings-example-sync: FAIL"
ok "a drifted default in the root template fails the suite"

# --- must-fail control: root present but MISSING a key --------------------
fx="$(fixture missingkey)"
sed -i.bak '/^REVIEW_GATE_THREADS = /d' "$fx/vstack.settings.toml.example"
rm -f "$fx/vstack.settings.toml.example.bak"
rc="$(run_fixture "$fx")"
expect_rc missingkey "$rc" 1
expect_out "$fx" "the absent key is named" "REVIEW_GATE_THREADS present in root template"
ok "a key dropped from the root template fails the suite"

# --- must-fail control: drifted UNQUOTED values in both templates ---------
# Both sides parse to an empty default under a value reader that only reads
# the quoted form, so a presence check that accepts any assignment lets two
# different values agree.
fx="$(fixture unquoted)"
sed -i.bak 's/^REVIEW_GATE_MODE = "enforce"$/REVIEW_GATE_MODE = enforce/' "$fx/skills/review-gate/vstack.settings.toml.example"
sed -i.bak 's/^REVIEW_GATE_MODE = "enforce"$/REVIEW_GATE_MODE = warn/' "$fx/vstack.settings.toml.example"
rm -f "$fx/skills/review-gate/vstack.settings.toml.example.bak" "$fx/vstack.settings.toml.example.bak"
rc="$(run_fixture "$fx")"
expect_rc unquoted "$rc" 1
expect_out "$fx" "the unquoted skill-side assignment is named" "REVIEW_GATE_MODE present in skill template"
expect_out "$fx" "the unquoted root-side assignment is named" "REVIEW_GATE_MODE present in root template"
ok "two drifted UNQUOTED defaults fail rather than agreeing as empty"

# --- must-fail control: the SECURITY caveat check can fail ----------------
fx="$(fixture nocaveat)"
sed -i.bak 's/SECURITY/NOTE/g' "$fx/skills/review-gate/vstack.settings.toml.example"
rm -f "$fx/skills/review-gate/vstack.settings.toml.example.bak"
rc="$(run_fixture "$fx")"
expect_rc nocaveat "$rc" 1
expect_out "$fx" "the caveat-less key is named" "carries the SECURITY caveat in the skill template"
ok "a key that lost its SECURITY caveat fails the suite"

# --- must-fail control: the SKILL template absent is a hard failure -------
# It ships beside the suite, so its absence is a broken checkout rather than
# a downstream condition, and nothing below it is measurable.
fx="$(fixture noskill)"
rm -f "$fx/skills/review-gate/vstack.settings.toml.example"
rc="$(run_fixture "$fx")"
expect_rc noskill "$rc" 1
expect_out "$fx" "the missing template is named" "review-gate skill template missing"
ok "an absent skill template fails loud"

if [ "$fail" -ne 0 ]; then
  echo "settings-example-sync-controls: FAIL"
  exit 1
fi
echo "pass: settings-example-sync-controls"
