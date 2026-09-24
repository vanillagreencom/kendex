# Install channels

The headline install is the curl script. The rest are package-manager entries that point at the same GitHub release artifacts. On Linux and macOS the app and the CLI install together; the CLI is also available on its own.

| Channel | Command | Installs | Recipe |
|---|---|---|---|
| curl | `curl -fsSL https://kendex.ai/install.sh \| sh` | app + CLI (Linux), CLI (macOS) | [`/install.sh`](../install.sh) |
| Homebrew | `brew install vanillagreencom/kendex/kendex` | app + CLI | [`homebrew/kendex-cask.rb`](homebrew/kendex-cask.rb) |
| Homebrew (CLI) | `brew install vanillagreencom/kendex/kendex-cli` | CLI | [`homebrew/kendex-cli.rb`](homebrew/kendex-cli.rb) |
| Arch | `yay -S kendex-bin` | app + CLI | [`arch/kendex-bin/`](arch/kendex-bin/) |
| Arch (from source) | `yay -S kendex` | app + CLI | [`arch/kendex/`](arch/kendex/) |
| Arch (latest commit) | `yay -S kendex-git` | app + CLI | [`arch/kendex-git/`](arch/kendex-git/) |
| Arch (latest commit, CLI) | `yay -S kendex-cli-git` | CLI | [`arch/kendex-cli-git/`](arch/kendex-cli-git/) |
| App bundles | download from the release | app | built by `release.yml` |

The desktop app binary is named `kendex-app`, after its cargo package, and every channel that installs both keeps it off `PATH` (on Linux the AppImage or the plain `kendex-app` binary, on macOS the `.app` bundle) so the `kendex` command is the CLI. That name is also what a Linux launcher matches a running window against, which is why both the curl script and the Arch packages put `StartupWMClass=kendex-app` in the desktop entry they write.

## The four Arch packages

Three install the desktop app and the command together and one installs the command alone; they differ in where the bytes come from.

| Package | Contents | Source |
|---|---|---|
| `kendex` | app + CLI | the tagged release, built from source |
| `kendex-git` | app + CLI | remote `main`, built from source |
| `kendex-bin` | app + CLI | the release's prebuilt AppImage and command |
| `kendex-cli-git` | CLI | remote `main`, built from source |

All four install `/usr/bin/kendex`, so no two can be installed together: each names the other three in `conflicts`, in both directions. A dependency on the name `kendex` is satisfied by `kendex` itself, which carries it as its `pkgname`, and by `kendex-git` and `kendex-bin`, which declare it in `provides`. `kendex-cli-git` declares no `provides`: a dependency on `kendex` asks for the app as well, and the command alone would satisfy it wrongly. None of the four declares `replaces`: every name already exists under its own recipe, and a `replaces` would swap a person's chosen variant for another during an ordinary system upgrade, taking the desktop app away from a `kendex-git` install without asking.

Every recipe carries `epoch=1`. kendex 1.0.0 follows 5.0.1, so the version number goes backwards; without the epoch pacman reads 1.0.0 as older than the 5.x a machine already holds and never offers the upgrade.

`kendex` and `kendex-git`, the two desktop packages built from source, build the frontend themselves (`npm ci` then `npm run build` under `ui/`) before `cargo build`, because the desktop binary embeds `ui/dist` and only `cargo tauri build` would run that step on its own. Those two install the app as a plain binary at `/usr/lib/kendex/kendex-app`, where `kendex-bin` installs the released AppImage at `/usr/lib/kendex/kendex.AppImage`; both are off `PATH`. `kendex-cli-git` builds from source too and runs neither npm step, which is why it carries no `npm` makedepend and installs no app. The desktop packages depend on `desktop-file-utils` and `xdg-utils` because the app makes itself the `kendex://` handler on first launch through `update-desktop-database` and `xdg-mime`. `kendex-cli-git` depends only on git and `dbus`. All four declare `dbus` because the command links libdbus-1 through keyring’s `sync-secret-service` backend; Arch’s `dbus` also supplies the headers and `dbus-1.pc` for source builds. The Linux Homebrew formula installs `dbus` and patches the command to find its library.

