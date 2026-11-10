//! Validation execution, stage completion and completion notices.

use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use agent_runtime::clock;
use serde::Serialize;

use super::{KILL_GRACE, apply, item_of_run_dir, load};
use crate::error::{Error, Result};
use crate::mailbox::{Mailbox, Refusal, Sent};
use crate::ops::mail::{KeyedSend, SendResult};
use crate::ops::validate::{self, MarkNotice, RecordEnd, RecordStop, Validate, Validated};
use crate::ops::{self, Env, ReconcileRound, Request, job_ended};
use crate::send::Keyed;
use crate::settings::Settings;
use crate::state::{
    self, FleetState, ItemState, Lane, Locking, Record, Stage, StageKind, StageOutcome, Stop,
    ValidateJob,
};

/// How long the mailbox program is given to take the notice.
const NOTICE_TIMEOUT: Duration = Duration::from_secs(60);
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

/// The transition environment at this moment: the command's stamp re-read
/// after a wait that outlasted the one it started with (the child run for
/// the run's whole bound; the stop's wait for the job), so the close, its
/// notice's send and the stop's finishing transition carry the clock of the
/// close, never the launch's: a stage `end` stamped at the job's launch
/// second would read a sentinel time later than it as out of bounds. The
/// nonce and the owner identity stay the command's.
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
    let snapshot = load(path)?.ok_or_else(|| Error::RecordMissing {
        path: path.to_path_buf(),
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

/// The run's `start` record field.
fn start_field(run_dir: &Path, key: &str) -> Option<String> {
    let text = fs::read_to_string(run_dir.join("start")).ok()?;
    text.lines()
        .find_map(|l| l.strip_prefix(key).and_then(|r| r.strip_prefix('=')))
        .map(str::to_owned)
}

#[allow(
    clippy::disallowed_methods,
    reason = "the executor owns its command group and reaps it on every return"
)]
pub fn execute(
    run_dir: &Path,
    clock: &dyn crate::schedule::Clock,
    group_leader: &Path,
) -> Result<()> {
    use std::io::Write;
    use std::os::unix::process::{CommandExt, ExitStatusExt};
    use std::process::{Command, Stdio};
    let fail = |read, cause: String| Error::ValidateUnreadable { read, cause };
    let start = super::files::fields(&run_dir.join("start"))?;
    let field = |key: &str| start.get(key).map(String::as_str).unwrap_or("");
    let timeout = field("timeout-secs")
        .parse::<u64>()
        .ok()
        .filter(|n| *n > 0)
        .ok_or_else(|| fail("timeout-secs", field("timeout-secs").to_owned()))?;
    let command =
        fs::read_to_string(run_dir.join("cmd")).map_err(|e| fail("cmd", e.to_string()))?;
    match fs::read_to_string(run_dir.join("exit")) {
        Ok(s) if validate::sentinel_outcome(s.trim_end()).is_some() => return Ok(()),
        Ok(s) => return Err(fail("sentinel", s)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(fail("sentinel", e.to_string())),
    }
    let mut claim = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(run_dir.join("execution"))
        .map_err(|e| fail("execution-unanswered", e.to_string()))?;
    execution_mark(&mut claim, "not-started")?;
    let mut log = fs::File::create(run_dir.join("log")).map_err(|e| fail("log", e.to_string()))?;
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
        crate::effects::own_cgroup_dir()
            .ok_or("cgroup-unread")
            .and_then(Cap::of)
    });
    let began = clock.now();
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
    let mut bash = Command::new("/bin/bash");
    if runner.get("runner").is_some_and(|r| r == "attached") {
        bash.args([
            "-c",
            ". \"$1\"; exec \"${KENDEX_GROUP_LEADER[@]}\" /bin/bash -c \"$2\"",
            "_",
            &group_leader.display().to_string(),
            &command,
        ]);
    } else if matches!(cap, Some(Ok(_))) {
        // At the cap the kernel kills the process its badness ranks first
        // (`proc_pid_oom_score_adj(5)`): the command's tree is ranked above
        // this executor, which shares the cap and must outlive the kill to
        // record it.
        bash.args([
            "-c",
            "printf 1000 2>/dev/null >/proc/self/oom_score_adj; exec /bin/bash -c \"$1\"",
            "_",
            &command,
        ]);
    } else {
        bash.args(["-c", &command]);
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
    let deadline = began + Duration::from_secs(timeout);
    // Keep the owned leader unreaped until its group is empty. Its kernel
    // number cannot be reused while cleanup reads the group's members.
    let bounded = loop {
        match agent_runtime::process::identity(pid) {
            agent_runtime::reading::Reading::Gone => break false,
            agent_runtime::reading::Reading::Live(_) if clock.now() >= deadline => break true,
            agent_runtime::reading::Reading::Live(_) => clock.sleep(Duration::from_millis(100)),
            agent_runtime::reading::Reading::Unreadable { cause } => {
                return Err(fail("command-status", cause.to_owned()));
            }
        }
    };
    if !bounded {
        atomic(run_dir, "own-exit", "")?;
    }
    // The verdict is written before the command's group is ended: a teardown
    // the executor cannot confirm is its own error, and never takes back the
    // verdict the command already gave.
    let status = if bounded {
        124
    } else {
        let status = group.reap_leader()?;
        status
            .code()
            .unwrap_or_else(|| 128 + status.signal().unwrap_or(0))
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
    atomic(
        run_dir,
        "exit",
        &sentinel(status, &ended_at, bounded, memory.as_ref()),
    )?;
    group.end()
}

/// The run's sentinel line: its exit and end, then what the memory cap
/// says where the launcher set one, then the verdict's own suffix. A kill
/// at the cap is the run's cause and replaces that suffix, since it decides
/// the verdict (`ops::validate::sentinel_outcome`).
fn sentinel(status: i32, ended_at: &str, bounded: bool, memory: Option<&MemoryEnd>) -> String {
    let suffix = match memory {
        Some(MemoryEnd::Killed { limit, peak }) => {
            let peak = peak.map_or_else(|| "unread".to_owned(), |peak| peak.to_string());
            format!(" cause=memory-cap limit={limit} peak={peak}")
        }
        Some(MemoryEnd::Within | MemoryEnd::Unstated(_)) | None if bounded => {
            " verdict=no-verdict".to_owned()
        }
        Some(MemoryEnd::Within | MemoryEnd::Unstated(_)) | None if status == 3 => {
            " verdict=no-verdict cause=host".to_owned()
        }
        Some(MemoryEnd::Within | MemoryEnd::Unstated(_)) | None => String::new(),
    };
    let word = match memory {
        Some(MemoryEnd::Unstated(word)) => format!(" {word}"),
        Some(MemoryEnd::Within | MemoryEnd::Killed { .. }) | None => String::new(),
    };
    format!("guard-exit={status} at={ended_at}{word}{suffix}\n")
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
                Some(pid) => crate::effects::pgid_reading(pid),
                None => agent_runtime::reading::Reading::Unreadable {
                    cause: "execution-unanswered",
                },
            }));
        }
        Err(e) => return Err(super::files::unreadable("command-identity", e)),
    };
    let record: CommandRecord = serde_json::from_slice(&bytes)?;
    Ok(Some(match record.start {
        Some(start) => crate::effects::group_reading(&agent_runtime::process::Identity {
            pid: record.pid,
            start,
        }),
        None => crate::effects::pgid_reading(record.pid),
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

/// What the run left: the outcome its sentinel named, or, with no sentinel
/// (the child was ended before it wrote one), `stopped` where the stage
/// records the intentional stop and `lost` where nothing recorded an
/// intent; the sentinel's own `at=` time where it parses; the run's wall
/// time from its `timing` record; and the command's last `validate:`
/// selection line, which `--record` reads the lanes and selection from.
struct Left {
    outcome: StageOutcome,
    at: Option<u64>,
    seconds: Option<u64>,
    selection: Option<String>,
}

/// Read the run directory once the child ended, `stopped` being whether the
/// stage records a `validate stop`.
fn read_left(run_dir: &Path, stopped: bool) -> Left {
    let sentinel = match fs::read_to_string(run_dir.join("exit")) {
        Ok(text) => Some(text.trim_end().to_owned()),
        Err(_) => None,
    };
    let selection = super::files::RunFile::read(run_dir)
        .ok()
        .and_then(|run| run.selection().ok())
        .map(|(_, selection)| selection);
    let outcome = match sentinel.as_deref().and_then(validate::sentinel_outcome) {
        _ if stopped => StageOutcome::Stopped,
        Some(word) => word,
        None => StageOutcome::Lost,
    };
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
    Left {
        outcome,
        at,
        seconds,
        selection,
    }
}

/// How a notice's send went: the owner word to mark the stage with, or a
/// send held, the stage left owed for the next walk (a send whose outcome
/// is not known, one the lane's record refuses for now, or a fleet record
/// that cannot be read to route it).
enum NoticeSend {
    Marked(String),
    Held,
}

/// Send the end notice `text` to the lane of `item` and answer the word its
/// mark records. The fleet record picks the route. A session lane takes the
/// `orch-runtime send` owner, which records the directive owed before the
/// CLI and settles it under its own reconcile, so an irreversible send is
/// never retried blindly. Every other lane takes the mailbox's outbound
/// directive route, `lane-mail send --item ITEM --directive --file F
/// --delivery-id <key>`, which writes the lane's own inbox (`to-lane.jsonl`)
/// and judges the key under the lock, so a replay after a lost mark lands
/// once and answers `delivery-repeated`. The mark is `sent` on a receipt or
/// a repeated delivery, and `unsent:<cause>` where the route refused or
/// never started: recorded, never a reason to hold the close. The send is
/// held where its answer is not known, the replay under the key landing at
/// most once, and where the fleet record cannot be read, since the mailbox
/// route would send to a session lane with no owed record. The file the
/// program reads the notice from is this walker's own scratch,
/// `<key>.<the request's stamp>.notice`, created exclusively and removed by
/// this walker alone, so a second walker of the same notice (the owed walk
/// meeting the job's send in flight) never removes the file the first's
/// program is about to read; the record carries the key, never the file.
#[allow(
    clippy::disallowed_methods,
    reason = "the end notice's file, this walker's own under the state directory, created exclusively for the mailbox program to read and removed by this walker after its send"
)]
fn send_notice(
    settings: &Settings,
    item: &str,
    key: &str,
    text: &str,
    env: &Env,
    locking: Locking,
) -> NoticeSend {
    use std::io::Write;
    let dir = settings.state_dir.join("validate");
    if let Err(e) = fs::create_dir_all(&dir) {
        return NoticeSend::Marked(format!("unsent:notice-dir:{e}"));
    }
    let path = dir.join(format!("{key}.{}.notice", env.round_id()));
    let written = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
        .and_then(|mut file| file.write_all(format!("{text}\n").as_bytes()));
    if let Err(e) = written {
        return NoticeSend::Marked(format!("unsent:notice-write:{e}"));
    }
    let mark = match lane_record(settings, item) {
        Ok(Some(lane)) if lane.session_channel() => {
            send_session(settings, &lane, key, &path, env, locking)
        }
        Ok(Some(_) | None) => send_directive(settings, item, key, &path),
        Err(_) => NoticeSend::Held,
    };
    let _ = fs::remove_file(&path);
    mark
}

/// The lane of `item` from the fleet record where one stands. No fleet, or
/// one with no record for `item`, is no session lane: the mailbox route
/// then writes a local inbox, which is the channel every non-cloud lane
/// reads. A fleet that cannot be read is `Err`: it may hold a session lane.
#[allow(
    clippy::disallowed_methods,
    reason = "the notice send's one read of the fleet record, to route a cloud session lane to its own send owner"
)]
fn lane_record(settings: &Settings, item: &str) -> Result<Option<Lane>> {
    let fleet = state::fleet_path(&settings.state_dir);
    let Some(snapshot) = state::load(&fleet)? else {
        return Ok(None);
    };
    let fleet = FleetState::view(&fleet, &snapshot.doc)?;
    Ok(fleet.lanes.into_iter().find(|l| l.item == item))
}

