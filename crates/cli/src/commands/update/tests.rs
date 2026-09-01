use std::path::PathBuf;

use kendex_core::command_update::staged_path;

use super::*;

#[path = "../../../../fixture_url.rs"]
mod fixture_url;
use fixture_url::file_url;

#[path = "../../../../test_util.rs"]
mod test_util;
use test_util::no_record_on_this_runner;

/// The one skew this order can still leave is an app already across
/// and a command that would not move. It is not a dead end — the
/// command's version is unchanged, so the next run reads newer and
/// repeats both halves — and the message has to say so rather than
/// leave a bare io error to be read as total failure.
#[test]
fn a_command_that_would_not_move_says_whether_the_app_went_without_it() {
    let error = "permission denied";
    let split = command_failure("5.1.0", true, error);
    assert!(split.contains("the desktop app is on 5.1.0"), "{split}");
    assert!(split.contains("run kendex update again"), "{split}");

    let neither = command_failure("5.1.0", false, error);
    assert!(!neither.contains("desktop app"), "{neither}");
}

/// One machine, one release waiting, one command on disk: everything a
/// run needs except who owns the bytes. What each arm did to that
/// command is then the whole difference between them.
fn a_release_is_out(dir: &tempfile::TempDir) -> (Env, String, PathBuf) {
    a_release_is_out_under(dir.path())
}

fn a_release_is_out_under(home: &Path) -> (Env, String, PathBuf) {
    std::fs::create_dir_all(home).unwrap();
    let installed = home.join("kendex");
    std::fs::write(&installed, INSTALLED).unwrap();
    std::fs::write(home.join("new-command"), OFFERED).unwrap();
    std::fs::write(home.join("new-command.sig"), TEST_SIGNATURE).unwrap();
    // Every release publishes what it built for this target beside its
    // feed, so the fixture does too; the tests that alter this document
    // are the ones that say what happens when it is not this release's.
    publishes(home, PUBLISHED_DIGESTS, PUBLISHED_DIGESTS_SIGNATURE);
    std::fs::write(
        home.join("feed.json"),
        format!(
            r#"{{"schema": 1, "version": "9.9.9", "assets": {{"{TEST_TARGET}": {}}}}}"#,
            serde_json::to_string(&file_url(&home.join("new-command"))).unwrap()
        ),
    )
    .unwrap();
    (
        Env::host_rooted(home),
        file_url(&home.join("feed.json")),
        installed,
    )
}

/// Put a digests document and its signature where this target's update
/// looks for them, which is beside the feed and under this target's name.
fn publishes(home: &Path, document: &str, signature: &str) {
    let name = format!("digests-{TEST_TARGET}.json");
    std::fs::write(home.join(&name), document).unwrap();
    std::fs::write(home.join(format!("{name}.sig")), signature).unwrap();
}

const INSTALLED: &[u8] = b"the command already here";
/// What the feed offers is the signed blob below, because a release only
/// offers a command `TEST_SIGNATURE` covers and `PUBLISHED_DIGESTS` names;
/// nothing else gets written.
const OFFERED: &[u8] = SIGNED_BYTES;

/// Run the direct-install path used by the refusal cases below.
fn direct(env: &Env, feed_url: &str, installed: &Path) -> CliResult {
    run_on(
        env,
        false,
        feed_url,
        installed,
        &InstallChannel::Direct,
        TEST_KEY,
        TEST_TARGET,
    )
}

/// The defect this binding exists for: a binary the release key really
/// signed, offered by a feed for a release it does not belong to. The
/// signature checks out — it is a genuine one over exactly these bytes —
/// and the download is still refused, because this release published a
/// different hash for its command.
#[test]
fn a_signed_binary_from_another_release_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let (env, feed_url, installed) = a_release_is_out(&dir);
    std::fs::write(dir.path().join("new-command"), ANOTHER_RELEASE).unwrap();
    std::fs::write(
        dir.path().join("new-command.sig"),
        ANOTHER_RELEASE_SIGNATURE,
    )
    .unwrap();

    let refused = direct(&env, &feed_url, &installed).unwrap_err().to_string();

    assert!(
        refused.contains("the kendex command hashes to"),
        "{refused}"
    );
    assert_eq!(std::fs::read(&installed).unwrap(), INSTALLED);
    assert!(!staged_path(&installed).exists());
}

