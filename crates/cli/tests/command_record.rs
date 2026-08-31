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
use std::path::Path;
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
/// because that run records the file it is running from. Until then the
/// app reads no record and refuses the command, which is the safe
/// direction.
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

/// An empty record is a name a claim published and never filled — the one
/// state a first run can leave behind, since `create_new` takes the name
/// before the bytes go in it. Nothing else would repair it: every later
/// run finds the name taken too, and the app refuses a command it does own
/// until `kendex update` rewrites the record. So the run that finds it
/// takes the name back.
#[test]
#[allow(clippy::unwrap_used)]
fn an_empty_record_is_repaired_by_the_next_first_run() {
    if no_record_on_this_runner() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = kendex_core::env::Env::host_rooted(&home);
    let file = env.installed_command_file();
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    // What a claim leaves when the write behind it never lands.
    fs::write(&file, "").unwrap();
    let ours = home.join("ours/kendex");
    fs::create_dir_all(ours.parent().unwrap()).unwrap();
    fs::write(&ours, b"the kendex that ran").unwrap();

    kendex_core::command_update::record_first_run(&env, &ours).unwrap();

    assert_eq!(
        kendex_core::command_update::recorded_command(&env).map(|record| record.path),
        Some(ours),
        "an empty record is nobody's, and the run that found it left it that way"
    );
}

/// Concurrent first runs both answer `Ok` and leave one readable record,
/// naming one of the two files that ran.
///
/// Not a proof of the ordering, and not what holds `create_new` either: a
/// writer that truncated and rewrote would pass this too, because each of
/// the two writes a whole line. What reds on that is
/// `a_record_already_there_is_not_written_over_by_a_first_run`, which has
/// a record it must leave alone. What is left here is the pair — two runs
/// starting together neither fail nor leave the record unreadable between
/// them.
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

    let recorded = kendex_core::command_update::recorded_command(&env).unwrap();
    assert!(
        recorded.path == theirs || recorded.path == second,
        "the record names {}",
        recorded.path.display()
    );
    assert_eq!(
        fs::read_to_string(env.installed_command_file()).unwrap(),
        format!("{}\n", recorded.path.display()),
        "the record holds more than the line the run that won wrote"
    );
    // Nothing writes a name like that today: this guards against a staged
    // write coming back, not against one a writer here makes.
    let beside: Vec<_> = fs::read_dir(env.installed_command_file().parent().unwrap())
        .unwrap()
        .filter_map(|entry| entry.ok().map(|entry| entry.file_name()))
        .filter(|name| name.to_string_lossy().starts_with("installed-command."))
        .collect();
    assert!(
        beside.is_empty(),
        "files left beside the record: {beside:?}"
    );
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
    kendex_core::command_update::record_command(&env, &theirs).unwrap();

    kendex(&home, &["verify"]);

    assert_eq!(
        kendex_core::command_update::recorded_command(&env).map(|record| record.path),
        Some(theirs),
        "a run repointed a record it did not write"
    );
}

/// The record a run writes is the one `XDG_DATA_HOME` names rather than the
/// one under `HOME`. The withdrawn fix carried `HOME` onto a `sudo` line and
/// so was correct only for people who do not set this; a record written by
/// the person's own run reads their own variable.
///
/// Linux alone: `XDG_DATA_HOME` is the layout `dirs` reads there, and the
/// macOS layout has no such variable to honour.
#[test]
#[cfg(target_os = "linux")]
#[allow(clippy::unwrap_used)]
fn the_record_a_run_writes_is_the_one_xdg_data_home_names() {
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

    kendex_with(&home, &[("XDG_DATA_HOME", &data_home)], &["verify"]);

    assert_eq!(
        kendex_core::command_update::recorded_command(&env).map(|record| record.path),
        Some(std::fs::canonicalize(env!("CARGO_BIN_EXE_kendex")).unwrap()),
        "the run wrote to a data directory other than the one it was given"
    );
    assert!(
        !kendex_core::env::Env::host_rooted(&home)
            .installed_command_file()
            .exists(),
        "the run wrote a second record under HOME, so the assertion above proves nothing"
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
/// through it lands on the file at the other end. A first run creates the
/// record rather than writing it, so the name is already taken and the
/// file it points at is left alone.
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
    let aimed_at = home.join("someone-elses-file");
    let theirs = "whatever they keep here\n";
    fs::write(&aimed_at, theirs).unwrap();
    std::os::unix::fs::symlink(&aimed_at, &file).unwrap();

    kendex(&home, &["verify"]);

    assert_eq!(
        fs::read_to_string(&aimed_at).unwrap(),
        theirs,
        "the run wrote through a link at {}",
        file.display()
    );
}
