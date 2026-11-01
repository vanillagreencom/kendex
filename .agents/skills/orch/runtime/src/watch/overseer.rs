//! The overseer observation duty (step5-map § A3; decision 121 Q9, Q10):
//! one verdict of the controller's session per pass, in the legacy reading
//! order (the login wall, the exit record, the session rows, the pane as
//! the fallback), each reading three-valued, stored in the one [`Slot`] the
//! lanes' observation reads in the same pass, so the controller is judged
//! once per pass (decision 153 (4): the mail duty takes no gate from it).
//!
//! A death is counted on `ORCH_OVERSEER_DEAD_PASSES` consecutive passes
//! that read the session gone, never on an unreadable read; a wall the rows
//! or the account state needs one pass, a wall the screen alone shows takes
//! the same count and the account judgement's confirmation. The case is
//! said on the log before anything moves, then the one existing request,
//! `request-transfer` with its cause and the spent account, asks for the
//! succession; decision 77's terminal proof runs inside that transfer. The
//! marks and the account walk stay the legacy's, called through the one
//! runner and counted (decision 75).

// Every reading is matched variant by variant (decision 105).
#![deny(clippy::wildcard_enum_match_arm)]

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use agent_runtime::harness::Harness;
use agent_runtime::host;
use agent_runtime::observe::{self, ProcessReading, State, WallKind};
use agent_runtime::process::Identity;
use agent_runtime::reading::Reading;
use agent_runtime::rows::{self, SessionVerdict};
use serde::Serialize;
use serde_json::Value;

use super::baseline::{Baseline, Change};
use super::events::{Event, OverseerCase};
use super::lanes::{Readers as LaneReaders, Relaunch, WallRoute, banner_payload};
use super::{Body, Produced, Runner, Tick};
use crate::ops::{OverseerExpected, RequestTransfer};
use crate::settings::{Settings, Succession, WatchSettings};
use crate::state::{FleetState, Pending, TransferCause};

/// The bound on the legacy judge and the account walk, each one process:
/// the judge waits on a credentials lock and a usage endpoint per account.
const LEGACY_BOUND: Duration = Duration::from_secs(120);

/// Where the verdict was read, the `source=` word of the line.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Source {
    Auth,
    Record,
    Rows,
    Context,
    Process,
    Pane,
    Account,
}

impl Source {
    pub fn word(self) -> &'static str {
        match self {
            Source::Auth => "auth",
            Source::Record => "record",
            Source::Rows => "rows",
            Source::Context => "context",
            Source::Process => "process",
            Source::Pane => "pane",
            Source::Account => "account",
        }
    }
}

/// The one verdict of the controller's session a pass gives.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "verdict", rename_all = "kebab-case")]
pub enum Verdict {
    /// The harness runs and may be working.
    Live,
    /// The harness is gone from its pane.
    Exited { source: Source },
    /// The harness runs and its account refuses every turn.
    Walled {
        source: Source,
        kind: WallKind,
        /// The wall's own words: the row's message, the screen's banner, or
        /// the account line.
        text: String,
    },
    /// A controller operation the runtime holds open is replacing the
    /// session; nothing is judged beside it.
    Transferring { intent: String },
    /// No controller record names a pane to read.
    Unwatched { cause: &'static str },
    /// The pane, its process or its screen could not be read; nothing is
    /// counted on it.
    Unreadable { cause: String },
}

/// The verdict with the pass that gave it and the pane it was read from.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Judged {
    pub verdict: Verdict,
    /// `<server pid> <pane id>`, the key the rows are kept under.
    pub pane_key: Option<String>,
    /// The epoch second of the pass.
    pub at: u64,
}

/// The slot the observation duty stores each pass's verdict in, read by
/// the wall relaunch's gate; the mail duty reads no gate from it (decision
/// 153 (4)).
#[derive(Debug, Clone, Default)]
pub struct Slot(Arc<Mutex<Option<Judged>>>);

impl Slot {
    pub fn new() -> Slot {
        Slot::default()
    }

    pub fn store(&self, judged: Judged) {
        *self.0.lock().unwrap_or_else(|p| p.into_inner()) = Some(judged);
    }

    /// The last verdict stored, or `None` before the first observation.
    pub fn read(&self) -> Option<Judged> {
        self.0.lock().unwrap_or_else(|p| p.into_inner()).clone()
    }
}

/// What the legacy judge answered (`oversee-succeed --check-marks`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Marks {
    pub key: MarkKey,
    pub kind: String,
    pub value: String,
    pub mark: String,
    pub succession: Succession,
    pub account: String,
    pub resets: String,
    pub status: String,
    pub reserve_only: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarkKey {
    Reached,
    Unmeasured,
    Below,
}

