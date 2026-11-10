//! The event log the controller session follows: typed events rendered to
//! the `EVENT` line grammar the released watch printed, byte for byte, and
//! appended, one line each, to the log beside the fleet state. A line's
//! number is its position in the file, which is what a handoff names and
//! what `watch log --since` reads from.
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
    /// process with another start.
    Gone,
    /// The launcher named the live runner for replacement (`--replace`),
    /// and it released its claim.
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

/// Which reading of the overseer's own session an `overseer-*` line reports.
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
/// a count, a stamp; the grammar has no quoting. The variants are the lines
/// the released watch printed, whose shapes a follower parses, and this
/// runtime's own (`watch-taken-over`, `idle-unread`, `reconcile-refused`,
/// `notice-unmarked`, `directive-send-unsettled`, and `watch-step-failed`
/// for any duty). A line whose tail is free-form carries the tail as one
/// string field, and a line whose whole body its duty composes
/// (`usage-limit*`, `report-due`, `tracker-quota`) carries that body.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// The one periodic line.
    Heartbeat {
        loops: u32,
        interval: Duration,
        since: Option<String>,
    },
    /// This runtime's own: a claim taken over, naming the identity it read;
    /// `start` is `None` on a record that carries no start, rendered `none`.
    WatchTakenOver {
        pid: u32,
        start: Option<String>,
        reason: Takeover,
    },
    /// A duty's body failed `count` times in a row; the run goes on
    /// (`watch::Thread`).
    WatchStepFailed {
        step: Duty,
        count: u64,
    },
    /// This runtime's own: the reconcile duty could not complete or mark an
    /// open intent, `refusal` the refusal's key; printed when the key
    /// changes, as `main-workflow-absent` is.
    ReconcileRefused {
        intent: String,
        refusal: String,
    },
    /// This runtime's own: an owed notice was sent and the store refused
    /// its mark, `cause` the refusal's key.
    NoticeUnmarked {
        intent: String,
        cause: String,
    },
    /// This runtime's own: a session send recorded
    /// owed on the lane `item` that no kept receipt settles, `cause` the
    /// settle's word; printed when the cause is new or changed, as
    /// `reconcile-refused` is.
    DirectiveSendUnsettled {
        item: String,
        cause: String,
    },
    LaneClosed {
        item: String,
    },
    LaneCloseRefused {
        item: String,
    },
    Triage {
        id: String,
    },
    Handoff {
        item: String,
    },
    WindowGone {
        lane: String,
    },
    LaneExited {
        lane: String,
    },
    DirectiveRead {
        item: String,
        id: String,
    },
    /// `age` in seconds.
    DirectiveUnread {
        item: String,
        id: String,
        age: u64,
    },
    /// `age` in seconds.
    StartStalled {
        item: String,
        age: u64,
    },
    /// A lead or lane read idle with unread mail, which
    /// the wake duty delivers to; `lane` is the item key, or `overseer`.
    IdleUnread {
        lane: String,
    },
    // The wake duty's own lines.
    /// This runtime's own: the wake's line confirmed by
    /// a new user turn in the target's own bound session file.
    WakeDelivered {
        target: String,
    },
    /// This runtime's own: the wake's line typed and the bound passed with
    /// no such turn, `cause` the verb's word (`turn-pending`, `pane-gone`,
    /// `pane-unreadable`); nothing is typed again for that unread state.
    WakeUnconfirmed {
        target: String,
        cause: String,
    },
    /// This runtime's own: the target read idle with
    /// unread mail and no confirmable route for its harness; nothing typed.
    WakeLimit {
        target: String,
        harness: String,
        cause: String,
    },
    LaneReady {
        item: String,
    },
    /// `age` in seconds, printed with its unit; `reason` is
    /// `relaunch-pending` on a relaunch.
    LanePrepareStuck {
        item: String,
        age: u64,
        log: String,
        reason: Option<String>,
    },
    /// `exit` is a relaunch's exit status, on a relaunch.
    LanePrepareFailed {
        item: String,
        reason: String,
        exit: Option<i32>,
        log: String,
    },
    ParkedMerged {
        item: String,
        pr: String,
        repo: String,
    },
    ParkedClosed {
        item: String,
        pr: String,
        repo: String,
    },
    /// The hit line as the search composed it.
    Merged {
        line: String,
    },
    MainWorkflowAbsent {
        repo: String,
        workflow: String,
        cause: String,
    },
    MainPushFailing {
        repo: String,
        workflow: String,
        event: String,
        run: String,
        jobs: String,
        cause: String,
    },
    /// The workflow is fixed, `warnings` the JSON
    /// array text.
    MainPushBudget {
        repo: String,
        run: String,
        warnings: String,
    },
    /// `runs=2` is fixed.
    RefreshFailing {
        repo: String,
        last: String,
        since: String,
        report: String,
        cause: String,
    },
    /// `age` in seconds, `state` the cloud lane's `finished` or
    /// `out-of-credit` where its pull request or account read one.
    LaneStalled {
        item: String,
        age: u64,
        state: Option<String>,
    },
    // The hosted readings' lines.
    /// A stalled cloud lane the watch closed once its directive stood
    /// unanswered past the bound,
    /// `directive_age` the seconds since that directive was sent.
    CloudStallClosed {
        item: String,
        directive_age: u64,
    },
    OwnerAskResolved {
        re: String,
        by: String,
        id: String,
    },
    OwnerAskClosed {
        re: String,
        by: String,
    },
    OwnerNote {
        id: String,
    },
    /// The repository with its `overseer:` prefix
    /// dropped, and `re=` where the note answers something.
    PeerNote {
        repository: String,
        id: String,
        kind: String,
        re: Option<String>,
    },
    LaneQuestion {
        item: String,
        id: String,
    },
    LaneNotice {
        item: String,
        id: String,
    },
    OverseerMark {
        pane: String,
        kind: String,
        value: String,
        mark: String,
        succession: Succession,
    },
    /// `age` in seconds.
    OverseerContextStale {
        pane: String,
        age: u64,
    },
    OverseerContextUnmeasured {
        pane: String,
        gap: String,
    },
    /// This runtime's own: the watch's GitHub sign-in was refused and the
    /// credential ladder renewed none, `cause` the renewal's word.
    GitHubAuthFailed {
        cause: String,
    },
    /// `overseer-dead`, `overseer-walled` or
    /// `overseer-reserve`, with `cause=` only on a death the watch read the
    /// cause of (`memory-cap`), and `record=` only on a death judged with no
    /// recorded line (`none`, or `<generation>:<pane>`).
    OverseerSession {
        case: OverseerCase,
        pane: String,
        window: String,
        passes: u32,
        succession: Succession,
        source: String,
        cause: Option<&'static str>,
        record: Option<String>,
    },
    LaneRelaunched {
        item: String,
        lane: String,
        from: String,
    },
    /// `note` the Copilot session note where one
    /// stands.
    LaneAsking {
        lane: String,
        note: Option<String>,
    },
    ModelCapacity {
        lane: String,
    },
    /// `note` as for `lane-asking`, or
    /// `cause=<word>` where the lane's own Stop row named a stop reason
    /// that is not the harness's ordinary end.
    IdleAfterReturn {
        lane: String,
        note: Option<String>,
    },
    /// `fields` is the roster's own field text,
    /// `change` the comma-joined kinds.
    Account {
        fields: String,
        change: String,
        was_status: String,
        was_verdict: String,
    },
    /// `row` is `boxes=0`, or the due row.
    VerifyingDeadline {
        id: String,
        row: String,
    },
    /// A Verifying item whose checklist cannot be judged: an open
    /// branch-provable box or invalid post-merge metadata.
    VerifyingInvalid {
        id: String,
    },
    // The observation duty's lines.
    /// `usage-limit` or `usage-limit-passed`, then the body composed from
    /// its optional parts, the lane, the
    /// claimed account, `resets=` and `wall_kind=auth`, as one line.
    UsageLimit {
        passed: bool,
        line: String,
    },
    /// This runtime's own: a window of the fleet
    /// session that no lane record, controller record, open intent or
    /// receipt names, reported and never adopted or closed.
    StrayWindow {
        pane: String,
        window: String,
        server: u64,
        name: String,
    },
    /// This runtime's own: a lane whose pane, process or
    /// screen could not be read this pass, with the reader's cause; never
    /// `window-gone` or `lane-exited`.
    LaneUnreadable {
        lane: String,
        cause: String,
    },
    /// One line of a pane tail or a banner window under a lane or overseer
    /// line: the text itself, unindented; one variant per physical line.
    Tail(String),
    // The mail duty's lines.
    /// One line of a message's payload
    /// under its `lane-question`, `lane-notice`, `owner-note`,
    /// `owner-ask-resolved` or `peer-note` line (the text, line by line,
    /// then `options: a, b`), indented two spaces so only a watch record
    /// begins with `EVENT`. One variant per physical line, since the
    /// follow numbers lines.
    Payload {
        line: String,
    },
    // The tracker and GitHub read duty's lines.
    /// The tracker's quota refusal, the one limit event, its body composed
    /// from the receipt: `tracker-quota status=<future|elapsed|
    /// missing|invalid> reset=<ISO|unavailable> limit=<requests|complexity|
    /// endpoint|unknown>`.
    TrackerQuota {
        line: String,
    },
    // The local-lane readings' lines.
    /// A running or parked lane past the
    /// age bound, once per age interval; each count is a number or
    /// `unread`, `stage` the status file's `Step` line, `parked`, `unread`
    /// or `none`.
    LaneLong {
        item: String,
        age: u64,
        review_rounds: String,
        fix_receipts: String,
        validation_runs: String,
        restacks: String,
        repeated_class_rounds: String,
        stage: String,
    },
    // The GitHub duty's readings' lines.
    /// The reducer pass found a new attention key; `rc` the highest status
    /// any repository's reducer returned. The reducer lines and the pass's
    /// stderr follow as `Tail` lines.
    PrWatch {
        rc: i32,
    },
    /// One open alert, its optional fields in the line's fixed order,
    /// `report=repeat` on a pass that lists an alert already reported with
    /// no verdict recorded.
    SecurityAlert {
        repo: String,
        kind: String,
        number: u64,
        severity: Option<String>,
        /// `package` or `rule`.
        subject_key: String,
        subject: String,
        manifest: Option<String>,
        scope: Option<String>,
        advisory: Option<String>,
        validity: Option<String>,
        url: String,
        pr: Option<u64>,
        repeat: bool,
    },
    /// `reads` the comma-joined `<source>:<cause>` set, printed when the
    /// set changes.
    SecurityAlertsUnread {
        reads: String,
    },
    /// `key` is `<repo>#<number>`, `head` present on a pull request alone.
    OutsideContribution {
        key: String,
        kind: String,
        author: String,
        head: Option<String>,
    },
    // The report and heartbeat duties' lines.
    /// The report's due line, `report-due reason=<minutes|issues>
    /// since=<UTC> [landed=<N>]`.
    ReportDue {
        line: String,
    },
    /// A line of the heartbeat's body or of the report's under its `EVENT`
    /// line: the text unprefixed; one variant per physical line, since
    /// the follow numbers lines.
    Body {
        line: String,
    },
}

