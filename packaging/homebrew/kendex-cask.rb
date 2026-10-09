# Homebrew cask for the kendex desktop app. Lives in the tap
# `vanillagreencom/homebrew-kendex` as `Casks/kendex.rb`. The formula is
# named kendex-cli, so the plain name resolves here and the DEFAULT brew
# install is the app:
#
#   brew install vanillagreencom/kendex/kendex
#
# Installs the app and links the kendex command out of it, so the two
# update together.
cask "kendex" do
  version "1.13.0"
  sha256 arm:   "397bfbd8b416dfc2af73bd54d30e8a02423cc9c2189a55e42e865770175f92ac",
         intel: "87c2ce70599d9ee10759b2cab7bd8aa72b9d4eb94dd31d9401f0acc83e355c2f"

  # Tauri names the Intel disk image `x64` and the Apple-silicon one `aarch64`.
  arch arm: "aarch64", intel: "x64"
  url "https://github.com/vanillagreencom/kendex/releases/download/v#{version}/kendex_#{version}_#{arch}.dmg"
  name "kendex"
  desc "Package manager for AI coding agents, skills, and hooks"
  homepage "https://kendex.ai"

  # Homebrew's sanctioned way to let an app replace itself: the cask
  # steps aside, and the in-app Update button owns the upgrade.
  auto_updates true

  app "kendex.app"
  binary "#{appdir}/kendex.app/Contents/MacOS/kendex"

  # A cask has no `version_scheme`, the formula's way over the 5.x-to-1.0
  # restart: `auto_updates true` above hands the upgrade to the app, and
  # the app renders no notice for a feed older than itself, so a 5.x
  # install is offered nothing. The reinstall below is what reaches it.
  # Earlier casks installed the kendex-cli formula beside the app, and
  # `brew uninstall kendex` leaves it in place, so it is removed by hand
  # before the install, whose `binary` link refuses the name it holds.
  caveats <<~EOS
    Upgrading from kendex 5.x, or from a cask that installed the
    kendex-cli formula: this cask now links the kendex command out of the
    app. Reinstall once, removing the formula, because uninstalling the
    app leaves it behind:

      brew uninstall kendex
      brew uninstall kendex-cli
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
