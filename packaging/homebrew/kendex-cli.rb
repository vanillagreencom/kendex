# Homebrew formula for the kendex CLI on its own. Lives in the tap
# `vanillagreencom/homebrew-kendex` as `Formula/kendex-cli.rb`, installed
# with:
#
#   brew install vanillagreencom/kendex/kendex-cli
#
# The plain `kendex` name belongs to the cask, so the default install is
# the app, which carries the command itself; this formula is the CLI-only
# channel. Installs the prebuilt release binary — no toolchain needed.
class KendexCli < Formula
  desc "Package manager for agents, skills, and hooks across AI coding tools"
  homepage "https://kendex.ai"
  version "1.14.0"
  # 1.0.0 follows 5.0.1, so the version number restarts. brew compares
  # this scheme before the number: an installed 5.x sits on scheme 0 and
  # reads as outdated, so `brew upgrade` reaches it. The Arch recipes
  # carry `epoch=1` for the same transition. Never lower it.
  version_scheme 1
  license "MIT"

  # Materializing a catalog shells out to git, and kendex refuses on
  # anything below 2.41 — the first that takes `--attr-source`. A
  # formula dependency carries no version, so the floor itself is
  # left to that refusal; brew's own git is well past it.
  depends_on "git"

  on_macos do
    on_arm do
      url "https://github.com/vanillagreencom/kendex/releases/download/v#{version}/kendex-aarch64-apple-darwin"
      sha256 "e4ba41e647555abeb4578412a0b254aec6413872928d6491a46e3ba631a9d266"
    end
    on_intel do
      url "https://github.com/vanillagreencom/kendex/releases/download/v#{version}/kendex-x86_64-apple-darwin"
      sha256 "46aafe7c8ffda9ce3a49b232a4b0c2a244419abf547b2a36962067e60b75373c"
    end
  end

  on_linux do
    depends_on "dbus"
    depends_on "patchelf" => :build

    on_intel do
      url "https://github.com/vanillagreencom/kendex/releases/download/v#{version}/kendex-x86_64-unknown-linux-gnu"
      sha256 "8df4fe2a1bdf977584ad72f7a71d3d7c304cbf40b58028b1081f66224a0d2a28"
    end
    on_arm do
      url "https://github.com/vanillagreencom/kendex/releases/download/v#{version}/kendex-aarch64-unknown-linux-gnu"
      sha256 "49dd7f8919baafe924384f5861d9d9c723ef92ead17014a8969a1acc0ad40476"
    end
  end

  def install
    executable = Dir["*"].first
    system "patchelf", "--set-rpath", Formula["dbus"].opt_lib, executable if OS.linux?
    bin.install executable => "kendex"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/kendex --version")
  end
end
