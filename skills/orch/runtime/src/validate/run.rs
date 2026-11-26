//! Validation execution, stage completion and completion notices.

use agent_runtime::record::Locking;
use std::collections::HashSet;
use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use agent_runtime::clock::{self, Clock};
use agent_runtime::effects::Reach;
use agent_runtime::{process::Member, reading::Unreadable};
use serde::Serialize;

use super::{KILL_GRACE, apply, ci_env, item_of_run_dir, load};
use crate::error::{Error, Result};
use crate::ops::validate::{self, MarkNotice, RecordEnd, RecordStop, Validate, Validated};
use crate::ops::{self, ReconcileRound, Request, job_ended};
use crate::send::{NoticeSend, send_notice};
use crate::settings::Settings;
use crate::state::{self, ItemState, Stage, StageKind, StageOutcome, Stop, ValidateJob};
use agent_runtime::journal::Env;

/// How long the launcher's stop is given: the setsid teardown's TERM grace
/// and KILL, or the user manager's own stop of the unit.
/// How long the stop waits for the job it ended to read gone: on the setsid
/// route the job outlives its child's group and closes the stage itself
/// (its close and its notice's send), on the unit route the manager ended
/// it with its child.
const STOP_WAIT: Duration = Duration::from_secs(KILL_GRACE * 3);
/// The poll between the stop's reads of the job.
const STOP_POLL: Duration = Duration::from_millis(200);

/// What the job reports when it ends.
#[derive(Debug, Clone, Serialize)]
pub struct RunReply {
    pub item: String,
    pub round_id: String,
    pub run_dir: String,
    pub outcome: Option<StageOutcome>,
    pub closed_now: bool,
    /// The run's wall time from its `timing` record, where the run left
    /// one and this run closed the stage.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub seconds: Option<u64>,
    /// The notice's owner word after this run: `sent`, `unsent:<cause>`,
    /// `owed` where this run's send is held, or the mark an earlier run
    /// left.
    pub notice: Option<String>,
}

/// Read the transition's stamp after the command or stop wait finishes.
/// The stage's end must be at or after the sentinel time. The nonce and
/// owner identity stay the command's.
#[allow(
    clippy::disallowed_methods,
    reason = "the job's and the stop's own stamp at their close, the command's clock read again after a wait the command's first stamp predates"
)]
fn env_now(env: &Env) -> Env {
    let since_epoch = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    Env {
        now_secs: since_epoch.as_secs(),
        now_nanos: since_epoch.as_nanos(),
        nonce: env.nonce,
        owner: env.owner.clone(),
    }
}

/// The run's stage under `run_dir`, with the item's stages.
fn stage_of(path: &Path, run_dir: &str) -> Result<(Vec<Stage>, usize)> {
    let snapshot = load(path)?.ok_or_else(|| {
        Error::Runtime(agent_runtime::Error::RecordMissing {
            path: path.to_path_buf(),
        })
    })?;
    let stages = snapshot.view::<ItemState>(path)?.stages;
    let index = stages
        .iter()
        .position(|s| s.kind == StageKind::Validate && s.run_dir.as_deref() == Some(run_dir))
        .ok_or_else(|| Error::RunUnadmitted {
            run_dir: run_dir.to_owned(),
        })?;
    Ok((stages, index))
}

pub fn execute(run_dir: &Path, clock: &dyn Clock, group_leader: &Path) -> Result<()> {
    execute_reading_tree(run_dir, clock, group_leader, agent_runtime::process::tree)
}

type TreeReader = fn(u32) -> std::result::Result<Vec<Member>, Unreadable>;

