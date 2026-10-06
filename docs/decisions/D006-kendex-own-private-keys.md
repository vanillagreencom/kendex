# D006: kendex's own private keys show on every package page with settings, under kendex's name

[← Decision Index](INDEX.md)

**Date**: 2026-09-26

**Status**: Active

**Research**: KEN-1841

**Decision**: kendex declares its own private keys, `KENDEX_USER_EMAIL` first, in a `[secrets]` template of its own, read by the same strict reader as a package template, `crates/core/src/settings_secret.rs`. Every package page whose template reads shows those keys after the package's own credentials, except a key the package declares too, which shows once as the package's. Each secret row carries its owner, and the app writes the edit under that owner.

**Why**: The Customize tab has no page of kendex's own, so a key no package declares had no page to appear on and no name to be written under. The key is written once to one file, so showing it on several pages shows one answer several times.

**Rejected**: A package declaring the key itself: that package would own an identity every package shares. A page of kendex's own: a new place in the app for one field, when the package pages already carry the private-file destination picker it needs.

**Revisit when**: kendex declares a second private key, a package page shows kendex keys a person reports as noise, or the app gains a project-wide settings page.
