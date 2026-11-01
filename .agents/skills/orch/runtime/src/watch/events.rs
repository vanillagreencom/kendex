//! The event log the controller session follows: typed events rendered to
//! the legacy `EVENT` line grammar byte for byte (decision 121, Q13) and
//! appended, one line each, to the log beside the fleet state. A line's
//! number is its position in the file, which is what a handoff names and
//! what `watch log --since` reads from (step5-map F8).
//!
//! The log is appended and synced before the baseline row the event moves
//! is written (`watch::commit`), so a crash between the two leaves the line
//! on disk and the row where it was: the duty finds the same news on its
//! next run and prints the line again, and no event is ever lost.

use std::fs::File;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Serialize;

use crate::error::{Result, WatchError};
use crate::schedule::Duty;
use crate::settings::Succession;

/// Why a runner took a standing claim over.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Takeover {
    /// The claim's identity read gone: a dead pid, or its pid reused by a
    /// process with another start (decision 99).
    Gone,
    /// The launcher named the live runner for replacement (`--replace`,
    /// the legacy `OVERSEE_WATCH_REPLACE`), and it released its claim.
    Replace,
}

impl Takeover {
    fn word(self) -> &'static str {
        match self {
            Takeover::Gone => "gone",
            Takeover::Replace => "replace",
        }
    }
}

/// Which reading of the overseer's own session an `overseer-*` line reports
/// (`oversee-watch:4452`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OverseerCase {
    Dead,
    Walled,
    Reserve,
}

impl OverseerCase {
    fn word(self) -> &'static str {
        match self {
            OverseerCase::Dead => "dead",
            OverseerCase::Walled => "walled",
            OverseerCase::Reserve => "reserve",
        }
    }
}

