# Lane details

What each lane fails on, its exclusions, the settings and the exit codes are in `preflight --help`. This file holds the grammars that do not fit a help entry: how the diff is taken, how `unwired-suite` reads a runner, and which globs `data-syntax` and `applied-migration-edited` ship.

## Diff construction

Content decides which lines a lane may read, never an attribute. The diff is taken with `--text`, so a `.gitattributes` `-diff` or `binary` row cannot withhold the lines a change adds. A file whose own bytes are binary contributes no lines in any scope.

The default and `--base` scopes include every non-ignored untracked file as a new file. `--staged` sees only the index, and reads shared settings from the index too, so a new untracked settings file cannot change the commit verdict. The personal `.env.local` file stays a runtime input in every scope.

## `unwired-suite` wiring grammar

Runners are `.github/workflows/*.yml`, `tools/validate*`, `scripts/validate*`, `package.json`, `Makefile`, `justfile`, and any `run-all.sh`.

Wiring is the suite named outright, a path-shaped glob its path satisfies, a directory it lives under, a manifest below the repo root whose subtree holds it, a runner beside it globbing its own directory, or a runner invoking bare `vitest`/`jest` at a command position whose default include glob covers the suite (`*.test.ts`/`js`/`mjs`) under the directory the runner runs from.

A command position means directly, chained after `;`/`&`/`|`, behind a directly preceding `npx`/`pnpm`/`yarn`/`exec`/`dlx`, with `NAME=value` assignment words (values plain or quoted) allowed before the runner word.

A comment (full-line or trailing), dependency key, or package path is not an invocation, and neither is a prose mention, except a colon-opened value beginning with the runner word, accepted erring quiet. A path-prefixed binary (`node_modules/.bin/vitest`) is not recognized, and a pinned explicit `include`/`testMatch` is not evaluated.

## Glob semantics

A leading `**/` matches at any depth and is the only depth crossing, so a `*` never reaches past its own path component. Both glob settings replace their shipped set rather than adding to it, and an empty value leaves the lane quiet.

## `data-syntax` JSONC paths

The `.jsonc` suffix declares JSON with comments. Some producers keep `.json` instead, and `PREFLIGHT_JSONC_GLOBS` names those paths. The shipped set is `**/tsconfig*.json`, `**/jsconfig*.json`, `**/.vscode/*.json`, `**/.devcontainer/*.json` and `**/*-color-theme.json`, which is VS Code's convention plus the two TypeScript manifests.

The lane has no JSONC parser and leaves these files to the producer that declares the dialect.

## `applied-migration-edited` glob set

refinery and Flyway record a checksum over a versioned migration's name and text, and refuse to run against a database whose recorded checksum moved.

The shipped set is `**/migrations/V*__*.sql` and `**/db/migration/V*__*.sql`: those two runners' filename shape under the two directory names they use, Flyway's own being the singular one, and nothing else. A runner that records an applied version without a checksum (golang-migrate, Goose, Alembic, Django) reopens its database after an edit, so naming its files would hard-fail a legitimate change. Every other layout is opt-in through `PREFLIGHT_MIGRATION_GLOBS`, sqlx and Flyway repeatable migrations (`R__*`) included.

A migration this branch added and then corrected is not the shape: the staged scope diffs against HEAD and qualifies each hit against the base for exactly that.
