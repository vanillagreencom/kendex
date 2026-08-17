#!/usr/bin/env bash
# Pins for SIZE_RATCHET_CLASSES: per-path-class thresholds resolve first
# match wins with the base threshold for unmatched paths, every verdict
# names the threshold that judged the path and why, --update stays
# tighten-only against each file's own threshold, an empty mapping is
# byte-identical single-threshold behavior, and a malformed entry is a
# config error (exit 2) naming it — never a silent fall back to the base.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
SR="$SKILL_DIR/scripts/size-ratchet"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unset SIZE_RATCHET_THRESHOLD SIZE_RATCHET_CLASSES SIZE_RATCHET_BASELINE SIZE_RATCHET_EXCLUDES SIZE_RATCHET_SETTINGS_FILE 2>/dev/null || true

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

new_repo() { # NAME
  R="$TMP/$1"
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}

mkfile() { # PATH LINES
  mkdir -p "$R/$(dirname "$1")"
  awk -v n="$2" 'BEGIN { for (i = 1; i <= n; i++) print "line " i }' >"$R/$1"
}

run_raw() { # [VAR=val ...] [-- script-args...] — run $SR in $R; sets OUT, RC
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

echo "=== a class threshold governs the paths it matches; the base governs the rest ==="
new_repo classes
mkfile src/big.txt 500
mkfile pkg/tests/big.txt 500
git -C "$R" add -A

# Control: with no classes both 500-line files are offenders at 400.
run_raw SIZE_RATCHET_THRESHOLD=400
if [ "$RC" -eq 1 ] \
  && case "$OUT" in *"src/big.txt — 500 lines"*) true ;; *) false ;; esac \
  && case "$OUT" in *"pkg/tests/big.txt — 500 lines"*) true ;; *) false ;; esac; then
  ok "control: without classes, both 500-line files are new offenders at 400"
else
  bad "control: no classes fails both files" "rc=$RC out=$OUT"
fi

run_raw SIZE_RATCHET_THRESHOLD=400 'SIZE_RATCHET_CLASSES=*/tests/*=800'
if [ "$RC" -eq 1 ] \
  && case "$OUT" in *"src/big.txt — 500 lines"*) true ;; *) false ;; esac \
  && case "$OUT" in *"pkg/tests/big.txt"*) false ;; *) true ;; esac; then
  ok "the 800 class spares the 500-line test file the 400 base still fails"
else
  bad "class threshold spares only its own paths" "rc=$RC out=$OUT"
fi

# The class threshold is a real ceiling, not an exemption.
mkfile pkg/tests/huge.txt 801
git -C "$R" add -A
run_raw SIZE_RATCHET_THRESHOLD=400 'SIZE_RATCHET_CLASSES=*/tests/*=800'
if [ "$RC" -eq 1 ] && case "$OUT" in *"pkg/tests/huge.txt — 801 lines > threshold 800 (class */tests/*)"*) true ;; *) false ;; esac; then
  ok "801 lines fails the 800 class — the class ceiling is real, not an exemption"
else
  bad "class threshold still fails above its own ceiling" "rc=$RC out=$OUT"
fi
rm "$R/pkg/tests/huge.txt"
git -C "$R" add -A

echo "=== every verdict names the threshold that judged the path, and why ==="
run_raw SIZE_RATCHET_THRESHOLD=400 'SIZE_RATCHET_CLASSES=*/tests/*=800'
case "$OUT" in
  *"src/big.txt — 500 lines > threshold 400 (default)"*) ok "an unmatched path's diagnostic names the base threshold as the default" ;;
  *) bad "unmatched-path diagnostic names the default" "rc=$RC out=$OUT" ;;
esac

