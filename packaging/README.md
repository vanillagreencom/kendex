# Install channels

The headline install is the curl script. It and the binary package-manager entries use GitHub release artifacts. The source-based Arch entries and the Nix flake build from this repository. On Linux and macOS the app and the CLI install together; the CLI is also available on its own.

| Channel | Command | Installs | Recipe |
|---|---|---|---|
| curl | `curl -fsSL https://kendex.ai/install.sh \| sh` | app + CLI (Linux), CLI (macOS) | [`/install.sh`](../install.sh) |
| Homebrew | `brew install vanillagreencom/kendex/kendex` | app + CLI | [`homebrew/kendex-cask.rb`](homebrew/kendex-cask.rb) |
| Homebrew (CLI) | `brew install vanillagreencom/kendex/kendex-cli` | CLI | [`homebrew/kendex-cli.rb`](homebrew/kendex-cli.rb) |
| Arch | `yay -S kendex-bin` | app + CLI | [`arch/kendex-bin/`](arch/kendex-bin/) |
| Arch (from source) | `yay -S kendex` | app + CLI | [`arch/kendex/`](arch/kendex/) |
| Arch (latest commit) | `yay -S kendex-git` | app + CLI | [`arch/kendex-git/`](arch/kendex-git/) |
| Arch (latest commit, CLI) | `yay -S kendex-cli-git` | CLI | [`arch/kendex-cli-git/`](arch/kendex-cli-git/) |
| Nix | `nix profile add github:vanillagreencom/kendex#kendex-cli` | CLI | [`/flake.nix`](../flake.nix), [`nix/kendex-cli.nix`](nix/kendex-cli.nix) |
| deb, rpm, Windows setup | download from the release | app + CLI | built by `release.yml` |
| dmg | download from the release | app (CLI inside the bundle) | built by `release.yml` |
| AppImage | download from the release | app | built by `release.yml` |

The `kendex` command opens the CLI. Use your desktop launcher to open the app.

## Nix flake

The repository root is a flake. On `x86_64-linux` and `aarch64-linux` it exposes the command as `packages.<system>.kendex-cli`, which is also `packages.<system>.default`. Nix builds it from source at the revision the flake reference names, with the version from the workspace `Cargo.toml` and the dependencies from `Cargo.lock`. No binary cache serves it, so the first install compiles the command.

A flake that depends on the command pins kendex as an input and lists the package wherever it declares packages, such as `environment.systemPackages`, `home.packages` or a derivation's `propagatedBuildInputs`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    kendex = {
      url = "github:vanillagreencom/kendex/<commit>";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, kendex, ... }: {
    # kendex.packages.${system}.kendex-cli
  };
}
```

`<commit>` is a commit on `main` or a release tag that carries `flake.nix`; the consumer's `flake.lock` records the commit either way. The `follows` line is optional: the nixpkgs it names must carry a `rustc` at least as new as the workspace `rust-version`, which is why the flake's own input is `nixos-unstable`.

The package installs `bin/kendex` and nothing else: no desktop app and no `kendex://` handler. The command is wrapped with Git and curl on its `PATH`, ahead of the caller's own, and it links libdbus-1 from the Nix store for the keyring's secret-service backend. A build of a commit displays `<version>+git.<commit>`, as `kendex-cli-git` does; a build of a working tree with uncommitted changes displays the plain version.

`kendex update` refuses to replace a command in the Nix store, whoever runs it, and names Nix as its installer; the desktop app's update card does the same. Move the pin instead: change `<commit>` in the consumer's input, or run `nix flake update kendex` where the input names no commit. A profile installed from `github:vanillagreencom/kendex#kendex-cli` takes `nix profile upgrade kendex-cli`.

## The four Arch packages


| Package | Contents | Source |
|---|---|---|
| `kendex` | app + CLI | the tagged release, built from source |
| `kendex-git` | app + CLI | remote `main`, built from source |
| `kendex-bin` | app + CLI | the release's prebuilt AppImage and command |
| `kendex-cli-git` | CLI | remote `main`, built from source |

All four install `/usr/bin/kendex`, so no two can be installed together: each names the other three in `conflicts`, in both directions. A dependency on the name `kendex` is satisfied by `kendex` itself, which carries it as its `pkgname`, and by `kendex-git` and `kendex-bin`, which declare it in `provides`. `kendex-cli-git` declares no `provides`: a dependency on `kendex` asks for the app as well, and the command alone would satisfy it wrongly. None of the four declares `replaces`: every name already exists under its own recipe, and a `replaces` would swap a person's chosen variant for another during an ordinary system upgrade, taking the desktop app away from a `kendex-git` install without asking.

Every recipe carries `epoch=1`. kendex 1.0.0 follows 5.0.1, so the version number goes backwards; without the epoch pacman reads 1.0.0 as older than the 5.x a machine already holds and never offers the upgrade.

`kendex` and `kendex-git`, the two desktop packages built from source, build the frontend themselves (`npm ci` then `npm run build` under `ui/`) before `cargo build`, because the desktop binary embeds `ui/dist` and only `cargo tauri build` would run that step on its own. Those two install the app as a plain binary at `/usr/lib/kendex/kendex-app`, where `kendex-bin` installs the released AppImage at `/usr/lib/kendex/kendex.AppImage`; both are off `PATH`. `kendex-cli-git` builds from source too and runs neither npm step, which is why it carries no `npm` makedepend and installs no app. The desktop packages depend on `desktop-file-utils` and `xdg-utils` because the app makes itself the `kendex://` handler on first launch through `update-desktop-database` and `xdg-mime`. `kendex-cli-git` depends only on git and `dbus`. All four declare `dbus` because the command links libdbus-1 through keyring’s `sync-secret-service` backend; Arch’s `dbus` also supplies the headers and `dbus-1.pc` for source builds. The Linux Homebrew formula installs `dbus` and patches the command to find its library.

Which package owns a running install is asked of the package manager (`pacman -Qoq`; `dpkg-query -S` and `rpm -qf` for the deb and rpm) rather than read off the layout, in `crates/core/src/install_channel.rs`: all four Arch packages install the same command, two track `main` where the other two track a release, and the update guidance names the package that is actually installed. A name that is none of these names nobody and offers no command.

## Per release

Maintainers update recipe pins after publication through [DEVELOPMENT.md § Release](../DEVELOPMENT.md#release).

### The version restart, once

The formula's counterpart to Arch's epoch is `version_scheme 1`: brew compares the scheme before the number, so an installed 5.0.1 (scheme 0) shows in `brew outdated` and `brew upgrade kendex-cli` moves it; the scheme never goes down. A cask has no version scheme, and `auto_updates true` hands its upgrade to an app that renders no notice for a feed older than itself, so the cask's `caveats` block tells a 5.x install to `brew uninstall` the app, then the `kendex-cli` formula that leaves behind, and install the app again from the tap. `the_formula_declares_the_restart_as_a_new_version_scheme` and `the_cask_tells_a_5_x_install_to_reinstall_the_app_and_its_cli` in `crates/cli/tests/packaging_recipes.rs` hold both; drop the cask's block once no install is left on 5.x.

## Publishing

Maintainer publication, credentials and failure handling: [DEVELOPMENT.md § Publishers](../DEVELOPMENT.md#publishers). Change recipes in this repository; channel publication replaces direct edits in the AUR or tap.

## Caveats

- Releases through v5.0.1 predate notarization; the cask's `caveats` block carries the one-time fix.
- The Linux AppImage needs FUSE (`fuse2`) to run.
- `install.sh` resolves `--version latest` through GitHub's latest-release API, which skips drafts, so `curl … | sh` works only once the draft release is published.
