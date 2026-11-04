//! The `agent-runtime` command: the versioned boundary other languages and
//! hosts speak to the library through. Every verb prints one JSON reply on
//! stdout; a refusal also prints one keyed line on stderr and exits 1. A
//! usage error prints `agent-runtime: usage` and clap's message on stderr
//! and exits 2, clap's own convention, with no reply: there was no request
//! to answer.

// Every reading, close and stop outcome is matched variant by variant.
#![deny(clippy::wildcard_enum_match_arm)]

use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use clap::error::ErrorKind;
use clap::{Parser, Subcommand};
use serde::{Deserialize, Serialize};
use serde_json::Map;

use agent_runtime::clock;
use agent_runtime::error::{Error, Result};
use agent_runtime::harness::{self, Harness};
use agent_runtime::host::tmux::{self, Close, PaneFields};
use agent_runtime::launch::{self, LaunchIntent};
use agent_runtime::observe::{self, ProcessReading, State};
use agent_runtime::process::{self, Identity};
use agent_runtime::protocol::{self, Outcome, Reply};
use agent_runtime::reading::{Reading, Unreadable};
use agent_runtime::record::{self, Expect};
use agent_runtime::session;

const RECORD_VERSION: u64 = 1;
const RECORD_VERSIONS: &[u64] = &[1];

#[derive(Parser)]
#[command(
    name = "agent-runtime",
    version,
    about = "Launch, observe, deliver to and stop one coding-harness session"
)]
struct Cli {
    #[command(subcommand)]
    verb: Verb,
}

#[derive(Subcommand)]
#[allow(
    clippy::large_enum_variant,
    reason = "the parsed command line, built once; `deliver` names a session by its facts in place of a record"
)]
enum Verb {
    /// Print the protocol and crate version.
    Version,
    /// Ask each installed harness its version.
    Probe {
        #[arg(long)]
        harness: Option<String>,
    },
    /// Open a tmux window on the named socket and session, start the
    /// harness the intent file describes in it, and write the launch record.
    Launch {
        #[arg(long)]
        intent: PathBuf,
        #[arg(long)]
        record: PathBuf,
        /// The tmux socket; the caller's own, or the default, when omitted.
        #[arg(long)]
        socket: Option<PathBuf>,
        #[arg(long)]
        session: String,
        #[arg(long)]
        window_name: String,
    },
    /// Read the recorded session: pane, process, native identity, state.
    Inspect {
        #[arg(long)]
        record: PathBuf,
    },
    /// Type text into the session's pane, only when the session is
    /// positively idle, and confirm it by a user turn the harness wrote to
    /// its own session file. The session is a launch record, or its facts
    /// on the line (`--harness` with the pane, the server and the session).
    Deliver {
        #[arg(long, conflicts_with = "harness")]
        record: Option<PathBuf>,
        /// The text to type, from a file.
        #[arg(long, conflicts_with = "line")]
        file: Option<PathBuf>,
        /// The text to type, as given.
        #[arg(long)]
        line: Option<String>,
        /// Deliver whatever the screen says; for a probe that knows better.
        #[arg(long)]
        force: bool,
        /// The session's harness, with the facts below in place of a record.
        #[arg(long, requires_all = ["socket", "server_pid", "pane", "cwd"])]
        harness: Option<String>,
        /// The harness executable, where it runs from a configured path.
        #[arg(long)]
        program: Option<PathBuf>,
        /// The tmux socket and server pid the pane sits on, and the server's
        /// start where the caller recorded one; without it the server at
        /// the socket stands for the pid alone.
        #[arg(long)]
        socket: Option<PathBuf>,
        #[arg(long)]
        server_pid: Option<u32>,
        #[arg(long)]
        server_start: Option<u64>,
        #[arg(long)]
        pane: Option<String>,
        /// The harness process the session runs as; only that identity is
        /// the harness.
        #[arg(long, requires = "start")]
        pid: Option<u32>,
        #[arg(long)]
        start: Option<String>,
        /// The account home the session file is read under; the harness's
        /// default home when omitted.
        #[arg(long)]
        home: Option<PathBuf>,
        #[arg(long)]
        cwd: Option<PathBuf>,
        /// The session id the file is named by; without one no delivery is
        /// confirmable, which the reply says as its limit.
        #[arg(long)]
        session_id: Option<String>,
        /// The file's user-turn count before the paste, as an earlier
        /// `--no-paste` read it; read now when omitted. The delivery is
        /// confirmed by a turn beyond it.
        #[arg(long)]
        turns_before: Option<u64>,
        /// Read the state and the turn count alone: nothing is typed.
        #[arg(long)]
        no_paste: bool,
        /// How long the confirming turn is waited for after the paste.
        #[arg(long, default_value_t = 15)]
        bound_secs: u64,
    },
    /// End the recorded harness exactly, then close its window.
    Stop {
        #[arg(long)]
        record: PathBuf,
        #[arg(long, default_value_t = 10)]
        grace_secs: u64,
    },
    /// Judge a captured screen held in a file (fixtures and probes), drawn
    /// by the named harness. The screen alone is judged: `--process` is the
    /// caller's own reading of the pane (`harness-up` asserts the harness
    /// holds it), which a live `inspect` reads from the pane's foreground
    /// process instead.
    Judge {
        #[arg(long)]
        screen: PathBuf,
        #[arg(long)]
        harness: String,
        #[arg(long, default_value = "harness-up")]
        process: String,
    },
    /// Process identity operations.
    Process {
        #[command(subcommand)]
        op: ProcessOp,
    },
}