/// One line of the log. Every field is one word: an item key, a lane name,
/// a count, a stamp; the grammar has no quoting, as the legacy's had none.
/// The variants are the lines whose shape the legacy watch fixed with one
/// `echo` or `printf`, each cited to that site, and this runtime's own
/// (`watch-taken-over`, `idle-unread`, `reconcile-refused`,
/// `notice-unmarked`, and `watch-step-failed` for any duty). A shape whose
/// legacy tail is free-form carries the tail as one string field. The lines
/// whose whole body the legacy composed elsewhere (`usage-limit*`,
/// `report-due`, `tracker-quota`) are their duties' to add here.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// `oversee-watch:5715`: the one periodic line (decision 128 (5)).
    Heartbeat {
        loops: u32,
        interval: Duration,
        since: Option<String>,
    },
    /// This runtime's own: a claim taken over, naming the identity it read;
    /// `start` is `None` on a legacy record, which carries no start.
    WatchTakenOver {
        pid: u32,
        start: Option<String>,
        reason: Takeover,
    },
    /// `oversee-watch:2002`, generalized to every duty: a duty's body
    /// failed `count` times in a row; the run goes on (`watch::Thread`).
    WatchStepFailed { step: Duty, count: u64 },
    /// This runtime's own: the reconcile duty could not complete or mark an
    /// open intent, `refusal` the refusal's key; printed when the key
    /// changes, as the legacy printed `main-workflow-absent`.
    ReconcileRefused { intent: String, refusal: String },
    /// This runtime's own: an owed notice was sent and the store refused
    /// its mark (decision 124i (36)), `cause` the refusal's key.
    NoticeUnmarked { intent: String, cause: String },
    /// `oversee-watch:1443`.
    LaneClosed { item: String },
    /// `oversee-watch:1459`.
    LaneCloseRefused { item: String },
    /// `oversee-watch:2066`.
    Triage { id: String },
    /// `oversee-watch:2139`.
    Handoff { item: String },
    /// `oversee-watch:4813`.
    WindowGone { lane: String },
    /// `oversee-watch:4845`.
    LaneExited { lane: String },
    /// `oversee-watch:3236`.
    DirectiveRead { item: String, id: String },
    /// `oversee-watch:3240`, `age` in seconds.
    DirectiveUnread { item: String, id: String, age: u64 },
    /// `oversee-watch:2747`, `age` in seconds.
    StartStalled { item: String, age: u64 },
    /// Decision 118 (2): a lane read idle with unread mail, which the wake
    /// duty delivers to.
    IdleUnread { lane: String },
    /// `oversee-watch:2162`.
    LaneReady { item: String },
    /// `oversee-watch:2161` (`age` in seconds, printed with its unit) and
    /// `:4686`, which adds `reason=relaunch-pending`.
    LanePrepareStuck {
        item: String,
        age: u64,
        log: String,
        reason: Option<String>,
    },
    /// `oversee-watch:2163` and `:4678`, which adds the relaunch's `exit=`.
    LanePrepareFailed {
        item: String,
        reason: String,
        exit: Option<i32>,
        log: String,
    },
    /// `oversee-watch:1963`.
    ParkedMerged {
        item: String,
        pr: String,
        repo: String,
    },
    /// `oversee-watch:1884`.
    ParkedClosed {
        item: String,
        pr: String,
        repo: String,
    },
    /// `oversee-watch:1928`: the hit line as the search composed it.
    Merged { line: String },
    /// `oversee-watch:2228`.
    MainWorkflowAbsent {
        repo: String,
        workflow: String,
        cause: String,
    },
    /// `oversee-watch:2381`.
    MainPushFailing {
        repo: String,
        workflow: String,
        event: String,
        run: String,
        jobs: String,
        cause: String,
    },
    /// `oversee-watch:2487`: the workflow is fixed, `warnings` the JSON
    /// array text.
    MainPushBudget {
        repo: String,
        run: String,
        warnings: String,
    },
    /// `oversee-watch:2633`: `runs=2` is fixed.
    RefreshFailing {
        repo: String,
        last: String,
        since: String,
        report: String,
        cause: String,
    },
    /// `oversee-watch:2735`, `age` in seconds.
    LaneStalled { item: String, age: u64 },
    /// `oversee-watch:3178`.
    OwnerAskResolved { re: String, by: String, id: String },
    /// `oversee-watch:3179`.
    OwnerAskClosed { re: String, by: String },
    /// `oversee-watch:3180`.
    OwnerNote { id: String },
    /// `oversee-watch:3181`: the repository with its `overseer:` prefix
    /// dropped, and `re=` where the note answers something.
    PeerNote {
        repository: String,
        id: String,
        kind: String,
        re: Option<String>,
    },
    /// `oversee-watch:3186`.
    LaneQuestion { item: String, id: String },
    /// `oversee-watch:3189`.
    LaneNotice { item: String, id: String },
    /// `oversee-watch:4061`.
    OverseerMark {
        pane: String,
        kind: String,
        value: String,
        mark: String,
        succession: Succession,
    },
    /// `oversee-watch:4159`, `age` in seconds.
    OverseerContextStale { pane: String, age: u64 },
    /// `oversee-watch:4175`.
    OverseerContextUnmeasured { pane: String, gap: String },
    /// `oversee-watch:4576`: `overseer-dead`, `overseer-walled` or
    /// `overseer-reserve`, with `record=` only on a death judged with no
    /// recorded line (`none`, or `<generation>:<pane>`).
    OverseerSession {
        case: OverseerCase,
        pane: String,
        window: String,
        passes: u32,
        succession: Succession,
        source: String,
        record: Option<String>,
    },
    /// `oversee-watch:4751`.
    LaneRelaunched {
        item: String,
        lane: String,
        from: String,
    },
    /// `oversee-watch:4998`, `note` the Copilot session note where one
    /// stands.
    LaneAsking { lane: String, note: Option<String> },
    /// `oversee-watch:5067`.
    ModelCapacity { lane: String },
    /// `oversee-watch:5092`, `note` as for `lane-asking`.
    IdleAfterReturn { lane: String, note: Option<String> },
    /// `oversee-watch:5221`: `fields` is the roster's own field text,
    /// `change` the comma-joined kinds.
    Account {
        fields: String,
        change: String,
        was_status: String,
        was_verdict: String,
    },
    /// `oversee-watch:5610` (`row` is `boxes=0`) and `:5621` (the due row).
    VerifyingDeadline { id: String, row: String },
}

