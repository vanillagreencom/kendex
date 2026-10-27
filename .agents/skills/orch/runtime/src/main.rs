//! The `orch-runtime` command: the versioned boundary scripts and hosts
//! speak to the library through. Every verb prints one JSON reply on stdout;
//! a refusal also prints one keyed line on stderr and exits 1. A usage error
//! prints `orch-runtime: usage` and clap's message on stderr and exits 2,
//! clap's own convention and agent-runtime's, with no reply: there was no
//! request to answer.

use std::collections::hash_map::RandomState;
use std::ffi::OsString;
use std::hash::{BuildHasher, Hasher};
use std::io::Write;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use clap::error::ErrorKind;
use clap::{Args, Parser, Subcommand};

use orch_runtime::effects::{self, SystemClock};
use orch_runtime::error::{Error, Result};
use orch_runtime::ops::{self, Env, Request};
use orch_runtime::protocol::{self, Reply};
use orch_runtime::settings::{self, Flags, Settings};
use orch_runtime::state::{self, Locking};

#[derive(Parser)]
#[command(
    name = "orch-runtime",
    version,
    about = "One repository's workflow records, their operations and the standing scheduler"
)]
struct Cli {
    /// The state directory for `--item` and `--fleet`, over every settings
    /// source; the legacy `--state-dir`.
    #[arg(long, global = true)]
    state_dir: Option<PathBuf>,
    /// Keep the settings reader off the project's private env file; the
    /// legacy `--no-private-env`.
    #[arg(long, global = true)]
    no_private_env: bool,
    #[command(subcommand)]
    verb: Verb,
}

#[derive(Subcommand)]
enum Verb {
    /// Print the protocol and crate version.
    Version,
    /// Read, initialize or migrate one state file.
    State {
        #[command(subcommand)]
        op: StateOp,
    },
    /// Apply one operation request to a state file, run the live effect its
    /// intent names, and print the committed transition.
    Op {
        #[command(flatten)]
        target: Target,
        /// A JSON request tagged by `op`.
        #[arg(long)]
        request: PathBuf,
    },
    /// Re-observe every open intent by its recorded identity and complete or
    /// mark each, starting no new effect.
    Reconcile {
        #[command(flatten)]
        target: Target,
    },
}

/// Which state file a verb acts on: a path, or an item or fleet under the
/// resolved state directory.
#[derive(Args)]
#[group(required = true, multiple = false)]
struct Target {
    #[arg(long)]
    file: Option<PathBuf>,
    #[arg(long)]
    item: Option<String>,
    #[arg(long)]
    fleet: bool,
}

#[derive(Subcommand)]
enum StateOp {
    /// A read-only snapshot with the file's version and revision.
    Inspect {
        #[command(flatten)]
        target: Target,
    },
    /// Create a state file with the object `workflow-state init` writes,
    /// refusing a standing file.
    Init {
        #[command(flatten)]
        target: Target,
        #[arg(long)]
        agent: Option<String>,
        #[arg(long)]
        worktree: Option<String>,
        #[arg(long)]
        branch: Option<String>,
        /// A JSON array; `[]` when unset.
        #[arg(long)]
        qa_labels: Option<String>,
        /// A JSON array; `[]` when unset.
        #[arg(long)]
        sub_issues: Option<String>,
    },
    /// Stamp a legacy file with its version and revision, keeping the
    /// original bytes beside it as `<file>.pre-migration`.
    Migrate {
        #[command(flatten)]
        target: Target,
    },
}

/// The clock and nonce this process stamps with. The nonce comes from the
/// hasher's random seed, the one source of randomness std provides.
fn system_env() -> Env {
    let since_epoch = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let nonce = (RandomState::new().build_hasher().finish() % 32_768) as u32;
    Env {
        now_secs: since_epoch.as_secs(),
        now_nanos: since_epoch.as_nanos(),
        nonce,
    }
}

/// The checkout the runtime runs in and the settings it acts on, resolved
/// once per process from the command line, the project files and the
/// environment, as the legacy scripts resolve them.
fn resolve_settings(flags: &Flags) -> Result<Settings> {
    let cwd = std::env::current_dir()
        .map_err(|e| Error::Runtime(agent_runtime::Error::io("cwd", PathBuf::from("."), e)))?;
    let roots = settings::roots(&cwd)?;
    let environment: Vec<(OsString, OsString)> = std::env::vars_os().collect();
    settings::load(&roots, &environment, flags)
}

