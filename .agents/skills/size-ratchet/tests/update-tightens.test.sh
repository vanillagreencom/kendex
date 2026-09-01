#!/usr/bin/env bash
# Pins for --update's tighten-only contract: rows are lowered or removed to
# match reality, NEVER added and NEVER raised — a grown file keeps its old
# row (and keeps failing), a new offender stays out of the baseline, and
# deliberate growth is a hand-edit that then passes (control).
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
SR="$SKILL_DIR/scripts/size-ratchet"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unset SIZE_RATCHET_THRESHOLD SIZE_RATCHET_CLASSES SIZE_RATCHET_DEFAULT_CLASSES SIZE_RATCHET_FROZEN_CLASSES SIZE_RATCHET_BASELINE SIZE_RATCHET_EXCLUDES SIZE_RATCHET_SETTINGS_FILE RATCHET_RAISE 2>/dev/null || true
# The shipped class list and frozen list are policy, pinned by
# shipped-defaults.test.sh. Every fixture here declares its own thresholds,
# so both start empty and a case that needs one sets it.
export SIZE_RATCHET_DEFAULT_CLASSES="" SIZE_RATCHET_FROZEN_CLASSES=""

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

mkfile() { # PATH LINES
  mkdir -p "$R/$(dirname "$1")"
  awk -v n="$2" 'BEGIN { for (i = 1; i <= n; i++) print "line " i }' >"$R/$1"
}

run_sr() { # [args...] — run in $R at threshold 10; sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && SIZE_RATCHET_THRESHOLD=10 "$SR" "$@" 2>&1)" || RC=$?
}

R="$TMP/upd"
mkdir -p "$R"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test

# One fixture exercising every row fate at once (threshold 10):
#   grown.txt   actual 20, row 12  -> kept at 12 (never raised), still fails
#   loose.txt   actual 15, row 30  -> lowered to 15
#   shrunk.txt  actual  5, row 12  -> removed (under threshold)
#   gone.txt    no file,   row 40  -> removed (left the tracked set)
#   newoff.txt  actual 25, no row  -> NOT added, still fails
mkfile grown.txt 20
mkfile loose.txt 15
mkfile shrunk.txt 5
mkfile newoff.txt 25
mkdir -p "$R/tools"
printf 'gone.txt\t40\ngrown.txt\t12\nloose.txt\t30\nshrunk.txt\t12\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A

run_sr --update
[ "$RC" -eq 1 ] && ok "--update still exits 1 while growth and a new offender remain" \
  || bad "--update still exits 1 while growth and a new offender remain" "rc=$RC out=$OUT"

expected="$(printf 'grown.txt\t12\nloose.txt\t15\n')"
actual="$(cat "$R/tools/size-ratchet-baseline.tsv")"
[ "$actual" = "$expected" ] && ok "rewritten baseline is byte-exact: grown kept at 12, loose lowered to 15, shrunk+gone removed, newoff NOT added" \
  || bad "rewritten baseline is byte-exact" "$(printf 'expected:\n%s\ngot:\n%s' "$expected" "$actual")"

LC_ALL=C sort -c "$R/tools/size-ratchet-baseline.tsv" \
  && ok "rewritten baseline is LC_ALL=C sorted" || bad "rewritten baseline is LC_ALL=C sorted" "$actual"

case "$OUT" in *"tightened: loose.txt 30 -> 15"*) ok "tightening is announced with old -> new" ;; *) bad "tightening is announced with old -> new" "$OUT" ;; esac
case "$OUT" in *"kept (grew"*) ok "the kept grown row is called out as a hand-edit, never --update" ;; *) bad "the kept grown row is called out" "$OUT" ;; esac
case "$OUT" in *"new offender: newoff.txt"*) ok "the surviving new offender still fails after --update" ;; *) bad "the surviving new offender still fails after --update" "$OUT" ;; esac
case "$OUT" in *"baselined file grew: grown.txt — 20 lines > baseline 12"*) ok "the surviving growth still fails after --update" ;; *) bad "the surviving growth still fails after --update" "$OUT" ;; esac

