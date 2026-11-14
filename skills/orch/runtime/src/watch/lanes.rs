//! The lane observation duty: one read per recorded lane per pass, by the pane
//! key and the identity its launch records, judged once by the one judge over
//! three-valued inputs, with every event line handed back before the baseline
//! row it settles moves.
//!
//! Nothing here acts. The duty reads a pane by its exact id on the server the
//! record names, its foreground through `observe::foreground` with the
//! recorded identity, its screen, and a Pi lane's session rows; it emits the
//! lines and asks the baseline for the rows that keep each one news once. A
//! reading that fails is `lane-unreadable` with its cause and never
//! `window-gone` or `lane-exited`. A window the fleet session holds that no
//! record, open intent or receipt names is `stray-window`, reported and never
//! adopted or closed.
//!
//! The wall rule: a wall screen first seen before the live process started is
//! that process's scrollback, not its wall; the `usage-limit` row is keyed to
//! the identity the wall was judged for, so a replayed screen from an earlier
//! process never promotes. A Pi lane's rows wall is the harness's own current
//! record and needs no comparison.
//!
//! The wall's record and route: the reset the banner names is read by the
//! grammar ([`reset`] below) and the line is `usage-limit-passed` once
//! the clock passes it; the account wall record and the lane record's own wall
//! are written through `ops::wall`; the wall relaunch is the walled lane's
//! close and its `launch-lane` on the account the walk picked, applied by the
//! runtime's own entry, started detached through the one runner under
//! `ORCH_WALL_RELAUNCH=auto`; a window gone while that
//! relaunch is still opening its replacement is not `window-gone`. A lane
//! `ORCH_WATCH_LANE_AGE_SECS` past its
//! launch is `lane-long` once per age interval with the counters its records
//! give. A lane told to hand off records `.handoff` in its item's state and
//! exits: the record is read where `workflow-state
//! handoff-standing` reads it and is `handoff` once per record.
//!
//! Hosted lanes are observed here by the capability line their host declares
//! (`watch::hosted`): a kind with a local pane is read by that pane as a local
//! lane is, a `status=verb` kind through the provider's status verb as well, a
//! `status=none` kind (a cloud session) by its pull request alone; a hosted
//! lane's status file and records are read through the provider. A merged
//! lane, local or hosted, whose work left nothing behind is closed through
//! `close-lane` at its `lane-exited` or `lane-idle` line, or once per screen
//! on any other reading.

// Every reading is matched variant by variant.
#![deny(clippy::wildcard_enum_match_arm)]

use agent_runtime::record::Document;
use std::collections::BTreeSet;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::path::{Path, PathBuf};
use std::time::{Duration, UNIX_EPOCH};

use agent_runtime::clock;
use agent_runtime::harness::Harness;
use agent_runtime::host::tmux::{self, PANE_DEAD, Pane, PaneFields, PaneState};
use agent_runtime::observe::{self, ProcessReading, State, WallAge, WallKind};
use agent_runtime::process::Identity;
use agent_runtime::reading::Reading;
use agent_runtime::rows::{self, LaneVerdict};
use agent_runtime::session;
use jiff::tz::TimeZone;
use serde::Serialize;
use serde_json::{Value, json};

use super::Produced;
use super::baseline::{Baseline, Change};
use super::events::Event;
use super::hosted::{self, Answer, Capabilities, Files, HostStatus, Hosts, PaneKind, Status};
use super::overseer::{Pick, RelaunchPending, relaunch_pending};
use super::wake;
use crate::effects::start_brief;
use crate::marker;
use crate::ops::CLOUD_KIND;
use crate::ops::wall::{self, RecordWallPauses, WallObservation, WallReading};
use crate::settings::{self, Settings, WallRelaunch, WatchSettings};
use crate::state::{self, FleetState, Lane, LaneStatus};
use agent_runtime::accounts::wall::{self as account_wall, AccountWallWrite, WallChannel};
use agent_runtime::intent::Phase;

/// The row kinds this duty keeps, each keyed by the lane's name, pruned
/// when the lane leaves the fleet record.
const LANE_ROWS: [&str; 10] = [
    "lane-exited",
    "lane-asking",
    "lane-idle",
    "model-capacity",
    "usage-limit",
    wake::RESUME_KIND,
    "lane-unreadable",
    "start-stalled",
    hosted::CLOSE_PENDING_ROW,
    hosted::LEFT_ROW,
];

/// Lines kept above the banner in a usage-limit block.
const BANNER_LEAD: usize = 3;

/// One window of the fleet session as the listing reads it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WindowRow {
    pub pane: String,
    pub window: String,
    pub name: String,
}

/// A pane read by exact id on the server whose pid, and where recorded
/// whose start, a record names, looked for among the sockets given, the
/// controller record's first ([`pane_at`]).
pub type PaneRead<'a> = &'a dyn Fn(&[PathBuf], u64, Option<u64>, &str) -> Reading<PaneState>;
/// Who holds a pane's terminal, read for the lane's harness and recorded
/// identity.
pub type ForegroundRead<'a> = &'a dyn Fn(u32, Option<Harness>, Option<&Identity>) -> ProcessReading;
/// The windows of a session on the server at the socket the controller
/// record names, else the one the fleet's reach names, with the server's
/// pid.
pub type WindowsRead<'a> = &'a dyn Fn(Option<&Path>, &str) -> Reading<(u64, Vec<WindowRow>)>;

/// The pane `pane` on the server [`agent_runtime::effects::server_at`] finds among
/// `sockets` by the recorded pid and start. A server proven gone, its pid
/// dead or reused, is the pane gone with it; one that cannot be told from
/// gone leaves the pane unreadable with the cause.
pub fn pane_at(
    sockets: &[PathBuf],
    server: u64,
    server_start: Option<u64>,
    pane: &str,
) -> Reading<PaneState> {
    match agent_runtime::effects::server_at(sockets, server, server_start) {
        agent_runtime::effects::Observed::Present(live) => tmux::pane_state(&live, pane),
        agent_runtime::effects::Observed::Gone { cause: _ } => Reading::Gone,
        agent_runtime::effects::Observed::Unobservable { cause } => Reading::Unreadable { cause },
    }
}

/// The windows of `session` on the server at `socket`; `Gone` for no such
/// session.
#[allow(
    clippy::disallowed_methods,
    reason = "the stray sweep's one listing of the fleet session, which reports a window and never adopts or closes it"
)]
pub fn windows_at(socket: &Path, session: &str) -> Reading<(u64, Vec<WindowRow>)> {
    let live = match tmux::server(socket) {
        Ok(live) => live,
        Err(_) => {
            return Reading::Unreadable {
                cause: "server-unreachable",
            };
        }
    };
    match tmux::session_present(&live, session) {
        Ok(true) => {}
        Ok(false) => return Reading::Gone,
        Err(_) => {
            return Reading::Unreadable {
                cause: "session-unreadable",
            };
        }
    }
    tmux::list_windows(&live, session)
        .map(|rows| {
            rows.into_iter()
                .map(|(window, pane, name)| WindowRow { pane, window, name })
                .collect()
        })
        .map(|rows| (u64::from(live.pid), rows))
}

/// The host reads the duty takes, injected so a pass is a function of the
/// record and what the kernel, the server and the files answered; production
/// takes [`Readers::kernel`]. No read takes a pid alone.
pub struct Readers<'a> {
    /// The pane a launch names.
    pub pane: PaneRead<'a>,
    /// Who holds the pane's terminal.
    pub foreground: ForegroundRead<'a>,
    /// The pane's screen, or the reader's cause.
    pub capture: &'a dyn Fn(&Pane) -> Result<String, String>,
    /// The epoch second the identity's process started (the wall rule).
    pub start_epoch: &'a dyn Fn(&Identity) -> Reading<u64>,
    /// A Pi lane's session rows verdict.
    pub rows: &'a dyn Fn(&Path) -> Reading<LaneVerdict>,
    /// Whether a lane's status file stands.
    pub status_file: &'a dyn Fn(&Path) -> Reading<()>,
    /// The windows of the fleet session; `Gone` for no such session.
    pub windows: WindowsRead<'a>,
    /// The pane ids the intent receipts under the state directory name.
    pub receipts: &'a dyn Fn(&Path) -> Reading<Vec<String>>,
    /// The zone a banner's reset is read in: the named IANA zone, or the
    /// runner's own for a banner naming none; `None` is a zone this host
    /// cannot resolve, which leaves the event with no time on it.
    pub zone: &'a dyn Fn(Option<&str>) -> Option<TimeZone>,
}

impl Readers<'static> {
    /// The readers production judges with: the recorded server found among
    /// the sockets given by pid and start, the exact pane, the one judge's
    /// foreground read, the capture, the rows and the status file.
    #[allow(
        clippy::disallowed_methods,
        reason = "the lane observation duty's reads: the recorded pane by exact id on the server the record names, its foreground through the one judge with the recorded identity, its screen and the lane's files; the duty judges beside the record and never acts"
    )]
    pub fn kernel() -> Readers<'static> {
        fn pane(
            sockets: &[PathBuf],
            server: u64,
            server_start: Option<u64>,
            pane: &str,
        ) -> Reading<PaneState> {
            pane_at(sockets, server, server_start, pane)
        }
        fn foreground(
            pane_pid: u32,
            harness: Option<Harness>,
            recorded: Option<&Identity>,
        ) -> ProcessReading {
            let owns = |name: &str| harness.is_some_and(|h| h.owns_process(name));
            observe::foreground(pane_pid, &owns, recorded)
        }
        fn capture(pane: &Pane) -> Result<String, String> {
            tmux::capture(pane).map_err(|e| e.to_string())
        }
        fn status_file(path: &Path) -> Reading<()> {
            match std::fs::metadata(path) {
                Ok(_) => Reading::Live(()),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Reading::Gone,
                Err(_) => Reading::Unreadable {
                    cause: "status-file-unreadable",
                },
            }
        }
        fn windows(socket: Option<&Path>, session: &str) -> Reading<(u64, Vec<WindowRow>)> {
            match socket {
                Some(socket) => windows_at(socket, session),
                None => Reading::Unreadable {
                    cause: "server-unreachable",
                },
            }
        }
        fn zone(name: Option<&str>) -> Option<TimeZone> {
            match name {
                Some(name) => TimeZone::get(name).ok(),
                None => TimeZone::try_system().ok(),
            }
        }
        Readers {
            pane: &pane,
            foreground: &foreground,
            capture: &capture,
            start_epoch: &observe::start_epoch,
            rows: &rows::lane_verdict,
            status_file: &status_file,
            windows: &windows,
            receipts: &receipts_in,
            zone: &zone,
        }
    }
}

/// The relaunch the wall route starts: the walled lane's close and its
/// `launch-lane` on the picked account, run detached in the launch's
/// checkout with its session, its output at `log`, its exit status landing
/// beside `marker`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Relaunch {
    pub item: String,
    pub window: String,
    /// The account picked.
    pub to: String,
    /// The account the wall spent.
    pub spent: String,
    pub cwd: PathBuf,
    pub session: String,
    /// The detached command, `sh -c` over the two requests, the close
    /// first.
    pub args: Vec<String>,
    pub marker: PathBuf,
    pub log: PathBuf,
}

/// The wall route's two calls and the setting that gates the second, injected
/// so a row plants the answers; production wires the overseer module's
/// [`super::overseer::Judges`] reads.
pub struct WallRoute<'a> {
    pub relaunch: WallRelaunch,
    /// `lanes pick --harness H --native-model M --exclude-lane SPENT --json`.
    pub pick: &'a dyn Fn(Harness, &str, &str) -> Pick,
    /// Start the relaunch detached through the one runner; `Err` is the
    /// launcher's refusal.
    pub start: &'a dyn Fn(&Relaunch) -> Result<(), String>,
}

/// The pane ids every receipt under `<state dir>/intents/` names: the first
/// pane word of each `.pane` file. An absent directory is no receipt; a
/// listing or a file that cannot be read is unreadable.
pub fn receipts_in(state_dir: &Path) -> Reading<Vec<String>> {
    let dir = state_dir.join("intents");
    let entries = match std::fs::read_dir(&dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Reading::Live(Vec::new()),
        Err(_) => {
            return Reading::Unreadable {
                cause: "receipts-unreadable",
            };
        }
    };
    let mut panes = Vec::new();
    for entry in entries {
        let Ok(entry) = entry else {
            return Reading::Unreadable {
                cause: "receipts-unreadable",
            };
        };
        let path = entry.path();
        if path.extension().is_none_or(|e| e != "pane") {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&path) else {
            return Reading::Unreadable {
                cause: "receipts-unreadable",
            };
        };
        if let Some(pane) = text.split_whitespace().find(|w| w.starts_with('%')) {
            panes.push(pane.to_owned());
        }
    }
    Reading::Live(panes)
}

/// Where a wall was read.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum WallSource {
    /// The banner on the pane's screen.
    Pane,
    /// The harness's own session row (a Pi lane).
    Rows,
}

/// What one lane is doing, the `lane_state` words over the typed inputs.
/// `Unreadable` is a read that failed; `Unjudged` is a read that settles
/// nothing. Serialized as `lane status` prints it, the word under `state`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case", tag = "state")]
pub enum LaneState {
    Gone,
    Unreadable {
        cause: String,
    },
    Exited,
    Walled {
        kind: WallKind,
        banner: String,
        source: WallSource,
    },
    Asking,
    RateLimitSwitch,
    Working,
    /// `cause` is the stop's own word from the harness's row where the
    /// lane was judged by its rows and the word is not its ordinary end;
    /// a pane-judged idle carries none but `api-error`, a Codex turn its
    /// provider's API ended.
    Idle {
        capacity: bool,
        cause: Option<String>,
    },
    Unjudged {
        cause: String,
    },
}

/// The three-valued inputs one lane is classified from.
pub struct Inputs<'a> {
    /// The lane's pane on this server; `None` where the kind's pane is the
    /// provider's own and the screen is its capture (`pane=verb`).
    pub pane: Option<&'a Reading<PaneFields>>,
    pub process: Option<&'a ProcessReading>,
    pub screen: Option<&'a Result<String, String>>,
    /// A Pi lane's rows; `None` for every other harness.
    pub rows: Option<&'a Reading<LaneVerdict>>,
    pub harness: Option<Harness>,
    /// Whether the account the lane spends was read as having room: the
    /// close's wall lift passes `Some(true)`, which judges a usage banner
    /// past; the watch reads none and reports every wall.
    pub account_room: Option<bool>,
}

