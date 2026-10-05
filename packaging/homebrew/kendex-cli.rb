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
  version "1.10.1"
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
      sha256 "45be5cfb20a1151994e63c282ca99e2a7728945181a641df8e706b764ba9903f"
    end
    on_intel do
      url "https://github.com/vanillagreencom/kendex/releases/download/v#{version}/kendex-x86_64-apple-darwin"
      sha256 "0c27b94aecf47571acd8d009ad09f2eaf91285beb43eee7c5f5f24aabb6d771b"
    end
  end

  on_linux do
    depends_on "dbus"
    depends_on "patchelf" => :build

    on_intel do
      url "https://github.com/vanillagreencom/kendex/releases/download/v#{version}/kendex-x86_64-unknown-linux-gnu"
      sha256 "5f87a227a9961905202d2fb690dacc5338830da937f9bce466053c8efa5d38ee"
    end
    on_arm do
      url "https://github.com/vanillagreencom/kendex/releases/download/v#{version}/kendex-aarch64-unknown-linux-gnu"
      sha256 "e34f12f2ba1f1cb63256a8371144a14d1d71ee2b76b4a04a716a41012a38559a"
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
