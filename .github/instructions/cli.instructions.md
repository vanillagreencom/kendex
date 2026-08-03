---
applyTo: "cli/**"
---

Rust workspace; repo convention runs `cargo test` and `cargo clippy`. Code
that writes `vstack.toml` or `vstack.settings.toml` must never reformat
content inside TOML string values — flag any line-oriented pass over TOML
text that is not string-state-aware; this has corrupted user config before.
