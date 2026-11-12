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

use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::{Value, json};

use crate::error::{Error, Result};
use crate::ops::{
    self, CloseIdentity, CloseLane, CloseMode, CloseOwnedResources, Ended, Env, NoLanding,
    ParkLane, ParkWait, Report, Request, Terminal, boxes,
};
use crate::schedule::Clock;
use crate::settings::Settings;
use crate::state::{self, FleetState, Lane, LaneStatus, Locking};
use crate::verify::Answer;
use crate::verify::wire::{Nullable, ParkPull, ParkPullAnswer};
use crate::watch::hosted::{
    self, Answer as HostAnswer, Asked, Capabilities, HostStopped, Input, PaneKind, Status, StopKind,
};
use crate::watch::lanes::{self, LaneState, reset};
use crate::watch::tracker::{self, TerminalState};
use agent_runtime::observe::WallKind;

use super::{Effected, lane_operation, operation};

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
/// session=`, `merged-unjudged`, and the box completion's `boxes-ticked`,
/// `boxes-unticked`, `boxes-held` or `boxes-unknown`), and the close
/// transition's effect as recorded.
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
    /// line under `host_close`, its refusal's `path`, a cause.
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
            fleet.overseer.as_ref().and_then(super::overseer_socket),
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
    {
        return Err(refused(
            "request-invalid",
            &[("item", &r.item), ("field", "park"), ("requires", "pr")],
        ));
    }
    let scripts = crate::watch::overseer::scripts_dir(&settings.roots.project);
    let host = hosted::host_of(&lane).to_owned();
    let caps = if host == "local" {
        Capabilities::LOCAL
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

/// How often the exit wait reads the lane again.
const EXIT_POLL: std::time::Duration = std::time::Duration::from_millis(200);

/// The Copilot exit's input file, the verb's own under the state directory.
#[allow(
    clippy::disallowed_methods,
    reason = "the close verb's own input file for the provider's send, written once and removed after"
)]
fn write_input(path: &Path, text: &str) -> std::io::Result<()> {
    std::fs::write(path, text)
}

#[allow(
    clippy::disallowed_methods,
    reason = "the close verb's own input file for the provider's send, removed once sent"
)]
fn remove_input(path: &Path) {
    let _ = std::fs::remove_file(path);
}