#[allow(
    clippy::disallowed_methods,
    reason = "the executor owns its command group and reaps it on every return"
)]
fn execute_reading_tree(
    run_dir: &Path,
    clock: &dyn Clock,
    group_leader: &Path,
    read_tree: TreeReader,
) -> Result<()> {
    use std::io::Write;
    use std::os::unix::process::{CommandExt, ExitStatusExt};
    use std::process::{Command, Stdio};
    let fail = |read, cause: String| Error::ValidateUnreadable { read, cause };
    let start = super::files::fields(&run_dir.join("start"))?;
    let field = |key: &str| start.get(key).map(String::as_str).unwrap_or("");
    let quiet = field("quiet-secs")
        .parse::<u64>()
        .ok()
        .filter(|n| *n > 0)
        .ok_or_else(|| fail("quiet-secs", field("quiet-secs").to_owned()))?;
    let expected = match field("expected-secs") {
        "" => None,
        secs => Some(
            secs.parse::<u64>()
                .map_err(|_| fail("expected-secs", secs.to_owned()))?,
        ),
    };
    let command =
        fs::read_to_string(run_dir.join("cmd")).map_err(|e| fail("cmd", e.to_string()))?;
    match fs::read_to_string(run_dir.join("exit")) {
        Ok(s) if validate::sentinel_outcome(s.trim_end()).is_some() => return Ok(()),
        Ok(s) => return Err(fail("sentinel", s)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(fail("sentinel", e.to_string())),
    }
    executor_mark(run_dir)?;
    let mut claim = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(run_dir.join("execution"))
        .map_err(|e| fail("execution-unanswered", e.to_string()))?;
    execution_mark(&mut claim, "not-started")?;
    // Every writer appends, so the executor's own warning lands after the
    // command's output instead of over it.
    let mut log = fs::OpenOptions::new()
        .append(true)
        .create(true)
        .open(run_dir.join("log"))
        .map_err(|e| fail("log", e.to_string()))?;
    let runner = super::files::fields(&run_dir.join("runner"))?;
    let line = runner
        .get("line")
        .filter(|line| !line.is_empty())
        .ok_or_else(|| fail("runner-unreadable", run_dir.display().to_string()))?;
    writeln!(log, "{line}").map_err(|e| fail("log", e.to_string()))?;
    let paths = run_dir.join("paths");
    // The launcher's line names the cap it set on the run's unit; the run's
    // own cgroup is read before the command so the kill count it ends with
    // is the command's alone.
    let cap = (runner.get("runner").is_some_and(|r| r == "systemd")
        && line.split(' ').any(|word| word.starts_with("memory-max=")))
    .then(|| {
        agent_runtime::effects::job::own_cgroup_dir()
            .ok_or("cgroup-unread")
            .and_then(Cap::of)
    });
    let cgroup = agent_runtime::effects::job::own_cgroup_dir().and_then(Kills::of);
    // The start's bound is the kernel's where the run's unit holds a cap,
    // and this executor's to hold on every other route.
    let bound = match field("memory-bound") {
        "" => None,
        bytes => Some(
            bytes
                .parse::<u64>()
                .map_err(|_| fail("memory-bound", bytes.to_owned()))?,
        ),
    };
    let reader = match (bound, &cap) {
        (Some(bound), Some(Ok(_))) => {
            writeln!(log, "memory-held=unit bound={bound}")
                .map_err(|e| fail("log", e.to_string()))?;
            None
        }
        (Some(bound), Some(Err(_)) | None) => {
            writeln!(log, "memory-held=reader bound={bound}")
                .map_err(|e| fail("log", e.to_string()))?;
            Some(bound)
        }
        (None, _) => None,
    };
    let started = clock
        .wall()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    // A validation command inherits the caller's environment, with the recorded
    // classification and base replacing any inherited validation context.
    let stdout = log.try_clone().map_err(|e| fail("log", e.to_string()))?;
    execution_mark(&mut claim, "attempted")?;
    // A foreground run forks through the github skill's group-leader prefix,
    // which restores the INT and QUIT a caller's async job leaves ignored. A
    // detached run takes the dispositions its unit or setsid start gives it,
    // so it runs no prefix and needs no perl.
    // An OOM killer, the unit's, a slice's or the host's, kills the process
    // its badness ranks first (`proc_pid_oom_score_adj(5)`): the command's
    // tree is ranked above every other process, this executor included,
    // which must outlive the kill to record it, and the unrelated work a
    // host-level kill would otherwise take. A host without the file ranks
    // nothing and runs the command alike.
    let mut bash = Command::new("/bin/bash");
    if runner.get("runner").is_some_and(|r| r == "attached") {
        bash.args([
            "-c",
            "printf 1000 2>/dev/null >/proc/self/oom_score_adj; . \"$1\"; exec \"${KENDEX_GROUP_LEADER[@]}\" /bin/bash -c \"$2\"",
            "_",
            &group_leader.display().to_string(),
            &command,
        ]);
    } else {
        bash.args([
            "-c",
            "printf 1000 2>/dev/null >/proc/self/oom_score_adj; exec /bin/bash -c \"$1\"",
            "_",
            &command,
        ]);
    }
    let child = bash
        .current_dir(field("worktree"))
        .process_group(0)
        .env("DEV_VALIDATE_CLASS", field("class"))
        .env("DEV_VALIDATE_DOCS_ONLY", field("docs-only"))
        .env("DEV_VALIDATE_BASE", field("validate-base"))
        .env(
            "DEV_VALIDATE_SCOPED",
            if field("scoped") == "true" {
                "true"
            } else {
                "false"
            },
        )
        .env("DEV_VALIDATE_MODE", field("validate-mode"))
        .env("DEV_VALIDATE_PATHS", &paths)
        .envs(ci_env(field("ci-event"), field("ci-fallback")))
        .stdin(Stdio::null())
        .stdout(stdout)
        .stderr(log)
        .spawn();
    let child = match child {
        Ok(child) => child,
        Err(error) => {
            execution_mark(&mut claim, "not-started")?;
            return Err(fail("command-not-started", error.to_string()));
        }
    };
    let mut group = CommandGroup {
        child,
        reaped: false,
        ended: false,
    };
    let pid = group.child.id();
    atomic(run_dir, "pid", &format!("{pid}\n"))?;
    let mut command_record = CommandRecord { pid, start: None };
    atomic(run_dir, "command", &serde_json::to_string(&command_record)?)?;
    match agent_runtime::process::identity(pid) {
        agent_runtime::reading::Reading::Live(id) => {
            command_record.start = Some(id.start);
            atomic(run_dir, "command", &serde_json::to_string(&command_record)?)?;
        }
        agent_runtime::reading::Reading::Gone => {}
        agent_runtime::reading::Reading::Unreadable { cause } => {
            return Err(fail("command-identity", cause.to_owned()));
        }
    }
    let run = Step {
        name: "run".to_owned(),
        command: command.split_whitespace().collect::<Vec<_>>().join(" "),
        expected: None,
        started: clock.now(),
        warned: false,
    };
    let mut progress = Progress::open(
        run_dir,
        pid,
        Duration::from_secs(quiet),
        run,
        expected,
        reader,
    )?;
    // Keep the owned leader unreaped until its group is empty. Its kernel
    // number cannot be reused while cleanup reads the group's members.
    let end = loop {
        match agent_runtime::process::identity(pid) {
            agent_runtime::reading::Reading::Gone => break End::Exited,
            agent_runtime::reading::Reading::Live(_) => {
                progress.observe(clock, read_tree)?;
                if let Some((limit, peak)) = progress.outgrew() {
                    break End::Outgrew { limit, peak };
                }
                if let Some(stalled) = progress.stalled(clock.now())? {
                    break End::Stalled(stalled);
                }
                clock.sleep(Duration::from_millis(100));
            }
            agent_runtime::reading::Reading::Unreadable { cause } => {
                return Err(fail("command-status", cause.to_owned()));
            }
        }
    };
    if matches!(end, End::Exited) {
        atomic(run_dir, "own-exit", "")?;
    }
    // The verdict is written before the command's tree is ended: a teardown
    // the executor cannot confirm is its own error, and never takes back the
    // verdict the command already gave.
    let status = match end {
        End::Exited => {
            let status = group.reap_leader()?;
            status
                .code()
                .unwrap_or_else(|| 128 + status.signal().unwrap_or(0))
        }
        End::Stalled(_) => 124,
        // The status a kill at a cap gives the leader.
        End::Outgrew { .. } => 137,
    };
    let ended = clock
        .wall()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let started_at = agent_runtime::clock::iso_utc(started);
    let ended_at = agent_runtime::clock::iso_utc(ended);
    atomic(
        run_dir,
        "timing",
        &format!(
            "started-at={started_at}\nended-at={ended_at}\nseconds={}\n",
            ended.saturating_sub(started)
        ),
    )?;
    let memory = cap.as_ref().map(MemoryEnd::of);
    let host_kill = cgroup.as_ref().is_some_and(Kills::rose);
    atomic(
        run_dir,
        "exit",
        &sentinel(status, &ended_at, &end, memory.as_ref(), host_kill),
    )?;
    if !matches!(end, End::Exited)
        && let Ok(members) = read_tree(pid)
    {
        stop_tree(members)?;
    }
    group.end()
}

/// How the executor's watch of its command ended.
enum End {
    /// The leader exited.
    Exited,
    /// The command showed no work for its quiet time.
    Stalled(Stalled),
    /// The tree's resident memory passed the bound this executor holds.
    Outgrew { limit: u64, peak: u64 },
}

/// Stop the observed tree, including members outside the leader's group.
#[allow(
    clippy::disallowed_methods,
    reason = "the command owner ends every identity of the stalled tree it spawned"
)]
fn stop_tree(members: Vec<Member>) -> Result<()> {
    use agent_runtime::process;
    let identities: Vec<_> = members.into_iter().map(|member| member.id).collect();
    match process::stop_identities(&identities, Duration::from_secs(KILL_GRACE))? {
        process::Stop::AlreadyGone | process::Stop::Stopped { .. } => Ok(()),
        other => Err(Error::ValidateUnreadable {
            read: "command-tree-unconfirmed",
            cause: format!("{other:?}"),
        }),
    }
}

/// The run's sentinel line: its exit and end, then what the memory cap
/// says where the launcher set one, then the verdict's own suffix. A kill
/// at the unit's cap, or the executor's end at its own bound, is the run's
/// cause and replaces that suffix, since it decides the verdict
/// (`ops::validate::sentinel_outcome`). A failed run whose group lost a
/// process to an OOM killer that was not its own cap names the host's. A
/// stall's last line is the line's last field, since it is the log's text.
fn sentinel(
    status: i32,
    ended_at: &str,
    end: &End,
    memory: Option<&MemoryEnd>,
    host_kill: bool,
) -> String {
    let suffix = match (memory, end) {
        (Some(MemoryEnd::Killed { limit, peak }), _) => {
            let peak = peak.map_or_else(|| "unread".to_owned(), |peak| peak.to_string());
            format!(" cause=memory-cap limit={limit} peak={peak}")
        }
        (_, End::Outgrew { limit, peak }) => {
            format!(" cause=memory-cap limit={limit} peak={peak}")
        }
        (_, End::Stalled(stalled)) => format!(
            " cause=stalled quiet-secs={} step={} last-line={}",
            stalled.quiet_secs, stalled.step, stalled.last_line
        ),
        (_, End::Exited) if host_kill && status != 0 => " cause=memory-host".to_owned(),
        (_, End::Exited) if status == 3 => " verdict=no-verdict cause=host".to_owned(),
        (_, End::Exited) => String::new(),
    };
    let word = match memory {
        Some(MemoryEnd::Unstated(word)) => format!(" {word}"),
        Some(MemoryEnd::Within | MemoryEnd::Killed { .. }) | None => String::new(),
    };
    format!("guard-exit={status} at={ended_at}{word}{suffix}\n")
}

/// How often the executor reads whether its command still works.
const PROGRESS_READ: Duration = Duration::from_secs(1);
/// The least time between two lines of the run's `progress` record.
const PROGRESS_LINE: Duration = Duration::from_secs(10);
/// The rise of the command tree's CPU time that counts as work: a command
/// blocked on a read or a lock accrues none, a spinning one a second a second.
const CPU_WORK_MS: u64 = 1000;

/// The executor's reading of whether its command still works: the run's log
/// grew, a process identity the last reading did not hold appeared at or
/// below the command's leader, or the tree's CPU time rose by
/// [`CPU_WORK_MS`]. Each line of the `progress` record says how long the
/// command has shown none of the three; a person and a wait read it, and only
/// the executor judges it: a command quiet for the start's `quiet-secs` has
/// stalled. With an unread tree, log growth is the evidence of work.
struct Progress {
    record: fs::File,
    log: PathBuf,
    leader: u32,
    quiet: Duration,
    log_bytes: u64,
    members: HashSet<(u32, String)>,
    /// The CPU time a rise is counted from: the reading at the last rise,
    /// lowered to any smaller reading, since a member that exits unreaped or
    /// leaves the tree takes its time out of the sum.
    cpu_from: Option<u64>,
    worked: Instant,
    next_read: Instant,
    next_line: Instant,
    steps: Steps,
    /// The bound this executor holds the tree's resident memory to, where
    /// no unit's cap holds it, and the most the tree has read.
    bound: Option<u64>,
    peak: u64,
}

