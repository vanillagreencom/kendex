# change-scope

The shared change classifier for kendex-managed repositories. It names a change's class once, and CI selection, review depth and work-tier admission all read that one answer.

## Features

- Classifies a pull-request or merge-group range as `render`, `trivial`, `micro`, `small` or `standard`.
- Classifies a work item before its branch exists, from its size estimate, the classes it holds and the paths it names.
- Reads repository policy from the base commit. `change-scope --help` declares the measurement settings' precedence.
- Measures production, test and render-mirror lines with one shared branch measurement.
- Proves a re-rendered install by running `kendex verify` over a private checkout of the head.
- Keeps an agent instruction change or a removed test at `small` or wider.
- Fails closed: anything unproved is `standard`, and the answer says whether it was measured.

## Install

```sh
kendex add vanillagreencom/kendex --skill change-scope
```

## How it works

The classifier reads the range's changed paths, the settings the base commit holds and the shared path rules. A diff of recorded renders earns its class when rendering it again matches. A documentation-only, few-line or one-folder diff earns its class by size. A file that gates a merge, runs as a hook or configures a coding tool keeps full checks. Other packages turn the class into their own decision.

The contracts and settings are in [SKILL.md](SKILL.md), `change-scope --help` and `harness-only --help`.

## Licence

MIT, in the repository's LICENSE file.
