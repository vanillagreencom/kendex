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
  version "1.18.0"
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
      sha256 "c7886bbb82207c4218cca9114b4f079f0de59a4c9459c15a4065c493c9824288"
    end
    on_intel do
      url "https://github.com/vanillagreencom/kendex/releases/download/v#{version}/kendex-x86_64-apple-darwin"
      sha256 "f7282a5adb3cce8de56a1125c75e422f3fcad516b81b4cf587723898b38b6add"
    end
  end

  on_linux do
    depends_on "dbus"
    depends_on "patchelf" => :build

    on_intel do
      url "https://github.com/vanillagreencom/kendex/releases/download/v#{version}/kendex-x86_64-unknown-linux-gnu"
      sha256 "b86686c5d33c15ba08008cac3fe697525188ed51389729ac088f58131210d3d8"
    end
    on_arm do
      url "https://github.com/vanillagreencom/kendex/releases/download/v#{version}/kendex-aarch64-unknown-linux-gnu"
      sha256 "3c95d4f703be2a194939d1ff54eac28ecefdb959d822c7f42c082da33732c4f0"
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
