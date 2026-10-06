# Nothing installs unless the signed digest names it

Read before changing the release feed, signing, digests or self-replace.

## The approach

Both shells read one public release feed and replace themselves from it. Discovery is unsigned: a feed and `latest.json` can be served or altered. So each release carries a per-target digest document signed under the one pinned key, binding each download to its release, target, source commit and build number, and an update installs nothing whose identity or hash that document does not name. The release procedure is the app-deploy skill, `.agents/skills/app-deploy/SKILL.md`.

## Why

An attacker who can serve the feed could offer a genuine older download, or another platform's, and a signature on the download alone would verify it. The digest document is what ties the download to the release the feed claimed.

## Rules

- Do verify every download against the digest document at `crates/core/src/release_digests.rs`; a genuinely signed document for another release or target is refused, as is one the key does not cover.
- Do fail a release lane that produced no signature rather than publish a command no client can verify.
- Do pin one updater key in two places that rotate together, `crates/app/tauri.conf.json` and `crates/core/src/update_feed.rs`, held equal by `crates/app/tests/tauri_config.rs`.
- Do replace a command only where its path is writable and outside a system prefix; a package-manager prefix names its package, asked of pacman, dpkg or rpm, and the card says which.
- Do keep release-only bundle settings in the overlays under `crates/app/release/`, never in `tauri.conf.json`, which tauri-build reads at compile time.
- Do let `inside_the_app` in `crates/core/src/install_channel.rs` be the one judge of a command an installer put inside the desktop app: it is the app's to update, and no verb records it as the installed command.
- Never let a release build honour `KENDEX_UPDATE_FEED`; a debug build alone does.
- Never move the channel pointer backwards: `tools/release-channel-point` authenticates the current and candidate documents and changes the pointer only to a newer build.

## The canonical example

`crates/core/src/release_digests.rs` with the test `update_over_a_local_feed_refuses_a_command_it_cannot_verify` in `crates/cli/tests/compat.rs`: a feed served from a local directory, a download the document does not name, and a refusal. A new download path starts there.

## Revisit when

The updater key has to rotate while clients pinned to the old key are still in use, or a release channel appears whose builds are not numbered in one sequence.

## Not governed

How a release is cut and published: the app-deploy skill. The package-manager recipes: `packaging/README.md`.
