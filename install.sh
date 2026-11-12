#!/bin/sh
# kendex installer.
#
#   curl -fsSL https://kendex.ai/install.sh | sh
#
# On Linux this installs the desktop app and the kendex command. On macOS it
# installs the kendex command; get the app with `brew install vanillagreencom/kendex/kendex`
# or from https://kendex.ai/download. `--cli-only` installs the command alone
# on every platform:
#
#   curl -fsSL https://kendex.ai/install.sh | sh -s -- --cli-only
# POSIX shell, because the published command pipes this into `sh` and that
# is dash on Debian and Ubuntu. No `pipefail` either: each pipeline here
# only rewrites text it was handed, and the release lookup checks its own
# answer by name, which says more than an abrupt exit would.
set -eu

# Each installer-owned message starts with install.sh: KEY=VALUE. Values
# escape backslashes and newlines; English explanation follows on later lines.
message() {
  printf 'install.sh: %s=' "$1"
  printf '%s\n' "$2" | sed -e 's/\\/\\\\/g' -e '$!s/$/\\n/' | tr -d '\n'
  printf '\n'
  shift 2
  printf '%s\n' "$@"
}

repo="vanillagreencom/kendex"
version="latest"
version_set=0
git_channel=0
cli_only=0

while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { message missing-option-value --version "A version must follow --version." >&2; exit 2; }
      version="$2"; version_set=1; shift 2 ;;
    --git)
      git_channel=1; shift ;;
    --cli-only)
      cli_only=1; shift ;;
    -h|--help)
      message usage install.sh "Usage: install.sh [--git | --version vX.Y.Z] [--cli-only]" \
        "Set KENDEX_GITHUB_TOKEN to a GitHub token to look up and download the release as that token's user."
      exit 0
      ;;
    *) message unknown-option "$1" "The installer does not accept this option." >&2; exit 2 ;;
  esac
done

[ "$git_channel" -eq 0 ] || [ "$version_set" -eq 0 ] || {
  message conflicting-options "--git --version" "Choose the rolling main build or a tagged version." >&2
  exit 2
}

# KENDEX_GITHUB_TOKEN sends the release lookup and every release download
# through api.github.com as the token's user, so an install keeps working
# while GitHub sheds anonymous traffic. The API is the route because
# github.com's release pages answer a request carrying a token exactly as an
# anonymous one, a refused token included. GH_TOKEN and GITHUB_TOKEN are not
# read: a caller holding one for something else keeps sending the anonymous
# requests it always has. Unexported, the token reaches no command this
# script starts except curl, which reads it from standard input.
github_token="${KENDEX_GITHUB_TOKEN:-}"
unset KENDEX_GITHUB_TOKEN
# The token is written into a curl config line, where a quote or a newline
# would end the header and begin an option of its own. GitHub's tokens are
# letters, digits and underscores.
case "$github_token" in
  *[![:alnum:]_]*)
    message github-token-invalid KENDEX_GITHUB_TOKEN "A GitHub token holds only letters, digits and underscores." >&2
    exit 2 ;;
esac

for cmd in awk curl install; do
  command -v "$cmd" >/dev/null || { message missing-command "$cmd" "Install this required command before running the installer." >&2; exit 1; }
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
    message unsupported-platform "$os $arch" "This platform has no installer build." >&2
    echo "  See https://kendex.ai/download for the desktop app, or build from source." >&2
    exit 1 ;;
esac

# One directory for everything downloaded, removed however this run ends.
# `sh` has no per-function cleanup — `trap ... RETURN` is bash's alone — and
# an installer that leaves a temp directory behind on every failed attempt
# fills a machine over time.
work="$(mktemp -d)" || { message temporary-directory-unavailable "${TMPDIR:-/tmp}" "No temporary download directory could be created." >&2; exit 1; }
trap 'rm -rf "$work"' EXIT

# A GET to api.github.com that carries the token, into $2; the remaining
# arguments go to curl. curl drops the header on a redirect to another host,
# which is where an asset download goes next: a signed storage address that
# carries its own authorization. --location-trusted would send the token
# there too, and is never passed. -q, which curl honours only as its first
# argument, skips the caller's .curlrc, where location-trusted or verbose
# would send the token on or print it. A 401 is the token, not the release,
# and stops the install by name rather than reading as a missing asset.
# The HTTP status is left in http_status for download's retry.
http_status=""
github_api() {
  local url="$1" out="$2" rc
  shift 2
  http_status="$(printf 'header = "Authorization: Bearer %s"\n' "$github_token" \
    | curl -q -K - -fL --proto '=https' -o "$out" -w '%{http_code}' "$@" "$url")" && return 0
  rc=$?
  [ "$http_status" != 401 ] || {
    message github-token-rejected "$url" "GitHub refused KENDEX_GITHUB_TOKEN." >&2
    exit 1
  }
  return "$rc"
}