mkdir -p "$R/tools"
printf 'pkg/tests/big.txt\t600\nsrc/big.txt\t600\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_raw SIZE_RATCHET_THRESHOLD=400 'SIZE_RATCHET_CLASSES=*/tests/*=800'
if [ "$RC" -eq 1 ] \
  && case "$OUT" in *"stale baseline row: pkg/tests/big.txt — 500 lines is at/under threshold 800 (class */tests/*)"*) true ;; *) false ;; esac \
  && case "$OUT" in *"baseline looser than reality: src/big.txt"*) true ;; *) false ;; esac; then
  ok "the same 500-line count is stale under the class 800 and merely loose under the base 400"
else
  bad "stale/loose split follows the path's own threshold" "rc=$RC out=$OUT"
fi

printf 'src/big.txt\t450\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_raw SIZE_RATCHET_THRESHOLD=400 'SIZE_RATCHET_CLASSES=*/tests/*=800'
case "$OUT" in
  *"src/big.txt — 500 lines > baseline 450 (threshold 400, default)"*) ok "a growth diagnostic names the baseline row and the threshold behind it" ;;
  *) bad "growth diagnostic names its threshold" "rc=$RC out=$OUT" ;;
esac
rm "$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A

# A row above reality but still above the file's threshold is LOOSE, and the
# diagnostic must say which threshold keeps the row alive — that is what
# tells a reader whether --update will tighten the row or drop it.
printf 'pkg/tests/big.txt\t900\n' >"$R/tools/size-ratchet-baseline.tsv"
mkfile pkg/tests/big.txt 850
git -C "$R" add -A
run_raw SIZE_RATCHET_THRESHOLD=400 'SIZE_RATCHET_CLASSES=*/tests/*=800'
case "$OUT" in
  *"baseline 900 > actual 850 lines, still over threshold 800 (class */tests/*)"*) ok "a loose row names the threshold still holding it above the line" ;;
  *) bad "loose diagnostic names its threshold" "rc=$RC out=$OUT" ;;
esac
mkfile pkg/tests/big.txt 500
rm "$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A

echo "=== glob semantics: the literal separators in a pattern are required ==="
new_repo globs
mkfile tests/root.txt 500
mkfile pkg/tests/nested.txt 500
git -C "$R" add -A
run_raw SIZE_RATCHET_THRESHOLD=400 'SIZE_RATCHET_CLASSES=*/tests/*=800'
if [ "$RC" -eq 1 ] \
  && case "$OUT" in *"tests/root.txt — 500 lines > threshold 400 (default)"*) true ;; *) false ;; esac \
  && case "$OUT" in *"pkg/tests/nested.txt"*) false ;; *) true ;; esac; then
  ok "'*/tests/*' needs its literal '/': it covers pkg/tests/x and never a root-level tests/x"
else
  bad "*/tests/* excludes the root-level dir" "rc=$RC out=$OUT"
fi
run_raw SIZE_RATCHET_THRESHOLD=400 'SIZE_RATCHET_CLASSES=tests/*=800;*/tests/*=800'
[ "$RC" -eq 0 ] && ok "control: the shipped both-forms mapping covers root-level and nested test dirs alike" \
  || bad "both-forms mapping covers both layouts" "rc=$RC out=$OUT"

# The one matcher never word-splits or glob-expands a pattern, on the class
# side as on the excludes side.
new_repo spacepat
mkfile "foo bqq.txt" 500
git -C "$R" add -A
run_raw SIZE_RATCHET_THRESHOLD=400 'SIZE_RATCHET_CLASSES=foo b*=800'
[ "$RC" -eq 0 ] && ok "a space-containing class pattern reaches matching as ONE pattern, unsplit" \
  || bad "space-containing class pattern" "rc=$RC out=$OUT"

echo "=== first match wins ==="
new_repo order
mkfile pkg/tests/a.txt 500
git -C "$R" add -A
run_raw SIZE_RATCHET_THRESHOLD=1000 'SIZE_RATCHET_CLASSES=*/tests/*=800;pkg/*=100'
[ "$RC" -eq 0 ] && ok "the earlier matching entry (800) wins over a later stricter one (100)" \
  || bad "first match wins (earlier lenient entry)" "rc=$RC out=$OUT"

run_raw SIZE_RATCHET_THRESHOLD=1000 'SIZE_RATCHET_CLASSES=pkg/*=100;*/tests/*=800'
if [ "$RC" -eq 1 ] && case "$OUT" in *"500 lines > threshold 100 (class pkg/*)"*) true ;; *) false ;; esac; then
  ok "reordering flips the verdict — the FIRST match decides, not the narrowest or the last"
else
  bad "first match wins (earlier strict entry)" "rc=$RC out=$OUT"
fi

echo "=== an empty mapping is exactly single-threshold behavior ==="
new_repo legacy
mkfile pkg/tests/a.txt 500
mkfile src/a.txt 500
git -C "$R" add -A
run_raw SIZE_RATCHET_THRESHOLD=400 >/dev/null
NOCLASS_OUT="$OUT"
NOCLASS_RC="$RC"
run_raw SIZE_RATCHET_THRESHOLD=400 SIZE_RATCHET_CLASSES=
if [ "$RC" = "$NOCLASS_RC" ] && [ "$OUT" = "$NOCLASS_OUT" ]; then
  ok "an explicitly empty SIZE_RATCHET_CLASSES produces byte-identical output to declaring none"
else
  bad "empty mapping is legacy behavior" "rc=$RC out=$OUT want-rc=$NOCLASS_RC"
fi
case "$NOCLASS_OUT" in
  *", classes "*) bad "no class note without classes" "out=$NOCLASS_OUT" ;;
  *) ok "the verdict line carries no class note when no class is configured" ;;
esac
run_raw SIZE_RATCHET_THRESHOLD=1000 'SIZE_RATCHET_CLASSES=*/tests/*=800'
case "$OUT" in
  *"classes */tests/*=800"*) ok "the verdict line carries the active class table" ;;
  *) bad "verdict line names the active classes" "rc=$RC out=$OUT" ;;
esac

echo "=== the mapping resolves from vstack.settings.toml, whitespace and all ==="
new_repo settingsfile
mkfile pkg/tests/a.txt 500
mkfile src/a.txt 500
git -C "$R" add -A
printf '[env]\nSIZE_RATCHET_THRESHOLD = "400"\nSIZE_RATCHET_CLASSES = "*/tests/*=800"\n' >"$R/vstack.settings.toml"
git -C "$R" add -A
run_raw
if [ "$RC" -eq 1 ] \
  && case "$OUT" in *"src/a.txt — 500 lines > threshold 400 (default)"*) true ;; *) false ;; esac \
  && case "$OUT" in *"pkg/tests/a.txt"*) false ;; *) true ;; esac; then
  ok "a repo expresses 400/800 in vstack.settings.toml with no local code"
else
  bad "two-tier config from vstack.settings.toml" "rc=$RC out=$OUT"
fi

printf '[env]\nSIZE_RATCHET_THRESHOLD = "400"\nSIZE_RATCHET_CLASSES = " */tests/* = 800 ; ; src/* = 900 "\n' >"$R/vstack.settings.toml"
git -C "$R" add -A
run_raw
[ "$RC" -eq 0 ] && ok "whitespace around entries and around '=' is trimmed, and an empty entry is skipped" \
  || bad "whitespace/empty-entry tolerance" "rc=$RC out=$OUT"
# The reported table is what the matcher used, not what was typed.
case "$OUT" in
  *"classes */tests/*=800;src/*=900"*) ok "the verdict line reports the parsed mapping, not the raw setting's spacing and empty entries" ;;
  *) bad "verdict line reports the parsed mapping" "rc=$RC out=$OUT" ;;
esac
rm "$R/vstack.settings.toml"

echo "=== a malformed mapping is a config error naming the entry ==="
new_repo malformed
mkfile a.txt 10
git -C "$R" add -A
run_raw SIZE_RATCHET_THRESHOLD=400 'SIZE_RATCHET_CLASSES=*/tests/*'
if [ "$RC" -eq 2 ] && case "$OUT" in *"entry '*/tests/*' is not 'pattern=threshold'"*) true ;; *) false ;; esac; then
  ok "an entry without '=' is exit 2 naming the entry"
else
  bad "missing '=' is a config error" "rc=$RC out=$OUT"
fi
run_raw SIZE_RATCHET_THRESHOLD=400 'SIZE_RATCHET_CLASSES=*/tests/*=eight-hundred'
if [ "$RC" -eq 2 ] && case "$OUT" in *"needs a positive integer threshold, got 'eight-hundred'"*) true ;; *) false ;; esac; then
  ok "a non-integer threshold is exit 2 naming the entry and the bad value"
else
  bad "non-integer threshold is a config error" "rc=$RC out=$OUT"
fi
run_raw SIZE_RATCHET_THRESHOLD=400 'SIZE_RATCHET_CLASSES=*/tests/*=0'
[ "$RC" -eq 2 ] && ok "a zero class threshold is exit 2 (positive integers only)" \
  || bad "zero class threshold is a config error" "rc=$RC out=$OUT"
run_raw SIZE_RATCHET_THRESHOLD=400 'SIZE_RATCHET_CLASSES==800'
if [ "$RC" -eq 2 ] && case "$OUT" in *"has an empty pattern"*) true ;; *) false ;; esac; then
  ok "an empty pattern is exit 2 (it would silently reclassify everything)"
else
  bad "empty pattern is a config error" "rc=$RC out=$OUT"
fi
# The mapping is one line: a pattern carrying a record separator is refused
# rather than splitting the note and the diagnostics it appears in.
for sep in tab newline; do
  case "$sep" in
    tab) bad_classes="$(printf 'a\tb*=800')" ;;
    newline) bad_classes="$(printf 'a\nb*=800')" ;;
  esac
  run_raw SIZE_RATCHET_THRESHOLD=400 "SIZE_RATCHET_CLASSES=$bad_classes"
  if [ "$RC" -eq 2 ] && case "$OUT" in *"tab or newline in its pattern"*) true ;; *) false ;; esac; then
    ok "a $sep inside a pattern is exit 2 (the mapping is one line)"
  else
    bad "a $sep inside a pattern is a config error" "rc=$RC out=$OUT"
  fi
done

run_raw SIZE_RATCHET_THRESHOLD=400 'SIZE_RATCHET_CLASSES=*/tests/*=800'
[ "$RC" -eq 0 ] && ok "control: the well-formed mapping the malformed cases mutate really passes" \
  || bad "well-formed mapping control" "rc=$RC out=$OUT"

echo "=== --update stays tighten-only against each file's own threshold ==="
new_repo upd
mkfile pkg/tests/shrunk.txt 900
mkfile pkg/tests/dropped.txt 500
mkfile src/shrunk.txt 500
mkdir -p "$R/tools"
printf 'pkg/tests/dropped.txt\t1200\npkg/tests/shrunk.txt\t1100\nsrc/shrunk.txt\t700\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_raw SIZE_RATCHET_THRESHOLD=400 'SIZE_RATCHET_CLASSES=*/tests/*=800' -- --update
BASE_AFTER="$(cat "$R/tools/size-ratchet-baseline.tsv")"
EXPECT="$(printf 'pkg/tests/shrunk.txt\t900\nsrc/shrunk.txt\t500\n')"
if [ "$BASE_AFTER" = "$EXPECT" ]; then
  ok "--update lowers each row to reality and drops only the row now under its OWN threshold"
else
  bad "--update tightens per-class" "got=$(printf '%s' "$BASE_AFTER" | tr '\n' '|') want=$(printf '%s' "$EXPECT" | tr '\n' '|')"
fi
[ "$RC" -eq 0 ] && ok "the re-check after --update is clean" || bad "post-update re-check" "rc=$RC out=$OUT"

# Same tree, no classes: the 500-line test file stays baselined because 400
# governs it — the control proving the drop above came from the class.
new_repo upd_noclass
mkfile pkg/tests/dropped.txt 500
mkdir -p "$R/tools"
printf 'pkg/tests/dropped.txt\t1200\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_raw SIZE_RATCHET_THRESHOLD=400 -- --update
if [ "$(cat "$R/tools/size-ratchet-baseline.tsv")" = "$(printf 'pkg/tests/dropped.txt\t500')" ]; then
  ok "control: without the class the same 500-line file keeps a row, tightened to 500"
else
  bad "no-class --update control" "got=$(cat "$R/tools/size-ratchet-baseline.tsv")"
fi

# Growth is still a hand-edit, class or not.
new_repo upd_grow
mkfile pkg/tests/grew.txt 900
mkdir -p "$R/tools"
printf 'pkg/tests/grew.txt\t850\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_raw SIZE_RATCHET_THRESHOLD=400 'SIZE_RATCHET_CLASSES=*/tests/*=800' -- --update
if [ "$RC" -eq 1 ] \
  && [ "$(cat "$R/tools/size-ratchet-baseline.tsv")" = "$(printf 'pkg/tests/grew.txt\t850')" ] \
  && case "$OUT" in *"900 lines > baseline 850 (threshold 800, class */tests/*)"*) true ;; *) false ;; esac; then
  ok "--update never raises a class-governed row: the grown file keeps 850 and still fails"
else
  bad "--update never raises under a class" "rc=$RC out=$OUT row=$(cat "$R/tools/size-ratchet-baseline.tsv")"
fi

echo "=== every shipped suite isolates every SIZE_RATCHET_* key the script reads ==="
# An inherited mapping or threshold must not be able to reclassify a fixture
# or fail a suite: each suite's `unset` line has to name the whole key set,
# derived from the script rather than restated here.
# Every SIZE_RATCHET_* identifier the shipped sources name, whatever reads
# it: keying off `sr_setting` alone would miss a key read another way (the
# settings-file override already is one).
KEYS="$(grep -rho 'SIZE_RATCHET_[A-Z][A-Z_]*' "$SKILL_DIR/scripts" | LC_ALL=C sort -u | tr '\n' ' ' || true)"
missing=""
unaccounted=""
checked_suites=0
for suite in "$TEST_DIR"/*.test.sh; do
  # A suite that binds $SR runs the gate. One that does not must not touch
  # the gate at all — otherwise it runs it with an environment nobody
  # isolated, and this check would step over it.
  if ! grep -q '^SR=' "$suite"; then
    grep -q '\$SR' "$suite" && unaccounted="$unaccounted $(basename "$suite")"
    continue
  fi
  checked_suites=$((checked_suites + 1))
  for key in $KEYS; do
    grep -q "^unset .*$key" "$suite" || missing="$missing $(basename "$suite"):$key"
  done
done
# Anti-vacuous controls: a derivation that found no keys, or a predicate that
# selected no suites, would otherwise pass silently.
derived_ok=yes
for key in SIZE_RATCHET_THRESHOLD SIZE_RATCHET_CLASSES SIZE_RATCHET_BASELINE SIZE_RATCHET_EXCLUDES SIZE_RATCHET_SETTINGS_FILE; do
  case " $KEYS " in
    *" $key "*) ;;
    *) derived_ok="no ($key)" ;;
  esac
done
[ "$derived_ok" = yes ] && ok "the key set really derives from the sources (control: all five SIZE_RATCHET_* keys are in it)" \
  || bad "key set derivation" "missing $derived_ok in KEYS=$KEYS"
# No magic count: every suite is either checked or provably gate-free.
[ "$checked_suites" -gt 0 ] && [ -z "$unaccounted" ] \
  && ok "every suite is accounted for — $checked_suites run the gate and are checked, the rest never touch it" \
  || bad "every suite is accounted for" "checked=$checked_suites unaccounted:$unaccounted"
[ -z "$missing" ] && ok "every gate-running suite unsets every SIZE_RATCHET_* key" \
  || bad "suites isolate the whole key set" "missing:$missing"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