impl Progress {
    #[allow(
        clippy::disallowed_methods,
        reason = "the executor creates its run's progress record once, beside the claim it holds"
    )]
    fn open(
        run_dir: &Path,
        leader: u32,
        quiet: Duration,
        run: Step,
        run_expected: Option<u64>,
        bound: Option<u64>,
    ) -> Result<Progress> {
        let record = fs::OpenOptions::new()
            .append(true)
            .create_new(true)
            .open(run_dir.join("progress"))
            .map_err(|e| super::files::unreadable("progress", e))?;
        let now = run.started;
        Ok(Progress {
            record,
            log: run_dir.join("log"),
            leader,
            quiet,
            log_bytes: 0,
            members: HashSet::new(),
            cpu_from: None,
            worked: now,
            next_read: now,
            next_line: now,
            steps: Steps {
                warnings: run_dir.join("warning"),
                read_to: 0,
                run_started: now,
                run_expected,
                run_warned: false,
                current: run,
            },
            bound,
            peak: 0,
        })
    }

    /// Read the command once its next reading is due, and append a line
    /// once its next line is. A tree that cannot be read shows no work and
    /// its line names the cause.
    #[allow(
        clippy::disallowed_methods,
        reason = "the executor's poll reads its injected clock and stamps the line it appends"
    )]
    fn observe(&mut self, clock: &dyn Clock, read_tree: TreeReader) -> Result<()> {
        use std::io::Write;
        let now = clock.now();
        if now < self.next_read {
            return Ok(());
        }
        self.next_read = now + PROGRESS_READ;
        let log_bytes = fs::metadata(&self.log)
            .map_err(|e| super::files::unreadable("log", e))?
            .len();
        let mut worked = log_bytes > self.log_bytes;
        if worked {
            self.steps.read(&self.log, now)?;
        }
        // The executor's own warnings in the log are no work of the command.
        self.log_bytes = log_bytes + self.steps.warn(&self.log, now)?;
        let tree = match read_tree(self.leader) {
            Ok(members) => {
                let cpu: u64 = members.iter().map(|m| m.cpu_ms).sum();
                let rss: u64 = members.iter().map(|m| m.rss_bytes).sum();
                self.peak = self.peak.max(rss);
                let ids: HashSet<(u32, String)> = members
                    .into_iter()
                    .map(|m| (m.id.pid, m.id.start))
                    .collect();
                worked |= !ids.is_subset(&self.members);
                let line = format!("procs={} cpu-ms={cpu}", ids.len());
                self.members = ids;
                let from = self.cpu_from.map_or(cpu, |from| from.min(cpu));
                if cpu >= from.saturating_add(CPU_WORK_MS) {
                    worked = true;
                    self.cpu_from = Some(cpu);
                } else {
                    self.cpu_from = Some(from);
                }
                line
            }
            Err(unread) => format!("tree=unread cause={}", unread.cause),
        };
        if worked {
            self.worked = now;
        }
        if now < self.next_line {
            return Ok(());
        }
        self.next_line = now + PROGRESS_LINE;
        let at = agent_runtime::clock::iso_utc(
            clock
                .wall()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs(),
        );
        writeln!(
            self.record,
            "at={at} quiet-for={} log-bytes={log_bytes} {tree}",
            now.duration_since(self.worked).as_secs()
        )
        .map_err(|e| super::files::unreadable("progress", e))
    }

    /// The bound and the tree's peak, once a reading of the tree's resident
    /// memory passed the bound this executor holds. A page two members
    /// share counts in each, so the sum can stand above what the kernel
    /// charges; a tree that could not be read is judged at its next read.
    fn outgrew(&self) -> Option<(u64, u64)> {
        let bound = self.bound?;
        (self.peak > bound).then_some((bound, self.peak))
    }

    /// The stall, once the command has shown no work for its quiet time:
    /// the step and the last line the log names.
    #[allow(
        clippy::disallowed_methods,
        reason = "the quiet time is measured on the executor's injected clock"
    )]
    fn stalled(&self, now: Instant) -> Result<Option<Stalled>> {
        if now.duration_since(self.worked) < self.quiet {
            return Ok(None);
        }
        let log = fs::read(&self.log).map_err(|e| super::files::unreadable("log", e))?;
        let log = String::from_utf8_lossy(&log);
        let last_line = log
            .lines()
            .filter(|line| !line.starts_with(WARNING))
            .filter_map(|line| line.rsplit('\r').map(str::trim).find(|s| !s.is_empty()))
            .next_back()
            .unwrap_or("")
            .to_owned();
        Ok(Some(Stalled {
            quiet_secs: self.quiet.as_secs(),
            step: self.steps.current.name.clone(),
            last_line,
        }))
    }
}

/// A command the executor ended for showing no work for its quiet time.
struct Stalled {
    quiet_secs: u64,
    step: String,
    last_line: String,
}

/// The line a run's command may print to name the step it starts, its
/// command and the time it is expected to take.
const STEP: &str = "validate-step: ";
/// The line the executor writes for a step or a run past its expected time.
const WARNING: &str = "validate-warning: ";

/// A step of a run: the newest `validate-step:` line its command printed, or
/// the run itself before any.
struct Step {
    name: String,
    command: String,
    expected: Option<u64>,
    started: Instant,
    warned: bool,
}

impl Step {
    /// The step a `validate-step: name=N command=C [expected-secs=E]` line
    /// starts at `now`; none for a line of another form.
    fn of(line: &str, now: Instant) -> Option<Step> {
        let rest = line.strip_prefix(STEP)?.strip_prefix("name=")?;
        let (name, rest) = rest.split_once(" command=")?;
        if name.is_empty() || name.contains(char::is_whitespace) {
            return None;
        }
        let (command, expected) = match rest.rsplit_once(" expected-secs=") {
            Some((command, secs))
                if !secs.is_empty() && secs.bytes().all(|b| b.is_ascii_digit()) =>
            {
                (command, secs.parse().ok())
            }
            Some(_) | None => (rest, None),
        };
        Some(Step {
            name: name.to_owned(),
            command: command.to_owned(),
            expected,
            started: now,
            warned: false,
        })
    }
}

/// The step a run is in and the warnings it owes: once for a step past its
/// own expected time, once for the run past the selector's, each into the
/// log and the run directory's `warning` record. A warning ends nothing.
struct Steps {
    warnings: PathBuf,
    /// The log offset the step lines are read from: the end of the last
    /// whole line read.
    read_to: u64,
    current: Step,
    run_started: Instant,
    run_expected: Option<u64>,
    run_warned: bool,
}

impl Steps {
    /// Take the newest step line among the log's whole lines past the last
    /// read.
    fn read(&mut self, log: &Path, now: Instant) -> Result<()> {
        use std::io::{Read, Seek, SeekFrom};
        let unreadable = |e: std::io::Error| super::files::unreadable("log", e);
        let mut file = fs::File::open(log).map_err(unreadable)?;
        file.seek(SeekFrom::Start(self.read_to))
            .map_err(unreadable)?;
        let mut tail = Vec::new();
        file.read_to_end(&mut tail).map_err(unreadable)?;
        let Some(end) = tail.iter().rposition(|b| *b == b'\n') else {
            return Ok(());
        };
        self.read_to += end as u64 + 1;
        if let Some(step) = String::from_utf8_lossy(&tail[..end])
            .lines()
            .filter_map(|line| Step::of(line, now))
            .next_back()
        {
            self.current = step;
        }
        Ok(())
    }