# The api.github.com address of the asset whose github.com download address
# is $1, read from the release in $work/release.json. Split at commas, the
# JSON holds one field to a line however it is laid out. An asset lists its
# "url" and "name" before its "browser_download_url"; a pairing whose name
# is not the one downloaded is refused, so a field order this does not
# expect finds nothing rather than another asset.
release_asset() {
  tr ',' '\n' < "$work/release.json" | awk -v want="$1" -v file="${1##*/}" \
      -v assets="https://api.github.com/repos/$repo/releases/assets/" '
    function field(key,   v) {
      if (!match($0, "\"" key "\": *\"[^\"]*\"")) return ""
      v = substr($0, RSTART, RLENGTH)
      sub("^\"" key "\": *\"", "", v)
      return substr(v, 1, length(v) - 1)
    }
    index(field("url"), assets) == 1 { url = field("url"); name = "" }
    field("name") != "" { name = field("name") }
    field("browser_download_url") == want && name == file && url != "" { print url; found = 1; exit }
    END { exit !found }
  '
}

# One release download into $2. Without a token it is the address as given.
# With one, a github.com release address is fetched as the api.github.com
# asset it names, from its tag's release, which stays read for the next
# download under the same tag; any other address gets no token. An asset
# the release does not hold answers 22, curl's code for the 404 the
# github.com address would have returned.
#
# A temporary error from GitHub, HTTP 408, 429, 500, 502, 503 or 504, is
# tried again, up to download_attempts tries download_retry_secs apart. The
# status decides, not curl's exit code: curl reports a 504 as 22 on a Linux
# runner and as a receive error, 56, on a macOS one, and its own --retry
# passes over 56. GitHub's release downloads answer such errors to some
# requests while a request in the same second succeeds (merge-group run
# 42568537011: one catalog job's command download got a 504, its sibling's
# succeeded), so a later try lands. A try carries no time limit, since a
# slow link fetching the AppImage is not a failure, so the retries add at
# most 70 s of waiting to the tries themselves. Nothing else is retried: a
# 404 or a refused connection fails at once.
download_attempts=8
download_retry_secs=10
release_tag=""
download() {
  local attempt=1 rc
  while :; do
    rc=0
    download_once "$1" "$2" || rc=$?
    [ "$rc" -ne 0 ] || return 0
    case "$http_status" in
      408|429|500|502|503|504) ;;
      *) return "$rc" ;;
    esac
    [ "$attempt" -lt "$download_attempts" ] || return "$rc"
    message download-retry "$http_status" \
      "The server answered $http_status for $1; trying again in $download_retry_secs s." >&2
    sleep "$download_retry_secs"
    attempt=$((attempt + 1))
  done
}

download_once() {
  local url="$1" out="$2" tag asset
  http_status=""
  tag="${url#"https://github.com/$repo/releases/download/"}"
  if [ -z "$github_token" ] || [ "$tag" = "$url" ]; then
    http_status="$(curl -fSL --proto '=https' -w '%{http_code}' -o "$out" "$url")"
    return
  fi
  tag="${tag%%/*}"
  if [ "$tag" != "$release_tag" ]; then
    github_api "https://api.github.com/repos/$repo/releases/tags/$tag" "$work/release.json" \
      -sS -H 'Accept: application/vnd.github+json' || return
    release_tag="$tag"
  fi
  asset="$(release_asset "$url")" || return 22
  github_api "$asset" "$out" -S -H 'Accept: application/octet-stream'
}

if [ "$git_channel" -eq 1 ]; then
  version="rolling-main"
