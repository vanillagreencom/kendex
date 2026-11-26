//! The wake duty: a lead or lane the mail duty reports unread mail for is
//! read positively idle, by identity and markers, and typed one line,
//! confirmed by a new user turn in that session's own bound file or a
//! hosted prompt row with the sent text's digest; a harness with no confirmable
//! route gets its limit reported. The duty acts only through
//! agent-runtime's `deliver` verb, run by the one runner under the `wake`
//! tag, and records its mark in the watch's own record (`ops::wake`),
//! durably, before it types, so a crash between the mark and the paste
//! never repeats a nudge for the same unread state; a later unread state
//! is a new wake. The record is read at the start of each pass: nothing
//! the fleet record's writers do to a lane or overseer record moves a mark.
//!
//! Lost outcome: a pass that stops after its mark and before the send's
//! answer leaves the mark with no outcome, the line typed whole, in part or
//! not at all. The next pass that meets that mark, for its unread state or
//! its resume, reconciles it once and types nothing for it: a local target's
//! bound file read past the mark's count, a later user turn being the
//! delivery and none `wake-unconfirmed cause=outcome-lost`; a hosted lane's
//! prompt rows are read once for the matching digest, else `outcome-lost`.
//!
//! Slot: the mail duty sets a baseline row of kind [`UNREAD_KIND`], its
//! identity the target (an item key, or [`OVERSEER_TARGET`]), its value the
//! unread state it announced (the newest unread envelope's id or index),
//! while the target's box holds mail the target has not read, and clears
//! the row once read. The wake reads that row from its tick's snapshot and
//! writes no row of its own.
//!
//! Resume: the lane and controller duties set a row of kind [`RESUME_KIND`]
//! for a passed lane wall (`usage-limit|<identity>|<reset>`), or a failed
//! turn (`<cause>|<key>`) on a reachable session. The identity is the lane's
//! name or [`OVERSEER_TARGET`]. The wake types the resume sentence before the inbox
//! line once per row value: the mark keeps the value typed. The overseer's
//! failed turn is asked as `<cause>|<key>|pass:<epoch>`, the pass's own
//! second, so its row changes every pass and the wake resumes it once per
//! pass while the failure stands. A wall's resume
//! waits for the lane's account, read through the close's own account read,
//! to read room and for any standing halt to lift, then is typed past its usage banner (`deliver
//! --account-room`).
//!
//! Hosted: a running lane whose host's line reads `launch=ssh`,
//! `pane=local`, `status=verb` runs its harness on that host under the ssh
//! client its window here holds. Its unread mail is typed into that window
//! through `deliver --transport` once the provider's `status` reads the
//! harness running. A running lane whose host's line reads `launch=ssh`,
//! `pane=verb` runs its harness in the provider's own session: its window
//! here is a viewer's, typed nothing, and its line goes through the
//! provider's `send --file` once the watch's judge reads the provider's
//! capture idle. On a `files=verb` host, Claude Code, Codex and Copilot
//! prompt rows past the pre-send complete-line cursor confirm the digest.
//! Pending, unmatched or failed post-send reads are read once on later
//! passes without resending. No evidence gives final `session-hosted`; a
//! failed pre-send cursor read still sends, final `rows-host-unread`. An
//! unanswered transport paste keeps `paste-unanswered`. A failed
//! turn's resume reaches either kind by the same route and is final as
//! typed; a provider read that refuses it is told once. A wall's resume is
//! local alone.
//!
//! The duty starts no detached process: nothing new charges the lane cap.
//!
//! The owner: an overseer the duty leaves idle
//! with its mail unread, `wake-limit` or `wake-unconfirmed` for the
//! [`OVERSEER_TARGET`], has no reader of the log but itself, so the owner
//! is told through the overseer mailbox's owner channel
//! (`super::owner_alert`): the event on the pass that reads it, the alert
//! on the next, once per unread state, the turn's word kept in the mark
//! beside the outcome. A lane's limit is the overseer's to handle.
//!
//! Follow: an overseer that follows the watch's log is woken by the log's
//! next line however its turn ended, a harness whose background exit starts
//! no turn included. Each pass reads the live claim's waiter through the
//! claim's one judge: a running waiter's start line is recorded
//! (`WakeRecord::follow_start`, what the overseer had consumed) and the
//! follow mark cleared. With no waiter running, a recorded start, a line at
//! or past it in the log, no unread row for the overseer (the mail line
//! wakes it then), no pending succession, no stop and no standing overseer
//! handoff, the idle overseer is typed one line naming the claim's start
//! command, once per mark under [`FOLLOW_TARGET`], confirmed by a new user
//! turn. A confirmed line writes no log line, since that line would stand
//! past the start again; a limit or an unconfirmed paste is said once and
//! the owner told once, as for its mail.

use agent_runtime::controller::Overseer;
use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::harness::Harness;
use agent_runtime::host;
use agent_runtime::reading::Reading;
use agent_runtime::stop::{self, Kind};
use serde_json::Value;

use super::claim;
use super::events;
use super::hosted::{self, Capabilities, Files, HostStatus, Launch, PaneKind, Status};
use super::lanes::LaneState;
use super::owner_alert::{self, Word};
use super::{Body, Event, Produced, Runner, Tick, context};
use crate::error::{Error, Result, WatchError};
use crate::mailbox::{DATA_RULE, Mailbox};
pub use crate::ops::wake::OVERSEER_TARGET;
use crate::ops::wake::{OUTCOME_LOST, ROWS_CURSOR_UNREAD, WakeMark, WakeOutcome, WakeRecord};
use crate::schedule::Duty;
use crate::settings::Settings;
use crate::state::{self, FleetState, Lane, LaneStatus, Record};
use agent_runtime::effects::overseer_socket;

/// The baseline row kind the mail duty signals unread mail with.
pub const UNREAD_KIND: &str = "unread";
/// The baseline row kind the lane and controller duties ask a resume with.
pub const RESUME_KIND: &str = "resume";
/// The resume row's cause for a session at a usage wall: typed past the
/// banner once its account reads room.
pub const WALL_CAUSE: &str = "usage-limit";

/// The cause of the resume row `row` where its key opens with the session
/// key `session` (`<cause>|<session>|…`), the one reading of whose session
/// a row asks for.
pub(super) fn resume_cause<'r>(row: &'r str, session: &str) -> Option<&'r str> {
    let (cause, key) = row.split_once('|')?;
    key.strip_prefix(session)?.starts_with('|').then_some(cause)
}

/// Whether a turn that ended on `cause` can spend a continuation: a
/// provider stop as agent-runtime names it, from a row word or a
/// pane-classified API error, or a reading lane's output limit.
pub(super) fn can_continue(harness: Harness, cause: &str, reading: bool) -> bool {
    stop::of_cause(harness, cause) == Some(Kind::Provider) || (reading && cause == "length")
}

/// Preserve one continuation through repeated failures until a finished
/// turn ends the chain. An existing wall resume does not spend it.
pub(super) fn continued(row: Option<&str>) -> bool {
    row.and_then(|r| r.split_once('|'))
        .is_some_and(|(cause, _)| cause != WALL_CAUSE)
}

/// The watch's wake record, beside the fleet state: it shares the runner's
/// own records' stem, which the retention duty never judges.
pub const WAKE_FILE: &str = "oversee-watch.wake.json";
/// What the verb may take past its own bound to read the pane and answer.
const ANSWER_MARGIN: Duration = Duration::from_secs(15);
/// Each read fetches the whole file through an ssh broker. One second
/// between calls keeps one wake from making sixty requests in fifteen seconds.
const HOST_ROWS_POLL: Duration = Duration::from_secs(1);
/// The owner alert's notice file under the state directory.
const ALERT_FILE: &str = "overseer-wake-unread.txt";
/// The follow wake's target word: its mark's key and its lines' target.
pub const FOLLOW_TARGET: &str = "overseer-follow";
/// The follow wake's owner notice file under the state directory.
const FOLLOW_ALERT_FILE: &str = "overseer-wake-follow.txt";
/// The limit an API error's resume refused before typing stands under: its
/// idle line is told instead, and the mark has an outcome, so no later pass
/// reconciles it as a lost send.
const RESUME_REFUSED: &str = "resume-refused";

/// The wake record's path for the fleet state at `fleet`.
pub fn record_path(fleet: &Path) -> PathBuf {
    fleet.parent().unwrap_or(Path::new(".")).join(WAKE_FILE)
}

