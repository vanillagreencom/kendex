#!/usr/bin/env bash
# Pins for the collection sites whose failure used to escape as the failing
# tool's OWN status. The contract reserves exit 1 for "a size violation was
# measured" and exit 2 for "could not measure", so a broken environment
# leaving through `set -e` with status 1 told every caller the opposite of
# the truth: the gate reported a failing repository instead of a broken gate.
# Pinned here: the repository-root cd, the scratch-file writes, the working
# copy of the baseline, both sorts (check path and --update pipeline), the
# index-presence probe, and grep's option order.
#
# Every case is asserted at exit 2 SPECIFICALLY — nonzero would be satisfied
# by exactly the value being ruled out — and each carries a shim-free (or
# disarmed-shim) control first, so a green run is evidence rather than a
# check that cannot fail.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
SR="$SKILL_DIR/scripts/size-ratchet"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Hermetic: a leaked setting would mask every case below.
unset SIZE_RATCHET_THRESHOLD SIZE_RATCHET_CLASSES SIZE_RATCHET_BASELINE SIZE_RATCHET_EXCLUDES SIZE_RATCHET_SETTINGS_FILE 2>/dev/null || true

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

REAL_GIT="$(command -v git)"
REAL_GREP="$(command -v grep)"
REAL_SORT="$(command -v sort)"
REAL_CP="$(command -v cp)"
REAL_MKTEMP="$(command -v mktemp)"

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

run_sr() { # — plain check in $R at threshold 10; sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && SIZE_RATCHET_THRESHOLD=10 "$SR" 2>&1)" || RC=$?
}

run_sr_shimmed() { # SHIMDIR [args...] — run_sr with SHIMDIR first on PATH
  local shimdir="$1"
  shift
  OUT=""
  RC=0
  OUT="$(cd "$R" && PATH="$shimdir:$PATH" SIZE_RATCHET_THRESHOLD=10 "$SR" "$@" 2>&1)" || RC=$?
}

echo "=== the repository-root cd is a config error, never the violation code ==="
# `git rev-parse --show-toplevel` answering with a path the process cannot
# enter (a repository removed mid-run, a permission change) used to kill the
# script through set -e with cd's own status 1.
CD_SHIM="$TMP/cd-shim"
mkdir -p "$CD_SHIM"
cat >"$CD_SHIM/git" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "rev-parse" ] && [ "\${2:-}" = "--show-toplevel" ]; then
  printf '%s\n' "$TMP/no-such-repository-root"
  exit 0
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$CD_SHIM/git"

new_repo cdfail
mkfile small.txt 5
git -C "$R" add -A
run_sr
[ "$RC" -eq 0 ] && ok "shim-free control: the fixture passes, so a nonzero below is the shim" \
  || bad "shim-free control: the cd fixture passes" "rc=$RC out=$OUT"

run_sr_shimmed "$CD_SHIM"
[ "$RC" -eq 2 ] && case "$OUT" in *"could not enter the repository root"*) true ;; *) false ;; esac \
  && ok "an unenterable repository root exits 2 with its own diagnostic, not 1" \
  || bad "an unenterable repository root exits 2" "rc=$RC out=$OUT"

echo "=== scratch writes are exit 2, never the violation code ==="
# mktemp -d succeeding does not make the scratch dir usable. Injected through
# the filesystem rather than a permission bit so the cases hold for root as
# well (CI images differ): an unwritable location is one that does not exist,
# and an unwritable FILE is one that is really a directory.
BROKEN_TMP_SHIM="$TMP/broken-tmp-shim"
mkdir -p "$BROKEN_TMP_SHIM"
cat >"$BROKEN_TMP_SHIM/mktemp" <<EOF
#!/usr/bin/env bash
# Hand back a scratch path whose parent was never created: mktemp "succeeds",
# every subsequent write into it fails with ENOENT.
for arg in "\$@"; do
  if [ "\$arg" = "-d" ]; then
    printf '%s\n' "$TMP/never-created/scratch"
    exit 0
  fi