elif [ "$version" = latest ] && [ -n "$github_token" ]; then
  # The token's own quota answers here, not the shared anonymous one.
  latest="https://api.github.com/repos/$repo/releases/latest"
  if github_api "$latest" "$work/release.json" -sS -H 'Accept: application/vnd.github+json' \
     && release_tag="$(tr ',' '\n' < "$work/release.json" | sed -n 's/^.*"tag_name": *"\([^"]*\)".*$/\1/p')" \
     && [ -n "$release_tag" ]; then
    version="$release_tag"
  else
    message release-unavailable "$latest" "The latest release could not be resolved." >&2
    exit 1
  fi
elif [ "$version" = latest ]; then
  # github.com redirects this page to the latest release's tag page. The API
  # would answer the same, but refuses anonymous callers on a shared IP whose
  # hourly quota is spent.
  latest="https://github.com/$repo/releases/latest"
  landed="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$latest")" || landed=""
  case "$landed" in
    */releases/tag/?*) version="${landed##*/releases/tag/}" ;;
    *) message release-unavailable "$latest" "The latest release could not be resolved." >&2; exit 1 ;;
  esac
else
  # The release workflow tags a main build main-build-N-A-SHA, with no v.
  case "$version" in
    main-build-*) ;;
    *) version="v${version#v}" ;;
  esac
fi
plain="${version#v}"
# A main build names its AppImage after the version it built, which its tag
# does not carry, so the build's own feed names every download; its command
# follows the main channel whichever option chose the build.
case "$version" in
  rolling-main|main-build-*) main_feed=1; record_channel=main ;;
  *) main_feed=0; record_channel=release ;;
esac
if [ "$git_channel" -eq 1 ]; then
  plain="main"
fi
base="https://github.com/$repo/releases/download/$version"

# Extract one URL from a map in the workflow-owned feed format. The producer
# writes one entry per line and never escapes its HTTPS URLs.
feed_url() {
  awk -v section="$1" -v key="$2" '
    $0 ~ "^[[:space:]]*\"" section "\":[[:space:]]*\\{" { inside=1; next }
    inside && $0 ~ /^[[:space:]]*}/ { exit }
    inside {
      prefix="\"" key "\": \""
      at=index($0, prefix)
      if (at) {
        value=substr($0, at + length(prefix))
        sub(/\".*/, "", value)
        print value
        found++
      }
    }
    END { if (found != 1) exit 1 }
  ' "$work/feed.json"
}

command_url="$base/kendex-$target"
app_url="$base/kendex_${plain}_${appimage_arch:-}.AppImage"
icon_ref="$version"
if [ "$main_feed" -eq 1 ]; then
  pointer="$base/feed.json"
  if ! download "$pointer" "$work/feed.json"; then
    message main-pointer-download-failed "$pointer" "The main build pointer could not be downloaded." >&2
    exit 1
  fi
  if ! command_url="$(feed_url assets "$target")"; then
    message main-pointer-invalid "$target" "The main build pointer has no complete download set for this target." >&2
    exit 1
  fi
  if [ "$kind" = linux ] && ! app_url="$(feed_url apps "$target")"; then
    message main-pointer-invalid "$target" "The main build pointer has no complete download set for this target." >&2
    exit 1
  fi
  icon_ref=$(sed -n 's/^[[:space:]]*"commit": "\([0-9a-f]*\)",*$/\1/p' "$work/feed.json")
  [ "${#icon_ref}" -eq 40 ] || {
    message main-pointer-invalid commit "The main build pointer has no source commit." >&2
    exit 1
  }
fi
if [ "$git_channel" -eq 1 ]; then
  # Until a release commit's own main build publishes, the pointer still
  # names a build from before that release. A build whose version core is
  # behind the installed command's is a downgrade, refused by the rule
  # `ReleaseFeed::relation_to` holds for `kendex update --git`. The installed
  # command orders the two cores itself, so the ordering is the parser its
  # own update reads with; a core runs up to the first `-` or `+`.
  if installed_command="$(command -v kendex)"; then
    if ! offered=$(sed -n 's/^[[:space:]]*"version": "\([^"]*\)",*$/\1/p' "$work/feed.json") \
       || [ -z "$offered" ]; then
      message main-pointer-invalid version "The main build pointer names no version." >&2
      exit 1
    fi
    if ! installed="$("$installed_command" --version)"; then
      message installed-version-unreadable "$installed_command" "The installed kendex command did not report its version, so this build cannot be checked against it." >&2
      exit 1
    fi
    installed="${installed#kendex }"
    if ! order="$("$installed_command" version-compare "${offered%%[-+]*}" "${installed%%[-+]*}")"; then
      message installed-version-unordered "$installed_command" "The installed kendex command could not order this build against itself." >&2
      exit 1
    fi
    [ "$order" != older ] || {
      message main-downgrade-refused "$offered" "main feed offers $offered, older than installed $installed; rolling updates cannot downgrade" >&2
      exit 1
    }
  fi
