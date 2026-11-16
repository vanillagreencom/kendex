# change-scope

The shared change classifier for kendex-managed repositories. It names the kind of a change once, so CI selection, review depth and work-tier admission all read one answer.

## Features

- Classifies a pull-request or merge-group range as `render`, `trivial`, `micro`, `small` or `standard`.
- Classifies a work item before its branch exists, from its size estimate, the classes it holds and the paths it names.
- Reads every setting from the base commit, never from the branch under judgement.
- Measures production, test and render-mirror lines with one shared branch measurement.
- Proves a re-rendered install by running `kendex verify` over a private checkout of the head.
- Keeps an agent instruction change or a removed test at `small` or wider.
- Fails closed: anything unproved is `standard`, and the answer says whether it was measured.

## Install

```sh
kendex add vanillagreencom/kendex --skill change-scope
```

## How it works

The classifier reads the changed paths of the range, the settings the base commit holds and the shared path rules. A diff of recorded renders earns its class by being rendered again. A documentation-only diff, a few-line diff or a one-folder diff earns its class by size. A file that gates a merge, runs as a hook or configures a coding tool keeps full checks. Other packages turn the class into their own decision.

The contracts and settings are in [SKILL.md](SKILL.md), `change-scope --help` and `harness-only --help`.

## Licence

MIT, in the repository's LICENSE file.
