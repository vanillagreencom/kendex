//! Process identity and the exact stop.
//!
//! A pid alone names nothing durable: the kernel reuses it. An `Identity` is
//! a pid with the start time the kernel recorded for it, and every signal
//! sent here is sent only while the live process still carries that start.
//! On Linux the start is the `starttime` field of `/proc/<pid>/stat`, in
//! clock ticks since boot, read as a file; elsewhere it is the `lstart`
//! column of `ps`, which is the one portable spelling. A recorded start is
//! read back in its own form, `ticks:` or `lstart:`, so each matches the
//! process it names; a start in neither form is unreadable, `start-form`.
//!
//! Every read here answers with a [`Reading`]: the process
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

// Every reading here is matched variant by variant: a
// wildcard arm would let a later variant fall into an absence.
#![deny(clippy::wildcard_enum_match_arm)]

use std::collections::HashMap;
use std::ffi::OsStr;
use std::fs;
use std::os::unix::process::ExitStatusExt;
use std::path::Path;
use std::process::{ExitStatus, Output};
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::error::{Error, Result};
use crate::host::{self, run_with};
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

/// `USER_HZ`, 100 on every Linux architecture (`include/asm-generic/
/// param.h`): the unit of the `ticks:` start the identity reader records and
/// of the CPU times `/proc/<pid>/stat` reports.
pub(crate) const USER_HZ: u64 = 100;

/// The fields of one `/proc/<pid>/stat` line this crate reads: the command
/// name inside the parentheses, then, counted after them, the state (field
/// 3), the parent pid (4), the process group (5), the foreground process
/// group of the controlling terminal (8, `-1` without one), the CPU times in
/// clock ticks (14 to 17: user and system, then those of the children it
/// reaped), the start in clock ticks since boot (22) and the resident set in
/// pages (24).
#[cfg(target_os = "linux")]
#[derive(Debug, PartialEq, Eq)]
struct Stat {
    name: String,
    state: char,
    ppid: u32,
    pgrp: u32,
    tpgid: i64,
    /// `None` where a CPU field is no whole number: only the tree reader
    /// needs them, so a line it cannot sum still answers every other read.
    cpu_ticks: Option<u64>,
    start: String,
    /// `None` where the field is no whole number, as `cpu_ticks`.
    rss_pages: Option<u64>,
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
    let cpu_ticks = fields
        .get(11..15)?
        .iter()
        .try_fold(0u64, |sum, field| sum.checked_add(field.parse().ok()?));
    let rss_pages = fields.get(21).and_then(|field| field.parse().ok());
    Some(Stat {
        name,
        state,
        ppid,
        pgrp,
        tpgid,
        cpu_ticks,
        start: format!("ticks:{start}"),
        rss_pages,
    })
}

/// The kernel's page size in bytes, the unit of a stat line's resident set,
/// from this process's auxiliary vector: `AT_PAGESZ` (`getauxval(3)`), read
/// as `proc(5)` lays `/proc/self/auxv` out, one native `unsigned long` type
/// and one value per entry. Read once; the size is fixed while a host runs.
#[cfg(target_os = "linux")]
fn page_bytes() -> std::result::Result<u64, Unreadable> {
    static PAGE: std::sync::OnceLock<Option<u64>> = std::sync::OnceLock::new();
    PAGE.get_or_init(|| {
        fs::read("/proc/self/auxv")
            .ok()
            .and_then(|auxv| page_size(&auxv))
    })
    .ok_or(Unreadable {
        cause: "page-size-unread",
    })
}

