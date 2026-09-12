#!/usr/bin/env bash
# tools/publish-aur: what it refuses, when it defers a package, what a dry
# run leaves alone, and what a push lands. Every run is over a copy of the
# world tools/tests/lib/aur-world.sh builds, whose curl and git stubs keep
# the script off the network: the "AUR" is a bare repository per package and
# the "release" is whatever the row put in downloads/.
#
# A run renders as `rc=<n> keys=<k=v,...>`: the exit status and every
# `publish-aur: <key>=<value>` line the run wrote, stdout and stderr
# together, in order and joined by `,`. The English under a keyed line is
# not pinned. Lines from tools/check-aur-sync are not keys of this script
# and are read only by the drift row, which pins its first line.
#
# The rows table is `label|release|argv|rc|keys`:
#   release  what downloads/ holds before the run: `ready` both commands
#            with the bytes the shipped fixture pins; `none` nothing; `wrong`
#            the x86_64 command with other bytes; `down` a curl that exits 7
#            on every call; `500` a HEAD on the x86_64 command answering 500;
#            `bin-ready` the icon, the AppImage and the command kendex-bin
#            pins, each with its bytes
#
# The fixture's kendex recipe pins aarch64 to the placeholder, as the real
# one does today. Every row but the placeholder one runs `ship`, which fills
# that pin with the aarch64 command's sha256, so the rows read the release
# checks; the placeholder row reads the deferral that comes before them.
#   argv     the arguments as written
#   keys     the keyed lines, `-` for none
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/aur-world.sh
. "$TEST_DIR/lib/aur-world.sh"
TMP="$(mktemp -d)" || { echo "publish-aur.test: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

command -v python3 >/dev/null 2>&1 || {
  echo 'python3 is required: tools/publish-aur reads its recipes through tools/check-aur-sync' >&2
  exit 1
}

aur_world "$TMP/pristine"

world() { # NAME — a fresh copy of the pristine world at $TMP/w-NAME
  local dir="$TMP/w-$1"
  rm -rf -- "$dir"
  cp -R -- "$TMP/pristine" "$dir"
  printf '%s\n' "$dir"
}

release() { # WORLD-DIR NAME — downloads/ as the rows table describes NAME
  local d="$1/downloads"
  rm -rf -- "$d"
  mkdir -p -- "$d"
  case "$2" in
    ready)
      printf 'x86_64 cli bytes' >"$d/kendex-x86_64"
      printf 'aarch64 cli bytes' >"$d/kendex-aarch64"
      ;;
    none) ;;
    wrong) printf 'other bytes' >"$d/kendex-x86_64" ;;
    down) printf '7\n' >"$d/exit" ;;
    500)
      printf 'x86_64 cli bytes' >"$d/kendex-x86_64"
      printf '500' >"$d/kendex-x86_64.status"
      ;;
    bin-ready)
      printf 'icon bytes' >"$d/icon.png"
      printf 'x86_64 app bytes' >"$d/kendex_1.2.3_amd64.AppImage"
      printf 'x86_64 cli bytes' >"$d/kendex-x86_64"
      ;;
    *) echo "publish-aur.test: no such release: $2" >&2; exit 1 ;;
  esac
}

# run WORLD-DIR ARGV... — sets RC, OUT, KEYS (the keyed lines joined by `,`)
run() {
  local dir="$1" line
  shift
  RC=0
  OUT="$(cd "$dir/tree" && PATH="$dir/bin:$PATH" tools/publish-aur "$@" 2>&1)" || RC=$?
  KEYS=""
  while IFS= read -r line; do
    case "$line" in
      'publish-aur: '*) KEYS="$KEYS,${line#publish-aur: }" ;;
    esac
  done <<EOF
$OUT
EOF
  KEYS="${KEYS#,}"
  [ -n "$KEYS" ] || KEYS="-"
}

# aur_head WORLD-DIR PACKAGE — the commit the world's AUR holds for PACKAGE
aur_head() { git --git-dir="$1/aur/$2.git" rev-parse master; }

# ship WORLD-DIR — kendex's aarch64 pin filled with the release's sha256 in
# both files, committed, so the recipe carries no placeholder.
ship() {
  local recipe="$1/tree/packaging/arch/kendex" sum
  sum="$(aur_world_sha256 'aarch64 cli bytes')"
  sed -i.bak "s/$AUR_WORLD_PLACEHOLDER/$sum/" "$recipe/PKGBUILD" "$recipe/.SRCINFO"
  rm -- "$recipe/PKGBUILD.bak" "$recipe/.SRCINFO.bak"
  grep -q "$AUR_WORLD_PLACEHOLDER" "$recipe/PKGBUILD" "$recipe/.SRCINFO" && { echo "publish-aur.test: ship left a placeholder" >&2; exit 1; }
  git -C "$1/tree" -c user.name=world -c user.email=world@example.invalid commit --quiet -am 'ship aarch64'
}

