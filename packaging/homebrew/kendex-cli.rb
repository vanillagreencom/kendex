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
  version "1.25.0"
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
      sha256 "ac1068acc879c2460b83c7b4714b2f320989b98e472d0e1940ecfcd878216c51"
    end
    on_intel do
      url "https://github.com/vanillagreencom/kendex/releases/download/v#{version}/kendex-x86_64-apple-darwin"
      sha256 "b88acfdeef4217a616292466a8a1d8a3cb79d22b8a615c73505fccacbb2180b8"
    end
  end

  on_linux do
    depends_on "dbus"
    depends_on "patchelf" => :build

    on_intel do
      url "https://github.com/vanillagreencom/kendex/releases/download/v#{version}/kendex-x86_64-unknown-linux-gnu"
      sha256 "9dfbeaf3a681dc51882ca3bda25b9d29fed0b300cba0b28608e4b860db1c462e"
    end
    on_arm do
      url "https://github.com/vanillagreencom/kendex/releases/download/v#{version}/kendex-aarch64-unknown-linux-gnu"
      sha256 "2e1f97d246b68ad5bc4dbb4a1fcbfe628d625490fe0060eeb975acaa99d618e2"
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
