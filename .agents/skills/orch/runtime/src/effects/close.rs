//! The close verb, `close-lane`: one lane ended by what its record, its host
//! and its tracker say. The verb reads before it acts: the record, the
//! identity the request fills, the tracker's verdict, the lane's state as the
//! observation duty judges it, the host's capability line, and for a park the
//! provider, the pull request and the lane's clean head. It then stops a
//! hosted harness through its provider, completes a merged item's
//! branch-provable boxes its lane left open ([`boxes`]), and makes the one
//! close transition (`close-owned-resources`), whose effect stops the
//! recorded identity, ends
//! the wake and the validation runs, archives and removes a finished item's
//! files, closes the provider's sandbox, closes the window and moves the
//! record, writing the merge cycle the delivery names. A park then stops the
//! sandbox with its disk kept and records the park. Every read that does not
//! answer refuses with its cause; nothing past a refusal runs.

use agent_runtime::record::Locking;
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::{Value, json};

use crate::error::{Error, Result};
use crate::ops::{
    self, CloseIdentity, CloseLane, CloseMode, CloseOwnedResources, Ended, NoLanding, OwedPark,
    ParkLane, ParkWait, Report, Request, Terminal, boxes,
};
use crate::settings::Settings;
use crate::state::{self, FleetState, Lane, LaneStatus};
use crate::verify::Answer;
use crate::verify::wire::{Nullable, ParkPull, ParkPullAnswer};
use crate::watch::hosted::{
    self, Answer as HostAnswer, Asked, Capabilities, HostStopped, PaneKind, Status, StopKind,
};
use crate::watch::lanes::{self, LaneState, reset};
use crate::watch::tracker::{self, TerminalState};
use agent_runtime::clock::Clock;
use agent_runtime::harness::Harness;
use agent_runtime::journal::Env;
use agent_runtime::observe::WallKind;

use super::{Effected, lane_operation};

/// How the close ended, by the record it left.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Word {
    /// The record reads done.
    Closed,
    /// The harness ended and the sandbox was kept: the record reads stopped.
    Stopped,
    /// The sandbox stopped with its disk kept: the record reads parked.
    Parked,
    /// The tracker's verdict alone was asked (`terminal-state`).
    State,
    /// The close's effect left something standing: the intent stays open
    /// with what it observed, for the repeat or the operator.
    Unconfirmed,
    /// The close's effect failed with nothing moved.
    Failed,
}

/// The close's answer: the word, the record's status, the tracker's verdict
/// for `terminal-state`, the notes a step left (`stop-skipped`,
/// `item-files-kept cause=`, `host-absent mail-status=`, `host-kept kind=
/// session=`, `merged-unjudged`, the box completion's `boxes-ticked`,
/// `boxes-unread cause=direct-delivery`, and under a disposal
/// `cycle-unrecorded cause=`, the open boxes' note and `boxes-comment=`,
/// and `base-follow refused cause=` where the base checkout could not
/// follow a recorded landing), and the close transition's effect as
/// recorded.
#[derive(Debug, Serialize)]
pub struct Closed {
    pub item: String,
    pub word: Word,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<LaneStatus>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub state: Option<&'static str>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub notes: Vec<String>,
    /// The observation the close's effect recorded: the provider's archive
    /// line under `host_close`, or `standing` with the state its `list`
    /// still names (`listed`) or `unconfirmed` with the list's cause, its
    /// refusal's `path`, a cause.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub observation: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub effect: Option<Effected>,
}

fn refused(key: &'static str, fields: &[(&str, &str)]) -> Error {
    agent_runtime::Error::refused(key, fields).into()
}

/// The identity the close works with: the record's, else the request's,
/// else the item key's tracker (`issue-N` names none).
struct Identity {
    harness: Option<String>,
    tracker: String,
    repo: Option<String>,
    derived: bool,
}

impl Identity {
    fn of(lane: &Lane, given: &CloseIdentity) -> Result<Identity> {
        ops::identity_fills(lane, given)?;
        let pick = |recorded: &Option<String>, supplied: &Option<String>| {
            recorded
                .clone()
                .filter(|v| !v.is_empty())
                .or_else(|| supplied.clone().filter(|v| !v.is_empty()))
        };
        let tracker = pick(&lane.tracker, &given.tracker);
        let derived = tracker.is_none();
        Ok(Identity {
            harness: pick(&lane.harness, &given.harness),
            tracker: tracker.unwrap_or_else(|| {
                if lane.item.starts_with("issue-") {
                    String::new()
                } else {
                    "linear".to_owned()
                }
            }),
            repo: pick(&lane.repo, &given.repo),
            derived,
        })
    }

    fn source(&self) -> &'static str {
        if self.derived { "derived" } else { "given" }
    }
}

/// The verdict the tracker answered, or its refusal naming the read.
fn verdict(settings: &Settings, lane: &Lane, who: &Identity, waits: bool) -> Result<TerminalState> {
    tracker::lane_verdict(settings, lane, &who.tracker, who.repo.as_deref(), waits).map_err(
        |cause| {
            refused(
                "tracker-read-failed",
                &[
                    ("item", &lane.item),
                    ("tracker", &who.tracker),
                    ("source", who.source()),
                    ("cause", &cause),
                ],
            )
        },
    )
}

/// The close ground a tracker verdict gives, the cause word an unread or
/// open one leaves for the item's files.
fn terminal(state: TerminalState) -> Option<Terminal> {
    state.verdict().map(|verdict| Terminal {
        verdict,
        source: "close-lane".to_owned(),
    })
}

/// The item's one lane record, with the tmux socket the controller record
/// names.
#[allow(
    clippy::disallowed_methods,
    reason = "the close verb's one read of the fleet record before it acts, a snapshot it judges; the close transition re-reads under the lock"
)]
fn read_lane(path: &Path, item: &str) -> Result<(Lane, Option<PathBuf>)> {
    let fleet = state::load(path)?
        .map(|snapshot| snapshot.view::<FleetState>(path))
        .transpose()?
        .ok_or_else(|| refused("lane-missing", &[("item", item)]))?;
    let records: Vec<&Lane> = fleet.lanes.iter().filter(|l| l.item == item).collect();
    match records.as_slice() {
        [] => Err(refused("lane-missing", &[("item", item)])),
        [lane] => Ok((
            (*lane).clone(),
            fleet
                .overseer
                .as_ref()
                .and_then(agent_runtime::effects::overseer_socket),
        )),
        many => Err(refused(
            "lane-duplicate",
            &[("item", item), ("count", &many.len().to_string())],
        )),
    }
}

