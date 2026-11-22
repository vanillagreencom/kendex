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

# Xcode run

- Install this skill in project scope.
- Consent to its repository effects.
- kendex runs `scripts/install.sh`, which adds [templates/mac-run.yml](templates/mac-run.yml) as `.github/workflows/mac-run.yml`.
- The installer preserves an existing workflow.
- Commit the workflow to the default branch. GitHub dispatches a workflow only when the default branch holds it.

## Consumer configuration

Edit the top-level `env` values in `.github/workflows/mac-run.yml`:

| Value | Meaning |
| --- | --- |
| `XCODE_SCHEME` | A shared Xcode scheme |
| `XCODE_DESTINATION` | An Xcode destination available on `macos-latest` |

- Replace the `App` placeholder in `XCODE_SCHEME`.
- Replace the example in `XCODE_DESTINATION` with a simulator supported by the selected Xcode.
- A screenshots run requires a concrete simulator in `XCODE_DESTINATION`, not a generic destination.
- The workflow runs `xcodebuild` from the repository root. A workspace, multiple projects or a project in a subdirectory needs the corresponding path or working directory in the installed workflow.
- The screenshot scheme must build one simulator application target.

## Dispatch

`workflow_dispatch` is the only trigger. Its only input is `step`:

| `step` | Operation |
| --- | --- |
| `build` | `xcodebuild build` |
| `test` | `xcodebuild test` |
| `screenshots` | Boots the selected simulator, builds, installs and launches the app, then captures `screenshots/launch.png` |

A `test` run requires a scheme with a test action.

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

A failing command fails the run, and the run still uploads its log. A failed checkout or runner interruption can prevent log creation or upload.

The workflow disables code signing. It does not archive, export or deploy an app.