# Every deferral and refusal, and what a dry run says, with the AUR behind
# the tree: the world's AUR holds the fixture, so the tree is bumped first.
bump() { # WORLD-DIR — kendex's recipe at pkgrel=2 in both files, committed
  local recipe="$1/tree/packaging/arch/kendex"
  sed -i.bak 's/^pkgrel=1$/pkgrel=2/' "$recipe/PKGBUILD" && rm -- "$recipe/PKGBUILD.bak"
  sed -i.bak 's/^	pkgrel = 1$/	pkgrel = 2/' "$recipe/.SRCINFO" && rm -- "$recipe/.SRCINFO.bak"
  grep -q '^pkgrel=2$' "$recipe/PKGBUILD" || { echo "publish-aur.test: the bump did not take" >&2; exit 1; }
  grep -q '^	pkgrel = 2$' "$recipe/.SRCINFO" || { echo "publish-aur.test: the bump did not take" >&2; exit 1; }
  git -C "$1/tree" -c user.name=world -c user.email=world@example.invalid commit --quiet -am 'bump'
}

rows='
release ready, dry run|ready|--dry-run kendex|0|changed=kendex,dry-run=kendex
release absent|none|--dry-run kendex|0|deferred=kendex
release bytes differ|wrong|--dry-run kendex|0|deferred=kendex
host unreachable|down|--dry-run kendex|1|unreachable=https://example.invalid/v1.2.3/kendex-x86_64
status 500|500|--dry-run kendex|1|status=500
git source needs no release|none|--dry-run kendex-git|0|unchanged=kendex-git
icons and per-arch downloads|bin-ready|--dry-run kendex-bin|0|unchanged=kendex-bin
absent package is skipped, the rest go on|none|--dry-run kendex kendex-git|0|deferred=kendex,unchanged=kendex-git
unknown option|none|--nope|2|option=--nope
unknown package|none|--dry-run vgs-shell|2|package=vgs-shell
'
while IFS='|' read -r label rel argv rc keys; do
  [ -n "$label" ] || continue
  dir="$(world row)"
  ship "$dir"
  bump "$dir"
  release "$dir" "$rel"
  before="$(aur_head "$dir" kendex)"
  # shellcheck disable=SC2086
  run "$dir" $argv
  after="$(aur_head "$dir" kendex)"
  if [ "$RC" = "$rc" ] && [ "$KEYS" = "$keys" ]; then
    ok "$label: rc=$rc keys=$keys"
  else
    bad "$label: want rc=$rc keys=$keys" "got rc=$RC keys=$KEYS
$OUT"
  fi
  if [ "$before" = "$after" ]; then
    ok "$label: the AUR was not written"
  else
    bad "$label: the AUR was written" "$before -> $after"
  fi
done <<EOF
$rows
EOF

# A recipe still pinning a target to the placeholder is deferred before any
# request, release or not: the fixture as shipped, with its release up.
dir="$(world placeholder)"
bump "$dir"
release "$dir" ready
before="$(aur_head "$dir" kendex)"
run "$dir" kendex
after="$(aur_head "$dir" kendex)"
if [ "$RC" = 0 ] && [ "$KEYS" = "deferred=kendex" ] && [ "$before" = "$after" ]; then
  ok "placeholder pin: rc=0 keys=$KEYS, the AUR was not written"
else
  bad "placeholder pin: want rc=0 keys=deferred=kendex and no push" "got rc=$RC keys=$KEYS $before -> $after
$OUT"
fi
case "$OUT" in
  *'kendex-aarch64'*'placeholder'*) ok "placeholder pin: the line names the file and the pin" ;;
  *) bad "placeholder pin: the line names the file and the pin" "$OUT" ;;
esac

# A dry run shows the whole diff, so a reader can review what a push would carry.
dir="$(world diff)"
ship "$dir"
bump "$dir"
release "$dir" ready
run "$dir" --dry-run kendex
case "$OUT" in
  *'-pkgrel=1'*'+pkgrel=2'*) ok "dry run prints the diff" ;;
  *) bad "dry run prints the diff" "$OUT" ;;
esac

# A drifted tree is refused before any AUR repository is read.
dir="$(world drift)"
recipe="$dir/tree/packaging/arch/kendex"
sed -i.bak 's/^pkgrel=1$/pkgrel=2/' "$recipe/PKGBUILD" && rm -- "$recipe/PKGBUILD.bak"
grep -q '^pkgrel=2$' "$recipe/PKGBUILD" || { echo "publish-aur.test: the drift did not take" >&2; exit 1; }
release "$dir" ready
run "$dir" --dry-run kendex
first="${OUT%%$'\n'*}"
if [ "$RC" = 1 ] && [ "$first" = "check-aur-sync: drift=1" ] && [ "$KEYS" = "-" ]; then
  ok "drifted recipes: rc=1 first=check-aur-sync: drift=1, no package reached"
else
  bad "drifted recipes" "rc=$RC first=$first keys=$KEYS"
fi

