//! What the record proves about a file, and what it refuses to prove.
//! The lookup itself lives in the parent; these are the arms that turn on
//! the record alone, against real files rather than a described machine.
//!
//! The writes below go through [`record_as`] with the identity spelled
//! out, rather than through the entries that ask this process. None of
//! these tests is about privilege, and a suite run as root — a root dev
//! container is one — would otherwise assert against records the guard
//! refused to write. That every entry does ask the process is proved in
//! `every_public_write_follows_this_process_uid`.

use super::*;

/// Bytes to take an identity from — a wrapper someone wrote, which is the
/// kind of file a record has to be able to disown.
const WRAPPER: &[u8] = b"#!/bin/sh\nexec /opt/kendex/kendex \"$@\"\n";

/// A record this build cannot read is not a record it acts on. The file
/// carries two lines and both have to be what they claim: one absolute
/// path, and one SHA-256. A half-written record, a relative path, or a
/// digest that is not one reads as no record rather than as a record with
/// a field to work around.
#[test]
fn a_record_that_is_not_a_path_and_a_digest_is_no_record() {
    let dir = tempfile::tempdir().unwrap();
    let env = Env::host_rooted(dir.path());
    let file = env.installed_command_file();
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    assert_eq!(recorded_command(&env), None, "nothing written at all");

    // Where a record on this host names the command. `is_absolute` is a
    // lexical test, so a Unix-shaped literal is a relative path on Windows
    // and every case below would be refused for the wrong reason — the
    // shape of the path rather than the fault the case is about.
    let installed = match cfg!(windows) {
        true => r"C:\Program Files\kendex\kendex.exe",
        false => "/usr/local/bin/kendex",
    };
    let digest = crate::hash::sha256_hex(WRAPPER);
    for written in [
        String::new(),
        "  \n".to_owned(),
        // The path alone: the whole of the record before the digest
        // existed, and a build that acted on it would replace by name.
        format!("{installed}\n"),
        format!("bin/kendex\n{digest}\n"),
        format!("{installed}\n{}\n", &digest[..63]),
        format!("{installed}\n{}z\n", &digest[..63]),
        format!("{installed}\n{digest}{digest}\n"),
    ] {
        std::fs::write(&file, &written).unwrap();
        assert_eq!(recorded_command(&env), None, "{written:?}");
    }

    // The control: the same file, well formed, is read. Without it every
    // assertion above passes for a reader that returns `None` always.
    record_as(&env, Write::Command(Path::new(installed), WRAPPER), false).unwrap();
    assert_eq!(
        recorded_command(&env),
        Some(InstalledCommand {
            path: PathBuf::from(installed),
            digest,
        })
    );
}

/// The bootstrap widens who has a record, never what a record vouches for.
/// A first run names the file it ran from and nothing else, so the wrapper
/// case stays exactly where KEN-444 left it: a second `kendex` on `PATH`
/// that this install never put there is still not ours to replace.
#[test]
#[cfg(unix)]
fn a_first_run_vouches_for_its_own_file_and_no_other() {
    let dir = tempfile::tempdir().unwrap();
    let env = Env::host_rooted(dir.path());
    let ours = dir.path().join("kendex");
    std::fs::write(&ours, b"the binary that ran").unwrap();
    record_as(&env, Write::FirstRun(&ours), false).unwrap();

    let wrapper = dir.path().join("bin/kendex");
    std::fs::create_dir_all(wrapper.parent().unwrap()).unwrap();
    std::fs::write(&wrapper, WRAPPER).unwrap();
    // Executable, or the search passes over it and the refusal below would
    // be a file that was never a candidate rather than one turned away.
    std::fs::set_permissions(
        &wrapper,
        std::os::unix::fs::PermissionsExt::from_mode(0o755),
    )
    .unwrap();
    assert_eq!(
        crate::command_update::command_beside_app(
            &crate::install_channel::Host,
            &[wrapper],
            &[],
            recorded_command(&env).as_ref(),
        ),
        crate::command_update::CommandBeside::NotOurs(
            crate::install_channel::InstallChannel::Unknown
        ),
        "a file the first run did not name was adopted"
    );
}

/// A staging name left behind by a run that died between the link and the
/// unlink is a second name for the record itself. Written to rather than
/// created, the record is truncated and filled in with whatever the next
/// run was staging — the first-writer contract undone by its own cleanup
/// not having happened.
///
/// Driven through the name supply rather than through a real crash: what
/// varies is which name a staging write is offered, and the case is the
/// one where the first offer is taken.
#[test]
fn a_staging_name_left_behind_is_never_written_through() {
    let dir = tempfile::tempdir().unwrap();
    let record = dir.path().join("installed-command");
    std::fs::write(&record, "the record already here\n").unwrap();
    // What a crash leaves: the staging name still pointing at the record.
    let leftover = dir.path().join("installed-command.stale");
    std::fs::hard_link(&record, &leftover).unwrap();
    let free = dir.path().join("installed-command.free");

    let offers = std::sync::atomic::AtomicUsize::new(0);
    let staged = stage("the next run's record\n", || {
        match offers.fetch_add(1, std::sync::atomic::Ordering::Relaxed) {
            0 => leftover.clone(),
            _ => free.clone(),
        }
    })
    .unwrap();

    assert_eq!(staged, free, "the taken name was staged under");
    assert_eq!(
        std::fs::read_to_string(&record).unwrap(),
        "the record already here\n",
        "the record was written through its other name"
    );
    assert_eq!(
        std::fs::read_to_string(&free).unwrap(),
        "the next run's record\n"
    );
}

