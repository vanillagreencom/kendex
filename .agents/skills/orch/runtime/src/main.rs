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
    /// U6d: send a directive to a cloud session lane of the fleet: the send
    /// recorded owed on the lane first, made once through `lane-mail`, and
    /// its receipt stamped after (decision 31).
    Send {
        /// The lane's item.
        #[arg(long)]
        item: String,
        /// The file holding the directive's text.
        #[arg(long)]
        file: PathBuf,
    },
    /// U6h: the accounts judge's reads (step6-map § A10): the pick a
    /// launcher receives (decision 94 (b)) and the roster under the judge's
    /// statement.
    Accounts {
        #[command(subcommand)]
        op: AccountsOp,
    },
    /// U6a: a validation run, started for a round and run as its detached
    /// job (step6-map § A1).
    Validate {
        #[command(subcommand)]
        op: ValidateOp,
    },
    /// U6b: read an item's proof rows for a need (step6-map § A2): complete
    /// with the rows that prove the tree, pending on a ci row, or missing
    /// naming the tree and the narrowest declared mode it lacks. The read
    /// records nothing.
    ReadProof {
        #[arg(long)]
        item: String,
        /// The tree the need asks about: the worktree's snapshot tree.
        #[arg(long)]
        tree: String,
        /// The head the tree is committed at; a restack's recorded skip is
        /// read by it.
        #[arg(long)]
        head: Option<String>,
        /// The base the need judges from; a row over exactly it covers the
        /// need.
        #[arg(long)]
        base: Option<String>,
        /// The round whose own rows a recovery reads.
        #[arg(long, required_if_eq("need", "recovery"))]
        round: Option<String>,
        /// round, submit, restack or recovery.
        #[arg(long, value_parser = parse_need)]
        need: orch_runtime::ops::proof::Need,
    },
}

/// The need word a `--need` carries.
fn parse_need(word: &str) -> std::result::Result<orch_runtime::ops::proof::Need, String> {
    use orch_runtime::ops::proof::Need;
    match word {
        "round" => Ok(Need::Round),
        "submit" => Ok(Need::Submit),
        "restack" => Ok(Need::Restack),
        "recovery" => Ok(Need::Recovery),
        other => Err(format!("{other}: not round, submit, restack or recovery")),
    }
}

/// U6a: the validation run's verbs.
#[derive(Subcommand)]
enum ValidateOp {
    /// Resolve the mode from the project's declaration, classify the
    /// worktree, judge reuse over the item's proof rows, record the proof
    /// and the job on the round's admitted run, write the run directory
    /// the executor reads, and launch the run's job detached.
    Start {
        /// The item and round, or the admitted run directory the legacy
        /// start forwards.
        #[arg(long, requires = "round", conflicts_with = "run_dir")]
        item: Option<String>,
        #[arg(long, requires = "item")]
        round: Option<String>,
        #[arg(long, required_unless_present = "item")]
        run_dir: Option<String>,
        /// The base commit of a fix round; none for an implement round.
        #[arg(long)]
        base: Option<String>,
        /// A mode other than the narrowest the declaration admits.
        #[arg(long, value_parser = parse_mode)]
        mode: Option<orch_runtime::state::ValidateMode>,
        /// Why a wider mode than the narrowest is run; recorded with it.
        #[arg(long, requires = "mode")]
        cause: Option<String>,
        /// The caller's word: dev, submit or restack.
        #[arg(long, default_value = "dev")]
        caller: String,
        /// The poll interval the run records; the legacy `--poll`.
        #[arg(long, default_value_t = orch_runtime::validate::POLL_DEFAULT, value_parser = clap::value_parser!(u64).range(1..))]
        poll: u64,
        /// Run the command whatever earlier row would answer it.
        #[arg(long)]
        fresh: bool,
    },
    /// The run's job: run the kept executor as the bounded child, close
    /// the stage once with the lane's end notice owed, send it and mark it.
    Run {
        #[arg(long)]
        item: String,
        #[arg(long)]
        round: String,
        #[arg(long)]
        run_dir: String,
    },
    /// U6l: stop a started run: the stop recorded on its open stage, the
    /// job ended by its recorded identity through the launcher, the stage
    /// closed `stopped` with the lane's end notice (decision 188 (c)).
    Stop {
        /// The item; without it the run directory names it, as the legacy
        /// stop forwards.
        #[arg(long)]
        item: Option<String>,
        #[arg(long)]
        run_dir: String,
    },
}

