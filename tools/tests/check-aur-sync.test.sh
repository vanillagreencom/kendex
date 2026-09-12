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
#           .SRCINFO lacks is a drift on its own); `epoch`, `groups`,
#           `backup`, `sha512` kendex's PKGBUILD gaining that field and its
#           .SRCINFO not (fields the comparison must name, or a stale one
#           passes); `pkgbase` the .SRCINFO's pkgbase line renamed; `stray`
#           kendex's .SRCINFO carrying a line makepkg never writes; `stray-var`
#           kendex's PKGBUILD assigning a name that is neither a field nor a
#           `_helper`; `helper` a `_commit=` helper in the PKGBUILD, which is
#           fine; `scriptlet` kendex naming an install scriptlet in both files with the
#           file beside them (the AUR copy lacks it); `patch` two local
#           sources in both files, one under a `name::` alias, both present;
#           `patch-gone` the same with the aliased one absent; `changelog-gone`
#           a changelog named in both files and absent; `append` kendex's
#           PKGBUILD growing depends with `depends+=` and its .SRCINFO not
#           (makepkg honours it; a comparison that skipped it would call a
#           stale .SRCINFO current); `indexed` the same through `depends[1]=`;
#           `declared` a `declare -a` in the header; `aur-extra` the AUR copy
#           tracking an old.install the recipe never names; `aur-drift` the AUR copy of kendex's PKGBUILD behind the
#           tree; `aur-gone` no AUR repository for kendex
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
    epoch) header_line "$recipe/PKGBUILD" 'epoch=1' ;;
    groups) header_line "$recipe/PKGBUILD" "groups=('kendex-tools')" ;;
    backup) header_line "$recipe/PKGBUILD" "backup=('etc/kendex.toml')" ;;
    sha512) header_line "$recipe/PKGBUILD" "sha512sums_x86_64=('SKIP')" ;;
    pkgbase)
      sed -i.bak 's/^pkgbase = kendex$/pkgbase = kendex-renamed/' "$recipe/.SRCINFO" && rm -- "$recipe/.SRCINFO.bak"
      grep -q '^pkgbase = kendex-renamed$' "$recipe/.SRCINFO" || { echo "check-aur-sync.test: the pkgbase edit did not take" >&2; exit 1; }
      ;;
    stray) header_line "$recipe/.SRCINFO" "$(printf '\tflavour = spicy')" ;;
    stray-var) header_line "$recipe/PKGBUILD" 'flavour=spicy' ;;
    helper) header_line "$recipe/PKGBUILD" '_commit=abc123' ;;
    scriptlet)
      header_line "$recipe/PKGBUILD" 'install=kendex.install'
      header_line "$recipe/.SRCINFO" "$(printf '\tinstall = kendex.install')"
      printf 'post_install() { :; }\n' >"$recipe/kendex.install"
      ;;
    patch|patch-gone)
      header_line "$recipe/PKGBUILD" "source=('fix.patch' 'renamed.txt::notes.txt')"
      header_line "$recipe/PKGBUILD" "sha256sums=('SKIP' 'SKIP')" '^source='
      header_line "$recipe/.SRCINFO" "$(printf '\tsource = fix.patch')"
      header_line "$recipe/.SRCINFO" "$(printf '\tsource = renamed.txt::notes.txt')" '^\tsource = fix.patch'
      header_line "$recipe/.SRCINFO" "$(printf '\tsha256sums = SKIP')" '^\tsource = renamed'
      header_line "$recipe/.SRCINFO" "$(printf '\tsha256sums = SKIP')" '^\tsha256sums = SKIP'
      printf -- '--- a\n+++ b\n' >"$recipe/fix.patch"
      [ "$name" = patch ] && printf 'notes\n' >"$recipe/notes.txt"
      ;;
    changelog-gone)
      header_line "$recipe/PKGBUILD" 'changelog=ChangeLog'
      header_line "$recipe/.SRCINFO" "$(printf '\tchangelog = ChangeLog')"
      ;;
    append) header_line "$recipe/PKGBUILD" "depends+=('curl')" '^depends=' ;;
    indexed) header_line "$recipe/PKGBUILD" "depends[1]='curl'" '^depends=' ;;
    declared) header_line "$recipe/PKGBUILD" "declare -a extras=('a')" ;;
    aur-drift)
      git clone --quiet -- "$dir/aur/kendex.git" "$dir/seed"
      sed -i.bak 's/^pkgrel=1$/pkgrel=0/' "$dir/seed/PKGBUILD" && rm -- "$dir/seed/PKGBUILD.bak"
      git -C "$dir/seed" -c user.name=aur -c user.email=aur@example.invalid commit --quiet -am 'behind'
      git -C "$dir/seed" push --quiet origin HEAD:master
      rm -rf -- "$dir/seed"
      ;;
    aur-gone) rm -rf -- "$dir/aur/kendex.git" ;;
    aur-extra)
      git clone --quiet -- "$dir/aur/kendex.git" "$dir/seed"
      printf 'post_install() { :; }\n' >"$dir/seed/old.install"
      git -C "$dir/seed" add --all
      git -C "$dir/seed" -c user.name=aur -c user.email=aur@example.invalid commit --quiet -m 'stale companion'
      git -C "$dir/seed" push --quiet origin HEAD:master
      rm -rf -- "$dir/seed"
      ;;
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
epoch added to the PKGBUILD only|epoch|-|1|drift=1
groups added to the PKGBUILD only|groups|-|1|drift=1
backup added to the PKGBUILD only|backup|-|1|drift=1
sha512sums_x86_64 added to the PKGBUILD only|sha512|-|1|drift=1
pkgbase renamed in the .SRCINFO|pkgbase|-|1|drift=1
a line makepkg never writes in the .SRCINFO|stray|-|2|unreadable=packaging/arch/kendex/.SRCINFO
a name that is no field in the PKGBUILD|stray-var|-|2|unreadable=packaging/arch/kendex/PKGBUILD
a _helper variable in the PKGBUILD|helper|-|0|Arch PKGBUILD/.SRCINFO agree (kendex, kendex-bin, kendex-git)
scriptlet present beside the recipe|scriptlet|kendex|0|Arch PKGBUILD/.SRCINFO agree (kendex)
scriptlet not yet on the AUR|scriptlet|--remote kendex|1|drift=3
local sources present beside the recipe|patch|kendex|0|Arch PKGBUILD/.SRCINFO agree (kendex)
local source absent|patch-gone|kendex|1|drift=1
changelog absent|changelog-gone|kendex|1|drift=1
depends+= with a stale .SRCINFO|append|kendex|2|unreadable=packaging/arch/kendex/PKGBUILD
depends[1]= with a stale .SRCINFO|indexed|kendex|2|unreadable=packaging/arch/kendex/PKGBUILD
declare in the header|declared|kendex|2|unreadable=packaging/arch/kendex/PKGBUILD
remote agrees|clean|--remote kendex|0|AUR recipes match this repo (kendex)
remote behind|aur-drift|--remote kendex|1|drift=1
remote gone|aur-gone|--remote kendex|2|clone=kendex
remote tracks a dropped companion|aur-extra|--remote kendex|1|drift=1
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
for name in epoch groups backup pkgbase; do
  dir="$(world "$name")"
  run "$dir"
  case "$OUT" in
    *"kendex: $name differs"*) ok "$name drift names the key" ;;
    *) bad "$name drift names the key" "$OUT" ;;
  esac