/// The one line typed, which runs the target's inbox read. Only the
/// overseer's own box takes a data notice, so only its line says the data
/// rule.
fn line_for(target: &str) -> String {
    if target == OVERSEER_TARGET {
        return format!(
            "Run .agents/skills/mailbox/scripts/lane-mail inbox --item {target}. {DATA_RULE} Act on every other envelope it prints, answers and directives alike, as its text directs."
        );
    }
    format!(
        "Run .agents/skills/mailbox/scripts/lane-mail inbox --item {target} and act on every envelope it prints, answers and directives alike, as its text directs."
    )
}

fn line_digest(line: &str) -> u32 {
    agent_runtime::session::text_digest(line)
}

/// The follow wake's line: `start` is the claim's start command, its
/// `[RUN_DIR]` and `[NEXT_LINE]` the session's own to fill.
fn follow_line(start: &str) -> String {
    format!(
        "The fleet watch log has lines past your last follow and no follow runs: handle each numbered line from your next unhandled line, then re-arm with {start}"
    )
}

/// A resume the lanes duty asked for the lane `lane`: its row's value,
/// which the mark keeps once typed, and the cause the row names.
struct Resume {
    lane: String,
    row: String,
    cause: String,
    /// How the session's last turn ended, as the sentence says it.
    ended: &'static str,
    /// Whether the turn ended at a wall: its pane stands at a usage banner
    /// only the account's reading with room judges past.
    wall: bool,
    /// A posted reading takes the normal idle report into verification.
    reading_has_result: bool,
}

impl Resume {
    /// The resume a row's value asks for; none for a cause the wake does
    /// not resume (`told|…`, an API error's resume already answered by the
    /// same end).
    fn of(lane: &str, row: &str) -> Option<Resume> {
        let (cause, _) = row.split_once('|')?;
        let ended = match cause {
            WALL_CAUSE => "its account's usage limit, which has since reset",
            "told" => return None,
            "length" => "the output limit",
            stop::API_ERROR => "an API error",
            cause
                if Harness::ALL
                    .iter()
                    .any(|harness| stop::of_cause(*harness, cause) == Some(Kind::Provider)) =>
            {
                "a provider error"
            }
            _ => return None,
        };
        Some(Resume {
            lane: lane.to_owned(),
            row: row.to_owned(),
            cause: cause.to_owned(),
            ended,
            wall: cause == WALL_CAUSE,
            reading_has_result: false,
        })
    }

    /// Whether the wake resumes `lane`, whose host declares `caps`, for this
    /// cause: a wall's resume spends an account its reading measures, an API
    /// error's any lane the wake types into.
    fn reaches(&self, lane: &Lane, caps: Option<Capabilities>) -> bool {
        if self.wall {
            resumable(lane)
        } else {
            reaches(lane, caps)
        }
    }

    /// The line typed for `target`: the resume sentence, then the inbox
    /// line, so the resumed turn reads the mail that waited too.
    fn line(&self, target: &str) -> String {
        if super::verifying::is_reading_lane(target) {
            return format!(
                "Continue the post-merge check for {target} using your original brief and box. Your last turn ended on {}. {}",
                self.ended,
                line_for(target)
            );
        }
        format!(
            "Resume the orch workflow for {target} from where this session stopped: your last turn ended on {}. {}",
            self.ended,
            line_for(target)
        )
    }
}

/// Whether the wake types into `lane`, whose host declares `caps`, at all;
/// the lanes duty asks an API error's resume for such a lane alone.
pub fn reaches(lane: &Lane, caps: Option<Capabilities>) -> bool {
    // The socket only names where a paste would go.
    target_of(lane, Path::new(""), || caps).is_some()
}

/// Whether the wake resumes `lane` at a passed wall: a lane it types into,
/// spending an account the wall's account reading measures. The lanes duty
/// asks a wall's resume for such a lane alone.
pub fn resumable(lane: &Lane) -> bool {
    lane_target(lane, Path::new(""))
        .is_some_and(|target| crate::effects::room_measured(lane, Some(target.harness)).is_some())
}

/// The outcome that left the target's mail unread, as the log said it;
/// none for a delivery or a mark with no outcome yet.
fn unwoken(target: &str, outcome: Option<&WakeOutcome>) -> Option<Event> {
    match outcome? {
        WakeOutcome::Delivered { .. } => None,
        WakeOutcome::Unconfirmed { cause } => Some(Event::WakeUnconfirmed {
            target: target.to_owned(),
            cause: cause.clone(),
            resume: None,
        }),
        WakeOutcome::Limit { harness, cause } => Some(Event::WakeLimit {
            target: target.to_owned(),
            harness: harness.clone(),
            cause: cause.clone(),
            resume: None,
        }),
    }
}

/// Where the owner's turn stands once `mark`'s outcome is on the log: told
/// for the overseer left unwoken, for its mail or its follow, where no turn
/// stands yet (an alerted state is never alerted again, whatever its later
/// outcome); nothing for a delivery or a lane, whose limit the overseer
/// handles (`lane-reach.md` § Mail the wake cannot deliver).
fn owner_word(target: &str, mark: &WakeMark) -> Option<Word> {
    if !matches!(target, OVERSEER_TARGET | FOLLOW_TARGET)
        || unwoken(target, mark.outcome.as_ref()).is_none()
    {
        return None;
    }
    mark.owner.or(Some(Word::Told))
}

/// The line a confirmed delivery to `target` writes: none for the follow
/// wake, whose own line would stand past the start it woke the session for.
fn delivered(target: &str, resume: Option<String>) -> Option<Event> {
    (target != FOLLOW_TARGET).then(|| Event::WakeDelivered {
        target: target.to_owned(),
        resume,
    })
}

/// The owner's alert for an overseer left idle with its mail unread, in
/// the shape of `context::alert_text`: what stands unread, why no wake
/// reached it, what the owner can do.
fn alert_text(pane: &str, unread: &str, said: &Event) -> String {
    let why = said.render();
    let why = why.strip_prefix("EVENT ").unwrap_or(&why);
    let line = line_for(OVERSEER_TARGET);
    format!(
        "{why}: the overseer in pane {pane} is idle with mail past its read cursor that has no recorded reply, newest unread={unread}, and the watch could not wake it, so nothing acts on that mail until a turn runs in that pane. Type one line into pane {pane}, such as: {line} The remedy for this line is under idle-unread in the orch skill's references/oversee-events.md.\n"
    )
}

/// The owner's alert for an overseer left idle with watch lines past its
/// last follow and no follow running.
fn follow_alert_text(pane: &str, said: &Event) -> String {
    let why = said.render();
    let why = why.strip_prefix("EVENT ").unwrap_or(&why);
    format!(
        "{why}: the overseer in pane {pane} is idle, the fleet watch log has lines past its last follow and no follow runs, and the watch could not wake it, so nothing acts on those lines until a turn runs in that pane. Type one line into pane {pane} that asks it to handle each numbered line of the fleet watch log from its next unhandled line and re-arm its follow. The remedy for this line is under wake-limit in the orch skill's references/oversee-events.md.\n"
    )
}

/// A target's recorded facts, as `deliver` takes them: the pane by its
/// exact key on its server, the harness and the identity holding the pane,
/// and the home, directory and id its session file is found by; and how
/// its line reaches it.
struct Target {
    name: String,
    harness: Harness,
    pane: String,
    server: u64,
    server_start: Option<u64>,
    socket: PathBuf,
    identity: Option<(u64, String)>,
    home: Option<PathBuf>,
    cwd: PathBuf,
    session_id: Option<String>,
    route: Route,
    prompt_rows: bool,
}

impl Target {
    fn rows_lane(&self) -> Option<&Lane> {
        if !self.prompt_rows {
            return None;
        }
        match &self.route {
            Route::Transport { lane, .. } | Route::Send { lane, .. } => Some(lane),
            Route::Pane => None,
        }
    }
}

/// How a target's line reaches it.
enum Route {
    /// Typed into its pane here, where its harness runs.
    Pane,
    /// Typed into its pane here, whose ssh client runs the harness on
    /// `host` (`deliver --transport`).
    Transport { host: String, lane: Box<Lane> },
    /// Sent through `host`'s own `send`, the provider holding the harness's
    /// session; the pane here is a viewer's window, the mark's key alone,
    /// and nothing is typed into it. `lane` is the record the watch's judge
    /// reads the harness by.
    Send { host: String, lane: Box<Lane> },
}

fn u64_of(value: &Value) -> Option<u64> {
    match value {
        Value::Number(n) => n.as_u64(),
        Value::String(s) => s.parse().ok(),
        Value::Null | Value::Bool(_) | Value::Array(_) | Value::Object(_) => None,
    }
}

