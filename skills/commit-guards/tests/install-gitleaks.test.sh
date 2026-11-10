#!/usr/bin/env bash
# Pins scripts/install-gitleaks: it installs the archive its platform maps to
# only when the archive matches the pinned SHA-256, leaves a current install
# alone, rides out a release outage of minutes but not one past its window,
# and refuses an unpinned platform, a failed download or a dash-led DIR;
# -h/--help and a dash-led DIR create and download nothing. The release
# server is a fake curl serving a fixture archive on a virtual clock, so the
# retry window passes without sleeping; the rows that install run a
# disposable copy of the script whose pins name that archive's digest.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"

SCRIPTS="$(cd "$TEST_DIR/../scripts" && pwd)"
TMP_ROOT="$TMP"
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "install-gitleaks: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "install-gitleaks: scratch=resolve-failed" >&2; exit 1; }

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

# The fixture archive: a gitleaks that answers `version` with the pinned
# version, so a second run reads the install as current.
mkdir -p "$TMP_ROOT/archive"
printf '#!/bin/sh\n[ "$1" = version ] && echo 8.30.1\n' >"$TMP_ROOT/archive/gitleaks"
chmod +x "$TMP_ROOT/archive/gitleaks"
tar -czf "$TMP_ROOT/fixture.tar.gz" -C "$TMP_ROOT/archive" gitleaks
if command -v sha256sum >/dev/null 2>&1; then
  FIXTURE_SHA="$(sha256sum "$TMP_ROOT/fixture.tar.gz")"
else
  FIXTURE_SHA="$(shasum -a 256 "$TMP_ROOT/fixture.tar.gz")"
fi
FIXTURE_SHA="${FIXTURE_SHA%% *}"

# The fakes: curl logs the URL, then answers each attempt by the virtual
# second it starts: a stalled endpoint before STALL_SECS, OUTAGE_STATUS (504
# by default) before OUTAGE_SECS, then CURL_STATUS (200, which copies the fixture
# archive to its -o path). Each attempt is logged to TRY_LOG as "START STATUS
# END". A stalled attempt ends at --max-time, or never without one. A failed
# HTTP response normally exits 22 with -f, but can end as a receive error (56)
# even with HTTP 500, as GitHub release run 42854385828 did. OUTAGE_EXIT models
# that result independently of the status. curl-8_7_1/src/tool_operate.c,
# post_per_transfer (https://github.com/curl/curl/blob/curl-8_7_1/src/tool_operate.c),
# gates HTTP --retry on exit 0 or 22; exit 28 retries as a timeout. The old
# flags remain modeled for the pre-fix control: a fixed --retry-delay, else
# doubling from 1 s up to 600, and --retry-max-time checked after each attempt.
# -w names the last status. --connect-timeout is accepted and not modeled,
# since --max-time also bounds the stall it bounds. Unmodeled options exit 2.
# sleep advances CLOCK, which the disposable script reads instead of SECONDS.
# uname answers UNAME_S and UNAME_M.
FAKE_BIN="$TMP_ROOT/fake-bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/curl" <<'SH'
#!/usr/bin/env bash
set -eu
out="" url="" write="" retries=0 delay=0 max=0 attempt=0
while [ $# -gt 0 ]; do
  case "$1" in
    -fsSL) ;;
    -o) out=$2; shift ;;
    -w) write=$2; shift ;;
    --retry) retries=$2; shift ;;
    --retry-delay) delay=$2; shift ;;
    --retry-max-time) max=$2; shift ;;
    --connect-timeout) shift ;;
    --max-time) attempt=$2; shift ;;
    https://*) url=$1 ;;
    *) printf 'fake curl: unmodeled %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
