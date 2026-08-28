#![cfg(unix)]

use std::fs;

use super::*;
use crate::base::Base;

fn fixture() -> (tempfile::TempDir, std::path::PathBuf, std::path::PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("kendex.settings.toml");
    let elsewhere = tmp.path().join("elsewhere.toml");
    (tmp, path, elsewhere)
}

fn link_over(path: &Path, target: &Path) {
    fs::remove_file(path).unwrap();
    std::os::unix::fs::symlink(target, path).unwrap();
}

/// The race, made deterministic: the swap happens between the check and
/// the write, which is the window a precondition cannot cover on its own.
///
/// The first half is the hole, run as it used to be — check passes, the
/// name becomes a link, `fs::write` follows it, and the bytes land in a
/// file outside the place kendex was asked to manage. The second half is
/// the same swap against a handle that was opened once: the bytes go to
/// the inode the check proved, and the file at the end of the link is
/// untouched.
///
/// What this proves: the write cannot follow a link that arrives after
/// the check. What it does not prove: that no window exists in the
/// scheduler between two real syscalls — nothing at this level can, and
/// the point is that there is no longer a name resolution to lose.
#[test]
fn a_swap_between_the_check_and_the_write_cannot_move_the_bytes() {
    // Check-then-write, the shape this replaces.
    let (_tmp, path, elsewhere) = fixture();
    fs::write(&path, "[env]\n").unwrap();
    fs::write(&elsewhere, "someone else's file\n").unwrap();
    let pre = Base::of("[env]\n").plain_pre();
    pre.check(&path).unwrap();
    link_over(&path, &elsewhere);
    fs::write(&path, "written").unwrap();
    assert_eq!(
        fs::read_to_string(&elsewhere).unwrap(),
        "written",
        "the hole: a following write lands at the other end of the link"
    );

    // One handle, same swap.
    let (_tmp, path, elsewhere) = fixture();
    fs::write(&path, "[env]\n").unwrap();
    fs::write(&elsewhere, "someone else's file\n").unwrap();
    let pre = Base::of("[env]\n").plain_pre();
    let plain = open(&path, &pre).unwrap().expect("a plain precondition");
    link_over(&path, &elsewhere);
    plain.write(&path, b"written").unwrap();
    assert_eq!(
        fs::read_to_string(&elsewhere).unwrap(),
        "someone else's file\n",
        "the bytes must not reach the file the link points at"
    );
}

/// A link already at the name never opens at all.
#[test]
fn a_link_where_the_file_should_be_refuses_before_anything_is_read() {
    let (_tmp, path, elsewhere) = fixture();
    fs::write(&elsewhere, "[env]\n").unwrap();
    std::os::unix::fs::symlink(&elsewhere, &path).unwrap();

    let pre = Base::of("[env]\n").plain_pre();
    assert!(matches!(
        open(&path, &pre),
        Err(CoreError::PlanStale { .. })
    ));
    // Even though the bytes at the other end are exactly the ones the
    // base names — which is what a following check would have accepted.
    assert!(Pre::from(&Base::of("[env]\n")).check(&path).is_ok());
}

/// The absent half. Creating the file exclusively is the check, so a link
/// that arrives before the write is refused rather than followed.
#[test]
fn a_link_arriving_where_nothing_was_refuses_at_the_moment_of_the_write() {
    let (_tmp, path, elsewhere) = fixture();
    fs::write(&elsewhere, "someone else's file\n").unwrap();
    let plain = open(&path, &Base::absent().plain_pre())
        .unwrap()
        .expect("a plain precondition");
    std::os::unix::fs::symlink(&elsewhere, &path).unwrap();

    assert!(matches!(
        plain.write(&path, b"written"),
        Err(CoreError::PlanStale { .. })
    ));
    assert_eq!(
        fs::read_to_string(&elsewhere).unwrap(),
        "someone else's file\n"
    );
}

/// Nothing is created for a precondition that is never written through —
/// which is what lets an edit decide it changes nothing and leave the
/// place as it found it.
#[test]
fn an_absent_precondition_makes_no_file_until_the_write() {
    let (_tmp, path, _) = fixture();
    let plain = open(&path, &Base::absent().plain_pre()).unwrap();
    assert!(plain.is_some());
    assert!(!path.exists());
}