/// The two ways a feed can point this target at a release that is not the
/// one it claims: serve another platform's digests, or an earlier
/// release's. Both documents are genuinely signed — nothing here can forge
/// one — so what refuses them is the release and target they name.
#[test]
fn digests_for_another_target_or_another_release_are_refused() {
    for (document, signature, why) in [
        (
            OTHER_TARGET_DIGESTS,
            OTHER_TARGET_DIGESTS_SIGNATURE,
            "aarch64-apple-darwin",
        ),
        (OLDER_DIGESTS, OLDER_DIGESTS_SIGNATURE, "5.0.0"),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let (env, feed_url, installed) = a_release_is_out(&dir);
        publishes(dir.path(), document, signature);

        let refused = direct(&env, &feed_url, &installed).unwrap_err().to_string();

        assert!(refused.contains(why), "{refused}");
        assert_eq!(std::fs::read(&installed).unwrap(), INSTALLED, "{why}");
        assert!(!staged_path(&installed).exists(), "{why}");
    }
}

/// An update finds the release's statement or installs nothing: a channel
/// serving no document, or one nothing signed, leaves the command alone
/// rather than falling back on the signature by itself.
#[test]
fn a_release_that_publishes_no_verifiable_digests_installs_nothing() {
    for missing in [true, false] {
        let dir = tempfile::tempdir().unwrap();
        let (env, feed_url, installed) = a_release_is_out(&dir);
        let name = format!("digests-{TEST_TARGET}.json");
        match missing {
            true => std::fs::remove_file(dir.path().join(&name)).unwrap(),
            false => {
                std::fs::write(dir.path().join(format!("{name}.sig")), "not a signature").unwrap()
            }
        }

        assert!(direct(&env, &feed_url, &installed).is_err(), "{missing}");
        assert_eq!(std::fs::read(&installed).unwrap(), INSTALLED, "{missing}");
        assert!(!staged_path(&installed).exists(), "{missing}");
    }
}

/// A throwaway minisign keypair signing every blob and document below, so
/// the admitted arm runs the real check rather than a stub standing in for
/// it. One pair serves both halves: the app and the command are held to
/// one key. The target is named rather than read off this build, so the
/// documents are the same on every machine this test runs on.
const TEST_KEY: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IDc1RTYwNzZERUJFMDVFNTcKUldSWFh1RHJiUWZtZFdVSnJYQmd0QnhLVUdUQnN2MWNTR2N6SW9jZ1Z1Q0FoZmlzWDVIeFZJaUkK";
const TEST_TARGET: &str = "x86_64-unknown-linux-gnu";
const TEST_SIGNATURE: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9tIHRhdXJpIHNlY3JldCBrZXkKUlVSWFh1RHJiUWZtZFFaYlYyV1NhdUcwUWR6d1cxRWZGRXo4RzNuUjgrTStHOEhXMDlVSUpvM1p4eTEvdzBtZ2FqZnpxTFZYUGVZU2cyMEVRL29iV3RTZ1ZjQ09pVUFEM3dBPQp0cnVzdGVkIGNvbW1lbnQ6IHRpbWVzdGFtcDoxNzg4MDQyMjM0CWZpbGU6a2VuZGV4LXg4Nl82NC11bmtub3duLWxpbnV4LWdudQpROGN6cHBoVVd4RUNDWlZxTUpXSnhDd0JJUGNUalBsczhjMDJ5L0JOUzQ4d2g3OTNXemU1UHVXRTRmS3RLTS9HZ2pvbzR3eEVpM2ZUVTA4WXd4dGlCZz09Cg==";
const SIGNED_BYTES: &[u8] = b"kendex AppImage bytes";

/// The app download this release published, and the signature over it.
const SIGNED_IMAGE: &[u8] = b"the linux appimage";
const SIGNED_IMAGE_SIGNATURE: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9tIHRhdXJpIHNlY3JldCBrZXkKUlVSWFh1RHJiUWZtZFQ5UklsNVQ1ZjMvV25YVTBnSVJDcDBFVFF4R1RHZlFjbTZabTA4WFhuQklYN0VpSDhnTXJObFBkQnVEdlpQczVVc3J4bVhaZEVWZGg2d2ZFUTlkQlFrPQp0cnVzdGVkIGNvbW1lbnQ6IHRpbWVzdGFtcDoxNzg4MDQyNjUzCWZpbGU6a2VuZGV4XzkuOS45X2FtZDY0LkFwcEltYWdlCnA0RW9QUFFrYTR1WFNwQlJmRUY2VldxTFBDV2tOb0NHeDN6TGI2R0J1K2pacm1Qa3JnbndpeW9kMjBWTDFSZ2M0cHFqM2R2QlNkRmpZRGkwdmZOOEFBPT0K";