printf '%s\n' "$url" >>"$CURL_LOG"
NEVER=999999
t="$(cat "$CLOCK")" backoff=1
start=$t
while :; do
  if [ "$t" -lt "${STALL_SECS:-0}" ]; then
    code=${STALL_STATUS:-000} end=$NEVER
    [ "$attempt" -eq 0 ] || end=$((t + attempt))
  elif [ "$t" -lt "${OUTAGE_SECS:-0}" ]; then
    code=${OUTAGE_STATUS:-504} end=$t
  else
    code=${CURL_STATUS:-200} end=$t
  fi
  rc=0
  if [ "$t" -lt "${STALL_SECS:-0}" ]; then
    rc=28
  elif [ "$code" != 200 ]; then
    rc=${OUTAGE_EXIT:-22}
  fi
  printf '%s %s %s\n' "$t" "$code" "$end" >>"$TRY_LOG"
  [ "$end" -lt "$NEVER" ] || break
  case "$code:$rc" in
    *:28 | 408:22 | 429:22 | 500:22 | 502:22 | 503:22 | 504:22) ;;
    *) break ;;
  esac
  [ "$retries" -gt 0 ] && { [ "$max" -eq 0 ] || [ "$((end - start))" -lt "$max" ]; } || break
  retries=$((retries - 1))
  if [ "$delay" -gt 0 ]; then
    t=$((end + delay))
  else
    t=$((end + backoff)) backoff=$((backoff * 2 > 600 ? 600 : backoff * 2))
  fi
done
printf '%s\n' "$end" >"$CLOCK"
var='%{http_code}'
printf '%s' "${write//"$var"/$code}"
[ "$rc" -eq 0 ] || exit "$rc"
cp -- "$FIXTURE" "$out"
SH
cat >"$FAKE_BIN/sleep" <<'SH'
#!/usr/bin/env bash
set -eu
now="$(cat "$CLOCK")"
printf '%s\n' "$((now + $1))" >"$CLOCK"
SH
cat >"$FAKE_BIN/uname" <<'SH'
#!/usr/bin/env bash
case "$1" in -s) echo "$UNAME_S" ;; -m) echo "$UNAME_M" ;; *) exit 64 ;; esac
SH
chmod +x "$FAKE_BIN/curl" "$FAKE_BIN/sleep" "$FAKE_BIN/uname"