    /// Write each warning now owed; the bytes added to the log.
    #[allow(
        clippy::disallowed_methods,
        reason = "the executor's warnings are measured on its injected clock and appended to its run's own records"
    )]
    fn warn(&mut self, log: &Path, now: Instant) -> Result<u64> {
        use std::io::Write;
        let mut owed = Vec::new();
        let step = &mut self.current;
        if let Some(expected) = step.expected
            && !step.warned
            && now.duration_since(step.started).as_secs() > expected
        {
            step.warned = true;
            owed.push((expected, now.duration_since(step.started).as_secs()));
        }
        if let Some(expected) = self.run_expected
            && !self.run_warned
            && now.duration_since(self.run_started).as_secs() > expected
        {
            self.run_warned = true;
            owed.push((expected, now.duration_since(self.run_started).as_secs()));
        }
        let mut text = String::new();
        for (expected, elapsed) in owed {
            text.push_str(&format!(
                "{WARNING}slow step={} command={} expected-secs={expected} elapsed-secs={elapsed}: the run goes on while it makes progress; no needed check is dropped to meet the expected time\n",
                self.current.name, self.current.command
            ));
        }
        if text.is_empty() {
            return Ok(0);
        }
        for path in [log, self.warnings.as_path()] {
            fs::OpenOptions::new()
                .append(true)
                .create(true)
                .open(path)
                .and_then(|mut file| file.write_all(text.as_bytes()))
                .map_err(|e| super::files::unreadable("warning", e))?;
        }
        Ok(text.len() as u64)
    }
}

/// A cgroup v2 `memory.events` file's counts this run reads: the times the
/// group reached its own `memory.max`, and the processes an OOM killer
/// took from it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Events {
    max: u64,
    oom_kill: u64,
}

impl Events {
    fn read(dir: &Path) -> Option<Events> {
        let text = fs::read_to_string(dir.join("memory.events")).ok()?;
        let count = |key: &str| {
            text.lines()
                .find_map(|line| line.strip_prefix(key)?.strip_prefix(' '))?
                .trim()
                .parse()
                .ok()
        };
        Some(Events {
            max: count("max")?,
            oom_kill: count("oom_kill")?,
        })
    }
}

/// The cgroup this executor and its command run in, with its counts before
/// the command.
struct Kills {
    dir: PathBuf,
    before: Events,
}

impl Kills {
    fn of(dir: PathBuf) -> Option<Kills> {
        Events::read(&dir).map(|before| Kills { dir, before })
    }

    /// An OOM killer took a process from the group since the command
    /// started; counts unread after are no kill.
    fn rose(&self) -> bool {
        Events::read(&self.dir).is_some_and(|after| after.oom_kill > self.before.oom_kill)
    }
}

/// The memory cap the kernel holds on the run's own cgroup, and the
/// group's counts before the command.
#[derive(Debug)]
struct Cap {
    dir: PathBuf,
    limit: u64,
    before: Events,
}

impl Cap {
    /// The cap at `dir`, or why it holds none: no whole number in
    /// `memory.max` (`max`, or no memory controller on the group), or
    /// counts that cannot be read.
    fn of(dir: PathBuf) -> std::result::Result<Cap, &'static str> {
        let limit = fs::read_to_string(dir.join("memory.max"))
            .ok()
            .and_then(|text| text.trim().parse().ok())
            .ok_or("cgroup-uncapped")?;
        let before = Events::read(&dir).ok_or("cgroup-unread")?;
        Ok(Cap { dir, limit, before })
    }
}

/// How the run ended against the cap its launcher set.
#[derive(Debug, PartialEq, Eq)]
enum MemoryEnd {
    /// No kill at the cap.
    Within,
    /// The group reached its own cap and an OOM killer took a member: a
    /// kill counted with no rise of the group's own `max` came from an
    /// ancestor's cap or the host's, and is not this cap's.
    Killed { limit: u64, peak: Option<u64> },
    /// The cap does not hold the run, or its counts went unread after: the
    /// word the sentinel states.
    Unstated(String),
}

impl MemoryEnd {
    fn of(cap: &std::result::Result<Cap, &'static str>) -> MemoryEnd {
        let cap = match cap {
            Ok(cap) => cap,
            Err(cause) => {
                return MemoryEnd::Unstated(format!("memory-cap=unavailable cause={cause}"));
            }
        };
        match Events::read(&cap.dir) {
            None => MemoryEnd::Unstated("memory-cap=unread".to_owned()),
            Some(after) if after.max > cap.before.max && after.oom_kill > cap.before.oom_kill => {
                MemoryEnd::Killed {
                    limit: cap.limit,
                    peak: fs::read_to_string(cap.dir.join("memory.peak"))
                        .ok()
                        .and_then(|text| text.trim().parse().ok()),
                }
            }
            Some(_) => MemoryEnd::Within,
        }
    }
}

#[allow(
    clippy::disallowed_methods,
    reason = "the executor publishes each run file whole before its reader can observe it"
)]
fn atomic(dir: &Path, name: &str, text: &str) -> Result<()> {
    let part = dir.join(format!("{name}.part"));
    fs::write(&part, text)
        .and_then(|_| fs::rename(&part, dir.join(name)))
        .map_err(|e| Error::ValidateUnreadable {
            read: "run-file",
            cause: format!("{name}: {e}"),
        })
}

fn execution_mark(file: &mut fs::File, status: &str) -> Result<()> {
    use std::io::{Seek, Write};
    file.set_len(0)
        .and_then(|_| file.rewind())
        .and_then(|_| writeln!(file, "{status}"))
        .map_err(|e| super::files::unreadable("execution-unanswered", e))
}

#[derive(serde::Serialize, serde::Deserialize)]
struct CommandRecord {
    pid: u32,
    start: Option<String>,
}

/// The executor's own identity, which stands from before its claim to after
/// its sentinel. A follower whose wrapper hides the run's unit holds the
/// run by it, through the window where the command's group has ended and
/// the sentinel has not yet landed. It is linked in whole and exclusively,
/// so a reader never sees part of it and a second executor of the run
/// never names itself in the first one's place.
#[derive(serde::Serialize, serde::Deserialize)]
struct ExecutorRecord {
    pid: u32,
    start: String,
}

#[allow(
    clippy::disallowed_methods,
    reason = "the executor reads its own identity to record it"
)]
fn executor_mark(run_dir: &Path) -> Result<()> {
    use agent_runtime::reading::Reading;
    let fail = |cause: String| Error::ValidateUnreadable {
        read: "executor-identity",
        cause,
    };
    let start = match agent_runtime::process::identity(std::process::id()) {
        Reading::Live(identity) => identity.start,
        Reading::Gone => return Err(fail("own-identity-gone".to_owned())),
        Reading::Unreadable { cause } => return Err(fail(cause.to_owned())),
    };
    let record = ExecutorRecord {
        pid: std::process::id(),
        start,
    };
    let part = run_dir.join("executor.part");
    fs::write(&part, serde_json::to_string(&record)?)
        .and_then(|_| fs::hard_link(&part, run_dir.join("executor")))
        .map_err(|e| fail(e.to_string()))?;
    fs::remove_file(&part).map_err(|e| fail(e.to_string()))
}

/// The executor's reading by the identity it recorded, `None` where the run
/// holds no record: its executor never started, or predates the record.
#[allow(
    clippy::disallowed_methods,
    reason = "a run's executor is read by its recorded identity; nothing is signalled"
)]
pub(crate) fn executor_reading(
    run_dir: &Path,
) -> Result<Option<agent_runtime::reading::Reading<()>>> {
    let bytes = match fs::read(run_dir.join("executor")) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(super::files::unreadable("executor-identity", e)),
    };
    let record: ExecutorRecord = serde_json::from_slice(&bytes)?;
    Ok(Some(
        match agent_runtime::process::still_runs(&agent_runtime::process::Identity {
            pid: record.pid,
            start: record.start,
        }) {
            agent_runtime::reading::Reading::Live(_) => agent_runtime::reading::Reading::Live(()),
            agent_runtime::reading::Reading::Gone => agent_runtime::reading::Reading::Gone,
            agent_runtime::reading::Reading::Unreadable { cause } => {
                agent_runtime::reading::Reading::Unreadable { cause }
            }
        },
    ))
}