done
exec "$REAL_MKTEMP" "\$@"
EOF
chmod +x "$BROKEN_TMP_SHIM/mktemp"

new_repo brokentmp
mkfile small.txt 5
git -C "$R" add -A
run_sr
[ "$RC" -eq 0 ] && ok "shim-free control: the broken-scratch fixture passes" \
  || bad "shim-free control: the broken-scratch fixture passes" "rc=$RC out=$OUT"

# No baseline in this fixture, so the first scratch write is the empty-baseline
# initialization.
run_sr_shimmed "$BROKEN_TMP_SHIM"
[ "$RC" -eq 2 ] && case "$OUT" in *"could not initialize the empty baseline scratch file"*) true ;; *) false ;; esac \
  && ok "an unwritable scratch dir is exit 2 at the baseline init, not the violation code 1" \
  || bad "unwritable scratch dir is exit 2 at the baseline init" "rc=$RC out=$OUT"
case "$OUT" in
  *"violation"*) bad "an unwritable scratch dir must not read as a size violation" "$OUT" ;;
  *) ok "the broken-scratch diagnostic never claims a violation was measured" ;;
esac

# Same class, next site along: let the baseline write land but make counts.raw
# unwritable by pre-creating it as a DIRECTORY. This is the only way to reach
# the counts initialization independently — `: >` and `>>` share one file and
# one mode, so the per-file append guard cannot be injected separately from it.
COUNTS_SHIM="$TMP/counts-shim"
mkdir -p "$COUNTS_SHIM"
COUNTS_SCRATCH="$TMP/counts-scratch"
cat >"$COUNTS_SHIM/mktemp" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = "-d" ]; then
    rm -rf "$COUNTS_SCRATCH"
    mkdir -p "$COUNTS_SCRATCH/counts.raw" || exit 1
    printf '%s\n' "$COUNTS_SCRATCH"
    exit 0
  fi
done
exec "$REAL_MKTEMP" "\$@"
EOF
chmod +x "$COUNTS_SHIM/mktemp"

run_sr_shimmed "$COUNTS_SHIM"
[ "$RC" -eq 2 ] && case "$OUT" in *"could not initialize the counts scratch file"*) true ;; *) false ;; esac \
  && ok "an unwritable counts scratch file is exit 2 with its own diagnostic" \
  || bad "unwritable counts scratch file is exit 2" "rc=$RC out=$OUT"

echo "=== a failed working copy of the baseline is exit 2 ==="
# The baseline is copied into the scratch dir before anything reads it; that
# cp's failure used to leave through set -e with status 1.
CP_STAGE_SHIM="$TMP/cp-stage-shim"
mkdir -p "$CP_STAGE_SHIM"
cat >"$CP_STAGE_SHIM/cp" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "tools/size-ratchet-baseline.tsv" ]; then
    echo "cp: simulated staging failure" >&2
    exit 1
  fi
done
exec "$REAL_CP" "\$@"
EOF
chmod +x "$CP_STAGE_SHIM/cp"

new_repo cpstage
mkfile big.txt 15
mkdir -p "$R/tools"
printf 'big.txt\t15\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_sr
[ "$RC" -eq 0 ] && ok "shim-free control: the baselined fixture passes" \
  || bad "shim-free control: the baselined fixture passes" "rc=$RC out=$OUT"

run_sr_shimmed "$CP_STAGE_SHIM"
[ "$RC" -eq 2 ] && case "$OUT" in *"could not stage a working copy of tools/size-ratchet-baseline.tsv"*) true ;; *) false ;; esac \
  && ok "a failed baseline staging copy is exit 2 with its own diagnostic" \
  || bad "a failed baseline staging copy is exit 2" "rc=$RC out=$OUT"