run_sr --update
actual2="$(cat "$R/tools/size-ratchet-baseline.tsv")"
[ "$RC" -eq 1 ] && [ "$actual2" = "$expected" ] && ok "--update is idempotent: second run changes nothing" \
  || bad "--update is idempotent" "rc=$RC got: $actual2"

# Control: deliberate growth accepted by HAND-EDITING the rows makes the
# repo pass — proving the failures above were the ratchet, not noise.
printf 'grown.txt\t20\nloose.txt\t15\nnewoff.txt\t25\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_sr
[ "$RC" -eq 0 ] && ok "hand-edited acceptance rows pass (control: growth is a reviewed human edit)" \
  || bad "hand-edited acceptance rows pass" "rc=$RC out=$OUT"

# A tracked-but-absent file (unstaged deletion / sparse checkout) counts
# from the INDEX blob — "every tracked file" holds without the worktree
# copy. An over-threshold baselined row therefore survives --update at its
# real size, and a sparse tree cannot smuggle a new offender past the gate.
R="$TMP/upd-absent"
mkdir -p "$R"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
mkfile keep.txt 15
mkdir -p "$R/tools"
printf 'keep.txt\t15\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
rm "$R/keep.txt" # unstaged: keep.txt stays in git ls-files; index holds 15 lines
run_sr --update
row="$(cat "$R/tools/size-ratchet-baseline.tsv")"
[ "$RC" -eq 0 ] && [ "$row" = "$(printf 'keep.txt\t15')" ] \
  && ok "--update keeps a tracked-but-absent over-threshold row at its index-counted size" \
  || bad "--update keeps the tracked-but-absent row (index count)" "rc=$RC row=$row out=$OUT"

# Sparse fail-open guard: a tracked-but-absent NEW offender still fails.
R="$TMP/sparse-offender"
mkdir -p "$R"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
mkfile huge.txt 40
git -C "$R" add -A
rm "$R/huge.txt"
run_sr
[ "$RC" -eq 1 ] && case "$OUT" in *"huge.txt"*) true ;; *) false ;; esac \
  && ok "a tracked-but-absent new offender is counted from the index and fails" \
  || bad "sparse new offender fails" "rc=$RC out=$OUT"

# --update with no baseline file: never creates one (it cannot add rows).
R="$TMP/upd2"
mkdir -p "$R"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
mkfile big.txt 20
git -C "$R" add -A
run_sr --update
[ "$RC" -eq 1 ] && [ ! -e "$R/tools/size-ratchet-baseline.tsv" ] && case "$OUT" in *"never adds rows"*) true ;; *) false ;; esac \
  && ok "--update without a baseline writes nothing and the new offender still fails" \
  || bad "--update without a baseline writes nothing" "rc=$RC out=$OUT"

echo "=== --update stages the replacement on the destination's own filesystem ==="
# The replacement used to be built under `mktemp -d` (i.e. TMPDIR, commonly a
# separate filesystem from the checkout), so the final `mv` could not rename and
# fell back to copy-then-remove — an interruption mid-copy left the tracked
# baseline truncated or missing, defeating the stated atomic-replace intent.
#
# Asserted by WHERE the staging file is created, not by running across a real
# device boundary: a cross-device run SUCCEEDS under both the old and the new
# code (mv's copy fallback is correct, just not atomic), so a success assertion
# would be vacuous for this bug. Same-directory staging is the property that
# makes the rename atomic, and it is directly observable.
MKTEMP_SHIM="$TMP/mktemp-shim"
mkdir -p "$MKTEMP_SHIM"
REAL_MKTEMP="$(command -v mktemp)"
MKTEMP_LOG="$TMP/mktemp-templates.log"
: >"$MKTEMP_LOG"
cat >"$MKTEMP_SHIM/mktemp" <<EOF
#!/usr/bin/env bash
# Record the template of every FILE mktemp (never the -d scratch dir), then
# defer to the real mktemp so the run behaves normally.
for arg in "\$@"; do
  [ "\$arg" = "-d" ] && exec "$REAL_MKTEMP" "\$@"