/// Every name taken is a failure, not a silent overwrite of the last one
/// offered. The message names how many were tried, because the state it
/// describes is a directory nobody has swept.
#[test]
fn a_staging_write_with_no_free_name_fails() {
    let dir = tempfile::tempdir().unwrap();
    let taken = dir.path().join("installed-command.taken");
    std::fs::write(&taken, "someone else's\n").unwrap();

    let why = stage("mine\n", || taken.clone()).unwrap_err();

    assert!(why.contains(&STAGING_ATTEMPTS.to_string()), "{why}");
    assert_eq!(
        std::fs::read_to_string(&taken).unwrap(),
        "someone else's\n",
        "the taken name was written anyway"
    );
}

/// A run acting as root writes no record, wherever `HOME` points it.
///
/// The case: `sudoers` carrying `env_keep HOME`, so an elevated `kendex
/// update` resolves the record path out of the invoking account's home and
/// root then opens a file every component of whose name that account can
/// replace. Both writers are driven — `record_first_run`, which every verb
/// reaches before its arguments are parsed, and `record_command`, which
/// `kendex update` reaches after the bytes land — and neither leaves so
/// much as the directory behind.
///
/// Root is passed in rather than become: a suite does not choose the uid it
/// is started under. What is real is everything else — the same `Env`, the
/// same functions, a home on disk. The control is the second half, where
/// the identical calls with the identical fixture write both records;
/// without it every assertion above would hold for a pair of functions
/// that never wrote anything.
#[test]
#[cfg(unix)]
fn a_run_acting_as_root_writes_no_record() {
    let dir = tempfile::tempdir().unwrap();
    // The home an elevated run would be pointed at: this account's, kept
    // across the privilege change by the sudoers policy.
    let theirs = dir.path().join("home");
    let env = Env::host_rooted(&theirs);
    let file = env.installed_command_file();
    let running = dir.path().join("kendex");
    std::fs::write(&running, WRAPPER).unwrap();

    record_as(&env, Write::FirstRun(&running), true).unwrap();
    record_as(&env, Write::Command(&running, WRAPPER), true).unwrap();
    assert!(
        !file.exists(),
        "{} was written by a root run",
        file.display()
    );
    assert!(
        !file.parent().unwrap().exists(),
        "{} was created by a root run",
        file.parent().unwrap().display()
    );

    // The control. Same home, same file, same bytes, and the only thing
    // that changed is who is making the write.
    record_as(&env, Write::FirstRun(&running), false).unwrap();
    assert_eq!(
        recorded_command(&env),
        Some(InstalledCommand {
            path: running.clone(),
            digest: crate::hash::sha256_hex(WRAPPER),
        }),
        "the bootstrap did not write where the root arm was asked not to"
    );
    let replaced = b"the bytes that replaced it";
    record_as(&env, Write::Command(&running, replaced), false).unwrap();
    assert_eq!(
        recorded_command(&env).unwrap().digest,
        crate::hash::sha256_hex(replaced),
        "the update write did not land where the root arm was asked not to"
    );
}

/// The guard is wired to this process's own uid and not to a constant,
/// on every entry that writes a record.
///
/// The tests above drive the seam, which is told an identity and so can
/// say nothing about where the identity came from. These drive the public
/// entries, and hold each answer against the uid read independently —
/// from the syscall, not from [`acting_as_root`], which is the function
/// whose wiring is in question.
///
/// All three, because the seam takes the identity as an argument and an
/// argument can be a literal. One entry passing its process's answer says
/// nothing about the next: `record_command` is the write `kendex update`
/// makes after the bytes land, and a constant there is this defect back
/// with the bootstrap still covered.
///
/// Both directions fall out of the comparison. A build answering `true`
/// always strands every person on the record they already had, and fails
/// this on any unprivileged runner, which is every CI job; a build
/// answering `false` always is the defect this change exists to close, and
/// fails it under a root runner. Neither uid is skipped and neither passes
/// for free.
#[test]
#[cfg(unix)]
fn every_public_write_follows_this_process_uid() {
    let privileged = rustix::process::geteuid().is_root();
    let entries: [(&str, &dyn Fn(&Env, &Path) -> Result<(), String>); 3] = [
        ("record_command", &|env, path| {
            record_command(env, path, WRAPPER)
        }),
        ("record_first_run", &record_first_run),
        ("record_installed", &record_installed),
    ];

    // A home of its own for each: a record already there is what
    // `record_first_run` reads to decide it is not the first, so one home
    // shared between them would have an earlier entry answering for a
    // later one.
    for (entry, write) in entries {
        let dir = tempfile::tempdir().unwrap();
        let env = Env::host_rooted(dir.path());
        let running = dir.path().join("kendex");
        std::fs::write(&running, WRAPPER).unwrap();

        write(&env, &running).unwrap();

        assert_eq!(
            recorded_command(&env).map(|record| record.digest),
            (!privileged).then(|| crate::hash::sha256_hex(WRAPPER)),
            "{entry} did not follow this process's uid (root: {privileged})"
        );
    }

    // The control, on a home of its own: the same write told the opposite
    // identity does the opposite thing. Without it every assertion above
    // holds for a writer that never writes, and for one that always does.
    let other = tempfile::tempdir().unwrap();
    let env = Env::host_rooted(other.path());
    let running = other.path().join("kendex");
    std::fs::write(&running, WRAPPER).unwrap();

    record_as(&env, Write::FirstRun(&running), !privileged).unwrap();

    assert_eq!(
        recorded_command(&env).map(|record| record.digest),
        privileged.then(|| crate::hash::sha256_hex(WRAPPER)),
        "the write does the same thing whichever identity it is told"
    );
}