/// End the lane `r` names. The answer is how far the close got; a refusal
/// changed nothing past the reads it names.
pub fn close_lane(
    path: &Path,
    r: &CloseLane,
    settings: &Settings,
    env: &Env,
    locking: Locking,
    clock: &dyn Clock,
) -> Result<Closed> {
    let (lane, socket) = read_lane(path, &r.item)?;
    let who = Identity::of(&lane, &r.identity)?;
    let answer = |word: Word, status: Option<LaneStatus>| Closed {
        item: r.item.clone(),
        word,
        status,
        state: None,
        notes: Vec::new(),
        observation: None,
        effect: None,
    };
    if lane.status == LaneStatus::Done && r.mode != CloseMode::TerminalState {
        return Ok(answer(Word::Closed, Some(LaneStatus::Done)));
    }
    if lane.mail_root.as_deref().is_none_or(str::is_empty) {
        return Err(refused(
            "record-invalid",
            &[("item", &r.item), ("field", "mail_root")],
        ));
    }
    match &r.mode {
        CloseMode::TerminalState => {
            let state = verdict(settings, &lane, &who, true)?;
            let mut closed = answer(Word::State, Some(lane.status));
            closed.state = Some(state.word());
            return Ok(closed);
        }
        CloseMode::IfTerminal => {
            if verdict(settings, &lane, &who, true)? == TerminalState::Open {
                return Err(refused("item-open", &[("item", &r.item)]));
            }
        }
        CloseMode::Close | CloseMode::KeepSandbox | CloseMode::Park(_) => {}
    }
    if let CloseMode::Park(wait) = &r.mode
        && wait.pr.is_none()
        && wait.until_pr.is_none()
        && wait.ask.is_none()
    {
        return Err(refused(
            "request-invalid",
            &[("item", &r.item), ("field", "park"), ("requires", "pr|ask")],
        ));
    }
    let scripts = crate::watch::overseer::scripts_dir(&settings.roots.project);
    let host = hosted::host_of(&lane).to_owned();
    let caps = if host == "local" {
        Capabilities::local()
    } else {
        hosted::capabilities(&scripts, &host).map_err(|cause| {
            refused(
                "host-capabilities-unread",
                &[("item", &r.item), ("host", &host), ("cause", &cause)],
            )
        })?
    };
    let close = Close {
        path,
        r,
        settings,
        env,
        locking,
        clock,
        scripts: &scripts,
        host: &host,
        caps,
        who,
        lane,
        socket,
    };
    match caps.stop {
        Some(StopKind::None) => close.cloud(),
        Some(StopKind::Window | StopKind::Verb) => match close.lane.status {
            LaneStatus::Stopped => close.stopped(),
            LaneStatus::Parked => close.parked(),
            LaneStatus::Preparing if close.prepare_step() != Some("selection") => close.preparing(),
            LaneStatus::Preparing | LaneStatus::Running => close.running(),
            LaneStatus::Done => unreachable!("a done record answered above"),
        },
        None => Err(refused(
            "host-capabilities-unread",
            &[("item", &r.item), ("host", &host), ("stop", "missing")],
        )),
    }
}

/// One close in progress.
struct Close<'a> {
    path: &'a Path,
    r: &'a CloseLane,
    settings: &'a Settings,
    env: &'a Env,
    locking: Locking,
    clock: &'a dyn Clock,
    scripts: &'a Path,
    host: &'a str,
    /// The host kind's capability line, read before the close.
    caps: Capabilities,
    who: Identity,
    lane: Lane,
    /// The controller record's tmux socket, where the lane's server is
    /// looked for first.
    socket: Option<PathBuf>,
}

/// What the wall's account reading said: the `account=` word of a
/// `lane-live state=walled` refusal (`room`, `walled`, `unlisted`,
/// `unmeasured`, `read-failed`, or `none` with no account or a harness the
/// judge reads none for), and the reset still ahead or `unresolved`.
struct WallRead {
    account: &'static str,
    resets: Option<String>,
}

impl WallRead {
    fn lifts(&self) -> bool {
        self.account == "room" && self.resets.is_none()
    }
}

/// The account `lane` spends and its harness, where the wall's account
/// reading measures it: a record naming its account, on a harness the
/// accounts judge reads usage for.
pub(crate) fn room_measured(lane: &Lane, harness: Option<Harness>) -> Option<(&str, Harness)> {
    let account = lane.account.as_deref().filter(|a| !a.is_empty())?;
    match harness? {
        harness @ (Harness::Claude | Harness::Codex) => Some((account, harness)),
        Harness::Copilot | Harness::Pi => None,
    }
}

/// A walled lane's account read (`lanes pick --lane` in process), the one
/// reading a wall's lift and the watch's resume weigh: for the model the
/// record names, the whole account where it names none, the widest reading,
/// so it lifts no wall the model's own would keep; under the record's host
/// `host`, `local` for a local lane, never the caller's setting. The word is
/// `room`, `walled`, `unlisted`, `unmeasured`, `read-failed`, or `none` for a
/// lane [`room_measured`] does not measure.
pub(crate) fn account_room(
    settings: &Settings,
    fleet: &Path,
    host: &str,
    lane: &Lane,
    harness: Option<Harness>,
    now: u64,
) -> &'static str {
    let Some((account, harness)) = room_measured(lane, harness) else {
        return "none";
    };
    let request = agent_runtime::accounts::PickRequest {
        harness,
        model: lane.model.clone().filter(|m| !m.is_empty()),
        exclude: Vec::new(),
        for_overseer: false,
        lane: Some(account.to_owned()),
        projected: false,
        max_pct: None,
        min_headroom_pct: None,
        binding_floor: false,
        admit_unread_scope: false,
        opens_here: false,
    };
    match super::lane_operation::pick_account(settings, fleet, host, &request, now).exit() {
        0 => "room",
        3 => "walled",
        4 => "unlisted",
        5 => "unmeasured",
        _ => "read-failed",
    }
}

/// How often the exit wait reads the lane again.
const EXIT_POLL: std::time::Duration = std::time::Duration::from_millis(200);

/// The ground the close transition persists; a keep carries the judged park
/// its sandbox stop follows.
enum Ground {
    Terminal(Terminal),
    Exited,
    Ended(&'static str),
    Keep(Option<OwedPark>),
}

/// What the close records of the lane's landing: the merge cycle, the
/// disposal of what it could not record, the notes, and the one comment a
/// disposal of open boxes posts once the record reads done.
#[derive(Default)]
struct Landing {
    cycle: Option<state::CycleRow>,
    disposed: Option<state::LandingDisposal>,
    notes: Vec<String>,
    comment: Option<String>,
}

/// A hosted lane's worktree as its sandbox's disk reads it.
struct LaneHead {
    head: String,
    branch: String,
    remote: Option<String>,
}

/// Why the close completes a merged item's boxes on `ground`, and whether
/// its tracker read the item Done, or `None` where it completes none: its
/// worktree or sandbox gone (`gone`, or the merged ground, which the close
/// takes only on a gone worktree), or its item Done with the lane ended.
fn boxes_cause(ground: &Ground, gone: bool) -> Option<(boxes::Cause, bool)> {
    match ground {
        Ground::Ended("merged") => Some((boxes::Cause::SandboxGone, false)),
        Ground::Terminal(Terminal {
            verdict: state::TerminalVerdict::Completed,
            ..
        }) if gone => Some((boxes::Cause::SandboxGone, true)),
        Ground::Terminal(Terminal {
            verdict: state::TerminalVerdict::Completed,
            ..
        }) => Some((boxes::Cause::LaneEnded, true)),
        Ground::Terminal(_) | Ground::Exited | Ground::Ended(_) | Ground::Keep(_) => None,
    }
}

impl Close<'_> {
    fn item(&self) -> &str {
        &self.r.item
    }

    fn hosted(&self) -> bool {
        self.host != "local" && self.lane.kind.as_deref() != Some(crate::ops::CLOUD_KIND)
    }

    fn prepare_step(&self) -> Option<&str> {
        self.lane
            .extra
            .get("prepare")
            .and_then(|p| p.get("step"))
            .and_then(Value::as_str)
    }

    fn keep(&self) -> bool {
        matches!(self.r.mode, CloseMode::KeepSandbox | CloseMode::Park(_))
    }

    fn park(&self) -> Option<&ParkWait> {
        match &self.r.mode {
            CloseMode::Park(wait) => Some(wait),
            CloseMode::Close
            | CloseMode::KeepSandbox
            | CloseMode::TerminalState
            | CloseMode::IfTerminal => None,
        }
    }