echo "=== a failed sort is exit 2, in both the check and update paths ==="
# Two distinct sorts: the counts sort on the check path, and the awk-to-sort
# pipeline that builds the tightened baseline on the update path. The shim
# targets one at a time so each site is pinned by its own diagnostic.
SORT_SHIM="$TMP/sort-shim"
mkdir -p "$SORT_SHIM"
cat >"$SORT_SHIM/sort" <<EOF
#!/usr/bin/env bash
# \$SR_SORT_FAIL picks the invocation to break:
#   counts   — the one carrying the classified counts as its operand
#   pipeline — the --update awk|sort, identified by reading STDIN (no file
#              operand) and not being the -c hygiene check
has_operand=0
is_check=0
for arg in "\$@"; do
  case "\$arg" in
    -c) is_check=1 ;;
    -*) ;;
    *) has_operand=1 ;;
  esac
done
case "\${SR_SORT_FAIL:-}" in
  counts)
    for arg in "\$@"; do
      case "\$arg" in
        *counts.classed)
          echo "sort: simulated counts sort failure" >&2
          exit 2
          ;;
      esac
    done
    ;;
  pipeline)
    if [ "\$has_operand" -eq 0 ] && [ "\$is_check" -eq 0 ]; then
      echo "sort: simulated pipeline sort failure" >&2
      exit 2
    fi
    ;;
esac
exec "$REAL_SORT" "\$@"
EOF
chmod +x "$SORT_SHIM/sort"

run_sort_shimmed() { # WHICH [args...] — run_sr with the sort shim armed
  local which="$1"
  shift
  OUT=""
  RC=0
  OUT="$(cd "$R" && PATH="$SORT_SHIM:$PATH" SR_SORT_FAIL="$which" SIZE_RATCHET_THRESHOLD=10 "$SR" "$@" 2>&1)" || RC=$?
}

new_repo sortfail
mkfile big.txt 15
mkdir -p "$R/tools"
printf 'big.txt\t20\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A

# Control with the shim ON PATH but disarmed, so a green result below is the
# arming and not the shim merely being absent or inert.
run_sort_shimmed "" --update
[ "$RC" -eq 0 ] && ok "control: the disarmed sort shim passes the whole run through" \
  || bad "control: the disarmed sort shim passes through" "rc=$RC out=$OUT"

printf 'big.txt\t20\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_sort_shimmed counts
[ "$RC" -eq 2 ] && case "$OUT" in *"could not sort the collected counts"*) true ;; *) false ;; esac \
  && ok "a failed counts sort is a collection error: exit 2, measurement declared incomplete" \
  || bad "a failed counts sort is exit 2" "rc=$RC out=$OUT"
case "$OUT" in *"size-ratchet: OK"*) bad "no OK verdict may accompany a failed counts sort" "$OUT" ;; *) ok "no OK verdict accompanies the failed counts sort" ;; esac

run_sort_shimmed pipeline --update
[ "$RC" -eq 2 ] && case "$OUT" in *"could not build the tightened baseline"*"baseline unchanged"*) true ;; *) false ;; esac \
  && ok "a failed --update sort pipeline is exit 2 and says the baseline is unchanged" \
  || bad "a failed --update sort pipeline is exit 2" "rc=$RC out=$OUT"
row="$(cat "$R/tools/size-ratchet-baseline.tsv")"
[ "$row" = "$(printf 'big.txt\t20')" ] \
  && ok "the diagnostic is honest: the baseline really is byte-identical after the aborted update" \
  || bad "the baseline is unchanged after the aborted update" "row=$row"

