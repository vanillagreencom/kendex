#!/usr/bin/env bash
# Pins how tools/vacuous-suite-scan classifies a suite, over fixture skills
# small enough to scan in a second.
#
# The scan's whole method is to blank a skill's product files and re-run each
# suite, so what it can conclude from a blanked PASS depends on which direction
# the suite asserts in. A presence assertion that still passes is asserting
# nothing. An absence assertion that still passes is passing because the method
# removed what it looks for. Those are opposite facts and the tool must not
# report them as one, so every case below is paired: the same suite body with
# and without its declaration, and each declaration checked against a run that
# disproves it.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$(cd "$TEST_DIR/.." && pwd)/vacuous-suite-scan"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT

PASS=0
FAIL=0
ok() {
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "$1"
}
bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"
}

OUT=""
RC=0
# Errexit is on, so a refusal is captured through an `if` rather than ending
# the suite that asked for it.
scan() { # scan SKILL_DIR [FLAG...]
  if OUT="$("$SCAN" "$@" 2>&1)"; then RC=0; else RC=$?; fi
}

has() { # has DESCRIPTION NEEDLE
  case "$OUT" in
  *"$2"*) ok "$1" ;;
  *) bad "$1" "not in output: $2"$'\n        '"$OUT" ;;
  esac
}

lacks() { # lacks DESCRIPTION NEEDLE
  case "$OUT" in
  *"$2"*) bad "$1" "found in output: $2"$'\n        '"$OUT" ;;
  *) ok "$1" ;;
  esac
}

# A fixture skill: one product script holding a marker, plus whichever suites
# the case names. The product is CLEAN of the forbidden token, which is what
# lets an absence assertion pass its pristine run.
new_skill() { # new_skill NAME -> path on stdout
  local d="$TMP/$1/probe"
  mkdir -p "$d/scripts" "$d/tests"
  printf '#!/usr/bin/env bash\necho SHIPPED-MARKER\n' >"$d/scripts/thing.sh"
  printf '%s' "$d"
}

# Passes pristine, fails blanked: the marker is gone once the product is
# emptied. This is what "detecting" means, and every fixture skill carries one
# so the scan has a measurement to report.
add_detecting() { # add_detecting SKILL_DIR
  cat >"$1/tests/detecting.test.sh" <<'SUITE'
#!/usr/bin/env bash
set -euo pipefail
grep -q SHIPPED-MARKER "$(dirname "${BASH_SOURCE[0]}")/../scripts/thing.sh"
SUITE
}

# Passes pristine AND blanked: it fails only when a forbidden token appears,
# and an emptied product has none. DECL is written above the body, so the same
# assertion can be run declared and undeclared.
add_absence() { # add_absence SKILL_DIR NAME [DECL_LINE]
  {
    printf '#!/usr/bin/env bash\n'
    [ "$#" -ge 3 ] && printf '%s\n' "$3"
    cat <<'SUITE'
set -euo pipefail
if grep -q FORBIDDEN "$(dirname "${BASH_SOURCE[0]}")/../scripts/thing.sh"; then
  echo "forbidden token in a shipped script" >&2
  exit 1
fi
SUITE
  } >"$1/tests/$2.test.sh"
}

echo "=== a declared absence assertion is its own category, not vacuous ==="
S="$(new_skill declared)"
add_detecting "$S"
add_absence "$S" absence '# vacuous-suite-scan: absence-subject'
scan "$S" --list
if [ "$RC" -eq 0 ]; then
  ok "the scan passes over a declared absence assertion"
else
  bad "the scan passes over a declared absence assertion" "rc=$RC out=$OUT"
fi
has "it is listed under absence-subject" "absence-subject  absence.test.sh"
lacks "it is not listed as vacuous" "vacuous          absence.test.sh"
has "the count line carries an absence-subject column" "1 absence-subject"
has "nothing was counted vacuous" "0 vacuous"

echo "=== the control: the same assertion undeclared is still called vacuous ==="
S="$(new_skill undeclared)"
add_detecting "$S"
add_absence "$S" absence
scan "$S" --list
has "an undeclared absence assertion is reported vacuous" "vacuous          absence.test.sh"
has "the vacuous count sees it" "1 vacuous"
lacks "and it is not credited to the new category" "absence-subject  absence.test.sh"

echo "=== a declaration the blanked run disproves is a contradiction ==="
# Declares absence-subject, but asserts the product is NON-empty: blanking it
# makes the suite fail, which an absence assertion cannot do.
S="$(new_skill contradiction)"
add_detecting "$S"
cat >"$S/tests/liar.test.sh" <<'SUITE'
#!/usr/bin/env bash
# vacuous-suite-scan: absence-subject
set -euo pipefail
grep -q SHIPPED-MARKER "$(dirname "${BASH_SOURCE[0]}")/../scripts/thing.sh"
SUITE
scan "$S"
if [ "$RC" -ne 0 ]; then
  ok "the scan refuses a run holding a contradiction"
