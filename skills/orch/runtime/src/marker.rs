//! The launch record a lane's turn-end hook reads: the marker under the
//! checkout's common git directory (`lane-mail/<item in lower case>`,
//! holding the lane's root), the lane's own mailbox directory under its
//! root (`tmp/lane-mail/<item>`), the refresh record in the worktree's git
//! directory (`lane-refresh`) and the launch-fields record beside the marker
//! (`lane-launch/<item in lower case>.json`). This module owns their
//! spellings and the containment over them, so a hosted launch composing a
//! path for the provider and a local launch writing one land the record
//! where the hook reads it.

use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::host::{self, Place};
use agent_runtime::reading::Reading;

use crate::error::Result;

/// The bound on one `git rev-parse` of the lane's checkout.
const GIT_BOUND: Duration = Duration::from_secs(30);
/// The mailbox's context reading, kept across a resumed session only.
pub const CONTEXT_RECORD: &str = "context.json";

fn refused(key: &'static str, fields: &[(&str, &str)]) -> crate::Error {
    crate::Error::from(agent_runtime::Error::refused(key, fields))
}

/// The item as a path component: ASCII letters, digits, dot, underscore
/// and hyphen, never empty, `.` or `..`, the alphabet the hook composes the
/// marker's name in. A name outside it would name another path.
pub fn item_name(item: &str) -> Result<&str> {
    let plain = item
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'));
    if item.is_empty() || item == "." || item == ".." || !plain {
        return Err(refused("marker-item-invalid", &[("item", item)]));
    }
    Ok(item)
}

pub fn marker_path(common: &Path, item: &str) -> PathBuf {
    common.join("lane-mail").join(item.to_ascii_lowercase())
}

pub fn launch_path(common: &Path, item: &str) -> PathBuf {
    common
        .join("lane-launch")
        .join(format!("{}.json", item.to_ascii_lowercase()))
}

pub fn refresh_path(git_dir: &Path) -> PathBuf {
    git_dir.join("lane-refresh")
}

pub fn mailbox_path(root: &Path, item: &str) -> PathBuf {
    root.join("tmp").join("lane-mail").join(item)
}

/// The worktree git directory and the common git directory a linked
/// worktree's `.git` file names (`gitdir: <clone>/.git/worktrees/<name>`);
/// `None` for any other content, a checkout's own `.git` directory
/// included, since neither names a path a remote caller can use.
pub fn git_dirs_of(gitfile: &str) -> Option<(PathBuf, PathBuf)> {
    let git_dir = gitfile.trim_end_matches('\n').strip_prefix("gitdir: /")?;
    let git_dir = format!("/{git_dir}");
    let common = git_dir.rsplit_once("/worktrees/")?.0;
    if !common.ends_with("/.git") {
        return None;
    }
    Some((PathBuf::from(&git_dir), PathBuf::from(common)))
}

/// The directories git names for a checkout: its root, its own git
/// directory and the common one.
pub struct Checkout {
    pub root: PathBuf,
    pub git_dir: PathBuf,
    pub common: PathBuf,
}

/// Where the record of a launch into `worktree` belongs, read from git;
/// a checkout git cannot answer for is refused by its cause.
#[allow(
    clippy::disallowed_methods,
    reason = "the marker's one read of the lane's checkout roots, `git rev-parse` through the one runner; it acts on nothing"
)]
pub fn checkout(worktree: &Path) -> Result<Checkout> {
    let dir = worktree.display().to_string();
    let out = host::run_tagged_in(
        "launch",
        "git",
        Path::new("git"),
        "rev-parse",
        &[
            "-C",
            &dir,
            "rev-parse",
            "--path-format=absolute",
            "--show-toplevel",
            "--absolute-git-dir",
            "--git-common-dir",
        ],
        Place {
            cwd: None,
            env: &[],
        },
        GIT_BOUND,
    )
    .map_err(|e| refused("marker-git-failed", &[("cause", &e.to_string())]))?;
    if !out.status.success() {
        let cause = host::stderr_text(&out);
        return Err(refused(
            "marker-git-failed",
            &[("cause", cause.lines().next().unwrap_or(""))],
        ));
    }
    let text = host::stdout_text(&out);
    let mut lines = text.lines();
    match (lines.next(), lines.next(), lines.next()) {
        (Some(root), Some(git_dir), Some(common)) => Ok(Checkout {
            root: PathBuf::from(root),
            git_dir: PathBuf::from(git_dir),
            common: PathBuf::from(common),
        }),
        _ => Err(refused(
            "marker-git-failed",
            &[("cause", "rev-parse-short")],
        )),
    }
}

