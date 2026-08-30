//! That the record the desktop app reads is written by running this
//! command, whichever verb was run.
//!
//! Asserted against the built binary rather than the function behind it:
//! the defect was never that the write was wrong, it was that nothing
//! called it outside `kendex update`, and a test that calls the seam
//! itself would have passed throughout.
//!
//! Which is why every case here needs a runner that can write a record.
//! A run acting as root writes none, and the refusals below — a record
//! left alone, a link not written through, a pipe never opened — are the
//! same nothing the guard produces, so under a root runner they would
//! hold without the code under test having decided anything. Each says so
//! and stops instead; see `no_record_on_this_runner`.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::{no_record_on_this_runner, rooted};

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

fn kendex(home: &Path, args: &[&str]) -> Output {
    kendex_with(home, &[], args)
}

#[allow(clippy::expect_used)]
fn kendex_with(home: &Path, vars: &[(&str, &Path)], args: &[&str]) -> Output {
    command(home, vars)
        .args(args)
        .output()
        .expect("kendex binary runs")
}

fn command(home: &Path, vars: &[(&str, &Path)]) -> Command {
    let mut run = Command::new(env!("CARGO_BIN_EXE_kendex"));
    run.current_dir(home)
        .env_clear()
        .env("HOME", home)
        .env("KENDEX_REAL_HOME", "1")
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("PATH", std::env::var("PATH").unwrap_or_default());
    for (key, value) in vars {
        run.env(key, value);
    }
    run
}

