# Install channels

The headline install is the curl script. The rest are package-manager entries that point at the same GitHub release artifacts. On Linux and macOS the app and the CLI install together; the CLI is also available on its own.

| Channel | Command | Installs | Recipe |
|---|---|---|---|
| curl | `curl -fsSL https://kendex.ai/install.sh \| sh` | app + CLI (Linux), CLI (macOS) | [`/install.sh`](../install.sh) |
| Homebrew | `brew install vanillagreencom/kendex/kendex` | app + CLI | [`homebrew/kendex-cask.rb`](homebrew/kendex-cask.rb) |
| Homebrew (CLI) | `brew install vanillagreencom/kendex/kendex-cli` | CLI | [`homebrew/kendex-cli.rb`](homebrew/kendex-cli.rb) |
| Arch | `yay -S kendex-bin` | app + CLI | [`arch/kendex-bin/`](arch/kendex-bin/) |
| Arch (CLI) | `yay -S kendex` | CLI | [`arch/kendex/`](arch/kendex/) |
| Arch (latest commit) | `yay -S kendex-git` | CLI | [`arch/kendex-git/`](arch/kendex-git/) |
| App bundles | download from the release | app | built by `release.yml` |

The desktop app binary is named `kendex-app`, after its cargo package, and every channel that installs both keeps it off `PATH` (the AppImage on Linux, the `.app` bundle on macOS) so the `kendex` command is the CLI. That name is also what a Linux launcher matches a running window against, which is why both the curl script and the Arch package put `StartupWMClass=kendex-app` in the desktop entry they write.

## Per release

Each new `vX.Y.Z` changes the artifact checksums. Update, in this repo:

- `arch/kendex/PKGBUILD` + `.SRCINFO`: `pkgver` and `sha256sums_x86_64` / `sha256sums_aarch64` (the released `kendex-x86_64-unknown-linux-gnu` and `kendex-aarch64-unknown-linux-gnu`).
- `arch/kendex-bin/PKGBUILD` + `.SRCINFO`: `pkgver`, the four icon `sha256sums`, and the per-arch pairs (AppImage, CLI binary) in `sha256sums_x86_64` and `sha256sums_aarch64`. Regenerate `.SRCINFO` with `makepkg --printsrcinfo > .SRCINFO` in the package directory; `tools/check-aur-sync` refuses a PKGBUILD whose `.SRCINFO` disagrees, and the commit would fail on the AUR publish anyway.
- `homebrew/kendex-cli.rb`: `version` and all four `sha256` lines (macOS arm and Intel, Linux Intel and arm).
- `homebrew/kendex-cask.rb`: `version` and both `.dmg` checksums (`arm:` is the `_aarch64.dmg`, `intel:` the `_x64.dmg`).

Checksums for the released files come from the release page or `sha256sum <file>` on a download. A target shipping for the first time has all-zero placeholders until its first release fills them. Recipes carrying a placeholder are pushed to the tap and AUR only as part of that release's version bump, never before — pushed early, a user on the new target gets a checksum mismatch instead of a clear "not supported".

Committing that bump to `main` is what publishes it; the workflows under § Publishing carry the recipes to their channels.

Each Linux CLI `sha256` (one per architecture) is the same value in all three of `kendex-cli.rb`, `arch/kendex/PKGBUILD`, and `arch/kendex-bin/PKGBUILD` — bump all three together. `kendex-git` needs no checksum change; its `pkgver()` is computed at build time from the cloned commit.

## Publishing

Nothing pulls from this repository: two workflows push the recipes out, and a hand edit in the AUR or the tap is overwritten by the next run.

