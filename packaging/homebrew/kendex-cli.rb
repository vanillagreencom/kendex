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
  version "1.22.1"
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
      sha256 "cefdd4148b3a762442f8e5922174e7ee0a0f43253f73fcad4f74fcaf5b15b528"
    end
    on_intel do
      url "https://github.com/vanillagreencom/kendex/releases/download/v#{version}/kendex-x86_64-apple-darwin"
      sha256 "199c5ba3a670c2616295a7072aa9bc7945c64f0123e8605742c2ec5ea1d50029"
    end
  end

  on_linux do
    depends_on "dbus"
    depends_on "patchelf" => :build

    on_intel do
      url "https://github.com/vanillagreencom/kendex/releases/download/v#{version}/kendex-x86_64-unknown-linux-gnu"
      sha256 "297ac2c48f29b0e8db4e7590f050c659e7e865ddfb0cb15cd06357cab6fd7e63"
    end
    on_arm do
      url "https://github.com/vanillagreencom/kendex/releases/download/v#{version}/kendex-aarch64-unknown-linux-gnu"
      sha256 "fd5c5212b52d4fd1a7cd74934ff5a3d17e51517633212b03e1d7ee5522e00d49"
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
