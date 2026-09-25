//! What the trash keeps and what it lets go: the two bounds, the entries
//! this invocation wrote, the person's own emptying, and the one writer
//! every removal lands through.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use super::*;
use crate::env::FakeOs;
use crate::test_util::rooted;

const DAY: u64 = 86_400;

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
}

fn fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(rooted(&tmp), FakeOs::Linux);
    Fixture { _tmp: tmp, env }
}

/// A fixture reading these two bounds; an empty string is the variable
/// exported empty.
fn bounded(days: &str, mb: &str) -> Fixture {
    let mut f = fixture();
    f.env = f
        .env
        .clone()
        .with_var(KEEP_DAYS_VAR, days)
        .with_var(KEEP_MB_VAR, mb);
    f
}

/// An entry moved into the trash `age` seconds ago under `base`, holding
/// one file of `bytes` bytes, as an earlier invocation left it.
fn plant(f: &Fixture, age: u64, base: &str, bytes: usize) -> PathBuf {
    let stamp = clock::iso_from_unix(clock::unix_now() - age).replace(':', "-");
    let entry = f.env.trash_dir().join(format!("{stamp}-{base}"));
    fs::create_dir_all(&entry).unwrap();
    fs::write(entry.join("blob"), vec![b'x'; bytes]).unwrap();
    entry
}

/// Every name the trash directory holds but the size record's.
fn names(f: &Fixture) -> BTreeSet<String> {
    match fs::read_dir(f.env.trash_dir()) {
        Ok(listing) => listing
            .flatten()
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .filter(|name| name != SIZES_FILE)
            .collect(),
        Err(_) => BTreeSet::new(),
    }
}

/// The size record as the trash holds it, by entry name.
fn recorded(f: &Fixture) -> BTreeMap<String, u64> {
    let text = fs::read_to_string(f.env.trash_dir().join(SIZES_FILE)).unwrap();
    serde_json::from_str(&text).unwrap()
}

fn name_of(path: &Path) -> String {
    path.file_name().unwrap().to_string_lossy().into_owned()
}

/// The age bound alone: with the size bound out of reach, every entry
/// older than the count of days goes and every younger one stays.
#[test]
fn entries_past_the_age_bound_go_and_the_rest_stay() {
    let f = bounded("7", "1024");
    let young = plant(&f, DAY, "a", 10);
    let week = plant(&f, 6 * DAY, "b", 10);
    plant(&f, 8 * DAY, "c", 10);
    plant(&f, 30 * DAY, "d", 10);

    assert_eq!(retain(&f.env), Ok(2));
    assert_eq!(names(&f), BTreeSet::from([name_of(&young), name_of(&week)]));
}

/// The size bound alone, newest first: the entry that takes the running
/// total past the bound goes, and every older one with it, however small
/// and however far inside the age bound.
#[test]
fn entries_past_the_size_bound_go_oldest_first() {
    let f = bounded("365", "1");
    let quarter = 300 * 1024;
    let newest = plant(&f, DAY, "a", quarter);
    let second = plant(&f, 2 * DAY, "b", quarter);
    let third = plant(&f, 3 * DAY, "c", quarter);
    plant(&f, 4 * DAY, "d", quarter);
    plant(&f, 5 * DAY, "e", 10);

    assert_eq!(retain(&f.env), Ok(2));
    assert_eq!(
        names(&f),
        BTreeSet::from([name_of(&newest), name_of(&second), name_of(&third)])
    );
    // The crossing entry was measured and then went, and its record
    // with it; what went unmeasured was never recorded.
    assert_eq!(
        recorded(&f),
        BTreeMap::from([
            (name_of(&newest), quarter as u64),
            (name_of(&second), quarter as u64),
            (name_of(&third), quarter as u64),
        ])
    );
}

