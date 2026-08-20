# Install channels

The headline install is the curl script. The rest are package-manager entries
that point at the same GitHub release artifacts. On Linux and macOS the app
and the CLI install together; the CLI is also available on its own.

| Channel | Command | Installs | Recipe |
|---|---|---|---|
| curl | `curl -fsSL https://kendex.ai/install.sh \| sh` | app + CLI (Linux), CLI (macOS) | [`/install.sh`](../install.sh) |
| Homebrew | `brew install vanillagreencom/kendex/kendex` | app + CLI | [`homebrew/kendex-cask.rb`](homebrew/kendex-cask.rb) |
| Homebrew (CLI) | `brew install vanillagreencom/kendex/kendex-cli` | CLI | [`homebrew/kendex-cli.rb`](homebrew/kendex-cli.rb) |
| Arch | `yay -S kendex-bin` | app + CLI | [`arch/kendex-bin/`](arch/kendex-bin/) |
| Arch (CLI) | `yay -S kendex` | CLI | [`arch/kendex/`](arch/kendex/) |
| Arch (latest commit) | `yay -S kendex-git` | CLI | [`arch/kendex-git/`](arch/kendex-git/) |
| App bundles | download from the release | app | built by `release.yml` |

The desktop app binary is named `kendex`, the same as the CLI, so every
channel that installs both keeps the app off `PATH` (the AppImage on Linux,
the `.app` bundle on macOS) and leaves the `kendex` command to the CLI.

## Per release

Each new `vX.Y.Z` changes the artifact checksums. Update, in this repo:

- `arch/kendex/PKGBUILD` + `.SRCINFO`: `pkgver` and `sha256sums_x86_64` /
  `sha256sums_aarch64` (the released `kendex-x86_64-unknown-linux-gnu` and
  `kendex-aarch64-unknown-linux-gnu`).
- `arch/kendex-bin/PKGBUILD` + `.SRCINFO`: `pkgver`, the icon `sha256sums`,
  and the per-arch pairs (AppImage, CLI binary) in `sha256sums_x86_64` and
  `sha256sums_aarch64`. Regenerate `.SRCINFO` with `makepkg --printsrcinfo`.
- `homebrew/kendex-cli.rb`: `version` and all four `sha256` lines (macOS arm
  and Intel, Linux Intel and arm).
- `homebrew/kendex-cask.rb`: `version` and both `.dmg` checksums (`arm:` is
  the `_aarch64.dmg`, `intel:` the `_x64.dmg`).

Checksums for the released files come from the release page or
`sha256sum <file>` on a download. A target shipping for the first time has
all-zero placeholders until its first release fills them.

Then push the recipes to their channels:

- **Homebrew**: copy `homebrew/kendex-cli.rb` to `Formula/kendex-cli.rb` and
  `homebrew/kendex-cask.rb` to `Casks/kendex.rb` in the tap repo
  `vanillagreencom/homebrew-kendex`, and commit. The formula deliberately
  is NOT named `kendex`: brew resolves a formula before a cask, and the
  plain name must reach the cask so the default install is the app.
- **Arch**: in each AUR package clone, copy the `PKGBUILD` + `.SRCINFO` and
  `git push` to `ssh://aur@aur.archlinux.org/<name>.git`. Pushing needs the
  AUR account's SSH key.

Each Linux CLI `sha256` (one per architecture) is the same value in all
three of `kendex-cli.rb`, `arch/kendex/PKGBUILD`, and `arch/kendex-bin/PKGBUILD`
— bump all three together. `kendex-git` needs no checksum change; its `pkgver()` is computed at
build time from the cloned commit.

## Caveats

- The macOS `.app` is not yet notarized, so Gatekeeper calls it "damaged" on
  first launch until signing is added to the release. The cask's caveat tells
  users to clear the quarantine flag once: `xattr -cr /Applications/kendex.app`.
- The Linux AppImage needs FUSE (`fuse2`) to run.
- The release workflow publishes as a **draft**, and `install.sh` resolves
  `--version latest` through GitHub's latest-release API, which skips drafts.
  So `curl … | sh` only works after the release is published
  (`gh release edit vX --draft=false`).
