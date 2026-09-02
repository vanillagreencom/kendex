#!/usr/bin/env bash
# Pins for the policy the package ships and the machinery the units need:
# the `k` byte suffix on a class and the `b` suffix on a row, the stale-row
# re-measure, the default class list and the overrides a repo layers over it,
# the CHANGELOG exclusion, --staged lowering a shrunk row itself, and the
# frozen classes that refuse a raise whatever RATCHET_RAISE says.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
SR="$SKILL_DIR/scripts/size-ratchet"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sr-shipped.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

unset SIZE_RATCHET_THRESHOLD SIZE_RATCHET_CLASSES SIZE_RATCHET_DEFAULT_CLASSES SIZE_RATCHET_FROZEN_CLASSES SIZE_RATCHET_BASELINE SIZE_RATCHET_EXCLUDES SIZE_RATCHET_SETTINGS_FILE RATCHET_RAISE 2>/dev/null || true
# This suite is the one that runs the SHIPPED lists, so it sets nothing it is
# testing: a case that needs a different mapping passes it per run.

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

BASE="tools/size-ratchet-baseline.tsv"
TAB="$(printf '\t')"

new_repo() { # NAME
  R="$TMP/$1"
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}

mklines() { # PATH LINES
  mkdir -p "$R/$(dirname "$1")"
  awk -v n="$2" 'BEGIN { for (i = 1; i <= n; i++) print "line " i }' >"$R/$1"
}

mkbytes() { # PATH BYTES — exactly BYTES bytes, and zero newlines, so a case
            # that confuses the units is visible rather than coincidental
  mkdir -p "$R/$(dirname "$1")"
  head -c "$2" /dev/zero | tr '\0' 'x' >"$R/$1"
}

run() { # [VAR=val ...] [-- script-args ...] — run $SR in $R; sets OUT, RC
  local envs=() args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --)
        shift
        args=("$@")
        break
        ;;
      *) envs+=("$1") ;;
    esac
    shift
  done
  OUT=""
  RC=0
  OUT="$(cd "$R" && env ${envs[@]+"${envs[@]}"} "$SR" ${args[@]+"${args[@]}"} 2>&1)" || RC=$?
}

has() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

echo "=== a class threshold carries its unit: bare is lines, 'k' is kibibytes ==="
new_repo units
mkbytes wide.txt 2000
git -C "$R" add -A
run SIZE_RATCHET_DEFAULT_CLASSES= 'SIZE_RATCHET_CLASSES=*.txt=1k'
[ "$RC" -eq 1 ] && has "wide.txt — 2000 bytes > threshold 1024" \
  && ok "a 'k' threshold counts bytes and says so, at 1024 to the k" \
  || bad "a k threshold counts bytes" "rc=$RC out=$OUT"
# The control that the unit really moved: the same file under a BARE 1000 is
# zero lines and passes, so nothing but the suffix decided the verdict.
run SIZE_RATCHET_DEFAULT_CLASSES= 'SIZE_RATCHET_CLASSES=*.txt=1000'
[ "$RC" -eq 0 ] && ok "control: the same file under a bare threshold is measured in lines and passes" \
  || bad "control: a bare threshold counts lines" "rc=$RC out=$OUT"
run SIZE_RATCHET_DEFAULT_CLASSES= 'SIZE_RATCHET_CLASSES=*.txt=1kk'
[ "$RC" -eq 2 ] && has "the 'k' byte suffix" \
  && ok "a threshold the parser cannot read is exit 2 naming the entry" \
  || bad "malformed unit suffix is a config error" "rc=$RC out=$OUT"

echo "=== a byte-class row carries a 'b', and a row in the wrong unit is re-measured ==="
new_repo rowunit
MD20K='SIZE_RATCHET_CLASSES=*.md=20k'
mkbytes doc.md 30000
mkdir -p "$R/tools"
printf 'doc.md\t30000b\n' >"$R/$BASE"
git -C "$R" add -A
git -C "$R" commit -q -m seed
run "$MD20K"
[ "$RC" -eq 0 ] && ok "a byte row suffixed 'b' freezes its file" \
  || bad "a suffixed byte row freezes its file" "rc=$RC out=$OUT"
# The same number without the suffix is a LINE count on a byte class: it is
# not compared, it is reported as one to re-measure.
printf 'doc.md\t30000\n' >"$R/$BASE"
git -C "$R" add -A
run "$MD20K"
[ "$RC" -eq 1 ] && has "baseline row in the wrong unit: doc.md — row 30000" && has "counts bytes" \
  && ok "an unsuffixed row on a byte class is reported as one to re-measure" \
  || bad "unsuffixed row on a byte class" "rc=$RC out=$OUT"
has "grew" && bad "the wrong-unit row is not read as growth" "$OUT" \
  || ok "and never as growth — the numbers are not comparable"
run "$MD20K" -- --update
[ "$RC" -eq 0 ] && [ "$(cat "$R/$BASE")" = "$(printf 'doc.md\t30000b')" ] \
  && ok "one --update rewrites the line row as a byte row and the check passes" \
  || bad "--update re-measures the stale row" "rc=$RC row=$(cat "$R/$BASE") out=$OUT"
