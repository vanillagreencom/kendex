# Homebrew cask for the kendex desktop app. Lives in the tap
# `vanillagreencom/homebrew-kendex` as `Casks/kendex.rb`. The formula is
# named kendex-cli, so the plain name resolves here and the DEFAULT brew
# install is the app:
#
#   brew install vanillagreencom/kendex/kendex
#
# Installs the app and, through the formula dependency, the kendex command.
cask "kendex" do
  version "1.0.0"
  sha256 arm:   "ec48eb743789aad02581a1272ceadb6f49a15646d7774818f140d5ef4afbc350",
         intel: "dac61f402f66441e80ddf8f9fbbb59fa53660f0a997a906c9ad11c27a1e7910f"

  # Tauri names the Intel disk image `x64` and the Apple-silicon one `aarch64`.
  arch arm: "aarch64", intel: "x64"
  url "https://github.com/vanillagreencom/kendex/releases/download/v#{version}/kendex_#{version}_#{arch}.dmg"
  name "kendex"
  desc "Package manager for AI coding agents, skills, and hooks"
  homepage "https://kendex.ai"

  # Homebrew's sanctioned way to let an app replace itself: the cask
  # steps aside, and the in-app Update button owns the upgrade.
  auto_updates true

  depends_on formula: "vanillagreencom/kendex/kendex-cli"

  app "kendex.app"

  # Homebrew has no epoch, so an installed 5.x reads as newer than 1.0.0
  # and `brew upgrade` changes nothing; `auto_updates true` above defers
  # to the app, which renders no notice for a feed older than itself. The
  # reinstall below is what reaches a 5.x install on this channel.
  caveats <<~EOS
    Upgrading from kendex 5.x: 1.0.0 restarts the version number, and
    Homebrew reads it as older than what you have, so neither `brew
    upgrade` nor the app's own updater offers it. Reinstall once:

      brew uninstall kendex
      brew install vanillagreencom/kendex/kendex

    Releases through v5.0.1 predate Apple notarization; on those, macOS
    may say the app is "damaged" on first launch. Clear the quarantine
    flag once:

      xattr -cr /Applications/kendex.app

    Later releases are signed and notarized, and the kendex command is
    unaffected either way.
  EOS

  zap trash: [
    "~/Library/Application Support/ai.kendex.app",
    "~/Library/Caches/ai.kendex.app",
    "~/Library/Preferences/ai.kendex.app.plist",
  ]
end
