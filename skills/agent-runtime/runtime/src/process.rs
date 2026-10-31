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
//! Every read here answers with a [`Reading`] (decision 99): the process
//! live under its identity, gone (no live process holds the pid, an exited
//! one awaiting its parent's wait included), or unreadable with the cause.
//! A `/proc` entry that cannot be read or parsed, a `ps` that failed, or a
//! process table with one such entry is unreadable, never an absence.
//!
//! The same table answers which processes hold a pane's terminal: the
//! members of the foreground process group the kernel records for the
//! pane's own process (`tpgid`), each named by its command. tmux's
//! `pane_current_command` is that group's `argv[0]` basename, an
//! interpreter's name for a script, and carries no pid, so the identity
//! reader reads the group's members itself.

// Every reading here is matched variant by variant (decision 105): a
// wildcard arm would let a later variant fall into an absence.
#![deny(clippy::wildcard_enum_match_arm)]

use std::collections::HashMap;
use std::ffi::OsStr;
#[cfg(target_os = "linux")]
use std::fs;
use std::os::unix::process::ExitStatusExt;
#[cfg(not(target_os = "linux"))]
use std::path::Path;
use std::process::{Command, ExitStatus, Output};
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::error::{Error, Result};
use crate::host::run_with;
use crate::reading::{Reading, Unreadable};

/// The bound on one `ps` run.
const PS_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Identity {
    pub pid: u32,
    /// The start the kernel reports for the pid: `ticks:<n>` on Linux,
    /// `lstart:<text>` elsewhere.
    pub start: String,
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

/// The fields of one `/proc/<pid>/stat` line this crate reads: the command
/// name inside the parentheses, then, counted after them, the state (field
/// 3), the parent pid (4), the process group (5), the foreground process
/// group of the controlling terminal (8, `-1` without one) and the start in
/// clock ticks since boot (22).
#[cfg(target_os = "linux")]
#[derive(Debug, PartialEq, Eq)]
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

/// What one `/proc/<pid>/stat` read says. No entry (ENOENT, or the ESRCH
/// some kernels report for a process that exited between a listing and the
/// read) is `Gone`; so is a process that has exited and waits for its
/// parent (`Z`, `X`), which holds its pid and nothing else. Any other read
/// error, and a line this crate cannot parse, is `Unreadable`.
#[cfg(target_os = "linux")]
fn stat_reading(read: std::io::Result<String>) -> Reading<Stat> {
    let text = match read {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound || e.raw_os_error() == Some(3) => {
            return Reading::Gone;
        }
        Err(_) => {
            return Reading::Unreadable {
                cause: "stat-unreadable",
            };
        }
    };
    match parse_stat(&text) {
        None => Reading::Unreadable {
            cause: "stat-unparsed",
        },
        Some(Stat {
            state: 'Z' | 'X', ..
        }) => Reading::Gone,
        Some(stat) => Reading::Live(stat),
    }
}

#[cfg(target_os = "linux")]
fn stat_of(pid: u32) -> Reading<Stat> {
    stat_reading(fs::read_to_string(format!("/proc/{pid}/stat")))
}

/// What a `ps -p <pid>` answer says, from its exit status and both streams
/// (decision 105). A row under exit 0 is `Live`, its blanks squeezed. `Gone`
/// is the one documented no-match answer alone: exit 1 with nothing on
/// either stream. procps-ng exits 1 when it printed no process
/// (`src/ps/output.c`, `show_one_proc`'s end-of-run call: `exit(1)` unless
/// `did_stuff`), and Apple's and FreeBSD's `ps` exit 1 when no process was
/// kept (`ps.c`: `if (nkept == 0) ... exit(1)`; the FreeBSD manual says
/// only "0 on success, and >0 if an error occurs"). procps-ng exits 1 for a
/// usage error too, writing it to stderr, so a written error under exit 1
/// is no absence. Every other answer is `Unreadable` with a cause naming
/// the status: `ps-exit-<code>`, `ps-signal-<n>` for a `ps` ended by a
/// signal before it answered, `ps-empty` for a successful run that printed
/// no row.
fn ps_reading(output: &Output) -> Reading<String> {
    let text = String::from_utf8_lossy(&output.stdout)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    match (
        output.status.code(),
        text.is_empty(),
        output.stderr.is_empty(),
    ) {
        (Some(0), false, _) => Reading::Live(text),
        (Some(0), true, _) => Reading::Unreadable { cause: "ps-empty" },
        (Some(1), true, true) => Reading::Gone,
        (Some(_) | None, _, _) => Reading::Unreadable {
            cause: status_cause(output.status),
        },
    }
}

/// The cause word for a `ps` status that is no answer: `ps-exit-<code>` or
/// `ps-signal-<n>`. A reading's cause is a stable `&'static str`, and the
/// set of these words is finite (an exit code is one byte, a signal number
/// is small), so each distinct word is made once and kept for the life of
/// the process.
fn status_cause(status: ExitStatus) -> &'static str {
    static WORDS: Mutex<Vec<&'static str>> = Mutex::new(Vec::new());
    let word = match (status.code(), status.signal()) {
        (Some(code), _) => format!("ps-exit-{code}"),
        (None, Some(signal)) => format!("ps-signal-{signal}"),
        (None, None) => "ps-status-unknown".to_owned(),
    };
    let mut words = WORDS.lock().unwrap_or_else(PoisonError::into_inner);
    if let Some(known) = words.iter().find(|w| **w == word) {
        return known;
    }
    let kept: &'static str = Box::leak(word.into_boxed_str());
    words.push(kept);
    kept
}