Which package owns a running install is asked of pacman (`pacman -Qoq`) rather than read off the layout, in `crates/core/src/install_channel.rs`: all four install the same command, two track `main` where the other two track a release, and the update guidance names the package that is actually installed. A name pacman prints that is none of the four names nobody and offers no command.

## Per release

Each new `vX.Y.Z` changes the artifact checksums. Update, in this repo:

- `arch/kendex/PKGBUILD` + `.SRCINFO`: `pkgver` and the one `sha256sums` entry, over the tag's source tarball.
- `arch/kendex-bin/PKGBUILD` + `.SRCINFO`: `pkgver`, the four icon `sha256sums`, and the per-arch pairs (AppImage, CLI binary) in `sha256sums_x86_64` and `sha256sums_aarch64`. Regenerate `.SRCINFO` with `makepkg --printsrcinfo > .SRCINFO` in the package directory; `tools/check-aur-sync` refuses a PKGBUILD whose `.SRCINFO` disagrees, and the commit would fail on the AUR publish anyway.
- `homebrew/kendex-cli.rb`: `version` and all four `sha256` lines (macOS arm and Intel, Linux Intel and arm).
- `homebrew/kendex-cask.rb`: `version` and both `.dmg` checksums (`arm:` is the `_aarch64.dmg`, `intel:` the `_x64.dmg`).

Checksums for the released files come from the release page or `sha256sum <file>` on a download. A target shipping for the first time has all-zero placeholders until its first release fills them. Recipes carrying a placeholder are pushed to the tap and AUR only as part of that release's version bump, never before — pushed early, a user on the new target gets a checksum mismatch instead of a clear "not supported".

Committing that bump to `main` is what publishes it; the workflows under § Publishing carry the recipes to their channels.

Each Linux CLI `sha256` (one per architecture) is the same value in `kendex-cli.rb` and `arch/kendex-bin/PKGBUILD` — bump both together. `kendex-git` and `kendex-cli-git` need no checksum change; each `pkgver()` is computed at build time from the cloned commit.

### The version restart, once

Arch survives 1.0.0 following 5.0.1 on the `epoch=1` above. The formula's counterpart is `version_scheme 1`: brew compares the scheme before the number, so an installed 5.0.1 (scheme 0) shows in `brew outdated` and `brew upgrade kendex-cli` moves it; the scheme never goes down. A cask has no version scheme, and `auto_updates true` hands its upgrade to an app that renders no notice for a feed older than itself, so the cask's `caveats` block tells a 5.x install to `brew uninstall` the app, then the `kendex-cli` formula that leaves behind, and install the app again from the tap. `the_formula_declares_the_restart_as_a_new_version_scheme` and `the_cask_tells_a_5_x_install_to_reinstall_the_app_and_its_cli` in `crates/cli/tests/packaging_recipes.rs` hold both; drop the cask's block once no install is left on 5.x.

## Publishing

Nothing pulls from this repository: two workflows push the recipes out, and a hand edit in the AUR or the tap is overwritten by the next run.

**Arch** (`.github/workflows/publish-aur.yml`, `tools/publish-aur`): carries the four packages above, and runs on every push to `main` that touches `packaging/arch/`, the two tools, or the workflow itself, and copies each package's `PKGBUILD` + `.SRCINFO` into a clone of `ssh://aur@aur.archlinux.org/<name>.git`, committing and pushing only what differs. Before a package is pushed, its recipe is checked for a target still pinned to the all-zero placeholder, which defers the whole package (a keyed `deferred=` line in the log, exit 0): the recipe is pushed whole or not at all, so a placeholder would reach every user on that target as a package that fails makepkg's validity check. Then every download the recipe pins is fetched and hashed: a download that is absent, or whose bytes do not hash to the pin, defers the package the same way until the release is up, so a version bump merged ahead of its tag is harmless: publishing the release (a draft becoming a release) runs the workflow again and lands it. A file the AUR tracks that the recipe no longer names is removed on the next publish, and the remote check reports one as drift. An unreachable host or an unexpected HTTP status fails the run instead: neither is a release that has not happened yet. `kendex-git` and `kendex-cli-git` have only a git source and are never deferred. An AUR name nobody has pushed yet is a first publication (`new=<package>`), not a fault. A package's file set is `PKGBUILD`, `.SRCINFO` and every companion file its recipe names (`tools/check-aur-sync --print-files`); a named file that is missing is a drift finding before anything is published. The published files are diffed against the AUR afterwards, and a weekly job compares the packages that are publishable that day (`tools/publish-aur --publishable`, then `tools/check-aur-sync --remote` on them) and reports drift without publishing; a deferred package is expected to differ and is left out.

