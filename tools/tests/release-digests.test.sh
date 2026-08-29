#!/usr/bin/env bash
# Pins tools/release-digests: it names this lane's two downloads by the
# rules the release publishes them under, measures each with SHA-256, and
# writes one document naming the version and the target. The refusing
# direction runs first in every pair, and each refusal is checked to have
# left no document behind — a lane that half-wrote one would publish a
# statement it never measured, which every client then holds its downloads
# to. Signing is not driven here: it needs the release secret, so
# --document-only is the mode a test can run.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIGESTS="$(cd "$TEST_DIR/.." && pwd)/release-digests"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT

PASS=0
FAIL=0
ok() {
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "$1"
}
bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"
}

DIST="$TMP/dist"
OUT=""
RC=0

# A lane that built the Linux x86_64 release: the command it staged and the
# AppImage its bundler produced, beside the sibling files a lane also
# stages and no document names.
linux_lane() {
  rm -rf "$DIST"
  mkdir -p "$DIST"
  printf 'the kendex command' >"$DIST/kendex-x86_64-unknown-linux-gnu"
  printf 'the app download' >"$DIST/kendex_9.9.9_amd64.AppImage"
  printf 'a signature' >"$DIST/kendex_9.9.9_amd64.AppImage.sig"
  printf 'a package' >"$DIST/kendex_9.9.9_amd64.deb"
}

# Errexit is on, so a refusal is captured through an `if` rather than
# ending the suite that is asking for it.
run() { # run TARGET VERSION [DIST]
  if OUT=$("$DIGESTS" --document-only "$1" "$2" "${3-$DIST}" 2>&1); then
    RC=0
  else
    RC=$?
  fi
}

document() { printf '%s/digests-%s.json' "$DIST" "$1"; }

field() { # field NAME FILE
  sed -n "s/.*\"$1\": \"\\([^\"]*\\)\".*/\\1/p" "$2"
}

# --- refusals ---------------------------------------------------------

linux_lane
run aarch64-unknown-linux-musl 9.9.9
[ "$RC" -ne 0 ] && case "$OUT" in *"not a target this release builds"*) true ;; *) false ;; esac &&
  ok "a target the release does not build is refused" ||
  bad "a target the release does not build is refused" "rc=$RC out=$OUT"

run x86_64-unknown-linux-gnu '9.9.9", "target": "elsewhere'
[ "$RC" -ne 0 ] && case "$OUT" in *"not a version"*) true ;; *) false ;; esac &&
  ok "a version carrying JSON of its own is refused" ||
  bad "a version carrying JSON of its own is refused" "rc=$RC out=$OUT"

run x86_64-unknown-linux-gnu 9.9.9 "$TMP/never-staged"
[ "$RC" -ne 0 ] && case "$OUT" in *"is not a directory"*) true ;; *) false ;; esac &&
  ok "a lane that staged nothing is refused" ||
  bad "a lane that staged nothing is refused" "rc=$RC out=$OUT"

linux_lane
rm "$DIST/kendex-x86_64-unknown-linux-gnu"
run x86_64-unknown-linux-gnu 9.9.9
[ "$RC" -ne 0 ] && case "$OUT" in *"holds no kendex command"*) true ;; *) false ;; esac &&
  ok "a lane missing its command is refused" ||
  bad "a lane missing its command is refused" "rc=$RC out=$OUT"
[ ! -f "$(document x86_64-unknown-linux-gnu)" ] &&
  ok "a refused lane leaves no document behind" ||
  bad "a refused lane leaves no document behind" "$(cat "$(document x86_64-unknown-linux-gnu)")"

linux_lane
rm "$DIST/kendex_9.9.9_amd64.AppImage"
run x86_64-unknown-linux-gnu 9.9.9
[ "$RC" -ne 0 ] && case "$OUT" in *"holds no app download"*) true ;; *) false ;; esac &&
  ok "a lane missing its app download is refused" ||
  bad "a lane missing its app download is refused" "rc=$RC out=$OUT"