/// One `ps` run through the crate's one runner, in the C locale and UTC so a
/// reader elsewhere prints the same text; the status comes back whole.
fn ps(operation: &'static str, args: &[&str]) -> Result<Output> {
    let env: [(&str, &OsStr); 2] = [("LC_ALL", OsStr::new("C")), ("TZ", OsStr::new("UTC"))];
    run_with("ps", operation, args, &env, None, PS_TIMEOUT)
}

/// One `ps` column of one pid. A `ps` that could not run, or did not answer
/// within the bound, is `ps-unavailable`.
fn ps_column(pid: u32, column: &str) -> Reading<String> {
    let column = format!("{column}=");
    let pid = pid.to_string();
    match ps("ps-column", &["-o", &column, "-p", &pid]) {
        Ok(output) => ps_reading(&output),
        Err(_) => Reading::Unreadable {
            cause: "ps-unavailable",
        },
    }
}

/// The identity of the live process holding `pid`: the pid with the start
/// the kernel reports for it in this host's recording form.
pub fn identity(pid: u32) -> Reading<Identity> {
    #[cfg(target_os = "linux")]
    {
        stat_of(pid).map(|stat| Identity {
            pid,
            start: stat.start,
        })
    }
    #[cfg(not(target_os = "linux"))]
    {
        match ps_column(pid, "stat") {
            Reading::Live(state) if state.starts_with('Z') => return Reading::Gone,
            Reading::Live(_) => {}
            Reading::Gone => return Reading::Gone,
            Reading::Unreadable { cause } => return Reading::Unreadable { cause },
        }
        start_lstart(pid).map(|start| Identity { pid, start })
    }
}

/// The `/proc` starttime of a pid as `ticks:<n>`. A host without `/proc`
/// cannot read this form, so a `ticks:` start recorded elsewhere is
/// unreadable there, never gone.
#[cfg(target_os = "linux")]
fn start_ticks(pid: u32) -> Reading<String> {
    stat_of(pid).map(|stat| stat.start)
}

#[cfg(not(target_os = "linux"))]
fn start_ticks(_pid: u32) -> Reading<String> {
    Reading::Unreadable {
        cause: "ticks-unavailable",
    }
}