/// A binary the release key really signed, published by a release this
/// one is not.
const ANOTHER_RELEASE: &[u8] = b"an older kendex, signed when it shipped";
const ANOTHER_RELEASE_SIGNATURE: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9tIHRhdXJpIHNlY3JldCBrZXkKUlVSWFh1RHJiUWZtZGVPc2R4SXlPL1pMT0xsb3VZbWxVUitUeEJ0RVdFeFlYNklSK25UWXp6eW1xc1orMXhhZlp1VEpFNXl6ZTAxNFdSVUhHSEdZRy92UkRuYUowQ3pqREE4PQp0cnVzdGVkIGNvbW1lbnQ6IHRpbWVzdGFtcDoxNzg4MDQyMjM0CWZpbGU6b3RoZXItcmVsZWFzZS1iaW5hcnkKRGo3KzA1eXdMWVN4TzN5OFhQQU9mbFQrUzFoNzA4NkdJU3RNTzZqaGZLNXhqQmp4aHNzRDZGT2ZBc05ZdlhqbHZOVFdoZTYvWHJXRFo5ZTVyVzRYQWc9PQo=";

/// What `tools/release-digests` wrote for this release's Linux lane,
/// byte for byte, and the two documents a feed can serve in its place
/// that are equally genuine and are not this release's.
const PUBLISHED_DIGESTS: &str = r#"{
  "schema": 1,
  "version": "9.9.9",
  "target": "x86_64-unknown-linux-gnu",
  "command": "aae05017e20c96dd3cd26b1fd324365c2ab53512db82b53362e75f8f553ffaea",
  "app": "d489b792c3c3d6e9633ff28507f2c7da40a24eec743521842ebc283c2c3226ff"
}
"#;
const PUBLISHED_DIGESTS_SIGNATURE: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9tIHRhdXJpIHNlY3JldCBrZXkKUlVSWFh1RHJiUWZtZFpxNkg5WFpISHVZL2xIMWR6eWxZN3djZUU2NXpERjVNMjRUMUJlcXlnS1V5dUpDNGsySlpHZkRBUEhiOFN3dFRhVElPaWltajA3RTNpNVk3NndJcXdZPQp0cnVzdGVkIGNvbW1lbnQ6IHRpbWVzdGFtcDoxNzg4MDQyMjM0CWZpbGU6ZGlnZXN0cy14ODZfNjQtdW5rbm93bi1saW51eC1nbnUuanNvbgpzSkg3dGJuMXVNSHIyRkE5enlISnVSRWRNS0xXcWxFVEJ1TkRaSXFsR0ZzZm5LbCtqNThBckYzb1JQVE9UeEk5WExEMXpKYTlSZnl0S2xQUXZxTk9Bdz09Cg==";
const OTHER_TARGET_DIGESTS: &str = r#"{
  "schema": 1,
  "version": "9.9.9",
  "target": "aarch64-apple-darwin",
  "command": "ea1eb85cbb8a7c5b0ee438f4924e7825fece13173e9764c8308b1d95bbd7226a",
  "app": "a9c46ccd0a1b1a38b8e7bceb39644bd068f49fd58aeb185491be24326939d567"
}
"#;
const OTHER_TARGET_DIGESTS_SIGNATURE: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9tIHRhdXJpIHNlY3JldCBrZXkKUlVSWFh1RHJiUWZtZFF5S1FzZklvb203YVRMdVlqa2NNYm15alFnZVBPcFNvQmdRd3FWOFRFQUxxZENMRk1kOUJlQlcyTUJ4bDdPaWJ2UFZHbHYxcE5ubkRsRUNKR3RpL1FRPQp0cnVzdGVkIGNvbW1lbnQ6IHRpbWVzdGFtcDoxNzg4MDQyMjM0CWZpbGU6ZGlnZXN0cy1hYXJjaDY0LWFwcGxlLWRhcndpbi5qc29uCml0RG1oZWpkZW5iZHBmcERNMHZVNHh3eGFmVTNObHBOZVI5clJwOXFXd2pBQWZGMW9WU0ZkQ3Fici9ib2NhRnFVdzFjcW80NWVPWWJNOWdnNlF0NENBPT0K";
const OLDER_DIGESTS: &str = r#"{
  "schema": 1,
  "version": "5.0.0",
  "target": "x86_64-unknown-linux-gnu",
  "command": "aae05017e20c96dd3cd26b1fd324365c2ab53512db82b53362e75f8f553ffaea",
  "app": "42c30601103ba7015436bd2feed7b3867ab36ec71e3bece765400efe82a33a08"
}
"#;
const OLDER_DIGESTS_SIGNATURE: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9tIHRhdXJpIHNlY3JldCBrZXkKUlVSWFh1RHJiUWZtZFJQSzRNQ0I5Rnk3enVxSkhFb3htZXA0L295SS8ycUhHZnRyWVdjcy9uNTJHczE4M1Q4KzZLL0Vja2tTTFB4SVk4RXRneFRpYWszSTRDbTkyd0RrUEFrPQp0cnVzdGVkIGNvbW1lbnQ6IHRpbWVzdGFtcDoxNzg4MDQyMjM0CWZpbGU6ZGlnZXN0cy14ODZfNjQtdW5rbm93bi1saW51eC1nbnUuanNvbgpVbDlnc2FSQUdFMVY2VWI1Z3NpL3BmMVZ4bDBpTm4wZ05aUUkyaG9ldFByMGhtdGVZTVhpUnVFN0ZuQ01ob0lGR08rMlMrazA1L1luUXQwTjNzMUxDdz09Cg==";

