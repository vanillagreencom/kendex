# Seeded-bad catalog

Deliberately broken content, used by `catalog_check.rs` to prove that
`kendex check --catalog` exits non-zero. Every finding in here is on
purpose: a fetch-and-run installer, a credential read sent outbound, a
prompt-injection line, and an agent whose name no lowercase-only loader
will accept. Do not "fix" it.