- `workflow_dispatch` takes `packages` (space separated, default all four), `dry_run` and `check_key`; a dry run clones over HTTPS, prints the diff, and pushes nothing. Locally: `tools/publish-aur --dry-run [package...]`, which needs no key.
- Secret `AUR_SSH_PRIVATE_KEY`: the key of the AUR account `vanillagreen`, which maintains the four packages: RSA 4096, fingerprint `SHA256:t8gSJ7RLCH3fyWUrv+wJqzDOyeXkGdhrDuyfVuu19Do`, and a rotation changes this line. A real run proves the key with one login before any clone (`tools/publish-aur --check-key`), printing its fingerprint; a `check_key` dispatch runs only that proof. Locally, `ssh -T -i KEY aur@aur.archlinux.org` answers `Welcome to AUR, vanillagreen!` for the right key. Variable `AUR_SSH_KNOWN_HOSTS`: the `aur.archlinux.org` host key line, verified against the fingerprints on the Arch wiki's AUR page before it is stored; the job prints the fingerprint it trusts. A real run with either unset fails by name; it never pushes nothing under a green run.
- Variables `AUR_COMMIT_NAME` and `AUR_COMMIT_EMAIL` are optional; unset, the AUR commit is authored as `kendex packaging <packaging@vanillagreen>`.

**Homebrew** (`.github/workflows/publish-homebrew.yml`, `tools/publish-homebrew`): runs on every push to `main` that touches `packaging/homebrew/`, the tool or the workflow itself, copies `kendex-cli.rb` to `Formula/kendex-cli.rb` and `kendex-cask.rb` to `Casks/kendex.rb` in the tap `vanillagreencom/homebrew-kendex`, and commits and pushes only if they differ. The formula deliberately is NOT named `kendex`: brew resolves a formula before a cask, and the plain name must reach the cask so the default install is the app. A recipe still pinning a target to the all-zero placeholder is deferred (a keyed `deferred=` line, exit 0) and the other recipe goes on its own; a run with both deferred pushes nothing. Beyond that the push is unconditional: it does not fetch the release's downloads the way the AUR publisher does, so a Homebrew recipe carrying a version bump must not reach `main` before that release is published.

- `workflow_dispatch` takes `dry_run`; a dry run clones the public tap, prints the diff, and pushes nothing. Locally: `tools/publish-homebrew --dry-run`, which needs no token.
- Deploy keys are disabled on the tap, so the push uses an installation token of the fleet GitHub App, minted for `homebrew-kendex` alone. Secrets `FLEET_GH_APP_ID` (the App ID) and `FLEET_GH_APP_PRIVATE_KEY` (its PEM private key); the App is installed on the organisation with contents write on the tap. A real run with either unset fails by name before anything is cloned.

## Caveats

- Releases through v5.0.1 predate Apple notarization, so Gatekeeper calls those "damaged" on first launch; the cask's caveat gives the one-time fix (`xattr -cr /Applications/kendex.app`). Later releases are Developer ID signed and notarized by the release workflow.
- The Linux AppImage needs FUSE (`fuse2`) to run.
- The release workflow publishes as a **draft**, and `install.sh` resolves `--version latest` through GitHub's latest-release API, which skips drafts. So `curl … | sh` only works after the release is published (`gh release edit vX --draft=false`).