/// Whether a run ended at all, inside `limit`. For the cases whose failure
/// is a command that never returns, where `output` would hang the suite
/// rather than fail it.
#[allow(clippy::expect_used)]
fn ran_within(home: &Path, args: &[&str], limit: std::time::Duration) -> bool {
    let mut run = command(home, &[])
        .args(args)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .expect("kendex binary runs");
    let deadline = std::time::Instant::now() + limit;
    loop {
        if run.try_wait().expect("the run reports its state").is_some() {
            return true;
        }
        if std::time::Instant::now() >= deadline {
            let _ = run.kill();
            let _ = run.wait();
            return false;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
}

/// The time a file was last written.
#[allow(clippy::expect_used)]
fn modified(path: &Path) -> std::time::SystemTime {
    fs::metadata(path)
        .and_then(|found| found.modified())
        .unwrap_or_else(|error| panic!("no timestamp on {}: {error}", path.display()))
}

/// The file this test binary runs the command from, under the one spelling
/// a run of it reports back: `current_exe` is resolved before it is
/// recorded, so a fixture naming the unresolved path would compare unequal
/// on any host whose temporary or target tree runs through a link.
#[allow(clippy::expect_used)]
fn the_command_that_runs() -> PathBuf {
    fs::canonicalize(env!("CARGO_BIN_EXE_kendex")).expect("the built binary canonicalizes")
}

/// A record written when the command was installed, with the bytes it names
/// replaced afterwards — the ordering a real install has and a fixture does
/// not, since it writes both within one millisecond.
///
/// A run reads that ordering to decide the bytes may have moved at all, so
/// a fixture that left the record newer would be answered by the timestamps
/// and never reach the case it is about.
#[allow(clippy::expect_used)]
fn installed_before_the_bytes_were_replaced(record: &Path, bytes: &Path) {
    let written = fs::metadata(bytes)
        .and_then(|bytes| bytes.modified())
        .expect("the fixture command carries a timestamp");
    fs::File::options()
        .write(true)
        .open(record)
        .and_then(|file| file.set_modified(written - std::time::Duration::from_secs(60)))
        .expect("the fixture record takes a timestamp");
}

/// The same ordering for a link, whose own timestamps the standard library
/// cannot reach: opening one follows it, so `set_modified` would stamp the
/// file at the other end. `touch -h` reaches them, and the GNU and BSD
/// builds both carry it.
#[allow(clippy::expect_used)]
fn older_than_the_command(link: &Path, command: &Path) {
    let reference = link
        .parent()
        .expect("the fixture link sits in a directory")
        .join("fixture-timestamp");
    fs::write(&reference, "").expect("the fixture reference is written");
    installed_before_the_bytes_were_replaced(&reference, command);
    let stamped = Command::new("touch")
        .args(["-h", "-r"])
        .args([&reference, &link.to_path_buf()])
        .status()
        .expect("touch runs");
    assert!(stamped.success(), "the fixture link took no timestamp");
    fs::remove_file(&reference).expect("the fixture reference is removed");
}

/// An install made before the record existed has none, and its owner has
/// no reason to reach for `update` rather than any other verb. Whichever
/// they run, the app can carry the command across afterwards.
///
/// `verify` is the verb here because it is the one with nothing to do with
/// updating: a record written by that run is a record written by any run.
#[test]
#[allow(clippy::unwrap_used)]
fn any_verb_records_the_command_an_install_never_recorded() {
    if no_record_on_this_runner() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    // The canonical root, and the same one handed to the run: a resolver
    // asked about a different spelling of that directory reads an empty one.
    let home = rooted(&tmp);
    let env = kendex_core::env::Env::host_rooted(&home);
    assert_eq!(
        kendex_core::command_update::recorded_command(&env),
        None,
        "the fixture starts with a record, so this proves nothing"
    );

    kendex(&home, &["verify"]);

    let recorded = kendex_core::command_update::recorded_command(&env)
        .unwrap_or_else(|| panic!("no record at {}", env.installed_command_file().display()));
    assert_eq!(
        recorded.path,
        std::fs::canonicalize(env!("CARGO_BIN_EXE_kendex")).unwrap(),
        "the record names a file other than the one that ran"
    );
    assert_eq!(
        recorded.digest,
        kendex_core::hash::sha256_hex(&fs::read(env!("CARGO_BIN_EXE_kendex")).unwrap()),
        "the record names bytes other than the ones that ran"
    );
}

/// `--version` and `--help` never reach dispatch — clap answers them and
/// exits — and they are what a person runs when the card says their command
/// is behind. A bootstrap behind the parse would miss the run most likely to
/// be their first.
#[test]
#[allow(clippy::unwrap_used)]
fn the_forms_clap_answers_itself_record_the_command_too() {
    if no_record_on_this_runner() {
        return;
    }
    for form in ["--version", "--help"] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let env = kendex_core::env::Env::host_rooted(&home);

        kendex(&home, &[form]);

        assert!(
            kendex_core::command_update::recorded_command(&env).is_some(),
            "{form} left the command unrecorded at {}",
            env.installed_command_file().display()
        );
    }
}

/// Whether a record is already there is the filesystem's answer, not a
/// read's. The distinguishing case is a record this build cannot parse:
/// `recorded_command` reads it as absent, so a first run that decided by
/// reading would write over it, and two copies starting together would
/// both decide the same way and leave the record naming whichever finished
/// last. Refusing the name that is taken cannot do that.
///
/// The unparseable record itself stays; `kendex update` rewrites it,
/// because that is the run replacing the bytes. Until then the app reads
/// no record and refuses the command, which is the safe direction.
#[test]
#[allow(clippy::unwrap_used)]
fn a_record_already_there_is_not_written_over_by_a_first_run() {
    if no_record_on_this_runner() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = kendex_core::env::Env::host_rooted(&home);
    let file = env.installed_command_file();
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    fs::write(&file, "half a record").unwrap();
    assert_eq!(
        kendex_core::command_update::recorded_command(&env),
        None,
        "the fixture parses, so a read could tell it was there and this proves nothing"
    );
    let ours = home.join("ours/kendex");
    fs::create_dir_all(ours.parent().unwrap()).unwrap();
    fs::write(&ours, b"the kendex that ran").unwrap();

    kendex_core::command_update::record_first_run(&env, &ours).unwrap();

    assert_eq!(
        fs::read_to_string(&file).unwrap(),
        "half a record",
        "a first run wrote over a record that was already there"
    );

    // And the running file was not read to reach that answer. Every run
    // comes through here, `--version` and `--help` among them, so a record
    // this build cannot read costs a look at one name and nothing else —
    // never a read and a hash of the whole executable. A running path that
    // is not there at all says so: the read that would have failed never
    // happens.
    kendex_core::command_update::record_first_run(&env, &home.join("no/such/kendex")).unwrap();
    assert!(
        !home.join("no/such/kendex").exists(),
        "the fixture exists, so this proves nothing"
    );
}

/// Concurrent first runs leave one whole record and nothing beside it.
///
/// Not a proof of the ordering — two threads rarely land inside the window
/// that would show it, and a version deciding by reading passes this too.
/// What it does hold is the staging: the file each writer prepares has to
/// be its own, and a name built from the process id alone is not, which is
/// how the pair came to overwrite each other's staged copy the first time
/// this ran.
#[test]
#[allow(clippy::unwrap_used)]
fn concurrent_first_runs_leave_one_whole_record() {
    if no_record_on_this_runner() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = kendex_core::env::Env::host_rooted(&home);
    let theirs = home.join("theirs/kendex");
    let second = home.join("second/kendex");
    for (path, bytes) in [
        (&theirs, b"the kendex they installed".as_slice()),
        (&second, b"a second copy of kendex".as_slice()),
    ] {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, bytes).unwrap();
    }

    let both = std::thread::scope(|scope| {
        let a = scope.spawn(|| kendex_core::command_update::record_first_run(&env, &theirs));
        let b = scope.spawn(|| kendex_core::command_update::record_first_run(&env, &second));
        (a.join().unwrap(), b.join().unwrap())
    });
    assert!(both.0.is_ok() && both.1.is_ok(), "{both:?}");

    // Whichever won, the record names one of them whole and nothing was
    // left staged beside it.
    let recorded = kendex_core::command_update::recorded_command(&env).unwrap();
    assert!(
        recorded.path == theirs || recorded.path == second,
        "the record names {}",
        recorded.path.display()
    );
    assert_eq!(
        recorded.digest,
        kendex_core::hash::sha256_hex(&fs::read(&recorded.path).unwrap()),
        "the record names bytes other than the ones at the path it names"
    );
    let beside: Vec<_> = fs::read_dir(env.installed_command_file().parent().unwrap())
        .unwrap()
        .filter_map(|entry| entry.ok().map(|entry| entry.file_name()))
        .filter(|name| name.to_string_lossy().starts_with("installed-command."))
        .collect();
    assert!(beside.is_empty(), "staged files left behind: {beside:?}");
}