echo "=== a broken index probe never reads as 'file absent' ==="
# The probe used to be `[ "$(git cat-file -t ":$FILE" 2>/dev/null)" = "blob" ]`.
# cat-file exits 128 for "not in the index" AND for a corrupt or unavailable
# object, so with its status discarded a broken read compared unequal to "blob"
# and fell through to "absent" — an EMPTY baseline (every frozen offender
# forgotten, a stale row silently gone) or ZERO exclusions. Fail-open, in the
# direction that loses violations.
#
# The shim fails the index QUERY the probe now depends on, with a status that is
# neither 0 nor git's "missing" 128, so nothing can mistake it for absence.
INDEX_PROBE_SHIM="$TMP/index-probe-shim"
mkdir -p "$INDEX_PROBE_SHIM"
cat >"$INDEX_PROBE_SHIM/git" <<EOF
#!/usr/bin/env bash
# Break only the single-path index probe (ls-files -s with a pathspec); the
# collection loop's own "ls-files -sz" listing and everything else pass through.
if [ "\${1:-}" = "ls-files" ] && [ "\${2:-}" = "-s" ]; then
  for arg in "\$@"; do
    case "\$arg" in
      *"\${SR_PROBE_TARGET:?SR_PROBE_TARGET must name the probe to break}"*)
        echo "fatal: simulated index query failure" >&2
        exit 71
        ;;
    esac
  done
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$INDEX_PROBE_SHIM/git"

run_probe_failing() { # PATH-SUBSTRING — run_sr with only that index probe broken
  OUT=""
  RC=0
  OUT="$(cd "$R" && PATH="$INDEX_PROBE_SHIM:$PATH" SR_PROBE_TARGET="$1" SIZE_RATCHET_THRESHOLD=10 "$SR" 2>&1)" || RC=$?
}

# --- the baseline probe: a tracked-but-absent baseline holding a STALE row ---
new_repo idxprobe-baseline
mkfile small.txt 3
# A row for a file now under the threshold: a real violation the gate must
# report. If the probe degrades to "absent", this row disappears and the run
# reports OK — the exact fail-open being pinned.
mkdir -p "$R/tools"
printf 'small.txt\t50\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
rm "$R/tools/size-ratchet-baseline.tsv" # tracked but not materialized

run_sr
[ "$RC" -eq 1 ] && case "$OUT" in *"stale baseline row: small.txt"*) true ;; *) false ;; esac \
  && ok "control: the index baseline is read and its stale row FAILS the run" \
  || bad "control: the index baseline's stale row fails the run" "rc=$RC out=$OUT"

run_probe_failing size-ratchet-baseline.tsv
[ "$RC" -eq 2 ] && case "$OUT" in *"could not query the index for tools/size-ratchet-baseline.tsv"*) true ;; *) false ;; esac \
  && ok "a broken baseline index probe is a collection error: exit 2, refusing to treat it as absent" \
  || bad "a broken baseline index probe is exit 2" "rc=$RC out=$OUT"
case "$OUT" in
  *"size-ratchet: OK"*) bad "a broken index probe must never report OK against an empty baseline" "$OUT" ;;
  *) ok "no OK verdict accompanies the broken baseline probe" ;;
esac

# --- the excludes probe: a tracked-but-absent list that exempts an offender ---
new_repo idxprobe-excludes
mkfile vendor/big.txt 40
mkdir -p "$R/tools"
printf 'vendor/*\tvendored\n' >"$R/tools/size-ratchet-excludes"
git -C "$R" add -A
rm "$R/tools/size-ratchet-excludes" # tracked but not materialized

run_sr
[ "$RC" -eq 0 ] && ok "control: the index exclusion list is read and exempts vendor/big.txt" \
  || bad "control: the index exclusion list exempts vendor/big.txt" "rc=$RC out=$OUT"

run_probe_failing size-ratchet-excludes
[ "$RC" -eq 2 ] && case "$OUT" in *"could not query the index for tools/size-ratchet-excludes"*) true ;; *) false ;; esac \
  && ok "a broken excludes index probe is a collection error: exit 2, never zero exclusions" \
  || bad "a broken excludes index probe is exit 2" "rc=$RC out=$OUT"