has "grew" && bad "the re-measure reports no growth" "$OUT" || ok "and reports no growth doing it"
# The reverse direction is the same rule: a 'b' row on a line class.
new_repo rowunit-rev
mklines big.txt 500
mkdir -p "$R/tools"
printf 'big.txt\t500b\n' >"$R/$BASE"
git -C "$R" add -A
run SIZE_RATCHET_THRESHOLD=400 SIZE_RATCHET_DEFAULT_CLASSES=
[ "$RC" -eq 1 ] && has "wrong unit: big.txt — row 500b" && has "counts lines" \
  && ok "a 'b' row on a line class is reported the same way" \
  || bad "b row on a line class" "rc=$RC out=$OUT"

echo "=== the shipped class list judges each kind of file by its own number ==="
new_repo shipped
mkbytes AGENTS.md 30000
mkbytes pkg/CLAUDE.md 30000
mkbytes skills/x/SKILL.md 30000
mkbytes skills/x/workflows/do.md 45000
mkbytes docs/reference.md 70000
mklines src/big.rs 500
mklines src/tests/big.rs 500
mkbytes docs/small.md 50000
mkbytes CLAUDE.md 20000
git -C "$R" add -A
run
[ "$RC" -eq 1 ] || bad "the shipped list fails the over-sized files" "rc=$RC out=$OUT"
for pair in \
  "AGENTS.md — 30000 bytes > threshold 24576 (class AGENTS.md)" \
  "pkg/CLAUDE.md — 30000 bytes > threshold 24576 (class */CLAUDE.md)" \
  "skills/x/SKILL.md — 30000 bytes > threshold 24576 (class */SKILL.md)" \
  "skills/x/workflows/do.md — 45000 bytes > threshold 40960 (class */workflows/*.md)" \
  "docs/reference.md — 70000 bytes > threshold 65536 (class *.md)" \
  "src/big.rs — 500 lines > threshold 400 (default)"; do
  has "$pair" && ok "shipped class: ${pair%% —*} is judged at its own threshold" \
    || bad "shipped class for ${pair%% —*}" "out=$OUT"
done
# Nothing under its class is mentioned — the report names offenders only.
# The `offender: ` prefix keeps each name exact: a bare `CLAUDE.md` would
# match the `pkg/CLAUDE.md` line that IS an offender and pass vacuously.
for quiet in src/tests/big.rs docs/small.md CLAUDE.md; do
  has "offender: $quiet" && bad "$quiet is under its class and must not be reported" "$OUT" \
    || ok "$quiet is under its shipped class and is not mentioned"
done

echo "=== markdown entries come first, so a doc under tests/ is judged as a doc ==="
# The shipped list's ORDER is behavioural, not cosmetic: first match wins, so
# the same file is a document at its byte class or a test at 800 lines
# depending on which entry the resolver reaches first.
new_repo md-under-tests
mklines pkg/tests/notes.md 900
git -C "$R" add -A
run
[ "$RC" -eq 0 ] && ok "a 900-line markdown file under tests/ passes — its byte class judged it" \
  || bad "a doc under tests/ is judged as a doc" "rc=$RC out=$OUT"
# The control: the same file under the inverted list IS an offender at 800
# lines, so the shipped order is what spared it.
run 'SIZE_RATCHET_DEFAULT_CLASSES=*/tests/*=800;*/test/*=800;*.md=64k'
[ "$RC" -eq 1 ] && has "pkg/tests/notes.md — 900 lines > threshold 800" \
  && ok "control: with the test entries first the same file fails at 800 lines" \
  || bad "control: the inverted order fails the same file" "rc=$RC out=$OUT"

echo "=== a root-level test directory is judged and frozen like any other ==="
# `*/tests/*` needs its literal slash, so the shipped list carries the root
# form beside it. Without that, the standard home of Rust integration tests
# would take neither the 800-line class nor the freeze, and both statements
# the list makes about tests would be false for it.
new_repo root-tests
mklines tests/root.rs 500
mklines test/legacy.rs 500
mklines __tests__/spec.rs 500
mklines tests.rs 500
git -C "$R" add -A
run
[ "$RC" -eq 0 ] \
  && ok "root-level tests/, test/, __tests__/ and tests.rs all sit under their 800 class" \
  || bad "a root-level test path takes the test class" "rc=$RC out=$OUT"
# The control: the same four files under a list carrying only the `*/` forms
# are offenders at the 400 default, so the root patterns are what spared them.
run 'SIZE_RATCHET_DEFAULT_CLASSES=*.md=64k;*/tests/*=800;*/test/*=800;*/__tests__/*=800;*/tests.rs=800'
[ "$RC" -eq 1 ] && has "tests/root.rs — 500 lines > threshold 400 (default)" \
  && has "tests.rs — 500 lines > threshold 400 (default)" \
  && ok "control: with only the '*/' forms the same files are offenders at 400" \
  || bad "control: the '*/' forms alone miss a root-level test path" "rc=$RC out=$OUT"
# And frozen: a root-level test row refuses a raise, declared or not.
new_repo root-tests-frozen
mklines tests/root.rs 900
mkdir -p "$R/tools"
printf 'tests/root.rs\t900\n' >"$R/$BASE"
git -C "$R" add -A
git -C "$R" commit -q -m seed
mklines tests/root.rs 1000
printf 'tests/root.rs\t1000\n' >"$R/$BASE"
git -C "$R" add -A
run RATCHET_RAISE=1
[ "$RC" -eq 1 ] && has "frozen baseline row raised: tests/root.rs — row 900 -> 1000 lines" \
  && ok "a root-level test row refuses the raise the declaration carries elsewhere" \
  || bad "a root-level test row is frozen" "rc=$RC out=$OUT"
