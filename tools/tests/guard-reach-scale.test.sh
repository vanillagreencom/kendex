#!/usr/bin/env bash
# tools/guard --suite-reach scans every file of a tree on each call, and
# tools/ci-job-set makes that call on every selection. One suite of
# SCALE_LINES lines, each spelling SCALE_NAMES_PER_LINE distinct path names,
# is answered inside a deadline the parent process holds. A scan that grows a
# file's kept text one line at a time, or its names one name at a time,
# misses it more than threefold: in an awk array element or a bash one under
# GNU Awk, and in an awk string under mawk and BWK awk. The scan as it stands
# answers in a few seconds under each of the three on the same host. The
# deadline is a coarse scale bound, not a latency figure. A second suite,
# four lines long, reads a changed doc on its last line before its echo, so
# its answer needs the whole joined text a doc query's prefilter reads; the
# long suite already carries the join's scale.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/lib/guard-world.sh"

SCALE_LINES=150000
SCALE_NAMES_PER_LINE=2
DEADLINE_SECONDS=20

# Runs ARGV in the world with stdin from CHANGED, stdout to OUT and stderr to
# ERR, and kills its whole process group past SECONDS: macOS ships no
# timeout(1), and the guard's awk and git children would outlive a kill of the
# guard alone. Exits with the command's status, or 124 past the deadline.
DEADLINE_PY='
import os, signal, subprocess, sys
limit, changed, out, err, *argv = sys.argv[1:]
with open(changed) as i, open(out, "w") as o, open(err, "w") as e:
    process = subprocess.Popen(argv, stdin=i, stdout=o, stderr=e, start_new_session=True)
    try:
        status = process.wait(timeout=float(limit))
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        sys.exit(124)
sys.exit(status if status >= 0 else 128 - status)
'

echo "=== --suite-reach answers a long suite inside the deadline ==="
# tool-a reaches a.test.sh, which runs it, and big.test.sh, whose last line
# before its echo spells it, so only a scan that read the whole long file
# answers both. guide.md reaches late.test.sh alone, whose last line before
# its echo reads it: big.test.sh would answer for tool-a whatever a doc
# query found in it. That read is the third of late.test.sh's four kept
# lines, past the middle, so a join that keeps only the first half of a
# file's kept lines drops it. The demo suite of the world reaches none, so an
# answer of the whole tree fails too.
mkdir -p "$R/skills/demo/references"
printf '# guide\n' >"$R/skills/demo/references/guide.md"
printf '#!/usr/bin/env bash\necho a\n' >"$R/skills/demo/scripts/tool-a"
printf '#!/usr/bin/env bash\n"$PWD/skills/demo/scripts/tool-a"\necho "pass: 1   fail: 0"\n' \
  >"$R/skills/demo/tests/a.test.sh"
awk -v lines="$SCALE_LINES" -v names="$SCALE_NAMES_PER_LINE" 'BEGIN {
  print "#!/usr/bin/env bash"
  for (n = 1; n <= lines; n++) {
    printf ":"
    for (k = 1; k <= names; k++) printf " /n%d-%d", k, n
    printf "\n"
  }
  print ": /tool-a"
  print "echo \"pass: 1   fail: 0\""
}' >"$R/skills/demo/tests/big.test.sh"
printf '%s\n' '#!/usr/bin/env bash' ': 1' ': 2' 'cat "$PWD/skills/demo/references/guide.md" >/dev/null' \
  'echo "pass: 1   fail: 0"' >"$R/skills/demo/tests/late.test.sh"
chmod +x "$R/skills/demo/scripts/tool-a" "$R/skills/demo/tests/a.test.sh" "$R/skills/demo/tests/big.test.sh" \
  "$R/skills/demo/tests/late.test.sh"
printf '%s\n' skills/demo/scripts/tool-a skills/demo/references/guide.md >"$TMP/changed"
WANT="$(printf '%s\n' skills/demo/tests/a.test.sh skills/demo/tests/big.test.sh skills/demo/tests/late.test.sh)"
RC=0
(cd "$R" && python3 -c "$DEADLINE_PY" "$DEADLINE_SECONDS" "$TMP/changed" "$TMP/reach-out" "$TMP/reach-err" \
  "$GUARD" --suite-reach) || RC=$?
REACH="$(cat "$TMP/reach-out")"
[ "$RC" -eq 0 ] && [ "$REACH" = "$WANT" ] \
  && ok "--suite-reach answers a $SCALE_LINES-line suite inside ${DEADLINE_SECONDS}s" \
  || bad "--suite-reach answers a $SCALE_LINES-line suite inside ${DEADLINE_SECONDS}s" \
    "rc=$RC reach=$REACH err=$(tail -n 5 "$TMP/reach-err")"

printf 'pass: %d fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
