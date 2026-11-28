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
//! record and needs no comparison. A local Claude rate-limit row needs a
//! launch position, and that position excludes earlier auth failures too.
//!
//! The wall's record and route: the reset the banner names is read by the
//! grammar ([`reset`] below) and the line is `usage-limit-passed` once
//! the clock passes it; the account wall record and the lane record's own wall
//! are written through `ops::wall`; the wall relaunch is the walled lane's
//! close and its `launch-lane` on the entry the lane walk chose, the spent
//! account left out, for a usage and an auth wall alike. A provider stop and
//! an exited harness take the same relaunch ([`continue_lane`],
//! `restart_exited`). The runtime's own entry applies
//! both, started detached through the one runner under
//! `ORCH_WALL_RELAUNCH=auto`; a window gone while that
//! relaunch is still opening its replacement is not `window-gone`. A lane
//! `ORCH_WATCH_LANE_AGE_SECS` past its
//! launch is `lane-long` once per age interval with the counters its records
//! give. A lane told to hand off records `.handoff` in its item's state and
//! exits: the record is read where `workflow-state
//! handoff-standing` reads it and is `handoff` once per record.
//!
//! A lane's own process writes only its item record, so the fleet writes its
//! turn end owes are taken from that record here, once per fact: a cleared
//! start's session bound, a replacement's first turn end reset, and a switch
//! the turn end marked started recovered through the fleet's
//! `recover-lane-model`.
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
use agent_runtime::controller::model::{Check, Place, launch_of, record_model_check};
use agent_runtime::harness::Harness;
use agent_runtime::host::tmux::{self, PANE_DEAD, Pane, PaneFields, PaneState};
use agent_runtime::observe::{self, IdleTurn, ProcessReading, State, WallAge, WallKind};
use agent_runtime::process::Identity;
use agent_runtime::protocol::Outcome;
use agent_runtime::reading::Reading;
use agent_runtime::rows::{self, LaneVerdict};
use agent_runtime::session;
use agent_runtime::stop::{self, Action, Kind, Session, reset};
use jiff::tz::TimeZone;
use serde::Serialize;
use serde_json::{Value, json};

use super::Produced;
use super::baseline::{Baseline, Change};
use super::events::Event;
use super::hosted::{self, Answer, Capabilities, Files, HostStatus, Hosts, PaneKind, Status};
use super::overseer::{RelaunchPending, relaunch_pending};
use super::verifying::is_reading_lane;
use super::wake;
use crate::effects::relaunch::{Close as RecordClose, Relaunch as RecordRelaunch};
use crate::effects::start_brief;
use crate::mailbox::Refusal;
use crate::marker;
use crate::ops::CLOUD_KIND;
use crate::ops::lane::RecoveryReason;
use crate::ops::wall::{self, RecordWallPauses, WallObservation, WallReading};
use crate::settings::{self, Settings, WallRelaunch, WatchSettings};
use crate::state::{self, CloseGround, FleetState, Lane, LaneMembers, LaneStatus};
use agent_runtime::accounts::walk::{self as lane_walk, Chosen, WalkAnswer, WalkRequest, Walked};
use agent_runtime::accounts::wall::{self as account_wall, AccountWallWrite, WallChannel};
use agent_runtime::controller::successor::{self as choice, Leaving};
use agent_runtime::intent::{EffectOp, Obligation, Phase};

/// The row kinds this duty keeps, each keyed by the lane's name, pruned
/// when the lane leaves flight; [`RESTART_ROW`] alone stands until the
/// lane's assignment ends.
const LANE_ROWS: [&str; 13] = [
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
    PROVIDER_ROW,
    RESTART_ROW,
    SSH_ROWS_FLOOR,
];

/// Pre-existing rows at the first successful watch read of a legacy launch.
/// The floor belongs to the attempt named after its first separator.
const SSH_ROWS_FLOOR: &str = "ssh-session-rows-floor";

/// The row of a worker's continuation episode: `<since>|<last>[|<said>]`,
/// the epoch seconds its first and latest stopped turns were read at, and
/// the [`said_once`] mark of the refusal last told.
const PROVIDER_ROW: &str = "provider-stop";

/// The row of an exited lane's restart, for the assignment its record's
/// `launched_at` names, which every relaunch keeps:
/// `owed|<launched_at>|<told>` while no restart started, `<told>` the hash
/// of the refusal last said; `started|<launched_at>|<death>` once one
/// started for the exit on the pane hashed `<death>`; `dead|<launched_at>`
/// once a second exit was said. A parked or stopped lane keeps the row,
/// since its relaunch keeps `launched_at`; it goes with a done record or
/// one gone from the fleet.
const RESTART_ROW: &str = "lane-restart";

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
/// A Codex or Copilot session's last failed turn, by its harness, home,
/// directory and id.
pub type SessionFailureRead<'a> =
    &'a dyn Fn(Harness, &Path, &Path, &str) -> Reading<Option<session::Failure>>;
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
    /// One read binds the lane verdict to its row position.
    pub rows: &'a dyn Fn(&Path) -> Reading<rows::Row>,
    /// How the last turn of the Codex or Copilot session whose id the
    /// record names, under its home and directory, ended: its own session
    /// record read through `session::last_failure`, the one reading of a
    /// failed turn those harnesses write no hook row for.
    pub session_failure: SessionFailureRead<'a>,
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
        fn session_failure(
            harness: Harness,
            home: &Path,
            cwd: &Path,
            id: &str,
        ) -> Reading<Option<session::Failure>> {
            match agent_runtime::effects::fixed_id_file(harness, home, cwd, id) {
                Reading::Live(file) => session::last_failure(harness, &file),
                Reading::Gone => Reading::Gone,
                Reading::Unreadable { cause } => Reading::Unreadable { cause },
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
            rows: &rows::last_row,
            session_failure: &session_failure,
            status_file: &status_file,
            windows: &windows,
            receipts: &receipts_in,
            zone: &zone,
        }
    }
}

/// The relaunch the wall route starts: the walled lane's close and its
/// `launch-lane` with its destination credentials, run detached in the launch's
/// checkout with its session, its output at `log`, its exit status landing
/// beside `marker`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Relaunch {
    pub item: String,
    pub window: String,
    /// The destination account, or `-` for inherited credentials.
    pub to: String,
    /// The predecessor's account, or `-` for inherited credentials.
    pub spent: String,
    pub cwd: PathBuf,
    pub session: String,
    /// The detached command, `sh -c` over the two requests, the close
    /// first.
    pub args: Vec<String>,
    pub marker: PathBuf,
    pub log: PathBuf,
}

/// The recovery route's calls and the setting that gates a replacement.
pub struct WallRoute<'a> {
    pub relaunch: WallRelaunch,
    /// The lane walk (`orch-runtime lane walk --fleet --replaces ITEM`) for
    /// the item whose charge it leaves out; `Err` is the walk's refusal.
    pub walk: &'a dyn Fn(&str, &WalkRequest) -> Result<Walked, String>,
    /// `ORCH_LANE_PREFERENCE`, which a provider move walks less the stopped
    /// lane's own provider.
    pub preference: Option<&'a str>,
    /// `ORCH_LANE_HOST`, where the walk judges an entry naming no host and
    /// the caller step, `None` this machine; `Err` is the setting's refusal.
    pub host: Result<Option<String>, String>,
    /// The standing halt at the lane's mailbox.
    pub halted: &'a dyn Fn(&Lane) -> Result<bool, Refusal>,
    /// An exited local lane's relaunch from its record, its session
    /// resumed (`effects::relaunch::composed`); `Err` is its refusal.
    pub exited: &'a dyn Fn(&Lane) -> Result<RecordRelaunch, String>,
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
    /// The harness's own session row.
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
    /// a pane-judged provider failure carries `api-error`.
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
    /// The lane's rows, where its harness supplies them.
    pub rows: Option<&'a Reading<rows::Row>>,
    pub harness: Option<Harness>,
    /// Whether the account the lane spends was read as having room: the
    /// close's wall lift passes `Some(true)`, which judges a usage banner
    /// past; the watch reads none and reports every wall.
    pub account_room: Option<bool>,
}

/// The classifier, in the rung order: the window (where the pane is this
/// server's), the read, the process (a pane with nothing but shells under
/// it is the lane, finished), pane dialogs and walls except on Pi, then
/// the rows. A failed-turn pane can end a Working row. A Pi lane with no rows is unjudged,
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
    let Some(harness) = inputs.harness else {
        return LaneState::Unjudged {
            cause: "harness-unrecorded".to_owned(),
        };
    };
    let pane = observe::observe_pane(screen, harness, process, inputs.account_room);
    let screen_state = match pane.state {
        State::Idle => LaneState::Idle {
            capacity: pane.idle == Some(IdleTurn::Capacity),
            cause: (pane.idle == Some(IdleTurn::ApiError)).then(|| stop::API_ERROR.to_owned()),
        },
        State::Working => LaneState::Working,
        State::Asking { .. } => LaneState::Asking,
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
    };
    if harness != Harness::Pi
        && matches!(
            screen_state,
            LaneState::Asking | LaneState::RateLimitSwitch | LaneState::Walled { .. }
        )
    {
        return screen_state;
    }
    if let Some(reading) = inputs.rows {
        let verdict = match reading {
            Reading::Live(row) => rows::judge_lane(row).map(|verdict| (row, verdict)),
            Reading::Gone => Reading::Gone,
            Reading::Unreadable { cause } => Reading::Unreadable { cause },
        };
        match verdict {
            Reading::Live((_, LaneVerdict::Walled { kind })) => {
                return LaneState::Walled {
                    kind,
                    banner: String::new(),
                    source: WallSource::Rows,
                };
            }
            Reading::Live((_, LaneVerdict::Working)) => {
                if matches!(&screen_state, LaneState::Idle { capacity: true, .. })
                    || matches!(&screen_state, LaneState::Idle { cause: Some(_), .. })
                {
                    return screen_state;
                }
                return LaneState::Working;
            }
            Reading::Live((_, LaneVerdict::Idle { cause })) => {
                return LaneState::Idle {
                    capacity: false,
                    cause,
                };
            }
            Reading::Unreadable { cause } => {
                return LaneState::Unjudged {
                    cause: cause.to_owned(),
                };
            }
            Reading::Gone => {}
        }
    }
    // Claude, Codex and Copilot fall back to their pane when no row stands.
    // Pi's carrier drawing cannot settle its turn without the row.
    if harness == Harness::Pi {
        return LaneState::Unjudged {
            cause: "rows-none".to_owned(),
        };
    }
    screen_state
}

/// Whether a local Claude lane's StopFailure `row` is its own session's.
/// A stop the stop reading names at or before the launch position is the
/// predecessor's. Legacy records without one use the pane as evidence of a
/// Claude rate limit.
fn launch_current(lane: &Lane, row: &rows::Row) -> bool {
    match lane.session_rows_at_launch {
        Some(at) if row.position <= at => rows::stop_of(row).is_none(),
        None => row.error.as_deref() != Some("rate_limit"),
        Some(_) => true,
    }
}

/// One pass's inputs beyond the readers.
pub struct Pass<'a> {
    pub fleet: &'a FleetState,
    /// The file `fleet` was read from, read again after hosted closes and
    /// by the stray sweep after its listing.
    pub fleet_path: &'a Path,
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
    /// The claim store, beside which the relaunch markers live.
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
    row: Option<rows::Row>,
    provider_running: bool,
    state: LaneState,
}

impl Observed<'_> {
    fn hosted_unreadable(&self) -> bool {
        matches!(self.state, LaneState::Unreadable { .. }) && hosted::host_of(self.lane) != "local"
    }

    fn current_auth_row(&self) -> bool {
        self.row
            .as_ref()
            .zip(self.lane.session_rows_at_launch)
            .is_some_and(|(row, at)| {
                row.position > at
                    && matches!(
                        rows::judge_lane(row),
                        Reading::Live(LaneVerdict::Walled {
                            kind: WallKind::Auth
                        })
                    )
            })
    }
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
    rows: Option<Result<Reading<rows::Row>, String>>,
}

impl HostRead {
    fn failed(cause: String) -> Self {
        Self {
            status: Some(Err(cause)),
            screen: None,
            rows: None,
        }
    }

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
                Some(Ok(match hosted::session_rows(scripts, lane) {
                    Answer::Live(text) => rows::last_row_in(&text),
                    Answer::Gone => Reading::Gone,
                    Answer::Unreadable { .. } => Reading::Unreadable {
                        cause: "rows-host-unread",
                    },
                }))
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

/// Claude's provider stops are recorded by the hook after native retries.
/// Keep the existing screen judgment for other hosted Claude observations.
fn ssh_claude_rows(
    lane: &Lane,
    pass: &Pass,
    out: &mut Produced,
) -> Result<Reading<rows::Row>, String> {
    let rooted = hosted::with_session_root(lane, &pass.fleet.intents);
    let text = match hosted::confirmed_session_rows(pass.scripts, &rooted) {
        Answer::Live(text) => text,
        Answer::Gone => String::new(),
        Answer::Unreadable { cause } => return Err(cause),
    };
    let at = if let Some(at) = lane.session_rows_at_launch {
        at
    } else {
        let Some(launch) = &lane.launch else {
            return Ok(Reading::Gone);
        };
        let name = lane_name(lane);
        let attempt = format!(
            "{:?}|{:?}|{:?}|{}|{:?}",
            launch.server,
            launch.server_start,
            launch.pane,
            identity_word(identity_of(lane).as_ref()),
            lane.session_since,
        );
        let floor = pass.baseline.get(SSH_ROWS_FLOOR, &name).and_then(|value| {
            let (floor, recorded) = value.split_once('|')?;
            (recorded == attempt)
                .then(|| floor.parse::<usize>().ok())
                .flatten()
        });
        match floor {
            Some(floor) => floor,
            None => {
                out.changes.push(set(
                    SSH_ROWS_FLOOR,
                    &name,
                    format!("{}|{attempt}", rows::last_position_in(&text)),
                ));
                return Ok(Reading::Gone);
            }
        }
    };
    Ok(match rows::last_row_in(&text) {
        Reading::Live(row)
            if row.position > at
                && row.harness.as_deref() == Some("claude")
                && rows::stop_of(&row) == Some(Kind::Provider) =>
        {
            Reading::Live(row)
        }
        Reading::Unreadable { cause } => Reading::Unreadable { cause },
        Reading::Live(_) | Reading::Gone => Reading::Gone,
    })
}

/// Read one lane: the pane, its foreground, its screen and its local rows. `host` is what its provider answered first: an
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
        row: None,
        provider_running: false,
        state,
    };
    let harness_up = match host.status {
        Some(Err(cause)) => return unread(LaneState::Unjudged { cause }),
        Some(Ok(HostStatus::Exited)) => return unread(LaneState::Exited),
        Some(Ok(HostStatus::Running)) => true,
        None => false,
    };
    let rows_unread = host
        .rows
        .as_ref()
        .and_then(|read| read.as_ref().err())
        .cloned();
    let row_reading = match host.rows {
        Some(Ok(reading)) => Some(reading),
        Some(Err(_)) => Some(Reading::Unreadable {
            cause: "rows-host-unread",
        }),
        None => (harness == Some(Harness::Pi) || hosted::host_of(lane) == "local")
            .then_some(lane.mail_root.as_deref())
            .flatten()
            .map(|root| {
                let file = lane_rows_file(root, &lane.item);
                (readers.rows)(&file)
            }),
    };
    let current_rows = row_reading.as_ref().filter(|reading| {
        let Reading::Live(row) = reading else {
            return true;
        };
        if harness != Some(Harness::Claude)
            || hosted::host_of(lane) != "local"
            || row.harness.as_deref() != Some("claude")
            || row.event.as_deref() != Some("StopFailure")
        {
            return true;
        }
        launch_current(lane, row)
    });
    let live_row = |reading| match reading {
        Some(Reading::Live(row)) => Some(row),
        Some(Reading::Gone | Reading::Unreadable { .. }) | None => None,
    };
    let judge = |inputs: &Inputs| match (classify(inputs), rows_unread.as_ref()) {
        (LaneState::Unjudged { cause }, Some(refusal)) if cause == "rows-host-unread" => {
            LaneState::Unreadable {
                cause: refusal.clone(),
            }
        }
        (state, _) => state,
    };
    if let Some(screen) = host.screen {
        let state = judge(&Inputs {
            pane: None,
            process: Some(&ProcessReading::HarnessUp),
            screen: Some(&screen),
            rows: current_rows,
            harness,
            account_room,
        });
        return Observed {
            lane,
            name: name.clone(),
            pane_key: recorded.map(|(server, pane_id)| format!("{server} {pane_id}")),
            identity: identity.clone(),
            screen: screen.ok(),
            row: live_row(row_reading),
            provider_running: harness_up,
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
                row: live_row(row_reading),
                provider_running: false,
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
    let state = judge(&Inputs {
        pane: Some(&pane),
        process: process.as_ref(),
        screen: screen.as_ref(),
        rows: current_rows,
        harness,
        account_room,
    });
    Observed {
        lane,
        name,
        pane_key,
        identity,
        screen: screen.and_then(Result::ok),
        row: live_row(row_reading),
        provider_running: harness_up,
        state,
    }
}

fn lane_rows_file(root: &str, item: &str) -> PathBuf {
    marker::mailbox_path(Path::new(root), item).join(rows::LANE_FILE)
}

fn lane_refused(key: &'static str, fields: &[(&str, &str)]) -> crate::error::Error {
    crate::error::Error::from(agent_runtime::Error::refused(key, fields))
}

/// The fleet state at `path` as a lane verb or the stray sweep reads it: a
/// snapshot, never written back; no fleet state refuses `fleet-missing`.
#[allow(
    clippy::disallowed_methods,
    reason = "a lane verb's or the stray sweep's one read of the fleet state, a snapshot it judges; it acts on nothing"
)]
pub fn read_fleet(path: &Path) -> crate::error::Result<FleetState> {
    state::load(path)?
        .map(|snapshot| <FleetState as state::Record>::view(path, &snapshot.doc))
        .transpose()?
        .ok_or_else(|| lane_refused("fleet-missing", &[("path", &path.display().to_string())]))
}