/// A lane as a target: its launch pane on the fleet server, its recorded
/// harness identity, and its session under the account home, else the
/// harness's default home (as `effects::launch` reads them). Pi uses its
/// recorded launch home because its account can be a provider seat.
/// A lane with no harness, pane, server or
/// directory is nobody to type into. Nor is a lane whose record names
/// another host: its session runs there, the pane here holds the client,
/// and no file here confirms its turn; [`hosted_target`] names such a lane
/// for the unread wake alone. Nor is a lane that is not running: it is
/// relaunched, never woken, and the mail duty's unread row for it stands
/// until that duty's next turn.
fn lane_target(lane: &Lane, socket: &Path) -> Option<Target> {
    if lane.host.as_deref().is_some_and(|h| h != "local") {
        return None;
    }
    window_target(lane, socket)
}

/// A hosted lane as a target: a running lane whose host's line reads
/// `launch=ssh`, and either `pane=local` with `status=verb`, its window here
/// holding the ssh client its harness runs under on the host, or
/// `pane=verb`, the provider holding the harness's session and its window
/// here a viewer's. It names no identity, home or session: the pane's
/// foreground is the client or a viewer, and the session's file is on the
/// host.
fn hosted_target(lane: &Lane, caps: Capabilities, socket: &Path) -> Option<Target> {
    let host = hosted::host_of(lane).to_owned();
    let route = match caps.pane {
        PaneKind::Local if caps.status == Status::Verb => Route::Transport {
            host,
            lane: Box::new(lane.clone()),
        },
        PaneKind::Local => return None,
        PaneKind::Verb => Route::Send {
            host,
            lane: Box::new(lane.clone()),
        },
    };
    let target = window_target(lane, socket).filter(|_| caps.launch == Some(Launch::Ssh))?;
    Some(Target {
        identity: None,
        home: None,
        session_id: None,
        route,
        prompt_rows: caps.files == Files::Verb && target.harness != Harness::Pi,
        ..target
    })
}

/// A lane as the wake's target: its window here, else a hosted lane's under
/// the line `line` gives, asked only where no local window answers.
fn target_of(
    lane: &Lane,
    socket: &Path,
    line: impl FnOnce() -> Option<Capabilities>,
) -> Option<Target> {
    lane_target(lane, socket).or_else(|| hosted_target(lane, line()?, socket))
}

/// The line `lane`'s host declares, read once per pass into `lines`; none
/// for a local lane or a line that could not be read.
fn host_line(
    lines: &mut BTreeMap<String, std::result::Result<Capabilities, String>>,
    scripts: &Path,
    lane: &Lane,
) -> Option<Capabilities> {
    let host = hosted::host_of(lane);
    if host == crate::provider::LOCAL {
        return None;
    }
    lines
        .entry(host.to_owned())
        .or_insert_with(|| hosted::capabilities(scripts, host))
        .as_ref()
        .ok()
        .copied()
}

/// Whether `lane`'s standing mark is the one for `unread` on its recorded
/// window.
fn marked(record: &WakeRecord, lane: &Lane, unread: &str) -> bool {
    let Some(launch) = lane.launch.as_ref() else {
        return false;
    };
    matches!(
        (record.get(&lane.item), launch.pane.as_deref(), launch.server),
        (Some(mark), Some(pane), Some(server)) if mark.stands_for(unread, pane, server)
    )
}

fn hosted_open(mark: &WakeMark) -> bool {
    mark.turns_before != ROWS_CURSOR_UNREAD
        && match &mark.outcome {
            None => true,
            Some(WakeOutcome::Unconfirmed { cause }) => matches!(
                cause.as_str(),
                "turn-pending" | "turn-unmatched" | "rows-host-unread"
            ),
            Some(WakeOutcome::Delivered { .. } | WakeOutcome::Limit { .. }) => false,
        }
}

/// A running lane's recorded window as a target, wherever its harness runs.
fn window_target(lane: &Lane, socket: &Path) -> Option<Target> {
    if lane.status != LaneStatus::Running {
        return None;
    }
    let harness = Harness::parse(lane.harness.as_deref()?)?;
    let launch = lane.launch.as_ref()?;
    let identity = match (launch.pid, &launch.start) {
        (Some(pid), Some(start)) => Some((pid, start.clone())),
        (None, _) | (Some(_), None) => None,
    };
    let home = match harness {
        Harness::Pi => lane.home.as_deref().map(PathBuf::from),
        Harness::Claude | Harness::Codex | Harness::Copilot => {
            lane.account.as_deref().map(PathBuf::from)
        }
    };
    Some(Target {
        name: lane.item.clone(),
        harness,
        pane: launch.pane.clone()?,
        server: launch.server?,
        server_start: launch.server_start,
        socket: socket.to_path_buf(),
        identity,
        home,
        cwd: PathBuf::from(lane.mail_root.as_deref()?),
        session_id: lane.session_id.clone(),
        route: Route::Pane,
        prompt_rows: false,
    })
}

/// The overseer as a target: the session record's pane, server, harness
/// identity, home and directory, as the launchers wrote them, on `socket`.
fn overseer_target(overseer: &Overseer, socket: &Path) -> Option<Target> {
    let extra = &overseer.extra;
    let text = |key: &str| extra.get(key).and_then(Value::as_str);
    let harness = Harness::parse(text("harness")?)?;
    let identity = match (
        extra.get("harness_pid").and_then(u64_of),
        text("harness_start"),
    ) {
        (Some(pid), Some(start)) => Some((pid, start.to_owned())),
        (None, _) | (Some(_), None) => None,
    };
    Some(Target {
        name: OVERSEER_TARGET.to_owned(),
        harness,
        pane: text("pane")?.to_owned(),
        server: extra.get("server").and_then(u64_of)?,
        server_start: extra.get("server_start").and_then(u64_of),
        socket: socket.to_path_buf(),
        identity,
        home: text("home").map(PathBuf::from),
        cwd: PathBuf::from(text("cwd")?),
        session_id: overseer.session_id.clone(),
        route: Route::Pane,
        prompt_rows: false,
    })
}

/// What a `--no-paste` read of the target answered.
enum Read {
    /// Positively idle, with the bound file's user-turn count.
    Idle { turns: u64 },
    /// Idle, and no confirmable route: nothing to type into.
    Limit { harness: String, cause: String },
    /// Not idle, or the pane gone or unreadable.
    Refused,
}

/// What a paste answered.
enum Paste {
    Confirmed {
        turns_after: u64,
    },
    Unconfirmed {
        cause: String,
    },
    /// Refused before anything was typed: the pane was no longer idle, or
    /// gone or unreadable, or the line never reached it.
    Refused,
}

enum Confirmation {
    Matched { turns_after: u64 },
    Unconfirmed { cause: String },
    Limit { harness: String, cause: String },
    Refused,
}

/// The refusals `deliver --key` answers, each with nothing pressed: the key
/// verb's own, field for field.
const KEY_REFUSALS: [&str; 8] = [
    "key-invalid",
    "pane-gone",
    "pane-unreadable",
    "pane-self",
    "process-mismatch",
    "deliver-refused",
    "key-unsent",
    "server-unmatched",
];

/// `lane key --item --key`: one key pressed into the dialog the item's
/// in-flight lane shows. The pane is resolved from the lane's record as the
/// wake resolves it: its window here, or a hosted lane's window whose ssh
/// client runs its harness. The checks and the key are agent-runtime's
/// `deliver --key`, whose refusal is this verb's. A lane the resolver gives
/// no pane refuses `lane-unreachable`; one whose provider holds its session
/// names `route=provider`, whose keys go through the provider's `send`.
pub fn press_key(settings: &Settings, fleet_path: &Path, item: &str, key: &str) -> Result<Value> {
    let unreachable = |fields: &[(&str, &str)]| {
        Error::from(agent_runtime::Error::refused("lane-unreachable", fields))
    };
    let fleet = super::lanes::read_fleet(fleet_path)?;
    let lane = super::lanes::in_flight(&fleet, item)?;
    let wake = Wake {
        fleet: fleet_path.to_path_buf(),
        record: record_path(fleet_path),
        settings: settings.clone(),
        clock: Box::new(agent_runtime::clock::SystemClock),
    };
    let socket = wake.socket(&fleet)?;
    let host_name = hosted::host_of(lane);
    let target = if host_name == crate::provider::LOCAL {
        lane_target(lane, &socket)
    } else {
        let scripts = super::overseer::scripts_dir(&settings.roots.project);
        let caps = hosted::capabilities(&scripts, host_name).map_err(|cause| {
            unreachable(&[("item", item), ("host", host_name), ("cause", &cause)])
        })?;
        hosted_target(lane, caps, &socket)
    };
    let target = match target {
        Some(Target {
            route: Route::Send { .. },
            ..
        }) => {
            return Err(unreachable(&[
                ("item", item),
                ("host", host_name),
                ("route", "provider"),
            ]));
        }
        Some(target) => target,
        None => return Err(unreachable(&[("item", item)])),
    };
    let mut args = wake.target_args(&target, false)?;
    args.extend(["--key".to_owned(), key.to_owned()]);
    let reply = match wake.deliver("lane-key", &args)? {
        Delivery::Reply(reply) => reply,
        Delivery::Unbuilt(build) => {
            let setup = settings.roots.project.join(crate::settings::ORCH_SETUP);
            let mut cause = format!("unbuilt: run {}", setup.display());
            if let Some(build) = build {
                cause.push_str(&format!("; its build refused: {build}"));
            }
            return Err(Error::Runtime(agent_runtime::Error::External {
                program: "agent-runtime",
                operation: "deliver",
                cause,
            }));
        }
    };
    if reply.get("ok").and_then(Value::as_bool) == Some(true) {
        let mut result = reply.get("result").cloned().unwrap_or(Value::Null);
        if let Value::Object(fields) = &mut result {
            fields.insert("item".to_owned(), Value::from(item));
        }
        return Ok(result);
    }
    let refusal = reply.get("refusal");
    let key = refusal
        .and_then(|r| r.get("key"))
        .and_then(Value::as_str)
        .and_then(|k| KEY_REFUSALS.into_iter().find(|known| *known == k))
        .ok_or_else(|| protocol_error("refused", &reply))?;
    let fields = refusal
        .and_then(|r| r.get("fields"))
        .and_then(Value::as_array)
        .map(|fields| {
            fields
                .iter()
                .filter_map(|field| {
                    Some((
                        field.get(0)?.as_str()?.to_owned(),
                        field.get(1)?.as_str()?.to_owned(),
                    ))
                })
                .collect()
        })
        .unwrap_or_default();
    Err(Error::Runtime(agent_runtime::Error::Refused {
        key,
        fields,
    }))
}