# The control that the FROZEN list is what refused it.
run RATCHET_RAISE=1 SIZE_RATCHET_FROZEN_CLASSES=
[ "$RC" -eq 0 ] && ok "control: with the frozen list emptied the same declared raise passes" \
  || bad "control: an empty frozen list allows the declared raise" "rc=$RC out=$OUT"

echo "=== a row's unit suffix is exactly one trailing b, or the row is malformed ==="
# Every consumer of a row strips ONE trailing b, so a row the validator lets
# through with two would be read as the bare number by all of them.
new_repo row-suffix
mklines big.rs 500
mkdir -p "$R/tools"
git -C "$R" add -A
for row in "big.rs${TAB}500bb" "big.rs${TAB}b500" "big.rs${TAB}500b7"; do
  printf '%s\n' "$row" >"$R/$BASE"
  git -C "$R" add -A
  run
  [ "$RC" -eq 2 ] && has "malformed row(s) above" && has "$row" \
    && ok "the row '$row' is exit 2, quoted back" \
    || bad "a malformed suffix is a config error" "row=$row rc=$RC out=$OUT"
done
# The control: the single-suffix form those mutate is accepted.
printf 'big.rs\t500\n' >"$R/$BASE"
git -C "$R" add -A
run
[ "$RC" -eq 0 ] && ok "control: the well-formed row those cases mutate really passes" \
  || bad "well-formed row control" "rc=$RC out=$OUT"

echo "=== a repo overrides a class, never the list ==="
new_repo override
mkbytes skills/x/SKILL.md 10000
mkbytes AGENTS.md 30000
git -C "$R" add -A
run 'SIZE_RATCHET_CLASSES=*/SKILL.md=8k'
[ "$RC" -eq 1 ] && has "skills/x/SKILL.md — 10000 bytes > threshold 8192 (class */SKILL.md)" \
  && ok "the repo's own entry decides the class it names" \
  || bad "a repo entry overrides its class" "rc=$RC out=$OUT"
has "AGENTS.md — 30000 bytes > threshold 24576" \
  && ok "and the rest of the shipped list still decides everything else" \
  || bad "the shipped list survives an override" "out=$OUT"
# The control: the same SKILL.md passes under the shipped 24k, so the override
# is what failed it.
run
has "skills/x/SKILL.md" && bad "control: SKILL.md passes under the shipped class" "$OUT" \
  || ok "control: without the override the 10000-byte SKILL.md is under 24k and passes"

echo "=== a repo class scoped to a directory does not shadow a frozen class ==="
# `*` crosses `/`, so `ui/*.ts` reaches the test files under ui/ too, and an
# entry written for components would retitle the class the package ships for
# them. The rule these arms pin: README.md "Path classes".
new_repo shadow
mklines ui/src/App.ts 300
mklines ui/src/App.test.ts 500
mklines docs/guide.md 300
git -C "$R" add -A
run 'SIZE_RATCHET_CLASSES=ui/*.ts=250;ui/*.tsx=250'
if [ "$RC" -eq 1 ] \
  && has "ui/src/App.ts — 300 lines > threshold 250 (class ui/*.ts)" \
  && ! has "ui/src/App.test.ts" && ! has "docs/guide.md"; then
  ok "the repo class judges the component and hands the frozen test and doc back to the shipped list"
else
  bad "a directory-scoped repo class spares frozen paths" "rc=$RC out=$OUT"
fi
# The control: the freeze is what routes those two paths. Drop it and the same
# repo class takes them at 250 — which is the defect this section pins.
run 'SIZE_RATCHET_CLASSES=ui/*.ts=250;ui/*.tsx=250' SIZE_RATCHET_FROZEN_CLASSES=
if [ "$RC" -eq 1 ] && has "ui/src/App.test.ts — 500 lines > threshold 250 (class ui/*.ts)"; then
  ok "control: with nothing frozen the same class does take the test file at 250"
else
  bad "control: the freeze is what routes the shadowed path" "rc=$RC out=$OUT"
fi
# Markdown carries the unit too: the shadow would have judged 300 lines where
# the shipped class judges bytes.
run 'SIZE_RATCHET_CLASSES=docs/*=250'
[ "$RC" -eq 0 ] && ok "a doc under a directory-scoped class keeps its shipped byte ceiling" \
  || bad "markdown keeps its class under a directory-scoped repo entry" "rc=$RC out=$OUT"
run 'SIZE_RATCHET_CLASSES=docs/*=250' SIZE_RATCHET_FROZEN_CLASSES=
if [ "$RC" -eq 1 ] && has "docs/guide.md — 300 lines > threshold 250 (class docs/*)"; then
  ok "control: unfrozen, that same entry judges the doc in lines at 250"
else
  bad "control: markdown shadow" "rc=$RC out=$OUT"
fi
# Restating the shipped class's own pattern is how a repo names the class it
# means to move, and that entry decides the frozen path.
run 'SIZE_RATCHET_CLASSES=ui/*.ts=250;*.test.*=100'
if [ "$RC" -eq 1 ] && has "ui/src/App.test.ts — 500 lines > threshold 100 (class *.test.*)"; then
  ok "an entry restating a shipped pattern wins on a frozen path"