done

# The scriptlet finding names the file the recipe promised.
dir="$(world install)"
run "$dir"
case "$OUT" in
  *'install=kendex.install names no file'*) ok "absent scriptlet is named" ;;
  *) bad "absent scriptlet is named" "$OUT" ;;
esac

# The remote finding names the companion the AUR still tracks.
dir="$(world aur-extra)"
run "$dir" --remote kendex
case "$OUT" in
  *'kendex: old.install is published but the recipe no longer names it'*) ok "remote drift names the stale companion" ;;
  *) bad "remote drift names the stale companion" "$OUT" ;;
esac

# The remote finding names the scriptlet the AUR lacks.
dir="$(world scriptlet)"
run "$dir" --remote kendex
case "$OUT" in
  *'kendex: kendex.install is not published at all'*) ok "remote drift names the missing scriptlet" ;;
  *) bad "remote drift names the missing scriptlet" "$OUT" ;;
esac

# The missing-file findings name the field and the file, aliases resolved.
dir="$(world patch-gone)"
run "$dir" kendex
case "$OUT" in
  *'kendex: source=notes.txt names no file'*) ok "absent local source is named after its alias" ;;
  *) bad "absent local source is named after its alias" "$OUT" ;;
esac
dir="$(world changelog-gone)"
run "$dir" kendex
case "$OUT" in
  *'kendex: changelog=ChangeLog names no file'*) ok "absent changelog is named" ;;
  *) bad "absent changelog is named" "$OUT" ;;