done
for arg in "\$@"; do
  case "\$arg" in
    -*) ;;
    *) printf '%s\n' "\$arg" >>"$MKTEMP_LOG" ;;
  esac
done
exec "$REAL_MKTEMP" "\$@"
EOF
chmod +x "$MKTEMP_SHIM/mktemp"

R="$TMP/staging"
mkdir -p "$R"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
mkfile loose.txt 15
mkdir -p "$R/tools"
printf 'loose.txt\t30\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A

OUT=""
RC=0
OUT="$(cd "$R" && umask 022 && PATH="$MKTEMP_SHIM:$PATH" SIZE_RATCHET_THRESHOLD=10 "$SR" --update 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && [ "$(cat "$R/tools/size-ratchet-baseline.tsv")" = "$(printf 'loose.txt\t15')" ] \
  && ok "control: the shimmed --update really tightened the baseline (30 -> 15)" \
  || bad "control: shimmed --update tightens" "rc=$RC out=$OUT"

# Vacuity anchor: an empty log would satisfy every "no template outside tools/"
# phrasing of the assertion below.
templates="$(cat "$MKTEMP_LOG")"
[ -n "$templates" ] \
  && ok "control: the mktemp shim recorded a file template, so the location assertion has something to read" \
  || bad "the mktemp shim recorded nothing" "log is empty"

# The property: every staging template sits in the baseline's OWN directory.
outside="$(printf '%s\n' "$templates" | grep -v '^tools/' || true)"
[ -z "$outside" ] \
  && ok "--update stages the replacement inside tools/, the baseline's own directory (rename is same-filesystem)" \
  || bad "--update stages outside the baseline's directory" "templates outside tools/: $outside"

# rename(2) carries the SOURCE's mode, and mktemp creates at 0600 — so the
# replaced baseline must not come back private.
mode="$(ls -l "$R/tools/size-ratchet-baseline.tsv" | cut -c1-10)"
[ "$mode" = "-rw-r--r--" ] \
  && ok "the replaced baseline keeps the umask-implied mode (0644), not mktemp's 0600" \
  || bad "the replaced baseline's mode" "got $mode, want -rw-r--r--"

# Globbed, not `ls | grep`: the staging file is a DOTFILE, so the dot glob is
# load-bearing — a plain `*` would report "clean" while debris sat right there.
leftovers=""
for entry in "$R"/tools/* "$R"/tools/.*; do
  [ -e "$entry" ] || continue # unmatched glob expands to itself
  base="${entry##*/}"
  case "$base" in
    "." | ".." | "size-ratchet-baseline.tsv") continue ;;
  esac
  leftovers="${leftovers:+$leftovers }$base"
done
[ -z "$leftovers" ] \
  && ok "no staging debris is left beside the baseline" \
  || bad "no staging debris is left beside the baseline" "$leftovers"

echo "=== the staging chmod survives BSD/macOS option parsing ==="
# BSD chmod parses options with getopt(3), which stops at the first non-option
# argument — the mode — so `chmod 644 -- FILE` reads `--` as a literal filename
# and fails on the nonexistent file `--`, aborting every --update on macOS. GNU
# chmod permutes and accepts either order, so a Linux-only run cannot see it.
# BSD chmod is not available on this runner, so the RULE is modelled in a shim
# rather than the binary: options are honoured only until the first operand.
CHMOD_SHIM="$TMP/chmod-shim"
mkdir -p "$CHMOD_SHIM"
REAL_CHMOD="$(command -v chmod)"
cat >"$CHMOD_SHIM/chmod" <<EOF
#!/usr/bin/env bash
args=()
seen_operand=0
for arg in "\$@"; do
  if [ "\$seen_operand" -eq 0 ]; then
    case "\$arg" in
      --) seen_operand=1; continue ;; # end-of-options, consumed
      -*) args+=("\$arg"); continue ;; # an option
      *) seen_operand=1 ;;             # the mode: BSD stops scanning here
    esac
  fi
  if [ "\$arg" = "--" ]; then
    echo "chmod: --: No such file or directory" >&2
    exit 1
  fi
  args+=("\$arg")