/// An entry is walked once in its lifetime: the pass that first needs
/// its size records it, held or not, and every later pass reads the
/// record instead, so an entry that will no longer read is still judged.
/// The listing measures fresh and stops on it. A pass that learned
/// nothing writes nothing: the record file is the same file afterwards.
#[cfg(unix)]
#[test]
fn an_entry_is_measured_once_in_its_lifetime() {
    use std::os::unix::fs::MetadataExt as _;
    use std::os::unix::fs::PermissionsExt as _;
    if crate::test_util::no_record_on_this_runner() {
        return;
    }
    let f = bounded("7", "1024");
    let planted = plant(&f, DAY, "planted", 10);
    let removed = f._tmp.path().join("removed");
    fs::create_dir_all(&removed).unwrap();
    fs::write(removed.join("blob"), vec![b'x'; 20]).unwrap();
    move_to_trash(&f.env, &removed).unwrap();
    let held = f.env.held().trashed.into_iter().next().unwrap();

    assert_eq!(retain(&f.env), Ok(0));
    assert_eq!(
        recorded(&f),
        BTreeMap::from([(name_of(&planted), 10), (name_of(&held), 20)])
    );
    let record = f.env.trash_dir().join(SIZES_FILE);
    let written = fs::metadata(&record).unwrap().ino();
    let locked = [planted.join("locked"), held.join("locked")];
    for dir in &locked {
        fs::create_dir_all(dir).unwrap();
        fs::set_permissions(dir, fs::Permissions::from_mode(0o000)).unwrap();
    }

    let next = f.env.next_invocation();
    let outcome = retain(&next);
    let listed = list(&next);
    for dir in &locked {
        fs::set_permissions(dir, fs::Permissions::from_mode(0o755)).unwrap();
    }
    assert_eq!(outcome, Ok(0));
    assert_eq!(fs::metadata(&record).unwrap().ino(), written);
    let Err(reason) = listed else {
        panic!("{listed:?}");
    };
    assert!(reason.contains("locked"), "{reason}");
}

/// A record follows the listing: an entry the pass removes, or one
/// taken out by hand, loses its row on the next write, and a row is
/// never written for an entry the pass did not measure.
#[test]
fn the_record_holds_only_the_entries_the_trash_holds() {
    let f = bounded("7", "1024");
    let young = plant(&f, DAY, "young", 10);
    plant(&f, 40 * DAY, "aged", 10);

    assert_eq!(retain(&f.env), Ok(1));
    assert_eq!(recorded(&f), BTreeMap::from([(name_of(&young), 10)]));

    fs::remove_dir_all(&young).unwrap();
    let later = plant(&f, 2 * DAY, "later", 30);
    assert_eq!(retain(&f.env.next_invocation()), Ok(0));
    assert_eq!(recorded(&f), BTreeMap::from([(name_of(&later), 30)]));
}

/// A record that does not parse is not an empty record: the pass stops
/// before it removes anything and names the file.
#[test]
fn a_record_that_will_not_parse_stops_the_pass_with_everything_intact() {
    let f = bounded("7", "1024");
    plant(&f, 40 * DAY, "aged", 10);
    let record = f.env.trash_dir().join(SIZES_FILE);
    fs::write(&record, "{\"half").unwrap();

    let Err(Stopped { removed, reason }) = retain(&f.env) else {
        panic!("a torn record was read");
    };
    assert_eq!(removed, 0);
    assert!(reason.contains(&record.display().to_string()), "{reason}");
    assert_eq!(names(&f).len(), 1);
}

/// What this invocation wrote is kept and still counted: its bytes fill
/// the bound, and a younger entry nobody holds goes to make room.
#[test]
fn a_held_entrys_bytes_count_toward_the_bound() {
    let f = bounded("365", "1");
    let small = plant(&f, DAY, "small", 300 * 1024);
    let removed = f._tmp.path().join("removed");
    fs::create_dir_all(&removed).unwrap();
    fs::write(removed.join("blob"), vec![b'x'; 900 * 1024]).unwrap();
    move_to_trash(&f.env, &removed).unwrap();

    assert_eq!(retain(&f.env), Ok(1));
    let kept = names(&f);
    assert!(!kept.contains(&name_of(&small)), "{kept:?}");
    assert_eq!(kept.len(), 1, "{kept:?}");
}

