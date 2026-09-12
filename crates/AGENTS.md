# crates/

The Rust workspace: `core` holds the domain, `cli` and `app` are thin shells over it, and each has its own `AGENTS.md`. `test_util.rs` is the test module every crate's test binaries include by path.

- A test that runs the kendex binary hands it a fixture home: `fixture_env()` from `test_util.rs`, or a `HOME` with `KENDEX_REAL_HOME=1` on the next line. A debug build otherwise runs in the dev sandbox and a release build on the real machine. Two `tools/guard` lanes check it, per file naming the binary and per `HOME` set; `cli/tests/dev_sandbox.rs` proves the sandbox.
