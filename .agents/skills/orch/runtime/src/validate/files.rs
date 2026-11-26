//! Run-file reads for validation, proof and the catalog entry.
use crate::error::{Error, Result};
use crate::state::{Proof, Reused, Stage, StageOutcome, ValidateMode};
use agent_runtime::clock::Clock;
use agent_runtime::effects::{JobHandle, SidecarRead};
use agent_runtime::{process, reading::Reading};
use serde_json::json;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, UNIX_EPOCH};

pub fn unreadable(read: &'static str, cause: impl ToString) -> Error {
    Error::ValidateUnreadable {
        read,
        cause: cause.to_string(),
    }
}

/// The refusal of a read whose cause is one word the caller holds, kept on
/// the keyed line as `field=value`.
pub fn unread_value(read: &'static str, field: &'static str, value: impl ToString) -> Error {
    Error::ValidateValue {
        read,
        field,
        value: value.to_string(),
    }
}

pub fn fields(path: &Path) -> Result<BTreeMap<String, String>> {
    let text = fs::read_to_string(path)
        .map_err(|e| unreadable("record", format!("{}: {e}", path.display())))?;
    Ok(text
        .lines()
        .filter_map(|l| l.split_once('=').map(|(k, v)| (k.to_owned(), v.to_owned())))
        .collect())
}

/// The battery's selection line opens with this, its own form: a refusal or
/// notice of the entry also opens `validate:` and can land in a run's log
/// after it.
const SELECTION: &str = "validate: lanes=";

/// The last selection line of a run's log.
pub fn selection_line(log: &str) -> Option<&str> {
    log.lines().rfind(|l| l.starts_with(SELECTION))
}

pub fn mode(word: &str) -> Result<ValidateMode> {
    match word {
        "full" => Ok(ValidateMode::Full),
        "range" => Ok(ValidateMode::Range),
        "ci" => Ok(ValidateMode::Ci),
        "docs" => Ok(ValidateMode::Docs),
        _ => Err(unreadable("invalid-mode", word)),
    }
}

pub struct Timing {
    pub seconds: u64,
    pub started_at: String,
    pub ended_at: String,
}