    /// The ground on a terminal verdict, else the one `open` gives, with
    /// the cause the item's files stay for.
    fn by_verdict(&self, open: Ground, notes: &mut Vec<String>) -> Result<Ground> {
        match verdict(self.settings, &self.lane, &self.who, false) {
            Ok(state) => match terminal(state) {
                Some(t) => Ok(Ground::Terminal(t)),
                None => {
                    notes.push("item-files-kept cause=open".to_owned());
                    Ok(open)
                }
            },
            Err(e) => {
                notes.push(format!("item-files-kept cause={}", cause_word(&e)));
                Ok(open)
            }
        }
    }

    /// A Claude cloud session, which nothing here stops: the item's files
    /// where its tracker ended it, the window its launch opened, its local
    /// worktree and the record; the session stays the operator's.
    fn cloud(self) -> Result<Closed> {
        if self.park().is_some() {
            self.park_check()?;
        }
        let mut notes = Vec::new();
        let ground = self.by_verdict(Ground::Ended("stop-none"), &mut notes)?;
        let session = self.lane.session_id.clone().unwrap_or_default();
        let mut closed = self.close_on(ground)?;
        if closed.word == Word::Closed {
            notes.push(format!(
                "host-kept kind={} session={session}",
                crate::ops::CLOUD_KIND
            ));
        }
        closed.notes.splice(0..0, notes);
        Ok(closed)
    }

    /// A record an earlier keep or a failed park left stopped: no pane, no
    /// harness; the mailbox is read only for an item its tracker holds open.
    /// A park the record already owes reads its sandbox for nothing: its
    /// mailbox was read when the mark was written, and no session has run
    /// since to add an ask.
    fn stopped(self) -> Result<Closed> {
        if let Some(wait) = self.park() {
            let owed = self.owed(wait);
            if owed.is_none() {
                self.refuse_ask()?;
            }
            let judged = self.park_judge(wait, owed.clone())?;
            if owed.is_none() {
                self.owe_park(&judged)?;
            }
            return self.park_sandbox(&judged, Vec::new());
        }
        let mut notes = Vec::new();
        let ground = if self.keep() {
            Ground::Keep(None)
        } else {
            self.by_verdict(Ground::Exited, &mut notes)?
        };
        if !matches!(ground, Ground::Terminal(_)) {
            self.refuse_ask()?;
        }
        if self.keep() {
            return Ok(self.word(Word::Stopped, Some(LaneStatus::Stopped)));
        }
        let mut closed = self.close_on(ground)?;
        closed.notes.splice(0..0, notes);
        Ok(closed)
    }

    /// A parked record: its sandbox is stopped and no session ran since the
    /// park read its mailbox, so a full close is the provider's close alone;
    /// a park or a keep changes nothing.
    fn parked(self) -> Result<Closed> {
        if self.keep() {
            let mut closed = self.word(Word::Parked, Some(LaneStatus::Parked));
            if let Some(parked) = self.lane.extra.get("parked") {
                closed.observation = Some(json!({"parked": parked}));
            }
            return Ok(closed);
        }
        let mut notes = Vec::new();
        let ground = self.by_verdict(Ground::Exited, &mut notes)?;
        let mut closed = self.close_on(ground)?;
        closed.notes.splice(0..0, notes);
        Ok(closed)
    }

    /// Preparation before harness start: a park has nothing to judge; the
    /// close supersedes the launch intent and ends the record.
    fn preparing(self) -> Result<Closed> {
        if self.park().is_some() {
            return Err(refused(
                "record-invalid",
                &[
                    ("item", self.item()),
                    ("field", "status"),
                    ("value", "preparing"),
                ],
            ));
        }
        let mut notes = Vec::new();
        let ground = if self.keep() {
            Ground::Keep(None)
        } else {
            self.by_verdict(Ground::Exited, &mut notes)?
        };
        let mut closed = self.close_on(ground)?;
        closed.notes.splice(0..0, notes);
        Ok(closed)
    }

    /// A running lane: judged by its state, its harness stopped through its
    /// provider where it is hosted, then closed, kept or parked.
    fn running(self) -> Result<Closed> {
        let socket = self.socket.as_deref();
        let mut judged = lanes::judge(self.settings, &self.lane, socket, None);
        // A limit banner stays on a parked lane's screen after its window
        // resets, since the lane takes no turn to scroll it away: a usage
        // wall is weighed against the record's account and lifts only where
        // that reading has room and the banner names no reset ahead.
        let mut wall = None;
        if let LaneState::Walled {
            kind: WallKind::Usage,
            banner,
            ..
        } = &judged
        {
            let read = self.wall(banner);
            if read.lifts() {
                judged = lanes::judge(self.settings, &self.lane, socket, Some(true));
            }
            wall = Some(read);
        }
        let mut notes = Vec::new();
        if let Some(wait) = self.park() {
            let park = self.park_judge(wait, None)?;
            if !matches!(judged, LaneState::Exited) {
                self.refuse_ask()?;
                self.host_stop(&mut notes)?;
            }
            let closed = self.close_on(Ground::Keep(Some(park.owed_mark())))?;
            if closed.word != Word::Stopped {
                return Ok(closed);
            }
            return self.park_sandbox(&park, notes);
        }
        let ground = match &judged {
            LaneState::Exited => self.by_verdict(Ground::Exited, &mut notes)?,
            LaneState::Gone => self.windowless(&mut notes)?,
            LaneState::Unjudged { cause } if cause == "pane-unrecorded" => {
                self.windowless(&mut notes)?
            }
            LaneState::Idle { .. } | LaneState::RateLimitSwitch => {
                match self.finished(&mut notes)? {
                    Some(ground) => ground,
                    None => return Err(self.live("idle")),
                }
            }
            // A lane whose landing is recorded and whose work left nothing on
            // its host is over whatever its screen reads: the two records are
            // the proof, the screen none. An unanswered ask still refuses
            // below: it is owed mail, a record.
            LaneState::Unjudged { .. }
            | LaneState::Walled { .. }
            | LaneState::Working
            | LaneState::Asking
            | LaneState::Unreadable { .. }
                if self.merged_and_done()? =>
            {
                self.by_verdict(Ground::Ended("merged"), &mut notes)?
            }
            LaneState::Unjudged { .. } => return Err(self.live("unjudged")),
            LaneState::Walled { .. } => return Err(self.walled(wall.as_ref())),
            LaneState::Working => return Err(self.live("working")),
            LaneState::Asking => return Err(self.live("asking")),
            LaneState::Unreadable { cause } => {
                return Err(refused(
                    "pane-read-failed",
                    &[("item", self.item()), ("cause", cause)],
                ));
            }
        };
        let ground = if self.keep() {
            Ground::Keep(None)
        } else {
            ground
        };
        let acts = !matches!(judged, LaneState::Exited) && self.hosted();
        let mut host_absent = false;
        if acts {
            match self.refuse_ask() {
                Ok(()) => {}
                Err(e) if matches!(ground, Ground::Terminal(_)) && self.host_absent(&e)? => {
                    notes.push(format!("host-absent mail-status={}", cause_word(&e)));
                    host_absent = true;
                }
                Err(e) => return Err(e),
            }
        }
        let landing = self.landing(&ground, boxes_cause(&ground, host_absent))?;
        let ground = if host_absent {
            Ground::Ended(state::HOST_ABSENT)
        } else {
            if acts {
                self.host_stop(&mut notes)?;
            }
            ground
        };
        let mut closed = self.persist(ground, landing)?;
        closed.notes.splice(0..0, notes);
        Ok(closed)
    }

    /// The close on `ground` with the landing its delivery names recorded.
    fn close_on(&self, ground: Ground) -> Result<Closed> {
        let landing = self.landing(&ground, None)?;
        self.persist(ground, landing)
    }