/// The item's one in-flight lane record: none refuses `lane-missing`, two
/// `lane-ambiguous`.
pub fn in_flight<'a>(fleet: &'a FleetState, item: &str) -> crate::error::Result<&'a Lane> {
    let mut lanes = fleet
        .lanes
        .iter()
        .filter(|l| l.item == item && l.status.in_flight());
    match (lanes.next(), lanes.next()) {
        (Some(lane), None) => Ok(lane),
        (None, _) => Err(lane_refused("lane-missing", &[("item", item)])),
        (Some(_), Some(_)) => Err(lane_refused("lane-ambiguous", &[("item", item)])),
    }
}

/// `lane status --item`. The lane is the item's one in-flight record; its
/// host is read as the observation duty reads it, so a host whose
/// capability line cannot be read, or whose kind judges no status, leaves
/// the lane unjudged with the cause; the counts are the `lane-long` line's,
/// read where it reads them, and the stage is the one the same item state
/// holds open in the lane's current session ([`session_stage`]), the
/// record's `session_since`, as its post-PR stop is ([`stop_fact`]);
/// nothing is written.
pub fn status(settings: &Settings, path: &Path, item: &str) -> crate::error::Result<Value> {
    let fleet = read_fleet(path)?;
    let lane = in_flight(&fleet, item)?;
    let scripts = super::overseer::scripts_dir(&settings.roots.project);
    let hosts = Hosts::read(&scripts, [lane]);
    let (host, files) = match hosts.of(lane) {
        Err(cause) => (HostRead::failed(cause), None),
        Ok(caps) if caps.status == Status::None => {
            (HostRead::failed("status-none".to_owned()), Some(caps.files))
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
    let (counters, doc, _) = lane_state(
        lane,
        files,
        path.parent().unwrap_or(&settings.state_dir),
        &scripts,
        &mut said,
    );
    let since = lane.session_since.as_deref().and_then(clock::epoch_secs);
    let (stage, stage_start) = stage_fact(&doc, since);
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
        "stage_start": stage_start,
        "post_pr_stop": stop_fact(&doc, since),
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
        Err(cause) => HostRead::failed(cause),
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
    let assigned: BTreeSet<String> = pass
        .fleet
        .lanes
        .iter()
        .filter(|l| l.status != LaneStatus::Done)
        .map(lane_name)
        .collect();
    // Rows of lanes that left the record no longer describe an observation.
    for kind in LANE_ROWS {
        let kept = if kind == RESTART_ROW {
            &assigned
        } else {
            &names
        };
        for identity in pass.baseline.identities(kind) {
            let controller_resume = kind == wake::RESUME_KIND && identity == wake::OVERSEER_TARGET;
            if !(kept.contains(&identity) || controller_resume) {
                out.changes.push(clear(kind, &identity));
            }
        }
    }
    hosted::prune_close_markers(pass, &mut out);
    hosted::complete_parks(pass, &mut out);
    let sockets = agent_runtime::effects::fleet_sockets(
        pass.fleet
            .overseer
            .as_ref()
            .and_then(agent_runtime::effects::overseer_socket),
        pass.server.map(Path::to_path_buf),
    );
    let observed: Vec<Observed> = in_flight
        .iter()
        .filter_map(|lane| {
            let mut host = match hosts.of(lane) {
                // This kind has no harness for this duty to judge.
                Ok(caps) if caps.status == Status::None => return None,
                Ok(caps) => HostRead::of(pass.scripts, lane, caps),
                Err(cause) => HostRead::failed(cause),
            };
            if lane.status == LaneStatus::Running
                && lane.harness.as_deref() == Some("claude")
                // Older records with no launch identity can only be judged
                // by their pane. They cannot bind a watch floor to an attempt.
                && (lane.mail_root_confirmed || identity_of(lane).is_some())
                && matches!(host.status, Some(Ok(HostStatus::Running)))
                && hosts.of(lane).is_ok_and(|caps| {
                    caps.launch == Some(hosted::Launch::Ssh) && caps.files == Files::Verb
                })
            {
                host.rows = Some(ssh_claude_rows(lane, pass, &mut out));
            }
            let failed_status = matches!(host.status, Some(Err(_)));
            let mut obs = read_lane(lane, pass.readers, &sockets, host, None);
            // The lane status verb carries this cause as unjudged. The
            // watch reports that failed provider read as lane-unreadable.
            if failed_status && let LaneState::Unjudged { cause } = obs.state {
                obs.state = LaneState::Unreadable { cause };
            }
            Some(obs)
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
    let observed_lanes: Vec<&Lane> = observed
        .iter()
        .filter(|o| !o.hosted_unreadable())
        .map(|o| o.lane)
        .collect();
    hosted::retry_pending_closes(&observed_lanes, pass, &hosts, &mut out);
    wall_pauses(&walls, pass, &mut out);
    hosted::prepare(pass, &mut out);
    hosted::cloud_stalls(pass, &hosts, &mut out);
    // The close verb can remove a sandbox and settle its lane in this
    // duty. The file readers below need that record, even if the verb's
    // reply was lost.
    let current;
    let pass = if in_flight
        .iter()
        .any(|lane| hosts.of(lane).is_ok_and(|caps| caps.files == Files::Verb))
    {
        current = match read_fleet(pass.fleet_path) {
            Ok(fleet) => fleet,
            Err(cause) => {
                fail(&mut out, format!("fleet-read-failed cause={cause}"));
                return out;
            }
        };
        &Pass {
            fleet: &current,
            ..*pass
        }
    } else {
        pass
    };
    for lane in pass
        .fleet
        .lanes
        .iter()
        .filter(|lane| lane.status.in_flight())
    {
        start_stall(lane, pass, &hosts, &mut out);
    }
    lane_long(pass, &hosts, &mut out);
    handoffs(pass, &hosts, &mut out);
    model_facts(pass, &hosts, &mut out);
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
            // A launch whose host has not named the root yet: the pass reads
            // nothing and keeps the row, so a record already said is not said
            // again. Past preparing, a pending root is the read's failure.
            Ok(Files::Verb)
                if lane.status == LaneStatus::Preparing && hosted::root_pending(lane) =>
            {
                continue;
            }
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
    let reported_here = |row: &str| row.strip_suffix("|reported") == Some(pane_key.as_str());
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
        } => wall(obs, *kind, banner, *source, &slice, pass, cap, out),
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
    if !obs.hosted_unreadable()
        && !matches!(
            state,
            LaneState::Gone | LaneState::Exited | LaneState::Idle { .. }
        )
    {
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
            // A launched harness execs in its window's shell, so its exit
            // closes the window: the commonest exit reads gone.
            restart_exited(obs, pass, out);
            return reading;
        }
        LaneState::Unreadable { cause } => {
            // A failed hosted read breaks the sequence of exit readings.
            // Keep a report for this pane unless the provider read it running.
            if obs.hosted_unreadable()
                && get("lane-exited")
                    .is_some_and(|prior| obs.provider_running || !reported_here(&prior))
            {
                out.changes.push(clear("lane-exited", lane));
                if get(hosted::CLOSE_PENDING_ROW)
                    .is_some_and(|pending| pending.starts_with("lane-exited|"))
                {
                    out.changes.push(clear(hosted::CLOSE_PENDING_ROW, lane));
                }
            }
            report_unreadable(out, pass.baseline, "lane-unreadable", lane, cause);
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
        if prior.as_deref().is_some_and(reported_here) {
            // A restart a halt or a refusal held is asked again.
            restart_exited(obs, pass, out);
            return reading;
        }
        if prior.as_deref() == Some(pane_key.as_str()) {
            out.events.push(Event::LaneExited { lane: lane.clone() });
            out.events.extend(payload(report_tail(&slice, cap)));
            out.changes
                .push(set("lane-exited", lane, format!("{pane_key}|reported")));
            out.changes.push(clear("lane-asking", lane));
            hosted::close_finished(obs.lane, pass, hosts, "lane-exited", &pane_key, false, out);
            restart_exited(obs, pass, out);
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
    // per pane, row position, confirmed wake and slice, on the first pass for
    // a local Codex lane below a prior turn and on two passes otherwise;
    // the line carries the
    // stop's cause where the verdict kept one, so a turn its output limit
    // cut is told apart from a finished one, whose line carries none, else
    // a Copilot lane's policy note, keyed as the asking line keys it. A
    // turn a continuation resumes takes no line while its session is
    // reached ([`continue_lane`]).
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
            let wakes = match wake::load_record(&pass.state_dir.join(wake::WAKE_FILE)) {
                Ok(wakes) => wakes,
                Err(error) => {
                    fail(out, error.to_string());
                    return reading;
                }
            };
            let prior = get("lane-idle").unwrap_or_default();
            let confirmed_wake = wakes.get(&obs.lane.item).and_then(|mark| {
                matches!(
                    mark.outcome,
                    Some(crate::ops::wake::WakeOutcome::Delivered { .. })
                )
                .then(|| format!("Some({})", mark.at))
            });
            // The latest mark can replace a delivery with a limit. Keep
            // the wake stamp already seen for this pane in that case.
            let wake_at = confirmed_wake
                .as_deref()
                .or_else(|| {
                    prior
                        .strip_prefix(&pane_key)?
                        .strip_prefix('|')?
                        .split('|')
                        .nth(1)
                })
                .unwrap_or("None");
            let position = obs.row.as_ref().map(|row| row.position);
            let note = cause
                .as_ref()
                .map(|word| format!("cause={word}"))
                .or_else(|| copilot_note(obs.lane, pass));
            let key = keyed(
                format!("{pane_key}|{position:?}|{wake_at}|{}", hash_of(&slice)),
                note.as_deref(),
            );
            let reported = prior == format!("{key}|reported");
            // A hosted lane's screen between a finished tool call and the
            // next reads the same, so only a local lane's is believed at once.
            let codex_after_turn = obs.lane.harness.as_deref() == Some("codex")
                && hosted::host_of(obs.lane) == "local"
                && obs.screen.as_deref().is_some_and(|s| s != slice);
            if !(reported || prior == key || codex_after_turn) {
                out.changes.push(set("lane-idle", lane, key));
                return reading;
            }
            let continuation = cause.as_deref().filter(|cause| {
                obs.lane
                    .harness
                    .as_deref()
                    .and_then(Harness::parse)
                    .is_some_and(|harness| {
                        wake::can_continue(harness, cause, is_reading_lane(&obs.lane.item))
                    })
            });
            // Only a lane whose merge landed and whose work has left its
            // host ([`hosted::work_left`], the finished close's own read)
            // takes the line and the close below, never a resume or a move,
            // a merge read after this turn's continuation was asked
            // included: the rows it clears are its mark of being told. A
            // merged lane whose work is live, whose merge is undated or
            // whose read fails is resumed and moved like an unmerged one.
            let owed = get(wake::RESUME_KIND).is_some() || get(PROVIDER_ROW).is_some();
            let left = (continuation.is_some() || owed)
                && matches!(
                    super::github::finished_merge(pass.baseline, obs.lane),
                    super::github::FinishedMerge::Eligible { .. }
                )
                && hosts.of(obs.lane).ok().is_some_and(|caps| {
                    matches!(hosted::work_left(obs.lane, pass, &caps), Some(Answer::Gone))
                });
            if let Some(cause) = continuation
                && !left
                && wake::reaches(obs.lane, hosts.of(obs.lane).ok())
            {
                if !reported {
                    out.changes
                        .push(set("lane-idle", lane, format!("{key}|reported")));
                }
                continue_lane(obs, cause, &key, &wakes, pass, out);
                return reading;
            }
            let continued = left && owed;
            if reported && !continued {
                return reading;
            }
            out.changes
                .push(set("lane-idle", lane, format!("{key}|reported")));
            out.changes.push(clear(wake::RESUME_KIND, lane));
            out.changes.push(clear(PROVIDER_ROW, lane));
            out.events.push(Event::IdleAfterReturn {
                lane: lane.clone(),
                note,
            });
            out.events.extend(payload(bounded_tail(&slice, cap)));
            hosted::close_finished(obs.lane, pass, hosts, "lane-idle", &key, false, out);
        }
        // A pass that reads no stopped turn ends a first sighting, which two
        // consecutive idle passes confirm, but never a told one: the told
        // key's own parts tell the next turn apart, and one transient
        // reading between two idle passes would otherwise tell the same
        // stop again.
        LaneState::Walled { .. }
        | LaneState::Asking
        | LaneState::RateLimitSwitch
        | LaneState::Working
        | LaneState::Unjudged { .. } => {
            if get("lane-idle").is_some_and(|row| !row.ends_with("|reported")) {
                out.changes.push(clear("lane-idle", lane));
            }
            out.changes.push(clear("model-capacity", lane));
        }
        // These returned above, the pane or session they key on ended.
        LaneState::Gone | LaneState::Unreadable { .. } | LaneState::Exited => {
            out.changes.push(clear("lane-idle", lane));
            out.changes.push(clear("model-capacity", lane));
        }
    }
    reading
}

/// The lane and wake duties each own their read and clear their own row.
pub(super) fn report_unreadable(
    out: &mut Produced,
    baseline: &Baseline,
    kind: &str,
    lane: &str,
    cause: &str,
) {
    if baseline.get(kind, lane) != Some(cause) {
        out.events.push(Event::LaneUnreadable {
            lane: lane.to_owned(),
            cause: cause.to_owned(),
        });
        out.changes.push(set(kind, lane, cause.to_owned()));
    }
}

/// A worker whose turn ended on a continuation cause is resumed on its own
/// account once per pass while the stop stands: each resume the wake
/// delivered is followed by a fresh row (`<cause>|<key>|pass:<epoch>`),
/// which the wake types once, and one it has not typed, or refused,
/// stands, since the wake tells a refused one itself. A row the wake does
/// not resume, such as an earlier watch's `told|<key>`, is replaced. A
/// provider stop takes `stop::action`'s answer: past
/// `stop::PROVIDER_PATIENCE` since the episode's first stopped turn, under
/// `ORCH_WALL_RELAUNCH=auto` with no halt standing, the walk over the lane
/// preference less the lane's own provider is read, and an entry with room
/// takes the lane, its brief naming the prior transcript; with none it is
/// resumed still. A move refused, or a walk that could not judge, is told
/// once while its reason stands as `idle-after-return` with the refusal
/// under it ([`said_once`]). The episode
/// stands as [`stop::standing`] judges it; the first finished turn ends it.
fn continue_lane(
    obs: &Observed,
    cause: &str,
    key: &str,
    wakes: &crate::ops::wake::WakeRecord,
    pass: &Pass,
    out: &mut Produced,
) {
    let lane = &obs.name;
    let marker = wall::relaunch_marker_path(watch_state_dir(pass.claim_store), lane);
    match relaunch_pending(&marker, pass.settings.prepare, pass.now) {
        RelaunchPending::None => {}
        // The move this episode started still owns the lane.
        RelaunchPending::Pending => return,
        RelaunchPending::Unreadable { path, cause } => {
            fail(
                out,
                format!("state-read-failed path={} cause={cause}", path.display()),
            );
            return;
        }
    }
    let episode = pass.baseline.get(PROVIDER_ROW, lane).and_then(|value| {
        let mut fields = value.split('|');
        let recorded = stop::Episode {
            since: fields.next()?.parse().ok()?,
            last: fields.next()?.parse().ok()?,
        };
        let since = stop::standing(Some(recorded), pass.now)?;
        Some((since, fields.next()))
    });
    let (since, told) = episode.unwrap_or((pass.now, None));
    let row = |said: Option<&str>| match said {
        Some(said) => format!("{since}|{}|{said}", pass.now),
        None => format!("{since}|{}", pass.now),
    };
    out.changes.push(set(PROVIDER_ROW, lane, row(told)));
    let tell = |out: &mut Produced, reason: &str| {
        let (news, said) = said_once(told, reason);
        if !news {
            return;
        }
        out.events.push(Event::IdleAfterReturn {
            lane: lane.clone(),
            note: Some(format!("cause={cause}")),
        });
        out.events.push(Event::Tail(format!(
            "provider-move-refused lane={lane} reason={reason}"
        )));
        out.changes.push(set(PROVIDER_ROW, lane, row(Some(&said))));
    };
    let age = Duration::from_secs(pass.now.saturating_sub(since));
    if let Some(harness) = obs.lane.harness.as_deref().and_then(Harness::parse)
        && stop::of_cause(harness, cause) == Some(Kind::Provider)
    {
        // The walk is read only once the patience has passed, since no
        // walk's answer moves a younger stop.
        let found = (age >= stop::PROVIDER_PATIENCE
            && pass.route.relaunch == WallRelaunch::Auto
            && halt_reason(obs, pass).is_none())
        .then(|| match &pass.route.host {
            Err(cause) => Found::Unjudged(cause.clone()),
            Ok(fleet) => {
                match provider_walk(obs.lane, harness, pass.route.preference, fleet.as_deref()) {
                    Some(request) => walked(&obs.lane.item, &request, pass),
                    None => Found::None,
                }
            }
        });
        let ground = stop::Ground {
            own_room: true,
            room: matches!(found, Some(Found::Destination(_))),
            reset: false,
            resets: &[],
        };
        match (
            stop::action(Kind::Provider, age, Session::Worker, ground),
            found,
        ) {
            (Action::MoveProvider, Some(Found::Destination(to))) => {
                match move_provider(obs, harness, &to, pass, out) {
                    Ok(()) => {
                        out.events.push(Event::Tail(format!(
                            "provider-move cause={cause} since={}",
                            clock::iso_utc(since)
                        )));
                        out.changes.push(clear(PROVIDER_ROW, lane));
                        out.changes.push(clear(wake::RESUME_KIND, lane));
                        return;
                    }
                    Err(reason) => tell(out, &reason),
                }
            }
            (Action::Resume, Some(Found::Unjudged(cause))) => {
                tell(out, &format!("walk-unjudged {cause}"));
            }
            (Action::Resume, None | Some(Found::None | Found::Destination(_))) => {}
            (action @ Action::MoveProvider, None | Some(Found::None | Found::Unjudged(_)))
            | (
                action @ (Action::MoveAccount { .. }
                | Action::WaitForReset
                | Action::Notify { .. }
                | Action::NotifyReset { .. }),
                _,
            ) => tell(out, &format!("action-unexpected action={action:?}")),
        }
    }
    let asked = pass.baseline.get(wake::RESUME_KIND, lane);
    // A wall's resume is the wall route's, never this episode's.
    let answered = asked.is_none_or(|row| {
        !wake::asks_resume(row)
            || row
                .split_once('|')
                .is_some_and(|(c, _)| c == wake::WALL_CAUSE)
            || wakes.get(&obs.lane.item).is_some_and(|mark| {
                mark.resume.as_deref() == Some(row)
                    && matches!(
                        mark.outcome,
                        Some(crate::ops::wake::WakeOutcome::Delivered { .. })
                    )
            })
    });
    if !answered {
        return;
    }
    out.changes.push(set(
        wake::RESUME_KIND,
        lane,
        format!("{cause}|{key}|pass:{}", pass.now),
    ));
}

/// An exited local lane, its harness gone under a live window or with its
/// window, and its item not merged, is started again under
/// `ORCH_WALL_RELAUNCH=auto` with no halt standing: the record's own
/// relaunch on its own account, which `effects::relaunch::composed` judges
/// ended by the record's process identity and judges room on, resuming
/// the session the record binds and closing its last attempt on the
/// `restart-recovery` ground. Each pass that reads the exit asks again
/// while no restart started, a refusal said once while it stands. An
/// assignment is restarted once: a later exit, on another pane, is said as
/// `second-death` once and relaunches nothing. A hosted lane's exit is its
/// provider's close's ([`hosted::close_finished`]). A refusal is said
/// under the `lane-exited` or `window-gone` line.
fn restart_exited(obs: &Observed, pass: &Pass, out: &mut Produced) {
    if pass.route.relaunch != WallRelaunch::Auto
        || hosted::host_of(obs.lane) != "local"
        || !matches!(
            super::github::finished_merge(pass.baseline, obs.lane),
            super::github::FinishedMerge::None
        )
    {
        return;
    }
    let lane = &obs.name;
    let attempt = obs.lane.launched_at.as_deref().unwrap_or("-");
    let death = hash_of(obs.pane_key.as_deref().unwrap_or_default()).to_string();
    let prior: Vec<&str> = pass
        .baseline
        .get(RESTART_ROW, lane)
        .map(|row| row.split('|').collect())
        .unwrap_or_default();
    let told = match prior.as_slice() {
        [_, at, ..] if *at != attempt => None,
        ["owed", _, told] => Some(*told),
        ["started", _, restarted] if *restarted == death => return,
        ["started", _, _] => {
            out.events.push(Event::Tail(format!(
                "relaunch-refused lane={lane} reason=second-death"
            )));
            out.changes
                .push(set(RESTART_ROW, lane, format!("dead|{attempt}")));
            return;
        }
        ["dead", _] => return,
        _ => None,
    };
    // A refusal told under `reason`, said once while its `mark` stands.
    let refused_as = |out: &mut Produced, mark: &str, reason: &str| {
        let (news, said) = said_once(told, mark);
        if news {
            out.events.push(Event::Tail(format!(
                "relaunch-refused lane={lane} reason={reason}"
            )));
        }
        out.changes
            .push(set(RESTART_ROW, lane, format!("owed|{attempt}|{said}")));
    };
    let refused = |out: &mut Produced, reason: &str| refused_as(out, reason, reason);
    if let Some(halt) = halt_reason(obs, pass) {
        return refused_as(out, &halt.mark, &halt.reason);
    }
    let RecordRelaunch {
        close,
        launch,
        account,
    } = match (pass.route.exited)(obs.lane) {
        Ok(relaunch) => relaunch,
        Err(cause) => return refused(out, &cause),
    };
    // The relaunch's own judge read the account it lands on with room.
    let ground = stop::Ground {
        own_room: true,
        room: false,
        reset: false,
        resets: &[],
    };
    match stop::action(Kind::Exited, Duration::ZERO, Session::Worker, ground) {
        Action::Resume => {}
        action @ (Action::MoveAccount { .. }
        | Action::MoveProvider
        | Action::WaitForReset
        | Action::Notify { .. }
        | Action::NotifyReset { .. }) => {
            return refused(out, &format!("action-unexpected action={action:?}"));
        }
    }
    let Some(cwd) = obs
        .lane
        .mail_root
        .as_deref()
        .and_then(|root| std::fs::canonicalize(root).ok())
    else {
        return refused(out, "checkout-unavailable");
    };
    let close = match &close {
        RecordClose::Request(path) => Some(path.as_path()),
        RecordClose::Confirmed(_) => None,
    };
    let recovery = Recovery {
        cwd,
        session: pass.session.map(str::to_owned).unwrap_or_default(),
        args: relaunch_args(pass, close, &launch),
    };
    let account = account.unwrap_or_else(|| "-".to_owned());
    match start_recovery(obs, pass, out, recovery, &account, &account) {
        Ok(()) => out
            .changes
            .push(set(RESTART_ROW, lane, format!("started|{attempt}|{death}"))),
        Err(reason) => refused(out, &reason),
    }
}

/// Move the observed lane to `to`, an entry on another provider the walk
/// found room on, through the record's relaunch with the brief naming its
/// prior transcript; `Err` is the refusal's reason.
fn move_provider(
    obs: &Observed,
    harness: Harness,
    to: &Destination,
    pass: &Pass,
    out: &mut Produced,
) -> Result<(), String> {
    let spent = obs.lane.account.clone().unwrap_or_else(|| "-".to_owned());
    let recovery = relaunch_request(
        obs.lane,
        harness,
        to,
        Leaves::Provider,
        RecoveryReason::UsageLimit,
        None,
        pass,
    )
    .map_err(|cause| format!("context-unavailable cause={cause}"))?;
    start_recovery(obs, pass, out, recovery, &to.account, &spent)
}

/// A line's key with the note the line carries, so a changed note is news
/// under an unchanged screen.
fn keyed(key: String, note: Option<&str>) -> String {
    match note {
        Some(note) => format!("{key}|{note}"),
        None => key,
    }
}

/// Whether a refusal `said` is news against the mark `prior` its row kept,
/// and the mark to keep: a refusal is told once while it stands, and a
/// changed one is told again. A mark no refusal hashes to, such as a
/// legacy row's `told`, makes the next refusal news once.
fn said_once(prior: Option<&str>, said: &str) -> (bool, String) {
    let mark = hash_of(said).to_string();
    (prior != Some(mark.as_str()), mark)
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
    reason = "the wall's inputs are the observation, the judge's three words, the slice, the pass, the cap and the sink"
)]
fn wall(
    obs: &Observed,
    kind: WallKind,
    banner: &str,
    source: WallSource,
    slice: &str,
    pass: &Pass,
    cap: usize,
    out: &mut Produced,
) -> (LaneState, WallReading) {
    let lane = &obs.name;
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
    let row_text = obs
        .row
        .as_ref()
        .and_then(|row| row.message.as_deref())
        .unwrap_or_default();
    let text = match source {
        WallSource::Rows => row_text,
        WallSource::Pane => banner,
    };
    let hash = hash_of(text).to_string();
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
    let auth = kind == WallKind::Auth;
    let evidence = match age {
        WallAge::Current => source,
        WallAge::Older | WallAge::Unjudged { .. } if auth && obs.current_auth_row() => {
            WallSource::Rows
        }
        WallAge::Older => return unjudged("wall-predates-process"),
        WallAge::Unjudged { cause } => return unjudged(cause),
    };
    // Keep the pane's original sighting and hash for its age check,
    // deduplication and standing pause.
    let observed = WallReading::Walled { first_seen };
    let walled = LaneState::Walled {
        kind,
        banner: if evidence == WallSource::Pane {
            banner.to_owned()
        } else {
            String::new()
        },
        source: evidence,
    };
    let identity = identity_word(obs.identity.as_ref());
    // The reset the banner states decides which event this is: pinned to the
    // first sighting, never to this pass, so a dayless clause names the day
    // the wall was seen on; a login wall has no reset.
    let channel = match evidence {
        WallSource::Pane => WallChannel::Pane,
        WallSource::Rows => WallChannel::Row,
    };
    let reset_at = if auth {
        None
    } else {
        let report = account_wall::harness_own_limit(text, channel);
        reset::reported_epoch(text, report, first_seen, pass.readers.zone)
    };
    let passed = reset_at.is_some_and(|at| at <= pass.now);
    let reported = format!(
        "usage-limit{}{}",
        if passed { "-passed" } else { "" },
        if auth { ":auth" } else { "" }
    );
    let same_wall = same_banner && prior.get(2).is_some_and(|i| *i == identity);
    // A relaunch from before the reset leaves the passed wall to the wake;
    // one from after it (`lane-relaunched|passed`) owns the lane still.
    let relaunched_after = prior.get(4).is_some_and(|r| r == "passed");
    let quiet = same_wall
        && prior.get(3).is_some_and(|r| {
            *r == reported || (r == "lane-relaunched" && (!passed || relaunched_after))
        });
    // The halt refusal that held this wall, by its mark (`held:MARK`): a
    // pass under the same refusal says nothing, and a changed one is told
    // as the first was. A bare `held`, as a watch before the mark wrote it,
    // is a held wall whose refusal no mark names: its next refusal is told
    // once, and a cleared halt still takes the passed reset's resume.
    let held = prior
        .get(5)
        .filter(|_| same_wall)
        .and_then(|r| match r.as_str() {
            "held" => Some(""),
            r => r.strip_prefix("held:"),
        });
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
                    banner: text.to_owned(),
                    channel,
                },
            )
            .map_err(crate::Error::from)
        })
        .err()
        .map(|e| e.to_string());
    // The line's body: the lane, the account it spends where one is
    // named (an ended sign-in's the home its inherited credentials ran
    // under where the record names none), `resets=` where read,
    // `wall_kind=auth`.
    let mut line = lane.clone();
    let named = if auth {
        spent_account(obs.lane)
    } else {
        Some(account.as_str()).filter(|a| !a.is_empty())
    };
    if let Some(named) = named {
        line.push(' ');
        line.push_str(named);
    }
    if let Some(at) = reset_at {
        line.push_str(" resets=");
        line.push_str(&clock::iso_utc(at));
    }
    if auth {
        line.push_str(" wall_kind=auth");
    }
    if quiet && !rewalled && held.is_none() {
        // A wall no relaunch took is walked again on each later pass under
        // the same banner, before its reset and after it while the lane
        // still sits at it, so an account that gains room takes the lane
        // with nobody starting it. A refusal is said once while it stands.
        if pass.route.relaunch == WallRelaunch::Auto
            && prior.get(3).is_some_and(|r| r != "lane-relaunched")
        {
            let mut notes = Vec::new();
            let said = match route(obs, kind, reset_at.is_some(), pass, out, &mut notes) {
                Routed::Relaunched { .. } => {
                    let mut row = format!("{first_seen}|{hash}|{identity}|lane-relaunched");
                    // The passed wall's own-account resume goes with it.
                    if passed {
                        row.push_str("|passed");
                        out.changes.push(clear(wake::RESUME_KIND, lane));
                    }
                    out.changes.push(set("usage-limit", lane, row));
                    None
                }
                Routed::Opening => return unjudged("auth-recovery-opening"),
                Routed::Waiting => None,
                Routed::Held { mark } => Some(mark),
                Routed::Left => Some(notes.join("\n")),
            };
            if let Some(said) = said {
                let (news, said) = said_once(prior.get(6).map(String::as_str), &said);
                if news {
                    out.events.push(Event::UsageLimit { passed, line });
                    out.events.extend(notes.into_iter().map(Event::Tail));
                    let mut row = prior.clone();
                    row.resize(7, String::new());
                    row[6] = said;
                    out.changes.push(set("usage-limit", lane, row.join("|")));
                }
            }
        }
        return (walled, observed);
    }
    let lines = match evidence {
        WallSource::Rows => row_text.lines().map(str::to_owned).collect(),
        WallSource::Pane => match banner_payload(slice, banner, cap) {
            Some(lines) => lines,
            // The judge and the payload disagree on where the banner is:
            // nothing is printed and the wall stays unjudged this pass.
            None => return unjudged("banner-missing"),
        },
    };
    let mut notes = Vec::new();
    let mut retry = String::new();
    let told_at = out.events.len();
    match reset_at.filter(|_| passed) {
        None => match route(obs, kind, reset_at.is_some(), pass, out, &mut notes) {
            Routed::Relaunched { tell } => {
                // A move is the relaunch's line alone, but for the owner the
                // table tells, once: the line goes before the relaunch's.
                if tell {
                    out.events
                        .insert(told_at, Event::UsageLimit { passed, line });
                }
                out.changes.push(set(
                    "usage-limit",
                    lane,
                    format!("{first_seen}|{hash}|{identity}|lane-relaunched"),
                ));
                return (walled, observed);
            }
            Routed::Opening => return unjudged("auth-recovery-opening"),
            Routed::Held { mark } => {
                let (news, mark) = said_once(held, &mark);
                if !news {
                    return (walled, observed);
                }
                retry = format!("held:{mark}");
            }
            Routed::Left | Routed::Waiting => {}
        },
        // A passed reset: the wake resumes the lane it reaches, once per
        // wall, and the note says whether it will.
        Some(_) if rewalled => {
            notes.push("resume walled".to_owned());
            out.changes.push(clear(wake::RESUME_KIND, lane));
        }
        Some(at) => {
            let resumable = wake::resumable(obs.lane);
            if (held.is_some() || resumable)
                && let Some(halt) = halt_reason(obs, pass)
            {
                let (news, mark) = said_once(held, &halt.mark);
                if !news {
                    return (walled, observed);
                }
                notes.push(format!("resume held reason={}", halt.reason));
                retry = format!("held:{mark}");
            } else if resumable {
                notes.push("resume wake".to_owned());
                out.changes.push(set(
                    wake::RESUME_KIND,
                    lane,
                    format!("{}|{identity}|{at}", wake::WALL_CAUSE),
                ));
            } else {
                notes.push("resume unreached".to_owned());
            }
        }
    }
    // The walk's notes are what a later walk compares with; a passed
    // reset's resume note walked nothing, so the last walk's mark stands.
    let said = if reset_at.filter(|_| passed).is_none() {
        said_once(None, &notes.join("\n")).1
    } else {
        prior
            .get(6)
            .filter(|_| same_wall)
            .cloned()
            .unwrap_or_default()
    };
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
        format!("{first_seen}|{hash}|{identity}|{reported}|{screen}|{retry}|{said}"),
    ));
    (walled, observed)
}