/// The refusals that leave the pane untouched, which the duty leaves for
/// its next pass; any other refusal is the call itself failing.
const PANE_REFUSALS: [&str; 4] = [
    "deliver-refused",
    "pane-gone",
    "pane-unreadable",
    "paste-unsent",
];

/// Register the wake duty on `runner` for the fleet state at `fleet`, as
/// `watch run` registers every duty. The duty writes no fleet record: its
/// mark is the runner-private record beside the fleet state.
pub fn register(runner: &mut Runner<'_>, fleet: &Path, settings: &Settings) {
    runner.register(Duty::Wake, body(fleet, settings));
}

/// The wake duty's body for the fleet state at `fleet`.
pub fn body<'a>(fleet: &Path, settings: &Settings) -> Body<'a> {
    let wake = Wake {
        fleet: fleet.to_path_buf(),
        record: record_path(fleet),
        settings: settings.clone(),
        clock: Box::new(agent_runtime::clock::SystemClock),
    };
    Box::new(move |tick: &Tick| wake.run(tick))
}

struct Wake {
    fleet: PathBuf,
    /// The watch's wake record, [`record_path`] of `fleet`.
    record: PathBuf,
    settings: Settings,
    clock: Box<dyn agent_runtime::clock::Clock + Send>,
}

impl Wake {
    /// One pass: the unread and resume rows, then the overseer's follow. A
    /// follow arm that fails leaves the lines the rows earned standing, with
    /// its cause.
    fn run(&self, tick: &Tick) -> Result<Produced> {
        let mut produced = self.unread_and_resumes(tick)?;
        let mail_owed = tick
            .baseline
            .rows
            .iter()
            .any(|r| r.kind == UNREAD_KIND && r.identity == OVERSEER_TARGET);
        if let Err(cause) = self.follow(tick.wall, mail_owed, &mut produced) {
            produced.failed = Some(cause.to_string());
        }
        Ok(produced)
    }

    /// The fleet watch's socket the targets' panes are on: the overseer
    /// record's, else the fleet's reach.
    fn socket(&self, fleet: &FleetState) -> Result<PathBuf> {
        Ok(match fleet.overseer.as_ref().and_then(overseer_socket) {
            Some(socket) => socket,
            None => crate::effects::fleet_reach(&self.settings)?
                .socket()?
                .to_path_buf(),
        })
    }

    fn unread_and_resumes(&self, tick: &Tick) -> Result<Produced> {
        let mut produced = Produced::default();
        let rows = |kind: &str| -> Vec<(String, String)> {
            tick.baseline
                .rows
                .iter()
                .filter(|r| r.kind == kind)
                .map(|r| (r.identity.clone(), r.value.clone()))
                .collect()
        };
        let unread = rows(UNREAD_KIND);
        let resumes = rows(RESUME_KIND);
        if unread.is_empty() && resumes.is_empty() {
            return Ok(produced);
        }
        // The marks as the record holds them at the start of this pass:
        // nothing is carried in memory between passes.
        let mut record = load_record(&self.record)?;
        let Some(fleet) = load_fleet(&self.fleet)? else {
            return Ok(produced);
        };
        let socket = self.socket(&fleet)?;
        let scripts = super::overseer::scripts_dir(&self.settings.roots.project);
        // Each host's line is shared by new sends and open receipt reads
        // in this pass.
        let mut lines = BTreeMap::new();
        // A resume goes first: its line runs the inbox read too, so the
        // unread state it types for stands marked when the mail is served.
        for (name, row) in resumes {
            let Some(mut resume) = Resume::of(&name, &row) else {
                continue;
            };
            if name == OVERSEER_TARGET {
                let Some(overseer) = fleet.overseer.as_ref().filter(|o| {
                    o.extra.get("off").is_none_or(Value::is_null)
                        && !fleet
                            .intents
                            .iter()
                            .any(|i| i.open() && i.op.on_controller())
                }) else {
                    continue;
                };
                let Some(target) = overseer_target(overseer, &socket) else {
                    continue;
                };
                let session = format!("{} {}", target.server, target.pane);
                if resume.wall || resume_cause(&row, &session).is_none() {
                    continue;
                }
                if let Some(mark) = record
                    .get(&name)
                    .filter(|m| m.resume.as_deref() == Some(row.as_str()))
                    .cloned()
                {
                    self.repeat(
                        &target,
                        mark,
                        Some(&resume.cause),
                        &mut record,
                        &mut produced,
                    )?;
                } else {
                    let state = wake_unread(&unread, &name, record.get(&name)).to_owned();
                    self.first_pass(
                        &target,
                        &state,
                        Some(&resume),
                        tick.wall,
                        &mut record,
                        &mut produced,
                    )?;
                }
                continue;
            }
            let Some(lane) = fleet
                .lanes
                .iter()
                .find(|l| super::lanes::lane_name(l) == name)
            else {
                continue;
            };
            let marked = record.get(&lane.item);
            if let Some(mark) = marked.filter(|m| m.resume.as_deref() == Some(row.as_str())) {
                if mark.outcome.is_none() {
                    let mark = mark.clone();
                    self.reconcile(
                        lane,
                        &socket,
                        mark,
                        Some(&resume.cause),
                        &mut record,
                        &mut produced,
                    )?;
                }
                continue;
            }
            let caps = host_line(&mut lines, &scripts, lane);
            if !resume.reaches(lane, caps) {
                continue;
            }
            let Some(target) = target_of(lane, &socket, || caps) else {
                continue;
            };
            if resume.wall {
                // A wall resume reaches local lanes alone. Check the halt
                // after the account reads room: a halt can land while this
                // resume is already owed.
                if crate::effects::account_room(
                    &self.settings,
                    &self.fleet,
                    "local",
                    lane,
                    Some(target.harness),
                    tick.wall,
                ) != "room"
                {
                    continue;
                }
                let mailbox =
                    Mailbox::new(crate::effects::fleet_mailbox(&self.settings).mail_program);
                match mailbox.lane_halted(lane) {
                    Ok(false) => {}
                    Ok(true) => continue,
                    Err(cause) => {
                        super::lanes::fail(
                            &mut produced,
                            format!("wall-resume {}: halt-unread cause={cause}", lane.item),
                        );
                        continue;
                    }
                }
            }
            let state = wake_unread(&unread, &target.name, marked).to_owned();
            if !resume.wall && super::verifying::is_reading_lane(&lane.item) {
                match super::verifying::reading_lane_has_result(&self.settings, lane) {
                    Ok(posted) => resume.reading_has_result = posted,
                    Err(cause) => {
                        super::lanes::fail(
                            &mut produced,
                            format!("reading-lane {}: {cause}", lane.item),
                        );
                        continue;
                    }
                }
            }
            self.first_pass(
                &target,
                &state,
                Some(&resume),
                tick.wall,
                &mut record,
                &mut produced,
            )?;
        }
        for (name, state) in unread {
            let target = if name == OVERSEER_TARGET {
                fleet
                    .overseer
                    .as_ref()
                    .and_then(|o| overseer_target(o, &socket))
            } else {
                let Some(lane) = fleet.lanes.iter().find(|l| l.item == name) else {
                    continue;
                };
                if let Some(mark) = record
                    .get(&lane.item)
                    .filter(|m| m.outcome.is_none() && marked(&record, lane, &state))
                    .cloned()
                {
                    self.reconcile(lane, &socket, mark, None, &mut record, &mut produced)?;
                    continue;
                }
                let line = || {
                    (!marked(&record, lane, &state)
                        || record.get(&lane.item).is_some_and(hosted_open))
                    .then(|| host_line(&mut lines, &scripts, lane))
                    .flatten()
                };
                target_of(lane, &socket, line)
            };
            let Some(target) = target else {
                continue;
            };
            self.serve(&target, &state, tick.wall, &mut record, &mut produced)?;
        }
        Ok(produced)
    }

