//! The wake duty: a lead or lane the mail duty reports unread mail for is
//! read positively idle, by identity and markers, and typed one line,
//! confirmed by a new user turn in that session's own bound file, never a
//! neighbour's and never the newest file; a harness with no confirmable
//! route gets its limit reported. The duty acts only through
//! agent-runtime's `deliver` verb, run by the one runner under the `wake`
//! tag, and records its mark in the watch's own record (`ops::wake`),
//! durably, before it types, so a crash between the mark and the paste
//! never repeats a nudge for the same unread state; a later unread state
//! is a new wake. The record is read at the start of each pass: nothing
//! the fleet record's writers do to a lane or overseer record moves a mark.
//!
//! Slot: the mail duty sets a baseline row of kind [`UNREAD_KIND`], its
//! identity the target (an item key, or [`OVERSEER_TARGET`]), its value the
//! unread state it announced (the newest unread envelope's id or index),
//! while the target's box holds mail the target has not read, and clears
//! the row once read. The wake reads that row from its tick's snapshot and
//! writes no row of its own.
//!
//! Resume: the lanes duty sets a row of kind [`RESUME_KIND`], its identity
//! the lane's name, its value the wall it asks a resume for
//! (`usage-limit|<identity>|<reset>`), for a lane [`resumable`] names whose
//! wall's reset passed. The wake reads the lane's account through the close's
//! own account read and, once it reads room, types the resume sentence before
//! the inbox line into the pane past its usage banner (`deliver
//! --account-room`), once per row value: the mark keeps the value typed.
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

use agent_runtime::controller::Overseer;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::harness::Harness;
use agent_runtime::host;
use serde_json::Value;

use super::owner_alert::{self, Word};
use super::{Body, Event, Produced, Runner, Tick, context};
use crate::error::{Error, Result, WatchError};
pub use crate::ops::wake::OVERSEER_TARGET;
use crate::ops::wake::{WakeMark, WakeOutcome, WakeRecord};
use crate::schedule::Duty;
use crate::settings::Settings;
use crate::state::{self, FleetState, Lane, LaneStatus, Record};
use agent_runtime::effects::overseer_socket;

/// The baseline row kind the mail duty signals unread mail with.
pub const UNREAD_KIND: &str = "unread";
/// The baseline row kind the lanes duty asks a resume with.
pub const RESUME_KIND: &str = "resume";
/// The watch's wake record, beside the fleet state: it shares the runner's
/// own records' stem, which the retention duty never judges.
pub const WAKE_FILE: &str = "oversee-watch.wake.json";
/// What the verb may take past its own bound to read the pane and answer.
const ANSWER_MARGIN: Duration = Duration::from_secs(15);
/// The owner alert's notice file under the state directory.
const ALERT_FILE: &str = "overseer-wake-unread.txt";

/// The wake record's path for the fleet state at `fleet`.
pub fn record_path(fleet: &Path) -> PathBuf {
    fleet.parent().unwrap_or(Path::new(".")).join(WAKE_FILE)
}

/// The one line typed, which runs the target's inbox read.
fn line_for(target: &str) -> String {
    format!(
        "Run .agents/skills/mailbox/scripts/lane-mail inbox --item {target} and act on every envelope it prints, answers and directives alike, as its text directs."
    )
}

/// A resume the lanes duty asked: its row's value, which the mark keeps
/// once typed, and the cause the row names.
struct Resume {
    row: String,
    cause: &'static str,
    /// How the session's last turn ended, as the sentence says it.
    ended: &'static str,
}

impl Resume {
    /// The resume a row's value asks for; none for a cause the wake does
    /// not resume.
    fn of(row: &str) -> Option<Resume> {
        let (cause, ended) = match row.split('|').next()? {
            "usage-limit" => (
                "usage-limit",
                "its account's usage limit, which has since reset",
            ),
            _ => return None,
        };
        Some(Resume {
            row: row.to_owned(),
            cause,
            ended,
        })
    }

    /// The line typed for `target`: the resume sentence, then the inbox
    /// line, so the resumed turn reads the mail that waited too.
    fn line(&self, target: &str) -> String {
        format!(
            "Resume the orch workflow for {target} from where this session stopped: your last turn ended on {}. {}",
            self.ended,
            line_for(target)
        )
    }
}

