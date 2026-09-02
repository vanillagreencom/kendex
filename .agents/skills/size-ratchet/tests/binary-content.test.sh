#!/usr/bin/env bash
# Pins the refusal on a tracked blob git reads as binary. A raw NUL typed in
# place of its escape makes git call the file binary — no textual diff, a
# `git grep -I` that drops the path — while `wc -l` still returns a number, so
# the gate used to measure content nobody could read. It now refuses by name
# and byte offset.
#
# Pinned here: the refusal fires in both scopes (index and worktree), and in
# every mode, since it runs before the --seed and --update branches; a byte
# class is refused too, the content deciding and not the unit; a SIZE-excluded
# text path is sniffed like every other, git's own diff attribute the only
# exemption; the sniff window is bounded in bytes under any locale; and a scan
# that comes back empty refuses rather than passing. Each must-fail control
# reverts one behavior and shows the fixture going green, so the green cases
# are evidence.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
SR="$SKILL_DIR/scripts/size-ratchet"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Hermetic: a leaked setting would mask every case below.
unset SIZE_RATCHET_THRESHOLD SIZE_RATCHET_CLASSES SIZE_RATCHET_DEFAULT_CLASSES SIZE_RATCHET_FROZEN_CLASSES SIZE_RATCHET_BASELINE SIZE_RATCHET_EXCLUDES SIZE_RATCHET_SETTINGS_FILE RATCHET_RAISE 2>/dev/null || true
# The shipped class list and frozen list are policy, pinned by
# shipped-defaults.test.sh. Every fixture here declares its own thresholds,
# so both start empty and a case that needs one sets it.
export SIZE_RATCHET_DEFAULT_CLASSES="" SIZE_RATCHET_FROZEN_CLASSES=""
# A fixture repo is its own repo: an inherited git environment would make
# `git add` write into the index of whatever repo invoked this suite.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE 2>/dev/null || true

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

# A one-line TypeScript source whose string literal carries a raw U+0000 where
# the escape was meant. `printf` writes it, so this suite holds no NUL itself.
plant_nul() { # PATH LEADING-BYTES
  mkdir -p "$R/$(dirname "$1")"
  { printf '%s' "$2"; printf '\000'; printf 'y";\n'; } >"$R/$1"
}

# OUT via a file, never a command substitution: bash drops NUL bytes from
# `$(...)`, so a diagnostic that leaked the byte would read as clean here.
run_in() { # [VAR=val ...] [-- script-args...] — run $SR in $R; sets OUTFILE, OUT, RC
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
  OUTFILE="$TMP/out.$$"
  RC=0
  (cd "$R" && env ${envs[@]+"${envs[@]}"} "$GATE" ${args[@]+"${args[@]}"}) >"$OUTFILE" 2>&1 || RC=$?
  OUT="$(cat "$OUTFILE")"
}
GATE="$SR"

has() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

echo "=== control: the same fixture without the byte is measured and clean ==="
new_repo control
mkdir -p "$R/src"
printf 'const a = "xy";\n' >"$R/src/installed.ts"
git -C "$R" add -A
run_in SIZE_RATCHET_THRESHOLD=400 -- --staged
if [ "$RC" -eq 0 ]; then
  ok "control: a NUL-free .ts under the line threshold passes (exit 0)"
else
  bad "control: the fixture is clean but for the byte" "rc=$RC out=$OUT"
fi

echo "=== a staged line-class blob carrying a NUL is refused by path and offset ==="
new_repo staged
plant_nul src/installed.ts 'const a = "x'
git -C "$R" add -A
run_in SIZE_RATCHET_THRESHOLD=400 -- --staged
# 'const a = "x' is 12 bytes, so the byte sits at offset 12.
if [ "$RC" -eq 2 ] && has 'src/installed.ts: a NUL byte at offset 12'; then
  ok "the index blob is refused (exit 2), naming the path and the byte offset"
else
  bad "a staged .ts with a NUL is refused naming the offset" "rc=$RC out=$OUT"
fi
if has 'tracked as reviewable text' && has 'Write the escape'; then
  ok "the refusal states why it refuses and tells the author to write the escape"
else
  bad "the refusal carries its cause and remedy" "out=$OUT"
fi

echo "=== the diagnostic never reprints the byte ==="
# Reprinting it puts the byte into whatever log or CI annotation carries the
# diagnostic onward — the same invisibility, one layer out.
total="$(wc -c <"$OUTFILE")"
stripped="$(LC_ALL=C tr -d '\000' <"$OUTFILE" | wc -c)"
if [ "$((total))" -eq "$((stripped))" ] && [ "$((total))" -gt 0 ]; then
  ok "the whole diagnostic ($((total)) bytes) carries no NUL of its own"