impl Marks {
    /// The first line the judge printed, parsed as the legacy parsed it; a
    /// line the watch has no name for settles nothing.
    pub fn parse(line: &str) -> Option<Marks> {
        let key = if line.starts_with("oversee-succeed: mark-reached ") {
            MarkKey::Reached
        } else if line.starts_with("oversee-succeed: mark-unmeasured ") {
            MarkKey::Unmeasured
        } else if line.starts_with("oversee-succeed: account-below-mark ") {
            MarkKey::Below
        } else {
            return None;
        };
        let mut marks = Marks {
            key,
            kind: String::new(),
            value: String::new(),
            mark: String::new(),
            succession: Succession::On,
            account: String::new(),
            resets: String::new(),
            status: String::new(),
            reserve_only: false,
        };
        for field in line.split_whitespace() {
            if let Some(v) = field.strip_prefix("kind=") {
                marks.kind = v.to_owned();
            } else if let Some(v) = field.strip_prefix("value=") {
                marks.value = v.to_owned();
            } else if let Some(v) = field.strip_prefix("mark=") {
                marks.mark = v.to_owned();
            } else if let Some(v) = field.strip_prefix("succession=") {
                marks.succession = if v == "off" {
                    Succession::Off
                } else {
                    Succession::On
                };
            } else if let Some(v) = field.strip_prefix("account=") {
                marks.account = v.to_owned();
            } else if let Some(v) = field.strip_prefix("resets=") {
                marks.resets = v.to_owned();
            } else if let Some(v) = field.strip_prefix("status=") {
                marks.status = v.to_owned();
            } else if field == "reserve_only=true" {
                marks.reserve_only = true;
            }
        }
        Some(marks)
    }

    /// A non-reserve headroom mark reached: the account judgement that
    /// confirms a wall read off the screen.
    fn confirms_wall(&self) -> bool {
        self.key == MarkKey::Reached && self.kind == "headroom" && !self.reserve_only
    }
}

/// What the account walk picked for a walled succession.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Pick {
    Lane(String),
    None,
    Unjudged { cause: String },
}

/// The legacy calls the duty makes through the one runner (decision 121
/// Q9), injected so a row plants the answers; production takes
/// [`Legacy::scripts`].
pub struct Legacy<'a> {
    /// The directory the scripts run from.
    pub scripts: PathBuf,
    /// `oversee-succeed --check-marks [--harness H]`'s first line.
    pub marks: MarksRead<'a>,
    /// `lanes pick --harness H --exclude-lane SPENT --for-overseer --json`.
    pub pick: PickRead<'a>,
    /// The wall route's pick for a lane's model (`oversee-watch:4710`):
    /// `lanes pick --harness H --native-model M --exclude-lane SPENT --json`.
    pub wall_pick: WallPickRead<'a>,
    /// The wall relaunch, the record's own `open-terminal --relaunch` line
    /// started detached through the job-unit launcher at the path given.
    pub relaunch: RelaunchStart<'a>,
}

/// The judge's answer, read from the scripts directory for the harness.
pub type MarksRead<'a> = &'a dyn Fn(&Path, Option<Harness>) -> Result<Marks, String>;
/// The walk's pick for a harness, the spent account excluded.
pub type PickRead<'a> = &'a dyn Fn(&Path, Harness, &str) -> Pick;
/// The walk's pick for a harness and model, the spent account excluded.
pub type WallPickRead<'a> = &'a dyn Fn(&Path, Harness, &str, &str) -> Pick;
/// The relaunch started through the job-unit launcher; `Err` its refusal.
pub type RelaunchStart<'a> = &'a dyn Fn(&Path, &Relaunch) -> Result<(), String>;

/// The job-unit name and record of a wall relaunch, beside its log.
fn relaunch_record(r: &Relaunch) -> (String, PathBuf) {
    (
        format!("wall-relaunch-{}", r.item),
        r.log.with_extension("unit"),
    )
}

/// The shell line the legacy ran the relaunch under (`oversee-watch:4748`):
/// the launcher in the recovered checkout with the recovered session, its
/// output appended to the log, its exit status written beside the marker.
const RELAUNCH_WRAPPER: &str = "log=\"$1\"; exit_file=\"$2\"; launch_cwd=\"$3\"; export ORCH_TMUX_SESSION=\"$4\"; shift 4; exec >>\"$log\" 2>&1; rc=0; (cd -- \"$launch_cwd\" && \"$@\") || rc=$?; printf \"%s\\n\" \"$rc\" > \"$exit_file\"";

