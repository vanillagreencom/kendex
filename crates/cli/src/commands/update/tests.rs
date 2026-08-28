use super::*;

#[test]
fn fetched_urls_are_always_positional_arguments() {
    assert_eq!(
        curl_args("--output=/tmp/owned"),
        [
            "-fsS",
            "--location",
            "--max-redirs",
            "3",
            "--proto",
            "=https,file",
            "--proto-redir",
            "=https",
            "--",
            "--output=/tmp/owned",
        ]
    );
}

/// The one skew this order can still leave is an app already across
/// and a command that would not move. It is not a dead end — the
/// command's version is unchanged, so the next run reads newer and
/// repeats both halves — and the message has to say so rather than
/// leave a bare io error to be read as total failure.
#[test]
fn a_command_that_would_not_move_says_whether_the_app_went_without_it() {
    let error = || std::io::Error::from(std::io::ErrorKind::PermissionDenied);
    let split = command_failure("5.1.0", true, &error());
    assert!(split.contains("the desktop app is on 5.1.0"), "{split}");
    assert!(split.contains("run kendex update again"), "{split}");

    let neither = command_failure("5.1.0", false, &error());
    assert!(!neither.contains("desktop app"), "{neither}");
}

/// One machine, one release waiting, one command on disk: everything a
/// run needs except who owns the bytes. What each arm did to that
/// command is then the whole difference between them.
fn a_release_is_out(dir: &tempfile::TempDir) -> (Env, String, PathBuf) {
    let home = dir.path();
    let installed = home.join("kendex");
    std::fs::write(&installed, INSTALLED).unwrap();
    std::fs::write(home.join("new-command"), OFFERED).unwrap();
    std::fs::write(
        home.join("feed.json"),
        format!(
            r#"{{"schema": 1, "version": "9.9.9", "assets": {{"{}": "file://{}/new-command"}}}}"#,
            target_triple(),
            home.display()
        ),
    )
    .unwrap();
    (
        Env::host_rooted(home),
        format!("file://{}/feed.json", home.display()),
        installed,
    )
}

const INSTALLED: &[u8] = b"the command already here";
const OFFERED: &[u8] = b"#!/bin/sh\necho 9.9.9\n";

/// The arm no process in this repo can reach, and the one whose absence
/// costs the most: a package manager owns these bytes, so the run says
/// which command brings them current and stops there. Exit zero, because
/// nothing went wrong — the release is real and the way to it is real,
/// it is just not ours to take.
#[test]
fn a_package_managed_command_is_left_for_its_package_manager() {
    let dir = tempfile::tempdir().unwrap();
    let (env, feed_url, installed) = a_release_is_out(&dir);
    let brew = InstallChannel::Managed {
        command: "brew upgrade kendex-cli".to_owned(),
    };

    run_on(&env, false, &feed_url, &installed, &brew).unwrap();

    assert_eq!(std::fs::read(&installed).unwrap(), INSTALLED);
    assert!(!staged_path(&installed).exists());
}

/// The same release, the same command on disk, an install that is ours:
/// now the download lands. Read against the arm above, this is what says
/// the guard is what stopped the other one, rather than a feed that
/// never had anything to offer.
#[test]
fn a_direct_command_is_replaced_from_the_feed() {
    let dir = tempfile::tempdir().unwrap();
    let (env, feed_url, installed) = a_release_is_out(&dir);

    run_on(&env, false, &feed_url, &installed, &InstallChannel::Direct).unwrap();

    assert_eq!(std::fs::read(&installed).unwrap(), OFFERED);
    assert!(!staged_path(&installed).exists());
}

/// A throwaway minisign keypair signing `SIGNED_IMAGE`, so the admitted
/// arm runs the real check rather than a stub standing in for it.
const TEST_KEY: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IDk0QUI0NzI3RTVDMTVCODEKUldTQlc4SGxKMGVybEhxeFovbTJ3U1phMng4aE9VTXByV09pUVRFVFNKbFZ5aWxtUTAvVGgyWEwK";
const TEST_SIGNATURE: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9tIHJzaWduIHNlY3JldCBrZXkKUlVTQlc4SGxKMGVybElTMUxrbkMyQ0tBWGlnejY1S0xLekovK0tBYllNdkdJTVU0bitTSjRBSCt1RlpwWnZkRHNKcWFTSHVoeStIQkpyVDlOaVRIMmROWVVSb21mMVBVRmd3PQp0cnVzdGVkIGNvbW1lbnQ6IGtlbmRleCB0ZXN0CnpKSnpYYnBtODZYRW40eHgxSTVkeG5YdktxT0k5ZXdmSkEyMkdtZXpreGgwbUNJZysybkJ2cGowUXZ6N2c3RHA4TEZBVXVBQUVMRExuUzFuaVpsaUF3PT0K";
const SIGNED_IMAGE: &[u8] = b"kendex AppImage bytes";

/// A path with something already installed at it, so every arm can say
/// whether the bytes there moved.
fn installed_app(dir: &tempfile::TempDir) -> PathBuf {
    let path = dir.path().join("kendex.AppImage");
    std::fs::write(&path, b"the app already here").unwrap();
    path
}

/// The admitted arm: a signature that checks out puts the download in
/// place and leaves no staged file behind.
#[test]
fn an_app_image_whose_signature_checks_out_is_written() {
    let dir = tempfile::tempdir().unwrap();
    let installed = installed_app(&dir);

    install_app_image(
        &installed,
        SIGNED_IMAGE,
        TEST_SIGNATURE.as_bytes(),
        TEST_KEY,
    )
    .unwrap();

    assert_eq!(std::fs::read(&installed).unwrap(), SIGNED_IMAGE);
    assert!(!staged_path(&installed).exists());
}

/// The refused arm, driven by both shapes a bad download takes: bytes
/// the signature does not cover, and a body that is no signature at
/// all. Either way the installed app is exactly as it was.
#[test]
fn an_app_image_that_fails_verification_is_never_written() {
    let dir = tempfile::tempdir().unwrap();
    let installed = installed_app(&dir);

    let tampered = install_app_image(&installed, b"tampered", TEST_SIGNATURE.as_bytes(), TEST_KEY)
        .unwrap_err();
    assert!(
        tampered.contains("signature verification failed"),
        "{tampered}"
    );

    let malformed =
        install_app_image(&installed, SIGNED_IMAGE, b"not a signature", TEST_KEY).unwrap_err();
    assert!(malformed.contains("not base64"), "{malformed}");

    assert_eq!(std::fs::read(&installed).unwrap(), b"the app already here");
    assert!(!staged_path(&installed).exists());
}

/// Two runs sharing one staged path would each rename the other's bytes
/// into place, so the name carries the process id. It stays a sibling
/// of the target, since a rename cannot cross filesystems.
#[test]
fn the_staged_file_is_a_sibling_named_for_this_process() {
    let target = Path::new("/opt/kendex/kendex.AppImage");
    let staged = staged_path(target);
    assert_eq!(staged.parent(), target.parent());
    let suffix = format!(".update.{}", std::process::id());
    assert!(
        staged.to_string_lossy().ends_with(&suffix),
        "{}",
        staged.display()
    );
}

/// A run whose rename cannot land takes its own staged file away, or
/// the directory collects one per process id that ever tried.
#[test]
fn a_replacement_that_cannot_land_leaves_no_staged_file() {
    let dir = tempfile::tempdir().unwrap();
    let target = dir.path().join("kendex.AppImage");
    std::fs::create_dir(&target).unwrap();

    assert!(replace_executable(&target, b"bytes").is_err());
    assert!(!staged_path(&target).exists());
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
