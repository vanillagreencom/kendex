# change-scope

The shared change classifier for kendex-managed repositories. It names the kind of a diff once, so CI selection, review depth and work-tier admission all read one answer.

## Features

- Classify a pull-request or merge-group range as `render`, `trivial`, `micro`, `small` or `standard`.
- Read every setting from the base commit, never from the branch under judgement.
- Measure production, test and render-mirror lines with one shared branch measurement.
- Prove a re-rendered install by running `kendex verify` over a private checkout of the head.
- Fail closed: anything unproved is `standard`, and the answer says whether it was measured.

## Install

```bash
kendex add vanillagreencom/kendex --skill change-scope
```

## How it works

The classifier reads the changed paths of the range, the settings the base commit holds and the shared path rules. A diff of recorded renders is proved by re-rendering; a documentation-only diff, a few-line diff or a one-subsystem diff earns its class by size; a file that gates a merge, runs as a hook or configures a harness keeps full checks. Other packages map the class to their own decision.

Contracts and settings: [SKILL.md](SKILL.md), `change-scope --help` and `harness-only --help`.

## Licence

MIT, in the repository's LICENSE file.
