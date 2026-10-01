---
name: xcode-run
description: "Load to install or dispatch a macOS GitHub Actions build, test or simulator screenshot run for an Xcode project."
summary: "Installs a manual Mac workflow for Xcode builds, tests and simulator screenshots. Each run returns its logs and PNGs in one artifact."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "1.0.0"
tags: [swift, testing]
repo-effects:
  summary: "Adds a manual Mac build, test and simulator screenshot workflow to this repository."
  writes:
    - ".github/workflows/mac-run.yml"
  installer: "scripts/install.sh"
  removal: "Delete .github/workflows/mac-run.yml."
  notes:
    - "An existing workflow is preserved, including its scheme and destination settings."
    - "Set XCODE_SCHEME and XCODE_DESTINATION in the installed workflow before dispatch."
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# Xcode run

Install this skill in project scope and consent to its repository effects. kendex runs `scripts/install.sh` to add [templates/mac-run.yml](templates/mac-run.yml) as `.github/workflows/mac-run.yml`. The installer preserves an existing workflow. Commit the workflow to the default branch so GitHub can dispatch it.

## Consumer configuration

Edit the top-level `env` values in `.github/workflows/mac-run.yml`:

| Value | Meaning |
| --- | --- |
| `XCODE_SCHEME` | A shared Xcode scheme. Replace the `App` placeholder. |
| `XCODE_DESTINATION` | An Xcode destination available on `macos-latest`. Replace the example with a simulator supported by the selected Xcode. Screenshots require a concrete simulator, not a generic destination. |

The workflow runs `xcodebuild` from the repository root. A workspace, multiple projects or a project in a subdirectory needs the corresponding path or working directory in the installed workflow. The screenshot scheme must build one simulator application target. The workflow reads its app path and simulator identifier from `xcodebuild -showBuildSettings -json`. It reads the bundle identifier from the built app's `Info.plist`.

## Dispatch

`workflow_dispatch` is the only trigger. Its only input is `step`:

| `step` | Operation |
| --- | --- |
| `build` | `xcodebuild build`. This is the default. |
| `test` | `xcodebuild test`. The scheme must have a test action. |
| `screenshots` | Boot the selected simulator, build, install and launch the app, then capture `screenshots/launch.png`. |

```bash
gh workflow run mac-run.yml -f step=build
gh workflow run mac-run.yml -f step=test
gh workflow run mac-run.yml -f step=screenshots
```

Screenshots capture the launch view after a short wait. They do not navigate the app or assert that its UI is ready.

## Artifact

Each run uploads one artifact named `mac-run`:

- `logs/<step>.log`: combined command output for the selected operation.
- `screenshots/*.png`: simulator images from a screenshot run.

The upload runs with `if: always()`. A failing command fails the run and keeps its log for upload. A failed checkout or runner interruption can prevent log creation or upload.

The workflow disables code signing. It does not archive, export or deploy an app.