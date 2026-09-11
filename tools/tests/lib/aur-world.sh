#!/usr/bin/env bash
# A neutral world for the AUR publishing suites: a repository holding copies
# of tools/check-aur-sync and tools/publish-aur beside three fixture recipes,
# one bare "AUR" repository per package seeded with those same files, and a
# bin/ of stubs that keep both scripts off the network.
#
#   aur_world DIR     builds the world under DIR; the caller owns DIR
#
# Layout under DIR:
#   tree/                the repository the scripts run from, one commit
#   aur/<package>.git    bare repositories on `master`, seeded from tree/
#   downloads/           what the curl stub serves, one file per basename
#   bin/git              rewrites an aur.archlinux.org remote to aur/<package>.git
#                        and hands everything to the real git
#   bin/curl             answers from downloads/ (see below)
#
# The curl stub reads the URL as its last argument and looks up its basename:
#   --head          prints `downloads/<name>.status` if present, else 200 when
#                   `downloads/<name>` exists and 404 when it does not
#   a body request  prints `downloads/<name>`, or exits 22 (curl's -f status)
#   downloads/exit  when present, every call exits with the number it holds
#
# The fixture recipes: kendex pins one x86_64 download and an aarch64
# placeholder; kendex-bin pins an icon in `source` and two downloads in
# `source_x86_64`; kendex-git has only a `git+` source. Each .SRCINFO is
# written to agree with its PKGBUILD. Callers wanting a drifted recipe edit
# their own copy of the world.

AUR_WORLD_PLACEHOLDER='0000000000000000000000000000000000000000000000000000000000000000'

# The same pick tools/publish-aur makes: macOS ships shasum and no sha256sum.
aur_world_sha256() { # STRING — its SHA-256 in lowercase hex
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum
  else
    printf '%s' "$1" | shasum -a 256
  fi | cut -d' ' -f1
}

aur_world_srcinfo() { # FILE PKGBASE LINE... — a pkgbase stanza of LINEs, then its one pkgname
  local file="$1" base="$2" line
  shift 2
  {
    printf 'pkgbase = %s\n' "$base"
    for line in "$@"; do printf '\t%s\n' "$line"; done
    printf '\npkgname = %s\n' "$base"
  } >"$file"
}

