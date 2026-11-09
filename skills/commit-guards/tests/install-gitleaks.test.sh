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
# second it starts: a stalled endpoint before STALL_SECS, 504 before
# OUTAGE_SECS, then CURL_STATUS (200 by default, which copies the fixture
# archive to its -o path). Each attempt is logged to TRY_LOG as "START STATUS
# END". Its retries follow curl's own, per `curl --manual` (curl 8.5.0) on
# --retry, --retry-delay, --retry-max-time and --max-time, and recorded runs of
# that curl against a local 504 server and a local server that accepts and
# never answers: only a timeout (exit 28, status 000) and 408, 429, 500, 502,
# 503 and 504 retry; a stalled attempt ends at --max-time, or never without
# one; the wait is --retry-delay, else 1 s doubling up to 600; the max time is
# checked when an attempt ends, before its wait; -f exits 22 and -w names the
# last attempt's status. --connect-timeout is accepted and not modeled, since
# --max-time also bounds the stall it bounds. An option it does not model
# exits 2 before any attempt, so a changed curl call fails the suite rather
# than going unmodeled. uname answers UNAME_S and UNAME_M.
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
t=0 backoff=1
while :; do
  if [ "$t" -lt "${STALL_SECS:-0}" ]; then
    code=000 end=$NEVER
    [ "$attempt" -eq 0 ] || end=$((t + attempt))
  elif [ "$t" -lt "${OUTAGE_SECS:-0}" ]; then
    code=504 end=$t
  else
    code=${CURL_STATUS:-200} end=$t
  fi
  printf '%s %s %s\n' "$t" "$code" "$end" >>"$TRY_LOG"
  [ "$end" -lt "$NEVER" ] || break
  case "$code" in 000 | 408 | 429 | 500 | 502 | 503 | 504) ;; *) break ;; esac
  [ "$retries" -gt 0 ] && { [ "$max" -eq 0 ] || [ "$end" -lt "$max" ]; } || break
  retries=$((retries - 1))
  if [ "$delay" -gt 0 ]; then
    t=$((end + delay))
  else
    t=$((end + backoff)) backoff=$((backoff * 2 > 600 ? 600 : backoff * 2))
  fi
done
var='%{http_code}'
printf '%s' "${write//"$var"/$code}"
[ "$code" = 000 ] && exit 28
[ "$code" = 200 ] || exit 22
cp -- "$FIXTURE" "$out"
SH
cat >"$FAKE_BIN/uname" <<'SH'
#!/usr/bin/env bash
case "$1" in -s) echo "$UNAME_S" ;; -m) echo "$UNAME_M" ;; *) exit 64 ;; esac
SH
chmod +x "$FAKE_BIN/curl" "$FAKE_BIN/uname"

# copy NAME [FROM TO]...: a disposable copy of the script at $TMP_ROOT/NAME,
# each FROM replaced by its TO on the one line holding it, in SCRIPT.
SCRIPT=""
copy() {
  local name=$1 from to n before
  shift
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

CURL_LOG="$TMP_ROOT/curl.log"
TRY_LOG="$TMP_ROOT/tries.log"
OUT_LOG="$TMP_ROOT/out.log"
run() { # DIR [NAME=VALUE...] — the exit status and the first stable line; the whole output in OUT_LOG
  local dir=$1 rc=0
  shift
  : >"$CURL_LOG"
  : >"$TRY_LOG"
  env PATH="$FAKE_BIN:$PATH" CURL_LOG="$CURL_LOG" TRY_LOG="$TRY_LOG" FIXTURE="$TMP_ROOT/fixture.tar.gz" UNAME_S=Linux UNAME_M=x86_64 "$@" "$SCRIPT" "$dir" >"$OUT_LOG" 2>&1 || rc=$?
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
assert_eq "a release answering 404 is refused" \
  "rc=1 install-gitleaks: download=gitleaks_8.30.1_linux_x64.tar.gz" "$(run "$D" CURL_STATUS=404)"
assert_eq "after one attempt, without waiting out the window" "0 404 0" "$(cat "$TRY_LOG")"
assert_eq "an empty directory argument is a usage error" "rc=2 install-gitleaks: usage=1" "$(run "")"

echo "=== a release outage ==="
# Two minutes of 504s: far past the old 7 s of retries, within a few minutes.
SCRIPT="$PINNED"
D="$TMP_ROOT/outage"
assert_eq "an outage of two minutes is ridden out and the binary installed" \
  "rc=0 install-gitleaks: installed=8.30.1:$D/gitleaks" "$(run "$D" OUTAGE_SECS=120)"
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
copy old-retry "$LINUX_PIN" "$FIXTURE_SHA" '--retry "$RETRY_SECS" --retry-delay "$RETRY_DELAY_SECS" --retry-max-time "$RETRY_SECS"' '--retry 3'
assert_eq "control: the old curl --retry 3 fails a two-minute outage" \
  "rc=1 install-gitleaks: download=gitleaks_8.30.1_linux_x64.tar.gz" "$(run "$TMP_ROOT/old-retry-dir" OUTAGE_SECS=120)"
copy no-max "$LINUX_PIN" "$FIXTURE_SHA" '--retry-max-time "$RETRY_SECS"' '--retry-max-time 0'
run "$TMP_ROOT/no-max-dir" OUTAGE_SECS=100000 >/dev/null
assert_eq "control: without the max time a long outage retries past the budget" "no" "$(in_budget)"
copy backoff "$LINUX_PIN" "$FIXTURE_SHA" '--retry-delay "$RETRY_DELAY_SECS"' '--retry-delay "$RETRY_DELAY_SECS" --retry-delay 0'
run "$TMP_ROOT/backoff-dir" OUTAGE_SECS=100000 >/dev/null
assert_eq "control: curl's doubling backoff retries past the budget" "no" "$(in_budget)"
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