case "$OUT" in
  *"new offender: vendor/big.txt"*) bad "a broken excludes probe must not report the excluded path as an offender" "$OUT" ;;
  *) ok "no violation is reported against the path the unreadable list exempts" ;;
esac

echo "=== every grep call site survives non-permuting (BSD/POSIX) option parsing ==="
# Option scanning stops at the first non-option argument, which for grep is the
# PATTERN — so `grep -c . -- FILE` reads `--` as a literal filename on any
# non-permuting grep and fails on a clean repo, tripping collection_error
# universally. GNU greps permute and accept it, so a Linux-only run cannot see
# it. A CLASS guard, not a site guard: the shim is on PATH for the whole run, so
# it covers every grep in the script AND in lib/settings.sh at once.
GREP_ORDER_SHIM="$TMP/grep-order-shim"
mkdir -p "$GREP_ORDER_SHIM"
cat >"$GREP_ORDER_SHIM/grep" <<EOF
#!/usr/bin/env bash
args=()
seen_operand=0
for arg in "\$@"; do
  if [ "\$seen_operand" -eq 0 ]; then
    case "\$arg" in
      # An end-of-options marker seen while still scanning options IS the
      # terminator. Kept in the forwarded args so the real grep keeps its
      # protection. (No backticks in this heredoc: it is unquoted for the
      # REAL_GREP interpolation, so backticks would run as command substitution.)
      --) seen_operand=1; args+=("\$arg"); continue ;;
      -*) args+=("\$arg"); continue ;;
      *) seen_operand=1 ;; # the pattern: scanning stops here
    esac
  fi
  if [ "\$arg" = "--" ]; then
    echo "grep: --: No such file or directory" >&2
    exit 2
  fi
  args+=("\$arg")
done
exec "$REAL_GREP" "\${args[@]}"
EOF
chmod +x "$GREP_ORDER_SHIM/grep"

# The shim proven in BOTH directions on a real file first, or a green run below
# would only mean the shim is a pass-through.
gprobe="$TMP/grep-order-probe"
printf 'a\n' >"$gprobe"
if "$GREP_ORDER_SHIM/grep" -c . -- "$gprobe" >/dev/null 2>&1; then
  bad "the BSD grep shim models the option-parsing rule" "trailing -- was accepted; the shim is inert"
else
  ok "control: the BSD grep shim rejects 'grep -c . -- FILE', the form that breaks on macOS"
fi
"$GREP_ORDER_SHIM/grep" -c -- . "$gprobe" >/dev/null 2>&1 \
  && ok "control: the same shim accepts 'grep -c -- . FILE', so it is not rejecting everything" \
  || bad "the BSD grep shim accepts the leading -- form" "the shim rejects the correct form too"

# A fixture that drives BOTH shapes: count_nonempty_lines (the violations
# count) and the baseline-row validation, worktree copy.
new_repo greporder
mkfile big.txt 15
mkdir -p "$R/tools"
printf 'big.txt\t15\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_sr
[ "$RC" -eq 0 ] && ok "shim-free control: the grep-order fixture passes" \
  || bad "shim-free control: the grep-order fixture passes" "rc=$RC out=$OUT"

run_sr_shimmed "$GREP_ORDER_SHIM"
[ "$RC" -eq 0 ] && case "$OUT" in *"size-ratchet: OK"*) true ;; *) false ;; esac \
  && ok "the whole run is clean under non-permuting grep option parsing" \
  || bad "the run is clean under non-permuting grep option parsing" "rc=$RC out=$OUT"

# And the index-copy validation path, which is a separate call site.
rm "$R/tools/size-ratchet-baseline.tsv" # tracked but absent: read from the index
run_sr_shimmed "$GREP_ORDER_SHIM"
[ "$RC" -eq 0 ] \
  && ok "the index-copy baseline validation also survives non-permuting grep" \
  || bad "the index-copy baseline validation survives non-permuting grep" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