/// The `ps -o lstart` start of a pid as `lstart:<squeezed text>`. Available
/// on every host, so a legacy `lstart`-form identity can be matched on
/// Linux too.
fn start_lstart(pid: u32) -> Reading<String> {
    ps_column(pid, "lstart").map(|text| format!("lstart:{text}"))
}

/// The form a recorded start is written in, so a reader matches a live pid's
/// start in the same form. The runtime writes the host form; a legacy shell
/// writer records the bare `ps -o lstart` text; the non-Linux reader records
/// `lstart:`. All three are admitted (decision 55).
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

/// A live pid's start read in `form` and normalized.
fn start_in_form(pid: u32, form: StartForm) -> Reading<String> {
    let read = match form {
        StartForm::Ticks => start_ticks(pid),
        StartForm::Lstart => start_lstart(pid),
    };
    read.map(|start| normalize_start(&start))
}

/// The process group holding the terminal of `pane_pid`'s process: the
/// group whose members read the pane's keystrokes, `None` for a live
/// process with no controlling terminal.
pub fn foreground_group(pane_pid: u32) -> Reading<Option<u32>> {
    #[cfg(target_os = "linux")]
    {
        stat_of(pane_pid).map(|stat| u32::try_from(stat.tpgid).ok())
    }
    #[cfg(not(target_os = "linux"))]
    {
        match ps_column(pane_pid, "tpgid") {
            Reading::Live(text) => match text.parse::<i64>() {
                Ok(group) => Reading::Live(u32::try_from(group).ok()),
                Err(_) => Reading::Unreadable {
                    cause: "ps-unparsed",
                },
            },
            Reading::Gone => Reading::Gone,
            Reading::Unreadable { cause } => Reading::Unreadable { cause },
        }
    }
}

/// Whether the process this identity names still runs: live under the
/// recorded start, carried back as `Live`. `Gone` when no live process
/// holds the pid, and also when the pid now carries another start: the
/// recorded process ended either way, and [`identity`] tells the two apart
/// for a caller that needs to. The recorded start is read in its own form,
/// so a `ticks:`, an `lstart:` and a bare legacy start each match the live
/// pid they name (decision 55).
pub fn still_runs(id: &Identity) -> Reading<Identity> {
    match identity(id.pid) {
        Reading::Live(_) => {}
        Reading::Gone => return Reading::Gone,
        Reading::Unreadable { cause } => return Reading::Unreadable { cause },
    }
    match start_in_form(id.pid, start_form(&id.start)) {
        Reading::Live(start) if start == normalize_start(&id.start) => Reading::Live(id.clone()),
        Reading::Live(_) | Reading::Gone => Reading::Gone,
        Reading::Unreadable { cause } => Reading::Unreadable { cause },
    }
}