#[allow(
    clippy::disallowed_methods,
    reason = "the run's command identity is read before a new start can use its host"
)]
pub(crate) fn command_reading(
    run_dir: &Path,
) -> Result<Option<agent_runtime::reading::Reading<()>>> {
    let bytes = match fs::read(run_dir.join("command")) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            let claim = match fs::read_to_string(run_dir.join("execution")) {
                Ok(claim) => claim,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
                Err(e) => return Err(super::files::unreadable("execution", e)),
            };
            if claim == "not-started\n" {
                return Ok(Some(agent_runtime::reading::Reading::Gone));
            }
            let pid = fs::read_to_string(run_dir.join("pid"))
                .ok()
                .and_then(|p| p.trim().parse().ok());
            return Ok(Some(match pid {
                Some(pid) => agent_runtime::effects::job::pgid_reading(pid),
                None => agent_runtime::reading::Reading::Unreadable {
                    cause: "execution-unanswered",
                },
            }));
        }
        Err(e) => return Err(super::files::unreadable("command-identity", e)),
    };
    let record: CommandRecord = serde_json::from_slice(&bytes)?;
    Ok(Some(match record.start {
        Some(start) => {
            agent_runtime::effects::job::group_reading(&agent_runtime::process::Identity {
                pid: record.pid,
                start,
            })
        }
        None => agent_runtime::effects::job::pgid_reading(record.pid),
    }))
}

struct CommandGroup {
    child: std::process::Child,
    reaped: bool,
    ended: bool,
}
impl CommandGroup {
    /// The leader's own exit status, once it has exited. Its group's number
    /// stays its own while a member holds it, so the end below still names
    /// the group the command left.
    #[allow(
        clippy::disallowed_methods,
        reason = "the command owner reaps the child it spawned"
    )]
    fn reap_leader(&mut self) -> Result<std::process::ExitStatus> {
        let status = self.child.wait().map_err(|e| Error::ValidateUnreadable {
            read: "command-reap",
            cause: e.to_string(),
        })?;
        self.reaped = true;
        Ok(status)
    }

    #[allow(
        clippy::disallowed_methods,
        reason = "the command owner ends every readable identity in its group and reaps its child"
    )]
    fn end(&mut self) -> Result<()> {
        use agent_runtime::{process, reading::Reading};
        let rows = process::table().map_err(|e| Error::ValidateUnreadable {
            read: "command-group",
            cause: e.cause.to_owned(),
        })?;
        let mut identities = Vec::new();
        for row in rows.iter().filter(|row| row.pgrp == self.child.id()) {
            match process::identity(row.pid) {
                Reading::Live(id) => identities.push(id),
                Reading::Gone => {}
                Reading::Unreadable { cause } => {
                    return Err(Error::ValidateUnreadable {
                        read: "command-group",
                        cause: cause.to_owned(),
                    });
                }
            }
        }
        match process::stop_identities(&identities, Duration::from_secs(KILL_GRACE))? {
            process::Stop::AlreadyGone | process::Stop::Stopped { .. } => {}
            other => {
                return Err(Error::ValidateUnreadable {
                    read: "command-group-unconfirmed",
                    cause: format!("{other:?}"),
                });
            }
        }
        if !self.reaped {
            self.reap_leader()?;
        }
        self.ended = true;
        Ok(())
    }
}
impl Drop for CommandGroup {
    #[allow(
        clippy::disallowed_methods,
        reason = "an executor error still ends and reaps the command it owns"
    )]
    fn drop(&mut self) {
        if !self.ended {
            let _ = self.end();
            if !self.reaped {
                let _ = self.child.kill();
                let _ = self.child.wait();
            }
        }
    }
}

/// What the run left: the outcome its sentinel named, or `lost` with no
/// sentinel; the sentinel's own `at=` time where it parses; the run's wall
/// time from its `timing` record; and the command's last `validate:`
/// selection line, which `--record` reads the lanes and selection from.
struct Left {
    outcome: StageOutcome,
    at: Option<u64>,
    seconds: Option<u64>,
    selection: Option<String>,
}

/// Read the run directory once the child ended. Only `NotFound` proves no
/// sentinel: an unreadable sentinel keeps the stage open for reconcile.
fn read_left(run_dir: &Path) -> Result<Left> {
    let sentinel = match fs::read_to_string(run_dir.join("exit")) {
        Ok(text) => Some(text.trim_end().to_owned()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => {
            return Err(Error::ValidateUnreadable {
                read: "sentinel",
                cause: e.to_string(),
            });
        }
    };
    let selection = super::files::RunFile::read(run_dir)
        .ok()
        .and_then(|run| run.selection().ok())
        .map(|(_, selection)| selection);
    let outcome = sentinel
        .as_deref()
        .and_then(validate::sentinel_outcome)
        .unwrap_or(StageOutcome::Lost);
    let at = sentinel.as_deref().and_then(|line| {
        line.split(' ')
            .find_map(|f| f.strip_prefix("at="))
            .and_then(clock::epoch_secs)
    });
    let seconds = fs::read_to_string(run_dir.join("timing"))
        .ok()
        .and_then(|text| {
            text.lines()
                .find_map(|l| l.strip_prefix("seconds="))
                .and_then(|s| s.parse().ok())
        });
    Ok(Left {
        outcome,
        at,
        seconds,
        selection,
    })
}

/// Send the stage's owed notice and mark it: the owner word written, or
/// `owed` where the send is held and the stage left for the next walk.
fn send_and_mark(
    path: &Path,
    settings: &Settings,
    reach: &Reach,
    item: &str,
    stage: &Stage,
    env: &Env,
    locking: Locking,
) -> Result<String> {
    let (Some(notice), Some(run_dir), Some(round_id)) =
        (&stage.notice, &stage.run_dir, &stage.round_id)
    else {
        return Ok(String::new());
    };
    let to = notice.to.as_deref().unwrap_or(item);
    let mark = match send_notice(settings, reach, to, &notice.key, &notice.text, env, locking) {
        NoticeSend::Marked(mark) => mark,
        NoticeSend::Held => return Ok(agent_runtime::intent::NOTICE_OWED.to_owned()),
    };
    let marked = apply(
        path,
        Validate::Mark(MarkNotice {
            round_id: round_id.clone(),
            run_dir: run_dir.clone(),
            owner: mark,
        }),
        env,
        locking,
    )?;
    Ok(match marked {
        Validated::Mark(m) => m.owner,
        Validated::Settle(_)
        | Validated::Start(_)
        | Validated::Launch(_)
        | Validated::End(_)
        | Validated::Stop(_)
        | Validated::Refuse(_) => String::new(),
    })
}

/// The job's main: run the executor, close the stage, send the notice
/// through `reach`.
pub fn run(
    settings: &Settings,
    reach: &Reach,
    item: &str,
    round: &str,
    run_dir: &str,
    env: &Env,
    locking: Locking,
) -> Result<RunReply> {
    let path = state::item_path(&settings.state_dir, item);
    let (stages, index) = stage_of(&path, run_dir)?;
    let stage = &stages[index];
    if stage.proof.is_none() {
        return Err(Error::RunUnstarted {
            run_dir: run_dir.to_owned(),
        });
    }
    if stage.end.is_some() {
        // A second run of the same job: the close stands, nothing is sent.
        return Ok(RunReply {
            item: item.to_owned(),
            round_id: round.to_owned(),
            run_dir: run_dir.to_owned(),
            outcome: stage.outcome,
            closed_now: false,
            seconds: None,
            notice: stage.notice.as_ref().map(|n| n.owner.clone()),
        });
    }
    let run_dir_path = PathBuf::from(run_dir);
    execute(
        &run_dir_path,
        &agent_runtime::clock::SystemClock,
        &super::group_leader(settings),
    )?;
    // Stamp the close after the command ends.
    let env = &env_now(env);
    let left = read_left(&run_dir_path)?;
    let ended = apply(
        &path,
        Validate::End(RecordEnd {
            round_id: round.to_owned(),
            run_dir: run_dir.to_owned(),
            outcome: left.outcome,
            end: left.at,
            seconds: left.seconds,
            selection: left.selection,
            notify: true,
        }),
        env,
        locking,
    )?;
    let Validated::End(ended) = ended else {
        unreachable!("an end reports its end")
    };
    if !ended.closed_now {
        return Ok(RunReply {
            item: item.to_owned(),
            round_id: round.to_owned(),
            run_dir: run_dir.to_owned(),
            outcome: ended.outcome,
            closed_now: false,
            seconds: None,
            notice: ended.notice_owner,
        });
    }
    // The notice is on disk as `owed`; the send follows and the mark after.
    let (stages, index) = stage_of(&path, run_dir)?;
    let notice = send_and_mark(&path, settings, reach, item, &stages[index], env, locking)?;
    Ok(RunReply {
        item: item.to_owned(),
        round_id: round.to_owned(),
        run_dir: run_dir.to_owned(),
        outcome: ended.outcome,
        closed_now: true,
        seconds: ended.seconds,
        notice: Some(notice),
    })
}

/// Send every end notice the item's closed runs still record `owed`: the
/// continuation a crash between the close and the send left behind, run
/// before the item's `reconcile-round` transition. A mark the store refused
/// leaves the notice owed, so the next reconcile sends again; the mailbox
/// reads a repeat within its window as sent, and a session send is read by
/// its key on the lane's record. Each goes through `reach`.
pub fn deliver_owed(
    settings: &Settings,
    reach: &Reach,
    path: &Path,
    env: &Env,
    locking: Locking,
) -> Result<()> {
    let Some(snapshot) = load(path)? else {
        return Ok(());
    };
    let item = path
        .file_stem()
        .and_then(OsStr::to_str)
        .and_then(|s| s.strip_prefix("workflow-state-"))
        .unwrap_or_default()
        .to_owned();
    let stages = snapshot.view::<ItemState>(path)?.stages;
    for stage in stages.iter().filter(|s| {
        s.kind == StageKind::Validate
            && s.end.is_some()
            && s.notice
                .as_ref()
                .is_some_and(agent_runtime::intent::Notice::owed)
    }) {
        if let Err(e) = send_and_mark(path, settings, reach, &item, stage, env, locking) {
            // The store refused the mark: the notice stays owed for the
            // next reconcile, and this one is not failed over it.
            let _ = e;
        }
    }
    Ok(())
}

// --- The stop -------------------------------------------------------------------

/// What `validate stop` reports.
#[derive(Debug, Clone, Serialize)]
pub struct StopReply {
    pub item: String,
    pub round_id: String,
    pub run_dir: String,
    /// The stop as the stage records it: this call's or an earlier one's.
    pub stop: Stop,
    pub recorded_now: bool,
    /// The launcher's runner word for the job, `systemd` or `setsid`.
    pub runner: String,
    pub ended: JobEnded,
    pub job: JobState,
    /// The stage after the finishing transition: its word where it closed,
    /// whether it is closed, and its notice's owner word.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub outcome: Option<StageOutcome>,
    pub closed: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub notice: Option<String>,
}

/// What the launcher's stop did.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum JobEnded {
    /// The unit was stopped, or the child's group torn down.
    Signalled,
    /// Nothing to end: the manager has no such unit, or the recorded child
    /// is not this run's executor any more.
    AlreadyGone,
}

