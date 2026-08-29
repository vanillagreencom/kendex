use super::*;

#[path = "../../../fixture_url.rs"]
mod fixture_url;
use fixture_url::file_url;

/// A throwaway minisign keypair signing `OFFERED`, so the admitted arm
/// runs the real check rather than a stub standing in for it. One pair
/// serves both halves: the app and the command are held to one key.
const TEST_KEY: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IDk0QUI0NzI3RTVDMTVCODEKUldTQlc4SGxKMGVybEhxeFovbTJ3U1phMng4aE9VTXByV09pUVRFVFNKbFZ5aWxtUTAvVGgyWEwK";
const TEST_SIGNATURE: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9tIHJzaWduIHNlY3JldCBrZXkKUlVTQlc4SGxKMGVybElTMUxrbkMyQ0tBWGlnejY1S0xLekovK0tBYllNdkdJTVU0bitTSjRBSCt1RlpwWnZkRHNKcWFTSHVoeStIQkpyVDlOaVRIMmROWVVSb21mMVBVRmd3PQp0cnVzdGVkIGNvbW1lbnQ6IGtlbmRleCB0ZXN0CnpKSnpYYnBtODZYRW40eHgxSTVkeG5YdktxT0k5ZXdmSkEyMkdtZXpreGgwbUNJZysybkJ2cGowUXZ6N2c3RHA4TEZBVXVBQUVMRExuUzFuaVpsaUF3PT0K";

/// What the feed offers is the signed blob, because a release only ever
/// offers a command `TEST_SIGNATURE` covers; nothing else gets written.
const OFFERED: &[u8] = b"kendex AppImage bytes";
const INSTALLED: &[u8] = b"the command already here";
/// The release the fixture feed publishes, and the target it publishes
/// for — fixed here so a test says the same thing on every build host.
const RELEASE: &str = "9.9.9";
const TARGET: &str = "x86_64-unknown-linux-gnu";

/// One machine mid-update: a `kendex` command already installed, and a
/// release the feed offers at [`RELEASE`] with a signed command binary
/// behind it. What each arm does to that command is the whole difference
/// between them.
fn a_release_is_out(dir: &tempfile::TempDir) -> (String, PathBuf) {
    a_release_is_out_under(dir.path())
}

fn a_release_is_out_under(home: &Path) -> (String, PathBuf) {
    std::fs::create_dir_all(home).unwrap();
    let installed = home.join("kendex");
    std::fs::write(&installed, INSTALLED).unwrap();
    std::fs::write(home.join("new-command"), OFFERED).unwrap();
    std::fs::write(home.join("new-command.sig"), TEST_SIGNATURE).unwrap();
    // A path spliced into a URL is not a URL: a home directory holding a
    // space or a `#` addresses a different file, or none. The feed is JSON,
    // which has no literal string, so the URL goes through serde too.
    std::fs::write(
        home.join("feed.json"),
        format!(
            r#"{{"schema": 1, "version": "{RELEASE}", "assets": {{"{TARGET}": {}}}}}"#,
            serde_json::to_string(&file_url(&home.join("new-command"))).unwrap()
        ),
    )
    .unwrap();
    (file_url(&home.join("feed.json")), installed)
}

fn across(beside: &CommandBeside, feed: &str, release: &str) -> Result<CommandHalf, String> {
    bring_command_across(beside, feed, release, TARGET, TEST_KEY)
}

/// The whole point of the family update: the command a person runs ends
/// up on the release the app is installing, and it got there from that
/// release's own published asset.
#[test]
fn the_command_lands_on_the_release_the_app_is_installing() {
    let dir = tempfile::tempdir().unwrap();
    let (feed_url, installed) = a_release_is_out(&dir);

    let half = across(&CommandBeside::Ours(installed.clone()), &feed_url, RELEASE).unwrap();

    assert_eq!(half, CommandHalf::Moved);
    assert_eq!(std::fs::read(&installed).unwrap(), OFFERED);
    assert!(!staged_path(&installed).exists());
}

/// The same arm with the release sitting under a directory whose name holds
/// characters a URL reserves. A space and a `#` are ordinary in a Windows
/// profile directory, and spelled into a URL rather than encoded they
/// address a different file, or none.
#[test]
fn a_release_under_a_name_a_url_reserves_is_still_fetched() {
    let dir = tempfile::tempdir().unwrap();
    let (feed_url, installed) = a_release_is_out_under(&dir.path().join("my release #1"));

    across(&CommandBeside::Ours(installed.clone()), &feed_url, RELEASE).unwrap();

    assert_eq!(std::fs::read(&installed).unwrap(), OFFERED);
}