else
  bad "restating a shipped pattern wins" "rc=$RC out=$OUT"
fi

# A frozen path the shipped list names no class for still takes the repo's
# entry: the base threshold is a number nobody wrote for it. The shipped list
# is non-empty and simply names nothing under ui/, which is the shape a
# consumer meets; the emptied-list arm below is the degenerate one.
run 'SIZE_RATCHET_CLASSES=ui/*.ts=250' 'SIZE_RATCHET_DEFAULT_CLASSES=*.rs=100'
if [ "$RC" -eq 1 ] && has "ui/src/App.test.ts — 500 lines > threshold 250 (class ui/*.ts)"; then
  ok "with no shipped class to hand the frozen path to, the repo entry still decides it"
else
  bad "skipped entry stands where the shipped list claims nothing" "rc=$RC out=$OUT"
fi
run 'SIZE_RATCHET_CLASSES=ui/*.ts=250' SIZE_RATCHET_DEFAULT_CLASSES=
if [ "$RC" -eq 1 ] && has "ui/src/App.test.ts — 500 lines > threshold 250 (class ui/*.ts)"; then
  ok "and the same holds with the shipped list dropped entirely"
else
  bad "skipped entry stands with an empty shipped list" "rc=$RC out=$OUT"
fi
# Two entries reach the frozen path and both are skipped. The FIRST is the one
# that stands, the way first-match-wins decides every other path.
run 'SIZE_RATCHET_CLASSES=ui/*.ts=250;ui/*=900' SIZE_RATCHET_DEFAULT_CLASSES=
if [ "$RC" -eq 1 ] && has "ui/src/App.test.ts — 500 lines > threshold 250 (class ui/*.ts)" \
  && ! has "class ui/*)"; then
  ok "the first skipped entry stands, not the last"
else
  bad "the fallback keeps first-match-wins" "rc=$RC out=$OUT"
fi

# The rule protects the shipped class that NAMES the path, not any one number,
# so it runs in both directions: a looser repo entry is skipped too.
new_repo shadowloose
mklines ui/src/Wide.test.ts 900
git -C "$R" add -A
run 'SIZE_RATCHET_CLASSES=ui/*=2000'
if [ "$RC" -eq 1 ] && has "ui/src/Wide.test.ts — 900 lines > threshold 800 (class *.test.*)"; then
  ok "a LOOSER repo entry is skipped too — the shipped 800 judges the ui test file"
else
  bad "the skip is direction-agnostic" "rc=$RC out=$OUT"
fi
# The control: the same entry governs the same directory where nothing is
# frozen, so the fixture really is within its reach at 2000.
run 'SIZE_RATCHET_CLASSES=ui/*=2000' SIZE_RATCHET_FROZEN_CLASSES=
[ "$RC" -eq 0 ] && ok "control: unfrozen, that entry does take the 900-line file at 2000" \
  || bad "control: the looser entry reaches the fixture" "rc=$RC out=$OUT"

echo "=== the verdict line reports what each repo entry actually governed ==="
# An entry that decided no counted path governs nothing, and a run printing it
# as the mapping in force would advertise a threshold nothing was judged
# against. Three shapes arrive at that state and the line names none of them,
# because the engine holds no state that tells them apart: every arm below
# asserts the SAME reason.
new_repo shadownote
mklines ui/src/App.ts 300
mklines ui/src/App.test.ts 500
git -C "$R" add -A
NOTHING="(governed nothing: decided no counted path)"
# Shape one: every path it matches is frozen, so it is passed over on all of
# them.
run 'SIZE_RATCHET_CLASSES=ui/src/*.test.ts=100'
if [ "$RC" -eq 0 ] && has "classes ui/src/*.test.ts=100 $NOTHING"; then
  ok "an entry every one of whose paths is frozen is reported as governing nothing"
else
  bad "a wholly yielded entry says so on the verdict line" "rc=$RC out=$OUT"
fi
# Shape two: it matches a counted path, but an EARLIER repo entry already
# claimed it. Nothing was frozen and nothing yielded.
run SIZE_RATCHET_DEFAULT_CLASSES= SIZE_RATCHET_FROZEN_CLASSES= 'SIZE_RATCHET_CLASSES=*.ts=400;ui/*.ts=250'
if [ "$RC" -eq 1 ] && has "classes *.ts=400;ui/*.ts=250 $NOTHING"; then
  ok "an entry an earlier one shadows is reported the same way, with no cause claimed"
else
  bad "an ordering-shadowed entry says the same thing" "rc=$RC out=$OUT"
fi
# Shape three: no counted path matches it at all.
run 'SIZE_RATCHET_CLASSES=uii/*.ts=1'
if [ "$RC" -eq 0 ] && has "classes uii/*.ts=1 $NOTHING"; then
  ok "an entry no counted path matches is reported the same way"
else
  bad "a never-matched entry says the same thing" "rc=$RC out=$OUT"
fi
# An entry that DOES govern its own paths and was passed over on frozen ones
# is a different statement, and that one the engine can stand behind.
run 'SIZE_RATCHET_CLASSES=ui/*.ts=400'
if [ "$RC" -eq 0 ] && has "classes ui/*.ts=400 (yielded on frozen paths)" && ! has "governed nothing"; then
  ok "an entry that governs some paths and is passed over on frozen ones says exactly that"