else
  bad "the refusal never reprints the byte" "total=$total stripped=$stripped"
fi

echo "=== a BYTE class is refused too — the content decides, not the unit ==="
# A repo's whole markdown surface sits in byte classes, so a rule keyed on the
# unit would leave every SKILL.md and AGENTS.md free to carry the byte.
new_repo byteclass
plant_nul skills/demo/SKILL.md 'const a = "x'
git -C "$R" add -A
run_in SIZE_RATCHET_THRESHOLD=400 SIZE_RATCHET_CLASSES='*/SKILL.md=24k' -- --staged
if [ "$RC" -eq 2 ] && has 'skills/demo/SKILL.md: a NUL byte at offset 12'; then
  ok "a SKILL.md in a byte class is refused (exit 2), naming the path and offset"
else
  bad "a byte class is asked about its content too" "rc=$RC out=$OUT"
fi
# CI runs the gate without --staged, so the worktree arm is the half a NUL
# reaching main would meet. Pinned here, not inferred from the index arm.
run_in SIZE_RATCHET_THRESHOLD=400 SIZE_RATCHET_CLASSES='*/SKILL.md=24k'
if [ "$RC" -eq 2 ] && has 'skills/demo/SKILL.md: a NUL byte at offset 12'; then
  ok "the worktree scan CI runs refuses the byte-class blob too (exit 2, same offset)"
else
  bad "the byte-class refusal fires in the scope CI runs" "rc=$RC out=$OUT"
fi

echo "=== must-fail control: keyed on the unit again, the same fixture goes green ==="
# The control restores the one thing that changed — the sniff answering only
# where the resolved unit is lines — and leaves every call site standing.
UNIT="$TMP/unit-scripts"
mkdir -p "$UNIT"
cp -R "$SKILL_DIR/scripts/." "$UNIT/"
UNIT_ANCHOR='note_if_binary() {'
if awk -v anchor="$UNIT_ANCHOR" '
    { print }
    index($0, anchor) == 1 { print "  if [ \"${PU:-l}\" = \"b\" ]; then return 0; fi # must-fail control: coverage back to line classes"; n++ }
    END { exit (n == 1 ? 0 : 3) }
  ' "$UNIT/size-ratchet" >"$UNIT/size-ratchet.mut"; then
  mv "$UNIT/size-ratchet.mut" "$UNIT/size-ratchet"
  chmod +x "$UNIT/size-ratchet"
  new_repo unitctrl
  plant_nul skills/demo/SKILL.md 'const a = "x'
  git -C "$R" add -A
  GATE="$UNIT/size-ratchet"
  run_in SIZE_RATCHET_THRESHOLD=400 SIZE_RATCHET_CLASSES='*/SKILL.md=24k' -- --staged
  GATE="$SR"
  if [ "$RC" -eq 0 ] && ! has 'NUL byte at offset'; then
    ok "narrowing the sniff back to line classes lets the SKILL.md pass"
  else
    bad "the control narrows the coverage it should" "rc=$RC out=$OUT"
  fi
else
  bad "the unit control's substitution matched exactly one site" "no single '$UNIT_ANCHOR' line at the start of a line in $UNIT/size-ratchet"
fi

echo "=== a SIZE-excluded text path is sniffed like any other ==="
# The exclusion list answers which paths carry no SIZE bound. Reading it as a
# content exemption let every entry carry the byte unseen — a lockfile, a
# generated bundle, the shipped CHANGELOG*.md default worst of all.
new_repo excluded
plant_nul assets/icon.png 'const a = "x'
mkdir -p "$R/tools"
printf 'assets/*\tbinary media — not reviewable text\n' >"$R/tools/size-ratchet-excludes"
git -C "$R" add -A
run_in SIZE_RATCHET_THRESHOLD=400 -- --staged
if [ "$RC" -eq 2 ] && has 'assets/icon.png: a NUL byte at offset 12'; then
  ok "the size exclusion buys no content exemption — the path is refused by name and offset"
else
  bad "a size-excluded text path is sniffed like every other path" "rc=$RC out=$OUT"
fi

echo "=== and git's own diff attribute is what exempts it ==="
# The authority is the record git already keeps: a path declared binary (or
# -diff) is out of every textual diff, so its bytes were never reviewable
# text. Same fixture, same exclusion list, one .gitattributes line added.
printf 'assets/* binary\n' >"$R/.gitattributes"
run_in SIZE_RATCHET_THRESHOLD=400 -- --staged
if [ "$RC" -eq 2 ] && has 'assets/icon.png: a NUL byte at offset 12'; then
  ok "an unstaged .gitattributes exempts nothing under --staged (exit 2)"