fn with_unit(secs: u64) -> String {
    format!("{secs}s")
}

impl Event {
    /// The line as the legacy printed it, without its newline.
    pub fn render(&self) -> String {
        match self {
            Event::Heartbeat {
                loops,
                interval,
                since,
            } => format!(
                "EVENT heartbeat loops={loops} interval={} since={}",
                with_unit(interval.as_secs()),
                since.as_deref().unwrap_or("none")
            ),
            Event::WatchTakenOver { pid, start, reason } => {
                format!(
                    "EVENT watch-taken-over pid={pid} start={} reason={}",
                    start.as_deref().unwrap_or("none"),
                    reason.word()
                )
            }
            Event::WatchStepFailed { step, count } => {
                format!("EVENT watch-step-failed step={} count={count}", step.word())
            }
            Event::ReconcileRefused { intent, refusal } => {
                format!("EVENT reconcile-refused intent={intent} refusal={refusal}")
            }
            Event::NoticeUnmarked { intent, cause } => {
                format!("EVENT notice-unmarked intent={intent} cause={cause}")
            }
            Event::LaneClosed { item } => format!("EVENT lane-closed {item}"),
            Event::LaneCloseRefused { item } => format!("EVENT lane-close-refused {item}"),
            Event::Triage { id } => format!("EVENT triage {id}"),
            Event::Handoff { item } => format!("EVENT handoff {item}"),
            Event::WindowGone { lane } => format!("EVENT window-gone {lane}"),
            Event::LaneExited { lane } => format!("EVENT lane-exited {lane}"),
            Event::DirectiveRead { item, id } => format!("EVENT directive-read {item} {id}"),
            Event::DirectiveUnread { item, id, age } => {
                format!("EVENT directive-unread {item} {id} age={age}")
            }
            Event::StartStalled { item, age } => format!("EVENT start-stalled {item} age={age}"),
            Event::IdleUnread { lane } => format!("EVENT idle-unread {lane}"),
            Event::LaneReady { item } => format!("EVENT lane-ready {item}"),
            Event::LanePrepareStuck {
                item,
                age,
                log,
                reason,
            } => {
                let reason = reason
                    .as_deref()
                    .map(|r| format!(" reason={r}"))
                    .unwrap_or_default();
                format!(
                    "EVENT lane-prepare-stuck {item} age={} log={log}{reason}",
                    with_unit(*age)
                )
            }
            Event::LanePrepareFailed {
                item,
                reason,
                exit,
                log,
            } => {
                let exit = exit.map(|rc| format!(" exit={rc}")).unwrap_or_default();
                format!("EVENT lane-prepare-failed {item} reason={reason}{exit} log={log}")
            }
            Event::ParkedMerged { item, pr, repo } => {
                format!("EVENT parked-merged {item} pr={pr} repo={repo}")
            }
            Event::ParkedClosed { item, pr, repo } => {
                format!("EVENT parked-closed {item} pr={pr} repo={repo}")
            }
            Event::Merged { line } => format!("EVENT merged {line}"),
            Event::MainWorkflowAbsent {
                repo,
                workflow,
                cause,
            } => format!("EVENT main-workflow-absent {repo} workflow={workflow} cause={cause}"),
            Event::MainPushFailing {
                repo,
                workflow,
                event,
                run,
                jobs,
                cause,
            } => format!(
                "EVENT main-push-failing {repo} workflow={workflow} event={event} run={run} jobs={jobs} cause={cause}"
            ),
            Event::MainPushBudget {
                repo,
                run,
                warnings,
            } => format!(
                "EVENT main-push-budget {repo} workflow=skill-tests.yml run={run} warnings={warnings}"
            ),
            Event::RefreshFailing {
                repo,
                last,
                since,
                report,
                cause,
            } => format!(
                "EVENT refresh-failing {repo} runs=2 last={last} since={since} report={report} cause={cause}"
            ),
            Event::LaneStalled { item, age } => format!("EVENT lane-stalled {item} age={age}"),
            Event::OwnerAskResolved { re, by, id } => {
                format!("EVENT owner-ask-resolved {re} by={by} id={id}")
            }
            Event::OwnerAskClosed { re, by } => format!("EVENT owner-ask-closed {re} by={by}"),
            Event::OwnerNote { id } => format!("EVENT owner-note {id}"),
            Event::PeerNote {
                repository,
                id,
                kind,
                re,
            } => {
                let re = re
                    .as_deref()
                    .map(|r| format!(" re={r}"))
                    .unwrap_or_default();
                format!("EVENT peer-note {repository} {id} kind={kind}{re}")
            }
            Event::LaneQuestion { item, id } => format!("EVENT lane-question {item} {id}"),
            Event::LaneNotice { item, id } => format!("EVENT lane-notice {item} {id}"),
            Event::OverseerMark {
                pane,
                kind,
                value,
                mark,
                succession,
            } => format!(
                "EVENT overseer-mark {pane} kind={kind} value={value} mark={mark} succession={}",
                succession.word()
            ),
            Event::OverseerContextStale { pane, age } => {
                format!("EVENT overseer-context-stale {pane} age={age}")
            }
            Event::OverseerContextUnmeasured { pane, gap } => {
                format!("EVENT overseer-context-unmeasured {pane} gap={gap}")
            }
            Event::OverseerSession {
                case,
                pane,
                window,
                passes,
                succession,
                source,
                record,
            } => {
                let record = record
                    .as_deref()
                    .map(|r| format!(" record={r}"))
                    .unwrap_or_default();
                format!(
                    "EVENT overseer-{} {pane} window={window} passes={passes} succession={} source={source}{record}",
                    case.word(),
                    succession.word()
                )
            }
            Event::LaneRelaunched { item, lane, from } => {
                format!("EVENT lane-relaunched {item} lane={lane} from={from}")
            }
            Event::LaneAsking { lane, note } => {
                let note = note.as_deref().map(|n| format!(" {n}")).unwrap_or_default();
                format!("EVENT lane-asking {lane}{note}")
            }
            Event::ModelCapacity { lane } => format!("EVENT model-capacity {lane}"),
            Event::IdleAfterReturn { lane, note } => {
                let note = note.as_deref().map(|n| format!(" {n}")).unwrap_or_default();
                format!("EVENT idle-after-return {lane}{note}")
            }
            Event::Account {
                fields,
                change,
                was_status,
                was_verdict,
            } => format!("EVENT account {fields} change={change} was={was_status}/{was_verdict}"),
            Event::VerifyingDeadline { id, row } => format!("EVENT verifying-deadline {id} {row}"),
        }
    }
}

