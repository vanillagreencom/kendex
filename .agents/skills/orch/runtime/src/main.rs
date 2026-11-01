//! The `orch-runtime` command: the versioned boundary scripts and hosts
//! speak to the library through. Every verb prints one JSON reply on stdout;
//! a refusal also prints one keyed line on stderr and exits 1. A usage error
//! prints `orch-runtime: usage` and clap's message on stderr and exits 2,
//! clap's own convention and agent-runtime's, with no reply: there was no
//! request to answer.
use std::collections::hash_map::RandomState;
use std::ffi::{OsStr, OsString};
use std::hash::{BuildHasher, Hasher};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use clap::error::ErrorKind;
use clap::{Args, Parser, Subcommand};

use orch_runtime::effects;
use orch_runtime::error::{Error, Result};
use orch_runtime::ops::{self, Env, Request};
use orch_runtime::protocol::{self, Reply};
use orch_runtime::schedule;
use orch_runtime::settings::{self, Flags, Settings};
use orch_runtime::state::{self, Locking};
use orch_runtime::verify;
use orch_runtime::watch;

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
    /// Read or initialize one state file.
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
    /// The detached job a transfer runs in (decision 76): claim the open
    /// intent, run its effect from the request written beside the record,
    /// record the outcome.
    Job {
        #[command(flatten)]
        target: Target,
        #[arg(long)]
        intent: String,
    },
    /// The standing scheduler over one fleet state (decisions 62, 121).
    Watch {
        #[command(subcommand)]
        op: WatchOp,
    },
    /// Judge the paths a running lane adds, or a launch before its record
    /// stands, against the fleet's holders under the launch lock, and widen
    /// the lane record where one stands (decisions 118 (3), 142 (4)).
    Admit {
        #[command(flatten)]
        target: Target,
        /// A JSON `admit-paths` request: the item, its tracker and
        /// repository, the paths added, the brief, the checkout and range
        /// the change-scope paths are read over, and the in-scope paths.
        #[arg(long)]
        request: PathBuf,
    },
}

