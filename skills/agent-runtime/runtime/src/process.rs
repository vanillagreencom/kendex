//! Process identity and the exact stop.
//!
//! A pid alone names nothing durable: the kernel reuses it. An `Identity` is
//! a pid with the start time the kernel recorded for it, and every signal
//! sent here is sent only while the live process still carries that start.
//! On Linux the start is the `starttime` field of `/proc/<pid>/stat`, in
//! clock ticks since boot, read as a file; elsewhere it is the `lstart`
//! column of `ps`, which is the one portable spelling. A recorded start is
//! read back in its own form, so the legacy shell writers' bare `lstart`
//! text and this crate's `ticks:` form each match the process they name.
//!
//! The same table answers which processes hold a pane's terminal: the
//! members of the foreground process group the kernel records for the
//! pane's own process (`tpgid`), each named by its command. tmux's
//! `pane_current_command` is that group's `argv[0]` basename, an
//! interpreter's name for a script, and carries no pid, so the identity
//! reader reads the group's members itself.

use std::collections::HashMap;
use std::fs;
#[cfg(not(target_os = "linux"))]
use std::path::Path;
use std::process::Command;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::error::{Error, Result};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Identity {
    pub pid: u32,
    /// The start the kernel reports for the pid: `ticks:<n>` on Linux,
    /// `lstart:<text>` elsewhere.
    pub start: String,
}

/// What a process read found.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Liveness {
    Live,
    Zombie,
    Gone,
}

/// The one process table read: pid, parent pid, process group and command
/// name per row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
    pub pid: u32,
    pub ppid: u32,
    pub pgrp: u32,
    pub name: String,
}