else
  bad "the scan refuses a run holding a contradiction" "rc=0 out=$OUT"
fi
has "the contradicting suite is named" "CONTRADICTION liar.test.sh"
has "the reason is the absence one, not the harness one" \
  "declares absence-subject but failed against a blanked product"
has "and it names the found-it reading" \
  "it found what it forbids in a product holding nothing"

echo "=== the absence reason names the refusal reading as well ==="
# The other way a declared absence lint fails blanked: it did not find the
# forbidden thing, it REFUSED TO RUN, because a fail-closed anchor saw the
# emptied product. From outside the suite the two are one exit status, so the
# reason names both rather than asserting the one it cannot check.
S="$(new_skill refusedscan)"
add_detecting "$S"
cat >"$S/tests/refused.test.sh" <<'SUITE'
#!/usr/bin/env bash
# vacuous-suite-scan: absence-subject
set -euo pipefail
p="$(dirname "${BASH_SOURCE[0]}")/../scripts/thing.sh"
if ! grep -q SHIPPED-MARKER "$p"; then
  echo "the product is empty; this lint read nothing" >&2
  exit 1
fi
if grep -q FORBIDDEN "$p"; then
  echo "forbidden token in a shipped script" >&2
  exit 1
fi
SUITE
scan "$S"
if [ "$RC" -ne 0 ]; then
  ok "a declared absence suite that refuses the blanked run is reported"
else
  bad "a declared absence suite that refuses the blanked run is reported" "rc=0 out=$OUT"
fi
has "and the reason names the refusal reading" \
  "a fail-closed check refused to run over the emptied product"

echo "=== harness-subject keeps its own reason ==="
S="$(new_skill harnesslie)"
add_detecting "$S"
cat >"$S/tests/harnesslie.test.sh" <<'SUITE'
#!/usr/bin/env bash
# vacuous-suite-scan: harness-subject
set -euo pipefail
grep -q SHIPPED-MARKER "$(dirname "${BASH_SOURCE[0]}")/../scripts/thing.sh"
SUITE
scan "$S"
if [ "$RC" -ne 0 ]; then
  ok "a disproved harness-subject claim still fails the run"
else
  bad "a disproved harness-subject claim still fails the run" "rc=0 out=$OUT"
fi
has "with the reason that fits harness-subject" \
  "declares harness-subject but breaking product code reached it"

echo "=== a skill of nothing but absence assertions measured nothing ==="
# The side of the count the new category falls on, asserted rather than
# described: were absence counted as a measurement, this run would exit 0
# having settled no suite's vacuity at all.
S="$(new_skill absenceonly)"
add_absence "$S" absence '# vacuous-suite-scan: absence-subject'
scan "$S"
if [ "$RC" -ne 0 ]; then
  ok "a skill of only absence assertions is not a passing scan"
else
  bad "a skill of only absence assertions is not a passing scan" "rc=0 out=$OUT"
fi
has "and it says nothing was measured" "no suite was measured"
# The needle is text only the refusal carries. `absence-subject` on its own
# proves nothing: the tally line above the refusal prints it as a column
# label, so that needle matched whatever the refusal happened to say.
has "naming absence-subject among the reasons" \
  "all harness-subject or absence-subject"

echo "=== a malformed declaration ends the run ==="
S="$(new_skill twosubjects)"
add_detecting "$S"
cat >"$S/tests/two.test.sh" <<'SUITE'
#!/usr/bin/env bash
# vacuous-suite-scan: harness-subject
# vacuous-suite-scan: absence-subject
set -euo pipefail
SUITE
scan "$S"
if [ "$RC" -ne 0 ]; then
  ok "two declared subjects are refused"
else
  bad "two declared subjects are refused" "rc=0 out=$OUT"
fi
has "and the refusal names both" "declares 2 vacuous-suite-scan subjects"

S="$(new_skill unknownsubject)"
add_detecting "$S"
cat >"$S/tests/typo.test.sh" <<'SUITE'
#!/usr/bin/env bash
# vacuous-suite-scan: absense-subject
set -euo pipefail
SUITE
scan "$S"
if [ "$RC" -ne 0 ]; then
  ok "a misspelled subject is refused rather than ignored"
else
  bad "a misspelled subject is refused rather than ignored" "rc=0 out=$OUT"
fi
has "and the refusal shows the canonical declarations" \
  "a declaration is exactly '# vacuous-suite-scan: harness-subject'"