impl Legacy<'static> {
    /// The scripts under the project's orch install, run through the
    /// runner and counted under the duty's tag.
    #[allow(
        clippy::disallowed_methods,
        reason = "the overseer duty's two legacy reads through the one runner: the account judgement and the account walk stay legacy in step 5 (decision 75, 121 Q9)"
    )]
    pub fn scripts(project: &Path) -> Legacy<'static> {
        fn marks(dir: &Path, harness: Option<Harness>) -> Result<Marks, String> {
            let mut args = vec!["--check-marks"];
            if let Some(h) = harness {
                args.push("--harness");
                args.push(h.name());
            }
            let out = host::run_tagged(
                "overseer-marks",
                "oversee-succeed",
                &dir.join("oversee-succeed"),
                "check-marks",
                &args,
                LEGACY_BOUND,
            )
            .map_err(|e| e.to_string())?;
            if !out.status.success() {
                return Err(format!(
                    "oversee-succeed --check-marks: {}",
                    host::stderr_text(&out)
                ));
            }
            let text = host::stdout_text(&out);
            let first = text.lines().next().unwrap_or("");
            Marks::parse(first).ok_or_else(|| format!("mark line unnamed: {first}"))
        }
        fn pick(dir: &Path, harness: Harness, spent: &str) -> Pick {
            let out = host::run_tagged(
                "overseer-pick",
                "lanes",
                &dir.join("lanes"),
                "pick",
                &[
                    "pick",
                    "--harness",
                    harness.name(),
                    "--exclude-lane",
                    spent,
                    "--for-overseer",
                    "--json",
                ],
                LEGACY_BOUND,
            );
            picked(out)
        }
        fn wall_pick(dir: &Path, harness: Harness, model: &str, spent: &str) -> Pick {
            let out = host::run_tagged(
                "wall-pick",
                "lanes",
                &dir.join("lanes"),
                "pick",
                &[
                    "pick",
                    "--harness",
                    harness.name(),
                    "--native-model",
                    model,
                    "--exclude-lane",
                    spent,
                    "--json",
                ],
                LEGACY_BOUND,
            );
            picked(out)
        }
        fn relaunch(job_unit: &Path, r: &Relaunch) -> Result<(), String> {
            let (name, record) = relaunch_record(r);
            let record = record.display().to_string();
            let log = r.log.display().to_string();
            let exit = format!("{}.exit", r.marker.display());
            let cwd = r.cwd.display().to_string();
            let mut args = vec![
                "launch",
                &name,
                &record,
                "--",
                "bash",
                "-c",
                RELAUNCH_WRAPPER,
                "wall-relaunch",
                &log,
                &exit,
                &cwd,
                &r.session,
            ];
            args.extend(r.args.iter().map(String::as_str));
            let out = host::run_tagged(
                "wall-relaunch",
                "job-unit",
                job_unit,
                "launch",
                &args,
                LEGACY_BOUND,
            )
            .map_err(|e| e.to_string())?;
            if out.status.success() {
                Ok(())
            } else {
                Err(host::stderr_text(&out))
            }
        }
        Legacy {
            scripts: project.join(".agents/skills/orch/scripts"),
            marks: &marks,
            pick: &pick,
            wall_pick: &wall_pick,
            relaunch: &relaunch,
        }
    }
}

/// The walk's answer as the legacy read it: the `config_dir` of a lane at
/// exit 0, none at exit 3, else unjudged with the cause.
fn picked(out: agent_runtime::Result<std::process::Output>) -> Pick {
    let out = match out {
        Ok(out) => out,
        Err(e) => {
            return Pick::Unjudged {
                cause: e.to_string(),
            };
        }
    };
    match out.status.code() {
        Some(0) => serde_json::from_str::<Value>(&host::stdout_text(&out))
            .ok()
            .and_then(|v| v.get("config_dir")?.as_str().map(str::to_owned))
            .map_or(
                Pick::Unjudged {
                    cause: "pick-unparsed".to_owned(),
                },
                Pick::Lane,
            ),
        Some(3) => Pick::None,
        Some(code) => Pick::Unjudged {
            cause: format!("exit={code}"),
        },
        None => Pick::Unjudged {
            cause: "signalled".to_owned(),
        },
    }
}

/// The controller record's fields the duty reads, as the legacy
/// `ol_names` read them: the server by pid, its start where recorded, the
/// pane, and the harness identity the watch start recorded.
#[derive(Debug, Clone, PartialEq)]
pub struct Record {
    pub server: u64,
    pub server_start: Option<u64>,
    pub pane: String,
    pub window: String,
    pub generation: Option<u64>,
    pub harness: Option<Harness>,
    pub identity: Option<Identity>,
    pub session_rows: Option<PathBuf>,
    pub exit_status: Option<String>,
    pub account: Option<String>,
    pub pending: Option<Pending>,
    pub raw: serde_json::Map<String, Value>,
}

fn number(value: Option<&Value>) -> Option<u64> {
    match value? {
        Value::Number(n) => n.as_u64(),
        Value::String(s) => s.parse().ok(),
        Value::Null | Value::Bool(_) | Value::Array(_) | Value::Object(_) => None,
    }
}

fn text(value: Option<&Value>) -> Option<String> {
    match value? {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        Value::Null | Value::Bool(_) | Value::Array(_) | Value::Object(_) => None,
    }
}

impl Record {
    /// The record as the fleet state holds it; `None` where it names no
    /// server or pane.
    pub fn read(fleet: &FleetState) -> Option<Record> {
        let overseer = fleet.overseer.as_ref()?;
        let raw = &overseer.extra;
        let server = number(raw.get("server"))?;
        let pane = text(raw.get("pane"))?;
        let pid = number(raw.get("harness_pid")).and_then(|p| u32::try_from(p).ok());
        let start = text(raw.get("harness_start"));
        let identity = match (pid, start) {
            (Some(pid), Some(start)) => Some(Identity { pid, start }),
            (Some(_), None) | (None, Some(_)) | (None, None) => None,
        };
        Some(Record {
            server,
            server_start: number(raw.get("server_start")),
            pane,
            window: text(raw.get("window")).unwrap_or_default(),
            generation: overseer.generation,
            harness: text(raw.get("harness")).as_deref().and_then(Harness::parse),
            identity,
            session_rows: text(raw.get("session_rows")).map(PathBuf::from),
            exit_status: raw
                .get("exit")
                .and_then(|e| e.get("status"))
                .and_then(|s| text(Some(s))),
            account: text(raw.get("account")),
            pending: overseer.pending.clone(),
            raw: raw.clone(),
        })
    }

