#!/usr/bin/env bash
# Pins tools/install-gitleaks: it installs the archive its platform maps to
# only when the archive matches the pinned SHA-256, leaves a current install
# alone, and refuses an unpinned platform or a failed download. The release
# server is a fake curl serving a fixture archive; the rows that install run a
# disposable copy of the script whose pins name that archive's digest.
set -euo pipefail

unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="$(cd "$TEST_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)" || { echo "install-gitleaks: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "install-gitleaks: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "install-gitleaks: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

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

# The fakes: curl copies the fixture archive to its -o path and logs the URL,
# or exits CURL_FAIL; uname answers UNAME_S and UNAME_M.
FAKE_BIN="$TMP_ROOT/fake-bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/curl" <<'SH'
#!/usr/bin/env bash
set -eu
out="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift ;;
    https://*) url=$1 ;;
  esac
  shift
done
printf '%s\n' "$url" >>"$CURL_LOG"
[ "${CURL_FAIL:-0}" -eq 0 ] || exit "$CURL_FAIL"
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
  cp "$TOOLS/install-gitleaks" "$SCRIPT"
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
run() { # DIR [NAME=VALUE...] — the exit status and the first stable line
  local dir=$1 rc=0 out
  shift
  : >"$CURL_LOG"
  out="$(env PATH="$FAKE_BIN:$PATH" CURL_LOG="$CURL_LOG" FIXTURE="$TMP_ROOT/fixture.tar.gz" UNAME_S=Linux UNAME_M=x86_64 "$@" "$SCRIPT" "$dir" 2>&1)" || rc=$?
  printf 'rc=%s %s' "$rc" "$(printf '%s\n' "$out" | awk '/^install-gitleaks: / && !seen { print; seen=1 }')"
}

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
D="$TMP_ROOT/offline"
assert_eq "a failed download is refused" \
  "rc=1 install-gitleaks: download=gitleaks_8.30.1_linux_x64.tar.gz" "$(run "$D" CURL_FAIL=22)"
assert_eq "an empty directory argument is a usage error" "rc=2 install-gitleaks: usage=1" "$(run "")"

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

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
