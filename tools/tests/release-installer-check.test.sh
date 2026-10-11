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
# The deb is opened with ar and tar. The rows run on Linux only, the one
# host whose release lane checks a .deb: on macOS the fixture's ar round
# trip does not extract, and the macOS leg answered extract= on every row.
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
#
# The attach table adds partial attachment and detach failure inputs. It runs on
# every host, with hdiutil and codesign stubbed on PATH: the stub refuses
# the first `refusals` attaches, saying `stub refusal` on stderr, then
# mounts an app built with the `sidecar` word. `cause` and `info` say whether
# the FAIL log carries the stub's refusal and image listing. The log is
# the CI diagnosis when the real hdiutil cannot attach an image. Each row also
# asserts that no owned device remains. The foreign image must stay attached.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$(cd "$TEST_DIR/.." && pwd)/release-installer-check"
TMP="$(mktemp -d)" || { echo 'release-installer-check.test: scratch=mktemp-failed' >&2; exit 1; }
[[ -d "$TMP" && ! -L "$TMP" ]] || { echo 'release-installer-check.test: scratch=not-a-directory' >&2; exit 1; }
TMP="$(cd -- "$TMP" && pwd -P)" || { echo 'release-installer-check.test: scratch=resolve-failed' >&2; exit 1; }
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
    if [[ "${4:-}" == macos && "$got" == *" first=extract="* ]]; then
      cat "$TMP/err"
      hdiutil info || printf 'hdiutil info: exit=%s\n' "$?"
    fi
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
  # The fixtures are unsigned, so a signing identity exported on the host
  # would push every row through the signing lane's refusal.
  env -u APPLE_SIGNING_IDENTITY "$CHECK" "$1" "${2:-$OUT}" >"$TMP/std" 2>"$TMP/err" || rc=$?
  printf 'rc=%s first=%s checked=%s' "$rc" "$(first_text)" "$(checked_text)"
}

LINUX=x86_64-unknown-linux-gnu
DEB="bundle/deb/kendex_${VERSION}_amd64.deb"

if [ "$(uname -s)" = Linux ]; then
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

# The lane passes OUT relative to the checkout, and the deb is opened from
# a directory of its own, so a relative OUT has to be made absolute first.
build_linux command
relative_rc=0
(cd "$TMP" && "$CHECK" "$LINUX" out) >"$TMP/std" 2>"$TMP/err" || relative_rc=$?
assert_eq "rc=$relative_rc first=$(first_text) checked=$(checked_text)" \
  "rc=1 first=missing=*.rpm checked=$DEB" \
  "a relative output directory is read the way an absolute one is"
else
  echo "=== the Linux lane rows run on Linux only ==="
fi

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
    assert_eq "$(run "$MACOS")" "rc=$rc first=$first checked=$checked" "$label" macos
  done <<EOF
the app, its updater archive and its disk image all carry the sidecar|command|command|command|0|-|bundle/macos/kendex.app,bundle/macos/kendex.app.tar.gz,bundle/dmg/kendex_${VERSION}_aarch64.dmg
an app with no sidecar|absent|command|command|1|absent=$OUT/bundle/macos/kendex.app|-
an updater archive with no sidecar|command|absent|command|1|absent=$OUT/bundle/macos/kendex.app.tar.gz|bundle/macos/kendex.app
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

# stub_tools — hdiutil as check_dmg calls it, and a codesign the unsigned
# lane never runs, under STUB
STUB="$TMP/stub"
stub_tools() { # SIDECAR
  rm -rf -- "${STUB:?}"
  mkdir -p "$STUB/bin"
  mac_app "$STUB/image/kendex.app" "$1"
  : >"$STUB/foreign"
  cat >"$STUB/bin/hdiutil" <<STUBEOF
#!/bin/sh
case "\$1" in
  attach)
    if [ -f "$STUB/attached" ]; then
      echo "hdiutil: attach failed - Resource temporarily unavailable" >&2
      exit 1
    fi
    left=\$(cat "$STUB/refusals")
    if [ "\$left" -gt 0 ]; then
      echo \$((left - 1)) >"$STUB/refusals"
      [ "\$(cat "$STUB/partial")" != yes ] || : >"$STUB/attached"
      echo "hdiutil: attach failed - stub refusal" >&2
      exit 1
    fi
    while [ "\$#" -gt 0 ]; do
      [ "\$1" != -mountpoint ] || mount=\$2
      shift
    done
    cp -R "$STUB/image/." "\$mount"
    : >"$STUB/attached"
    ;;
  detach)
    [ "\$2" = -force ] && [ "\$3" = /dev/stub-owned ] || exit 2
    [ "\$(cat "$STUB/detach-error")" != yes ] || exit 1
    rm "$STUB/attached"
    ;;
  info)
    if [ "\${2:-}" = -plist ]; then
      printf '%s\n' '<plist version="1.0"><dict><key>images</key><array>'
      printf '%s\n' '<dict><key>image-path</key><string>/foreign.dmg</string><key>system-entities</key><array><dict><key>dev-entry</key><string>/dev/stub-foreign</string></dict></array></dict>'
      if [ -f "$STUB/attached" ]; then
        printf '%s\n' '<dict><key>image-path</key><string>$OUT/bundle/dmg/kendex_${VERSION}_aarch64.dmg</string><key>system-entities</key><array><dict><key>dev-entry</key><string>/dev/stub-owned</string></dict><dict><key>dev-entry</key><string>/dev/stub-owned-partition</string></dict></array></dict>'
      fi
      printf '%s\n' '</array></dict></plist>'
    else
      echo "image-path : $OUT/bundle/dmg/kendex_${VERSION}_aarch64.dmg"
    fi
    ;;
  *) echo "hdiutil stub: no verb \$1" >&2; exit 2 ;;