#[derive(Subcommand)]
enum WatchOp {
    /// Claim the fleet state and run the duties until `watch stop`.
    Run {
        #[command(flatten)]
        target: Target,
        /// Seconds between two runs of a long-pass duty; the legacy
        /// `--interval`.
        #[arg(long, default_value_t = 240, value_parser = clap::value_parser!(u64).range(1..))]
        interval: u64,
        /// Long passes per heartbeat; the legacy `--max-loops`.
        #[arg(long, default_value_t = 25, value_parser = clap::value_parser!(u32).range(1..))]
        max_loops: u32,
        /// The stamp the heartbeat's `since=` carries; the legacy `--since`.
        #[arg(long)]
        since: Option<String>,
        /// A live runner's pid to stop and replace; the legacy
        /// `OVERSEE_WATCH_REPLACE`.
        #[arg(long)]
        replace: Option<u32>,
        /// A repository (`owner/repo`) the GitHub inventories read beside
        /// the lanes' own and the connected ones; the legacy `--repo`.
        #[arg(long = "repo")]
        repos: Vec<String>,
    },
    /// The claim and whether its identity runs, the due times the records
    /// imply, and the last event line's number.
    Status {
        #[command(flatten)]
        target: Target,
    },
    /// Ask the claimed runner to stop and wait for its claim's release.
    Stop {
        #[command(flatten)]
        target: Target,
    },
    /// The event log's numbered lines from `--since` on.
    Log {
        #[command(flatten)]
        target: Target,
        #[arg(long, default_value_t = 1)]
        since: u64,
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
}

/// The clock, nonce and owner this process stamps with. The nonce comes
/// from the hasher's random seed, the one source of randomness std provides;
/// the owner is this process's identity through agent-runtime's one reader
/// (decision 72). A failed identity read refuses the verb with its cause
/// (decision 90); a reader that answers with no process for this pid
/// leaves the owner unset, and the library then refuses to persist an
/// intent without one.
#[allow(
    clippy::disallowed_methods,
    reason = "the command reads the wall clock and its own identity for the stamp and the owner it writes with (decision 72); no effect runs here"
)]
fn system_env() -> Result<Env> {
    let since_epoch = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let nonce = (RandomState::new().build_hasher().finish() % 32_768) as u32;
    let pid = std::process::id();
    let owner = match agent_runtime::process::identity(pid) {
        agent_runtime::reading::Reading::Live(id) => Some(orch_runtime::state::Owner {
            pid: id.pid as u64,
            start: id.start,
        }),
        agent_runtime::reading::Reading::Gone => None,
        agent_runtime::reading::Reading::Unreadable { cause } => {
            return Err(Error::Runtime(agent_runtime::Error::Process {
                operation: "owner-identity",
                pid,
                cause: cause.to_owned(),
            }));
        }
    };
    Ok(Env {
        now_secs: since_epoch.as_secs(),
        now_nanos: since_epoch.as_nanos(),
        nonce,
        owner,
    })
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

/// The JSON request at `path`, as `T`: an operation request, or the
/// `admit` verb's.
fn read_request<T: serde::de::DeserializeOwned>(path: &PathBuf) -> Result<T> {
    let bytes = std::fs::read(path)
        .map_err(|e| Error::Runtime(agent_runtime::Error::io("read-request", path.clone(), e)))?;
    serde_json::from_slice(&bytes).map_err(|e| Error::Request {
        path: path.clone(),
        cause: e.to_string(),
    })
}

fn run(cli: Cli) -> Result<serde_json::Value> {
    let locking = host_locking(std::env::var_os("PATH").as_deref());
    let flags = Flags {
        state_dir: cli.state_dir.clone(),
        private_env: !cli.no_private_env,
    };
    let value = match cli.verb {
        Verb::Version => serde_json::json!({
            "protocol": protocol::PROTOCOL,
            "crate": env!("CARGO_PKG_VERSION"),
            "agent_runtime_protocol": agent_runtime::protocol::PROTOCOL,
        }),
        Verb::State {
            op: StateOp::Inspect { target },
        } => {
            let settings = resolve_settings(&flags)?;
            serde_json::to_value(inspect_state(&target_path(&target, &settings))?)?
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
            serde_json::to_value(init_state(&target_path(&target, &settings), &fields)?)?
        }
        Verb::Op { target, request } => {
            let settings = resolve_settings(&flags)?;
            let path = target_path(&target, &settings);
            let request = read_request(&request)?;
            // The target's kind is the precondition of every operation,
            // checked before anything is read: a verification must not
            // reach GitHub for a target it could never record on.
            ops::target_kind(&path, &request)?;
            // What the settings refuse before any transition: a succession
            // under `ORCH_OVERSEER_SUCCESSION=off` (decision 78).
            ops::admit(&request, &settings)?;
            let env = system_env()?;
            // A verification reads GitHub first and makes its one
            // transition through record-verification itself.
            if let Request::VerifyHead(r) = &request {
                return Ok(serde_json::to_value(verify_head(&path, r, &env, locking)?)?);
            }
            // An adoption reads the pane first and makes its one transition
            // on what it read.
            if let Request::AdoptController(r) = &request {
                return Ok(serde_json::to_value(effects::adopt_controller(
                    &path, r, &settings, locking,
                )?)?);
            }
            // The notices earlier outcomes still owe are sent before the
            // request's own transition; a mark the store refused is in the
            // reply and fails nothing (decision 124i (36)).
            let notices_unmarked = effects::send_owed_notices(
                &path,
                &request,
                &settings,
                &env,
                locking,
                &schedule::SystemClock,
            )?;
            let applied = persist(&path, &request, &env, locking, &settings)?;
            // Run the live effect the persisted intent names and record its
            // outcome; the committed outcome transition is the result.
            match effects::run(
                &path,
                &request,
                &applied.report,
                &settings,
                &env,
                locking,
                &schedule::SystemClock,
            )? {
                Some(outcome) => {
                    let mut reply = serde_json::json!({
                        "persisted": applied,
                        "effect": outcome,
                    });
                    if !notices_unmarked.is_empty() {
                        reply["notices_unmarked"] = serde_json::to_value(notices_unmarked)?;
                    }
                    reply
                }
                None => serde_json::to_value(applied)?,
            }
        }
        Verb::Reconcile { target } => {
            let settings = resolve_settings(&flags)?;
            let path = target_path(&target, &settings);
            let env = system_env()?;
            serde_json::to_value(effects::reconcile(
                &path,
                &settings,
                &env,
                locking,
                &schedule::SystemClock,
            )?)?
        }
        Verb::Job { target, intent } => {
            let settings = resolve_settings(&flags)?;
            let path = target_path(&target, &settings);
            let env = system_env()?;
            serde_json::to_value(effects::run_job(
                &path,
                &intent,
                &settings,
                &env,
                locking,
                &schedule::SystemClock,
            )?)?
        }
        Verb::Watch { op } => watch_verb(op, &flags, locking)?,
        Verb::Admit { target, request } => {
            let settings = resolve_settings(&flags)?;
            let path = target_path(&target, &settings);
            let request: ops::AdmitPaths = read_request(&request)?;
            let env = system_env()?;
            serde_json::to_value(admit(&path, &request, &env, locking, &settings)?)?
        }
    };
    Ok(value)
}

/// The `watch` verbs. `run` claims as this process's identity (decision
/// 99), records the legacy claim fields (the pane it serves, its program and
/// directory, its arguments) and registers every duty, one registration
/// line each (decision 153 (2)): the reconcile of every open intent on the
/// long cadence (decision 121, Q4) and the duties under `watch/`.
fn watch_verb(op: WatchOp, flags: &Flags, locking: Locking) -> Result<serde_json::Value> {
    let settings = resolve_settings(flags)?;
    let clock = schedule::SystemClock;
    match op {
        WatchOp::Run {
            target,
            interval,
            max_loops,
            since,
            replace,
            repos,
        } => {
            let path = target_path(&target, &settings);
            let paths = watch::Paths::of(&path)?;
            let env = system_env()?;
            let Some(owner) = env.owner.clone() else {
                return Err(orch_runtime::error::WatchError::IdentityUnreadable.into());
            };
            let identity = agent_runtime::process::Identity {
                pid: owner.pid as u32,
                start: owner.start.clone(),
            };
            let record = watch::Recorded {
                pane: std::env::var("TMUX_PANE").unwrap_or_else(|_| "none".to_owned()),
                script: std::env::current_exe()
                    .map(|p| p.display().to_string())
                    .map_err(|e| {
                        Error::Runtime(agent_runtime::Error::io("exe", PathBuf::from("."), e))
                    })?,
                cwd: std::env::current_dir()
                    .map(|p| p.display().to_string())
                    .map_err(|e| {
                        Error::Runtime(agent_runtime::Error::io("cwd", PathBuf::from("."), e))
                    })?,
                args: std::env::args().skip(1).collect(),
            };
            let mut runner = watch::Runner::new(
                paths,
                &clock,
                &settings,
                watch::Flags {
                    interval: std::time::Duration::from_secs(interval),
                    max_loops,
                    since: since.clone(),
                    replace,
                },
                identity,
                record,
            );
            // The tracker read duty (U5e): the inventories once per pass,
            // the terminal closes, the heartbeat's inputs; the GitHub duty
            // (U5e2) shares its slot.
            let shared = watch::tracker::register(
                &mut runner,
                &path,
                &settings,
                &env,
                locking,
                since.clone(),
            )?;
            // U5f: the verification duty on the tracker's slot, the
            // heartbeat's body on both slots, the report and the retention.
            let verifying = watch::verifying::register(&mut runner, &settings, shared.clone());
            watch::heartbeat::register(
                &mut runner,
                &settings,
                std::time::Duration::from_secs(interval),
                max_loops,
                since.clone(),
                repos.clone(),
                shared.clone(),
                verifying,
            );
            watch::report::register(&mut runner, &path, &settings, repos.clone());
            watch::retention::register(&mut runner, &path, &settings, locking)?;
            watch::github::register(&mut runner, &path, &settings, since.clone(), repos, shared)?;
            watch::mail::register(&mut runner, &path, &settings)?;
            let reconcile_settings = settings.clone();
            let nonce = env.nonce;
            watch::overseer::register(
                &mut runner,
                &path,
                &settings,
                &env,
                locking,
                watch::overseer::Slot::new(),
            );
            watch::wake::register(&mut runner, &path, &settings);
            runner.register(
                schedule::Duty::Reconcile,
                Box::new(move |tick: &watch::Tick| {
                    let env = Env {
                        now_secs: tick.wall,
                        now_nanos: u128::from(tick.wall) * 1_000_000_000,
                        nonce,
                        owner: Some(owner.clone()),
                    };
                    let run =
                        effects::reconcile(&path, &reconcile_settings, &env, locking, tick.clock)?;
                    Ok(reconcile_lines(&run, tick.baseline))
                }),
            );
            Ok(serde_json::to_value(runner.run()?)?)
        }
        WatchOp::Status { target } => {
            let paths = watch::Paths::of(&target_path(&target, &settings))?;
            Ok(serde_json::to_value(watch::status(&paths)?)?)
        }
        WatchOp::Stop { target } => {
            let paths = watch::Paths::of(&target_path(&target, &settings))?;
            Ok(serde_json::to_value(watch::claim::stop(&paths, &clock)?)?)
        }
        WatchOp::Log { target, since } => {
            let paths = watch::Paths::of(&target_path(&target, &settings))?;
            let lines = watch::events::read_since(&paths.log, since)?;
            Ok(serde_json::json!({ "lines": lines }))
        }
    }
}

/// The baseline row kind holding each intent the reconcile last refused,
/// by its refusal key.
const RECONCILE_REFUSED: &str = "reconcile-refused";

/// What the reconcile duty publishes of its report: a line per open intent
/// it could not complete or mark, printed when the refusal is new or its
/// key changed and cleared when the intent is no longer refused, as the
/// legacy printed a standing `main-workflow-absent`; and a line per owed
/// notice sent whose mark the store refused. A deferral to a live or
/// unreadable owner is a reconciled outcome, not a refusal, and prints
/// nothing (decisions 128 (5), 130).
fn reconcile_lines(run: &effects::ReconcileRun, baseline: &watch::Baseline) -> watch::Produced {
    let mut produced = watch::Produced::default();
    for refused in &run.refused {
        if baseline.get(RECONCILE_REFUSED, &refused.intent) != Some(refused.refusal.as_str()) {
            produced.events.push(watch::Event::ReconcileRefused {
                intent: refused.intent.clone(),
                refusal: refused.refusal.clone(),
            });
            produced.changes.push(watch::Change::Set {
                kind: RECONCILE_REFUSED.to_owned(),
                identity: refused.intent.clone(),
                value: refused.refusal.clone(),
            });
        }
    }
    for intent in baseline.identities(RECONCILE_REFUSED) {
        if !run.refused.iter().any(|r| r.intent == intent) {
            produced.changes.push(watch::Change::Clear {
                kind: RECONCILE_REFUSED.to_owned(),
                identity: intent,
            });
        }
    }
    for notice in &run.notices_unmarked {
        produced.events.push(watch::Event::NoticeUnmarked {
            intent: notice.intent.clone(),
            cause: notice.refusal.clone(),
        });
    }
    produced
}

/// The lock policy for the host whose `PATH` is `path_var`, as the legacy
/// writers resolve theirs: the legacy wait, and the mutex wherever
/// `flock(1)` is not on that path. The one lookup of the lock tool, which
/// decides the locking every write of this process takes.
#[allow(
    clippy::disallowed_methods,
    reason = "the command's one lookup of the lock tool"
)]
fn host_locking(path_var: Option<&OsStr>) -> Locking {
    Locking {
        wait: agent_runtime::record::Wait::LEGACY,
        legacy_mutex: !agent_runtime::record::flock_on_path(path_var),
    }
}

