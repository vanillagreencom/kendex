---
name: npm-deploy
description: "Audit the Pi extension packages against npm, land their version bumps, publish from the default branch, tag, refresh and verify."
argument-hint: "[package-name]"
---
Run a complete npm deployment pass for the kendex Pi extension packages under `pi-extensions/`. An optional package name in `$ARGUMENTS` limits the audit, the bump, the publish and the tags to that package; with no argument every package is in scope. The catalog policy test and the closing refresh and check read the whole catalog and take no package filter, so a scoped run still validates every package and can update unrelated ones whose merged source changed.

## Intent

Find every `pi-extensions/*/package.json` package whose consumer-facing content changed since its last npm release, then validate it, land its version bump, and tag it; the tag push starts the GitHub workflow that publishes it from the default branch. Then refresh the installed copies and verify. Leave no dirty or untracked files anywhere.

kendex distribution is independent of npm. `kendex update-pi` installs the catalog source; npm publishing populates the pi.dev gallery and lets external users run `pi install npm:@vanillagreen/<name>`. Skipping a publish never breaks kendex consumers.

## Hard rules

- Publish only a commit that is on the default branch: the version bump lands through a pull request through the repository's normal gates and merge queue, never a direct push, and its tag names that merged commit after `git fetch`. The workflow refuses a tag whose commit the default branch does not hold.
- Publish only packages that need a new npm version. Use the scoped name from `package.json` (`@vanillagreen/<name>`).
- Per-package release tags are `<unscoped-name>-v<version>` at the bump commit (example `pi-qol-v2.1.0`). A version npm already serves is never published again; a missing tag for a served version is a tagging gap, fixed by tagging the commit that bumped it.
- The tag push is the publish. `.github/workflows/publish-npm.yml` runs on it and publishes the version the tag names with npm trusted publishing, so this pass runs no `npm publish` and needs no npm login or token. Push one tag per `git push`: GitHub starts no workflow for a push that carries more than three tags.
- Each package's `CHANGELOG.md` is the release record. Consumer-facing changes since the last release sit under `### Unreleased`; a release renames that heading to the new version. A package whose files changed since its tag with no `### Unreleased` entry gets the entry written and merged before any bump.

## Skip publish for

- Refactors with no behavior change, internal cleanup, comment or typo fixes.
- README or documentation edits, unless the gallery copy needs them.
- Repository-only files: tests, fixtures, tooling.

Semver bump from the unreleased entries:

- patch: a fix with no API change, docs packaged with the runtime, a settings or notice wording change.
- minor: additive, such as a new tool, setting, field, command or backward-compatible feature.
- major: breaking, such as a removed or renamed tool, a changed settings key, a changed envelope or protocol shape consumers parse, or a dropped Pi peer floor.

## Audit

1. Inspect `git status --short --branch`; the tree must be clean, and `HEAD` must equal the freshly fetched default-branch ref, so nothing unmerged is audited. Pin that commit as `<base>` and read every package's files and versions from it.
2. Enumerate the packages in scope: `find pi-extensions -maxdepth 2 -name package.json | sort`, reading `name` and `version` from each.
3. For each package compute the npm version (`npm view <name> version`), the unreleased entry count (the `- ` lines under `### Unreleased` in its `CHANGELOG.md`), and the tag for its current version. An `E404` from that lookup means npm serves no version of the package, which is its own row below; any other lookup failure stops the pass with the error npm printed. Where npm serves a version, place the manifest `version` against it with `kendex version-compare <version> <npm version>`, whose verdict is `newer`, `same` or `older`; step 4 acts on `older` and the rows in step 7 mean `newer` and `same`, because a string comparison misreads both a lexical boundary such as 1.10.0 against 1.9.0 and a prerelease identifier.
4. Hold every package's verdict before touching anything. A verdict of `older` means npm serves a version ahead of the default branch, which no ordinary pass produces: stop there and report the package and both versions. Nothing below runs until every package in scope has a verdict, so one package's repair cannot reach the remote ahead of another package's stop.
5. Repair a tagging gap: when npm already serves the manifest `version` and its tag is missing, tag that version's bump commit on the fetched default branch and push the tag. It publishes nothing: where the tag's commit carries the publish workflow, the run the push starts reports `publish-npm: served=`. The tag gives the drift check below a baseline the package would otherwise never reach.
6. Compute the file drift from that tag (`git diff --name-only <tag>..<base> -- pi-extensions/<dir>`). A package whose `version` is newer than npm, and one npm does not serve at all, needs no baseline: a tag for its version, where one exists, marks a publish that has not passed yet, and its row below reads the versions instead.
7. Classify each package:
   - npm serves no version: this is the package's first release. Publish the manifest `version` as declared, with its `CHANGELOG.md` carrying a heading for that version rather than `### Unreleased`, and tag it like any other.
   - `version` newer than npm: publish it (a bump already merged and not yet published).
   - `version` equals npm and unreleased entries exist: bump it first.
   - `version` equals npm, no unreleased entry, files changed since the tag: decide whether the change is consumer-facing; if it is, write the entry first; if not, skip and say why.
   - nothing changed: skip.

