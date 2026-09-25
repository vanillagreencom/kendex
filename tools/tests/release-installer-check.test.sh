#!/usr/bin/env bash
# tools/release-installer-check: every installer a lane built carries a
# kendex command that runs and answers the lane's own version, and one
# that lost it, carries another build's, or cannot run is refused by name
# with nothing after it checked.
#
# Every run renders as `rc=<n> first=<f> checked=<c>`:
#   first    LINE 1 of stderr, `<key>=<value>` with the
#            `release-installer-check: ` prefix off; `-` when it said
#            nothing; every stderr line verbatim joined by `;` when line 1
#            is something else, so a run that stopped some other way cannot
#            render as one that stopped for the row's reason
#   checked  the installers the `checked=` lines on stdout name, joined by
#            `,`, as paths under OUT; `-` when none was checked
#
# The Linux table is `label|deb|rc|first|checked`:
#   deb    the .deb the lane built, as a word: `command` (the built command
#          inside), `other` (a command answering another version),
#          `noexec` (the command without its execute bit), `absent` (no
#          command in it), `none` (no .deb), `two` (two of them)
# The deb is opened with ar and tar, which every host running this has.
# No host here builds an .rpm, so every Linux row that gets past the deb
# stops at `missing=*.rpm`; the deb's own verdict is what the row holds, and
# the .rpm leg is proved by the release lane over the real package. The
# direction left open is an .rpm defect the deb does not share.
#
# The macOS table is `label|app|archive|dmg|rc|first|checked`, with each
# column `command`, `absent` or `none` as above, and runs only where hdiutil
# and codesign are on PATH: the disk image is made and mounted by hdiutil,
# and the signature check asks codesign whether the app is signed. Every
# fixture app is unsigned: the lane-without-secrets row warns and passes,
# the lane-that-signs row (APPLE_SIGNING_IDENTITY set) refuses, and a
# signed app is the release lane's alone to prove.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$(cd "$TEST_DIR/.." && pwd)/release-installer-check"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT
OUT="$TMP/out"
VERSION=9.9.9
PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$label" "$want" "$got"
  fi
}

# command FILE VERSION|noexec — a kendex that answers `kendex VERSION`
command_at() {
  mkdir -p "$(dirname "$1")"
  printf '#!/bin/sh\nprintf "kendex %s\\n"\n' "${2:-$VERSION}" >"$1"
  chmod +x "$1"
}

# lane — a fresh OUT holding the command this lane built and nothing else
lane() {
  rm -rf "$OUT"
  mkdir -p "$OUT/bundle"
  command_at "$OUT/kendex"
}

# deb NAME WORD — a .deb under OUT/bundle/deb whose usr/bin/kendex is WORD
deb() {
  local name=$1 word=$2 build="$TMP/deb-build"
  rm -rf "$build"
  mkdir -p "$build/data/usr/bin" "$build/control" "$OUT/bundle/deb"
  case "$word" in
    command) command_at "$build/data/usr/bin/kendex" ;;
    other) command_at "$build/data/usr/bin/kendex" 9.9.8 ;;
    noexec) command_at "$build/data/usr/bin/kendex"; chmod -x "$build/data/usr/bin/kendex" ;;
    absent) ;;
    *) printf 'deb: no package is built for the word %s\n' "$word" >&2; exit 1 ;;
  esac
  printf 'Package: kendex\nVersion: %s\nArchitecture: amd64\nMaintainer: kendex\nDescription: fixture\n' "$VERSION" >"$build/control/control"
  printf '2.0\n' >"$build/debian-binary"
  tar -czf "$build/control.tar.gz" -C "$build/control" .
  tar -czf "$build/data.tar.gz" -C "$build/data" .
  (cd "$build" && ar rc "$OUT/bundle/deb/$name" debian-binary control.tar.gz data.tar.gz)
}

# build_linux WORD — the deb column of a Linux row, as files under OUT
build_linux() {
  lane
  case "$1" in
    none) mkdir -p "$OUT/bundle/deb" ;;
    two) deb "kendex_${VERSION}_amd64.deb" command; deb "kendex_5.0.0_amd64.deb" command ;;
    *) deb "kendex_${VERSION}_amd64.deb" "$1" ;;
  esac
}

first_text() { # — LINE 1 of stderr, `-` when it said nothing
  local text first
  text="$(cat "$TMP/err")"
  [[ "$text" != "" ]] || { printf -- '-'; return; }
  first="$(sed -n '1s/^release-installer-check: //p' "$TMP/err")"
  if [[ "$first" != "" ]]; then
    printf '%s' "$first"
  else
    printf '%s' "$text" | paste -s -d ';' -
  fi
}

checked_text() { # — the installers the checked= lines name, `-` for none
  local names
  names="$(sed -n "s|^checked=$OUT/||p" "$TMP/std" | paste -s -d ',' -)"
  [[ "$names" != "" ]] || names='-'
  printf '%s' "$names"
}

run() { # TARGET [OUT]
  local rc=0
  "$CHECK" "$1" "${2:-$OUT}" >"$TMP/std" 2>"$TMP/err" || rc=$?
  printf 'rc=%s first=%s checked=%s' "$rc" "$(first_text)" "$(checked_text)"
}

LINUX=x86_64-unknown-linux-gnu
DEB="bundle/deb/kendex_${VERSION}_amd64.deb"

