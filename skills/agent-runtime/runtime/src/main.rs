//! The `agent-runtime` command: the versioned boundary other languages and
//! hosts speak to the library through. Every verb prints one JSON reply on
//! stdout; a refusal also prints one keyed line on stderr and exits 1.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

use clap::{Parser, Subcommand};
use serde::{Deserialize, Serialize};
use serde_json::Map;

use agent_runtime::clock;
use agent_runtime::error::{Error, Result};
use agent_runtime::harness::{self, Harness};
use agent_runtime::host::tmux;
use agent_runtime::launch::{self, LaunchIntent};
use agent_runtime::observe::{self, ProcessReading, State};
use agent_runtime::process::{self, Identity};
use agent_runtime::protocol::{self, Outcome, Reply};
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
    /// Paste a file's text into the recorded pane, only when the session
    /// is positively idle.
    Deliver {
        #[arg(long)]
        record: PathBuf,
        #[arg(long)]
        file: PathBuf,
        /// Deliver whatever the screen says; for a probe that knows better.
        #[arg(long)]
        force: bool,
    },
    /// End the recorded harness exactly, then close its window.
    Stop {
        #[arg(long)]
        record: PathBuf,
        #[arg(long, default_value_t = 10)]
        grace_secs: u64,
    },
    /// Find the newest lead native session for a working directory.
    Session {
        #[arg(long)]
        harness: String,
        #[arg(long)]
        cwd: PathBuf,
        #[arg(long)]
        home: Option<PathBuf>,
    },
    /// Judge a captured screen held in a file (fixtures and probes), drawn
    /// by the named harness.
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
    /// The pane's shell when the window opened.
    shell: Option<Identity>,
    /// The harness process below the shell, read once it is up.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    harness_process: Option<Identity>,
    /// The native session the harness recorded for the cwd, read once it
    /// is up.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    native_session: Option<session::SessionRef>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    stopped: Option<StopRecord>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct StopRecord {
    at: String,
    outcome: process::Stop,
    window_closed: bool,
}

#[derive(Debug, Serialize)]
struct Inspection {
    pane_present: bool,
    foreground: Option<String>,
    pane_pid: Option<u32>,
    harness_process: Option<Identity>,
    harness_live: Option<process::Liveness>,
    native_session: Option<session::SessionRef>,
    state: State,
    screen_tail: Vec<String>,
}

fn read_record(path: &Path) -> Result<(LaunchRecord, u64, Map<String, serde_json::Value>)> {
    let loaded = record::read::<LaunchRecord>(path, RECORD_VERSIONS)?.ok_or_else(|| {
        Error::refused("record-missing", &[("path", &path.display().to_string())])
    })?;
    Ok((loaded.body, loaded.revision, loaded.extra))
}

fn harness_identity(rec: &LaunchRecord) -> Result<Option<Identity>> {
    let (_, pane_pid) = tmux::pane_process(&rec.pane)?;
    let rows = process::table()?;
    let h = rec.harness;
    let below = process::below(&rows, pane_pid, &|n| h.owns_process(n));
    let Some((_, pid)) = below.first() else {
        return Ok(None);
    };
    process::identity(*pid)
}