/// One numbered line of the log, as `watch log` prints it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Numbered {
    pub n: u64,
    pub line: String,
}

/// The log open for appending, with the number of the last line it holds.
pub struct EventLog {
    path: PathBuf,
    file: File,
    last: u64,
}

fn record_error(path: &Path, op: &'static str, e: std::io::Error) -> WatchError {
    WatchError::Record {
        path: path.to_path_buf(),
        op,
        cause: e.to_string(),
    }
}

/// The number of lines `path` holds; none where no log stands yet.
pub fn line_count(path: &Path) -> Result<u64> {
    match File::open(path) {
        Ok(file) => Ok(BufReader::new(file).lines().count() as u64),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(0),
        Err(e) => Err(record_error(path, "read", e).into()),
    }
}

/// The lines from number `since` (1-based) on; none where no log stands.
pub fn read_since(path: &Path, since: u64) -> Result<Vec<Numbered>> {
    let file = match File::open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(record_error(path, "read", e).into()),
    };
    let mut out = Vec::new();
    for (index, line) in BufReader::new(file).lines().enumerate() {
        let n = index as u64 + 1;
        let line = line.map_err(|e| record_error(path, "read", e))?;
        if n >= since {
            out.push(Numbered { n, line });
        }
    }
    Ok(out)
}