/// How the job read after the stop's bounded wait.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum JobState {
    Gone,
    /// Still live after the wait: it owns its close, or the next reconcile
    /// does.
    Live,
    /// The identity read could not say; the stage stays as it stood.
    Unreadable,
}

/// End the recorded command group before its executor. Unreadable identities
/// remain owed; a reused process number is left alone.
#[allow(
    clippy::disallowed_methods,
    reason = "the stop's one ask of the job launcher to end the run's job by its recorded identity, after the stop was recorded on the stage"
)]
fn end_job(_settings: &Settings, run_dir: &str, _job: &ValidateJob) -> Result<JobEnded> {
    stop_files(Path::new(run_dir), true).map(|answer| {
        if answer.is_some() {
            JobEnded::Signalled
        } else {
            JobEnded::AlreadyGone
        }
    })
}

/// What a worktree stop ended: the units and the process groups.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct WorktreeStop {
    pub units: usize,
    pub groups: usize,
}

/// Every unfinished run in `worktree` ended, but the started jobs of the
/// open stages `keep` admits, which its caller stops through those stages: a
/// run an item admits through its stage's stop, and a run no item admits, one
/// whose stage is closed or one `keep` admits with no job, by the identity
/// its own files name. A stop's owed notices go through `reach`.
#[allow(
    clippy::disallowed_methods,
    reason = "a worktree stop waits, bounded, for an attached executor to close its recorded stage after its command was ended"
)]
pub fn stop_worktree(
    settings: &Settings,
    reach: &Reach,
    worktree: &Path,
    keep: Option<&str>,
    env: &Env,
    locking: Locking,
) -> Result<WorktreeStop> {
    let mut stopped = WorktreeStop::default();
    let mut count = |runner: Option<&str>| match runner {
        Some("systemd") => stopped.units += 1,
        Some(_) => stopped.groups += 1,
        None => {}
    };
    for run in super::files::runs(worktree)?
        .into_iter()
        .filter(|r| r.sentinel.is_none())
    {
        let rd = run.dir.display().to_string();
        match item_of_run_dir(&settings.state_dir, &rd) {
            Ok((item, _)) if Some(item.as_str()) == keep => {
                let (stages, index) = stage_of(&state::item_path(&settings.state_dir, &item), &rd)?;
                if stages[index].end.is_some() || stages[index].job.is_none() {
                    count(stop_files(&run.dir, false)?);
                }
            }
            Ok((item, _)) => match stop(settings, reach, Some(&item), &rd, env, locking) {
                Ok(mut reply) => {
                    if reply.runner == "attached" && reply.job == JobState::Live && !reply.closed {
                        let deadline = Instant::now() + STOP_WAIT;
                        let path = state::item_path(&settings.state_dir, &item);
                        while !reply.closed && Instant::now() < deadline {
                            std::thread::sleep(STOP_POLL);
                            let (stages, index) = stage_of(&path, &rd)?;
                            reply.closed = stages[index].end.is_some();
                        }
                    }
                    if reply.job != JobState::Gone && !reply.closed {
                        return Err(match reply.job {
                            JobState::Unreadable => super::files::unreadable(
                                "stop-unreadable",
                                format!("run-dir={rd} job=unreadable stage=open"),
                            ),
                            JobState::Live => Error::ValidateStopFailed {
                                run_dir: rd,
                                cause: "job=live stage=open".to_owned(),
                            },
                            JobState::Gone => unreachable!("a gone job satisfies its stop"),
                        });
                    }
                    if reply.ended == JobEnded::Signalled {
                        count(Some(&reply.runner));
                    }
                }
                Err(Error::RunClosed { .. }) => count(stop_files(&run.dir, false)?),
                Err(error) => return Err(error),
            },
            Err(Error::RunUnadmitted { .. }) => count(stop_files(&run.dir, false)?),
            Err(error) => return Err(error),
        }
    }
    Ok(stopped)
}

/// End a run's command group, then its runner unless that runner is
/// attached, by the identities its own files record. The `stop` file makes
/// the run's ending read a stop, so `--record` reads it `verdict=no-verdict`,
/// and `--wait` reads it `state=done stopped`, not `lost`, where the run
/// wrote no sentinel, and `state=done guard-exit=N ... validate=no-verdict`
/// where it wrote one. It is written
/// before the end it records: at once on a run whose stage records the stop
/// (`staged`), since that stage's close reads `stopped` whatever the stop
/// finds, and otherwise only where the command group, or a runner that is
/// not attached, does not read gone. A run whose work reads gone at a stop
/// no stage records keeps the word its own ending reads.
#[allow(
    clippy::disallowed_methods,
    reason = "a validation stop ends its recorded command group before stopping the executor that owns its close"
)]
pub(crate) fn stop_files(run_dir: &Path, staged: bool) -> Result<Option<&'static str>> {
    let mut marked = false;
    let mut mark = |live: bool| -> Result<()> {
        if live && !marked {
            atomic(run_dir, "stop", "stop-requested\n")?;
            marked = true;
        }
        Ok(())
    };
    mark(staged)?;
    let mut stopped = false;
    match fs::read(run_dir.join("command")) {
        Ok(bytes) => {
            let record: CommandRecord = serde_json::from_slice(&bytes)?;
            let start = record.start.ok_or_else(|| {
                super::files::unreadable("stop-unreadable", "command identity was not recorded")
            })?;
            let identity = agent_runtime::process::Identity {
                pid: record.pid,
                start,
            };
            mark(!matches!(
                agent_runtime::effects::job::group_reading(&identity),
                agent_runtime::reading::Reading::Gone
            ))?;
            stopped = agent_runtime::effects::job::stop_group(&identity)?;
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            let run = super::files::RunFile::read(run_dir)?;
            let runner = super::files::fields(&run_dir.join("runner"))
                .ok()
                .and_then(|r| r.get("runner").cloned());
            if super::files::unstarted(&run)? {
                // A start whose child never ran and whose launcher wrote no
                // runner record names no process and no unit: there is
                // nothing to stop. A unit is stopped by the name its record
                // carries, below.
                if fs::symlink_metadata(run_dir.join("runner"))
                    .is_err_and(|e| e.kind() == std::io::ErrorKind::NotFound)
                {
                    return Ok(None);
                }
                match runner.as_deref() {
                    Some("systemd") => {}
                    Some("setsid" | "attached") => return Ok(None),
                    _ => {
                        return Err(super::files::unreadable(
                            "stop-unreadable",
                            format!("run-dir={} record-unreadable", run_dir.display()),
                        ));
                    }
                }
            } else if command_reading(run_dir)?
                .is_some_and(|reading| !matches!(reading, agent_runtime::reading::Reading::Gone))
                || !matches!(
                    super::files::runner_reading(&run),
                    agent_runtime::reading::Reading::Gone
                )
            {
                return Err(super::files::unreadable(
                    "stop-unreadable",
                    format!("run-dir={} execution-unanswered", run_dir.display()),
                ));
            }
        }
        Err(e) => {
            return Err(Error::ValidateStopFailed {
                run_dir: run_dir.display().to_string(),
                cause: e.to_string(),
            });
        }
    }
    let runner = super::files::fields(&run_dir.join("runner"));
    if runner
        .as_ref()
        .is_ok_and(|r| r.get("runner").is_some_and(|v| v == "attached"))
    {
        return Ok(stopped.then_some("attached"));
    }
    mark(!matches!(
        agent_runtime::effects::job::recorded_live(&run_dir.join("runner")),
        agent_runtime::reading::Reading::Gone
    ))?;
    let runner = agent_runtime::effects::job::stop_recorded(&run_dir.join("runner"))?;
    Ok(runner.or(stopped.then_some("setsid")))
}