pub struct RunFile {
    pub dir: PathBuf,
    pub start: BTreeMap<String, String>,
    pub sentinel: Option<String>,
    stopped: bool,
}
impl RunFile {
    pub fn read(dir: &Path) -> Result<Self> {
        let sentinel = match fs::read_to_string(dir.join("exit")) {
            Ok(s) if !s.trim().is_empty() => Some(s.trim_end().to_owned()),
            Ok(_) => None,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
            Err(e) => return Err(unreadable("sentinel-unreadable", e)),
        };
        let stopped = match fs::read_to_string(dir.join("stop")) {
            Ok(text) if text == "stop-requested\n" => true,
            Ok(_) => return Err(unreadable("stop-unreadable", dir.display())),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => false,
            Err(e) => return Err(unreadable("stop-unreadable", e)),
        };
        Ok(Self {
            stopped,
            dir: dir.to_owned(),
            start: fields(&dir.join("start"))?,
            sentinel,
        })
    }
    pub fn get(&self, key: &str) -> &str {
        self.start.get(key).map(String::as_str).unwrap_or("")
    }
    pub fn outcome(&self) -> Option<StageOutcome> {
        self.stop_word(
            self.sentinel
                .as_deref()
                .and_then(crate::ops::validate::sentinel_outcome),
        )
    }
    /// How the run ended. With a sentinel, its word, `None` where it names
    /// none. Without one, `lost` where [`lost`] reads it so under
    /// `past_grace`, else `None`. Either word reads `stopped` where the stop
    /// file records a stop.
    fn ending(&self, past_grace: bool) -> Result<Option<StageOutcome>> {
        if self.sentinel.is_some() {
            return Ok(self.outcome());
        }
        Ok(self.stop_word(lost(self, past_grace)?.then_some(StageOutcome::Lost)))
    }
    /// A stop the stop file records ended the run: its ending reads
    /// `stopped`, as the stage's close reads it.
    fn stop_word(&self, ended: Option<StageOutcome>) -> Option<StageOutcome> {
        if self.stopped {
            ended.map(|_| StageOutcome::Stopped)
        } else {
            ended
        }
    }
    pub fn verdict(&self) -> Result<&'static str> {
        self.verdict_of(self.ending(false)?)
    }
    fn verdict_of(&self, ending: Option<StageOutcome>) -> Result<&'static str> {
        match ending {
            Some(StageOutcome::Pass) if self.get("validate-mode") == "ci" => Ok("pending"),
            Some(StageOutcome::Pass) => Ok("pass"),
            Some(StageOutcome::NoVerdict | StageOutcome::Stopped) => Ok("no-verdict"),
            Some(_) => Ok("FAILING"),
            None if self.sentinel.is_some() => {
                Err(unreadable("sentinel-unreadable", self.dir.display()))
            }
            None => Ok("unfinished"),
        }
    }
    pub fn selection(&self) -> Result<(Option<String>, String)> {
        let fallback = match self.get("selection") {
            "all" => "all",
            "subset" => "subset",
            _ => "unreported",
        }
        .to_owned();
        let log = match fs::read_to_string(self.dir.join("log")) {
            Ok(s) => s,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok((None, fallback)),
            Err(e) => return Err(unreadable("record-unreadable", e)),
        };
        let Some(line) = selection_line(&log) else {
            return Ok((None, fallback));
        };
        let words: Vec<_> = line.split(' ').collect();
        if words.len() != 3 {
            return Ok((None, fallback));
        }
        let lanes = words[1].strip_prefix("lanes=").filter(|s| {
            !s.is_empty()
                && s.split(',').all(|s| {
                    !s.is_empty()
                        && s.bytes()
                            .all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b))
                })
        });
        let selection = words[2]
            .strip_prefix("selection=")
            .filter(|s| matches!(*s, "all" | "subset" | "battery"));
        Ok(match (lanes, selection) {
            (Some(l), Some(s)) => (Some(l.to_owned()), s.to_owned()),
            _ => (None, fallback),
        })
    }
    pub fn proof(&self) -> Result<Proof> {
        let read = |name: &str| match fs::read_to_string(self.dir.join(name)) {
            Ok(text) => Ok(Some(text)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(unreadable("proof-unreadable", e)),
        };
        let paths = read("paths")?;
        let cmd = read("cmd")?;
        let complete = paths.is_some() && cmd.is_some();
        let paths = paths.unwrap_or_default();
        let paths: Vec<_> = paths.lines().map(str::to_owned).collect();
        Ok(Proof {
            tree: self.get("tree").into(),
            head: self.get("head").into(),
            base: self.get("validate-base").into(),
            mode: mode(self.get("validate-mode"))?,
            cause: None,
            caller: "dev".into(),
            cmd: if complete {
                cmd.unwrap_or_default()
            } else {
                String::new()
            },
            class: self.get("class").into(),
            docs_only: self.get("docs-only") == "true",
            paths_hash: crate::ops::validate::paths_hash(&paths),
            scoped: self.get("scoped") == "true",
            selection: self.selection()?.1,
            finding_prefix: self.get("finding-prefix").into(),
            poll_secs: self.get("poll-secs").parse().unwrap_or(30),
            expected_secs: self.get("expected-secs").parse().ok(),
            class_base: (!self.get("class-base").is_empty()).then(|| self.get("class-base").into()),
            ci_fallback: None,
            ci_event: None,
            class_fallback: None,
            reused: (!self.get("pass-run").is_empty()).then(|| Reused::PassRun {
                run_dir: self.get("pass-run").into(),
            }),
        })
    }
    pub fn stage(&self) -> Result<Stage> {
        let start = self
            .get("start")
            .parse::<u64>()
            .map_err(|e| unreadable("start", e))?;
        self.stage_at(start)
    }
    fn stage_at(&self, start: u64) -> Result<Stage> {
        let end = self.sentinel.as_deref().and_then(|s| {
            s.split_whitespace()
                .find_map(|w| w.strip_prefix("at="))
                .and_then(agent_runtime::clock::epoch_secs)
        });
        let proof = self.proof()?;
        let outcome = if proof.cmd.is_empty() {
            Some(StageOutcome::NoVerdict)
        } else {
            self.outcome()
        };
        serde_json::from_value(json!({"kind":"validate", "start":start, "end":end, "outcome":outcome, "run_dir":self.dir, "proof":proof})).map_err(Error::from)
    }
    pub fn record(&self) -> Result<String> {
        let mode = mode(self.get("validate-mode"))?;
        let (lanes, selection) = self.selection()?;
        let ending = self.ending(false)?;
        let verdict = self.verdict_of(ending)?;
        let mut line = format!(
            "validate-mode={} {}selection={selection} verdict={verdict} head={} start={}",
            mode.word(),
            lanes.map(|s| format!("lanes={s} ")).unwrap_or_default(),
            self.get("head"),
            self.get("start")
        );
        for key in ["class-base", "tree"] {
            self.append(&mut line, key);
        }
        if let Some(t) = self.timing()? {
            line.push_str(&format!(
                " seconds={} started-at={} ended-at={}",
                t.seconds, t.started_at, t.ended_at
            ));
        }
        for key in ["scoped", "ci-fallback", "host"] {
            self.append(&mut line, key);
        }
        if self.get("ci-event") == "merge_group" {
            self.append(&mut line, "ci-event");
        }
        let mut slow: Vec<String> = Vec::new();
        for warning in self.warnings()?.lines() {
            if let Some(step) = warning
                .split(' ')
                .find_map(|word| word.strip_prefix("step="))
                .filter(|step| !slow.iter().any(|seen| seen == step))
            {
                slow.push(step.to_owned());
            }
        }
        if !slow.is_empty() {
            line.push_str(&format!(" slow-step={}", slow.join(",")));
        }
        // The run ended with no sentinel: `--wait`'s word for it.
        if self.sentinel.is_none() && ending == Some(StageOutcome::Lost) {
            line.push_str(" state=lost");
        }
        Ok(line)
    }
    /// The executor's warnings for a step or the run past its expected time.
    pub fn warnings(&self) -> Result<String> {
        match fs::read_to_string(self.dir.join("warning")) {
            Ok(text) => Ok(text),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
            Err(e) => Err(unreadable("warning-unreadable", e)),
        }
    }
    /// The ended run's timing record; a run with no sentinel has none yet.
    pub fn timing(&self) -> Result<Option<Timing>> {
        if self.sentinel.is_none() {
            return Ok(None);
        }
        let timing =
            fields(&self.dir.join("timing")).map_err(|e| unreadable("timing-unreadable", e))?;
        let seconds = timing
            .get("seconds")
            .and_then(|v| v.parse::<u64>().ok())
            .ok_or_else(|| unread_value("timing-unreadable", "cause", "seconds"))?;
        let time = |key: &'static str| {
            timing
                .get(key)
                .filter(|v| agent_runtime::clock::epoch_secs(v).is_some())
                .cloned()
                .ok_or_else(|| unread_value("timing-unreadable", "cause", key))
        };
        Ok(Some(Timing {
            seconds,
            started_at: time("started-at")?,
            ended_at: time("ended-at")?,
        }))
    }
    fn append(&self, line: &mut String, key: &str) {
        if !self.get(key).is_empty() {
            line.push_str(&format!(" {key}={}", self.get(key)));
        }
    }
}