/// What the wall route did with a walled lane.
enum Routed {
    /// The relaunch started and `lane-relaunched` is out; `tell` is the
    /// table's notice for the wall's line ([`Action::MoveAccount`]).
    Relaunched { tell: bool },
    /// A replacement's open launch still owns the outcome.
    Opening,
    /// The mailbox holds the relaunch, under the halt's `mark`
    /// ([`Halt`]). Check it again even if the wall passes.
    Held { mark: String },
    /// The wall is left to the overseer; `notes` carry the walk's answer
    /// and any refusal, or that nothing recovers the lane.
    Left,
    /// No account has room and the wall's reset is named: the lane waits.
    Waiting,
}

enum AuthRecovery {
    Ready,
    Opening,
    AwaitingTurn,
}

/// The current launch follows a confirmed auth close in the intent journal.
/// A subsequent launch after another disposition starts a new recovery.
fn auth_recovery(lane: &Lane, pass: &Pass) -> Result<AuthRecovery, String> {
    let mut transitions = pass.fleet.intents.iter().rev().filter(|intent| {
        intent.target == lane.item
            && intent.reconciled.is_none()
            && ((intent.op == EffectOp::LaunchSession
                && (intent.outcome == Outcome::Confirmed || intent.open()))
                || (intent.op == EffectOp::CloseResources && intent.outcome == Outcome::Confirmed))
    });
    let (Some(launch), Some(close)) = (transitions.next(), transitions.next()) else {
        return Ok(AuthRecovery::Ready);
    };
    if launch.op != EffectOp::LaunchSession
        || lane.session_since.as_deref() != Some(launch.created_at.as_str())
        || close.op != EffectOp::CloseResources
    {
        return Ok(AuthRecovery::Ready);
    }
    let fleet = pass.state_dir.join(agent_runtime::record::FLEET_FILE_NAME);
    let members = LaneMembers::of(&fleet, close).map_err(|e| e.to_string())?;
    if !matches!(members.close, Some(CloseGround::NoLanding { reason, .. })
        if RecoveryReason::read(&reason) == Some(RecoveryReason::AuthWall))
    {
        return Ok(AuthRecovery::Ready);
    }
    if launch.open() {
        return Ok(AuthRecovery::Opening);
    }
    Ok(if completed_turn_since_launch(lane)? {
        AuthRecovery::Ready
    } else {
        AuthRecovery::AwaitingTurn
    })
}