    fn pane_key(&self) -> String {
        format!("{} {}", self.server, self.pane)
    }

    /// The successor a dead session's recovery replays: the pending the
    /// fleet last chose, else this record's own launch fields.
    fn held_successor(&self) -> Option<Pending> {
        if let Some(pending) = &self.pending {
            return Some(pending.clone());
        }
        let line = text(self.raw.get("launch_line"))?;
        Some(Pending {
            launch_line: Some(line),
            harness: text(self.raw.get("harness")),
            account: self.account.clone(),
            home: text(self.raw.get("home")),
            model: text(self.raw.get("model")),
            effort: text(self.raw.get("effort")),
            cwd: text(self.raw.get("cwd")),
            class: text(self.raw.get("class")),
            permission: None,
            extra_args: Vec::new(),
            extra: serde_json::Map::new(),
        })
    }

    /// The compare-and-swap set the request carries: the record as read.
    fn expected(&self) -> OverseerExpected {
        let get = |key: &str| self.raw.get(key).cloned().unwrap_or(Value::Null);
        OverseerExpected {
            server: get("server"),
            server_start: get("server_start"),
            pane: get("pane"),
            // The typed fields of the record are not in `raw`.
            generation: self.generation.map_or(Value::Null, Value::from),
            launch_line: get("launch_line"),
            cwd: get("cwd"),
            session_id: None,
            pending: self
                .pending
                .as_ref()
                .and_then(|p| serde_json::to_value(p).ok())
                .unwrap_or(Value::Null),
        }
    }
}

/// The reads of one pass, three-valued each.
struct Reads {
    process: ProcessReading,
    screen: Result<String, String>,
    rows: Option<Reading<SessionVerdict>>,
}

/// One pass's inputs.
pub struct Pass<'a> {
    pub fleet: &'a FleetState,
    pub readers: &'a LaneReaders<'a>,
    pub legacy: &'a Legacy<'a>,
    pub baseline: &'a Baseline,
    pub settings: &'a WatchSettings,
    pub succession: Succession,
    /// `ORCH_OVERSEER_PREFERENCE`, which the mark line's payload names.
    pub preference: &'a str,
    pub now: u64,
    /// The one request the duty makes: `request-transfer`, as the `op`
    /// command runs it; `Err` is the refusal's text.
    pub transfer: &'a dyn Fn(RequestTransfer) -> Result<(), String>,
}

/// The verdict of the record's session from the reads, in the legacy
/// order (`overseer_pane_read`, `overseer_judge`): the login wall first,
/// then the exit record over a bare shell, then the rows, then the pane.
fn judge(record: &Record, reads: &Reads, marks: &mut dyn FnMut() -> Option<Marks>) -> Verdict {
    let bare = matches!(reads.process, ProcessReading::ShellsOnly);
    let screen = match &reads.screen {
        Ok(screen) => screen.as_str(),
        Err(cause) => {
            return Verdict::Unreadable {
                cause: cause.clone(),
            };
        }
    };
    if let ProcessReading::Unread { cause } = reads.process {
        return Verdict::Unreadable {
            cause: cause.to_owned(),
        };
    }
    let Some(harness) = record.harness else {
        return Verdict::Unreadable {
            cause: "harness-unrecorded".to_owned(),
        };
    };
    let state = observe::judge(screen, harness, &reads.process, None);
    if let State::Walled {
        kind: WallKind::Auth,
        banner,
    } = &state
    {
        return Verdict::Walled {
            source: Source::Auth,
            kind: WallKind::Auth,
            text: banner.clone(),
        };
    }
    if record.exit_status.is_some() && bare {
        return Verdict::Exited {
            source: Source::Record,
        };
    }
    if let Some(rows) = &reads.rows {
        match rows {
            Reading::Live(SessionVerdict::Ended) if bare => {
                return Verdict::Exited {
                    source: Source::Rows,
                };
            }
            Reading::Live(SessionVerdict::Walled { kind }) => {
                let message = record
                    .session_rows
                    .as_deref()
                    .map(rows::last_row)
                    .and_then(|r| match r {
                        Reading::Live(row) => row.message,
                        Reading::Gone | Reading::Unreadable { .. } => None,
                    })
                    .unwrap_or_else(|| "message=unrecorded".to_owned());
                // A rows usage wall stands unless the account judgement
                // measures room (`overseer-wall-lifted`); an auth wall
                // stands whatever it reads.
                if *kind == WallKind::Usage && marks().is_some_and(|m| m.key == MarkKey::Below) {
                    return Verdict::Live;
                }
                return Verdict::Walled {
                    source: Source::Rows,
                    kind: *kind,
                    text: message,
                };
            }
            Reading::Live(SessionVerdict::Wedged) => {
                return Verdict::Exited {
                    source: if bare {
                        Source::Process
                    } else {
                        Source::Context
                    },
                };
            }
            Reading::Live(SessionVerdict::Ended | SessionVerdict::Live) => {
                return if bare {
                    Verdict::Exited {
                        source: Source::Process,
                    }
                } else {
                    Verdict::Live
                };
            }
            Reading::Live(SessionVerdict::Unsupported)
            | Reading::Gone
            | Reading::Unreadable { .. } => {}
        }
    }
    match state {
        State::Exited => Verdict::Exited {
            source: Source::Process,
        },
        State::Walled {
            kind: WallKind::Usage,
            banner,
        } => {
            // The screen never decides alone: the overseer's pane carries
            // every lane's banner it relayed. The account judgement
            // confirms it or the session reads as the working overseer it
            // looks like.
            if marks().is_some_and(|m| m.confirms_wall()) {
                Verdict::Walled {
                    source: Source::Pane,
                    kind: WallKind::Usage,
                    text: banner,
                }
            } else {
                Verdict::Live
            }
        }
        State::Walled {
            kind: WallKind::Auth,
            ..
        }
        | State::Idle
        | State::Working
        | State::Asking
        | State::RateLimitSwitch
        | State::Unjudged { .. } => Verdict::Live,
    }
}

