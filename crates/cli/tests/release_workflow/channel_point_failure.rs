//! What `tools/release-channel-point` leaves behind when the one call that
//! changes the channel fails, and what the run after it does with that.
//! `gh release upload --clobber` deletes an asset before uploading its
//! replacement and uploads in parallel, so a failure can leave anything from
//! the whole set to nothing at all, and the run that failed does not read
//! back which. Each state below is driven out of that one branch, and each is
//! answered by the next run rather than by the failure.
//!
//! The guard's reads and its verdict are `channel_point.rs`, whose fixture
//! these run against.

#[cfg(unix)]
use crate::channel::channel_step_env;
#[cfg(unix)]
use crate::channel_point::{Channel, Fixture, STAGED};

/// The upload is the one call that changes the channel, and the branch that
/// catches it failing has to fail the job. A guard that printed its error and
/// then exited 0 would let the release workflow's channel job go green with
/// the channel short a manifest, which every candidate machine reads as no
/// update at all.
///
/// What it says is what this run knows: the upload failed, and the channel
/// carries some mixture of what was there and what landed. It names no
/// post-failure state, because it does not read one — the three tests below
/// drive three different states out of the same branch.
#[cfg(unix)]
#[test]
fn a_failed_upload_fails_the_job_and_defers_to_the_next_run() {
    let run = Fixture::new(Channel::Carrying("1.0.0-rc1"), &STAGED).run(
        "1.0.0-rc2",
        &["dist/latest.json"],
        &["latest.json", "feed.json"],
    );
    assert_ne!(
        run.code, 0,
        "a failed upload was survivable: {:?}",
        run.calls
    );
    // The fixture reached the upload rather than stopping at an earlier read,
    // so it is that branch this exercises and not one above it.
    assert!(
        run.ran("release upload").is_some(),
        "the run never got as far as the upload: {:?}",
        run.calls
    );
    // Named off the workflow, like every other channel-named claim here.
    let channel = channel_step_env("CHANNEL");
    for said in [
        format!("Uploading to the {channel} channel failed"),
        "which this run does not read back".to_owned(),
        "Re-run the tag: that run reads the channel".to_owned(),
    ] {
        assert!(run.output.contains(&said), "{said} missing: {}", run.output);
    }
}

/// One state that branch can leave: the channel kept its latest.json, so the
/// re-run reads a version off it, takes it, and publishes the whole staged
/// set. Both runs are against the one channel, so the second reads what the
/// first actually left rather than a pose of it.
#[cfg(unix)]
#[test]
fn a_failed_upload_that_kept_latest_json_is_written_by_the_re_run() {
    let channel = Fixture::new(Channel::Carrying("1.0.0-rc1"), &STAGED);
    let failed = channel.run(
        "1.0.0-rc2",
        &["dist/latest.json"],
        &["latest.json", "feed.json"],
    );
    assert_ne!(
        failed.code, 0,
        "a failed upload was survivable: {:?}",
        failed.calls
    );
    assert_eq!(
        failed.after,
        Some(vec!["feed.json".to_owned(), "latest.json".to_owned()]),
        "the fixture did not keep latest.json, so this proves nothing: {:?}",
        failed.calls
    );

    let again = channel.run("1.0.0-rc2", &[], &[]);
    assert_eq!(again.code, 0, "the re-run refused: {}", again.output);
    let mut whole: Vec<String> = STAGED.iter().map(|name| (*name).to_owned()).collect();
    whole.sort();
    assert_eq!(
        again.after,
        Some(whole),
        "the re-run did not publish the whole set: {:?}",
        again.calls
    );
}

