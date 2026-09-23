# Homebrew formula for the kendex CLI on its own. Lives in the tap
# `vanillagreencom/homebrew-kendex` as `Formula/kendex-cli.rb`, installed
# with:
#
#   brew install vanillagreencom/kendex/kendex-cli
#
# The plain `kendex` name belongs to the cask, so the default install is
# the app; this formula is the CLI-only channel and what the cask depends
# on. Installs the prebuilt release binary — no toolchain needed.
class KendexCli < Formula
  desc "Package manager for agents, skills, and hooks across AI coding tools"
  homepage "https://kendex.ai"
  version "1.0.0"
  license "MIT"

  # Materializing a catalog shells out to git, and kendex refuses on
  # anything below 2.41 — the first that takes `--attr-source`. A
  # formula dependency carries no version, so the floor itself is
  # left to that refusal; brew's own git is well past it.
  depends_on "git"

  on_macos do
    on_arm do
      url "https://github.com/vanillagreencom/kendex/releases/download/v#{version}/kendex-aarch64-apple-darwin"
      sha256 "8f587d1af395f1c7952d7a80ed335ee1779e6a1f778b2e851f171badddcda192"
    end
    on_intel do
      url "https://github.com/vanillagreencom/kendex/releases/download/v#{version}/kendex-x86_64-apple-darwin"
      sha256 "66b4089fd48792ac093c04c47c958103f5c288caec15dff8f216948dd7285228"
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/vanillagreencom/kendex/releases/download/v#{version}/kendex-x86_64-unknown-linux-gnu"
      sha256 "0d4ae9ffa82f3600d34a18e4a36009bae29ecd06ba7fa8fb0ef1d569d3a0936f"
    end
    on_arm do
      url "https://github.com/vanillagreencom/kendex/releases/download/v#{version}/kendex-aarch64-unknown-linux-gnu"
      sha256 "04e16bcc316d764c5d275d5f89689f8ba531f3c9d438e23adca24c5ad5bc6126"
    end
  end

  def install
    bin.install Dir["*"].first => "kendex"
  end

  # kendex 1.0.0 follows 5.0.1, so the version number goes backwards.
  # Homebrew has no epoch: it reads 1.0.0 as lower than an installed 5.x,
  # `brew outdated` names nothing and `brew upgrade` changes nothing, with
  # no way to say otherwise in a formula. The Arch recipes carry `epoch=1`
  # for the same transition; here the reinstall below is the whole answer.
  def caveats
    <<~EOS
      Upgrading from kendex 5.x: 1.0.0 restarts the version number, and
      Homebrew reads it as older than what you have, so `brew upgrade`
      offers nothing. Reinstall once:

        brew uninstall kendex-cli
        brew install vanillagreencom/kendex/kendex-cli
    EOS
  end

  test do
    assert_match "1.0.0", shell_output("#{bin}/kendex --version")
  end
end