aur_world() { # DIR
  local dir="$1" repo tree real_git package sum_cli sum_icon sum_app
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  tree="$dir/tree"
  mkdir -p "$tree/tools" "$tree/packaging/arch/kendex" "$tree/packaging/arch/kendex-bin" \
    "$tree/packaging/arch/kendex-git" "$dir/aur" "$dir/downloads" "$dir/bin"
  cp -- "$repo/tools/check-aur-sync" "$repo/tools/publish-aur" "$tree/tools/"

  sum_cli="$(aur_world_sha256 'x86_64 cli bytes')"
  sum_icon="$(aur_world_sha256 'icon bytes')"
  sum_app="$(aur_world_sha256 'x86_64 app bytes')"

  cat >"$tree/packaging/arch/kendex/PKGBUILD" <<EOF
pkgname=kendex
pkgver=1.2.3
pkgrel=1
pkgdesc='fixture command'
arch=('x86_64' 'aarch64')
url='https://example.invalid'
license=('MIT')
depends=('git>=2.41')
provides=('kendex')
conflicts=('kendex-git')
options=('!strip')
source_x86_64=("kendex-\$pkgver::https://example.invalid/v\$pkgver/kendex-x86_64")
source_aarch64=("kendex-\$pkgver::https://example.invalid/v\$pkgver/kendex-aarch64")
sha256sums_x86_64=('$sum_cli')
sha256sums_aarch64=('$AUR_WORLD_PLACEHOLDER')

package() {
  install -Dm755 "\$srcdir/kendex-\$pkgver" "\$pkgdir/usr/bin/kendex"
}
EOF
  aur_world_srcinfo "$tree/packaging/arch/kendex/.SRCINFO" kendex \
    'pkgdesc = fixture command' \
    'pkgver = 1.2.3' \
    'pkgrel = 1' \
    'url = https://example.invalid' \
    'arch = x86_64' \
    'arch = aarch64' \
    'license = MIT' \
    'depends = git>=2.41' \
    'provides = kendex' \
    'conflicts = kendex-git' \
    'options = !strip' \
    'source_x86_64 = kendex-1.2.3::https://example.invalid/v1.2.3/kendex-x86_64' \
    "sha256sums_x86_64 = $sum_cli" \
    'source_aarch64 = kendex-1.2.3::https://example.invalid/v1.2.3/kendex-aarch64' \
    "sha256sums_aarch64 = $AUR_WORLD_PLACEHOLDER"

  cat >"$tree/packaging/arch/kendex-bin/PKGBUILD" <<EOF
pkgname=kendex-bin
pkgver=1.2.3
pkgrel=1
pkgdesc='fixture app and command'
arch=('x86_64')
url='https://example.invalid'
license=('MIT')
depends=('fuse2')
provides=('kendex')
conflicts=('kendex' 'kendex-git')
source=("kendex.png::https://example.invalid/v\$pkgver/icon.png")
source_x86_64=(
  "kendex-app-\$pkgver.AppImage::https://example.invalid/v\$pkgver/kendex_\${pkgver}_amd64.AppImage"
  "kendex-\$pkgver::https://example.invalid/v\$pkgver/kendex-x86_64"
)
sha256sums=('$sum_icon')
sha256sums_x86_64=(
  '$sum_app'
  '$sum_cli'
)

package() {
  install -Dm755 "\$srcdir/kendex-\$pkgver" "\$pkgdir/usr/bin/kendex"
}
EOF
  aur_world_srcinfo "$tree/packaging/arch/kendex-bin/.SRCINFO" kendex-bin \
    'pkgdesc = fixture app and command' \
    'pkgver = 1.2.3' \
    'pkgrel = 1' \
    'url = https://example.invalid' \
    'arch = x86_64' \
    'license = MIT' \
    'depends = fuse2' \
    'provides = kendex' \
    'conflicts = kendex' \
    'conflicts = kendex-git' \
    'source = kendex.png::https://example.invalid/v1.2.3/icon.png' \
    "sha256sums = $sum_icon" \
    'source_x86_64 = kendex-app-1.2.3.AppImage::https://example.invalid/v1.2.3/kendex_1.2.3_amd64.AppImage' \
    'source_x86_64 = kendex-1.2.3::https://example.invalid/v1.2.3/kendex-x86_64' \
    "sha256sums_x86_64 = $sum_app" \
    "sha256sums_x86_64 = $sum_cli"

  cat >"$tree/packaging/arch/kendex-git/PKGBUILD" <<'EOF'
pkgname=kendex-git
pkgver=r0.0000000
pkgrel=1
pkgdesc='fixture from the latest commit'
arch=('x86_64')
url='https://example.invalid'
license=('MIT')
provides=('kendex')
conflicts=('kendex')
depends=('git>=2.41')
makedepends=('rust' 'cargo' 'git')
source=('git+https://example.invalid/kendex.git')
sha256sums=('SKIP')

pkgver() {
  cd "$srcdir/kendex"
  printf 'r%s.%s' "$(git rev-list --count HEAD)" "$(git rev-parse --short HEAD)"
}

package() {
  cd "$srcdir/kendex"
  install -Dm755 target/release/kendex "$pkgdir/usr/bin/kendex"
}
EOF
  aur_world_srcinfo "$tree/packaging/arch/kendex-git/.SRCINFO" kendex-git \
    'pkgdesc = fixture from the latest commit' \
    'pkgver = r0.0000000' \
    'pkgrel = 1' \
    'url = https://example.invalid' \
    'arch = x86_64' \
    'license = MIT' \
    'makedepends = rust' \
    'makedepends = cargo' \
    'makedepends = git' \
    'depends = git>=2.41' \
    'provides = kendex' \
    'conflicts = kendex' \
    'source = git+https://example.invalid/kendex.git' \
    'sha256sums = SKIP'

  # One commit, so `git rev-parse --short HEAD` resolves for the sync message.
  git -C "$tree" init --quiet
  git -C "$tree" -c user.name=world -c user.email=world@example.invalid \
    add --all
  git -C "$tree" -c user.name=world -c user.email=world@example.invalid \
    commit --quiet -m 'fixture recipes'

  # Each "AUR" repository holds the fixture's recipe on master, so a run over
  # an unchanged tree reports every package as already published.
  for package in kendex kendex-bin kendex-git; do
    git -c init.defaultBranch=master init --quiet --bare -- "$dir/aur/$package.git"
    mkdir -p -- "$dir/seed-$package"
    cp -- "$tree/packaging/arch/$package/PKGBUILD" "$tree/packaging/arch/$package/.SRCINFO" \
      "$dir/seed-$package/"
    git -C "$dir/seed-$package" init --quiet
    git -C "$dir/seed-$package" add --all
    git -C "$dir/seed-$package" -c user.name=aur -c user.email=aur@example.invalid \
      commit --quiet -m 'seed'
    git -C "$dir/seed-$package" push --quiet -- "$dir/aur/$package.git" HEAD:master
    rm -rf -- "$dir/seed-$package"
  done

  # The stubs name the real git by absolute path, so they cannot resolve
  # themselves through PATH, and find their world beside their own file, so
  # a copy of the world carries its stubs with it.
  real_git="$(command -v git)"
  cat >"$dir/bin/git" <<EOF
#!/bin/sh
# Every aur.archlinux.org remote, over HTTPS or SSH, is this world's bare repository.
world="\$(cd "\$(dirname "\$0")/.." && pwd)"
n=\$#
while [ "\$n" -gt 0 ]; do
  a="\$1"; shift
  case "\$a" in
    https://aur.archlinux.org/*.git|ssh://aur@aur.archlinux.org/*.git) a="\$world/aur/\${a##*/}" ;;
  esac
  set -- "\$@" "\$a"
  n=\$((n - 1))
done
exec "$real_git" "\$@"
EOF
  cat >"$dir/bin/curl" <<EOF
#!/bin/sh
world="\$(cd "\$(dirname "\$0")/.." && pwd)/downloads"
[ -f "\$world/exit" ] && exit "\$(cat "\$world/exit")"
for a in "\$@"; do url="\$a"; done
name="\${url##*/}"
head=0
for a in "\$@"; do [ "\$a" = "--head" ] && head=1; done
if [ "\$head" -eq 1 ]; then
  if [ -f "\$world/\$name.status" ]; then cat "\$world/\$name.status"
  elif [ -f "\$world/\$name" ]; then printf 200
  else printf 404
  fi
  exit 0
fi
[ -f "\$world/\$name" ] || exit 22
cat "\$world/\$name"
EOF
  chmod +x "$dir/bin/git" "$dir/bin/curl"
}