**Arch** (`.github/workflows/publish-aur.yml`, `tools/publish-aur`): runs on every push to `main` that touches `packaging/arch/`, the two tools, or the workflow itself, and copies each package's `PKGBUILD` + `.SRCINFO` into a clone of `ssh://aur@aur.archlinux.org/<name>.git`, committing and pushing only what differs. Before a package is pushed, its recipe is checked for a target still pinned to the all-zero placeholder, which defers the whole package (a keyed `deferred=` line in the log, exit 0): the recipe is pushed whole or not at all, so a placeholder would reach every user on that target as a package that fails makepkg's validity check. Then every download the recipe pins is fetched and hashed: a download that is absent, or whose bytes do not hash to the pin, defers the package the same way until the release is up, so a version bump merged ahead of its tag is harmless and publishes itself on the next run. An unreachable host or an unexpected HTTP status fails the run instead: neither is a release that has not happened yet. `kendex-git` has only a git source and is never deferred. A package's file set is `PKGBUILD`, `.SRCINFO` and every companion file its recipe names, scriptlets (`install=`, `changelog=`) and local `source` entries such as a patch (`tools/check-aur-sync --print-files`); a name with no file beside the recipe is a drift finding before anything is published. The published files are diffed against the AUR afterwards, and a weekly job compares the packages that are publishable that day (`tools/publish-aur --publishable`, then `tools/check-aur-sync --remote` on them) and reports drift without publishing; a deferred package is expected to differ and is left out.

- `workflow_dispatch` takes `packages` (space separated, default all three) and `dry_run`; a dry run clones over HTTPS, prints the diff, and pushes nothing. Locally: `tools/publish-aur --dry-run [package...]`, which needs no key.
- Secret `AUR_SSH_PRIVATE_KEY`: the AUR account's SSH key. Variable `AUR_SSH_KNOWN_HOSTS`: the `aur.archlinux.org` host key line, verified against the fingerprints on the Arch wiki's AUR page before it is stored; the job prints the fingerprint it trusts. A real run with either unset fails by name; it never pushes nothing under a green run.
- Variables `AUR_COMMIT_NAME` and `AUR_COMMIT_EMAIL` are optional; unset, the AUR commit is authored as `kendex packaging <packaging@vanillagreen>`.

**Homebrew** (`.github/workflows/publish-homebrew.yml`, `tools/publish-homebrew`): runs on every push to `main` that touches `packaging/homebrew/`, the tool or the workflow itself, copies `kendex-cli.rb` to `Formula/kendex-cli.rb` and `kendex-cask.rb` to `Casks/kendex.rb` in the tap `vanillagreencom/homebrew-kendex`, and commits and pushes only if they differ. The formula deliberately is NOT named `kendex`: brew resolves a formula before a cask, and the plain name must reach the cask so the default install is the app. A recipe still pinning a target to the all-zero placeholder is deferred (a keyed `deferred=` line, exit 0) and the other recipe goes on its own; a run with both deferred pushes nothing. Beyond that the push is unconditional: it does not fetch the release's downloads the way the AUR publisher does, so a Homebrew recipe carrying a version bump must not reach `main` before that release is published.

- `workflow_dispatch` takes `dry_run`; a dry run clones the public tap, prints the diff, and pushes nothing. Locally: `tools/publish-homebrew --dry-run`, which needs no token.
- Deploy keys are disabled on the tap, so the push uses an installation token of the fleet GitHub App, minted for `homebrew-kendex` alone. Secrets `FLEET_GH_APP_ID` (the App ID) and `FLEET_GH_APP_PRIVATE_KEY` (its PEM private key); the App is installed on the organisation with contents write on the tap. A real run with either unset fails by name before anything is cloned.

## Caveats

- Releases through v5.0.1 predate Apple notarization, so Gatekeeper calls those "damaged" on first launch; the cask's caveat gives the one-time fix (`xattr -cr /Applications/kendex.app`). Later releases are Developer ID signed and notarized by the release workflow.
- The Linux AppImage needs FUSE (`fuse2`) to run.
- The release workflow publishes as a **draft**, and `install.sh` resolves `--version latest` through GitHub's latest-release API, which skips drafts. So `curl … | sh` only works after the release is published (`gh release edit vX --draft=false`).
