#!/usr/bin/env bash
# lib/atomic-install.sh: gg_install_file replaces a policy file by a rename
# inside its own directory, or not at all. One table over the destination's
# shape (existing with a mode, absent, read-only, a symlink) and each step a
# stub can fail (stat, chmod, mv, no scratch directory): a row reads back the
# exit status and every line printed, then the destination's content and
# mode and the staging files left beside it. The planted staging symlink is
# the one scripted control below the table: it needs a writer that publishes
# its pid before it stages.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
SCRIPTS="$SKILL_DIR/scripts"
COMMON="$SCRIPTS/lib/common.sh"
INSTALL="$SCRIPTS/lib/atomic-install.sh"
ROOT="$TMP"

PASS=0
FAIL=0
assert_eq() { # LABEL EXPECT ACTUAL
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"
  fi
}
filemode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# A failing stub ahead of PATH for one step; each names itself on stderr so a
# diagnostic that folds it in is read back with what it said.
stub() { # NAME [MESSAGE]
  mkdir -p "$ROOT/no$1"
  printf '#!/bin/sh\n%s\nexit 1\n' "${2:+echo \"$2\" >&2}" >"$ROOT/no$1/$1"
  chmod +x "$ROOT/no$1/$1"
}
stub stat
stub chmod "chmod: refused by the test stub"
stub mv

printf 'REPLACEMENT\n' >"$ROOT/src.tsv"
mkdir -p "$ROOT/outside"

# A fresh fixture directory holding tools/dest.tsv as the row asks: a file
# with a mode, a symlink to a file outside the tree, or nothing.
fx() { # NAME SHAPE
  R="$ROOT/$1"
  mkdir -p "$R/tools"
  case "$2" in
    absent) ;;
    link)
      printf 'BEHIND THE LINK\n' >"$ROOT/outside/$1.tsv"
      chmod 644 "$ROOT/outside/$1.tsv"
      ln -s "$ROOT/outside/$1.tsv" "$R/tools/dest.tsv"
      ;;
    *)
      printf 'ORIGINAL\n' >"$R/tools/dest.tsv"
      chmod "$2" "$R/tools/dest.tsv"
      ;;
  esac
}

