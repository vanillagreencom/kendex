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

## Release handling

- Pin nothing, freeze nothing, hold no release back. Fleet lanes follow the vendor's latest Pi through the fleet's `fleet-cli-update`. A `hold` verdict stops a peer floor from rising, never a lane from updating.
- Start the run as soon as a new release is seen.
- The Linear item a new Pi release creates, and every follow-up a failing run files, is priority High (2), never Backlog. A failing run is fixed forward, never by pinning Pi to an older release.

## Input

- No argument: the target is npm's current `latest` of `@earendil-works/pi-coding-agent`.
- A version: that version is the target. Every source is still fetched.
- A pasted changelog: the authoritative entry list for the range; changelog fetching is skipped. The target is the highest released version header in the paste, and step 1 captures that version.

## 1. Capture the target

Read the target once, at the start, and use these values for the whole run:

```bash
npm view @earendil-works/pi-coding-agent@<latest|version> version dist.integrity gitHead
gh api repos/earendil-works/pi/commits/v<version> --jq .sha
```

The two commit values must match; a mismatch stops the run. Record the version, the integrity, the upstream source commit and `git rev-parse HEAD` as the run-start head.

Create this run's own directory with `mkdir -p tmp/pi-update && mktemp -d tmp/pi-update/run.XXXXXX`; `<run>` is the path it prints, and the record's Evidence names it. A retry starts a new `<run>`. Write the candidate record under `tmp/pi-update/`. The committed `pi-update.audit.md` keeps the last cleared record until step 6 replaces it.

## 2. Audit the range

- **Marker.** In scope is every released version header above `lastVersion` and at or below the target. A target at or below `lastVersion` means nothing to audit: refresh `lastRun` and `lastRunHead`, commit the marker, stop. `lastVersion` and `lastDate` never move backward.
- **First run** (marker absent): propose a baseline, the newest Pi version named in `git log`, and ask the user to confirm it before any work. Seed the marker there.
- **Sources.** Enumerate every changelog on each run; never trust a stored list:

  ```bash
  gh api 'repos/earendil-works/pi/git/trees/main?recursive=1' --jq '.tree[].path | select(endswith("/CHANGELOG.md"))'
  gh api repos/earendil-works/pi/contents/<path> -H "Accept: application/vnd.github.raw"
  ```

  A source key is the path without `packages/` and `/CHANGELOG.md`. Record every key in the marker's `sourcesCovered`; report a key present last run and absent now. <https://pi.dev/news/releases> is a cross-check only. A `## [Unreleased]` block is a heads-up, never in scope.

- **Classify** each entry into one bucket:
  - Required parity fix: Pi changed a behaviour, event shape, provider input or setting that an extension overrides, mirrors, reads or copied.
  - Optional improvement: a new Pi field, helper or event that could simplify an extension that is still correct.
  - Non-impact: outside every extension surface. One line of reason each.
- For an entry that adds or changes a field of a tool result, an event or a provider stream option, find every kendex listener or override of that surface, including `tool_result` handlers and `registerProvider` shims. Record each listener or override beside the entry with its classification.
- **Triage by import.** A source reaches every package that imports its npm package (`coding-agent` is `@earendil-works/pi-coding-agent`, `ai` is `@earendil-works/pi-ai`, `agent` is `@earendil-works/pi-agent-core`, `tui` is `@earendil-works/pi-tui`, and so on). Find them on each run, never from a stored list: `grep -rlE "['\"]@earendil-works/pi-<name>['\"/]" pi-extensions/*/ --include='*.ts' --include='*.mjs' --include='*.js' --exclude-dir=node_modules --exclude-dir=tests --exclude-dir=__tests__`. For an `ai` entry that names a provider, also grep `pi-extensions/*/` for that provider id: a package that registers the provider is in reach. A source that no package imports is Non-impact.
- For each Required or Optional entry, cite the affected `path::symbol` and read the Pi source when a field name is unclear.

## 3. Apply the blocking rule

Read `pi-extensions/pi-hooks/pi-contract.json` for the events and calls pi-hooks uses; never a fixed list. Check every `### Breaking Changes` entry in range, from every source, against it. The rule for an entry that names one is `pi-extensions/AGENTS.md`. List each Breaking Changes entry in the record's Verdict table with the contract names it carries.

## 4. Prove behaviour against the target

Package suites run on older pinned Pi versions and fake hosts, so a green suite does not prove a contract change. For every Required entry and every blocking entry:

