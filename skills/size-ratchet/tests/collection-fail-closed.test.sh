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
# count, and the worktree read guard (wc failure). Worktree counts are
# collected in batched wc invocations, so the batch's own integrity is
# pinned too: every file across several batches keeps its own count, and a
# file that cannot be measured still fails loud by name rather than
# vanishing into a partial batch.
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
unset SIZE_RATCHET_THRESHOLD SIZE_RATCHET_CLASSES SIZE_RATCHET_DEFAULT_CLASSES SIZE_RATCHET_FROZEN_CLASSES SIZE_RATCHET_BASELINE SIZE_RATCHET_EXCLUDES SIZE_RATCHET_SETTINGS_FILE RATCHET_RAISE 2>/dev/null || true
# The shipped class list and frozen list are policy, pinned by
# shipped-defaults.test.sh. Every fixture here declares its own thresholds,
# so both start empty and a case that needs one sets it.
export SIZE_RATCHET_DEFAULT_CLASSES="" SIZE_RATCHET_FROZEN_CLASSES=""

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

REAL_GIT="$(command -v git)"
REAL_GREP="$(command -v grep)"
REAL_WC="$(command -v wc)"
REAL_AWK="$(command -v awk)"
REAL_MV="$(command -v mv)"
REAL_CP="$(command -v cp)"

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

# grep shim: fail any bare `-c` invocation (the engine's line counts), pass
# the rest through to the real grep. The fixtures below carry no settings
# file, so the settings library's own bare-`-c` ambiguity count is never
# reached under this shim.
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

# wc shim: succeed while printing nothing. The batch invocation then comes
# back empty (a shortfall, not a measurement) and each single-file re-read
# yields no count at all — an empty count arithmetically evaluates to 0,
# which would file every tracked file as a 0-line file and pass.
WC_EMPTY_SHIM="$TMP/wc-empty-shim"
mkdir -p "$WC_EMPTY_SHIM"
cat >"$WC_EMPTY_SHIM/wc" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$WC_EMPTY_SHIM/wc"

# wc shim: on a multi-file invocation drop the LAST file's row while still
# printing the summary row and exiting 0 — the shape in which the summary
# slides into the final input's slot. Single-file reads pass through, so
# the per-file re-measurement still works.
WC_DROPLAST_SHIM="$TMP/wc-droplast-shim"
mkdir -p "$WC_DROPLAST_SHIM"
cat >"$WC_DROPLAST_SHIM/wc" <<EOF
#!/usr/bin/env bash
files=0
seen_sep=0
for a in "\$@"; do
  if [ "\$seen_sep" = 1 ]; then
    files=\$((files + 1))
    continue
  fi
  if [ "\$a" = "--" ]; then seen_sep=1; fi
done
if [ "\$files" -gt 1 ]; then
  "$REAL_WC" "\$@" | "$REAL_AWK" '{ a[NR] = \$0 } END { for (i = 1; i <= NR; i++) if (i != NR - 1) print a[i] }'
  exit 0
fi
exec "$REAL_WC" "\$@"
EOF
chmod +x "$WC_DROPLAST_SHIM/wc"

# mv shim: fail only the replace onto the repo baseline (relative path is
# an argument verbatim); the engine's internal \$TMP moves pass through.
MV_SHIM="$TMP/mv-shim"
mkdir -p "$MV_SHIM"
cat >"$MV_SHIM/mv" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "tools/size-ratchet-baseline.tsv" ]; then
    echo "mv: simulated replace failure" >&2
    exit 1
  fi
done
exec "$REAL_MV" "\$@"
EOF
chmod +x "$MV_SHIM/mv"

# cp shim: the engine cp's the baseline twice per --update run (initial
# load, then the post-replace re-read); fail the second — the re-read
# after a successful mv. Reset $TMP/cp-calls before each run.
CP_SHIM="$TMP/cp-shim"
mkdir -p "$CP_SHIM"
cat >"$CP_SHIM/cp" <<EOF
#!/usr/bin/env bash
hit=0
for a in "\$@"; do
  [ "\$a" = "tools/size-ratchet-baseline.tsv" ] && hit=1