/// The `state inspect` verb's one call of the inspection; the compiler
/// boundary names it, so this is its one caller.
#[allow(
    clippy::disallowed_methods,
    reason = "the command's one call of the state inspection"
)]
fn inspect_state(path: &Path) -> Result<state::Inspection> {
    state::inspect(path)
}

/// The `state init` verb's one call of the creation; the compiler boundary
/// names it, so this is its one caller.
#[allow(
    clippy::disallowed_methods,
    reason = "the command's one call of the state file's creation"
)]
fn init_state(path: &Path, fields: &state::InitFields) -> Result<state::Initialized> {
    state::init(path, fields)
}

/// The `verify-head` request's one call of the verification, which reads
/// GitHub and records the verdict; the compiler boundary names the
/// verification, so this is its one caller.
#[allow(
    clippy::disallowed_methods,
    reason = "the command's one call of the verification"
)]
fn verify_head(
    path: &Path,
    r: &ops::VerifyHead,
    env: &Env,
    locking: Locking,
) -> Result<verify::Verified> {
    verify::run(path, r, env, locking)
}

/// The command's one store entry: the request's transition committed,
/// judged against the host facts a lane transition needs (decision 97), the
/// cap setting, the legacy claim store and the kernel's own reads.
#[allow(
    clippy::disallowed_methods,
    reason = "the command's one store entry; every effect that follows runs through the operation handle"
)]
fn persist(
    path: &Path,
    request: &Request,
    env: &Env,
    locking: Locking,
    settings: &Settings,
) -> Result<ops::Applied> {
    let host = kernel_host(settings);
    ops::apply_on(path, request, env, locking, &host)
}