linux_lane
printf 'another release' >"$DIST/kendex_5.0.0_amd64.AppImage"
run x86_64-unknown-linux-gnu 9.9.9
[ "$RC" -ne 0 ] && case "$OUT" in *"more than one app download"*) true ;; *) false ;; esac &&
  ok "two app downloads in one lane are refused rather than picked between" ||
  bad "two app downloads in one lane are refused rather than picked between" "rc=$RC out=$OUT"

# --- the document ------------------------------------------------------

linux_lane
run x86_64-unknown-linux-gnu 9.9.9
DOC=$(document x86_64-unknown-linux-gnu)
[ "$RC" -eq 0 ] && [ -f "$DOC" ] &&
  ok "the lane above, with nothing missing, writes its document" ||
  bad "the lane above, with nothing missing, writes its document" "rc=$RC out=$OUT"

[ "$(field version "$DOC")" = "9.9.9" ] && [ "$(field target "$DOC")" = "x86_64-unknown-linux-gnu" ] &&
  ok "the document names the release and the target it was written for" ||
  bad "the document names the release and the target it was written for" "$(cat "$DOC")"

expect_command=$(sha256sum "$DIST/kendex-x86_64-unknown-linux-gnu" | cut -d' ' -f1)
expect_app=$(sha256sum "$DIST/kendex_9.9.9_amd64.AppImage" | cut -d' ' -f1)
[ "$(field command "$DOC")" = "$expect_command" ] && [ "$(field app "$DOC")" = "$expect_app" ] &&
  ok "each digest is plain SHA-256 over the download it names" ||
  bad "each digest is plain SHA-256 over the download it names" "$(cat "$DOC")"

# The document is what a client parses, so a lane that wrote something
# only sed can read would pass every check above and fail in the field.
if command -v jq >/dev/null 2>&1; then
  jq -e '.schema == 1 and (.command | test("^[0-9a-f]{64}$")) and (.app | test("^[0-9a-f]{64}$"))' \
    "$DOC" >/dev/null 2>&1 &&
    ok "the document is JSON carrying the schema this build reads" ||
    bad "the document is JSON carrying the schema this build reads" "$(cat "$DOC")"
fi

# --- the lanes this host cannot build ----------------------------------

rm -rf "$DIST"
mkdir -p "$DIST"
printf 'the windows command' >"$DIST/kendex-x86_64-pc-windows-msvc.exe"
printf 'the windows installer' >"$DIST/kendex_9.9.9_x64-setup.exe"
printf 'a signature' >"$DIST/kendex_9.9.9_x64-setup.exe.sig"
run x86_64-pc-windows-msvc 9.9.9
DOC=$(document x86_64-pc-windows-msvc)
[ "$RC" -eq 0 ] &&
  [ "$(field command "$DOC")" = "$(sha256sum "$DIST/kendex-x86_64-pc-windows-msvc.exe" | cut -d' ' -f1)" ] &&
  [ "$(field app "$DOC")" = "$(sha256sum "$DIST/kendex_9.9.9_x64-setup.exe" | cut -d' ' -f1)" ] &&
  ok "the Windows lane measures the .exe command and the installer" ||
  bad "the Windows lane measures the .exe command and the installer" "rc=$RC out=$OUT"

rm -rf "$DIST"
mkdir -p "$DIST"
printf 'the mac command' >"$DIST/kendex-aarch64-apple-darwin"
printf 'the mac archive' >"$DIST/kendex-aarch64-apple-darwin.app.tar.gz"
printf 'a signature' >"$DIST/kendex-aarch64-apple-darwin.app.tar.gz.sig"
printf 'a disk image' >"$DIST/kendex_9.9.9_aarch64.dmg"
run aarch64-apple-darwin 9.9.9
DOC=$(document aarch64-apple-darwin)
[ "$RC" -eq 0 ] &&
  [ "$(field app "$DOC")" = "$(sha256sum "$DIST/kendex-aarch64-apple-darwin.app.tar.gz" | cut -d' ' -f1)" ] &&
  ok "the macOS lane measures the archive its updater installs, not the dmg" ||
  bad "the macOS lane measures the archive its updater installs, not the dmg" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
