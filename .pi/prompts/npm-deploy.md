---
description: Audit changed Pi extensions, validate, bump, publish to npm, tag, push, refresh, and verify
argument-hint: "[package-name]"
---
Run a complete npm deployment pass for vstack Pi extensions. Optional package filter: `$ARGUMENTS`.

## Intent
Find every `pi-extensions/*/package.json` package whose source/docs/package contents changed since its last npm deployment tag, then validate, bump, publish, tag, push, refresh, and verify it. Leave no dirty/untracked files.

vstack distribution is independent of npm. `vstack add`/`refresh` copies local source — npm publishing only populates the pi.dev gallery and lets external users run `pi install npm:@vanillagreen/<name>`. Skipping a publish never breaks vstack consumers.

## Hard rules
- Publish only Pi extension packages that actually need a new npm version.
- Use scoped npm names from `package.json` (normally `@vanillagreen/<name>`).
- Per-package release tags use `<unscoped-name>-v<version>` (example: `pi-qol-v1.0.4`).
- Never publish outside `op run --env-file=../../.env.npm -- npm publish --userconfig=../../.npmrc`.
- Never write or log npm tokens. `.env.npm` only contains an `op://` reference, never a literal token; never commit `.env.npm` (gitignored).
- Never use `op run --no-masking` outside one-off auth verification.
- Stage only intended files. Preserve unrelated user dirty files; if unrelated dirt exists, stop and ask unless the user explicitly included it.
- Version bump commits are separate from source/docs commits when source/docs changes are not already committed.
- After any committed Pi package source change, run `vstack refresh -g`, then `vstack verify -g <changed packages...>`.

## Skip publish for
- Refactors with no behavior change.
- Internal cleanup, comment/typo fixes.
- README/doc edits unless gallery copy needs updating.

Semver bump rules:
- patch — bug fix, no API change.
- minor — additive: new tool, new setting, backward-compatible feature.
- major — breaking: removed/renamed tool, changed setting key, dropped Pi peerDependency support.

## Audit
1. Inspect `git status --short --branch`.
2. Enumerate all packages:
   - `find pi-extensions -maxdepth 2 -name package.json -print | sort`
   - For each manifest, read `name` and `version`.
3. For each package, compute:
   - current npm version: `npm view <name> version`
   - expected current tag: `<unscoped-name>-v<package.json version>`
   - source drift since that tag: `git diff --name-only <tag>..HEAD -- <package-dir>` when the tag exists.
4. Mark a package for deployment if any of these are true:
   - package files changed since its current version tag,
   - `package.json` version is greater than npm version,
   - npm version exists but matching git tag is missing,
   - user package filter names the package.

## Documentation freshness check
For each marked package, compare changed code to package docs before publishing:
- Read its README and package `vstack.extensionManager.settings`.
- Look for stale setting keys, config examples, commands, shortcuts, tool names, default values, package names, behavior claims, screenshots captions, and install/publish instructions.
- If new user-visible behavior, settings, commands, tool behavior, critical safety behavior, or workflow changes are missing from docs, update docs first.
- Also grep all Pi extension READMEs for stale unscoped config examples such as `"pi-web-tools"` under `vstack.extensionManager.config`; current keys should be scoped (`"@vanillagreen/pi-web-tools"`).

## Validation
For every marked package, run the strongest available validation before publish:
- If `scripts.check` exists: `npm run check`.
- Else run available `typecheck`, `test:unit`, `test`, and/or `build` scripts as applicable.
- If no scripts exist, run lightweight syntax/import checks where practical (for TS-only Pi extensions, use an existing package with `tsx` if available, or explain why live import is not practical due peer deps).
- For repo-level/CLI changes discovered while auditing, run relevant repo tests too (`cd cli && cargo test`).
- Do not proceed on failing validation unless the user explicitly accepts the risk.

## Commit source/docs before version bumps
If there are intended source/docs changes not yet committed:
1. Stage only those intended files.
2. Commit with a concise package-scoped message.
3. Re-check status.

## Version bump and publish
For each marked package that needs publishing:
1. Choose semver bump:
   - patch: bug fix, docs packaged with runtime, settings/docs cleanup, UI fix.
   - minor: additive new command/tool/setting/feature.
   - major: breaking setting/tool/API behavior.
2. Bump the package only:
   ```bash
   cd pi-extensions/<dir>
   npm version <patch|minor|major> --no-git-tag-version
   cd ../..
   ```
3. Stage only that package's `package.json` and any lockfile changed by `npm version`.
4. Commit version bumps. Prefer a single coordinated commit if deploying multiple packages.
5. Publish each package:
   ```bash
   cd pi-extensions/<dir>
   op run --env-file=../../.env.npm -- npm publish --userconfig=../../.npmrc
   cd ../..
   ```
6. Verify npm reports the new version:
   `npm view <name> version`.
7. Create per-package git tags at the version-bump commit:
   `git tag <unscoped-name>-v<version>`.

## Push, refresh, verify
1. Push `main` and all new package tags.
2. Run:
   ```bash
   vstack refresh -g
   vstack verify -g <changed scoped package names...>
   ```
3. Confirm `git status --short --branch` is clean and local `main` matches `origin/main`.

## Final report
Report:
- packages audited and deployed,
- versions published to npm,
- commits and tags pushed,
- validation commands/results,
- refresh/verify result,
- final git status.