/// The classifier, in the rung order: the window (where the pane is this
/// server's), the read, the process (a pane with nothing but shells under
/// it is the lane, finished), the rows where the harness writes them, then
/// the screen through the one judge. A Pi lane with no rows is unjudged,
/// never idle off its pane.
pub fn classify(inputs: &Inputs) -> LaneState {
    match inputs.pane {
        None | Some(Reading::Live(_)) => {}
        Some(Reading::Gone) => return LaneState::Gone,
        Some(Reading::Unreadable { cause }) => {
            return LaneState::Unreadable {
                cause: (*cause).to_owned(),
            };
        }
    }
    let Some(process) = inputs.process else {
        return LaneState::Unreadable {
            cause: "process-unread".to_owned(),
        };
    };
    if let ProcessReading::ShellsOnly = process {
        return LaneState::Exited;
    }
    let screen = match inputs.screen {
        Some(Ok(screen)) => screen,
        Some(Err(cause)) => {
            return LaneState::Unreadable {
                cause: cause.clone(),
            };
        }
        None => {
            return LaneState::Unreadable {
                cause: "capture-unread".to_owned(),
            };
        }
    };
    if let Some(rows) = inputs.rows {
        match rows {
            Reading::Live(LaneVerdict::Walled) => {
                return LaneState::Walled {
                    kind: WallKind::Usage,
                    banner: String::new(),
                    source: WallSource::Rows,
                };
            }
            Reading::Live(LaneVerdict::Working) => return LaneState::Working,
            Reading::Live(LaneVerdict::Idle { cause }) => {
                return LaneState::Idle {
                    capacity: false,
                    cause: cause.clone(),
                };
            }
            Reading::Gone => {
                return LaneState::Unjudged {
                    cause: "rows-none".to_owned(),
                };
            }
            Reading::Unreadable { cause } => {
                return LaneState::Unjudged {
                    cause: (*cause).to_owned(),
                };
            }
        }
    }
    let Some(harness) = inputs.harness else {
        return LaneState::Unjudged {
            cause: "harness-unrecorded".to_owned(),
        };
    };
    match observe::judge(screen, harness, process, inputs.account_room) {
        // Codex's two turn ends that are no finished return, each by its
        // line on the pane: the capacity refusal first, then an API error.
        State::Idle => {
            let slice = observe::below_last_turn(screen);
            let codex = harness == Harness::Codex;
            let capacity = codex && observe::codex_capacity_refused(&slice);
            LaneState::Idle {
                capacity,
                cause: (codex && !capacity && observe::codex_api_error(&slice))
                    .then(|| "api-error".to_owned()),
            }
        }
        State::Working => LaneState::Working,
        State::Asking => LaneState::Asking,
        State::RateLimitSwitch => LaneState::RateLimitSwitch,
        State::Walled { kind, banner } => LaneState::Walled {
            kind,
            banner,
            source: WallSource::Pane,
        },
        State::Exited => LaneState::Exited,
        State::Unjudged { cause } => match process {
            ProcessReading::Unread { cause: read } if cause == "process-unread" => {
                LaneState::Unreadable {
                    cause: (*read).to_owned(),
                }
            }
            ProcessReading::Unread { .. }
            | ProcessReading::ShellsOnly
            | ProcessReading::HarnessUp
            | ProcessReading::Harness { .. }
            | ProcessReading::ForegroundShell { .. }
            | ProcessReading::ForegroundOther { .. } => LaneState::Unjudged { cause },
        },
    }
}

/// One pass's inputs beyond the readers.
pub struct Pass<'a> {
    pub fleet: &'a FleetState,
    pub readers: &'a Readers<'a>,
    pub baseline: &'a Baseline,
    pub settings: &'a WatchSettings,
    /// The epoch second the pass started at.
    pub now: u64,
    /// The fleet's tmux session, for the stray sweep; none skips it.
    pub session: Option<&'a str>,
    /// The panes this runtime's own processes hold: the runner's claim pane
    /// and the controller's, never strays.
    pub own_panes: &'a [String],
    /// The state directory the receipts are read under, the item states
    /// stand in and a relaunch logs to.
    pub state_dir: &'a Path,
    /// The claim store, beside which the relaunch markers live
    /// (`lib/lane-claims.sh`, `lane_claims_dir`).
    pub claim_store: &'a Path,
    /// The account records' root the wall records are written under.
    pub account_state: &'a agent_runtime::settings::Judged<std::path::PathBuf>,
    /// The scripts directory: the relaunch's `orch-runtime` entry and the
    /// provider calls.
    pub scripts: &'a Path,
    /// The wall route's calls and setting.
    pub route: &'a WallRoute<'a>,
    /// Record the lane walls this pass observed on the fleet record
    /// (`ops::wall`); `Err` is the store's refusal.
    pub wall_pauses: &'a dyn Fn(RecordWallPauses) -> Result<(), String>,
    /// The hosted arms' reads beyond the scripts directory: `gh`, the
    /// account roster and the fleet's repositories.
    pub hosted: &'a hosted::Reads<'a>,
    /// The account a Copilot record naming none runs on ([`copilot_home`]).
    pub copilot_home: Option<&'a Path>,
    /// The tmux server the fleet's reach names, asked where the controller
    /// record names none.
    pub server: Option<&'a Path>,
}

/// What one lane's pass read, kept for the report a row asks for.
struct Observed<'a> {
    lane: &'a Lane,
    name: String,
    pane_key: Option<String>,
    identity: Option<Identity>,
    screen: Option<String>,
    rows_key: Option<String>,
    state: LaneState,
}

fn hash_of(text: &str) -> u64 {
    let mut hasher = DefaultHasher::new();
    text.hash(&mut hasher);
    hasher.finish()
}

/// The lane's name in a line: the window name the launcher gave it, else
/// its item.
pub(super) fn lane_name(lane: &Lane) -> String {
    lane.window.clone().unwrap_or_else(|| lane.item.clone())
}

fn identity_of(lane: &Lane) -> Option<Identity> {
    let launch = lane.launch.as_ref()?;
    Some(Identity {
        pid: u32::try_from(launch.pid?).ok()?,
        start: launch.start.clone()?,
    })
}

fn identity_word(identity: Option<&Identity>) -> String {
    identity.map_or_else(|| "none".to_owned(), |i| format!("{}:{}", i.pid, i.start))
}

/// What a lane's host answers before its pane is read: the provider's
/// status verb where the lane's kind declares one, its capture where the
/// kind's pane is the provider's own (`pane=verb`), and a Pi lane's session
/// rows where its files are the provider's (`files=verb`), the last two
/// asked only where the status verb read the harness running or was not
/// asked.
pub(super) struct HostRead {
    status: Option<Result<HostStatus, String>>,
    screen: Option<Result<String, String>>,
    rows: Option<Answer<String>>,
}

impl HostRead {
    pub(super) fn of(scripts: &Path, lane: &Lane, caps: Capabilities) -> HostRead {
        let status = match (caps.status, lane.harness.as_deref()) {
            (Status::Verb, Some(harness)) => Some(hosted::status(
                scripts,
                hosted::host_of(lane),
                &lane.item,
                harness,
            )),
            (Status::Verb, None) | (Status::Pane | Status::Task | Status::None, _) => None,
        };
        let screen = match (caps.pane, &status) {
            (PaneKind::Verb, None | Some(Ok(HostStatus::Running))) => {
                Some(hosted::capture(scripts, hosted::host_of(lane), &lane.item))
            }
            (PaneKind::Verb, Some(Ok(HostStatus::Exited) | Err(_))) | (PaneKind::Local, _) => None,
        };
        let pi = lane.harness.as_deref().and_then(Harness::parse) == Some(Harness::Pi);
        let rows = match (caps.files, &status) {
            (Files::Verb, None | Some(Ok(HostStatus::Running))) if pi => {
                Some(hosted::session_rows(scripts, lane))
            }
            (Files::Verb, None | Some(Ok(HostStatus::Running)))
            | (Files::Verb, Some(Ok(HostStatus::Exited) | Err(_)))
            | (Files::Local | Files::None, _) => None,
        };
        HostRead {
            status,
            screen,
            rows,
        }
    }
}

/// Read one lane: the pane, its foreground, its screen and, for a Pi lane,
/// its rows, each once. `host` is what its provider answered first: an
/// exited harness is the lane exited whatever its pane shows, a failed read
/// leaves it unjudged, and a running one is the proof that the harness is
/// up, which the pane is judged with: the provider's own where its kind
/// captures it, else the local pane, whose own foreground is the transport
/// shell and proves nothing of the harness either way. `sockets` are where
/// the lane's server is looked for, the controller record's first, then
/// the one the fleet's reach names.
fn read_lane<'a>(
    lane: &'a Lane,
    readers: &Readers,
    sockets: &[PathBuf],
    host: HostRead,
    account_room: Option<bool>,
) -> Observed<'a> {
    let name = lane_name(lane);
    let harness = lane.harness.as_deref().and_then(Harness::parse);
    let identity = identity_of(lane);
    let launch = lane.launch.as_ref();
    let recorded = match (
        launch.and_then(|l| l.server),
        launch.and_then(|l| l.pane.as_deref()),
    ) {
        (Some(server), Some(pane_id)) => Some((server, pane_id)),
        (None, _) | (_, None) => None,
    };
    let unread = |state: LaneState| Observed {
        lane,
        name: name.clone(),
        pane_key: recorded.map(|(server, pane_id)| format!("{server} {pane_id}")),
        identity: identity.clone(),
        screen: None,
        rows_key: None,
        state,
    };
    let harness_up = match host.status {
        Some(Err(cause)) => return unread(LaneState::Unjudged { cause }),
        Some(Ok(HostStatus::Exited)) => return unread(LaneState::Exited),
        Some(Ok(HostStatus::Running)) => true,
        None => false,
    };
    let (rows_reading, rows_key) = match host.rows {
        Some(answer) => {
            let row = match answer {
                Answer::Live(text) => rows::last_row_in(&text),
                Answer::Gone => Reading::Gone,
                Answer::Unreadable { cause: _ } => Reading::Unreadable {
                    cause: "rows-host-unread",
                },
            };
            let key = match &row {
                Reading::Live(row) => serde_json::to_string(row).ok(),
                Reading::Gone | Reading::Unreadable { .. } => None,
            };
            let verdict = match row {
                Reading::Live(row) => rows::judge_lane(&row),
                Reading::Gone => Reading::Gone,
                Reading::Unreadable { cause } => Reading::Unreadable { cause },
            };
            (Some(verdict), key)
        }
        None => {
            let rows_file = (harness == Some(Harness::Pi))
                .then(|| {
                    lane.mail_root.as_deref().map(|root| {
                        Path::new(root)
                            .join("tmp")
                            .join("lane-mail")
                            .join(&lane.item)
                            .join("session-rows.jsonl")
                    })
                })
                .flatten();
            let key = rows_file.as_deref().and_then(|f| match rows::last_row(f) {
                Reading::Live(row) => serde_json::to_string(&row).ok(),
                Reading::Gone | Reading::Unreadable { .. } => None,
            });
            (rows_file.as_deref().map(|f| (readers.rows)(f)), key)
        }
    };
    if let Some(screen) = host.screen {
        let state = classify(&Inputs {
            pane: None,
            process: Some(&ProcessReading::HarnessUp),
            screen: Some(&screen),
            rows: rows_reading.as_ref(),
            harness,
            account_room,
        });
        return Observed {
            lane,
            name: name.clone(),
            pane_key: recorded.map(|(server, pane_id)| format!("{server} {pane_id}")),
            identity: identity.clone(),
            screen: screen.ok(),
            rows_key,
            state,
        };
    }
    let Some((server, pane_id)) = recorded else {
        return unread(LaneState::Unjudged {
            cause: "pane-unrecorded".to_owned(),
        });
    };
    let pane_key = Some(format!("{server} {pane_id}"));
    let pane = match (readers.pane)(
        sockets,
        server,
        launch.and_then(|l| l.server_start),
        pane_id,
    ) {
        Reading::Live(PaneState::Running(fields)) => Reading::Live(fields),
        // A pane its server keeps after its process exited holds no
        // session: a local lane has ended, its kept screen the closing
        // lines. A hosted lane's local pane is the transport to its host,
        // whose end proves nothing of the harness there.
        Reading::Live(PaneState::Dead(kept)) if hosted::host_of(lane) == "local" => {
            return Observed {
                lane,
                name,
                pane_key,
                identity,
                screen: (readers.capture)(&kept).ok(),
                rows_key,
                state: LaneState::Exited,
            };
        }
        Reading::Live(PaneState::Dead(_)) => Reading::Unreadable { cause: PANE_DEAD },
        Reading::Gone => Reading::Gone,
        Reading::Unreadable { cause } => Reading::Unreadable { cause },
    };
    let (process, screen) = match &pane {
        Reading::Live(fields) => (
            Some(if harness_up {
                ProcessReading::HarnessUp
            } else {
                (readers.foreground)(fields.pid, harness, identity.as_ref())
            }),
            Some((readers.capture)(&fields.pane)),
        ),
        Reading::Gone | Reading::Unreadable { .. } => (None, None),
    };
    let state = classify(&Inputs {
        pane: Some(&pane),
        process: process.as_ref(),
        screen: screen.as_ref(),
        rows: rows_reading.as_ref(),
        harness,
        account_room,
    });
    Observed {
        lane,
        name,
        pane_key,
        identity,
        screen: screen.and_then(Result::ok),
        rows_key,
        state,
    }
}

/// `lane status --item`. The lane is the item's one in-flight record; its
/// host is read as the observation duty reads it, so a host whose
/// capability line cannot be read, or whose kind judges no status, leaves
/// the lane unjudged with the cause; the counts are the `lane-long` line's,
/// read where it reads them; nothing is written.
#[allow(
    clippy::disallowed_methods,
    reason = "the verb's one read of the fleet state, a snapshot it judges and prints; it acts on nothing"
)]
pub fn status(settings: &Settings, path: &Path, item: &str) -> crate::error::Result<Value> {
    fn refused(key: &'static str, fields: &[(&str, &str)]) -> crate::error::Error {
        crate::error::Error::from(agent_runtime::Error::refused(key, fields))
    }
    let fleet = state::load(path)?
        .map(|snapshot| <FleetState as state::Record>::view(path, &snapshot.doc))
        .transpose()?
        .ok_or_else(|| refused("fleet-missing", &[("path", &path.display().to_string())]))?;
    let mut lanes = fleet
        .lanes
        .iter()
        .filter(|l| l.item == item && l.status.in_flight());
    let lane = match (lanes.next(), lanes.next()) {
        (Some(lane), None) => lane,
        (None, _) => return Err(refused("lane-missing", &[("item", item)])),
        (Some(_), Some(_)) => return Err(refused("lane-ambiguous", &[("item", item)])),
    };
    let scripts = super::overseer::scripts_dir(&settings.roots.project);
    let hosts = Hosts::read(&scripts, [lane]);
    let unjudged = |cause: String| HostRead {
        status: Some(Err(cause)),
        screen: None,
        rows: None,
    };
    let (host, files) = match hosts.of(lane) {
        Err(cause) => (unjudged(cause), None),
        Ok(caps) if caps.status == Status::None => {
            (unjudged("status-none".to_owned()), Some(caps.files))
        }
        Ok(caps) => (HostRead::of(&scripts, lane, caps), Some(caps.files)),
    };
    let readers = Readers::kernel();
    let sockets = agent_runtime::effects::fleet_sockets(
        fleet
            .overseer
            .as_ref()
            .and_then(agent_runtime::effects::overseer_socket),
        crate::effects::fleet_reach(settings)?.socket,
    );
    let observed = read_lane(lane, &readers, &sockets, host, None);
    let mut said = Produced::default();
    let (counters, stage) = lane_counts(
        lane,
        files,
        path.parent().unwrap_or(&settings.state_dir),
        &scripts,
        &mut said,
    );
    let mut reply = json!({
        "item": lane.item,
        "window": observed.name,
        "pane_key": observed.pane_key,
        "identity": observed.identity.as_ref().map(|i| identity_word(Some(i))),
        "review_rounds": counters.review_rounds,
        "fix_receipts": counters.fix_receipts,
        "validation_runs": counters.validation_runs,
        "restacks": counters.restacks,
        "repeated_class_rounds": counters.repeated_class_rounds,
        "stage": stage,
        "counts_cause": said.failed,
    });
    let state = serde_json::to_value(&observed.state).unwrap_or_default();
    if let (Value::Object(reply), Value::Object(state)) = (&mut reply, state) {
        reply.extend(state);
    }
    Ok(reply)
}

