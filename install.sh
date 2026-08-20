#!/usr/bin/env bash
# kendex installer.
#
#   curl -fsSL https://kendex.ai/install.sh | sh
#
# On Linux this installs the desktop app and the kendex command. On macOS it
# installs the kendex command; get the app with `brew install vanillagreencom/kendex/kendex`
# or from https://kendex.ai/download.
set -euo pipefail

repo="vanillagreencom/kendex"
version="latest"

while [ $# -gt 0 ]; do
  case "$1" in
    --version) version="${2:?missing version after --version}"; shift 2 ;;
    -h|--help)
      echo "Usage: install.sh [--version vX.Y.Z]"
      exit 0
      ;;
    *) echo "install.sh: unknown option: $1" >&2; exit 2 ;;
  esac
done

for cmd in curl install; do
  command -v "$cmd" >/dev/null || { echo "install.sh: missing required command: $cmd" >&2; exit 1; }
done

os="$(uname -s)"
arch="$(uname -m)"
# Tauri names AppImages with Debian arch words (amd64, aarch64), not the
# Rust triple, so x86_64 needs its own spelling.
case "$os-$arch" in
  Linux-x86_64|Linux-amd64)    target="x86_64-unknown-linux-gnu";  kind="linux"; appimage_arch="amd64" ;;
  Linux-aarch64|Linux-arm64)   target="aarch64-unknown-linux-gnu"; kind="linux"; appimage_arch="aarch64" ;;
  Darwin-arm64|Darwin-aarch64) target="aarch64-apple-darwin";      kind="macos" ;;
  Darwin-x86_64)               target="x86_64-apple-darwin";       kind="macos" ;;
  *)
    echo "install.sh: unsupported platform: $os $arch" >&2
    echo "  See https://kendex.ai/download for the desktop app, or build from source." >&2
    exit 1 ;;
esac

if [ "$version" = latest ]; then
  version="$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
fi
[ -n "$version" ] || { echo "install.sh: could not resolve the latest release" >&2; exit 1; }
plain="${version#v}"
base="https://github.com/$repo/releases/download/$version"

# Pick a bin dir already on PATH; prefer a writable user dir over sudo.
bindir=""
for candidate in "$HOME/.local/bin" "/usr/local/bin"; do
  case ":$PATH:" in *":$candidate:"*) bindir="$candidate"; break ;; esac
done
[ -n "$bindir" ] || bindir="$HOME/.local/bin"

install_cli() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  echo "Downloading the kendex command ($target)…"
  # curl exits 22 on an HTTP error — here a 404 for an asset the release
  # lacks; any other failure is the network, not the release.
  if curl -fSL --proto '=https' -o "$tmp/kendex" "$base/kendex-$target"; then
    :
  else
    rc=$?
    echo "install.sh: could not download kendex-$target from $base" >&2
    [ "$rc" -eq 22 ] && echo "  release $version may have no build for $target (see https://github.com/$repo/releases)" >&2
    exit 1
  fi
  chmod +x "$tmp/kendex"
  # mkdir -p exits 0 on a directory that already exists, writable or not,
  # so create-if-missing first and let writability alone pick the branch.
  [ -d "$bindir" ] || mkdir -p "$bindir" 2>/dev/null || true
  if [ -w "$bindir" ]; then
    install -m 0755 "$tmp/kendex" "$bindir/kendex"
  else
    echo "Installing to $bindir needs elevated permissions."
    sudo install -D -m 0755 "$tmp/kendex" "$bindir/kendex"
  fi
  echo "Installed the kendex command to $bindir/kendex"
}

# One icon size into the theme directory it belongs to. A missing icon is
# not worth failing an install over, so a download that fails is skipped —
# but curl creates the file before the transfer, so the empty one it leaves
# behind is removed. A launcher prefers the size it finds over the size that
# would have looked right, and an empty file is a file.
install_icon() {
  local dir=$1 source=$2
  mkdir -p "$dir"
  curl -fsSL --proto '=https' -o "$dir/kendex.png" "$source" ||
    rm -f "$dir/kendex.png"
}

# The desktop app on Linux is the AppImage, kept off PATH so the `kendex`
# command stays the CLI. A .desktop entry launches it from the app menu.
# StartupWMClass ties the window to this entry: without it a launcher shows
# the running app as a second, unnamed, iconless item.
install_app_linux() {
  local data libdir tmp
  data="${XDG_DATA_HOME:-$HOME/.local/share}"
  libdir="$data/kendex"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  echo "Downloading the desktop app…"
  if ! curl -fSL --proto '=https' -o "$tmp/kendex.AppImage" \
      "$base/kendex_${plain}_${appimage_arch}.AppImage"; then
    echo "install.sh: could not download the desktop app; the kendex command is installed." >&2
    return 0
  fi
  mkdir -p "$libdir" "$data/applications"
  install -m 0755 "$tmp/kendex.AppImage" "$libdir/kendex.AppImage"
  # Every size the app ships, each in its own slot: a launcher or dock that
  # picks the 128px icon for a HiDPI slot has to upscale it, and the result
  # looks soft.
  local icons="https://raw.githubusercontent.com/$repo/$version/crates/app/icons"
  local theme="$data/icons/hicolor"
  install_icon "$theme/32x32/apps" "$icons/32x32.png"
  install_icon "$theme/128x128/apps" "$icons/128x128.png"
  install_icon "$theme/256x256/apps" "$icons/128x128@2x.png"
  install_icon "$theme/512x512/apps" "$icons/icon.png"
  cat > "$data/applications/kendex.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=kendex
Comment=Manage AI coding agents, skills, and hooks
Exec=$libdir/kendex.AppImage
Icon=kendex
StartupWMClass=kendex-app
Categories=Development;Utility;
Terminal=false
DESKTOP
  echo "Installed the desktop app to $libdir/kendex.AppImage"
}

install_cli
if [ "$kind" = linux ]; then
  install_app_linux
else
  echo "Desktop app: brew install vanillagreencom/kendex/kendex, or https://kendex.ai/download"
fi

case ":$PATH:" in
  *":$bindir:"*) ;;
  *) echo "Note: $bindir is not on your PATH. Add it, e.g.:"
     echo "  echo 'export PATH=\"$bindir:\$PATH\"' >> ~/.profile" ;;
esac
"$bindir/kendex" --version || true
