//! Process identity and the exact stop.
//!
//! A pid alone names nothing durable: the kernel reuses it. An `Identity` is
//! a pid with the start time the kernel recorded for it, and every signal
//! sent here is sent only while the live process still carries that start.
//! On Linux the start is the `starttime` field of `/proc/<pid>/stat`, in
//! clock ticks since boot, read as a file; elsewhere it is the `lstart`
//! column of `ps`, which is the one portable spelling. The two never meet,
//! since an identity is compared only on the host that recorded it.

use std::collections::HashMap;
use std::fs;
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

/// The one process table read: pid, parent pid and command name per row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
    pub pid: u32,
    pub ppid: u32,
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

/// The fields after the parenthesised command name of a `/proc/<pid>/stat`
/// line: state is the first, starttime the twentieth.
#[cfg(target_os = "linux")]
fn stat_fields(stat: &str) -> Option<(char, String)> {
    let after = stat.rsplit_once(')')?.1.trim_start();
    let mut fields = after.split_whitespace();
    let state = fields.next()?.chars().next()?;
    let start = fields.nth(18)?;
    Some((state, format!("ticks:{start}")))
}

/// Read a pid's liveness.
pub fn liveness(pid: u32) -> Result<Liveness> {
    #[cfg(target_os = "linux")]
    {
        match proc_stat(pid)? {
            None => Ok(Liveness::Gone),
            Some(stat) => match stat_fields(&stat) {
                Some(('Z', _)) | Some(('X', _)) => Ok(Liveness::Zombie),
                Some(_) => Ok(Liveness::Live),
                None => Err(Error::Process {
                    operation: "parse-stat",
                    pid,
                    cause: "unreadable stat line".to_owned(),
                }),
            },
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

/// Read the start the kernel reports for a pid, `None` for a pid no process
/// holds.
pub fn start(pid: u32) -> Result<Option<String>> {
    #[cfg(target_os = "linux")]
    {
        match proc_stat(pid)? {
            None => Ok(None),
            Some(stat) => stat_fields(&stat)
                .map(|(_, s)| Some(s))
                .ok_or_else(|| Error::Process {
                    operation: "parse-stat",
                    pid,
                    cause: "unreadable stat line".to_owned(),
                }),
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
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
}

/// The identity of a live pid, `None` when no live process holds it.
pub fn identity(pid: u32) -> Result<Option<Identity>> {
    Ok(start(pid)?.map(|start| Identity { pid, start }))
}

/// Whether the process this identity names still runs: live, with the same
/// start. A zombie or a pid now carrying another start is `Gone`.
pub fn still_runs(id: &Identity) -> Result<Liveness> {
    match liveness(id.pid)? {
        Liveness::Gone => Ok(Liveness::Gone),
        Liveness::Zombie => Ok(Liveness::Zombie),
        Liveness::Live => match start(id.pid)? {
            Some(s) if s == id.start => Ok(Liveness::Live),
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
            let Ok(Some(stat)) = proc_stat(pid) else {
                continue;
            };
            let Some(open) = stat.find('(') else { continue };
            let Some(close) = stat.rfind(')') else {
                continue;
            };
            let name = stat[open + 1..close].to_owned();
            let mut fields = stat[close + 1..].split_whitespace();
            let _state = fields.next();
            let Some(ppid) = fields.next().and_then(|p| p.parse::<u32>().ok()) else {
                continue;
            };
            rows.push(Row { pid, ppid, name });
        }
        Ok(rows)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let output = Command::new("ps")
            .args(["-A", "-o", "pid=", "-o", "ppid=", "-o", "comm="])
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
            let (Some(pid), Some(ppid)) = (
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
            rows.push(Row { pid, ppid, name });
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