/// What this invocation moved to the trash is never a candidate, however
/// far past the bounds it is; the next invocation's pass judges it like
/// any other entry.
#[test]
fn an_entry_this_invocation_wrote_survives_its_pass() {
    let f = bounded("365", "0");
    plant(&f, DAY, "old", 10);
    let removed = f._tmp.path().join("removed");
    fs::create_dir_all(&removed).unwrap();
    fs::write(removed.join("file"), "bytes").unwrap();
    move_to_trash(&f.env, &removed).unwrap();

    assert_eq!(retain(&f.env), Ok(1));
    let kept = names(&f);
    assert_eq!(kept.len(), 1, "{kept:?}");
    assert!(
        kept.iter().all(|name| name.ends_with("-removed")),
        "{kept:?}"
    );

    let next = f.env.next_invocation();
    assert_eq!(retain(&next), Ok(1));
    assert!(names(&f).is_empty());
}

/// A bound that is not a count stops the pass before it removes
/// anything and says which variable it could not read.
#[test]
fn a_setting_that_is_not_a_count_stops_the_pass_with_everything_intact() {
    let rows: [(&str, &str, &str); 8] = [
        ("x", "512", KEEP_DAYS_VAR),
        ("-1", "512", KEEP_DAYS_VAR),
        ("1.5", "512", KEEP_DAYS_VAR),
        ("3 days", "512", KEEP_DAYS_VAR),
        ("30", "lots", KEEP_MB_VAR),
        ("30", "-5", KEEP_MB_VAR),
        ("30", "0.5", KEEP_MB_VAR),
        ("30", "512MB", KEEP_MB_VAR),
    ];
    for (days, mb, refused) in rows {
        let f = bounded(days, mb);
        plant(&f, 400 * DAY, "old", 2 * 1024 * 1024);
        let before = names(&f);

        let Err(Stopped { removed, reason }) = retain(&f.env) else {
            panic!("{days:?}/{mb:?} was read as a bound");
        };
        assert_eq!(removed, 0, "{days:?}/{mb:?}");
        assert!(reason.contains(refused), "{days:?}/{mb:?}: {reason}");
        assert_eq!(names(&f), before, "{days:?}/{mb:?}");
    }
}

/// A variable exported empty, or as whitespace, reads as unset: the
/// default bounds apply.
#[test]
fn a_setting_exported_empty_reads_as_the_default() {
    for (days, mb) in [("", ""), (" ", "\t")] {
        let f = bounded(days, mb);
        let young = plant(&f, DAY, "a", 10);
        plant(&f, (DEFAULT_KEEP_DAYS + 1) * DAY, "b", 10);

        assert_eq!(retain(&f.env), Ok(1), "{days:?}");
        assert_eq!(names(&f), BTreeSet::from([name_of(&young)]), "{days:?}");
    }
}

/// A removal that fails stops the pass where it is and reports the
/// entries that went before it; the entries after it stay.
#[cfg(unix)]
#[test]
fn a_removal_that_fails_stops_the_pass_and_reports_what_went_before() {
    use std::os::unix::fs::PermissionsExt as _;
    if crate::test_util::no_record_on_this_runner() {
        return;
    }
    let f = bounded("7", "1024");
    plant(&f, 10 * DAY, "first", 10);
    let stuck = plant(&f, 20 * DAY, "stuck", 10);
    let after = plant(&f, 30 * DAY, "after", 10);
    // A directory nothing may write in cannot lose the file it holds.
    fs::set_permissions(&stuck, fs::Permissions::from_mode(0o555)).unwrap();

    let outcome = retain(&f.env);
    fs::set_permissions(&stuck, fs::Permissions::from_mode(0o755)).unwrap();
    let Err(Stopped { removed, reason }) = outcome else {
        panic!("{outcome:?}");
    };
    assert_eq!(removed, 1);
    assert!(reason.contains("stuck"), "{reason}");
    assert_eq!(
        names(&f),
        BTreeSet::from([name_of(&stuck), name_of(&after)])
    );
}