#[derive(Subcommand)]
enum ProcessOp {
    /// The identity of a live pid.
    Identity { pid: u32 },
    /// Whether an identity still runs.
    Live { pid: u32, start: String },
}

/// What a launch records: the pane, the command, and the identities read
/// so far. Written at launch and healed by `inspect` as the harness comes up.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct LaunchRecord {
    harness: Harness,
    intent: LaunchIntent,
    command_line: String,
    pane: tmux::Pane,
    launched_at: String,
    /// The harness process holding the pane, read once it is up and the
    /// only process a later read confirms.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    harness_process: Option<Identity>,
    /// The native session the harness recorded for the cwd, bound once it
    /// is up: by the id the launch fixed, else as the one lead session for
    /// the cwd that appeared after the window opened and stood in no
    /// `baseline`. Never the newest file by its age.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    native_session: Option<session::SessionRef>,
    /// The lead session ids for the cwd under the launch's home before the
    /// window opened, the floor `native_session` is bound above for a
    /// harness whose launch fixes no id. Three-valued:
    /// absent where no baseline was read (the launch fixed an id, named no
    /// home, or the record predates the field), when nothing binds by
    /// appearance; present and empty where the store held no lead for the
    /// cwd, when exactly one appeared lead binds; present and filled as
    /// read.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    baseline: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    stopped: Option<StopRecord>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct StopRecord {
    at: String,
    outcome: process::Stop,
    window: Close,
}

/// What `inspect` read: the pane by its exact id, the recorded harness and
/// whether it still runs, the native session and the judged state. Each
/// read is three-valued; an unreadable pane or process is
/// printed as such, never as absent.
#[derive(Debug, Serialize)]
struct Inspection {
    pane: Reading<PaneFields>,
    harness_process: Option<Identity>,
    harness_live: Option<Reading<Identity>>,
    native_session: Option<session::SessionRef>,
    /// Why `native_session` is null though the store was asked: the cause
    /// word of the read that failed. Absent when the store was read whole,
    /// or not asked.
    #[serde(skip_serializing_if = "Option::is_none")]
    native_session_unreadable: Option<&'static str>,
    state: State,
    screen_tail: Vec<String>,
}

fn read_record(path: &Path) -> Result<(LaunchRecord, u64, Map<String, serde_json::Value>)> {
    let loaded = record::read::<LaunchRecord>(path, RECORD_VERSIONS)?.ok_or_else(|| {
        Error::refused("record-missing", &[("path", &path.display().to_string())])
    })?;
    Ok((loaded.body, loaded.revision, loaded.extra))
}

/// The harness's process names for this record: its own, and the configured
/// program's where the intent names one.
fn owns(rec: &LaunchRecord) -> impl Fn(&str) -> bool + '_ {
    move |name| {
        rec.harness
            .owns_process_of(rec.intent.program.as_deref(), name)
    }
}

/// The harness holding the pane with no identity recorded: the nearest
/// harness-named process under the pane's own, by one table read. `Gone`
/// when no harness process runs under the pane.
fn harness_identity(rec: &LaunchRecord) -> Reading<Identity> {
    let fields = match tmux::pane_fields(&rec.pane.server, &rec.pane.id) {
        Reading::Live(fields) => fields,
        Reading::Gone => return Reading::Gone,
        Reading::Unreadable { cause } => return Reading::Unreadable { cause },
    };
    let rows = match process::table() {
        Ok(rows) => rows,
        Err(Unreadable { cause }) => return Reading::Unreadable { cause },
    };
    let below = process::below(&rows, fields.pid, &owns(rec));
    let Some((_, pid)) = below.first() else {
        return Reading::Gone;
    };
    process::identity(*pid)
}