/// The file a target names: the path, or the item or fleet file under the
/// resolved state directory.
fn target_path(target: &Target, settings: &Settings) -> PathBuf {
    if let Some(file) = &target.file {
        return file.clone();
    }
    if target.fleet {
        return state::fleet_path(&settings.state_dir);
    }
    state::item_path(
        &settings.state_dir,
        target.item.as_deref().unwrap_or_default(),
    )
}

fn parse_array(text: Option<&str>) -> Result<Option<serde_json::Value>> {
    match text {
        None => Ok(None),
        Some(text) => serde_json::from_str(text)
            .map(Some)
            .map_err(|e| Error::Request {
                path: PathBuf::from("<argument>"),
                cause: e.to_string(),
            }),
    }
}

fn read_request(path: &PathBuf) -> Result<Request> {
    let bytes = std::fs::read(path)
        .map_err(|e| Error::Runtime(agent_runtime::Error::io("read-request", path.clone(), e)))?;
    serde_json::from_slice(&bytes).map_err(|e| Error::Request {
        path: path.clone(),
        cause: e.to_string(),
    })
}

fn run(cli: Cli) -> Result<serde_json::Value> {
    // The lock policy follows this host's PATH, as the legacy writers' does.
    let locking = Locking::for_host(std::env::var_os("PATH").as_deref());
    let flags = Flags {
        state_dir: cli.state_dir.clone(),
        private_env: !cli.no_private_env,
    };
    let clock = SystemClock;
    let value = match cli.verb {
        Verb::Version => serde_json::json!({
            "protocol": protocol::PROTOCOL,
            "crate": env!("CARGO_PKG_VERSION"),
            "record_version": state::RECORD_VERSION,
            "agent_runtime_protocol": agent_runtime::protocol::PROTOCOL,
        }),
        Verb::State {
            op: StateOp::Inspect { target },
        } => {
            let settings = resolve_settings(&flags)?;
            serde_json::to_value(state::inspect(&target_path(&target, &settings))?)?
        }
        Verb::State {
            op:
                StateOp::Init {
                    target,
                    agent,
                    worktree,
                    branch,
                    qa_labels,
                    sub_issues,
                },
        } => {
            let settings = resolve_settings(&flags)?;
            let fields = state::InitFields {
                agent: agent.unwrap_or_default(),
                worktree: worktree.unwrap_or_default(),
                branch: branch.unwrap_or_default(),
                qa_labels: parse_array(qa_labels.as_deref())?,
                sub_issues: parse_array(sub_issues.as_deref())?,
            };
            serde_json::to_value(state::init(&target_path(&target, &settings), &fields)?)?
        }
        Verb::State {
            op: StateOp::Migrate { target },
        } => {
            let settings = resolve_settings(&flags)?;
            serde_json::to_value(state::migrate(&target_path(&target, &settings), locking)?)?
        }
        Verb::Op { target, request } => {
            let settings = resolve_settings(&flags)?;
            let path = target_path(&target, &settings);
            let request = read_request(&request)?;
            let env = system_env();
            let applied = ops::apply(&path, &request, &env, locking)?;
            // Run the live effect the persisted intent names and record its
            // outcome; the committed outcome transition is the result.
            match effects::run(
                &path,
                &request,
                &applied.report,
                &settings,
                &env,
                locking,
                &clock,
            )? {
                Some(outcome) => serde_json::json!({
                    "persisted": applied,
                    "effect": outcome,
                }),
                None => serde_json::to_value(applied)?,
            }
        }
        Verb::Reconcile { target } => {
            let settings = resolve_settings(&flags)?;
            let path = target_path(&target, &settings);
            let env = system_env();
            let reconciled = effects::reconcile(&path, &settings, &env, locking, &clock)?;
            serde_json::json!({ "reconciled": reconciled })
        }
    };
    Ok(value)
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
            let _ = writeln!(stderr.lock(), "orch-runtime: usage");
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