- **One install location.** Node resolves an import from the importing file's own directories, so an install beside a package is invisible to it. Copy the whole `pi-extensions` tree without any `node_modules`, so a test that imports a sibling package by relative path finds it. Each time this step runs, make a new directory with `mktemp -d <run>/work.XXXXXX` and copy into it with `rsync -a --exclude node_modules pi-extensions <that directory>/`. `<copy>` is `pi-extensions/<package>` inside that directory. In `<copy>`, run `npm install --no-save --include=dev --include=peer --include=optional --no-package-lock --ignore-scripts --no-audit --no-fund` with every `@earendil-works/pi-*` package named in its dependency declarations, including `peerDependencies` and `devDependencies`, each at `@<version>`, plus the other packages its `DEVELOPMENT.md` install line names. Keep `package.json` unchanged. The extension, its other dependencies, every check and the suite then run from `<copy>`.
- **Prove the version.** Before any check or suite, print the `@earendil-works/pi-coding-agent` version that resolves from the extension's entry file and from the suite's directory. The record states it. A version other than the target stops the run.

  ```bash
  node --input-type=module -e 'import { findPackageJSON } from "node:module"; import { readFileSync } from "node:fs"; import { pathToFileURL } from "node:url"; for (const at of process.argv.slice(1)) console.log(at, JSON.parse(readFileSync(findPackageJSON("@earendil-works/pi-coding-agent", pathToFileURL(at)), "utf8")).version)' <copy>/<entry file> <copy>/<suite directory>/
  ```

- Put each check in `<copy>`'s own test directory, and load the real extension from `<copy>` into a real `createAgentSession` with a controlled provider: a faux provider as in `pi-extensions/pi-hooks/tests/pi-session.ts`, or a stubbed endpoint for a provider an extension registers, as in `pi-extensions/pi-codex-minimal-tools/tests/transcript-context.test.ts`.
- Pair each check with a regression control that fails on the old behaviour: the check run on a copy of the pre-fix code set up the same way, or a fixture that plants the old behaviour. A check whose control passes proves nothing.
- Run each touched package's suite in `<copy>` with the command its `test` script runs, less any `npm install` the script runs first: that install puts the package's own pin back (`pi-hooks` has one).

When a behaviour cannot be exercised inside Pi, the record says so; it never asserts parity.

## 5. Repair and simplify

- Edit the canonical files under `pi-extensions/` only, never a harness mirror (`.pi/`, `.claude/`, `.codex/`, `.agents/`, `.opencode/`, `.cursor/`).
- A fix to behaviour a `hooks/*.sh` script holds changes `pi-extensions/pi-hooks/extensions/hooks.ts` in the same commit.
- Each fix ships a test per the code-quality skill and a `### Unreleased` entry in the package's `CHANGELOG.md`. Bump no package version; bump no CLI version.
- Take an Optional entry that removes code, or defer it with its reason.
- One commit per logical change. A fix that spans packages for one entry is one commit naming them all.
- A fix you cannot land in this run becomes a Linear item at priority High (2) through the linear skill, and the verdict follows `pi-extensions/AGENTS.md`.

## 6. Merge and record

1. Land the fixes through a pull request (orch). Stage only intended files.
2. Test the exact merged commit: extract the `pi-extensions` tree of the full default-branch commit that holds the fixes into a new directory from `mktemp -d <run>/merged.XXXXXX` with `git archive <sha> pi-extensions | tar -x -C <that directory>`. `<copy>` is now `pi-extensions/<package>` inside it. Copy each step 4 check from the newest work copy's test directory into `<copy>`'s, then run step 4 from its install on in `<copy>`: the install, the version proof, the checks and the suite, and no `rsync`. That full SHA is the tested extension commit.
3. Replace `pi-update.audit.md` with the candidate record (§ Audit record) and update the marker: under `roll`, `lastVersion` and `lastDate` move to the target; under `hold` they stay at the last cleared release. Either way `lastRun` and `lastRunHead` refresh.
4. Run `node --test pi-extensions/package-policy.test.mjs` and land the record and marker through a pull request whose subject says `audited through v<version>`.
5. From the main checkout, run `kendex refresh` and report the Pi packages it updated.

## 7. Notify and publish

- Write the result to `tmp/pi-update/result.md`, naming the Pi release, the verdict and the tested extension commit. From a lane, send it to your own overseer with `.agents/skills/orch/scripts/lane-mail notice --item <ITEM> --file tmp/pi-update/result.md`, the text opening with `For the fleet overseer:`; the overseer relays it with `lane-mail peer send --repo fleet --file <PATH>`. From a session on the control VM's kendex checkout, `.agents/skills/orch/scripts/lane-mail peer send --repo fleet --file tmp/pi-update/result.md` reaches the fleet overseer directly.

- Publication is the `npm-deploy` skill, run as linked work: a Linear item related to this one. A failed publish leaves that item open. It does not block fleet rollout, and it does not block the next compatibility run. Add no publication recovery step.

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
