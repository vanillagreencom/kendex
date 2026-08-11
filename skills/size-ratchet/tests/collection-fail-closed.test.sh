#!/usr/bin/env bash
# Pins for fail-closed collection in scripts/size-ratchet: the gate must
# distinguish "measured and fine" from "could not measure" and refuse
# loudly on the latter. Two historic fail-opens are pinned here:
#   (1) an unreadable index blob was recorded as absent and skipped, so an
#       over-threshold unbaselined file passed as "OK — 0 checked";
#   (2) `grep -c … || true` on the violations count turned a grep
#       execution failure into an empty count and a passing verdict.
# Every other guarded collection site is pinned the same way: the two
# baseline-hygiene validations (worktree + index copy), the --update row
# count, and the worktree read guard (wc failure).
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
REAL_WC="$(command -v wc)"

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

# grep shim: fail the `-nEv` invocations (baseline-hygiene validation),
# pass the rest through to the real grep.
GREP_NEV_SHIM="$TMP/grep-nev-shim"
mkdir -p "$GREP_NEV_SHIM"
cat >"$GREP_NEV_SHIM/grep" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "-nEv" ]; then
    echo "grep: simulated -nEv execution failure" >&2
    exit 2
  fi
done
exec "$REAL_GREP" "\$@"
EOF
chmod +x "$GREP_NEV_SHIM/grep"

# wc shim: unconditional failure — every line count breaks. PATH shimming
# beats mode-000 permissions, which are unreliable on privileged runners.
WC_SHIM="$TMP/wc-shim"
mkdir -p "$WC_SHIM"
cat >"$WC_SHIM/wc" <<'EOF'
#!/usr/bin/env bash
echo "wc: simulated read failure" >&2
exit 1
EOF
chmod +x "$WC_SHIM/wc"

# wc shim: pass the first two calls through (the collection loop's counts
# for the fixture's two tracked files), fail from the third on — which in
# --update is the recount of the candidate baseline. Exit 7 on purpose: a
# raw tool status escaping instead of the contract's exit 2 must be
# visible. Reset $TMP/wc-calls before each run.
WC_RECOUNT_SHIM="$TMP/wc-recount-shim"
mkdir -p "$WC_RECOUNT_SHIM"
cat >"$WC_RECOUNT_SHIM/wc" <<EOF
#!/usr/bin/env bash
n="\$(cat "$TMP/wc-calls" 2>/dev/null)" || n=0
n=\$((n + 1))
printf '%s\n' "\$n" >"$TMP/wc-calls"
if [ "\$n" -ge 3 ]; then
  echo "wc: simulated recount failure" >&2
  exit 7
fi
exec "$REAL_WC" "\$@"
EOF
chmod +x "$WC_RECOUNT_SHIM/wc"

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

echo "=== fail-closed: broken worktree-baseline validation terminates ==="
new_repo nevwt
mkfile big.txt 15
mkdir -p "$R/tools"
printf 'big.txt\t15\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_sr
[ "$RC" -eq 0 ] && ok "shim-free control: the baselined repo passes" \
  || bad "shim-free control: the baselined repo passes" "rc=$RC out=$OUT"
run_sr_shimmed "$GREP_NEV_SHIM"
[ "$RC" -eq 2 ] && case "$OUT" in *"could not validate tools/size-ratchet-baseline.tsv (grep exit 2)"*) true ;; *) false ;; esac \
  && ok "a grep failure validating the worktree baseline is a collection error, exit 2" \
  || bad "a grep failure validating the worktree baseline is a collection error" "rc=$RC out=$OUT"
case "$OUT" in *"size-ratchet: OK"*) bad "no OK verdict may accompany broken baseline validation" "$OUT" ;; *) ok "no OK verdict accompanies broken worktree-baseline validation" ;; esac

echo "=== fail-closed: broken index-baseline validation terminates ==="
rm "$R/tools/size-ratchet-baseline.tsv" # unstaged: baseline now index-only
run_sr
[ "$RC" -eq 0 ] && ok "shim-free control: the index-only baseline passes" \
  || bad "shim-free control: the index-only baseline passes" "rc=$RC out=$OUT"
run_sr_shimmed "$GREP_NEV_SHIM"
[ "$RC" -eq 2 ] && case "$OUT" in *"could not validate tools/size-ratchet-baseline.tsv (index copy) (grep exit 2)"*) true ;; *) false ;; esac \
  && ok "a grep failure validating the index baseline copy is a collection error, exit 2" \
  || bad "a grep failure validating the index baseline copy is a collection error" "rc=$RC out=$OUT"

