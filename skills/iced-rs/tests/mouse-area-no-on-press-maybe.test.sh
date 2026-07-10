#!/usr/bin/env bash
# vstack#478: MouseArea (Iced 0.14) has NO `on_press_maybe` method — only `button`
# does. The skill previously recommended `mouse_area(x).on_press_maybe(...)`, which
# does not compile. This guard fails if that misuse is ever reintroduced into the
# guidance sources (SKILL.md + references/), so a future reference refresh cannot
# silently restore the bug.
#
# Run: bash skills/iced-rs/tests/mouse-area-no-on-press-maybe.test.sh
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"

PASS=0
FAIL=0

pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

# Guidance sources to police (SKILL.md + reference docs). Bundled upstream
# `examples/` are real iced code and use the valid button.on_press_maybe, so they
# are intentionally out of scope.
SOURCES=("$SKILL_DIR/SKILL.md" "$SKILL_DIR/references")

# 1. No `mouse_area(...).on_press_maybe(...)` construct anywhere in the guidance.
#    Matches a `mouse_area` occurrence followed on the same line by `.on_press_maybe`.
if grep -rnE 'mouse_area.*\.on_press_maybe' "${SOURCES[@]}" >/dev/null 2>&1; then
    fail "found forbidden mouse_area(...).on_press_maybe(...) construct:"
    grep -rnE 'mouse_area.*\.on_press_maybe' "${SOURCES[@]}" >&2 || true
else
    pass "no mouse_area(...).on_press_maybe(...) construct in guidance sources"
fi

# 2. The correct conditional pattern (gate the on_press call, keep wrapper) is present.
if grep -rqE 'area = area\.on_press\(' "$SKILL_DIR/SKILL.md" "$SKILL_DIR/references/widgets.md"; then
    pass "corrected conditional mouse_area on_press pattern present"
else
    fail "corrected conditional mouse_area on_press pattern missing from SKILL.md / widgets.md"
fi

# 3. The VALID button on_press_maybe guidance must stay intact (do not over-correct).
if grep -qE 'on_press_maybe\(self, on_press: Option<Message>\)' "$SKILL_DIR/references/widget-button.md"; then
    pass "button on_press_maybe(Option<Message>) API guidance intact"
else
    fail "button on_press_maybe API guidance was removed from widget-button.md"
fi

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then exit 1; fi
