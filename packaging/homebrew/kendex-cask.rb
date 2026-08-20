# Homebrew cask for the kendex desktop app. Lives in the tap
# `vanillagreencom/homebrew-kendex` as `Casks/kendex.rb`. The formula is
# named kendex-cli, so the plain name resolves here and the DEFAULT brew
# install is the app:
#
#   brew install vanillagreencom/kendex/kendex
#
# Installs the app and, through the formula dependency, the kendex command.
cask "kendex" do
  version "5.0.1"
  # The Intel sha256 is filled by the first release after 5.0.1.
  sha256 arm:   "f8215e1c059d2afcebfc1b56d64094b2f9fe7dacb1a773ce127acc85c262fb3b",
         intel: "0000000000000000000000000000000000000000000000000000000000000000"

  # Tauri names the Intel disk image `x64` and the Apple-silicon one `aarch64`.
  arch arm: "aarch64", intel: "x64"
  url "https://github.com/vanillagreencom/kendex/releases/download/v#{version}/kendex_#{version}_#{arch}.dmg"
  name "kendex"
  desc "Package manager for AI coding agents, skills, and hooks"
  homepage "https://kendex.ai"

  depends_on formula: "vanillagreencom/kendex/kendex-cli"

  app "kendex.app"

  caveats <<~EOS
    kendex is not notarized by Apple yet, so macOS may say the app is
    "damaged" on first launch. Clear the quarantine flag once:

      xattr -cr /Applications/kendex.app

    The kendex command is installed by the formula and is unaffected.
  EOS

  zap trash: [
    "~/Library/Application Support/ai.kendex.app",
    "~/Library/Caches/ai.kendex.app",
    "~/Library/Preferences/ai.kendex.app.plist",
  ]
end