    /// Set or drop the target's mark in `record` and write the record
    /// whole, durably, before the caller goes on.
    fn write(&self, record: &mut WakeRecord, target: &str, mark: Option<WakeMark>) -> Result<()> {
        match mark {
            Some(mark) => record.set(target, mark),
            None => record.clear(target),
        }
        store_record(&self.record, record)
    }

    /// One target with the unread state `unread`: a standing mark for it
    /// is re-read and never typed for again, and the overseer's owed alert
    /// goes out on it; a new state is read idle, marked, typed and
    /// confirmed.
    fn serve(
        &self,
        target: &Target,
        unread: &str,
        now: u64,
        record: &mut WakeRecord,
        produced: &mut Produced,
    ) -> Result<()> {
        if let Some(mark) = record.get(&target.name)
            && mark.stands_for(unread, &target.pane, target.server)
        {
            self.repeat(target, mark.clone(), None, record, produced)
        } else {
            self.first_pass(target, unread, None, now, record, produced)
        }
    }

    /// A lane's standing `mark` with no outcome (module doc, Lost outcome),
    /// `resume` the cause where the mark is the resume's: the target's
    /// evidence is re-read by [`Wake::repeat`]. A lane that
    /// is no target is relaunched, never woken.
    fn reconcile(
        &self,
        lane: &Lane,
        socket: &Path,
        mark: WakeMark,
        resume: Option<&str>,
        record: &mut WakeRecord,
        produced: &mut Produced,
    ) -> Result<()> {
        if hosted::host_of(lane) != crate::provider::LOCAL {
            let scripts = super::overseer::scripts_dir(&self.settings.roots.project);
            if mark.turns_before != ROWS_CURSOR_UNREAD
                && let Ok(caps) = hosted::capabilities(&scripts, hosted::host_of(lane))
                && let Some(target) = hosted_target(lane, caps, socket)
                && target.prompt_rows
            {
                return self.repeat(&target, mark, resume, record, produced);
            }
            return self.lost(&lane.item, mark, resume, record, produced);
        }
        match lane_target(lane, socket) {
            Some(target) => self.repeat(&target, mark, resume, record, produced),
            None => Ok(()),
        }
    }

    /// A mark with no outcome that no reading resolves: unconfirmed with
    /// [`OUTCOME_LOST`], told once, with the owner's word, and final.
    fn lost(
        &self,
        name: &str,
        mut mark: WakeMark,
        resume: Option<&str>,
        record: &mut WakeRecord,
        produced: &mut Produced,
    ) -> Result<()> {
        mark.outcome = Some(WakeOutcome::Unconfirmed {
            cause: OUTCOME_LOST.to_owned(),
        });
        mark.owner = owner_word(name, &mark);
        self.write(record, name, Some(mark))?;
        produced.events.push(Event::WakeUnconfirmed {
            target: name.to_owned(),
            cause: OUTCOME_LOST.to_owned(),
            resume: resume.map(str::to_owned),
        });
        Ok(())
    }

    /// A pass over the target's standing `mark`: never typed again; the
    /// file re-read for a late turn, a mark with no outcome reconciled, and
    /// the owner's turn for an overseer still unwoken. `resume` is the cause
    /// a reconciled resume's line names.
    fn repeat(
        &self,
        target: &Target,
        mut mark: WakeMark,
        resume: Option<&str>,
        record: &mut WakeRecord,
        produced: &mut Produced,
    ) -> Result<()> {
        let name = target.name.clone();
        match &mark.outcome {
            Some(WakeOutcome::Delivered { .. }) => return Ok(()),
            // A limit stands as read: the pane is not read again for it,
            // and the owner's turn is all that is left.
            Some(WakeOutcome::Limit { .. }) => return self.owner_turn(target, mark, record),
            None | Some(WakeOutcome::Unconfirmed { .. }) => {}
        }
        // The paste may have gone in: the file alone says whether the turn
        // arrived, and nothing is typed again for this mark.
        let confirmation = if matches!(target.route, Route::Pane) {
            match self.read(target, false)? {
                Read::Idle { .. } => self.confirm(target, &mark)?,
                Read::Limit { harness, cause } => Confirmation::Limit { harness, cause },
                Read::Refused => Confirmation::Refused,
            }
        } else {
            if mark.outcome.is_some() && !hosted_open(&mark) {
                return Ok(());
            }
            match self.hosted_confirmation(
                target,
                mark.turns_before,
                mark.line_digest,
                Duration::ZERO,
            ) {
                Paste::Confirmed { turns_after } => Confirmation::Matched { turns_after },
                Paste::Unconfirmed { .. } if mark.outcome.is_none() => {
                    return self.lost(&name, mark, resume, record, produced);
                }
                Paste::Unconfirmed { cause } => Confirmation::Unconfirmed { cause },
                Paste::Refused => Confirmation::Refused,
            }
        };
        match confirmation {
            Confirmation::Matched { turns_after } => {
                mark.outcome = Some(WakeOutcome::Delivered { turns_after });
                // Woken after all: nothing is owed to the owner.
                mark.owner = None;
                self.write(record, &name, Some(mark))?;
                produced
                    .events
                    .extend(delivered(&name, resume.map(str::to_owned)));
                Ok(())
            }
            Confirmation::Unconfirmed { cause }
                if cause == "turn-unmatched" || !matches!(target.route, Route::Pane) =>
            {
                let outcome = WakeOutcome::Unconfirmed {
                    cause: cause.clone(),
                };
                if mark.outcome.as_ref() == Some(&outcome) {
                    return self.owner_turn(target, mark, record);
                }
                let had_outcome = mark.outcome.is_some();
                mark.outcome = Some(outcome);
                if !had_outcome {
                    mark.owner = owner_word(&name, &mark);
                }
                self.write(record, &name, Some(mark))?;
                produced.events.push(Event::WakeUnconfirmed {
                    target: name,
                    cause,
                    resume: resume.map(str::to_owned),
                });
                Ok(())
            }
            Confirmation::Unconfirmed { .. } if mark.outcome.is_none() => {
                self.lost(&name, mark, resume, record, produced)
            }
            // Still idle and unwoken: the owner's turn.
            Confirmation::Unconfirmed { .. } => self.owner_turn(target, mark, record),
            // Not idle, or the pane gone or unreadable: the reading the
            // alert would stand on is not there this pass.
            Confirmation::Refused => Ok(()),
            Confirmation::Limit { harness, cause } => {
                mark.outcome = Some(WakeOutcome::Limit {
                    harness: harness.clone(),
                    cause: cause.clone(),
                });
                mark.owner = owner_word(&name, &mark);
                self.write(record, &name, Some(mark))?;
                produced.events.push(Event::WakeLimit {
                    target: name,
                    harness,
                    cause,
                    resume: resume.map(str::to_owned),
                });
                Ok(())
            }
        }
    }

