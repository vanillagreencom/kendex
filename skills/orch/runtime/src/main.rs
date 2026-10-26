//! The `orch-runtime` command: the versioned boundary scripts and hosts
//! speak to the library through. Every verb prints one JSON reply on stdout;
//! a refusal also prints one keyed line on stderr and exits 1. A usage error
//! prints `orch-runtime: usage` and clap's message on stderr and exits 2,
//! clap's own convention and agent-runtime's, with no reply: there was no
//! request to answer.

use std::collections::hash_map::RandomState;
use std::hash::{BuildHasher, Hasher};
use std::io::Write;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use clap::error::ErrorKind;
use clap::{Parser, Subcommand};

use orch_runtime::error::{Error, Result};
use orch_runtime::ops::{self, Env, Request};
use orch_runtime::protocol::{self, Reply};
use orch_runtime::state::{self, Locking};

#[derive(Parser)]
#[command(
    name = "orch-runtime",
    version,
    about = "One repository's workflow records, their operations and the standing scheduler"
)]
struct Cli {
    #[command(subcommand)]
    verb: Verb,
}

#[derive(Subcommand)]
enum Verb {
    /// Print the protocol and crate version.
    Version,
    /// Read or migrate one state file.
    State {
        #[command(subcommand)]
        op: StateOp,
    },
    /// Apply one operation request to a state file and print the result of
    /// the committed transition.
    Op {
        #[arg(long)]
        file: PathBuf,
        /// A JSON request tagged by `op`.
        #[arg(long)]
        request: PathBuf,
    },
}

#[derive(Subcommand)]
enum StateOp {
    /// A read-only snapshot with the file's version and revision.
    Inspect {
        #[arg(long)]
        file: PathBuf,
    },
    /// Stamp a legacy file with its version and revision, keeping the
    /// original bytes beside it as `<file>.pre-migration`.
    Migrate {
        #[arg(long)]
        file: PathBuf,
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
    let value = match cli.verb {
        Verb::Version => serde_json::json!({
            "protocol": protocol::PROTOCOL,
            "crate": env!("CARGO_PKG_VERSION"),
            "record_version": state::RECORD_VERSION,
            "agent_runtime_protocol": agent_runtime::protocol::PROTOCOL,
        }),
        Verb::State {
            op: StateOp::Inspect { file },
        } => serde_json::to_value(state::inspect(&file)?)?,
        Verb::State {
            op: StateOp::Migrate { file },
        } => serde_json::to_value(state::migrate(&file, locking)?)?,
        Verb::Op { file, request } => {
            let request = read_request(&request)?;
            serde_json::to_value(ops::apply(&file, &request, &system_env(), locking)?)?
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
