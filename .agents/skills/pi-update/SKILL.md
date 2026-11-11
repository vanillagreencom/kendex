---
name: pi-update
description: "Load to check the kendex Pi extensions against a Pi release, fix what breaks, and record the verdict."
summary: "Pi compatibility audit: capture the target release, audit its changelogs, apply the pi-hooks blocking rule, prove the real extensions against its SDK, fix forward, record one verdict, notify the fleet and hand publication to npm-deploy."
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# Pi update

Checks `pi-extensions/*` against a Pi release and records one verdict. The record is `pi-extensions/pi-update.audit.md`, the one compatibility record. The marker `pi-extensions/pi-update.state.json` only says which releases were read. The rule the verdict applies is `pi-extensions/AGENTS.md`.

To audit a Pi release, follow [workflows/audit-release.md](workflows/audit-release.md). A step this file cites is that workflow's step.

## Release handling

- Pin nothing, freeze nothing, hold no release back. Fleet lanes follow the vendor's latest Pi through the fleet's `fleet-cli-update`. A `hold` verdict stops a peer floor from rising, never a lane from updating.
- Start the run as soon as a new release is seen.
- The Linear item a new Pi release creates, and every follow-up a failing run files, is priority High (2), never Backlog. A failing run is fixed forward, never by pinning Pi to an older release.

## Input

- No argument: the target is npm's current `latest` of `@earendil-works/pi-coding-agent`.
- A version: that version is the target. Every source is still fetched.
- A pasted changelog: the authoritative entry list for the range; changelog fetching is skipped. The target is the highest released version header in the paste, and [workflows/audit-release.md](workflows/audit-release.md) step 1 captures that version.

## Audit record

Name each Linear item by id only, beside the Pi entry and package it concerns. Do not state its status, priority or adoption.

The record holds: the ``Marker `<old>` → `<new>`.`` line, where `<old>` is `lastVersion` at run start and `<new>` the target; the sources fetched; every classified entry; and a `## Verdict` section. The Verdict section opens with the verdict and then this summary, in this form:

```markdown
Verdict: `roll`.

- Target release: `<version>`, npm `@earendil-works/pi-coding-agent@<version>` integrity `<sha512-…>`, upstream source commit `<40-hex>`.
- Entries examined: <the releases and sources read, and the Breaking Changes entries the table lists>.
- Tested extension commit: `<40-hex>`.
- Evidence: <the `<run>` directory, the fixtures, tests and CI runs step 4 and step 6 ran, and the Pi version each resolved>.
```

The Breaking Changes table follows. A `roll` clears `<new>`; a `hold` clears `<old>`. What `pi-extensions/package-policy.test.mjs` refuses in the record is the Pi update audit bullet of `pi-extensions/AGENTS.md`.

## Final report

- Releases covered, old marker to target, with dates, and the source keys that carried entries.
- Entry counts per bucket, and the verdict with each blocking entry and the pi-hooks change it waits for.
- Commits shipped, packages touched, and tests run with pass counts.
- Deferred Optional entries with their reasons; the Non-impact log.
- The tested extension commit, the marker commit, the npm-deploy item, and the refresh result.
- How step 7's result was sent: from a lane, the exit status of `lane-mail notice`, which prints nothing on success; from the control VM, the receipt `lane-mail peer send` prints.
- `git status --short` is clean.

## Notes

- Pi releases every package in lockstep under one version, so `lastVersion` covers the whole release.
- `pi update` reconciles only `git:` and `npm:` entries in Pi's `settings.json`. kendex installs extensions as path packages, so a changelog entry about `pi update` does not reach them; say so in the record.
- `pi-tool-renderer` replaces Pi's `read`, `bash`, `edit`, `write`, search and list renderers. A Pi change to their default look is a choice for the user, not an automatic mirror.