    /// The overseer's follow (module doc, Follow): the claim's waiter read
    /// through the claim's one judge, its start recorded where one runs,
    /// else the follow line typed where a line stands at or past the start
    /// and no guard holds. `mail_owed` is an overseer unread row standing.
    fn follow(&self, now: u64, mail_owed: bool, produced: &mut Produced) -> Result<()> {
        let paths = claim::Paths::of(&self.fleet)?;
        let Some(held) = claim::read(&paths)? else {
            return Ok(());
        };
        // No live claim: no watch for a follow to read.
        if held.cwd.is_empty() || !matches!(claim::read_live(&held), Reading::Live(_)) {
            return Ok(());
        }
        let follow = claim::waiter(Path::new(&held.cwd), &held.origin, &paths.log);
        let running = match &follow.pattern {
            Some(pattern) => claim::running(pattern).map_err(|cause| {
                Error::Runtime(agent_runtime::Error::External {
                    program: "process-table",
                    operation: "read",
                    cause,
                })
            })?,
            None => None,
        };
        let mut record = load_record(&self.record)?;
        if let Some(start) = running {
            if record.follow_start != Some(start) || record.get(FOLLOW_TARGET).is_some() {
                record.follow_start = Some(start);
                self.write(&mut record, FOLLOW_TARGET, None)?;
            }
            return Ok(());
        }
        // No follow seen: the turn end holds a session that never armed one.
        let Some(start) = record.follow_start else {
            return Ok(());
        };
        if mail_owed || events::line_count(&paths.log)? < start {
            return Ok(());
        }
        let Some(fleet) = load_fleet(&self.fleet)? else {
            return Ok(());
        };
        let Some(overseer) = fleet.overseer.as_ref() else {
            return Ok(());
        };
        // A succession under way, a stopped controller or a handoff that
        // stands is the controller's own lifecycle, not an idle follower.
        if overseer.pending.is_some() || overseer.extra.get("off").is_some_and(|o| !o.is_null()) {
            return Ok(());
        }
        // The controller's handoff is the fleet record's own item's.
        let Some(item) = state::item_of(&self.fleet) else {
            return Ok(());
        };
        let dir = self.fleet.parent().unwrap_or(Path::new("."));
        let handoff = crate::ops::store::handoff_standing(dir, item, None)?;
        if handoff["standing"].as_str() != Some("none") {
            return Ok(());
        }
        let Some(target) = overseer_target(overseer, &self.socket(&fleet)?) else {
            return Ok(());
        };
        let target = Target {
            name: FOLLOW_TARGET.to_owned(),
            ..target
        };
        match record.get(FOLLOW_TARGET) {
            Some(mark) if mark.stands_for("", &target.pane, target.server) => {
                self.repeat(&target, mark.clone(), None, &mut record, produced)
            }
            Some(_) | None => self.follow_first(&target, &follow.start, now, &mut record, produced),
        }
    }

    /// The follow line for an overseer no mark on its pane stands for: read
    /// idle, marked, typed and confirmed; a limit or an unconfirmed paste is
    /// said, with the owner's word; a paste refused before typing leaves
    /// the mark that stood.
    fn follow_first(
        &self,
        target: &Target,
        start: &str,
        now: u64,
        record: &mut WakeRecord,
        produced: &mut Produced,
    ) -> Result<()> {
        let name = target.name.clone();
        let standing = record.get(&name).cloned();
        let line = follow_line(start);
        let mut mark = WakeMark {
            pane: target.pane.clone(),
            server: target.server,
            server_start: target.server_start,
            unread: String::new(),
            turns_before: 0,
            line_digest: line_digest(&line),
            at: now,
            outcome: None,
            owner: None,
            resume: None,
        };
        let events = match self.read(target, false)? {
            Read::Refused => return Ok(()),
            Read::Limit { harness, cause } => {
                mark.outcome = Some(WakeOutcome::Limit {
                    harness: harness.clone(),
                    cause: cause.clone(),
                });
                vec![Event::WakeLimit {
                    target: name.clone(),
                    harness,
                    cause,
                    resume: None,
                }]
            }
            Read::Idle { turns } => {
                mark.turns_before = turns;
                // The mark is on disk before anything is typed.
                self.write(record, &name, Some(mark.clone()))?;
                match self.paste(target, &line, turns, false)? {
                    Paste::Confirmed { turns_after } => {
                        mark.outcome = Some(WakeOutcome::Delivered { turns_after });
                        delivered(&name, None).into_iter().collect()
                    }
                    Paste::Unconfirmed { cause } => {
                        mark.outcome = Some(WakeOutcome::Unconfirmed {
                            cause: cause.clone(),
                        });
                        vec![Event::WakeUnconfirmed {
                            target: name.clone(),
                            cause,
                            resume: None,
                        }]
                    }
                    Paste::Refused => return self.write(record, &name, standing),
                }
            }
        };
        mark.owner = owner_word(&name, &mark);
        self.write(record, &name, Some(mark))?;
        produced.events.extend(events);
        Ok(())
    }

    /// The owner's turn for a standing overseer mark whose outcome left the
    /// mail unread: the alert on the pass after the outcome was said, the
    /// mark advanced to `alerted` only once the owner holds the words, so
    /// an alert the owner did not get is sent again on the next pass;
    /// nothing after for this unread state. A mark that owes nothing (a
    /// lane's, a delivery's, one alerted already) is left as it is.
    fn owner_turn(
        &self,
        target: &Target,
        mut mark: WakeMark,
        record: &mut WakeRecord,
    ) -> Result<()> {
        if mark.owner != Some(Word::Told) {
            return Ok(());
        }
        let Some(said) = unwoken(&target.name, mark.outcome.as_ref()) else {
            return Ok(());
        };
        let (file, text, fields) = if target.name == FOLLOW_TARGET {
            (
                FOLLOW_ALERT_FILE,
                follow_alert_text(&target.pane, &said),
                format!("pane={} target={FOLLOW_TARGET}", target.pane),
            )
        } else {
            (
                ALERT_FILE,
                alert_text(&target.pane, &mark.unread, &said),
                format!("pane={} unread={}", target.pane, mark.unread),
            )
        };
        match owner_alert::send(&self.settings, file, &text) {
            Ok(()) => {
                mark.owner = Some(Word::Alerted);
                self.write(record, &target.name, Some(mark))?;
                context::note("wake-owner-alerted", &fields);
            }
            Err(cause) => context::note(
                "overseer-notice-failed",
                &format!("channel=owner cause={cause}"),
            ),
        }
        Ok(())
    }

    /// A new unread state, or the resume `resume` asks: the target read
    /// idle, marked, typed where its harness has a route and confirmed, the
    /// outcome and the owner's word written with the mark. A resume types its
    /// sentence before the inbox line and says `resume=` on its line, with no
    /// `idle-unread`; a wall's reads the pane past its usage banner; every
    /// mark carries the last resume typed for the target.
    fn first_pass(
        &self,
        target: &Target,
        unread: &str,
        resume: Option<&Resume>,
        now: u64,
        record: &mut WakeRecord,
        produced: &mut Produced,
    ) -> Result<()> {
        let name = target.name.clone();
        let standing = record.get(&name).cloned();
        let line = resume.map_or_else(|| line_for(&name), |r| r.line(&name));
        let mut mark = WakeMark {
            pane: target.pane.clone(),
            server: target.server,
            server_start: target.server_start,
            unread: unread.to_owned(),
            turns_before: 0,
            line_digest: line_digest(&line),
            at: now,
            outcome: None,
            owner: None,
            resume: resume
                .map(|r| r.row.clone())
                .or_else(|| standing.as_ref().and_then(|m| m.resume.clone())),
        };
        let said = resume.map(|r| r.cause.to_owned());
        let lines = |event: Event| match resume {
            Some(_) => vec![event],
            None => vec![Event::IdleUnread { lane: name.clone() }, event],
        };
        let limit = |mark: &mut WakeMark, harness: String, cause: String| {
            mark.outcome = Some(WakeOutcome::Limit {
                harness: harness.clone(),
                cause: cause.clone(),
            });
            lines(Event::WakeLimit {
                target: name.clone(),
                harness,
                cause,
                resume: said.clone(),
            })
        };
        let room = resume.is_some_and(|r| r.wall);
        if resume.is_some_and(|r| r.reading_has_result) {
            self.untyped(target, standing.as_ref(), resume, &mark, record, produced)?;
            return Ok(());
        }
        let read = match &target.route {
            // An exited or unread hosted harness is the lanes duty's to
            // name; the rows cursor is read only after this idle check.
            // A transport window's screen is judged by the paste itself; a
            // provider-held session's screen is the provider's capture, read
            // by the watch's one judge, and only an idle one is sent its line.
            Route::Transport { host, .. } => {
                let scripts = super::overseer::scripts_dir(&self.settings.roots.project);
                match hosted::status(&scripts, host, &name, target.harness.name()) {
                    Ok(HostStatus::Running) => Read::Idle { turns: 0 },
                    Ok(HostStatus::Exited) | Err(_) => Read::Refused,
                }
            }
            Route::Send { lane, .. } => {
                match super::lanes::judge(&self.settings, lane, Some(&target.socket), None) {
                    LaneState::Idle { .. } => Read::Idle { turns: 0 },
                    LaneState::Gone
                    | LaneState::Unreadable { .. }
                    | LaneState::Exited
                    | LaneState::Walled { .. }
                    | LaneState::Asking
                    | LaneState::RateLimitSwitch
                    | LaneState::Working
                    | LaneState::Unjudged { .. } => Read::Refused,
                }
            }
            Route::Pane => self.read(target, room)?,
        };
        let events = match read {
            Read::Refused => {
                self.untyped(target, standing.as_ref(), resume, &mark, record, produced)?;
                return Ok(());
            }
            Read::Limit { harness, cause } => limit(&mut mark, harness, cause),
            Read::Idle { turns } => {
                mark.turns_before = if matches!(target.route, Route::Pane) {
                    turns
                } else {
                    self.hosted_cursor(target)
                };
                // The mark is on disk before anything is typed.
                self.write(record, &name, Some(mark.clone()))?;
                match self.paste(target, &line, mark.turns_before, room)? {
                    Paste::Confirmed { turns_after } => {
                        mark.outcome = Some(WakeOutcome::Delivered { turns_after });
                        lines(Event::WakeDelivered {
                            target: name.clone(),
                            resume: said.clone(),
                        })
                    }
                    Paste::Unconfirmed { cause } => {
                        mark.outcome = Some(WakeOutcome::Unconfirmed {
                            cause: cause.clone(),
                        });
                        lines(Event::WakeUnconfirmed {
                            target: name.clone(),
                            cause,
                            resume: said.clone(),
                        })
                    }
                    Paste::Refused => {
                        // Nothing was typed: the mark that stood before
                        // stands again.
                        if !self.untyped(
                            target,
                            standing.as_ref(),
                            resume,
                            &mark,
                            record,
                            produced,
                        )? {
                            self.write(record, &name, standing)?;
                        }
                        return Ok(());
                    }
                }
            }
        };
        mark.owner = owner_word(&name, &mark);
        self.write(record, &name, Some(mark))?;
        produced.events.extend(events);
        Ok(())
    }