/// A Stop row that ends a turn with no error follows a completed turn: Claude
/// Code's, and Pi's, whose carrier writes the turn's `stop_reason` and its
/// working-agent count. Startup idleness and open-turn rows can both occur
/// before the replacement's credentials have worked.
#[allow(
    clippy::disallowed_methods,
    reason = "the wall route reads the lane's turn rows after its recorded launch position"
)]
fn completed_turn_since_launch(lane: &Lane) -> Result<bool, String> {
    let (Some(at), Some(root)) = (lane.session_rows_at_launch, lane.mail_root.as_deref()) else {
        return Ok(false);
    };
    let harness = lane.harness.as_deref();
    if hosted::host_of(lane) != "local" || !matches!(harness, Some("claude" | "pi")) {
        return Ok(false);
    }
    let file = lane_rows_file(root, &lane.item);
    let text = match std::fs::read_to_string(&file) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(e) => return Err(format!("rows-unreadable path={} cause={e}", file.display())),
    };
    Ok(rows::rows_after_in(&text, at as u64).any(|reading| {
        matches!(
            reading,
            Reading::Live(row)
                if row.harness.as_deref() == harness
                    && row.event.as_deref() == Some("Stop")
                    && matches!(rows::judge_lane(&row), Reading::Live(LaneVerdict::Idle { cause: None }))
        )
    }))
}

/// A standing halt, or a halt read the mailbox refused: `reason` is the
/// told text, and `mark` what a later pass compares to say it once while it
/// stands. A refusal's cause text, stderr or reply line can carry a
/// timestamp, pid or path that changes from pass to pass, so the mark keeps
/// only what stays fixed under one refusal: its verb and kind, and an
/// exit's status and keyed line's key and value, which names the repair
/// (`command-missing=jq`, then `command-missing=date` once jq is back).
struct Halt {
    mark: String,
    reason: String,
}

fn halt_reason(obs: &Observed, pass: &Pass) -> Option<Halt> {
    if pass.route.relaunch != WallRelaunch::Auto {
        return None;
    }
    match (pass.route.halted)(obs.lane) {
        Ok(false) => None,
        Ok(true) => Some(Halt {
            mark: "halted".to_owned(),
            reason: "halted".to_owned(),
        }),
        Err(cause) => {
            let kind = match &cause {
                Refusal::NotStarted { .. } => "not-started".to_owned(),
                Refusal::Unanswered { .. } => "unanswered".to_owned(),
                Refusal::Exit { status, keyed, .. } => {
                    let status = status.map_or_else(|| "signal".to_owned(), |c| c.to_string());
                    // `lane-mail --help`'s keyed line: `<key>=<value>`, or a
                    // key whose value follows its own ` field=`, closed by
                    // trailing fields that may change from pass to pass.
                    let pair = keyed
                        .as_deref()
                        .and_then(|line| {
                            let (key, rest) = line.split_once('=')?;
                            let value = rest.split_whitespace().next().unwrap_or_default();
                            Some(format!("{key}={value}"))
                        })
                        .unwrap_or_else(|| "unkeyed".to_owned());
                    format!("exit status={status} key={pair}")
                }
                Refusal::Reply { cause, .. } => format!("reply-{cause}"),
            };
            Some(Halt {
                mark: format!("halt-unread verb={} {kind}", cause.verb()),
                reason: format!("halt-unread cause={cause}"),
            })
        }
    }
}

/// A usage or auth wall walks the lane preference, then the lane's own
/// harness, for an account with room, the spent account left out, so an
/// ended sign-in never relaunches on the account it ended on, and prints
/// the walk's answer under the event; `stop::action` judges the walled
/// account's stop on that answer and on whether the wall's reset is named
/// (`reset`). Under `ORCH_WALL_RELAUNCH=auto` a move takes the lane to the
/// walk's destination through the record's own relaunch, started detached
/// through the one runner, its marker written first for the outcome reader
/// ([`start_recovery`]). A relaunch refused after the walk is said under
/// the event, after the walk's line, and never asked again this pass; a
/// stop nothing recovers says `recovery-stopped` with its cause.
fn route(
    obs: &Observed,
    kind: WallKind,
    reset: bool,
    pass: &Pass,
    out: &mut Produced,
    notes: &mut Vec<String>,
) -> Routed {
    let lane = &obs.name;
    let refused = |notes: &mut Vec<String>, reason: &str| {
        notes.push(format!("wall-relaunch-refused lane={lane} reason={reason}"));
        Routed::Left
    };
    let harness = obs.lane.harness.as_deref().and_then(Harness::parse);
    let model = obs.lane.model.as_deref().unwrap_or("");
    let (Some(harness), false) = (harness, model.is_empty()) else {
        return refused(notes, "record-unnamed");
    };
    if let Some(halt) = halt_reason(obs, pass) {
        notes.push(format!(
            "wall-relaunch-refused lane={lane} reason={}",
            halt.reason
        ));
        return Routed::Held { mark: halt.mark };
    }
    let Some(spent) = spent_account(obs.lane) else {
        return refused(notes, "account-unknown");
    };
    let recovery = match kind {
        WallKind::Auth => match auth_recovery(obs.lane, pass) {
            Ok(recovery) => recovery,
            Err(cause) => return refused(notes, &format!("auth-recovery-unread cause={cause}")),
        },
        WallKind::Usage => AuthRecovery::Ready,
    };
    match (pass.route.relaunch, recovery) {
        (_, AuthRecovery::Opening) => return Routed::Opening,
        (WallRelaunch::Auto, AuthRecovery::AwaitingTurn) => {
            return refused(notes, "auth-recovery-unconfirmed");
        }
        (
            WallRelaunch::Ask | WallRelaunch::Auto,
            AuthRecovery::Ready | AuthRecovery::AwaitingTurn,
        ) => {}
    }
    let fleet = match &pass.route.host {
        Ok(fleet) => fleet.as_deref(),
        Err(cause) => {
            notes.push(format!("pick unjudged {cause}"));
            return Routed::Left;
        }
    };
    let Some(request) = account_walk(
        obs.lane,
        harness,
        model,
        spent,
        pass.route.preference,
        fleet,
    ) else {
        notes.push("pick unjudged walk-empty".to_owned());
        return Routed::Left;
    };
    let to = match walked(&obs.lane.item, &request, pass) {
        Found::Destination(to) => {
            notes.push(to.note(harness, model));
            Some(to)
        }
        Found::None => {
            notes.push("pick none".to_owned());
            None
        }
        Found::Unjudged(cause) => {
            notes.push(format!("pick unjudged {cause}"));
            return Routed::Left;
        }
    };
    // The walled account itself has no room: the wall is that reading.
    let ground = stop::Ground {
        own_room: false,
        room: to.is_some(),
        reset,
        resets: &[],
    };
    let to = match (
        stop::action(Kind::from(kind), Duration::ZERO, Session::Worker, ground),
        to,
    ) {
        (Action::MoveAccount { tell }, Some(to)) => (to, tell.is_some()),
        (Action::WaitForReset, None) => return Routed::Waiting,
        (Action::Notify { .. }, None) => {
            notes.push(format!(
                "recovery-stopped cause={}",
                match kind {
                    WallKind::Auth => "no-other-account",
                    WallKind::Usage => "no-room-no-reset",
                }
            ));
            return Routed::Left;
        }
        (action @ Action::MoveAccount { .. }, None)
        | (action @ (Action::WaitForReset | Action::Notify { .. }), Some(_))
        | (action @ (Action::Resume | Action::MoveProvider | Action::NotifyReset { .. }), _) => {
            return refused(notes, &format!("action-unexpected action={action:?}"));
        }
    };
    let (to, tell) = to;
    if pass.route.relaunch == WallRelaunch::Ask {
        return Routed::Left;
    }
    if account_wall::canon(&to.account) == account_wall::canon(spent) {
        return refused(notes, "spent-account");
    }
    let ground = match kind {
        WallKind::Usage => RecoveryReason::UsageLimit,
        WallKind::Auth => RecoveryReason::AuthWall,
    };
    match relaunch_request(
        obs.lane,
        harness,
        &to,
        Leaves::Account,
        ground,
        Some(spent),
        pass,
    ) {
        Ok(recovery) => match start_recovery(obs, pass, out, recovery, &to.account, spent) {
            Ok(()) => Routed::Relaunched { tell },
            Err(reason) => refused(notes, &reason),
        },
        Err(cause) => refused(notes, &format!("context-unavailable cause={cause}")),
    }
}

/// The account a lane spends: its record's, else the home its last launch
/// ran under on inherited credentials.
fn spent_account(lane: &Lane) -> Option<&str> {
    [&lane.account, &lane.home]
        .into_iter()
        .find_map(|a| a.as_deref().filter(|a| !a.is_empty()))
}

/// What a recovery move leaves behind: the walled account, or the provider
/// that stopped answering.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Leaves {
    Account,
    Provider,
}

/// Where a walk lands a lane: the entry it chose and that entry's account.
struct Destination {
    harness: Harness,
    /// The model the entry runs; `None` is the harness's default.
    model: Option<String>,
    effort: Option<String>,
    account: String,
}

impl Destination {
    /// The walk's line under the event: the account, and the harness and
    /// model where the walk chose another harness or model than the lane's
    /// own, `model`. The walk stays on the lane's host, so the line names
    /// none.
    fn note(&self, from: Harness, model: &str) -> String {
        if self.harness == from && self.model.as_deref().unwrap_or_default() == model {
            format!("pick lane={}", self.account)
        } else {
            format!(
                "pick lane={} harness={} model={}",
                self.account,
                self.harness.name(),
                self.model.as_deref().unwrap_or("-")
            )
        }
    }
}