/// A second state: the upload fell over after `--clobber` deleted
/// latest.json, so the channel carries assets nothing can read a version off
/// and every later run refuses it. The tag re-run publishes nothing, and the
/// message that sent the operator at it is the one that says so.
///
/// The two messages are asserted against each other here, because nothing
/// checking them together is how the failure's claim about the next run
/// outran the refusals twice. What is checked is the claim as the WEAKEST
/// refusal can keep it: that the run refuses and says what it found. Four
/// refusals can follow this failure and they differ — two of them fail
/// because a read failed, so an asset list is not something they could ever
/// give. `a_read_it_could_not_make_stops_the_write` drives those three; the
/// asset names below are this one branch's own, not what the failure
/// promises.
#[cfg(unix)]
#[test]
fn a_failed_upload_that_lost_latest_json_refuses_every_later_run() {
    let channel = Fixture::new(Channel::Carrying("1.0.0-rc1"), &STAGED);
    let failed = channel.run("1.0.0-rc2", &["dist/latest.json"], &["feed.json"]);
    assert_ne!(
        failed.code, 0,
        "a failed upload was survivable: {:?}",
        failed.calls
    );
    assert_eq!(
        failed.after,
        Some(vec!["feed.json".to_owned()]),
        "the fixture did not lose latest.json, so this proves nothing: {:?}",
        failed.calls
    );
    assert!(
        failed
            .output
            .contains("either writes it or refuses, saying what it found"),
        "{}",
        failed.output
    );

    // The re-run the message sends them on, with nothing failing.
    let again = channel.run("1.0.0-rc2", &[], &[]);
    assert_ne!(
        again.code, 0,
        "the re-run wrote over a channel nothing can read: {:?}",
        again.calls
    );
    assert!(
        again.ran("release upload").is_none(),
        "the re-run published over the leftovers: {:?}",
        again.calls
    );
    // The claim kept, as every refusal has to keep it.
    assert!(
        again.output.contains("Nothing was written to the")
            && again.output.contains("no latest.json"),
        "the refusal did not say what it found: {}",
        again.output
    );
    // And what this branch can give beyond it, because the read above it
    // already held the names. Asserted apart from the claim, so a later
    // change here cannot be read as the failure promising it.
    assert!(
        again
            .output
            .contains("carries feed.json and no latest.json")
            && again.output.contains("have to come off"),
        "the branch that can name the leftovers did not: {}",
        again.output
    );
    assert_eq!(
        again.after,
        Some(vec!["feed.json".to_owned()]),
        "the re-run changed the channel it refused: {:?}",
        again.calls
    );
}

/// A third state, and the one that says why the failure must not name any of
/// them. `gh` deletes every colliding asset before it uploads, so a failure
/// that is the connection rather than one file lands nothing at all, and the
/// channel this run published carries nothing. That is not a channel anyone
/// has to clear: the next run reads it as one no write has landed on and
/// takes it.
#[cfg(unix)]
#[test]
fn a_failed_upload_that_landed_nothing_leaves_a_channel_the_next_run_takes() {
    let channel = Fixture::new(Channel::Absent, &STAGED);
    let failed = channel.run("1.0.0-rc5", &["dist/latest.json"], &[]);
    assert_ne!(
        failed.code, 0,
        "a failed upload was survivable: {:?}",
        failed.calls
    );
    assert!(
        failed.ran("release create").is_some(),
        "the fixture did not reach the create: {:?}",
        failed.calls
    );
    assert_eq!(
        failed.after,
        Some(Vec::new()),
        "the fixture left assets, so this proves nothing: {:?}",
        failed.calls
    );
    // The one thing about the channel this run does know, because it is what
    // this run did rather than what the failure left.
    assert!(
        failed
            .output
            .contains("This run is what published that channel"),
        "{}",
        failed.output
    );

    let again = channel.run("1.0.0-rc5", &[], &[]);
    assert_eq!(again.code, 0, "the re-run refused: {}", again.output);
    assert!(
        again.ran("release upload").is_some(),
        "the re-run published nothing: {:?}",
        again.calls
    );
}

/// What an emptied channel allows, pinned rather than described. The
/// forward-only rule reads the version off the channel, and a channel
/// carrying nothing has none, so the run after a failure that landed nothing
/// takes any tag — an older one included. Both shells refuse a downgrade, so
/// candidates stall on a channel behind them rather than install an older
/// build, which is why this is pinned here and not repaired.
#[cfg(unix)]
#[test]
fn an_emptied_channel_takes_an_older_tag() {
    let channel = Fixture::new(Channel::Carrying("1.0.0-rc9"), &STAGED);
    let failed = channel.run("1.0.0-rc9", &["dist/latest.json"], &[]);
    assert_ne!(
        failed.code, 0,
        "a failed upload was survivable: {:?}",
        failed.calls
    );
    assert_eq!(
        failed.after,
        Some(Vec::new()),
        "the fixture did not empty the channel: {:?}",
        failed.calls
    );

    let older = channel.run("1.0.0-rc2", &[], &[]);
    assert_eq!(
        older.code, 0,
        "an emptied channel refused an older tag, so this pin is stale: {}",
        older.output
    );
    assert!(
        older.ran("release upload").is_some(),
        "an emptied channel refused an older tag, so this pin is stale: {:?}",
        older.calls
    );
}
