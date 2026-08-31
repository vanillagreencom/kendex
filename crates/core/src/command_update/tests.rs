//! The lookup and the halves it drives, against real files.
//!
//! Records are written through `record`'s own seam with the identity
//! spelled out. None of these cases is about privilege, and the entries
//! beside that seam write nothing when the process is root — a root dev
//! container is one — which would leave the lookups here answering for a
//! record that was never written.

use super::*;
use crate::env::Env;
use crate::install_channel::Host;
use record::{Write, record_as};

mod described;

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

/// The command half, under this suite's release key and target.
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
    /// Paths whose directory refuses this process's writes — what an
    /// unprivileged app meets at a `sudo`-installed `/usr/local/bin`.
    unwritable: Vec<PathBuf>,
    links: Vec<(PathBuf, PathBuf)>,
    arch: bool,
}

impl HostProbe for Machine {
    fn replaceable(&self, path: &Path) -> bool {
        !self.unwritable.iter().any(|p| p == path)
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

/// The lookup with an installer's record behind it. Tests about *which*
/// candidate wins record the one they expect to win: get the order wrong
/// and the found path is a different file, which reads `NotOurs` and fails
/// the assertion just as loudly.
fn located(machine: &Machine, probed: &[PathBuf], installed: &str) -> CommandBeside {
    command_beside_app(machine, probed, &[], Some(&recorded(installed)))
}

/// The record an installer would have left for a file on this machine.
fn recorded(path: &str) -> InstalledCommand {
    InstalledCommand {
        path: PathBuf::from(path),
    }
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

/// One machine, one executable named `kendex` in a directory that takes a
/// rename. Whether it is ours is the only thing the two arms below differ
/// on, and it is the only thing that decides.
fn a_kendex_on_this_machine(dir: &tempfile::TempDir) -> (Env, PathBuf) {
    let bin = dir.path().join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let command = bin.join("kendex");
    std::fs::write(&command, WRAPPER).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&command, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    (Env::host_rooted(dir.path()), command)
}

/// What someone wrote themselves: a shell script named `kendex` that runs
/// the real one. Executable, correctly named, and in a writable directory.
const WRAPPER: &[u8] = b"#!/bin/sh\nexec /opt/kendex/kendex \"$@\"\n";

/// A wrapper someone wrote is not kendex, however much it looks like it
/// from outside. Nothing recorded it, so it is refused and the card is
/// told there is no owner to name — and the file is left exactly as its
/// author wrote it.
#[test]
fn a_command_no_installer_recorded_is_never_replaced() {
    let dir = tempfile::tempdir().unwrap();
    let (env, wrapper) = a_kendex_on_this_machine(&dir);
    let probed = vec![wrapper.clone()];

    let beside = command_beside_app(&Host, &probed, &[], recorded_command(&env).as_ref());
    assert_eq!(beside, CommandBeside::NotOurs(InstallChannel::Unknown));

    let (feed_url, _) = a_release_is_out(&dir);
    assert_eq!(
        across(&beside, &feed_url, RELEASE).unwrap(),
        CommandHalf::Untouched
    );
    assert_eq!(std::fs::read(&wrapper).unwrap(), WRAPPER);
}

/// The same file, the same directory, the same shape — with an installer's
/// record behind it. Read against the arm above, this is what says the
/// record is what refused the wrapper, and not a fixture that could never
/// have been carried in the first place.
///
/// The record is left exactly as it was, too: it names a path, so the
/// bytes that land at that path are still the command it names, and the
/// next release finds a command it can prove rather than one it has to
/// refuse.
#[test]
fn the_command_an_installer_recorded_is_carried_across() {
    let dir = tempfile::tempdir().unwrap();
    let (env, command) = a_kendex_on_this_machine(&dir);
    record_as(&env, Write::Command(&command), false).unwrap();
    let probed = vec![command.clone()];

    let beside = command_beside_app(&Host, &probed, &[], recorded_command(&env).as_ref());
    assert_eq!(beside, CommandBeside::Ours(Host.resolve(&command)));

    let (feed_url, _) = a_release_is_out(&dir);
    let record = env.installed_command_file();
    let written = std::fs::read(&record).unwrap();
    assert_eq!(
        across(&beside, &feed_url, RELEASE).unwrap(),
        CommandHalf::Moved
    );
    assert_eq!(std::fs::read(&command).unwrap(), OFFERED);
    assert_eq!(
        std::fs::read(&record).unwrap(),
        written,
        "the command half rewrote a record that already named the path it replaced"
    );
    assert_eq!(
        command_beside_app(&Host, &probed, &[], recorded_command(&env).as_ref()),
        CommandBeside::Ours(Host.resolve(&command)),
        "a release the app just installed is not one it has to refuse next time"
    );
}

/// A record naming one command says nothing about another. Someone with
/// an install.sh kendex and a wrapper of their own on `PATH` ahead of it
/// keeps the wrapper.
#[test]
fn a_record_of_one_command_does_not_vouch_for_another() {
    let dir = tempfile::tempdir().unwrap();
    let (env, wrapper) = a_kendex_on_this_machine(&dir);
    let theirs = Path::new("/home/pat/.local/bin/kendex");
    record_as(&env, Write::Command(theirs), false).unwrap();

    assert_eq!(
        command_beside_app(&Host, &[wrapper], &[], recorded_command(&env).as_ref()),
        CommandBeside::NotOurs(InstallChannel::Unknown),
        "a record of another path vouched for this one"
    );
}

/// A recorded command outside `PATH` and outside both directories
/// `install.sh` chooses between — `~/.cargo/bin/kendex` under an app a
/// Finder launch hands the four system directories. Nothing else in the
/// search names it, so the record has to be searched and not only
/// checked, or the app updates alone and every terminal stays behind.
#[test]
fn a_recorded_command_no_other_route_reaches_is_still_found() {
    let cargo_bin = "/home/pat/.cargo/bin/kendex";
    let machine = Machine {
        present: candidates(&[cargo_bin]),
        ..Machine::default()
    };
    // What a Finder launch leaves: no kendex on `PATH`, and none in
    // either installer directory.
    let probed = command_candidates(
        Path::new("/home/pat"),
        Some(&std::ffi::OsString::from("/usr/bin:/bin")),
    );
    assert!(
        !probed.iter().any(|p| p == Path::new(cargo_bin)),
        "the fixture only means something while no other candidate names it: {probed:?}"
    );

    assert_eq!(
        located(&machine, &probed, cargo_bin),
        CommandBeside::Ours(cargo_bin.into())
    );
}

/// `install.sh` writes `/usr/local/bin` with `sudo` whenever that is the
/// first of its two directories on `PATH`, and the desktop app runs
/// unprivileged. The command there is kendex's — an installer recorded
/// it — and what is missing is the privilege to replace it. Called not ours, that reads as a command kendex has no claim on and
/// names nothing a person can do; called what it is, the card can name the
/// one command that moves it.
#[test]
fn a_recorded_command_this_app_cannot_write_is_ours_without_the_privilege() {
    let sudo_installed = "/usr/local/bin/kendex";
    let probed = candidates(&[sudo_installed]);
    let unprivileged = Machine {
        present: probed.clone(),
        unwritable: probed.clone(),
        ..Machine::default()
    };

    assert_eq!(
        located(&unprivileged, &probed, sudo_installed),
        CommandBeside::NeedsPrivilege(sudo_installed.into())
    );

    // The control the arm above needs: the same path, writable, is where
    // the answer differs. A fixture nothing could carry would read
    // `NeedsPrivilege` for the wrong reason.
    let privileged = Machine {
        present: probed.clone(),
        ..Machine::default()
    };
    assert_eq!(
        located(&privileged, &probed, sudo_installed),
        CommandBeside::Ours(sudo_installed.into())
    );

    // And the privilege is not a way around the record: an unrecorded
    // command in a directory this process cannot write is still not ours.
    assert_eq!(
        located(&unprivileged, &probed, "/home/pat/.local/bin/kendex"),
        CommandBeside::NotOurs(InstallChannel::Unknown)
    );
}

/// The command half writes nothing where the app has no privilege to
/// write it. The card said so before Update now was pressed; what must
/// not happen is a write attempt reported as a moved half.
#[test]
fn the_command_half_leaves_a_path_it_cannot_write_alone() {
    let dir = tempfile::tempdir().unwrap();
    let (feed_url, installed) = a_release_is_out(&dir);

    let half = across(
        &CommandBeside::NeedsPrivilege(installed.clone()),
        &feed_url,
        RELEASE,
    )
    .unwrap();

    assert_eq!(half, CommandHalf::Untouched);
    assert_eq!(std::fs::read(&installed).unwrap(), INSTALLED);
}
