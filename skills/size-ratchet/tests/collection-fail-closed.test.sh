#!/usr/bin/env bash
# Pins for fail-closed collection in scripts/size-ratchet: the gate must
# distinguish "measured and fine" from "could not measure" and refuse
# loudly on the latter. Two historic fail-opens are pinned here:
#   (1) an unreadable index blob was recorded as absent and skipped, so an
#       over-threshold unbaselined file passed as "OK — 0 checked";
#   (2) `grep -c … || true` on the violations count turned a grep
#       execution failure into an empty count and a passing verdict.
# Each shim scenario carries a shim-free control first, so a green run is
# evidence, not a check that cannot fail; the shim's own stderr text is
# asserted in the failing case to pin the cause to the shim.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
SR="$SKILL_DIR/scripts/size-ratchet"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Hermetic: a leaked setting would mask every case below.
unset SIZE_RATCHET_THRESHOLD SIZE_RATCHET_BASELINE SIZE_RATCHET_EXCLUDES SIZE_RATCHET_SETTINGS_FILE 2>/dev/null || true

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

REAL_GIT="$(command -v git)"
REAL_GREP="$(command -v grep)"

new_repo() { # NAME — fresh fixture repo in $R
  R="$TMP/$1"
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}

mkfile() { # PATH LINES — file of LINES lines under $R
  mkdir -p "$R/$(dirname "$1")"
  awk -v n="$2" 'BEGIN { for (i = 1; i <= n; i++) print "line " i }' >"$R/$1"
}

run_sr() { # [args...] — run in $R at threshold 10; sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && SIZE_RATCHET_THRESHOLD=10 "$SR" "$@" 2>&1)" || RC=$?
}

run_sr_shimmed() { # SHIMDIR [args...] — run_sr with SHIMDIR first on PATH
  local shimdir="$1"
  shift
  OUT=""
  RC=0
  OUT="$(cd "$R" && PATH="$shimdir:$PATH" SIZE_RATCHET_THRESHOLD=10 "$SR" "$@" 2>&1)" || RC=$?
}

# git shim: fail `git show :big.txt` (the index-blob read), pass everything
# else through to the real git.
GIT_SHIM="$TMP/git-shim"
mkdir -p "$GIT_SHIM"
cat >"$GIT_SHIM/git" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "show" ] && [ "\${2:-}" = ":big.txt" ]; then
  echo "fatal: simulated object read failure for big.txt" >&2
  exit 128
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$GIT_SHIM/git"

# grep shim: fail any bare `-c` invocation (the engine's line counts; the
# settings library only ever uses combined flags like -Ec), pass the rest
# through to the real grep.
GREP_SHIM="$TMP/grep-shim"
mkdir -p "$GREP_SHIM"
cat >"$GREP_SHIM/grep" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "-c" ]; then
    echo "grep: simulated execution failure" >&2
    exit 2
  fi
done
exec "$REAL_GREP" "\$@"
EOF
chmod +x "$GREP_SHIM/grep"

echo "=== control: tracked-but-absent over-threshold files are counted from the index ==="
new_repo blobfail
mkfile big.txt 11
mkfile ok.txt 3
git -C "$R" add -A
rm "$R/big.txt" # unstaged: the index still lists big.txt, blob readable
run_sr
[ "$RC" -eq 1 ] && case "$OUT" in *"new offender: big.txt — 11 lines > threshold 10"*) true ;; *) false ;; esac \
  && ok "shim-free control: the absent offender is counted from its readable blob and fails as NEW" \
  || bad "shim-free control: the absent offender is counted from its readable blob" "rc=$RC out=$OUT"

echo "=== fail-closed: an unreadable index blob terminates, never skips ==="
# Pre-fix behavior: git show's failure filed big.txt as absent and the gate
# printed "OK — 1 tracked file(s) checked" at exit 0.
run_sr_shimmed "$GIT_SHIM"
[ "$RC" -eq 2 ] && case "$OUT" in *"cannot read index blob for tracked file 'big.txt'"*) true ;; *) false ;; esac \
  && ok "an unreadable blob is a collection error: exit 2, diagnostic names big.txt" \
  || bad "an unreadable blob is a collection error naming the file" "rc=$RC out=$OUT"
case "$OUT" in *"simulated object read failure"*) ok "git's own stderr is surfaced, pinning the cause to the failed read" ;; *) bad "git's own stderr is surfaced" "$OUT" ;; esac
case "$OUT" in *"size-ratchet: OK"*) bad "no OK verdict may accompany a collection failure" "$OUT" ;; *) ok "no OK verdict accompanies the collection failure" ;; esac

echo "=== fail-closed: a baselined unreadable blob refuses --update, baseline untouched ==="
new_repo updfail
mkfile big.txt 15
mkdir -p "$R/tools"
printf 'big.txt\t15\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
rm "$R/big.txt"
run_sr_shimmed "$GIT_SHIM" --update
[ "$RC" -eq 2 ] && case "$OUT" in *"cannot read index blob for tracked file 'big.txt'"*) true ;; *) false ;; esac \
  && ok "--update on an unreadable blob refuses with exit 2, naming the file" \
  || bad "--update on an unreadable blob refuses" "rc=$RC out=$OUT"
row="$(cat "$R/tools/size-ratchet-baseline.tsv")"
[ "$row" = "$(printf 'big.txt\t15')" ] && ok "the baseline row survives the refused --update verbatim" \
  || bad "the baseline row survives the refused --update" "row=$row"

echo "=== control: a clean repo passes with the real grep ==="
new_repo grepfail
mkfile small.txt 5
git -C "$R" add -A
run_sr
[ "$RC" -eq 0 ] && case "$OUT" in *"size-ratchet: OK"*) true ;; *) false ;; esac \
  && ok "shim-free control: no violations passes" \
  || bad "shim-free control: no violations passes" "rc=$RC out=$OUT"

echo "=== fail-closed: a broken violations count terminates, never passes ==="
# Pre-fix behavior: `grep -c . || true` yielded an empty count, the numeric
# test was false, and the gate printed OK at exit 0.
run_sr_shimmed "$GREP_SHIM"
[ "$RC" -eq 2 ] && case "$OUT" in *"could not count lines"*) true ;; *) false ;; esac \
  && ok "a grep execution failure on the count is a collection error, exit 2" \
  || bad "a grep execution failure on the count is a collection error" "rc=$RC out=$OUT"
case "$OUT" in *"size-ratchet: OK"*) bad "no OK verdict may accompany a broken count" "$OUT" ;; *) ok "no OK verdict accompanies the broken count" ;; esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