fi

# Where kendex keeps its own state, spelled the way the app's resolver
# spells it — `dirs::data_dir()`, which is XDG on Linux and Application
# Support on macOS. Both ends have to agree or the app reads an empty
# directory and decides the command is nobody's.
kendex_data() {
  case "$kind" in
    macos) printf '%s' "$HOME/Library/Application Support/kendex" ;;
    *) printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}/kendex" ;;
  esac
}

# Pick a bin dir already on PATH; prefer a writable user dir over sudo.
bindir=""
for candidate in "$HOME/.local/bin" "/usr/local/bin"; do
  case ":$PATH:" in *":$candidate:"*) bindir="$candidate"; break ;; esac
done
[ -n "$bindir" ] || bindir="$HOME/.local/bin"

# What this script trusts, stated rather than left to be inferred: TLS to
# kendex.ai for the script and to github.com for what it downloads. It does
# not check the minisign signature the release publishes beside each asset,
# because minisign is not on a machine that has installed nothing and a
# check that runs only where the tool happens to be present is one an
# attacker's target simply does not have.
#
# That holds for every run of this script, not only the first. It is the
# upgrade path as well as the install, and a re-run overwrites the command
# and the AppImage with another download nothing checked, so a swapped
# release asset reaches a machine however many times it has installed here.
# `kendex update` is the path held to the key: it refuses either half unless
# a signature under the release key covers the bytes it fetched. A machine
# kept current by re-running this script never gets that check.
install_cli() {
  message command-download "$target" "Downloading the kendex command."
  # curl exits 22 on an HTTP error — here a 404 for an asset the release
  # lacks; any other failure is the network, not the release. Testing the
  # download in the condition and reading `$?` in the else is what keeps that
  # code: `if ! download` would hand back the negation instead.
  if download "$command_url" "$work/kendex"; then
    :
  else
    rc=$?
    message command-download-failed "$rc" "The kendex command could not be downloaded." >&2
    message command-download-url "$command_url" "The command download used this URL." >&2
    [ "$rc" -eq 22 ] && message release-http-error "$target" "The release server returned an HTTP error for this target." >&2
    exit 1
  fi
  chmod +x "$work/kendex"
  # mkdir -p exits 0 on a directory that already exists, writable or not,
  # so create-if-missing first and let writability alone pick the branch.
  [ -d "$bindir" ] || mkdir -p "$bindir" 2>/dev/null || true
  if [ -w "$bindir" ]; then
    install -m 0755 "$work/kendex" "$bindir/kendex"
  else
    message privilege-required "$bindir" "Installing the command here needs elevated permissions."
    # The branch is taken because the directory is not writable, whether or
    # not it exists. Two commands rather than the one `install -D` that
    # made the directory itself: -D makes directories on GNU coreutils
    # only, and BSD install on macOS spells its own -D "-D dest" and takes
    # an operand, so it reads the "-m" behind it as that operand and exits
    # 64 on the usage it is left with. The mkdir covers the one case -D
    # covered, the directory the unprivileged mkdir above could not make,
    # and its -m sets the mode of that directory rather than leaving it to
    # root's umask. It is not the general equivalent of -D, which modes
    # every leading directory it makes where -m modes only the last.
    #
    # Both run bare under set -eu, so a refused escalation stops the run
    # here rather than reaching the line that says the command installed.
    #
    # The default macOS layout comes here: /etc/paths puts root-owned
    # /usr/local/bin on PATH. A mac whose /usr/local Homebrew chowned to
    # the account takes the writable branch above instead.
    [ -d "$bindir" ] || sudo mkdir -m 0755 -p "$bindir"
    sudo install -m 0755 "$work/kendex" "$bindir/kendex"
  fi
  message command-installed "$bindir/kendex" "The kendex command is installed."
  # What this script installed, so the desktop app can tell this file from
  # any other executable someone has named `kendex` — a wrapper script in a
  # writable directory answers every other test the same way, and the app
  # would otherwise write a release binary over it. Failing to record it
  # costs the app-side update, never the install, so it is reported and the
  # run continues.
  state="$(kendex_data)"
  if ! { mkdir -p "$state" 2>/dev/null \
     && printf '%s\n%s\n' "$bindir/kendex" "$record_channel" > "$state/installed-command"; }; then
    message command-record-failed "$state/installed-command" "The command identity could not be recorded; the desktop app will not update it." >&2
  fi
}

