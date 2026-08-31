# Developing kendex

Working on kendex itself. To install and use it, start from the
[README](../README.md).

## Build from source

Rust, Node, and git 2.41 or newer required — kendex materializes a
catalog with `git --attr-source`, which no earlier git takes.

```sh
cargo build --release -p kendex-cli               # the `kendex` CLI
npm ci --prefix ui
cd crates/app && ../../ui/node_modules/.bin/tauri dev   # the desktop app
```

## Where a debug build writes

A debug build keeps its own home under the platform data directory
(`kendex-dev`) instead of yours, so a branch cannot leave records your
installed kendex will not read. Your global skills and agents are not
visible to it, and nothing it writes reaches them.

The boundary is the home, not the whole machine. Three things stay outside
it: a repository you point a debug build at is the real one, so
`--scope project` reads and writes it as usual; a harness folder you set to
an explicit absolute path is used as written; and programs kendex runs for
you, `npm` among them, still see your real home. To dogfood a build against
your real setup, say so:

```sh
KENDEX_REAL_HOME=1 cargo run -p kendex-cli --bin kendex -- list
```

Only `1` opts out — the hatch permits writes to a real machine, so a value
nobody could read as consent leaves the sandbox on.