/// Skew, driven from both sides: the app installing a release the feed is
/// behind, and one the feed is ahead of. Either way the pair would come out
/// split by version rather than by failure, so nothing is written and the
/// app's own version stays behind, which is what brings the card back to
/// try both halves again. Build metadata is not skew — SemVer keeps it out
/// of precedence, and the release job stamps one version into both.
#[test]
fn a_feed_on_another_release_moves_neither_half() {
    for offered in ["9.9.8", "10.0.0"] {
        let dir = tempfile::tempdir().unwrap();
        let (feed_url, installed) = a_release_is_out(&dir);

        let refused =
            across(&CommandBeside::Ours(installed.clone()), &feed_url, offered).unwrap_err();

        assert!(refused.contains(offered), "{offered}: {refused}");
        assert!(refused.contains(RELEASE), "{offered}: {refused}");
        assert!(
            refused.contains("nothing was updated"),
            "{offered}: {refused}"
        );
        assert_eq!(std::fs::read(&installed).unwrap(), INSTALLED, "{offered}");
    }

    let dir = tempfile::tempdir().unwrap();
    let (feed_url, installed) = a_release_is_out(&dir);
    let build_metadata = format!("{RELEASE}+ci");
    assert_eq!(
        across(&CommandBeside::Ours(installed), &feed_url, &build_metadata).unwrap(),
        CommandHalf::Moved
    );
}

/// A release that publishes no command for this machine cannot move the
/// command that is installed on it, so it moves neither half rather than
/// leaving one behind. The refusal names the target, because that is the
/// only part a person can act on.
#[test]
fn a_release_with_no_command_for_this_target_stops_the_family() {
    let dir = tempfile::tempdir().unwrap();
    let (feed_url, installed) = a_release_is_out(&dir);

    let refused = bring_command_across(
        &CommandBeside::Ours(installed.clone()),
        &feed_url,
        RELEASE,
        "sparc-unknown-none-elf",
        TEST_KEY,
    )
    .unwrap_err();

    assert!(refused.contains("sparc-unknown-none-elf"), "{refused}");
    assert!(refused.contains("nothing was updated"), "{refused}");
    assert_eq!(std::fs::read(&installed).unwrap(), INSTALLED);
}

/// Absence is not failure. A dmg or msi with no command beside it is the
/// whole install already, and a command another installer owns is that
/// installer's to move — neither stops the app from updating itself.
#[test]
fn no_command_or_one_another_installer_owns_lets_the_app_go_alone() {
    let dir = tempfile::tempdir().unwrap();
    let (feed_url, installed) = a_release_is_out(&dir);

    for beside in [
        CommandBeside::Absent,
        CommandBeside::NotOurs(InstallChannel::Unknown),
    ] {
        assert_eq!(
            across(&beside, &feed_url, RELEASE).unwrap(),
            CommandHalf::Untouched,
            "{beside:?}"
        );
        assert_eq!(std::fs::read(&installed).unwrap(), INSTALLED, "{beside:?}");
    }
}

/// The command half is signed for the same reason the app half is: the feed
/// names a host, so a run has to be able to be handed bytes and refuse them.
/// Driven by both shapes a bad download takes, and either way the command
/// already installed is exactly as it was.
#[test]
fn a_command_binary_that_fails_verification_is_never_written() {
    for (file, corrupt) in [
        ("new-command", b"kendex AppImage bytes, and more".as_slice()),
        ("new-command.sig", b"not a signature".as_slice()),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let (feed_url, installed) = a_release_is_out(&dir);
        std::fs::write(dir.path().join(file), corrupt).unwrap();

        let refused =
            across(&CommandBeside::Ours(installed.clone()), &feed_url, RELEASE).unwrap_err();

        assert!(
            refused.contains("the kendex command could not be updated"),
            "{file}: {refused}"
        );
        assert_eq!(std::fs::read(&installed).unwrap(), INSTALLED, "{file}");
        assert!(!staged_path(&installed).exists(), "{file}");
    }
}

/// The recovery the ordering exists for. A machine left split — a command
/// already across, an app that would not follow — presses again, and the
/// command half runs over bytes already at the release rather than refusing
/// them, so the retry that fixes the app does not stall on the half that
/// already worked.
#[test]
fn a_retry_over_a_command_already_across_is_not_refused() {
    let dir = tempfile::tempdir().unwrap();
    let (feed_url, installed) = a_release_is_out(&dir);
    let beside = CommandBeside::Ours(installed.clone());

    across(&beside, &feed_url, RELEASE).unwrap();
    let again = across(&beside, &feed_url, RELEASE).unwrap();

    assert_eq!(again, CommandHalf::Moved);
    assert_eq!(std::fs::read(&installed).unwrap(), OFFERED);
}