#[cfg(target_os = "linux")]
fn page_size(auxv: &[u8]) -> Option<u64> {
    /// `AT_PAGESZ` in `include/uapi/linux/auxvec.h`.
    const AT_PAGESZ: usize = 6;
    let word = std::mem::size_of::<usize>();
    auxv.chunks_exact(2 * word).find_map(|entry| {
        let (key, value) = entry.split_at(word);
        if usize::from_ne_bytes(key.try_into().ok()?) != AT_PAGESZ {
            return None;
        }
        u64::try_from(usize::from_ne_bytes(value.try_into().ok()?))
            .ok()
            .filter(|bytes| *bytes > 0)
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
    // A task being reaped (`X`) writes its process group and session as
    // -1, which no group parses from; its state alone says it is gone, as a
    // zombie's does.
    if matches!(stat_state(&text), Some('Z' | 'X')) {
        return Reading::Gone;
    }
    match parse_stat(&text) {
        None => Reading::Unreadable {
            cause: "stat-unparsed",
        },
        Some(stat) => Reading::Live(stat),
    }
}

/// The state field of a stat line: the first field after the command
/// name's closing parenthesis.
#[cfg(target_os = "linux")]
fn stat_state(stat: &str) -> Option<char> {
    let close = stat.rfind(')')?;
    stat[close + 1..].split_whitespace().next()?.chars().next()
}

#[cfg(target_os = "linux")]
fn stat_of(pid: u32) -> Reading<Stat> {
    stat_reading(fs::read_to_string(format!("/proc/{pid}/stat")))
}

/// What a `ps -p <pid>` answer says, from its exit status and both streams.
/// A row under exit 0 is `Live`, its blanks squeezed. `Gone`
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

/// A capped control group's charge and its cap. The charge counts every
/// process under the group, so it is the figure the cap is enforced on.
/// `oom_kill` is the OOM kills the caps read have made, from their
/// `memory.events` `oom_kill`, `None` where one of them could not be read,
/// which is no count of zero.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Memory {
    pub current: u64,
    pub max: u64,
    pub oom_kill: Option<u64>,
}

impl Memory {
    fn fuller_than(self, other: Memory) -> bool {
        u128::from(self.current) * u128::from(other.max)
            > u128::from(other.current) * u128::from(self.max)
    }
}

/// The capped group on the path of the control group `pid` runs in, under
/// `cgroup_root`, that stands nearest its cap, read with that group's own
/// charge: any cap on the path ends the process when its group fills.
/// `Live(None)` where no cap stands on the path, so a reading there decides
/// nothing; `Gone` where `proc_root` holds no such pid; unreadable where the
/// group, a cap on the path or a capped group's charge could not be read or
/// parsed, which is never a reading of zero. A `memory.max` of `max` is no
/// cap; the root of the tree keeps none. The OOM kill count is read beside
/// the charge and leaves the charge's reading standing where it is unread.
pub fn memory_of(proc_root: &Path, cgroup_root: &Path, pid: u32) -> Reading<Option<Memory>> {
    caps_of(proc_root, cgroup_root, pid).map(|(caps, oom_kill)| {
        caps.into_iter()
            .reduce(|fullest, capped| {
                if capped.fuller_than(fullest) {
                    capped
                } else {
                    fullest
                }
            })
            .map(|fullest| Memory {
                oom_kill,
                ..fullest
            })
    })
}

/// The one control group on `pid`'s path whose cap a reading judges.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Level<'a> {
    /// The group the process runs in.
    Own,
    /// The nearest group on the path, the process's own included, whose
    /// directory carries this name, such as `tmux.service`.
    Named(&'a str),
}

/// The cap of the one group `level` picks on the path of the control group
/// `pid` runs in, under `cgroup_root`, read with that group's own charge
/// and its own `memory.events` `oom_kill`. Unlike [`memory_of`], no other
/// cap on the path is read: a parent slice every session shares fills with
/// the others' memory, and a hand-over frees none of it. `Live(None)`
/// where that group keeps no cap; `Gone` where `proc_root` holds no such
/// pid; unreadable where the group, its cap or its charge could not be
/// read or parsed, and `cgroup-level-off-path` where no group on the path
/// carries the named level, which is never a group without a cap.
pub fn memory_at(
    proc_root: &Path,
    cgroup_root: &Path,
    pid: u32,
    level: Level,
) -> Reading<Option<Memory>> {
    let path = match group_of(proc_root, pid) {
        Reading::Live(path) => path,
        Reading::Gone => return Reading::Gone,
        Reading::Unreadable { cause } => return Reading::Unreadable { cause },
    };
    let judged = match level {
        Level::Own => Path::new(path.as_str()),
        Level::Named(name) => match Path::new(path.as_str())
            .ancestors()
            .find(|group| group.file_name() == Some(OsStr::new(name)))
        {
            Some(group) => group,
            None => {
                return Reading::Unreadable {
                    cause: "cgroup-level-off-path",
                };
            }
        },
    };
    let dir = cgroup_root.join(judged);
    match cap_at(&dir) {
        Ok(Some(memory)) => Reading::Live(Some(Memory {
            oom_kill: kills(&dir),
            ..memory
        })),
        Ok(None) => Reading::Live(None),
        Err(cause) => Reading::Unreadable { cause },
    }
}

/// The memory a new process tree in `pid`'s control group can take now, in
/// bytes: the host's available memory or the least headroom under a cap on
/// the group's path, whichever is smaller, since any cap on the path ends
/// the tree when its group fills. The host's figure is `MemAvailable` of
/// `<proc_root>/meminfo`, the kernel's estimate of what can be allocated
/// without swapping (`proc_meminfo(5)`). Unreadable, never a size, where
/// either reading is: a host with no `meminfo`, any host but Linux, is
/// `host-room-unread`.
pub fn room(
    proc_root: &Path,
    cgroup_root: &Path,
    pid: u32,
) -> std::result::Result<u64, Unreadable> {
    let unreadable = |cause: &'static str| Unreadable { cause };
    let available = match fs::read_to_string(proc_root.join("meminfo")) {
        Ok(text) => mem_available(&text).ok_or(unreadable("meminfo-unparsed"))?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Err(unreadable("host-room-unread"));
        }
        Err(_) => return Err(unreadable("meminfo-unreadable")),
    };
    let caps = match caps_of(proc_root, cgroup_root, pid) {
        Reading::Live((caps, _)) => caps,
        Reading::Gone => return Err(unreadable("pid-gone")),
        Reading::Unreadable { cause } => return Err(unreadable(cause)),
    };
    Ok(caps
        .iter()
        .map(|cap| cap.max.saturating_sub(cap.current))
        .fold(available, u64::min))
}

