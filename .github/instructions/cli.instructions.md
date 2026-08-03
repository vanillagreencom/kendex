---
applyTo: "cli/**"
---

Rust workspace; repo convention runs `cargo test` and `cargo clippy`. Code
that writes `vstack.toml` or `vstack.settings.toml` must never reformat
content inside TOML string values — flag any line-oriented pass over TOML
text that is not string-state-aware; this has corrupted user config before.
Inline `#[cfg(test)]` modules deliberately use the OS tempdir
(`std::env::temp_dir`) with cleanup — the repo's `<worktree>/tmp/` rule
governs agent working artifacts, not test-runtime fixtures; do not flag
OS-tempdir use inside test code.