/// What a component of the record may be before anything is written: a
/// directory or nothing, a plain file or nothing, never a link, so a
/// launch never writes through a path a peer put there.
#[derive(Clone, Copy)]
enum Kind {
    Dir,
    File,
}

fn contained(path: &Path, kind: Kind) -> Result<()> {
    let unsafe_path = || refused("marker-unsafe", &[("path", &path.display().to_string())]);
    match std::fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_symlink() => Err(unsafe_path()),
        Ok(meta) => match kind {
            Kind::Dir if meta.is_dir() => Ok(()),
            Kind::File if meta.is_file() => Ok(()),
            Kind::Dir | Kind::File => Err(unsafe_path()),
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(refused(
            "marker-unreadable",
            &[
                ("path", &path.display().to_string()),
                ("cause", &e.to_string()),
            ],
        )),
    }
}

/// The resumed session whose context reading the mailbox keeps: the
/// harness word and the session id as the mailbox records them.
pub struct Resumed<'a> {
    pub harness: &'a str,
    pub session_id: &'a str,
}

/// Write the launch record for `item` into `worktree`: the marker holding
/// the root, the mailbox directory, the refresh record for a refresh lane
/// (removed otherwise, so a relaunch states it again), the launch-fields
/// record removed (a local launch has none), and the mailbox's context
/// reading kept only across the session `resumed` names. Every component
/// is judged before anything is made, so a refusal leaves the tree as it
/// was; `tmp` itself may be a link, since a worktree setup links it.
#[allow(
    clippy::disallowed_methods,
    reason = "the launch record's writer: the marker, the mailbox directory and the refresh record, written before the window the hook will judge opens"
)]
pub fn write(worktree: &Path, item: &str, refresh: bool, resumed: Option<Resumed>) -> Result<()> {
    let item = item_name(item)?;
    let Checkout {
        root,
        git_dir,
        common,
    } = checkout(worktree)?;
    let marker = marker_path(&common, item);
    let launch = launch_path(&common, item);
    let refresh_record = refresh_path(&git_dir);
    let mailbox = mailbox_path(&root, item);
    for dir in [
        common.join("lane-mail"),
        common.join("lane-launch"),
        root.join("tmp").join("lane-mail"),
        mailbox.clone(),
    ] {
        contained(&dir, Kind::Dir)?;
    }
    for file in [&marker, &refresh_record, &launch] {
        contained(file, Kind::File)?;
    }
    let write_failed = |path: &Path, e: &dyn std::fmt::Display| {
        refused(
            "marker-write-failed",
            &[
                ("path", &path.display().to_string()),
                ("cause", &e.to_string()),
            ],
        )
    };
    for dir in [common.join("lane-mail"), mailbox.clone()] {
        std::fs::create_dir_all(&dir).map_err(|e| write_failed(&dir, &e))?;
    }
    let context = mailbox.join(CONTEXT_RECORD);
    if !context_kept(&context, resumed)? {
        remove(&context)?;
    }
    let root_line = format!("{}\n", root.display());
    replace(&marker, root_line.as_bytes())?;
    remove(&launch)?;
    if refresh {
        replace(&refresh_record, root_line.as_bytes())?;
    } else {
        remove(&refresh_record)?;
    }
    Ok(())
}

/// Whether the context reading at `context` is the resumed session's own:
/// its `harness` and `session_id` equal the resumed identity. A reading
/// that cannot be read refuses, since the launch cannot decide what the
/// lane continues from.
#[allow(
    clippy::disallowed_methods,
    reason = "the context record is read by its path, three-valued: absent is nothing to keep"
)]
fn context_kept(context: &Path, resumed: Option<Resumed>) -> Result<bool> {
    let Some(resumed) = resumed else {
        return Ok(false);
    };
    let text = match std::fs::symlink_metadata(context) {
        Ok(meta) if meta.file_type().is_symlink() || !meta.is_file() => return Ok(false),
        Ok(_) => std::fs::read_to_string(context),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(e) => Err(e),
    }
    .map_err(|e| {
        refused(
            "marker-context-unreadable",
            &[
                ("path", &context.display().to_string()),
                ("cause", &e.to_string()),
            ],
        )
    })?;
    let value: serde_json::Value = match serde_json::from_str(&text) {
        Ok(value) => value,
        Err(e) => {
            return Err(refused(
                "marker-context-unreadable",
                &[
                    ("path", &context.display().to_string()),
                    ("cause", &e.to_string()),
                ],
            ));
        }
    };
    Ok(
        value.get("harness").and_then(serde_json::Value::as_str) == Some(resumed.harness)
            && value.get("session_id").and_then(serde_json::Value::as_str)
                == Some(resumed.session_id),
    )
}