fn with_unit(secs: u64) -> String {
    format!("{secs}s")
}

impl Event {
    /// The line without its newline.
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
            Event::DirectiveSendUnsettled { item, cause } => {
                format!("EVENT directive-send-unsettled item={item} cause={cause}")
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
            // The wake duty's own lines.
            Event::WakeDelivered { target } => format!("EVENT wake-delivered {target}"),
            Event::WakeUnconfirmed { target, cause } => {
                format!("EVENT wake-unconfirmed {target} cause={cause}")
            }
            Event::WakeLimit {
                target,
                harness,
                cause,
            } => format!("EVENT wake-limit {target} harness={harness} cause={cause}"),
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
            Event::LaneStalled { item, age, state } => {
                let state = state
                    .as_deref()
                    .map(|s| format!(" state={s}"))
                    .unwrap_or_default();
                format!("EVENT lane-stalled {item} age={age}{state}")
            }
            // The hosted readings' render arm.
            Event::CloudStallClosed {
                item,
                directive_age,
            } => {
                format!("EVENT cloud-stall-closed {item} directive_age={directive_age}")
            }
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
            Event::GitHubAuthFailed { cause } => {
                format!("EVENT github-auth-failed cause={cause}")
            }
            Event::OverseerSession {
                case,
                pane,
                window,
                passes,
                succession,
                source,
                cause,
                record,
            } => {
                let cause = cause.map(|c| format!(" cause={c}")).unwrap_or_default();
                let record = record
                    .as_deref()
                    .map(|r| format!(" record={r}"))
                    .unwrap_or_default();
                format!(
                    "EVENT overseer-{} {pane} window={window} passes={passes} succession={} source={source}{cause}{record}",
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
            Event::VerifyingInvalid { id } => format!("EVENT verifying-invalid {id}"),
            // The observation duty's render arms.
            Event::UsageLimit { passed, line } => {
                let event = if *passed {
                    "usage-limit-passed"
                } else {
                    "usage-limit"
                };
                format!("EVENT {event} {line}")
            }
            Event::StrayWindow {
                pane,
                window,
                server,
                name,
            } => format!("EVENT stray-window {pane} window={window} server={server} name={name}"),
            Event::LaneUnreadable { lane, cause } => {
                format!("EVENT lane-unreadable {lane} cause={cause}")
            }
            Event::Tail(line) => line.clone(),
            // The mail duty's render arms.
            Event::Payload { line } => format!("  {line}"),
            // The tracker and GitHub read duty's render arms.
            Event::TrackerQuota { line } => format!("EVENT {line}"),
            // The local-lane readings' render arms.
            Event::LaneLong {
                item,
                age,
                review_rounds,
                fix_receipts,
                validation_runs,
                restacks,
                repeated_class_rounds,
                stage,
            } => format!(
                "EVENT lane-long {item} age={age} review_rounds={review_rounds} fix_receipts={fix_receipts} validation_runs={validation_runs} restacks={restacks} repeated_class_rounds={repeated_class_rounds} stage={stage}"
            ),
            // The GitHub duty's readings' render arms.
            Event::PrWatch { rc } => format!("EVENT pr-watch rc={rc}"),
            Event::SecurityAlert {
                repo,
                kind,
                number,
                severity,
                subject_key,
                subject,
                manifest,
                scope,
                advisory,
                validity,
                url,
                pr,
                repeat,
            } => {
                let mut line = format!("EVENT security-alert {repo} kind={kind} number={number}");
                if let Some(severity) = severity {
                    line.push_str(&format!(" severity={severity}"));
                }
                line.push_str(&format!(" {subject_key}={subject}"));
                for (name, value) in [
                    ("manifest", manifest),
                    ("scope", scope),
                    ("advisory", advisory),
                    ("validity", validity),
                ] {
                    if let Some(value) = value {
                        line.push_str(&format!(" {name}={value}"));
                    }
                }
                line.push_str(&format!(" url={url}"));
                if let Some(pr) = pr {
                    line.push_str(&format!(" pr={pr}"));
                }
                if *repeat {
                    line.push_str(" report=repeat");
                }
                line
            }
            Event::SecurityAlertsUnread { reads } => {
                format!("EVENT security-alerts-unread reads={reads}")
            }
            Event::OutsideContribution {
                key,
                kind,
                author,
                head,
            } => {
                let head = head
                    .as_deref()
                    .map(|h| format!(" head={h}"))
                    .unwrap_or_default();
                format!("EVENT outside-contribution {key} kind={kind} author={author}{head}")
            }
            // The report and heartbeat duties' render arms.
            Event::ReportDue { line } => format!("EVENT {line}"),
            Event::Body { line } => line.clone(),
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
    // The lines rotated out before the live file, which its numbering
    // continues from.
    base: u64,
}

fn record_error(path: &Path, op: &'static str, e: std::io::Error) -> WatchError {
    WatchError::Record {
        path: path.to_path_buf(),
        op,
        cause: e.to_string(),
    }
}

/// The number of lines the log holds, its rotated segments counted: the
/// number of its last line; none where no log stands yet.
pub fn line_count(path: &Path) -> Result<u64> {
    Ok(live_base(path)? + file_lines(path)?)
}

/// The lines from number `since` (1-based) on, the rotated segments read
/// through; none where no log stands.
pub fn read_since(path: &Path, since: u64) -> Result<Vec<Numbered>> {
    let mut out = Vec::new();
    let mut base = 0;
    for segment in segments(path)? {
        if segment.base + segment.lines >= since {
            read_numbered(&segment.path, segment.base, since, &mut out)?;
        }
        base = segment.base + segment.lines;
    }
    read_numbered(path, base, since, &mut out)?;
    Ok(out)
}

/// The lines of one file numbered from `base + 1`, those at or past
/// `since` appended to `out`; an absent file holds none.
fn read_numbered(path: &Path, base: u64, since: u64, out: &mut Vec<Numbered>) -> Result<()> {
    let file = match File::open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(record_error(path, "read", e).into()),
    };
    for (index, line) in BufReader::new(file).lines().enumerate() {
        let n = base + index as u64 + 1;
        let line = line.map_err(|e| record_error(path, "read", e))?;
        if n >= since {
            out.push(Numbered { n, line });
        }
    }
    Ok(())
}

/// The number of lines one file holds; none where it does not stand.
fn file_lines(path: &Path) -> Result<u64> {
    match File::open(path) {
        Ok(file) => Ok(BufReader::new(file).lines().count() as u64),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(0),
        Err(e) => Err(record_error(path, "read", e).into()),
    }
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
        let mut file = open_live(path)?;
        let terminate = |file: &mut File| -> std::io::Result<()> {
            if ends_unterminated(file)? {
                file.write_all(b"\n")?;
                file.sync_data()?;
            }
            Ok(())
        };
        terminate(&mut file).map_err(|e| record_error(path, "terminate", e))?;
        let base = live_base(path)?;
        let last = base + file_lines(path)?;
        Ok(EventLog {
            path: path.to_path_buf(),
            file,
            last,
            base,
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
        if self.last - self.base >= SEGMENT_LINES {
            self.rotate()?;
        }
        Ok(self.last)
    }

    /// Rotate the live file out as the segment `<log>.<base>` and open a
    /// fresh one whose first line is `last + 1`: the live log stays within
    /// [`SEGMENT_LINES`], and the numbering a handoff names continues
    /// across the segments, which `read_since` reads through. Under the
    /// runner's record lock, as every append is.
    #[allow(
        clippy::disallowed_methods,
        reason = "the event log's own rotation: the one rename of the live file onto its segment name, the runner's own record beside the fleet state"
    )]
    fn rotate(&mut self) -> Result<()> {
        let segment = segment_path(&self.path, self.base);
        std::fs::rename(&self.path, &segment).map_err(|e| record_error(&self.path, "rotate", e))?;
        self.file = open_live(&self.path)?;
        self.base = self.last;
        Ok(())
    }
}

/// Lines a live log holds before it is rotated out: small enough that the
/// follow and `watch log` read it whole, large enough that a quiet fleet
/// rotates seldom or never.
pub const SEGMENT_LINES: u64 = 10_000;

/// One rotated segment of the log, `<log>.<base>`: it holds the lines
/// `base + 1` to `base + lines`. The newest segment fixes the live log's
/// base, so the retention duty never removes it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Segment {
    pub path: PathBuf,
    pub base: u64,
    pub lines: u64,
}