esac
STUBEOF
  printf '#!/bin/sh\necho "codesign stub: not called on an unsigned lane" >&2\nexit 2\n' >"$STUB/bin/codesign"
  chmod +x "$STUB/bin/hdiutil" "$STUB/bin/codesign"
}

echo "=== the disk image attach, hdiutil stubbed ==="
DMG="bundle/dmg/kendex_${VERSION}_aarch64.dmg"
while IFS='|' read -r label sidecar refusals partial detach_error rc first checked cause info remaining; do
  [[ "$label" != "" && "$label" != \#* ]] || continue
  build_macos command command none
  stub_tools "$sidecar"
  printf '%s\n' "$refusals" >"$STUB/refusals"
  printf '%s\n' "$partial" >"$STUB/partial"
  printf '%s\n' "$detach_error" >"$STUB/detach-error"
  : >"$OUT/$DMG"
  got="$(PATH="$STUB/bin:$PATH" run "$MACOS")"
  got_cause=no
  got_info=no
  if [[ "$first" == extract=* ]]; then
    # A failed success expectation reaches the real FAIL printer without
    # adding its deliberate mismatch to this suite's failure count.
    detail="$(PATH="$STUB/bin:$PATH" assert_eq "$got" "rc=0 first=- checked=$DMG" "$label" macos)"
    [[ "$detail" != *"stub refusal"* ]] || got_cause=yes
    [[ "$detail" != *"image-path : $OUT/$DMG"* ]] || got_info=yes
  fi
  got_remaining=no
  [[ ! -f "$STUB/attached" ]] || got_remaining=yes
  foreign=yes
  [[ -f "$STUB/foreign" ]] || foreign=no
  PATH="$STUB/bin:$PATH" assert_eq "$got cause=$got_cause info=$got_info remaining=$got_remaining foreign=$foreign" \
    "rc=$rc first=$first checked=$checked cause=$cause info=$info remaining=$remaining foreign=yes" "$label" macos
done <<EOF
a disk image with no sidecar releases its attachment on refusal|absent|0|no|no|1|absent=$OUT/$DMG|bundle/macos/kendex.app,bundle/macos/kendex.app.tar.gz|no|no|no
a disk image refused once and mounted on the next attempt is checked|command|1|no|no|0|-|bundle/macos/kendex.app,bundle/macos/kendex.app.tar.gz,$DMG|no|no|no
a disk image refused on every attempt names hdiutil's refusal|command|3|no|no|1|extract=$OUT/$DMG|bundle/macos/kendex.app,bundle/macos/kendex.app.tar.gz|yes|yes|no
a partially attached failed attempt releases its devices before the next attach|command|1|yes|no|0|-|bundle/macos/kendex.app,bundle/macos/kendex.app.tar.gz,$DMG|no|no|no
a final failed attach leaves no image attached|command|3|yes|no|1|extract=$OUT/$DMG|bundle/macos/kendex.app,bundle/macos/kendex.app.tar.gz|yes|yes|no
a detach failure refuses and retains the image for exit cleanup|command|1|yes|yes|1|detach=$OUT/$DMG|bundle/macos/kendex.app,bundle/macos/kendex.app.tar.gz|no|no|yes
EOF

# The same partial-attachment row must fail when failed-attempt cleanup is
# removed from a disposable production copy. Keep the attach and its refusal.
CONTROL="$TMP/check-without-failed-attach-cleanup"
python3 - "$CHECK" "$CONTROL" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
needle = '    detach_image "$dmg" || die detach "$dmg"\n'
assert source.count(needle) == 1
changed = source.replace(needle, '    : # failed-attempt cleanup disabled\n')
assert changed != source
Path(sys.argv[2]).write_text(changed)
PY
chmod +x "$CONTROL"
build_macos command command none
stub_tools command
printf '1\n' >"$STUB/refusals"
printf 'yes\n' >"$STUB/partial"
printf 'no\n' >"$STUB/detach-error"
: >"$OUT/$DMG"
got="$(CHECK="$CONTROL" PATH="$STUB/bin:$PATH" run "$MACOS")"
detail="$(assert_eq "$got" "rc=0 first=- checked=bundle/macos/kendex.app,bundle/macos/kendex.app.tar.gz,$DMG" \
  'partial attachment control')"
red=no
[[ "$detail" != *"  FAIL  "* ]] || red=yes
assert_eq "$got red=$red" \
  "rc=1 first=extract=$OUT/$DMG checked=bundle/macos/kendex.app,bundle/macos/kendex.app.tar.gz red=yes" \
  'must-fail: without failed-attempt cleanup the same image blocks the next attach'

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
