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

  # A cask has no `version_scheme`, the formula's way over the 5.x-to-1.0
  # restart: `auto_updates true` above hands the upgrade to the app, and
  # the app renders no notice for a feed older than itself, so a 5.x
  # install is offered nothing. The reinstall below is what reaches it.
  # `brew uninstall kendex` leaves the kendex-cli formula in place, so the
  # command is removed by hand before the install pulls it back at 1.0.0.
  caveats <<~EOS
    Upgrading from kendex 5.x: 1.0.0 restarts the version number. This
    cask leaves upgrades to the app, and the app's updater sees 1.0.0 as
    older than itself, so nothing offers it. Reinstall once, the kendex
    command included, because uninstalling the app leaves its kendex-cli
    formula behind:

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