/// The mode word a `--mode` carries.
fn parse_mode(word: &str) -> std::result::Result<orch_runtime::state::ValidateMode, String> {
    use orch_runtime::state::ValidateMode;
    match word {
        "full" => Ok(ValidateMode::Full),
        "range" => Ok(ValidateMode::Range),
        "ci" => Ok(ValidateMode::Ci),
        other => Err(format!("{other}: not full, range or ci")),
    }
}

/// U6h: the accounts judge's verbs.
#[derive(Subcommand)]
enum AccountsOp {
    /// Which account a launch spends: the listing judged with this fleet's
    /// seats and live charges; the reply carries `lanes pick`'s exit by
    /// number and the record or the counts it printed, so a caller reads
    /// the verdict it read before.
    Pick {
        #[command(flatten)]
        target: Target,
        #[arg(long)]
        harness: String,
        /// The selector the harness runs; the legacy `--native-model`.
        #[arg(long)]
        native_model: Option<String>,
        /// A config dir the pick omits before judging; the legacy
        /// `--exclude-lane`.
        #[arg(long = "exclude-lane")]
        exclude: Vec<String>,
        /// The item of the lane a relaunch replaces: its charge is left
        /// out, so a replacement adds no lane.
        #[arg(long)]
        replaces: Option<String>,
        /// Judge seats as ordinary accounts.
        #[arg(long)]
        for_overseer: bool,
        /// Judge one named account instead of choosing.
        #[arg(long)]
        lane: Option<String>,
        /// Judge the named account on the projection.
        #[arg(long)]
        projected: bool,
        /// The bound in percent used; `ORCH_LANE_MAX_PCT` where unset.
        #[arg(long, value_parser = clap::value_parser!(u32).range(0..=100), conflicts_with = "min_headroom_pct")]
        max_pct: Option<u32>,
        /// The headroom the caller's own judgement triggers at: the same
        /// bound as `--max-pct 100-T`, the succession walk's and the
        /// turn-end hook's mark (U8d).
        #[arg(long, value_parser = clap::value_parser!(u32).range(0..=100))]
        min_headroom_pct: Option<u32>,
        /// Hold the account's own binding bucket to the bound beside the
        /// model's window (U8d).
        #[arg(long)]
        binding_floor: bool,
        /// Print the lane's launch prefix, `VAR=<config dir>`, and exit by
        /// the answer's exit in place of the reply: the room check a
        /// consumer's `SECOND_OPINION_<NAME>_ROOM_CMD` runs (U8d).
        #[arg(long)]
        env: bool,
    },
    /// The listing under the judge's statement: each row with its status
    /// word, and the roster lines the heartbeat prints.
    Roster {
        /// The provider to read under; this machine's own read where
        /// unset.
        #[arg(long)]
        host: Option<String>,
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
            // U6g: a pull request's verification reads its current head
            // first, then judges and records it as verify-head does.
            if let Request::VerifyPr(r) = &request {
                return Ok(serde_json::to_value(ops::verify_pr::run(
                    &path, r, &env, locking,
                )?)?);
            }
            // An adoption reads the pane first and makes its one transition
            // on what it read.
            if let Request::AdoptController(r) = &request {
                return Ok(serde_json::to_value(effects::adopt_controller(
                    &path, r, &settings, locking,
                )?)?);
            }
            // U6a: a round's reconcile first sends the end notices its
            // closed runs still owe, the continuation a crash between a
            // run's close and its send left (decision 124f (28)).
            if let Request::ReconcileRound(_) = &request {
                orch_runtime::validate::run::deliver_owed(&settings, &path, &env, locking)?;
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
            // U6c: an acceptance makes its close, posts the round's summary
            // through the tracker CLI and records the comment's id
            // (step6-map § A8); its reply is the close's report.
            if let Request::AcceptResult(r) = &request {
                return Ok(serde_json::to_value(ops::accept(
                    &path,
                    r,
                    &settings.reads.tracker_cli,
                    &env,
                    locking,
                )?)?);
            }
            let applied = persist(&path, &request, &env, locking, &settings)?;
            // U6a: the reconcile may have closed a runtime-started run and
            // written its end notice owed in that same transition; the owed
            // walk runs after it as well as before, so that notice is sent
            // in this call (decision 184 (2)).
            if let Request::ReconcileRound(_) = &request {
                orch_runtime::validate::run::deliver_owed(&settings, &path, &env, locking)?;
            }
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
        Verb::Accounts { op } => accounts_verb(op, &flags)?,
        Verb::Watch { op } => watch_verb(op, &flags, locking)?,
        Verb::Admit { target, request } => {
            let settings = resolve_settings(&flags)?;
            let path = target_path(&target, &settings);
            let request: ops::AdmitPaths = read_request(&request)?;
            let env = system_env()?;
            serde_json::to_value(admit(&path, &request, &env, locking, &settings)?)?
        }
        // U6a
        Verb::Validate {
            op:
                ValidateOp::Start {
                    item,
                    round,
                    run_dir,
                    base,
                    mode,
                    cause,
                    caller,
                    poll,
                    fresh,
                },
        } => {
            let settings = resolve_settings(&flags)?;
            let env = system_env()?;
            let request = orch_runtime::validate::StartRequest {
                item,
                round,
                run_dir,
                base,
                mode,
                cause,
                caller,
                poll,
                fresh,
            };
            serde_json::to_value(orch_runtime::validate::start(
                &settings, &request, &env, locking,
            )?)?
        }
        Verb::Validate {
            op:
                ValidateOp::Run {
                    item,
                    round,
                    run_dir,
                },
        } => {
            let settings = resolve_settings(&flags)?;
            let env = system_env()?;
            serde_json::to_value(orch_runtime::validate::run::run(
                &settings, &item, &round, &run_dir, &env, locking,
            )?)?
        }
        // U6l
        Verb::Validate {
            op: ValidateOp::Stop { item, run_dir },
        } => {
            let settings = resolve_settings(&flags)?;
            let env = system_env()?;
            serde_json::to_value(orch_runtime::validate::run::stop(
                &settings,
                item.as_deref(),
                &run_dir,
                &env,
                locking,
            )?)?
        }
        // U6b
        Verb::ReadProof {
            item,
            tree,
            head,
            base,
            round,
            need,
        } => {
            let settings = resolve_settings(&flags)?;
            let request = orch_runtime::ops::proof::ReadProof {
                need,
                tree,
                head,
                base,
                round,
            };
            serde_json::to_value(orch_runtime::proof::run(&settings, &item, &request)?)?
        }
        // U6d
        Verb::Send { item, file } => {
            let settings = resolve_settings(&flags)?;
            let path = state::fleet_path(&settings.state_dir);
            let env = system_env()?;
            serde_json::to_value(orch_runtime::send::run(
                &path, &item, &file, &settings, &env, locking,
            )?)?
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
                &path,
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

/// U6h: the accounts judge's verbs, each a read: the pick over the
/// listing and this fleet's state, the roster over the listing.
#[allow(
    clippy::disallowed_methods,
    reason = "the command's one construction of the kernel host for the pick's occupancy read; the judge acts on nothing"
)]
fn accounts_verb(op: AccountsOp, flags: &Flags) -> Result<serde_json::Value> {
    let settings = resolve_settings(flags)?;
    let now = system_env()?.now_secs;
    match op {
        AccountsOp::Pick {
            target,
            harness,
            native_model,
            exclude,
            replaces,
            for_overseer,
            lane,
            projected,
            max_pct,
            min_headroom_pct,
            binding_floor,
            env,
        } => {
            let path = target_path(&target, &settings);
            let host = ops::Host::kernel(settings.lane_cap, Some(settings.claim_store.clone()));
            let request = ops::accounts::PickRequest {
                harness,
                model: native_model,
                exclude,
                replaces,
                for_overseer,
                lane,
                projected,
                max_pct,
                min_headroom_pct,
                binding_floor,
                host: None,
            };
            let answer = ops::accounts::pick_fleet(&settings, &path, &host, &request, now);
            if env {
                // The text form a consumer's room check reads: the account
                // variable the harness launches under (agent-runtime's
                // table) and the directory, on stdout at exit 0; any other
                // answer is its keyed line on stderr at the answer's exit.
                if let ops::accounts::PickAnswer::Lane(judged) = &answer {
                    let harness = agent_runtime::harness::Harness::parse(&request.harness)
                        .map(|h| h.account_var(request.model.as_deref()))
                        .unwrap_or("CLAUDE_CONFIG_DIR");
                    let _ = writeln!(
                        std::io::stdout().lock(),
                        "{harness}={}",
                        judged.row.config_dir
                    );
                } else {
                    let reply = answer.reply();
                    let _ = writeln!(
                        std::io::stderr().lock(),
                        "orch-runtime: account-{} harness={} exit={}",
                        reply["answer"].as_str().unwrap_or("unjudged"),
                        request.harness,
                        answer.exit()
                    );
                }
                std::process::exit(answer.exit());
            }
            Ok(answer.reply())
        }
        AccountsOp::Roster { host } => {
            let today = ops::accounts::today(now);
            Ok(match ops::accounts::roster(&settings, host.as_deref()) {
                Ok(roster) => serde_json::json!({
                    "read": true,
                    "accounts": roster.rows.len(),
                    "lines": roster.lines(&today),
                    "rows": roster.rows.iter().map(|r| serde_json::json!({
                        "alias": r.alias,
                        "config_dir": r.config_dir,
                        "harness": r.harness,
                        "measured_through": r.measured_through,
                        "status": r.status,
                        "word": r.word().text(),
                        "ended": r.ended(&today),
                        "record": r.raw,
                    })).collect::<Vec<serde_json::Value>>(),
                }),
                Err(cause) => serde_json::json!({"read": false, "cause": cause}),
            })
        }
    }
}

/// The baseline row kind holding each intent the reconcile last refused,
/// by its refusal key.
const RECONCILE_REFUSED: &str = "reconcile-refused";

/// What the reconcile duty publishes of its report: a line per open intent
/// it could not complete or mark, printed when the refusal is new or its
/// key changed and cleared when the intent is no longer refused, as the
/// legacy printed a standing `main-workflow-absent`; a line per owed session
/// send no kept receipt settles, keyed the same way by item and cause; and a
/// line per owed notice sent whose mark the store refused. A deferral to a
/// live or unreadable owner is a reconciled outcome, not a refusal, and
/// prints nothing (decisions 128 (5), 130).
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
    // U6d2 (decision 184 (5)): the baseline row kind holding each lane
    // whose session send stands owed with no receipt to settle it, by the
    // settle's cause word; the line prints once per cause.
    const DIRECTIVE_SEND_UNSETTLED: &str = "directive-send-unsettled";
    let unsettled = &run.directive_sends.sends_unsettled;
    for send in unsettled {
        if baseline.get(DIRECTIVE_SEND_UNSETTLED, &send.item) != Some(send.cause.as_str()) {
            produced.events.push(watch::Event::DirectiveSendUnsettled {
                item: send.item.clone(),
                cause: send.cause.clone(),
            });
            produced.changes.push(watch::Change::Set {
                kind: DIRECTIVE_SEND_UNSETTLED.to_owned(),
                identity: send.item.clone(),
                value: send.cause.clone(),
            });
        }
    }
    for item in baseline.identities(DIRECTIVE_SEND_UNSETTLED) {
        if !unsettled.iter().any(|s| s.item == item) {
            produced.changes.push(watch::Change::Clear {
                kind: DIRECTIVE_SEND_UNSETTLED.to_owned(),
                identity: item,
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
    verify::run(path, r, env, locking, verify::Caller::VerifyHead)
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
/// store, the kernel's reads, the programs the admission reads through and
/// the settings the accounts judge reads a launch's account under (U6i).
#[allow(
    clippy::disallowed_methods,
    reason = "the command's one construction of the kernel host, handed to the store entries alone"
)]
fn kernel_host(settings: &Settings) -> ops::Host<'_> {
    ops::Host::kernel(settings.lane_cap, Some(settings.claim_store.clone()))
        .admitting(ops::Clis {
            tracker: settings.reads.tracker_cli.clone(),
            gh: PathBuf::from("gh"),
            scope_paths: settings.scope_paths_cli.clone(),
        })
        .judging(settings)
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