/// Content comes off the handle the check was made on, so an edit reads
/// what the precondition proved rather than the name a second time.
#[test]
fn the_content_is_read_through_the_handle_that_was_checked() {
    let (_tmp, path, _) = fixture();
    fs::write(&path, "[env]\nMODE = \"a\"\n").unwrap();
    let pre = Base::of("[env]\nMODE = \"a\"\n").plain_pre();
    let plain = open(&path, &pre).unwrap().expect("a plain precondition");
    assert_eq!(plain.content(), b"[env]\nMODE = \"a\"\n");
    plain.write(&path, b"[env]\nMODE = \"b\"\n").unwrap();
    assert_eq!(fs::read_to_string(&path).unwrap(), "[env]\nMODE = \"b\"\n");
}

/// Bytes that changed under the plan are refused, the way the following
/// check refuses them — the guarantee is added to, never traded away.
#[test]
fn content_that_moved_since_the_plan_still_refuses() {
    let (_tmp, path, _) = fixture();
    fs::write(&path, "[env]\n").unwrap();
    let pre = Base::of("[env]\n").plain_pre();
    fs::write(&path, "[env]\nsomeone else wrote this\n").unwrap();
    assert!(matches!(
        open(&path, &pre),
        Err(CoreError::PlanStale { .. })
    ));
}

/// The partition the op arms route on, pinned over every variant: a
/// `Plain*` precondition always takes the one-handle path, and no other
/// one ever does. The arms are a single match over this, so a write that
/// resolved the name twice for a `Plain*` precondition is unreachable
/// rather than merely absent — and a variant added later fails here
/// before it can quietly take the ordinary path.
///
/// `HashIs` staying on the ordinary path is deliberate: it follows a link
/// on purpose, because a settings file somebody linked themselves is
/// edited in place with the link kept.
#[test]
fn only_a_precondition_that_names_a_kind_takes_the_one_handle_path() {
    let (_tmp, path, _) = fixture();
    fs::write(&path, "[env]\n").unwrap();
    let every = [
        (Pre::Absent, false),
        (
            Pre::HashIs {
                hash: hash_of(&path),
            },
            false,
        ),
        (
            Pre::PlainHashIs {
                hash: hash_of(&path),
            },
            true,
        ),
        (Pre::PlainAbsent, true),
        (
            Pre::SymlinkTo {
                target: path.clone(),
            },
            false,
        ),
        (
            Pre::TreeIs {
                hash: hash_of(&path),
            },
            false,
        ),
        (Pre::Any, false),
    ];
    for (pre, one_handle) in every {
        let plain = match &pre {
            // The absent half only opens where nothing is there.
            Pre::PlainAbsent => open(&path.with_extension("gone"), &pre).unwrap(),
            _ => open(&path, &pre).unwrap(),
        };
        assert_eq!(plain.is_some(), one_handle, "{pre:?}");
    }
}

fn hash_of(path: &Path) -> String {
    crate::hash::hash_tree(path).unwrap()
}

/// Not a directory, pipe, socket or device — what `plain_tree` asked of a
/// path before anything opened it, asked here of the handle itself. A
/// socket and a directory carry the claim everywhere; the pipe carries a
/// second claim of its own, below.
#[test]
fn nothing_but_a_regular_file_gets_through() {
    let (tmp, _, _) = fixture();
    let pre = Pre::PlainHashIs {
        hash: "whatever".to_owned(),
    };

    let dir = tmp.path().join("a-directory");
    fs::create_dir(&dir).unwrap();
    assert!(
        matches!(open(&dir, &pre), Err(CoreError::PlanStale { .. })),
        "a directory must not open"
    );

    let socket = tmp.path().join("a-socket");
    std::os::unix::net::UnixListener::bind(&socket).unwrap();
    assert!(
        matches!(open(&socket, &pre), Err(CoreError::PlanStale { .. })),
        "a socket must not open"
    );
}

