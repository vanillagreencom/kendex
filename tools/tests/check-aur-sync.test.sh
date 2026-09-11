#!/usr/bin/env bash
# tools/check-aur-sync: whether each PKGBUILD agrees with its .SRCINFO, what
# it prints for tools/publish-aur, and with --remote whether the AUR holds
# this tree's files. Every run is over the world tools/tests/lib/aur-world.sh
# builds (a copy per row that plants a defect), plus one run over this
# repository's own recipes.
#
# A run renders as `rc=<n> first=<line>`: the exit status and LINE 1 of the
# run's output, stdout and stderr together, with the `check-aur-sync: `
# prefix off for a keyed refusal. A refusal row pins its own key and value;
# the English under the key is not pinned.
#
# The rows table is `label|world|argv|rc|first`:
#   world   `clean` the world as built; `pkgrel` kendex's PKGBUILD bumped to
#           pkgrel=2 and its .SRCINFO not; `two` that bump and a new pkgdesc;
#           `no-srcinfo` kendex's .SRCINFO deleted; `unterminated` kendex's
#           PKGBUILD with an array never closed; `install` kendex naming an
#           install scriptlet no file holds, in both files (an `install` the
#           .SRCINFO lacks is a drift on its own); `aur-drift` the
#           AUR copy of kendex's PKGBUILD behind the tree; `aur-gone` no AUR
#           repository for kendex
#   argv    the arguments as written, `-` for none
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../.." && pwd)"
# shellcheck source=lib/aur-world.sh
. "$TEST_DIR/lib/aur-world.sh"
TMP="$(mktemp -d)" || { echo "check-aur-sync.test: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

command -v python3 >/dev/null 2>&1 || {
  echo 'python3 is required: it is what tools/check-aur-sync runs under' >&2
  exit 1
}

# A pristine world, copied per row so a planted defect stays private to it.
aur_world "$TMP/pristine"

world() { # NAME — a fresh copy of the pristine world at $TMP/w-NAME, defect planted
  local name="$1" dir="$TMP/w-$1" recipe
  rm -rf -- "$dir"
  cp -R -- "$TMP/pristine" "$dir"
  recipe="$dir/tree/packaging/arch/kendex"
  case "$name" in
    clean) ;;
    pkgrel) sed -i.bak 's/^pkgrel=1$/pkgrel=2/' "$recipe/PKGBUILD" && rm -- "$recipe/PKGBUILD.bak" ;;
    two)
      sed -i.bak -e 's/^pkgrel=1$/pkgrel=2/' -e "s/^pkgdesc=.*/pkgdesc='renamed'/" "$recipe/PKGBUILD" &&
        rm -- "$recipe/PKGBUILD.bak"
      ;;
    no-srcinfo) rm -- "$recipe/.SRCINFO" ;;
    unterminated) header_line "$recipe/PKGBUILD" 'extras=(' ;;
    install)
      header_line "$recipe/PKGBUILD" 'install=kendex.install'
      header_line "$recipe/.SRCINFO" "$(printf '\tinstall = kendex.install')"
      ;;
    aur-drift)
      git clone --quiet -- "$dir/aur/kendex.git" "$dir/seed"
      sed -i.bak 's/^pkgrel=1$/pkgrel=0/' "$dir/seed/PKGBUILD" && rm -- "$dir/seed/PKGBUILD.bak"
      git -C "$dir/seed" -c user.name=aur -c user.email=aur@example.invalid commit --quiet -am 'behind'
      git -C "$dir/seed" push --quiet origin HEAD:master
      rm -rf -- "$dir/seed"
      ;;
    aur-gone) rm -rf -- "$dir/aur/kendex.git" ;;
    *) echo "check-aur-sync.test: no such world: $name" >&2; exit 1 ;;
  esac
  # The edits above must have taken: a sed that matched nothing leaves the
  # row proving the clean world twice.
  case "$name" in
    pkgrel|two) grep -q '^pkgrel=2$' "$recipe/PKGBUILD" || { echo "check-aur-sync.test: the $name edit did not take" >&2; exit 1; } ;;
  esac
  case "$name" in
    two) grep -q "^pkgdesc='renamed'$" "$recipe/PKGBUILD" || { echo "check-aur-sync.test: the two edit did not take" >&2; exit 1; } ;;
  esac
  printf '%s\n' "$dir"
}

# header_line FILE LINE [AFTER] — LINE added after the line matching AFTER
# (default: the `options` line), inside a PKGBUILD's metadata header or a
# .SRCINFO's pkgbase stanza. Appending to the file would land it after
# package() or under the pkgname stanza, which is not where makepkg reads it.
header_line() {
  local file="$1" line="$2" after="${3:-^[[:space:]]*options}"
  awk -v line="$line" -v after="$after" '{ print } $0 ~ after { print line }' "$file" >"$file.new" &&
    mv -- "$file.new" "$file"
  grep -qxF -- "$line" "$file" || { echo "check-aur-sync.test: the header edit did not take: $line" >&2; exit 1; }
}

# run WORLD-DIR ARGV... — sets RC and FIRST (keyed prefix stripped), OUT the whole output
run() {
  local dir="$1"
  shift
  RC=0
  OUT="$(cd "$dir/tree" && PATH="$dir/bin:$PATH" tools/check-aur-sync "$@" 2>&1)" || RC=$?
  FIRST="${OUT%%$'\n'*}"
  FIRST="${FIRST#check-aur-sync: }"
}

