#!/usr/bin/env bash
# Surface: tools/apt-install. Inputs: that script.
# A fake sudo, dpkg and apt-get stand in for the runner's: dpkg prints the
# row's architecture, and apt-get records each call as
# `<mirror> <verb> <packages>` and keeps a copy of the sources file the call
# read. The mirror is `image` when the call read the image's sources file and
# `official` otherwise.
#
# The rows table is `label|arch|fail|rc|calls|out`:
#   arch    what dpkg prints, `-` for a dpkg that fails
#   fail    the `<mirror>:<verb>:<status>` calls that fail with that status,
#           `-` for none
#   rc      the tool's exit status
#   calls   the apt-get calls in order, `;`-terminated
#   out     the tool's output lines, `;`-terminated, `-` for none. The
#           `::warning` line is a workflow command the Actions runner turns
#           into the run summary's annotation, and the `apt-install:` line is
#           the keyed refusal the header defines.
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TOOL="$(cd -- "$TEST_DIR/.." && pwd -P)/apt-install"
TMP_ROOT="$(mktemp -d)" || { echo 'apt-install.test: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "apt-install.test: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'apt-install.test: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

PASS=0
assert_eq() {
  [[ $1 == "$2" ]] || { printf 'FAIL: %s: expected [%s], got [%s]\n' "$3" "$2" "$1" >&2; exit 1; }
  PASS=$((PASS + 1))
  printf 'ok: %s\n' "$3"
}

mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/sudo" <<'SUDO'
#!/usr/bin/env bash
exec "$@"
SUDO
cat >"$TMP_ROOT/bin/apt-get" <<'APT'
#!/usr/bin/env bash
set -euo pipefail
sourcelist='' sourceparts='' timeout='' verb='' packages=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      case "$2" in
        Dir::Etc::sourcelist=*) sourcelist="${2#*=}" ;;
        Dir::Etc::sourceparts=*) sourceparts="${2#*=}" ;;
        Acquire::https::Timeout=*) timeout="${2#*=}" ;;
      esac
      shift 2 ;;
    -y) shift ;;
    update | install) verb="$1"; shift ;;
    *) packages+=("$1"); shift ;;
  esac
done
[ "$sourceparts" = /dev/null ] || { echo "sourceparts=$sourceparts" >&2; exit 90; }
[ "$timeout" = 30 ] || { echo "acquire-timeout=$timeout" >&2; exit 91; }
mirror=official
[ "$sourcelist" != "$APT_IMAGE_SOURCES" ] || mirror=image
cp -- "$sourcelist" "$FAKE_LOG_DIR/$mirror.sources"
call="$mirror $verb"
[ "${#packages[@]}" -eq 0 ] || call+=" ${packages[*]}"
printf '%s;' "$call" >>"$FAKE_LOG_DIR/calls"
for failure in $FAKE_FAIL; do
  [ "${failure%:*}" != "$mirror:$verb" ] || exit "${failure##*:}"
done
APT
cat >"$TMP_ROOT/bin/dpkg" <<'DPKG'
#!/usr/bin/env bash
[ "$*" = --print-architecture ] && [ -n "$FAKE_ARCH" ] || exit 2
printf '%s\n' "$FAKE_ARCH"
DPKG
chmod +x "$TMP_ROOT/bin/sudo" "$TMP_ROOT/bin/apt-get" "$TMP_ROOT/bin/dpkg"

# The two URI forms the image's sources carry for the Ubuntu archive.
cat >"$TMP_ROOT/ubuntu.sources" <<'SOURCES'
Types: deb
URIs: mirror+file:/etc/apt/apt-mirrors.txt
Suites: noble noble-updates noble-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://azure.archive.ubuntu.com/ubuntu/
Suites: noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SOURCES
IMAGE_BYTES="$(cat "$TMP_ROOT/ubuntu.sources")"
OFFICIAL_BYTES='Types: deb
URIs: https://archive.ubuntu.com/ubuntu/
Suites: noble noble-updates noble-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg'