done
if [ "\$hit" = 1 ]; then
  n="\$(cat "$TMP/cp-calls" 2>/dev/null)" || n=0
  n=\$((n + 1))
  printf '%s\n' "\$n" >"$TMP/cp-calls"
  if [ "\$n" -ge 2 ]; then
    echo "cp: simulated re-read failure" >&2
    exit 1
  fi
fi
exec "$REAL_CP" "\$@"
EOF
chmod +x "$CP_SHIM/cp"

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

echo "=== fail-closed: a failed baseline replace exits 2 with the mv-side diagnostic ==="
new_repo updmv
mkfile big.txt 15
mkdir -p "$R/tools"
printf 'big.txt\t20\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_sr_shimmed "$MV_SHIM" --update
[ "$RC" -eq 2 ] && case "$OUT" in *"could not replace tools/size-ratchet-baseline.tsv"*) true ;; *) false ;; esac \
  && ok "a failed replace is a collection error: exit 2, never mv's raw status" \
  || bad "a failed replace is a collection error, exit 2" "rc=$RC out=$OUT"
case "$OUT" in *"mv: simulated replace failure"*) ok "mv's own stderr is surfaced, pinning the cause" ;; *) bad "mv's own stderr is surfaced" "$OUT" ;; esac
row="$(cat "$R/tools/size-ratchet-baseline.tsv")"
[ "$row" = "$(printf 'big.txt\t20')" ] && ok "the failed replace leaves the original loose row byte-identical" \
  || bad "the failed replace leaves the original loose row byte-identical" "row=$row"
run_sr --update
[ "$RC" -eq 0 ] && [ "$(cat "$R/tools/size-ratchet-baseline.tsv")" = "$(printf 'big.txt\t15')" ] \
  && ok "shim-free control: the mv fixture really tightens 20 -> 15" \
  || bad "shim-free control: the mv fixture really tightens 20 -> 15" "rc=$RC out=$OUT"

echo "=== fail-closed: a failed post-replace re-read exits 2 and says the baseline WAS replaced ==="
new_repo updcp
mkfile big.txt 15
mkdir -p "$R/tools"
printf 'big.txt\t20\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
rm -f "$TMP/cp-calls"
run_sr_shimmed "$CP_SHIM" --update
[ "$RC" -eq 2 ] && case "$OUT" in *"could not re-read tools/size-ratchet-baseline.tsv"*"baseline WAS replaced"*) true ;; *) false ;; esac \
  && ok "a failed re-read after a successful replace is a collection error whose diagnostic owns the mutation" \
  || bad "a failed re-read after a successful replace is a collection error owning the mutation" "rc=$RC out=$OUT"
row="$(cat "$R/tools/size-ratchet-baseline.tsv")"
[ "$row" = "$(printf 'big.txt\t15')" ] && ok "the diagnostic is honest: the on-disk baseline really was tightened to 15" \
  || bad "the diagnostic is honest: the on-disk baseline really was tightened to 15" "row=$row"

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

echo "=== fail-closed: a wc that succeeds without printing a count is not a measurement ==="
new_repo wcempty
mkfile small.txt 5
git -C "$R" add -A
run_sr
[ "$RC" -eq 0 ] && ok "shim-free control: the materialized repo passes" \
  || bad "shim-free control: the materialized repo passes" "rc=$RC out=$OUT"
run_sr_shimmed "$WC_EMPTY_SHIM"
[ "$RC" -eq 2 ] && case "$OUT" in *"line count for tracked file 'small.txt' came back as ''"*) true ;; *) false ;; esac \
  && ok "an empty count is a collection error naming the file, never arithmetic zero" \
  || bad "an empty count is a collection error naming the file" "rc=$RC out=$OUT"
case "$OUT" in *"size-ratchet: OK"*) bad "no OK verdict may accompany an empty count" "$OUT" ;; *) ok "no OK verdict accompanies the empty count" ;; esac