rows='
agree|clean|-|0|Arch PKGBUILD/.SRCINFO agree (kendex, kendex-bin, kendex-git)
one package|clean|kendex-git|0|Arch PKGBUILD/.SRCINFO agree (kendex-git)
pkgrel drift|pkgrel|-|1|drift=1
two drifts|two|-|1|drift=2
srcinfo missing|no-srcinfo|-|2|missing=packaging/arch/kendex/.SRCINFO
unterminated array|unterminated|-|2|unreadable=packaging/arch/kendex/PKGBUILD
install scriptlet absent|install|-|1|drift=1
remote agrees|clean|--remote kendex|0|AUR recipes match this repo (kendex)
remote behind|aur-drift|--remote kendex|1|drift=1
remote gone|aur-gone|--remote kendex|2|clone=kendex
'
while IFS='|' read -r label name argv rc first; do
  [ -n "$label" ] || continue
  dir="$(world "$name")"
  if [ "$argv" = "-" ]; then run "$dir"; else
    # shellcheck disable=SC2086
    run "$dir" $argv
  fi
  if [ "$RC" = "$rc" ] && [ "$FIRST" = "$first" ]; then
    ok "$label: rc=$rc first=$first"
  else
    bad "$label: want rc=$rc first=$first" "got rc=$RC first=$FIRST"
  fi
done <<EOF
$rows
EOF

# The drift finding names the key that differs, so the author knows what to regenerate.
dir="$(world pkgrel)"
run "$dir"
case "$OUT" in
  *'kendex: pkgrel differs'*) ok "pkgrel drift names the key" ;;
  *) bad "pkgrel drift names the key" "$OUT" ;;
esac

# The scriptlet finding names the file the recipe promised.
dir="$(world install)"
run "$dir"
case "$OUT" in
  *'install=kendex.install names no file'*) ok "absent scriptlet is named" ;;
  *) bad "absent scriptlet is named" "$OUT" ;;
esac

# A name outside the package set is argparse's refusal, exit 2, before any file is read.
dir="$(world clean)"
run "$dir" vgs-shell
if [ "$RC" = 2 ]; then ok "unknown package: rc=2"; else bad "unknown package: want rc=2" "got rc=$RC first=$FIRST"; fi

# --print-sources: every http(s) source, expanded, in PKGBUILD order; a git+ source is not one.
run "$dir" --print-sources kendex
want='https://example.invalid/v1.2.3/kendex-x86_64
https://example.invalid/v1.2.3/kendex-aarch64'
if [ "$RC" = 0 ] && [ "$OUT" = "$want" ]; then ok "--print-sources kendex: both downloads, expanded"; else bad "--print-sources kendex" "rc=$RC out=$OUT"; fi
run "$dir" --print-sources kendex-git
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "--print-sources kendex-git: nothing, its source is git+"; else bad "--print-sources kendex-git" "rc=$RC out=$OUT"; fi

# --print-source-checksums pairs each download with the sum at its own index
# in the array of its own architecture suffix.
sum_cli="$(aur_world_sha256 'x86_64 cli bytes')"
sum_icon="$(aur_world_sha256 'icon bytes')"
sum_app="$(aur_world_sha256 'x86_64 app bytes')"
run "$dir" --print-source-checksums kendex-bin
want="$(printf 'https://example.invalid/v1.2.3/icon.png\t%s\nhttps://example.invalid/v1.2.3/kendex_1.2.3_amd64.AppImage\t%s\nhttps://example.invalid/v1.2.3/kendex-x86_64\t%s' "$sum_icon" "$sum_app" "$sum_cli")"
if [ "$RC" = 0 ] && [ "$OUT" = "$want" ]; then ok "--print-source-checksums kendex-bin: paired per architecture suffix"; else bad "--print-source-checksums kendex-bin" "rc=$RC out=$OUT"; fi
run "$dir" --print-source-checksums kendex
want="$(printf 'https://example.invalid/v1.2.3/kendex-x86_64\t%s\nhttps://example.invalid/v1.2.3/kendex-aarch64\t%s' "$sum_cli" "$AUR_WORLD_PLACEHOLDER")"
if [ "$RC" = 0 ] && [ "$OUT" = "$want" ]; then ok "--print-source-checksums kendex: the placeholder is printed as pinned"; else bad "--print-source-checksums kendex" "rc=$RC out=$OUT"; fi

# A download with no sum at its index is unreadable, not silently unpaired.
header_line "$dir/tree/packaging/arch/kendex/PKGBUILD" \
  'source_aarch64=("kendex-$pkgver::https://example.invalid/v$pkgver/kendex-aarch64" "extra::https://example.invalid/v$pkgver/extra")' \
  '^sha256sums_aarch64='

run "$dir" --print-source-checksums kendex
if [ "$RC" = 2 ] && [ "$FIRST" = "unreadable=packaging/arch/kendex/PKGBUILD" ]; then ok "unpaired download: rc=2 unreadable"; else bad "unpaired download" "rc=$RC first=$FIRST"; fi

# This repository's own recipes, as committed.
RC=0
OUT="$(cd "$REPO" && tools/check-aur-sync 2>&1)" || RC=$?
if [ "$RC" = 0 ]; then ok "this repository's packaging/arch agrees"; else bad "this repository's packaging/arch agrees" "$OUT"; fi

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
