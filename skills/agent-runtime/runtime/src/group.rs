//! A process group a launch makes in place and records in a file, for a
//! program that runs in no pane this crate owns, such as a hosted lane on its
//! host: `lead` makes the group, records its leader's identity and becomes
//! the program; `reading` and `stop` act on the recorded group alone.
//!
//! The group is made, never taken from whatever started the caller: an SSH
//! server may run a command in a group it shares with every other session's
//! commands, so a stop of "the caller's group" there would reach them all.
//! A new group is made by `setpgid(0, 0)` before the exec, with no fork, so
//! the recorded pid and start are the program's own. A session is not made:
//! it would need a fork from a session leader and would drop the terminal a
//! pane's `ssh -t` gives, and with it the hang-up that ends the program when
//! the connection does.

use std::ffi::{OsStr, OsString};
use std::path::Path;
use std::time::Duration;

use serde_json::{Value, json};

use crate::error::{Error, Result, ShapeReason};
use crate::host;
use crate::process::{self, Identity, Stop};
use crate::reading::Reading;

/// The recorded leader's identity at `path`, `None` where no record stands:
/// a group no `lead` made, or one whose record its owner removed.
pub fn read(path: &Path) -> Result<Option<Identity>> {
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(Error::io("read", path, e)),
    };
    serde_json::from_slice(&bytes)
        .map(Some)
        .map_err(|e| Error::RecordShape {
            path: path.to_path_buf(),
            field: String::new(),
            reason: ShapeReason::TypeMismatch,
            cause: e.to_string(),
        })
}

/// Where the caller stands when it asks to lead: its pid, its process group,
/// the foreground group of its controlling terminal (`None` without one) and
/// how many other processes are in the group it is in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Standing {
    pub pid: u32,
    pub pgrp: u32,
    pub terminal: Option<u32>,
    pub others: usize,
}

/// What a caller's standing allows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lead {
    /// It leads no group and holds no terminal: a new group is made.
    Make,
    /// It already leads a group no other process is in, as a session leader
    /// does: that group is the program's. `setpgid` refuses a session leader,
    /// so none is made.
    Keep,
    /// It leads a group other processes are in, which it does not own.
    Shared { others: usize },
    /// It holds a terminal and leads no group: a new group there is a
    /// background group of that terminal, and a program reading it would be
    /// stopped.
    Terminal { tpgid: u32 },
}

pub fn judge(standing: Standing) -> Lead {
    match (standing.pid == standing.pgrp, standing.terminal) {
        (true, _) if standing.others == 0 => Lead::Keep,
        (true, _) => Lead::Shared {
            others: standing.others,
        },
        (false, None) => Lead::Make,
        (false, Some(tpgid)) => Lead::Terminal { tpgid },
    }
}

fn unread(cause: &str) -> Error {
    Error::refused("group-unread", &[("cause", cause)])
}

/// This process's standing, from one table read and its terminal's reading.
fn caller_standing() -> Result<Standing> {
    let pid = std::process::id();
    let rows = process::table().map_err(|e| unread(e.cause))?;
    let Some(own) = rows.iter().find(|row| row.pid == pid) else {
        return Err(unread("own-row-absent"));
    };
    let terminal = match process::foreground_group(pid) {
        Reading::Live(terminal) => terminal,
        Reading::Gone => return Err(unread("own-stat-gone")),
        Reading::Unreadable { cause } => return Err(unread(cause)),
    };
    Ok(Standing {
        pid,
        pgrp: own.pgrp,
        terminal,
        others: rows
            .iter()
            .filter(|row| row.pgrp == own.pgrp && row.pid != pid)
            .count(),
    })
}

/// Lead the group recorded at `path` and become `program` with `args`. A
/// record whose group still runs refuses `group-live`: a launch that skipped
/// its stop never starts a second program over the first. The record is
/// written before the exec and removed where the exec fails. Returns only the
/// refusal; on success this process is the program.
pub fn lead(path: &Path, program: &OsStr, args: &[OsString]) -> Error {
    match lead_checked(path, program, args) {
        Ok(never) => match never {},
        Err(error) => error,
    }
}