# One line for an install: the exit status and every printed line, then the
# destination's content and mode (`-` when absent, the link's target content
# beside it for a symlink fixture) and the count of staging files left in its
# directory.
install_line() { # SHIM-DIR ARM — ARM is `tmpdir` (gg_tmpdir first) or `bare`
  local rc=0 out dest="$R/tools/dest.tsv" content="-" mode="-" target=""
  out="$(cd "$R" && PATH="${1:+$1:}$PATH" GG_CHECK=probe bash -c '
    set -euo pipefail
    . "$1"
    . "$2"
    [ "$3" = bare ] || gg_tmpdir
    gg_install_file "$4" tools/dest.tsv "the fixture"
  ' _ "$COMMON" "$INSTALL" "$2" "$ROOT/src.tsv" 2>&1)" || rc=$?
  out="${out//"$ROOT"/<root>}"
  if [ -e "$dest" ]; then
    content="$(cat "$dest")"
    mode="$(filemode "$dest")"
  fi
  [ ! -L "$dest" ] || target=" link-target=$(cat "$ROOT/outside/${R##*/}.tsv")"
  [ -e "$ROOT/outside/${R##*/}.tsv" ] && [ ! -L "$dest" ] && target=" former-target=$(cat "$ROOT/outside/${R##*/}.tsv")"
  printf 'rc=%s%s dest=%s mode=%s%s staged=%s' "$rc" "${out:+ $(printf '%s\n' "$out" | paste -sd ';' -)}" "$content" "$mode" "$target" "$(find "$R/tools" -name '*gg-install*' | wc -l | tr -d ' ')"
}

echo "=== gg_install_file ==="
# label | fixture shape | shim | arm | expect
rows=(
  "an existing destination is replaced and keeps its own mode|644||tmpdir|rc=0 dest=REPLACEMENT mode=644 staged=0"
  "a mode neither the staging default nor the umask gives is kept too|755||tmpdir|rc=0 dest=REPLACEMENT mode=755 staged=0"
  "a destination without owner-write is replaced and keeps its read-only mode|444||tmpdir|rc=0 dest=REPLACEMENT mode=444 staged=0"
  "a destination that does not exist yet lands with the staging file's owner-only mode|absent||tmpdir|rc=0 dest=REPLACEMENT mode=600 staged=0"
  "a symlink destination is replaced by a file with the mode of the file behind it; the file behind it is untouched|link||tmpdir|rc=0 dest=REPLACEMENT mode=644 former-target=BEHIND THE LINK staged=0"
  "an unreadable mode is a loud refusal, the destination untouched|644|$ROOT/nostat|tmpdir|rc=2 ::error::probe: could not read the mode of tools/dest.tsv — the fixture was not replaced dest=ORIGINAL mode=644 staged=0"
  "no scratch directory is a refusal before anything is staged|644||bare|rc=2 ::error::probe: gg_install_file needs gg_tmpdir called first — the fixture was not replaced dest=ORIGINAL mode=644 staged=0"
  "a failed chmod names the mode it could not give and what chmod said, the destination untouched|644|$ROOT/nochmod|tmpdir|rc=2 ::error::probe: could not give the replacement for the fixture tools/dest.tsv's mode (644) (chmod: refused by the test stub) dest=ORIGINAL mode=644 staged=0"
  "a failed rename is a loud collection error, the destination byte-identical|644|$ROOT/nomv|tmpdir|rc=2 ::error::probe: could not replace the fixture at tools/dest.tsv — inspect the file before trusting it dest=ORIGINAL mode=644 staged=0"
)
i=0
for row in "${rows[@]}"; do
  IFS='|' read -r label shape shim arm expect <<<"$row"
  i=$((i + 1))
  fx "install-$i" "$shape"
  assert_eq "$label" "$expect" "$(install_line "$shim" "$arm")"
done

echo "=== a planted staging symlink does not redirect the write ==="
# cp writes THROUGH a symlink, so a staging name the repository can predict is
# an arbitrary-file overwrite waiting for the next --update. The writer
# publishes its own pid and waits, so the symlink is planted at the EXACT name
# a pid-derived scheme would choose: the control is aimed, not a guess.
fx install-symlink 644
printf 'VICTIM\n' >"$ROOT/victim.txt"
pidfile="$ROOT/writer.pid"
gofile="$ROOT/writer.go"
(
  cd "$R" && GG_CHECK=probe bash -c '
    set -euo pipefail
    echo "$$" >"$3"
    i=0
    while [ ! -e "$4" ] && [ "$i" -lt 200 ]; do i=$((i + 1)); sleep 0.05; done
    . "$1"
    . "$2"
    gg_tmpdir
    gg_install_file "$5" tools/dest.tsv "the fixture"
  ' _ "$COMMON" "$INSTALL" "$pidfile" "$gofile" "$ROOT/src.tsv"
) >"$ROOT/writer.out" 2>&1 &
writer=$!
i=0
while [ ! -s "$pidfile" ] && [ "$i" -lt 200 ]; do i=$((i + 1)); sleep 0.05; done
assert_eq "the control is aimed at the pid the writer actually uses" "published" "$([ -s "$pidfile" ] && echo published || echo none)"
ln -s "$ROOT/victim.txt" "$R/tools/.gg-install.$(cat "$pidfile").dest.tsv"
: >"$gofile"
wait "$writer" || true
rm -f "$R/tools/.gg-install.$(cat "$pidfile").dest.tsv"
assert_eq "the victim is untouched, the install lands on its real destination, and no staging file is left" \
  "victim=VICTIM dest=REPLACEMENT staged=0 out=" \
  "victim=$(cat "$ROOT/victim.txt") dest=$(cat "$R/tools/dest.tsv") staged=$(find "$R/tools" -name '*gg-install*' | wc -l | tr -d ' ') out=$(cat "$ROOT/writer.out")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
