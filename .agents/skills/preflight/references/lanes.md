# Lane details

Read when setting a `PREFLIGHT_*_GLOBS` value, or when a finding turns on how the diff is taken or how `unwired-suite` reads a runner.

## Diff construction

preflight takes the diff with `--text`, so a `.gitattributes` `-diff` or `binary` row does not withhold the lines a change adds.

`--staged` reads the shared settings files from the index, so a new untracked settings file does not change the commit verdict. The personal `.env.local` file stays a runtime input in every scope.

## `unwired-suite` wiring grammar

Runners are `.github/workflows/*.yml`, `tools/validate*`, `scripts/validate*`, `package.json`, `Makefile`, `justfile`, and any `run-all.sh`. preflight collects them from tracked and untracked paths alike. An untracked runner is in scope exactly when an untracked suite is, so a workflow added beside its suite wires it before either is committed.

A runner wires a suite in any of these ways:

- It names the suite outright.
- It names a path-shaped glob the suite's path satisfies.
- It names a directory the suite lives under.
- It is a manifest below the repo root whose subtree holds the suite.
- It sits beside the suite and globs its own directory.
- It invokes `vitest`, `jest` or `bun test` over the whole of that runner's default include. That include covers `*.test.ts`, `*.test.js` and `*.test.mjs` under the directory the runner runs from.

The rules from here to the end of this section apply only to the sixth form, the `vitest`, `jest` or `bun test` invocation. preflight reads that invocation by tokenizing the runner line.

Only a field that carries a command is read as one:

- A shell runner (`Makefile`, `justfile`, `tools/validate*`, `run-all.sh`) is commands throughout.
- A workflow carries commands in a `run:` value and in the block scalar a `run: |` opens, and nowhere else. A step's `name: bun test` is text.
- A manifest carries commands in a value inside its `scripts` object. A `description` or a dependency key is text.
- Everything else is read and dropped unjudged.

A command splits at an unquoted `;`, `&`, `|`, backtick or parenthesis.

A command position is the start of a command, past any leading `NAME=value` assignment words and any `npx`, `pnpm`, `yarn`, `exec` or `dlx`:

- `bun` counts only when `test` follows it. `bun run test` does not count.
- `vitest` may be followed by `run` or `watch`.
- `jest` takes no subcommand, so every word after it is a path pattern.

Every remaining word must be a flag. A word that is not a flag is a positional path or filter that restricts the run to part of the tree. preflight then records no default include, and the path token that word writes decides whether the suite is wired. `vitest run src/`, `jest tests/`, `bun test src/` and `bun test 'src/'` are all read that way. A flag's detached value is such a word too: `bun test --timeout 5000` records nothing, where `bun test --timeout=5000` records the default include.

These are not invocations:

- A comment, full-line or trailing.
- A dependency key or a package path.
- A prose mention, whose following words are positionals.
- A path-prefixed binary, such as `node_modules/.bin/vitest`.

preflight does not evaluate a pinned explicit `include` or `testMatch`.

## Glob semantics

A glob setting's value lists its globs separated by spaces. A leading `**/` matches at any depth and is the only depth crossing, so a `*` never reaches past its own path component. Every glob setting reads this grammar.

## `data-syntax` JSONC paths

`JSONC_GLOBS` in `scripts/preflight` declares the shipped set of `PREFLIGHT_JSONC_GLOBS`.

## Sourced-library trees

`PREFLIGHT_SOURCED_LIB_GLOBS` names directories, not files. A path is in a sourced-library tree when one of its parent directories matches a glob, so the glob covers the tree's whole depth.

`SOURCED_LIB_GLOBS` in `scripts/preflight` declares the shipped set. A project that keeps its libraries elsewhere, such as `tools/sh`, lists that directory. That project also retains any shipped trees it still needs.

For a non-executable file in these trees:

- `fail-open` omits the strict-mode preamble check.
- `shellcheck-errors` omits SC2168. Other ShellCheck errors still fail.

Executable files keep both checks. Staged scope reads the executable bit from the index.

## `applied-migration-edited` glob set

`MIGRATION_GLOBS` in `scripts/preflight` declares the shipped set. refinery and Flyway record a checksum over a versioned migration's name and text, and refuse to run against a database whose recorded checksum moved.

A runner that records an applied version without a checksum (golang-migrate, Goose, Alembic, Django) reopens its database after an edit, so naming its files would hard-fail a legitimate change.

Every other layout is opt-in, sqlx and Flyway repeatable migrations (`R__*`) included.