/// The mailbox's outbound directive to a non-session lane, keyed by the run.
#[allow(
    clippy::disallowed_methods,
    reason = "the validation job's one outbound send of the lane's end notice through the mailbox program, keyed by the run so a replay lands once"
)]
fn send_directive(settings: &Settings, item: &str, key: &str, file: &Path) -> NoticeSend {
    match Mailbox::new(settings.lane_mail_cli.clone())
        .bounded(NOTICE_TIMEOUT)
        .send_directive(item, None, false, file, Some(key), None)
    {
        Ok(Sent::Mailbox { .. } | Sent::Repeated { .. }) => NoticeSend::Marked("sent".to_owned()),
        // The program routed the lane to its session itself: the send's own
        // result marks it.
        Ok(Sent::Session { send }) => NoticeSend::Marked(session_mark(send.result)),
        // Nothing was appended: the program never started, or refused by
        // its own key before writing any mailbox.
        Err(
            refusal @ (Refusal::NotStarted { .. }
            | Refusal::Exit {
                status: Some(_),
                keyed: Some(_),
                ..
            }),
        ) => NoticeSend::Marked(format!("unsent:{refusal}")),
        // No answer, a signal, an exit with no keyed line or a receipt that
        // does not decode: the append may stand.
        Err(Refusal::Unanswered { .. } | Refusal::Exit { .. } | Refusal::Reply { .. }) => {
            NoticeSend::Held
        }
    }
}