/// The release's statement, read the way an update reads it.
fn published() -> ReleaseDigests {
    ReleaseDigests::for_release(
        TEST_KEY,
        PUBLISHED_DIGESTS.as_bytes(),
        PUBLISHED_DIGESTS_SIGNATURE.as_bytes(),
        "9.9.9",
        TEST_TARGET,
    )
    .unwrap()
}

/// A path with something already installed at it, so every arm can say
/// whether the bytes there moved.
fn installed_app(dir: &tempfile::TempDir) -> PathBuf {
    let path = dir.path().join("kendex.AppImage");
    std::fs::write(&path, b"the app already here").unwrap();
    path
}

/// The admitted arm: a signature that checks out over the download this
/// release published puts it in place and leaves no staged file behind.
#[test]
fn an_app_image_whose_signature_checks_out_is_written() {
    let dir = tempfile::tempdir().unwrap();
    let installed = installed_app(&dir);
    let digests = published();

    install_verified(
        &installed,
        SIGNED_IMAGE,
        SIGNED_IMAGE_SIGNATURE.as_bytes(),
        TEST_KEY,
        |bytes| digests.verify_app(bytes),
    )
    .unwrap();

    assert_eq!(std::fs::read(&installed).unwrap(), SIGNED_IMAGE);
    assert!(!staged_path(&installed).exists());
}

/// The refused arm, driven by all three shapes a bad download takes:
/// bytes the signature does not cover, a body that is no signature at
/// all, and bytes carrying a real signature that this release did not
/// publish for this half. Either way the installed app is exactly as it
/// was.
#[test]
fn an_app_image_that_fails_verification_is_never_written() {
    let dir = tempfile::tempdir().unwrap();
    let installed = installed_app(&dir);
    let digests = published();
    let install = |bytes: &[u8], signature: &[u8]| {
        install_verified(&installed, bytes, signature, TEST_KEY, |bytes| {
            digests.verify_app(bytes)
        })
    };

    let tampered = install(b"tampered", SIGNED_IMAGE_SIGNATURE.as_bytes()).unwrap_err();
    assert!(
        tampered.contains("signature verification failed"),
        "{tampered}"
    );

    let malformed = install(SIGNED_IMAGE, b"not a signature").unwrap_err();
    assert!(malformed.contains("not base64"), "{malformed}");

    // Genuinely signed under the same key, and not what this release
    // published for the app half.
    let elsewhere = install(SIGNED_BYTES, TEST_SIGNATURE.as_bytes()).unwrap_err();
    assert!(
        elsewhere.contains("the desktop app download hashes to"),
        "{elsewhere}"
    );

    assert_eq!(std::fs::read(&installed).unwrap(), b"the app already here");
    assert!(!staged_path(&installed).exists());
}