fn set(kind: &str, identity: &str, value: String) -> Change {
    Change::Set {
        kind: kind.to_owned(),
        identity: identity.to_owned(),
        value,
    }
}

fn clear(kind: &str, identity: &str) -> Change {
    Change::Clear {
        kind: kind.to_owned(),
        identity: identity.to_owned(),
    }
}

/// The rows this duty keeps, keyed by the pane key.
const ROWS: [&str; 3] = ["overseer-dead", "overseer-walled", "overseer-mark"];

/// The duty's pass: the one verdict, stored in `slot`, then the count, the
/// line and the request.
pub fn observe(pass: &Pass, slot: &Slot) -> Produced {
    let mut out = Produced::default();
    let judged = pass_verdict(pass, &mut out);
    slot.store(judged);
    out
}

fn pass_verdict(pass: &Pass, out: &mut Produced) -> Judged {
    let at = pass.now;
    let judged = |verdict: Verdict, pane_key: Option<String>| Judged {
        verdict,
        pane_key,
        at,
    };
    if let Some(intent) = pass
        .fleet
        .intents
        .iter()
        .find(|i| i.open() && i.op.on_controller())
    {
        return judged(
            Verdict::Transferring {
                intent: intent.id.clone(),
            },
            None,
        );
    }
    let Some(record) = Record::read(pass.fleet) else {
        return judged(
            Verdict::Unwatched {
                cause: "record-unnamed",
            },
            None,
        );
    };
    let key = record.pane_key();
    // Rows of a pane that is no longer the controller's go with it.
    for kind in ROWS {
        for identity in pass.baseline.identities(kind) {
            if identity != key {
                out.changes.push(clear(kind, &identity));
            }
        }
    }
    let reads = match (pass.readers.pane)(record.server, record.server_start, &record.pane) {
        Reading::Live(fields) => Reads {
            process: (pass.readers.foreground)(
                fields.pid,
                record.harness,
                record.identity.as_ref(),
            ),
            screen: (pass.readers.capture)(&fields.pane),
            rows: record.session_rows.as_deref().map(rows::session_verdict),
        },
        Reading::Gone => {
            return judged(
                Verdict::Unreadable {
                    cause: "pane-gone".to_owned(),
                },
                Some(key),
            );
        }
        Reading::Unreadable { cause } => {
            return judged(
                Verdict::Unreadable {
                    cause: cause.to_owned(),
                },
                Some(key),
            );
        }
    };
    // The account judgement, read at most once per pass and only where a
    // reading asks for it.
    let mut marks_read: Option<Option<Marks>> = None;
    let mut marks = || -> Option<Marks> {
        if marks_read.is_none() {
            marks_read = Some((pass.legacy.marks)(&pass.legacy.scripts, record.harness).ok());
        }
        marks_read.clone().flatten()
    };
    let mut verdict = judge(&record, &reads, &mut marks);
    let mut reserve = false;
    if verdict == Verdict::Live
        && let Some(m) = marks()
        && m.key == MarkKey::Reached
        && m.kind == "headroom"
        && m.value == "0"
    {
        if m.reserve_only {
            reserve = true;
        } else {
            verdict = Verdict::Walled {
                source: Source::Account,
                kind: WallKind::Usage,
                text: format!(
                    "account={} headroom=0 resets={}",
                    if m.account.is_empty() {
                        "unknown"
                    } else {
                        &m.account
                    },
                    if m.resets.is_empty() {
                        "none"
                    } else {
                        &m.resets
                    }
                ),
            };
        }
    }
    let marks_now = marks_read.clone().flatten();
    let (case, source, passes_needed) = match &verdict {
        Verdict::Exited { source } => {
            (Some(OverseerCase::Dead), *source, pass.settings.dead_passes)
        }
        Verdict::Walled { source, .. } => (
            Some(OverseerCase::Walled),
            *source,
            if *source == Source::Pane {
                pass.settings.dead_passes
            } else {
                1
            },
        ),
        Verdict::Live if reserve => (Some(OverseerCase::Reserve), Source::Account, 1),
        Verdict::Live
        | Verdict::Transferring { .. }
        | Verdict::Unwatched { .. }
        | Verdict::Unreadable { .. } => (None, Source::Pane, 0),
    };
    let Some(case) = case else {
        // Live, or a read that settles nothing: the death count is dropped
        // only on a live reading, never on an unreadable one.
        if verdict == Verdict::Live {
            out.changes.push(clear("overseer-dead", &key));
            let prior = pass.baseline.get("overseer-walled", &key).unwrap_or("");
            if !prior.starts_with("reserve:")
                || marks_now.as_ref().is_some_and(|m| m.key == MarkKey::Below)
            {
                out.changes.push(clear("overseer-walled", &key));
            }
            mark_check(&record, &key, marks_now.as_ref(), pass, out);
        }
        return judged(verdict, Some(key));
    };
    let (row, other) = match case {
        OverseerCase::Dead => ("overseer-dead", "overseer-walled"),
        OverseerCase::Walled | OverseerCase::Reserve => ("overseer-walled", "overseer-dead"),
    };
    out.changes.push(clear(other, &key));
    out.changes.push(clear("overseer-mark", &key));
    let prefix = if case == OverseerCase::Reserve {
        "reserve:"
    } else {
        ""
    };
    let prior = pass.baseline.get(row, &key).unwrap_or("").to_owned();
    // A reserve attempt neither consumes nor suppresses a real failure's
    // recovery.
    let prior = match (case, prior.strip_prefix("reserve:")) {
        (OverseerCase::Reserve, Some(p)) => p.to_owned(),
        (OverseerCase::Reserve, None) => prior,
        (OverseerCase::Dead | OverseerCase::Walled, Some(_)) => String::new(),
        (OverseerCase::Dead | OverseerCase::Walled, None) => prior,
    };
    match prior.as_str() {
        "reported" | "requested" => return judged(verdict, Some(key)),
        "announced" => {
            transfer(&record, case, &verdict, &key, prefix, pass, out);
            return judged(verdict, Some(key));
        }
        _ => {}
    }
    let count = prior.parse::<u32>().unwrap_or(0) + 1;
    if count < passes_needed {
        out.changes.push(set(row, &key, format!("{prefix}{count}")));
        return judged(verdict, Some(key));
    }
    // The line, with the wall's own words under it, before anything moves.
    let plan_relaunch = pass.succession == Succession::On
        && match case {
            OverseerCase::Dead => record.held_successor().is_some(),
            OverseerCase::Walled | OverseerCase::Reserve => true,
        };
    let record_field = match case {
        OverseerCase::Dead if record.held_successor().is_none() => {
            Some(format!("{}:{}", record.server, record.pane))
        }
        OverseerCase::Dead | OverseerCase::Walled | OverseerCase::Reserve => None,
    };
    out.events.push(Event::OverseerSession {
        case,
        pane: record.pane.clone(),
        window: record.window.clone(),
        passes: passes_needed,
        succession: pass.succession,
        source: source.word().to_owned(),
        record: record_field,
    });
    if let Verdict::Walled { source, text, .. } = &verdict {
        let lines: Vec<String> = match source {
            Source::Pane => {
                let slice = reads
                    .screen
                    .as_deref()
                    .map(observe::below_last_turn)
                    .unwrap_or_default();
                banner_payload(&slice, text, pass.settings.tail_lines as usize).unwrap_or_default()
            }
            Source::Auth
            | Source::Record
            | Source::Rows
            | Source::Context
            | Source::Process
            | Source::Account => text.lines().map(str::to_owned).collect(),
        };
        out.events.extend(lines.into_iter().map(Event::Tail));
    }
    // The request follows on the duty's next run, after the line is on
    // disk (`A1:276`): the row says it is owed and the duty asks to run
    // again at once.
    out.changes.push(set(
        row,
        &key,
        format!(
            "{prefix}{}",
            if plan_relaunch {
                "announced"
            } else {
                "reported"
            }
        ),
    ));
    out.next_due = plan_relaunch.then_some(pass_next_due());
    judged(verdict, Some(key))
}