echo "=== batching: the summary row is never read as a file's count ==="
# A tracked file named exactly like the summary row wc appends, positioned
# last in its batch: the one arrangement in which a lost final row lands
# the batch SUM (12) in that file's slot and reports it as an offender.
new_repo wctotal
mkfile a.txt 8
mkfile total 4
git -C "$R" add -A
run_sr
[ "$RC" -eq 0 ] && case "$OUT" in *"OK — 2 tracked file(s) checked"*) true ;; *) false ;; esac \
  && ok "shim-free control: both files pass at threshold 10" \
  || bad "shim-free control: both files pass at threshold 10" "rc=$RC out=$OUT"
run_sr_shimmed "$WC_DROPLAST_SHIM"
[ "$RC" -eq 0 ] && case "$OUT" in *"OK — 2 tracked file(s) checked"*) true ;; *) false ;; esac \
  && ok "a batch missing its last row is re-measured per file, never completed with the summary" \
  || bad "a batch missing its last row is re-measured per file" "rc=$RC out=$OUT"
case "$OUT" in
  *"new offender: total"*) bad "the batch sum must never become the count of the file named total" "$OUT" ;;
  *) ok "the batch sum never becomes the count of the file named total" ;;
esac

echo "=== batching: every file in every batch keeps its own count ==="
# The fixture holds more files than one batch carries, so the collection
# spans several wc invocations: a lost batch, a dropped row or positional
# drift shows up as a wrong count, a missing offender or a refusal. Names
# chosen to sit either side of the boundary and to exercise the shapes that
# make positional parsing load-bearing — a path containing spaces, and a
# path spelled exactly like the summary row wc appends to every multi-file
# invocation.
new_repo batching
i=0
while [ "$i" -lt 300 ]; do
  mkfile "f$i.txt" 2
  i=$((i + 1))
done
mkfile "a file with spaces.txt" 13
mkfile "aa-offender.txt" 12
mkfile "total" 14
mkfile "zz-offender.txt" 11
git -C "$R" add -A
run_sr
[ "$RC" -eq 1 ] && ok "the multi-batch fixture reports violations" || bad "the multi-batch fixture reports violations" "rc=$RC out=$OUT"
for expect in "a file with spaces.txt — 13 lines" "aa-offender.txt — 12 lines" "total — 14 lines" "zz-offender.txt — 11 lines"; do
  case "$OUT" in
    *"new offender: $expect"*) ok "$expect is reported with its own count" ;;
    *) bad "$expect is reported with its own count" "out=$OUT" ;;
  esac
done
case "$OUT" in *"4 violation(s)"*) ok "exactly the four over-threshold files are violations" ;; *) bad "exactly four violations" "out=$OUT" ;; esac
OUT=""; RC=0
OUT="$(cd "$R" && SIZE_RATCHET_THRESHOLD=100 "$SR" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *"OK — 304 tracked file(s) checked"*) true ;; *) false ;; esac \
  && ok "all 304 tracked files are counted — no batch is skipped" \
  || bad "all 304 tracked files are counted" "rc=$RC out=$OUT"

echo "=== batching: one unreadable file fails loud by ITS name, not by batch ==="
if [ "$(id -u)" -eq 0 ]; then
  printf '  skip  unreadable-file pin needs a non-root reader (chmod 000 cannot deny root)\n'
else
  chmod 000 "$R/f7.txt"
  run_sr
  [ "$RC" -eq 2 ] && case "$OUT" in *"cannot read tracked file 'f7.txt'"*) true ;; *) false ;; esac \
    && ok "an unreadable file inside a batch is exit 2, diagnostic names f7.txt" \
    || bad "an unreadable file inside a batch names f7.txt" "rc=$RC out=$OUT"
  case "$OUT" in *"size-ratchet: OK"*) bad "no OK verdict may accompany an unreadable file" "$OUT" ;; *) ok "no OK verdict accompanies the unreadable file" ;; esac
  chmod 644 "$R/f7.txt"
  run_sr
  [ "$RC" -eq 1 ] && case "$OUT" in *"4 violation(s)"*) true ;; *) false ;; esac \
    && ok "control: the same file readable, the batch measures the fixture again" \
    || bad "control: the same file readable, the batch measures again" "rc=$RC out=$OUT"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
