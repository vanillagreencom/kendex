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
/// path before anything opened it, asked here of the handle itself. The
/// pipe is the one that matters twice: refused, and refused without the
/// open being able to hold the apply still.
#[test]
fn nothing_but_a_regular_file_gets_through() {
    let (tmp, _, _) = fixture();
    let pre = Pre::PlainHashIs {
        hash: "whatever".to_owned(),
    };

    let dir = tmp.path().join("a-directory");
    fs::create_dir(&dir).unwrap();
    assert!(open(&dir, &pre).is_err(), "a directory must not open");

    let pipe = tmp.path().join("a-pipe");
    assert_eq!(
        rustix::fs::mknodat(
            rustix::fs::CWD,
            &pipe,
            rustix::fs::FileType::Fifo,
            rustix::fs::Mode::RUSR | rustix::fs::Mode::WUSR,
            0,
        )
        .map(|()| ()),
        Ok(())
    );
    assert!(
        matches!(open(&pipe, &pre), Err(CoreError::PlanStale { .. })),
        "a pipe must be refused, and the open must not block on it"
    );
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