fn segment_path(log: &Path, base: u64) -> PathBuf {
    let name = log
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    log.with_file_name(format!("{name}.{base}"))
}

/// The rotated segments beside `log`, oldest first: every sibling named
/// `<log>.<number>`; none where the directory does not stand.
pub fn segments(log: &Path) -> Result<Vec<Segment>> {
    let dir = log.parent().unwrap_or(Path::new("."));
    let prefix = format!(
        "{}.",
        log.file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default()
    );
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(record_error(dir, "read-dir", e).into()),
    };
    let mut out = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|e| record_error(dir, "read-dir", e))?;
        let name = entry.file_name().to_string_lossy().into_owned();
        let Some(suffix) = name.strip_prefix(&prefix) else {
            continue;
        };
        let Ok(base) = suffix.parse::<u64>() else {
            continue;
        };
        let path = entry.path();
        let lines = file_lines(&path)?;
        out.push(Segment { path, base, lines });
    }
    out.sort_by_key(|s| s.base);
    Ok(out)
}

/// The number of lines before the live log's first: the newest segment's
/// end, or none with no segment.
fn live_base(log: &Path) -> Result<u64> {
    Ok(segments(log)?.last().map_or(0, |s| s.base + s.lines))
}

/// The live log open for appending, created where none stands.
#[allow(
    clippy::disallowed_methods,
    reason = "the event log's one open for appending: the runner's own record beside the fleet state"
)]
fn open_live(path: &Path) -> Result<File> {
    std::fs::OpenOptions::new()
        .append(true)
        .read(true)
        .create(true)
        .open(path)
        .map_err(|e| record_error(path, "open", e).into())
}