/// The inspection of a pane that was not read live: nothing of it judged.
fn unjudged(rec: &LaunchRecord, pane: Reading<PaneFields>, cause: &str) -> Inspection {
    Inspection {
        pane,
        harness_process: rec.harness_process.clone(),
        harness_live: None,
        native_session: rec.native_session.clone(),
        native_session_unreadable: None,
        state: State::Unjudged {
            cause: cause.to_owned(),
        },
        screen_tail: Vec::new(),
    }
}

/// What the store answered when the record's native session was asked for.
enum Binding {
    Bound(session::SessionRef),
    /// Nothing binds yet: the fixed id's file is not written, no lead or
    /// several appeared, or no baseline was read to bind above.
    Unbound,
    /// A read failed; nothing is bound over an unread store.
    Unreadable(&'static str),
}

/// The record's native session, bound by its fixed id where the launch
/// fixed one (the file that id names under `home`, once written), else as
/// the one lead for the cwd that appeared at or after the launch and stood
/// in no baseline. None or several bind nothing; a record that predates
/// the baseline and fixed no id binds nothing either, since nothing tells
/// its session from a neighbour's.
fn bound_session(rec: &LaunchRecord, home: &Path) -> Binding {
    if let Some(id) = &rec.intent.session_id {
        let Some(file) = session::fixed_file(rec.harness, home, &rec.intent.cwd, id) else {
            return Binding::Unbound;
        };
        match std::fs::metadata(&file) {
            Ok(meta) if meta.is_file() => {}
            Ok(_) => return Binding::Unbound,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Binding::Unbound,
            Err(_) => return Binding::Unreadable("session-file-unreadable"),
        }
        return match session::identify(rec.harness, &file, Some(&rec.intent.cwd)) {
            Ok(Some(found)) => Binding::Bound(found),
            Ok(None) => Binding::Unbound,
            Err(_) => Binding::Unreadable("session-file-unreadable"),
        };
    }
    // A record with no baseline read binds nothing by appearance: nothing
    // tells its session from a neighbour's. An empty baseline
    // was read, and the one lead that appeared over it is the launch's.
    let Some(baseline) = &rec.baseline else {
        return Binding::Unbound;
    };
    let Some(since) = clock::epoch_secs(&rec.launched_at) else {
        return Binding::Unbound;
    };
    let since = std::time::UNIX_EPOCH + std::time::Duration::from_secs(since);
    match session::new_leads(rec.harness, home, &rec.intent.cwd, since, baseline) {
        Reading::Live(mut appeared) => match appeared.len() {
            1 => Binding::Bound(appeared.remove(0)),
            _ => Binding::Unbound,
        },
        Reading::Gone => Binding::Unbound,
        Reading::Unreadable { cause } => Binding::Unreadable(cause),
    }
}

/// A pane read and its screen judged once: the pane by its exact id, who
/// holds its terminal against the recorded identity, and the state.
struct Judged {
    pane: Reading<PaneFields>,
    /// Who holds the terminal; none when the pane was not read live.
    reading: Option<ProcessReading>,
    state: State,
    screen_tail: Vec<String>,
}

/// Read `pane` and judge its screen for `harness`. Who holds the pane's
/// terminal is read against `recorded` where the caller has one: that
/// identity alone is the harness, and an ended one is read as other, never
/// replaced. With none, the harness-named process now in the
/// foreground is read, for the caller to record.
fn judge_pane(
    harness: Harness,
    owns: &dyn Fn(&str) -> bool,
    pane: &tmux::Pane,
    recorded: Option<&Identity>,
) -> Result<Judged> {
    let fields = match tmux::pane_fields(&pane.server, &pane.id) {
        Reading::Live(fields) => fields,
        Reading::Gone => {
            return Ok(Judged {
                pane: Reading::Gone,
                reading: None,
                state: State::Unjudged {
                    cause: "pane-gone".to_owned(),
                },
                screen_tail: Vec::new(),
            });
        }
        Reading::Unreadable { cause } => {
            return Ok(Judged {
                pane: Reading::Unreadable { cause },
                reading: None,
                state: State::Unjudged {
                    cause: "pane-unreadable".to_owned(),
                },
                screen_tail: Vec::new(),
            });
        }
    };
    let reading = observe::foreground(fields.pid, owns, recorded);
    let screen = tmux::capture(pane)?;
    let state = observe::judge(&screen, harness, &reading, None);
    let screen_tail: Vec<String> = screen
        .lines()
        .rev()
        .filter(|l| !l.trim().is_empty())
        .take(12)
        .map(str::to_owned)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();
    Ok(Judged {
        pane: Reading::Live(fields),
        reading: Some(reading),
        state,
        screen_tail,
    })
}

fn inspect(rec: &mut LaunchRecord) -> Result<Inspection> {
    let judged = judge_pane(
        rec.harness,
        &owns(rec),
        &rec.pane,
        rec.harness_process.as_ref(),
    )?;
    let fields = match judged.pane {
        Reading::Live(fields) => fields,
        Reading::Gone => return Ok(unjudged(rec, Reading::Gone, "pane-gone")),
        Reading::Unreadable { cause } => {
            return Ok(unjudged(
                rec,
                Reading::Unreadable { cause },
                "pane-unreadable",
            ));
        }
    };
    if let Some(ProcessReading::Harness { identity }) = &judged.reading
        && rec.harness_process.is_none()
    {
        rec.harness_process = Some(identity.clone());
    }
    let harness_live = rec.harness_process.as_ref().map(process::still_runs);
    let mut native_session_unreadable = None;
    if rec.native_session.is_none() {
        let home = rec
            .intent
            .home
            .clone()
            .or_else(|| session::default_home(rec.harness));
        if let Some(home) = home {
            match bound_session(rec, &home) {
                Binding::Bound(found) => rec.native_session = Some(found),
                Binding::Unbound => {}
                Binding::Unreadable(cause) => native_session_unreadable = Some(cause),
            }
        }
    }
    Ok(Inspection {
        pane: Reading::Live(fields),
        harness_process: rec.harness_process.clone(),
        harness_live,
        native_session: rec.native_session.clone(),
        native_session_unreadable,
        state: judged.state,
        screen_tail: judged.screen_tail,
    })
}

/// What a delivery is confirmed by: the session file bound once (a launch
/// record's), or the id the file is found by, or nothing,
/// which no paste can be confirmed against.
enum SessionFile {
    Bound(PathBuf),
    ById {
        home: Option<PathBuf>,
        cwd: PathBuf,
        id: String,
    },
    Unbound,
}

/// The session `deliver` types into: its pane, the harness and the identity
/// holding it, and the file its turn is confirmed in.
struct Session {
    harness: Harness,
    program: Option<PathBuf>,
    pane: tmux::Pane,
    recorded: Option<Identity>,
    file: SessionFile,
}

/// The session a launch record names, inspected once and healed as
/// `inspect` heals it, with the pane judged by that same read.
fn recorded_session(path: &Path) -> Result<(Session, Judged)> {
    let (mut rec, revision, extra) = read_record(path)?;
    let inspection = inspect(&mut rec)?;
    record::write(
        path,
        RECORD_VERSION,
        &rec,
        &extra,
        Expect::Revision(revision),
    )?;
    let judged = Judged {
        pane: inspection.pane,
        reading: None,
        state: inspection.state,
        screen_tail: inspection.screen_tail,
    };
    let file = match rec.native_session {
        Some(bound) => SessionFile::Bound(bound.file),
        None => SessionFile::Unbound,
    };
    Ok((
        Session {
            harness: rec.harness,
            program: rec.intent.program,
            pane: rec.pane,
            recorded: rec.harness_process,
            file,
        },
        judged,
    ))
}

/// How a delivery ended. A paste alone settles nothing: `confirmed` is a
/// user turn the harness wrote to the session's own file after the paste,
/// `unconfirmed` the bound passed with no such turn, `limit` a session with
/// no confirmable route, into which nothing is typed.
#[derive(Debug, Serialize)]
#[serde(tag = "delivery", rename_all = "kebab-case")]
enum Delivery {
    /// `--no-paste`: the state read and the bound file's turn count.
    Read {
        state: State,
        file: PathBuf,
        turns: u64,
    },
    Confirmed {
        outcome: Outcome,
        route: &'static str,
        pane: String,
        bytes: usize,
        file: PathBuf,
        turns_before: u64,
        turns_after: u64,
    },
    Unconfirmed {
        outcome: Outcome,
        cause: &'static str,
        pane: String,
        file: PathBuf,
        turns_before: u64,
    },
    Limit {
        harness: Harness,
        cause: &'static str,
    },
}

/// How often the session file is read for the confirming turn.
const TURN_POLL: Duration = Duration::from_millis(250);

/// Type `text` into the session's pane when `judged` read it idle, and
/// confirm the delivery by a user turn in its own file within `bound`.
/// `None` text reads the state and the turn count alone. `turns_before` is
/// the count an earlier read gave, else the file is counted now, before
/// the paste.
fn deliver(
    session: &Session,
    judged: Judged,
    text: Option<&str>,
    force: bool,
    turns_before: Option<u64>,
    bound: Duration,
) -> Result<Delivery> {
    let pane_id = session.pane.id.as_str();
    match &judged.pane {
        Reading::Live(_) => {}
        Reading::Gone => return Err(Error::refused("pane-gone", &[("pane", pane_id)])),
        Reading::Unreadable { cause } => {
            return Err(Error::refused(
                "pane-unreadable",
                &[("pane", pane_id), ("cause", cause)],
            ));
        }
    }
    if !force && judged.state != State::Idle {
        let word = serde_json::to_value(&judged.state)
            .ok()
            .and_then(|v| v.get("state").and_then(|s| s.as_str()).map(str::to_owned))
            .unwrap_or_else(|| "unjudged".to_owned());
        return Err(Error::refused(
            "deliver-refused",
            &[("pane", pane_id), ("state", &word)],
        ));
    }
    let harness = session.harness;
    let file = match &session.file {
        SessionFile::Bound(path) => path.clone(),
        SessionFile::Unbound => {
            return Ok(Delivery::Limit {
                harness,
                cause: "session-unbound",
            });
        }
        SessionFile::ById { home, cwd, id } => {
            let Some(home) = home else {
                return Ok(Delivery::Limit {
                    harness,
                    cause: "home-unknown",
                });
            };
            match session::fixed_id_file(harness, home, cwd, id) {
                Reading::Live(path) => path,
                // Not written yet: a harness whose fixed id names the path
                // writes it with the first turn, which is the turn awaited;
                // one that names no path has no file to confirm in.
                Reading::Gone => match session::fixed_file(harness, home, cwd, id) {
                    Some(path) => path,
                    None => {
                        return Ok(Delivery::Limit {
                            harness,
                            cause: "session-file-absent",
                        });
                    }
                },
                Reading::Unreadable { cause } => {
                    return Err(Error::refused(
                        "session-store-unreadable",
                        &[("home", &home.display().to_string()), ("cause", cause)],
                    ));
                }
            }
        }
    };
    let before = match turns_before {
        Some(n) => n,
        None => session::user_turns(harness, &file)? as u64,
    };
    let Some(text) = text else {
        return Ok(Delivery::Read {
            state: judged.state,
            file,
            turns: before,
        });
    };
    let text = text.trim_end_matches('\n');
    // A line that never reached the pane is refused as unsent, so the
    // caller may type it again; a paste asked and not answered may stand in
    // the pane, and only its turn says whether it went in.
    let loaded = tmux::load_line(&session.pane, text)
        .map_err(|e| Error::refused("paste-unsent", &[("cause", e.key())]))?;
    let pasted = loaded.paste();
    let deadline = Instant::now() + bound;
    let unconfirmed = |cause: &'static str| Delivery::Unconfirmed {
        outcome: Outcome::Unconfirmed,
        cause,
        pane: pane_id.to_owned(),
        file: file.clone(),
        turns_before: before,
    };
    if pasted.is_err() {
        return Ok(unconfirmed("paste-unanswered"));
    }
    loop {
        let after = session::user_turns(harness, &file)? as u64;
        if after > before {
            return Ok(Delivery::Confirmed {
                outcome: Outcome::Confirmed,
                route: "pane-paste",
                pane: pane_id.to_owned(),
                bytes: text.len(),
                file,
                turns_before: before,
                turns_after: after,
            });
        }
        match tmux::pane_fields(&session.pane.server, pane_id) {
            Reading::Live(_) => {}
            Reading::Gone => return Ok(unconfirmed("pane-gone")),
            Reading::Unreadable { .. } => return Ok(unconfirmed("pane-unreadable")),
        }
        if Instant::now() >= deadline {
            return Ok(unconfirmed("turn-pending"));
        }
        std::thread::sleep(TURN_POLL);
    }
}

