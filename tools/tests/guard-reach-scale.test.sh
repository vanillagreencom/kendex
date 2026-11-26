#!/usr/bin/env bash
# tools/guard --suite-reach scans every file of a tree on each call, and
# tools/ci-job-set makes that call on every selection, so the scan's cost must
# stay linear in a file's length. One suite of SCALE_LINES lines, each spelling
# a distinct path name, is answered inside a deadline the parent process
# holds. A scan that copies its growing per-file state on each line or name
# takes over a minute there, and the linear scan about a second on the same
# host. The deadline is a coarse scale bound, not a latency figure.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/lib/guard-world.sh"

SCALE_LINES=150000
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
# tool-a reaches a.test.sh, which runs it. big.test.sh names every one of its
# paths once and never tool-a, so the exact answer also shows the long file
# was matched and left out.
printf '#!/usr/bin/env bash\necho a\n' >"$R/skills/demo/scripts/tool-a"
printf '#!/usr/bin/env bash\n"$PWD/skills/demo/scripts/tool-a"\necho "pass: 1   fail: 0"\n' \
  >"$R/skills/demo/tests/a.test.sh"
awk -v lines="$SCALE_LINES" 'BEGIN {
  print "#!/usr/bin/env bash"
  for (n = 1; n <= lines; n++) printf ": /fixture/n%d\n", n
  print "echo \"pass: 1   fail: 0\""
}' >"$R/skills/demo/tests/big.test.sh"
chmod +x "$R/skills/demo/scripts/tool-a" "$R/skills/demo/tests/a.test.sh" "$R/skills/demo/tests/big.test.sh"
printf '%s\n' skills/demo/scripts/tool-a >"$TMP/changed"
RC=0
(cd "$R" && python3 -c "$DEADLINE_PY" "$DEADLINE_SECONDS" "$TMP/changed" "$TMP/reach-out" "$TMP/reach-err" \
  "$GUARD" --suite-reach) || RC=$?
REACH="$(cat "$TMP/reach-out")"
[ "$RC" -eq 0 ] && [ "$REACH" = skills/demo/tests/a.test.sh ] \
  && ok "--suite-reach answers a $SCALE_LINES-line suite inside ${DEADLINE_SECONDS}s" \
  || bad "--suite-reach answers a $SCALE_LINES-line suite inside ${DEADLINE_SECONDS}s" \
    "rc=$RC reach=$REACH err=$(tail -n 5 "$TMP/reach-err")"

printf 'pass: %d fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