/// The walk's answer as a recovery reads it.
enum Found {
    Destination(Destination),
    /// Every entry judged, none with room.
    None,
    /// No decision: the walk refused, held on its `:last` entry, left an
    /// entry unread, or chose an entry with no account to land on.
    Unjudged(String),
}

/// What the lane walk answers `request` with for `item`, its own charge
/// left out.
fn walked(item: &str, request: &WalkRequest, pass: &Pass) -> Found {
    let walked = match (pass.route.walk)(item, request) {
        Ok(walked) => walked,
        Err(cause) => return Found::Unjudged(cause),
    };
    match walked.answer {
        WalkAnswer::Lane(chosen) => match *chosen {
            Chosen {
                harness,
                model,
                effort,
                account: Some(account),
                ..
            } => Found::Destination(Destination {
                harness,
                model: Some(model).filter(|m| !m.is_empty()),
                effort: Some(effort).filter(|e| !e.is_empty()),
                account,
            }),
            Chosen { account: None, .. } => Found::Unjudged("walk-account-unnamed".to_owned()),
        },
        WalkAnswer::None if walked.unread.is_empty() => Found::None,
        WalkAnswer::None => Found::Unjudged(format!("walk-unread {}", walked.unread.join(" "))),
        WalkAnswer::Held { last_choice, .. } => {
            Found::Unjudged(format!("walk-held last_choice={last_choice}"))
        }
    }
}

/// The posture the lane's launch ran under, as a walk passes over an entry
/// whose harness cannot carry it: the recorded words, or none where the
/// launch ran the settings' posture.
fn source_of(lane: &Lane, harness: Harness) -> lane_walk::Source {
    lane_walk::Source {
        harness,
        flags: recorded_permission(lane)
            .map(|words| words.split_whitespace().map(str::to_owned).collect()),
    }
}

/// Where the walk judges an entry naming `entry` as its host, under the
/// fleet's `ORCH_LANE_HOST` `fleet`: the account walk's own judgement, with
/// this machine named `local`, as [`hosted::host_of`] names a lane's.
fn judged_host<'a>(entry: Option<&'a str>, fleet: Option<&'a str>) -> &'a str {
    crate::ops::accounts::judged_host(entry, fleet).unwrap_or("local")
}

/// The walk a walled lane leaves its account by: the lane preference, then
/// the lane's own harness and model on any other account, the spent one
/// left out. A lane moves only within its own host, whose store holds its
/// session and transcript, so the walk keeps the entries it judges there,
/// and the caller step only where the fleet's host (`fleet`,
/// `ORCH_LANE_HOST`, else this machine) is that host. A hosted lane's
/// transcript stands on its host, where no brief composed here can name
/// it, so its walk keeps the entries of its own harness alone. `None` where
/// that leaves the walk no step: a walk of nothing answers `none`, which
/// would read as no account having room.
fn account_walk(
    lane: &Lane,
    harness: Harness,
    model: &str,
    spent: &str,
    preference: Option<&str>,
    fleet: Option<&str>,
) -> Option<WalkRequest> {
    let host = hosted::host_of(lane);
    let local = host == "local";
    // A preference the filter empties stays an empty one: a request naming
    // none takes the whole `ORCH_LANE_PREFERENCE` again in the walk.
    let preference = preference.map(|text| {
        entries_where(text, |entry| {
            judged_host(entry.host.as_deref(), fleet) == host && (local || entry.harness == harness)
        })
    });
    let caller = (judged_host(None, fleet) == host).then(|| lane_walk::Caller {
        harness,
        lane: None,
        model: Some(model.to_owned()),
        effort: lane.effort.clone().filter(|e| !e.is_empty()),
        pick_model: Some(model.to_owned()),
        keep: false,
    });
    if preference.as_deref().is_none_or(str::is_empty) && caller.is_none() {
        return None;
    }
    Some(WalkRequest {
        scope: lane_walk::Scope::Lane,
        preference,
        lane: None,
        exclude: vec![spent.to_owned()],
        max_pct: None,
        min_headroom_pct: None,
        source: Some(source_of(lane, harness)),
        caller,
        keep_unmeasured: false,
    })
}

/// The walk a lane its provider stopped for the whole patience leaves that
/// provider by: the lane preference less every entry on the lane's own
/// provider, and no entry of its own; none where no preference is set. A
/// local lane's move names its transcript on this machine, so the walk
/// keeps the entries it judges here; a hosted lane's transcript stands on
/// its host, so it takes no move.
fn provider_walk(
    lane: &Lane,
    harness: Harness,
    preference: Option<&str>,
    fleet: Option<&str>,
) -> Option<WalkRequest> {
    if hosted::host_of(lane) != "local" {
        return None;
    }
    let model = lane.model.as_deref().unwrap_or_default();
    let caller = agent_runtime::controller::views::Caller {
        harness: Some(harness),
        model: Some(model.to_owned()),
        ..Default::default()
    };
    // The entry's host does not change its provider, so it is judged
    // without one.
    let others = entries_where(preference?, |entry| {
        let bare = format!("{}:{}:{}", entry.harness.name(), entry.model, entry.effort);
        judged_host(entry.host.as_deref(), fleet) == "local"
            && choice::recovery_walk(&caller, harness, Leaving::Provider { preference: &bare })
                .preference
                .is_some_and(|p| !p.is_empty())
    });
    (!others.is_empty()).then(|| WalkRequest {
        scope: lane_walk::Scope::Lane,
        preference: Some(others),
        lane: None,
        exclude: Vec::new(),
        max_pct: None,
        min_headroom_pct: None,
        source: Some(source_of(lane, harness)),
        caller: None,
        keep_unmeasured: false,
    })
}

/// The lane preference `text` with only the entries `keep` holds, each
/// provider entry judged as the controller's provider walk judges one
/// ([`Leaving::Provider`]) where the caller asks that. A preference the
/// lane grammar refuses is kept as written, so the walk refuses it by its
/// own rule.
fn entries_where(text: &str, keep: impl Fn(&lane_walk::Entry) -> bool) -> String {
    let Ok(parsed) = lane_walk::Preference::parse(text, lane_walk::Scope::Lane) else {
        return text.to_owned();
    };
    let last = parsed.entries.len().saturating_sub(1);
    let mut kept = Vec::new();
    for (i, entry) in parsed.entries.iter().enumerate() {
        if keep(entry) {
            kept.push(if parsed.last_choice && i == last {
                format!("{}:last", entry.text)
            } else {
                entry.text.clone()
            });
        }
    }
    kept.join(",")
}

/// The record's own relaunch onto `to` for the watch's session, on the
/// record's own host: the walk's harness, model, effort and account in
/// place of the record's, a permission word the new harness takes, and a brief that
/// names the prior transcript where the move starts the harness fresh on
/// another harness or off a provider ([`moved_start_brief`]); a move to
/// another account of the same harness keeps the start brief.
fn relaunch_request(
    lane: &Lane,
    from: Harness,
    to: &Destination,
    leaves: Leaves,
    ground: RecoveryReason,
    exclude: Option<&str>,
    pass: &Pass,
) -> Result<Recovery, String> {
    let mut moved = lane.clone();
    moved.model.clone_from(&to.model);
    moved.effort.clone_from(&to.effort);
    let crosses = to.harness != from;
    // A recorded word is the source's own spelling: a walk crosses
    // harnesses only under a full bypass, which the new harness spells its
    // own way, or names none where it has no permission word.
    if crosses && recorded_permission(lane).is_some() {
        match to.harness.bypass_words().first() {
            Some(word) => {
                moved.extra.insert("permission".to_owned(), json!(word));
            }
            None => {
                moved.extra.remove("permission");
            }
        }
    }
    let brief: fn(&Lane, Harness) -> Result<String, String> = match (crosses, leaves) {
        (true, Leaves::Account | Leaves::Provider) | (false, Leaves::Provider) => moved_start_brief,
        (false, Leaves::Account) => start_brief,
    };
    let Composed { cwd, close, launch } = compose_relaunch(
        &moved,
        to.harness,
        &Composition {
            stem: "wall-relaunch",
            account: Some(&to.account),
            exclude,
            brief,
            ground,
        },
        pass.state_dir,
    )?;
    Ok(Recovery {
        cwd,
        session: pass.session.map(str::to_owned).unwrap_or_default(),
        args: relaunch_args(pass, Some(&close), &launch),
    })
}

/// The handoff sentence a lane moved to another harness or provider starts
/// on (`workflows/handoff.md` § 2), naming the prior session's transcript:
/// the file the record's bound session id names under the home its last
/// launch ran in, read on this machine. A session with no file here, or a
/// store that cannot be read, names no transcript, so the move is refused
/// with the cause.
fn moved_start_brief(lane: &Lane, harness: Harness) -> Result<String, String> {
    let from = lane
        .harness
        .as_deref()
        .and_then(Harness::parse)
        .ok_or_else(|| "harness-unrecorded".to_owned())?;
    let id = lane
        .session_id
        .as_deref()
        .filter(|id| !id.is_empty())
        .ok_or_else(|| "session-unrecorded".to_owned())?;
    let home = lane
        .home
        .as_deref()
        .or(lane.account.as_deref())
        .map(PathBuf::from)
        .or_else(|| agent_runtime::effects::default_home(from))
        .ok_or_else(|| "home-unrecorded".to_owned())?;
    let cwd = lane
        .mail_root
        .as_deref()
        .ok_or_else(|| "checkout-unrecorded".to_owned())?;
    let transcript = match agent_runtime::effects::fixed_id_file(from, &home, Path::new(cwd), id) {
        Reading::Live(file) => file,
        Reading::Gone => return Err(format!("transcript-absent session={id}")),
        Reading::Unreadable { cause } => {
            return Err(format!("transcript-unreadable session={id} cause={cause}"));
        }
    };
    let brief = start_brief(lane, harness)?;
    Ok(format!(
        "{}\nContinue {} from the prior {} transcript at {}; read it first, then resume the orch workflow.\n",
        brief.trim_end(),
        lane.item,
        from.name(),
        transcript.display()
    ))
}

/// The runtime's own argv for a relaunch's requests through the one shell
/// word, each exiting by its effect's outcome, never by its admission
/// alone: the launch is asked only once the close's effect did not fail
/// (an unconfirmed close leaves the launch's own transition to refuse a
/// lane whose harness still runs), and the launch's status is the chain's:
/// a replacement whose effect failed, or whose outcome is still open,
/// leaves the status the outcome reader says or settles from the launch's
/// intent. A close an earlier relaunch confirmed is not sent again.
fn relaunch_args(pass: &Pass, close: Option<&Path>, launch: &Path) -> Vec<String> {
    let entry = pass.scripts.join("orch-runtime").display().to_string();
    let state = pass.state_dir.display().to_string();
    let launch = launch.display().to_string();
    match close {
        Some(close) => vec![
            "sh".to_owned(),
            "-c".to_owned(),
            "\"$1\" --state-dir \"$2\" op --fleet --effect-exit --request \"$3\"; rc=$?; [ \"$rc\" -eq 0 ] || [ \"$rc\" -eq 75 ] || exit \"$rc\"; exec \"$1\" --state-dir \"$2\" op --fleet --effect-exit --request \"$4\"".to_owned(),
            "wall-relaunch".to_owned(),
            entry,
            state,
            close.display().to_string(),
            launch,
        ],
        None => vec![
            "sh".to_owned(),
            "-c".to_owned(),
            "exec \"$1\" --state-dir \"$2\" op --fleet --effect-exit --request \"$3\"".to_owned(),
            "wall-relaunch".to_owned(),
            entry,
            state,
            launch,
        ],
    }
}

/// Start a composed relaunch of the observed lane: a hosted lane of any
/// kind has its harness stopped through the provider first (its `stop
/// --item --harness`), and a stop not confirmed refuses the relaunch as
/// `stop-failed` with the status, or `stop-unanswered` where it gave no
/// answer; then the marker the outcome reader settles, then the detached
/// start, and `lane-relaunched` with its log. `Err` is the refusal's
/// reason.
fn start_recovery(
    obs: &Observed,
    pass: &Pass,
    out: &mut Produced,
    recovery: Recovery,
    to: &str,
    spent: &str,
) -> Result<(), String> {
    let lane = &obs.name;
    let host = hosted::host_of(obs.lane);
    // A stop refused or unanswered alike may leave the harness running, so
    // neither relaunches beside it this pass.
    if host != "local"
        && let Some(harness) = obs.lane.harness.as_deref()
        && let Err(hosted::Asked::Failed(cause) | hosted::Asked::Unknown(cause)) =
            hosted::stop(pass.scripts, host, &obs.lane.item, harness)
    {
        return Err(cause);
    }
    let marker = wall::relaunch_marker_path(watch_state_dir(pass.claim_store), lane);
    let log = pass
        .state_dir
        .join(format!("wall-relaunch-{}.log", obs.lane.item));
    if let Err(e) = wall::write_relaunch_marker(&marker, &obs.lane.item, pass.now, &log) {
        return Err(format!(
            "marker-unwritten path={} cause={e}",
            marker.display()
        ));
    }
    let relaunch = Relaunch {
        item: obs.lane.item.clone(),
        window: lane.clone(),
        to: to.to_owned(),
        spent: spent.to_owned(),
        cwd: recovery.cwd,
        session: recovery.session,
        args: recovery.args,
        marker,
        log: log.clone(),
    };
    (pass.route.start)(&relaunch).map_err(|cause| format!("launch-failed cause={cause}"))?;
    out.events.push(Event::LaneRelaunched {
        item: obs.lane.item.clone(),
        lane: relaunch.to,
        from: relaunch.spent,
    });
    out.events
        .push(Event::Tail(format!("log={}", log.display())));
    Ok(())
}

/// The relaunch's parts before the marker: the checkout, the session and
/// the runtime's own argv.
pub(crate) struct Recovery {
    pub(crate) cwd: PathBuf,
    pub(crate) session: String,
    pub(crate) args: Vec<String>,
}

/// The permission choice a relaunch keeps: the record's `permission`, the
/// words of the launch line the runtime launched it with. `None` is a
/// record stating no choice, which runs the settings' posture.
fn recorded_permission(lane: &Lane) -> Option<String> {
    lane.extra
        .get("permission")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|w| !w.is_empty())
        .map(str::to_owned)
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
    pub(crate) ground: RecoveryReason,
}

