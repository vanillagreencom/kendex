# Lane details

The lane table and the scope rules are [SKILL.md](../SKILL.md) § Lanes. This
file holds what does not fit a table cell: how the diff is taken, the
`unwired-suite` wiring grammar, and why `applied-migration-edited` ships the
default glob set it does.

## What a lane may read

CONTENT decides which lines a lane may read, never an attribute. The diff is
taken with `--text`, so a `.gitattributes` `-diff` or `binary` row cannot
withhold the lines a change adds, and a file whose own bytes are binary
contributes no lines in any scope.

The default and `--base` scopes include every non-ignored untracked file as a
new file; `--staged` sees only the index.

## `unwired-suite` wiring grammar

Runners are `.github/workflows/*.yml`, `tools/validate*`, `scripts/validate*`,
`package.json`, `Makefile`, `justfile`, and any `run-all.sh`.

Wiring is the suite named outright, a path-shaped glob its path satisfies, a
directory it lives under, a manifest below the repo root whose subtree holds
it, a runner beside it globbing its own directory, or a runner invoking bare
`vitest`/`jest` at a command position whose default include glob covers the
suite (`*.test.ts`/`js`/`mjs`) under the directory the runner runs from.

A command position means directly, chained after `;`/`&`/`|`, behind a
directly preceding `npx`/`pnpm`/`yarn`/`exec`/`dlx`, with `NAME=value`
assignment words (values plain or quoted) allowed before the runner word.

A comment (full-line or trailing), dependency key, or package path is not an
invocation, and neither is a prose mention, except a colon-opened value
beginning with the runner word, accepted erring quiet. A path-prefixed binary
(`node_modules/.bin/vitest`) is not recognized, and a pinned explicit
`include`/`testMatch` is not evaluated. An empty or unreadable runner set
leaves the lane quiet.

## `applied-migration-edited` glob set

refinery and Flyway record a checksum over a versioned migration's name and
text and refuse to run against a database whose recorded checksum moved.

`PREFLIGHT_MIGRATION_GLOBS` replaces the set, default
`**/migrations/V*__*.sql` and `**/db/migration/V*__*.sql`, which is those two
runners' filename shape under the two directory names they use, Flyway's own
being the singular one, and nothing else: a runner recording an applied
version without a checksum (golang-migrate, Goose, Alembic, Django) reopens
its database after an edit, so naming its files would hard-fail a legitimate
change. Every other layout is opt-in, sqlx and Flyway repeatable migrations
(`R__*`) included.

A leading `**/` matches at any depth and is the only depth crossing, so a `*`
never reaches past its own path component.

Not the shape: a migration added at a new version, one this branch added and
then corrected (the staged scope diffs against HEAD and is qualified against
the base for exactly that), and a mode change, which moves no text. `--all`
reads every tracked line as added and a repository with no base to read
answers nothing, so both stay quiet, as does an empty value.
