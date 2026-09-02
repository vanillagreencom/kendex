#!/usr/bin/env bash
# Pins for what a FROZEN class does to a baseline row: it never rises, and
# across a change of the class's UNIT the row is judged against HEAD's own blob
# measured in the new unit — the re-measure crosses, the growth under it does
# not. The shipped lists are in play here, because a consumer meets this rule
# while adopting them; the open-class case is the discriminating control.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
SR="$SKILL_DIR/scripts/size-ratchet"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sr-frozen.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

unset SIZE_RATCHET_THRESHOLD SIZE_RATCHET_CLASSES SIZE_RATCHET_DEFAULT_CLASSES SIZE_RATCHET_FROZEN_CLASSES SIZE_RATCHET_BASELINE SIZE_RATCHET_EXCLUDES SIZE_RATCHET_SETTINGS_FILE RATCHET_RAISE 2>/dev/null || true
# Like shipped-defaults.test.sh, this suite runs the SHIPPED lists, so it sets
# nothing it is testing: a case needing a different mapping passes it per run.

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


echo "=== a frozen row crosses a unit change only at HEAD's own measurement ==="
# The consumer case: the row was written when the class counted lines, and the
# class it is judged against counts bytes now. One --update adopts the new unit.
new_repo frozen-unit-change
mkbytes doc.md 70000
mkdir -p "$R/tools"
printf 'doc.md\t700\n' >"$R/$BASE"
git -C "$R" add -A
git -C "$R" commit -q -m lines
run -- --update
[ "$RC" -eq 0 ] && [ "$(cat "$R/$BASE")" = "$(printf 'doc.md\t70000b')" ] \
  && ok "one --update re-measures a frozen line row into bytes and the check passes" \
  || bad "a frozen line-to-byte re-measure passes" "rc=$RC row=$(cat "$R/$BASE") out=$OUT"
git -C "$R" add -A
run -- --staged
[ "$RC" -eq 0 ] \
  && ok "and the same index is clean under --staged" \
  || bad "the re-measured row passes --staged" "rc=$RC out=$OUT"

# The bound: the exemption is HEAD's copy, not this run's arithmetic. The row
# below EQUALS the measurement, which is what the number check alone admits.
new_repo frozen-unit-change-growth
mkbytes doc.md 70000
mkdir -p "$R/tools"
printf 'doc.md\t700\n' >"$R/$BASE"
git -C "$R" add -A
git -C "$R" commit -q -m lines
mkbytes doc.md 210000
run -- --update
[ "$RC" -eq 1 ] && [ "$(cat "$R/$BASE")" = "$(printf 'doc.md\t210000b')" ] \
  && has "frozen baseline row unit changed: doc.md — row 700 -> 210000b, but HEAD's copy measures 70000b in the new unit" \
  && ok "a file grown past HEAD's copy refuses even at the row --update just wrote" \
  || bad "growth under a unit change refuses" "rc=$RC row=$(cat "$R/$BASE") out=$OUT"
has "never raises an existing row" \
  && ok "and the remedy names the frozen-class rule, not a --update that would change nothing" \
  || bad "the growth refusal carries the frozen remedy" "$OUT"
run RATCHET_RAISE=1
[ "$RC" -eq 1 ] && has "frozen baseline row unit changed" \
  && ok "and RATCHET_RAISE=1 does not admit it" \
  || bad "a declared growth under a unit change fails closed" "rc=$RC out=$OUT"
git -C "$R" add -A
run -- --staged
[ "$RC" -eq 1 ] && has "frozen baseline row unit changed" \
  && ok "and --staged refuses the same index" \
  || bad "--staged refuses growth under a unit change" "rc=$RC out=$OUT"

# One row, one failure: where the row is not the measurement, the size check
# already reports it, so the unit branch stays quiet rather than printing a
# second remedy that contradicts the first.
new_repo frozen-unit-change-once
mkbytes doc.md 70000
mkdir -p "$R/tools"
printf 'doc.md\t700\n' >"$R/$BASE"
git -C "$R" add -A
git -C "$R" commit -q -m lines
printf 'doc.md\t65600b\n' >"$R/$BASE"
git -C "$R" add -A
run
[ "$RC" -eq 1 ] && has "baselined file grew: doc.md" && has "1 violation(s)" \
  && ok "a row under the measurement is reported once, as growth" \
  || bad "a row under the measurement is one violation" "rc=$RC out=$OUT"