else
  bad "the staged scope reads the attribute from the index" "rc=$RC out=$OUT"
fi
git -C "$R" add -A
run_in SIZE_RATCHET_THRESHOLD=400 -- --staged
if [ "$RC" -eq 0 ] && ! has 'NUL byte at offset'; then
  ok "a path .gitattributes declares binary is exempt from the sniff (exit 0)"
else
  bad "git's own attribute exempts the path" "rc=$RC out=$OUT"
fi
awk 'BEGIN { for (i = 0; i < 900; i++) print "x" }' >>"$R/assets/icon.png" # still measured
run_in SIZE_RATCHET_THRESHOLD=400 SIZE_RATCHET_EXCLUDES=tools/no-list
if [ "$RC" -eq 1 ] && has 'new offender: assets/icon.png'; then
  ok "a diff-exempt path is still measured — 900 lines over the threshold reds it"
else
  bad "the attribute exempts the sniff, not the measurement" "rc=$RC out=$OUT"
fi

echo "=== must-fail control: with the size list back in charge, the same fixture goes green ==="
# The control restores the one thing that changed — the size exclusion
# short-circuiting the walk before the sniff — and leaves the rest standing.
EXC="$TMP/excl-scripts"
mkdir -p "$EXC"
cp -R "$SKILL_DIR/scripts/." "$EXC/"
EXC_ANCHOR='  if is_excluded "$f"; then excluded=1; fi'
if awk -v anchor="$EXC_ANCHOR" '
    { print }
    $0 == anchor { print "  if [ \"$excluded\" -eq 1 ]; then continue; fi # must-fail control: the size list back in charge of content"; n++ }
    END { exit (n == 1 ? 0 : 3) }
  ' "$EXC/size-ratchet" >"$EXC/size-ratchet.mut"; then
  mv "$EXC/size-ratchet.mut" "$EXC/size-ratchet"
  chmod +x "$EXC/size-ratchet"
  new_repo exclctrl
  plant_nul assets/icon.png 'const a = "x'
  mkdir -p "$R/tools"
  printf 'assets/*\tbinary media — not reviewable text\n' >"$R/tools/size-ratchet-excludes"
  git -C "$R" add -A
  GATE="$EXC/size-ratchet"
  run_in SIZE_RATCHET_THRESHOLD=400 -- --staged
  GATE="$SR"
  if [ "$RC" -eq 0 ] && ! has 'NUL byte at offset'; then
    ok "size exclusion short-circuiting the walk lets the NUL fixture pass — the case above reds without it"
  else
    bad "the control restores the short-circuit it should" "rc=$RC out=$OUT"
  fi
else
  bad "the exclusion control's substitution matched exactly one site" "no single '$EXC_ANCHOR' line in $EXC/size-ratchet"
fi

echo "=== the worktree scan CI runs refuses the same blob ==="
# A NUL that reached main must red in CI too, not only at its commit.
new_repo worktree
plant_nul src/installed.ts 'const a = "x'
git -C "$R" add -A
run_in SIZE_RATCHET_THRESHOLD=400
if [ "$RC" -eq 2 ] && has 'src/installed.ts: a NUL byte at offset 12'; then
  ok "the worktree copy is refused the same way (exit 2, same offset)"
else
  bad "the no---staged scan refuses it too" "rc=$RC out=$OUT"
fi

echo "=== the 8000 bound is bytes even when the locale is multibyte ==="
# The prefilter's read bound counts CHARACTERS unless the locale is C, so a
# NUL past byte 8000 would stop a character-wise read while `od -N 8000` finds
# nothing, and the contradiction refusal above would red a file git reads as
# text. 5000 x U+00E9 is 5000 characters and 10000 bytes: the byte at 10000 is
# outside the window by git's rule, inside it by the character count.
plant_wide_nul() { # 5000 two-byte characters in $R/src/installed.ts, then the byte
  mkdir -p "$R/src"
  { awk 'BEGIN { for (i = 0; i < 5000; i++) printf "\303\251" }'; printf '\000'; printf '\n'; } >"$R/src/installed.ts"
  git -C "$R" add -A
}
# No locale is assumed present: the case needs a multibyte one to say anything.
utf8_locale="$({ locale -a 2>/dev/null || true; } | awk 'tolower($0) ~ /\.utf-?8$/ && !f { v = $0; f = 1 } END { if (f) print v }')"
if [ -z "$utf8_locale" ]; then
  printf '  skip  the byte-bound case needs a UTF-8 locale; `locale -a` lists none here\n'