    /// The landing the close records, read before it acts: the merge cycle
    /// the request's delivery names, and on a ground that completes a
    /// merged item's boxes (`boxes`), their completion. Both are read here
    /// because the close is the last reader of their inputs: the record's
    /// confirm deletes the pull request it parked and the item's files leave
    /// with it, and a done record answers a later close at once. So a cycle
    /// the recorder refuses, or boxes left open, refuse the close with
    /// nothing moved, unless the request's disposal gives that part up.
    fn landing(&self, ground: &Ground, boxes: Option<(boxes::Cause, bool)>) -> Result<Landing> {
        let disposal = self.r.landing.as_ref().map(|l| &l.disposed);
        let mut landing = Landing::default();
        let (mut record, mut open) = (false, false);
        if let Some(delivery) = &self.r.delivery
            && !matches!(ground, Ground::Keep(_))
        {
            match crate::ops::cycle::recorded(
                self.settings,
                Path::new("gh"),
                self.path,
                &self.lane,
                delivery,
                self.env.now_secs,
            ) {
                Ok(row) => {
                    landing.notes.extend(row.notes.iter().cloned());
                    landing.cycle = Some(row);
                }
                Err(cause) if disposal.is_some_and(|d| d.of.record()) => {
                    landing
                        .notes
                        .push(format!("cycle-unrecorded cause={cause}"));
                    record = true;
                }
                Err(cause) => {
                    return Err(refused(
                        "cycle-unrecorded",
                        &[("item", self.item()), ("cause", &cause)],
                    ));
                }
            }
        }
        if let Some((cause, done)) = boxes
            && let Some(completion) = self.boxes(cause, done, &mut landing.notes)
        {
            match completion {
                boxes::Completion::Settled(note) => landing.notes.extend(note),
                boxes::Completion::Unsettled { note, comment }
                    if disposal.is_some_and(|d| d.of.boxes()) =>
                {
                    landing.notes.push(note);
                    landing.comment = comment;
                    open = true;
                }
                boxes::Completion::Unsettled { note, .. } => {
                    let mut words = note.split_whitespace();
                    let state = words.next().unwrap_or("").trim_start_matches("boxes-");
                    let cause = words
                        .find_map(|w| w.strip_prefix("cause="))
                        .unwrap_or("unread");
                    return Err(refused(
                        "boxes-unsettled",
                        &[("item", self.item()), ("state", state), ("cause", cause)],
                    ));
                }
            }
        }
        landing.disposed = disposal
            .filter(|_| record || open)
            .map(|d| state::LandingDisposal {
                of: match (record, open) {
                    (true, true) => state::Disposed::Both,
                    (true, false) => state::Disposed::Record,
                    (false, _) => state::Disposed::Boxes,
                },
                ..d.clone()
            });
        Ok(landing)
    }

    /// A merged item's branch-provable boxes completed from its merged pull
    /// request's evidence where the close ends a lane that did not complete
    /// them; `None` where the close completes none: an item no Linear
    /// tracker holds (the completion is the linear package's), or a
    /// delivery no pull request names. A direct delivery has no evidence
    /// section to read, which its note says.
    fn boxes(
        &self,
        cause: boxes::Cause,
        done: bool,
        notes: &mut Vec<String>,
    ) -> Option<boxes::Completion> {
        if self.who.tracker != "linear" {
            return None;
        }
        let (pr, repo) = match &self.r.delivery {
            Some(ops::Delivery::Pr { pr, repo }) => (*pr, repo.clone()),
            Some(ops::Delivery::Commit { .. }) => {
                notes.push("boxes-unread cause=direct-delivery".to_owned());
                return None;
            }
            None => (
                self.lane
                    .extra
                    .get("cycle")
                    .and_then(|c| c.get("pr"))
                    .and_then(Value::as_u64)?,
                None,
            ),
        };
        let Some(repo) = repo.or_else(|| self.who.repo.clone()) else {
            return Some(boxes::Completion::Unsettled {
                note: "boxes-unticked cause=repo-missing".to_owned(),
                comment: None,
            });
        };
        let merged = boxes::Merged { repo: &repo, pr };
        Some(boxes::complete(
            self.settings,
            Path::new("gh"),
            self.item(),
            &merged,
            cause,
            done,
        ))
    }

    /// The ground a lane whose work may be over closes on: its item ended
    /// by its tracker, else its merge landed with its work over
    /// ([`Self::merged_and_done`]); `None` is a lane still at work on an
    /// open item. A tracker that does not answer refuses, unless the landing
    /// and the work's end prove the lane over, as they do whatever its
    /// screen reads: the item's files then stay with the tracker's cause.
    fn finished(&self, notes: &mut Vec<String>) -> Result<Option<Ground>> {
        let open = match verdict(self.settings, &self.lane, &self.who, false) {
            Ok(state) => match terminal(state) {
                Some(t) => return Ok(Some(Ground::Terminal(t))),
                None => Ok(()),
            },
            Err(e) => Err(e),
        };
        match self.merged_and_done() {
            Ok(true) => {
                let cause = open
                    .as_ref()
                    .map_or_else(cause_word, |()| "open".to_owned());
                notes.push(format!("item-files-kept cause={cause}"));
                Ok(Some(Ground::Ended("merged")))
            }
            Ok(false) => open.map(|()| None),
            Err(e) => Err(open.err().unwrap_or(e)),
        }
    }

    /// A record no pane carries, its recorded pane gone or none recorded:
    /// its harness is ended by the provider or its launch identity alone,
    /// on its item's end or its landed merge; otherwise `pane-missing`.
    fn windowless(&self, notes: &mut Vec<String>) -> Result<Ground> {
        self.finished(notes)?.ok_or_else(|| {
            refused(
                "pane-missing",
                &[("item", self.item()), ("window", &self.window())],
            )
        })
    }

    fn window(&self) -> String {
        self.lane
            .window
            .clone()
            .unwrap_or_else(|| self.item().to_owned())
    }

    fn walled(&self, wall: Option<&WallRead>) -> Error {
        let window = self.window();
        let mut fields = vec![
            ("item", self.item()),
            ("state", "walled"),
            ("window", window.as_str()),
            ("account", wall.map_or("none", |w| w.account)),
        ];
        if let Some(resets) = wall.and_then(|w| w.resets.as_deref()) {
            fields.push(("resets", resets));
        }
        refused("lane-live", &fields)
    }

    /// The record's account read for the wall ([`account_room`]); then, on
    /// room, the reset the banner names: a dated reset still ahead keeps the
    /// wall with it, a clause that keys to no time (a zone with no zoneinfo
    /// here, a date that names no day) keeps it `unresolved`, and a clock or
    /// weekday reset names no day, which the account's reading answers
    /// alone.
    fn wall(&self, banner: &str) -> WallRead {
        let account = account_room(
            self.settings,
            self.path,
            self.host,
            &self.lane,
            self.who.harness.as_deref().and_then(Harness::parse),
            self.env.now_secs,
        );
        let read = |resets: Option<String>| WallRead { account, resets };
        if account != "room" {
            return read(None);
        }
        let Some(key) = reset::key(banner) else {
            return read(reset::clause(banner).then(|| "unresolved".to_owned()));
        };
        let now = self.env.now_secs;
        let Some(zone) = (lanes::Readers::kernel().zone)(key.zone.as_deref()) else {
            return read(Some("unresolved".to_owned()));
        };
        if !matches!(key.day, reset::Day::Dated { .. }) {
            return read(None);
        }
        match reset::epoch(&key, now, &zone) {
            None => read(Some("unresolved".to_owned())),
            Some(at) if at > now => read(Some(agent_runtime::clock::iso_utc(at))),
            Some(_) => read(None),
        }
    }