else
  bad "a partly yielded entry says so on the verdict line" "rc=$RC out=$OUT"
fi
# The control: an entry that governs its paths with nothing frozen carries no
# annotation at all, so the annotations above are not on every entry.
run 'SIZE_RATCHET_CLASSES=ui/*.ts=400' SIZE_RATCHET_FROZEN_CLASSES=
if [ "$RC" -eq 1 ] && has "classes ui/*.ts=400," && ! has "governed nothing" && ! has "yielded"; then
  ok "control: with nothing frozen the same entry is reported plain"
else
  bad "control: an unyielded entry carries no annotation" "rc=$RC out=$OUT"
fi

echo "=== the remedy follows HEAD's baseline, not the verdict label ==="
# One predicate decides every size remedy: whether HEAD's baseline carries the
# path. A path HEAD does not carry has no row to raise, so the declaration
# admits a first one in every class; a path HEAD carries is a raise, which a
# frozen class refuses. The NEW label appears on both sides of that line, so
# reading the label instead misdirects in one direction or the other.
new_repo bootstrap
mklines src/a.test.ts 900
mklines src/big.ts 500
mkdir -p "$R/tools"
printf 'src/big.ts	500
' >"$R/$BASE"
git -C "$R" add -A
git -C "$R" commit -q -m seed
run
if [ "$RC" -eq 1 ] && has "new offender: src/a.test.ts — 900 lines > threshold 800 (class *.test.*)" \
  && has "remedy: split at a concept seam, or declare the row with RATCHET_RAISE=1"; then
  ok "a frozen new offender is offered the bootstrap, not a remedy the freeze forbids"
else
  bad "NEW on a frozen path names the bootstrap" "rc=$RC out=$OUT"
fi
# The control: writing that row turns the same path into the ADDED verdict,
# which names the same remedy, and the declaration then carries the run.
printf 'src/a.test.ts	900
src/big.ts	500
' >"$R/$BASE"
git -C "$R" add -A
run
if [ "$RC" -eq 1 ] && has "baseline row added: src/a.test.ts" \
  && has "remedy: split at a concept seam, or declare the row with RATCHET_RAISE=1"; then
  ok "control: the ADDED verdict for the same path names the same remedy"
else
  bad "control: ADDED names the bootstrap" "rc=$RC out=$OUT"
fi
run RATCHET_RAISE=1
[ "$RC" -eq 0 ] && ok "control: and the declaration carries that first row in a frozen class" \
  || bad "control: the bootstrap is admitted in a frozen class" "rc=$RC out=$OUT"

# The other direction, same NEW label: HEAD carries the row, the change deletes
# it and the file grows. Bootstrapping is impossible here — restoring the row
# at the new size is the raise a frozen class refuses — so the remedy is the
# split, and the arm above is its control.
new_repo remedy-head
mkbytes docs/guide.md 30000
mkdir -p "$R/tools"
printf 'docs/guide.md	30000b
' >"$R/$BASE"
git -C "$R" add -A
git -C "$R" commit -q -m row
mkbytes docs/guide.md 70000
: >"$R/$BASE"
git -C "$R" add -A
run
if [ "$RC" -eq 1 ] && has "new offender: docs/guide.md — 70000 bytes > threshold 65536 (class *.md)" \
  && has "remedy: split at a concept seam (a frozen class never raises an existing row)"; then
  ok "a NEW verdict for a path HEAD's baseline carries is offered the split, not a bootstrap"
else
  bad "the deleted-row NEW verdict names the raise it cannot have" "rc=$RC out=$OUT"
fi
# And the route the bootstrap wording would have sent its author down is the
# one the gate refuses, which is why that wording must not appear here.
printf 'docs/guide.md	70000b
' >"$R/$BASE"
git -C "$R" add -A
run RATCHET_RAISE=1
if [ "$RC" -eq 1 ] && has "frozen baseline row raised: docs/guide.md — row 30000 -> 70000 bytes"; then
  ok "control: restoring that row and declaring it is refused, so the bootstrap remedy would misdirect"
else
  bad "control: the declared raise of the restored row is refused" "rc=$RC out=$OUT"
fi

echo "=== the package excludes CHANGELOG*.md by default ==="
new_repo changelog
mkbytes CHANGELOG.md 200000
mkbytes NOTES.md 200000
git -C "$R" add -A
run
[ "$RC" -eq 1 ] && has "NOTES.md — 200000 bytes" \
  && ok "control: an ordinary 200k markdown file is an offender" \
  || bad "control: a large markdown file is an offender" "rc=$RC out=$OUT"
has "CHANGELOG.md" && bad "CHANGELOG.md is excluded by the package" "$OUT" \
  || ok "CHANGELOG.md is out of the counted set with no repo exclusion list at all"

echo "=== --staged lowers a shrunk row itself and stages the baseline ==="
new_repo autolower
mklines big.rs 500
mkdir -p "$R/tools"
printf 'big.rs\t500\n' >"$R/$BASE"
git -C "$R" add -A
git -C "$R" commit -q -m seed
mklines big.rs 450
git -C "$R" add big.rs
# The control: the ordinary check still refuses the now-loose row, so the
# --staged run below is what resolves it rather than the shrink alone.
run
[ "$RC" -eq 1 ] && has "baseline looser than reality: big.rs" \
  && ok "control: the plain check still refuses the loose row" \
  || bad "control: the plain check refuses the loose row" "rc=$RC out=$OUT"