printf 'doc.md\t90000b\n' >"$R/$BASE"
git -C "$R" add -A
run
[ "$RC" -eq 1 ] && has "baseline looser than reality: doc.md" && has "1 violation(s)" \
  && ok "and a row over it is reported once, as slack, with --update as the remedy" \
  || bad "a row over the measurement is one violation" "rc=$RC out=$OUT"
run -- --update
[ "$RC" -eq 0 ] && [ "$(cat "$R/$BASE")" = "$(printf 'doc.md\t70000b')" ] \
  && ok "and that remedy resolves it" \
  || bad "--update resolves the slack row" "rc=$RC row=$(cat "$R/$BASE") out=$OUT"

# The pre-commit hook's own path: --staged over an untouched stale row adopts
# the bounded re-measure itself and stages it, so the commit passes first try.
new_repo frozen-unit-change-hook
mkbytes doc.md 70000
mkdir -p "$R/tools"
printf 'doc.md\t700\n' >"$R/$BASE"
git -C "$R" add -A
git -C "$R" commit -q -m lines
run -- --staged
[ "$RC" -eq 0 ] && has "re-measured (the class counts bytes now): doc.md 700 -> 70000b" \
  && ok "--staged re-measures a stale frozen row itself and the commit is clean" \
  || bad "--staged adopts a bounded re-measure" "rc=$RC out=$OUT"
[ "$(cat "$R/$BASE")" = "$(printf 'doc.md\t70000b')" ] \
  && [ "$(git -C "$R" show :tools/size-ratchet-baseline.tsv)" = "$(printf 'doc.md\t70000b')" ] \
  && ok "and the re-measured row is what the commit records, not just the worktree" \
  || bad "--staged stages the re-measured row" "row=$(cat "$R/$BASE") staged=$(git -C "$R" show :tools/size-ratchet-baseline.tsv)"
# The discriminating half: the same path with the file grown past HEAD's copy
# restores the baseline and stages nothing.
new_repo frozen-unit-change-hook-growth
mkbytes doc.md 70000
mkdir -p "$R/tools"
printf 'doc.md\t700\n' >"$R/$BASE"
git -C "$R" add -A
git -C "$R" commit -q -m lines
mkbytes doc.md 210000
git -C "$R" add -A
run -- --staged
[ "$RC" -eq 1 ] && has "restored and nothing was staged" \
  && [ "$(cat "$R/$BASE")" = "$(printf 'doc.md\t700')" ] \
  && [ "$(git -C "$R" show :tools/size-ratchet-baseline.tsv)" = "$(printf 'doc.md\t700')" ] \
  && ok "control: with the file grown past HEAD, --staged restores the row and stages nothing" \
  || bad "--staged refuses growth and stages nothing" "rc=$RC row=$(cat "$R/$BASE") out=$OUT"

# The reverse direction is the same rule, and it arrives differently: a repo
# override moves the class rather than a stale row meeting the shipped one.
new_repo frozen-unit-change-rev
mklines doc.md 700
mkdir -p "$R/tools"
printf 'doc.md\t70000b\n' >"$R/$BASE"
git -C "$R" add -A
git -C "$R" commit -q -m bytes
run 'SIZE_RATCHET_CLASSES=*.md=600' -- --update
[ "$RC" -eq 0 ] && [ "$(cat "$R/$BASE")" = "$(printf 'doc.md\t700')" ] \
  && ok "a frozen byte-to-line re-measure passes the same way" \
  || bad "a frozen byte-to-line re-measure passes" "rc=$RC row=$(cat "$R/$BASE") out=$OUT"
git -C "$R" checkout -q -- "$BASE"
mklines doc.md 900
run 'SIZE_RATCHET_CLASSES=*.md=600' -- --update
[ "$RC" -eq 1 ] && [ "$(cat "$R/$BASE")" = "$(printf 'doc.md\t900')" ] \
  && has "frozen baseline row unit changed: doc.md — row 70000b -> 900, but HEAD's copy measures 700 in the new unit" \
  && ok "and grown past HEAD it refuses in that direction too" \
  || bad "the reverse direction refuses growth" "rc=$RC row=$(cat "$R/$BASE") out=$OUT"

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
