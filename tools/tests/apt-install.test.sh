#!/usr/bin/env bash
# Surface: tools/apt-install. Inputs: that script.
# A fake sudo and apt-get stand in for the runner's: apt-get records each
# call as `<mirror> <verb> <packages>` and keeps a copy of the sources file the
# call read. The mirror is `image` when the call read the image's sources
# file and `official` otherwise.
#
# The rows table is `label|fail|rc|calls`:
#   fail    the `<mirror>:<verb>` calls that exit 100, `-` for none
#   rc      the tool's exit status
#   calls   the apt-get calls in order, `;`-separated
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
case " $FAKE_FAIL " in *" $mirror:$verb "*) exit 100 ;; esac
APT
chmod +x "$TMP_ROOT/bin/sudo" "$TMP_ROOT/bin/apt-get"

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

run_tool() { # FAIL PACKAGE...
  local fail="$1"
  shift
  rm -rf -- "$TMP_ROOT/log" "$TMP_ROOT/runner-temp"
  mkdir -p "$TMP_ROOT/log" "$TMP_ROOT/runner-temp"
  : >"$TMP_ROOT/log/calls"
  RC=0
  env -i PATH="$TMP_ROOT/bin:$PATH" RUNNER_TEMP="$TMP_ROOT/runner-temp" \
    APT_ACQUIRE_OPTIONS='-o Acquire::Retries=3 -o Acquire::https::Timeout=30' \
    APT_IMAGE_SOURCES="$TMP_ROOT/ubuntu.sources" \
    FAKE_LOG_DIR="$TMP_ROOT/log" FAKE_FAIL="$fail" \
    "$BASH" "$TOOL" "$@" >"$TMP_ROOT/out" 2>&1 || RC=$?
  CALLS="$(cat "$TMP_ROOT/log/calls")"
}

ROWS='
official installs|-|0|official update;official install libdbus-1-dev libgtk-3-dev;
official update fails|official:update|0|official update;image update;image install libdbus-1-dev libgtk-3-dev;
official install fails after an update that warned|official:install|0|official update;official install libdbus-1-dev libgtk-3-dev;image update;image install libdbus-1-dev libgtk-3-dev;
both updates fail|official:update image:update|1|official update;image update;
both installs fail|official:install image:install|1|official update;official install libdbus-1-dev libgtk-3-dev;image update;image install libdbus-1-dev libgtk-3-dev;
'
while IFS='|' read -r label fail rc calls; do
  [ -n "$label" ] || continue
  [ "$fail" != - ] || fail=''
  run_tool "$fail" libdbus-1-dev libgtk-3-dev
  assert_eq "$RC" "$rc" "$label: exit"
  assert_eq "$CALLS" "$calls" "$label: apt-get calls"
  assert_eq "$(cat "$TMP_ROOT/log/official.sources")" "$OFFICIAL_BYTES" "$label: first try reads archive.ubuntu.com with the image's suites and key"
  assert_eq "$(cat "$TMP_ROOT/ubuntu.sources")" "$IMAGE_BYTES" "$label: the image's sources are unchanged"
  assert_eq "$(ls -A "$TMP_ROOT/runner-temp")" '' "$label: the rewritten copy is removed"
done <<<"$ROWS"

run_tool official:update libdbus-1-dev
assert_eq "$(cat "$TMP_ROOT/log/image.sources")" "$IMAGE_BYTES" "fallback reads the image's own sources"

run_tool -
assert_eq "$RC" 2 "no package: usage"
assert_eq "$CALLS" '' "no package: no apt-get call"

printf 'pass: %s   fail: 0\n' "$PASS"