    fn live(&self, state: &str) -> Error {
        refused(
            "lane-live",
            &[
                ("item", self.item()),
                ("state", state),
                ("window", &self.window()),
            ],
        )
    }

    /// Whether the record's merge cycle, or the delivery the request names,
    /// stands and the lane's last work is over: its item closed out or its
    /// worktree gone, read here ([`hosted::left_locally`], the watch's own
    /// reading) or on its host through the provider where it is hosted
    /// ([`hosted::record_left`]). The close-out removes the live state
    /// record only once the project's verification passed, and the close
    /// stops the session before it releases the worktree, so a lane need not
    /// remove the directory it runs in. A recorded merge alone is no proof:
    /// a lane resumed on a merged item works on with its record standing. A
    /// read that fails refuses.
    fn merged_and_done(&self) -> Result<bool> {
        if !(super::stop::record_merged(&self.lane) || self.r.delivery.is_some()) {
            return Ok(false);
        }
        let root = self.lane.mail_root.as_deref().unwrap_or("");
        if !self.hosted() {
            return match hosted::left_locally(&self.settings.state_dir, &self.lane) {
                HostAnswer::Gone => Ok(true),
                HostAnswer::Live(()) => Ok(false),
                HostAnswer::Unreadable { cause } => Err(refused(
                    "state-unreadable",
                    &[
                        ("item", self.item()),
                        (
                            "path",
                            &state::item_path(&self.settings.state_dir, self.item())
                                .display()
                                .to_string(),
                        ),
                        ("cause", &cause),
                    ],
                )),
            };
        }
        match hosted::record_left(self.scripts, &self.lane) {
            HostAnswer::Gone => Ok(true),
            HostAnswer::Live(()) => Ok(false),
            HostAnswer::Unreadable { cause } => Err(refused(
                if cause.split_whitespace().nth(1) == Some(hosted::BUSY) {
                    hosted::BUSY
                } else {
                    "worktree-read-failed"
                },
                &[("item", self.item()), ("root", root), ("cause", &cause)],
            )),
        }
    }

    /// An ask the lane holds unanswered refuses the close: the answer would
    /// reach the session the close ends. A mailbox that cannot be read
    /// refuses too. A park on the lane's own ask passes: its judge reads
    /// that ask, and the answer reaches the relaunched session.
    fn refuse_ask(&self) -> Result<()> {
        if self.park().is_some_and(|wait| wait.ask.is_some()) {
            return Ok(());
        }
        match self.open_ask()? {
            None => Ok(()),
            Some(ask) => Err(refused(
                "ask-unanswered",
                &[("item", self.item()), ("ask", &ask)],
            )),
        }
    }

    /// The oldest ask the lane's mailbox holds unanswered; a mailbox that
    /// cannot be read refuses.
    fn open_ask(&self) -> Result<Option<String>> {
        match lane_operation::pending_ask(&self.settings.lane_mail_cli, &self.lane) {
            Ok(ask) => Ok(ask),
            Err(cause) if cause.starts_with(hosted::BUSY) => Err(refused(
                hosted::BUSY,
                &[("item", self.item()), ("step", "mail-read")],
            )),
            Err(cause) => Err(refused(
                "mail-read-failed",
                &[("item", self.item()), ("cause", &cause)],
            )),
        }
    }

    /// Whether a mailbox read that failed on a terminal item's full close is
    /// a sandbox the provider no longer holds: its list names no row for
    /// the item. A list that fails keeps the mailbox's refusal.
    fn host_absent(&self, error: &Error) -> Result<bool> {
        if error.key() != "mail-read-failed" || self.keep() {
            return Ok(false);
        }
        match hosted::lists_item(self.scripts, self.host, self.item()) {
            Ok(listed) => Ok(listed.is_none()),
            Err(cause) if cause.starts_with(hosted::BUSY) => Err(refused(
                hosted::BUSY,
                &[("item", self.item()), ("step", "list")],
            )),
            Err(_) => Ok(false),
        }
    }

    /// The hosted harness ended: a Copilot lane on a provider that captures
    /// its pane first gets `C-c` and `/exit` through the provider's input,
    /// so it writes its session totals, and needs no stop where that ends
    /// it; otherwise the provider's stop, then its pane read exited within
    /// the close bound.
    fn host_stop(&self, notes: &mut Vec<String>) -> Result<()> {
        if self.who.harness.as_deref() == Some("copilot")
            && self.caps.pane == PaneKind::Verb
            && self.copilot_exit()?
        {
            return Ok(());
        }
        match self.provider_stop(notes)? {
            Some(processes) => self.await_exit(Some(processes)),
            None => Ok(()),
        }
    }

    /// Copilot's own exit through the provider's input, where the provider
    /// reads it running: `C-c`, then `/exit` as the input file's text, then
    /// the exit wait. `false` is a lane that did not exit within the bound,
    /// or whose input the provider refused, left to the provider's stop.
    fn copilot_exit(&self) -> Result<bool> {
        match hosted::status(self.scripts, self.host, self.item(), "copilot") {
            Ok(hosted::HostStatus::Running) => {}
            Ok(hosted::HostStatus::Exited) => return Ok(true),
            Err(cause) => {
                return Err(refused(
                    "pane-read-failed",
                    &[("item", self.item()), ("cause", &cause)],
                ));
            }
        }
        if hosted::send_key(self.scripts, self.host, self.item(), "C-c").is_err() {
            return Ok(false);
        }
        if hosted::send_text(
            self.scripts,
            self.host,
            self.item(),
            &self.settings.state_dir,
            "/exit",
        )
        .is_err()
        {
            return Ok(false);
        }
        Ok(self.await_exit(None).is_ok())
    }

    /// The lane's pane read exited within the close bound
    /// (`ORCH_LANE_CLOSE_SECS`), counted from now, after the stop returned:
    /// its provider's status and capture where the kind captures its pane,
    /// the recorded local pane otherwise; a pane gone reads exited. A lane
    /// with neither has nothing to wait on. An unjudged reading waits on,
    /// a hosted Pi pane between turns among them; a read that fails, the
    /// provider's status or its capture, refuses `pane-read-failed`.
    fn await_exit(&self, processes: Option<u32>) -> Result<()> {
        let pane = self.lane.launch.as_ref().and_then(|l| l.pane.clone());
        if pane.is_none() && self.caps.pane != PaneKind::Verb {
            return Ok(());
        }
        let socket = self.socket.as_deref();
        let read = || match lanes::judge(self.settings, &self.lane, socket, None) {
            LaneState::Exited | LaneState::Gone => Some(Ok(())),
            LaneState::Unreadable { cause } => Some(Err(refused(
                "pane-read-failed",
                &[("item", self.item()), ("cause", &cause)],
            ))),
            LaneState::Unjudged { cause }
                if self.caps.status == Status::Verb
                    && cause.starts_with("harness-probe-failed") =>
            {
                Some(Err(refused(
                    "pane-read-failed",
                    &[("item", self.item()), ("cause", &cause)],
                )))
            }
            LaneState::Unjudged { .. }
            | LaneState::Walled { .. }
            | LaneState::Asking
            | LaneState::RateLimitSwitch
            | LaneState::Working
            | LaneState::Idle { .. } => None,
        };
        if let Some(answer) = agent_runtime::effects::poll_until(
            self.clock,
            self.settings.close_grace.get()?,
            EXIT_POLL,
            read,
        ) {
            return answer;
        }
        let harness = self.who.harness.as_deref().unwrap_or("unknown");
        let count = processes.map(|p| p.to_string()).unwrap_or_default();
        let pane = pane.as_deref().unwrap_or("");
        Err(refused(
            "exit-timeout",
            &[
                ("item", self.item()),
                ("harness", harness),
                ("pane", pane),
                ("processes", &count),
            ],
        ))
    }