/// One lane judged as the observation duty judges it, for the close: its
/// host read first where its kind declares a status verb or its own pane,
/// then its recorded pane; a host whose capability line cannot be read
/// leaves it unjudged with the cause. `socket` is the one the controller
/// record names, where the lane's server is looked for first, as the
/// observation duty looks.
pub(crate) fn judge(
    settings: &Settings,
    lane: &Lane,
    socket: Option<&Path>,
    account_room: Option<bool>,
) -> LaneState {
    let scripts = super::overseer::scripts_dir(&settings.roots.project);
    let hosts = Hosts::read(&scripts, [lane]);
    let host = match hosts.of(lane) {
        Err(cause) => HostRead {
            status: Some(Err(cause)),
            screen: None,
            rows: None,
        },
        Ok(caps) => HostRead::of(&scripts, lane, caps),
    };
    let readers = Readers::kernel();
    let sockets = agent_runtime::effects::fleet_sockets(
        socket.map(Path::to_path_buf),
        crate::effects::fleet_reach(settings)
            .ok()
            .and_then(|reach| reach.socket),
    );
    read_lane(lane, &readers, &sockets, host, account_room).state
}

/// The non-blank lines of `block`, the last `cap` of them.
pub fn bounded_tail(block: &str, cap: usize) -> Vec<String> {
    let lines: Vec<&str> = block.lines().filter(|l| !l.trim().is_empty()).collect();
    let start = lines.len().saturating_sub(cap);
    lines[start..].iter().map(|l| (*l).to_owned()).collect()
}

/// The lane-exited payload: the closing report with the prompt noise of a
/// shell in a removed worktree dropped.
pub fn report_tail(block: &str, cap: usize) -> Vec<String> {
    let lines: Vec<&str> = block.lines().filter(|l| !l.trim().is_empty()).collect();
    if lines.is_empty() {
        return Vec::new();
    }
    let kept: Vec<&str> = lines
        .iter()
        .copied()
        .filter(|l| !(l.starts_with("Hook failed:") || is_cd_noise(l)))
        .collect();
    if kept.is_empty() {
        return vec![format!("payload-noise-only lines={}", lines.len())];
    }
    let start = kept.len().saturating_sub(cap);
    kept[start..].iter().map(|l| (*l).to_owned()).collect()
}

fn is_cd_noise(line: &str) -> bool {
    line.starts_with("bash: cd: ") && line.ends_with(": No such file or directory")
}

/// The usage-limit payload: a window of `cap` non-blank lines of `slice`
/// around the banner's first line, `BANNER_LEAD` above it and the rest
/// below, slid up when it runs into the bottom. `None`
/// where the banner's first line is not in the slice.
pub fn banner_payload(slice: &str, banner: &str, cap: usize) -> Option<Vec<String>> {
    let first = banner.lines().next()?;
    if first.is_empty() || cap == 0 {
        return None;
    }
    let lines: Vec<&str> = slice.lines().filter(|l| !l.trim().is_empty()).collect();
    let at = lines.iter().position(|l| *l == first)?;
    let lead = BANNER_LEAD.min(cap - 1);
    let mut start = at.saturating_sub(lead);
    let mut end = start + cap;
    if end > lines.len() {
        end = lines.len();
        start = end.saturating_sub(cap);
    }
    Some(lines[start..end].iter().map(|l| (*l).to_owned()).collect())
}

/// The lines of an event's payload as events.
fn payload(lines: Vec<String>) -> impl Iterator<Item = Event> {
    // The capture keeps each row's trailing blanks for the judge
    // (`host::tmux::capture`); a reader of the log needs none.
    lines
        .into_iter()
        .map(|l| Event::Tail(l.trim_end_matches(' ').to_owned()))
}

/// A set-change for a lane row.
pub(super) fn set(kind: &str, lane: &str, value: String) -> Change {
    Change::Set {
        kind: kind.to_owned(),
        identity: lane.to_owned(),
        value,
    }
}

pub(super) fn clear(kind: &str, lane: &str) -> Change {
    Change::Clear {
        kind: kind.to_owned(),
        identity: lane.to_owned(),
    }
}

/// A partial failure of the pass, said by the runner under its one rule; the
/// first one stands, the pass goes on.
pub(super) fn fail(out: &mut Produced, line: String) {
    out.failed.get_or_insert(line);
}

/// The watch's own state directory, beside the claim store:
/// where the account wall records and the relaunch markers live.
pub fn watch_state_dir(claim_store: &Path) -> &Path {
    claim_store.parent().unwrap_or(claim_store)
}

/// The lanes pass: every in-flight lane a pane or the provider's status verb
/// judges read once, the lines printed for each kind, the hosted readings (the
/// prepare records, the cloud stall), the finished close of a merged lane, the stray
/// sweep and the start stall, with the rows that keep each line news once. A
/// host whose capability line could not be read is the pass's failure once,
/// and its lanes are left unjudged this pass.
pub fn observe(pass: &Pass) -> Produced {
    let mut out = Produced::default();
    let cap = pass.settings.tail_lines as usize;
    // The hosts of the lanes this pass judges, the in-flight ones alone: a
    // parked, done or stopped record's host is not asked; `lane_long`'s parked
    // arm reads no line.
    let hosts = Hosts::read(
        pass.scripts,
        pass.fleet.lanes.iter().filter(|l| l.status.in_flight()),
    );
    for cause in hosts.unreadable() {
        fail(&mut out, cause.to_owned());
    }
    let in_flight: Vec<&Lane> = pass
        .fleet
        .lanes
        .iter()
        .filter(|l| l.status.in_flight())
        .collect();
    let names: BTreeSet<String> = in_flight.iter().map(|l| lane_name(l)).collect();
    // Rows of lanes that left the record no longer describe an observation.
    for kind in LANE_ROWS {
        for identity in pass.baseline.identities(kind) {
            if !names.contains(&identity) {
                out.changes.push(clear(kind, &identity));
            }
        }
    }
    hosted::prune_close_markers(pass, &mut out);
    hosted::complete_parks(pass, &mut out);
    // A `status=none` kind's window holds no harness the pane passes judge.
    let lanes: Vec<(&Lane, Capabilities)> = in_flight
        .iter()
        .filter_map(|l| hosts.of(l).ok().map(|caps| (*l, caps)))
        .filter(|(_, caps)| caps.status != Status::None)
        .collect();
    let sockets = agent_runtime::effects::fleet_sockets(
        pass.fleet
            .overseer
            .as_ref()
            .and_then(agent_runtime::effects::overseer_socket),
        pass.server.map(Path::to_path_buf),
    );
    let observed: Vec<Observed> = lanes
        .iter()
        .map(|(lane, caps)| {
            read_lane(
                lane,
                pass.readers,
                &sockets,
                HostRead::of(pass.scripts, lane, *caps),
                None,
            )
        })
        .collect();
    let mut walls = Vec::new();
    for obs in &observed {
        let reading = observe_one(obs, pass, &hosts, cap, &mut out);
        walls.push(WallObservation {
            item: obs.lane.item.clone(),
            window: obs.lane.window.clone().unwrap_or_default(),
            reading,
        });
    }
    let observed_lanes: Vec<&Lane> = observed.iter().map(|o| o.lane).collect();
    hosted::retry_pending_closes(&observed_lanes, pass, &hosts, &mut out);
    wall_pauses(&walls, pass, &mut out);
    hosted::prepare(pass, &mut out);
    hosted::cloud_stalls(pass, &hosts, &mut out);
    for lane in &in_flight {
        start_stall(lane, pass, &hosts, &mut out);
    }
    lane_long(pass, &hosts, &mut out);
    handoffs(pass, &hosts, &mut out);
    if let Some(session) = pass.session {
        strays(session, pass, &mut out);
    }
    out
}

/// The lane record's own wall: the observations handed to the
/// record's transition where a wall stands on a record, a `usage-limit` row
/// stands, or this pass read one; otherwise the record is left untouched. A
/// refused write is the duty's news as one line, and the next pass asks again.
fn wall_pauses(walls: &[WallObservation], pass: &Pass, out: &mut Produced) {
    let standing = pass
        .fleet
        .lanes
        .iter()
        .any(|l| l.extra.get("walled").is_some_and(|w| !w.is_null()));
    let seen = walls
        .iter()
        .any(|w| matches!(w.reading, WallReading::Walled { .. }));
    if !(standing || seen || !pass.baseline.identities("usage-limit").is_empty()) {
        return;
    }
    // A refused write is the pass's partial failure (said by the runner under
    // its one rule).
    if let Err(cause) = (pass.wall_pauses)(RecordWallPauses {
        observations: walls.to_vec(),
    }) {
        fail(out, format!("wall-unrecorded lane=oversee cause={cause}"));
    }
}

/// Whether an item's handoff record stands, as `workflow-state
/// handoff-standing` answers it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HandoffReading {
    /// The record, one JSON line as jq's `tojson` prints it.
    Stands { record: String },
    /// No record, or one the relaunched lane stamped `resumed_at` on.
    None,
    /// A place that could not be read; never "no handoff".
    Unreadable { path: PathBuf },
}

/// One place's answer: an absent file is none; a file that cannot be read
/// or parsed is unreadable, never no handoff; `.handoff` stands where it is
/// an object with no `resumed_at`.
pub fn handoff_read(path: &Path) -> HandoffReading {
    match item_doc(path) {
        Reading::Live(doc) => match standing_record(&doc) {
            Some(record) => HandoffReading::Stands { record },
            None => HandoffReading::None,
        },
        Reading::Gone => HandoffReading::None,
        Reading::Unreadable { cause: _ } => HandoffReading::Unreadable {
            path: path.to_path_buf(),
        },
    }
}

/// An item state's standing handoff record, one JSON line.
pub(super) fn standing_record(doc: &Document) -> Option<String> {
    match doc.get("handoff") {
        Some(Value::Object(record)) => match record.get("resumed_at") {
            None | Some(Value::Null) => Some(Value::Object(record.clone()).to_string()),
            Some(
                Value::Bool(_)
                | Value::Number(_)
                | Value::String(_)
                | Value::Array(_)
                | Value::Object(_),
            ) => None,
        },
        None
        | Some(
            Value::Null | Value::Bool(_) | Value::Number(_) | Value::String(_) | Value::Array(_),
        ) => None,
    }
}

/// The places an item's handoff record is read, in order: the item's file
/// under the state directory, then under the lane root's `tmp` where a root
/// is named and that is another file. A lane whose launch forbids writing
/// the main checkout keeps its record in its worktree's `tmp`.
pub fn handoff_places(state_dir: &Path, item: &str, root: Option<&Path>) -> Vec<PathBuf> {
    let mut places = vec![state::item_path(state_dir, item)];
    if let Some(root) = root {
        let place = state::item_path(&root.join("tmp"), item);
        if place != places[0] {
            places.push(place);
        }
    }
    places
}

/// The item's standing handoff over its places, the lane's root as the
/// worktree: the first standing record wins, else any unreadable place,
/// else none.
pub fn handoff_standing(state_dir: &Path, lane: &Lane) -> HandoffReading {
    let root = lane
        .mail_root
        .as_deref()
        .filter(|r| !r.is_empty())
        .map(Path::new);
    let mut unread = None;
    for place in handoff_places(state_dir, &lane.item, root) {
        match handoff_read(&place) {
            HandoffReading::Stands { record } => return HandoffReading::Stands { record },
            HandoffReading::Unreadable { path } => {
                unread.get_or_insert(path);
            }
            HandoffReading::None => {}
        }
    }
    match unread {
        Some(path) => HandoffReading::Unreadable { path },
        None => HandoffReading::None,
    }
}

/// The handoff read: every lane's record read once where its host's files
/// are, a local lane's of any status on this disk and an in-flight lane's
/// on a `files=verb` host through its provider; a standing record is
/// `handoff` with the record under it once per record (the row keyed by the
/// record's checksum, so a re-run between the event and the relaunch says
/// nothing), a record the relaunch stamped clears the row, and a place that
/// could not be read is the pass's partial failure with the other lanes'
/// news standing. Rows of items no record names go.
fn handoffs(pass: &Pass, hosts: &Hosts, out: &mut Produced) {
    let recorded: BTreeSet<&str> = pass.fleet.lanes.iter().map(|l| l.item.as_str()).collect();
    for kind in ["handoff", hosted::CLONE_ROW] {
        for item in pass.baseline.identities(kind) {
            if !recorded.contains(item.as_str()) {
                out.changes.push(clear(kind, &item));
            }
        }
    }
    for lane in &pass.fleet.lanes {
        let item = lane.item.as_str();
        let reading = match hosts.of(lane).map(|caps| caps.files) {
            Ok(Files::Local) => handoff_standing(pass.state_dir, lane),
            Ok(Files::Verb) if lane.status.in_flight() => match hosted::handoff(pass, lane, out) {
                Ok(reading) => reading,
                Err(fields) => {
                    fail(out, format!("handoff-read-failed item={item} {fields}"));
                    continue;
                }
            },
            // A lane out of flight is not asked of its host, whose sandbox
            // a park may have stopped; a kind with no files keeps no record
            // here; a host whose line could not be read is the pass's
            // failure already.
            Ok(Files::Verb | Files::None) | Err(_) => continue,
        };
        match reading {
            HandoffReading::None => out.changes.push(clear("handoff", item)),
            HandoffReading::Unreadable { path } => fail(
                out,
                format!("handoff-read-failed item={item} path={}", path.display()),
            ),
            HandoffReading::Stands { record } => {
                let key = agent_runtime::record::cksum(record.as_bytes()).to_string();
                let prior = pass.baseline.get("handoff", item);
                out.changes.push(set("handoff", item, key.clone()));
                if prior != Some(key.as_str()) {
                    out.events.push(Event::Handoff {
                        item: item.to_owned(),
                    });
                    out.events.push(Event::Tail(record));
                }
            }
        }
    }
}