/// A composed relaunch: the checkout it runs from and its two request files
/// in the order the runtime's entry applies them.
pub(crate) struct Composed {
    pub(crate) cwd: PathBuf,
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
/// else `mail_root`). A
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
    if is_reading_lane(&lane.item) {
        return Err("reading-lane".to_owned());
    }
    if lane.class.is_none()
        || lane
            .class_reason
            .as_deref()
            .is_none_or(|r| r.trim().is_empty())
    {
        return Err("class-unrecorded".to_owned());
    }
    let cwd = lane
        .extra
        .get("checkout")
        .and_then(Value::as_str)
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
    let refresh = lane
        .extra
        .get("refresh")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let permission = recorded_permission(lane);
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
        "no_landing": how.ground.ground(),
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
        close,
        launch: file,
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

/// The `stray-window` row of a pane first seen while an open launch's
/// window stood asked on its server: the next pass that still finds it
/// unnamed reports it.
const STRAY_HELD: &str = "held";

/// The stray sweep: every window of the fleet session whose pane no lane
/// record, controller record, open intent, receipt or own pane names is
/// reported once per pane key and never adopted or closed. The records are
/// read after the listing they judge, so a window a launch or a succession
/// opened and recorded while the pass ran its lane reads is named by them.
/// A pane an open launch's window asked on the listed server may be, its
/// pane not yet recorded, is held one pass: a launch records its pane
/// before that pass, and a lost launch's window is reported then. An
/// unreadable listing, receipt set or fleet state reports nothing.
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
    let Ok(fleet) = read_fleet(pass.fleet_path) else {
        return;
    };
    let mut known: BTreeSet<String> = receipts.into_iter().collect();
    known.extend(pass.own_panes.iter().cloned());
    for lane in &fleet.lanes {
        if let Some(pane) = lane.launch.as_ref().and_then(|l| l.pane.clone()) {
            known.insert(pane);
        }
    }
    if let Some(pane) = fleet
        .overseer
        .as_ref()
        .and_then(|o| o.extra.get("pane"))
        .and_then(|p| p.as_str())
    {
        known.insert(pane.to_owned());
    }
    let mut asked = false;
    for intent in fleet.intents.iter().filter(|i| i.open()) {
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
        // A window an effect opened with nothing typed stands in its set
        // before any outcome or phase names it; a window asked stands
        // there until its pane is recorded.
        for held in intent.obligations.iter().flat_map(|set| &set.standing) {
            match &held.obligation {
                Obligation::Pane { pane, .. } => {
                    known.insert(pane.clone());
                }
                // The listing names its server by pid alone: an obligation
                // on a dead server whose pid the live one reused holds a
                // pane one pass at most.
                Obligation::Window { server: on, .. } => asked |= *on == server,
                Obligation::Process(_)
                | Obligation::Pid { .. }
                | Obligation::PaneUnaddressed { .. }
                | Obligation::Receipt
                | Obligation::JobSidecar { .. }
                | Obligation::JobUnit { .. }
                | Obligation::JobGroup(_)
                | Obligation::JobPgid { .. } => {}
            }
        }
    }
    let mut seen = BTreeSet::new();
    for window in windows {
        if known.contains(&window.pane) {
            continue;
        }
        let key = format!("{server} {}", window.pane);
        seen.insert(key.clone());
        match pass.baseline.get("stray-window", &key) {
            None if asked => {
                out.changes
                    .push(set("stray-window", &key, STRAY_HELD.to_owned()));
                continue;
            }
            None => {}
            Some(row) if row == STRAY_HELD => {}
            Some(_) => continue,
        }
        out.events.push(Event::StrayWindow {
            pane: window.pane.clone(),
            window: window.window.clone(),
            server,
            name: window.name.clone(),
        });
        out.changes
            .push(set("stray-window", &key, "reported".to_owned()));
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
        // A row that holds the launch alone reads as its first report.
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

/// The row a lane's model facts were judged under, keyed by its item: the
/// checksum of the facts its item record holds, so each is acted on, or
/// refused, once.
const FACTS_ROW: &str = "model-facts";

/// What one lane's facts came to: applied (or nothing to apply), refused for
/// good with the line said once, or unsettled with the line said and the
/// facts judged again on the next pass.
enum Facts {
    Judged,
    Refused(String),
    Unsettled(String),
}

/// The fleet writes a lane's own process may not make, taken from what it
/// kept on its item record: a cleared start's session bound on the fleet's
/// lane, a replacement's first turn end resetting its switched check, and a
/// switch the turn end marked started recovered through the fleet's
/// `recover-lane-model`. Every value of the item record is the lane's to
/// write, so each is taken as a fact alone, a session in its owner's form
/// bound to the launch the fleet record runs, and everything a write or a
/// relaunch composes is read from the fleet record. A local lane's alone:
/// a hosted lane's switch is its host's.
fn model_facts(pass: &Pass, hosts: &Hosts, out: &mut Produced) {
    let recorded: BTreeSet<&str> = pass.fleet.lanes.iter().map(|l| l.item.as_str()).collect();
    for item in pass.baseline.identities(FACTS_ROW) {
        if !recorded.contains(item.as_str()) {
            out.changes.push(clear(FACTS_ROW, &item));
        }
    }
    for lane in pass.fleet.lanes.iter().filter(|l| l.status.in_flight()) {
        let files = hosts.of(lane).ok().map(|caps| caps.files);
        if files != Some(Files::Local) {
            continue;
        }
        let (_, doc, _) = lane_state(lane, files, pass.state_dir, pass.scripts, out);
        let Reading::Live(doc) = doc else {
            continue;
        };
        let held = [
            "model_checks",
            crate::ops::store::LANE_SESSION,
            crate::ops::store::MODEL_RESET,
        ]
        .map(|member| doc.get(member).cloned().unwrap_or(Value::Null));
        if held.iter().all(Value::is_null) {
            continue;
        }
        let key = agent_runtime::record::cksum(json!(held).to_string().as_bytes()).to_string();
        if pass.baseline.get(FACTS_ROW, &lane.item) == Some(key.as_str()) {
            continue;
        }
        match lane_facts(pass, &lane.item, &held) {
            Facts::Judged => out.changes.push(set(FACTS_ROW, &lane.item, key)),
            Facts::Refused(line) => {
                fail(out, line);
                out.changes.push(set(FACTS_ROW, &lane.item, key));
            }
            Facts::Unsettled(line) => fail(out, line),
        }
    }
}

/// One lane's facts, `[model_checks, lane_session, model_reset]`, against
/// its fleet lane read now.
fn lane_facts(pass: &Pass, item: &str, held: &[Value; 3]) -> Facts {
    let [checks, session, reset] = held;
    let fleet = agent_runtime::record::fleet_path(pass.state_dir);
    let unsettled = |cause: &dyn std::fmt::Display| {
        Facts::Unsettled(format!("model-facts-unapplied item={item} cause={cause}"))
    };
    let entry = match fleet_lane(&fleet, item) {
        Ok(Some(entry)) => entry,
        Ok(None) => return Facts::Judged,
        Err(e) => return unsettled(&e),
    };
    let refused =
        |cause: &str| Facts::Refused(format!("model-facts-refused item={item} cause={cause}"));
    let word = |value: &Value, key: &str| value.get(key).and_then(Value::as_str).map(str::to_owned);
    let identity = launch_of(&Place::Lane(item.to_owned()), &entry);

    // A cleared start's session, in the launch the fleet lane runs.
    if !session.is_null() {
        let Some(id) = bound(session) else {
            return refused("session-form");
        };
        let launch = entry.get("launch");
        let same = |key: &str| {
            session["launch"].get(key).is_some()
                && session["launch"].get(key) == launch.and_then(|l| l.get(key))
        };
        if same("pid") && same("start") && word(&entry, "session_id").as_deref() != Some(id) {
            let Some(launch) = launch_identity(&entry) else {
                return Facts::Judged;
            };
            if let Err(e) = rewrite_fleet(&fleet, |doc| {
                Ok(crate::ops::lane::rebind_session(doc, item, id, &launch))
            }) {
                return unsettled(&e);
            }
        }
    }

    // A replacement's first turn end under the launch the fleet lane runs.
    if !reset.is_null() {
        let Some(id) = bound(reset) else {
            return refused("session-form");
        };
        let check = &entry["model_check"];
        let awaiting = check["outcome"] == "switched"
            && check["recovery_started"] == true
            && check["launch_identity"] != identity;
        if awaiting
            && reset.get("launch_identity") == Some(&identity)
            && word(&entry, "session_id").as_deref() == Some(id)
        {
            let written = rewrite_fleet(&fleet, |doc| {
                let env = agent_runtime::journal::Env::system()?;
                crate::ops::store::model_reset(&fleet, doc, &env, item, id, &entry)
            });
            if let Err(e) = written {
                return unsettled(&e);
            }
        }
    }

    // A switch the turn end marked started, bound to the launch the fleet
    // lane runs, in the session it binds.
    let Some(checks) = checks.as_object() else {
        return Facts::Judged;
    };
    for (id, check) in checks {
        let started = check["outcome"] == "switched" && check["recovery_started"] == true;
        if !started {
            continue;
        }
        if !agent_runtime::context::session_bound(id) {
            return refused("session-form");
        }
        if check.get("launch_identity") != Some(&identity)
            || word(&entry, "session_id").as_deref() != Some(id.as_str())
        {
            continue;
        }
        let model = word(&entry, "model").unwrap_or_default();
        if word(check, "launched").as_deref() != Some(model.as_str()) {
            return refused("model-unheld");
        }
        let Some(observed) =
            word(check, "observed").filter(|o| agent_runtime::context::session_bound(o))
        else {
            return refused("observed-form");
        };
        let switch = Check {
            session: id.clone(),
            outcome: "switched".to_owned(),
            cause: String::new(),
            launched: model,
            observed,
        };
        let recorded = rewrite_fleet(&fleet, |doc| {
            let at = agent_runtime::journal::Env::system()?.iso();
            Ok(record_model_check(
                &fleet,
                doc,
                &at,
                &Place::Lane(item.to_owned()),
                &switch,
                &entry,
            )?)
        });
        match recorded {
            Ok(report) if report["result"] == "acquired" => {}
            Ok(_) => return Facts::Judged,
            Err(e) => return unsettled(&e),
        }
        return recover(pass, item, id, &identity, &entry);
    }
    Facts::Judged
}

/// A fact's `session_id` where it is spelled in the form the session's
/// reader names a path by.
fn bound(fact: &Value) -> Option<&str> {
    fact.get("session_id")
        .and_then(Value::as_str)
        .filter(|session| agent_runtime::context::session_bound(session))
}

/// The fleet record's first lane for `item`, as it stands now.
#[allow(
    clippy::disallowed_methods,
    reason = "the lane pass's read of the fleet lane a lane's facts are judged against, read again before each pass's writes"
)]
fn fleet_lane(fleet: &Path, item: &str) -> crate::error::Result<Option<Value>> {
    let Some(snapshot) = state::load(fleet)? else {
        return Ok(None);
    };
    Ok(snapshot
        .doc
        .get("lanes")
        .and_then(Value::as_array)
        .and_then(|lanes| {
            lanes
                .iter()
                .find(|l| l.get("item").and_then(Value::as_str) == Some(item))
        })
        .cloned())
}

/// The harness process the fleet lane's launch records.
fn launch_identity(entry: &Value) -> Option<Identity> {
    let launch = entry.get("launch")?;
    Some(Identity {
        pid: u32::try_from(launch.get("pid")?.as_u64()?).ok()?,
        start: launch.get("start")?.as_str()?.to_owned(),
    })
}

/// One transition of the fleet record, judged against the record it stores
/// over and applied again where another writer moved it.
#[allow(
    clippy::disallowed_methods,
    reason = "the lane pass's fleet writes of what a lane's own process may not write, each a transition of the store's own"
)]
fn rewrite_fleet(
    fleet: &Path,
    change: impl Fn(&mut Document) -> crate::error::Result<Value>,
) -> crate::error::Result<Value> {
    agent_runtime::record::reread(
        || {
            let snapshot = state::load(fleet)?.ok_or_else(|| {
                crate::error::Error::from(agent_runtime::Error::RecordMissing {
                    path: fleet.to_path_buf(),
                })
            })?;
            let mut doc = snapshot.doc.clone();
            let reply = change(&mut doc)?;
            agent_runtime::record::store(
                fleet,
                &snapshot.doc,
                &doc,
                agent_runtime::record::Locking::FLOCK,
            )?;
            Ok(reply)
        },
        crate::error::Error::key,
    )
}

/// How long the recovery's claim, composition and job start are given.
const RECOVERY_BOUND: Duration = Duration::from_secs(120);

/// The fleet's `recover-lane-model` for the switch the pass recorded,
/// through the runtime's entry from the lane's checkout, so its settings,
/// its relaunch and its job are the ones the lane's own checkout names.
#[allow(
    clippy::disallowed_methods,
    reason = "the lane pass's one start of a model recovery, the runtime's entry through the one runner"
)]
fn recover(pass: &Pass, item: &str, session: &str, identity: &Value, entry: &Value) -> Facts {
    let request = json!({
        "op": "recover-lane-model",
        "item": item,
        "session": session,
        "launch_identity": identity,
    })
    .to_string();
    let dir = pass.state_dir.display().to_string();
    let cwd = entry
        .get("mail_root")
        .and_then(Value::as_str)
        .filter(|root| !root.is_empty())
        .map(Path::new);
    let ran = agent_runtime::host::run_tagged_in(
        "lanes",
        hosted::ORCH_RUNTIME,
        &pass.scripts.join(hosted::ORCH_RUNTIME),
        "recover-lane-model",
        &[
            "--state-dir",
            &dir,
            "op",
            "--fleet",
            "--request-json",
            &request,
        ],
        agent_runtime::host::Place { cwd, env: &[] },
        RECOVERY_BOUND,
    );
    let unsettled = |cause: String| {
        Facts::Unsettled(format!(
            "model-recovery-unanswered item={item} cause={cause}"
        ))
    };
    let out = match ran {
        Ok(out) => out,
        Err(e) => return unsettled(e.to_string()),
    };
    let Ok(reply) = serde_json::from_slice::<Value>(&out.stdout) else {
        return unsettled(format!("{}", out.status));
    };
    if reply["ok"] == true {
        return Facts::Judged;
    }
    let refusal = &reply["refusal"];
    let fields: String = refusal["fields"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|pair| {
            Some(format!(
                " {}={}",
                pair.get(0)?.as_str()?,
                pair.get(1)?.as_str()?
            ))
        })
        .collect();
    Facts::Refused(format!(
        "model-recovery-refused key={}{fields}",
        refusal["key"].as_str().unwrap_or_default()
    ))
}
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

/// The five counts and the stage of the `lane-long` line.
fn lane_counts(
    lane: &Lane,
    files: Option<Files>,
    state_dir: &Path,
    scripts: &Path,
    out: &mut Produced,
) -> (Counters, String) {
    let (counters, _, step) = lane_state(lane, files, state_dir, scripts, out);
    (counters, step(scripts, lane))
}

/// A lane's `Step` line, read where its files are.
type StepRead = fn(&Path, &Lane) -> String;

/// The five counts with the item state they were read from, read where the
/// lane's files are: under its worktree on this disk, through its host's
/// `cat`, or nowhere for a kind that keeps none (`files=none`); with the
/// reader of the lane's `Step` line, not yet run, so a caller that prints no
/// stage asks no host for it. A parked lane's disk is not asked, and a host
/// whose capability line could not be read counts nothing.
fn lane_state(
    lane: &Lane,
    files: Option<Files>,
    state_dir: &Path,
    scripts: &Path,
    out: &mut Produced,
) -> (Counters, Reading<Document>, StepRead) {
    match (lane.status, files) {
        (LaneStatus::Parked, _) => (Counters::unread(), Reading::Gone, |_, _| {
            "parked".to_owned()
        }),
        (
            LaneStatus::Running | LaneStatus::Preparing | LaneStatus::Stopped | LaneStatus::Done,
            Some(Files::Local),
        ) => {
            let (counters, doc) = lane_counters(lane, state_dir, out);
            (counters, doc, |_, lane| lane_step(lane))
        }
        (
            LaneStatus::Running | LaneStatus::Preparing | LaneStatus::Stopped | LaneStatus::Done,
            Some(Files::Verb),
        ) => {
            let (counters, doc) = hosted::counters(scripts, lane, out);
            (counters, doc, hosted::step)
        }
        (
            LaneStatus::Running | LaneStatus::Preparing | LaneStatus::Stopped | LaneStatus::Done,
            Some(Files::None),
        ) => (Counters::unread(), Reading::Gone, |_, _| "none".to_owned()),
        // A host whose line could not be read, which the duty's pass says once.
        (
            LaneStatus::Running | LaneStatus::Preparing | LaneStatus::Stopped | LaneStatus::Done,
            None,
        ) => (
            Counters::unread(),
            Reading::Unreadable {
                cause: STATE_UNREAD,
            },
            |_, _| "unread".to_owned(),
        ),
    }
}