# copy NAME [FROM TO]...: a disposable copy of the script at $TMP_ROOT/NAME,
# each FROM replaced by its TO on the one line holding it, in SCRIPT.
SCRIPT=""
copy() {
  local name=$1 from to n before
  shift
  set -- 'start=$SECONDS' 'start=$(cat "$CLOCK")' 'SECONDS - start' '$(cat "$CLOCK") - start' "$@"
  SCRIPT="$TMP_ROOT/$name"
  cp "$SCRIPTS/install-gitleaks" "$SCRIPT"
  while [ $# -gt 0 ]; do
    from=$1 to=$2
    shift 2
    n="$(FROM="$from" awk 'index($0, ENVIRON["FROM"]) { n++ } END { print n + 0 }' "$SCRIPT")"
    [ "$n" -eq 1 ] || { echo "harness: copy $name: '$from' matched $n lines" >&2; exit 2; }
    before="$(cat -- "$SCRIPT")"
    FROM="$from" TO="$to" awk '{ i = index($0, ENVIRON["FROM"]); if (i) $0 = substr($0, 1, i - 1) ENVIRON["TO"] substr($0, i + length(ENVIRON["FROM"])); print }' \
      "$SCRIPT" >"$SCRIPT.new"
    mv -- "$SCRIPT.new" "$SCRIPT"
    [ "$before" != "$(cat -- "$SCRIPT")" ] || { echo "harness: copy $name: '$from' changed nothing" >&2; exit 2; }
  done
  chmod +x "$SCRIPT"
}
LINUX_PIN=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
DARWIN_ARM_PIN=b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5

CLOCK="$TMP_ROOT/clock"
CURL_LOG="$TMP_ROOT/curl.log"
TRY_LOG="$TMP_ROOT/tries.log"
OUT_LOG="$TMP_ROOT/out.log"
run() { # DIR [NAME=VALUE...] — the exit status and the first stable line; the whole output in OUT_LOG
  local dir=$1 rc=0
  shift
  : >"$CURL_LOG"
  : >"$TRY_LOG"
  printf '0\n' >"$CLOCK"
  env PATH="$FAKE_BIN:$PATH" CLOCK="$CLOCK" CURL_LOG="$CURL_LOG" TRY_LOG="$TRY_LOG" FIXTURE="$TMP_ROOT/fixture.tar.gz" UNAME_S=Linux UNAME_M=x86_64 "$@" "$SCRIPT" "$dir" >"$OUT_LOG" 2>&1 || rc=$?
  printf 'rc=%s %s' "$rc" "$(awk '/^install-gitleaks: / && !seen { print; seen=1 }' "$OUT_LOG")"
}
# The latest second a failing download may end: its CI callers run it in a
# timeout-minutes: 5 job, and this leaves that job 60 s for checkout, the
# download= line and its later steps.
BUDGET_SECS=240
# in_budget: yes when the last download attempt ended by BUDGET_SECS, no when
# it ended later, no-attempt when none was logged, so a copy that fails before
# its first attempt satisfies neither a positive row nor a control.
in_budget() { awk -v b="$BUDGET_SECS" 'END { if (NR == 0) print "no-attempt"; else print ($3 <= b ? "yes" : "no") }' "$TRY_LOG"; }

echo "=== a pinned archive installs once ==="
copy pinned "$LINUX_PIN" "$FIXTURE_SHA" "$DARWIN_ARM_PIN" "$FIXTURE_SHA"
D="$TMP_ROOT/fresh"
assert_eq "an empty directory receives the binary" \
  "rc=0 install-gitleaks: installed=8.30.1:$D/gitleaks" "$(run "$D")"
assert_eq "the archive is the Linux x64 release" \
  "https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz" "$(cat "$CURL_LOG")"
assert_eq "the installed binary answers its version" "8.30.1" "$("$D/gitleaks" version)"
assert_eq "a current install is left alone" \
  "rc=0 install-gitleaks: skip=$D/gitleaks" "$(run "$D")"
assert_eq "and downloads nothing" "" "$(cat "$CURL_LOG")"
D="$TMP_ROOT/stale"
mkdir -p "$D"
printf '#!/bin/sh\necho 8.0.0\n' >"$D/gitleaks"
chmod +x "$D/gitleaks"
assert_eq "another version is replaced" \
  "rc=0 install-gitleaks: installed=8.30.1:$D/gitleaks" "$(run "$D")"
D="$TMP_ROOT/darwin"
assert_eq "an arm64 Mac receives the binary" \
  "rc=0 install-gitleaks: installed=8.30.1:$D/gitleaks" "$(run "$D" UNAME_S=Darwin UNAME_M=arm64)"
assert_eq "from the Darwin arm64 release" \
  "https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_darwin_arm64.tar.gz" "$(cat "$CURL_LOG")"
PINNED="$SCRIPT"

echo "=== refusals install nothing ==="
copy shipped
D="$TMP_ROOT/mismatch"
assert_eq "an archive off its pinned digest is refused" \
  "rc=1 install-gitleaks: checksum=gitleaks_8.30.1_linux_x64.tar.gz" "$(run "$D")"
assert_eq "and leaves no binary" "absent" "$([ -e "$D/gitleaks" ] && echo present || echo absent)"
SCRIPT="$PINNED"
D="$TMP_ROOT/bsd"
assert_eq "an operating system with no pin is refused" \
  "rc=1 install-gitleaks: platform=FreeBSD" "$(run "$D" UNAME_S=FreeBSD)"
assert_eq "an architecture with no pin is refused" \
  "rc=1 install-gitleaks: platform=riscv64" "$(run "$D" UNAME_M=riscv64)"
D="$TMP_ROOT/missing"
for status in 400 401 403 404 501; do
  for rc in 22 28 56; do
    assert_eq "HTTP $status/exit $rc is refused" \
      "rc=1 install-gitleaks: download=gitleaks_8.30.1_linux_x64.tar.gz" "$(run "$D" CURL_STATUS="$status" OUTAGE_EXIT="$rc")"
    assert_eq "after one attempt, without waiting out the window" "0 $status 0" "$(cat "$TRY_LOG")"
    assert_eq "with no retry wait" "0" "$(cat "$CLOCK")"
  done
done
assert_eq "an empty directory argument is a usage error" "rc=2 install-gitleaks: usage=1" "$(run "")"

echo "=== a release outage ==="
# Two minutes: far past the old 7 s of retries, within the window. Include
# the recorded HTTP 500/exit 56 incident, not just curl's usual HTTP exit 22.
SCRIPT="$PINNED"
for status in 408 429 500 502 503 504; do
  for rc in 22 56; do
    D="$TMP_ROOT/outage-$status-$rc"
    assert_eq "HTTP $status/exit $rc recovers inside the window" \
      "rc=0 install-gitleaks: installed=8.30.1:$D/gitleaks" "$(run "$D" OUTAGE_SECS=120 OUTAGE_STATUS="$status" OUTAGE_EXIT="$rc")"
    assert_eq "the installed binary answers its pinned version" "8.30.1" "$("$D/gitleaks" version 2>/dev/null || echo absent)"
  done
done
D="$TMP_ROOT/timeout-recovery"
assert_eq "a timeout with a partial HTTP 200 response recovers" \
  "rc=0 install-gitleaks: installed=8.30.1:$D/gitleaks" "$(run "$D" STALL_SECS=120 STALL_STATUS=200)"
D="$TMP_ROOT/receive-down"
assert_eq "HTTP 500/exit 56 past the window is refused" \
  "rc=1 install-gitleaks: download=gitleaks_8.30.1_linux_x64.tar.gz" "$(run "$D" OUTAGE_SECS=100000 OUTAGE_STATUS=500 OUTAGE_EXIT=56)"
# The issue's failure contract includes the last status and elapsed seconds.
assert_eq "the failure names exit 56, HTTP 500, and 150 seconds of retrying" \
  "56 500 150" "$(awk '/^The release archive/ { for (i=1; i<NF; i++) { if ($i == "exit") { rc=$(i+1); sub(/,$/, "", rc) } if ($i == "status") code=$(i+1); if ($i == "after") elapsed=$(i+1) } print rc, code, elapsed }' "$OUT_LOG")"
assert_eq "and leaves no binary" "absent" "$([ -e "$D/gitleaks" ] && echo present || echo absent)"
assert_eq "within the CI job's budget" "yes" "$(in_budget)"
D="$TMP_ROOT/down"
assert_eq "an outage past the window is refused" \
  "rc=1 install-gitleaks: download=gitleaks_8.30.1_linux_x64.tar.gz" "$(run "$D" OUTAGE_SECS=100000)"
# last_status: 504 when the explanation under the first line names that status,
# no-attempt when no download attempt was logged.
last_status() {
  [ -s "$TRY_LOG" ] || { echo no-attempt; return; }
  awk '!/^install-gitleaks: / && /(^|[^0-9])504([^0-9]|$)/ { print "504"; exit }' "$OUT_LOG"
}
assert_eq "naming the last status" "504" "$(last_status)"
assert_eq "and leaves no binary" "absent" "$([ -e "$D/gitleaks" ] && echo present || echo absent)"
assert_eq "giving up within the CI job's budget" "yes" "$(in_budget)"
D="$TMP_ROOT/stalled"
assert_eq "an endpoint that stops answering is refused" \
  "rc=1 install-gitleaks: download=gitleaks_8.30.1_linux_x64.tar.gz" "$(run "$D" STALL_SECS=100000)"
assert_eq "within the CI job's budget" "yes" "$(in_budget)"

echo "=== help and a dash-led DIR touch nothing ==="
# in_cwd DIR ARG: run ARG from an empty working directory DIR, then report the
# result, what DIR holds and what was fetched.
in_cwd() {
  local res
  mkdir -p -- "$1"
  res="$(cd -- "$1" && run "$2")" || return 1
  printf '%s cwd=[%s] fetched=[%s]' "$res" "$(ls -A -- "$1")" "$(cat -- "$CURL_LOG")"
}
for row in "-h|rc=0 install-gitleaks: usage=help" "--help|rc=0 install-gitleaks: usage=help" "-gitleaks|rc=2 install-gitleaks: usage=-gitleaks"; do
  arg=${row%%|*}
  assert_eq "$arg exits with its code and creates and downloads nothing" \
    "${row#*|} cwd=[] fetched=[]" "$(in_cwd "$TMP_ROOT/cwd$arg" "$arg")"
done

echo "=== must-fail controls ==="
copy no-check '[ "$got" = "$want" ] ||' 'true ||'
assert_eq "control: without the digest comparison an archive off its pin installs" \
  "rc=0 install-gitleaks: installed=8.30.1:$TMP_ROOT/no-check-dir/gitleaks" "$(run "$TMP_ROOT/no-check-dir")"
copy no-skip "$LINUX_PIN" "$FIXTURE_SHA" 'if [ "$current" = "$VERSION" ]; then' 'if false; then'
assert_eq "control: without the version check a current install downloads again" \
  "rc=0 install-gitleaks: installed=8.30.1:$TMP_ROOT/fresh/gitleaks" "$(run "$TMP_ROOT/fresh")"
copy arch-map 'aarch64 | arm64) arch=arm64 ;;' 'aarch64 | arm64) arch=x64 ;;'
run "$TMP_ROOT/arch-map-dir" UNAME_S=Darwin UNAME_M=arm64 >/dev/null
assert_eq "control: a wrong architecture map fetches the wrong release" \
  "https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_darwin_x64.tar.gz" "$(cat "$CURL_LOG")"

copy no-help '-h | --help) say usage help;' '--never) say usage help;'
assert_eq "control: without the help case --help is refused as a dash-led DIR" \
  "rc=2 install-gitleaks: usage=--help cwd=[] fetched=[]" "$(in_cwd "$TMP_ROOT/no-help-cwd" --help)"
copy no-dash "$LINUX_PIN" "$FIXTURE_SHA" '-*) say usage "$1"' '--never) say usage "$1"'
in_cwd "$TMP_ROOT/no-dash-cwd" -gitleaks >/dev/null
assert_eq "control: without the dash-led refusal the DIR is created and the release fetched" \
  "-gitleaks https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz" \
  "$(ls -A -- "$TMP_ROOT/no-dash-cwd") $(cat -- "$CURL_LOG")"
copy curl-only "$LINUX_PIN" "$FIXTURE_SHA" \
  'curl -fsSL' 'curl -fsSL --retry "$RETRY_SECS" --retry-delay "$RETRY_DELAY_SECS" --retry-max-time "$RETRY_SECS"' \
  'case "$code:$rc" in' 'case curl-only in'
assert_eq "control: the pre-fix curl-only retry refuses the recovering HTTP 500/exit 56" \
  "rc=1 install-gitleaks: download=gitleaks_8.30.1_linux_x64.tar.gz" \
  "$(run "$TMP_ROOT/curl-only-dir" OUTAGE_SECS=120 OUTAGE_STATUS=500 OUTAGE_EXIT=56)"
copy no-max "$LINUX_PIN" "$FIXTURE_SHA" '[ "$elapsed" -lt "$RETRY_SECS" ] || break' 'true || break'
run "$TMP_ROOT/no-max-dir" OUTAGE_SECS=300 >/dev/null
assert_eq "control: without the window a long outage retries past the budget" "no" "$(in_budget)"
copy long-delay "$LINUX_PIN" "$FIXTURE_SHA" 'sleep "$RETRY_DELAY_SECS"' 'sleep 600'
run "$TMP_ROOT/long-delay-dir" OUTAGE_SECS=100000 >/dev/null
assert_eq "control: an unbounded retry delay overshoots the budget" "no" "$(in_budget)"
copy no-attempt-max "$LINUX_PIN" "$FIXTURE_SHA" ' --max-time "$ATTEMPT_SECS"' ''
run "$TMP_ROOT/no-attempt-max-dir" STALL_SECS=100000 >/dev/null
assert_eq "control: without a per-attempt max time a stalled endpoint hangs past the budget" "no" "$(in_budget)"
copy long-window "$LINUX_PIN" "$FIXTURE_SHA" 'RETRY_SECS=150' 'RETRY_SECS=3000'
run "$TMP_ROOT/long-window-dir" OUTAGE_SECS=100000 >/dev/null
assert_eq "control: a window of 3000 s retries past the budget" "no" "$(in_budget)"
copy no-status "$LINUX_PIN" "$FIXTURE_SHA" 'last HTTP status ${code:-000}' 'last HTTP status unread'
run "$TMP_ROOT/no-status-dir" OUTAGE_SECS=100000 >/dev/null
assert_eq "control: an explanation without the status does not name 504" "" "$(last_status)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
