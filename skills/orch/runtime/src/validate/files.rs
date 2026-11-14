//! Run-file reads for validation, proof and the catalog entry.
use crate::error::{Error, Result};
use crate::state::{Proof, Reused, Stage, StageOutcome, ValidateMode};
use agent_runtime::clock::Clock;
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

pub fn fields(path: &Path) -> Result<BTreeMap<String, String>> {
    let text = fs::read_to_string(path)
        .map_err(|e| unreadable("record", format!("{}: {e}", path.display())))?;
    Ok(text
        .lines()
        .filter_map(|l| l.split_once('=').map(|(k, v)| (k.to_owned(), v.to_owned())))
        .collect())
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
        let outcome = self
            .sentinel
            .as_deref()
            .and_then(crate::ops::validate::sentinel_outcome);
        if self.stopped {
            outcome.map(|_| StageOutcome::Stopped)
        } else {
            outcome
        }
    }
    pub fn verdict(&self) -> Result<&'static str> {
        match (self.sentinel.is_some(), self.outcome()) {
            (_, Some(StageOutcome::Pass)) if self.get("validate-mode") == "ci" => Ok("pending"),
            (_, Some(StageOutcome::Pass)) => Ok("pass"),
            (_, Some(StageOutcome::NoVerdict | StageOutcome::Stopped)) => Ok("no-verdict"),
            (_, Some(_)) => Ok("FAILING"),
            (false, None) => Ok("unfinished"),
            (true, None) => Err(unreadable("sentinel-unreadable", self.dir.display())),
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
        let Some(line) = log.lines().rfind(|l| l.starts_with("validate:")) else {
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
            timeout_secs: self.get("timeout-secs").parse().unwrap_or(0),
            poll_secs: self.get("poll-secs").parse().unwrap_or(30),
            cap_secs: self.get("cap-secs").parse().unwrap_or(0),
            class_base: (!self.get("class-base").is_empty()).then(|| self.get("class-base").into()),
            ci_fallback: None,
            ci_event: None,
            class_fallback: None,
            reused: if !self.get("pass-run").is_empty() {
                Some(Reused::PassRun {
                    run_dir: self.get("pass-run").into(),
                })
            } else if !self.get("bound-run").is_empty() {
                Some(Reused::BoundRun {
                    run_dir: self.get("bound-run").into(),
                })
            } else {
                None
            },
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
        let mut line = format!(
            "validate-mode={} {}selection={selection} verdict={} head={} start={}",
            mode.word(),
            lanes.map(|s| format!("lanes={s} ")).unwrap_or_default(),
            self.verdict()?,
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
        for key in ["scoped", "ci-fallback"] {
            self.append(&mut line, key);
        }
        if self.get("ci-event") == "merge_group" {
            self.append(&mut line, "ci-event");
        }
        Ok(line)
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
            .ok_or_else(|| unreadable("timing-unreadable", "seconds"))?;
        let time = |key: &'static str| {
            timing
                .get(key)
                .filter(|v| agent_runtime::clock::epoch_secs(v).is_some())
                .cloned()
                .ok_or_else(|| unreadable("timing-unreadable", key))
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

pub fn runs(worktree: &Path) -> Result<Vec<RunFile>> {
    let entries = match fs::read_dir(worktree.join("tmp")) {
        Ok(e) => e,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(unreadable("runs", e)),
    };
    let mut runs = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|e| unreadable("runs", e))?;
        if !entry
            .file_name()
            .to_string_lossy()
            .starts_with("dev-validate-")
        {
            continue;
        }
        match fs::metadata(entry.path().join("start")) {
            Ok(_) => runs.push(RunFile::read(&entry.path())?),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(unreadable("start", e)),
        }
    }
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
/// before any other record, and its executor claims the directory
/// (`execution`, `command`) before it runs anything, so a directory holding
/// none of the three is never live, holds nothing to stop, and is lost once
/// the launch grace has passed. Any other directory is read by the
/// executor's and the launcher's records.
pub(crate) fn unstarted(run: &RunFile) -> Result<bool> {
    for record in ["execution", "command", "job.err"] {
        match fs::symlink_metadata(run.dir.join(record)) {
            Ok(_) => return Ok(false),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(unreadable(record, e)),
        }
    }
    Ok(true)
}

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
    match agent_runtime::effects::job::recorded_live(&run.dir.join("runner")) {
        Reading::Live(()) => Reading::Live(0),
        Reading::Gone => Reading::Gone,
        Reading::Unreadable { cause } => Reading::Unreadable { cause },
    }
}

pub fn live(worktree: &Path) -> Result<Option<(PathBuf, u32)>> {
    for run in runs(worktree)? {
        if run.sentinel.is_some() {
            continue;
        }
        if super::run::command_reading(&run.dir)?
            .is_some_and(|reading| !matches!(reading, Reading::Gone))
        {
            let pid = fs::read_to_string(run.dir.join("pid"))
                .ok()
                .and_then(|p| p.trim().parse().ok())
                .unwrap_or(0);
            return Ok(Some((run.dir, pid)));
        }
        if unstarted(&run)? {
            continue;
        }
        match runner_reading(&run) {
            Reading::Live(pid) => return Ok(Some((run.dir, pid))),
            Reading::Unreadable { .. } => return Ok(Some((run.dir, 0))),
            Reading::Gone => {}
        }
    }
    Ok(None)
}

#[allow(
    clippy::disallowed_methods,
    reason = "validation waits read the injected clock and never start work"
)]
pub fn wait(run_dir: &Path, budget: u64, clock: &dyn Clock) -> Result<(String, i32)> {
    let first = RunFile::read(run_dir)?;
    let start = first
        .get("start")
        .parse::<u64>()
        .map_err(|e| unreadable("no-run", e))?;
    let cap = first
        .get("cap-secs")
        .parse::<u64>()
        .ok()
        .filter(|n| *n > 0)
        .ok_or_else(|| unreadable("no-run", "cap-secs"))?;
    let poll = first
        .get("poll-secs")
        .parse::<u64>()
        .ok()
        .filter(|n| *n > 0)
        .ok_or_else(|| unreadable("no-run", "poll-secs"))?;
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
            let cause = crate::ops::validate::memory_cap_cause(s)
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
        let unstarted = unstarted(&run)?;
        let state = if elapsed >= cap {
            Some("timeout")
        } else if unstarted && elapsed >= poll.max(10) {
            Some("lost")
        } else if unstarted {
            None
        } else if let Ok(pid) = fs::read_to_string(run_dir.join("pid")) {
            if pid
                .trim()
                .parse::<u32>()
                .is_ok_and(|pid| matches!(process::identity(pid), Reading::Gone))
                && matches!(runner_reading(&run), Reading::Gone)
            {
                Some("lost")
            } else {
                None
            }
        } else if elapsed >= poll.max(10) && matches!(runner_reading(&run), Reading::Gone) {
            Some("lost")
        } else {
            None
        };
        if let Some(state) = state {
            if fs::metadata(run_dir.join("exit")).is_ok_and(|m| m.len() > 0) {
                continue;
            }
            return Ok((
                format!(
                    "state={state} elapsed-secs={elapsed} cap-secs={cap} validate=FAILING run-dir={}{log}",
                    run_dir.display()
                ),
                1,
            ));
        }
        if clock.now() >= call {
            return Ok((
                format!(
                    "state=running elapsed-secs={elapsed} cap-secs={cap} run-dir={}",
                    run_dir.display()
                ),
                3,
            ));
        }
        clock.sleep(
            Duration::from_secs(poll.min(cap - elapsed))
                .min(call.saturating_duration_since(clock.now())),
        );
    }
}