/// The record a person's install already has is not taken off it by a
/// second kendex they happen to run once. Left unguarded, the app would
/// carry across the copy nobody uses and leave the one they do.
#[test]
#[allow(clippy::unwrap_used)]
fn a_run_does_not_take_the_record_off_another_install() {
    if no_record_on_this_runner() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = kendex_core::env::Env::host_rooted(&home);
    let theirs = home.join("bin/kendex");
    fs::create_dir_all(theirs.parent().unwrap()).unwrap();
    fs::write(&theirs, b"the kendex install.sh put here").unwrap();
    kendex_core::command_update::record_installed(&env, &theirs).unwrap();

    kendex(&home, &["verify"]);

    assert_eq!(
        kendex_core::command_update::recorded_command(&env).map(|record| record.path),
        Some(theirs),
        "a run repointed a record it did not write"
    );
}

/// The bytes a record names after the run that replaced them wrote no
/// record. What an elevated `kendex update` leaves behind: the path is
/// still the person's command, the digest is a file that is gone, and
/// `command_beside_app` stops matching the one command the card was
/// offering.
const REPLACED: &[u8] = b"the bytes an elevated update replaced";

/// A replacement made with privilege the app lacks writes no record at
/// all, so this one keeps naming bytes that are gone. The next run from
/// the recorded path is running those new bytes, which is the same proof
/// a first run offers, and it says what is there now.
///
/// Read back through the resolver rather than off the file: what has to
/// hold is the answer the app gets, and a test that parses the file itself
/// would pass for a record the app reads as none.
#[test]
#[allow(clippy::unwrap_used)]
fn a_run_from_the_recorded_path_says_what_replaced_its_bytes() {
    if no_record_on_this_runner() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = kendex_core::env::Env::host_rooted(&home);
    let installed = the_command_that_runs();
    kendex_core::command_update::record_command(&env, &installed, REPLACED).unwrap();
    installed_before_the_bytes_were_replaced(&env.installed_command_file(), &installed);

    kendex(&home, &["verify"]);

    let recorded = kendex_core::command_update::recorded_command(&env)
        .unwrap_or_else(|| panic!("no record at {}", env.installed_command_file().display()));
    assert_eq!(
        recorded.path, installed,
        "the run moved the record off the path it was installed at"
    );
    assert_eq!(
        recorded.digest,
        kendex_core::hash::sha256_hex(&fs::read(&installed).unwrap()),
        "the record still names the bytes the elevated run replaced"
    );
}