    /// A read or paste refused before anything was typed, for an API error's
    /// resume: the lanes duty left that end's line to the resume, so the
    /// line is told here instead, once, and the target's mark keeps the
    /// resume, so it is never typed afterwards. Where none stood, the mark
    /// stands for no unread state, so a mail wake for the target is still
    /// new, under [`RESUME_REFUSED`]. Answers whether it told; a wall's
    /// resume waits for the next pass.
    fn untyped(
        &self,
        target: &Target,
        standing: Option<&WakeMark>,
        resume: Option<&Resume>,
        mark: &WakeMark,
        record: &mut WakeRecord,
        produced: &mut Produced,
    ) -> Result<bool> {
        let Some(resume) = resume.filter(|r| !r.wall) else {
            return Ok(false);
        };
        let kept = WakeMark {
            resume: Some(resume.row.clone()),
            ..standing.cloned().unwrap_or_else(|| WakeMark {
                unread: String::new(),
                turns_before: 0,
                outcome: Some(WakeOutcome::Limit {
                    harness: target.harness.name().to_owned(),
                    cause: RESUME_REFUSED.to_owned(),
                }),
                ..mark.clone()
            })
        };
        self.write(record, &target.name, Some(kept))?;
        produced.events.push(Event::IdleAfterReturn {
            lane: resume.lane.clone(),
            note: Some(format!("cause={}", resume.cause)),
        });
        Ok(true)
    }

    /// Read the target through `deliver --no-paste`; `room` passes the
    /// account read with room, which judges a usage banner past.
    fn read(&self, target: &Target, room: bool) -> Result<Read> {
        let mut args = self.target_args(target, room)?;
        args.push("--no-paste".to_owned());
        match self.call(&args)? {
            Answer::Refused => Ok(Read::Refused),
            Answer::Result(result) => match result.get("delivery").and_then(Value::as_str) {
                Some("read") => Ok(Read::Idle {
                    turns: result
                        .get("turns")
                        .and_then(Value::as_u64)
                        .ok_or_else(|| protocol_error("a read without its turn count", &result))?,
                }),
                Some("limit") => Ok(Read::Limit {
                    harness: word(&result, "harness")?,
                    cause: word(&result, "cause")?,
                }),
                Some(_) | None => Err(protocol_error("not a read", &result)),
            },
        }
    }

    fn confirm(&self, target: &Target, mark: &WakeMark) -> Result<Confirmation> {
        let mut args = self.target_args(target, false)?;
        args.extend([
            "--no-paste".to_owned(),
            "--line-digest".to_owned(),
            mark.line_digest.to_string(),
            "--turns-before".to_owned(),
            mark.turns_before.to_string(),
            "--bound-secs".to_owned(),
            "0".to_owned(),
        ]);
        match self.call(&args)? {
            Answer::Refused => Ok(Confirmation::Refused),
            Answer::Result(result) => match result.get("delivery").and_then(Value::as_str) {
                Some("confirmed") => Ok(Confirmation::Matched {
                    turns_after: result
                        .get("turns_after")
                        .and_then(Value::as_u64)
                        .ok_or_else(|| {
                            protocol_error("a confirmation without its turn count", &result)
                        })?,
                }),
                Some("unconfirmed") => Ok(Confirmation::Unconfirmed {
                    cause: word(&result, "cause")?,
                }),
                Some("limit") => Ok(Confirmation::Limit {
                    harness: word(&result, "harness")?,
                    cause: word(&result, "cause")?,
                }),
                Some(_) | None => Err(protocol_error("not a confirmation", &result)),
            },
        }
    }

    /// Type `line` into the target through `deliver`, confirmed by equal
    /// text after `turns_before`; `room` as [`Wake::read`] takes it. A
    /// hosted target is confirmed by its prompt rows where available.
    /// A provider-held session takes the line through its provider's `send`:
    /// an unwritten input or a busy provider leaves the state for the next
    /// pass; any other failure may have typed
    /// part of the line, so it is final with its cause and never sent
    /// again for this state.
    fn paste(&self, target: &Target, line: &str, turns_before: u64, room: bool) -> Result<Paste> {
        if let Route::Send { host, .. } = &target.route {
            let scripts = super::overseer::scripts_dir(&self.settings.roots.project);
            return Ok(
                match hosted::send_text(
                    &scripts,
                    host,
                    &target.name,
                    &self.settings.state_dir,
                    line,
                ) {
                    Ok(()) => self.hosted_confirmation(
                        target,
                        turns_before,
                        line_digest(line),
                        self.settings.engine.verify.get()?,
                    ),
                    Err(hosted::Asked::Failed(cause))
                        if matches!(
                            cause.split_whitespace().next(),
                            Some(hosted::BUSY | hosted::SEND_INPUT_UNWRITTEN)
                        ) =>
                    {
                        Paste::Refused
                    }
                    Err(hosted::Asked::Failed(cause) | hosted::Asked::Unknown(cause)) => {
                        Paste::Unconfirmed { cause }
                    }
                },
            );
        }
        let mut args = self.target_args(target, room)?;
        args.extend([
            "--bound-secs".to_owned(),
            self.settings.engine.verify.get()?.as_secs().to_string(),
        ]);
        if matches!(target.route, Route::Pane) {
            args.extend(["--turns-before".to_owned(), turns_before.to_string()]);
        }
        args.extend(["--line".to_owned(), line.to_owned()]);
        match self.call(&args)? {
            Answer::Refused => Ok(Paste::Refused),
            Answer::Result(result) => match result.get("delivery").and_then(Value::as_str) {
                Some("confirmed") => Ok(Paste::Confirmed {
                    turns_after: result
                        .get("turns_after")
                        .and_then(Value::as_u64)
                        .ok_or_else(|| {
                            protocol_error("a confirmation without its turn count", &result)
                        })?,
                }),
                Some("unconfirmed") => Ok(Paste::Unconfirmed {
                    cause: word(&result, "cause")?,
                }),
                Some("pasted")
                    if result.get("cause").and_then(Value::as_str) == Some("paste-unanswered") =>
                {
                    Ok(Paste::Unconfirmed {
                        cause: "paste-unanswered".to_owned(),
                    })
                }
                Some("pasted") => Ok(self.hosted_confirmation(
                    target,
                    turns_before,
                    line_digest(line),
                    self.settings.engine.verify.get()?,
                )),
                Some(_) | None => Err(protocol_error("not a paste", &result)),
            },
        }
    }

    fn hosted_cursor(&self, target: &Target) -> u64 {
        let Some(lane) = target.rows_lane() else {
            return 0;
        };
        let scripts = super::overseer::scripts_dir(&self.settings.roots.project);
        match hosted::session_rows(&scripts, lane) {
            hosted::Answer::Live(text) => agent_runtime::rows::complete_line_count(&text),
            hosted::Answer::Gone => 0,
            hosted::Answer::Unreadable { .. } => ROWS_CURSOR_UNREAD,
        }
    }