/// The owner word a session send's result marks the stage with: delivered
/// is `sent`; an archived session or a failed send is terminal, the stage
/// marked `unsent:session:<result>` and never retried blindly (the lane's
/// `directive_send` keeps the receipt for the hosted stall close).
fn session_mark(result: SendResult) -> String {
    match result {
        SendResult::Sent => "sent".to_owned(),
        SendResult::Archived => "unsent:session:archived".to_owned(),
        SendResult::Failed => "unsent:session:failed".to_owned(),
    }
}

/// The session send owner for a cloud lane, keyed by the notice:
/// `send::run_keyed` reads the lane's `directive_send` under this key inside
/// its owed write, under the store's lock, so a replay (the stage still owed
/// when the owed walk or the job's own retry meets it) takes what this
/// notice's own send already settled, with no CLI call, whichever walker's
/// settle it was: a send made `sent` and a found `sent` both mark `sent`;
/// `archived` or `failed`, made or found, takes the terminal mark; a send
/// found owed under this key is held until it settles (the verb's reconcile,
/// or the operator's mark after the watch's `directive-send-unsettled` line),
/// and one found unreadable is held too, never a reason to act. A refusal
/// (the send's outcome unknown, another send still owed on the lane, the
/// lane's record moved) holds the stage owed and sends nothing. The residual,
/// stated and not claimed exactly-once: a crash after this send's settle,
/// then another send to the same lane, then the replay, sends the notice
/// twice, a repeated line in the session and not a harm.
fn send_session(
    settings: &Settings,
    lane: &Lane,
    key: &str,
    file: &Path,
    env: &Env,
    locking: Locking,
) -> NoticeSend {
    let fleet = state::fleet_path(&settings.state_dir);
    match crate::send::run_keyed(&fleet, &lane.item, file, settings, env, locking, key) {
        Ok(Keyed::Sent(sent)) => NoticeSend::Marked(session_mark(sent.send.result)),
        Ok(Keyed::Found(KeyedSend::Settled(result))) => NoticeSend::Marked(session_mark(result)),
        Ok(Keyed::Found(KeyedSend::Owed | KeyedSend::Unreadable)) | Err(_) => NoticeSend::Held,
    }
}