else
  new_repo bytebound
  plant_wide_nul
  run_in "LC_ALL=$utf8_locale" "LANG=$utf8_locale" SIZE_RATCHET_THRESHOLD=400 -- --staged
  if [ "$RC" -eq 0 ] && ! has 'located none'; then
    ok "under $utf8_locale a NUL past byte 8000 leaves the blob text (exit 0)"
  else
    bad "the sniff bound counts bytes under a multibyte locale" "rc=$RC out=$OUT"
  fi

  echo "=== must-fail control: without LC_ALL=C the same fixture is refused ==="
  # Exit 0 is also what a sniff that never ran returns, so the case above is
  # evidence only beside this: the `LC_ALL=C` bound removed, nothing else.
  BOUND="$TMP/bound-scripts"
  mkdir -p "$BOUND"
  cp -R "$SKILL_DIR/scripts/." "$BOUND/"
  BOUND_ANCHOR='  local LC_ALL=C chunk status=0 off'
  if awk -v anchor="$BOUND_ANCHOR" '
      $0 == anchor { print "  local chunk status=0 off"; n++; next }
      { print }
      END { exit (n == 1 ? 0 : 3) }
    ' "$BOUND/size-ratchet" >"$BOUND/size-ratchet.mut"; then
    mv "$BOUND/size-ratchet.mut" "$BOUND/size-ratchet"
    chmod +x "$BOUND/size-ratchet"
    new_repo boundctrl
    plant_wide_nul
    GATE="$BOUND/size-ratchet"
    run_in "LC_ALL=$utf8_locale" "LANG=$utf8_locale" SIZE_RATCHET_THRESHOLD=400 -- --staged
    GATE="$SR"
    if [ "$RC" -eq 2 ] && has 'located none'; then
      ok "a character-counting bound refuses the same fixture — the case above is evidence"
    else
      bad "the control removes the byte bound it should" "rc=$RC out=$OUT"
    fi
  else
    bad "the byte-bound control's substitution matched exactly one site" "no single '$BOUND_ANCHOR' line in $BOUND/size-ratchet"
  fi
fi

echo "=== a locating scan that comes back empty refuses, it does not pass ==="
# The prefilter is byte-exact, so a stop it reports and a scan that then finds
# nothing contradict each other; calling that clean is the fail-open the sniff
# exists to close. A NONZERO `od` is already caught by pipefail — this is the
# quiet-success half.
OD_SHIM="$TMP/od-shim"
mkdir -p "$OD_SHIM"
printf '#!/usr/bin/env bash\nexit 0\n' >"$OD_SHIM/od"
chmod +x "$OD_SHIM/od"
new_repo scanempty
plant_nul src/installed.ts 'const a = "x'
git -C "$R" add -A
run_in "PATH=$OD_SHIM:$PATH" SIZE_RATCHET_THRESHOLD=400 -- --staged
if [ "$RC" -eq 2 ] && has "src/installed.ts" && has "located none"; then
  ok "an od that succeeds and prints nothing is a refusal (exit 2), naming the path"
else
  bad "an empty locating scan refuses rather than reporting clean" "rc=$RC out=$OUT"
fi
case "$OUT" in *"size-ratchet: OK"*) bad "no OK verdict may accompany the empty scan" "$OUT" ;; *) ok "no OK verdict accompanies the empty scan" ;; esac


echo "=== must-fail control: with the refusal reverted, the NUL fixture goes green ==="
# The control keeps every call site and the whole detection text and removes
# only the behavior, so a green run below rules out a vacuous assertion.
CTRL="$TMP/control-scripts"
mkdir -p "$CTRL"
cp -R "$SKILL_DIR/scripts/." "$CTRL/"
ANCHOR='note_if_binary() {'
if awk -v anchor="$ANCHOR" '
    { print }
    index($0, anchor) == 1 { print "  return 0 # must-fail control: the refusal, reverted"; n++ }
    END { exit (n == 1 ? 0 : 3) }
  ' "$CTRL/size-ratchet" >"$CTRL/size-ratchet.mut"; then
  mv "$CTRL/size-ratchet.mut" "$CTRL/size-ratchet"
  chmod +x "$CTRL/size-ratchet"
  new_repo mustfail
  plant_nul src/installed.ts 'const a = "x'
  git -C "$R" add -A
  GATE="$CTRL/size-ratchet"
  run_in SIZE_RATCHET_THRESHOLD=400 -- --staged
  GATE="$SR"
  if [ "$RC" -eq 0 ] && ! has 'NUL byte at offset'; then
    ok "reverting the refusal lets the NUL fixture pass — the cases above red without it"
  else
    bad "the control removes the behavior it should" "rc=$RC out=$OUT"
  fi
else
  bad "the control's substitution matched exactly one site" "no single '$ANCHOR' line at the start of a line in $CTRL/size-ratchet"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