/// One lane's lines and rows from what was read, and what the record's
/// wall transition is told of it.
fn observe_one(
    obs: &Observed,
    pass: &Pass,
    hosts: &Hosts,
    cap: usize,
    out: &mut Produced,
) -> WallReading {
    let lane = &obs.name;
    let get = |kind: &str| pass.baseline.get(kind, lane).map(str::to_owned);
    let pane_key = obs.pane_key.clone().unwrap_or_default();
    let slice = obs
        .screen
        .as_deref()
        .map(observe::below_last_turn)
        .unwrap_or_default();
    // The wall is judged before the kind's lines: an older screen settles
    // nothing, and the lane then takes the unjudged path below.
    let (state, reading) = match &obs.state {
        LaneState::Walled {
            kind,
            banner,
            source,
        } => wall(obs, *kind, banner, *source, &slice, pass, hosts, cap, out),
        LaneState::Unreadable { .. } => (obs.state.clone(), WallReading::Unavailable),
        // A gone window's rows wait for the pass that judges it.
        LaneState::Gone => (obs.state.clone(), WallReading::Clear),
        // A read with no banner ends the wall: a later wall under the same
        // banner is news again.
        LaneState::Exited
        | LaneState::Asking
        | LaneState::RateLimitSwitch
        | LaneState::Working
        | LaneState::Idle { .. }
        | LaneState::Unjudged { .. } => {
            out.changes.push(clear("usage-limit", lane));
            (obs.state.clone(), WallReading::Clear)
        }
    };
    if !matches!(
        state,
        LaneState::Gone | LaneState::Exited | LaneState::Idle { .. }
    ) {
        let key = format!("{pane_key}|{}", hash_of(&slice));
        hosted::close_left(obs.lane, pass, hosts, &key, out);
    }
    match &state {
        LaneState::Gone => {
            // A window gone because the relaunch the route started is still
            // opening it is not news, and its rows wait for the pass that
            // judges the gone window; a marker this pass cannot read is its
            // partial failure, never "not pending".
            let marker = wall::relaunch_marker_path(watch_state_dir(pass.claim_store), lane);
            match relaunch_pending(&marker, pass.settings.prepare, pass.now) {
                RelaunchPending::Pending => return reading,
                RelaunchPending::Unreadable { path, cause } => {
                    fail(
                        out,
                        format!("state-read-failed path={} cause={cause}", path.display()),
                    );
                    return reading;
                }
                RelaunchPending::None => {}
            }
            out.events.push(Event::WindowGone { lane: lane.clone() });
            for kind in [
                "lane-asking",
                "usage-limit",
                "model-capacity",
                "lane-exited",
                "lane-idle",
                "lane-unreadable",
            ] {
                out.changes.push(clear(kind, lane));
            }
            return reading;
        }
        LaneState::Unreadable { cause } => {
            if get("lane-unreadable").as_deref() != Some(cause.as_str()) {
                out.events.push(Event::LaneUnreadable {
                    lane: lane.clone(),
                    cause: cause.clone(),
                });
                out.changes
                    .push(set("lane-unreadable", lane, cause.clone()));
            }
            return reading;
        }
        LaneState::Exited
        | LaneState::Walled { .. }
        | LaneState::Asking
        | LaneState::RateLimitSwitch
        | LaneState::Working
        | LaneState::Idle { .. }
        | LaneState::Unjudged { .. } => {
            out.changes.push(clear("lane-unreadable", lane));
        }
    }
    // Exited: two consecutive passes on one pane key, then reported once.
    // The row standing is the first pass's record: a lane with no pane of
    // its own, which the provider's status verb judges, keys on nothing,
    // and an absent row must not read as that first pass.
    if let LaneState::Exited = state {
        let prior = get("lane-exited");
        if prior.as_deref() == Some(format!("{pane_key}|reported").as_str()) {
            return reading;
        }
        if prior.as_deref() == Some(pane_key.as_str()) {
            out.events.push(Event::LaneExited { lane: lane.clone() });
            out.events.extend(payload(report_tail(&slice, cap)));
            out.changes
                .push(set("lane-exited", lane, format!("{pane_key}|reported")));
            out.changes.push(clear("lane-asking", lane));
            hosted::close_finished(obs.lane, pass, hosts, "lane-exited", &pane_key, out);
        } else {
            out.changes.push(set("lane-exited", lane, pane_key));
        }
        return reading;
    }
    out.changes.push(clear("lane-exited", lane));
    // Asking: once per prompt, keyed by the pane, the slice and a Copilot
    // lane's policy note, so a grant a policy withdraws under an unchanged
    // prompt is news.
    match &state {
        LaneState::Asking | LaneState::RateLimitSwitch => {
            let note = copilot_note(obs.lane, pass);
            let fingerprint = keyed(format!("{pane_key}|{}", hash_of(&slice)), note.as_deref());
            let prior = get("lane-asking");
            out.changes
                .push(set("lane-asking", lane, fingerprint.clone()));
            if prior.as_deref() != Some(fingerprint.as_str()) {
                out.events.push(Event::LaneAsking {
                    lane: lane.clone(),
                    note,
                });
                out.events.extend(payload(bounded_tail(&slice, cap)));
            }
        }
        LaneState::Working | LaneState::Idle { .. } => {
            out.changes.push(clear("lane-asking", lane));
        }
        LaneState::Gone
        | LaneState::Unreadable { .. }
        | LaneState::Exited
        | LaneState::Walled { .. }
        | LaneState::Unjudged { .. } => {}
    }
    // Idle: the capacity refusal once per turn, else the finished turn once
    // per screen, on the first pass for a local Codex lane below a prior
    // turn and on two consecutive passes otherwise; the line carries the
    // stop's cause where the verdict kept one, so a turn its output limit
    // cut is told apart from a finished one, whose line carries none, else
    // a Copilot lane's policy note, keyed as the asking line keys it.
    match &state {
        LaneState::Idle { capacity: true, .. } => {
            let key = hash_of(&slice).to_string();
            out.changes.push(clear("lane-idle", lane));
            if get("model-capacity").as_deref() != Some(key.as_str()) {
                out.changes.push(set("model-capacity", lane, key));
                out.events.push(Event::ModelCapacity { lane: lane.clone() });
            }
        }
        LaneState::Idle {
            capacity: false,
            cause,
        } => {
            out.changes.push(clear("model-capacity", lane));
            let turn = obs.rows_key.as_deref().unwrap_or(&slice);
            let note = cause
                .as_ref()
                .map(|word| format!("cause={word}"))
                .or_else(|| copilot_note(obs.lane, pass));
            let key = keyed(format!("{pane_key}|{}", hash_of(turn)), note.as_deref());
            let prior = get("lane-idle").unwrap_or_default();
            if prior == format!("{key}|reported") {
                return reading;
            }
            // A hosted lane's screen between a finished tool call and the
            // next reads the same, so only a local lane's is believed at once.
            let codex_after_turn = obs.lane.harness.as_deref() == Some("codex")
                && hosted::host_of(obs.lane) == "local"
                && obs.screen.as_deref().is_some_and(|s| s != slice);
            if prior == key || codex_after_turn {
                out.changes
                    .push(set("lane-idle", lane, format!("{key}|reported")));
                out.events.push(Event::IdleAfterReturn {
                    lane: lane.clone(),
                    note,
                });
                out.events.extend(payload(bounded_tail(&slice, cap)));
                hosted::close_finished(obs.lane, pass, hosts, "lane-idle", &key, out);
            } else {
                out.changes.push(set("lane-idle", lane, key));
            }
        }
        LaneState::Gone
        | LaneState::Unreadable { .. }
        | LaneState::Exited
        | LaneState::Walled { .. }
        | LaneState::Asking
        | LaneState::RateLimitSwitch
        | LaneState::Working
        | LaneState::Unjudged { .. } => {
            out.changes.push(clear("lane-idle", lane));
            out.changes.push(clear("model-capacity", lane));
        }
    }
    reading
}

/// A line's key with the note the line carries, so a changed note is news
/// under an unchanged screen.
fn keyed(key: String, note: Option<&str>) -> String {
    match note {
        Some(note) => format!("{key}|{note}"),
        None => key,
    }
}

/// The account a Copilot record naming none runs on, as the lane's own
/// readers name it: the runtime's `COPILOT_HOME`, else `.copilot` under its
/// home.
pub fn copilot_home(settings: &Settings) -> Option<PathBuf> {
    settings
        .copilot_home
        .as_deref()
        .map(PathBuf::from)
        .or_else(|| {
            settings
                .home
                .as_deref()
                .map(|home| Path::new(home).join(".copilot"))
        })
}

/// The policy note of a Copilot lane's line (`lane-asking`,
/// `idle-after-return`), for a running record whose launch granted
/// allow-all (`allow_all` true): what the session's status-line record
/// under its account's `lane-status/` says. Enterprise managed settings can
/// withdraw the grant mid-run, and each tool call then waits on a prompt
/// nobody at the pane answers, so `stop-cause=allow-all-blocked-by-policy`
/// where the CLI reports `allow_all_enabled` false, and
/// `session-record=<reason>` where no record answers for the session:
/// [`agent_runtime::context::copilot_record`]'s reasons, or `worktree-unmatched` and
/// `store-unreadable` from the store read that binds a record naming no
/// session id. The record is read under the record's `account`, else the
/// `home` its confirmed launch ran under, else the watch's own Copilot home
/// (`account-unnamed` with none). `None` for every other lane: a launch
/// without the grant waits on its prompts by design, and the record alone
/// cannot tell the two apart; a hosted lane's store is on its host, which
/// this machine's store would answer wrongly.
fn copilot_note(lane: &Lane, pass: &Pass) -> Option<String> {
    if lane.harness.as_deref() != Some("copilot")
        || lane.extra.get("allow_all") != Some(&Value::Bool(true))
        || hosted::host_of(lane) != "local"
    {
        return None;
    }
    let named = [&lane.account, &lane.home]
        .into_iter()
        .find_map(|field| field.as_deref().filter(|a| !a.is_empty()));
    let home = match named {
        Some(home) => PathBuf::from(home),
        None => match pass.copilot_home {
            Some(home) => home.to_path_buf(),
            None => return Some("session-record=account-unnamed".to_owned()),
        },
    };
    let session = match lane.session_id.as_deref().filter(|id| !id.is_empty()) {
        Some(id) => id.to_owned(),
        None => {
            let Some(root) = lane.mail_root.as_deref().filter(|r| !r.is_empty()) else {
                return Some("session-record=worktree-unmatched".to_owned());
            };
            let Ok(cwd) = std::fs::canonicalize(root) else {
                return Some("session-record=store-unreadable".to_owned());
            };
            let since = lane
                .session_since
                .as_deref()
                .and_then(clock::epoch_secs)
                .map(|secs| UNIX_EPOCH + Duration::from_secs(secs));
            match session::lead_at(Harness::Copilot, &home, &cwd, since) {
                Reading::Live(lead) => lead.id,
                Reading::Gone => return Some("session-record=worktree-unmatched".to_owned()),
                Reading::Unreadable { .. } => {
                    return Some("session-record=store-unreadable".to_owned());
                }
            }
        }
    };
    match agent_runtime::context::copilot_record(&home, &session, "", pass.now) {
        Ok(record) => record
            .stop_cause(true)
            .map(|cause| format!("stop-cause={cause}")),
        Err(reason) => Some(format!("session-record={reason}")),
    }
}

/// The wall: the `usage-limit` row keyed to the identity it was judged for,
/// the screen's age against the live process's start, the reset the banner
/// names, the account wall record, the route (the pick, and under `auto`
/// the relaunch) while the reset is ahead and the wake's resume once it
/// passed, then the line once per reported event with the banner window
/// under it; the row keeps the screen's hash, so a resumed turn that ended
/// at the same banner is told once. The state the lane takes for the kind
/// loops: walled where the wall stands, unjudged where it is an older
/// screen or could not be judged; and what the record's wall transition is
/// told.
#[allow(
    clippy::too_many_arguments,
    reason = "the wall's inputs are the observation, the judge's three words, the slice, the pass, the hosts and the sink"
)]
fn wall(
    obs: &Observed,
    kind: WallKind,
    banner: &str,
    source: WallSource,
    slice: &str,
    pass: &Pass,
    hosts: &Hosts,
    cap: usize,
    out: &mut Produced,
) -> (LaneState, WallReading) {
    let lane = &obs.name;
    let walled = LaneState::Walled {
        kind,
        banner: banner.to_owned(),
        source,
    };
    let unjudged = |cause: &str| {
        (
            LaneState::Unjudged {
                cause: cause.to_owned(),
            },
            WallReading::Clear,
        )
    };
    // A rows wall carries the harness's own message; the banner judged a
    // pane wall is the screen's.
    let text = match source {
        WallSource::Rows => obs
            .rows_key
            .as_deref()
            .and_then(|row| serde_json::from_str::<rows::Row>(row).ok())
            .and_then(|row| row.message)
            .unwrap_or_default(),
        WallSource::Pane => banner.to_owned(),
    };
    let hash = hash_of(&text).to_string();
    let prior: Vec<String> = pass
        .baseline
        .get("usage-limit", lane)
        .map(|v| v.split('|').map(str::to_owned).collect())
        .unwrap_or_default();
    let same_banner = prior.get(1).is_some_and(|h| *h == hash);
    let first_seen = if same_banner {
        prior
            .first()
            .and_then(|s| s.parse::<u64>().ok())
            .unwrap_or(pass.now)
    } else {
        pass.now
    };
    let age = match source {
        WallSource::Rows => WallAge::Current,
        WallSource::Pane => match &obs.identity {
            Some(identity) => observe::wall_age(first_seen, &(pass.readers.start_epoch)(identity)),
            None => WallAge::Unjudged {
                cause: "identity-unrecorded",
            },
        },
    };
    match age {
        WallAge::Current => {}
        // The screen predates the live process: its scrollback, not its
        // wall. The row keeps the first sighting, so the comparison holds
        // on every later pass.
        WallAge::Older => return unjudged("wall-predates-process"),
        WallAge::Unjudged { cause } => return unjudged(cause),
    }
    let observed = WallReading::Walled { first_seen };
    let identity = identity_word(obs.identity.as_ref());
    let auth = kind == WallKind::Auth;
    // The reset the banner states decides which event this is: pinned to the
    // first sighting, never to this pass, so a dayless clause names the day
    // the wall was seen on; a login wall has no reset.
    let reset_at = if auth {
        None
    } else {
        reset::key(&text).and_then(|key| {
            let zone = (pass.readers.zone)(key.zone.as_deref())?;
            reset::epoch(&key, first_seen, &zone)
        })
    };
    let passed = reset_at.is_some_and(|at| at <= pass.now);
    let reported = format!(
        "usage-limit{}{}",
        if passed { "-passed" } else { "" },
        if auth { ":auth" } else { "" }
    );
    let quiet = same_banner
        && prior.get(2).is_some_and(|i| *i == identity)
        && prior
            .get(3)
            .is_some_and(|r| *r == reported || (!passed && r == "lane-relaunched"));
    // A resume asked for this wall whose screen has since moved under the
    // same banner: the resumed turn ended at the wall again, told once.
    let screen = hash_of(slice).to_string();
    let rewalled = quiet
        && passed
        && pass.baseline.get(wake::RESUME_KIND, lane).is_some()
        && prior.get(4).is_some_and(|s| *s != screen);
    // The account wall is recorded on every walled pass, the quiet ones
    // included, so a record a write failed to land lands later.
    let account = obs.lane.account.clone().unwrap_or_default();
    let unwritten = pass
        .account_state
        .get()
        .map_err(crate::Error::from)
        .and_then(|root| {
            account_wall::record_account_wall(
                &root,
                &AccountWallWrite {
                    config_dir: account.clone(),
                    reset: reset_at,
                    now: pass.now,
                    first_seen,
                    banner: text.clone(),
                    channel: match source {
                        WallSource::Pane => WallChannel::Pane,
                        WallSource::Rows => WallChannel::Row,
                    },
                },
            )
            .map_err(crate::Error::from)
        })
        .err()
        .map(|e| e.to_string());
    if quiet && !rewalled {
        return (walled, observed);
    }
    let lines = match source {
        WallSource::Rows => text.lines().map(str::to_owned).collect(),
        WallSource::Pane => match banner_payload(slice, banner, cap) {
            Some(lines) => lines,
            // The judge and the payload disagree on where the banner is:
            // nothing is printed and the wall stays unjudged this pass.
            None => return unjudged("banner-missing"),
        },
    };
    let mut notes = Vec::new();
    match reset_at.filter(|_| passed) {
        None => match route(obs, &account, pass, hosts, out, &mut notes) {
            Routed::Relaunched => {
                out.changes.push(set(
                    "usage-limit",
                    lane,
                    format!("{first_seen}|{hash}|{identity}|lane-relaunched"),
                ));
                return (walled, observed);
            }
            Routed::Left => {}
        },
        // A passed reset: the wake resumes the lane it reaches, once per
        // wall, and the note says whether it will.
        Some(_) if rewalled => {
            notes.push("resume walled".to_owned());
            out.changes.push(clear(wake::RESUME_KIND, lane));
        }
        Some(at) if wake::resumable(obs.lane) => {
            notes.push("resume wake".to_owned());
            out.changes.push(set(
                wake::RESUME_KIND,
                lane,
                format!("usage-limit|{identity}|{at}"),
            ));
        }
        Some(_) => notes.push("resume unreached".to_owned()),
    }
    // The line's body: the lane, the claimed account where the record names
    // one, `resets=` where read, `wall_kind=auth`.
    let mut line = lane.clone();
    if !account.is_empty() {
        line.push(' ');
        line.push_str(&account);
    }
    if let Some(at) = reset_at {
        line.push_str(" resets=");
        line.push_str(&clock::iso_utc(at));
    }
    if auth {
        line.push_str(" wall_kind=auth");
    }
    out.events.push(Event::UsageLimit { passed, line });
    out.events.extend(notes.into_iter().map(Event::Tail));
    if let Some(cause) = unwritten {
        out.events.push(Event::Tail(format!(
            "account-wall: record-unwritten config_dir={account} cause={cause}"
        )));
    }
    out.events.extend(payload(lines));
    out.changes.push(set(
        "usage-limit",
        lane,
        format!("{first_seen}|{hash}|{identity}|{reported}|{screen}"),
    ));
    (walled, observed)
}

