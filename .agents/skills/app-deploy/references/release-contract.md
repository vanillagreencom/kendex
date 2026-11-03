# Release publication

Read when the release workflow evaluates publication or recovers an update channel.

## Artifacts and channels

`.github/workflows/release.yml` declares the downloadable assets and update manifests. `crates/core/src/update_feed.rs::ReleaseFeed` owns the feed shape and accepted schema. Use those declarations when checking a release; keep no second filename, target or field inventory here.

The command and app updates must have their signatures and signed digest documents. The release lane fails when a required signature is absent. `tools/release-digests` owns the digest document; `tools/release-installer-check` and `tools/release-installer-check.ps1` check the installers. The trust boundary is [docs/architecture/updates.md](../../../../docs/architecture/updates.md). Every `install.sh` run relies on TLS to kendex.ai and github.com without verifying asset signatures. `kendex update` verifies against the pinned release key.

A stable release remains a draft until the operator reviews and publishes it under [the release workflow](../workflows/release.md). A candidate publishes immediately. The release workflow dispatches candidate AUR publication on `main`; a release created with its job token does not start release-event workflows.

`crates/core/src/update_channel.rs` owns channel selection and discovery URLs. A candidate build follows the candidate channel. A stable build receives no candidate offer. A main build follows the main channel after an explicit `--git` installation or update. Installing a candidate or main build keeps that channel until the person changes it.

Each channel pointer names downloads on an immutable build release. Resolve the pointer once per install so that downloads cannot come from different builds. `tools/release-channel-point` keeps the pointer moving forward: candidate versions increase, and main build numbers increase after signed identity verification. An older candidate or main build leaves the pointer alone. The release workflow keeps a main run together through all targets and publication; a newer push can replace only a wholly pending run.

If a candidate channel update was missed, rerun the newest candidate release's channel job. If the main channel release exists without its `feed.json`, delete that empty release and rerun the newest main workflow. Check the release is empty first: the publisher creates a channel only when the release is absent and refuses an existing release whose assets are not exactly the pointer. A failed asset read does not establish an empty release.
