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

use std::collections::BTreeMap;
use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Deserialize;
use serde_json::{Value, json};

use crate::accounts::wall;
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

/// The one folder under the account records' root whose records
/// [`charges`] counts, and so the one place a lead with an account writes.
pub fn workers_dir(account_state: &Path) -> PathBuf {
    account_state.join("workers")
}

/// A record a lead wrote with `--account`: the leader and the account its
/// program spends on.
#[derive(Deserialize)]
struct Worker {
    #[serde(flatten)]
    leader: Identity,
    account: Option<String>,
}

/// The charges per account of the workers recorded under `dir`, keyed by the
/// account's one spelling: a record naming an account charges it while its
/// leader reads live or unreadable (an unread identity protects its account,
/// never frees it) and nothing once its leader is gone. A record with no
/// account, or of another shape, charges nothing. Each file is its caller's:
/// this read removes none. The names a write's temporary files take (a
/// leading `.`) are not records.
pub fn charges(
    dir: &Path,
    still_runs: &dyn Fn(&Identity) -> Reading<Identity>,
) -> Result<BTreeMap<String, u32>> {
    let mut charges = BTreeMap::new();
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(charges),
        Err(e) => return Err(Error::io("read-dir", dir, e)),
    };
    for entry in entries {
        let entry = entry.map_err(|e| Error::io("read-dir", dir, e))?;
        if entry.file_name().as_encoded_bytes().starts_with(b".") {
            continue;
        }
        let path = entry.path();
        let bytes = match std::fs::read(&path) {
            Ok(bytes) => bytes,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => return Err(Error::io("read", &path, e)),
        };
        let Ok(Worker {
            leader,
            account: Some(account),
        }) = serde_json::from_slice(&bytes)
        else {
            continue;
        };
        if account.is_empty() {
            continue;
        }
        match still_runs(&leader) {
            Reading::Gone => {}
            Reading::Live(_) | Reading::Unreadable { .. } => {
                *charges.entry(wall::canon(&account)).or_insert(0) += 1;
            }
        }
    }
    Ok(charges)
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
/// written before the exec and removed where the exec fails; with `account`
/// it names the account the program spends on, which [`charges`] counts.
/// Returns only the refusal; on success this process is the program.
pub fn lead(path: &Path, account: Option<&str>, program: &OsStr, args: &[OsString]) -> Error {
    match lead_checked(path, account, program, args) {
        Ok(never) => match never {},
        Err(error) => error,
    }
}

fn lead_checked(
    path: &Path,
    account: Option<&str>,
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
    let mut record = serde_json::to_value(&leader).map_err(|source| Error::Json {
        path: path.to_path_buf(),
        source,
    })?;
    if let Some(account) = account {
        record["account"] = json!(account);
    }
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
/// `member`, whether that pid is the group's ([`descends_into`]). No record
/// reads `gone`.
pub fn reading(path: &Path, member: Option<u32>) -> Result<Value> {
    let Some(leader) = read(path)? else {
        return Ok(with_member(
            json!({"reading": "gone"}),
            member.map(|_| false),
        ));
    };
    Ok(match process::group_table(&leader) {
        Reading::Live(rows) => with_member(
            json!({
                "reading": "live",
                "pid": leader.pid,
                "start": leader.start,
                "members": rows.iter().filter(|row| row.pgrp == leader.pid).count(),
            }),
            member.map(|pid| descends_into(&rows, pid, leader.pid)),
        ),
        Reading::Gone => with_member(json!({"reading": "gone"}), member.map(|_| false)),
        Reading::Unreadable { cause } => json!({"reading": "unreadable", "cause": cause}),
    })
}

/// Whether `pid` is the group `group`'s, read from one table: it or one of
/// its ancestors is a member. A hook is a child its harness waits for, and
/// the harness is the member, so the answer holds whether a harness runs its
/// hook in its own group or in a new one. The walk ends at pid 1 or at a
/// process the table does not hold, either of which is no member.
fn descends_into(rows: &[process::Row], pid: u32, group: u32) -> bool {
    let by_pid: std::collections::HashMap<u32, &process::Row> =
        rows.iter().map(|row| (row.pid, row)).collect();
    let mut next = pid;
    for _ in 0..=rows.len() {
        let Some(row) = by_pid.get(&next).filter(|_| next > 1) else {
            return false;
        };
        if row.pgrp == group {
            return true;
        }
        next = row.ppid;
    }
    false
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