/// A machine described by what is on it, so arms `for_cli` can only reach
/// through a real filesystem are reachable here.
#[derive(Default)]
struct Machine {
    /// Paths this machine would run.
    present: Vec<PathBuf>,
    /// Paths that are there and are not commands: a directory, or a data
    /// file, carrying a command's name.
    not_commands: Vec<PathBuf>,
    links: Vec<(PathBuf, PathBuf)>,
    arch: bool,
}

impl HostProbe for Machine {
    fn replaceable(&self, _: &Path) -> bool {
        true
    }

    fn exists(&self, path: &Path) -> bool {
        self.is_command(path) || self.not_commands.iter().any(|p| p == path)
    }

    fn is_command(&self, path: &Path) -> bool {
        self.present.iter().any(|p| p == path)
    }

    fn resolve(&self, path: &Path) -> PathBuf {
        self.links
            .iter()
            .find(|(from, _)| from == path)
            .map_or_else(|| path.to_owned(), |(_, to)| to.clone())
    }

    fn on_path(&self, _: &str) -> bool {
        false
    }

    fn os_release(&self) -> Option<String> {
        self.arch.then(|| "ID=arch\n".to_owned())
    }
}

fn candidates(paths: &[&str]) -> Vec<PathBuf> {
    paths.iter().map(PathBuf::from).collect()
}

/// `PATH` order decides which `kendex` a person runs, so it decides which
/// one a family update replaces: the search reads `PATH` before the
/// installer's own directories and stops at the first candidate that
/// exists. Replacing a second copy further down would move the half nobody
/// runs and leave the half they do.
#[test]
fn the_command_a_shell_resolves_first_is_the_one_replaced() {
    let on_path = "/opt/bin/kendex";
    let machine = Machine {
        present: candidates(&[on_path, "/home/pat/.local/bin/kendex"]),
        ..Machine::default()
    };
    let probed = command_candidates(
        Path::new("/home/pat"),
        Some(&std::ffi::OsString::from("/opt/bin")),
    );

    assert_eq!(
        command_beside_app(&machine, &probed, &[]),
        CommandBeside::Ours(on_path.into())
    );
}

/// A copy another installer owns is never replaced, and the answer names
/// who owns it, so the card can tell the person which command moves it
/// rather than leaving the app to update alone in silence. Judged by the
/// file behind the name, because a link on `PATH` is how a package's copy
/// is reached without ever naming its prefix.
///
/// Both arms of "not ours" run: a distro whose helper this build can name,
/// and one it cannot, where the honest answer carries no command at all.
#[test]
fn a_command_another_installer_owns_is_never_ours_and_names_its_owner() {
    let named = candidates(&["/usr/bin/kendex"]);
    let linked = candidates(&["/home/pat/.local/bin/kendex"]);
    let cases = [
        (
            Machine {
                present: named.clone(),
                arch: true,
                ..Machine::default()
            },
            &named,
            InstallChannel::Managed {
                manager: "an AUR helper".to_owned(),
                command: "update kendex with your AUR helper".to_owned(),
            },
        ),
        (
            Machine {
                present: linked.clone(),
                links: vec![(linked[0].clone(), named[0].clone())],
                ..Machine::default()
            },
            &linked,
            InstallChannel::Unknown,
        ),
    ];
    for (machine, probed, owner) in cases {
        assert_eq!(
            command_beside_app(&machine, probed, &[]),
            CommandBeside::NotOurs(owner),
            "{probed:?}"
        );
    }
}

/// Two ways to have no command to move. Nothing installed under any
/// candidate is a dmg or msi install; the running app reachable as
/// `kendex` is not a command to carry — written over, it would take the
/// command binary and then be written back by the app half, leaving the
/// machine with neither.
#[test]
fn nothing_installed_and_the_running_app_both_read_absent() {
    let image = PathBuf::from("/home/pat/.local/bin/kendex");
    let probed = vec![image.clone()];
    assert_eq!(
        command_beside_app(&Machine::default(), &probed, &[]),
        CommandBeside::Absent
    );

    let only_the_app = Machine {
        present: probed.clone(),
        ..Machine::default()
    };
    assert_eq!(
        command_beside_app(&only_the_app, &probed, &[image]),
        CommandBeside::Absent
    );
}

/// Windows is the case the updater's own path cannot cover. It judges no
/// path there, so nothing but the running executable itself keeps the app
/// out of the search — and the desktop executable is `kendex.exe`, the
/// name the command carries, so an install directory on `PATH` puts the
/// app first in line. Taken for the command, it would be overwritten with
/// the CLI binary before the updater ever ran.
#[test]
fn a_windows_app_on_path_is_never_taken_for_the_command() {
    let exe = PathBuf::from("C:/Program Files/kendex/kendex.exe");
    let machine = Machine {
        present: vec![exe.clone()],
        ..Machine::default()
    };
    let probed = vec![exe.clone()];

    // What the updater offers on Windows: no path at all.
    assert_eq!(
        command_beside_app(&machine, &probed, &[]),
        CommandBeside::Ours(exe.clone()),
        "the fixture has to reach the app before the exclusion can be what stops it"
    );
    assert_eq!(
        command_beside_app(&machine, &probed, &[exe]),
        CommandBeside::Absent
    );
}