/// Whether the wake resumes `lane` at a passed wall: a lane it types into,
/// spending an account the wall's account reading measures. The lanes duty
/// asks a resume for such a lane alone.
pub fn resumable(lane: &Lane) -> bool {
    // The socket only names where a paste would go.
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
/// for the overseer left unwoken, where no turn stands yet (an alerted
/// state is never alerted again, whatever its later outcome); nothing for
/// a delivery or a lane, whose limit the overseer handles (`lane-reach.md`
/// § Mail the wake cannot deliver).
fn owner_word(target: &str, mark: &WakeMark) -> Option<Word> {
    if target != OVERSEER_TARGET || unwoken(target, mark.outcome.as_ref()).is_none() {
        return None;
    }
    mark.owner.or(Some(Word::Told))
}

/// The owner's alert for an overseer left idle with its mail unread, in
/// the shape of `context::alert_text`: what stands unread, why no wake
/// reached it, what the owner can do.
fn alert_text(pane: &str, unread: &str, said: &Event) -> String {
    let why = said.render();
    let why = why.strip_prefix("EVENT ").unwrap_or(&why);
    format!(
        "{why}: the overseer in pane {pane} is idle with mail it has not read, newest unread={unread}, and the watch could not wake it, so nothing acts on that mail until a turn runs in that pane. Type one line into pane {pane}, such as: Run .agents/skills/mailbox/scripts/lane-mail inbox --item overseer and act on every envelope it prints. The remedy for this line is under idle-unread in the orch skill's references/oversee-events.md.\n"
    )
}

/// A target's recorded facts, as `deliver` takes them: the pane by its
/// exact key on its server, the harness and the identity holding the pane,
/// and the home, directory and id its session file is found by.
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
/// harness's default home (as `effects::launch` reads them; Pi's account is
/// a provider seat, not its home). A lane with no harness, pane, server or
/// directory is nobody to type into. Nor is a lane whose record names
/// another host: its session runs there, the pane here holds the client,
/// and no file here confirms its turn. Nor is a lane that is not running:
/// it is relaunched, never woken, and the mail duty's unread row for it
/// stands until that duty's next turn.
fn lane_target(lane: &Lane, socket: &Path) -> Option<Target> {
    if lane.status != LaneStatus::Running || lane.host.as_deref().is_some_and(|h| h != "local") {
        return None;
    }
    let harness = Harness::parse(lane.harness.as_deref()?)?;
    let launch = lane.launch.as_ref()?;
    let identity = match (launch.pid, &launch.start) {
        (Some(pid), Some(start)) => Some((pid, start.clone())),
        (None, _) | (Some(_), None) => None,
    };
    let home = match harness {
        Harness::Pi => None,
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
    };
    Box::new(move |tick: &Tick| wake.run(tick))
}

struct Wake {
    fleet: PathBuf,
    /// The watch's wake record, [`record_path`] of `fleet`.
    record: PathBuf,
    settings: Settings,
}

impl Wake {
    #[allow(
        clippy::disallowed_methods,
        reason = "the wake's one construction of the kernel host, for the read of a print-mode turn a lane record names before anything is typed; the read acts on nothing"
    )]
    fn run(&self, tick: &Tick) -> Result<Produced> {
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
        let socket = match fleet.overseer.as_ref().and_then(overseer_socket) {
            Some(socket) => socket,
            None => crate::effects::fleet_reach(&self.settings)?
                .socket()?
                .to_path_buf(),
        };
        let host = crate::ops::Host::kernel();
        // A resume goes first: its line runs the inbox read too, so the
        // unread state it types for stands marked when the mail is served.
        for (name, row) in resumes {
            let Some(resume) = Resume::of(&row) else {
                continue;
            };
            let Some(lane) = fleet
                .lanes
                .iter()
                .find(|l| super::lanes::lane_name(l) == name)
                .filter(|l| resumable(l) && !crate::ops::wake::turn_runs(l, &host))
            else {
                continue;
            };
            let Some(target) = lane_target(lane, &socket) else {
                continue;
            };
            let marked = record.get(&target.name);
            if marked.and_then(|m| m.resume.as_deref()) == Some(row.as_str()) {
                continue;
            }
            // The local listing: the wake types into local lanes alone.
            let room = crate::effects::account_room(
                &self.settings,
                &self.fleet,
                "local",
                lane,
                Some(target.harness),
                tick.wall,
            );
            if room != "room" {
                continue;
            }
            let state = unread
                .iter()
                .find(|(t, _)| *t == target.name)
                .map(|(_, s)| s.clone())
                .or_else(|| marked.map(|m| m.unread.clone()))
                .unwrap_or_default();
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
                fleet.lanes.iter().find(|l| l.item == name).and_then(|l| {
                    lane_target(l, &socket).filter(|_| !crate::ops::wake::turn_runs(l, &host))
                })
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
        let name = target.name.clone();
        if let Some(mark) = record.get(&name)
            && mark.stands_for(unread, &target.pane, target.server)
        {
            let mut mark = mark.clone();
            match &mark.outcome {
                Some(WakeOutcome::Delivered { .. }) => return Ok(()),
                // A limit stands as read: the pane is not read again for
                // it, and the owner's turn is all that is left.
                Some(WakeOutcome::Limit { .. }) => return self.owner_turn(target, mark, record),
                None | Some(WakeOutcome::Unconfirmed { .. }) => {}
            }
            // The paste may have gone in: the file alone says whether the
            // turn arrived, and nothing is typed again for this state.
            match self.read(target, false)? {
                Read::Idle { turns } if turns > mark.turns_before => {
                    mark.outcome = Some(WakeOutcome::Delivered { turns_after: turns });
                    // Woken after all: nothing is owed to the owner.
                    mark.owner = None;
                    self.write(record, &name, Some(mark))?;
                    produced.events.push(Event::WakeDelivered {
                        target: name,
                        resume: None,
                    });
                    Ok(())
                }
                // Still idle and unwoken: the owner's turn.
                Read::Idle { .. } => self.owner_turn(target, mark, record),
                // Not idle, or the pane gone or unreadable: the reading the
                // alert would stand on is not there this pass.
                Read::Refused => Ok(()),
                Read::Limit { harness, cause } => {
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
                        resume: None,
                    });
                    Ok(())
                }
            }
        } else {
            self.first_pass(target, unread, None, now, record, produced)
        }
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
        let text = alert_text(&target.pane, &mark.unread, &said);
        match owner_alert::send(&self.settings, ALERT_FILE, &text) {
            Ok(()) => {
                mark.owner = Some(Word::Alerted);
                let fields = format!("pane={} unread={}", target.pane, mark.unread);
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
    /// outcome and the owner's word written with the mark. A resume reads
    /// the pane past its usage banner, types its sentence before the inbox
    /// line and says `resume=` on its line, with no `idle-unread`; every
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
        let mut mark = WakeMark {
            pane: target.pane.clone(),
            server: target.server,
            server_start: target.server_start,
            unread: unread.to_owned(),
            turns_before: 0,
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
        let room = resume.is_some();
        let events = match self.read(target, room)? {
            Read::Refused => return Ok(()),
            Read::Limit { harness, cause } => limit(&mut mark, harness, cause),
            Read::Idle { turns } => {
                mark.turns_before = turns;
                // The mark is on disk before anything is typed.
                self.write(record, &name, Some(mark.clone()))?;
                let line = resume.map_or_else(|| line_for(&name), |r| r.line(&name));
                match self.paste(target, &line, turns, room)? {
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
                        self.write(record, &name, standing)?;
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

    /// Type `line` into the target through `deliver`, confirmed by a user
    /// turn beyond `turns_before`; `room` as [`Wake::read`] takes it.
    fn paste(&self, target: &Target, line: &str, turns_before: u64, room: bool) -> Result<Paste> {
        let mut args = self.target_args(target, room)?;
        args.extend([
            "--turns-before".to_owned(),
            turns_before.to_string(),
            "--line".to_owned(),
            line.to_owned(),
        ]);
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
                Some(_) | None => Err(protocol_error("not a paste", &result)),
            },
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
            "--bound-secs".to_owned(),
            self.settings.engine.verify.get()?.as_secs().to_string(),
        ];
        if let Some(start) = target.server_start {
            args.extend(["--server-start".to_owned(), start.to_string()]);
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

    /// One run of agent-runtime's `deliver`, its reply read whole: a result,
    /// or the refusal's key. No reply is the program failing, not a reading
    /// of the pane.
    #[allow(
        clippy::disallowed_methods,
        reason = "the wake acts only through agent-runtime's own `deliver` verb, run by the one runner under the `wake` tag, and records its mark before it types"
    )]
    fn call(&self, args: &[String]) -> Result<Answer> {
        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        let output = host::run_tagged(
            "wake",
            "agent-runtime",
            &self.settings.agent_runtime,
            "deliver",
            &args,
            self.settings.engine.verify.get()? + ANSWER_MARGIN,
        )?;
        // agent-runtime unbuilt under a running watch: the pass fails with
        // the cause the watch's admission gives the same state, which names
        // orch's setup.
        if crate::ready::setup_required(output.status.code()) {
            return Err(crate::ready::unbuilt(
                crate::ready::Duty::Watch,
                "agent-runtime",
                &self.settings,
            )
            .refusal());
        }
        let reply: Value = serde_json::from_slice(&output.stdout).map_err(|_| {
            Error::Runtime(agent_runtime::Error::External {
                program: "agent-runtime",
                operation: "deliver",
                cause: format!(
                    "no reply (exit {:?}): {}",
                    output.status.code(),
                    host::stderr_text(&output)
                ),
            })
        })?;
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
fn load_record(path: &Path) -> Result<WakeRecord> {
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