pub(super) fn run_dirs(worktree: &Path) -> Result<Vec<PathBuf>> {
    let entries = match fs::read_dir(worktree.join("tmp")) {
        Ok(e) => e,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(unreadable("runs", e)),
    };
    let mut dirs = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|e| unreadable("runs", e))?;
        if !entry
            .file_name()
            .to_string_lossy()
            .starts_with(super::RUN_DIR_PREFIX)
        {
            continue;
        }
        // Released orch left plain files with this prefix beside run directories.
        let dir = entry.path();
        match fs::metadata(&dir) {
            Ok(metadata) if metadata.is_dir() => {}
            Ok(_) => continue,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => return Err(unreadable("runs", e)),
        }
        match fs::metadata(dir.join("start")) {
            Ok(_) => dirs.push(dir),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(unreadable("start", e)),
        }
    }
    Ok(dirs)
}

pub fn runs(worktree: &Path) -> Result<Vec<RunFile>> {
    let mut runs = run_dirs(worktree)?
        .iter()
        .map(|dir| RunFile::read(dir))
        .collect::<Result<Vec<_>>>()?;
    runs.sort_by(|a, b| {
        a.get("start")
            .parse::<u64>()
            .unwrap_or(u64::MAX)
            .cmp(&b.get("start").parse::<u64>().unwrap_or(u64::MAX))
            .then(a.dir.cmp(&b.dir))
    });
    Ok(runs)
}