fn lead_checked(
    path: &Path,
    program: &OsStr,
    args: &[OsString],
) -> Result<std::convert::Infallible> {
    let file = path.display().to_string();
    if let Some(recorded) = read(path)? {
        match process::group_members(&recorded) {
            Reading::Gone => {}
            Reading::Live(_) => {
                return Err(Error::refused(
                    "group-live",
                    &[("pid", &recorded.pid.to_string()), ("file", &file)],
                ));
            }
            Reading::Unreadable { cause } => return Err(unread(cause)),
        }
    }
    let standing = caller_standing()?;
    let new_group = match judge(standing) {
        Lead::Make => true,
        Lead::Keep => false,
        Lead::Shared { others } => {
            return Err(Error::refused(
                "group-shared",
                &[
                    ("pid", &standing.pid.to_string()),
                    ("members", &others.to_string()),
                ],
            ));
        }
        Lead::Terminal { tpgid } => {
            return Err(Error::refused(
                "group-unmade",
                &[
                    ("cause", "terminal"),
                    ("pid", &standing.pid.to_string()),
                    ("pgid", &standing.pgrp.to_string()),
                    ("tpgid", &tpgid.to_string()),
                ],
            ));
        }
    };
    let leader = match process::identity(standing.pid) {
        Reading::Live(identity) => identity,
        Reading::Gone => return Err(unread("own-stat-gone")),
        Reading::Unreadable { cause } => return Err(unread(cause)),
    };
    let record = serde_json::to_value(&leader).map_err(|source| Error::Json {
        path: path.to_path_buf(),
        source,
    })?;
    crate::record::replace_atomically(path, &record)?;
    let failed = host::exec(program, args, new_group);
    let removed = match std::fs::remove_file(path) {
        Ok(()) => "yes".to_owned(),
        Err(e) => format!("no:{}", e.kind()),
    };
    Err(Error::refused(
        "exec-failed",
        &[
            ("program", &program.to_string_lossy()),
            ("cause", &failed.kind().to_string()),
            ("record-removed", &removed),
        ],
    ))
}

/// The recorded group's reading: `live` with the leader's identity and the
/// count of its members, `gone`, or `unreadable` with the cause; with
/// `member`, whether that pid is in the recorded group. No record reads
/// `gone`.
pub fn reading(path: &Path, member: Option<u32>) -> Result<Value> {
    let Some(leader) = read(path)? else {
        return Ok(with_member(
            json!({"reading": "gone"}),
            member.map(|_| false),
        ));
    };
    Ok(match process::group_members(&leader) {
        Reading::Live(rows) => with_member(
            json!({
                "reading": "live",
                "pid": leader.pid,
                "start": leader.start,
                "members": rows.len(),
            }),
            member.map(|pid| rows.iter().any(|row| row.pid == pid)),
        ),
        Reading::Gone => with_member(json!({"reading": "gone"}), member.map(|_| false)),
        Reading::Unreadable { cause } => json!({"reading": "unreadable", "cause": cause}),
    })
}

fn with_member(mut value: Value, member: Option<bool>) -> Value {
    if let Some(member) = member {
        value["member"] = json!(member);
    }
    value
}

/// Stop the recorded group alone, every member by its own identity: TERM,
/// `grace`, then KILL. No record is a group already gone.
#[allow(
    clippy::disallowed_methods,
    reason = "the session command's exact stop of the one group its record names"
)]
pub fn stop(path: &Path, grace: Duration) -> Result<Value> {
    let stop = match read(path)? {
        Some(leader) => process::stop_group(&leader, grace)?,
        None => Stop::AlreadyGone,
    };
    Ok(json!({"stop": stop}))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Each standing a caller can hold, with the lead it allows; the ids are
    /// synthetic.
    #[test]
    fn a_standing_allows_the_one_lead_its_group_and_terminal_permit() {
        let rows = [
            ((40, 7, None, 3), Lead::Make),
            ((40, 40, None, 0), Lead::Keep),
            ((40, 40, Some(40), 0), Lead::Keep),
            ((40, 40, None, 2), Lead::Shared { others: 2 }),
            ((40, 40, Some(40), 1), Lead::Shared { others: 1 }),
            ((40, 7, Some(7), 0), Lead::Terminal { tpgid: 7 }),
        ];
        for ((pid, pgrp, terminal, others), lead) in rows {
            let standing = Standing {
                pid,
                pgrp,
                terminal,
                others,
            };
            assert_eq!(judge(standing), lead, "{standing:?}");
        }
    }

    #[test]
    fn a_record_reads_absent_as_none_and_a_foreign_shape_as_record_shape() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("record");
        assert_eq!(read(&path).unwrap(), None);
        std::fs::write(&path, "4242 Tue Nov 11 09:00:00 2026\n").unwrap();
        assert_eq!(read(&path).unwrap_err().key(), "record-shape");
        std::fs::write(&path, r#"{"pid":4242,"start":"ticks:9"}"#).unwrap();
        assert_eq!(
            read(&path).unwrap(),
            Some(Identity {
                pid: 4242,
                start: "ticks:9".to_owned()
            })
        );
    }
}