run_tool() { # ARCH FAIL PACKAGE...
  local arch="$1" fail="$2" line
  shift 2
  rm -rf -- "$TMP_ROOT/log" "$TMP_ROOT/runner-temp"
  mkdir -p "$TMP_ROOT/log" "$TMP_ROOT/runner-temp"
  : >"$TMP_ROOT/log/calls"
  RC=0
  env -i PATH="$TMP_ROOT/bin:$PATH" RUNNER_TEMP="$TMP_ROOT/runner-temp" \
    APT_ACQUIRE_OPTIONS='-o Acquire::Retries=3 -o Acquire::https::Timeout=30' \
    APT_IMAGE_SOURCES="$TMP_ROOT/ubuntu.sources" \
    FAKE_LOG_DIR="$TMP_ROOT/log" FAKE_FAIL="$fail" FAKE_ARCH="$arch" \
    "$BASH" "$TOOL" "$@" >"$TMP_ROOT/out" 2>&1 || RC=$?
  CALLS="$(cat "$TMP_ROOT/log/calls")"
  OUT=''
  while IFS= read -r line; do OUT+="$line;"; done <"$TMP_ROOT/out"
}

ROWS="
official installs|amd64|-|0|official update;official install libdbus-1-dev libgtk-3-dev;|-
official update fails|amd64|official:update:100|0|official update;image update;image install libdbus-1-dev libgtk-3-dev;|::warning title=apt mirror::apt-get update from archive.ubuntu.com sources exited 100, retrying with the runner image's sources;
official install fails after an update that warned|amd64|official:install:100|0|official update;official install libdbus-1-dev libgtk-3-dev;image update;image install libdbus-1-dev libgtk-3-dev;|::warning title=apt mirror::apt-get install from archive.ubuntu.com sources exited 100, retrying with the runner image's sources;
both updates fail|amd64|official:update:100 image:update:1|1|official update;image update;|::warning title=apt mirror::apt-get update from archive.ubuntu.com sources exited 100, retrying with the runner image's sources;apt-install: install=failed official=update:100 image=update:1;
both installs fail|amd64|official:install:100 image:install:100|1|official update;official install libdbus-1-dev libgtk-3-dev;image update;image install libdbus-1-dev libgtk-3-dev;|::warning title=apt mirror::apt-get install from archive.ubuntu.com sources exited 100, retrying with the runner image's sources;apt-install: install=failed official=install:100 image=install:100;
arm64 installs from the image only|arm64|-|0|image update;image install libdbus-1-dev libgtk-3-dev;|-
arm64 image install fails|arm64|image:install:100|1|image update;image install libdbus-1-dev libgtk-3-dev;|apt-install: install=failed image=install:100;
architecture unreadable|-|-|1||apt-install: arch=unreadable;
"
while IFS='|' read -r label arch fail rc calls out; do
  [ -n "$label" ] || continue
  [ "$arch" != - ] || arch=''
  [ "$fail" != - ] || fail=''
  [ "$out" != - ] || out=''
  run_tool "$arch" "$fail" libdbus-1-dev libgtk-3-dev
  assert_eq "$RC" "$rc" "$label: exit"
  assert_eq "$CALLS" "$calls" "$label: apt-get calls"
  assert_eq "$OUT" "$out" "$label: output"
  [ "$arch" != amd64 ] ||
    assert_eq "$(cat "$TMP_ROOT/log/official.sources")" "$OFFICIAL_BYTES" "$label: first try reads archive.ubuntu.com with the image's suites and key"
  assert_eq "$(cat "$TMP_ROOT/ubuntu.sources")" "$IMAGE_BYTES" "$label: the image's sources are unchanged"
  assert_eq "$(ls -A "$TMP_ROOT/runner-temp")" '' "$label: the rewritten copy is removed"
done <<<"$ROWS"

run_tool amd64 official:update:100 libdbus-1-dev
assert_eq "$(cat "$TMP_ROOT/log/image.sources")" "$IMAGE_BYTES" "fallback reads the image's own sources"

run_tool amd64 ''
assert_eq "$RC" 2 "no package: usage"
assert_eq "$CALLS" '' "no package: no apt-get call"

printf 'pass: %s   fail: 0\n' "$PASS"