pub fn stages(worktree: &Path) -> Result<Vec<Stage>> {
    let mut stages = Vec::new();
    for run in runs(worktree)?.iter().filter(|r| {
        matches!(r.get("validate-mode"), "full" | "range" | "ci" | "docs")
            && !r.get("tree").is_empty()
    }) {
        if run.get("start").parse::<u64>().is_ok() {
            stages.push(run.stage()?);
            continue;
        }
        // A run whose start second cannot be read has no place in the order:
        // its pass proves nothing, and any other answer stands after every
        // pass at its tree.
        if run.outcome() == Some(StageOutcome::Pass) {
            continue;
        }
        let mut unordered = run.stage_at(u64::MAX)?;
        unordered.end = None;
        unordered.outcome = None;
        stages.push(unordered);
    }
    Ok(stages)
}

pub enum LastPass {
    Pass(RunFile),
    Red(PathBuf),
    None,
}
impl LastPass {
    pub fn line(&self) -> (String, i32) {
        match self {
            Self::Pass(run) => (
                format!(
                    "run-dir={} head={} tree={}{}",
                    run.dir.display(),
                    run.get("head"),
                    run.get("tree"),
                    if run.outcome() == Some(StageOutcome::NoVerdict) {
                        " verdict=no-verdict"
                    } else {
                        ""
                    }
                ),
                0,
            ),
            Self::Red(dir) => (format!("last-pass=red run-dir={}", dir.display()), 1),
            Self::None => ("last-pass=none".into(), 1),
        }
    }
}

pub fn last_pass(worktree: &Path) -> Result<LastPass> {
    let mut found = None;
    let mut red = None;
    let mut unknown = None;
    for run in runs(worktree)? {
        if !matches!(run.get("validate-mode"), "full" | "range" | "docs") {
            continue;
        }
        let no_finding = || {
            let prefix = run.get("finding-prefix");
            !prefix.is_empty()
                && fs::read_to_string(run.dir.join("log"))
                    .is_ok_and(|s| !s.lines().skip(1).any(|l| l.starts_with(prefix)))
        };
        let passed = run.outcome() == Some(StageOutcome::Pass)
            || (run.outcome() == Some(StageOutcome::NoVerdict) && no_finding());
        let start = run.get("start").parse::<u64>();
        if !passed {
            match start {
                Ok(start) => red = Some((start, run.dir)),
                Err(_) => unknown = Some(run.dir),
            }
        } else if !run.get("tree").is_empty()
            && !run.get("head").is_empty()
            && let Ok(start) = start
            && found.as_ref().is_none_or(|(old, _)| start > *old)
        {
            found = Some((start, run));
        }
    }
    if let Some(dir) = unknown {
        return Ok(LastPass::Red(dir));
    }
    if let Some((start, dir)) = red
        && found.as_ref().is_none_or(|(pass, _)| start >= *pass)
    {
        return Ok(LastPass::Red(dir));
    }
    Ok(found
        .map(|(_, run)| LastPass::Pass(run))
        .unwrap_or(LastPass::None))
}

/// Whether the directory is a start whose child never ran: the runtime's
/// start creates the job's error log, `job.err`, with the run directory and
/// before any other record, and its executor records itself (`executor`)
/// and claims the directory (`execution`, `command`) before it runs
/// anything, so a directory holding none of the four is never live, holds
/// nothing to stop, and is lost once the launch grace has passed. Any other
/// directory is read by the executor's and the launcher's records.
pub(crate) fn unstarted(run: &RunFile) -> Result<bool> {
    for record in ["executor", "execution", "command", "job.err"] {
        match fs::symlink_metadata(run.dir.join(record)) {
            Ok(_) => return Ok(false),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(unreadable(record, e)),
        }
    }
    Ok(true)
}