done
exec "$REAL_CHMOD" "\${args[@]}"
EOF
chmod +x "$CHMOD_SHIM/chmod"

# The shim proven in the FAILING direction first, on a real file: without this
# the shim could be a pass-through and the case below would prove nothing.
probe="$TMP/chmod-probe"
: >"$probe"
if "$CHMOD_SHIM/chmod" 644 -- "$probe" 2>/dev/null; then
  bad "the BSD chmod shim models the option-parsing rule" "trailing -- was accepted; the shim is inert"
else
  ok "control: the BSD chmod shim rejects 'chmod MODE -- FILE', the form macOS breaks on"
fi
"$CHMOD_SHIM/chmod" -- 644 "$probe" 2>/dev/null \
  && ok "control: the same shim accepts 'chmod -- MODE FILE', so it is not rejecting everything" \
  || bad "the BSD chmod shim accepts the leading -- form" "the shim rejects the correct form too"

R="$TMP/bsd-chmod"
mkdir -p "$R"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
mkfile loose.txt 15
mkdir -p "$R/tools"
printf 'loose.txt\t30\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A

OUT=""
RC=0
OUT="$(cd "$R" && umask 022 && PATH="$CHMOD_SHIM:$PATH" SIZE_RATCHET_THRESHOLD=10 "$SR" --update 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && [ "$(cat "$R/tools/size-ratchet-baseline.tsv")" = "$(printf 'loose.txt\t15')" ] \
  && ok "--update completes under BSD chmod option parsing (the mode's -- comes first)" \
  || bad "--update completes under BSD chmod option parsing" "rc=$RC out=$OUT"

echo "=== the baseline policy never measures itself ==="
R="$TMP/self-row-update"
mkdir -p "$R/tools"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
mkfile shrunk.txt 1
printf 'shrunk.txt\t50\ntools/size-ratchet-baseline.tsv\t2\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
OUT=""; RC=0
OUT="$(cd "$R" && SIZE_RATCHET_THRESHOLD=1 "$SR" --update 2>&1)" || RC=$?
OUT2=""; RC2=0
OUT2="$(cd "$R" && SIZE_RATCHET_THRESHOLD=1 "$SR" 2>&1)" || RC2=$?
[ "$RC" -eq 0 ] && [ "$RC2" -eq 0 ] && [ ! -s "$R/tools/size-ratchet-baseline.tsv" ] \
  && ok "--update drops a self row and its immediate plain check passes" \
  || bad "--update drops the self row in one run" "update=$RC check=$RC2 baseline=$(cat "$R/tools/size-ratchet-baseline.tsv") out=$OUT2"

R="$TMP/self-row-staged"
mkdir -p "$R/tools"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
mkfile limited.txt 5
printf 'limited.txt\t5\ntools/size-ratchet-baseline.tsv\t2\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
git -C "$R" commit -q -m baseline
mkfile limited.txt 1
git -C "$R" add limited.txt
OUT=""; RC=0
OUT="$(cd "$R" && SIZE_RATCHET_THRESHOLD=1 "$SR" --staged 2>&1)" || RC=$?
FIRST_BASELINE="$(cat "$R/tools/size-ratchet-baseline.tsv")"
OUT2=""; RC2=0
OUT2="$(cd "$R" && SIZE_RATCHET_THRESHOLD=1 "$SR" --staged 2>&1)" || RC2=$?
[ "$RC" -eq 0 ] && [ -z "$FIRST_BASELINE" ] && [ "$RC2" -eq 0 ] && [ ! -s "$R/tools/size-ratchet-baseline.tsv" ] \
  && ok "--staged drops a self row and its immediate staged check passes" \
  || bad "--staged drops the self row in one run" "first=$RC second=$RC2 baseline=$(cat "$R/tools/size-ratchet-baseline.tsv") out=$OUT2"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