echo "=== a declaration is read by its prefix, so a malformed payload is refused ==="
# Each line below is one a reader would call a declaration, carrying a payload
# outside the accepted shape. The failure being pinned is what used to happen
# to them: the payload was matched as part of the detection, so a line that
# missed the shape read as no declaration at all and its suite fell through to
# vacuous with no refusal — the reverse of what the refusal is for.
refuses_payload() { # refuses_payload NAME DECL_LINE PAYLOAD
  local S
  S="$(new_skill "malformed-$1")"
  add_detecting "$S"
  add_absence "$S" bad "$2"
  scan "$S"
  if [ "$RC" -ne 0 ]; then
    ok "the $1 payload is refused"
  else
    bad "the $1 payload is refused" "rc=0 out=$OUT"
  fi
  has "and the refusal prints the $1 payload" \
    "declares an unknown vacuous-suite-scan subject: '$3'"
}

refuses_payload underscored '# vacuous-suite-scan: absence_subject' ' absence_subject'
refuses_payload capitalized '# vacuous-suite-scan: Absence-subject' ' Absence-subject'
refuses_payload trailing-space '# vacuous-suite-scan: absence-subject ' ' absence-subject '
refuses_payload empty '# vacuous-suite-scan:' ''

echo "=== a well-formed declaration does not shield a malformed one ==="
# The doubled-declaration refusal counts declarations, so it has to count the
# malformed line too: a header whose second line is unreadable is still a
# header claiming two subjects, not a header claiming the first one.
S="$(new_skill goodplusbad)"
add_detecting "$S"
cat >"$S/tests/pair.test.sh" <<'SUITE'
#!/usr/bin/env bash
# vacuous-suite-scan: harness-subject
# vacuous-suite-scan: absence_subject
set -euo pipefail
SUITE
scan "$S"
if [ "$RC" -ne 0 ]; then
  ok "one good and one malformed declaration are refused together"
else
  bad "one good and one malformed declaration are refused together" "rc=0 out=$OUT"
fi
has "and the count sees both lines" "declares 2 vacuous-suite-scan subjects"

echo "=== a malformed declaration is read even on a suite that cannot run ==="
# A header defect is settled by reading the header, so it must not depend on
# the suite surviving the pristine run. The cases above all put the bad header
# on a suite that runs; this one puts it on a suite that fails in the copy and
# is set aside as unrunnable before any comparison.
S="$(new_skill unrunnabletypo)"
add_detecting "$S"
cat >"$S/tests/brokentypo.test.sh" <<'SUITE'
#!/usr/bin/env bash
# vacuous-suite-scan: absense-subject
set -euo pipefail
echo "this suite cannot run from a copy" >&2
exit 1
SUITE
scan "$S"
if [ "$RC" -ne 0 ]; then
  ok "the typo is refused though its suite never reached the comparison"
else
  bad "the typo is refused though its suite never reached the comparison" "rc=0 out=$OUT"
fi
has "and the refusal names the unknown subject" \
  "declares an unknown vacuous-suite-scan subject: ' absense-subject'"
# The refusal comes before staging, so no tally line was printed for the skill.
lacks "and nothing was classified first" "unrunnable-in-copy"

echo "=== a declaration below the header window is not read ==="
# suite_subject reads the first 20 lines. A declaration written past that is
# not a category the scan honours, and the suite falls back to vacuous.
S="$(new_skill deepdecl)"
add_detecting "$S"
{
  printf '#!/usr/bin/env bash\n'
  # Lines 2 through 20, putting the declaration on line 21 — one past the
  # window, which is the edge the bound is worth pinning at.
  i=0
  while [ "$i" -lt 19 ]; do
    printf '# padding\n'
    i=$((i + 1))
  done
  printf '# vacuous-suite-scan: absence-subject\n'
  cat <<'SUITE'
set -euo pipefail
if grep -q FORBIDDEN "$(dirname "${BASH_SOURCE[0]}")/../scripts/thing.sh"; then
  echo "forbidden token in a shipped script" >&2
  exit 1
fi
SUITE
} >"$S/tests/deep.test.sh"
if [ "$(sed -n '21p' "$S/tests/deep.test.sh")" != "# vacuous-suite-scan: absence-subject" ]; then
  bad "the fixture puts its declaration on line 21" "$(sed -n '18,23p' "$S/tests/deep.test.sh")"
else
  ok "the fixture puts its declaration on line 21"
fi
scan "$S" --list
has "a declaration past line 20 is not read" "vacuous          deep.test.sh"
lacks "and it is not credited to absence-subject" "absence-subject  deep.test.sh"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