#[cfg(test)]
#[allow(
    clippy::disallowed_methods,
    reason = "the row plants the log file it opens"
)]
mod tests {
    use super::*;

    /// A trailing partial line (an append cut short) counted as a line and
    /// joined by the next append would carry two events on one line and put
    /// the follow's numbering off by one. The open terminates it: the partial line keeps its number, and the next
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

    /// A rotation that renumbered would point the line a handoff names
    /// elsewhere in the successor's follow, as would a reopened log that
    /// counted the live file alone. The live file rotates
    /// out at `SEGMENT_LINES` as `<log>.<base>`; the next line's number,
    /// the count and a `read_since` across the boundary continue the
    /// numbering, a reopen resumes from it, and the segment is listed with
    /// its base and its lines.
    #[test]
    fn a_rotation_keeps_the_numbering_and_a_read_crosses_the_segment_boundary() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("oversee-watch.log");
        let mut log = EventLog::open(&path).unwrap();
        let first: Vec<Event> = (1..=SEGMENT_LINES)
            .map(|n| Event::Triage {
                id: format!("KEN-{n}"),
            })
            .collect();
        assert_eq!(log.append(&first).unwrap(), SEGMENT_LINES);
        let segment = dir.path().join("oversee-watch.log.0");
        assert_eq!(
            segments(&path).unwrap(),
            vec![Segment {
                path: segment.clone(),
                base: 0,
                lines: SEGMENT_LINES
            }]
        );
        assert_eq!(std::fs::read(&path).unwrap(), b"", "a fresh live file");
        let n = log
            .append(&[Event::Handoff {
                item: "KEN-A".into(),
            }])
            .unwrap();
        assert_eq!(n, SEGMENT_LINES + 1);
        assert_eq!(line_count(&path).unwrap(), SEGMENT_LINES + 1);
        assert_eq!(
            read_since(&path, SEGMENT_LINES - 1).unwrap(),
            vec![
                Numbered {
                    n: SEGMENT_LINES - 1,
                    line: format!("EVENT triage KEN-{}", SEGMENT_LINES - 1)
                },
                Numbered {
                    n: SEGMENT_LINES,
                    line: format!("EVENT triage KEN-{SEGMENT_LINES}")
                },
                Numbered {
                    n: SEGMENT_LINES + 1,
                    line: "EVENT handoff KEN-A".into()
                },
            ]
        );
        drop(log);
        let mut again = EventLog::open(&path).unwrap();
        assert_eq!(
            again.last(),
            SEGMENT_LINES + 1,
            "a reopen resumes the numbering"
        );
        assert_eq!(
            again
                .append(&[Event::Handoff {
                    item: "KEN-B".into()
                }])
                .unwrap(),
            SEGMENT_LINES + 2
        );
        assert_eq!(
            read_since(&path, SEGMENT_LINES + 2).unwrap(),
            vec![Numbered {
                n: SEGMENT_LINES + 2,
                line: "EVENT handoff KEN-B".into()
            }]
        );
        // The segment's bytes are the lines it took, untouched.
        assert_eq!(
            std::fs::read_to_string(&segment).unwrap().lines().count() as u64,
            SEGMENT_LINES
        );
    }
}