# A push lands the tree's files on the AUR's master and verifies them there.
dir="$(world push)"
ship "$dir"
bump "$dir"
release "$dir" ready
before="$(aur_head "$dir" kendex)"
run "$dir" kendex
after="$(aur_head "$dir" kendex)"
if [ "$RC" = 0 ] && [ "$KEYS" = "changed=kendex,pushed=kendex" ]; then
  ok "push: rc=0 keys=$KEYS"
else
  bad "push" "rc=$RC keys=$KEYS
$OUT"
fi
if [ "$before" != "$after" ] &&
  [ "$(git --git-dir="$dir/aur/kendex.git" show master:PKGBUILD)" = "$(cat "$dir/tree/packaging/arch/kendex/PKGBUILD")" ] &&
  [ "$(git --git-dir="$dir/aur/kendex.git" show master:.SRCINFO)" = "$(cat "$dir/tree/packaging/arch/kendex/.SRCINFO")" ]; then
  ok "push: the AUR's master holds the tree's PKGBUILD and .SRCINFO"
else
  bad "push: the AUR's master holds the tree's files" "$before -> $after"
fi
case "$OUT" in
  *'AUR recipes match this repo (kendex)'*) ok "push: verified against the AUR afterwards" ;;
  *) bad "push: verified against the AUR afterwards" "$OUT" ;;
esac
subject="$(git --git-dir="$dir/aur/kendex.git" log -1 --format=%s master)"
revision="$(git -C "$dir/tree" rev-parse --short HEAD)"
if [ "$subject" = "sync from vanillagreencom/kendex $revision" ]; then
  ok "push: the commit names this tree's revision"
else
  bad "push: the commit names this tree's revision" "$subject"
fi

# A second run after the push finds nothing to do.
run "$dir" kendex
if [ "$RC" = 0 ] && [ "$KEYS" = "unchanged=kendex" ]; then
  ok "push again: unchanged"
else
  bad "push again: unchanged" "rc=$RC keys=$KEYS"
fi

# A recipe naming a scriptlet publishes it beside PKGBUILD and .SRCINFO:
# left behind, every AUR build of the package fails on the missing file.
dir="$(world scriptlet)"
ship "$dir"
recipe="$dir/tree/packaging/arch/kendex"
awk '{ print } /^options=/ { print "install=kendex.install" }' "$recipe/PKGBUILD" >"$recipe/PKGBUILD.new" && mv -- "$recipe/PKGBUILD.new" "$recipe/PKGBUILD"
awk '{ print } /^\toptions = / { print "\tinstall = kendex.install" }' "$recipe/.SRCINFO" >"$recipe/.SRCINFO.new" && mv -- "$recipe/.SRCINFO.new" "$recipe/.SRCINFO"
printf 'post_install() { :; }\n' >"$recipe/kendex.install"
grep -q '^install=kendex.install$' "$recipe/PKGBUILD" && grep -q '^	install = kendex.install$' "$recipe/.SRCINFO" || { echo "publish-aur.test: the scriptlet edit did not take" >&2; exit 1; }
git -C "$dir/tree" add --all
git -C "$dir/tree" -c user.name=world -c user.email=world@example.invalid commit --quiet -m 'scriptlet'
release "$dir" ready
run "$dir" kendex
if [ "$RC" = 0 ] && [ "$KEYS" = "changed=kendex,pushed=kendex" ] &&
  [ "$(git --git-dir="$dir/aur/kendex.git" show master:kendex.install)" = "$(cat "$recipe/kendex.install")" ]; then
  ok "scriptlet: pushed beside the recipe, the AUR's master holds kendex.install"
else
  bad "scriptlet: the AUR's master holds kendex.install" "rc=$RC keys=$KEYS
$OUT"
fi

# --publishable decides and prints, clones nothing: the deferred package is a
# keyed line, the ready ones are the bare names on stdout, the AUR is untouched.
dir="$(world publishable)"
bump "$dir"
release "$dir" none
rm -rf -- "$dir/aur/kendex-git.git"
before="$(aur_head "$dir" kendex)"
run "$dir" --publishable kendex kendex-git
after="$(aur_head "$dir" kendex)"
names="$(printf '%s\n' "$OUT" | grep -x 'kendex\|kendex-bin\|kendex-git' || true)"
if [ "$RC" = 0 ] && [ "$KEYS" = "deferred=kendex" ] && [ "$names" = "kendex-git" ] && [ "$before" = "$after" ]; then
  ok "--publishable: kendex deferred, kendex-git named, no clone attempted (its AUR repository is gone and nothing complained)"
else
  bad "--publishable: want rc=0 keys=deferred=kendex names=kendex-git" "got rc=$RC keys=$KEYS names=$names
$OUT"
fi

# An AUR repository that cannot be cloned fails that package and goes on.
dir="$(world clone)"
release "$dir" none
rm -rf -- "$dir/aur/kendex-git.git"
run "$dir" --dry-run kendex-git kendex-bin
if [ "$RC" = 1 ] && [ "$KEYS" = "clone=kendex-git,deferred=kendex-bin" ]; then
  ok "clone failure: rc=1 keys=$KEYS"
else
  bad "clone failure" "rc=$RC keys=$KEYS
$OUT"
fi

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
