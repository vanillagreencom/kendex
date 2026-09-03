# Release feed and self-update

Covers: crates/core/src/app_update.rs, crates/core/src/update_feed/, crates/core/src/release_digests.rs, crates/core/src/install_channel.rs, crates/core/src/update_channel.rs, crates/core/src/command_update.rs, tools/release-digests, tools/release-channel-point

Both shells read one public release feed and replace themselves from it. What the release workflow publishes and how a release is cut is [../RELEASING.md](../RELEASING.md).

## Boundaries

- Discovery is unsigned; one pinned key covers a per-target document binding each download to its release and target. A signature over a download proves the bytes and nothing else, so `digests-<target>.json` is signed under the release key and an update installs nothing whose hash it does not name. Enforced by the tests in `crates/core/src/release_digests/tests.rs` and `crates/cli/tests/compat.rs::update_over_a_local_feed_refuses_a_command_it_cannot_verify`.
- The app and the CLI pin one updater key and ship one version. Enforced by `crates/app/tests/tauri_config.rs::the_app_and_the_cli_pin_one_updater_key` and `::the_app_and_the_cli_ship_one_version`.

## Invariants

1. Off the launch path, one check at a time machine-wide reads the feed six-hourly at most, keeps the last document, follows no final link, and nothing gates on it. Enforced by `crates/core/tests/app_update.rs::one_attempt_is_reused_for_six_hours`.
2. A reply that is not a feed leaves the last valid notice standing; a rollback clears the notice; a symlinked cache entry is replaced without touching its target. Enforced by `crates/core/tests/app_update.rs`.
3. A genuinely signed document for another release or target is refused, as is a document the release key does not cover or one larger than a document can be. Enforced by `crates/core/src/release_digests/tests.rs`.
4. Replacing needs the running path writable and outside a system prefix; a package-manager prefix names its command and the card says which. Either shell carries its own command, marker last. Enforced by `crates/cli/tests/compat.rs::a_desktop_app_that_cannot_be_replaced_leaves_the_command_alone` and the tests in `crates/core/src/install_channel/`.
5. Only a debug build honours `KENDEX_UPDATE_FEED`; the release build reads the channel compiled in (`crates/core/src/update_channel.rs`). Not mechanically enforced.

## Decisions

- The digest document exists because nothing signs the feed or `latest.json`; a feed that can be served or altered could otherwise offer a genuine older download, or another platform's, and it would verify.
- A lane that produced no signature fails the tag rather than publishing a command no client can verify.