fn inspect(rec: &mut LaunchRecord) -> Result<Inspection> {
    let present = tmux::pane_present(&rec.pane)?;
    if !present {
        return Ok(Inspection {
            pane_present: false,
            foreground: None,
            pane_pid: None,
            harness_process: rec.harness_process.clone(),
            harness_live: None,
            native_session: rec.native_session.clone(),
            state: State::Unjudged {
                cause: "pane-gone".to_owned(),
            },
            screen_tail: Vec::new(),
        });
    }
    let (foreground, pane_pid) = tmux::pane_process(&rec.pane)?;
    let rows = process::table()?;
    let h = rec.harness;
    let found = process::below(&rows, pane_pid, &|n| h.owns_process(n));
    let harness_live = match &rec.harness_process {
        Some(id) => Some(process::still_runs(id)?),
        None => None,
    };
    if (rec.harness_process.is_none() || harness_live != Some(process::Liveness::Live))
        && let Some((_, pid)) = found.first()
    {
        rec.harness_process = process::identity(*pid)?;
    }
    let harness_live = match &rec.harness_process {
        Some(id) => Some(process::still_runs(id)?),
        None => None,
    };
    let reading = if found.is_empty() && process::only_shells_below(&rows, pane_pid) {
        ProcessReading::ShellsOnly
    } else {
        ProcessReading::HarnessUp
    };
    if rec.native_session.is_none() {
        let home = rec
            .intent
            .home
            .clone()
            .or_else(|| session::default_home(rec.harness));
        if let Some(home) = home {
            rec.native_session = session::find_lead(rec.harness, &home, &rec.intent.cwd)?;
        }
    }
    let screen = tmux::capture(&rec.pane)?;
    let state = observe::judge(&screen, rec.harness, reading, None);
    let tail: Vec<String> = screen
        .lines()
        .rev()
        .filter(|l| !l.trim().is_empty())
        .take(12)
        .map(str::to_owned)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();
    Ok(Inspection {
        pane_present: true,
        foreground: Some(foreground),
        pane_pid: Some(pane_pid),
        harness_process: rec.harness_process.clone(),
        harness_live,
        native_session: rec.native_session.clone(),
        state,
        screen_tail: tail,
    })
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
            let socket = socket.unwrap_or_else(tmux::ambient_socket);
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
            let pane = tmux::new_window(&server, &session, &window_name, &intent.cwd, &line)?;
            let shell = match tmux::pane_process(&pane) {
                Ok((_, pid)) => process::identity(pid)?,
                Err(_) => None,
            };
            let rec = LaunchRecord {
                harness: intent.harness,
                intent,
                command_line: line,
                pane,
                launched_at: clock::now(),
                shell,
                harness_process: None,
                native_session: None,
                stopped: None,
            };
            record::write(
                &record_path,
                RECORD_VERSION,
                &rec,
                &Map::new(),
                Expect::Absent,
            )?;
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
            force,
        } => {
            let (mut rec, revision, extra) = read_record(&record_path)?;
            let text = std::fs::read_to_string(&file).map_err(|e| Error::io("read", &file, e))?;
            let inspection = inspect(&mut rec)?;
            record::write(
                &record_path,
                RECORD_VERSION,
                &rec,
                &extra,
                Expect::Revision(revision),
            )?;
            if !inspection.pane_present {
                return Err(Error::refused("pane-gone", &[("pane", &rec.pane.id)]));
            }
            if !force && inspection.state != State::Idle {
                let word = serde_json::to_value(&inspection.state)
                    .ok()
                    .and_then(|v| v.get("state").and_then(|s| s.as_str()).map(str::to_owned))
                    .unwrap_or_else(|| "unjudged".to_owned());
                return Err(Error::refused(
                    "deliver-refused",
                    &[("pane", &rec.pane.id), ("state", &word)],
                ));
            }
            tmux::send_line(&rec.pane, text.trim_end_matches('\n'))?;
            Ok(serde_json::json!({
                "outcome": Outcome::Confirmed,
                "route": "pane-paste",
                "pane": rec.pane.id,
                "bytes": text.len(),
            }))
        }
        Verb::Stop {
            record: record_path,
            grace_secs,
        } => {
            let (mut rec, revision, extra) = read_record(&record_path)?;
            let grace = Duration::from_secs(grace_secs);
            let identity = match rec.harness_process.clone() {
                Some(id) => Some(id),
                None => harness_identity(&rec).unwrap_or(None),
            };
            let h = rec.harness;
            let outcome = match identity {
                Some(id) => process::stop_tree(&id, &|n| h.owns_process(n), grace)?,
                None => process::Stop::AlreadyGone,
            };
            let window_closed = tmux::kill_window(&rec.pane).unwrap_or(false);
            rec.stopped = Some(StopRecord {
                at: clock::now(),
                outcome: outcome.clone(),
                window_closed,
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
                "window_closed": window_closed,
            }))
        }
        Verb::Session {
            harness: name,
            cwd,
            home,
        } => {
            let h = Harness::parse(&name)
                .ok_or_else(|| Error::refused("harness-unknown", &[("harness", &name)]))?;
            let home = home
                .or_else(|| session::default_home(h))
                .ok_or_else(|| Error::refused("home-unresolved", &[("harness", h.name())]))?;
            let found = session::find_lead(h, &home, &cwd)?;
            Ok(serde_json::to_value(found).unwrap_or_default())
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
                "unread" => ProcessReading::Unread,
                other => {
                    return Err(Error::refused(
                        "process-reading-unknown",
                        &[("value", other)],
                    ));
                }
            };
            Ok(serde_json::to_value(observe::judge(&text, h, reading, None)).unwrap_or_default())
        }
        Verb::Process { op } => match op {
            ProcessOp::Identity { pid } => {
                Ok(serde_json::to_value(process::identity(pid)?).unwrap_or_default())
            }
            ProcessOp::Live { pid, start } => Ok(serde_json::to_value(process::still_runs(
                &Identity { pid, start },
            )?)
            .unwrap_or_default()),
        },
    }
}

fn main() {
    let cli = Cli::parse();
    let stdout = std::io::stdout();
    let stderr = std::io::stderr();
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