    /// The provider's stop: the count of processes it signalled, or `None`
    /// where an item whose worktree its close-out removed skips the stop on
    /// a full close, which the provider's close ends; a keep or a park
    /// refuses it.
    fn provider_stop(&self, notes: &mut Vec<String>) -> Result<Option<u32>> {
        let harness = self.who.harness.as_deref().ok_or_else(|| {
            refused(
                "harness-unsupported",
                &[("item", self.item()), ("harness", "unknown")],
            )
        })?;
        match hosted::stop_answer(self.scripts, self.host, self.item(), harness) {
            Ok(HostStopped::Stopped { processes }) => Ok(Some(processes)),
            Ok(HostStopped::WorktreeRemoved) if !self.keep() => {
                notes.push(format!(
                    "stop-skipped item={} harness={harness} cause=worktree-removed",
                    self.item()
                ));
                Ok(None)
            }
            Ok(HostStopped::WorktreeRemoved) => Err(refused(
                "stop-failed",
                &[
                    ("item", self.item()),
                    ("harness", harness),
                    ("cause", "provider"),
                    ("status", "4"),
                ],
            )),
            Err(Asked::Failed(cause)) if cause.starts_with(hosted::BUSY) => Err(refused(
                hosted::BUSY,
                &[
                    ("item", self.item()),
                    ("harness", harness),
                    ("step", "stop"),
                ],
            )),
            Ok(HostStopped::Refused { status }) => Err(refused(
                "stop-failed",
                &[
                    ("item", self.item()),
                    ("harness", harness),
                    ("cause", "provider"),
                    ("status", &status.to_string()),
                ],
            )),
            Ok(HostStopped::Unparsed) => Err(refused(
                "stop-failed",
                &[
                    ("item", self.item()),
                    ("harness", harness),
                    ("cause", "answer-unparsed"),
                ],
            )),
            Err(Asked::Failed(cause) | Asked::Unknown(cause)) => Err(refused(
                "stop-failed",
                &[
                    ("item", self.item()),
                    ("harness", harness),
                    ("cause", &cause),
                ],
            )),
        }
    }

    fn word(&self, word: Word, status: Option<LaneStatus>) -> Closed {
        Closed {
            item: self.item().to_owned(),
            word,
            status,
            state: None,
            notes: Vec::new(),
            observation: None,
            effect: None,
        }
    }

    /// The one close transition on `ground` and its effect, read by the
    /// outcome it recorded; the landing's comment is posted once the record
    /// reads done.
    fn persist(&self, ground: Ground, landing: Landing) -> Result<Closed> {
        let (terminal, no_landing, ended) = match ground {
            Ground::Terminal(t) => (Some(t), None, None),
            Ground::Exited => (None, None, None),
            Ground::Ended(source) => (
                None,
                None,
                Some(Ended {
                    source: source.to_owned(),
                }),
            ),
            Ground::Keep(park) => (
                None,
                Some(NoLanding {
                    reason: "keep-sandbox".to_owned(),
                    source: "close-lane".to_owned(),
                    interrupt: true,
                    park,
                }),
                None,
            ),
        };
        let Landing {
            cycle,
            disposed,
            notes,
            comment,
        } = landing;
        let request = Request::CloseOwnedResources(CloseOwnedResources {
            item: self.item().to_owned(),
            terminal,
            no_landing,
            ended,
            identity: Some(self.r.identity.clone()),
            cycle,
            disposed,
        });
        let applied =
            super::lane_operation::apply_request(self.path, &request, self.env, self.locking)?;
        let effected = super::run(
            self.path,
            &request,
            &applied.report,
            self.settings,
            self.env,
            self.locking,
            self.clock,
        )?;
        let mut closed = self.word(Word::Unconfirmed, Some(self.lane.status));
        closed.notes = notes;
        if let Some(Effected::Recorded(recorded)) = &effected
            && let Report::RecordOutcome(outcome) = &recorded.report
        {
            let intent = &outcome.intent;
            closed.observation = intent.observation.clone();
            closed.status = outcome.lane.as_ref().map(|l| l.status);
            closed.word = match (intent.open(), intent.outcome) {
                (true, _) => Word::Unconfirmed,
                (false, agent_runtime::protocol::Outcome::Confirmed) => match closed.status {
                    Some(LaneStatus::Stopped) => Word::Stopped,
                    Some(_) | None => Word::Closed,
                },
                (false, _) => Word::Failed,
            };
        }
        if let Some(refused) = closed
            .observation
            .as_ref()
            .and_then(|o| o.get("base"))
            .and_then(Value::as_str)
            .filter(|base| base.starts_with("refused "))
        {
            closed.notes.push(format!("base-follow {refused}"));
        }
        if let Some(text) = comment.filter(|_| closed.word == Word::Closed) {
            let posted = boxes::post(self.settings, self.item(), &text);
            closed.notes.push(format!("boxes-comment={posted}"));
        }
        closed.effect = effected;
        Ok(closed)
    }

    // --- the park ---------------------------------------------------------------

    /// The provider asked without effect whether it can stop the sandbox it
    /// will later start: a provider without the stop-sandbox and start pair
    /// refuses with the absent-verb status.
    fn park_check(&self) -> Result<()> {
        if self.host == "local" {
            return Err(refused(
                "park-refused",
                &[("item", self.item()), ("reason", "local")],
            ));
        }
        match hosted::stop_sandbox(self.scripts, self.host, self.item(), true) {
            Ok(()) => Ok(()),
            Err(Asked::Failed(cause)) if cause.starts_with(hosted::BUSY) => Err(refused(
                hosted::BUSY,
                &[("item", self.item()), ("step", "stop-sandbox-check")],
            )),
            Err(Asked::Failed(cause) | Asked::Unknown(cause)) => Err(refused(
                "park-refused",
                &[
                    ("item", self.item()),
                    ("reason", "provider-unsupported"),
                    ("host", self.host),
                    ("cause", &cause),
                ],
            )),
        }
    }

    fn park_refused(&self, reason: &str, fields: &[(&str, &str)]) -> Error {
        let mut all = vec![("item", self.item()), ("reason", reason)];
        all.extend_from_slice(fields);
        refused("park-refused", &all)
    }