/// The same, where the data directory is the one `XDG_DATA_HOME` names
/// rather than the one under `HOME`. The withdrawn fix carried `HOME` onto
/// a `sudo` line and so was correct only for people who do not set this;
/// a record written by the person's own run reads their own variable.
///
/// Linux alone: `XDG_DATA_HOME` is the layout `dirs` reads there, and the
/// macOS layout has no such variable to honour.
#[test]
#[cfg(target_os = "linux")]
#[allow(clippy::unwrap_used)]
fn the_record_a_run_moves_is_the_one_xdg_data_home_names() {
    if no_record_on_this_runner() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    // A second home whose Linux data directory is the one the run is told
    // to use, so the fixture asks `Env` for that path instead of spelling
    // the layout a second time.
    let elsewhere = home.join("elsewhere");
    let env = kendex_core::env::Env::host_rooted(&elsewhere);
    let data_home = elsewhere.join(".local/share");
    let installed = the_command_that_runs();
    kendex_core::command_update::record_command(&env, &installed, REPLACED).unwrap();
    installed_before_the_bytes_were_replaced(&env.installed_command_file(), &installed);

    kendex_with(&home, &[("XDG_DATA_HOME", &data_home)], &["verify"]);

    let recorded = kendex_core::command_update::recorded_command(&env)
        .unwrap_or_else(|| panic!("no record at {}", env.installed_command_file().display()));
    assert_eq!(
        recorded.digest,
        kendex_core::hash::sha256_hex(&fs::read(&installed).unwrap()),
        "the run read a data directory other than the one it was given"
    );
    assert!(
        !kendex_core::env::Env::host_rooted(&home)
            .installed_command_file()
            .exists(),
        "the run wrote a second record under HOME, so the assertion above proves nothing"
    );
}

/// Only the digest moves, and only for the file the run is executing. A
/// record naming another install whose bytes have also been replaced is
/// left exactly as it is: repointing a record by path is what
/// `record_first_run` refuses, and a version that acted on the mismatch
/// alone would take a person's record off the copy they run.
#[test]
#[allow(clippy::unwrap_used)]
fn a_run_does_not_say_what_replaced_another_installs_bytes() {
    if no_record_on_this_runner() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = kendex_core::env::Env::host_rooted(&home);
    let theirs = home.join("bin/kendex");
    fs::create_dir_all(theirs.parent().unwrap()).unwrap();
    fs::write(&theirs, b"the kendex install.sh put here").unwrap();
    kendex_core::command_update::record_command(&env, &theirs, REPLACED).unwrap();
    // Older than the bytes at both paths, so the timestamps let the run
    // reach the case and the path is the only thing that can refuse it.
    installed_before_the_bytes_were_replaced(&env.installed_command_file(), &theirs);
    let before = fs::read_to_string(env.installed_command_file()).unwrap();

    kendex(&home, &["verify"]);

    assert_eq!(
        fs::read_to_string(env.installed_command_file()).unwrap(),
        before,
        "a run rewrote a record naming a file it was not running from"
    );
}

/// A record whose path and digest both still describe the file keeps its
/// content, and comes out of the run saying which version of the command
/// it describes.
///
/// The content is half the answer. The other half is the timestamp: an
/// elevated `update --force` installs the same bytes again and leaves the
/// command newer than a record that already names it, so a run that read,
/// hashed and then left the timestamp alone would leave that true forever
/// and every later run would read and hash the whole command for nothing.
/// Carrying the command's own time onto the record is what closes it, and
/// the assertion below is that closure rather than a proxy for it: the run
/// reads on only where the command is strictly newer.
#[test]
#[allow(clippy::unwrap_used)]
fn a_record_that_still_matches_keeps_its_content_and_stops_being_reread() {
    if no_record_on_this_runner() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = kendex_core::env::Env::host_rooted(&home);
    let installed = the_command_that_runs();
    let bytes = fs::read(&installed).unwrap();
    kendex_core::command_update::record_command(&env, &installed, &bytes).unwrap();
    // Backdated for the same reason the replacement cases are: without it
    // the timestamps refuse the case and this passes without the digest
    // ever being compared.
    installed_before_the_bytes_were_replaced(&env.installed_command_file(), &installed);
    let written = fs::read_to_string(env.installed_command_file()).unwrap();

    kendex(&home, &["verify"]);

    assert_eq!(
        fs::read_to_string(env.installed_command_file()).unwrap(),
        written,
        "a record naming the bytes that are there was rewritten"
    );
    assert_eq!(
        modified(&env.installed_command_file()),
        modified(&installed),
        "the record still reads older than the command, so every later run rereads it"
    );
}