#[cfg(target_os = "linux")]
fn proc_stat(pid: u32) -> Result<Option<String>> {
    match fs::read_to_string(format!("/proc/{pid}/stat")) {
        Ok(text) => Ok(Some(text)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        // A process that exited between the directory listing and the read
        // reports ESRCH as a generic error on some kernels.
        Err(e) if e.raw_os_error() == Some(3) => Ok(None),
        Err(e) => Err(Error::Process {
            operation: "read-stat",
            pid,
            cause: e.to_string(),
        }),
    }
}

/// The fields of one `/proc/<pid>/stat` line this crate reads: the command
/// name inside the parentheses, then, counted after them, the state (field
/// 3), the parent pid (4), the process group (5), the foreground process
/// group of the controlling terminal (8, `-1` without one) and the start in
/// clock ticks since boot (22).
#[cfg(target_os = "linux")]
struct Stat {
    name: String,
    state: char,
    ppid: u32,
    pgrp: u32,
    tpgid: i64,
    start: String,
}

#[cfg(target_os = "linux")]
fn parse_stat(stat: &str) -> Option<Stat> {
    let open = stat.find('(')?;
    let close = stat.rfind(')')?;
    let name = stat[open + 1..close].to_owned();
    let fields: Vec<&str> = stat[close + 1..].split_whitespace().collect();
    let state = fields.first()?.chars().next()?;
    let ppid = fields.get(1)?.parse().ok()?;
    let pgrp = fields.get(2)?.parse().ok()?;
    let tpgid = fields.get(5)?.parse().ok()?;
    let start = fields.get(19)?;
    Some(Stat {
        name,
        state,
        ppid,
        pgrp,
        tpgid,
        start: format!("ticks:{start}"),
    })
}

#[cfg(target_os = "linux")]
fn stat_of(pid: u32) -> Result<Option<Stat>> {
    match proc_stat(pid)? {
        None => Ok(None),
        Some(stat) => parse_stat(&stat).map(Some).ok_or_else(|| Error::Process {
            operation: "parse-stat",
            pid,
            cause: "unreadable stat line".to_owned(),
        }),
    }
}

/// Read a pid's liveness.
pub fn liveness(pid: u32) -> Result<Liveness> {
    #[cfg(target_os = "linux")]
    {
        match stat_of(pid)? {
            None => Ok(Liveness::Gone),
            Some(Stat {
                state: 'Z' | 'X', ..
            }) => Ok(Liveness::Zombie),
            Some(_) => Ok(Liveness::Live),
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        let output = Command::new("ps")
            .args(["-o", "stat=", "-p", &pid.to_string()])
            .output()
            .map_err(|e| Error::Process {
                operation: "ps-stat",
                pid,
                cause: e.to_string(),
            })?;
        let text = String::from_utf8_lossy(&output.stdout).trim().to_owned();
        if text.is_empty() {
            return Ok(Liveness::Gone);
        }
        Ok(if text.starts_with('Z') {
            Liveness::Zombie
        } else {
            Liveness::Live
        })
    }
}

/// Read the start the kernel reports for a pid in this host's recording
/// form, `None` for a pid no process holds: `ticks:<n>` on Linux, the
/// `lstart:<text>` of `ps` elsewhere.
pub fn start(pid: u32) -> Result<Option<String>> {
    #[cfg(target_os = "linux")]
    {
        start_ticks(pid)
    }
    #[cfg(not(target_os = "linux"))]
    {
        start_lstart(pid)
    }
}

/// The `/proc` starttime of a pid as `ticks:<n>`; `None` where no process
/// holds the pid, and on a host without `/proc`.
#[cfg(target_os = "linux")]
fn start_ticks(pid: u32) -> Result<Option<String>> {
    Ok(stat_of(pid)?.map(|s| s.start))
}

#[cfg(not(target_os = "linux"))]
fn start_ticks(_pid: u32) -> Result<Option<String>> {
    Ok(None)
}

/// The `ps -o lstart` start of a pid as `lstart:<squeezed text>`, in the C
/// locale and UTC so a reader elsewhere prints the same line; `None` where
/// no process holds the pid. Available on every host, so a legacy
/// `lstart`-form identity can be matched on Linux too.
fn start_lstart(pid: u32) -> Result<Option<String>> {
    let output = Command::new("ps")
        .env("LC_ALL", "C")
        .env("TZ", "UTC")
        .args(["-o", "lstart=", "-p", &pid.to_string()])
        .output()
        .map_err(|e| Error::Process {
            operation: "ps-lstart",
            pid,
            cause: e.to_string(),
        })?;
    let text = String::from_utf8_lossy(&output.stdout);
    let joined = text.split_whitespace().collect::<Vec<_>>().join(" ");
    Ok(if joined.is_empty() {
        None
    } else {
        Some(format!("lstart:{joined}"))
    })
}

/// The form a recorded start is written in, so a reader matches a live pid's
/// start in the same form. The runtime writes [`start`]'s host form; a
/// legacy shell writer records the bare `ps -o lstart` text; the non-Linux
/// reader records `lstart:`. All three are admitted (decision 55).
enum StartForm {
    Ticks,
    Lstart,
}

fn start_form(recorded: &str) -> StartForm {
    if recorded.starts_with("ticks:") {
        StartForm::Ticks
    } else {
        StartForm::Lstart
    }
}

/// The comparable body of a recorded start: the digits after `ticks:`, or
/// the `lstart` text with any `lstart:` prefix dropped and its blanks
/// squeezed, as `ps -o lstart` and the legacy `lane_process_start` squeeze
/// it. Two spellings of one process's start compare equal here.
fn normalize_start(recorded: &str) -> String {
    if let Some(ticks) = recorded.strip_prefix("ticks:") {
        return ticks.trim().to_owned();
    }
    let body = recorded.strip_prefix("lstart:").unwrap_or(recorded);
    body.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// A live pid's start read in `form` and normalized; `None` for a pid no
/// process holds.
fn start_in_form(pid: u32, form: StartForm) -> Result<Option<String>> {
    let read = match form {
        StartForm::Ticks => start_ticks(pid)?,
        StartForm::Lstart => start_lstart(pid)?,
    };
    Ok(read.map(|s| normalize_start(&s)))
}

/// The identity of a live pid, `None` when no live process holds it.
pub fn identity(pid: u32) -> Result<Option<Identity>> {
    Ok(start(pid)?.map(|start| Identity { pid, start }))
}

/// The process group holding the terminal of `pane_pid`'s process: the
/// group whose members read the pane's keystrokes. `None` for a pid no
/// process holds, or one with no controlling terminal.
pub fn foreground_group(pane_pid: u32) -> Result<Option<u32>> {
    #[cfg(target_os = "linux")]
    {
        Ok(stat_of(pane_pid)?.and_then(|s| u32::try_from(s.tpgid).ok()))
    }
    #[cfg(not(target_os = "linux"))]
    {
        let text = ps_column(pane_pid, "tpgid")?;
        Ok(text
            .and_then(|t| t.parse::<i64>().ok())
            .and_then(|t| u32::try_from(t).ok()))
    }
}

/// One `ps` column of one pid, trimmed; `None` where no process holds it.
#[cfg(not(target_os = "linux"))]
fn ps_column(pid: u32, column: &str) -> Result<Option<String>> {
    let output = Command::new("ps")
        .args(["-o", &format!("{column}="), "-p", &pid.to_string()])
        .output()
        .map_err(|e| Error::Process {
            operation: "ps-column",
            pid,
            cause: e.to_string(),
        })?;
    let text = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    Ok(if text.is_empty() { None } else { Some(text) })
}

/// Whether the process this identity names still runs: live, with the same
/// start. A zombie or a pid now carrying another start is `Gone`. The
/// recorded start is read in its own form, so a `ticks:`, an `lstart:` and a
/// bare legacy start each match the live pid they name (decision 55).
pub fn still_runs(id: &Identity) -> Result<Liveness> {
    match liveness(id.pid)? {
        Liveness::Gone => Ok(Liveness::Gone),
        Liveness::Zombie => Ok(Liveness::Zombie),
        Liveness::Live => match start_in_form(id.pid, start_form(&id.start))? {
            Some(s) if s == normalize_start(&id.start) => Ok(Liveness::Live),
            _ => Ok(Liveness::Gone),
        },
    }
}

/// One read of the whole process table.
pub fn table() -> Result<Vec<Row>> {
    #[cfg(target_os = "linux")]
    {
        let mut rows = Vec::new();
        let entries = fs::read_dir("/proc").map_err(|e| Error::Process {
            operation: "read-proc",
            pid: 0,
            cause: e.to_string(),
        })?;
        for entry in entries.flatten() {
            let Some(pid) = entry
                .file_name()
                .to_str()
                .and_then(|n| n.parse::<u32>().ok())
            else {
                continue;
            };
            // A process that exits during the listing, or a line this
            // reader cannot parse, is left out of the table.
            let Ok(Some(stat)) = stat_of(pid) else {
                continue;
            };
            rows.push(Row {
                pid,
                ppid: stat.ppid,
                pgrp: stat.pgrp,
                name: stat.name,
            });
        }
        Ok(rows)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let output = Command::new("ps")
            .args([
                "-A", "-o", "pid=", "-o", "ppid=", "-o", "pgid=", "-o", "comm=",
            ])
            .output()
            .map_err(|e| Error::Process {
                operation: "ps-table",
                pid: 0,
                cause: e.to_string(),
            })?;
        let text = String::from_utf8_lossy(&output.stdout);
        let mut rows = Vec::new();
        for line in text.lines() {
            let mut parts = line.split_whitespace();
            let (Some(pid), Some(ppid), Some(pgrp)) = (
                parts.next().and_then(|p| p.parse().ok()),
                parts.next().and_then(|p| p.parse().ok()),
                parts.next().and_then(|p| p.parse().ok()),
            ) else {
                continue;
            };
            let name = parts.collect::<Vec<_>>().join(" ");
            let name = Path::new(&name)
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or(&name)
                .to_owned();
            rows.push(Row {
                pid,
                ppid,
                pgrp,
                name,
            });
        }
        Ok(rows)
    }
}

/// The pids at or below `root` whose name `matches`, nearest first, from one
/// table read. `root` itself is included when it matches.
pub fn below(rows: &[Row], root: u32, matches: &dyn Fn(&str) -> bool) -> Vec<(u32, u32)> {
    let parents: HashMap<u32, u32> = rows.iter().map(|r| (r.pid, r.ppid)).collect();
    let mut found = Vec::new();
    for row in rows {
        if !matches(&row.name) {
            continue;
        }
        let mut hops = 0u32;
        let mut q = Some(row.pid);
        while let Some(pid) = q {
            if pid == root {
                found.push((hops, row.pid));
                break;
            }
            if hops > rows.len() as u32 {
                break;
            }
            q = parents.get(&pid).copied().filter(|p| *p != 0);
            hops += 1;
        }
    }
    found.sort();
    found
}

/// Whether every process under `pid` is a shell: a pane whose harness has
/// exited and left only its shell reads `true`.
pub fn only_shells_below(rows: &[Row], pid: u32) -> bool {
    let children: HashMap<u32, Vec<&Row>> = rows.iter().fold(HashMap::new(), |mut m, r| {
        m.entry(r.ppid).or_default().push(r);
        m
    });
    let mut stack = vec![pid];
    while let Some(p) = stack.pop() {
        for child in children.get(&p).into_iter().flatten() {
            if !is_shell(&child.name) {
                return false;
            }
            stack.push(child.pid);
        }
    }
    true
}

pub fn is_shell(name: &str) -> bool {
    matches!(
        name.trim_start_matches('-'),
        "bash" | "zsh" | "fish" | "sh" | "dash"
    )
}

/// What an exact stop did.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case", tag = "outcome")]
pub enum Stop {
    /// Every named process has exited.
    Stopped { signaled: u32 },
    /// The identity had already ended before the first signal.
    AlreadyGone,
    /// The identity no longer matches: the pid now holds another process.
    IdentityStale,
    /// A signaled process still runs after the grace.
    Timeout { pid: u32 },
}

fn signal(pid: u32, name: &str) -> Result<bool> {
    let status = Command::new("kill")
        .args([format!("-{name}"), pid.to_string()])
        .status()
        .map_err(|e| Error::Process {
            operation: "kill",
            pid,
            cause: e.to_string(),
        })?;
    Ok(status.success())
}

/// End the processes `targets` names, each only while its start still
/// matches: TERM, a grace, then KILL to what still runs. A pid whose start
/// changed between reads is left alone.
pub fn stop_identities(targets: &[Identity], grace: Duration) -> Result<Stop> {
    let mut live: Vec<Identity> = Vec::new();
    for t in targets {
        match still_runs(t)? {
            Liveness::Live => live.push(t.clone()),
            Liveness::Zombie | Liveness::Gone => {}
        }
    }
    if live.is_empty() {
        return Ok(Stop::AlreadyGone);
    }
    let signaled = live.len() as u32;
    for sig in ["TERM", "KILL"] {
        let mut remaining = Vec::new();
        for id in &live {
            if still_runs(id)? != Liveness::Live {
                continue;
            }
            if !signal(id.pid, sig)? && still_runs(id)? == Liveness::Live {
                return Err(Error::Process {
                    operation: "signal",
                    pid: id.pid,
                    cause: format!("SIG{sig} refused"),
                });
            }
            remaining.push(id.clone());
        }
        let deadline = Instant::now() + grace;
        loop {
            remaining.retain(|id| matches!(still_runs(id), Ok(Liveness::Live)));
            if remaining.is_empty() || Instant::now() >= deadline {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        if remaining.is_empty() {
            return Ok(Stop::Stopped { signaled });
        }
        live = remaining;
    }
    Ok(Stop::Timeout { pid: live[0].pid })
}

/// Stop one recorded identity and the harness-named processes below it.
/// `IdentityStale` when the pid runs something else now.
pub fn stop_tree(root: &Identity, matches: &dyn Fn(&str) -> bool, grace: Duration) -> Result<Stop> {
    match still_runs(root)? {
        Liveness::Gone => {
            return Ok(match start(root.pid)? {
                Some(_) => Stop::IdentityStale,
                None => Stop::AlreadyGone,
            });
        }
        Liveness::Zombie => return Ok(Stop::AlreadyGone),
        Liveness::Live => {}
    }
    let rows = table()?;
    let mut targets = Vec::new();
    for (_, pid) in below(&rows, root.pid, matches) {
        if let Some(id) = identity(pid)? {
            targets.push(id);
        }
    }
    if targets.is_empty() {
        return Ok(Stop::Stopped { signaled: 0 });
    }
    stop_identities(&targets, grace)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rows(spec: &[(u32, u32, &str)]) -> Vec<Row> {
        spec.iter()
            .map(|(pid, ppid, name)| Row {
                pid: *pid,
                ppid: *ppid,
                pgrp: *pid,
                name: (*name).to_owned(),
            })
            .collect()
    }

    #[test]
    fn below_finds_named_descendants_nearest_first_and_includes_the_root() {
        let t = rows(&[
            (1, 0, "init"),
            (10, 1, "tmux"),
            (20, 10, "bash"),
            (30, 20, "claude"),
            (31, 30, "node"),
            (40, 1, "claude"),
        ]);
        let found = below(&t, 20, &|n| n == "claude");
        assert_eq!(found, vec![(1, 30)]);
        let found = below(&t, 30, &|n| n == "claude");
        assert_eq!(found, vec![(0, 30)]);
        assert!(below(&t, 20, &|n| n == "codex").is_empty());
    }

    /// A synthetic `/proc/<pid>/stat` line with a space in its command name
    /// and the fields this crate reads at their documented positions.
    #[cfg(target_os = "linux")]
    #[test]
    fn parse_stat_reads_the_name_state_parent_foreground_group_and_start() {
        let mut fields: Vec<String> = (3..=52).map(|n| n.to_string()).collect();
        fields[0] = "S".to_owned(); // 3: state
        fields[1] = "41".to_owned(); // 4: ppid
        fields[2] = "42".to_owned(); // 5: pgrp
        fields[5] = "4567".to_owned(); // 8: tpgid
        fields[19] = "9912345".to_owned(); // 22: starttime
        let line = format!("42 (my script) {}", fields.join(" "));
        let stat = parse_stat(&line).expect("parsed");
        assert_eq!(stat.name, "my script");
        assert_eq!(stat.state, 'S');
        assert_eq!(stat.ppid, 41);
        assert_eq!(stat.pgrp, 42);
        assert_eq!(stat.tpgid, 4567);
        assert_eq!(stat.start, "ticks:9912345");
        // No controlling terminal: the kernel writes -1, read as no group.
        fields[5] = "-1".to_owned();
        let line = format!("42 (x) {}", fields.join(" "));
        assert_eq!(parse_stat(&line).unwrap().tpgid, -1);
        assert!(
            parse_stat("42 (x) S 1").is_none(),
            "a short line parses to nothing"
        );
    }

    #[test]
    fn the_table_names_a_child_this_test_owns_in_its_own_group() {
        use std::os::unix::process::CommandExt;
        let mut child = Command::new("sleep")
            .arg("30")
            .process_group(0)
            .spawn()
            .unwrap();
        let rows = table().unwrap();
        let row = rows
            .iter()
            .find(|r| r.pid == child.id())
            .expect("the child's row");
        assert_eq!(row.name, "sleep");
        assert_eq!(row.ppid, std::process::id());
        assert_eq!(row.pgrp, child.id(), "a new group led by the child");
        let _ = child.kill();
        child.wait().unwrap();
    }

    #[test]
    fn only_shells_below_reads_an_exited_harness_pane_as_shells() {
        let t = rows(&[(20, 1, "bash"), (21, 20, "zsh"), (22, 21, "sh")]);
        assert!(only_shells_below(&t, 20));
        let t = rows(&[(20, 1, "bash"), (21, 20, "claude")]);
        assert!(!only_shells_below(&t, 20));
    }

    #[test]
    fn a_zombie_identity_does_not_run() {
        // The current process is live and carries a stable start.
        let me = std::process::id();
        let id = identity(me).unwrap().unwrap();
        assert_eq!(still_runs(&id).unwrap(), Liveness::Live);
        let stale = Identity {
            pid: me,
            start: "ticks:0".to_owned(),
        };
        assert_eq!(still_runs(&stale).unwrap(), Liveness::Gone);
    }

    /// Decision 55: one reader admits every start form a shipped writer
    /// produced. A `ticks:`, an `lstart:` and a bare `ps -o lstart` start
    /// each match the live process they name, and any other value is `Gone`.
    #[test]
    fn still_runs_matches_every_shipped_start_form_and_rejects_a_mismatch() {
        let me = std::process::id();
        // The lstart text a legacy shell writer records bare, and the
        // non-Linux reader records with an `lstart:` prefix.
        let prefixed = start_lstart(me).unwrap().expect("own lstart");
        let bare = prefixed
            .strip_prefix("lstart:")
            .expect("lstart prefix")
            .to_owned();
        // The host form the runtime itself records (ticks on Linux).
        let native = start(me).unwrap().expect("own start");
        for form in [native, prefixed.clone(), bare.clone()] {
            let id = Identity {
                pid: me,
                start: form.clone(),
            };
            assert_eq!(still_runs(&id).unwrap(), Liveness::Live, "form {form:?}");
        }
        // A legacy fixture value copied from
        // `skills/orch/tests/rust/fixtures/workflow-state-oversee.json`: a
        // ticks start no live process here holds.
        let fixture = Identity {
            pid: me,
            start: "ticks:9912345".to_owned(),
        };
        assert_eq!(still_runs(&fixture).unwrap(), Liveness::Gone);
        // A mismatch in the lstart form is `Gone` too.
        let wrong = Identity {
            pid: me,
            start: "lstart:Thu Jan  1 00:00:00 1970".to_owned(),
        };
        assert_eq!(still_runs(&wrong).unwrap(), Liveness::Gone);
    }

    #[test]
    fn stopping_a_child_this_test_owns_ends_it_exactly_once() {
        let mut child = Command::new("sleep").arg("30").spawn().unwrap();
        let id = identity(child.id()).unwrap().unwrap();
        let stop = stop_identities(std::slice::from_ref(&id), Duration::from_secs(5)).unwrap();
        assert_eq!(stop, Stop::Stopped { signaled: 1 });
        child.wait().unwrap();
        // A second stop of the ended identity signals nothing.
        assert_eq!(
            stop_identities(std::slice::from_ref(&id), Duration::from_secs(1)).unwrap(),
            Stop::AlreadyGone
        );
    }
}