    /// The one reading that admits a park, made before anything is
    /// signalled: the provider's check, the ask it names the lane's oldest
    /// open one, the pull request open on the lane's own head and branch (a
    /// queue park) or the dependency open in a watched repository, a head
    /// read from the worktree pushed to its sandbox's `origin`, the lane's
    /// clean-status record bound to that head, and for a queue park the
    /// merge queue holding it, or auto-merge armed with GitHub reading it
    /// CLEAN, and the github skill's reducer silent on it. A park the record
    /// owes (`owed`, its judged head) reads its sandbox for nothing: its
    /// check, ask, head and clean status were judged when its mark was
    /// written and no session can have moved them since; its sandbox stop is
    /// the provider's own answer to the check. What GitHub holds can move,
    /// so every read of it is made again, the head match against the
    /// judged head among them.
    fn park_judge(&self, wait: &ParkWait, owed: Option<String>) -> Result<ParkLane> {
        if owed.is_none() {
            self.park_check()?;
        }
        if let Some(ask) = wait.ask.as_ref().filter(|_| owed.is_none()) {
            let open = self.open_ask()?;
            if open.as_deref() != Some(ask.as_str()) {
                return Err(self.park_refused(
                    "ask-not-open",
                    &[("ask", ask), ("open", open.as_deref().unwrap_or("none"))],
                ));
            }
        }
        let gh = crate::watch::github::handle(Path::new("gh"));
        // A lane that parks is hosted, and a hosted launch records the
        // repository it names.
        let repo = crate::repo::of_lane(self.who.repo.as_deref(), &self.settings.roots.project)
            .map_err(|unread| {
                self.park_refused("repo-unresolved", &[("cause", &unread.to_string())])
            })?;
        let until_repo = wait.until_repo.as_ref().map(|r| r.to_ascii_lowercase());
        if let Some(until) = &until_repo
            && !self.settings.reads.watched([repo.as_str()]).contains(until)
        {
            return Err(self.park_refused("repo-unwatched", &[("repo", until)]));
        }
        let target = match wait.until_pr {
            Some(n) => Some((n, until_repo.clone().unwrap_or_else(|| repo.clone()))),
            None => wait.pr.map(|n| (n, repo.clone())),
        };
        let pull = match target {
            Some((number, target_repo)) => {
                let pull = self.park_pull(&gh, &target_repo, number)?;
                if pull.state != "OPEN" {
                    return Err(self.park_refused(
                        "pr-not-open",
                        &[("pr", &number.to_string()), ("state", &pull.state)],
                    ));
                }
                Some(pull)
            }
            None => None,
        };
        // A queue park's pull request is the lane's own; a dependency park
        // and an ask park read none of its checks.
        let queue = pull.as_ref().filter(|_| wait.until_pr.is_none());
        // An owed park's head, branch and clean status were judged when its
        // mark was written; a pull request's head branch cannot change, so
        // only its head is matched again.
        let (head, branch, source) = match owed {
            Some(head) => (head, None, "park-owed"),
            None => {
                let (head, branch, source) = self.worktree_head(queue)?;
                (head, Some(branch), source)
            }
        };
        let pr = wait.pr.unwrap_or_default().to_string();
        if let Some(pull) = queue {
            if let Some(branch) = &branch
                && pull.head_ref_name != *branch
            {
                return Err(self.park_refused(
                    "pr-branch-mismatch",
                    &[
                        ("pr", &pr),
                        ("branch", &pull.head_ref_name),
                        ("branch-source", source),
                    ],
                ));
            }
            if pull.head_ref_oid != head {
                return Err(self.park_refused(
                    "pr-head-mismatch",
                    &[("pr", &pr), ("branch-source", source)],
                ));
            }
        }
        if let Some(branch) = &branch {
            self.clean_status(&head, branch, source)?;
        }
        if let Some(pull) = queue {
            let queued =
                pull.is_in_merge_queue || matches!(pull.merge_queue_entry, Nullable::Present(_));
            if !queued {
                if !matches!(pull.auto_merge_request, Nullable::Present(_)) {
                    return Err(self
                        .park_refused("not-armed", &[("pr", &pr), ("head", &pull.head_ref_oid)]));
                }
                if pull.merge_state_status != "CLEAN" {
                    return Err(self.park_refused(
                        "merge-state",
                        &[("pr", &pr), ("state", &pull.merge_state_status)],
                    ));
                }
            }
            self.reducer_silent(&repo, &pr)?;
        }
        Ok(ParkLane {
            item: self.item().to_owned(),
            head,
            repo,
            pr: wait.pr,
            until_pr: wait.until_pr,
            until_repo,
            ask: wait.ask.clone(),
            reservation: None,
            owed: false,
        })
    }

    /// The lane's head and branch for a park judged in full, and where they
    /// were read: a head read from the worktree is the sandbox's alone until
    /// its remote-tracking ref names it, since the park would strand it with
    /// the agent that can push it stopped; the pull request's head, taken
    /// where the worktree is unread, is the remote's.
    fn worktree_head(&self, queue: Option<&ParkPull>) -> Result<(String, String, &'static str)> {
        match (self.lane_head(), queue) {
            (
                Ok(LaneHead {
                    head,
                    branch,
                    remote,
                }),
                _,
            ) => {
                if remote.as_deref() != Some(head.as_str()) {
                    return Err(self.park_refused(
                        "unpushed",
                        &[
                            ("head", &head),
                            ("remote", remote.as_deref().unwrap_or("absent")),
                        ],
                    ));
                }
                Ok((head, branch, "worktree"))
            }
            (Err(()), None) => Err(self.park_refused("worktree-unread", &[])),
            (Err(()), Some(pull)) => {
                match self.recorded_branch() {
                    Some(branch) => Ok((pull.head_ref_oid.clone(), branch, "workflow-state")),
                    None => Err(self
                        .park_refused("worktree-unread", &[("branch-source", "workflow-state")])),
                }
            }
        }
    }

    /// The lane's clean-status record bound to `head` on `branch`, read
    /// through the provider's `cat`.
    fn clean_status(&self, head: &str, branch: &str, source: &str) -> Result<()> {
        let root = self.lane.mail_root.as_deref().unwrap_or("");
        let clean = match hosted::fetch(
            self.scripts,
            self.host,
            self.item(),
            &format!("{root}/tmp/park-status.json"),
        ) {
            HostAnswer::Live(text) => text,
            HostAnswer::Gone | HostAnswer::Unreadable { .. } => {
                return Err(self.park_refused("clean-status-unread", &[]));
            }
        };
        let clean: Value = serde_json::from_str(&clean).unwrap_or(Value::Null);
        let bound = clean.get("head").and_then(Value::as_str) == Some(head)
            && clean.get("branch").and_then(Value::as_str) == Some(branch)
            && clean.get("porcelain").and_then(Value::as_str) == Some("")
            && clean
                .get("at")
                .and_then(Value::as_str)
                .is_some_and(|at| !at.is_empty());
        if !bound {
            return Err(self.park_refused("clean-status-invalid", &[("branch-source", source)]));
        }
        Ok(())
    }

    /// The judged head of the park this record owes for `wait`, the one
    /// reading that says a park is owed: the record's mark asks the same
    /// wait, its dependency repository in the lower case the judge records.
    /// A mark carrying no head owes nothing, and its park is judged in full.
    fn owed(&self, wait: &ParkWait) -> Option<String> {
        let mark = self.lane.extra.get(state::PARK_OWED)?;
        let mark: OwedPark = serde_json::from_value(mark.clone()).ok()?;
        let asked = ParkWait {
            until_repo: wait.until_repo.as_ref().map(|r| r.to_ascii_lowercase()),
            ..wait.clone()
        };
        (mark.wait == asked).then_some(mark.head)
    }

    /// A stopped record's park, judged in full, recorded owed with its judged
    /// head before its sandbox stop: a stop that fails then leaves the park
    /// for the watch to complete, never a kept sandbox.
    fn owe_park(&self, park: &ParkLane) -> Result<()> {
        let owed = ParkLane {
            owed: true,
            ..park.clone()
        };
        super::lane_operation::apply_request(
            self.path,
            &Request::ParkLane(owed),
            self.env,
            self.locking,
        )?;
        Ok(())
    }