fn run(cli: Cli) -> Result<serde_json::Value> {
    match cli.verb {
        Verb::Version => Ok(serde_json::json!({
            "protocol": protocol::PROTOCOL,
            "crate": env!("CARGO_PKG_VERSION"),
        })),
        Verb::Probe { harness: name } => {
            let targets: Vec<Harness> = match name {
                Some(n) => vec![
                    Harness::parse(&n)
                        .ok_or_else(|| Error::refused("harness-unknown", &[("harness", &n)]))?,
                ],
                None => Harness::ALL.to_vec(),
            };
            let mut rows = Vec::new();
            for h in targets {
                match harness::probe(h) {
                    Ok(installed) => rows.push(serde_json::to_value(installed).unwrap_or_default()),
                    Err(e) => rows.push(serde_json::json!({
                        "harness": h.name(),
                        "missing": protocol::diagnostic_line(&e),
                    })),
                }
            }
            Ok(serde_json::Value::Array(rows))
        }
        Verb::Launch {
            intent,
            record: record_path,
            socket,
            session,
            window_name,
        } => {
            let text =
                std::fs::read_to_string(&intent).map_err(|e| Error::io("read", &intent, e))?;
            let intent: LaunchIntent =
                serde_json::from_str(&text).map_err(|source| Error::Json {
                    path: intent.clone(),
                    source,
                })?;
            let command = launch::build(&intent)?;
            if let Some(brief) = &command.brief_path
                && !brief.is_file()
            {
                return Err(Error::refused(
                    "brief-file-missing",
                    &[("path", &brief.display().to_string())],
                ));
            }
            let socket = match socket {
                Some(socket) => socket,
                None => tmux::ambient_socket()?,
            };
            let server = tmux::server(&socket)?;
            if !tmux::session_present(&server, &session)? {
                return Err(Error::refused(
                    "tmux-session-missing",
                    &[
                        ("session", &session),
                        ("socket", &socket.display().to_string()),
                    ],
                ));
            }
            let line = command.shell_line();
            // The leads that stand before the window opens, so the one that
            // appears after it is the launch's own. A store that cannot be
            // read is no baseline: the launch is refused before any window
            // opens rather than recording a floor it does not have.
            let baseline = match intent
                .home
                .clone()
                .or_else(|| session::default_home(intent.harness))
            {
                Some(home) if intent.session_id.is_none() => {
                    match session::lead_ids(intent.harness, &home, &intent.cwd) {
                        Reading::Live(ids) => Some(ids),
                        Reading::Gone => Some(Vec::new()),
                        Reading::Unreadable { cause } => {
                            return Err(Error::refused(
                                "baseline-unreadable",
                                &[("home", &home.display().to_string()), ("cause", cause)],
                            ));
                        }
                    }
                }
                Some(_) | None => None,
            };
            let launched_at = clock::now();
            // A `new-window` that started and gave no answer may have opened
            // the window, and names no pane a record could hold: the refusal
            // says so, with the session and the window's name to find it by.
            let pane = match tmux::new_window(&server, &session, &window_name, &intent.cwd) {
                Ok(pane) => pane,
                Err(
                    e @ Error::External {
                        operation: "new-window",
                        ..
                    },
                ) => {
                    return Err(Error::refused(
                        "launch-window-unanswered",
                        &[
                            ("cause", &e.to_string()),
                            ("session", &session),
                            ("window", &window_name),
                        ],
                    ));
                }
                Err(e) => return Err(e),
            };
            let rec = LaunchRecord {
                harness: intent.harness,
                intent,
                command_line: line,
                pane,
                launched_at,
                harness_process: None,
                native_session: None,
                baseline,
                stopped: None,
            };
            // The record names the window before its line is typed, so an
            // `inspect` or a `stop` reads what the launch opened whatever
            // the answer to the line. A window nothing was typed into is
            // closed by its exact id where the record cannot stand or the
            // line never reached it.
            if let Err(e) = record::write(
                &record_path,
                RECORD_VERSION,
                &rec,
                &Map::new(),
                Expect::Absent,
            ) {
                // A window whose close cannot be read may stand holding only
                // its shell, which no record names: the refusal names it.
                return Err(match tmux::kill_window(&rec.pane) {
                    Close::Closed | Close::AlreadyGone => e,
                    Close::Unreadable { cause } => Error::refused(
                        "launch-window-unclosed",
                        &[
                            ("cause", e.key()),
                            ("close", &cause),
                            ("session", &rec.pane.session),
                            ("window", &rec.pane.window),
                            ("pane", &rec.pane.id),
                        ],
                    ),
                });
            }
            let loaded = match tmux::load_line(&rec.pane, &rec.command_line) {
                Ok(loaded) => loaded,
                Err(e) => {
                    let record = record_path.display().to_string();
                    return Err(match tmux::kill_window(&rec.pane) {
                        Close::Closed | Close::AlreadyGone => {
                            let _ = std::fs::remove_file(&record_path);
                            Error::refused("launch-line-unsent", &[("cause", e.key())])
                        }
                        Close::Unreadable { .. } => Error::refused(
                            "launch-line-unsent",
                            &[("cause", e.key()), ("record", &record)],
                        ),
                    });
                }
            };
            if let Err(e) = loaded.paste() {
                return Err(Error::refused(
                    "launch-line-unanswered",
                    &[
                        ("cause", e.key()),
                        ("record", &record_path.display().to_string()),
                    ],
                ));
            }
            Ok(serde_json::to_value(&rec).unwrap_or_default())
        }
        Verb::Inspect {
            record: record_path,
        } => {
            let (mut rec, revision, extra) = read_record(&record_path)?;
            let inspection = inspect(&mut rec)?;
            record::write(
                &record_path,
                RECORD_VERSION,
                &rec,
                &extra,
                Expect::Revision(revision),
            )?;
            Ok(serde_json::to_value(inspection).unwrap_or_default())
        }
        Verb::Deliver {
            record: record_path,
            file,
            line,
            force,
            harness,
            program,
            socket,
            server_pid,
            server_start,
            pane,
            pid,
            start,
            home,
            cwd,
            session_id,
            turns_before,
            no_paste,
            bound_secs,
        } => {
            let text = match (&file, line, no_paste) {
                (_, _, true) => None,
                (Some(file), None, false) => {
                    Some(std::fs::read_to_string(file).map_err(|e| Error::io("read", file, e))?)
                }
                (None, Some(line), false) => Some(line),
                (None, None, false) => {
                    return Err(Error::refused("deliver-text-missing", &[]));
                }
                (Some(_), Some(_), false) => unreachable!("clap refuses --file with --line"),
            };
            let (session, judged) = match (record_path, harness) {
                (Some(path), None) => recorded_session(&path)?,
                (None, Some(name)) => {
                    let harness = Harness::parse(&name)
                        .ok_or_else(|| Error::refused("harness-unknown", &[("harness", &name)]))?;
                    let (Some(socket), Some(server_pid), Some(pane), Some(cwd)) =
                        (socket, server_pid, pane, cwd)
                    else {
                        unreachable!("clap requires the pane and session facts with --harness")
                    };
                    let recorded = match (pid, start) {
                        (Some(pid), Some(start)) => Some(Identity { pid, start }),
                        (None, _) => None,
                        (Some(_), None) => unreachable!("clap requires --start with --pid"),
                    };
                    let server = match server_start {
                        Some(start) => tmux::Server {
                            socket,
                            pid: server_pid,
                            start,
                        },
                        None => {
                            let live = tmux::server(&socket)?;
                            if live.pid != server_pid {
                                return Err(Error::refused(
                                    "server-unmatched",
                                    &[
                                        ("socket", &socket.display().to_string()),
                                        ("recorded", &server_pid.to_string()),
                                        ("live", &live.pid.to_string()),
                                    ],
                                ));
                            }
                            live
                        }
                    };
                    let pane = tmux::Pane {
                        server,
                        id: pane,
                        window: String::new(),
                        session: String::new(),
                    };
                    let file = match session_id {
                        Some(id) => SessionFile::ById {
                            home: home.or_else(|| session::default_home(harness)),
                            cwd,
                            id,
                        },
                        None => SessionFile::Unbound,
                    };
                    let session = Session {
                        harness,
                        program,
                        pane,
                        recorded,
                        file,
                    };
                    let owns = |name: &str| {
                        session
                            .harness
                            .owns_process_of(session.program.as_deref(), name)
                    };
                    let judged = judge_pane(
                        session.harness,
                        &owns,
                        &session.pane,
                        session.recorded.as_ref(),
                    )?;
                    (session, judged)
                }
                (None, None) => return Err(Error::refused("deliver-session-missing", &[])),
                (Some(_), Some(_)) => unreachable!("clap refuses --record with --harness"),
            };
            Ok(serde_json::to_value(deliver(
                &session,
                judged,
                text.as_deref(),
                force,
                turns_before,
                Duration::from_secs(bound_secs),
            )?)
            .unwrap_or_default())
        }
        Verb::Stop {
            record: record_path,
            grace_secs,
        } => {
            let (mut rec, revision, extra) = read_record(&record_path)?;
            let grace = Duration::from_secs(grace_secs);
            // The recorded harness, else the one read in the pane now; a
            // read that fails stops nothing and refuses with its cause.
            let identity = match rec.harness_process.clone() {
                Some(id) => Reading::Live(id),
                None => harness_identity(&rec),
            };
            let outcome = match identity {
                Reading::Live(id) => process::stop_tree(&id, &owns(&rec), grace)?,
                Reading::Gone => process::Stop::AlreadyGone,
                Reading::Unreadable { cause } => {
                    return Err(Error::refused(
                        "harness-unreadable",
                        &[("pane", &rec.pane.id), ("cause", cause)],
                    ));
                }
            };
            // The window is the launch's own: closed whole, and only once
            // the stop confirmed every process it names ended.
            let window = match &outcome {
                process::Stop::Stopped { .. } | process::Stop::AlreadyGone => {
                    tmux::kill_window(&rec.pane)
                }
                process::Stop::IdentityStale
                | process::Stop::Timeout { .. }
                | process::Stop::Unreadable { .. } => Close::Unreadable {
                    cause: "stop-unconfirmed".to_owned(),
                },
            };
            rec.stopped = Some(StopRecord {
                at: clock::now(),
                outcome: outcome.clone(),
                window: window.clone(),
            });
            record::write(
                &record_path,
                RECORD_VERSION,
                &rec,
                &extra,
                Expect::Revision(revision),
            )?;
            Ok(serde_json::json!({
                "stop": outcome,
                "window": window,
            }))
        }
        Verb::Judge {
            screen,
            harness: name,
            process: reading,
        } => {
            let h = Harness::parse(&name)
                .ok_or_else(|| Error::refused("harness-unknown", &[("harness", &name)]))?;
            let text =
                std::fs::read_to_string(&screen).map_err(|e| Error::io("read", &screen, e))?;
            let reading = match reading.as_str() {
                "shells-only" => ProcessReading::ShellsOnly,
                "harness-up" => ProcessReading::HarnessUp,
                "unread" => ProcessReading::Unread {
                    cause: "caller-asserted",
                },
                other => {
                    return Err(Error::refused(
                        "process-reading-unknown",
                        &[("value", other)],
                    ));
                }
            };
            Ok(serde_json::to_value(observe::judge(&text, h, &reading, None)).unwrap_or_default())
        }
        // Both print the reading whole: `live` with the identity, `gone`,
        // or `unreadable` with its cause.
        Verb::Process { op } => match op {
            ProcessOp::Identity { pid } => {
                Ok(serde_json::to_value(process::identity(pid)).unwrap_or_default())
            }
            ProcessOp::Live { pid, start } => Ok(serde_json::to_value(process::still_runs(
                &Identity { pid, start },
            ))
            .unwrap_or_default()),
        },
    }
}

