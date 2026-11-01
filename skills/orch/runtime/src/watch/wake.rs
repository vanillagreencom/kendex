//! The wake duty (step5-map § A9, § B rows 3, 7, 8; decisions 60, 61, 65,
//! 99, 118 (2), 121 Q6, 135a): a lead or lane the mail duty reports unread
//! mail for is read positively idle, by identity and markers, and typed one
//! line, confirmed by a new user turn in that session's own bound file,
//! never a neighbour's and never the newest file; a harness with no
//! confirmable route gets its limit reported. The duty acts only through
//! agent-runtime's `deliver` verb, run by the one runner under the `wake`
//! tag, and records its mark in the watch's own record (`ops::wake`,
//! decision 159), durably, before it types, so a crash between the mark and
//! the paste never repeats a nudge for the same unread state; a later
//! unread state is a new wake. The record is read at the start of each
//! pass: nothing the fleet record's writers do (the legacy `open-terminal
//! --wake` rewrites a lane's `wake` object) moves a mark.
//!
//! Slot: the mail duty sets a baseline row of kind [`UNREAD_KIND`], its
//! identity the target (an item key, or [`OVERSEER_TARGET`]), its value the
//! unread state it announced (the newest unread envelope's id or index),
//! while the target's box holds mail the target has not read, and clears
//! the row once read. The wake reads that row from its tick's snapshot and
//! writes no row of its own.
//!
//! Codex (decisions 94, 121 Q6): a Codex lane keeps the legacy
//! `open-terminal --wake` route until the paste route is proved on a real
//! Codex (the step-9 native case); the duty reads it idle, reports
//! `wake-limit` and types nothing, so no resumed execution of live history
//! is ever started here. The duty starts no detached process: nothing new
//! charges the lane cap.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::harness::Harness;
use agent_runtime::host;
use agent_runtime::host::tmux;
use serde_json::Value;

use super::{Body, Event, Produced, Runner, Tick};
use crate::error::{Error, Result, WatchError};
pub use crate::ops::wake::OVERSEER_TARGET;
use crate::ops::wake::{WakeMark, WakeOutcome, WakeRecord};
use crate::schedule::Duty;
use crate::settings::Settings;
use crate::state::{self, FleetState, Lane, Overseer, Record};

/// The baseline row kind the mail duty signals unread mail with.
pub const UNREAD_KIND: &str = "unread";
/// The watch's wake record, beside the fleet state: it shares the runner's
/// own records' stem, which the retention duty never judges.
pub const WAKE_FILE: &str = "oversee-watch.wake.json";
/// What the verb may take past its own bound to read the pane and answer.
const ANSWER_MARGIN: Duration = Duration::from_secs(15);

/// The wake record's path for the fleet state at `fleet`.
pub fn record_path(fleet: &Path) -> PathBuf {
    fleet.parent().unwrap_or(Path::new(".")).join(WAKE_FILE)
}

/// The one line typed: the legacy `open-terminal --wake` line, which runs
/// the target's inbox read.
fn line_for(target: &str) -> String {
    format!(
        "Run .agents/skills/mailbox/scripts/lane-mail inbox --item {target} and act on every envelope it prints, answers and directives alike, as its text directs."
    )
}

/// The capability limit a harness has for a positively idle paste, where
/// it has one: Codex's print-mode resume refuses while its process runs
/// and its paste route is unproved (decision 121 Q6), so an idle Codex
/// session is reported and never typed into.
fn route_limit(harness: Harness) -> Option<&'static str> {
    match harness {
        Harness::Codex => Some("process-running"),
        Harness::Claude | Harness::Copilot | Harness::Pi => None,
    }
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

/// The socket the overseer record names, where it names one.
fn overseer_socket(overseer: &Overseer) -> Option<PathBuf> {
    overseer
        .extra
        .get("server_socket")
        .and_then(Value::as_str)
        .map(PathBuf::from)
}