/// The pipe's own claim: refused, AND refused without the open being able
/// to hold the apply still, which is what `O_NONBLOCK` on the open is for.
///
/// Linux only because `rustix` exposes no `mknodat` on Apple targets and
/// there is no portable way to make a FIFO from `std`. The refusal itself
/// is covered everywhere by the socket and the directory above; what is
/// pinned only here is that the open does not block.
#[test]
#[cfg(target_os = "linux")]
fn a_pipe_is_refused_without_the_open_holding_the_apply() {
    let (tmp, _, _) = fixture();
    let pipe = tmp.path().join("a-pipe");
    rustix::fs::mknodat(
        rustix::fs::CWD,
        &pipe,
        rustix::fs::FileType::Fifo,
        rustix::fs::Mode::RUSR | rustix::fs::Mode::WUSR,
        0,
    )
    .unwrap();
    let pre = Pre::PlainHashIs {
        hash: "whatever".to_owned(),
    };
    assert!(matches!(
        open(&pipe, &pre),
        Err(CoreError::PlanStale { .. })
    ));
}

/// The cause a person is given is the one actually met. Re-plan and retry
/// is the way out of a stale plan and is useless against a permission, so
/// a read-only file must not be told to re-plan.
#[test]
fn a_permission_is_reported_as_itself_and_not_as_a_stale_plan() {
    use std::os::unix::fs::PermissionsExt;
    let (_tmp, path, _) = fixture();
    fs::write(&path, "[env]\n").unwrap();
    let pre = Base::of("[env]\n").plain_pre();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o444)).unwrap();

    // Running as root defeats the mode, and there is nothing to assert.
    if fs::OpenOptions::new().write(true).open(&path).is_ok() {
        return;
    }
    let Err(refused) = open(&path, &pre) else {
        panic!("a file this build cannot write must not open");
    };
    assert!(
        matches!(&refused, CoreError::Io { source, .. }
            if source.kind() == std::io::ErrorKind::PermissionDenied),
        "{refused:?}"
    );
    // And the shapes that DO mean the world moved keep saying so.
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
    fs::remove_file(&path).unwrap();
    assert!(matches!(
        open(&path, &pre),
        Err(CoreError::PlanStale { .. })
    ));
}

/// Bytes that are not UTF-8 refuse, exactly as `read_if_exists` refuses
/// them. Decoded lossily they would come back as U+FFFD and be written
/// over the bytes they replaced.
#[test]
fn content_that_is_not_utf8_refuses_rather_than_being_replaced() {
    let (_tmp, path, _) = fixture();
    let invalid = [b'a', 0xff, b'b'];
    fs::write(&path, invalid).unwrap();
    let pre = Pre::PlainHashIs {
        hash: crate::hash::hash_bytes(&invalid),
    };
    let plain = open(&path, &pre).unwrap().expect("a plain precondition");
    assert_eq!(plain.content(), invalid);

    let refused = plain.text(&path).unwrap_err();
    assert!(
        matches!(&refused, CoreError::Io { source, .. }
            if source.kind() == std::io::ErrorKind::InvalidData),
        "{refused:?}"
    );
    // What the fallback path does with the same bytes, so the two agree.
    assert!(crate::fs::read_if_exists(&path).is_err());
}

/// Truncating through the handle keeps the inode, so a file's mode and
/// the hard links to it survive a write as they did under `fs::write`.
#[test]
fn a_write_keeps_the_file_it_was_proved_on() {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    let (tmp, path, _) = fixture();
    fs::write(&path, "[env]\n").unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o640)).unwrap();
    let linked = tmp.path().join("also.toml");
    fs::hard_link(&path, &linked).unwrap();
    let before = fs::metadata(&path).unwrap().ino();

    let pre = Base::of("[env]\n").plain_pre();
    open(&path, &pre)
        .unwrap()
        .expect("a plain precondition")
        .write(&path, b"[env]\nMODE = \"x\"\n")
        .unwrap();

    let after = fs::metadata(&path).unwrap();
    assert_eq!(after.ino(), before, "the write must keep the inode");
    assert_eq!(after.permissions().mode() & 0o777, 0o640);
    assert_eq!(
        fs::read_to_string(&linked).unwrap(),
        "[env]\nMODE = \"x\"\n",
        "a hard link to the same inode sees the write"
    );
}

