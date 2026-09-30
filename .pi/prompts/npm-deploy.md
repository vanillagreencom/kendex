---
name: npm-deploy
description: "Audit the Pi extension packages against npm, land their version bumps, tag them so the publish workflow runs, refresh and verify."
argument-hint: "[package-name]"
---
Run a complete npm deployment pass for the kendex Pi extension packages under `pi-extensions/`. An optional package name in `$ARGUMENTS` limits the audit, the bump, the publish and the tags to that package; with no argument every package is in scope. The catalog policy test and the closing refresh and check read the whole catalog and take no package filter, so a scoped run still validates every package and can update unrelated ones whose merged source changed.

## Intent

Find every `pi-extensions/*/package.json` package whose consumer-facing content changed since its last npm release, then validate it, land its version bump, and tag it; the tag push starts the GitHub workflow, which publishes it from the default branch. Then refresh the installed copies and verify. Leave no dirty or untracked files anywhere.

kendex distribution is independent of npm. `kendex update-pi` installs the catalog source; npm publishing populates the pi.dev gallery and lets external users run `pi install npm:@vanillagreen/<name>`. Skipping a publish never breaks kendex consumers.

## Hard rules

- Publish only a commit that is on the default branch: the version bump lands through a pull request through the repository's normal gates and merge queue, never a direct push, and its tag names that merged commit after `git fetch`. The workflow refuses a tag whose commit the default branch does not hold.
- Publish only packages that need a new npm version. Use the scoped name from `package.json` (`@vanillagreen/<name>`).
- Per-package release tags are `<unscoped-name>-v<version>` at the bump commit (example `pi-qol-v2.1.0`). A version npm already serves is never published again; a missing tag for a served version is a tagging gap, repaired as Audit step 5 says.
- The tag push is the publish. `.github/workflows/publish-npm.yml` runs on it and dispatches its own publish job on the default branch, which publishes the version the tag names with npm trusted publishing. For a package npm already serves, this pass runs no `npm publish` and needs no npm login or token; a package npm does not serve yet is the first-release row of Audit step 7. Push one tag per `git push`: GitHub starts no workflow for a push that carries more than three tags.
- Each package's `CHANGELOG.md` is the release record. Consumer-facing changes since the last release sit under `### Unreleased`; a release renames that heading to the new version. A package whose files changed since its tag with no `### Unreleased` entry gets the entry written and merged before any bump.

## Skip publish for

- Refactors with no behavior change, internal cleanup, comment or typo fixes.
- README or documentation edits, unless the gallery copy needs them.
- Repository-only files: tests, fixtures, tooling.

