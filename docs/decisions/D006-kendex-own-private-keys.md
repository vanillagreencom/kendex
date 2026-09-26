# D006: kendex's own private keys show on every package page with settings, under kendex's name

[← Decision Index](INDEX.md)

**Date**: 2026-09-26

**Status**: Active

**Research**: —

**Context**: KEN-1841 makes `KENDEX_USER_EMAIL` a private key kendex declares itself, not a package's. The Customize tab has no page of kendex's own: every settings and secrets field sits on an installed package's page, and a secret edit is checked against the declaration of the package it names. A key no package declares had no page to appear on and no name to be written under.

**Decision**: kendex declares its own private keys in a `[secrets]` template of its own, read by the same strict reader as a package template (`crates/core/src/settings_secret.rs::own_declared`). The declaration joins every package's in `settings_secret::declared` and seeds the secret side of `settings_secret::contested`. Every package page whose template reads shows those keys after the package's own credentials (`crates/core/src/settings_view.rs::template_of`), except a key the package declares too, which shows once as the package's. Each `SecretRow` carries its `owner`, and the app's field writes the edit under that owner, not under the page's package.

**Rationale**:

- The key is written once to one file, and the app already keys a pending edit by key name alone (`ui/src/lib/secret-rows.ts::secretEditIn`), so showing it on several pages shows one answer several times, not several answers.
- A package declaring the key itself would make that package the owner of an identity every package shares, and would need a second copy of its explainer in each template that reads it.
- A page of kendex's own is a new place in the app for one field; the package pages already carry the private-file destination picker the field needs.
- Carrying the owner on the row keeps one check at the write (`settings_secret::apply_edits`) instead of a second rule for which names may write which keys.

**Revisit When**: kendex declares a second private key, a package page shows kendex keys a person reports as noise, or the app gains a project-wide settings page.

**Verification**: `cargo test -p kendex-core --lib settings_` (`kendex_own_keys_follow_the_package_s_own_credentials`, `kendex_own_key_is_written_under_kendex_and_no_other_name`, `a_package_declaring_a_kendex_key_under_the_other_table_contests_it`) and `ui/src/components/customize/secret-field-row.test.tsx` (`hands up a value for a key kendex declares under kendex's name`).

**References**: KEN-1841.