/// The host a fleet transition judges against: the cap, the legacy claim
/// store, the kernel's reads and the programs the admission reads through.
#[allow(
    clippy::disallowed_methods,
    reason = "the command's one construction of the kernel host, handed to the store entries alone"
)]
fn kernel_host(settings: &Settings) -> ops::Host<'static> {
    ops::Host::kernel(settings.lane_cap, Some(settings.claim_store.clone())).admitting(ops::Clis {
        tracker: settings.reads.tracker_cli.clone(),
        gh: PathBuf::from("gh"),
        scope_paths: settings.scope_paths_cli.clone(),
    })
}

/// The `admit` verb's one store entry: the judgement committed under the
/// launch lock (decision 108 (5)) through the one dispatcher.
#[allow(
    clippy::disallowed_methods,
    reason = "the command's one admission store entry; no effect runs after it"
)]
fn admit(
    path: &Path,
    request: &ops::AdmitPaths,
    env: &Env,
    locking: Locking,
    settings: &Settings,
) -> Result<ops::PathsAdmitted> {
    let host = kernel_host(settings);
    let request = ops::Request::AdmitPaths(Box::new(request.clone()));
    let applied = ops::apply_on(path, &request, env, locking, &host)?;
    match applied.report {
        ops::Report::AdmitPaths(admitted) => Ok(*admitted),
        other => unreachable!("an admit-paths request reports its admission, not {other:?}"),
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