    #[allow(
        clippy::disallowed_methods,
        reason = "the wake has no intent handle; its bounded provider receipt poll waits on its own injected clock"
    )]
    fn hosted_confirmation(
        &self,
        target: &Target,
        cursor: u64,
        digest: u32,
        bound: Duration,
    ) -> Paste {
        let unconfirmed = |cause: &str| Paste::Unconfirmed {
            cause: cause.to_owned(),
        };
        let Some(lane) = target.rows_lane() else {
            return unconfirmed("session-hosted");
        };
        if cursor == ROWS_CURSOR_UNREAD {
            return unconfirmed("rows-host-unread");
        }
        let scripts = super::overseer::scripts_dir(&self.settings.roots.project);
        let deadline = self.clock.now() + bound;
        loop {
            let text = match hosted::session_rows(&scripts, lane) {
                hosted::Answer::Live(text) => text,
                hosted::Answer::Gone => return unconfirmed("rows-host-unread"),
                hosted::Answer::Unreadable { .. } => return unconfirmed("rows-host-unread"),
            };
            let mut unmatched = false;
            for reading in agent_runtime::rows::rows_after_in(&text, cursor) {
                let row = match reading {
                    Reading::Live(row) => row,
                    Reading::Gone => continue,
                    Reading::Unreadable { .. } => return unconfirmed("rows-host-unread"),
                };
                if row.event.as_deref() != Some("UserPromptSubmit") {
                    continue;
                }
                match row.digest {
                    Some(value) if value == digest => {
                        return Paste::Confirmed {
                            turns_after: row.position as u64,
                        };
                    }
                    Some(_) => unmatched = true,
                    None => return unconfirmed("session-hosted"),
                }
            }
            let pending = if unmatched {
                "turn-unmatched"
            } else {
                "turn-pending"
            };
            let remaining = deadline.saturating_duration_since(self.clock.now());
            if remaining.is_zero() {
                return unconfirmed(pending);
            }
            self.clock.sleep(HOST_ROWS_POLL.min(remaining));
            if self.clock.now() >= deadline {
                return unconfirmed(pending);
            }
        }
    }

    fn target_args(&self, target: &Target, room: bool) -> Result<Vec<String>> {
        let mut args = vec![
            "deliver".to_owned(),
            "--harness".to_owned(),
            target.harness.name().to_owned(),
            "--socket".to_owned(),
            target.socket.display().to_string(),
            "--server-pid".to_owned(),
            target.server.to_string(),
            "--pane".to_owned(),
            target.pane.clone(),
            "--cwd".to_owned(),
            target.cwd.display().to_string(),
        ];
        if let Some(start) = target.server_start {
            args.extend(["--server-start".to_owned(), start.to_string()]);
        }
        match target.route {
            Route::Transport { .. } => args.push("--transport".to_owned()),
            Route::Pane | Route::Send { .. } => {}
        }
        if let Some(program) = self
            .settings
            .engine
            .harness_binaries
            .get()?
            .get(&target.harness)
        {
            args.extend(["--program".to_owned(), program.display().to_string()]);
        }
        if let Some((pid, start)) = &target.identity {
            args.extend([
                "--pid".to_owned(),
                pid.to_string(),
                "--start".to_owned(),
                start.clone(),
            ]);
        }
        if let Some(home) = &target.home {
            args.extend(["--home".to_owned(), home.display().to_string()]);
        }
        if let Some(id) = &target.session_id {
            args.extend(["--session-id".to_owned(), id.clone()]);
        }
        if room {
            args.push("--account-room".to_owned());
        }
        Ok(args)
    }

    /// One run of agent-runtime's `deliver` counted under `tag`, its reply
    /// read whole, or its wrapper's 69 for an unbuilt key with the setup's
    /// refusal where it built first. No reply is the program failing, not a
    /// reading of the pane.
    #[allow(
        clippy::disallowed_methods,
        reason = "the wake and the key verb act only through agent-runtime's own `deliver` verb, run by the one runner under their own tag"
    )]
    fn deliver(&self, tag: &'static str, args: &[String]) -> Result<Delivery> {
        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        let output = host::run_tagged(
            tag,
            "agent-runtime",
            &self.settings.agent_runtime,
            "deliver",
            &args,
            self.settings.engine.verify.get()? + ANSWER_MARGIN,
        )?;
        let code = output.status.code();
        if crate::ready::setup_required(code) {
            return Ok(Delivery::Unbuilt(crate::ready::build_refusal(&output)));
        }
        let reply: Value = serde_json::from_slice(&output.stdout).map_err(|_| {
            Error::Runtime(agent_runtime::Error::External {
                program: "agent-runtime",
                operation: "deliver",
                cause: format!("no reply (exit {code:?}): {}", host::stderr_text(&output)),
            })
        })?;
        Ok(Delivery::Reply(reply))
    }

    /// The wake's run of `deliver`: a result, or the refusal's key; the
    /// mark is recorded before it types.
    fn call(&self, args: &[String]) -> Result<Answer> {
        // agent-runtime unbuilt under a running watch: the pass fails with
        // the cause the watch's admission gives the same state, which names
        // orch's setup.
        let reply = match self.deliver("wake", args)? {
            Delivery::Reply(reply) => reply,
            Delivery::Unbuilt(build) => {
                return Err(crate::ready::unbuilt(
                    crate::ready::Duty::Watch,
                    "agent-runtime",
                    &self.settings,
                    build,
                )
                .refusal());
            }
        };
        if reply.get("ok").and_then(Value::as_bool) == Some(true) {
            return Ok(Answer::Result(
                reply.get("result").cloned().unwrap_or(Value::Null),
            ));
        }
        let key = reply
            .get("refusal")
            .and_then(|r| r.get("key"))
            .and_then(Value::as_str)
            .ok_or_else(|| protocol_error("neither a result nor a refusal", &reply))?;
        if PANE_REFUSALS.contains(&key) {
            return Ok(Answer::Refused);
        }
        Err(protocol_error("refused", &reply))
    }
}

fn wake_unread<'a>(
    unread: &'a [(String, String)],
    target: &str,
    standing: Option<&'a WakeMark>,
) -> &'a str {
    unread
        .iter()
        .find(|(name, _)| name == target)
        .map(|(_, state)| state.as_str())
        .or_else(|| standing.map(|mark| mark.unread.as_str()))
        .unwrap_or_default()
}

/// What a run of `deliver` gave: its reply, or the wrapper's unbuilt
/// answer with the setup's refusal where it built first.
enum Delivery {
    Reply(Value),
    Unbuilt(Option<String>),
}

/// A reply of `deliver`: its result, or a refusal that read the pane.
enum Answer {
    Result(Value),
    Refused,
}

fn protocol_error(what: &str, reply: &Value) -> Error {
    Error::Runtime(agent_runtime::Error::External {
        program: "agent-runtime",
        operation: "deliver",
        cause: format!("{what}: {reply}"),
    })
}

fn word(result: &Value, key: &str) -> Result<String> {
    result
        .get(key)
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| protocol_error(&format!("no `{key}`"), result))
}

fn record_error(path: &Path, op: &'static str, cause: String) -> Error {
    WatchError::Record {
        path: path.to_path_buf(),
        op,
        cause,
    }
    .into()
}

/// The wake record as it stands: empty where none was written yet. An
/// unreadable or malformed record is the pass failing, never an empty
/// record, since an empty record would type for a state already marked.
pub(crate) fn load_record(path: &Path) -> Result<WakeRecord> {
    match std::fs::read(path) {
        Ok(bytes) => {
            serde_json::from_slice(&bytes).map_err(|e| record_error(path, "parsed", e.to_string()))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(WakeRecord::default()),
        Err(e) => Err(record_error(path, "read", e.to_string())),
    }
}

/// Write the wake record whole: a temporary file beside it, synced, then
/// renamed into place, so the mark is on disk before anything is typed and
/// a reader never sees half of one.
#[allow(
    clippy::disallowed_methods,
    reason = "the wake record's one writer: the watch's own record beside the fleet state, replaced atomically before anything is typed"
)]
fn store_record(path: &Path, record: &WakeRecord) -> Result<()> {
    let tmp = path.with_extension("json.tmp");
    let bytes = serde_json::to_vec_pretty(record)
        .map_err(|e| record_error(path, "serialized", e.to_string()))?;
    let write = || -> std::io::Result<()> {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(&tmp)?;
        file.write_all(&bytes)?;
        file.sync_data()?;
        std::fs::rename(&tmp, path)
    };
    write().map_err(|e| record_error(path, "written", e.to_string()))
}

/// The fleet record as it stands; none where no record stands yet.
#[allow(
    clippy::disallowed_methods,
    reason = "the wake duty's one read of the fleet record each pass, for the recorded pane, identity and session of each target with unread mail; it writes no fleet record"
)]
fn load_fleet(path: &Path) -> Result<Option<FleetState>> {
    let Some(snapshot) = state::load(path)? else {
        return Ok(None);
    };
    Ok(Some(FleetState::view(path, &snapshot.doc)?))
}