/// The item state's newest stage still open, neither ended nor superseded,
/// that started at or after `since`, the current session's start, as its
/// kind and start: a stage an earlier session left open is not this
/// session's work.
pub(crate) fn session_stage(doc: &Document, since: u64) -> Option<(&str, u64)> {
    doc.get("stages")?
        .as_array()?
        .iter()
        .rev()
        .find_map(|stage| {
            let start = stage.get("start")?.as_u64()?;
            let open = stage.get("end").is_none_or(Value::is_null)
                && stage.get("superseded") != Some(&Value::Bool(true));
            (open && start >= since).then_some((stage.get("kind")?.as_str()?, start))
        })
}

/// Whether the item state holds a stage of `kind` that started at or after
/// `since`, the current session's start, whatever its end: an ended or
/// superseded stage of the session still ran in it.
fn session_held(doc: &Document, since: u64, kind: &str) -> bool {
    doc.get("stages")
        .and_then(Value::as_array)
        .is_some_and(|stages| {
            stages.iter().any(|stage| {
                stage.get("kind").and_then(Value::as_str) == Some(kind)
                    && stage
                        .get("start")
                        .and_then(Value::as_u64)
                        .is_some_and(|start| start >= since)
            })
        })
}

/// Whether a lane on this disk recorded a stage of `kind` in its current
/// session ([`session_held`]), read from the item state its checkout names
/// as `lane status` reads it: `false` where no item state stands, the cause
/// where the state or the session's start cannot be read.
pub(crate) fn local_held(lane: &Lane, state_dir: &Path, kind: &str) -> Result<bool, String> {
    let (_, doc) = lane_counters(lane, state_dir, &mut Produced::default());
    match (
        &doc,
        lane.session_since.as_deref().and_then(clock::epoch_secs),
    ) {
        (Reading::Live(doc), Some(since)) => Ok(session_held(doc, since, kind)),
        (Reading::Gone, _) => Ok(false),
        (Reading::Live(_), None) => Err("session-since-unread".to_owned()),
        (Reading::Unreadable { cause }, _) => Err((*cause).to_owned()),
    }
}

/// The facts' stage and its start: `none` where the lane wrote no item state
/// or no stage of the current session stands open, `unread` where the state
/// or the session's start could not be read.
fn stage_fact(doc: &Reading<Document>, since: Option<u64>) -> (String, Option<u64>) {
    match (doc, since) {
        (Reading::Live(doc), Some(since)) => match session_stage(doc, since) {
            Some((kind, start)) => (kind.to_owned(), Some(start)),
            None => ("none".to_owned(), None),
        },
        (Reading::Gone, _) => ("none".to_owned(), None),
        (Reading::Live(_), None) | (Reading::Unreadable { .. }, _) => ("unread".to_owned(), None),
    }
}

/// The facts' post-PR stop: the item state's standing stop where it was
/// recorded at or after `since`, the current session's start; a stop an
/// earlier session left, or one whose time cannot be read, is not this
/// session's.
fn stop_fact(doc: &Reading<Document>, since: Option<u64>) -> Value {
    let (Reading::Live(doc), Some(since)) = (doc, since) else {
        return Value::Null;
    };
    doc.get("post_pr_stop")
        .filter(|stop| {
            stop.get("at")
                .and_then(Value::as_u64)
                .is_some_and(|at| at >= since)
        })
        .cloned()
        .unwrap_or(Value::Null)
}

/// The counters of a running lane: the item's own workflow state in the
/// state directory its checkout names ([`lane_state_dir`]), or under the
/// fleet's where the record names no worktree on this disk; the
/// validation run index under the worktree; a state the lane has not
/// written, or one that cannot be read, counts nothing, and a checkout
/// whose files could not be read says so.
fn lane_counters(
    lane: &Lane,
    state_dir: &Path,
    out: &mut Produced,
) -> (Counters, Reading<Document>) {
    let unread = || {
        (
            Counters::unread(),
            Reading::Unreadable {
                cause: STATE_UNREAD,
            },
        )
    };
    // The worktree the record names, read three-valued: a root this reader
    // cannot read counts nothing.
    let root = match lane.mail_root.as_deref().map(Path::new) {
        None => None,
        Some(root) => match std::fs::metadata(root) {
            Ok(meta) if meta.is_dir() => Some(root),
            Ok(_) => None,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
            Err(_) => return unread(),
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
                return unread();
            }
        },
    };
    let doc = item_doc(&state::item_path(&state_dir, &lane.item));
    let counters = match &doc {
        Reading::Live(doc) => counters_of(doc, runs).unwrap_or_else(Counters::unread),
        Reading::Gone | Reading::Unreadable { .. } => Counters::unread(),
    };
    (counters, doc)
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

pub(super) const STATE_UNREAD: &str = "state-unreadable";

