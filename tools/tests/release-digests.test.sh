#!/usr/bin/env bash
# tools/release-digests --document-only: a lane names its two downloads by
# the rules the release publishes them under, measures each with SHA-256,
# and writes one document naming the version and the target; a lane it
# cannot account for is refused with nothing written. Signing is not
# driven here: it needs the release secret, so --document-only is the mode
# a test can run.
#
# Every run renders as `rc=<n> out=<o> doc=<d>`:
#   out  the run's stable first line, `<key>=<value>`, with the
#        `release-digests: ` prefix off; `-` when the run said nothing; every
#        line verbatim joined by `;` when it said something carrying no such
#        line, so a run that stopped some other way cannot render as one that
#        stopped for the row's reason
#   doc  the document DIST/digests-TARGET.json: `absent`, or its fields as
#        `schema=<n> version=<v> target=<t> command=<hex> app=<hex>` read
#        through jq, or `unparsed:<text>` when jq cannot read it
#
# The refusals table is `label|world|target|version|rc|first|document`:
#   world     what the Linux x86_64 lane staged, as words `build` maps onto
#             files: `command`, `app`, `sig` (the app's signature), `app2`
#             (another release's app download), `unstaged` (no directory)
#   first     the `<key>=<value>` only that `die` call emits. Every `die`
#             exits 1, so the key and its value are the one thing that
#             separates one refusal from another; the English under that line
#             is not pinned.
#   document  `absent`: a lane that half-wrote a document would publish a
#             statement it never measured, so every refusal row checks it.
#
# The lanes table is `label|target|staged|command file|app file`:
#   staged        the files the lane's staging step left in DIST, each
#                 written with its own name as content so no two share a
#                 digest
#   command file  the download the document's `command` must measure
#   app file      the download its `app` must measure
# The expected digests come from the host's sha256sum or shasum, the same
# pick the script makes and the independent oracle of its arithmetic.
#
# jq is required: the document is a contract a client parses as JSON, and
# a check that only sed can read would pass a document no client can.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIGESTS="$(cd "$TEST_DIR/.." && pwd)/release-digests"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT
DIST="$TMP/dist"
VERSION=9.9.9
PASS=0
FAIL=0

command -v jq >/dev/null 2>&1 || {
  echo 'jq is required: the document under test is parsed as JSON by every client' >&2
  exit 1
}

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

# The same pick tools/release-digests makes, for the same reason: macOS
# ships shasum and no sha256sum.
sha256() { # FILE — the file's SHA-256 in lowercase hex
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1"
  else
    shasum -a 256 "$1"
  fi | cut -d' ' -f1
}

# stage FILE... — a fresh DIST holding each file, its name as its content.
stage() {
  local file
  rm -rf "$DIST"
  mkdir -p "$DIST"
  for file in "$@"; do
    printf '%s' "$file" >"$DIST/$file"
  done
}

# build WORLD — the Linux x86_64 lane's DIST from the world's words.
build() {
  local word files=""
  for word in $1; do
    case "$word" in
      command) files="$files kendex-x86_64-unknown-linux-gnu" ;;
      app) files="$files kendex_${VERSION}_amd64.AppImage" ;;
      sig) files="$files kendex_${VERSION}_amd64.AppImage.sig" ;;
      app2) files="$files kendex_5.0.0_amd64.AppImage" ;;
      unstaged) rm -rf "$DIST"; return ;;
      *) printf 'build: no file is staged for the word %s\n' "$word" >&2; exit 1 ;;
    esac
  done
  # shellcheck disable=SC2086
  stage $files
}

out_text() { # — the run's stable first line, `-` when it said nothing
  local text first
  text="$(cat "$TMP/out")"
  [[ "$text" != "" ]] || { printf -- '-'; return; }
  first="$(awk '/^release-digests: / { sub(/^release-digests: /, ""); print; exit }' "$TMP/out")"
  if [[ "$first" != "" ]]; then
    printf '%s' "$first"
  else
    printf '%s' "$text" | paste -s -d ';' -
  fi
}

doc_text() { # TARGET — the document's fields, `absent`, or `unparsed:<text>`
  local doc="$DIST/digests-$1.json" fields
  [[ -e "$doc" ]] || { printf 'absent'; return; }
  # schema keeps its JSON type: a client reads it as a number, so a quoted
  # "1" renders with its quotes and reddens the row.
  if fields="$(jq -r '"schema=\(.schema|tojson) version=\(.version) target=\(.target) command=\(.command) app=\(.app)"' "$doc" 2>/dev/null)"; then
    printf '%s' "$fields"
  else
    printf 'unparsed:%s' "$(paste -s -d ';' - <"$doc")"
  fi
}