run -- --staged
[ "$RC" -eq 0 ] && ok "--staged passes the shrinking commit on the first attempt" \
  || bad "--staged passes the shrinking commit" "rc=$RC out=$OUT"
[ "$(cat "$R/$BASE")" = "$(printf 'big.rs\t450')" ] \
  && ok "and the row is lowered to the size the commit records" \
  || bad "the row is lowered" "row=$(cat "$R/$BASE")"
staged="$(git -C "$R" diff --cached --name-only)"
case "$staged" in *"$BASE"*) ok "and the baseline is staged, so the commit carries it" ;; *) bad "the baseline is staged" "staged=$staged" ;; esac

echo "=== a --staged run the rewrite cannot rescue leaves the baseline alone ==="
# The residue a rejected commit must not carry: the developer never asked for
# those bytes, and is about to go and change something else.
new_repo autolower-reject
mklines grew.rs 500
mklines shrunk.rs 500
mkdir -p "$R/tools"
printf 'grew.rs\t500\nshrunk.rs\t500\n' >"$R/$BASE"
git -C "$R" add -A
git -C "$R" commit -q -m seed
mklines grew.rs 600
mklines shrunk.rs 450
git -C "$R" add grew.rs shrunk.rs
# The restore is a WRITE, on the path taken when the run is already failing:
# it must put the file back as it found it, mode included. A narrower-than-
# umask mode is what a plain redirect through the existing inode would widen.
chmod 600 "$R/$BASE"
mode_before="$(ls -l "$R/$BASE" | cut -c1-10)"
run -- --staged
# Both verdicts and the count: the restored verdict is the INDEX copy's, which
# names the loose row too. Asserting the growth alone would pass on a run that
# reported the rewritten candidate's verdict and lost the other violation.
[ "$RC" -eq 1 ] && has "baselined file grew: grew.rs" && has "baseline looser than reality: shrunk.rs" \
  && has "size-ratchet: 2 violation(s)" \
  && ok "the run reports the index copy's own two violations, counted" \
  || bad "the run reports the index verdict in full" "rc=$RC out=$OUT"
has "the run is not clean, so tools/size-ratchet-baseline.tsv is restored and nothing was staged" \
  && ok "and says the baseline was put back, so the restore is not silent" \
  || bad "the restore is announced" "out=$OUT"
[ "$(cat "$R/$BASE")" = "$(printf 'grew.rs\t500\nshrunk.rs\t500')" ] \
  && ok "and the worktree baseline is byte-identical to what the run found" \
  || bad "the worktree baseline is untouched" "row=$(cat "$R/$BASE")"
[ "$(ls -l "$R/$BASE" | cut -c1-10)" = "$mode_before" ] \
  && ok "and comes back at its own mode ($mode_before), not the umask's" \
  || bad "the restore preserves the file mode" "before=$mode_before after=$(ls -l "$R/$BASE" | cut -c1-10)"
chmod 644 "$R/$BASE"
case "$(git -C "$R" diff --cached --name-only)" in
  *"$BASE"*) bad "nothing is staged by a rejected run" "the baseline is in the index" ;;
  *) ok "and nothing was staged — the rejected commit carries no baseline change" ;;
esac
# The control that the rewrite really would have fired: drop the growth and
# the identical fixture passes, staging the same lowered row.
mklines grew.rs 500
git -C "$R" add grew.rs
run -- --staged
[ "$RC" -eq 0 ] && [ "$(cat "$R/$BASE")" = "$(printf 'grew.rs\t500\nshrunk.rs\t450')" ] \
  && ok "control: with the growth gone the same run tightens and stages" \
  || bad "control: the rewrite fires once the run can come out clean" "rc=$RC row=$(cat "$R/$BASE") out=$OUT"

echo "=== a malformed WORKTREE baseline never fails a clean staged snapshot ==="
# Hand-editing a row is the documented way to raise one, so a half-typed row
# is the realistic state; the commit records the index copy, which is fine.
new_repo autolower-malformed
mklines big.rs 500
mkdir -p "$R/tools"
printf 'big.rs\t500\n' >"$R/$BASE"
git -C "$R" add -A
git -C "$R" commit -q -m seed
printf 'big.rs\tfive hundred\n' >"$R/$BASE"
run -- --staged
[ "$RC" -eq 0 ] && ok "the commit passes on its own snapshot, rewrite skipped" \
  || bad "a malformed worktree copy does not fail the staged run" "rc=$RC out=$OUT"
[ "$(cat "$R/$BASE")" = "$(printf 'big.rs\tfive hundred')" ] \
  && ok "and the half-typed row is left exactly as it was" \
  || bad "the malformed copy is untouched" "row=$(cat "$R/$BASE")"
# The control: the same file GOVERNING a run is still a loud config error.
run
[ "$RC" -eq 2 ] && has "malformed row(s) above" \
  && ok "control: the same file governing the default mode is exit 2" \
  || bad "control: a governing malformed baseline is exit 2" "rc=$RC out=$OUT"