/// The instant the announced request is made at: the duty's next slice.
#[allow(
    clippy::disallowed_methods,
    reason = "the one instant the duty asks to run again at, which the runner floors at its next slice"
)]
fn pass_next_due() -> std::time::Instant {
    std::time::Instant::now()
}

/// The announced succession: `request-transfer` with the case's cause and
/// the spent account; a refusal is the duty's failure, said on the log by
/// the runner, and the row stays announced so the next pass asks again.
fn transfer(
    record: &Record,
    case: OverseerCase,
    verdict: &Verdict,
    key: &str,
    prefix: &str,
    pass: &Pass,
    out: &mut Produced,
) {
    let row = match case {
        OverseerCase::Dead => "overseer-dead",
        OverseerCase::Walled | OverseerCase::Reserve => "overseer-walled",
    };
    let (cause, exclude_account, successor) = match case {
        OverseerCase::Dead => (TransferCause::Dead, None, record.held_successor()),
        OverseerCase::Walled | OverseerCase::Reserve => {
            let spent = match verdict {
                Verdict::Walled {
                    source: Source::Account,
                    ..
                }
                | Verdict::Live => record.account.clone(),
                Verdict::Walled { .. } => record.account.clone(),
                Verdict::Exited { .. }
                | Verdict::Transferring { .. }
                | Verdict::Unwatched { .. }
                | Verdict::Unreadable { .. } => None,
            };
            let picked = match (record.harness, spent.as_deref()) {
                (Some(harness), Some(spent)) => {
                    (pass.legacy.pick)(&pass.legacy.scripts, harness, spent)
                }
                (None, _) | (_, None) => Pick::Unjudged {
                    cause: "record-unnamed".to_owned(),
                },
            };
            let successor = match picked {
                Pick::Lane(to) => record.held_successor().map(|mut p| {
                    p.home = (record.harness == Some(Harness::Claude)).then(|| to.clone());
                    p.account = Some(to);
                    p.launch_line = None;
                    p
                }),
                Pick::None | Pick::Unjudged { .. } => None,
            };
            (TransferCause::Walled, spent, successor)
        }
    };
    let Some(successor) = successor else {
        out.changes.push(set(row, key, format!("{prefix}reported")));
        return;
    };
    let request = RequestTransfer {
        expected: record.expected(),
        successor,
        brief_file: None,
        cause,
        exclude_account,
        handoff_session_id: None,
        recovery: None,
    };
    if let Ok(()) = (pass.transfer)(request) {
        out.changes
            .push(set(row, key, format!("{prefix}requested")));
    }
}