/// `MemAvailable` in bytes from a `meminfo` text, which states it in kB.
fn mem_available(meminfo: &str) -> Option<u64> {
    let figure = meminfo
        .lines()
        .find_map(|line| line.strip_prefix("MemAvailable:"))?;
    figure
        .trim()
        .strip_suffix(" kB")?
        .trim()
        .parse::<u64>()
        .ok()?
        .checked_mul(1024)
}

/// Every capped group on the path of the control group `pid` runs in, under
/// `cgroup_root`, nearest first, each with its own charge, and the sum of
/// their `memory.events` `oom_kill`, `None` where one of them could not be
/// read; the readings [`memory_of`] states.
fn caps_of(proc_root: &Path, cgroup_root: &Path, pid: u32) -> Reading<(Vec<Memory>, Option<u64>)> {
    let path = match group_of(proc_root, pid) {
        Reading::Live(path) => path,
        Reading::Gone => return Reading::Gone,
        Reading::Unreadable { cause } => return Reading::Unreadable { cause },
    };
    let group = cgroup_root.join(path);
    let mut caps = Vec::new();
    let mut oom_kill = Some(0u64);
    let mut dir = group.as_path();
    loop {
        match cap_at(dir) {
            Ok(Some(cap)) => {
                oom_kill = oom_kill.zip(kills(dir)).map(|(sum, n)| sum + n);
                caps.push(cap);
            }
            Ok(None) => {}
            Err(cause) => return Reading::Unreadable { cause },
        }
        match dir.parent() {
            Some(parent) if dir != cgroup_root && parent.starts_with(cgroup_root) => dir = parent,
            Some(_) | None => return Reading::Live((caps, oom_kill)),
        }
    }
}

/// The path, below the v2 root, of the control group `pid` runs in, read
/// off `<proc_root>/<pid>/cgroup`.
fn group_of(proc_root: &Path, pid: u32) -> Reading<String> {
    let text = match fs::read_to_string(proc_root.join(pid.to_string()).join("cgroup")) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Reading::Gone,
        Err(_) => {
            return Reading::Unreadable {
                cause: "cgroup-unreadable",
            };
        }
    };
    // Only the v2 tree is read (`0::/<path>`): a host on the v1 hierarchy
    // alone reads unreadable, so a mark set there reports itself unmeasured
    // instead of judging a figure it never read.
    match text
        .lines()
        .find_map(|line| line.strip_prefix("0::"))
        .map(|path| path.trim_start_matches('/'))
    {
        Some(path) => Reading::Live(path.to_owned()),
        None => Reading::Unreadable {
            cause: "cgroup-v2-absent",
        },
    }
}

/// The cap of the group at `dir` with its charge, `oom_kill` unread;
/// `None` where the group keeps no cap, a `memory.max` of `max` or none at
/// all, as the root of the tree keeps none.
fn cap_at(dir: &Path) -> std::result::Result<Option<Memory>, &'static str> {
    let Some(max) = cgroup_figure(&dir.join("memory.max"))? else {
        return Ok(None);
    };
    match cgroup_figure(&dir.join("memory.current"))? {
        Some(current) => Ok(Some(Memory {
            current,
            max,
            oom_kill: None,
        })),
        None => Err("memory-current-unreadable"),
    }
}

/// One control-group figure: `None` for `max` or a file the group lacks.
fn cgroup_figure(file: &Path) -> std::result::Result<Option<u64>, &'static str> {
    match fs::read_to_string(file) {
        Ok(text) if text.trim() == "max" => Ok(None),
        Ok(text) => text
            .trim()
            .parse::<u64>()
            .map(Some)
            .map_err(|_| "cgroup-figure-unparsed"),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err("cgroup-file-unreadable"),
    }
}