run() { # TARGET VERSION
  local rc=0
  "$DIGESTS" --document-only "$1" "$2" "$DIST" >"$TMP/out" 2>&1 || rc=$?
  printf 'rc=%s out=%s doc=%s' "$rc" "$(out_text)" "$(doc_text "$1")"
}

fields_present() { # ROW FIELD... — a row with an empty field asserts nothing
  local row="$1" field
  shift
  for field in "$@"; do
    [[ "$field" != "" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
  done
}

# A rendering aid for writing rows: every table renders, then the run is
# refused.
probe() { # LABEL GOT
  [[ "${TOOLS_TABLE_PROBE:-}" == 1 ]] || return 1
  printf '%s => %s\n' "$1" "$2"
}

asserted() { # BEFORE — refuses a table that asserted no row past that tally
  [[ "${TOOLS_TABLE_PROBE:-}" != 1 ]] || return 0
  [[ "$((PASS + FAIL))" -gt "$1" ]] || { echo "no row was asserted" >&2; exit 2; }
}

run_refusals() {
  local title="$1" rows="$2" label world target version rc first document got row before=$((PASS + FAIL))
  echo "=== $title ==="
  while IFS= read -r row; do
    [[ "$row" != "" ]] || continue
    IFS='|' read -r label world target version rc first document <<<"$row"
    fields_present "$row" "$label" "$world" "$target" "$version" "$rc" "$first" "$document"
    build "$world"
    got="$(run "$target" "$version")"
    probe "$label" "$got" && continue
    assert_eq "$got" "rc=$rc out=$first doc=$document" "$label"
  done <<<"$rows"
  asserted "$before"
}

run_lanes() {
  local title="$1" rows="$2" label target staged command_file app_file got row before=$((PASS + FAIL))
  echo "=== $title ==="
  while IFS= read -r row; do
    [[ "$row" != "" ]] || continue
    IFS='|' read -r label target staged command_file app_file <<<"$row"
    fields_present "$row" "$label" "$target" "$staged" "$command_file" "$app_file"
    # shellcheck disable=SC2086
    stage $staged
    got="$(run "$target" "$VERSION")"
    probe "$label" "$got" && continue
    assert_eq "$got" "rc=0 out=- doc=schema=1 version=$VERSION target=$target command=$(sha256 "$DIST/$command_file") app=$(sha256 "$DIST/$app_file")" "$label"
  done <<<"$rows"
  asserted "$before"
}

run_refusals "the refusals, each leaving no document" "\
a target the release does not build is refused|command app sig|aarch64-unknown-linux-musl|9.9.9|1|target=aarch64-unknown-linux-musl|absent
a version carrying JSON of its own is refused|command app sig|x86_64-unknown-linux-gnu|9.9.9\", \"target\": \"elsewhere|1|version=9.9.9\", \"target\": \"elsewhere|absent
a lane that staged nothing is refused|unstaged|x86_64-unknown-linux-gnu|9.9.9|1|not-a-directory=$DIST|absent
a lane missing its command is refused|app sig|x86_64-unknown-linux-gnu|9.9.9|1|missing=kendex-x86_64-unknown-linux-gnu|absent
a lane missing its app download is refused|command sig|x86_64-unknown-linux-gnu|9.9.9|1|missing=kendex_*_amd64.AppImage|absent
two app downloads in one lane are refused rather than picked between|command app app2 sig|x86_64-unknown-linux-gnu|9.9.9|1|ambiguous=kendex_*_amd64.AppImage|absent
"

run_lanes "the lanes, each measuring the two downloads its updater installs" "\
the Linux lane measures the command and the AppImage, not the deb or the signature|x86_64-unknown-linux-gnu|kendex-x86_64-unknown-linux-gnu kendex_9.9.9_amd64.AppImage kendex_9.9.9_amd64.AppImage.sig kendex_9.9.9_amd64.deb|kendex-x86_64-unknown-linux-gnu|kendex_9.9.9_amd64.AppImage
the Windows lane measures the .exe command and the installer|x86_64-pc-windows-msvc|kendex-x86_64-pc-windows-msvc.exe kendex_9.9.9_x64-setup.exe kendex_9.9.9_x64-setup.exe.sig|kendex-x86_64-pc-windows-msvc.exe|kendex_9.9.9_x64-setup.exe
the macOS lane measures the archive its updater installs, not the dmg|aarch64-apple-darwin|kendex-aarch64-apple-darwin kendex-aarch64-apple-darwin.app.tar.gz kendex-aarch64-apple-darwin.app.tar.gz.sig kendex_9.9.9_aarch64.dmg|kendex-aarch64-apple-darwin|kendex-aarch64-apple-darwin.app.tar.gz
"

[[ "${TOOLS_TABLE_PROBE:-}" != 1 ]] || { echo "a probe run renders rows instead of asserting them" >&2; exit 2; }
printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