# And the case the rewrite is actually reached for: a snapshot that FAILS,
# with an unusable baseline in the worktree. The verdict is the commit's own,
# reported as a violation — never the config error of a file it does not
# record. All three of soft mode's escapes go through here: a malformed row,
# unsorted rows, and a duplicated path each make the copy unrewritable, and
# any of them failing the run would put a config error about a file the commit
# does not record in place of the verdict on the snapshot it does.
for kind in malformed unsorted duplicate; do
  case "$kind" in
    malformed) worktree_rows="$(printf 'big.rs\tfive hundred\nother.rs\t500')"; want="malformed row(s) above" ;;
    unsorted) worktree_rows="$(printf 'other.rs\t500\nbig.rs\t500')"; want="rows must be LC_ALL=C sorted" ;;
    duplicate) worktree_rows="$(printf 'big.rs\t500\nbig.rs\t500')"; want="duplicate path row(s) above" ;;
  esac
  new_repo "autolower-$kind-failing"
  mklines big.rs 500
  mklines other.rs 500
  mkdir -p "$R/tools"
  printf 'big.rs\t500\nother.rs\t500\n' >"$R/$BASE"
  git -C "$R" add -A
  git -C "$R" commit -q -m seed
  mklines big.rs 600
  git -C "$R" add big.rs
  printf '%s\n' "$worktree_rows" >"$R/$BASE"
  run -- --staged
  [ "$RC" -eq 1 ] && has "baselined file grew: big.rs" \
    && ok "a $kind worktree copy leaves the failing snapshot's own verdict standing (exit 1, not 2)" \
    || bad "a $kind worktree copy does not turn a violation into a config error" "rc=$RC out=$OUT"
  # The skip must SAY so. A rewrite that quietly does not happen leaves the
  # run failing on the verdict the rewrite existed to resolve, with a remedy
  # naming the file that just refused and nothing connecting the two.
  has "$want" && has "the --staged rewrite is skipped and the verdict comes from the index copy" \
    && ok "and the $kind skip is announced, naming its own reason" \
    || bad "the $kind skip says so" "out=$OUT"
  [ "$(cat "$R/$BASE")" = "$worktree_rows" ] \
    && ok "and the $kind worktree copy is left exactly as it was" \
    || bad "the $kind worktree copy is untouched" "rows=$(cat "$R/$BASE")"
  # The control, per state: the SAME file governing the default mode is still
  # a loud config error, so the skip is scoped to the rewrite and has not
  # softened the gate.
  run
  [ "$RC" -eq 2 ] && has "$want" \
    && ok "control: the same $kind file governing the default mode is exit 2" \
    || bad "control: a governing $kind baseline is exit 2" "rc=$RC out=$OUT"
done

echo "=== an added or raised row names the ROW, not the file's size ==="
# The two quantities differ whenever the row sits above the file, which is
# exactly when both a LOOSE and a raise verdict fire on one path — and a gate
# refusal that quotes the wrong number is a wrong-cause message.
new_repo raise-numbers
mkdir -p "$R/tools"
mklines other.rs 500
mklines big.rs 500
printf 'other.rs\t500\n' >"$R/$BASE"
git -C "$R" add -A
git -C "$R" commit -q -m seed
printf 'big.rs\t900\nother.rs\t500\n' >"$R/$BASE"
git -C "$R" add -A
run
[ "$RC" -eq 1 ] && has "baseline row added: big.rs — a first row, at 900 lines" \
  && ok "an added row is reported at the row's own value" \
  || bad "an added row names the row" "rc=$RC out=$OUT"
has "baseline looser than reality: big.rs — baseline 900 > actual 500 lines" \
  && ok "and the measurement is where it belongs, on the LOOSE line" \
  || bad "the LOOSE line carries the measurement" "out=$OUT"
# The same for a raise: HEAD's row and the current row, never the file.
new_repo raise-numbers-raised
mkdir -p "$R/tools"
mklines big.rs 500
printf 'big.rs\t500\n' >"$R/$BASE"
git -C "$R" add -A
git -C "$R" commit -q -m seed
printf 'big.rs\t900\n' >"$R/$BASE"
git -C "$R" add -A
run
[ "$RC" -eq 1 ] && has "baseline row raised: big.rs — row 500 -> 900 lines" \
  && ok "a raised row is reported as HEAD's row to the current row" \
  || bad "a raised row names both rows" "rc=$RC out=$OUT"

echo "=== the --staged rewrite carries unstaged row edits rather than dropping them ==="
new_repo autolower-edge
mklines big.rs 500
mklines other.rs 500
mkdir -p "$R/tools"
# HEAD freezes big.rs alone, so other.rs is an offender the commit inherits.
printf 'big.rs\t500\n' >"$R/$BASE"
git -C "$R" add -A
git -C "$R" commit -q -m seed
mklines big.rs 450
git -C "$R" add big.rs
# The unstaged edit is a row the index copy does not carry, so only a rewrite
# that READ the worktree copy can preserve it.
printf 'big.rs\t500\nother.rs\t500\n' >"$R/$BASE"
run RATCHET_RAISE=1 -- --staged
[ "$RC" -eq 0 ] && [ "$(cat "$R/$BASE")" = "$(printf 'big.rs\t450\nother.rs\t500')" ] \
  && ok "the rewrite reads the worktree copy, so the unstaged row edit survives into the index" \
  || bad "unstaged row edits survive the rewrite" "rc=$RC row=$(cat "$R/$BASE") out=$OUT"