/// The ground the close transition persists.
enum Ground {
    Terminal(Terminal),
    Exited,
    Ended(&'static str),
    Keep,
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
        Ground::Terminal(_) | Ground::Exited | Ground::Ended(_) | Ground::Keep => None,
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
        let mut closed = self.persist(ground)?;
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
    fn stopped(self) -> Result<Closed> {
        let mut notes = Vec::new();
        let ground = if self.keep() {
            Ground::Keep
        } else {
            self.by_verdict(Ground::Exited, &mut notes)?
        };
        if !matches!(ground, Ground::Terminal(_)) {
            self.refuse_ask()?;
        }
        if let Some(wait) = self.park() {
            let judged = self.park_judge(wait)?;
            return self.park_sandbox(&judged, Vec::new());
        }
        if self.keep() {
            return Ok(self.word(Word::Stopped, Some(LaneStatus::Stopped)));
        }
        let mut closed = self.persist(ground)?;
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
        let mut closed = self.persist(ground)?;
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
            Ground::Keep
        } else {
            self.by_verdict(Ground::Exited, &mut notes)?
        };
        let mut closed = self.persist(ground)?;
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
        } = &judged.state
        {
            let read = self.wall(banner);
            if read.lifts() {
                judged = lanes::judge(self.settings, &self.lane, socket, Some(true));
            }
            wall = Some(read);
        }
        let mut notes = Vec::new();
        if let Some(wait) = self.park() {
            let park = self.park_judge(wait)?;
            if !matches!(judged.state, LaneState::Exited) {
                self.refuse_ask()?;
                self.host_stop(&mut notes)?;
            }
            let closed = self.persist(Ground::Keep)?;
            if closed.word != Word::Stopped {
                return Ok(closed);
            }
            return self.park_sandbox(&park, notes);
        }
        let ground = match &judged.state {
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
            LaneState::Unjudged { .. } if judged.answered && self.merged_and_done()? => {
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
        let ground = if self.keep() { Ground::Keep } else { ground };
        if !matches!(judged.state, LaneState::Exited) && self.hosted() {
            match self.refuse_ask() {
                Ok(()) => {}
                Err(e) if matches!(ground, Ground::Terminal(_)) && self.host_absent(&e)? => {
                    notes.push(format!("host-absent mail-status={}", cause_word(&e)));
                    let cause = boxes_cause(&ground, true);
                    let mut closed = self.persist(Ground::Ended(state::HOST_ABSENT))?;
                    closed.notes.splice(0..0, notes);
                    self.complete_boxes(cause, &mut closed);
                    return Ok(closed);
                }
                Err(e) => return Err(e),
            }
            self.host_stop(&mut notes)?;
        }
        let cause = boxes_cause(&ground, false);
        let mut closed = self.persist(ground)?;
        closed.notes.splice(0..0, notes);
        self.complete_boxes(cause, &mut closed);
        Ok(closed)
    }

    /// A merged item's branch-provable boxes completed from its merged pull
    /// request's evidence where the close ended a lane that did not complete
    /// them, its note added to the close's. It runs only once the record
    /// reads done: a close left unconfirmed or failed is asked again, and
    /// the completion's comment is a tracker write no repeat may make twice,
    /// while a done record answers a later close at once. A Linear item
    /// alone: the completion is the linear package's.
    fn complete_boxes(&self, cause: Option<(boxes::Cause, bool)>, closed: &mut Closed) {
        let Some((cause, done)) = cause.filter(|_| closed.word == Word::Closed) else {
            return;
        };
        let notes = &mut closed.notes;
        if self.who.tracker != "linear" {
            return;
        }
        let pr = match &self.r.delivery {
            Some(ops::Delivery::Pr { pr, repo }) => Some((*pr, repo.clone())),
            Some(ops::Delivery::Commit { .. }) => None,
            None => self
                .lane
                .extra
                .get("cycle")
                .and_then(|c| c.get("pr"))
                .and_then(Value::as_u64)
                .map(|pr| (pr, None)),
        };
        let Some((pr, repo)) = pr else {
            return;
        };
        let Some(repo) = repo.or_else(|| self.who.repo.clone()) else {
            notes.push("boxes-unticked cause=repo-missing".to_owned());
            return;
        };
        let merged = boxes::Merged { repo: &repo, pr };
        if let Some(note) = boxes::complete(
            self.settings,
            Path::new("gh"),
            self.item(),
            &merged,
            cause,
            done,
        ) {
            notes.push(note);
        }
    }

    /// The ground a lane whose work may be over closes on: its item ended
    /// by its tracker, else its merge landed with its work over
    /// ([`Self::merged_and_done`]); `None` is a lane still at work on an
    /// open item. A tracker that does not answer refuses.
    fn finished(&self, notes: &mut Vec<String>) -> Result<Option<Ground>> {
        if let Some(t) = terminal(verdict(self.settings, &self.lane, &self.who, false)?) {
            return Ok(Some(Ground::Terminal(t)));
        }
        if !self.merged_and_done()? {
            return Ok(None);
        }
        notes.push("item-files-kept cause=open".to_owned());
        Ok(Some(Ground::Ended("merged")))
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

    /// The record's account read for the wall (`lanes pick --lane` in
    /// process): for the model the record names, the whole account where it
    /// names none, the widest reading, so it lifts no wall the model's own
    /// would keep; under the record's host, `local` for a local lane, never
    /// the caller's setting. Then, on room, the reset the banner names:
    /// a dated reset still ahead keeps the wall with it, a clause that keys
    /// to no time (a zone with no zoneinfo here, a date that names no day)
    /// keeps it `unresolved`, and a clock or weekday reset names no day,
    /// which the account's reading answers alone.
    fn wall(&self, banner: &str) -> WallRead {
        let account = self.lane.account.as_deref().filter(|a| !a.is_empty());
        let harness = self.who.harness.as_deref();
        let (Some(account), Some(harness @ ("claude" | "codex"))) = (account, harness) else {
            return WallRead {
                account: "none",
                resets: None,
            };
        };
        let request = crate::ops::accounts::PickRequest {
            harness: harness.to_owned(),
            model: self.lane.model.clone().filter(|m| !m.is_empty()),
            exclude: Vec::new(),
            replaces: None,
            for_overseer: false,
            lane: Some(account.to_owned()),
            projected: false,
            max_pct: None,
            min_headroom_pct: None,
            binding_floor: false,
            host: Some(self.host.to_owned()),
            admit_unread_scope: false,
        };
        let answer = super::lane_operation::pick_account(
            self.settings,
            self.path,
            &request,
            self.env.now_secs,
        );
        let account = match answer.exit() {
            0 => "room",
            3 => "walled",
            4 => "unlisted",
            5 => "unmeasured",
            _ => "read-failed",
        };
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
    /// worktree gone, read on its host through the provider where it is
    /// hosted ([`hosted::record_left`]). The close-out removes the live state
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
            return Ok(std::fs::symlink_metadata(root).is_err() || self.closed_out()?);
        }
        match hosted::record_left(self.scripts, &self.lane) {
            HostAnswer::Gone => Ok(true),
            HostAnswer::Live(()) => Ok(false),
            HostAnswer::Unreadable { cause } => Err(refused(
                if cause.contains(&format!("exit={}", hosted::LANE_HOST_BUSY_EXIT)) {
                    "lane-host-busy"
                } else {
                    "worktree-read-failed"
                },
                &[("item", self.item()), ("root", root), ("cause", &cause)],
            )),
        }
    }

    /// Whether the item's close-out removed its live state record.
    fn closed_out(&self) -> Result<bool> {
        let path = state::item_path(&self.settings.state_dir, self.item());
        match std::fs::metadata(&path) {
            Ok(_) => Ok(false),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(true),
            Err(e) => Err(refused(
                "state-unreadable",
                &[
                    ("item", self.item()),
                    ("path", &path.display().to_string()),
                    ("cause", &e.to_string()),
                ],
            )),
        }
    }

    /// An ask the lane holds unanswered refuses the close: the answer would
    /// reach the session the close ends. A mailbox that cannot be read
    /// refuses too.
    fn refuse_ask(&self) -> Result<()> {
        match lane_operation::pending_ask(&self.settings.lane_mail_cli, &self.lane) {
            Ok(None) => Ok(()),
            Ok(Some(ask)) => Err(refused(
                "ask-unanswered",
                &[("item", self.item()), ("ask", &ask)],
            )),
            Err(cause) if cause.starts_with("lane-host-busy") => Err(refused(
                "lane-host-busy",
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
            Ok(listed) => Ok(!listed),
            Err(cause) if cause.starts_with("lane-host-busy") => Err(refused(
                "lane-host-busy",
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
        if hosted::send(self.scripts, self.host, self.item(), Input::Key("C-c")).is_err() {
            return Ok(false);
        }
        let input = self.settings.state_dir.join(format!(
            "copilot-exit.{}.{}",
            self.item(),
            std::process::id()
        ));
        let written = write_input(&input, "/exit");
        let sent = written.is_ok()
            && hosted::send(self.scripts, self.host, self.item(), Input::File(&input)).is_ok();
        remove_input(&input);
        if !sent {
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
        let read = || match lanes::judge(self.settings, &self.lane, socket, None).state {
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
        if let Some(answer) = operation::poll_until(
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
            Ok(HostStopped::Refused {
                status: hosted::LANE_HOST_BUSY_EXIT,
            }) => Err(refused(
                "lane-host-busy",
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
    /// outcome it recorded.
    fn persist(&self, ground: Ground) -> Result<Closed> {
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
            Ground::Keep => (
                None,
                Some(NoLanding {
                    reason: "keep-sandbox".to_owned(),
                    source: "close-lane".to_owned(),
                    interrupt: true,
                }),
                None,
            ),
        };
        let mut notes = Vec::new();
        let cycle = match &self.r.delivery {
            Some(delivery) if no_landing.is_none() => match crate::ops::cycle::recorded(
                self.settings,
                Path::new("gh"),
                self.path,
                &self.lane,
                delivery,
                self.env.now_secs,
            ) {
                Ok(row) => {
                    notes.extend(row.notes.iter().cloned());
                    Some(row)
                }
                Err(cause) => {
                    notes.push(format!("cycle-unrecorded cause={cause}"));
                    None
                }
            },
            Some(_) | None => None,
        };
        let request = Request::CloseOwnedResources(CloseOwnedResources {
            item: self.item().to_owned(),
            terminal,
            no_landing,
            ended,
            identity: Some(self.r.identity.clone()),
            cycle,
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
            Err(Asked::Failed(cause)) if cause.starts_with("lane-host-busy") => Err(refused(
                "lane-host-busy",
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
    /// signalled: the provider's check, the pull request open on the lane's
    /// own head and branch (a queue park) or the dependency open in a
    /// watched repository, the lane's clean-status record bound to that
    /// head, and for a queue park the merge queue holding it, or auto-merge
    /// armed with GitHub reading it CLEAN, and the github skill's reducer
    /// silent on it.
    fn park_judge(&self, wait: &ParkWait) -> Result<ParkLane> {
        self.park_check()?;
        let gh = crate::watch::github::handle(Path::new("gh"));
        let repo = match &self.who.repo {
            Some(repo) => repo.clone(),
            None => self.checkout_repo(&gh)?,
        };
        let until_repo = wait.until_repo.as_ref().map(|r| r.to_ascii_lowercase());
        if let Some(until) = &until_repo
            && *until != repo.to_ascii_lowercase()
            && !self
                .settings
                .reads
                .connected_repos
                .iter()
                .any(|c| c.to_ascii_lowercase() == *until)
        {
            return Err(self.park_refused("repo-unwatched", &[("repo", until)]));
        }
        let (target, target_repo) = match wait.until_pr {
            Some(n) => (n, until_repo.clone().unwrap_or_else(|| repo.clone())),
            None => (wait.pr.unwrap_or_default(), repo.clone()),
        };
        let pull = self.park_pull(&gh, &target_repo, target)?;
        if pull.state != "OPEN" {
            return Err(self.park_refused(
                "pr-not-open",
                &[("pr", &target.to_string()), ("state", &pull.state)],
            ));
        }
        let dependency = wait.until_pr.is_some();
        let (head, branch, source) = match self.lane_head() {
            Ok((head, branch)) => (head, branch, "worktree"),
            Err(()) if dependency => return Err(self.park_refused("worktree-unread", &[])),
            Err(()) => match self.recorded_branch() {
                Some(branch) => (pull.head_ref_oid.clone(), branch, "workflow-state"),
                None => {
                    return Err(self
                        .park_refused("worktree-unread", &[("branch-source", "workflow-state")]));
                }
            },
        };
        let pr = wait.pr.unwrap_or(target).to_string();
        if !dependency {
            if pull.head_ref_name != branch {
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
        let bound = clean.get("head").and_then(Value::as_str) == Some(head.as_str())
            && clean.get("branch").and_then(Value::as_str) == Some(branch.as_str())
            && clean.get("porcelain").and_then(Value::as_str) == Some("")
            && clean
                .get("at")
                .and_then(Value::as_str)
                .is_some_and(|at| !at.is_empty());
        if !bound {
            return Err(self.park_refused("clean-status-invalid", &[("branch-source", source)]));
        }
        if !dependency {
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
            reservation: None,
        })
    }

    /// The checkout's own repository through gh, for a record naming none.
    fn checkout_repo(&self, gh: &crate::verify::Gh) -> Result<String> {
        let gh = gh
            .adding_env(Vec::new())
            .in_dir(&self.settings.roots.project);
        match gh.run(
            "park-repo",
            &[
                "repo",
                "view",
                "--json",
                "nameWithOwner",
                "--jq",
                ".nameWithOwner",
            ],
            None,
        ) {
            Ok(Answer::Printed { stdout, .. }) => {
                let repo = String::from_utf8_lossy(&stdout).trim().to_owned();
                if repo.contains('/') {
                    Ok(repo)
                } else {
                    Err(self.park_refused("repo-unresolved", &[]))
                }
            }
            Ok(Answer::Failed(_)) | Err(_) => Err(self.park_refused("repo-unresolved", &[])),
        }
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

    /// The lane's checked-out head and branch, read through the provider's
    /// `cat`: the worktree's `.git` file, its HEAD, then the branch ref,
    /// loose or packed. A read that fails, or a detached head, is `Err`.
    fn lane_head(&self) -> std::result::Result<(String, String), ()> {
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
        let sha = match cat(&format!("{}/{reference}", common.display()))? {
            Some(text) => text.trim().to_owned(),
            None => cat(&format!("{}/packed-refs", common.display()))?
                .ok_or(())?
                .lines()
                .find_map(|l| {
                    let (sha, name) = l.split_once(' ')?;
                    (name == reference).then(|| sha.to_owned())
                })
                .ok_or(())?,
        };
        if sha.is_empty() {
            return Err(());
        }
        Ok((sha, branch))
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
            Err(Asked::Failed(cause)) if cause.starts_with("lane-host-busy") => {
                return Err(refused(
                    "lane-host-busy",
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
