# Install channels

Distribution choices for people installing the kendex desktop app, CLI, or both.

## Install

| Channel | Command | Installs | Recipe |
|---|---|---|---|
| curl | `curl -fsSL https://kendex.ai/install.sh \| sh` | app + CLI on Linux; CLI on macOS | [install.sh](../install.sh) |
| Homebrew | `brew install vanillagreencom/kendex/kendex` | app + CLI | [cask](homebrew/kendex-cask.rb) |
| Homebrew CLI | `brew install vanillagreencom/kendex/kendex-cli` | CLI | [formula](homebrew/kendex-cli.rb) |
| Arch prebuilt | `yay -S kendex-bin` | app + CLI | [recipe](arch/kendex-bin/) |
| Arch release from source | `yay -S kendex` | app + CLI | [recipe](arch/kendex/) |
| Arch main from source | `yay -S kendex-git` | app + CLI | [recipe](arch/kendex-git/) |
| Arch main CLI from source | `yay -S kendex-cli-git` | CLI | [recipe](arch/kendex-cli-git/) |
| deb, rpm, Windows setup | Download from the release | app + CLI | [release workflow](../.github/workflows/release.yml) |
| dmg | Download from the release | app, with CLI inside the bundle | [release workflow](../.github/workflows/release.yml) |
| AppImage | Download from the release | app | [release workflow](../.github/workflows/release.yml) |

## How it works

Choose one Arch variant: they install the same command and cannot be installed together. The desktop variants satisfy a dependency on the app; the CLI-only variant does not. The `-git` variants build the latest source; the other variants follow a release.

The `kendex` command runs the CLI. Desktop installations launch the app separately from the application menu or bundle.

## Setup

- The Linux AppImage needs FUSE2 (`fuse2`).
- For an older Homebrew installation, follow the [cask's migration caveats](homebrew/kendex-cask.rb). They cover 5.x reinstalls, a leftover CLI formula and the quarantine remedy for releases through v5.0.1.
- The curl installer's latest-release route needs a published release; it does not install a draft.

## Per release

Maintainers update recipe pins through [DEVELOPMENT.md: Distribution packages](../DEVELOPMENT.md#distribution-packages), after following the [release standard](../changelog.d/README.md#release-standard).

## Publishing

[DEVELOPMENT.md: Distribution packages](../DEVELOPMENT.md#distribution-packages) owns release ordering, dry runs and publisher credentials. The [AUR](../.github/workflows/publish-aur.yml) and [Homebrew](../.github/workflows/publish-homebrew.yml) workflows declare their triggers. Edit recipes in this repository; publication overwrites direct channel edits.

## Licence

[MIT](../LICENSE)