/// Whether the open log ends in a partial line: a last byte that is no
/// newline, which an append cut short (ENOSPC, a kill mid-write) leaves.
fn ends_unterminated(file: &mut File) -> std::io::Result<bool> {
    let len = file.metadata()?.len();
    if len == 0 {
        return Ok(false);
    }
    file.seek(SeekFrom::Start(len - 1))?;
    let mut last = [0u8; 1];
    file.read_exact(&mut last)?;
    Ok(last[0] != b'\n')
}

impl EventLog {
    /// Open the log for appending, creating it where none stands, terminate
    /// a trailing partial line so the next append starts a line of its
    /// own, and count the lines it holds so the next line's number follows
    /// them.
    #[allow(
        clippy::disallowed_methods,
        reason = "the event log's one open for appending: the runner's own record beside the fleet state"
    )]
    pub fn open(path: &Path) -> Result<EventLog> {
        let mut file = std::fs::OpenOptions::new()
            .append(true)
            .read(true)
            .create(true)
            .open(path)
            .map_err(|e| record_error(path, "open", e))?;
        let terminate = |file: &mut File| -> std::io::Result<()> {
            if ends_unterminated(file)? {
                file.write_all(b"\n")?;
                file.sync_data()?;
            }
            Ok(())
        };
        terminate(&mut file).map_err(|e| record_error(path, "terminate", e))?;
        let last = line_count(path)?;
        Ok(EventLog {
            path: path.to_path_buf(),
            file,
            last,
        })
    }

    /// The number of the last line written.
    pub fn last(&self) -> u64 {
        self.last
    }

    /// Append one line per event and sync the file, so every line is on disk
    /// when this returns; the number of the last line written.
    pub fn append(&mut self, events: &[Event]) -> Result<u64> {
        if events.is_empty() {
            return Ok(self.last);
        }
        let mut text = String::new();
        for event in events {
            text.push_str(&event.render());
            text.push('\n');
        }
        self.file
            .write_all(text.as_bytes())
            .and_then(|()| self.file.sync_data())
            .map_err(|e| record_error(&self.path, "append", e))?;
        self.last += events.len() as u64;
        Ok(self.last)
    }
}

#[cfg(test)]
#[allow(
    clippy::disallowed_methods,
    reason = "the row plants the log file it opens"
)]
mod tests {
    use super::*;

    /// Defect: a trailing partial line (an append cut short) counted as a
    /// line and joined by the next append, so one line of the log carries
    /// two events and the numbering the follow uses is off by one. The open
    /// terminates it: the partial line keeps its number, and the next
    /// append is the line after it.
    #[test]
    fn a_trailing_partial_line_is_terminated_at_open_and_the_next_line_follows_it() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("oversee-watch.log");
        std::fs::write(&path, "EVENT handoff KEN-1\nEVENT tri").unwrap();
        let mut log = EventLog::open(&path).unwrap();
        assert_eq!(log.last(), 2);
        let n = log.append(&[Event::Triage { id: "KEN-2".into() }]).unwrap();
        assert_eq!(n, 3);
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "EVENT handoff KEN-1\nEVENT tri\nEVENT triage KEN-2\n"
        );
        assert_eq!(
            read_since(&path, 3).unwrap(),
            vec![Numbered {
                n: 3,
                line: "EVENT triage KEN-2".into()
            }]
        );
        // A terminated log and an empty one are left as they are.
        let log = EventLog::open(&path).unwrap();
        assert_eq!(log.last(), 3);
        let empty = dir.path().join("empty.log");
        let log = EventLog::open(&empty).unwrap();
        assert_eq!(log.last(), 0);
        assert_eq!(std::fs::read(&empty).unwrap(), b"");
    }
}