    /// The pull request's state, head, arm, merge state and queue
    /// membership, in one GraphQL read.
    fn park_pull(&self, gh: &crate::verify::Gh, repo: &str, number: u64) -> Result<ParkPull> {
        let pr = number.to_string();
        let failed = |cause: &str| {
            self.park_refused(
                "pr-read-failed",
                &[("pr", &pr), ("repo", repo), ("cause", cause)],
            )
        };
        let (owner, name) = repo.split_once('/').ok_or_else(|| failed("repo-shape"))?;
        let query = "query=query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { state headRefOid headRefName autoMergeRequest { enabledAt } mergeStateStatus isInMergeQueue mergeQueueEntry { position } } } }";
        let owner = format!("owner={owner}");
        let name = format!("name={name}");
        let number = format!("number={pr}");
        let args = [
            "api", "graphql", "-f", query, "-F", &owner, "-F", &name, "-F", &number,
        ];
        let stdout = match gh.run("park-pull", &args, None) {
            Ok(Answer::Printed { stdout, .. }) => stdout,
            Ok(Answer::Failed(failed_call)) => return Err(failed(&failed_call.detail())),
            Err(unrun) => return Err(failed(&unrun.detail())),
        };
        let answer: ParkPullAnswer =
            serde_json::from_slice(&stdout).map_err(|_| failed("payload-unparsed"))?;
        match answer.data.repository {
            Nullable::Present(repository) => match repository.pull_request {
                Nullable::Present(pull) => Ok(pull),
                Nullable::Absent | Nullable::Null => Err(failed("pr-absent")),
            },
            Nullable::Absent | Nullable::Null => Err(failed("repo-absent")),
        }
    }

    /// The lane's checked-out head and branch, and the commit its sandbox's
    /// `origin` remote-tracking ref names for that branch (`None` where the
    /// sandbox holds no such ref), read through the provider's `cat`: the
    /// worktree's `.git` file, its HEAD, then each ref, loose or packed. A
    /// read that fails, a detached head or a head ref absent is `Err`. Git
    /// moves the remote-tracking ref only on a push or fetch that reached
    /// the remote, so its equality with the head proves the head pushed.
    fn lane_head(&self) -> std::result::Result<LaneHead, ()> {
        let root = self.lane.mail_root.as_deref().unwrap_or("");
        let cat = |path: &str| match hosted::fetch(self.scripts, self.host, self.item(), path) {
            HostAnswer::Live(text) => Ok(Some(text)),
            HostAnswer::Gone => Ok(None),
            HostAnswer::Unreadable { .. } => Err(()),
        };
        let gitfile = cat(&format!("{root}/.git"))?.ok_or(())?;
        let line = gitfile.lines().next().ok_or(())?;
        let (git_dir, common) = crate::marker::git_dirs_of(line).ok_or(())?;
        let head = cat(&format!("{}/HEAD", git_dir.display()))?.ok_or(())?;
        let reference = head.trim().strip_prefix("ref: ").ok_or(())?;
        let branch = reference.strip_prefix("refs/heads/").ok_or(())?.to_owned();
        let commit_of = |name: &str| -> std::result::Result<Option<String>, ()> {
            let sha = match cat(&format!("{}/{name}", common.display()))? {
                Some(text) => Some(text.trim().to_owned()),
                None => cat(&format!("{}/packed-refs", common.display()))?.and_then(|packed| {
                    packed.lines().find_map(|l| {
                        let (sha, ref_name) = l.split_once(' ')?;
                        (ref_name == name).then(|| sha.to_owned())
                    })
                }),
            };
            Ok(sha.filter(|s| !s.is_empty()))
        };
        let head = commit_of(reference)?.ok_or(())?;
        let remote = commit_of(&format!("refs/remotes/origin/{branch}"))?;
        Ok(LaneHead {
            head,
            branch,
            remote,
        })
    }

    /// The branch the item's own workflow state recorded, for a queue park
    /// whose remote Git read failed.
    #[allow(
        clippy::disallowed_methods,
        reason = "the park's fallback read of the item's own recorded branch, a read it acts on nothing by"
    )]
    fn recorded_branch(&self) -> Option<String> {
        let path = state::item_path(&self.settings.state_dir, self.item());
        let snapshot = state::load(&path).ok().flatten()?;
        snapshot
            .doc
            .get("branch")
            .and_then(Value::as_str)
            .filter(|b| !b.is_empty())
            .map(str::to_owned)
    }

    /// The github skill's reducer silent on the pull request: no open thread,
    /// no standing objection, no disarmed or stale-review line. Its silence
    /// is no approval, which CLEAN or the queue proves.
    #[allow(
        clippy::disallowed_methods,
        reason = "the park's one run of the github skill's reducer through the one runner, its repository named"
    )]
    fn reducer_silent(&self, repo: &str, pr: &str) -> Result<()> {
        let reducer = match std::env::var_os("OVERSEE_WATCH_PR_WATCH") {
            Some(path) if !path.is_empty() => std::path::PathBuf::from(path),
            Some(_) | None => self
                .settings
                .roots
                .project
                .join(".agents/skills/github/scripts/pr-watch.sh"),
        };
        if !reducer.is_file() {
            return Err(self.park_refused(
                "reducer-missing",
                &[("path", &reducer.display().to_string())],
            ));
        }
        let env = [("GH_REPO", std::ffi::OsStr::new(repo))];
        let out = agent_runtime::host::run_tagged_in(
            "close",
            "pr-watch",
            &reducer,
            "park-reducer",
            &[pr],
            agent_runtime::host::Place {
                cwd: Some(&self.settings.roots.project),
                env: &env,
            },
            std::time::Duration::from_secs(120),
        )
        .map_err(|e| {
            self.park_refused("reducer-failed", &[("pr", pr), ("cause", &e.to_string())])
        })?;
        match out.status.code() {
            Some(0) => Ok(()),
            Some(1) => {
                let kinds: Vec<String> = agent_runtime::host::stdout_text(&out)
                    .lines()
                    .filter_map(|l| {
                        let mut f = l.split('\t');
                        (f.next() == Some(pr)).then(|| f.nth(1).unwrap_or("").to_owned())
                    })
                    .collect();
                let kinds = if kinds.is_empty() {
                    "unlisted".to_owned()
                } else {
                    kinds.join(",")
                };
                Err(self.park_refused("attention", &[("pr", pr), ("kinds", &kinds)]))
            }
            code => Err(self.park_refused(
                "reducer-failed",
                &[
                    ("pr", pr),
                    (
                        "exit",
                        &code.map_or_else(|| out.status.to_string(), |c| c.to_string()),
                    ),
                ],
            )),
        }
    }

    /// The sandbox stop and the record it earns, from a lane whose harness
    /// is gone and whose window is closed: the record reads stopped, so a
    /// stop that fails or answers without its line refuses with the record
    /// stopped, and only the confirmed line records parked.
    fn park_sandbox(&self, park: &ParkLane, notes: Vec<String>) -> Result<Closed> {
        match hosted::stop_sandbox(self.scripts, self.host, self.item(), false) {
            Ok(()) => {}
            Err(Asked::Failed(cause)) if cause.starts_with(hosted::BUSY) => {
                return Err(refused(
                    hosted::BUSY,
                    &[("item", self.item()), ("step", "stop-sandbox")],
                ));
            }
            Err(Asked::Failed(cause) | Asked::Unknown(cause)) => {
                return Err(refused(
                    "park-failed",
                    &[("item", self.item()), ("cause", &cause)],
                ));
            }
        }
        let applied = super::lane_operation::apply_request(
            self.path,
            &Request::ParkLane(park.clone()),
            self.env,
            self.locking,
        )?;
        let mut closed = self.word(Word::Parked, Some(LaneStatus::Parked));
        closed.notes = notes;
        if let Report::ParkLane(parked) = &applied.report {
            closed.observation = parked
                .lane
                .extra
                .get("parked")
                .map(|p| json!({"parked": p}));
        }
        Ok(closed)
    }
}

/// The cause word a refusal carries, for a note that names it.
fn cause_word(error: &Error) -> String {
    let text = error.to_string();
    text.split_whitespace()
        .find_map(|w| w.strip_prefix("cause="))
        .unwrap_or_else(|| error.key())
        .to_owned()
}