/// Replace `path` with `bytes` through a temporary file beside it, so a
/// reader meets the whole record or the one before it.
#[allow(
    clippy::disallowed_methods,
    reason = "the launch record's atomic write, beside the record it replaces"
)]
fn replace(path: &Path, bytes: &[u8]) -> Result<()> {
    let failed = |e: std::io::Error| {
        refused(
            "marker-write-failed",
            &[
                ("path", &path.display().to_string()),
                ("cause", &e.to_string()),
            ],
        )
    };
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("record");
    let staged = path.with_file_name(format!(".{name}.{}", std::process::id()));
    std::fs::write(&staged, bytes).map_err(failed)?;
    std::fs::rename(&staged, path).map_err(|e| {
        let _ = std::fs::remove_file(&staged);
        failed(e)
    })
}

#[allow(
    clippy::disallowed_methods,
    reason = "the launch record's removal of the record a launch does not carry"
)]
fn remove(path: &Path) -> Result<()> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(refused(
            "marker-write-failed",
            &[
                ("path", &path.display().to_string()),
                ("cause", &e.to_string()),
            ],
        )),
    }
}

/// The root the marker for `item` under `worktree`'s common git directory
/// holds, read three-valued: `Gone` where no marker stands, `Unreadable`
/// where the checkout or the marker could not be read.
#[allow(
    clippy::disallowed_methods,
    reason = "the marker read back after a crash, three-valued"
)]
pub fn read(worktree: &Path, item: &str) -> Reading<String> {
    let Ok(item) = item_name(item) else {
        return Reading::Unreadable {
            cause: "marker-item-invalid",
        };
    };
    let Ok(checkout) = checkout(worktree) else {
        return Reading::Unreadable {
            cause: "marker-git-failed",
        };
    };
    match std::fs::read_to_string(marker_path(&checkout.common, item)) {
        Ok(text) => Reading::Live(text.trim_end_matches('\n').to_owned()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Reading::Gone,
        Err(_) => Reading::Unreadable {
            cause: "marker-unreadable",
        },
    }
}

#[cfg(test)]
#[allow(
    clippy::disallowed_methods,
    reason = "the rows make the checkouts, links and records the writer judges"
)]
mod tests {
    use std::fs;
    use std::os::unix::fs::symlink;
    use std::process::Command;

    use super::*;