# One icon size into the theme directory it belongs to.
#
# The download lands somewhere else first and is installed only once it has
# arrived whole, the way every download here does. This script is the upgrade
# path as well as the install, so a fetch that fails on a re-run must leave
# the icon the last run installed exactly where it is — writing into the
# slot and cleaning up afterwards would take a working icon away over a rate
# limit. Nothing here can fail the install either: every failure is caught
# and named, and the function always returns 0.
install_icon() {
  local dir="$1" source="$2" size file
  size=${dir%/apps}
  size=${size##*/}
  file="$work/$size.png"
  if ! curl -fsSL --proto '=https' -o "$file" "$source"; then
    message icon-download-failed "$size" "The icon could not be downloaded; kendex keeps the one it has." >&2
  elif ! { mkdir -p "$dir" && install -m 0644 "$file" "$dir/kendex.png"; }; then
    message icon-install-failed "$dir" "The icon could not be written and was skipped." >&2
  fi
  return 0
}

# A path, ready to sit inside the quotes of an Exec key. Three layers of the
# Desktop Entry spec meet in that one value, and none of them is shell
# syntax:
#
#   * The value is a list of arguments. Every character the spec reserves —
#     space, tab, newline, " ' \ > < ~ | & ; $ * ? # ( ) ` — has to sit
#     inside quotes, which is why the whole path is written as one quoted
#     argument. That alone settles all but five of them.
#   * Inside those quotes " ` $ and \ each take a leading backslash.
#   * A launcher reads the file's own escapes first, and only \\ \s \n \t
#     \r exist there — so each backslash above is doubled again, a tab, a
#     carriage return and a newline go in by name, and any other backslash
#     makes a launcher refuse the whole key.
#
# Percent is the odd one out: it introduces a field code rather than being
# reserved, and a literal one is written %%. Doubling it is what the spec
# asks for, and it is still the better of two bad answers on GLib, which
# checks that the Exec binary exists before it undoubles them: a path with a
# percent in it gets a menu entry GLib will not read, where leaving the
# percent alone gets one that quietly launches a truncated path.
desktop_arg() {
  local tab cr
  tab=$(printf '\t')
  cr=$(printf '\r')
  # sed reads a line at a time, so a newline in the path arrives as two of
  # them: mark every line but the last and join them back up afterwards.
  printf '%s' "$1" | sed \
    -e 's/\\/\\\\\\\\/g' \
    -e 's/[$`"]/\\\\&/g' \
    -e 's/%/%%/g' \
    -e "s/$tab/\\\\t/g" \
    -e "s/$cr/\\\\r/g" \
    -e '$!s/$/\\n/' | tr -d '\n'
}

# The desktop app on Linux is the AppImage, kept off PATH so the `kendex`
# command stays the CLI. A .desktop entry launches it from the app menu.
# StartupWMClass ties the window to this entry: without it a launcher shows
# the running app as a second, unnamed, iconless item.
install_app_linux() {
  local data libdir
  data="${XDG_DATA_HOME:-$HOME/.local/share}"
  libdir="$(kendex_data)"
  message app-download "$appimage_arch" "Downloading the desktop app."
  if ! download "$app_url" "$work/kendex.AppImage"; then
    message app-download-failed "$appimage_arch" "The desktop app could not be downloaded; the kendex command is installed." >&2
    return 0
  fi
  mkdir -p "$libdir" "$data/applications"
  install -m 0755 "$work/kendex.AppImage" "$libdir/kendex.AppImage"
  # Every size the app ships, each in its own slot: a launcher or dock that
  # picks the 128px icon for a HiDPI slot has to upscale it, and the result
  # looks soft.
  local icons="https://raw.githubusercontent.com/$repo/$icon_ref/crates/app/icons"
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
Exec="$(desktop_arg "$libdir/kendex.AppImage")"
Icon=kendex
StartupWMClass=kendex-app
Categories=Development;Utility;
Terminal=false
DESKTOP
  message app-installed "$libdir/kendex.AppImage" "The desktop app is installed."
}

install_cli
case "$cli_only-$kind" in
  1-*) message app-skipped cli-only "The desktop app was not installed." ;;
  0-linux) install_app_linux ;;
  0-macos) message app-install-method macos "Desktop app: brew install vanillagreencom/kendex/kendex, or https://kendex.ai/download" ;;
esac

case ":$PATH:" in
  *":$bindir:"*) ;;
  *) message path-missing "$bindir" "Add this directory to PATH in your shell profile." ;;
esac
"$bindir/kendex" --version || true