/// An entry that will not measure stops the pass where it is, with
/// nothing removed and the unreadable path named, and stops the listing
/// the same way: a size left out would read as a trash smaller than it
/// is. A held entry is measured too, so one that will not measure stops
/// the pass just the same.
#[cfg(unix)]
#[test]
fn an_entry_that_will_not_measure_stops_the_pass_and_the_listing() {
    use std::os::unix::fs::PermissionsExt as _;
    if crate::test_util::no_record_on_this_runner() {
        return;
    }
    for held in [false, true] {
        let f = bounded("7", "1024");
        let readable = plant(&f, DAY, "readable", 10);
        plant(&f, 40 * DAY, "aged", 10);
        let sealed = match held {
            false => plant(&f, 2 * DAY, "sealed", 10),
            true => {
                let removed = f._tmp.path().join("sealed");
                fs::create_dir_all(&removed).unwrap();
                move_to_trash(&f.env, &removed).unwrap();
                f.env.held().trashed.into_iter().next().unwrap()
            }
        };
        let locked = sealed.join("locked");
        fs::create_dir_all(&locked).unwrap();
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).unwrap();

        let outcome = retain(&f.env);
        let listed = list(&f.env);
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o755)).unwrap();
        let Err(Stopped { removed, reason }) = outcome else {
            panic!("held={held}: {outcome:?}");
        };
        assert_eq!(removed, 0, "held={held}");
        assert!(
            reason.contains(&locked.display().to_string()),
            "held={held}: {reason}"
        );
        let kept = names(&f);
        assert_eq!(kept.len(), 3, "held={held}: {kept:?}");
        assert!(kept.contains(&name_of(&readable)), "held={held}: {kept:?}");
        let Err(reason) = listed else {
            panic!("held={held}: {listed:?}");
        };
        assert!(
            reason.contains(&locked.display().to_string()),
            "held={held}: {reason}"
        );
    }
}

/// A trash that will not read is not an empty trash: the pass stops and
/// names it.
#[cfg(unix)]
#[test]
fn a_trash_that_will_not_read_stops_the_pass() {
    use std::os::unix::fs::PermissionsExt as _;
    if crate::test_util::no_record_on_this_runner() {
        return;
    }
    let f = bounded("7", "1024");
    plant(&f, 30 * DAY, "old", 10);
    let trash = f.env.trash_dir();
    fs::set_permissions(&trash, fs::Permissions::from_mode(0o000)).unwrap();

    let outcome = retain(&f.env);
    fs::set_permissions(&trash, fs::Permissions::from_mode(0o755)).unwrap();
    let Err(Stopped { removed, reason }) = outcome else {
        panic!("{outcome:?}");
    };
    assert_eq!(removed, 0);
    assert!(reason.contains(&trash.display().to_string()), "{reason}");
    assert_eq!(names(&f).len(), 1);
}

/// The person's own request: everything, or everything past an age, and
/// never what this invocation wrote.
#[test]
fn empty_takes_every_entry_or_every_entry_past_an_age() {
    let f = fixture();
    let day = plant(&f, DAY, "a", 10);
    let five = plant(&f, 5 * DAY, "b", 10);
    plant(&f, 10 * DAY, "c", 10);
    let removed = f._tmp.path().join("removed");
    fs::create_dir_all(&removed).unwrap();
    move_to_trash(&f.env, &removed).unwrap();

    assert_eq!(empty(&f.env, Some(Duration::from_secs(7 * DAY))), Ok(1));
    let mut kept = names(&f);
    assert!(kept.remove(&name_of(&day)), "{kept:?}");
    assert!(kept.remove(&name_of(&five)), "{kept:?}");
    assert_eq!(kept.len(), 1, "{kept:?}");

    assert_eq!(empty(&f.env, None), Ok(2));
    let kept = names(&f);
    assert_eq!(kept.len(), 1, "{kept:?}");
    assert!(
        kept.iter().all(|name| name.ends_with("-removed")),
        "{kept:?}"
    );
}