/// The item's workflow state as the counts read it: the file's JSON object,
/// whatever its shape; `Gone` where the lane has written none, unreadable
/// where the file is no object.
pub(super) fn item_doc(path: &Path) -> Reading<Document> {
    let unreadable = Reading::Unreadable {
        cause: STATE_UNREAD,
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

/// A cause key: a trimmed string that
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

    /// A lane's recovery walks stay on its own host: the wall walk keeps the
    /// entries judged there (the entry's `@host`, else `ORCH_LANE_HOST`,
    /// else this machine) and the caller step only where the fleet's host
    /// (`ORCH_LANE_HOST`, else this machine) is that host, a hosted lane's
    /// walk its own harness's entries alone, and a preference the filter
    /// empties stays empty beside a kept caller step, so the walk never
    /// takes the whole `ORCH_LANE_PREFERENCE` back;
    /// the provider walk keeps a local lane's entries judged here, and a
    /// hosted lane takes none.
    #[test]
    fn a_lane_s_recovery_walks_keep_the_entries_judged_on_its_own_host() {
        let mixed = "codex:gpt-5:high,claude@/opt/box:opus:high,claude@local:opus:high,claude:opus:high:last";
        // (ORCH_LANE_PREFERENCE, lane host, ORCH_LANE_HOST, wall walk
        // entries, caller step kept, provider walk entries)
        let rows = [
            (
                mixed,
                None,
                None,
                Some("codex:gpt-5:high,claude@local:opus:high,claude:opus:high:last"),
                true,
                Some("codex:gpt-5:high"),
            ),
            (
                mixed,
                None,
                Some("/opt/box"),
                Some("claude@local:opus:high"),
                false,
                None,
            ),
            (
                mixed,
                Some("/opt/box"),
                None,
                Some("claude@/opt/box:opus:high"),
                false,
                None,
            ),
            (
                mixed,
                Some("/opt/box"),
                Some("/opt/box"),
                Some("claude@/opt/box:opus:high,claude:opus:high:last"),
                true,
                None,
            ),
            (
                "claude@/opt/box:opus:high",
                None,
                None,
                Some(""),
                true,
                None,
            ),
            (
                "codex:gpt-5:high",
                Some("/opt/box"),
                Some("/opt/box"),
                Some(""),
                true,
                None,
            ),
        ];
        for (preference, host, fleet, wall, caller, provider) in rows {
            let lane: Lane = serde_json::from_value(json!({
                "item": "KEN-1",
                "harness": "claude",
                "model": "opus",
                "status": "running",
                "host": host,
            }))
            .unwrap();
            let at = format!("{preference} {host:?} {fleet:?}");
            let request = account_walk(
                &lane,
                Harness::Claude,
                "opus",
                "/a",
                Some(preference),
                fleet,
            )
            .unwrap();
            assert_eq!(request.preference.as_deref(), wall, "{at}");
            assert_eq!(request.caller.is_some(), caller, "{at}");
            let moved = provider_walk(&lane, Harness::Claude, Some(preference), fleet);
            assert_eq!(
                moved.and_then(|r| r.preference).as_deref(),
                provider,
                "{at}"
            );
        }
    }

    /// The wall walk and the account walk's `Hosts::hosted` judge an entry
    /// by one rule: an empty entry host is no host, so the fleet's
    /// `ORCH_LANE_HOST` judges it on both.
    #[test]
    fn the_wall_walk_judges_an_entry_s_host_as_the_account_walk_does() {
        assert_eq!(judged_host(Some(""), Some("/opt/box")), "/opt/box");
        assert_eq!(
            crate::ops::accounts::judged_host(Some(""), Some("/opt/box")),
            Some("/opt/box")
        );
    }

    /// One pass per `now` over a neutral world under `route`, from the
    /// rows `seed` holds: `each` runs the pass, and its rows are applied as
    /// the runner commits a pass.
    fn route_passes(
        route: &WallRoute<'_>,
        seed: Baseline,
        nows: &[u64],
        mut each: impl FnMut(&Pass<'_>) -> Produced,
    ) {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let roots = agent_runtime::settings::Roots {
            project: root.clone(),
            common: root.clone(),
        };
        let environment = [(
            std::ffi::OsString::from("AGENT_RUNTIME_ACCOUNT_STATE_DIR"),
            root.join("accounts").into_os_string(),
        )];
        let settings = settings::load(
            &roots,
            &environment,
            &settings::Flags {
                state_dir: Some(root.clone()),
                private_env: false,
            },
        )
        .unwrap();
        let watch = settings.watch.get().unwrap();
        let fleet = FleetState {
            lanes: Vec::new(),
            overseer: None,
            fleet_log: Vec::new(),
            triaged: Vec::new(),
            launch_queue: Vec::new(),
            intents: Vec::new(),
        };
        let readers = Readers::kernel();
        let roster = || Err("unasked".to_owned());
        let reads = hosted::Reads {
            gh: Path::new("/nonexistent/gh"),
            roster: &roster,
            project: &settings.roots.project,
            reads: &settings.reads,
        };
        let wall_pauses = |_: RecordWallPauses| Ok(());
        let mut baseline = seed;
        for &now in nows {
            let pass = Pass {
                fleet: &fleet,
                fleet_path: &root.join("fleet.json"),
                readers: &readers,
                baseline: &baseline,
                settings: &watch,
                now,
                session: None,
                own_panes: &[],
                state_dir: &root,
                claim_store: &settings.claim_store,
                account_state: &settings.account_state,
                scripts: Path::new("/nonexistent"),
                route,
                wall_pauses: &wall_pauses,
                hosted: &reads,
                copilot_home: None,
                server: None,
            };
            let out = each(&pass);
            assert_eq!(out.failed, None, "{now}");
            for change in out.changes {
                baseline.apply(change);
            }
        }
    }

    fn walled_lane() -> Lane {
        serde_json::from_value(json!({
            "item": "KEN-1",
            "harness": "claude",
            "model": "opus",
            "account": "/a",
            "status": "running",
            "window": "gh-1",
        }))
        .unwrap()
    }

    fn observed<'a>(lane: &'a Lane, message: &str) -> Observed<'a> {
        Observed {
            lane,
            name: "gh-1".to_owned(),
            pane_key: Some("1 %1".to_owned()),
            identity: None,
            screen: Some(message.to_owned()),
            row: Some(rows::Row {
                position: 3,
                message: Some(message.to_owned()),
                ..rows::Row::default()
            }),
            provider_running: false,
            state: LaneState::Working,
        }
    }

    /// A wall walk the own-host filter leaves no entry and no caller step
    /// judged no account: the watch says so, never asking the walk, where
    /// a walk of nothing would answer `none` and stop the recovery as if no
    /// account had room. A walk with a step on the lane's host keeps its
    /// answer. The lines are the ones the overseer reads under
    /// `usage-limit` (`oversee-events.md`).
    #[test]
    fn a_wall_walk_with_no_entry_on_the_lane_s_host_judges_no_account() {
        let off_host: &[&str] = &["pick unjudged walk-empty"];
        let no_room: &[&str] = &["pick none", "recovery-stopped cause=no-room-no-reset"];
        // (case, ORCH_LANE_PREFERENCE, ORCH_LANE_HOST, lines, walk asked)
        let rows = [
            (
                "entries_off_host",
                Some("claude:opus:high"),
                Some("/opt/box"),
                off_host,
                false,
            ),
            (
                "no_preference_off_host",
                None,
                Some("/opt/box"),
                off_host,
                false,
            ),
            (
                "caller_on_host",
                Some("claude:opus:high"),
                None,
                no_room,
                true,
            ),
        ];
        for (case, preference, fleet, want, asked) in rows {
            let lane = walled_lane();
            let obs = observed(&lane, "429 Usage limit reached for this model");
            let walks = std::cell::Cell::new(0);
            let walk = |_: &str, request: &WalkRequest| {
                walks.set(walks.get() + 1);
                Ok(Walked {
                    answer: WalkAnswer::None,
                    walk: request.preference.clone().unwrap_or_default(),
                    entries: 0,
                    skipped: Vec::new(),
                    walled: 0,
                    unmeasured: 0,
                    unread: Vec::new(),
                    deprecated: Vec::new(),
                })
            };
            let halted = |_: &Lane| Ok::<_, Refusal>(false);
            let exited = |_: &Lane| Err("unasked".to_owned());
            let start = |_: &Relaunch| Err("unasked".to_owned());
            let wall_route = WallRoute {
                relaunch: WallRelaunch::Auto,
                walk: &walk,
                preference,
                host: Ok(fleet.map(str::to_owned)),
                halted: &halted,
                exited: &exited,
                start: &start,
            };
            route_passes(&wall_route, Baseline::default(), &[1_800_000_000], |pass| {
                let mut out = Produced::default();
                let mut notes = Vec::new();
                let routed = route(&obs, WallKind::Usage, false, pass, &mut out, &mut notes);
                assert!(matches!(routed, Routed::Left), "{case}");
                assert_eq!(notes, want, "{case}");
                out
            });
            assert_eq!(walks.get() > 0, asked, "{case}");
        }
    }

    /// A wall held by a halt tells each refusal once while it stands and a
    /// changed one again, before its reset and after it: a halt the mailbox
    /// could not read (`halt-unread`) after a standing halt is told, never
    /// hidden under the first, and the same refusal whose cause text moves
    /// from pass to pass is told once. A wall told and left, then walked
    /// again on each quiet pass, tells its halt refusal once the same way.
    /// An exit is the same refusal while its keyed line stands, whatever
    /// its stderr says, and another one when the keyed value names another
    /// repair. A wall a watch before the refusal mark held (a bare `held`)
    /// is still held: once its halt clears after the reset, the wake's
    /// resume is queued. The lines are the ones the overseer reads under
    /// `usage-limit` (`oversee-events.md`).
    #[test]
    fn a_held_wall_tells_each_changed_halt_refusal_once() {
        #[derive(Clone, Copy)]
        enum Read {
            Halted,
            Unread(&'static str),
            /// `lane-mail events`' exit 2: its keyed line, and its stderr.
            Exit(&'static str, &'static str),
            Clear,
        }
        const BEFORE: u64 = 1_800_000_000;
        // Past the 2027-10-04T18:00:00Z reset the message names.
        const PASSED: u64 = 1_822_672_800 + 60;
        let message = "You've hit your weekly limit · resets Oct 4, 2027, 6pm (UTC)";
        const HALTED: &str = "wall-relaunch-refused lane=gh-1 reason=halted";
        const UNREAD: &str =
            "wall-relaunch-refused lane=gh-1 reason=halt-unread cause=inbox: timeout pid=1";
        const JQ: &str = "command-missing=jq";
        const DATE: &str = "command-missing=date";
        const NO_JQ: &str = "wall-relaunch-refused lane=gh-1 reason=halt-unread cause=events: status=2 command-missing=jq";
        const NO_DATE: &str = "wall-relaunch-refused lane=gh-1 reason=halt-unread cause=events: status=2 command-missing=date";
        // The row a watch before the refusal mark wrote at a passed reset
        // it held: `first_seen|banner|identity|reported|screen|held|said`.
        let legacy = format!(
            "{BEFORE}|{banner}|none|usage-limit-passed|{banner}|held|",
            banner = hash_of(message)
        );
        // (case, the seeded row, whether the wake reaches the lane, per
        // pass: (now, the halt read, lines told, the wake's resume queued))
        type Step = (u64, Read, &'static [&'static str], bool);
        let scenarios: [(&str, Option<String>, bool, &[Step]); 4] = [
            (
                "halt_then_unread",
                None,
                false,
                &[
                    (BEFORE, Read::Halted, &[HALTED], false),
                    (BEFORE + 240, Read::Halted, &[], false),
                    (
                        BEFORE + 480,
                        Read::Unread("timeout pid=1"),
                        &[UNREAD],
                        false,
                    ),
                    (BEFORE + 720, Read::Unread("timeout pid=2"), &[], false),
                    (PASSED, Read::Unread("timeout pid=3"), &[], false),
                    (
                        PASSED + 240,
                        Read::Halted,
                        &["resume held reason=halted"],
                        false,
                    ),
                ],
            ),
            (
                "left_then_unread",
                None,
                false,
                &[
                    (BEFORE, Read::Clear, &["pick none"], false),
                    (
                        BEFORE + 240,
                        Read::Unread("timeout pid=1"),
                        &[UNREAD],
                        false,
                    ),
                    (BEFORE + 480, Read::Unread("timeout pid=2"), &[], false),
                    (BEFORE + 720, Read::Unread("timeout pid=3"), &[], false),
                ],
            ),
            (
                "exit_by_keyed_value",
                None,
                false,
                &[
                    (
                        BEFORE,
                        Read::Exit(JQ, "lane-mail: command-missing=jq\nat 1"),
                        &[NO_JQ],
                        false,
                    ),
                    (
                        BEFORE + 240,
                        Read::Exit(JQ, "lane-mail: command-missing=jq\nat 2"),
                        &[],
                        false,
                    ),
                    (
                        BEFORE + 480,
                        Read::Exit(DATE, "lane-mail: command-missing=date\nat 3"),
                        &[NO_DATE],
                        false,
                    ),
                    (
                        BEFORE + 720,
                        Read::Exit(DATE, "lane-mail: command-missing=date\nat 4"),
                        &[],
                        false,
                    ),
                ],
            ),
            (
                "legacy_held_cleared",
                Some(legacy),
                true,
                &[(PASSED + 480, Read::Clear, &["resume wake"], true)],
            ),
        ];
        for (case, seed, resumable, steps) in scenarios {
            let mut lane = walled_lane();
            if resumable {
                lane.launch = serde_json::from_value(json!({"pane": "%1", "server": 1})).unwrap();
                lane.mail_root = Some("/w".to_owned());
            }
            let obs = observed(&lane, message);
            let read = std::cell::Cell::new(Read::Clear);
            // No account has room, and the wall names its reset: the lane
            // waits, told once.
            let walk = |_: &str, request: &WalkRequest| {
                Ok(Walked {
                    answer: WalkAnswer::None,
                    walk: request.preference.clone().unwrap_or_default(),
                    entries: 0,
                    skipped: Vec::new(),
                    walled: 0,
                    unmeasured: 0,
                    unread: Vec::new(),
                    deprecated: Vec::new(),
                })
            };
            let halted_at = |_: &Lane| match read.get() {
                Read::Halted => Ok(true),
                Read::Unread(cause) => Err(Refusal::Unanswered {
                    verb: "inbox",
                    cause: cause.to_owned(),
                }),
                Read::Exit(keyed, stderr) => Err(Refusal::Exit {
                    verb: "events",
                    status: Some(2),
                    keyed: Some(keyed.to_owned()),
                    stderr: stderr.to_owned(),
                }),
                Read::Clear => Ok(false),
            };
            let exited = |_: &Lane| Err("unasked".to_owned());
            let start = |_: &Relaunch| Err("unasked".to_owned());
            let wall_route = WallRoute {
                relaunch: WallRelaunch::Auto,
                walk: &walk,
                preference: None,
                host: Ok(None),
                halted: &halted_at,
                exited: &exited,
                start: &start,
            };
            let mut baseline = Baseline::default();
            if let Some(row) = seed {
                baseline.apply(set("usage-limit", "gh-1", row));
            }
            let nows: Vec<u64> = steps.iter().map(|(now, ..)| *now).collect();
            let mut step = steps.iter();
            route_passes(&wall_route, baseline, &nows, |pass| {
                let &(now, halt, want, queued) = step.next().unwrap();
                read.set(halt);
                let mut out = Produced::default();
                wall(
                    &obs,
                    WallKind::Usage,
                    "",
                    WallSource::Rows,
                    message,
                    pass,
                    20,
                    &mut out,
                );
                let told: Vec<&str> = out
                    .events
                    .iter()
                    .filter_map(|e| {
                        if let Event::Tail(line) = e {
                            Some(line.as_str())
                        } else {
                            None
                        }
                    })
                    .filter(|line| {
                        ["wall-relaunch-refused", "resume ", "pick "]
                            .iter()
                            .any(|told| line.starts_with(told))
                    })
                    .collect();
                assert_eq!(told, want, "{case} {now}");
                let lines = out
                    .events
                    .iter()
                    .filter(|e| matches!(e, Event::UsageLimit { .. }))
                    .count();
                assert_eq!(lines, usize::from(!want.is_empty()), "{case} {now}");
                let resumed = out.changes.iter().any(|change| {
                    matches!(change, Change::Set { kind, identity, .. }
                        if kind == wake::RESUME_KIND && identity == "gh-1")
                });
                assert_eq!(resumed, queued, "{case} {now}");
                out
            });
        }
    }

    /// A Pi lane relaunched once for its sign-in, whose replacement completed
    /// a turn and then met a new 401, has worked on its credentials, so the
    /// auth route may relaunch it again.
    #[test]
    #[allow(
        clippy::disallowed_methods,
        reason = "the test plants the lane's rows file the carrier writes"
    )]
    fn a_pi_replacement_s_completed_turn_confirms_its_sign_in() {
        let root = tempfile::tempdir().unwrap();
        let lane: Lane = serde_json::from_value(json!({
            "item": "KEN-1",
            "harness": "pi",
            "status": "running",
            "session_rows_at_launch": 1,
            "mail_root": root.path(),
        }))
        .unwrap();
        let file = lane_rows_file(&root.path().display().to_string(), "KEN-1");
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        let signed_out = r#"{"harness":"pi","event":"Stop","stop_reason":"error","message":"401 {\"type\":\"error\",\"error\":{\"type\":\"authentication_error\"}}","working_agents":0}"#;
        let completed =
            r#"{"harness":"pi","event":"Stop","stop_reason":"stop","working_agents":0}"#;
        std::fs::write(&file, format!("{signed_out}\n")).unwrap();
        assert_eq!(completed_turn_since_launch(&lane), Ok(false));
        std::fs::write(&file, format!("{signed_out}\n{completed}\n{signed_out}\n")).unwrap();
        assert_eq!(completed_turn_since_launch(&lane), Ok(true));
    }

    /// A predecessor's safety refusal, at or before the launch position,
    /// is not the relaunched lane's state; the same row after it is.
    #[test]
    fn a_predecessor_s_safety_refusal_is_not_the_relaunched_lane_s_row() {
        let lane: Lane = serde_json::from_value(json!({
            "item": "KEN-1",
            "harness": "claude",
            "status": "running",
            "session_rows_at_launch": 2,
        }))
        .unwrap();
        let refusal = |position| {
            rows::Row {
            position,
            harness: Some("claude".to_owned()),
            event: Some("StopFailure".to_owned()),
            error: Some("invalid_request".to_owned()),
            message: Some("API Error: Sonnet 4.5 can't help with this. Start a new session to continue.\n\nLearn more: https://www.anthropic.com/legal/aup".to_owned()),
            ..rows::Row::default()
        }
        };
        assert!(!launch_current(&lane, &refusal(2)));
        assert!(launch_current(&lane, &refusal(3)));
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

    /// One pass of the idle table: the lane read in a state on a screen at
    /// a row position, a wake the lane's mark confirms delivered at an epoch
    /// second, or the watch replaced by one that loads the stored baseline.
    enum Step {
        Read(LaneState, &'static str, usize),
        Woken(u64),
        Restart,
    }

    fn idle() -> LaneState {
        LaneState::Idle {
            capacity: false,
            cause: None,
        }
    }

    /// The `idle-after-return` lines one local Claude lane draws over
    /// `steps`, each read through [`observe_one`] and its rows applied as
    /// the runner commits a pass.
    #[allow(
        clippy::disallowed_methods,
        reason = "the fixture plants the wake record the wake duty writes"
    )]
    fn idle_lines(steps: &[Step]) -> usize {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let roots = agent_runtime::settings::Roots {
            project: root.clone(),
            common: root.clone(),
        };
        let environment = [(
            std::ffi::OsString::from("AGENT_RUNTIME_ACCOUNT_STATE_DIR"),
            root.join("accounts").into_os_string(),
        )];
        let settings = settings::load(
            &roots,
            &environment,
            &settings::Flags {
                state_dir: Some(root.clone()),
                private_env: false,
            },
        )
        .unwrap();
        let watch = settings.watch.get().unwrap();
        let lane: Lane = serde_json::from_value(json!({
            "item": "KEN-1",
            "harness": "claude",
            "status": "running",
            "window": "gh-1",
        }))
        .unwrap();
        let fleet = FleetState {
            lanes: vec![lane.clone()],
            overseer: None,
            fleet_log: Vec::new(),
            triaged: Vec::new(),
            launch_queue: Vec::new(),
            intents: Vec::new(),
        };
        let readers = Readers::kernel();
        let walk = |_: &str, _: &WalkRequest| Err("unasked".to_owned());
        let halted = |_: &Lane| Ok::<_, Refusal>(false);
        let exited = |_: &Lane| Err("unasked".to_owned());
        let start = |_: &Relaunch| Err("unasked".to_owned());
        let route = WallRoute {
            relaunch: watch.wall_relaunch,
            walk: &walk,
            preference: None,
            host: Ok(None),
            halted: &halted,
            exited: &exited,
            start: &start,
        };
        let roster = || Err("unasked".to_owned());
        let reads = hosted::Reads {
            gh: Path::new("/nonexistent/gh"),
            roster: &roster,
            project: &settings.roots.project,
            reads: &settings.reads,
        };
        let wall_pauses = |_: RecordWallPauses| Ok(());
        let hosts = Hosts::read(Path::new("/nonexistent"), std::iter::empty());
        let stored = root.join("oversee-watch.baseline.json");
        let mut baseline = Baseline::default();
        let mut told = 0;
        for (n, step) in steps.iter().enumerate() {
            let (state, screen, position) = match step {
                Step::Read(state, screen, position) => (state, *screen, *position),
                Step::Woken(at) => {
                    let mark = json!({"marks": {"KEN-1": {
                        "pane": "%1", "server": 1, "unread": "u", "turns_before": 0,
                        "line_digest": 0, "at": at,
                        "outcome": {"wake": "delivered", "turns_after": 1},
                    }}});
                    std::fs::write(root.join(wake::WAKE_FILE), mark.to_string()).unwrap();
                    continue;
                }
                Step::Restart => {
                    baseline.store(&stored).unwrap();
                    baseline = Baseline::load(&stored).unwrap();
                    continue;
                }
            };
            let walled = matches!(state, LaneState::Walled { .. });
            let obs = Observed {
                lane: &lane,
                name: "gh-1".to_owned(),
                pane_key: Some("1 %1".to_owned()),
                identity: None,
                screen: Some(screen.to_owned()),
                row: Some(rows::Row {
                    position,
                    message: walled.then(|| "429 Usage limit reached for this model".to_owned()),
                    ..rows::Row::default()
                }),
                provider_running: false,
                state: state.clone(),
            };
            let pass = Pass {
                fleet: &fleet,
                fleet_path: &root.join("fleet.json"),
                readers: &readers,
                baseline: &baseline,
                settings: &watch,
                now: 1_800_000_000 + 240 * u64::try_from(n).unwrap(),
                session: None,
                own_panes: &[],
                state_dir: &root,
                claim_store: &settings.claim_store,
                account_state: &settings.account_state,
                scripts: Path::new("/nonexistent"),
                route: &route,
                wall_pauses: &wall_pauses,
                hosted: &reads,
                copilot_home: None,
                server: None,
            };
            let mut out = Produced::default();
            observe_one(&obs, &pass, &hosts, 20, &mut out);
            assert_eq!(out.failed, None, "pass {n}");
            told += out
                .events
                .iter()
                .filter(|e| matches!(e, Event::IdleAfterReturn { .. }))
                .count();
            for change in out.changes {
                baseline.apply(change);
            }
        }
        told
    }

    /// The idle line tells a stopped turn once per pane, row position,
    /// confirmed wake and slice: a pass in another state between idle
    /// passes on the unchanged screen, or a restart on the stored baseline,
    /// tells it no second time; a first sighting that pass interrupts is not
    /// confirmed; a changed slice, position or confirmed wake is a new turn.
    #[test]
    fn the_idle_line_tells_each_stopped_turn_once() {
        const DONE: &str = "Done: the suite passes.\n";
        let walled = LaneState::Walled {
            kind: WallKind::Usage,
            banner: String::new(),
            source: WallSource::Rows,
        };
        let unjudged = LaneState::Unjudged {
            cause: "foreground-unread".to_owned(),
        };
        let between = |state: LaneState| {
            vec![
                Step::Read(idle(), DONE, 3),
                Step::Read(idle(), DONE, 3),
                Step::Read(state, "Running the suite\n", 3),
                Step::Read(idle(), DONE, 3),
                Step::Read(idle(), DONE, 3),
            ]
        };
        let rows: Vec<(&str, Vec<Step>, usize)> = vec![
            ("working_between", between(LaneState::Working), 1),
            ("unjudged_between", between(unjudged), 1),
            ("walled_between", between(walled), 1),
            ("asking_between", between(LaneState::Asking), 1),
            ("switch_between", between(LaneState::RateLimitSwitch), 1),
            (
                "restart_after_working",
                vec![
                    Step::Read(idle(), DONE, 3),
                    Step::Read(idle(), DONE, 3),
                    Step::Read(LaneState::Working, "Running the suite\n", 3),
                    Step::Restart,
                    Step::Read(idle(), DONE, 3),
                    Step::Read(idle(), DONE, 3),
                ],
                1,
            ),
            (
                "first_sighting_interrupted",
                vec![
                    Step::Read(idle(), DONE, 3),
                    Step::Read(LaneState::Working, "Running the suite\n", 3),
                    Step::Read(idle(), DONE, 3),
                ],
                0,
            ),
            (
                "new_slice_after_working",
                vec![
                    Step::Read(idle(), DONE, 3),
                    Step::Read(idle(), DONE, 3),
                    Step::Read(LaneState::Working, "Running the suite\n", 3),
                    Step::Read(idle(), "Done: the fix is committed.\n", 3),
                    Step::Read(idle(), "Done: the fix is committed.\n", 3),
                ],
                2,
            ),
            (
                "new_position_after_working",
                vec![
                    Step::Read(idle(), DONE, 3),
                    Step::Read(idle(), DONE, 3),
                    Step::Read(LaneState::Working, "Running the suite\n", 3),
                    Step::Read(idle(), DONE, 5),
                    Step::Read(idle(), DONE, 5),
                ],
                2,
            ),
            (
                "confirmed_wake_after_working",
                vec![
                    Step::Read(idle(), DONE, 3),
                    Step::Read(idle(), DONE, 3),
                    Step::Woken(1_800_000_500),
                    Step::Read(LaneState::Working, "Running the suite\n", 3),
                    Step::Read(idle(), DONE, 3),
                    Step::Read(idle(), DONE, 3),
                ],
                2,
            ),
        ];
        for (name, steps, want) in rows {
            assert_eq!(idle_lines(&steps), want, "{name}");
        }
    }
}
