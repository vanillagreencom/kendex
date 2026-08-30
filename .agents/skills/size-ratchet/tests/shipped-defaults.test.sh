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

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