/// The marks of a working overseer (`overseer_mark_check`): the first
/// crossing is a line, then one every `mark_repeat` passes while it stands;
/// a below-mark answer clears the row; an unmeasured or failed judgement
/// leaves it as it was.
fn mark_check(record: &Record, key: &str, marks: Option<&Marks>, pass: &Pass, out: &mut Produced) {
    let Some(marks) = marks else {
        return;
    };
    match marks.key {
        MarkKey::Unmeasured => return,
        MarkKey::Below => {
            out.changes.push(clear("overseer-mark", key));
            return;
        }
        MarkKey::Reached => {}
    }
    if marks.kind.is_empty() || marks.value.is_empty() || marks.mark.is_empty() {
        return;
    }
    let prior = pass.baseline.get("overseer-mark", key).unwrap_or("");
    let mut passes = 0;
    if let Some(count) = prior.strip_prefix(&format!("{}|", marks.kind)) {
        passes = count.parse::<u32>().unwrap_or(0) + 1;
        if passes >= pass.settings.mark_repeat {
            passes = 0;
        }
    }
    if passes == 0 {
        out.events.push(Event::OverseerMark {
            pane: record.pane.clone(),
            kind: marks.kind.clone(),
            value: marks.value.clone(),
            mark: marks.mark.clone(),
            succession: marks.succession,
        });
        // The handling under the line (`oversee-watch:4062-4067`): the
        // succession's own words, naming the judge's path and the
        // preference the walk reads.
        let sentence = match marks.succession {
            Succession::Off => "ORCH_OVERSEER_SUCCESSION is off, so no successor opens: rewrite the overseer handoff file and ask the user to start a fresh overseer session.".to_owned(),
            Succession::On => format!(
                "Run {} -- [FLAGS] at the next safe point, with ORCH_OVERSEER_PREFERENCE={} choosing the successor lane.",
                pass.legacy.scripts.join("oversee-succeed").display(),
                if pass.preference.is_empty() {
                    "empty"
                } else {
                    pass.preference
                }
            ),
        };
        out.events.push(Event::Tail(sentence));
    }
    out.changes.push(set(
        "overseer-mark",
        key,
        format!("{}|{passes}", marks.kind),
    ));
}

/// The transfer as the `op` command runs it: admitted, applied through the
/// store's entry with the host's facts, its effect started.
#[allow(
    clippy::disallowed_methods,
    reason = "the overseer duty's one request, request-transfer with its cause: the same sequence the op command runs (admit, the store's entry with the kernel's readers, the effect's start), from the duty that read the session dead or walled (decision 121 Q10)"
)]
pub fn run_transfer(
    path: &Path,
    settings: &Settings,
    env: &crate::ops::Env,
    locking: crate::state::Locking,
    clock: &dyn crate::schedule::Clock,
    request: RequestTransfer,
) -> crate::error::Result<()> {
    let request = crate::ops::Request::RequestTransfer(Box::new(request));
    crate::ops::admit(&request, settings)?;
    let host = crate::ops::Host::kernel(settings.lane_cap, Some(settings.claim_store.clone()));
    let applied = crate::ops::apply_on(path, &request, env, locking, &host)?;
    crate::effects::run(
        path,
        &request,
        &applied.report,
        settings,
        env,
        locking,
        clock,
    )?;
    Ok(())
}

/// Register the native observation duty (decision 153; step5-map § A2,
/// § A3): the controller's one verdict first, stored in `slot`; then,
/// where that verdict leaves the fleet watched (live,
/// unwatched or unreadable, as the legacy long pass went on), the lanes.
/// `env` supplies the request's stamp inputs; the runner's own pane is its
/// `$TMUX_PANE`, never a stray.
pub fn register(
    runner: &mut Runner<'_>,
    path: &Path,
    settings: &Settings,
    env: &crate::ops::Env,
    locking: crate::state::Locking,
    slot: Slot,
) {
    let ctx = Observation {
        path: path.to_path_buf(),
        settings: settings.clone(),
        nonce: env.nonce,
        owner: env.owner.clone(),
        locking,
        slot,
        own_pane: std::env::var("TMUX_PANE").ok(),
    };
    runner.register(crate::schedule::Duty::NativeObservation, body(ctx));
}

