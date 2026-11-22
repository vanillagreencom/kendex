# change-scope

The shared change classifier for kendex-managed repositories. It names a change's class once, and the CI checks, the review depth and the work tier orch picks all read that one answer.

## Features

- Classifies a pull-request or merge-group range as `render`, `trivial`, `micro`, `small` or `standard`.
- Classifies a work item before its branch exists, from its size estimate, the classes it holds and the paths it names.
- Reads repository policy from the base commit, not from the change.
- Counts a branch's production, test and generated lines the same way for every caller.
- Checks that each changed generated install file matches a fresh generation of it.
- Keeps an agent instruction change or a removed test at `small` or wider.
- Treats anything it cannot prove as `standard`, and says whether it measured the change.

## Install

```sh
kendex add vanillagreencom/kendex --skill change-scope
```

## How it works

The classifier reads the range's changed paths, the settings the base commit holds and the shared path rules. A change to generated files is `render` only when generating them again gives the same files. A documentation-only, few-line or one-folder change gets its class by size. A file that gates a merge, runs as a hook or configures a coding tool keeps full checks. Other packages turn the class into their own decision.

The contracts and settings are in [SKILL.md](SKILL.md), `change-scope --help` and `harness-only --help`.

## Licence

MIT, in the repository's LICENSE file.