/// One read of the whole process table. A process that exits during the
/// listing is left out, and so is one that has exited and waits for its
/// parent (a zombie), which holds its pid and runs nothing: the `/proc`
/// read answers it gone, and the `ps` read drops its `Z` row. One entry
/// that cannot be read or parsed makes the whole table unreadable (decision
/// 99), since a decision over an incomplete table could select the wrong
/// process.
pub fn table() -> std::result::Result<Vec<Row>, Unreadable> {
    #[cfg(target_os = "linux")]
    {
        let unreadable = Unreadable {
            cause: "proc-unreadable",
        };
        let mut readings = Vec::new();
        for entry in fs::read_dir("/proc").map_err(|_| unreadable)? {
            let entry = entry.map_err(|_| unreadable)?;
            let Some(pid) = entry
                .file_name()
                .to_str()
                .and_then(|n| n.parse::<u32>().ok())
            else {
                continue;
            };
            readings.push((pid, stat_of(pid)));
        }
        table_of(readings)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let output = ps(
            "ps-table",
            &[
                "-A", "-o", "pid=", "-o", "ppid=", "-o", "pgid=", "-o", "stat=", "-o", "comm=",
            ],
        )
        .map_err(|_| Unreadable {
            cause: "ps-unavailable",
        })?;
        if !output.status.success() {
            return Err(Unreadable {
                cause: status_cause(output.status),
            });
        }
        let text = String::from_utf8_lossy(&output.stdout);
        let mut rows = Vec::new();
        for line in text.lines().filter(|l| !l.trim().is_empty()) {
            let mut parts = line.split_whitespace();
            let (Some(pid), Some(ppid), Some(pgrp), Some(stat)) = (
                parts.next().and_then(|p| p.parse().ok()),
                parts.next().and_then(|p| p.parse().ok()),
                parts.next().and_then(|p| p.parse().ok()),
                parts.next(),
            ) else {
                return Err(Unreadable {
                    cause: "ps-unparsed",
                });
            };
            if stat.starts_with('Z') {
                continue;
            }
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
        if rows.is_empty() {
            return Err(Unreadable { cause: "ps-empty" });
        }
        Ok(rows)
    }
}

/// The table from each listed pid's stat reading: an exited process is left
/// out, an unreadable one fails the whole table.
#[cfg(target_os = "linux")]
fn table_of(readings: Vec<(u32, Reading<Stat>)>) -> std::result::Result<Vec<Row>, Unreadable> {
    let mut rows = Vec::new();
    for (pid, reading) in readings {
        match reading {
            Reading::Live(stat) => rows.push(Row {
                pid,
                ppid: stat.ppid,
                pgrp: stat.pgrp,
                name: stat.name,
            }),
            Reading::Gone => {}
            Reading::Unreadable { cause } => return Err(Unreadable { cause }),
        }
    }
    Ok(rows)
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

/// What an exact stop did. A caller that drops it has not learned whether
/// the process ended (decision 105).
#[must_use]
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
    /// A read the stop depends on failed at `pid`, so whether that process
    /// runs is not known; nothing was signalled past that read. `signalled`
    /// says whether any signal was sent before it: a stop that sent none left
    /// every target as it found it.
    Unreadable {
        pid: u32,
        cause: String,
        signalled: bool,
    },
}

fn unreadable(pid: u32, cause: &'static str, signalled: bool) -> Stop {
    Stop::Unreadable {
        pid,
        cause: cause.to_owned(),
        signalled,
    }
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
/// changed between reads is left alone; one whose read fails ends the stop
/// as `Unreadable`, since a process that cannot be read cannot be confirmed
/// ended.
pub fn stop_identities(targets: &[Identity], grace: Duration) -> Result<Stop> {
    let mut live: Vec<Identity> = Vec::new();
    for t in targets {
        match still_runs(t) {
            Reading::Live(_) => live.push(t.clone()),
            Reading::Gone => {}
            Reading::Unreadable { cause } => return Ok(unreadable(t.pid, cause, false)),
        }
    }
    // Whether any signal has been sent: an unreadable read before the first
    // one leaves every target as it was.
    let mut sent = false;
    if live.is_empty() {
        return Ok(Stop::AlreadyGone);
    }
    let signaled = live.len() as u32;
    for sig in ["TERM", "KILL"] {
        let mut remaining = Vec::new();
        for id in &live {
            match still_runs(id) {
                Reading::Live(_) => {}
                Reading::Gone => continue,
                Reading::Unreadable { cause } => return Ok(unreadable(id.pid, cause, sent)),
            }
            let delivered = signal(id.pid, sig)?;
            sent = true;
            if !delivered {
                match still_runs(id) {
                    Reading::Live(_) => {
                        return Err(Error::Process {
                            operation: "signal",
                            pid: id.pid,
                            cause: format!("SIG{sig} refused"),
                        });
                    }
                    Reading::Gone => continue,
                    Reading::Unreadable { cause } => return Ok(unreadable(id.pid, cause, sent)),
                }
            }
            remaining.push(id.clone());
        }
        let deadline = Instant::now() + grace;
        loop {
            let mut unread = None;
            remaining.retain(|id| match still_runs(id) {
                Reading::Live(_) => true,
                Reading::Gone => false,
                Reading::Unreadable { cause } => {
                    unread = Some((id.pid, cause));
                    true
                }
            });
            if remaining.is_empty() {
                break;
            }
            if Instant::now() >= deadline {
                if let Some((pid, cause)) = unread {
                    return Ok(unreadable(pid, cause, sent));
                }
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

/// Stop one recorded identity and the harness-named processes below it,
/// each only while its start still matches. The recorded identity is the
/// harness, so it is always a target. `IdentityStale` when the pid runs
/// something else now; `Unreadable` when a read the stop depends on failed,
/// nothing signalled past it.
pub fn stop_tree(root: &Identity, matches: &dyn Fn(&str) -> bool, grace: Duration) -> Result<Stop> {
    match still_runs(root) {
        Reading::Live(_) => {}
        Reading::Gone => {
            return Ok(match identity(root.pid) {
                Reading::Live(_) => Stop::IdentityStale,
                Reading::Gone => Stop::AlreadyGone,
                Reading::Unreadable { cause } => unreadable(root.pid, cause, false),
            });
        }
        Reading::Unreadable { cause } => return Ok(unreadable(root.pid, cause, false)),
    }
    let rows = match table() {
        Ok(rows) => rows,
        Err(Unreadable { cause }) => return Ok(unreadable(root.pid, cause, false)),
    };
    let mut targets = vec![root.clone()];
    for (_, pid) in below(&rows, root.pid, matches) {
        if pid == root.pid {
            continue;
        }
        match identity(pid) {
            Reading::Live(id) => targets.push(id),
            Reading::Gone => {}
            Reading::Unreadable { cause } => return Ok(unreadable(pid, cause, false)),
        }
    }
    stop_identities(&targets, grace)
}

#[cfg(test)]
mod tests {
    use std::path::Path;

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

    /// A child this test holds: its pid is nobody else's while the test
    /// reads it, and it is killed and reaped on drop whatever the test
    /// asserted, so a failed assertion leaves nothing behind.
    struct Held(std::process::Child);

    impl Held {
        fn spawn(command: &mut Command) -> Held {
            Held(command.spawn().unwrap())
        }

        fn sleep() -> Held {
            Held::spawn(Command::new("sleep").arg("30"))
        }

        fn pid(&self) -> u32 {
            self.0.id()
        }

        /// Tell the child to exit and wait until the kernel reads it gone,
        /// bounded; it stays unreaped, so its pid is still held.
        fn kill_and_await_gone(&mut self) {
            self.0.kill().unwrap();
            await_gone(self.pid());
        }
    }

    impl Drop for Held {
        fn drop(&mut self) {
            // An already-ended child refuses the kill; the wait reaps it
            // either way.
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    /// A start in the same form as `live`, the host's own, that no process
    /// here carried: a mismatch that is read and refused, never an
    /// unsupported form.
    fn mismatched_start(live: &str) -> String {
        let mismatch = match start_form(live) {
            StartForm::Ticks => "ticks:0".to_owned(),
            StartForm::Lstart => "lstart:Thu Jan  1 00:00:00 1970".to_owned(),
        };
        assert_ne!(normalize_start(live), normalize_start(&mismatch));
        mismatch
    }

    fn await_gone(pid: u32) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while identity(pid) != Reading::Gone {
            assert!(Instant::now() < deadline, "the child never read gone");
            std::thread::sleep(Duration::from_millis(10));
        }
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
    fn stat_line(name: &str, state: &str) -> String {
        let mut fields: Vec<String> = (3..=52).map(|n| n.to_string()).collect();
        fields[0] = state.to_owned(); // 3: state
        fields[1] = "41".to_owned(); // 4: ppid
        fields[2] = "42".to_owned(); // 5: pgrp
        fields[5] = "4567".to_owned(); // 8: tpgid
        fields[19] = "9912345".to_owned(); // 22: starttime
        format!("42 ({name}) {}", fields.join(" "))
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn parse_stat_reads_the_name_state_parent_foreground_group_and_start() {
        let stat = parse_stat(&stat_line("my script", "S")).expect("parsed");
        assert_eq!(stat.name, "my script");
        assert_eq!(stat.state, 'S');
        assert_eq!(stat.ppid, 41);
        assert_eq!(stat.pgrp, 42);
        assert_eq!(stat.tpgid, 4567);
        assert_eq!(stat.start, "ticks:9912345");
        // No controlling terminal: the kernel writes -1, read as no group.
        let line = stat_line("x", "S").replace(" 4567 ", " -1 ");
        assert_eq!(parse_stat(&line).unwrap().tpgid, -1);
        assert!(
            parse_stat("42 (x) S 1").is_none(),
            "a short line parses to nothing"
        );
    }

    /// Decision 99: the three readings of one `/proc` stat read, from the
    /// kernel's answers as planted. No entry and an exited process are
    /// `Gone`; a refused read and an unparsable line are `Unreadable` with
    /// their causes, never an absence.
    #[cfg(target_os = "linux")]
    #[test]
    fn a_stat_read_is_live_gone_or_unreadable_by_what_the_kernel_answered() {
        use std::io::{Error as Io, ErrorKind};
        assert!(matches!(
            stat_reading(Ok(stat_line("claude", "S"))),
            Reading::Live(Stat { ref name, .. }) if name == "claude"
        ));
        assert_eq!(
            stat_reading(Ok(stat_line("claude", "Z"))),
            Reading::Gone,
            "an exited process awaiting its parent"
        );
        assert_eq!(
            stat_reading(Err(Io::from(ErrorKind::NotFound))),
            Reading::Gone
        );
        assert_eq!(
            stat_reading(Err(Io::from_raw_os_error(3))),
            Reading::Gone,
            "ESRCH for a process that exited mid-listing"
        );
        assert_eq!(
            stat_reading(Err(Io::from(ErrorKind::PermissionDenied))),
            Reading::Unreadable {
                cause: "stat-unreadable"
            }
        );
        assert_eq!(
            stat_reading(Ok("not a stat line".to_owned())),
            Reading::Unreadable {
                cause: "stat-unparsed"
            }
        );
    }

    /// Decision 99: a table is read whole or not at all. A process that
    /// exited mid-listing is left out; one entry that could not be read
    /// fails the table with that entry's cause.
    #[cfg(target_os = "linux")]
    #[test]
    fn a_table_leaves_out_an_exited_entry_and_is_unreadable_with_an_unread_one() {
        let live = |pid: u32| (pid, stat_reading(Ok(stat_line("claude", "S"))));
        let table = table_of(vec![live(1), (2, Reading::Gone), live(3)]).expect("readable");
        assert_eq!(table.iter().map(|r| r.pid).collect::<Vec<_>>(), vec![1, 3]);
        assert_eq!(
            table_of(vec![
                live(1),
                (
                    2,
                    Reading::Unreadable {
                        cause: "stat-unreadable"
                    }
                ),
                live(3),
            ]),
            Err(Unreadable {
                cause: "stat-unreadable"
            })
        );
    }

    /// The test-owned `ps` at `tests/rust/fixtures/fake-ps/ps`, found first
    /// on the child's `PATH` and asked the reader's own `-o lstart= -p`
    /// question; the pid chooses its answer (the script lists them). The
    /// production runner carries the status back whole.
    fn fake_ps(pid: u32) -> Output {
        let fixtures = Path::new(env!("CARGO_MANIFEST_DIR")).join("../tests/rust/fixtures/fake-ps");
        let mut path = fixtures.into_os_string();
        if let Some(rest) = std::env::var_os("PATH") {
            path.push(":");
            path.push(rest);
        }
        let env: [(&str, &OsStr); 1] = [("PATH", &path)];
        run_with(
            "ps",
            "fake-ps",
            &["-o", "lstart=", "-p", &pid.to_string()],
            &env,
            None,
            PS_TIMEOUT,
        )
        .expect("the fake ps runs")
    }

    /// Decision 105: the readings of a `ps -p` answer by its real exit
    /// status, from a fake `ps` on `PATH`. A row under exit 0 is live. The
    /// documented no-match answer, exit 1 with nothing on either stream, is
    /// gone. A `ps` killed by a signal, one exiting 2, a usage error written
    /// under exit 1 and a successful run that printed no row are each
    /// unreadable with a cause naming what happened, never an absence.
    #[test]
    fn a_ps_answer_is_live_gone_or_unreadable_by_its_exit_status_and_streams() {
        let rows: [(u32, Reading<String>); 6] = [
            (1, Reading::Live("Thu Jan 1 00:00:00 1970".to_owned())),
            (2, Reading::Gone),
            (
                4,
                Reading::Unreadable {
                    cause: "ps-signal-9",
                },
            ),
            (3, Reading::Unreadable { cause: "ps-exit-2" }),
            (5, Reading::Unreadable { cause: "ps-exit-1" }),
            (6, Reading::Unreadable { cause: "ps-empty" }),
        ];
        for (pid, expected) in rows {
            let output = fake_ps(pid);
            assert_eq!(
                ps_reading(&output),
                expected,
                "pid {pid}: status {:?}, stdout {:?}, stderr {:?}",
                output.status,
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        }
        assert!(
            fake_ps(4).status.signal() == Some(9),
            "the fixture's signalled answer is a real signal status"
        );
    }

    #[test]
    fn the_table_names_a_child_this_test_owns_in_its_own_group() {
        use std::os::unix::process::CommandExt;
        let child = Held::spawn(Command::new("sleep").arg("30").process_group(0));
        let rows = table().expect("a readable table");
        let row = rows
            .iter()
            .find(|r| r.pid == child.pid())
            .expect("the child's row");
        assert_eq!(row.name, "sleep");
        assert_eq!(row.ppid, std::process::id());
        assert_eq!(row.pgrp, child.pid(), "a new group led by the child");
    }

    /// A child that exited and stands unreaped holds its pid as a zombie:
    /// the table leaves it out and its identity reads gone, so a group
    /// read by pgid never holds on a member only its parent's reap would
    /// end (decision 124l (47)).
    #[cfg(target_os = "linux")]
    #[test]
    fn the_table_leaves_an_unreaped_exited_child_out() {
        let child = Held::spawn(&mut Command::new("true"));
        let pid = child.pid();
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let state = fs::read_to_string(format!("/proc/{pid}/stat"))
                .ok()
                .and_then(|text| parse_stat(&text))
                .map(|stat| stat.state);
            if state == Some('Z') {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "the child never read Z: {state:?}"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        let rows = table().expect("a readable table");
        assert!(
            !rows.iter().any(|r| r.pid == pid),
            "the zombie is no row of the table"
        );
        assert_eq!(identity(pid), Reading::Gone);
        drop(child);
    }

    #[test]
    fn only_shells_below_reads_an_exited_harness_pane_as_shells() {
        let t = rows(&[(20, 1, "bash"), (21, 20, "zsh"), (22, 21, "sh")]);
        assert!(only_shells_below(&t, 20));
        let t = rows(&[(20, 1, "bash"), (21, 20, "claude")]);
        assert!(!only_shells_below(&t, 20));
    }

    /// Decision 99 on a real process: a child this test holds reads live
    /// under its identity, and once it has exited, still held unreaped so
    /// its pid is nobody else's, reads gone. A recorded start the pid never
    /// carried, in the host's own form, reads gone through `still_runs`
    /// while the process runs.
    #[test]
    fn a_held_child_reads_live_then_gone_once_it_exited_and_a_stale_start_never_runs() {
        let mut child = Held::sleep();
        let pid = child.pid();
        let Reading::Live(id) = identity(pid) else {
            panic!("a held child is live");
        };
        assert_eq!(id.pid, pid);
        assert_eq!(still_runs(&id), Reading::Live(id.clone()));
        let stale = Identity {
            pid,
            start: mismatched_start(&id.start),
        };
        assert_eq!(still_runs(&stale), Reading::Gone);
        child.kill_and_await_gone();
        assert_eq!(still_runs(&id), Reading::Gone);
    }

    /// The `ticks:` start form is `/proc`'s: Linux reads it, so a ticks
    /// start the pid never carried is gone there; a host without `/proc`
    /// cannot read the form at all, so the same identity is unreadable with
    /// its cause, never gone (M2 of R-U4a5).
    #[test]
    fn a_ticks_start_is_read_on_linux_and_unreadable_elsewhere() {
        let child = Held::sleep();
        let ticks = Identity {
            pid: child.pid(),
            start: "ticks:0".to_owned(),
        };
        #[cfg(target_os = "linux")]
        {
            assert_eq!(still_runs(&ticks), Reading::Gone);
            let Reading::Live(id) = identity(child.pid()) else {
                panic!("a held child is live");
            };
            assert!(id.start.starts_with("ticks:"), "{:?}", id.start);
            assert_eq!(still_runs(&id), Reading::Live(id.clone()));
        }
        #[cfg(not(target_os = "linux"))]
        assert_eq!(
            still_runs(&ticks),
            Reading::Unreadable {
                cause: "ticks-unavailable"
            }
        );
    }

    /// Decision 55: one reader admits every start form a shipped writer
    /// produced. A `ticks:`, an `lstart:` and a bare `ps -o lstart` start
    /// each match the live process they name, and any other value is `Gone`.
    #[test]
    fn still_runs_matches_every_shipped_start_form_and_rejects_a_mismatch() {
        let me = std::process::id();
        // The lstart text a legacy shell writer records bare, and the
        // non-Linux reader records with an `lstart:` prefix.
        let Reading::Live(prefixed) = start_lstart(me) else {
            panic!("own lstart");
        };
        let bare = prefixed
            .strip_prefix("lstart:")
            .expect("lstart prefix")
            .to_owned();
        // The host form the runtime itself records (ticks on Linux).
        let Reading::Live(native) = identity(me) else {
            panic!("own identity");
        };
        for form in [native.start.clone(), prefixed.clone(), bare.clone()] {
            let id = Identity {
                pid: me,
                start: form.clone(),
            };
            assert_eq!(still_runs(&id), Reading::Live(id.clone()), "form {form:?}");
        }
        // A start in the host's own form that this process never carried.
        let mismatch = Identity {
            pid: me,
            start: mismatched_start(&native.start),
        };
        assert_eq!(still_runs(&mismatch), Reading::Gone);
        // A mismatch in the lstart form, read on every host, is `Gone` too.
        let wrong = Identity {
            pid: me,
            start: "lstart:Thu Jan  1 00:00:00 1970".to_owned(),
        };
        assert_eq!(still_runs(&wrong), Reading::Gone);
    }

    #[test]
    fn stopping_a_child_this_test_owns_ends_it_exactly_once() {
        let mut child = Held::sleep();
        let Reading::Live(id) = identity(child.pid()) else {
            panic!("a held child is live");
        };
        let stop = stop_identities(std::slice::from_ref(&id), Duration::from_secs(5)).unwrap();
        assert_eq!(stop, Stop::Stopped { signaled: 1 });
        child.0.wait().unwrap();
        // A second stop of the ended identity signals nothing.
        assert_eq!(
            stop_identities(std::slice::from_ref(&id), Duration::from_secs(1)).unwrap(),
            Stop::AlreadyGone
        );
    }
}
