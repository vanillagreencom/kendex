//! The lookup against a described machine: what `PATH`, the installer's
//! own directories and an owner's claim decide, with no file on disk to
//! decide it instead. The cases that need real files are next door.

use super::*;

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
        located(&machine, &probed, on_path),
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
        // Recorded, so the refusal is the installer's ownership and not
        // a missing record.
        assert_eq!(
            located(&machine, probed, &probed[0].display().to_string()),
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
        located(&Machine::default(), &probed, &image.display().to_string()),
        CommandBeside::Absent
    );

    let only_the_app = Machine {
        present: probed.clone(),
        ..Machine::default()
    };
    assert_eq!(
        command_beside_app(
            &only_the_app,
            &probed,
            &[image.clone()],
            Some(&recorded(&image.display().to_string()))
        ),
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

    // What the updater offers on Windows: no path at all. Recorded, so
    // the fixture reaches the app and the exclusion is what stops it.
    assert_eq!(
        command_beside_app(
            &machine,
            &probed,
            &[],
            Some(&recorded(&exe.display().to_string()))
        ),
        CommandBeside::Ours(exe.clone()),
        "the fixture has to reach the app before the exclusion can be what stops it"
    );
    assert_eq!(
        command_beside_app(
            &machine,
            &probed,
            &[exe.clone()],
            Some(&recorded(&exe.display().to_string()))
        ),
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
        located(&machine, &probed, "/usr/local/bin/kendex"),
        CommandBeside::Ours(real)
    );

    // With nothing runnable behind them they stop nothing: the answer is
    // that there is no command here, not that one of them is it.
    let neither = Machine {
        not_commands: candidates(&["/opt/a/kendex", "/opt/b/kendex"]),
        ..Machine::default()
    };
    assert_eq!(
        located(&neither, &probed[..2], "/usr/local/bin/kendex"),
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
    // `PATH` is built by the rule that reads it back: Windows splits on
    // `;`, and a hand-written `:` leaves the whole variable as one entry.
    let other = Path::new("/usr/bin");
    let path = std::env::join_paths([home_bin.as_path(), other]).unwrap();

    assert_eq!(
        command_candidates(home, Some(path.as_os_str())),
        vec![
            home_bin.join(COMMAND_NAME),
            other.join(COMMAND_NAME),
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