/// What the wall route did with a lane first read walled this pass.
enum Routed {
    /// The relaunch started and `lane-relaunched` is out.
    Relaunched,
    /// The wall is left to the overseer; `notes` carry the pick's answer
    /// and any refusal.
    Left,
}

/// The usage-limit route: the account walk's pick for the record's model with
/// the spent account excluded, its answer the line under the event; under
/// `ORCH_WALL_RELAUNCH=auto` a qualifying account takes the lane through the
/// record's own relaunch, started detached through the one runner, its marker
/// written first for the outcome reader. A hosted lane whose kind declares a
/// local pane has its harness stopped through the provider first (`lane-host
/// stop --item --harness`), and a stop not confirmed refuses the relaunch as
/// `stop-failed` with the status, or `stop-unanswered` where it gave no
/// answer. A relaunch refused after the pick is said
/// under the event, after the pick's line, and never asked again this pass.
fn route(
    obs: &Observed,
    account: &str,
    pass: &Pass,
    hosts: &Hosts,
    out: &mut Produced,
    notes: &mut Vec<String>,
) -> Routed {
    let lane = &obs.name;
    let refused = |notes: &mut Vec<String>, reason: &str| {
        notes.push(format!("wall-relaunch-refused lane={lane} reason={reason}"));
        Routed::Left
    };
    // A record naming no harness or model, or no account, asks no pick and
    // leaves the wall to the overseer with the reason under the event.
    let harness = obs.lane.harness.as_deref().and_then(Harness::parse);
    let model = obs.lane.model.as_deref().unwrap_or("");
    let (Some(harness), false) = (harness, model.is_empty()) else {
        return refused(notes, "record-unnamed");
    };
    if account.is_empty() {
        return refused(notes, "account-unknown");
    }
    let to = match (pass.route.pick)(harness, model, account) {
        Pick::Lane(to) => {
            notes.push(format!("pick lane={to}"));
            to
        }
        Pick::None => {
            notes.push("pick none".to_owned());
            return Routed::Left;
        }
        Pick::Unjudged { cause } => {
            notes.push(format!("pick unjudged {cause}"));
            return Routed::Left;
        }
    };
    match pass.route.relaunch {
        WallRelaunch::Auto => {}
        WallRelaunch::Ask => return Routed::Left,
    }
    // The spent account is never relaunched onto before its reset.
    if account_wall::canon(&to) == account_wall::canon(account) {
        return refused(notes, "spent-account");
    }
    let relaunch = match relaunch_request(
        obs.lane,
        harness,
        &to,
        account,
        pass.state_dir,
        pass.scripts,
        pass.session,
    ) {
        Ok(request) => request,
        Err(cause) => return refused(notes, &format!("context-unavailable cause={cause}")),
    };
    let host = hosted::host_of(obs.lane);
    if host != "local" {
        match hosts.of(obs.lane) {
            Ok(Capabilities {
                pane: PaneKind::Local,
                ..
            }) => {
                // A stop refused or unanswered alike may leave the harness
                // running, so neither relaunches beside it this pass.
                if let Err(hosted::Asked::Failed(cause) | hosted::Asked::Unknown(cause)) =
                    hosted::stop(pass.scripts, host, &obs.lane.item, harness.name())
                {
                    return refused(notes, &cause);
                }
            }
            Ok(Capabilities {
                pane: PaneKind::Verb,
                ..
            }) => {}
            Err(cause) => return refused(notes, &format!("stop-unjudged cause={cause}")),
        }
    }
    let marker = wall::relaunch_marker_path(watch_state_dir(pass.claim_store), lane);
    let log = pass
        .state_dir
        .join(format!("wall-relaunch-{}.log", obs.lane.item));
    if let Err(e) = wall::write_relaunch_marker(&marker, &obs.lane.item, pass.now, &log) {
        return refused(
            notes,
            &format!("marker-unwritten path={} cause={e}", marker.display()),
        );
    }
    let relaunch = Relaunch {
        item: obs.lane.item.clone(),
        window: lane.clone(),
        to: to.clone(),
        spent: account.to_owned(),
        cwd: relaunch.cwd,
        session: relaunch.session,
        args: relaunch.args,
        marker,
        log: log.clone(),
    };
    if let Err(cause) = (pass.route.start)(&relaunch) {
        return refused(notes, &format!("launch-failed cause={cause}"));
    }
    out.events.push(Event::LaneRelaunched {
        item: obs.lane.item.clone(),
        lane: to,
        from: account.to_owned(),
    });
    out.events
        .push(Event::Tail(format!("log={}", log.display())));
    Routed::Relaunched
}

/// The relaunch's parts before the marker: the checkout, the session and
/// the runtime's own argv.
pub(crate) struct Recovery {
    pub(crate) cwd: PathBuf,
    pub(crate) session: String,
    pub(crate) args: Vec<String>,
}

/// The permission choice a relaunch keeps: the record's `permission`, the
/// words of the launch line the runtime launched it with; on a record no
/// runtime launch wrote, the first spelling of the harness's permission
/// table among the `recovery.flags` an earlier launcher recorded (a Claude
/// line's words end at `--`), a `FLAG=VALUE` spelling given as its two
/// words. `Ok(None)` is a record stating no choice, which runs the settings'
/// posture; `Err` is a permission flag whose value the table lacks, a
/// choice no launch line carries faithfully, refused before anything is
/// stopped.
fn recorded_permission(lane: &Lane, harness: Harness) -> Result<Option<String>, String> {
    if let Some(word) = lane
        .extra
        .get("permission")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|w| !w.is_empty())
    {
        return Ok(Some(word.to_owned()));
    }
    let words: Vec<&str> = lane
        .extra
        .get("recovery")
        .and_then(|r| r.get("flags"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .split_whitespace()
        .take_while(|w| harness != Harness::Claude || *w != "--")
        .collect();
    let spellings = harness.permission_spellings();
    for (i, word) in words.iter().enumerate() {
        for (spelling, _) in &spellings {
            if word == spelling {
                return Ok(Some((*spelling).to_owned()));
            }
            if let Some((flag, value)) = spelling.split_once('=')
                && *word == flag
                && words.get(i + 1) == Some(&value)
            {
                return Ok(Some(format!("{flag} {value}")));
            }
        }
        let valued = spellings
            .iter()
            .filter_map(|(spelling, _)| spelling.split_once('='))
            .any(|(flag, _)| *word == flag || word.starts_with(&format!("{flag}=")));
        if valued {
            return Err("permission-choice-unrepresentable".to_owned());
        }
    }
    Ok(None)
}

/// What a relaunch from a lane record is composed with: the files' `stem`
/// beside the state, the account it lands on and the one it excludes, where
/// either is named, the brief it starts on and the `no_landing` ground the
/// close that retires the predecessor carries.
pub(crate) struct Composition<'a> {
    pub(crate) stem: &'a str,
    pub(crate) account: Option<&'a str>,
    pub(crate) exclude: Option<&'a str>,
    pub(crate) brief: fn(&Lane, Harness) -> Result<String, String>,
    pub(crate) ground: Value,
}

/// A composed relaunch: the checkout it runs from, the tmux session an
/// earlier launcher recorded, and its two request files in the order the
/// runtime's entry applies them.
pub(crate) struct Composed {
    pub(crate) cwd: PathBuf,
    pub(crate) session: Option<String>,
    pub(crate) close: PathBuf,
    pub(crate) launch: PathBuf,
}

/// The record's own relaunch as two requests the runtime's entry applies in
/// order from the lane's checkout: the predecessor retired through the
/// close route on the composition's `no-landing` ground (its harness idle
/// under its recorded identity, the item's work kept), then `launch-lane`
/// with the record's harness, model, effort, host, tracker and repository,
/// its refresh word and permission choice ([`recorded_permission`]), the
/// composition's accounts and brief. The checkout is the one the launch ran
/// from (`checkout` on a hosted record, whose `mail_root` is its host's;
/// the `recovery.cwd` an earlier launcher recorded; else `mail_root`). A
/// record naming no class or no reason (`class-unrecorded`: the launch
/// keeps the record's pair and would refuse once the close had retired the
/// predecessor), whose checkout is gone, or whose provider is spelled
/// relative to nothing, refuses before anything is stopped. `Err` is the
/// cause word.
#[allow(
    clippy::disallowed_methods,
    reason = "a relaunch's request and brief files, beside the state, written before the detached relaunch starts"
)]
pub(crate) fn compose_relaunch(
    lane: &Lane,
    harness: Harness,
    how: &Composition,
    state_dir: &Path,
) -> Result<Composed, String> {
    if lane.class.is_none()
        || lane
            .class_reason
            .as_deref()
            .is_none_or(|r| r.trim().is_empty())
    {
        return Err("class-unrecorded".to_owned());
    }
    let recovery = lane.extra.get("recovery").and_then(Value::as_object);
    let field = |key: &str| recovery.and_then(|r| r.get(key));
    let cwd = lane
        .extra
        .get("checkout")
        .and_then(Value::as_str)
        .or_else(|| field("cwd").and_then(Value::as_str))
        .or(lane.mail_root.as_deref())
        .unwrap_or("")
        .trim();
    if cwd.is_empty() {
        return Err("checkout-unrecorded".to_owned());
    }
    let host = lane.host.as_deref().unwrap_or("local");
    if !(host == "local" || host == CLOUD_KIND || host.starts_with('/')) {
        return Err("provider-relative".to_owned());
    }
    let cwd = std::fs::canonicalize(cwd).map_err(|_| "checkout-unavailable".to_owned())?;
    let refresh = field("refresh")
        .and_then(Value::as_bool)
        .or_else(|| lane.extra.get("refresh").and_then(Value::as_bool))
        .unwrap_or(false);
    let permission = recorded_permission(lane, harness)?;
    let stem = state_dir
        .join(format!("{}-{}", how.stem, lane.item))
        .display()
        .to_string();
    let brief = PathBuf::from(format!("{stem}.md"));
    std::fs::write(&brief, (how.brief)(lane, harness)?)
        .map_err(|e| format!("brief-unwritten path={} cause={e}", brief.display()))?;
    let close = PathBuf::from(format!("{stem}.close.json"));
    let retire = json!({
        "op": "close-owned-resources",
        "item": lane.item,
        "no_landing": how.ground.clone(),
    });
    std::fs::write(&close, retire.to_string())
        .map_err(|e| format!("request-unwritten path={} cause={e}", close.display()))?;
    let mut request = json!({
        "op": "launch-lane",
        "item": lane.item,
        "harness": harness.name(),
        "mail_root": cwd.display().to_string(),
        "refresh": refresh,
        "brief_file": brief.display().to_string(),
    });
    for (key, value) in [("account", how.account), ("exclude_account", how.exclude)] {
        if let Some(value) = value {
            request[key] = json!(value);
        }
    }
    for (key, value) in [
        ("tracker", &lane.tracker),
        ("repo", &lane.repo),
        ("model", &lane.model),
        ("effort", &lane.effort),
        ("host", &lane.host),
        ("kind", &lane.kind),
    ] {
        if let Some(value) = value.as_deref().filter(|v| !v.is_empty()) {
            request[key] = json!(value);
        }
    }
    if let Some(permission) = permission {
        request["permission"] = json!(permission);
    }
    let file = PathBuf::from(format!("{stem}.json"));
    std::fs::write(&file, request.to_string())
        .map_err(|e| format!("request-unwritten path={} cause={e}", file.display()))?;
    Ok(Composed {
        cwd,
        session: field("session")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_owned),
        close,
        launch: file,
    })
}

/// The wall's relaunch: the record's own relaunch ([`compose_relaunch`])
/// on the picked account with the spent account excluded, the start brief
/// and the `usage-limit` ground, run as one shell line; the session is the
/// one an earlier launcher recorded, else the watch's.
pub(crate) fn relaunch_request(
    lane: &Lane,
    harness: Harness,
    to: &str,
    spent: &str,
    state_dir: &Path,
    scripts: &Path,
    session: Option<&str>,
) -> Result<Recovery, String> {
    let Composed {
        cwd,
        session: recorded,
        close,
        launch: file,
    } = compose_relaunch(
        lane,
        harness,
        &Composition {
            stem: "wall-relaunch",
            account: Some(to),
            exclude: Some(spent),
            brief: start_brief,
            ground: json!({"reason": "usage-limit", "source": "wall-route"}),
        },
        state_dir,
    )?;
    // The two requests in order through the one shell word, each exiting by
    // its effect's outcome, never by its admission alone: the launch is
    // asked only once the close's effect did not fail (an unconfirmed close
    // leaves the launch's own transition to refuse a lane whose harness
    // still runs), and the launch's status is the chain's: a replacement
    // whose effect failed, or whose outcome is still open, leaves the status
    // the outcome reader says or settles from the launch's intent.
    let args = vec![
        "sh".to_owned(),
        "-c".to_owned(),
        "\"$1\" --state-dir \"$2\" op --fleet --effect-exit --request \"$3\"; rc=$?; [ \"$rc\" -eq 0 ] || [ \"$rc\" -eq 75 ] || exit \"$rc\"; exec \"$1\" --state-dir \"$2\" op --fleet --effect-exit --request \"$4\"".to_owned(),
        "wall-relaunch".to_owned(),
        scripts.join("orch-runtime").display().to_string(),
        state_dir.display().to_string(),
        close.display().to_string(),
        file.display().to_string(),
    ];
    Ok(Recovery {
        cwd,
        session: recorded
            .or_else(|| session.map(str::to_owned))
            .unwrap_or_default(),
        args,
    })
}