echo "=== fail-closed: a broken --update row count aborts BEFORE the baseline is replaced ==="
# The fixture's rewrite is NOT a content no-op: the row (20) is loose for
# the 15-line file, so --update would tighten it to 15. An abort that
# happened after the mv would therefore show as mutated content here.
new_repo updcount
mkfile big.txt 15
mkdir -p "$R/tools"
printf 'big.txt\t20\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_sr_shimmed "$GREP_SHIM" --update
[ "$RC" -eq 2 ] && case "$OUT" in *"could not count lines"*) true ;; *) false ;; esac \
  && ok "a grep failure counting the candidate baseline's rows is a collection error, exit 2" \
  || bad "a grep failure counting the candidate baseline's rows is a collection error" "rc=$RC out=$OUT"
case "$OUT" in *"size-ratchet: OK"*) bad "no OK verdict may accompany a broken --update count" "$OUT" ;; *) ok "no OK verdict accompanies the broken --update count" ;; esac
row="$(cat "$R/tools/size-ratchet-baseline.tsv")"
[ "$row" = "$(printf 'big.txt\t20')" ] && ok "the aborted --update leaves the original loose row byte-identical" \
  || bad "the aborted --update leaves the original loose row byte-identical" "row=$row"
run_sr --update
[ "$RC" -eq 0 ] && [ "$(cat "$R/tools/size-ratchet-baseline.tsv")" = "$(printf 'big.txt\t15')" ] \
  && ok "shim-free control: the same fixture really tightens 20 -> 15, proving the abort case would detect a mutation" \
  || bad "shim-free control: the same fixture really tightens 20 -> 15" "rc=$RC row=$(cat "$R/tools/size-ratchet-baseline.tsv") out=$OUT"

echo "=== fail-closed: a broken post-update recount aborts BEFORE the replace, exit 2 not raw status ==="
# Same genuinely-tightening fixture (loose row 20 for a 15-line file). The
# recount of the baseline's own counts row now reads the candidate before
# the replace: a wc failure there must exit 2 per the collection-error
# contract — never wc's raw status 7 — with the original row intact.
new_repo updrecount
mkfile big.txt 15
mkdir -p "$R/tools"
printf 'big.txt\t20\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
rm -f "$TMP/wc-calls"
run_sr_shimmed "$WC_RECOUNT_SHIM" --update
[ "$RC" -eq 2 ] && case "$OUT" in *"could not recount the updated baseline tools/size-ratchet-baseline.tsv"*) true ;; *) false ;; esac \
  && ok "a wc failure on the recount is a collection error: exit 2 with the update-aborted diagnostic" \
  || bad "a wc failure on the recount is a collection error, exit 2 (never raw status 7)" "rc=$RC out=$OUT"
case "$OUT" in *"wc: simulated recount failure"*) ok "the shim fired on the recount call (3rd wc), pinning the cause" ;; *) bad "the shim fired on the recount call" "$OUT" ;; esac
row="$(cat "$R/tools/size-ratchet-baseline.tsv")"
[ "$row" = "$(printf 'big.txt\t20')" ] && ok "the aborted recount leaves the original loose row byte-identical" \
  || bad "the aborted recount leaves the original loose row byte-identical" "row=$row"
run_sr --update
[ "$RC" -eq 0 ] && [ "$(cat "$R/tools/size-ratchet-baseline.tsv")" = "$(printf 'big.txt\t15')" ] \
  && ok "shim-free control: the recount fixture really tightens 20 -> 15" \
  || bad "shim-free control: the recount fixture really tightens 20 -> 15" "rc=$RC out=$OUT"

echo "=== fail-closed: an unreadable worktree file terminates with its own diagnostic ==="
# Fully materialized repo: every count goes through the worktree `wc -l`
# path, so the failing wc exercises exactly the worktree read guard (the
# index-blob path also pipes through wc, but only for absent files).
new_repo wcfail
mkfile small.txt 5
git -C "$R" add -A
run_sr
[ "$RC" -eq 0 ] && ok "shim-free control: the materialized repo passes" \
  || bad "shim-free control: the materialized repo passes" "rc=$RC out=$OUT"
run_sr_shimmed "$WC_SHIM"
[ "$RC" -eq 2 ] && case "$OUT" in *"cannot read tracked file 'small.txt'"*) true ;; *) false ;; esac \
  && ok "an unreadable worktree file is a collection error: exit 2, diagnostic names small.txt" \
  || bad "an unreadable worktree file is a collection error naming the file" "rc=$RC out=$OUT"
case "$OUT" in *"size-ratchet: OK"*) bad "no OK verdict may accompany a worktree read failure" "$OUT" ;; *) ok "no OK verdict accompanies the worktree read failure" ;; esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