/// A candidate has to be a command. A directory and a data file each carry
/// the name in a writable place, which answers every other question the
/// way a real command does, and each would take a release binary written
/// over it. The search passes both and lands on the command behind them.
#[test]
fn a_directory_or_a_data_file_named_kendex_is_not_a_command() {
    let real = PathBuf::from("/usr/local/bin/kendex");
    let machine = Machine {
        present: vec![real.clone()],
        not_commands: candidates(&["/opt/a/kendex", "/opt/b/kendex"]),
        ..Machine::default()
    };
    let probed = candidates(&["/opt/a/kendex", "/opt/b/kendex", "/usr/local/bin/kendex"]);

    assert_eq!(
        command_beside_app(&machine, &probed, &[]),
        CommandBeside::Ours(real)
    );

    // With nothing runnable behind them they stop nothing: the answer is
    // that there is no command here, not that one of them is it.
    let neither = Machine {
        not_commands: candidates(&["/opt/a/kendex", "/opt/b/kendex"]),
        ..Machine::default()
    };
    assert_eq!(
        command_beside_app(&neither, &probed[..2], &[]),
        CommandBeside::Absent
    );
}

/// `PATH` first, then the two directories `install.sh` chooses between,
/// each named once — a launcher whose `PATH` already carries `.local/bin`
/// must not have it probed twice.
///
/// Written against the constants rather than against their values: what
/// those values have to be is `install.sh`'s to say, and the contract test
/// in `crates/cli/tests/install_script.rs` reads them out of the script.
#[test]
fn candidates_are_path_then_the_installer_s_own_dirs_without_repeats() {
    let home = Path::new("/home/pat");
    let home_bin = home.join(INSTALLER_HOME_BIN);
    let system = Path::new(INSTALLER_SYSTEM_BIN).join(COMMAND_NAME);
    let path = std::ffi::OsString::from(format!("{}:/usr/bin", home_bin.display()));

    assert_eq!(
        command_candidates(home, Some(&path)),
        vec![
            home_bin.join(COMMAND_NAME),
            PathBuf::from(format!("/usr/bin/{COMMAND_NAME}")),
            system.clone(),
        ]
    );

    // No PATH at all still leaves the installer's own two, in its order.
    assert_eq!(
        command_candidates(home, None),
        vec![home_bin.join(COMMAND_NAME), system]
    );
}

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

fn artifact(bytes: &[u8], signature: &[u8]) -> SignedArtifact {
    SignedArtifact {
        bytes: bytes.to_vec(),
        signature: signature.to_vec(),
    }
}

/// The write both halves of both shells land through, read from both
/// sides. A signature that checks out puts the download in place; the two
/// shapes a bad download takes — bytes the signature does not cover, and a
/// body that is no signature at all — are turned away by name, and leave
/// what was installed exactly as it was. Neither arm leaves a staged file.
#[test]
fn an_artifact_is_written_only_when_its_signature_checks_out() {
    let dir = tempfile::tempdir().unwrap();
    let installed = dir.path().join("kendex.AppImage");
    let already = b"the app already here";
    std::fs::write(&installed, already).unwrap();

    let tampered = artifact(b"tampered", TEST_SIGNATURE.as_bytes())
        .install_at(&installed, TEST_KEY)
        .unwrap_err();
    assert!(
        tampered.contains("signature verification failed"),
        "{tampered}"
    );
    let malformed = artifact(OFFERED, b"not a signature")
        .install_at(&installed, TEST_KEY)
        .unwrap_err();
    assert!(malformed.contains("not base64"), "{malformed}");
    assert_eq!(std::fs::read(&installed).unwrap(), already);

    artifact(OFFERED, TEST_SIGNATURE.as_bytes())
        .install_at(&installed, TEST_KEY)
        .unwrap();
    assert_eq!(std::fs::read(&installed).unwrap(), OFFERED);
    assert!(!staged_path(&installed).exists());
}

/// Two runs sharing one staged path would each rename the other's bytes into
/// place, so the name carries the process id, and it stays a sibling of the
/// target since a rename cannot cross filesystems.
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

/// A run whose rename cannot land takes its own staged file away, or the
/// directory collects one per process id that ever tried.
#[test]
fn a_replacement_that_cannot_land_leaves_no_staged_file() {
    let dir = tempfile::tempdir().unwrap();
    let target = dir.path().join("kendex.AppImage");
    std::fs::create_dir(&target).unwrap();

    assert!(replace_executable(&target, b"bytes").is_err());
    assert!(!staged_path(&target).exists());
}