/// Wait, bounded, for the job to read gone by its recorded identity.
#[allow(
    clippy::disallowed_methods,
    reason = "the stop's bounded wait for the job it ended to read gone, polling the one identity reader"
)]
fn wait_job_gone(job: &ValidateJob) -> JobState {
    let deadline = Instant::now() + STOP_WAIT;
    loop {
        let state = match job_ended(job) {
            Some(true) => return JobState::Gone,
            Some(false) => JobState::Live,
            None => JobState::Unreadable,
        };
        if Instant::now() >= deadline {
            return state;
        }
        std::thread::sleep(STOP_POLL);
    }
}

/// The round's reconcile, the one finishing transition a gone job's stage
/// takes (`ops::item::reconcile_round`): a job gone with no sentinel and the
/// stage's stop recorded closes `stopped` with the notice owed in the same
/// write; a live job keeps its stage.
#[allow(
    clippy::disallowed_methods,
    reason = "the stop's one finishing transition, the round's reconcile through the one dispatcher"
)]
fn reconcile(path: &Path, round_id: &str, env: &Env, locking: Locking) -> Result<()> {
    ops::apply(
        path,
        &Request::ReconcileRound(ReconcileRound {
            round_id: round_id.to_owned(),
        }),
        env,
        locking,
    )?;
    Ok(())
}

