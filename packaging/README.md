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

Install only one Arch variant at a time. The desktop variants include the CLI; `kendex-cli-git` installs the CLI alone. Use your package manager to update the variant you installed. The [Arch recipes](arch/) own build and dependency details.

## Per release

Maintainers update recipe pins after publication through [DEVELOPMENT.md § Release](../DEVELOPMENT.md#release).

### The version restart, once

To upgrade a Homebrew app installed at 5.x, follow the [cask's reinstall instructions](homebrew/kendex-cask.rb): remove the old app and the CLI formula it leaves behind, then install the app again from the tap. A CLI-only installation takes `brew upgrade kendex-cli`.

## Publishing

Maintainer publication, credentials and failure handling: [DEVELOPMENT.md § Publishers](../DEVELOPMENT.md#publishers). Change recipes in this repository; channel publication replaces direct edits in the AUR or tap.

## Caveats

- Releases through v5.0.1 predate notarization; the cask's `caveats` block carries the one-time fix.
- The Linux AppImage needs FUSE (`fuse2`) to run.
- `install.sh` resolves `--version latest` through GitHub's latest-release API, which skips drafts, so `curl … | sh` works only once the draft release is published.