/// An emptying goes oldest first, so one that stops leaves the newest
/// entries, the ones a person is most likely to want back.
#[cfg(unix)]
#[test]
fn an_empty_that_stops_leaves_the_newest_entries() {
    use std::os::unix::fs::PermissionsExt as _;
    if crate::test_util::no_record_on_this_runner() {
        return;
    }
    let f = fixture();
    let newest = plant(&f, DAY, "newest", 10);
    let stuck = plant(&f, 2 * DAY, "stuck", 10);
    plant(&f, 3 * DAY, "oldest", 10);
    // A directory nothing may write in cannot lose the file it holds.
    fs::set_permissions(&stuck, fs::Permissions::from_mode(0o555)).unwrap();

    let outcome = empty(&f.env, None);
    fs::set_permissions(&stuck, fs::Permissions::from_mode(0o755)).unwrap();
    let Err(Stopped { removed, reason }) = outcome else {
        panic!("{outcome:?}");
    };
    assert_eq!(removed, 1);
    assert!(reason.contains("stuck"), "{reason}");
    assert_eq!(
        names(&f),
        BTreeSet::from([name_of(&newest), name_of(&stuck)])
    );
}

/// The listing: newest first, each entry's age and the bytes it holds,
/// and a name that carries no stamp is not kendex's and is left off.
#[test]
fn a_listing_reports_name_age_and_bytes_newest_first() {
    let f = fixture();
    let old = plant(&f, 3 * DAY, "old", 1500);
    let young = plant(&f, DAY, "young", 20);
    fs::create_dir_all(f.env.trash_dir().join("not-kendex")).unwrap();

    let listed = list(&f.env).unwrap();
    assert_eq!(listed.len(), 2, "{listed:?}");
    assert_eq!(listed[0].name, name_of(&young));
    assert_eq!(listed[0].bytes, 20);
    assert!((DAY..DAY + 60).contains(&listed[0].age_secs), "{listed:?}");
    assert_eq!(listed[1].name, name_of(&old));
    assert_eq!(listed[1].bytes, 1500);
    assert!(
        (3 * DAY..3 * DAY + 60).contains(&listed[1].age_secs),
        "{listed:?}"
    );

    assert_eq!(retain(&f.env), Ok(0));
    assert!(names(&f).contains("not-kendex"));
}

/// Files under an entry are summed, a link counts as itself and is never
/// read through, and a lone file is its own length.
#[cfg(unix)]
#[test]
fn bytes_under_counts_files_and_links_as_themselves() {
    let f = fixture();
    let outside = f._tmp.path().join("outside");
    fs::write(&outside, vec![b'x'; 4096]).unwrap();
    let entry = plant(&f, DAY, "tree", 100);
    fs::create_dir_all(entry.join("sub/deeper")).unwrap();
    fs::write(entry.join("sub/deeper/file"), vec![b'y'; 50]).unwrap();
    std::os::unix::fs::symlink(&outside, entry.join("link")).unwrap();

    let link_len = fs::symlink_metadata(entry.join("link")).unwrap().len();
    assert_eq!(bytes_under(&entry).unwrap(), 150 + link_len);
    assert_eq!(bytes_under(&outside).unwrap(), 4096);
}

/// No trash directory is a trash that holds nothing.
#[test]
fn an_absent_trash_holds_nothing() {
    let f = fixture();
    assert_eq!(retain(&f.env), Ok(0));
    assert_eq!(empty(&f.env, None), Ok(0));
    assert!(list(&f.env).unwrap().is_empty());
    assert!(!f.env.trash_dir().exists());
}