## Documentation freshness check

For each package to bump, compare the changed code to its docs before bumping: README, the settings table in `package.json` under `kendex.extensionManager.settings`, and the changelog entries. Fix stale setting keys, config examples, commands, tool names, defaults, behavior claims and install instructions first, through the same pull request. Config examples under `kendex.extensionManager.config` use the scoped key (`"@vanillagreen/pi-web-tools"`, never `"pi-web-tools"`).

## Validation

For every package in scope, before the bump lands, first run that package's setup the way its lane in `.github/workflows/skill-tests.yml` does, which owns those steps: a pinned peer install for some packages and `npm ci` for others. A fresh checkout without it stops on a missing module rather than on the package. Then run the strongest validation the package declares that a runner can complete: `npm run test:ci` when `scripts.test:ci` exists, which is the catalog's credential-free entry point, else `npm run check` when `scripts.check` exists, else the available `typecheck`, `test:unit`, `test` and `build` scripts. Run `node --test pi-extensions/package-policy.test.mjs`, which reads the whole catalog whatever the run is scoped to. Do not proceed on a failing validation unless the user explicitly accepts the risk.

## Version bump

Land every bump in one pull request: in each package run `npm version <new> --no-git-tag-version` from its own directory, so a committed `package-lock.json` follows the manifest, then rename its `### Unreleased` heading to `### <new version>`; change nothing else. Use the subject `chore(pi-extensions): npm release wave version bumps [no-changelog]`. Take the PR through review, the review gate, CI and the merge queue, then fetch the default branch again and pin its head as `<head>`. When this run lands no bump, `<head>` is `<base>`.

## Publish, tag, refresh, verify

For each package to publish, find its release commit first and call it `<release>`. For a package whose `version` is newer than npm, `<release>` is the newest commit on `<head>` that set `pi-extensions/<dir>/package.json` to the version being published, which is this run's merged bump where this run bumped that package. A wave mixes packages bumped now with packages bumped in an earlier run, so one commit cannot stand for all of them. For a package npm does not serve at all, `<release>` is `<head>` itself, because the commit that first set the version can precede the commits that completed the package, and only `<head>` is the validated default-branch state.

1. From the repository checkout, tag `<release>` as `<unscoped-name>-v<version>` and push that tag alone: `git push origin <tag>`. The push starts `.github/workflows/publish-npm.yml`, which publishes the version the tag names; `tools/publish-npm --help` lists every check it makes and every answer it prints.
2. Find the run the tag started with `gh run list --workflow publish-npm.yml --event push --branch <tag> --json databaseId,url`; it can take a few seconds to appear. Watch it with `gh run watch <databaseId> --exit-status`. A tag whose commit predates the workflow file starts no run: publish it with the dispatch in step 4.
3. Confirm `npm view <name> version` reports the new version, and keep the run URL for the final report.
4. When the run fails, read its log (`gh run view <databaseId> --log-failed`), fix the cause, and run it again against the same tag with `gh workflow run publish-npm.yml -f package=<unscoped-name> -f version=<version>`; watch that run as in step 2, with `--event workflow_dispatch` in place of `--event push --branch <tag>`. A tag already on the remote from an earlier failed run takes this dispatch too, never a second push. Until a run passes, the package's publication stays open in the final report. It blocks nothing else: continue with the other packages and the refresh below.

Then refresh the installed copies, which is a whole-scope pass and can move packages this run did not publish: `kendex refresh --global --yes`, which fetches the sources the global scope declares and needs `--yes` because a harness shell has no terminal to ask the write question at; a declared-source fetch there that fails only prints a `warning:` line and refreshes from the cached copy, so stop the pass on that line and report it rather than reading the check below as proof. Then `kendex update-pi --scope global`, then `kendex update-pi --check --scope global`, which must report every package up to date. `update-pi` finds a second copy itself and prints a `pi-shadow-package=<name>` block naming the managed copy, the shadow copy and the remedy. Report every block those two runs print, rather than listing Pi's `extensions/` directory by hand: the scan matches a loose module file as well as a directory, under any name, by the manifest and entry set rather than the directory name. Confirm `git status --short --branch` is clean.

## Final report

Report the packages audited and how each was classified, the versions published with their npm confirmation and publish run URL, every publication still open with its failed run URL, the bump pull request and the tags pushed, the validation commands and their results, the refresh and check results, any shadow copy found, and the final git status.