/// Both app-half refusals promise the same thing, so the sentence is
/// asserted where it is written rather than at each caller.
#[test]
fn a_refused_app_half_names_the_release_the_reason_and_the_retry() {
    let said = app_refused("5.1.0", "the directory holding /opt/kendex refuses writes");
    assert!(said.contains("5.1.0"), "{said}");
    assert!(said.contains("refuses writes"), "{said}");
    assert!(said.contains("nothing was updated"), "{said}");
}

#[test]
fn missing_asset_message_never_calls_current_or_older_available() {
    let current = missing_asset_message(VersionRelation::Current, "5.0.1", "5.0.1", "x").unwrap();
    let older = missing_asset_message(VersionRelation::Older, "5.0.0", "5.0.1", "x").unwrap();
    let newer = missing_asset_message(VersionRelation::Newer, "5.1.0", "5.0.1", "x").unwrap();
    assert!(current.contains("unchanged") && !current.contains("is available"));
    assert!(older.contains("is newer") && !older.contains("is available"));
    assert!(newer.contains("is available"));
}

/// The running command is at a path nothing else can vouch for: a lookup
/// by name cannot tell this binary from a wrapper someone wrote, and this
/// run is the one place that knows. So it records the path, on a run that
/// updated and on one that found nothing to do, which is how an install
/// made before the record existed gains one.
#[test]
fn an_update_records_the_command_it_is_running_as() {
    if no_record_on_this_runner() {
        return;
    }
    for force in [true, false] {
        let dir = tempfile::tempdir().unwrap();
        let (env, feed_url, installed) = a_release_is_out(&dir);

        run_on(
            &env,
            force,
            &feed_url,
            &installed,
            &InstallChannel::Direct,
            TEST_KEY,
            TEST_TARGET,
        )
        .unwrap();

        assert_eq!(
            std::fs::read(&installed).unwrap(),
            OFFERED,
            "force: {force}"
        );
        assert_eq!(
            kendex_core::command_update::recorded_command(&env),
            Some(kendex_core::command_update::InstalledCommand {
                path: installed.clone(),
            }),
            "force: {force}"
        );
    }
}

/// A run that finds nothing to do still records: the path is what an
/// install made before this record existed is missing.
#[test]
fn a_run_with_nothing_to_do_still_records_the_command() {
    if no_record_on_this_runner() {
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let (env, _, installed) = a_release_is_out(&dir);
    // A feed offering exactly what is running: nothing to fetch, nothing
    // to write.
    let feed = dir.path().join("current.json");
    std::fs::write(
        &feed,
        format!(
            r#"{{"schema": 1, "version": "{}", "assets": {{}}}}"#,
            env!("CARGO_PKG_VERSION")
        ),
    )
    .unwrap();

    run_on(
        &env,
        false,
        &file_url(&feed),
        &installed,
        &InstallChannel::Direct,
        TEST_KEY,
        TEST_TARGET,
    )
    .unwrap();

    assert_eq!(std::fs::read(&installed).unwrap(), INSTALLED);
    assert_eq!(
        kendex_core::command_update::recorded_command(&env),
        Some(kendex_core::command_update::InstalledCommand { path: installed })
    );
}

/// A package manager's copy is not ours to record. The run says whose it
/// is and stops before anything is written, and a record left here would
/// tell the app to replace bytes the CLI just refused to touch.
#[test]
fn a_package_managed_run_records_nothing() {
    // The nothing this asserts is the package-managed arm's. Under a
    // root runner it would be the guard's, and every arm would pass.
    if no_record_on_this_runner() {
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let (env, feed_url, installed) = a_release_is_out(&dir);
    let brew = InstallChannel::Managed {
        manager: "Homebrew".to_owned(),
        command: "brew upgrade kendex-cli".to_owned(),
    };

    run_on(
        &env,
        false,
        &feed_url,
        &installed,
        &brew,
        TEST_KEY,
        TEST_TARGET,
    )
    .unwrap();

    assert_eq!(kendex_core::command_update::recorded_command(&env), None);
}