/// The group's own `memory.events` `oom_kill`, `None` where it is unread.
fn kills(dir: &Path) -> Option<u64> {
    fs::read_to_string(dir.join("memory.events"))
        .ok()?
        .lines()
        .find_map(|line| line.strip_prefix("oom_kill "))?
        .trim()
        .parse()
        .ok()
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
/// on every host, so an `lstart`-form identity a shell writer recorded can
/// be matched on Linux too.
fn start_lstart(pid: u32) -> Reading<String> {
    ps_column(pid, "lstart").map(|text| format!("lstart:{text}"))
}

/// The form a recorded start is written in, so a reader matches a live pid's
/// start in the same form: the host form on Linux, `lstart:` where the
/// reader has no `/proc`.
enum StartForm {
    Ticks,
    Lstart,
}

/// The form of a recorded start and its comparable body: the digits after
/// `ticks:`, or the text after `lstart:` with its blanks squeezed, as
/// `ps -o lstart` pads it. `None` for a start in neither form.
fn recorded_start(recorded: &str) -> Option<(StartForm, String)> {
    if let Some(ticks) = recorded.strip_prefix("ticks:") {
        return Some((StartForm::Ticks, ticks.trim().to_owned()));
    }
    let text = recorded.strip_prefix("lstart:")?;
    Some((
        StartForm::Lstart,
        text.split_whitespace().collect::<Vec<_>>().join(" "),
    ))
}

/// A live pid's start read in `form`, its comparable body.
fn start_in_form(pid: u32, form: StartForm) -> Reading<String> {
    let read = match form {
        StartForm::Ticks => start_ticks(pid),
        StartForm::Lstart => start_lstart(pid),
    };
    read.map(|start| match recorded_start(&start) {
        Some((_, body)) => body,
        None => start,
    })
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
/// so a `ticks:` and an `lstart:` start each match the live pid they name;
/// a start in neither form is `Unreadable` with `start-form`.
pub fn still_runs(id: &Identity) -> Reading<Identity> {
    match identity(id.pid) {
        Reading::Live(_) => {}
        Reading::Gone => return Reading::Gone,
        Reading::Unreadable { cause } => return Reading::Unreadable { cause },
    }
    let Some((form, recorded)) = recorded_start(&id.start) else {
        return Reading::Unreadable {
            cause: "start-form",
        };
    };
    match start_in_form(id.pid, form) {
        Reading::Live(start) if start == recorded => Reading::Live(id.clone()),
        Reading::Live(_) | Reading::Gone => Reading::Gone,
        Reading::Unreadable { cause } => Reading::Unreadable { cause },
    }
}

/// One read of the whole process table. A process that exits during the
/// listing is left out, and so is one that has exited and waits for its
/// parent (a zombie), which holds its pid and runs nothing: the `/proc`
/// read answers it gone, and the `ps` read drops its `Z` row. One entry
/// that cannot be read or parsed makes the whole table unreadable, since a
/// decision over an incomplete table could select the wrong process.
pub fn table() -> std::result::Result<Vec<Row>, Unreadable> {
    #[cfg(target_os = "linux")]
    {
        table_of(proc_readings()?)
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

/// Every numbered `/proc` entry's stat reading, from one listing.
#[cfg(target_os = "linux")]
fn proc_readings() -> std::result::Result<Vec<(u32, Reading<Stat>)>, Unreadable> {
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
    Ok(readings)
}

/// A live process at or below a root, with the CPU time it used, user and
/// system, the children it has reaped included, and its resident memory. A
/// page two members share is in each one's resident size.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Member {
    pub id: Identity,
    pub cpu_ms: u64,
    pub rss_bytes: u64,
}

/// The live processes at or below `root` by their parent links, from one read
/// of the table, `root` first; empty where `root` no longer runs. Read whole
/// or not at all, as [`table`] is. A reaped child's CPU time is in its
/// parent's, so the members' sum falls only where a member exits unreaped
/// or leaves the tree. Linux only: elsewhere `tree-unread-here`.
pub fn tree(root: u32) -> std::result::Result<Vec<Member>, Unreadable> {
    #[cfg(target_os = "linux")]
    {
        tree_of(proc_readings()?, root, page_bytes()?)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = root;
        Err(Unreadable {
            cause: "tree-unread-here",
        })
    }
}

#[cfg(target_os = "linux")]
fn tree_of(
    readings: Vec<(u32, Reading<Stat>)>,
    root: u32,
    page_bytes: u64,
) -> std::result::Result<Vec<Member>, Unreadable> {
    let mut live = Vec::new();
    for (pid, reading) in readings {
        match reading {
            Reading::Live(stat) => live.push((pid, stat)),
            Reading::Gone => {}
            Reading::Unreadable { cause } => return Err(Unreadable { cause }),
        }
    }
    let mut children: HashMap<u32, Vec<usize>> = HashMap::new();
    for (index, (_, stat)) in live.iter().enumerate() {
        children.entry(stat.ppid).or_default().push(index);
    }
    // The entries are read one by one, so a pid freed and reused during the
    // listing can link two entries as each other's parent: each is visited
    // once.
    let mut visited = vec![false; live.len()];
    let mut queue: Vec<usize> = live
        .iter()
        .position(|(pid, _)| *pid == root)
        .into_iter()
        .collect();
    let mut members = Vec::new();
    while let Some(index) = queue.pop() {
        if std::mem::replace(&mut visited[index], true) {
            continue;
        }
        let (pid, stat) = &live[index];
        let ticks = stat.cpu_ticks.ok_or(Unreadable {
            cause: "cpu-unparsed",
        })?;
        let pages = stat.rss_pages.ok_or(Unreadable {
            cause: "rss-unparsed",
        })?;
        members.push(Member {
            id: Identity {
                pid: *pid,
                start: stat.start.clone(),
            },
            cpu_ms: ticks.saturating_mul(1000) / USER_HZ,
            rss_bytes: pages.saturating_mul(page_bytes),
        });
        queue.extend(children.get(pid).into_iter().flatten());
    }
    Ok(members)
}

/// Every live process's argument words, by pid, from one read: on Linux the
/// table's pids, each `/proc/<pid>/cmdline` split at its NUL bytes; elsewhere
/// `ps`'s `args` column, which joins the words with spaces, split again at
/// them. A process that exits while it is read, a zombie and a kernel thread
/// carry no words and are left out; a table that cannot be read is the cause.
pub fn command_lines() -> std::result::Result<Vec<(u32, Vec<String>)>, Unreadable> {
    #[cfg(target_os = "linux")]
    {
        Ok(table()?
            .into_iter()
            .filter_map(|row| {
                let bytes = fs::read(format!("/proc/{}/cmdline", row.pid)).ok()?;
                let words: Vec<String> = bytes
                    .split(|byte| *byte == 0)
                    .filter(|word| !word.is_empty())
                    .map(|word| String::from_utf8_lossy(word).into_owned())
                    .collect();
                (!words.is_empty()).then_some((row.pid, words))
            })
            .collect())
    }
    #[cfg(not(target_os = "linux"))]
    {
        let output =
            ps("ps-commands", &["-A", "-ww", "-o", "pid=", "-o", "args="]).map_err(|_| {
                Unreadable {
                    cause: "ps-unavailable",
                }
            })?;
        if !output.status.success() {
            return Err(Unreadable {
                cause: status_cause(output.status),
            });
        }
        Ok(String::from_utf8_lossy(&output.stdout)
            .lines()
            .filter_map(|line| {
                let mut words = line.split_whitespace();
                let pid = words.next()?.parse().ok()?;
                let words: Vec<String> = words.map(str::to_owned).collect();
                (!words.is_empty()).then_some((pid, words))
            })
            .collect())
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

pub fn is_shell(name: &str) -> bool {
    matches!(
        name.trim_start_matches('-'),
        "bash" | "zsh" | "fish" | "sh" | "dash"
    )
}

/// What an exact stop did. A caller that drops it has not learned whether
/// the process ended.
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

/// The bound on `kill`, which sends one signal and exits.
const KILL_TIMEOUT: Duration = Duration::from_secs(5);

/// Send `SIG<name>` to `pid` through the one runner, counted under
/// `signal`. `true` when `kill` delivered it; `false` when it refused,
/// as for a pid no process holds.
fn signal(pid: u32, name: &str) -> Result<bool> {
    let caller = host::Caller {
        program: "kill",
        operation: "kill",
        tag: Some("signal"),
    };
    let output = host::start(
        caller,
        OsStr::new("kill"),
        &[&format!("-{name}"), &pid.to_string()],
        host::Place::default(),
        None,
        false,
        KILL_TIMEOUT,
    )
    .map_err(|failed| Error::Process {
        operation: "kill",
        pid,
        cause: failed.cause(),
    })?;
    Ok(output.status.success())
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

/// The members of the process group `leader` leads, read in one table: every
/// row whose group is the leader's pid, the leader among them while it runs.
/// Once the leader reads gone, a member that still names its pid as its group
/// keeps the group live. A live process at the leader's pid ends the group:
/// the kernel frees a pid number only once no task holds it as its pid, its
/// group or its session, so a process that took the number, one that leads a
/// group of its own included, proves no member of the leader's group runs.
pub fn group_members(leader: &Identity) -> Reading<Vec<Row>> {
    group_table(leader).map(|rows| {
        rows.into_iter()
            .filter(|row| row.pgrp == leader.pid)
            .collect()
    })
}

/// The whole table [`group_members`] reads its members from, `Live` while
/// the group stands, so a reader that judges a process by its ancestors
/// reads them from the same table.
pub(crate) fn group_table(leader: &Identity) -> Reading<Vec<Row>> {
    let leader_runs = match still_runs(leader) {
        Reading::Live(_) => true,
        Reading::Gone => false,
        Reading::Unreadable { cause } => return Reading::Unreadable { cause },
    };
    let rows = match table() {
        Ok(rows) => rows,
        Err(Unreadable { cause }) => return Reading::Unreadable { cause },
    };
    if !leader_runs && rows.iter().any(|row| row.pid == leader.pid) {
        return Reading::Gone;
    }
    if leader_runs || rows.iter().any(|row| row.pgrp == leader.pid) {
        Reading::Live(rows)
    } else {
        Reading::Gone
    }
}

/// End every member of the group `leader` leads ([`group_members`]), each by
/// its own identity: TERM, the grace, then KILL. `AlreadyGone` where the
/// group reads gone; refused `stop-unreadable` where the group or a member's
/// identity cannot be read, nothing signalled.
pub fn stop_group(leader: &Identity, grace: Duration) -> Result<Stop> {
    let unreadable = |cause: &str| Error::refused("stop-unreadable", &[("cause", cause)]);
    let rows = match group_members(leader) {
        Reading::Live(rows) => rows,
        Reading::Gone => return Ok(Stop::AlreadyGone),
        Reading::Unreadable { cause } => return Err(unreadable(cause)),
    };
    let mut members = Vec::new();
    for row in rows {
        match identity(row.pid) {
            Reading::Live(id) => members.push(id),
            Reading::Gone => {}
            Reading::Unreadable { cause } => return Err(unreadable(cause)),
        }
    }
    stop_identities(&members, grace)
}

#[cfg(test)]
mod tests {
    use std::path::Path;
    use std::process::Command;

    use super::*;

    /// Held by every test that signals: the `kill` start count is
    /// process-wide, so two signalling tests at once would read each
    /// other's starts.
    static SIGNALLING: Mutex<()> = Mutex::new(());

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
        let mismatch = match recorded_start(live) {
            Some((StartForm::Ticks, _)) => "ticks:0".to_owned(),
            _ => "lstart:Thu Jan  1 00:00:00 1970".to_owned(),
        };
        let body = |start: &str| recorded_start(start).map(|(_, body)| body);
        assert_ne!(body(live), body(&mismatch));
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
        assert_eq!(stat.cpu_ticks, Some(14 + 15 + 16 + 17));
        assert_eq!(stat.start, "ticks:9912345");
        assert_eq!(stat.rss_pages, Some(24));
        // A CPU field that is no whole number leaves the line's other reads.
        let line = stat_line("x", "S").replace(" 16 ", " -1 ");
        let stat = parse_stat(&line).expect("parsed");
        assert_eq!((stat.ppid, stat.cpu_ticks), (41, None));
        // No controlling terminal: the kernel writes -1, read as no group.
        let line = stat_line("x", "S").replace(" 4567 ", " -1 ");
        assert_eq!(parse_stat(&line).unwrap().tpgid, -1);
        assert!(
            parse_stat("42 (x) S 1").is_none(),
            "a short line parses to nothing"
        );
    }

    /// The three readings of one `/proc` stat read, from the kernel's
    /// answers as planted. No entry and an exited process are
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
            stat_reading(Ok(
                "2412049 (sh) X 0 -1 -1 0 -1 4227084 171 0 0 0 0 0 0 0 20 0 0 0 21454565 0 0 0 0 0 0 0 0 0 0 0 0 1 0 0 17 16 0 0 0 0 0 0 0 0 0 0 0 0 0
".to_owned()
            )),
            Reading::Gone,
            "a task being reaped, its group and session written as -1"
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

    /// A table is read whole or not at all. A process that
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

    /// A tree holds the root and every process whose parent links reach it,
    /// each with its CPU time in milliseconds and its resident size in bytes
    /// at the page size given, and nothing outside it; an exited entry is
    /// left out, two entries a reused pid links as each other's parent are
    /// read once each, and one unreadable entry, CPU field or resident size
    /// anywhere fails the reading.
    #[cfg(target_os = "linux")]
    #[test]
    fn a_tree_holds_the_roots_descendants_with_their_cpu_and_memory_and_is_read_whole() {
        let entry = |pid: u32, ppid: u32, cpu: &str, rss: &str| {
            let line = stat_line("x", "S")
                .replacen("42 (x)", &format!("{pid} (x)"), 1)
                .replace(" 41 42 ", &format!(" {ppid} 42 "))
                .replace(" 14 15 16 17 ", &format!(" {cpu} 0 0 0 "))
                .replace(" 24 25 ", &format!(" {rss} 25 "));
            (pid, stat_reading(Ok(line)))
        };
        let readings = || {
            vec![
                entry(1, 0, "5", "7"),
                entry(10, 1, "250", "100"),
                entry(11, 10, "3", "2"),
                entry(12, 11, "0", "0"),
                entry(20, 1, "9", "50"),
                (13, Reading::Gone),
            ]
        };
        let mut members = tree_of(readings(), 10, 4096).expect("readable");
        members.sort_by_key(|m| m.id.pid);
        let read: Vec<(u32, u64, u64)> = members
            .iter()
            .map(|m| (m.id.pid, m.cpu_ms, m.rss_bytes))
            .collect();
        assert_eq!(read, vec![(10, 2500, 409_600), (11, 30, 8192), (12, 0, 0)]);
        assert_eq!(members[0].id.start, "ticks:9912345");
        assert!(tree_of(readings(), 99, 4096).expect("readable").is_empty());
        let looped = vec![entry(10, 11, "1", "1"), entry(11, 10, "1", "1")];
        assert_eq!(tree_of(looped, 10, 4096).expect("readable").len(), 2);
        let mut unread = readings();
        unread.push((
            30,
            Reading::Unreadable {
                cause: "stat-unreadable",
            },
        ));
        assert_eq!(
            tree_of(unread, 10, 4096),
            Err(Unreadable {
                cause: "stat-unreadable"
            })
        );
        for (field, cause) in [("cpu", "cpu-unparsed"), ("rss", "rss-unparsed")] {
            let mut uncounted = readings();
            uncounted.push(match field {
                "cpu" => entry(14, 12, "x", "1"),
                _ => entry(14, 12, "1", "x"),
            });
            assert_eq!(
                tree_of(uncounted, 10, 4096),
                Err(Unreadable { cause }),
                "{field}"
            );
        }
    }

    /// The page size is the `AT_PAGESZ` entry of an auxiliary vector in this
    /// host's word form, wherever it stands among the entries; a vector
    /// without one, or with a zero size, names none. This process's own
    /// vector names one.
    #[cfg(target_os = "linux")]
    #[test]
    fn the_page_size_is_the_auxiliary_vectors_page_entry() {
        let vector = |entries: &[(usize, usize)]| -> Vec<u8> {
            entries
                .iter()
                .flat_map(|(key, value)| [key.to_ne_bytes(), value.to_ne_bytes()].concat())
                .collect()
        };
        assert_eq!(
            page_size(&vector(&[(3, 64), (6, 16384), (0, 0)])),
            Some(16384)
        );
        assert_eq!(page_size(&vector(&[(3, 64), (0, 0)])), None);
        assert_eq!(page_size(&vector(&[(6, 0), (0, 0)])), None);
        assert!(page_bytes().is_ok_and(|bytes| bytes.is_power_of_two()));
    }

    /// The room is the host's available memory or the least headroom under
    /// a cap on the group's path, whichever is smaller: a farther cap with
    /// less room than the nearest one bounds it, and a group past its cap
    /// leaves none. A reading that cannot be made names its cause and is
    /// never a size.
    #[test]
    fn the_room_is_the_smaller_of_the_hosts_available_memory_and_the_least_headroom_under_a_cap() {
        const GIB: u64 = 1 << 30;
        /// Each group of the path, `a` then `a/b`, with its cap and charge,
        /// or none for a group with no cap.
        type Groups = [Option<(u64, u64)>; 2];
        let caps = |a, ab| -> Groups { [a, ab] };
        let cases = [
            ("uncapped", Some("8388608"), caps(None, None), Ok(8 * GIB)),
            (
                "the farther cap has less room",
                Some("8388608"),
                caps(Some((10 * GIB, 9 * GIB)), Some((4 * GIB, GIB))),
                Ok(GIB),
            ),
            (
                "the nearest cap has less room",
                Some("8388608"),
                caps(Some((10 * GIB, GIB)), Some((4 * GIB, 2 * GIB))),
                Ok(2 * GIB),
            ),
            (
                "the host has less room than any cap",
                Some("524288"),
                caps(Some((10 * GIB, GIB)), None),
                Ok(GIB / 2),
            ),
            (
                "a group past its cap",
                Some("8388608"),
                caps(None, Some((GIB, 2 * GIB))),
                Ok(0),
            ),
            (
                "no meminfo",
                None,
                caps(None, None),
                Err("host-room-unread"),
            ),
            (
                "no available figure",
                Some("x"),
                caps(None, None),
                Err("meminfo-unparsed"),
            ),
        ];
        for (case, available, groups, want) in cases {
            let root = tempfile::tempdir().unwrap();
            let proc_root = root.path().join("proc");
            let cgroup_root = root.path().join("cgroup");
            fs::create_dir_all(proc_root.join("7")).unwrap();
            fs::write(proc_root.join("7/cgroup"), "0::/a/b\n").unwrap();
            if let Some(kb) = available {
                let line = if kb == "x" {
                    String::new()
                } else {
                    format!("MemAvailable:   {kb} kB\n")
                };
                fs::write(
                    proc_root.join("meminfo"),
                    format!("MemTotal:       16777216 kB\nMemFree:        1 kB\n{line}"),
                )
                .unwrap();
            }
            for (group, cap) in ["a", "a/b"].into_iter().zip(groups) {
                let dir = cgroup_root.join(group);
                fs::create_dir_all(&dir).unwrap();
                let (max, current) = cap.map_or(("max".to_owned(), 5), |(max, current)| {
                    (max.to_string(), current)
                });
                fs::write(dir.join("memory.max"), format!("{max}\n")).unwrap();
                fs::write(dir.join("memory.current"), format!("{current}\n")).unwrap();
            }
            let read = room(&proc_root, &cgroup_root, 7).map_err(|unread| unread.cause);
            assert_eq!(read, want, "{case}");
        }
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

    /// The readings of a `ps -p` answer by its real exit
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

    /// The parent resumes from a spawn once the child's new image replaces
    /// its old one, which is before the kernel lays out that image's
    /// arguments: a read in that window finds no words and leaves the child
    /// out, so the row reads until the child carries words, bounded.
    #[test]
    fn the_command_lines_name_a_child_this_test_owns_by_its_words() {
        let child = Held::spawn(Command::new("sleep").arg("30"));
        let deadline = Instant::now() + Duration::from_secs(5);
        let words = loop {
            let lines = command_lines().expect("a readable table");
            let words = lines
                .iter()
                .find(|(pid, _)| *pid == child.pid())
                .map(|(_, words)| words.clone());
            if words.is_some() || Instant::now() >= deadline {
                break words;
            }
            std::thread::sleep(Duration::from_millis(10));
        };
        assert_eq!(words, Some(vec!["sleep".to_owned(), "30".to_owned()]));
    }

    /// A child that exited and stands unreaped holds its pid as a zombie:
    /// the table leaves it out and its identity reads gone, so a group
    /// read by pgid never holds on a member only its parent's reap would
    /// end.
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

    /// On a real process: a child this test holds reads live
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
    /// its cause, never gone.
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

    /// One reader admits every start form the runtime writes. A `ticks:`
    /// and an `lstart:` start each match the live process they name, a
    /// mismatch in either form is `Gone`, and the bare `ps -o lstart` text,
    /// in no form, is unreadable `start-form`.
    #[test]
    fn still_runs_matches_every_written_start_form_and_refuses_a_bare_one() {
        let me = std::process::id();
        // The lstart text the non-Linux reader records with its prefix.
        let Reading::Live(prefixed) = start_lstart(me) else {
            panic!("own lstart");
        };
        // The host form the runtime itself records (ticks on Linux).
        let Reading::Live(native) = identity(me) else {
            panic!("own identity");
        };
        for form in [native.start.clone(), prefixed.clone()] {
            let id = Identity {
                pid: me,
                start: form.clone(),
            };
            assert_eq!(still_runs(&id), Reading::Live(id.clone()), "form {form:?}");
        }
        let bare = Identity {
            pid: me,
            start: prefixed
                .strip_prefix("lstart:")
                .expect("lstart prefix")
                .to_owned(),
        };
        assert_eq!(
            still_runs(&bare),
            Reading::Unreadable {
                cause: "start-form"
            }
        );
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
        let _signalling = SIGNALLING.lock().unwrap_or_else(PoisonError::into_inner);
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

    /// A signal to a child this test owns is one counted `kill` start under
    /// `signal`, delivered, and the child reads ended by that signal, so a
    /// measurement of starts per duty sees every stop.
    #[test]
    fn a_signal_to_a_held_child_counts_one_kill_start_and_ends_it() {
        let _signalling = SIGNALLING.lock().unwrap_or_else(PoisonError::into_inner);
        let mut child = Held::sleep();
        let before = host::counts().of("kill", Some("signal"));
        assert!(signal(child.pid(), "TERM").unwrap());
        let status = child.0.wait().unwrap();
        assert_eq!(status.signal(), Some(15));
        assert_eq!(host::counts().of("kill", Some("signal")), before + 1);
    }

    /// A signal to a pid no process holds reads refused, as `kill`'s ESRCH
    /// exit, and still counts the one start. The pid is above the kernel's
    /// `pid_max`, which proc(5) says is never allocated, so nothing is
    /// signalled by accident.
    #[cfg(target_os = "linux")]
    #[test]
    fn a_signal_to_a_pid_nobody_holds_reads_refused_and_counts_one_start() {
        let _signalling = SIGNALLING.lock().unwrap_or_else(PoisonError::into_inner);
        let pid_max: u32 = fs::read_to_string("/proc/sys/kernel/pid_max")
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        let gone = pid_max.checked_add(1).unwrap();
        let before = host::counts().of("kill", Some("signal"));
        assert!(!signal(gone, "TERM").unwrap());
        assert_eq!(host::counts().of("kill", Some("signal")), before + 1);
    }
}