/// The stamp a name opens with is read back as the second it names; a
/// name with none, or with a stamp that is not a moment, is not an entry.
#[test]
fn a_name_is_dated_by_the_stamp_it_opens_with() {
    let at = 1_789_000_000;
    let stamp = clock::iso_from_unix(at).replace(':', "-");
    assert_eq!(trashed_at(&format!("{stamp}-skill")), Some(at));
    assert_eq!(trashed_at(&format!("{stamp}-2-skill")), Some(at));
    for name in [
        "",
        "skill",
        "2026-09-14T11-26-54Z",
        "2026-09-14T11-26-54Zskill",
        "2026-09-14 11-26-54Z-skill",
        "2026-13-14T11-26-54Z-skill",
        "2026-09-14T11:26:54Z-skill",
        "2026-09-14T11-26-54X-skill",
        "not-a-stamp-at-all-xx-skill",
    ] {
        assert_eq!(trashed_at(name), None, "{name:?}");
    }
}

/// A name a dangling link holds is a name that is taken, and `exists`
/// says it is free. What the move onto it then does depends on the
/// shape: a directory is refused (ENOTDIR from rename, then EEXIST
/// from the copy) and the uninstall aborts, while anything else is
/// renamed straight over the link and the trash loses what it held.
/// The guard is for both. Both seconds the call can land in are
/// seeded, so the clock cannot decide which name it reaches for.
#[cfg(unix)]
#[test]
fn a_trash_name_a_dangling_link_holds_is_not_taken() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(rooted(&tmp), FakeOs::Linux);
    let dir = env.trash_dir();
    std::fs::create_dir_all(&dir).unwrap();
    let now = crate::clock::unix_now();
    let held: Vec<PathBuf> = [now, now + 1]
        .iter()
        .map(|secs| {
            let stamp = crate::clock::iso_from_unix(*secs).replace(':', "-");
            dir.join(format!("{stamp}-pi-hooks"))
        })
        .collect();
    for name in &held {
        std::os::unix::fs::symlink(tmp.path().join("gone"), name).unwrap();
    }
    let package = tmp.path().join("pi-hooks");
    std::fs::create_dir_all(&package).unwrap();
    std::fs::write(package.join("package.json"), "{}").unwrap();

    move_to_trash(&env, &package).unwrap();

    assert!(!package.exists());
    for name in &held {
        assert!(name.is_symlink(), "{} was taken", name.display());
    }
    let landed: Vec<PathBuf> = std::fs::read_dir(&dir)
        .unwrap()
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.join("package.json").is_file())
        .collect();
    assert_eq!(landed.len(), 1, "{landed:?}");
    // Somewhere other than the two names that were already taken —
    // which counter it got is the clock's business, not this test's.
    assert!(!held.contains(&landed[0]), "{:?}", landed[0]);
}

/// The installed copy replaced by a link whose target is gone, with the
/// trash on another mount so the move is made by hand rather than by
/// rename. Read through, the copy fails with the target's ENOENT and
/// the uninstall aborts on it. /dev/shm is the second mount; a machine
/// that does not have it as one has nothing to prove here.
#[cfg(target_os = "linux")]
#[test]
fn a_copy_that_is_a_link_crosses_a_mount_into_the_trash() {
    use std::os::unix::fs::MetadataExt as _;
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(rooted(&tmp), FakeOs::Linux);
    let Ok(elsewhere) = tempfile::tempdir_in("/dev/shm") else {
        return;
    };
    let (Ok(here), Ok(there)) = (
        std::fs::metadata(tmp.path()).map(|m| m.dev()),
        std::fs::metadata(elsewhere.path()).map(|m| m.dev()),
    ) else {
        return;
    };
    if here == there {
        return;
    }
    let installed = elsewhere.path().join("pi-hooks");
    let gone = elsewhere.path().join("gone");
    std::os::unix::fs::symlink(&gone, &installed).unwrap();

    move_to_trash(&env, &installed).unwrap();

    assert!(!installed.is_symlink());
    let held = std::fs::read_dir(env.trash_dir())
        .unwrap()
        .flatten()
        .next()
        .unwrap()
        .path();
    assert_eq!(std::fs::read_link(held).unwrap(), gone);
}