/// A lane as a target: its launch pane on the fleet server, its recorded
/// harness identity, and its session under the account home, else the
/// harness's default home (as `effects::launch` reads them; Pi's account is
/// a provider seat, not its home). A lane with no harness, pane, server or
/// directory is nobody to type into.
fn lane_target(lane: &Lane, socket: &Path) -> Option<Target> {
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
/// identity, home and directory, as the legacy launchers wrote them.
fn overseer_target(overseer: &Overseer) -> Option<Target> {
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
        socket: overseer_socket(overseer).unwrap_or_else(tmux::ambient_socket),
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
    /// gone or unreadable.
    Refused,
}

/// The refusals that are a reading of the pane, which the duty leaves for
/// its next pass; any other refusal is the call itself failing.
const PANE_REFUSALS: [&str; 3] = ["deliver-refused", "pane-gone", "pane-unreadable"];

/// Register the wake duty on `runner` for the fleet state at `fleet`, as
/// `watch run` registers every duty (decision 153). The duty writes no
/// fleet record: its mark is the runner-private record beside the fleet
/// state (decision 159).
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
    fn run(&self, tick: &Tick) -> Result<Produced> {
        let mut produced = Produced::default();
        let unread: Vec<(String, String)> = tick
            .baseline
            .rows
            .iter()
            .filter(|r| r.kind == UNREAD_KIND)
            .map(|r| (r.identity.clone(), r.value.clone()))
            .collect();
        if unread.is_empty() {
            return Ok(produced);
        }
        // The marks as the record holds them at the start of this pass:
        // nothing is carried in memory between passes.
        let mut record = load_record(&self.record)?;
        let Some(fleet) = load_fleet(&self.fleet)? else {
            return Ok(produced);
        };
        let socket = fleet
            .overseer
            .as_ref()
            .and_then(overseer_socket)
            .unwrap_or_else(tmux::ambient_socket);
        for (name, state) in unread {
            let target = if name == OVERSEER_TARGET {
                fleet.overseer.as_ref().and_then(overseer_target)
            } else {
                fleet
                    .lanes
                    .iter()
                    .find(|l| l.item == name)
                    .and_then(|l| lane_target(l, &socket))
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
    /// is re-read and never typed for again; a new state is read idle,
    /// marked, typed and confirmed.
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
                Some(WakeOutcome::Delivered { .. } | WakeOutcome::Limit { .. }) => return Ok(()),
                None | Some(WakeOutcome::Unconfirmed { .. }) => {}
            }
            // The paste may have gone in: the file alone says whether the
            // turn arrived, and nothing is typed again for this state.
            match self.read(target)? {
                Read::Idle { turns } if turns > mark.turns_before => {
                    mark.outcome = Some(WakeOutcome::Delivered { turns_after: turns });
                    self.write(record, &name, Some(mark))?;
                    produced.events.push(Event::WakeDelivered { target: name });
                }
                Read::Idle { .. } | Read::Refused => {}
                Read::Limit { harness, cause } => {
                    mark.outcome = Some(WakeOutcome::Limit {
                        harness: harness.clone(),
                        cause: cause.clone(),
                    });
                    self.write(record, &name, Some(mark))?;
                    produced.events.push(Event::WakeLimit {
                        target: name,
                        harness,
                        cause,
                    });
                }
            }
            return Ok(());
        }
        let mut mark = WakeMark {
            pane: target.pane.clone(),
            server: target.server,
            server_start: target.server_start,
            unread: unread.to_owned(),
            turns_before: 0,
            at: now,
            outcome: None,
        };
        let limit = |mark: &mut WakeMark, harness: String, cause: String| {
            mark.outcome = Some(WakeOutcome::Limit {
                harness: harness.clone(),
                cause: cause.clone(),
            });
            vec![
                Event::IdleUnread { lane: name.clone() },
                Event::WakeLimit {
                    target: name.clone(),
                    harness,
                    cause,
                },
            ]
        };
        let events = match self.read(target)? {
            Read::Refused => return Ok(()),
            Read::Limit { harness, cause } => limit(&mut mark, harness, cause),
            Read::Idle { turns } => match route_limit(target.harness) {
                Some(cause) => limit(
                    &mut mark,
                    target.harness.name().to_owned(),
                    cause.to_owned(),
                ),
                None => {
                    mark.turns_before = turns;
                    // The mark is on disk before anything is typed.
                    self.write(record, &name, Some(mark.clone()))?;
                    match self.paste(target, &line_for(&name), turns)? {
                        Paste::Confirmed { turns_after } => {
                            mark.outcome = Some(WakeOutcome::Delivered { turns_after });
                            vec![
                                Event::IdleUnread { lane: name.clone() },
                                Event::WakeDelivered {
                                    target: name.clone(),
                                },
                            ]
                        }
                        Paste::Unconfirmed { cause } => {
                            mark.outcome = Some(WakeOutcome::Unconfirmed {
                                cause: cause.clone(),
                            });
                            vec![
                                Event::IdleUnread { lane: name.clone() },
                                Event::WakeUnconfirmed {
                                    target: name.clone(),
                                    cause,
                                },
                            ]
                        }
                        Paste::Refused => {
                            // Nothing was typed: the mark it was written
                            // for stands for nothing.
                            self.write(record, &name, None)?;
                            return Ok(());
                        }
                    }
                }
            },
        };
        self.write(record, &name, Some(mark))?;
        produced.events.extend(events);
        Ok(())
    }

    /// Read the target through `deliver --no-paste`.
    fn read(&self, target: &Target) -> Result<Read> {
        let mut args = self.target_args(target);
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
    /// turn beyond `turns_before`.
    fn paste(&self, target: &Target, line: &str, turns_before: u64) -> Result<Paste> {
        let mut args = self.target_args(target);
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

    fn target_args(&self, target: &Target) -> Vec<String> {
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
            self.settings.verify.as_secs().to_string(),
        ];
        if let Some(start) = target.server_start {
            args.extend(["--server-start".to_owned(), start.to_string()]);
        }
        if let Some(program) = self.settings.harness_binaries.get(&target.harness) {
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
        args
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
            self.settings.verify + ANSWER_MARGIN,
        )?;
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