/// What a repair leaves behind is the command's own time, not the moment
/// the record was written.
///
/// The difference is a replacement landing between the read and the write.
/// Stamped with the clock, that record would name the bytes this run read
/// while claiming to be newer than the ones that replaced them, and no
/// later run would ever look again: the state this whole change exists to
/// repair, made permanent. Stamped with the time of the file that was
/// read, the newer bytes are still newer and the next run repairs them.
///
/// The interleaving itself is not driven here. Landing a replacement
/// inside that window needs a seam in the code under test, and this
/// asserts the property that makes the window harmless instead.
#[test]
#[allow(clippy::unwrap_used)]
fn a_repair_leaves_the_record_naming_the_bytes_it_read() {
    if no_record_on_this_runner() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = kendex_core::env::Env::host_rooted(&home);
    let installed = the_command_that_runs();
    kendex_core::command_update::record_command(&env, &installed, REPLACED).unwrap();
    installed_before_the_bytes_were_replaced(&env.installed_command_file(), &installed);

    kendex(&home, &["verify"]);

    assert_eq!(
        modified(&env.installed_command_file()),
        modified(&installed),
        "the repaired record was stamped with the clock rather than the command it read"
    );
}

/// A pipe at the record path is not a record and is never read. Reading one
/// with nothing writing it blocks forever, and this read happens before the
/// arguments are parsed, so `--version` and `--help` would hang with it.
///
/// Driven against the built command under a deadline, since the failure is
/// a run that does not end.
#[test]
#[allow(clippy::unwrap_used)]
fn a_pipe_at_the_record_path_does_not_hold_the_command() {
    if no_record_on_this_runner() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = kendex_core::env::Env::host_rooted(&home);
    let file = env.installed_command_file();
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    let made = Command::new("mkfifo").arg(&file).status().unwrap();
    assert!(
        made.success(),
        "the fixture pipe was not made at {}",
        file.display()
    );

    let ended = ran_within(&home, &["--version"], std::time::Duration::from_secs(30));

    assert!(ended, "the command hung on a pipe at {}", file.display());
}

/// A link at the record path is a name somebody else chose, and a write
/// through it lands on the file at the other end. The record path is only
/// ever a plain file this install wrote, so a link there is refused and the
/// file it points at is left alone.
///
/// The link is backdated rather than the file it names: the run reads the
/// link's own timestamp to decide the command may have moved, so a link
/// made just now would be refused by the timestamps and this would pass
/// without the link ever being the reason.
#[test]
#[allow(clippy::unwrap_used)]
fn a_link_at_the_record_path_is_not_written_through() {
    if no_record_on_this_runner() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = kendex_core::env::Env::host_rooted(&home);
    let file = env.installed_command_file();
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    let installed = the_command_that_runs();
    // A whole, valid record naming the running command with bytes that are
    // gone: follow the link and there is every reason to rewrite it.
    let aimed_at = home.join("someone-elses-file");
    fs::write(
        &aimed_at,
        format!(
            "{}
{}
",
            installed.display(),
            kendex_core::hash::sha256_hex(REPLACED)
        ),
    )
    .unwrap();
    let theirs = fs::read_to_string(&aimed_at).unwrap();
    std::os::unix::fs::symlink(&aimed_at, &file).unwrap();
    older_than_the_command(&file, &installed);

    kendex(&home, &["verify"]);

    assert_eq!(
        fs::read_to_string(&aimed_at).unwrap(),
        theirs,
        "the run wrote through a link at {}",
        file.display()
    );
}