Choose the bump and write breaking-change entries under the [release standard](https://github.com/vanillagreencom/kendex/blob/main/changelog.d/README.md#release-standard). It also defines compatibility and owner approval.

## Audit

1. Inspect `git status --short --branch`; the tree must be clean, and `HEAD` must equal the freshly fetched default-branch ref, so nothing unmerged is audited. Pin that commit as `<base>` and read every package's files and versions from it.
2. Enumerate the packages in scope: `find pi-extensions -maxdepth 2 -name package.json | sort`, reading `name` and `version` from each.
3. For each package compute the npm version (`npm view <name> version`), the unreleased entry count (the `- ` lines under `### Unreleased` in its `CHANGELOG.md`), and the tag for its current version. An `E404` from that lookup means npm serves no version of the package, which is its own row below; any other lookup failure stops the pass with the error npm printed. Where npm serves a version, place the manifest `version` against it with `kendex version-compare <version> <npm version>`, whose verdict is `newer`, `same` or `older`; step 4 acts on `older` and the rows in step 7 mean `newer` and `same`, because a string comparison misreads both a lexical boundary such as 1.10.0 against 1.9.0 and a prerelease identifier.
4. Hold every package's verdict before touching anything. A verdict of `older` means npm serves a version ahead of the default branch, which no ordinary pass produces: stop there and report the package and both versions. Nothing below runs until every package in scope has a verdict, so one package's repair cannot reach the remote ahead of another package's stop.
5. Repair a tagging gap: when npm already serves the manifest `version` and its tag is missing, tag that version's bump commit on the fetched default branch and push the tag; a bootstrapped first release is tagged at the commit the admin published it from, not the first commit that set its version. It publishes nothing: where the tag's commit carries the publish workflow, the publish run its push dispatches on the default branch reports `publish-npm: served=`; find it as in Publish step 3. The tag gives the drift check below a baseline the package would otherwise never reach.
6. Compute the file drift from that tag (`git diff --name-only <tag>..<base> -- pi-extensions/<dir>`). A package whose `version` is newer than npm takes its drift from its release commit instead, `<release>`: the newest commit that set `pi-extensions/<dir>/package.json` to that version. A tag for its version, where one exists, marks a publish that has not passed yet, so its row below reads the versions and the drift from `<release>`.
7. Classify each package:
   - npm serves no version: this is the package's first release, which npm trusted publishing cannot make. Stop the pass for that package, publish and tag nothing for it, and report it as needing the one-time bootstrap in `docs/RELEASING.md` § Pi packages on npm. The admin who makes it tags the commit it was published from, so the next pass reads it as a served package.
   - `version` newer than npm: publish it (a bump already merged and not yet published) when its drift from `<release>` is empty. When the package changed since `<release>`, bump it again: the workflow refuses a tag whose package directory differs from the default branch's with `publish-npm: moved=<tag>`.
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

For each package to publish, find its release commit first: `<release>` as Audit step 6 defines it, read on `<head>`, which is this run's merged bump where this run bumped that package. A wave mixes packages bumped now with packages bumped in an earlier run, so one commit cannot stand for all of them.

1. When the tag `<unscoped-name>-v<version>` already exists on the remote (`git ls-remote --tags origin refs/tags/<tag>` prints a line), from an earlier pass whose publish did not pass, skip the tag and the push: note `<since>`, dispatch as in step 4, then find and watch the run as in step 3. Otherwise note the time as `<since>` (`date -u +%Y-%m-%dT%H:%M:%SZ`), and from the repository checkout tag `<release>` as `<unscoped-name>-v<version>` and push that tag alone: `git push origin <tag>`. The push starts a short run of `.github/workflows/publish-npm.yml` whose one job dispatches the publish run on the default branch; the publish run does the work. `tools/publish-npm --help` lists every check it makes and every answer it prints.
2. Check that the tag's commit carries the workflow: `git cat-file -e <tag>:.github/workflows/publish-npm.yml`. When it fails, the push started no run: dispatch the publish yourself as in step 4 and watch that run.
3. Find the publish run: `gh run list --workflow publish-npm.yml --event workflow_dispatch --created ">=<since>" --json databaseId,displayTitle,url --jq 'map(select(.displayTitle == "publish-npm <tag>"))'`. Every run of the workflow carries its tag in that title. Read again every 10 seconds; when no run appears within 3 minutes, find the tag's own run with `--event push --branch <tag>` in place of `--event workflow_dispatch`, read its log (`gh run view <databaseId> --log`), and report the publication open with that run's URL. Watch the publish run with `gh run watch <databaseId> --exit-status`, then confirm `npm view <name> version` reports the new version, and keep the run URL for the final report.
4. When the publish run fails, read its log (`gh run view <databaseId> --log-failed`) and fix the cause. A fix under `pi-extensions/<dir>`, and a run that answers `publish-npm: moved=<tag>`, need a new version: npm's provenance names the default branch's commit, so the same tag can no longer publish. Land that bump as in Version bump and tag it as in step 1. For any other cause, note a new `<since>` and run it again against the same tag: `gh workflow run publish-npm.yml --ref main -f tag=<tag>`; find and watch that run as in step 3. The publish job runs on the default branch alone, so a dispatch from any other ref fails before it starts. A tag already on the remote from an earlier failed run takes this dispatch too, never a second push. Until a run passes, the package's publication stays open in the final report. It blocks nothing else: continue with the other packages and the refresh below.

Then refresh the installed copies, which is a whole-scope pass and can move packages this run did not publish: `kendex refresh --global --yes`, which fetches the sources the global scope declares and needs `--yes` because a harness shell has no terminal to ask the write question at; a declared-source fetch there that fails only prints a `warning:` line and refreshes from the cached copy, so stop the pass on that line and report it rather than reading the check below as proof. Then `kendex update-pi --scope global`, then `kendex update-pi --check --scope global`, which must report every package up to date. `update-pi` finds a second copy itself and prints a `pi-shadow-package=<name>` block naming the managed copy, the shadow copy and the remedy. Report every block those two runs print, rather than listing Pi's `extensions/` directory by hand: the scan matches a loose module file as well as a directory, under any name, by the manifest and entry set rather than the directory name. Confirm `git status --short --branch` is clean.

## Final report

Report the packages audited and how each was classified, the versions published with their npm confirmation and publish run URL, every publication still open with its failed run URL, every first release waiting for its bootstrap, the bump pull request and the tags pushed, the validation commands and their results, the refresh and check results, any shadow copy found, and the final git status.