staged="$(git -C "$R" diff --cached --name-only)"
case "$staged" in *"$BASE"*) ok "and is staged with it — the accepted edge, visible in the diff" ;; *) bad "the edited baseline is staged" "staged=$staged" ;; esac
# And it cannot loosen: an unstaged RAISE is pulled back to the measured size.
new_repo autolower-loosen
mklines big.rs 500
mkdir -p "$R/tools"
printf 'big.rs\t500\n' >"$R/$BASE"
git -C "$R" add -A
git -C "$R" commit -q -m seed
mklines big.rs 450
git -C "$R" add big.rs
printf 'big.rs\t900\n' >"$R/$BASE"
run -- --staged
[ "$(cat "$R/$BASE")" = "$(printf 'big.rs\t450')" ] \
  && ok "an unstaged raise is tightened back to the staged size, never carried" \
  || bad "an unstaged raise is tightened back" "row=$(cat "$R/$BASE") out=$OUT"
# A worktree row the commit does not carry still cannot authorize anything:
# with nothing to tighten there is no rewrite, and the index copy governs.
new_repo autolower-unstaged-row
mklines keep.rs 10
mklines new.rs 500
mkdir -p "$R/tools"
: >"$R/$BASE"
git -C "$R" add -A
git -C "$R" commit -q -m seed
printf 'new.rs\t500\n' >"$R/$BASE"
run -- --staged
[ "$RC" -eq 1 ] && has "new offender: new.rs" \
  && ok "an unstaged row alone freezes nothing — the index copy still governs the verdict" \
  || bad "an unstaged row freezes nothing" "rc=$RC out=$OUT"

echo "=== rows in a frozen class never rise, whatever RATCHET_RAISE says ==="
new_repo frozen
mkbytes doc.md 70000
mklines code.rs 500
mkdir -p "$R/tools"
printf 'code.rs\t500\ndoc.md\t70000b\n' >"$R/$BASE"
git -C "$R" add -A
git -C "$R" commit -q -m seed
mkbytes doc.md 80000
mklines code.rs 600
printf 'code.rs\t600\ndoc.md\t80000b\n' >"$R/$BASE"
git -C "$R" add -A
run RATCHET_RAISE=1
[ "$RC" -eq 1 ] && has "frozen baseline row raised: doc.md — row 70000 -> 80000 bytes" \
  && ok "a markdown row is frozen by default and refuses the declared raise" \
  || bad "a shipped markdown class is frozen" "rc=$RC out=$OUT"
has "code.rs" && bad "the declared raise carries the unfrozen row" "$OUT" \
  || ok "and the declared raise carries the code row in the same commit"
# The control that the SHIPPED frozen list is what refused it.
run RATCHET_RAISE=1 SIZE_RATCHET_FROZEN_CLASSES=
[ "$RC" -eq 0 ] && ok "control: with the frozen list emptied the same declared raise passes" \
  || bad "control: an empty frozen list allows the declared raise" "rc=$RC out=$OUT"

echo "=== a frozen row crosses a unit change only up to HEAD's own measurement ==="
# The adoption case: the row was written when the class counted lines, and the
# class judging it counts bytes now. One --update carries it across.
new_repo frozen-unit-change
mkbytes doc.md 70000
mkdir -p "$R/tools"
printf 'doc.md\t700\n' >"$R/$BASE"
git -C "$R" add -A
git -C "$R" commit -q -m lines
run -- --update
[ "$RC" -eq 0 ] && [ "$(cat "$R/$BASE")" = "$(printf 'doc.md\t70000b')" ] \
  && ok "one --update re-measures a frozen line row into bytes and the commit is clean" \
  || bad "a frozen line-to-byte re-measure passes" "rc=$RC row=$(cat "$R/$BASE") out=$OUT"
# The bound, on the same fixture: a file grown since HEAD raises the frozen row
# whatever unit it is written in, so it refuses at the number --update wrote.
new_repo frozen-unit-change-raised
mkbytes doc.md 70000
mkdir -p "$R/tools"
printf 'doc.md\t700\n' >"$R/$BASE"
git -C "$R" add -A
git -C "$R" commit -q -m lines
mkbytes doc.md 210000
run RATCHET_RAISE=1 -- --update
[ "$RC" -eq 1 ] && has "frozen baseline row unit changed: doc.md — row 700 -> 210000b, but HEAD's copy measures 70000b in the new unit" \
  && ok "a hand-raised byte row in a frozen class still refuses, RATCHET_RAISE or not" \
  || bad "a raised frozen row across a unit change fails closed" "rc=$RC row=$(cat "$R/$BASE") out=$OUT"

new_repo open-unit-change
mklines big.rs 500
mkdir -p "$R/tools"
printf 'big.rs\t500\n' >"$R/$BASE"
git -C "$R" add -A
git -C "$R" commit -q -m lines
run SIZE_RATCHET_FROZEN_CLASSES= 'SIZE_RATCHET_CLASSES=*.rs=1k' -- --update
[ "$RC" -eq 1 ] && has "baseline row unit changed: big.rs" \
  && ok "an open unit migration needs RATCHET_RAISE=1" \
  || bad "an undeclared open unit migration fails closed" "rc=$RC out=$OUT"
run RATCHET_RAISE=1 SIZE_RATCHET_FROZEN_CLASSES= 'SIZE_RATCHET_CLASSES=*.rs=1k'
[ "$RC" -eq 0 ] \
  && ok "RATCHET_RAISE=1 admits an open unit migration" \
  || bad "a declared open unit migration passes" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