/// `start-stalled`: a lane `running_at` for `start_stall` seconds with no
/// status file under its mail root, repeated every `mark_repeat` passes while
/// the file is missing; a file that stands ends it, and one that cannot be
/// read settles nothing. The file is read where the lane's kind keeps it: on
/// this disk for a local kind, through the provider for a `files=verb` kind (a
/// fetch that failed is `start-stall-unread`, the pass's failure and no line;
/// a lane whose worktree the host no longer has is left), and a `files=none`
/// kind, a cloud session, by its pull request (`hosted::cloud_start_stall`).
fn start_stall(lane: &Lane, pass: &Pass, hosts: &Hosts, out: &mut Produced) {
    let name = lane_name(lane);
    let Some(running) = lane.running_at.as_deref().and_then(clock::epoch_secs) else {
        return;
    };
    let Some(root) = lane.mail_root.as_deref() else {
        return;
    };
    let Ok(caps) = hosts.of(lane) else {
        return;
    };
    if caps.files == Files::None {
        hosted::cloud_start_stall(lane, pass, out);
        return;
    }
    let prior = pass
        .baseline
        .get("start-stalled", &name)
        .unwrap_or_default();
    if prior == format!("{running}|seen") {
        return;
    }
    let file = match caps.files {
        Files::Local => {
            let path = state::status_file(Path::new(root), &lane.item);
            match (pass.readers.status_file)(&path) {
                Reading::Live(()) => Answer::Live(()),
                Reading::Gone => Answer::Gone,
                Reading::Unreadable { cause } => Answer::Unreadable {
                    cause: cause.to_owned(),
                },
            }
        }
        Files::Verb => match hosted::status_file(pass.scripts, lane) {
            Answer::Live(_) => Answer::Live(()),
            Answer::Gone => match hosted::worktree(pass.scripts, lane) {
                // The worktree the lane's own close-out removed writes no
                // status file: the merged check's lane, not a stalled one.
                Answer::Gone => return,
                Answer::Live(()) => Answer::Gone,
                Answer::Unreadable { cause } => Answer::Unreadable { cause },
            },
            Answer::Unreadable { cause } => Answer::Unreadable { cause },
        },
        Files::None => return,
    };
    match file {
        Answer::Live(()) => {
            out.changes
                .push(set("start-stalled", &name, format!("{running}|seen")));
            return;
        }
        Answer::Gone => {}
        Answer::Unreadable { cause } => {
            if caps.files == Files::Verb {
                fail(
                    out,
                    format!("start-stall-unread item={} cause={cause}", lane.item),
                );
            }
            return;
        }
    }
    let age = pass.now.saturating_sub(running);
    if age < pass.settings.start_stall.as_secs() {
        out.changes.push(clear("start-stalled", &name));
        return;
    }
    let mut parts = prior.split('|');
    let (prior_running, passes) = (parts.next().unwrap_or(""), parts.next());
    let passes = match passes.and_then(|p| p.parse::<u32>().ok()) {
        Some(p) if prior_running == running.to_string() => {
            let next = p + 1;
            if next < pass.settings.mark_repeat {
                next
            } else {
                0
            }
        }
        Some(_) | None => 0,
    };
    if passes == 0 {
        out.events.push(Event::StartStalled {
            item: name.clone(),
            age,
        });
    }
    out.changes
        .push(set("start-stalled", &name, format!("{running}|{passes}")));
}

/// The stray sweep: every window of the fleet session whose pane no lane
/// record, controller record, open intent, receipt or own pane names is
/// reported once per pane key and never adopted or closed. An unreadable
/// listing or receipt set reports nothing.
fn strays(session: &str, pass: &Pass, out: &mut Produced) {
    let socket = pass
        .fleet
        .overseer
        .as_ref()
        .and_then(agent_runtime::effects::overseer_socket);
    let socket = socket.as_deref().or(pass.server);
    let (server, windows) = match (pass.readers.windows)(socket, session) {
        Reading::Live(listing) => listing,
        Reading::Gone | Reading::Unreadable { .. } => return,
    };
    let receipts = match (pass.readers.receipts)(pass.state_dir) {
        Reading::Live(receipts) => receipts,
        Reading::Unreadable { cause: _ } | Reading::Gone => return,
    };
    let mut known: BTreeSet<String> = receipts.into_iter().collect();
    known.extend(pass.own_panes.iter().cloned());
    for lane in &pass.fleet.lanes {
        if let Some(pane) = lane.launch.as_ref().and_then(|l| l.pane.clone()) {
            known.insert(pane);
        }
    }
    if let Some(pane) = pass
        .fleet
        .overseer
        .as_ref()
        .and_then(|o| o.extra.get("pane"))
        .and_then(|p| p.as_str())
    {
        known.insert(pane.to_owned());
    }
    for intent in pass.fleet.intents.iter().filter(|i| i.open()) {
        let pane = match &intent.phase {
            Some(Phase::Opening { opening }) => opening.pane.clone(),
            Some(
                Phase::WindowOpened { opened }
                | Phase::Delivering { opened, .. }
                | Phase::Delivered { opened, .. }
                | Phase::IdentityRead { opened, .. },
            ) => Some(opened.pane.clone()),
            Some(Phase::CloudCreate { .. } | Phase::Preparing { .. }) | None => None,
        };
        known.extend(pane);
    }
    let mut seen = BTreeSet::new();
    for window in windows {
        if known.contains(&window.pane) {
            continue;
        }
        let key = format!("{server} {}", window.pane);
        seen.insert(key.clone());
        if pass.baseline.get("stray-window", &key).is_none() {
            out.events.push(Event::StrayWindow {
                pane: window.pane.clone(),
                window: window.window.clone(),
                server,
                name: window.name.clone(),
            });
            out.changes
                .push(set("stray-window", &key, "reported".to_owned()));
        }
    }
    for key in pass.baseline.identities("stray-window") {
        if !seen.contains(&key) {
            out.changes.push(clear("stray-window", &key));
        }
    }
}

/// `lane-long`: a running or parked lane, on this disk or hosted, `lane_age`
/// past its record's `launched_at`, reported once per age interval with the
/// counters its records give, the row keyed by the item and pruned only once
/// no record names it, so the gap a relaunch or a handoff leaves keeps the
/// reported interval. A hosted lane's `Step` line and records are read through
/// the provider; a `files=none` kind's stage is `none` and its counts
/// `unread`.
fn lane_long(pass: &Pass, hosts: &Hosts, out: &mut Produced) {
    let bound = pass.settings.lane_age.as_secs();
    let recorded: BTreeSet<&str> = pass.fleet.lanes.iter().map(|l| l.item.as_str()).collect();
    for identity in pass.baseline.identities("lane-long") {
        if !recorded.contains(identity.as_str()) {
            out.changes.push(clear("lane-long", &identity));
        }
    }
    for lane in &pass.fleet.lanes {
        let aged = match lane.status {
            LaneStatus::Running | LaneStatus::Parked => true,
            LaneStatus::Preparing | LaneStatus::Stopped | LaneStatus::Done => false,
        };
        let Some(launched) = aged
            .then(|| lane.launched_at.as_deref().and_then(clock::epoch_secs))
            .flatten()
        else {
            continue;
        };
        let age = pass.now.saturating_sub(launched);
        if age < bound {
            continue;
        }
        let interval = age / bound;
        let prior = pass
            .baseline
            .get("lane-long", &lane.item)
            .unwrap_or_default();
        // A released watch's row holds the launch alone after its first report.
        let prior = if prior == launched.to_string() {
            format!("{launched}|1")
        } else {
            prior.to_owned()
        };
        if prior == format!("{launched}|{interval}") {
            continue;
        }
        let files = hosts.of(lane).ok().map(|caps| caps.files);
        let (counters, stage) = lane_counts(lane, files, pass.state_dir, pass.scripts, out);
        out.events.push(Event::LaneLong {
            item: lane.item.clone(),
            age,
            review_rounds: counters.review_rounds,
            fix_receipts: counters.fix_receipts,
            validation_runs: counters.validation_runs,
            restacks: counters.restacks,
            repeated_class_rounds: counters.repeated_class_rounds,
            stage,
        });
        out.changes.push(set(
            "lane-long",
            &lane.item,
            format!("{launched}|{interval}"),
        ));
    }
}

/// The `Step` line of a local lane's status file: `unread` where the read
/// failed, `none`
/// where the lane writes no file or its file names no step; the line bare
/// or as a list item, its value after the colon.
fn lane_step(lane: &Lane) -> String {
    let Some(root) = lane.mail_root.as_deref() else {
        return "none".to_owned();
    };
    let path = state::status_file(Path::new(root), &lane.item);
    match std::fs::read_to_string(&path) {
        Ok(text) => step_of(&text),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => "none".to_owned(),
        Err(_) => "unread".to_owned(),
    }
}

/// The first `step:` line of a status file, case-insensitive, an optional
/// `-` or `*` list marker before it, the text after the colon and its
/// leading blanks; `none` without one.
pub fn step_of(text: &str) -> String {
    for line in text.lines() {
        let lower = line.to_ascii_lowercase();
        let body = lower
            .strip_prefix('-')
            .or_else(|| lower.strip_prefix('*'))
            .filter(|rest| rest.starts_with([' ', '\t']))
            .map(|rest| rest.trim_start_matches([' ', '\t']))
            .unwrap_or(lower.as_str());
        if !body.starts_with("step:") {
            continue;
        }
        let Some(at) = line.find(':') else { continue };
        let value = line[at + 1..].trim_start_matches([' ', '\t']);
        return if value.is_empty() {
            "none".to_owned()
        } else {
            value.to_owned()
        };
    }
    "none".to_owned()
}

/// The five counts of the `lane-long` line, each a number or `unread`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Counters {
    pub review_rounds: String,
    pub fix_receipts: String,
    pub validation_runs: String,
    pub restacks: String,
    pub repeated_class_rounds: String,
}

impl Counters {
    pub fn unread() -> Counters {
        let unread = || "unread".to_owned();
        Counters {
            review_rounds: unread(),
            fix_receipts: unread(),
            validation_runs: unread(),
            restacks: unread(),
            repeated_class_rounds: unread(),
        }
    }
}

/// The five counts and the stage of the `lane-long` line, read where the
/// lane's files are: under its worktree on this disk, through its host's
/// `cat`, or nowhere for a kind that keeps none (`files=none`). A parked
/// lane's disk is not asked, and a host whose capability line could not be
/// read counts nothing.
fn lane_counts(
    lane: &Lane,
    files: Option<Files>,
    state_dir: &Path,
    scripts: &Path,
    out: &mut Produced,
) -> (Counters, String) {
    match (lane.status, files) {
        (LaneStatus::Parked, _) => (Counters::unread(), "parked".to_owned()),
        (
            LaneStatus::Running | LaneStatus::Preparing | LaneStatus::Stopped | LaneStatus::Done,
            Some(Files::Local),
        ) => (lane_counters(lane, state_dir, out), lane_step(lane)),
        (
            LaneStatus::Running | LaneStatus::Preparing | LaneStatus::Stopped | LaneStatus::Done,
            Some(Files::Verb),
        ) => (
            hosted::counters(scripts, lane, out),
            hosted::step(scripts, lane),
        ),
        (
            LaneStatus::Running | LaneStatus::Preparing | LaneStatus::Stopped | LaneStatus::Done,
            Some(Files::None),
        ) => (Counters::unread(), "none".to_owned()),
        // A host whose line could not be read, which the duty's pass says once.
        (
            LaneStatus::Running | LaneStatus::Preparing | LaneStatus::Stopped | LaneStatus::Done,
            None,
        ) => (Counters::unread(), "unread".to_owned()),
    }
}

/// The counters of a running lane: the item's own workflow state in the
/// state directory its checkout names ([`lane_state_dir`]), or under the
/// fleet's where the record names no worktree on this disk; the
/// validation run index under the worktree; a state the lane has not
/// written, or one that cannot be read, counts nothing, and a checkout
/// whose files could not be read says so.
fn lane_counters(lane: &Lane, state_dir: &Path, out: &mut Produced) -> Counters {
    // The worktree the record names, read three-valued: a root this reader
    // cannot read counts nothing.
    let root = match lane.mail_root.as_deref().map(Path::new) {
        None => None,
        Some(root) => match std::fs::metadata(root) {
            Ok(meta) if meta.is_dir() => Some(root),
            Ok(_) => None,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
            Err(_) => return Counters::unread(),
        },
    };
    let runs = root
        .map(|root| root.join("tmp").join("validation-runs"))
        .and_then(|path| std::fs::read_to_string(path).ok())
        .and_then(|text| validation_runs_of(&text));
    let state_dir = match root {
        None => state_dir.to_path_buf(),
        Some(root) => match lane_state_dir(root) {
            Ok(dir) => dir,
            Err(cause) => {
                fail(
                    out,
                    format!("lane-long-rounds-unread item={} cause={cause}", lane.item),
                );
                return Counters::unread();
            }
        },
    };
    match item_doc(&state::item_path(&state_dir, &lane.item)) {
        Reading::Live(doc) => counters_of(&doc, runs).unwrap_or_else(Counters::unread),
        Reading::Gone | Reading::Unreadable { .. } => Counters::unread(),
    }
}

/// The state directory a local checkout's own files name, as the checkout's
/// `workflow-state` resolves it: its settings files and private env file
/// (`settings::state_dir_named`), a relative directory under the common
/// root its `.git` names (a linked worktree's gitfile; a `.git` directory,
/// or none, is the checkout's own root), so a worktree's state is where its
/// main checkout keeps it. Read off the root the record names alone, never
/// through a `git` run: a run would carry this process's environment and
/// walk up from the root into whatever repository holds it.
fn lane_state_dir(root: &Path) -> Result<PathBuf, String> {
    let gitfile = root.join(".git");
    let unread = |cause: String| format!("gitfile-unread path={} {cause}", gitfile.display());
    let common = match std::fs::metadata(&gitfile) {
        Ok(meta) if meta.is_dir() => root.to_path_buf(),
        Ok(_) => {
            let text = std::fs::read_to_string(&gitfile)
                .map_err(|e| unread(format!("cause={:?}", e.kind())))?;
            marker::git_dirs_of(&text)
                .and_then(|(_, common)| common.parent().map(Path::to_path_buf))
                .ok_or_else(|| unread("cause=no-linked-worktree".to_owned()))?
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => root.to_path_buf(),
        Err(e) => return Err(unread(format!("cause={:?}", e.kind()))),
    };
    let read = |path: &Path| agent_runtime::settings::read_text(path);
    let dir = settings::state_dir_named(root, &read).map_err(|e| e.to_string())?;
    Ok(if dir.is_absolute() {
        dir
    } else {
        common.join(dir)
    })
}

/// The item's workflow state as the counts read it: the file's JSON object,
/// whatever its shape; `Gone` where the lane has written none, unreadable
/// where the file is no object.
pub(super) fn item_doc(path: &Path) -> Reading<Document> {
    let unreadable = Reading::Unreadable {
        cause: "state-unreadable",
    };
    match std::fs::read_to_string(path) {
        Ok(text) => doc_of(&text).map_or(unreadable, Reading::Live),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Reading::Gone,
        Err(_) => unreadable,
    }
}

/// An item state's text as its JSON object; `None` for text that is no
/// object.
pub(super) fn doc_of(text: &str) -> Option<Document> {
    match serde_json::from_str::<Value>(text) {
        Ok(Value::Object(doc)) => Some(doc),
        Ok(
            Value::Null | Value::Bool(_) | Value::Number(_) | Value::String(_) | Value::Array(_),
        )
        | Err(_) => None,
    }
}

/// The run count of the validation runner's start inventory
/// (`lane_item_validation_runs`): the `dev-validate-runs-v1` header, one
/// unique `dev-validate-<id>` per line, a final newline; any other shape
/// is unread.
pub fn validation_runs_of(text: &str) -> Option<usize> {
    let rows: Vec<&str> = text.split('\n').collect();
    let (Some(first), Some(last)) = (rows.first(), rows.last()) else {
        return None;
    };
    if *first != "dev-validate-runs-v1" || !last.is_empty() {
        return None;
    }
    let runs = &rows[1..rows.len() - 1];
    let well_formed = runs.iter().all(|r| {
        r.strip_prefix("dev-validate-").is_some_and(|id| {
            !id.is_empty() && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
        })
    });
    let unique: BTreeSet<&&str> = runs.iter().collect();
    (well_formed && unique.len() == runs.len()).then_some(runs.len())
}

/// The counts the `lane_state_rounds` read from the item's workflow state:
/// review rounds as the first panel, the re-review cycles and the
/// comment-review iterations; fix receipts as the `stages` of kind `fix`,
/// unread without a `stages` list; the restacks; repeated class rounds as the
/// later distinct patch commits that repeat an equal cause or a shared
/// location or owner key, unread without any patch. `None` where a field has a
/// shape the count cannot read.
pub fn counters_of(doc: &Document, validation_runs: Option<usize>) -> Option<Counters> {
    fn count(value: Option<&Value>) -> Option<u64> {
        match value {
            None | Some(Value::Null | Value::Bool(false)) => Some(0),
            Some(Value::Number(n)) => n.as_u64(),
            Some(Value::Bool(true) | Value::String(_) | Value::Array(_) | Value::Object(_)) => None,
        }
    }
    let first_panel = match doc.get("first_panel") {
        None | Some(Value::Null | Value::Bool(false)) => 0,
        Some(
            Value::Bool(true)
            | Value::Number(_)
            | Value::String(_)
            | Value::Array(_)
            | Value::Object(_),
        ) => 1,
    };
    let review = doc.get("pr_comment_review").and_then(Value::as_object);
    let rounds = first_panel
        + count(doc.get("rereview_cycles"))?
        + count(review.and_then(|r| r.get("iterations")))?;
    let fixes = match doc.get("stages") {
        None | Some(Value::Null) => "unread".to_owned(),
        Some(Value::Array(stages)) => stages
            .iter()
            .filter(|s| s.get("kind").and_then(Value::as_str) == Some("fix"))
            .count()
            .to_string(),
        Some(Value::Bool(_) | Value::Number(_) | Value::String(_) | Value::Object(_)) => {
            return None;
        }
    };
    let restacks = count(doc.get("restacks"))?;
    let patches: Vec<&Value> = match review.and_then(|r| r.get("patched_causes")) {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(patches)) => patches.iter().collect(),
        Some(Value::Bool(_) | Value::Number(_) | Value::String(_) | Value::Object(_)) => {
            return None;
        }
    };
    let repeated = if patches.is_empty() {
        "unread".to_owned()
    } else {
        let mut seen: Vec<&Value> = Vec::new();
        let mut repeated: BTreeSet<String> = BTreeSet::new();
        for patch in patches {
            let commit = patch.get("commit");
            if seen.iter().any(|earlier| {
                earlier.get("commit") != commit
                    && (earlier.get("cause") == patch.get("cause")
                        || shared_cause_key(earlier, patch))
            }) {
                repeated.insert(commit.map(Value::to_string).unwrap_or_default());
            }
            seen.push(patch);
        }
        repeated.len().to_string()
    };
    Some(Counters {
        review_rounds: rounds.to_string(),
        fix_receipts: fixes,
        validation_runs: validation_runs.map_or_else(|| "unread".to_owned(), |n| n.to_string()),
        restacks: restacks.to_string(),
        repeated_class_rounds: repeated,
    })
}

