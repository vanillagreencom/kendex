#!/usr/bin/env bash
# Pins the refusal on a line-class blob git reads as binary. A raw NUL typed
# into a source file instead of its escape makes git call the file binary:
# no diff, no `git grep` hit, no blame — and `wc -l` still returns a number,
# so the gate used to report a clean measurement over content nobody could
# read. The gate now refuses that blob by name and byte offset.
#
# Pinned here: the refusal fires in both scopes (index and worktree), the
# offset is counted in BYTES and located inside the sniff window, the same
# bytes in a BYTE class pass because nothing counts their lines, an excluded
# path stays excluded, and the diagnostic never carries the byte itself.
# The must-fail control at the end reverts the refusal and shows the NUL
# fixture going green, so the green cases above are evidence.
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

# The fixture bytes: a one-line TypeScript source whose string literal carries
# a raw U+0000 where the author meant to type the escape. `printf` writes the
# byte; nothing in this file ever holds one, so this suite is itself readable.
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
if has 'measured in lines' && has 'Write the escape'; then
  ok "the refusal states why it refuses and tells the author to write the escape"
else
  bad "the refusal carries its cause and remedy" "out=$OUT"
fi

echo "=== the diagnostic never reprints the byte ==="
# Reprinting it would put a NUL into the log, terminal or CI annotation that
# carries the diagnostic onward — the same invisibility, one layer out.
total="$(wc -c <"$OUTFILE")"
stripped="$(LC_ALL=C tr -d '\000' <"$OUTFILE" | wc -c)"
if [ "$((total))" -eq "$((stripped))" ] && [ "$((total))" -gt 0 ]; then
  ok "the whole diagnostic ($((total)) bytes) carries no NUL of its own"
else
  bad "the refusal never reprints the byte" "total=$total stripped=$stripped"
fi

echo "=== the same bytes in a BYTE class pass — nothing counts their lines ==="
new_repo byteclass
plant_nul src/asset.png 'const a = "x'
git -C "$R" add -A
run_in SIZE_RATCHET_THRESHOLD=400 SIZE_RATCHET_CLASSES='*.png=64k' -- --staged
if [ "$RC" -eq 0 ]; then
  ok "a .png in a byte class carrying the identical bytes passes (exit 0)"
else
  bad "a byte class is never asked about content" "rc=$RC out=$OUT"
fi

echo "=== an excluded path stays excluded ==="
new_repo excluded
plant_nul assets/icon.png 'const a = "x'
mkdir -p "$R/tools"
printf 'assets/*\tbinary media — no lines to count\n' >"$R/tools/size-ratchet-excludes"
git -C "$R" add -A
run_in SIZE_RATCHET_THRESHOLD=400 -- --staged
if [ "$RC" -eq 0 ]; then
  ok "an excluded path is never sniffed (exit 0)"
else
  bad "the exclusion list precedes the sniff" "rc=$RC out=$OUT"
fi

echo "=== the worktree scan CI runs refuses the same blob ==="
# CI runs the gate without --staged, over a clean checkout: a NUL that reached
# main must red there too, not only at the commit that introduced it.
new_repo worktree
plant_nul src/installed.ts 'const a = "x'
git -C "$R" add -A
run_in SIZE_RATCHET_THRESHOLD=400
if [ "$RC" -eq 2 ] && has 'src/installed.ts: a NUL byte at offset 12'; then
  ok "the worktree copy is refused the same way (exit 2, same offset)"
else
  bad "the no---staged scan refuses it too" "rc=$RC out=$OUT"
fi

echo "=== the offset counts bytes, not characters ==="
# 100 x U+00E9 is 100 characters and 200 bytes. A count that came from the
# shell's character-wise read would report 100 here.
new_repo multibyte
mkdir -p "$R/src"
{ awk 'BEGIN { for (i = 0; i < 100; i++) printf "\303\251" }'; printf '\000'; printf '";\n'; } >"$R/src/installed.ts"
git -C "$R" add -A
run_in SIZE_RATCHET_THRESHOLD=400 -- --staged
if [ "$RC" -eq 2 ] && has 'src/installed.ts: a NUL byte at offset 200'; then
  ok "a NUL behind 100 two-byte characters is reported at byte offset 200"
else
  bad "the offset is a byte offset" "rc=$RC out=$OUT"
fi

echo "=== the sniff window is the leading 8000 bytes, git's own rule ==="
# git reads a blob as text when no NUL falls in the leading 8000 bytes, so
# the gate must agree at the boundary in both directions — a byte at offset
# 7999 is inside the window, one at 8000 is not.
for probe in "7999 2 inside" "8000 0 outside"; do
  set -- $probe
  pad="$1"
  want_rc="$2"
  where="$3"
  new_repo "window-$pad"
  mkdir -p "$R/src"
  { awk -v n="$pad" 'BEGIN { for (i = 0; i < n; i++) printf "x" }'; printf '\000'; printf '\n'; } >"$R/src/installed.ts"
  git -C "$R" add -A
  run_in SIZE_RATCHET_THRESHOLD=400 -- --staged
  if [ "$RC" -eq "$want_rc" ]; then
    ok "a NUL at offset $pad is $where the window (exit $RC)"
  else
    bad "the window boundary matches git's rule at offset $pad" "rc=$RC want=$want_rc out=$OUT"
  fi
done

echo "=== must-fail control: with the refusal reverted, the NUL fixture goes green ==="
# The control keeps every call site and the whole detection text and removes
# only the behavior, so a green run below proves the cases above are the
# refusal's doing rather than an assertion that cannot fail.
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