/// What the native observation duty runs with: the fleet state it reads,
/// the settings, the stamp inputs of its one request, and the slot the
/// mail duty reads the controller's verdict from.
struct Observation {
    path: PathBuf,
    settings: Settings,
    nonce: u32,
    owner: Option<crate::state::Owner>,
    locking: crate::state::Locking,
    slot: Slot,
    /// The runner's own pane, never a stray.
    own_pane: Option<String>,
}

/// The native observation duty's body (step5-map § A2, § A3; decision 121
/// Q9-Q11): the controller's one verdict first, stored in the slot;
/// then, where that verdict leaves the fleet watched (live, unwatched or
/// unreadable, as the legacy long pass went on), the lanes.
#[allow(
    clippy::disallowed_methods,
    reason = "the observation duty's one read of the fleet state each pass, a snapshot it judges; its transfer request goes through `run_transfer` and its wall record through `ops::apply`"
)]
fn body<'a>(ctx: Observation) -> Body<'a> {
    Box::new(move |tick: &Tick| {
        let Some(snapshot) = crate::state::load(&ctx.path)? else {
            return Ok(Produced::default());
        };
        let fleet =
            <crate::state::FleetState as crate::state::Record>::view(&ctx.path, &snapshot.doc)?;
        let readers = LaneReaders::kernel();
        let legacy = Legacy::scripts(&ctx.settings.roots.project);
        let env = crate::ops::Env {
            now_secs: tick.wall,
            now_nanos: u128::from(tick.wall) * 1_000_000_000,
            nonce: ctx.nonce,
            owner: ctx.owner.clone(),
        };
        let transfer = |request| {
            run_transfer(
                &ctx.path,
                &ctx.settings,
                &env,
                ctx.locking,
                tick.clock,
                request,
            )
            .map_err(|e| e.to_string())
        };
        let mut produced = observe(
            &Pass {
                fleet: &fleet,
                readers: &readers,
                legacy: &legacy,
                baseline: tick.baseline,
                settings: &ctx.settings.watch,
                succession: ctx.settings.succession,
                preference: &ctx.settings.overseer_preference,
                now: tick.wall,
                transfer: &transfer,
            },
            &ctx.slot,
        );
        let watched = ctx.slot.read().is_some_and(|j| match j.verdict {
            Verdict::Live | Verdict::Unwatched { .. } | Verdict::Unreadable { .. } => true,
            Verdict::Exited { .. } | Verdict::Walled { .. } | Verdict::Transferring { .. } => false,
        });
        if watched {
            let own: Vec<String> = ctx.own_pane.iter().cloned().collect();
            let wall_pick = |harness: Harness, model: &str, spent: &str| {
                (legacy.wall_pick)(&legacy.scripts, harness, model, spent)
            };
            let start = |r: &Relaunch| (legacy.relaunch)(&ctx.settings.job_unit, r);
            let route = WallRoute {
                relaunch: ctx.settings.watch.wall_relaunch,
                pick: &wall_pick,
                start: &start,
            };
            let wall_pauses = |request| {
                let request = crate::ops::Request::RecordWallPauses(request);
                crate::ops::apply(&ctx.path, &request, &env, ctx.locking)
                    .map(|_| ())
                    .map_err(|e| e.to_string())
            };
            let lanes = super::lanes::observe(&super::lanes::Pass {
                fleet: &fleet,
                readers: &readers,
                baseline: tick.baseline,
                settings: &ctx.settings.watch,
                now: tick.wall,
                session: ctx.settings.tmux_session.as_deref(),
                own_panes: &own,
                state_dir: &ctx.settings.state_dir,
                claim_store: &ctx.settings.claim_store,
                scripts: &legacy.scripts,
                route: &route,
                wall_pauses: &wall_pauses,
            });
            produced.events.extend(lanes.events);
            produced.changes.extend(lanes.changes);
            produced.failed = produced.failed.take().or(lanes.failed);
        }
        Ok(produced)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The legacy judge's line, parsed as the watch parsed it; a line the
    /// watch has no name for settles nothing.
    #[test]
    fn the_mark_line_is_read_field_by_field() {
        let m = Marks::parse(
            "oversee-succeed: mark-reached kind=headroom value=0 mark=5 succession=off account=/a resets=2026-01-01T00:00:00Z reserve_only=true",
        )
        .unwrap();
        assert_eq!(m.key, MarkKey::Reached);
        assert_eq!(m.kind, "headroom");
        assert_eq!(m.value, "0");
        assert_eq!(m.mark, "5");
        assert_eq!(m.succession, Succession::Off);
        assert_eq!(m.account, "/a");
        assert!(m.reserve_only);
        assert!(!m.confirms_wall());
        let below = Marks::parse("oversee-succeed: account-below-mark kind=headroom").unwrap();
        assert_eq!(below.key, MarkKey::Below);
        assert_eq!(below.succession, Succession::On);
        assert!(Marks::parse("oversee-succeed: something-else").is_none());
    }
}