/// A cause key (`lib/cause-keys.jq`, `cause_key`): a trimmed string that
/// is not empty, `TBD` or `general`.
fn cause_key(value: Option<&Value>) -> Option<String> {
    let text = value?.as_str()?.trim();
    (!text.is_empty() && text != "TBD" && text != "general").then(|| text.to_owned())
}

/// The location and owner keys of a patch (`cause_keys`): from its `text`
/// where it carries one (the header's third `|` field on, an `Owner:` line
/// after), else its `location` and `owner` fields.
fn cause_keys(patch: &Value) -> Vec<String> {
    let mut keys: Vec<String> = Vec::new();
    let (location, owner) = match patch.get("text").and_then(Value::as_str) {
        Some(text) => {
            let mut lines = text.split('\n');
            let header = lines.next().unwrap_or("");
            let location: Vec<&str> = header.split('|').skip(2).collect();
            let owner = lines
                .find_map(|l| l.strip_prefix("Owner:"))
                .map(|o| Value::String(o.to_owned()));
            (Some(Value::String(location.join("|"))), owner)
        }
        None => (patch.get("location").cloned(), patch.get("owner").cloned()),
    };
    for key in [cause_key(location.as_ref()), cause_key(owner.as_ref())]
        .into_iter()
        .flatten()
    {
        if !keys.contains(&key) {
            keys.push(key);
        }
    }
    keys
}

/// Whether two patches share a location or owner key (`shared_cause_key`).
fn shared_cause_key(a: &Value, b: &Value) -> bool {
    let keys = cause_keys(a);
    cause_keys(b).iter().any(|k| keys.contains(k))
}

/// The reset clause a usage-limit banner states: what
/// shape it comes in and what instant it names given the moment the banner was
/// first seen. The three tails in order, dated (`resets Sep 6, 4pm`, Codex's
/// `Try again at Sep 6th, 2026 4:30 PM`), weekday (`resets Thursday 4am`) and
/// clock (`resets 9:50am (America/Los_Angeles)`, `resets 21:00`); a duration,
/// a weekday with no clock and a bare number name no instant.
pub mod reset {
    use jiff::civil::{Date, DateTime};
    use jiff::tz::{AmbiguousOffset, TimeZone};
    use jiff::{Span, Timestamp};

    const MONTHS: [&str; 12] = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    const WEEKDAYS: [&str; 7] = [
        "Monday",
        "Tuesday",
        "Wednesday",
        "Thursday",
        "Friday",
        "Saturday",
        "Sunday",
    ];