echo "=== the Linux lane, one row per shape of .deb ==="
while IFS='|' read -r label word rc first checked; do
  [[ "$label" != "" && "$label" != \#* ]] || continue
  build_linux "$word"
  assert_eq "$(run "$LINUX")" "rc=$rc first=$first checked=$checked" "$label"
done <<EOF
a deb carrying the built command is checked, then the rpm no host here builds is missed|command|1|missing=*.rpm|$DEB
a deb with no command in it|absent|1|absent=$OUT/$DEB|-
a deb whose command answers another version|other|1|version-mismatch=$OUT/$DEB|-
a deb whose command cannot run|noexec|1|unrunnable=$OUT/$DEB|-
no deb at all|none|1|missing=*.deb|-
two debs, which is a lane that cannot say which it built|two|1|ambiguous=*.deb|-
EOF

echo "=== the lane itself ==="
lane
rm "$OUT/kendex"
assert_eq "$(run "$LINUX")" "rc=1 first=no-command=$OUT/kendex checked=-" \
  "a lane whose command did not build has no version to hold anything to"
lane
printf '#!/bin/sh\nexit 3\n' >"$OUT/kendex"
assert_eq "$(run "$LINUX")" "rc=1 first=version-unreadable=$OUT/kendex checked=-" \
  "a built command that does not answer --version stops the check"
assert_eq "$(run "$LINUX" "$TMP/nowhere")" "rc=1 first=not-a-directory=$TMP/nowhere checked=-" \
  "an output directory that is not there"
lane
assert_eq "$(run sparc-unknown-none-elf)" "rc=1 first=target=sparc-unknown-none-elf checked=-" \
  "a target the release does not build"
assert_eq "$(run x86_64-pc-windows-msvc)" \
  "rc=1 first=target=x86_64-pc-windows-msvc (checked by release-installer-check.ps1) checked=-" \
  "the Windows setup is the PowerShell script's to check"

# mac_app DIR WORD — a kendex.app at DIR whose sidecar is WORD
mac_app() {
  mkdir -p "$1/Contents/MacOS"
  printf '' >"$1/Contents/MacOS/kendex-app"
  case "$2" in
    command) command_at "$1/Contents/MacOS/kendex" ;;
    absent) ;;
    *) printf 'mac_app: no app is built for the word %s\n' "$2" >&2; exit 1 ;;
  esac
}

# build_macos APP ARCHIVE DMG — the three columns of a macOS row
build_macos() {
  lane
  mkdir -p "$OUT/bundle/macos" "$OUT/bundle/dmg"
  [[ "$1" == none ]] || mac_app "$OUT/bundle/macos/kendex.app" "$1"
  if [[ "$2" != none ]]; then
    rm -rf "$TMP/archive"
    mac_app "$TMP/archive/kendex.app" "$2"
    tar -czf "$OUT/bundle/macos/kendex.app.tar.gz" -C "$TMP/archive" kendex.app
  fi
  if [[ "$3" != none ]]; then
    rm -rf "$TMP/image"
    mac_app "$TMP/image/kendex.app" "$3"
    hdiutil create -quiet -srcfolder "$TMP/image" -volname kendex "$OUT/bundle/dmg/kendex_${VERSION}_aarch64.dmg"
  fi
}

MACOS=aarch64-apple-darwin
if command -v hdiutil >/dev/null 2>&1 && command -v codesign >/dev/null 2>&1; then
  echo "=== the macOS lane, one row per shape of bundle ==="
  while IFS='|' read -r label app archive dmg rc first checked; do
    [[ "$label" != "" && "$label" != \#* ]] || continue
    build_macos "$app" "$archive" "$dmg"
    assert_eq "$(run "$MACOS")" "rc=$rc first=$first checked=$checked" "$label"
  done <<EOF
the app, its updater archive and its disk image all carry the sidecar|command|command|command|0|-|bundle/macos/kendex.app,bundle/macos/kendex.app.tar.gz,bundle/dmg/kendex_${VERSION}_aarch64.dmg
an app with no sidecar|absent|command|command|1|absent=$OUT/bundle/macos/kendex.app/Contents/MacOS/kendex|-
an updater archive with no sidecar|command|absent|command|1|absent=$OUT/bundle/macos/kendex.app.tar.gz|bundle/macos/kendex.app
a disk image with no sidecar|command|command|absent|1|absent=$OUT/bundle/dmg/kendex_${VERSION}_aarch64.dmg|bundle/macos/kendex.app,bundle/macos/kendex.app.tar.gz
no disk image at all|command|command|none|1|missing=*.dmg|bundle/macos/kendex.app,bundle/macos/kendex.app.tar.gz
EOF
  build_macos command command command
  run "$MACOS" >/dev/null
  assert_eq "$(grep -c '^unsigned=' "$TMP/std" || true)" "1" \
    "an unsigned app on a lane without signing secrets is named as unsigned"
  # The same fixture on a lane that signs: the workflow exports
  # APPLE_SIGNING_IDENTITY only with every secret set, so an app it left
  # unsigned is refused rather than warned about.
  rc=0
  APPLE_SIGNING_IDENTITY="Developer ID Application: kendex" "$CHECK" "$MACOS" "$OUT" >"$TMP/std" 2>"$TMP/err" || rc=$?
  assert_eq "rc=$rc first=$(first_text)" "rc=1 first=unsigned=$OUT/bundle/macos/kendex.app" \
    "an unsigned app on a lane that signs is refused"
else
  echo "skipped: the macOS rows need hdiutil and codesign, which this host has none of"
fi

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