/// Stop a started run: the stop recorded on its open stage first (a record
/// before the effect; refused `run-closed` on a closed stage, `run-unstarted`
/// on one with no runtime job), the job ended by its recorded identity
/// through the launcher, a bounded wait for the job to read gone, then the
/// finishing transition and the owed walk: the stop ends the command's group
/// and then the job by its launcher record (the unit by its name, the setsid
/// job by its group), so the reconcile closes the stage `stopped` with the
/// notice owed and the walk sends it, whatever sentinel the executor wrote
/// first; a job that closed the stage itself before it was ended read the
/// same word, the first closer winning. `item` names the record; with none,
/// the run directory finds it. The walk sends through `reach`.
pub fn stop(
    settings: &Settings,
    reach: &Reach,
    item: Option<&str>,
    run_dir: &str,
    env: &Env,
    locking: Locking,
) -> Result<StopReply> {
    let item = match item {
        Some(item) => item.to_owned(),
        None => item_of_run_dir(&settings.state_dir, run_dir)?.0,
    };
    let path = state::item_path(&settings.state_dir, &item);
    let (stages, index) = stage_of(&path, run_dir)?;
    let round_id = stages[index].round_id.clone().unwrap_or_default();
    let stopped = apply(
        &path,
        Validate::Stop(RecordStop {
            round_id: round_id.clone(),
            run_dir: run_dir.to_owned(),
        }),
        env,
        locking,
    )?;
    let Validated::Stop(stopped) = stopped else {
        unreachable!("a stop reports its stop")
    };
    let (stages, index) = stage_of(&path, run_dir)?;
    let Some(job) = stages[index].job.clone() else {
        unreachable!("the stop stands on a started run")
    };
    let ended = end_job(settings, run_dir, &job)?;
    let job_state = if job.runner.as_deref() == Some("attached") {
        JobState::Live
    } else {
        wait_job_gone(&job)
    };
    // The finishing transition's own clock: the stop and the wait took time.
    let env = &env_now(env);
    deliver_owed(settings, reach, &path, env, locking)?;
    reconcile(&path, &round_id, env, locking)?;
    deliver_owed(settings, reach, &path, env, locking)?;
    let (stages, index) = stage_of(&path, run_dir)?;
    let stage = &stages[index];
    Ok(StopReply {
        item,
        round_id,
        run_dir: run_dir.to_owned(),
        stop: stopped.stop,
        recorded_now: stopped.recorded_now,
        runner: job.runner.unwrap_or_default(),
        ended,
        job: job_state,
        outcome: stage.outcome,
        closed: stage.end.is_some(),
        notice: stage.notice.as_ref().map(|n| n.owner.clone()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ops::validate::{end_notice, failure_cause, memory_cap_cause, sentinel_outcome};

    #[test]
    #[allow(
        clippy::disallowed_methods,
        reason = "the row plants a silent command under its private run directory"
    )]
    fn a_quiet_run_ends_stalled_when_its_process_tree_is_unreadable() {
        use agent_runtime::clock::SystemClock;
        use std::sync::atomic::{AtomicU64, Ordering};

        struct TestClock(Instant, AtomicU64);
        impl Clock for TestClock {
            fn now(&self) -> Instant {
                self.0 + Duration::from_secs(self.1.load(Ordering::Relaxed))
            }
            fn wall(&self) -> SystemTime {
                UNIX_EPOCH + Duration::from_secs(self.1.load(Ordering::Relaxed))
            }
            fn sleep(&self, _: Duration) {
                self.1.fetch_add(1, Ordering::Relaxed);
                SystemClock.sleep(Duration::from_millis(10));
            }
        }

        let dir = tempfile::tempdir().unwrap();
        let run = dir.path();
        fs::write(
            run.join("start"),
            format!("worktree={}\nquiet-secs=2\n", run.display()),
        )
        .unwrap();
        fs::write(run.join("runner"), "runner=setsid\nline=fixture\n").unwrap();
        fs::write(run.join("cmd"), "exec /bin/sleep 5").unwrap();
        let clock = TestClock(SystemClock.now(), AtomicU64::new(0));
        execute_reading_tree(run, &clock, run, |_| {
            Err(Unreadable {
                cause: "tree-unread-here",
            })
        })
        .unwrap();
        let line = fs::read_to_string(run.join("exit")).unwrap();
        assert_eq!(sentinel_outcome(&line), Some(StageOutcome::Fail), "{line}");
        assert!(
            failure_cause(line.trim_end())
                .is_some_and(|cause| cause.starts_with("cause=stalled step=run")),
            "{line}"
        );
    }

    fn events(max: u64, oom_kill: u64) -> String {
        format!("low 0\nhigh 0\nmax {max}\noom {oom_kill}\noom_kill {oom_kill}\noom_group_kill 0\n")
    }

    #[test]
    fn a_stalled_runs_log_tail_cannot_supply_its_verdict_or_cause() {
        for log in [
            "tool: verdict=no-verdict",
            "tool: cause=memory-host",
            "tool: cause=memory-cap limit=100 peak=200 last-line=other text",
        ] {
            let end = End::Stalled(Stalled {
                quiet_secs: 10,
                step: "run".into(),
                last_line: log.into(),
            });
            let line = sentinel(124, "2026-01-01T00:00:00Z", &end, None, false);
            let line = line.trim_end();
            assert_eq!(sentinel_outcome(line), Some(StageOutcome::Fail), "{line}");
            assert_eq!(
                failure_cause(line),
                Some(format!("cause=stalled step=run last-line={log}"))
            );
        }
    }

    /// A run whose own cgroup reached its cap while an OOM killer took a
    /// member, or whose tree the executor ended past the bound it holds,
    /// fails with the cause and its figures, whatever the leader's exit, on
    /// its sentinel, its `state=done` reading and its lane's end notice; a
    /// failed run whose group lost a process to a kill its own cap did not
    /// make names the host's, and a passing one keeps its pass; a cap
    /// reached with no kill, a group with no cap and counts unread after
    /// each keep the leader's verdict and the stall's suffix where it
    /// applies.
    #[test]
    #[allow(
        clippy::disallowed_methods,
        reason = "the row plants the sentinel's place under its own temporary directory"
    )]
    fn a_sentinel_that_stands_unread_is_no_absent_one_and_a_later_read_ends_it() {
        let dir = tempfile::tempdir().unwrap();
        let run = dir.path();
        let outcome = |run: &Path| read_left(run).map(|left| left.outcome);
        assert_eq!(outcome(run).unwrap(), StageOutcome::Lost);
        // A directory in the sentinel's place: its read fails while it stands.
        fs::create_dir(run.join("exit")).unwrap();
        let unread = outcome(run).unwrap_err();
        assert_eq!(
            (unread.key(), unread.fields()),
            (
                "validate-unreadable",
                vec![("read".to_owned(), "sentinel".to_owned())]
            )
        );
        fs::remove_dir(run.join("exit")).unwrap();
        fs::write(run.join("exit"), "guard-exit=0 at=2026-11-18T07:00:00Z\n").unwrap();
        assert_eq!(outcome(run).unwrap(), StageOutcome::Pass);
    }

    #[test]
    #[allow(
        clippy::disallowed_methods,
        reason = "the row plants a cgroup's files and a run directory under its own temporary directories"
    )]
    fn a_run_past_its_memory_bound_fails_with_its_figures_and_a_hosts_kill_is_named() {
        // case | memory.max, none where no unit cap holds the run | events
        // after | memory.peak | leader exit | how the watch ended | the
        // outcome | the cause the wait and the notice state
        type Row<'a> = (
            &'a str,
            Option<&'a str>,
            Option<String>,
            Option<&'a str>,
            i32,
            &'a str,
            StageOutcome,
            Option<&'a str>,
        );
        let killed = Some("cause=memory-cap limit=1073741824 peak=1100000000");
        let stalled = Some(
            "cause=stalled step=run last-line=cargo test: waiting on the build directory lock",
        );
        let unit = Some("1073741824");
        let rows: [Row; 13] = [
            (
                "killed, leader 0",
                unit,
                Some(events(3, 1)),
                Some("1100000000"),
                0,
                "exited",
                StageOutcome::Fail,
                killed,
            ),
            (
                "killed, leader 137",
                unit,
                Some(events(3, 1)),
                Some("1100000000"),
                137,
                "exited",
                StageOutcome::Fail,
                killed,
            ),
            (
                "killed, then stalled",
                unit,
                Some(events(3, 1)),
                Some("1100000000"),
                124,
                "stalled",
                StageOutcome::Fail,
                killed,
            ),
            (
                "killed, peak unread",
                unit,
                Some(events(3, 1)),
                None,
                0,
                "exited",
                StageOutcome::Fail,
                Some("cause=memory-cap limit=1073741824 peak=unread"),
            ),
            (
                "an ancestor's kill, leader 0",
                unit,
                Some(events(0, 1)),
                Some("1"),
                0,
                "exited",
                StageOutcome::Pass,
                None,
            ),
            (
                "an ancestor's kill, leader 1",
                unit,
                Some(events(0, 1)),
                Some("1"),
                1,
                "exited",
                StageOutcome::Fail,
                Some("cause=memory-host"),
            ),
            (
                "the host's kill, no unit, leader 137",
                None,
                Some(events(0, 1)),
                None,
                137,
                "exited",
                StageOutcome::Fail,
                Some("cause=memory-host"),
            ),
            (
                "outgrew the executor's bound",
                None,
                Some(events(0, 0)),
                None,
                137,
                "outgrew",
                StageOutcome::Fail,
                Some("cause=memory-cap limit=16777216 peak=50331648"),
            ),
            (
                "cap reached, reclaimed",
                unit,
                Some(events(3, 0)),
                Some("1"),
                1,
                "exited",
                StageOutcome::Fail,
                None,
            ),
            (
                "no cap, stalled",
                Some("max"),
                Some(events(0, 0)),
                None,
                124,
                "stalled",
                StageOutcome::Fail,
                stalled,
            ),
            (
                "no unit, stalled",
                None,
                Some(events(0, 0)),
                None,
                124,
                "stalled",
                StageOutcome::Fail,
                stalled,
            ),
            (
                "counts gone after",
                unit,
                None,
                None,
                0,
                "exited",
                StageOutcome::Pass,
                None,
            ),
            (
                "counts gone after, leader 1",
                unit,
                None,
                None,
                1,
                "exited",
                StageOutcome::Fail,
                None,
            ),
        ];
        for (case, max, after, peak, status, end, outcome, cause) in rows {
            let end = match end {
                "exited" => End::Exited,
                "stalled" => End::Stalled(Stalled {
                    quiet_secs: 660,
                    step: "run".to_owned(),
                    last_line: "cargo test: waiting on the build directory lock".to_owned(),
                }),
                _ => End::Outgrew {
                    limit: 16_777_216,
                    peak: 50_331_648,
                },
            };
            let dir = tempfile::tempdir().expect("tempdir");
            fs::write(
                dir.path().join("memory.max"),
                format!("{}\n", max.unwrap_or("max")),
            )
            .unwrap();
            fs::write(dir.path().join("memory.events"), events(0, 0)).unwrap();
            let cap = max.map(|_| Cap::of(dir.path().to_path_buf()));
            let kills = Kills::of(dir.path().to_path_buf());
            match after {
                Some(after) => fs::write(dir.path().join("memory.events"), after).unwrap(),
                None => fs::remove_file(dir.path().join("memory.events")).unwrap(),
            }
            if let Some(peak) = peak {
                fs::write(dir.path().join("memory.peak"), format!("{peak}\n")).unwrap();
            }
            let line = sentinel(
                status,
                "2026-01-01T00:00:00Z",
                &end,
                cap.as_ref().map(MemoryEnd::of).as_ref(),
                kills.as_ref().is_some_and(Kills::rose),
            );
            let line = line.trim_end();
            assert_eq!(sentinel_outcome(line), Some(outcome), "{case}: {line}");
            assert_eq!(
                failure_cause(line).as_deref(),
                cause.filter(|_| outcome == StageOutcome::Fail),
                "{case}: {line}"
            );
            if memory_cap_cause(line).is_some() {
                assert!(cause.is_some_and(|c| c.starts_with("cause=memory-cap ")));
            }
            if max == Some("max") {
                assert!(
                    line.contains(" memory-cap=unavailable cause=cgroup-uncapped"),
                    "{case}: {line}"
                );
            }
            if case.starts_with("counts gone after") {
                assert!(line.contains(" memory-cap=unread"), "{case}: {line}");
            }
            // The run's end notice and its waiter's `state=done` line carry
            // the cause the sentinel ends with.
            let run = tempfile::tempdir().expect("tempdir");
            let run_dir = run.path().display().to_string();
            fs::write(run.path().join("exit"), format!("{line}\n")).unwrap();
            fs::write(
                run.path().join("start"),
                "start=0\npoll-secs=1\nvalidate-mode=full\n",
            )
            .unwrap();
            let notice = end_notice("x", &run_dir, outcome).text;
            let (done, _) =
                super::super::files::wait(run.path(), 1, &agent_runtime::clock::SystemClock)
                    .unwrap();
            for (reader, text, mark) in [
                ("notice", &notice, " state=fail "),
                ("done", &done, " validate=FAILING "),
            ] {
                match cause {
                    Some(cause) => assert!(
                        text.contains(&format!("{mark}{cause} run-dir=")),
                        "{case} {reader}: {text}"
                    ),
                    None => assert!(!text.contains(" cause="), "{case} {reader}: {text}"),
                }
            }
        }
    }
}