    fn git(dir: &Path, args: &[&str]) {
        let out = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_SYSTEM", "/dev/null")
            .env("HOME", dir)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    fn checkout_in(dir: &Path) -> PathBuf {
        let root = dir.join("repo");
        fs::create_dir_all(&root).unwrap();
        git(&root, &["init", "-q", "-b", "main"]);
        root
    }

    /// A linked `tmp` is a worktree setup's own and is admitted; every other
    /// component as a link or the wrong kind refuses before anything is made.
    #[test]
    fn a_linked_or_wrong_kind_component_refuses_before_anything_is_written() {
        let dir = tempfile::tempdir().unwrap();
        let root = checkout_in(dir.path());
        let elsewhere = dir.path().join("elsewhere");
        fs::create_dir_all(&elsewhere).unwrap();
        type Plant<'a> = &'a dyn Fn(&Path);
        let rows: [(&str, Plant); 5] = [
            ("lane-mail linked", &|r: &Path| {
                symlink(&elsewhere, r.join(".git").join("lane-mail")).unwrap();
            }),
            ("marker a directory", &|r: &Path| {
                fs::create_dir_all(r.join(".git").join("lane-mail").join("ken-7")).unwrap();
            }),
            ("mailbox root linked", &|r: &Path| {
                fs::create_dir_all(r.join("tmp")).unwrap();
                symlink(&elsewhere, r.join("tmp").join("lane-mail")).unwrap();
            }),
            ("item mailbox a file", &|r: &Path| {
                fs::create_dir_all(r.join("tmp").join("lane-mail")).unwrap();
                fs::write(r.join("tmp").join("lane-mail").join("KEN-7"), "x").unwrap();
            }),
            ("refresh record linked", &|r: &Path| {
                symlink(&elsewhere, r.join(".git").join("lane-refresh")).unwrap();
            }),
        ];
        for (name, plant) in rows {
            let sub = dir.path().join(name.replace(' ', "-"));
            fs::create_dir_all(&sub).unwrap();
            let root = checkout_in(&sub);
            plant(&root);
            let err = write(&root, "KEN-7", true, None).expect_err(name);
            assert_eq!(err.key(), "marker-unsafe", "{name}: {err}");
            assert!(
                !root.join(".git").join("lane-mail").join("ken-7").is_file(),
                "{name}: nothing written"
            );
        }
        // A linked `tmp` is a worktree setup's own and is admitted.
        let linked_tmp = dir.path().join("linked-tmp");
        fs::create_dir_all(&linked_tmp).unwrap();
        symlink(&linked_tmp, root.join("tmp")).unwrap();
        write(&root, "KEN-7", false, None).unwrap();
        assert_eq!(
            fs::read_to_string(marker_path(&root.join(".git"), "KEN-7")).unwrap(),
            format!("{}\n", fs::canonicalize(&root).unwrap().display())
        );
        let mailbox = fs::canonicalize(mailbox_path(&root, "KEN-7")).unwrap();
        assert!(mailbox.is_dir());
        assert!(mailbox.starts_with(fs::canonicalize(&linked_tmp).unwrap()));
    }

    #[test]
    fn the_context_reading_survives_only_the_resumed_session_and_the_refresh_record_follows_the_launch()
     {
        let dir = tempfile::tempdir().unwrap();
        let root = checkout_in(dir.path());
        write(&root, "KEN-7", true, None).unwrap();
        let context = mailbox_path(&root, "KEN-7").join(CONTEXT_RECORD);
        fs::write(
            &context,
            r#"{"harness":"claude","session_id":"s-1","context":5}"#,
        )
        .unwrap();
        let git_dir = root.join(".git");
        assert!(refresh_path(&git_dir).is_file(), "a refresh lane's record");
        write(
            &root,
            "KEN-7",
            false,
            Some(Resumed {
                harness: "claude",
                session_id: "s-1",
            }),
        )
        .unwrap();
        assert!(context.is_file(), "the resumed session keeps its reading");
        assert!(
            !refresh_path(&git_dir).exists(),
            "a relaunch states refresh again"
        );
        write(
            &root,
            "KEN-7",
            false,
            Some(Resumed {
                harness: "claude",
                session_id: "s-2",
            }),
        )
        .unwrap();
        assert!(!context.exists(), "another session inherits nothing");
        fs::write(&context, "not json").unwrap();
        let err = write(
            &root,
            "KEN-7",
            false,
            Some(Resumed {
                harness: "claude",
                session_id: "s-1",
            }),
        )
        .expect_err("an unreadable reading refuses");
        assert_eq!(err.key(), "marker-context-unreadable");
        assert_eq!(
            read(&root, "KEN-7"),
            Reading::Live(fs::canonicalize(&root).unwrap().display().to_string())
        );
        assert_eq!(read(&root, "ken-x"), Reading::Gone);
        assert!(matches!(
            read(&dir.path().join("missing"), "KEN-7"),
            Reading::Unreadable { .. }
        ));
        assert_eq!(item_name("..").unwrap_err().key(), "marker-item-invalid");
        assert_eq!(item_name("KEN 7").unwrap_err().key(), "marker-item-invalid");
        assert_eq!(
            git_dirs_of("gitdir: /srv/clone/.git/worktrees/lane\n"),
            Some((
                PathBuf::from("/srv/clone/.git/worktrees/lane"),
                PathBuf::from("/srv/clone/.git")
            ))
        );
        assert_eq!(git_dirs_of("gitdir: ../relative"), None);
        assert_eq!(git_dirs_of("gitdir: /srv/clone/.git"), None);
    }
}