/// The parent is made only once the precondition holds, so a refused op
/// leaves no directory behind — the ordering the two-step path had.
#[test]
fn a_refused_write_leaves_no_directory_behind() {
    let (tmp, _, _) = fixture();
    let nested = tmp.path().join("not-yet/kendex.settings.toml");
    let pre = Base::of("[env]\n").plain_pre();
    assert!(open(&nested, &pre).is_err());
    assert!(!tmp.path().join("not-yet").exists());

    // And it IS made for a write that happens.
    open(&nested, &Base::absent().plain_pre())
        .unwrap()
        .expect("a plain precondition")
        .write(&nested, b"[env]\n")
        .unwrap();
    assert_eq!(fs::read_to_string(&nested).unwrap(), "[env]\n");
}

/// `PlanStale` is the rollback's proof that the failing op ran nothing,
/// so the absent half proves the name is free BEFORE it builds anything.
/// The exclusive create runs first; only a missing parent sends it back to
/// make one, and a failure after that is reported as a failure rather than
/// as a stale plan, because by then the op HAS mutated and a rollback that
/// skipped its paths would leave the directories behind.
///
/// Every refusal that can be constructed is one where nothing was made,
/// and each is checked for exactly that. The one that mutates and then
/// fails needs a writer to win the name inside the call, which no test can
/// schedule — it is closed by the ordering, not by a control.
#[test]
fn the_absent_half_refuses_before_it_makes_anything() {
    let (tmp, _, elsewhere) = fixture();
    let absent = Base::absent().plain_pre();

    // Somebody already holds the name.
    let taken = tmp.path().join("taken/kendex.settings.toml");
    fs::create_dir_all(taken.parent().unwrap()).unwrap();
    fs::write(&taken, "someone else\n").unwrap();
    let refused = open(&taken, &absent)
        .unwrap()
        .expect("a plain precondition")
        .write(&taken, b"[env]\n")
        .unwrap_err();
    assert!(
        matches!(refused, CoreError::PlanStale { .. }),
        "{refused:?}"
    );
    assert_eq!(fs::read_to_string(&taken).unwrap(), "someone else\n");

    // A dangling link holds it — exclusive creation refuses one too.
    let linked = tmp.path().join("linked/kendex.settings.toml");
    fs::create_dir_all(linked.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(elsewhere.join("nowhere"), &linked).unwrap();
    let refused = open(&linked, &absent)
        .unwrap()
        .expect("a plain precondition")
        .write(&linked, b"[env]\n")
        .unwrap_err();
    assert!(
        matches!(refused, CoreError::PlanStale { .. }),
        "{refused:?}"
    );

    // A parent that is a file, so no chain could be built here at all.
    let under_a_file = taken.join("beneath");
    let refused = open(&under_a_file, &absent)
        .unwrap()
        .expect("a plain precondition")
        .write(&under_a_file, b"[env]\n")
        .unwrap_err();
    assert!(
        matches!(refused, CoreError::PlanStale { .. }),
        "{refused:?}"
    );

    // Nothing above was built by a refusal.
    assert!(!tmp.path().join("not-built").exists());
    // And the write that is not refused does build its chain.
    let fresh = tmp.path().join("not-built/deeper/kendex.settings.toml");
    open(&fresh, &absent)
        .unwrap()
        .expect("a plain precondition")
        .write(&fresh, b"[env]\n")
        .unwrap();
    assert_eq!(fs::read_to_string(&fresh).unwrap(), "[env]\n");
}

/// The errnos a swap can produce, each meaning the thing at the path is
/// not the thing the plan looked at. A socket is the one that reaches a
/// live shape: `open(2)` refuses it, and reporting that as an ordinary
/// failure makes the rollback restore paths nothing touched.
#[test]
fn every_way_a_swap_shows_up_reads_as_a_stale_plan() {
    let (tmp, path, _) = fixture();
    fs::write(&path, "[env]\n").unwrap();
    let pre = Base::of("[env]\n").plain_pre();

    let socket = tmp.path().join("a-socket");
    std::os::unix::net::UnixListener::bind(&socket).unwrap();
    assert!(
        matches!(open(&socket, &pre), Err(CoreError::PlanStale { .. })),
        "a socket where the file was is the world moving, not a failure"
    );

    let dir = tmp.path().join("a-dir");
    fs::create_dir(&dir).unwrap();
    assert!(matches!(open(&dir, &pre), Err(CoreError::PlanStale { .. })));

    let under_a_file = path.join("beneath");
    assert!(matches!(
        open(&under_a_file, &pre),
        Err(CoreError::PlanStale { .. })
    ));
}
