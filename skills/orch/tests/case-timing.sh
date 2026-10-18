#!/usr/bin/env bash
# bash-runtime: 3.2
# Surface: shared assertion timing and run-all case reports.
# Inputs: lib/assertions.sh, run-all.sh, scripts/lib/lane-process.sh.
# The job-log reading consumes the case records as a machine-readable format.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${CASE_TIMING_LIB:-$TEST_DIR/lib/assertions.sh}"
TMP_ROOT="$(mktemp -d)" || { echo 'case-timing: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'case-timing: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'case-timing: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
PASS=0
FAIL=0
check() { # STATUS NAME
  if [ "$1" -eq 0 ]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$2"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$2"
  fi
}

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/battery"
cat > "$TMP_ROOT/bin/date" <<'CLOCK'
#!/usr/bin/env bash
set -euo pipefail
IFS= read -r now < "$TIMING_CLOCK"
printf '%s\n' "$now"
CLOCK
chmod +x "$TMP_ROOT/bin/date"
cat > "$TMP_ROOT/battery/timed&row.sh" <<'SUITE'
#!/usr/bin/env bash
set -euo pipefail
printf '100\n' > "$TIMING_CLOCK"
source "$TIMING_LIB"
pass fast
# Later PATH clock fixtures must not replace the helper's resolved clock.
date() { printf '999\n'; }
printf '101\n' > "$TIMING_CLOCK"
pass 'slow pass'
printf '103\n' > "$TIMING_CLOCK"
fail 'slow fail' detail
pass 'same operation'
printf 'pass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
SUITE
export TIMING_CLOCK="$TMP_ROOT/clock" TIMING_LIB="$LIB"
records_match() { # OUTPUT SUITE-FIELD
  local records
  records="$(sed -n '/^case /p' <<<"$1")" || return 1
  [ "$records" = "case ${2}seconds=1 result=ok name=slow pass
case ${2}seconds=2 result=FAIL name=slow fail" ]
}

PATH="$TMP_ROOT/bin:$PATH" "$BASH" "$TMP_ROOT/battery/timed&row.sh" > "$TMP_ROOT/direct.out" 2>&1 && rc=0 || rc=$?
out="$(cat "$TMP_ROOT/direct.out")"
records_match "$out" '' && status=0 || status=$?
check "$status" 'threshold and reset produce exact pass and failure seconds'
[[ "$rc" -eq 1 && "$out" == *'pass: 3   fail: 1'* ]] && status=0 || status=1
check "$status" 'timing preserves the assertion counters and failing exit'
[[ "$out" == *$'  ok    slow pass\n'* && "$out" == *$'  FAIL  slow fail\n'* ]] && status=0 || status=1
check "$status" 'timed assertions retain the existing rows'

PATH="$TMP_ROOT/bin:$PATH" "$BASH" "$TEST_DIR/run-all.sh" --battery "$TMP_ROOT/battery" > "$TMP_ROOT/runner.out" 2>&1 && rc=0 || rc=$?
out="$(cat "$TMP_ROOT/runner.out")"
records_match "$out" 'suite=timed&row ' && status=0 || status=$?
check "$status" 'run-all binds case seconds and names to the suite'
[[ "$rc" -eq 1 && "$out" == *' pass=3 fail=1'* ]] && status=0 || status=1
check "$status" 'run-all keeps the pass and fail totals'

# Keep the record and both assertions, but remove only the printed seconds.
awk '
  /printf '\''case seconds=%s result=%s name=%s/ {
    found++
    print "    printf '\''case result=%s name=%s\\n'\'' \"$1\" \"$2\""
    next
  }
  { print }
  END { if (found != 1) exit 1 }
' "$LIB" > "$TMP_ROOT/no-seconds.sh"
cmp -s "$LIB" "$TMP_ROOT/no-seconds.sh" && exit 1
TIMING_LIB="$TMP_ROOT/no-seconds.sh" PATH="$TMP_ROOT/bin:$PATH" "$BASH" "$TMP_ROOT/battery/timed&row.sh" > "$TMP_ROOT/control.out" 2>&1 && rc=0 || rc=$?
out="$(cat "$TMP_ROOT/control.out")"
records_match "$out" '' && status=1 || status=0
[[ "$rc" -eq 1 && "$out" == *'case result=ok name=slow pass'* ]] || status=1
check "$status" 'must-fail control rejects records with seconds removed'

printf 'pass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