/// The run id a run directory's name carries.
fn run_id_of(run_dir: &str) -> &str {
    let name = Path::new(run_dir)
        .file_name()
        .and_then(OsStr::to_str)
        .unwrap_or(run_dir);
    name.strip_prefix("dev-validate-").unwrap_or(name)
}

/// Send the stage's owed notice and mark it: the owner word written, or
/// `owed` where the send is held and the stage left for the next walk.
fn send_and_mark(
    path: &Path,
    settings: &Settings,
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
    let mark = match send_notice(settings, to, &notice.key, &notice.text, env, locking) {
        NoticeSend::Marked(mark) => mark,
        NoticeSend::Held => return Ok(state::NOTICE_OWED.to_owned()),
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
        Validated::Start(_) | Validated::Launch(_) | Validated::End(_) | Validated::Stop(_) => {
            String::new()
        }
    })
}

/// The job's main: run the executor, close the stage, send the notice.
pub fn run(
    settings: &Settings,
    item: &str,
    round: &str,
    run_dir: &str,
    env: &Env,
    locking: Locking,
) -> Result<RunReply> {
    let path = state::item_path(&settings.state_dir, item);
    let (stages, index) = stage_of(&path, run_dir)?;
    let stage = &stages[index];
    let Some(proof) = &stage.proof else {
        return Err(Error::RunUnstarted {
            run_dir: run_dir.to_owned(),
        });
    };
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
    let worktree = start_field(&run_dir_path, "worktree")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            run_dir_path
                .parent()
                .and_then(Path::parent)
                .map(Path::to_path_buf)
                .unwrap_or_default()
        });
    let _ = (worktree, proof);
    execute(
        &run_dir_path,
        &crate::schedule::SystemClock,
        &super::group_leader(settings),
    )?;
    // The close's own clock: the child ran for up to the run's bound.
    let env = &env_now(env);
    // The stage as it stands once the child ended: a `validate stop` that
    // ended the child recorded its intent on the stage before it did.
    let (stages, index) = stage_of(&path, run_dir)?;
    let left = read_left(&run_dir_path, stages[index].stop.is_some());
    let notice = validate::end_notice(run_id_of(run_dir), run_dir, left.outcome);
    let ended = apply(
        &path,
        Validate::End(RecordEnd {
            round_id: round.to_owned(),
            run_dir: run_dir.to_owned(),
            outcome: left.outcome,
            end: left.at,
            seconds: left.seconds,
            selection: left.selection,
            notice: Some(notice),
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
    let notice = send_and_mark(&path, settings, item, &stages[index], env, locking)?;
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
/// its key on the lane's record.
pub fn deliver_owed(settings: &Settings, path: &Path, env: &Env, locking: Locking) -> Result<()> {
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
            && s.notice.as_ref().is_some_and(state::Notice::owed)
    }) {
        if let Err(e) = send_and_mark(path, settings, &item, stage, env, locking) {
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
    stop_files(Path::new(run_dir)).map(|answer| {
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
/// its own files name.
pub fn stop_worktree(
    settings: &Settings,
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
                    count(stop_files(&run.dir)?);
                }
            }
            Ok((item, _)) => match stop(settings, Some(&item), &rd, env, locking) {
                Ok(reply) if reply.ended == JobEnded::Signalled => count(Some(&reply.runner)),
                Ok(_) => {}
                Err(Error::RunClosed { .. }) => count(stop_files(&run.dir)?),
                Err(error) => return Err(error),
            },
            Err(Error::RunUnadmitted { .. }) => count(stop_files(&run.dir)?),
            Err(error) => return Err(error),
        }
    }
    Ok(stopped)
}

#[allow(
    clippy::disallowed_methods,
    reason = "a validation stop ends its recorded command group before stopping the executor that owns its close"
)]
pub(crate) fn stop_files(run_dir: &Path) -> Result<Option<&'static str>> {
    atomic(run_dir, "stop", "stop-requested\n")?;
    let mut stopped = false;
    match fs::read(run_dir.join("command")) {
        Ok(bytes) => {
            let record: CommandRecord = serde_json::from_slice(&bytes)?;
            let start = record.start.ok_or_else(|| {
                super::files::unreadable("stop-unreadable", "command identity was not recorded")
            })?;
            stopped = crate::effects::stop_group(&agent_runtime::process::Identity {
                pid: record.pid,
                start,
            })?;
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            let run = super::files::RunFile::read(run_dir)?;
            let runner = super::files::fields(&run_dir.join("runner"))
                .ok()
                .and_then(|r| r.get("runner").cloned());
            let bare = super::files::bare_pid(&run)?;
            // A start whose child never ran and whose launcher wrote no runner
            // record names no process and no unit: there is nothing to stop.
            if matches!(bare, super::files::BarePid::Unstarted)
                && fs::symlink_metadata(run_dir.join("runner"))
                    .is_err_and(|e| e.kind() == std::io::ErrorKind::NotFound)
            {
                return Ok(None);
            }
            if !matches!(bare, super::files::BarePid::Absent)
                && !matches!(runner.as_deref(), Some("setsid" | "attached" | "systemd"))
            {
                return Err(super::files::unreadable(
                    "stop-unreadable",
                    format!("run-dir={} record-unreadable", run_dir.display()),
                ));
            }
            match bare {
                // A bare pid's record names no identity: a unit is stopped by
                // the name its record carries, below, and any other child's
                // group by the child its argv names.
                super::files::BarePid::Live(_)
                | super::files::BarePid::Unstarted
                | super::files::BarePid::Gone
                | super::files::BarePid::Other
                    if runner.as_deref() == Some("systemd") => {}
                super::files::BarePid::Live(pid) => {
                    let ended = match agent_runtime::process::identity(pid) {
                        agent_runtime::reading::Reading::Live(identity) => {
                            crate::effects::stop_group(&identity)?
                        }
                        agent_runtime::reading::Reading::Gone => false,
                        agent_runtime::reading::Reading::Unreadable { cause } => {
                            return Err(super::files::unreadable(
                                "stop-unreadable",
                                format!("run-dir={} pid={pid} {cause}", run_dir.display()),
                            ));
                        }
                    };
                    let word = if runner.as_deref() == Some("attached") {
                        "attached"
                    } else {
                        "setsid"
                    };
                    return Ok(ended.then_some(word));
                }
                super::files::BarePid::Unstarted
                | super::files::BarePid::Gone
                | super::files::BarePid::Other => return Ok(None),
                super::files::BarePid::Absent => {
                    if command_reading(run_dir)?.is_some_and(|reading| {
                        !matches!(reading, agent_runtime::reading::Reading::Gone)
                    }) || !matches!(
                        super::files::runner_reading(&run),
                        agent_runtime::reading::Reading::Gone
                    ) {
                        return Err(super::files::unreadable(
                            "stop-unreadable",
                            format!("run-dir={} execution-unanswered", run_dir.display()),
                        ));
                    }
                }
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
    let runner = crate::effects::stop_recorded(&run_dir.join("runner"))?;
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
/// the run directory finds it.
pub fn stop(
    settings: &Settings,
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
    deliver_owed(settings, &path, env, locking)?;
    reconcile(&path, &round_id, env, locking)?;
    deliver_owed(settings, &path, env, locking)?;
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
    use crate::ops::validate::{end_notice, memory_cap_cause, sentinel_outcome};

    fn events(max: u64, oom_kill: u64) -> String {
        format!("low 0\nhigh 0\nmax {max}\noom {oom_kill}\noom_kill {oom_kill}\noom_group_kill 0\n")
    }

    /// A run whose own cgroup reached its cap while an OOM killer took a
    /// member fails with the cause and its figures, whatever the leader's
    /// exit, on its sentinel, its `state=done` reading and its lane's end
    /// notice; a kill the group's own cap did not cause, a cap reached
    /// with no kill, a group with no cap and counts unread after each
    /// keep the leader's verdict and the bound's suffix where it applies.
    #[test]
    #[allow(
        clippy::disallowed_methods,
        reason = "the row plants a cgroup's files and a run directory under its own temporary directories"
    )]
    fn a_kill_at_the_runs_own_memory_cap_fails_the_run_with_its_figures() {
        // case | memory.max | events after | memory.peak | leader exit | bounded |
        // the outcome | the cause the line ends with
        type Row<'a> = (
            &'a str,
            &'a str,
            Option<String>,
            Option<&'a str>,
            i32,
            bool,
            StageOutcome,
            Option<&'a str>,
        );
        let killed = Some("cause=memory-cap limit=1073741824 peak=1100000000");
        let rows: [Row; 8] = [
            (
                "killed, leader 0",
                "1073741824",
                Some(events(3, 1)),
                Some("1100000000"),
                0,
                false,
                StageOutcome::Fail,
                killed,
            ),
            (
                "killed, leader 137",
                "1073741824",
                Some(events(3, 1)),
                Some("1100000000"),
                137,
                false,
                StageOutcome::Fail,
                killed,
            ),
            (
                "killed at the bound",
                "1073741824",
                Some(events(3, 1)),
                Some("1100000000"),
                124,
                true,
                StageOutcome::Fail,
                killed,
            ),
            (
                "killed, peak unread",
                "1073741824",
                Some(events(3, 1)),
                None,
                0,
                false,
                StageOutcome::Fail,
                Some("cause=memory-cap limit=1073741824 peak=unread"),
            ),
            (
                "an ancestor's kill",
                "1073741824",
                Some(events(0, 1)),
                Some("1"),
                0,
                false,
                StageOutcome::Pass,
                None,
            ),
            (
                "cap reached, reclaimed",
                "1073741824",
                Some(events(3, 0)),
                Some("1"),
                1,
                false,
                StageOutcome::Fail,
                None,
            ),
            (
                "no cap, bound",
                "max",
                Some(events(0, 0)),
                None,
                124,
                true,
                StageOutcome::NoVerdict,
                None,
            ),
            (
                "counts gone after",
                "1073741824",
                None,
                None,
                0,
                false,
                StageOutcome::Pass,
                None,
            ),
        ];
        for (case, max, after, peak, status, bounded, outcome, cause) in rows {
            let dir = tempfile::tempdir().expect("tempdir");
            fs::write(dir.path().join("memory.max"), format!("{max}\n")).unwrap();
            fs::write(dir.path().join("memory.events"), events(0, 0)).unwrap();
            let cap = Cap::of(dir.path().to_path_buf());
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
                bounded,
                Some(&MemoryEnd::of(&cap)),
            );
            let line = line.trim_end();
            assert_eq!(sentinel_outcome(line), Some(outcome), "{case}: {line}");
            assert_eq!(memory_cap_cause(line), cause, "{case}: {line}");
            match (max, bounded) {
                ("max", _) => assert!(
                    line.contains(" memory-cap=unavailable cause=cgroup-uncapped"),
                    "{case}: {line}"
                ),
                (_, true) if cause.is_none() => {
                    assert!(line.ends_with(" verdict=no-verdict"), "{case}: {line}")
                }
                _ => {}
            }
            if case == "counts gone after" {
                assert!(line.contains(" memory-cap=unread"), "{case}: {line}");
            }
            // The run's end notice and its waiter's `state=done` line carry
            // the cause the sentinel ends with.
            let run = tempfile::tempdir().expect("tempdir");
            let run_dir = run.path().display().to_string();
            fs::write(run.path().join("exit"), format!("{line}\n")).unwrap();
            fs::write(
                run.path().join("start"),
                "start=0\ncap-secs=1\npoll-secs=1\nvalidate-mode=full\n",
            )
            .unwrap();
            let notice = end_notice("x", &run_dir, outcome).text;
            let (done, _) =
                super::super::files::wait(run.path(), 1, &crate::schedule::SystemClock).unwrap();
            for (reader, text, mark) in [
                ("notice", &notice, " state=fail "),
                ("done", &done, " validate=FAILING "),
            ] {
                match cause {
                    Some(cause) => assert!(
                        text.contains(&format!("{mark}{cause} run-dir=")),
                        "{case} {reader}: {text}"
                    ),
                    None => assert!(!text.contains("memory-cap"), "{case} {reader}: {text}"),
                }
            }
        }
    }
}