/// A systemd run's runner reading inside the wrapper, which hides the
/// user manager.
const MANAGER_HIDDEN: &str = "manager-hidden";

#[allow(
    clippy::disallowed_methods,
    reason = "a foreground run is held by its recorded owner identity while its command starts"
)]
pub(crate) fn runner_reading(run: &RunFile) -> Reading<u32> {
    let runner = fields(&run.dir.join("runner"));
    if let Ok(runner) = &runner
        && runner.get("runner").is_some_and(|r| r == "attached")
    {
        let (Some(pid), Some(start)) = (
            runner.get("pid").and_then(|p| p.parse().ok()),
            runner.get("start"),
        ) else {
            return Reading::Unreadable {
                cause: "runner-unreadable",
            };
        };
        return match process::still_runs(&process::Identity {
            pid,
            start: start.clone(),
        }) {
            Reading::Live(_) => Reading::Live(pid),
            Reading::Gone => Reading::Gone,
            Reading::Unreadable { cause } => Reading::Unreadable { cause },
        };
    }
    let record = run.dir.join("runner");
    // The manager that would answer for the unit is out of reach, at this
    // poll and every later one.
    if agent_runtime::confine::confined()
        && matches!(
            agent_runtime::effects::job::read_handle(&record),
            SidecarRead::Present(JobHandle::Unit { .. })
        )
    {
        return Reading::Unreadable {
            cause: MANAGER_HIDDEN,
        };
    }
    match agent_runtime::effects::job::recorded_live(&record) {
        Reading::Live(()) => Reading::Live(0),
        Reading::Gone => Reading::Gone,
        Reading::Unreadable { cause } => Reading::Unreadable { cause },
    }
}

pub fn live(worktree: &Path) -> Result<Option<(PathBuf, u32)>> {
    live_inner(worktree, false)
}

/// A stop can report a failed read with its cause. Starts keep their
/// existing refusal on uncertain liveness to avoid overlapping jobs.
pub(crate) fn live_for_stop(worktree: &Path) -> Result<Option<(PathBuf, u32)>> {
    live_inner(worktree, true)
}

fn live_inner(worktree: &Path, strict: bool) -> Result<Option<(PathBuf, u32)>> {
    for run in runs(worktree)? {
        if strict && run.get("start").parse::<u64>().is_err() {
            return Err(unreadable("start", run.dir.display()));
        }
        if run.sentinel.is_some() {
            if strict {
                run.verdict()?;
            }
            continue;
        }
        match holds(&run, strict)? {
            Reading::Live(pid) => return Ok(Some((run.dir, pid))),
            // A start never overlaps a run whose work it cannot read.
            Reading::Unreadable { .. } => return Ok(Some((run.dir, 0))),
            Reading::Gone => {}
        }
    }
    Ok(None)
}

/// The work that holds a run with no sentinel, by the pid it names: its
/// command's group by the identity its executor recorded, else its runner
/// by the launcher's record, or by the executor's own record where the
/// wrapper hides the unit's manager. A run whose child never ran holds
/// nothing. Under `strict` an unreadable reading refuses with its cause.
/// Otherwise a hidden manager's reading with no executor record stays
/// unreadable, and any other unreadable reading holds the run, since a
/// later read can answer it: unconfined, `unit-unsettled` is also the
/// reading of a unit that still runs.
fn holds(run: &RunFile, strict: bool) -> Result<Reading<u32>> {
    let command = super::run::command_reading(&run.dir)
        .map_err(|e| unreadable("command-identity", format!("{}: {e}", run.dir.display())))?;
    if let (true, Some(Reading::Unreadable { cause })) = (strict, command.as_ref()) {
        return Err(unreadable(
            "command-identity",
            format!("{}: {cause}", run.dir.display()),
        ));
    }
    if command.is_some_and(|reading| !matches!(reading, Reading::Gone)) {
        let pid = fs::read_to_string(run.dir.join("pid"))
            .ok()
            .and_then(|p| p.trim().parse().ok())
            .unwrap_or(0);
        return Ok(Reading::Live(pid));
    }
    if unstarted(run)? {
        return Ok(Reading::Gone);
    }
    let reading = match runner_reading(run) {
        Reading::Unreadable {
            cause: MANAGER_HIDDEN,
        } => match super::run::executor_reading(&run.dir)
            .map_err(|e| unreadable("executor-identity", format!("{}: {e}", run.dir.display())))?
        {
            Some(Reading::Live(())) => Reading::Live(0),
            Some(Reading::Gone) => Reading::Gone,
            Some(Reading::Unreadable { cause }) => Reading::Unreadable { cause },
            None => Reading::Unreadable {
                cause: MANAGER_HIDDEN,
            },
        },
        reading => reading,
    };
    match reading {
        Reading::Unreadable { cause } if strict => Err(unreadable(
            "runner",
            format!("{}: {cause}", run.dir.display()),
        )),
        Reading::Unreadable { cause } if cause != MANAGER_HIDDEN => Ok(Reading::Live(0)),
        reading => Ok(reading),
    }
}