esac

# --print-files: the two makepkg reads, then each companion file the recipe names.
dir="$(world patch)"
run "$dir" --print-files kendex
if [ "$RC" = 0 ] && [ "$OUT" = "$(printf 'PKGBUILD\n.SRCINFO\nfix.patch\nnotes.txt')" ]; then ok "--print-files kendex: both local sources, the alias resolved"; else bad "--print-files kendex (patch)" "rc=$RC out=$OUT"; fi
dir="$(world scriptlet)"
run "$dir" --print-files kendex
if [ "$RC" = 0 ] && [ "$OUT" = "$(printf 'PKGBUILD\n.SRCINFO\nkendex.install')" ]; then ok "--print-files kendex: PKGBUILD, .SRCINFO, kendex.install"; else bad "--print-files kendex" "rc=$RC out=$OUT"; fi
dir="$(world clean)"
run "$dir" --print-files kendex-git
if [ "$RC" = 0 ] && [ "$OUT" = "$(printf 'PKGBUILD\n.SRCINFO')" ]; then ok "--print-files kendex-git: the two files"; else bad "--print-files kendex-git" "rc=$RC out=$OUT"; fi

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

# The inverse: a digest with no download at its index. makepkg refuses the
# recipe, so pairing the first sources and publishing would ship a broken one.
dir="$(world clean)"
header_line "$dir/tree/packaging/arch/kendex/PKGBUILD" \
  "sha256sums_x86_64=('$sum_cli' '$sum_cli')" '^sha256sums_x86_64='
sed -i.bak "0,/^sha256sums_x86_64=('$sum_cli')\$/{/^sha256sums_x86_64=('$sum_cli')\$/d}" "$dir/tree/packaging/arch/kendex/PKGBUILD" && rm -- "$dir/tree/packaging/arch/kendex/PKGBUILD.bak"
[ "$(grep -c '^sha256sums_x86_64=' "$dir/tree/packaging/arch/kendex/PKGBUILD")" = 1 ] || { echo "check-aur-sync.test: the surplus edit did not take" >&2; exit 1; }
run "$dir" --print-source-checksums kendex
if [ "$RC" = 2 ] && [ "$FIRST" = "unreadable=packaging/arch/kendex/PKGBUILD" ]; then ok "surplus checksum: rc=2 unreadable"; else bad "surplus checksum" "rc=$RC first=$FIRST
$OUT"; fi

# This repository's own recipes, as committed.
RC=0
OUT="$(cd "$REPO" && tools/check-aur-sync 2>&1)" || RC=$?
if [ "$RC" = 0 ]; then ok "this repository's packaging/arch agrees"; else bad "this repository's packaging/arch agrees" "$OUT"; fi

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