/// Exit status of a usage error, clap's convention.
const USAGE_EXIT: i32 = 2;

fn main() {
    let stdout = std::io::stdout();
    let stderr = std::io::stderr();
    let cli = match Cli::try_parse() {
        Ok(cli) => cli,
        Err(e) if matches!(e.kind(), ErrorKind::DisplayHelp | ErrorKind::DisplayVersion) => {
            let _ = e.print();
            return;
        }
        Err(e) => {
            let _ = writeln!(stderr.lock(), "agent-runtime: usage");
            let _ = writeln!(stderr.lock(), "{e}");
            std::process::exit(USAGE_EXIT);
        }
    };
    match run(cli) {
        Ok(value) => {
            let reply = Reply::ok(value);
            let _ = writeln!(
                stdout.lock(),
                "{}",
                serde_json::to_string(&reply).unwrap_or_default()
            );
        }
        Err(error) => {
            let _ = writeln!(stderr.lock(), "{}", protocol::diagnostic_line(&error));
            let _ = writeln!(stderr.lock(), "{error}");
            let reply: Reply<()> = Reply::refused(&error);
            let _ = writeln!(
                stdout.lock(),
                "{}",
                serde_json::to_string(&reply).unwrap_or_default()
            );
            std::process::exit(1);
        }
    }
}