/// Whether a run that wrote no sentinel is lost: no work holds it, no
/// sentinel has landed since `run` was read, and its executor claimed it
/// (`execution`) or its launch grace has passed. `--wait` and `--record`
/// read such a run here alike; `--record` reads no clock, so a run its
/// executor never claimed stays unfinished there. Work [`holds`] cannot
/// read, a unit whose manager the wrapper hides and whose executor left no
/// record, holds the run within its launch grace, where the executor may
/// not yet have started, and past the grace refuses `liveness-unreadable`
/// with its cause: its executor predates the record or never ran, and no
/// later poll here answers it.
fn lost(run: &RunFile, past_grace: bool) -> Result<bool> {
    let unread = match holds(run, false)? {
        Reading::Live(_) => return Ok(false),
        Reading::Unreadable { cause } => Some(cause),
        Reading::Gone => None,
    };
    // An executor that wrote its sentinel and exited after `run` was read
    // holds nothing now: the run ended with its verdict.
    if fs::metadata(run.dir.join("exit")).is_ok_and(|m| m.len() > 0) {
        return Ok(false);
    }
    match (unread, past_grace) {
        (Some(cause), true) => Err(unread_value("liveness-unreadable", "cause", cause)),
        (Some(_), false) => Ok(false),
        (None, true) => Ok(true),
        (None, false) => match fs::symlink_metadata(run.dir.join("execution")) {
            Ok(_) => Ok(true),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(unreadable("execution", e)),
        },
    }
}

/// Follow the run for `budget` seconds: its state line, under the warnings
/// the executor has written for a slow step or run.
pub fn wait(run_dir: &Path, budget: u64, clock: &dyn Clock) -> Result<(String, i32)> {
    let (line, exit) = wait_state(run_dir, budget, clock)?;
    let warnings = RunFile::read(run_dir)?.warnings()?;
    Ok((format!("{warnings}{line}"), exit))
}