    /// Which tail matched and the day it carries.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub enum Day {
        /// A month and day, the year where printed.
        Dated {
            month: u8,
            day: u8,
            year: Option<i16>,
        },
        /// A weekday, Monday 1 to Sunday 7.
        Weekday(u8),
        /// A clock alone: today or tomorrow from the sighting.
        Clock,
    }

    /// The wall a banner names, as the key: the tail, the clock in 24-hour
    /// form and the zone named in parentheses, if any.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct Key {
        pub day: Day,
        pub hour: u8,
        pub minute: u8,
        pub zone: Option<String>,
    }

    /// A clock as the `USAGE_RESET_CLOCK` reads it: one or two digits, an
    /// optional `:MM`, an optional `:SS`, an optional blank, an optional
    /// meridiem. `None` without a clock at all; the minutes and meridiem are
    /// checked by the caller.
    fn clock(text: &str) -> Option<(u32, Option<u8>, Option<char>, usize)> {
        let bytes = text.as_bytes();
        let digits = bytes
            .iter()
            .take(2)
            .take_while(|b| b.is_ascii_digit())
            .count();
        if digits == 0 {
            return None;
        }
        let hour: u32 = text[..digits].parse().ok()?;
        let mut at = digits;
        let mut minute = None;
        if bytes.get(at) == Some(&b':')
            && bytes.len() >= at + 3
            && bytes[at + 1..at + 3].iter().all(u8::is_ascii_digit)
        {
            minute = text[at + 1..at + 3].parse::<u8>().ok();
            at += 3;
        }
        if minute.is_some()
            && bytes.get(at) == Some(&b':')
            && bytes.len() >= at + 3
            && bytes[at + 1..at + 3].iter().all(u8::is_ascii_digit)
        {
            at += 3;
        }
        let mut meridiem = None;
        let mut probe = at;
        if bytes.get(probe).is_some_and(|b| b.is_ascii_whitespace()) {
            probe += 1;
        }
        if let Some(m) = bytes.get(probe..probe + 2)
            && matches!(m[0], b'a' | b'A' | b'p' | b'P')
            && matches!(m[1], b'm' | b'M')
        {
            meridiem = Some(m[0].to_ascii_lowercase() as char);
            at = probe + 2;
        }
        Some((hour, minute, meridiem, at))
    }

    /// The text after each lead, `resets` or `Try again at` and its blanks,
    /// in the order they stand on the line.
    fn after_leads(line: &str) -> Vec<&str> {
        let mut out = Vec::new();
        for lead in ["resets", "Resets", "Try again at", "try again at"] {
            for (at, _) in line.match_indices(lead) {
                let rest = &line[at + lead.len()..];
                let trimmed = rest.trim_start();
                if trimmed.len() < rest.len() {
                    out.push((at, trimmed));
                }
            }
        }
        out.sort_by_key(|(at, _)| *at);
        out.into_iter().map(|(_, rest)| rest).collect()
    }

    fn digits(text: &str, max: usize) -> usize {
        text.bytes()
            .take(max)
            .take_while(u8::is_ascii_digit)
            .count()
    }

    fn letters(text: &str) -> usize {
        text.bytes().take_while(u8::is_ascii_lowercase).count()
    }

    /// `Mon[th] D[th], [YYYY[,] ]clock`.
    fn dated(rest: &str) -> Option<(Day, u32, Option<u8>, Option<char>)> {
        let b = rest.as_bytes();
        if b.len() < 3 || !b[0].is_ascii_uppercase() || !b[1..3].iter().all(u8::is_ascii_lowercase)
        {
            return None;
        }
        let name = &rest[..3];
        let mut at = 3 + letters(&rest[3..]);
        let blanks = rest[at..].len() - rest[at..].trim_start().len();
        if blanks == 0 {
            return None;
        }
        at += blanks;
        let d = digits(&rest[at..], 2);
        if d == 0 {
            return None;
        }
        let day: u8 = rest[at..at + d].parse().ok()?;
        at += d + letters(&rest[at + d..]);
        if !rest[at..].starts_with(',') {
            return None;
        }
        at += 1;
        let blanks = rest[at..].len() - rest[at..].trim_start().len();
        if blanks == 0 {
            return None;
        }
        at += blanks;
        let month = MONTHS.iter().position(|m| *m == name)? as u8 + 1;
        // The optional year, taken where a clock follows it.
        if digits(&rest[at..], 4) == 4 && !rest[at + 4..].starts_with(':') {
            let year: i16 = rest[at..at + 4].parse().ok()?;
            let mut after = at + 4;
            if rest[after..].starts_with(',') {
                after += 1;
            }
            let blanks = rest[after..].len() - rest[after..].trim_start().len();
            if blanks > 0
                && let Some((h, m, mer, _)) = clock(&rest[after + blanks..])
            {
                return Some((
                    Day::Dated {
                        month,
                        day,
                        year: Some(year),
                    },
                    h,
                    m,
                    mer,
                ));
            }
        }
        let (h, m, mer, _) = clock(&rest[at..])?;
        Some((
            Day::Dated {
                month,
                day,
                year: None,
            },
            h,
            m,
            mer,
        ))
    }

    /// `Weekday clock`.
    fn weekday(rest: &str) -> Option<(Day, u32, Option<u8>, Option<char>)> {
        let b = rest.as_bytes();
        if b.first().is_none_or(|c| !c.is_ascii_uppercase()) {
            return None;
        }
        let word_len = 1 + letters(&rest[1..]);
        let word = &rest[..word_len];
        if !word.ends_with("day") {
            return None;
        }
        let blanks = rest[word_len..].len() - rest[word_len..].trim_start().len();
        if blanks == 0 {
            return None;
        }
        let dow = WEEKDAYS.iter().position(|w| *w == word)? as u8 + 1;
        let (h, m, mer, _) = clock(&rest[word_len + blanks..])?;
        Some((Day::Weekday(dow), h, m, mer))
    }

    /// The zone the line names in parentheses: an IANA name of one or more
    /// components.
    fn zone_of(line: &str) -> Option<String> {
        for (at, _) in line.match_indices('(') {
            let rest = &line[at + 1..];
            let Some(end) = rest.find(')') else { continue };
            let name = &rest[..end];
            let mut parts = name.split('/');
            let first_ok = parts
                .next()
                .is_some_and(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_alphabetic()));
            let rest_ok = parts.all(|p| {
                !p.is_empty()
                    && p.bytes()
                        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'+' | b'-'))
            });
            if first_ok && rest_ok {
                return Some(name.to_owned());
            }
        }
        None
    }

    /// Whether a line of `text` states a reset clause the grammar matches,
    /// keyed or not (`USAGE_RESET_ANY_RE`): a clause [`key`] answers `None`
    /// for, a clock with neither minutes nor a meridiem, still names a reset.
    pub fn clause(text: &str) -> bool {
        text.lines().any(|line| {
            after_leads(line)
                .iter()
                .any(|r| dated(r).is_some() || weekday(r).is_some() || clock(r).is_some())
        })
    }

    /// The key of the first line of `text` that states a reset in a shape
    /// the grammar reads (`usage_reset_key`), the tails tried dated, then
    /// weekday, then clock; `None` for none, or for a clock with neither
    /// minutes nor a meridiem.
    pub fn key(text: &str) -> Option<Key> {
        for line in text.lines() {
            let rests = after_leads(line);
            let found = rests
                .iter()
                .find_map(|r| dated(r))
                .or_else(|| rests.iter().find_map(|r| weekday(r)))
                .or_else(|| {
                    rests
                        .iter()
                        .find_map(|r| clock(r).map(|(h, m, mer, _)| (Day::Clock, h, m, mer)))
                });
            let Some((day, hour, minute, meridiem)) = found else {
                continue;
            };
            if minute.is_none() && meridiem.is_none() {
                return None;
            }
            let hour = match meridiem {
                Some('p') if hour != 12 => hour + 12,
                Some('a') if hour == 12 => 0,
                Some(_) | None => hour,
            };
            let hour = u8::try_from(hour).ok()?;
            return Some(Key {
                day,
                hour,
                minute: minute.unwrap_or(0),
                zone: zone_of(line),
            });
        }
        None
    }

    /// The UTC instants a wall clock names on `date` in `zone`, ascending:
    /// one, two in a fall-back hour, none in a spring-forward gap
    /// (`local_instants`).
    fn local_instants(zone: &TimeZone, date: Date, key: &Key) -> Vec<i64> {
        let Ok(dt) = DateTime::new(
            date.year(),
            date.month(),
            date.day(),
            key.hour as i8,
            key.minute as i8,
            0,
            0,
        ) else {
            return Vec::new();
        };
        let ambiguous = zone.to_ambiguous_timestamp(dt);
        match ambiguous.offset() {
            AmbiguousOffset::Unambiguous { .. } => ambiguous
                .unambiguous()
                .map(|t| vec![t.as_second()])
                .unwrap_or_default(),
            AmbiguousOffset::Fold { .. } => {
                let earlier = zone.to_ambiguous_timestamp(dt).earlier();
                let later = zone.to_ambiguous_timestamp(dt).later();
                match (earlier, later) {
                    (Ok(e), Ok(l)) => vec![e.as_second(), l.as_second()],
                    (Ok(_), Err(_)) | (Err(_), Ok(_)) | (Err(_), Err(_)) => Vec::new(),
                }
            }
            AmbiguousOffset::Gap { .. } => Vec::new(),
        }
    }

    /// The instant `key` names given the sighting `since` (`usage_reset_epoch`):
    /// a dated clause its own day, in the year it printed or the one of
    /// three around the sighting nearest it, the later instant in a
    /// fall-back hour; a weekday or a clock its first occurrence strictly
    /// after the sighting, over both instants a fold names. `None` where
    /// the clock names no instant.
    pub fn epoch(key: &Key, since: u64, zone: &TimeZone) -> Option<u64> {
        let since_ts = Timestamp::from_second(i64::try_from(since).ok()?).ok()?;
        let seen = since_ts.to_zoned(zone.clone());
        match key.day {
            Day::Dated { month, day, year } => {
                let years: Vec<i16> = match year {
                    Some(year) => vec![year],
                    None => vec![seen.year() - 1, seen.year(), seen.year() + 1],
                };
                let mut best: Option<(i64, i64)> = None;
                for y in years {
                    let Ok(date) = Date::new(y, month as i8, day as i8) else {
                        continue;
                    };
                    let Some(cand) = local_instants(zone, date, key).last().copied() else {
                        continue;
                    };
                    let distance = (cand - since as i64).abs();
                    if best.is_none_or(|(_, d)| distance < d) {
                        best = Some((cand, distance));
                    }
                }
                best.and_then(|(cand, _)| u64::try_from(cand).ok())
            }
            Day::Weekday(_) | Day::Clock => {
                let (dow, last) = match key.day {
                    Day::Weekday(dow) => (Some(dow), 7),
                    Day::Clock | Day::Dated { .. } => (None, 1),
                };
                for d in 0..=last {
                    let Ok(date) = seen.date().checked_add(Span::new().days(d)) else {
                        continue;
                    };
                    if dow.is_some_and(|dow| date.weekday().to_monday_one_offset() != dow as i8) {
                        continue;
                    }
                    for cand in local_instants(zone, date, key) {
                        if cand > since as i64 {
                            return u64::try_from(cand).ok();
                        }
                    }
                }
                None
            }
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        /// The rows hold the answers on the banners (`RESET_NOW` 1788364800
        /// read in UTC): each form the grammar accepts resolves to the instant
        /// the row pins, and the forms it excludes name none.
        #[test]
        fn the_reset_clause_resolves_to_the_instant_each_banner_names() {
            let since = 1_788_364_800;
            let utc = TimeZone::UTC;
            let la = TimeZone::get("America/Los_Angeles").unwrap();
            let rows: [(&str, &TimeZone, u64, Option<u64>); 15] = [
                (
                    "You've hit your usage limit \u{b7} resets 9:50am (America/Los_Angeles)",
                    &utc,
                    since,
                    Some(1_788_367_800),
                ),
                (
                    "You've hit your usage limit \u{b7} resets 9:50pm (UTC)",
                    &la,
                    since,
                    Some(1_788_385_800),
                ),
                (
                    "You've hit your session limit \u{b7} resets 21:00",
                    &utc,
                    since,
                    Some(1_788_382_800),
                ),
                (
                    "You've hit your usage limit \u{b7} resets 12pm",
                    &utc,
                    since,
                    Some(1_788_436_800),
                ),
                (
                    "You've hit your weekly limit \u{b7} resets Sep 6, 4pm",
                    &utc,
                    since,
                    Some(1_788_710_400),
                ),
                (
                    "You've hit your weekly limit \u{b7} resets Oct 7, 2027, 11:32am",
                    &utc,
                    since,
                    Some(1_822_908_720),
                ),
                (
                    "You've hit your weekly limit \u{b7} resets Thursday 4am",
                    &utc,
                    since,
                    Some(1_788_408_000),
                ),
                (
                    "You've hit your usage limit. Try again at Sep 6th, 2026 4:30 PM",
                    &utc,
                    since,
                    Some(1_788_712_200),
                ),
                (
                    "You've hit your weekly limit \u{b7} resets Aug 30, 4pm",
                    &utc,
                    since,
                    Some(1_788_105_600),
                ),
                (
                    "You've hit your weekly limit \u{b7} resets Oct 4, 6pm (UTC)",
                    &utc,
                    since,
                    Some(1_791_136_800),
                ),
                (
                    "You've hit your usage limit \u{b7} resets 9:50am (America/Los_Angeles)",
                    &utc,
                    1_788_369_300,
                    Some(1_788_454_200),
                ),
                (
                    "You've hit your usage limit \u{b7} resets 17:00",
                    &utc,
                    1_788_372_000,
                    Some(1_788_454_800),
                ),
                (
                    "You've hit your fast limit \u{b7} resets in 5m",
                    &utc,
                    since,
                    None,
                ),
                (
                    "You've hit your usage limit \u{b7} resets 2026-09-03",
                    &utc,
                    since,
                    None,
                ),
                (
                    "You've hit your weekly limit \u{b7} resets Thursday",
                    &utc,
                    since,
                    None,
                ),
            ];
            for (banner, zone, since, want) in rows {
                let got = key(banner).and_then(|k| {
                    let zone = match k.zone.as_deref() {
                        Some(name) => TimeZone::get(name).unwrap(),
                        None => (*zone).clone(),
                    };
                    epoch(&k, since, &zone)
                });
                assert_eq!(got, want, "{banner}");
            }
            let bogus =
                key("You've hit your usage limit \u{b7} resets 9:50am (Bogus/Zone)").unwrap();
            assert_eq!(bogus.zone.as_deref(), Some("Bogus/Zone"));
            assert!(TimeZone::get("Bogus/Zone").is_err());
        }
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    const COUNTS_STATE: &str = r#"{"first_panel":{},"rereview_cycles":1,"cycles":7,"pr_comment_review":{"iterations":3,"patched_causes":[{"cause":"a","commit":"aaa111"},{"cause":"a","commit":"bbb222"}]},"stages":[{"kind":"implement"},{"kind":"fix"},{"kind":"fix"},{"kind":"fix"},{"kind":"review"}],"validate_rounds":[{"kind":"implement"},{"kind":"fix"},{"kind":"restack"},{"kind":"restack"}],"restack_skips":[{},{}],"restacks":4}"#;
    const REPEATED_STATE: &str = r#"{"pr_comment_review":{"iterations":2,"patched_causes":[{"cause":"unchecked read","commit":"aaa111"},{"cause":"unchecked read","commit":"bbb222"}]}}"#;
    const LOCATION_STATE: &str = r#"{"pr_comment_review":{"iterations":2,"patched_causes":[{"cause":"unchecked read","commit":"aaa111","location":" src/x.rs (`f`) "},{"cause":"stale count","commit":"bbb222","location":"src/x.rs (`f`)"}]}}"#;
    const OWNER_STATE: &str = r#"{"pr_comment_review":{"iterations":2,"patched_causes":[{"cause":"cancel leaves intent","commit":"aaa111","location":"src/dialog.rs (`close_retry`)","owner":"src/alert.rs (`AlertRow`)"},{"cause":"send leaves intent","commit":"bbb222","location":"src/send.rs (`on_failed_send`)","owner":"src/alert.rs (`AlertRow`)"}]}}"#;

    fn doc(text: &str) -> Document {
        let Value::Object(doc) = serde_json::from_str::<Value>(text).unwrap() else {
            panic!("a state object: {text}")
        };
        doc
    }

    /// A suite row: its name, the state, the run index's count and the
    /// five words, or `None` for a refused shape.
    type Row<'a> = (&'a str, &'a str, Option<usize>, Option<[&'a str; 5]>);

    fn edited(text: &str, edit: impl Fn(&mut Value)) -> String {
        let mut value: Value = serde_json::from_str(text).unwrap();
        edit(&mut value);
        value.to_string()
    }

    /// The rows hold the counts on the states
    /// (`NAME|STATE|REVIEW|FIXES|VALIDATIONS|RESTACKS|REPEATED` with the run
    /// index each case plants): each row's five words, and `None` for the
    /// shape the count refuses.
    #[test]
    fn the_counts_read_from_each_state() {
        let four = Some(4);
        let none = Some(0);
        let owner_one_commit = edited(OWNER_STATE, |v| {
            v["pr_comment_review"]["patched_causes"][1]["commit"] = json!("aaa111");
        });
        let owner_three = edited(OWNER_STATE, |v| {
            v["pr_comment_review"]["patched_causes"]
                .as_array_mut()
                .unwrap()
                .push(json!({
                    "cause": "third", "commit": "ccc333",
                    "location": "src/third.rs (`third`)", "owner": "src/alert.rs (`AlertRow`)"
                }));
        });
        let owner_equals_location = edited(OWNER_STATE, |v| {
            let patch = &mut v["pr_comment_review"]["patched_causes"][1];
            let owner = patch["owner"].take();
            patch["location"] = owner;
            patch.as_object_mut().unwrap().remove("owner");
        });
        let no_stages = edited(COUNTS_STATE, |v| {
            v.as_object_mut().unwrap().remove("stages");
        });
        let rows: Vec<Row> = vec![
            (
                "separate_counts",
                COUNTS_STATE,
                four,
                Some(["5", "3", "4", "4", "1"]),
            ),
            (
                "no_stages",
                &no_stages,
                four,
                Some(["5", "unread", "4", "4", "1"]),
            ),
            (
                "no_validation_lists",
                r#"{"stages":[]}"#,
                none,
                Some(["0", "0", "0", "0", "unread"]),
            ),
            (
                "one_restack_no_record",
                r#"{"stages":[],"restacks":1}"#,
                none,
                Some(["0", "0", "0", "1", "unread"]),
            ),
            (
                "one_restack_range_run",
                r#"{"stages":[],"restacks":1,"validate_rounds":[{"kind":"restack"}]}"#,
                Some(1),
                Some(["0", "0", "1", "1", "unread"]),
            ),
            (
                "missing_index",
                r#"{"stages":[]}"#,
                None,
                Some(["0", "0", "unread", "0", "unread"]),
            ),
            (
                "one_restack_skipped",
                r#"{"stages":[],"restacks":1,"restack_skips":[{}]}"#,
                none,
                Some(["0", "0", "0", "1", "unread"]),
            ),
            (
                "two_bot_rounds",
                REPEATED_STATE,
                none,
                Some(["2", "unread", "0", "0", "1"]),
            ),
            (
                "different_causes_one_location",
                LOCATION_STATE,
                none,
                Some(["2", "unread", "0", "0", "1"]),
            ),
            (
                "one_owner_two_commits",
                OWNER_STATE,
                none,
                Some(["2", "unread", "0", "0", "1"]),
            ),
            (
                "one_owner_one_commit",
                &owner_one_commit,
                none,
                Some(["2", "unread", "0", "0", "0"]),
            ),
            (
                "one_owner_three_commits",
                &owner_three,
                none,
                Some(["2", "unread", "0", "0", "2"]),
            ),
            (
                "owner_equals_location",
                &owner_equals_location,
                none,
                Some(["2", "unread", "0", "0", "1"]),
            ),
            (
                "one_location_one_commit",
                r#"{"pr_comment_review":{"iterations":1,"patched_causes":[{"cause":"a","commit":"aaa111","location":"src/x.rs (`f`)"},{"cause":"b","commit":"aaa111","location":"src/x.rs (`f`)"}]}}"#,
                none,
                Some(["1", "unread", "0", "0", "0"]),
            ),
            (
                "ht_2098",
                r#"{"pr_comment_review":{"iterations":2,"patched_causes":[{"cause":"a","commit":"8f27054b","location":"src/x.rs (`f`)"},{"cause":"b","commit":"e4ed9beb","location":"src/x.rs (`f`)"},{"cause":"c","commit":"70110a24","location":"src/x.rs (`f`)"},{"cause":"d","commit":"d48cc623","location":"src/x.rs (`f`)"}]}}"#,
                none,
                Some(["2", "unread", "0", "0", "3"]),
            ),
            (
                "unknown_locations",
                r#"{"pr_comment_review":{"iterations":2,"patched_causes":[{"cause":"a","commit":"aaa111","location":"general"},{"cause":"b","commit":"bbb222","location":"general"}]}}"#,
                none,
                Some(["2", "unread", "0", "0", "0"]),
            ),
            (
                "new_symbol",
                r#"{"pr_comment_review":{"iterations":2,"patched_causes":[{"cause":"a","commit":"aaa111","location":"src/x.rs (`f`)"},{"cause":"b","commit":"bbb222","location":"src/x.rs (`g`)"}]}}"#,
                none,
                Some(["2", "unread", "0", "0", "0"]),
            ),
            (
                "internal_and_bot",
                r#"{"first_panel":{"agents":["reviewer-error"]},"rereview_cycles":1,"pr_comment_review":{"iterations":2,"patched_causes":[{"cause":"unchecked read","commit":"aaa111"},{"cause":"unchecked read","commit":"bbb222"}]}}"#,
                none,
                Some(["4", "unread", "0", "0", "1"]),
            ),
            (
                "no_classes",
                r#"{"first_panel":{"agents":["reviewer-error"]},"rereview_cycles":1,"pr_comment_review":{"iterations":2}}"#,
                none,
                Some(["4", "unread", "0", "0", "unread"]),
            ),
            (
                "same_commit",
                r#"{"pr_comment_review":{"iterations":1,"patched_causes":[{"cause":"unchecked read","commit":"aaa111"},{"cause":"unchecked read","commit":"aaa111"}]}}"#,
                none,
                Some(["1", "unread", "0", "0", "0"]),
            ),
            (
                "two_classes_one_round",
                r#"{"pr_comment_review":{"iterations":2,"patched_causes":[{"cause":"unchecked read","commit":"aaa111"},{"cause":"stale count","commit":"aaa111"},{"cause":"unchecked read","commit":"bbb222"},{"cause":"stale count","commit":"bbb222"}]}}"#,
                none,
                Some(["2", "unread", "0", "0", "1"]),
            ),
            (
                "initial_state",
                r#"{"rereview_cycles":0,"pr_comment_review":{"iterations":0,"patched_causes":[]}}"#,
                none,
                Some(["0", "unread", "0", "0", "unread"]),
            ),
            (
                "invalid_rounds",
                r#"{"rereview_cycles":"unknown"}"#,
                none,
                None,
            ),
        ];
        for (name, state, runs, want) in rows {
            let got = counters_of(&doc(state), runs).map(|c| {
                [
                    c.review_rounds,
                    c.fix_receipts,
                    c.validation_runs,
                    c.restacks,
                    c.repeated_class_rounds,
                ]
            });
            let want = want.map(|w| w.map(str::to_owned));
            assert_eq!(got, want, "{name}");
        }
    }

    /// The run index as `lane_item_validation_runs` reads it: the header,
    /// one unique run a line, a final newline; any other shape counts
    /// nothing (`missing_index`, `invalid_index`).
    #[test]
    fn the_run_index_counts_only_a_well_formed_inventory() {
        let rows = [
            ("dev-validate-runs-v1\n", Some(0)),
            (
                "dev-validate-runs-v1\ndev-validate-implement\ndev-validate-fix\ndev-validate-restack-a\ndev-validate-restack-b\n",
                Some(4),
            ),
            ("{\n", None),
            (
                "dev-validate-runs-v1\ndev-validate-a\ndev-validate-a\n",
                None,
            ),
            ("dev-validate-runs-v1\ndev-validate-a", None),
            ("dev-validate-runs-v1\ndev-validate-\n", None),
            ("", None),
        ];
        for (text, want) in rows {
            assert_eq!(validation_runs_of(text), want, "{text:?}");
        }
    }

    /// The `Step` line: bare or a list item,
    /// case-insensitive, the value after the colon with its case kept;
    /// `none` without one or with an empty one.
    #[test]
    fn the_step_line_is_read_bare_or_as_a_list_item() {
        let rows = [
            ("# Lane status\nStep: dev round 1\n", "dev round 1"),
            ("- Step: review\n", "review"),
            ("*\tstep:\tLoud Step\n", "Loud Step"),
            ("STEP: Loud\n", "Loud"),
            ("Step:\n", "none"),
            ("nothing here\n", "none"),
            ("-Step: no blank after the marker\n", "none"),
            ("", "none"),
        ];
        for (text, want) in rows {
            assert_eq!(step_of(text), want, "{text:?}");
        }
    }
}