/// Follow an admitted run another seat starts, from before its directory
/// exists, for `budget` seconds in all: queued while its `start` record is
/// absent, read every `poll` seconds, then followed as [`wait`] follows it.
/// A budget that ends before the start prints `state=queued` and exits 3.
/// A run no stage in `state_dir` admitted refuses `run-unadmitted`, one
/// whose stage closed with no start record refuses `run-ended-unstarted`
/// with the stage's word, as no verdict will come, and one whose open stage
/// holds the key of a start refused before it recorded the run refuses
/// `start-refused` with that key. The closed stage's cause is the refusal
/// that kept the run from starting: the key a refused start left, else the
/// key its refused launch's cause leads with, else the close's word.
#[allow(
    clippy::disallowed_methods,
    reason = "validation waits read the injected clock and never start work"
)]
pub fn wait_queued(
    state_dir: &Path,
    run_dir: &Path,
    budget: u64,
    poll: u64,
    clock: &dyn Clock,
) -> Result<(String, i32)> {
    let started = || match fs::symlink_metadata(run_dir.join("start")) {
        Ok(_) => Ok(true),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(unreadable("start", e)),
    };
    let follow = |call: std::time::Instant| {
        wait(
            run_dir,
            call.saturating_duration_since(clock.now()).as_secs(),
            clock,
        )
    };
    let begun = clock.now();
    let call = begun + Duration::from_secs(budget);
    loop {
        if started()? {
            return follow(call);
        }
        let (_, stage) = super::admitted_stage(state_dir, &run_dir.display().to_string())?;
        if stage.end.is_some() {
            // The start writes the record before it records the launch that
            // can close the stage, so a record that stands after the close
            // landed between the two reads.
            if started()? {
                return follow(call);
            }
            let detail = stage.job.and_then(|job| job.cause);
            let cause = match (stage.refused, stage.cause, &detail) {
                (Some(refused), _, _) => Some(refused),
                (None, Some(crate::ops::RunCause::LaunchFailed), Some(launch)) => {
                    Some(crate::error::launch_refusal_key(launch).to_owned())
                }
                (None, cause, _) => cause.map(|c| c.word().to_owned()),
            };
            return Err(Error::RunEndedUnstarted {
                run_dir: run_dir.display().to_string(),
                outcome: stage.outcome.map_or("none", StageOutcome::word),
                cause,
                detail,
            });
        }
        // A start clears the key when it records the run, before it writes
        // the `start` record, so a key read after an absent record stood
        // with no start.
        if let Some(cause) = stage.refused {
            return Err(Error::StartRefused {
                run_dir: run_dir.display().to_string(),
                cause,
            });
        }
        let now = clock.now();
        if now >= call {
            return Ok((
                format!(
                    "state=queued waited-secs={} run-dir={}",
                    now.duration_since(begun).as_secs(),
                    run_dir.display()
                ),
                3,
            ));
        }
        clock.sleep(Duration::from_secs(poll).min(call.saturating_duration_since(now)));
    }
}

#[allow(
    clippy::disallowed_methods,
    reason = "validation waits read the injected clock and never start work"
)]
fn wait_state(run_dir: &Path, budget: u64, clock: &dyn Clock) -> Result<(String, i32)> {
    let first = RunFile::read(run_dir)?;
    let start = first
        .get("start")
        .parse::<u64>()
        .map_err(|e| unreadable("no-run", e))?;
    let poll = first
        .get("poll-secs")
        .parse::<u64>()
        .ok()
        .filter(|n| *n > 0)
        .ok_or_else(|| unread_value("no-run", "cause", "poll-secs"))?;
    let call = clock.now() + Duration::from_secs(budget);
    loop {
        let run = RunFile::read(run_dir)?;
        if let Some(s) = &run.sentinel {
            let verdict = run.verdict()?;
            let verdict = if verdict == "pending" {
                "pass"
            } else {
                verdict
            };
            let status = s.split_whitespace().next().unwrap_or("");
            let at = s
                .split_whitespace()
                .find(|s| s.starts_with("at="))
                .unwrap_or("");
            let cause = crate::ops::validate::failure_cause(s)
                .filter(|_| verdict == "FAILING")
                .map(|cause| format!(" {cause}"))
                .unwrap_or_default();
            return Ok((
                format!(
                    "state=done {status} {at} validate={verdict}{cause} run-dir={} log={}/log",
                    run_dir.display(),
                    run_dir.display()
                ),
                i32::from(verdict != "pass"),
            ));
        }
        let now = clock
            .wall()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        let elapsed = now.saturating_sub(start);
        let log = if fs::metadata(run_dir.join("log")).is_ok() {
            format!(" log={}/log", run_dir.display())
        } else {
            String::new()
        };
        if let Some(ending) = run.ending(elapsed >= poll.max(10))? {
            let line = match ending {
                StageOutcome::Lost => format!(
                    "state=lost elapsed-secs={elapsed} validate=FAILING run-dir={}{log}",
                    run_dir.display()
                ),
                StageOutcome::Stopped => format!(
                    "state=done stopped validate=no-verdict run-dir={} log={}/log",
                    run_dir.display(),
                    run_dir.display()
                ),
                other => unreachable!("a run with no sentinel ends lost or stopped, not {other:?}"),
            };
            return Ok((line, 1));
        }
        if clock.now() >= call {
            return Ok((
                format!(
                    "state=running elapsed-secs={elapsed} run-dir={}",
                    run_dir.display()
                ),
                3,
            ));
        }
        clock.sleep(Duration::from_secs(poll).min(call.saturating_duration_since(clock.now())));
    }
}
