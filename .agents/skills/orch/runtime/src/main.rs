//! The `orch-runtime` command: the versioned boundary scripts and hosts
//! speak to the library through. Every verb prints one JSON reply on stdout;
//! a refusal also prints one keyed line on stderr and exits 1. A usage error
//! prints `orch-runtime: usage` and clap's message on stderr and exits 2,
//! clap's own convention and agent-runtime's, with no reply: there was no
//! request to answer.
use agent_runtime::record::{self, Locking};
use std::ffi::{OsStr, OsString};
use std::io::Write;
use std::path::{Path, PathBuf};

use clap::error::ErrorKind;
use clap::{Args, Parser, Subcommand};

use agent_runtime::clock::SystemClock;
use agent_runtime::controller::run as controller_run;
use agent_runtime::journal::Env;
use orch_runtime::effects;
use orch_runtime::error::{Error, Result};
use orch_runtime::ops::{self, Request};
use orch_runtime::protocol::{self, Reply};
use orch_runtime::ready;
use orch_runtime::schedule;
use orch_runtime::settings::{self, Flags, Settings};
use orch_runtime::state;
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
    /// source.
    #[arg(long, global = true)]
    state_dir: Option<PathBuf>,
    /// Keep the settings reader off the project's private env file.
    #[arg(long, global = true)]
    no_private_env: bool,
    #[command(subcommand)]
    verb: Verb,
}

#[derive(Subcommand)]
enum Verb {
    /// Print the protocol and crate version.
    Version,
    /// Whether what each duty needs is ready on this computer, one line per
    /// duty on stdout: `ready duty=D`, or `unready duty=D program=P cause=C
    /// fix=F` per program it lacks; exit 1 where a duty asked about is
    /// unready.
    Ready {
        /// A duty asked about (repeatable; default every duty).
        #[arg(long = "duty")]
        duties: Vec<String>,
    },
    DevReturn {
        #[arg(long)]
        text: bool,
        #[command(subcommand)]
        op: ops::artifact::DevReturn,
    },
    Round {
        #[arg(long)]
        text: bool,
        #[command(subcommand)]
        op: ops::artifact::Round,
    },
    /// Mint a reviewer's artifact path, or check its artifact for review
    /// acceptance; `--text` prints the result object alone and exits 0
    /// accepted, 1 rejected, 2 refused.
    ReviewArtifact {
        #[arg(long)]
        text: bool,
        #[command(subcommand)]
        op: ops::review_artifact::ReviewArtifact,
    },
    /// Read or initialize one state file.
    State {
        #[command(subcommand)]
        op: StateOp,
    },
    /// Archive what a caller removes outside the state verbs, or name the
    /// archive root it files under.
    Archive {
        #[command(subcommand)]
        op: orch_runtime::archive::Verb,
    },
    /// Apply one operation request to a state file, run the live effect its
    /// intent names, and print the committed transition.
    Op {
        #[command(flatten)]
        target: Target,
        /// A JSON request tagged by `op`, read from this file.
        #[arg(
            long,
            required_unless_present = "request_json",
            conflicts_with = "request_json"
        )]
        request: Option<PathBuf>,
        /// The JSON request itself. A request carrying a finding's or a
        /// reviewer's own text names the file holding it.
        #[arg(long)]
        request_json: Option<String>,
        /// Exit by the live effect's outcome, the reply printed as ever:
        /// 0 confirmed, 3 failed, 75 unconfirmed with its intent left open.
        /// A transfer's or a stop's job is waited for within twice the
        /// verify bound and a minute; its runner up under a recorded
        /// identity is 0, the predecessor's retirement then the job's. The
        /// intent read last is the reply's `settled`.
        #[arg(long)]
        effect_exit: bool,
    },
    /// Read the live tracker and report lifecycle findings and verification boxes.
    ReconcileItems {
        #[arg(long)]
        stale_hours: Option<u64>,
        /// `ITEM=OWNER/REPO#N`, repeatable: a merged pull request the item's
        /// boxes are judged from in place of its branch's own, read from
        /// GitHub. A malformed value refuses `merged-invalid`; an item the
        /// inventory holds no Verifying or container record of refuses
        /// `merged-unjudged`.
        #[arg(long, value_name = "ITEM=OWNER/REPO#N")]
        merged: Vec<String>,
    },
    /// Re-observe every open intent by its recorded identity and complete or
    /// mark each, starting no new effect.
    Reconcile {
        #[command(flatten)]
        target: Target,
    },
    /// The detached job a transfer runs in: claim the open intent, run its
    /// effect from the request written beside the record, record the outcome.
    Job {
        #[command(flatten)]
        target: Target,
        #[arg(long)]
        intent: String,
        /// The mailbox program the launcher named for the owner notice.
        #[arg(long)]
        mail_program: Option<PathBuf>,
        /// The mailbox root the launcher named.
        #[arg(long)]
        mail_root: Option<PathBuf>,
        /// The tmux server the launcher named.
        #[arg(long)]
        socket: Option<PathBuf>,
    },
    /// Start a command detached as a recorded job: a transient user unit
    /// where the user manager lingers, else a `setsid` group, the record
    /// written whole before the start. Exit 0 started, 75 possibly started
    /// (keep the record and start nothing again), 1 `job-launch-failed`
    /// with nothing started. Reads no settings.
    LaunchJob {
        /// The job's name, which names its unit.
        #[arg(long)]
        name: String,
        /// The record naming how the job runs.
        #[arg(long)]
        record: PathBuf,
        /// A file the job's standard error is appended to.
        #[arg(long)]
        stderr: Option<PathBuf>,
        /// The command and its arguments, after `--`.
        #[arg(last = true, required = true)]
        argv: Vec<String>,
    },
    /// Stop the job a `launch-job` record names, by its unit or its recorded
    /// group identity: `stopped` is the runner it stopped, null where the
    /// job had already ended. Reads no settings.
    StopJob {
        #[arg(long)]
        record: PathBuf,
    },
    /// Judge, render or publish the owner progress report.
    Report {
        #[arg(value_parser = ["due", "render", "write"])]
        action: String,
        #[arg(long)]
        state: Option<PathBuf>,
        #[arg(long)]
        session_start: Option<u64>,
        #[arg(long)]
        repo: Vec<String>,
        #[arg(long)]
        summary_file: Option<PathBuf>,
        #[arg(long)]
        succession: bool,
        /// The credential ladder ran and this process was started again
        /// under its selection.
        #[arg(long, hide = true)]
        credential_selected: bool,
    },
    /// The standing scheduler over one fleet state.
    Watch {
        #[command(subcommand)]
        op: WatchOp,
    },
    /// One lane's state as the observation duty judges it, and the account
    /// a lane of this fleet launches on: each a read, printed; nothing is
    /// written.
    Lane {
        #[command(subcommand)]
        op: LaneOp,
    },
    /// Close a Linear container once its last child is Done or Canceled:
    /// one stdout line, `closed ID`, `deferred [ID...]` or `held ID RESET`,
    /// the diagnostics on stderr, a refusal `container-close: KEY ...` on
    /// stderr at exit 1 (2 for a malformed parent id).
    ContainerClose {
        /// A checkout of the repository: the shared main checkout it is a
        /// worktree of holds the closers' one lock.
        checkout: PathBuf,
        /// The container's item id; one that leads with `-` is a malformed
        /// id, refused as such, never a flag.
        #[arg(allow_hyphen_values = true)]
        parent: String,
    },
    /// The change classifier's render proof for a consumer refresh pull
    /// request, read from GitHub in the project checkout and judged, writing
    /// no approval: one stdout line `ci-proof: head=SHA class=render
    /// measured=true version=VERSION job=ID` at exit 0, else one stderr line
    /// `ci-proof: cause=WORD` at exit 1.
    CiProof {
        /// The pull request's number.
        #[arg(allow_hyphen_values = true)]
        pr: String,
        /// The pull request's full lowercase head SHA.
        #[arg(allow_hyphen_values = true)]
        head: String,
        /// OWNER/REPO.
        #[arg(long, allow_hyphen_values = true)]
        repo: String,
    },
    /// The turn-end check a harness hook runs: the harness payload on
    /// stdin, the harness's answer on stdout and stderr, its exit status the
    /// harness's. Reads no settings.
    TurnEnd {
        /// The directory the hook is installed in, which names the harness.
        #[arg(long)]
        hook_dir: PathBuf,
        /// The event judged: none for a turn end, or deliver, halt, start,
        /// prompt, compact, usage, row or lane. Any other word is refused by
        /// the check itself, in the harness's own shape.
        #[arg(allow_hyphen_values = true)]
        arm: Option<String>,
        /// The event a row is written under where the payload names none.
        #[arg(allow_hyphen_values = true)]
        event: Option<String>,
    },
    /// The merge cycles the fleet record holds, printed as text lines: the
    /// per-class totals, or a running lane's stage rows. No fleet record
    /// prints nothing.
    Cycle {
        #[command(subcommand)]
        op: CycleOp,
    },
    /// Judge the recorded controller's own marks: the context reading handed
    /// in, its account at the headroom trigger, the rate to its wall, and its
    /// process's memory against its cgroup cap where a mark is set. The reply
    /// names one mark reached, one figure unmeasured, or every mark read and
    /// none reached; nothing is launched or written.
    Marks {
        #[command(flatten)]
        target: Target,
        /// `TOKENS:WINDOW`, the window empty where no adapter named one;
        /// left out, the account marks alone are judged.
        #[arg(long)]
        context: Option<String>,
        /// The controller's harness where its record names none.
        #[arg(long)]
        harness: Option<String>,
        /// The controller's account directory where its record names none.
        #[arg(long)]
        account: Option<String>,
        /// With `--item`, the tokens an attached launch keeps for the
        /// returns still to come: the reply carries that reserve's answer
        /// beside the plain one. Without `--item` it refuses
        /// `reserve-unpaired`.
        #[arg(long, value_parser = parse_reserve)]
        agent_reserve: Option<u64>,
    },
    /// The controller an overseer launch opens: the overseer walk's choice
    /// for the fleet's first controller, or for the successor of the
    /// recorded one, as the pending a `start-controller` or
    /// `request-transfer` request carries, with the walk's own reply and,
    /// for a succession, the record's compare-and-swap set. Nothing is
    /// launched or written.
    Successor {
        #[command(flatten)]
        target: Target,
        /// The pane of the recorded controller this launch replaces; left
        /// out, the fleet's first controller is chosen.
        #[arg(long)]
        predecessor: Option<String>,
        /// The directory a first controller starts in, and a successor
        /// whose predecessor's record names none.
        #[arg(long)]
        cwd: PathBuf,
        /// The handoff the controller's brief names; left out, the
        /// predecessor record's own, else the default.
        #[arg(long)]
        handoff: Option<String>,
        /// The mark that sent the succession (`context`, `headroom`, `rate`
        /// or `memory`), which decides whether the predecessor's own account
        /// is left or kept.
        #[arg(long, requires = "predecessor", value_parser = |word: &str| {
            agent_runtime::controller::views::MarkKind::parse(word)
                .ok_or_else(|| format!("{word}: not context, headroom, rate or memory"))
        })]
        mark: Option<agent_runtime::controller::views::MarkKind>,
        /// The model recovery's successor: the predecessor's own launch on
        /// the model it was launched with, and the recovery's binding; no
        /// walk.
        #[arg(long, requires = "predecessor", conflicts_with = "mark")]
        recover: bool,
    },
    /// The overseer handoff: with `--body`, the snapshot written over the
    /// handoff, its `Start here` header naming the fleet record's
    /// generation and its State line every open lane ask the running lanes'
    /// mailboxes hold; with `--asks`, those asks read and printed, nothing
    /// written.
    Handoff {
        #[command(flatten)]
        target: Target,
        /// The prepared body below the header, a separate nonempty regular
        /// file.
        #[arg(long, required_unless_present = "asks")]
        body: Option<PathBuf>,
        /// The handoff the snapshot replaces.
        #[arg(long, default_value = ops::successor::HANDOFF)]
        handoff: PathBuf,
        /// Keep the installed snapshot's content ahead of the body.
        #[arg(long, requires = "body")]
        keep_prior: bool,
        /// Print the open lane asks alone.
        #[arg(long, conflicts_with = "body")]
        asks: bool,
    },
    /// Register the controller a person opened by hand, run from its own
    /// tmux pane (`$TMUX_PANE`): its launch identity from the SessionStart
    /// row its harness wrote, else read off the pane, and what the running
    /// harness process was started with (the account its environment names,
    /// the model, effort and permission words on its command line), so its
    /// next hand-over launches the same session; then the one
    /// `adopt-controller` transition, with the notices the session's
    /// coverage needs. An absent fleet state is made first.
    Register {
        #[command(flatten)]
        target: Target,
        /// The account the session spends, where its rows and environment
        /// do not say.
        #[arg(long)]
        account: Option<String>,
    },
    /// Judge the paths a running lane adds, or a launch before its record
    /// stands, against the fleet's holders under the launch lock, and widen
    /// the lane record where one stands.
    Admit {
        #[command(flatten)]
        target: Target,
        /// A JSON `admit-paths` request: the item, its tracker and
        /// repository, the paths added, the brief, the checkout and range
        /// the change-scope paths are read over, and the in-scope paths.
        #[arg(long)]
        request: PathBuf,
    },
    /// The cycle a work item runs at, through change-scope's launch arm:
    /// one stdout line `tier=CLASS brief=VERB cause=CAUSE[ DETAIL]
    /// estimate=N|- delta=N|- paths=N` at exit 0, else one keyed stderr line
    /// at exit 1 for a body to refile or 2 for an environment failure.
    Tier(ops::tier::Args),
    /// Wait while Copilot's work on a pull request's current head is in
    /// flight, bounded by `ORCH_COPILOT_HOLD_SECS` from the wait's start:
    /// `none`, `settled` or `expired`, a read that requests and writes
    /// nothing.
    CopilotWait {
        /// `owner/name`.
        #[arg(long)]
        repo: String,
        #[arg(long)]
        pr: u64,
    },
    /// Wait for a pull request's merge-queue outcome: its state and queue
    /// entry polled under a budget, what earlier polls saw recorded on the
    /// item before each next poll, an unresolved review thread while queued
    /// or armed disarmed and dequeued, a failed required check read through
    /// `verify-pr`. The reply is the result object the merge workflow routes.
    QueueWatch {
        /// The item whose record keeps the memory.
        #[arg(long)]
        item: String,
        /// `owner/name`.
        #[arg(long)]
        repo: String,
        #[arg(long)]
        pr: u64,
        /// Seconds between polls.
        #[arg(long, default_value_t = 180)]
        poll: u64,
        /// The budget in seconds, an upper bound.
        #[arg(long, default_value_t = 2400)]
        max_wait: u64,
        /// Read no check rollup for an armed, unenqueued pull request.
        #[arg(long)]
        no_check_probe: bool,
        /// Read no review threads and pull no arm.
        #[arg(long)]
        no_guard: bool,
    },
    /// Send a directive to a cloud session lane of the fleet: the send
    /// recorded owed on the lane first, made once through `lane-mail`, and its
    /// receipt stamped after.
    Send {
        /// The lane's item.
        #[arg(long)]
        item: String,
        /// The file holding the directive's text.
        #[arg(long)]
        file: PathBuf,
    },
    /// A validation run, started for a round and run as its detached job.
    Validate {
        #[command(subcommand)]
        op: ValidateOp,
    },
    /// Read an item's proof rows for a need: complete with the rows that prove
    /// the tree, pending on a ci row, or missing naming the tree and the
    /// narrowest declared mode it lacks. The read records nothing.
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
        /// The exception {by, id, excused} a round closed `pass-excused`
        /// began with; its failed run proves its tree for this read alone.
        #[arg(long)]
        exception_file: Option<std::path::PathBuf>,
    },
}

/// The need word a `--need` carries.
/// `ORCH_HANDOFF_AGENT_RESERVE_TOKENS`'s spelling: a whole count with no
/// leading zero. A count past `u64` reserves past every mark, so it is held
/// at `u64::MAX`.
fn parse_reserve(word: &str) -> std::result::Result<u64, String> {
    let canonical = !word.is_empty()
        && word.bytes().all(|b| b.is_ascii_digit())
        && (word == "0" || !word.starts_with('0'));
    if !canonical {
        return Err(format!("{word}: not a whole token count"));
    }
    Ok(word.parse::<u64>().unwrap_or(u64::MAX))
}

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

/// The validation run's verbs.
#[derive(Subcommand)]
enum ValidateOp {
    // A doc comment here would replace the arguments' long help, the
    // entry's contract, with its one line.
    #[command(about = "Run or inspect validation through the catalog command entry.")]
    Entry(Box<orch_runtime::validate::entry::Args>),
    /// Read the project validation mode without starting a command.
    Mode {
        #[arg(long)]
        worktree: PathBuf,
        #[arg(long)]
        base: Option<String>,
    },
    /// Read which optional stages the main checkout's committed policy
    /// runs, without probing any tool.
    Policy {
        #[arg(long)]
        base_checkout: PathBuf,
        #[arg(long, value_parser = parse_stage)]
        stage: Option<orch_runtime::policy::Stage>,
    },
    /// Resolve the mode from the project's declaration, classify the
    /// worktree, judge reuse over the item's proof rows, record the proof
    /// and the job on the round's admitted run, write the run directory
    /// the executor reads, and launch the run's job detached.
    Start {
        /// The item and round, or the admitted run directory the start
        /// forwards.
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
        /// The poll interval the run records.
        #[arg(long, default_value_t = orch_runtime::validate::POLL_DEFAULT, value_parser = clap::value_parser!(u64).range(1..))]
        poll: u64,
        /// Run the command whatever earlier row would answer it.
        #[arg(long)]
        fresh: bool,
        #[arg(long)]
        foreground: bool,
        #[arg(long)]
        reproduce: bool,
        #[arg(long)]
        restack: bool,
    },
    /// The run's job: run the kept executor as the bounded child, close
    /// the stage once with the lane's end notice owed, send it through the
    /// mailbox its start named and mark it.
    Run {
        #[arg(long)]
        item: String,
        #[arg(long)]
        round: String,
        #[arg(long)]
        run_dir: String,
        #[command(flatten)]
        reach: WatchReach,
    },
    /// Stop a started run: the stop recorded on its open stage, the job ended
    /// by its recorded identity through the launcher, the stage closed
    /// `stopped` with the lane's end notice.
    Stop {
        /// The item; without it the run directory names it, as the stop
        /// forwards.
        #[arg(long)]
        item: Option<String>,
        #[arg(long)]
        run_dir: String,
    },
}

fn parse_stage(word: &str) -> std::result::Result<orch_runtime::policy::Stage, String> {
    orch_runtime::policy::Stage::parse(word).ok_or_else(|| format!("{word}: not an optional stage"))
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

#[derive(Subcommand)]
enum LaneOp {
    /// What the item's in-flight lane is doing: the provider's status verb
    /// where its host declares one, else its recorded pane, foreground and
    /// screen (a Pi lane's rows), judged by the watch's classifier.
    Status {
        /// The lane's item key.
        #[arg(long)]
        item: String,
    },
    /// The listing a lane of this fleet launches under: the fleet's
    /// provider's rows beside this machine's, each row with its status
    /// word, and the roster lines the heartbeat prints.
    Roster,
    /// Which account a lane of this fleet launches on: the listing under
    /// the fleet's provider judged with the fleet's seats, its live charges
    /// and the host's repository rule.
    Pick {
        #[command(flatten)]
        target: Target,
        #[arg(long)]
        harness: String,
        /// The selector the harness runs.
        #[arg(long)]
        native_model: Option<String>,
        /// Judge one named account instead of choosing.
        #[arg(long)]
        lane: Option<String>,
        /// Judge the named account on the projection.
        #[arg(long, requires = "lane")]
        projected: bool,
        /// A config dir the pick omits before judging.
        #[arg(long = "exclude-lane")]
        exclude: Vec<String>,
        /// The item of the lane a relaunch replaces: its charge is left
        /// out, so a replacement adds no lane.
        #[arg(long)]
        replaces: Option<String>,
        /// The bound in percent used; `AGENT_RUNTIME_ACCOUNT_MAX_PCT` where unset.
        #[arg(long, value_parser = clap::value_parser!(u32).range(0..=100), conflicts_with = "min_headroom_pct")]
        max_pct: Option<u32>,
        /// The headroom the caller's own judgement triggers at: the same
        /// bound as `--max-pct 100-T`.
        #[arg(long, value_parser = clap::value_parser!(u32).range(0..=100))]
        min_headroom_pct: Option<u32>,
        /// Hold the account's own binding bucket to the bound beside the
        /// model's window.
        #[arg(long)]
        binding_floor: bool,
    },
    /// The lane preference walk: `ORCH_LANE_PREFERENCE`'s entries in
    /// order, each entry's host read through its capability line and each
    /// judged by `pick`'s rule; the reply names the entry taken and every
    /// entry skipped with the judge's word.
    Walk {
        #[command(flatten)]
        target: Target,
        /// A named lane (a directory or a listed alias) every entry is
        /// judged on.
        #[arg(long)]
        lane: Option<String>,
        /// A config dir every pick omits before judging.
        #[arg(long = "exclude-lane")]
        exclude: Vec<String>,
        /// The item of the lane this launch replaces: its charge is left
        /// out, and no cloud session is taken.
        #[arg(long)]
        replaces: Option<String>,
        /// The bound in percent used; `AGENT_RUNTIME_ACCOUNT_MAX_PCT` where unset.
        #[arg(long, value_parser = clap::value_parser!(u32).range(0..=100), conflicts_with = "min_headroom_pct")]
        max_pct: Option<u32>,
        /// The headroom the caller's own judgement triggers at.
        #[arg(long, value_parser = clap::value_parser!(u32).range(0..=100))]
        min_headroom_pct: Option<u32>,
        /// The harness of the session the walk is asked for, whose
        /// permission posture an entry of another harness must take.
        #[arg(long)]
        source_harness: Option<String>,
        /// That session's launch words; left out, the harness's row alone
        /// answers.
        #[arg(long, requires = "source_harness", allow_hyphen_values = true)]
        source_flags: Option<String>,
        /// The predecessor's harness: its own entry walks last.
        #[arg(long)]
        caller_harness: Option<String>,
        #[arg(long, requires = "caller_harness")]
        caller_lane: Option<String>,
        /// The model the successor runs; a numeric entry's model too.
        #[arg(long, requires = "caller_harness")]
        caller_model: Option<String>,
        #[arg(long, requires = "caller_harness")]
        caller_effort: Option<String>,
        /// The model the caller's account is judged on.
        #[arg(long, requires = "caller_harness")]
        caller_pick_model: Option<String>,
        /// Keep the caller's own lane without a pick.
        #[arg(long, requires = "caller_harness")]
        caller_keep: bool,
        /// At a context mark with the caller's account unmeasured: an entry
        /// of its harness whose pick finds none keeps the caller's lane
        /// where the judge still reads it unmeasured.
        #[arg(long, requires = "caller_harness")]
        keep_unmeasured: bool,
    },
    /// The live charges of a fleet's lanes per account, the count
    /// agent-runtime's account reading asks for: `{"fleet", "charges",
    /// "started"}`, each account by its canonical config dir.
    Charges {
        #[arg(long, conflicts_with = "file", required_unless_present = "file")]
        fleet: bool,
        #[arg(long)]
        file: Option<PathBuf>,
        /// The item of a lane a relaunch replaces, left out of the count.
        #[arg(long)]
        replaces: Option<String>,
    },
}

#[derive(Subcommand)]
enum CycleOp {
    /// One `rollup class=` row per class with a record, in the target
    /// table's order then `unclassified`, and each recorded stage's
    /// `stage item=` row; nothing is written.
    Report,
    /// The `rollup class=` rows, each appended to the fleet log as a
    /// `cycle` row under its class.
    Rollup,
    /// A running lane's `stage item=` rows, by start, read without a cycle.
    Stages {
        /// The lane's item key.
        item: String,
    },
}

#[derive(Subcommand)]
enum WatchOp {
    /// Claim the fleet state and run the duties until `watch stop`.
    Run {
        #[command(flatten)]
        target: Target,
        /// Seconds between two runs of a long-pass duty.
        #[arg(long, default_value_t = 240, value_parser = clap::value_parser!(u64).range(1..))]
        interval: u64,
        /// Long passes per heartbeat.
        #[arg(long, default_value_t = 25, value_parser = clap::value_parser!(u32).range(1..))]
        max_loops: u32,
        /// The stamp the heartbeat's `since=` carries.
        #[arg(long)]
        since: Option<String>,
        /// A live runner's pid to stop and replace, or the pid of a
        /// start-less repeat loop whose own pass started this runner and
        /// ends it, whose release is waited out.
        #[arg(long)]
        replace: Option<u32>,
        /// A repository (`owner/repo`) the GitHub inventories read beside the
        /// lanes' own and the connected ones.
        #[arg(long = "repo")]
        repos: Vec<String>,
        /// The credential ladder ran and this process was started again
        /// under its selection.
        #[arg(long, hide = true)]
        credential_selected: bool,
        #[command(flatten)]
        reach: WatchReach,
    },
    /// Start `watch run` detached beside the fleet state with these flags,
    /// reaching the mailbox and tmux server this command reaches, named on
    /// its command line; `launch-job`'s answer and exits.
    Start {
        #[command(flatten)]
        target: Target,
        #[arg(long)]
        interval: Option<u64>,
        #[arg(long)]
        max_loops: Option<u32>,
        #[arg(long)]
        since: Option<String>,
        #[arg(long)]
        replace: Option<u32>,
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

/// The mailbox a detached process reaches (a watch, a validation run) and
/// the tmux server a watch reaches, each named by its start: it inherits
/// its directory and environment from whatever started it, which may stand
/// in another checkout.
#[derive(Args)]
struct WatchReach {
    /// The mailbox program its notices, alerts and mail reads run.
    #[arg(long)]
    mail_program: Option<PathBuf>,
    /// The mailbox root they are delivered and read under, the directory a
    /// write runs in.
    #[arg(long)]
    mail_root: Option<PathBuf>,
    /// The tmux server it asks where a record names none.
    #[arg(long)]
    socket: Option<PathBuf>,
}

impl WatchReach {
    /// The mailbox the start named, refused before anything is read or
    /// run: `mailbox-unnamed` naming the missing flag; the server where the
    /// start named one.
    fn mailbox(&self) -> Result<agent_runtime::effects::Reach> {
        let missing = |field: &str| {
            Error::Runtime(agent_runtime::Error::refused(
                "mailbox-unnamed",
                &[("field", field)],
            ))
        };
        let mail_program = self
            .mail_program
            .clone()
            .ok_or_else(|| missing("mail_program"))?;
        let mail_root = self.mail_root.clone().ok_or_else(|| missing("mail_root"))?;
        Ok(agent_runtime::effects::Reach {
            mail_program,
            mail_root,
            socket: self.socket.clone(),
        })
    }

    /// The reach a watch's start named, refused before anything is read or
    /// asked: `mailbox-unnamed` naming the missing flag, else
    /// `tmux-server-unnamed`.
    fn named(&self) -> Result<agent_runtime::effects::Reach> {
        let reach = self.mailbox()?;
        if reach.socket.is_none() {
            return Err(Error::Runtime(agent_runtime::Error::refused(
                "tmux-server-unnamed",
                &[],
            )));
        }
        Ok(reach)
    }
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
    /// An item's close-out: every entry of the state directory named for
    /// the item leaves but its mailbox and its record's lock file, after one
    /// archive of them, the mailbox and each standing `--archive` path, which
    /// the caller removes after. With no fleet state the directory's
    /// retention runs too, since no watch runs it there.
    Remove {
        #[arg(long)]
        item: String,
        #[arg(long)]
        archive: Vec<PathBuf>,
    },
    /// Create a state file with the init object, refusing a standing file.
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
    /// The value at a JSON pointer; the whole record with none.
    Get {
        #[command(flatten)]
        target: Target,
        pointer: Option<String>,
    },
    /// Whether the record stands, with its key and path.
    Exists {
        #[command(flatten)]
        target: Target,
    },
    /// The record's path.
    Path {
        #[command(flatten)]
        target: Target,
    },
    /// Set the value at each JSON pointer, every pair in one write. A `{`
    /// or `[` prefix, `null`, `true`, `false` and an all-digit word are
    /// JSON; anything else is the string itself, so a quoted word keeps its
    /// quotes.
    Set {
        #[command(flatten)]
        target: Target,
        /// POINTER VALUE, repeated.
        #[arg(required = true, num_args = 2.., value_names = ["POINTER", "VALUE"])]
        pairs: Vec<String>,
    },
    /// Set the value at a JSON pointer to the one JSON value a file holds.
    SetFile {
        #[command(flatten)]
        target: Target,
        pointer: String,
        #[arg(value_name = "FILE")]
        source: PathBuf,
    },
    /// Append a value, judged as `set` judges it, to the array at each
    /// JSON pointer, created when absent, every pair in one write.
    Append {
        #[command(flatten)]
        target: Target,
        /// POINTER VALUE, repeated.
        #[arg(required = true, num_args = 2.., value_names = ["POINTER", "VALUE"])]
        pairs: Vec<String>,
    },
    /// Append the one JSON value a file holds to the array at a JSON
    /// pointer in place of every element whose `--key` field equals the
    /// value's; a value without that field refuses `upsert-key`.
    Upsert {
        #[command(flatten)]
        target: Target,
        pointer: String,
        #[arg(long)]
        key: String,
        #[arg(value_name = "FILE")]
        source: PathBuf,
    },
    /// Move a finding into the array at `--into`, dropping every entry
    /// with its location and description from each `--drop` array first.
    /// The entry is the file's one value, or with `--element` the
    /// description and location of the element at that pointer in it, each
    /// `--field NAME=VALUE` beside them and an empty value left out.
    Bucket {
        #[arg(long)]
        item: String,
        #[arg(long)]
        into: String,
        #[arg(long)]
        drop: Vec<String>,
        #[arg(long)]
        element: Option<String>,
        #[arg(long = "field", value_name = "NAME=VALUE")]
        fields: Vec<String>,
        #[arg(value_name = "FILE")]
        source: PathBuf,
    },
    /// Close every member of the map at a JSON pointer: its `status`
    /// `closed`.
    CloseAll {
        #[command(flatten)]
        target: Target,
        pointer: String,
    },
    /// A model switch's checks, as the turn-end hook records them.
    ModelCheck {
        #[command(subcommand)]
        op: ModelCheckOp,
    },
    /// Fill the controller record's server start, and its harness, home and
    /// native session where it names none, for the session it names;
    /// another session refuses `overseer-native-unbound`.
    Heal {
        #[command(flatten)]
        target: Target,
        #[arg(long)]
        server: String,
        #[arg(long)]
        pane: String,
        #[arg(long)]
        start: String,
        #[arg(long, default_value = "")]
        harness: String,
        #[arg(long, default_value = "")]
        home: String,
        #[arg(long, default_value = "")]
        session: String,
    },
    /// Append the one JSON value a file holds to the array at a JSON
    /// pointer, created when absent; under `--unique`, nothing where the
    /// array already holds that value.
    AppendFile {
        #[command(flatten)]
        target: Target,
        pointer: String,
        #[arg(value_name = "FILE")]
        source: PathBuf,
        #[arg(long)]
        unique: bool,
    },
    /// Merge the one JSON object a file holds into the fleet record's lane
    /// `--lane`: each field it names replaces the lane's, and its
    /// `obligation` binds only where the lane names none.
    Merge {
        #[command(flatten)]
        target: Target,
        #[arg(long)]
        lane: String,
        #[arg(value_name = "FILE")]
        source: PathBuf,
    },
    /// Add one to the number at a JSON pointer; an absent field counts
    /// from 0.
    Increment {
        #[command(flatten)]
        target: Target,
        pointer: String,
    },
    /// Set the field at a JSON pointer to the current epoch seconds.
    SetNow {
        #[command(flatten)]
        target: Target,
        pointer: String,
    },
    /// Set the field at a JSON pointer to the commit a checkout's HEAD
    /// names.
    SetGitHead {
        #[command(flatten)]
        target: Target,
        pointer: String,
        /// The checkout; the working directory when unset.
        #[arg(long)]
        worktree: Option<PathBuf>,
    },
    /// A round cap: the resolved limit, or `below` or `at-cap` over the
    /// item's own count or a given one.
    Cap {
        /// REVIEW_MAX_CYCLES, REVIEW_MAX_EXTERNAL_ROUNDS or CI_FIX_MAX_CYCLES.
        setting: String,
        #[arg(long, conflicts_with = "count")]
        item: Option<String>,
        #[arg(long)]
        count: Option<u64>,
    },
    /// A pull request's automatic retry budget: spend one attempt, or
    /// restart it.
    HeadBudget {
        #[command(subcommand)]
        op: HeadBudgetOp,
    },
    /// The stop a pull request is told: record it and render its comment,
    /// or lift it.
    PostPrStop {
        #[command(subcommand)]
        op: StopOp,
    },
    /// The fleet log: its two reads and the row append.
    Log {
        #[command(subcommand)]
        op: LogOp,
    },
    /// The owner's standing instructions.
    Standing {
        #[command(subcommand)]
        op: StandingOp,
    },
    /// Mint a key for work with no issue id; writes nothing.
    NewLocalKey,
    /// Mint a round token, set it at a JSON pointer and report it.
    NewRoundId {
        #[command(flatten)]
        target: Target,
        pointer: String,
    },
    /// The owner progress report's path, its directory created.
    ProgressReportPath {
        /// The report a succession writes.
        #[arg(long)]
        succession: bool,
    },
    /// Whether the item's handoff record stands in any place it is read.
    HandoffStanding {
        #[arg(long)]
        item: String,
        /// The lane root whose `tmp` is read after the state directory.
        #[arg(long)]
        worktree: Option<PathBuf>,
    },
    /// Stamp the item's handoff record resumed in every place it stands.
    HandoffResume {
        #[arg(long)]
        item: String,
        /// The lane root whose `tmp` is read after the state directory.
        #[arg(long)]
        worktree: Option<PathBuf>,
    },
    /// The recorded finding occurrences.
    Findings {
        #[command(subcommand)]
        op: FindingsOp,
    },
}

#[derive(Args)]
struct CheckFields {
    #[arg(long)]
    session: String,
    #[arg(long)]
    outcome: String,
    #[arg(long, default_value = "")]
    cause: String,
    #[arg(long, default_value = "")]
    launched: String,
    #[arg(long, default_value = "")]
    observed: String,
    /// The record the check is bound to, as the caller read it.
    #[arg(long)]
    expected: PathBuf,
}

#[derive(Subcommand)]
enum ModelCheckOp {
    /// The item's once-only notice of an unavailable model for a session:
    /// `recorded` false where any check of the session stands.
    Slot {
        #[arg(long)]
        item: String,
        #[arg(long)]
        session: String,
        #[arg(long, default_value = "")]
        cause: String,
        #[arg(long, default_value = "")]
        observed: String,
    },
    /// The check of a switch on the item's own record (`--item`), or on the
    /// fleet record's lane (`--fleet --lane ITEM`) or controller
    /// (`--fleet`): `acquired`, `duplicate` or `stale`.
    Record {
        #[command(flatten)]
        target: Target,
        #[arg(long)]
        lane: Option<String>,
        #[command(flatten)]
        fields: CheckFields,
    },
    /// A replacement's first turn end: the lane's switched check `passed`.
    Reset {
        #[command(flatten)]
        target: Target,
        #[arg(long)]
        lane: String,
        #[arg(long)]
        session: String,
        #[arg(long)]
        expected: PathBuf,
    },
    /// Mark the session's standing switched check on the item's record
    /// (`--item`), the fleet record's lane (`--fleet --lane ITEM`) or
    /// controller (`--fleet`) started, before its recovery starts:
    /// `started_now` false on a repeat; no such check refuses
    /// `model-check-missing`.
    Start {
        #[command(flatten)]
        target: Target,
        #[arg(long)]
        lane: Option<String>,
        #[arg(long)]
        session: String,
    },
}

#[derive(Subcommand)]
enum HeadBudgetOp {
    /// `continue` with the attempt spent, or `at-cap` with nothing written.
    Take {
        #[arg(long)]
        item: String,
        /// `review-wait` restarts its count on a new head; `ci-fix` counts
        /// across heads.
        #[arg(long, value_parser = parse_budget_kind)]
        kind: orch_runtime::ops::store::BudgetKind,
        #[arg(long)]
        head: String,
    },
    /// Restart the budget: `reset`, or `none` where nothing was spent.
    Reset {
        #[arg(long)]
        item: String,
        #[arg(long, value_parser = parse_budget_kind)]
        kind: orch_runtime::ops::store::BudgetKind,
    },
}

/// The budget word a `--kind` carries.
fn parse_budget_kind(
    word: &str,
) -> std::result::Result<orch_runtime::ops::store::BudgetKind, String> {
    orch_runtime::ops::store::BudgetKind::parse(word)
        .ok_or_else(|| format!("{word}: not review-wait or ci-fix"))
}

#[derive(Args)]
struct StopFields {
    #[arg(long)]
    item: String,
    #[arg(long)]
    name: String,
    #[arg(long)]
    gate: String,
    #[arg(long)]
    remaining: String,
    /// The Markdown comment, rendered where this call records the stop.
    #[arg(long)]
    comment_file: PathBuf,
}

#[derive(Subcommand)]
enum StopOp {
    /// Record the stop, replacing a standing one.
    Record(StopFields),
    /// Record the stop where none stands; keep a standing one.
    RecordIfEmpty(StopFields),
    /// Lift the standing stop: `cleared`, or `none` where none stood.
    Clear {
        #[arg(long)]
        item: String,
    },
}

#[derive(Subcommand)]
enum LogOp {
    /// The last `ORCH_TAKEOVER_ROWS` rows but `cycle` and `token`; none
    /// where no fleet record stands.
    Takeover {
        #[command(flatten)]
        target: Target,
    },
    /// Every proposal and ruling row.
    Audit {
        #[command(flatten)]
        target: Target,
    },
    /// Append the row a file holds, its `at` stamped when absent and its
    /// text bounded by `ORCH_FLEET_LOG_ROW_BYTES`.
    Append {
        #[command(flatten)]
        target: Target,
        #[arg(value_name = "FILE")]
        source: PathBuf,
    },
}

#[derive(Subcommand)]
enum StandingOp {
    /// Append the instruction a file holds, its `at` stamped when absent.
    Add {
        #[command(flatten)]
        target: Target,
        #[arg(value_name = "FILE")]
        source: PathBuf,
    },
    /// Replace the array with the one a file holds and record the lift as
    /// one ruling row in the same write.
    Lift {
        #[command(flatten)]
        target: Target,
        #[arg(value_name = "FILE")]
        source: PathBuf,
    },
}

#[derive(Subcommand)]
enum FindingsOp {
    /// `{prior, classes}` over the recorded occurrences, for the requests a
    /// file holds or for every known class.
    Query {
        #[arg(long)]
        item: String,
        file: Option<PathBuf>,
    },
    /// Record the verified findings a batch file holds: a new identity
    /// joins, a known identity under the same class adds nothing, another
    /// class refuses and leaves coverage unknown.
    Record {
        #[arg(long)]
        item: String,
        file: PathBuf,
    },
}

/// The checkout the runtime runs in and the settings it acts on, resolved once
/// per process from the command line, the project files and the environment.
fn resolve_settings(flags: &Flags) -> Result<Settings> {
    let cwd = std::env::current_dir()
        .map_err(|e| Error::Runtime(agent_runtime::Error::io("cwd", PathBuf::from("."), e)))?;
    let roots = agent_runtime::settings::roots(&cwd)?;
    let environment: Vec<(OsString, OsString)> = std::env::vars_os().collect();
    settings::load(&roots, &environment, flags)
}

#[allow(
    clippy::disallowed_methods,
    reason = "a worktree that is no directory is the owner's own `not-directory` refusal, never the settings root resolver's; the read only picks the settings root"
)]
fn artifact_settings(flags: &Flags, worktree: Option<&Path>) -> Result<Settings> {
    match worktree.filter(|w| w.is_dir()) {
        Some(worktree) => {
            let environment: Vec<(OsString, OsString)> = std::env::vars_os().collect();
            settings::load(
                &agent_runtime::settings::roots(worktree)?,
                &environment,
                flags,
            )
        }
        None => resolve_settings(flags),
    }
}

fn artifact_reply(result: Result<ops::artifact::Answer>, text: bool, entry: &str) -> ! {
    let (value, status) = match result {
        Ok(answer) => {
            let value = if text {
                answer.text
            } else {
                serde_json::to_string(&Reply::ok(answer.value))
                    .expect("serializable artifact answer")
            };
            (value, answer.status)
        }
        Err(error) => {
            let prefix = if text { entry } else { "orch-runtime" };
            let cause = match &error {
                Error::Artifact { cause, .. } => cause.clone(),
                _ => error.to_string(),
            };
            let _ = writeln!(
                std::io::stderr().lock(),
                "{prefix}: {} {cause}",
                error.key()
            );
            if text {
                std::process::exit(2);
            }
            (
                serde_json::to_string(&Reply::<()>::refused(&error)).expect("serializable refusal"),
                1,
            )
        }
    };
    let _ = writeln!(std::io::stdout().lock(), "{value}");
    std::process::exit(status)
}

/// The file a target names: the path, or the item or fleet file under the
/// resolved state directory.
fn target_path(target: &Target, settings: &Settings) -> PathBuf {
    if let Some(file) = &target.file {
        return file.clone();
    }
    if target.fleet {
        return record::fleet_path(&settings.state_dir);
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
/// `value` as the reply, the process exiting `status` once it is printed
/// where the reply's outcome names a status of its own.
fn replied(value: serde_json::Value, status: i32) -> Result<serde_json::Value> {
    if status != 0 {
        let _ = writeln!(
            std::io::stdout().lock(),
            "{}",
            serde_json::to_string(&Reply::ok(value)).unwrap_or_default()
        );
        std::process::exit(status);
    }
    Ok(value)
}

/// The `ready` verb: the readiness lines of `duties` (every duty where
/// none is named) on stdout, the process exiting 1 where one is unready.
fn ready_verb(duties: &[String], flags: &Flags) -> Result<serde_json::Value> {
    let settings = resolve_settings(flags)?;
    let asked = if duties.is_empty() {
        ready::Duty::DUTIES.to_vec()
    } else {
        duties
            .iter()
            .map(|name| ready::Duty::from_word(name))
            .collect::<Result<Vec<_>>>()?
    };
    let (lines, all_ready) = ready::report(&asked, &settings)?;
    let mut out = std::io::stdout().lock();
    for line in lines {
        let _ = writeln!(out, "{line}");
    }
    drop(out);
    std::process::exit(if all_ready { 0 } else { 1 });
}

/// A detached job's launch as its verb answers it: exit 0 started, 75
/// possibly started, 1 `job-launch-failed` with nothing started.
fn launched(
    launch: &agent_runtime::effects::job::Launch,
    record: &Path,
) -> Result<serde_json::Value> {
    let status = match launch {
        agent_runtime::effects::job::Launch::Started { .. } => 0,
        agent_runtime::effects::job::Launch::Unanswered { .. } => {
            agent_runtime::effects::UNCONFIRMED_EXIT
        }
        agent_runtime::effects::job::Launch::Refused { cause } => {
            return Err(
                agent_runtime::Error::refused("job-launch-failed", &[("cause", cause)]).into(),
            );
        }
    };
    let mut value = serde_json::to_value(launch)?;
    value["record"] = serde_json::json!(record);
    replied(value, status)
}

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
        Verb::Ready { duties } => ready_verb(&duties, &flags)?,
        Verb::State { op } => state_verb(op, &flags, locking)?,
        Verb::Archive { op } => orch_runtime::archive::verb(op, &resolve_settings(&flags)?)?,
        Verb::Report {
            action,
            state,
            session_start,
            repo,
            summary_file,
            succession,
            credential_selected,
        } => {
            let invalid = match action.as_str() {
                "due" => summary_file.is_some() || succession,
                "render" => summary_file.is_some() || succession || session_start.is_some(),
                "write" => session_start.is_some(),
                _ => unreachable!("clap checks report actions"),
            };
            if invalid {
                return Err(
                    agent_runtime::Error::refused("report-args", &[("action", &action)]).into(),
                );
            }
            // A session's due names its start alone; every fleet request
            // names its fleet record and the repositories it reads.
            let missing = if session_start == Some(0) {
                Some("session-start")
            } else if session_start.is_some() {
                None
            } else if state.is_none() {
                Some("missing-state")
            } else if repo.is_empty() {
                Some("missing-repo")
            } else {
                None
            };
            if let Some(cause) = missing {
                return Err(agent_runtime::Error::refused(
                    "report-args",
                    &[("action", &action), ("cause", cause)],
                )
                .into());
            }
            let settings = resolve_settings(&flags)?;
            let now = Env::system()?.now_secs;
            let session = session_start.map(|start| watch::report::Session {
                start,
                fleet: state.clone(),
            });
            let fleet = state.unwrap_or_else(|| record::fleet_path(&settings.state_dir));
            let ctx = watch::report::Context::new(fleet, &settings, repo, Default::default());
            // The credential is selected where GitHub is first read: before a
            // render, and before a due's landed-item count, never before the
            // due answers that read nothing.
            let selected = |ctx: &watch::report::Context| -> Result<()> {
                if credential_selected {
                    Ok(())
                } else {
                    Err(reexec_with_github_auth(&ctx.settings))
                }
            };
            match action.as_str() {
                "due" => {
                    let line = match watch::report::cadence(&ctx, now, session.as_ref())? {
                        watch::report::Cadence::Answered(line) => line,
                        watch::report::Cadence::Count(owed) => {
                            selected(&ctx)?;
                            watch::report::landed(&ctx, now, owed)?
                        }
                    };
                    serde_json::json!({ "line": line })
                }
                "render" => {
                    selected(&ctx)?;
                    serde_json::json!({"body": watch::report::render(&ctx, now)?})
                }
                "write" => {
                    let summary = summary_file.ok_or_else(|| {
                        agent_runtime::Error::refused("report-summary", &[("cause", "missing")])
                    })?;
                    selected(&ctx)?;
                    watch::report::write(&ctx, now, &summary, succession)?
                }
                _ => unreachable!("clap checks the report action"),
            }
        }
        Verb::Op {
            target,
            request,
            request_json,
            effect_exit,
        } => {
            let settings = resolve_settings(&flags)?;
            let path = target_path(&target, &settings);
            let origin = request
                .clone()
                .unwrap_or_else(|| PathBuf::from("<request-json>"));
            let decoded = |e: serde_json::Error| Error::Request {
                path: origin.clone(),
                cause: e.to_string(),
            };
            let value: serde_json::Value = match (&request, &request_json) {
                (Some(file), _) => read_request(file)?,
                (None, Some(text)) => serde_json::from_str(text).map_err(decoded)?,
                (None, None) => unreachable!("clap requires one of the two"),
            };
            // A named record write starts no effect: it is one validated
            // transition, answered with its report.
            if let Some(record) = ops::records::Record::decode(&value) {
                let record = record.map_err(decoded)?;
                return ops::records::apply_record(
                    &path,
                    &record,
                    &settings.store,
                    &Env::system()?,
                    locking,
                );
            }
            let mut request: Request = serde_json::from_value(value).map_err(decoded)?;
            // The target's kind is the precondition of every operation,
            // checked before anything is read: a verification must not
            // reach GitHub for a target it could never record on.
            ops::target_kind(&path, &request)?;
            // An overseer's start or transfer opens on the overseer's own
            // handoff and takeover brief where the request names none.
            let held_brief = ops::successor::overseer_defaults(&mut request, &path, &settings)?;
            effects::companion_reach(&mut request, &settings)?;
            // What the settings refuse before any transition: a succession
            // under `AGENT_RUNTIME_CONTROLLER_SUCCESSION=off`.
            ops::admit(&request, &settings)?;
            let env = Env::system()?;
            // A push, a round's prune and a QA decision run their effects
            // between their own writes; a push or a prune answers with its
            // reply and the exit its outcome names.
            if let Request::RecordPush(r) = &request {
                let pushed = ops::push::run(&path, r, &settings, &flags, &env, locking)?;
                return replied(serde_json::to_value(&pushed)?, pushed.exit);
            }
            if let Request::PruneRound(r) = &request {
                let pruned = ops::prune_round(&path, r, &settings, locking)?;
                return replied(serde_json::to_value(&pruned)?, pruned.exit);
            }
            if let Request::RecordQaDecision(r) = &request {
                return ops::qa::run(&path, r, &settings, locking);
            }
            // A verification reads GitHub first and makes its one
            // transition through record-verification itself.
            if let Request::VerifyHead(r) = &request {
                return Ok(serde_json::to_value(verify_head(&path, r, &env, locking)?)?);
            }
            // A pull request's verification reads its current head first, then
            // judges and records it as verify-head does.
            if let Request::VerifyPr(r) = &request {
                return Ok(serde_json::to_value(ops::verify_pr::run(
                    &path,
                    r,
                    Path::new("gh"),
                    &env,
                    locking,
                )?)?);
            }
            if let Request::ApproveHead(r) = &request {
                return Ok(serde_json::to_value(ops::approve::run(
                    &path,
                    r,
                    &settings,
                    locking,
                    &SystemClock,
                )?)?);
            }
            // The review gate reads the pull request first, makes the one
            // request its head owes and records the verdict.
            if let Request::VerifyReview(r) = &request {
                return Ok(serde_json::to_value(ops::verify_review::run(
                    &path, r, &settings, &env, locking,
                )?)?);
            }
            // A lane's close reads its record, its tracker and its host
            // first, stops a hosted harness through its provider, then makes
            // its one close transition.
            if let Request::CloseLane(r) = &request {
                return Ok(serde_json::to_value(effects::close_lane(
                    &path,
                    r,
                    &settings,
                    &env,
                    locking,
                    &SystemClock,
                )?)?);
            }
            // An adoption reads the pane first and makes its one transition
            // on what it read.
            if let Request::AdoptController(r) = &request {
                return Ok(serde_json::to_value(effects::adopt_controller(
                    &path, r, &settings, locking,
                )?)?);
            }
            // A round's reconcile first sends the end notices its closed runs
            // still owe, the continuation a crash between a run's close and
            // its send left, through the fleet's mailbox.
            let notice_reach = matches!(request, Request::ReconcileRound(_))
                .then(|| effects::fleet_mailbox(&settings));
            if let Some(reach) = &notice_reach {
                orch_runtime::validate::run::deliver_owed(&settings, reach, &path, &env, locking)?;
            }
            // The notices earlier outcomes still owe are sent before the
            // request's own transition; a mark the store refused is in the
            // reply and fails nothing.
            let notices_unmarked = effects::send_owed_notices(
                &path,
                &request,
                &settings,
                &env,
                locking,
                &SystemClock,
            )?;
            // An acceptance makes its close, posts the round's summary through
            // the tracker CLI and records the comment's id; its reply is the
            // close's report.
            if let Request::AcceptResult(r) = &request {
                return Ok(serde_json::to_value(ops::accept(
                    &path, r, &settings, &env, locking,
                )?)?);
            }
            let applied = persist(&path, &request, &env, locking, &settings)?;
            // Every refusal from here on comes after the request's intent was
            // persisted: it names that intent, which stands for the reconcile,
            // so a caller never reads it as nothing done.
            let persisted = effects::persisted_intent(&applied.report).map(str::to_owned);
            let effected = || -> Result<serde_json::Value> {
                if let Some(held) = &held_brief {
                    held.write()?;
                }
                // The reconcile may have closed a runtime-started run and written
                // its end notice owed in that same transition; the owed walk runs
                // after it as well as before, so that notice is sent in this call.
                if let Some(reach) = &notice_reach {
                    orch_runtime::validate::run::deliver_owed(
                        &settings, reach, &path, &env, locking,
                    )?;
                }
                // Run the live effect the persisted intent names and record its
                // outcome; the committed outcome transition is the result.
                Ok(
                    match effects::run(
                        &path,
                        &request,
                        &applied.report,
                        &settings,
                        &env,
                        locking,
                        &SystemClock,
                    )? {
                        Some(outcome) => {
                            // An admitted request is not its effect: a caller that
                            // reads the status alone reads the effect's own outcome.
                            let settled = if effect_exit {
                                Some(match &outcome {
                                    effects::Effected::Recorded(applied) => {
                                        let ops::Report::RecordOutcome(r) = &applied.report else {
                                            unreachable!("record-outcome returns its own report")
                                        };
                                        controller_run::Settled::Recorded(r.intent.clone())
                                    }
                                    effects::Effected::Started(started) => {
                                        controller_run::Settled::Job(controller_run::await_job(
                                            &path,
                                            &started.intent,
                                            controller_run::job_bound(&settings.engine)?,
                                            &SystemClock,
                                        )?)
                                    }
                                })
                            } else {
                                None
                            };
                            let mut reply = serde_json::json!({
                                "persisted": applied,
                                "effect": outcome,
                            });
                            if !notices_unmarked.is_empty() {
                                reply["notices_unmarked"] = serde_json::to_value(notices_unmarked)?;
                            }
                            if let Some(settled) = settled {
                                reply["settled"] = serde_json::to_value(settled.intent())?;
                                let status = settled.status();
                                if status != 0 {
                                    let _ = writeln!(
                                        std::io::stdout().lock(),
                                        "{}",
                                        serde_json::to_string(&Reply::ok(reply))
                                            .unwrap_or_default()
                                    );
                                    std::process::exit(status);
                                }
                            }
                            reply
                        }
                        None => serde_json::to_value(applied)?,
                    },
                )
            };
            effected().map_err(|error| match persisted {
                Some(intent) => Error::Persisted {
                    intent,
                    error: Box::new(error),
                },
                None => error,
            })?
        }
        Verb::Reconcile { target } => {
            let settings = resolve_settings(&flags)?;
            let path = target_path(&target, &settings);
            let env = Env::system()?;
            serde_json::to_value(effects::reconcile(
                &path,
                &settings,
                &env,
                locking,
                &SystemClock,
            )?)?
        }
        Verb::Job {
            target,
            intent,
            mail_program,
            mail_root,
            socket,
        } => {
            // The job reaches only what its launcher named: a mailbox found
            // from the directory it inherited may be another checkout's.
            let missing = |field: &str| {
                Error::Runtime(agent_runtime::Error::refused(
                    "mailbox-unnamed",
                    &[("field", field)],
                ))
            };
            let reach = agent_runtime::effects::Reach {
                mail_program: mail_program.ok_or_else(|| missing("mail_program"))?,
                mail_root: mail_root.ok_or_else(|| missing("mail_root"))?,
                socket,
            };
            let settings = resolve_settings(&flags)?;
            let path = target_path(&target, &settings);
            let env = Env::system()?;
            serde_json::to_value(effects::run_job(
                &path,
                &intent,
                reach,
                &settings,
                &env,
                locking,
                &SystemClock,
            )?)?
        }
        Verb::LaunchJob {
            name,
            record,
            stderr,
            argv,
        } => {
            let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
            let launch = agent_runtime::effects::job::launch_command(
                &name,
                &record,
                &argv,
                stderr.as_deref(),
            );
            launched(&launch, &record)?
        }
        Verb::StopJob { record } => {
            serde_json::json!({"stopped": agent_runtime::effects::job::stop_recorded(&record)?})
        }
        Verb::ReconcileItems {
            stale_hours,
            merged,
        } => {
            let settings = resolve_settings(&flags)?;
            ready::admit(ready::Duty::ReconcileItems, &settings)?;
            watch::tracker::reconcile_items::repository(&settings.roots.project)?;
            serde_json::to_value(watch::tracker::reconcile_items::run(
                &settings,
                stale_hours,
                &merged,
                None,
                Env::system()?.now_secs,
            )?)?
        }
        Verb::Watch { op } => watch_verb(op, &flags, locking)?,
        Verb::DevReturn { op, text } => {
            let worktree = match &op {
                ops::artifact::DevReturn::Write(r) => Some(r.id.worktree.as_path()),
                ops::artifact::DevReturn::Check(r) => r.worktree.as_deref(),
            };
            let entry = match &op {
                ops::artifact::DevReturn::Write(_) => "dev-return-write",
                ops::artifact::DevReturn::Check(_) => "dev-artifact-check",
            };
            let result = artifact_settings(&flags, worktree).and_then(|settings| match op {
                ops::artifact::DevReturn::Write(r) => ops::artifact::write(&settings, &r),
                ops::artifact::DevReturn::Check(r) => {
                    ops::artifact::check(&settings, &r, &SystemClock)
                }
            });
            artifact_reply(result, text, entry)
        }
        Verb::Round { op, text } => {
            let worktree = match &op {
                ops::artifact::Round::Stamp(r) | ops::artifact::Round::Cut(r) => &r.id.worktree,
                ops::artifact::Round::Recover(r) => &r.id.worktree,
            };
            let entry = match &op {
                ops::artifact::Round::Recover(_) => "round-recover",
                ops::artifact::Round::Stamp(_) | ops::artifact::Round::Cut(_) => "dev-round-write",
            };
            let result = artifact_settings(&flags, Some(worktree)).and_then(|settings| {
                let env = Env::system()?;
                match op {
                    ops::artifact::Round::Stamp(r) => ops::artifact::stamp(&r, false, &env),
                    ops::artifact::Round::Cut(r) => ops::artifact::stamp(&r, true, &env),
                    ops::artifact::Round::Recover(r) => ops::artifact::recover(&settings, &r, &env),
                }
            });
            artifact_reply(result, text, entry)
        }
        Verb::ReviewArtifact { op, text } => {
            use ops::review_artifact::{self as review, ReviewArtifact};
            let result = match op {
                ReviewArtifact::Path(r) => review::path(&r, &SystemClock),
                ReviewArtifact::Check(r) => r
                    .issue
                    .as_deref()
                    .map(|issue| {
                        let caller = std::env::var("ORCH_STATE_DIR").ok();
                        review::state_dir(
                            issue,
                            &r.worktree,
                            flags.state_dir.as_deref(),
                            caller.as_deref(),
                        )
                        .map(|dir| (issue, dir))
                    })
                    .transpose()
                    .and_then(|state| {
                        let state = state.as_ref().map(|(issue, dir)| (*issue, dir.as_path()));
                        review::check_review(&r, state, &SystemClock)
                    }),
            };
            artifact_reply(result, text, "review-artifact-check")
        }
        Verb::Lane { op } => lane_verb(op, &flags)?,
        Verb::ContainerClose { checkout, parent } => {
            let settings = resolve_settings(&flags)?;
            let answer =
                ops::accept::container_close(&settings.reads.tracker_cli, &checkout, &parent);
            let mut err = std::io::stderr().lock();
            match answer {
                Ok(closed) => {
                    for note in &closed.notes {
                        let _ = writeln!(err, "{note}");
                    }
                    let _ = writeln!(std::io::stdout().lock(), "{}", closed.answer.line());
                    std::process::exit(0);
                }
                Err(refused) => {
                    for note in &refused.notes {
                        let _ = writeln!(err, "{note}");
                    }
                    let _ = writeln!(err, "{}", refused.line());
                    std::process::exit(refused.exit);
                }
            }
        }
        Verb::Tier(args) => {
            let settings = resolve_settings(&flags)?;
            std::process::exit(ops::tier::run(&settings.scope_paths_cli, &args));
        }
        Verb::CiProof { pr, head, repo } => {
            let settings = resolve_settings(&flags)?;
            ready::admit(ready::Duty::CiProof, &settings)?;
            match verify::ci_proof::refresh_verb(&settings, &pr, &head, &repo) {
                Ok(line) => {
                    let _ = writeln!(std::io::stdout().lock(), "{line}");
                    std::process::exit(0);
                }
                Err(cause) => {
                    let _ = writeln!(std::io::stderr().lock(), "ci-proof: cause={cause}");
                    std::process::exit(1);
                }
            }
        }
        Verb::TurnEnd {
            hook_dir,
            arm,
            event,
        } => {
            let answer = orch_runtime::turnend::run(
                &hook_dir,
                arm.as_deref(),
                event.as_deref(),
                flags.private_env,
                &mut std::io::stdin().lock(),
            );
            std::process::exit(answer.write());
        }
        Verb::Cycle { op } => {
            let settings = resolve_settings(&flags)?;
            let fleet = record::fleet_path(&settings.state_dir);
            let lines = match &op {
                CycleOp::Report => ops::cycle::rollup(&fleet, true)?,
                CycleOp::Rollup => {
                    ops::cycle::rollup_logged(&fleet, locking, &settings.store, &Env::system()?)?
                }
                CycleOp::Stages { item } => ops::cycle::stages(&settings, &fleet, item)?,
            };
            // The text the report and the overseer's reads take, a line each.
            let mut out = std::io::stdout().lock();
            for line in &lines {
                let _ = writeln!(out, "{line}");
            }
            std::process::exit(0);
        }
        Verb::Marks {
            target,
            context,
            harness,
            account,
            agent_reserve,
        } => {
            if agent_reserve.is_some() && target.item.is_none() {
                return Err(agent_runtime::Error::refused("reserve-unpaired", &[]).into());
            }
            let settings = resolve_settings(&flags)?;
            // A lane's reading is judged alone: no record and no account.
            if target.item.is_some() {
                let Some(context) = context.as_deref() else {
                    return Err(agent_runtime::Error::refused("context-unnamed", &[]).into());
                };
                return watch::overseer::lane_marks(&settings, context, agent_reserve);
            }
            let path = target_path(&target, &settings);
            let now = Env::system()?.now_secs;
            watch::overseer::marks_verb(
                &settings,
                &path,
                context.as_deref(),
                harness.as_deref(),
                account.as_deref(),
                now,
            )?
        }
        Verb::Successor {
            target,
            predecessor,
            cwd,
            handoff,
            mark,
            recover,
        } => {
            let settings = resolve_settings(&flags)?;
            let path = target_path(&target, &settings);
            if let (true, Some(pane)) = (recover, predecessor.as_deref()) {
                ops::successor::recovery(&settings, &path, pane)?
            } else {
                let now = Env::system()?.now_secs;
                ops::successor::successor(
                    &settings,
                    &path,
                    predecessor.as_deref(),
                    mark,
                    &cwd,
                    handoff.as_deref(),
                    now,
                )?
            }
        }
        Verb::Handoff {
            target,
            body,
            handoff,
            keep_prior,
            asks: _,
        } => {
            let settings = resolve_settings(&flags)?;
            let path = target_path(&target, &settings);
            match body {
                Some(body) => ops::successor::write_handoff(
                    &settings,
                    &path,
                    &body,
                    &handoff,
                    keep_prior,
                    &Env::system()?,
                )?,
                None => serde_json::json!({"asks": ops::successor::open_asks(&settings, &path)?}),
            }
        }
        Verb::Register { target, account } => {
            let settings = resolve_settings(&flags)?;
            ready::admit(ready::Duty::Register, &settings)?;
            let path = target_path(&target, &settings);
            match std::fs::metadata(&path) {
                Ok(_) => {}
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                    let fields = state::InitFields {
                        agent: String::new(),
                        worktree: String::new(),
                        branch: String::new(),
                        qa_labels: None,
                        sub_issues: None,
                    };
                    init_state(&path, &fields)?;
                }
                Err(e) => return Err(Error::Runtime(agent_runtime::Error::io("read", &path, e))),
            }
            effects::register_controller(&path, account.as_deref(), &settings, locking)?
        }
        Verb::Admit { target, request } => {
            let settings = resolve_settings(&flags)?;
            let path = target_path(&target, &settings);
            let request: ops::AdmitPaths = read_request(&request)?;
            let env = Env::system()?;
            serde_json::to_value(admit(&path, &request, &env, locking, &settings)?)?
        }
        Verb::Validate {
            op: ValidateOp::Entry(args),
        } => {
            std::process::exit(orch_runtime::validate::entry::dispatch(
                &args,
                &flags,
                &Env::system()?,
                locking,
            ));
        }
        Verb::Validate {
            op: ValidateOp::Mode { worktree, base },
        } => {
            let settings = orch_runtime::validate::entry::resolve_at(&worktree, &flags)?;
            let mode =
                orch_runtime::validate::entry::mode(&settings, &worktree, base, &Env::system()?)?;
            serde_json::json!({"mode": mode})
        }
        Verb::Validate {
            op:
                ValidateOp::Policy {
                    base_checkout,
                    stage,
                },
        } => orch_runtime::policy::reply(&base_checkout, stage, flags.private_env)?,
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
                    foreground,
                    reproduce,
                    restack,
                },
        } => {
            let settings = resolve_settings(&flags)?;
            let env = Env::system()?;
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
                foreground,
                reproduce,
                restack,
                prove: false,
            };
            let mut started = orch_runtime::validate::start(&settings, &request, &env, locking)?;
            if request.foreground && started.launched {
                started.outcome = orch_runtime::validate::run::run(
                    &settings,
                    &effects::fleet_mailbox(&settings),
                    &started.item,
                    &started.round_id,
                    &started.run_dir,
                    &env,
                    locking,
                )?
                .outcome;
            }
            serde_json::to_value(started)?
        }
        Verb::Validate {
            op:
                ValidateOp::Run {
                    item,
                    round,
                    run_dir,
                    reach,
                },
        } => {
            // The job reaches only the mailbox its start named, judged before
            // anything runs: one found from the directory it inherited may be
            // another checkout's.
            let reach = reach.mailbox()?;
            let settings = resolve_settings(&flags)?;
            let env = Env::system()?;
            serde_json::to_value(orch_runtime::validate::run::run(
                &settings, &reach, &item, &round, &run_dir, &env, locking,
            )?)?
        }
        Verb::Validate {
            op: ValidateOp::Stop { item, run_dir },
        } => {
            let settings = resolve_settings(&flags)?;
            let env = Env::system()?;
            serde_json::to_value(orch_runtime::validate::run::stop(
                &settings,
                &effects::fleet_mailbox(&settings),
                item.as_deref(),
                &run_dir,
                &env,
                locking,
            )?)?
        }
        Verb::ReadProof {
            item,
            tree,
            head,
            base,
            round,
            need,
            exception_file,
        } => {
            let settings = resolve_settings(&flags)?;
            let request = orch_runtime::ops::proof::ReadProof {
                need,
                tree,
                head,
                base,
                round,
                exception: exception_file
                    .as_deref()
                    .map(orch_runtime::state::Exception::read)
                    .transpose()?,
            };
            serde_json::to_value(orch_runtime::proof::run(&settings, &item, &request)?)?
        }
        Verb::CopilotWait { repo, pr } => {
            let settings = resolve_settings(&flags)?;
            let request = orch_runtime::ops::copilot_wait::CopilotWait {
                repo,
                pr,
                bound: orch_runtime::ops::copilot_wait::bound(&settings.review)?,
            };
            serde_json::to_value(orch_runtime::ops::copilot_wait::run(
                &request,
                Path::new("gh"),
                &SystemClock,
            )?)?
        }
        Verb::QueueWatch {
            item,
            repo,
            pr,
            poll,
            max_wait,
            no_check_probe,
            no_guard,
        } => {
            let settings = resolve_settings(&flags)?;
            let path = state::item_path(&settings.state_dir, &item);
            let env = Env::system()?;
            let request = orch_runtime::ops::queue_watch::QueueWatch {
                repo,
                pr,
                poll: std::time::Duration::from_secs(poll),
                max_wait: std::time::Duration::from_secs(max_wait),
                arm_grace: settings.queue_watch.arm_grace.get()?,
                confirm_polls: settings.queue_watch.confirm_polls.get()?,
                probe_interval: settings.queue_watch.probe_interval.get()?,
                check_probe: !no_check_probe,
                guard: !no_guard,
                reach_cmd: settings.queue_watch.reach_cmd.clone(),
            };
            let programs =
                orch_runtime::ops::queue_watch::Programs::installed(&settings.roots.project);
            serde_json::to_value(orch_runtime::ops::queue_watch::run(
                &path,
                &request,
                &programs,
                &settings,
                &SystemClock,
                &env,
                locking,
            )?)?
        }
        Verb::Send { item, file } => {
            let settings = resolve_settings(&flags)?;
            let path = record::fleet_path(&settings.state_dir);
            let env = Env::system()?;
            serde_json::to_value(orch_runtime::send::run(
                &path, &item, &file, &settings, &env, locking,
            )?)?
        }
    };
    Ok(value)
}

/// The word `watch run` is started again with once the ladder has run.
const CREDENTIAL_SELECTED: &str = "--credential-selected";

/// Select the GitHub credential this process and every program it starts
/// read with: before the claim, so a watch that cannot read GitHub never
/// stands as the fleet's watch, and before a report's GitHub reads, so a
/// stale inherited token leaves no window unread. The github skill's
/// ladder (`watch::github::select_sign_in`) prints the two token variables as it
/// leaves them, and this process starts itself again in place under that
/// environment with `--credential-selected`, which changes no running
/// thread's environment and keeps the pid and start the launcher recorded;
/// a watch renews the selection later through its handle
/// (`watch::github::install_sign_in`). A ladder with no working candidate refuses
/// `auth-failed`; one that cannot be run, and a restart that fails, refuse
/// with their cause. Returns only the refusal.
#[allow(
    clippy::disallowed_methods,
    reason = "the command's one restart of itself under the ladder's selection"
)]
fn reexec_with_github_auth(settings: &Settings) -> Error {
    let selected = match watch::github::select_sign_in(&settings.roots.project, &[]) {
        Ok(selected) => selected,
        Err(e) => return e,
    };
    let exe = match std::env::current_exe() {
        Ok(exe) => exe,
        Err(e) => return Error::Runtime(agent_runtime::Error::io("exe", PathBuf::from("."), e)),
    };
    let mut command = std::process::Command::new(&exe);
    command
        .args(std::env::args_os().skip(1))
        .arg(CREDENTIAL_SELECTED);
    for (name, value) in selected {
        if value.is_empty() {
            command.env_remove(name);
        } else {
            command.env(name, value);
        }
    }
    let e = std::os::unix::process::CommandExt::exec(&mut command);
    Error::Runtime(agent_runtime::Error::io("exec", exe, e))
}

/// The `watch` verbs. `run` runs the credential ladder, claims as this
/// process's identity, records the claim fields (the pane it serves, its
/// program and directory)
/// and registers every duty, one registration line each: the reconcile of
/// every open intent on the long cadence and the duties under `watch/`.
fn watch_verb(op: WatchOp, flags: &Flags, locking: Locking) -> Result<serde_json::Value> {
    // A run's reach is judged before the settings are read: a start that
    // names none has asked no server and alerted no mailbox.
    let named = match &op {
        WatchOp::Run { reach, .. } => Some(reach.named()?),
        WatchOp::Start { .. }
        | WatchOp::Status { .. }
        | WatchOp::Stop { .. }
        | WatchOp::Log { .. } => None,
    };
    let mut settings = resolve_settings(flags)?;
    settings.reach = named;
    let clock = SystemClock;
    match op {
        WatchOp::Run {
            target,
            interval,
            max_loops,
            since,
            replace,
            repos,
            credential_selected,
            reach: _,
        } => {
            if !credential_selected {
                ready::admit(ready::Duty::Watch, &settings)?;
                return Err(reexec_with_github_auth(&settings));
            }
            watch::github::install_sign_in(&settings.roots.project);
            let path = target_path(&target, &settings);
            let paths = watch::Paths::of(&path)?;
            let env = Env::system()?;
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
            )?;
            // The tracker read duty: the inventories once per pass, the
            // terminal closes, the heartbeat's inputs; the GitHub duty shares
            // its slot.
            let shared = watch::tracker::register(
                &mut runner,
                &path,
                &settings,
                &env,
                locking,
                since.clone(),
                repos.clone(),
            )?;
            // The verification duty on the tracker's slot, the heartbeat's
            // body on both slots, the report and the retention.
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
                &env,
                locking,
            );
            watch::report::register(&mut runner, &path, &settings, repos.clone(), shared.clone());
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
        WatchOp::Start {
            target,
            interval,
            max_loops,
            since,
            replace,
            repos,
        } => {
            let path = target_path(&target, &settings);
            let exe = std::env::current_exe().map_err(|e| {
                Error::Runtime(agent_runtime::Error::io("exe", PathBuf::from("."), e))
            })?;
            let mut program = vec![exe.display().to_string()];
            if let Some(dir) = &flags.state_dir {
                program.extend(["--state-dir".to_owned(), dir.display().to_string()]);
            }
            if !flags.private_env {
                program.push("--no-private-env".to_owned());
            }
            let mut words = Vec::new();
            let pairs = [
                ("--interval", interval.map(|n| n.to_string())),
                ("--max-loops", max_loops.map(|n| n.to_string())),
                ("--since", since),
                ("--replace", replace.map(|n| n.to_string())),
            ];
            for (flag, value) in pairs {
                if let Some(value) = value {
                    words.extend([flag.to_owned(), value]);
                }
            }
            for repo in repos {
                words.extend(["--repo".to_owned(), repo]);
            }
            let name = format!("watch-{}", Env::system()?.iso().replace(['-', ':'], ""));
            let (launch, record) = effects::start_watch(&path, &settings, &program, &words, &name)?;
            launched(&launch, &record)
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

/// The lane reads: a lane's state, and the account a lane of this fleet
/// launches on, each account verb a read through agent-runtime's one judge
/// with what only the fleet holds: the provider's rows, the fleet's seats
/// and live charges, the replaced lane and the host's repository rule.
#[allow(
    clippy::disallowed_methods,
    reason = "the command's one construction of the kernel host for the occupancy read; the judge acts on nothing"
)]
fn lane_verb(op: LaneOp, flags: &Flags) -> Result<serde_json::Value> {
    let settings = resolve_settings(flags)?;
    let now = Env::system()?.now_secs;
    let host = ops::Host::kernel();
    match op {
        LaneOp::Status { item } => Ok(watch::lanes::status(
            &settings,
            &record::fleet_path(&settings.state_dir),
            &item,
        )?),
        LaneOp::Charges {
            fleet: _,
            file,
            replaces,
        } => {
            let path = file.unwrap_or_else(|| record::fleet_path(&settings.state_dir));
            let facts = ops::accounts::fleet_facts(&path, &[], replaces.as_deref(), &host, now)
                .map_err(|cause| {
                    agent_runtime::Error::refused("fleet-unread", &[("cause", &cause)])
                })?;
            Ok(serde_json::json!({
                "fleet": path,
                "charges": facts.charges,
                "started": facts.started,
            }))
        }
        LaneOp::Roster => {
            settings.accounts.get()?;
            let today = agent_runtime::accounts::today(now);
            Ok(match ops::accounts::roster(&settings, None, now) {
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
        LaneOp::Pick {
            target,
            harness,
            native_model,
            lane,
            projected,
            exclude,
            replaces,
            max_pct,
            min_headroom_pct,
            binding_floor,
        } => {
            settings.accounts.get()?;
            let request = agent_runtime::accounts::PickRequest {
                harness: agent_runtime::harness::Harness::named(&harness)?,
                model: native_model,
                exclude,
                for_overseer: false,
                lane,
                projected,
                max_pct,
                min_headroom_pct,
                binding_floor,
                admit_unread_scope: false,
                opens_here: false,
            };
            Ok(ops::accounts::pick_fleet(
                &settings,
                &target_path(&target, &settings),
                &host,
                None,
                replaces.as_deref(),
                &request,
                now,
            )
            .reply())
        }
        LaneOp::Walk {
            target,
            lane,
            exclude,
            replaces,
            max_pct,
            min_headroom_pct,
            source_harness,
            source_flags,
            caller_harness,
            caller_lane,
            caller_model,
            caller_effort,
            caller_pick_model,
            caller_keep,
            keep_unmeasured,
        } => {
            settings.accounts.get()?;
            let request = agent_runtime::accounts::walk::WalkRequest {
                scope: agent_runtime::accounts::walk::Scope::Lane,
                preference: None,
                lane,
                exclude,
                max_pct,
                min_headroom_pct,
                source: source_harness
                    .map(|word| agent_runtime::harness::Harness::named(&word))
                    .transpose()?
                    .map(|harness| agent_runtime::accounts::walk::Source {
                        harness,
                        flags: source_flags
                            .map(|text| text.split_whitespace().map(str::to_owned).collect()),
                    }),
                caller: caller_harness
                    .map(|word| agent_runtime::harness::Harness::named(&word))
                    .transpose()?
                    .map(|harness| agent_runtime::accounts::walk::Caller {
                        harness,
                        lane: caller_lane,
                        model: caller_model,
                        effort: caller_effort,
                        pick_model: caller_pick_model,
                        keep: caller_keep,
                    }),
                keep_unmeasured,
            };
            Ok(ops::accounts::walk(
                &settings,
                &target_path(&target, &settings),
                &host,
                replaces.as_deref(),
                &request,
                now,
            )?
            .reply())
        }
    }
}

/// The baseline row kind holding each intent the reconcile last refused,
/// by its refusal key.
const RECONCILE_REFUSED: &str = "reconcile-refused";

/// What the reconcile duty publishes of its report: a line per open intent it
/// could not complete or mark, printed when the refusal is new or its key
/// changed and cleared when the intent is no longer refused,; a line per owed
/// session send no kept receipt settles, keyed the same way by item and cause;
/// and a line per owed notice sent whose mark the store refused. A deferral to
/// a live or unreadable owner is a reconciled outcome, not a refusal, and
/// prints nothing.
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
    // The baseline row kind holding each lane whose session send stands owed
    // with no receipt to settle it, by the settle's cause word; the line
    // prints once per cause.
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

/// The lock policy for the host whose `PATH` is `path_var`: the wait, and the
/// mutex wherever `flock(1)` is not on that path. The one lookup of the lock
/// tool, which decides the locking every write of this process takes.
#[allow(
    clippy::disallowed_methods,
    reason = "the command's one lookup of the lock tool"
)]
fn host_locking(path_var: Option<&OsStr>) -> Locking {
    Locking {
        wait: agent_runtime::record::Wait::DEFAULT,
        mkdir_mutex: !agent_runtime::record::flock_on_path(path_var),
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

/// The `state remove` verb: the item's close-out, then, where no fleet
/// state stands to run a watch, one retention pass over the directory. A
/// relative `--archive` path is the caller's working directory's.
fn remove_item(
    settings: &Settings,
    item: &str,
    archive: &[PathBuf],
    locking: Locking,
    now: u64,
) -> Result<serde_json::Value> {
    let project = &settings.roots.project;
    let cwd = std::env::current_dir()
        .map_err(|e| Error::Runtime(agent_runtime::Error::io("cwd", Path::new("."), e)))?;
    let archive: Vec<PathBuf> = archive.iter().map(|path| cwd.join(path)).collect();
    // The retention pass this verb runs where no fleet state stands reads
    // its days before anything is removed: a refusal after the removal
    // would answer refused over files already gone.
    if std::fs::metadata(record::fleet_path(&settings.state_dir)).is_err() {
        settings.retention_days.get()?;
    }
    let closed = orch_runtime::archive::close_out(
        &settings.archive_root,
        project,
        &settings.state_dir,
        item,
        &archive,
        locking,
        now,
    )?;
    let fleet = record::fleet_path(&settings.state_dir);
    let fleet_stands = match std::fs::metadata(&fleet) {
        Ok(_) => true,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => false,
        Err(e) => return Err(Error::Runtime(agent_runtime::Error::io("read", &fleet, e))),
    };
    let dir_stands = std::fs::metadata(&settings.state_dir).is_ok();
    let pruned = if fleet_stands || !dir_stands {
        serde_json::Value::Null
    } else {
        let pruned =
            watch::retention::pass(&fleet, &watch::Paths::of(&fleet)?, settings, locking, now)?;
        serde_json::json!({
            "paths": pruned.paths,
            "kept": pruned.archive,
            "unlocked": pruned.unlocked,
        })
    };
    Ok(serde_json::json!({
        "removed": closed.removed,
        "kept": closed.archive,
        "pruned": pruned,
    }))
}

/// The `state` verbs: a workflow's reads and writes of a record through the
/// store module, under the settings resolved once per process.
fn state_verb(op: StateOp, flags: &Flags, locking: Locking) -> Result<serde_json::Value> {
    use agent_runtime::controller::model::Place;
    use orch_runtime::ops::store::{self, Cap, CapSource, LogReader, StopMode, Write};
    let settings = resolve_settings(flags)?;
    let store_settings = &settings.store;
    let path_of = |target: &Target| target_path(target, &settings);
    let write = |target: &Target, write: Write| -> Result<serde_json::Value> {
        let env = Env::system()?;
        store::run_write(&path_of(target), locking, store_settings, &env, &write)
    };
    let item_target = |item: String| Target {
        file: None,
        item: Some(item),
        fleet: false,
    };
    match op {
        StateOp::Inspect { target } => Ok(serde_json::to_value(inspect_state(&path_of(&target))?)?),
        StateOp::Init {
            target,
            agent,
            worktree,
            branch,
            qa_labels,
            sub_issues,
        } => {
            let fields = state::InitFields {
                agent: agent.unwrap_or_default(),
                worktree: worktree.unwrap_or_default(),
                branch: branch.unwrap_or_default(),
                qa_labels: parse_array(qa_labels.as_deref())?,
                sub_issues: parse_array(sub_issues.as_deref())?,
            };
            Ok(serde_json::to_value(init_state(
                &path_of(&target),
                &fields,
            )?)?)
        }
        StateOp::Get { target, pointer } => {
            let doc = store::read(&path_of(&target))?;
            let pointer = pointer.unwrap_or_default();
            let value = store::get(&doc, &pointer)?;
            Ok(serde_json::json!({"pointer": pointer, "value": value}))
        }
        StateOp::Exists { target } => store::exists(&path_of(&target), &target_key(&target)),
        StateOp::Path { target } => Ok(serde_json::json!({
            "issue_id": target_key(&target),
            "path": path_of(&target).display().to_string(),
        })),
        StateOp::Set { target, pairs } => write(
            &target,
            paired(pairs, |pointer, value| Write::Set { pointer, value })?,
        ),
        StateOp::SetFile {
            target,
            pointer,
            source,
        } => write(
            &target,
            Write::SetFile {
                pointer,
                file: source,
            },
        ),
        StateOp::Append { target, pairs } => write(
            &target,
            paired(pairs, |pointer, value| Write::Append { pointer, value })?,
        ),
        StateOp::Upsert {
            target,
            pointer,
            key,
            source,
        } => write(
            &target,
            Write::Upsert {
                pointer,
                key,
                file: source,
            },
        ),
        StateOp::Bucket {
            item,
            into,
            drop,
            element,
            fields,
            source,
        } => {
            let fields = fields
                .iter()
                .map(|field| match field.split_once('=') {
                    Some((name, value)) if !name.is_empty() => {
                        Ok((name.to_owned(), value.to_owned()))
                    }
                    _ => Err(
                        agent_runtime::Error::refused("bucket-field", &[("field", field)]).into(),
                    ),
                })
                .collect::<Result<Vec<_>>>()?;
            write(
                &item_target(item),
                Write::Bucket(store::Bucket {
                    into,
                    drop,
                    file: source,
                    element,
                    fields,
                }),
            )
        }
        StateOp::CloseAll { target, pointer } => write(&target, Write::CloseAll { pointer }),
        StateOp::ModelCheck { op } => match op {
            ModelCheckOp::Slot {
                item,
                session,
                cause,
                observed,
            } => write(
                &item_target(item),
                Write::ModelSlot {
                    session,
                    cause,
                    observed,
                },
            ),
            ModelCheckOp::Record {
                target,
                lane,
                fields,
            } => {
                let place = match (target.fleet, lane) {
                    (false, _) => Place::Item,
                    (true, Some(lane)) => Place::Lane(lane),
                    (true, None) => Place::Controller,
                };
                write(
                    &target,
                    Write::ModelCheck(store::ModelCheck {
                        place,
                        check: agent_runtime::controller::model::Check {
                            session: fields.session,
                            outcome: fields.outcome,
                            cause: fields.cause,
                            launched: fields.launched,
                            observed: fields.observed,
                        },
                        expected: fields.expected,
                    }),
                )
            }
            ModelCheckOp::Reset {
                target,
                lane,
                session,
                expected,
            } => write(
                &target,
                Write::ModelReset {
                    lane,
                    session,
                    expected,
                },
            ),
            ModelCheckOp::Start {
                target,
                lane,
                session,
            } => {
                let place = match (target.fleet, lane) {
                    (false, _) => Place::Item,
                    (true, Some(lane)) => Place::Lane(lane),
                    (true, None) => Place::Controller,
                };
                write(&target, Write::ModelStart { place, session })
            }
        },
        StateOp::Heal {
            target,
            server,
            pane,
            start,
            harness,
            home,
            session,
        } => write(
            &target,
            Write::Heal(agent_runtime::controller::heal::Heal {
                server,
                pane,
                start,
                harness,
                home,
                session,
            }),
        ),
        StateOp::AppendFile {
            target,
            pointer,
            source,
            unique,
        } => write(
            &target,
            Write::AppendFile {
                pointer,
                file: source,
                unique,
            },
        ),
        StateOp::Merge {
            target,
            lane,
            source,
        } => write(&target, Write::LaneMerge { lane, file: source }),
        StateOp::Increment { target, pointer } => write(&target, Write::Increment { pointer }),
        StateOp::SetNow { target, pointer } => {
            let now = Env::system()?.now_secs;
            write(
                &target,
                Write::Set {
                    pointer,
                    value: serde_json::Value::from(now),
                },
            )
        }
        StateOp::SetGitHead {
            target,
            pointer,
            worktree,
        } => {
            let head = store::git_head(worktree.as_deref().unwrap_or(Path::new(".")))?;
            write(
                &target,
                Write::Set {
                    pointer,
                    value: serde_json::Value::String(head),
                },
            )
        }
        StateOp::Cap {
            setting,
            item,
            count,
        } => {
            let cap = Cap::parse(&setting)?;
            let path = state::item_path(&settings.state_dir, item.as_deref().unwrap_or_default());
            let doc = item.as_ref().map(|_| store::read(&path)).transpose()?;
            let source = match (&doc, count) {
                (Some(doc), _) => CapSource::Item(doc),
                (None, Some(count)) => CapSource::Count(count),
                (None, None) => CapSource::Bare,
            };
            store::cap(&path, store_settings, cap, &source)
        }
        StateOp::HeadBudget {
            op: HeadBudgetOp::Take { item, kind, head },
        } => write(&item_target(item), Write::HeadBudget { kind, head }),
        StateOp::HeadBudget {
            op: HeadBudgetOp::Reset { item, kind },
        } => write(&item_target(item), Write::HeadBudgetReset { kind }),
        StateOp::PostPrStop { op } => {
            let (mode, fields) = match op {
                StopOp::Record(fields) => (StopMode::Record, fields),
                StopOp::RecordIfEmpty(fields) => (StopMode::RecordIfEmpty, fields),
                StopOp::Clear { item } => {
                    return write(&item_target(item), Write::PostPrStopClear);
                }
            };
            let env = Env::system()?;
            let path = state::item_path(&settings.state_dir, &fields.item);
            let write = Write::PostPrStop {
                mode,
                name: fields.name,
                gate: fields.gate,
                remaining: fields.remaining,
            };
            store::post_pr_stop(
                &path,
                locking,
                store_settings,
                &env,
                &write,
                &fields.comment_file,
            )
        }
        StateOp::Log { op } => match op {
            LogOp::Takeover { target } => {
                let doc = store::read_if_standing(&path_of(&target))?;
                let rows = store::log_rows(doc.as_ref(), store_settings, LogReader::Takeover)?;
                Ok(serde_json::json!({"rows": rows}))
            }
            LogOp::Audit { target } => {
                let doc = store::read(&path_of(&target))?;
                let rows = store::log_rows(Some(&doc), store_settings, LogReader::Audit)?;
                Ok(serde_json::json!({"rows": rows}))
            }
            LogOp::Append { target, source } => write(&target, Write::LogAppend { file: source }),
        },
        StateOp::Standing { op } => match op {
            StandingOp::Add { target, source } => {
                write(&target, Write::StandingAdd { file: source })
            }
            StandingOp::Lift { target, source } => {
                write(&target, Write::StandingLift { file: source })
            }
        },
        StateOp::Remove { item, archive } => {
            let env = Env::system()?;
            remove_item(&settings, &item, &archive, locking, env.now_secs)
        }
        StateOp::NewLocalKey => {
            let key = store::local_key(&Env::system()?, std::process::id());
            Ok(serde_json::json!({"key": key}))
        }
        StateOp::NewRoundId { target, pointer } => {
            let token = Env::system()?.round_id();
            write(
                &target,
                Write::Set {
                    pointer,
                    value: serde_json::Value::String(token),
                },
            )
        }
        StateOp::ProgressReportPath { succession } => {
            let now = Env::system()?.now_secs;
            let path =
                store::progress_report_path(&store_settings.progress_report_dir, now, succession)?;
            Ok(serde_json::json!({"path": path.display().to_string()}))
        }
        StateOp::HandoffStanding { item, worktree } => {
            let root = handoff_root(&settings, flags, worktree.as_deref());
            store::handoff_standing(&settings.state_dir, &item, root.as_deref())
        }
        StateOp::HandoffResume { item, worktree } => {
            handoff_resume(&settings, flags, locking, &item, worktree.as_deref())
        }
        StateOp::Findings {
            op: FindingsOp::Query { item, file },
        } => {
            let doc = store::read(&state::item_path(&settings.state_dir, &item))?;
            let requests = file.as_deref().map(store::finding_requests).transpose()?;
            store::findings_query(&doc, requests)
        }
        StateOp::Findings {
            op: FindingsOp::Record { item, file },
        } => {
            let env = Env::system()?;
            let path = state::item_path(&settings.state_dir, &item);
            store::findings_record(&path, locking, store_settings, &env, &file)
        }
    }
}

/// The writes POINTER VALUE pairs name, each value judged as `set` judges
/// it: one write for one pair, else every pair in one transition.
fn paired(
    pairs: Vec<String>,
    each: impl Fn(String, serde_json::Value) -> orch_runtime::ops::store::Write,
) -> Result<orch_runtime::ops::store::Write> {
    use orch_runtime::ops::store::{self, Write};
    if !pairs.len().is_multiple_of(2) {
        return Err(agent_runtime::Error::refused(
            "pair-unmatched",
            &[("pointer", &pairs[pairs.len() - 1])],
        )
        .into());
    }
    let mut writes = Vec::with_capacity(pairs.len() / 2);
    let mut pairs = pairs.into_iter();
    while let (Some(pointer), Some(value)) = (pairs.next(), pairs.next()) {
        writes.push(each(pointer, store::judge(&value)?));
    }
    Ok(if writes.len() == 1 {
        writes.remove(0)
    } else {
        Write::Many(writes)
    })
}

/// The key a target's record is kept under: the item, `oversee` for the
/// fleet, the item a file's name carries.
fn target_key(target: &Target) -> String {
    if let Some(item) = &target.item {
        return item.clone();
    }
    if target.fleet {
        return "oversee".to_owned();
    }
    target
        .file
        .as_deref()
        .and_then(state::item_of)
        .map(str::to_owned)
        .unwrap_or_default()
}

/// The lane root whose `tmp` is the handoff record's second place: the
/// named worktree, else, with no state directory named either, the linked
/// worktree the caller runs in, whose launch may forbid writing the main
/// checkout.
fn handoff_root(settings: &Settings, flags: &Flags, worktree: Option<&Path>) -> Option<PathBuf> {
    if let Some(root) = worktree {
        return Some(root.to_path_buf());
    }
    if flags.state_dir.is_none() && settings.roots.project != settings.roots.common {
        return Some(settings.roots.project.clone());
    }
    None
}

/// Stamp the handoff record resumed in every place it stands, through the
/// `resume-handoff` transition on each, so no place keeps a spent record
/// standing. A place that could not be read refuses after the standing ones
/// are stamped; none standing refuses.
fn handoff_resume(
    settings: &Settings,
    flags: &Flags,
    locking: Locking,
    item: &str,
    worktree: Option<&Path>,
) -> Result<serde_json::Value> {
    use orch_runtime::ops::store::{self, Write};
    use orch_runtime::watch::lanes::{HandoffReading, handoff_places, handoff_read};
    let root = handoff_root(settings, flags, worktree);
    let mut resumed = Vec::new();
    let mut unread = None;
    for place in handoff_places(&settings.state_dir, item, root.as_deref()) {
        match handoff_read(&place) {
            HandoffReading::Stands { .. } => {
                let env = Env::system()?;
                // The fleet record's handoff is the overseer's own, outside
                // the item transitions; its stamp is the pointer write.
                let resumed_at = if state::Kind::of_path(&place) == state::Kind::Fleet {
                    let write = Write::Set {
                        pointer: "/handoff/resumed_at".to_owned(),
                        value: serde_json::Value::from(env.now_secs),
                    };
                    store::run_write(&place, locking, &settings.store, &env, &write)?;
                    env.now_secs
                } else {
                    let request = Request::ResumeHandoff(ops::ResumeHandoff {});
                    let applied = persist(&place, &request, &env, locking, settings)?;
                    let ops::Report::ResumeHandoff(report) = applied.report else {
                        unreachable!("a resume-handoff request reports its resume")
                    };
                    report.resumed_at
                };
                resumed.push(serde_json::json!({
                    "file": place.display().to_string(),
                    "resumed_at": resumed_at,
                }));
            }
            HandoffReading::Unreadable { path } => {
                unread.get_or_insert(path);
            }
            HandoffReading::None => {}
        }
    }
    if let Some(path) = unread {
        return Err(agent_runtime::Error::refused(
            "handoff-unread",
            &[("state-file", &path.display().to_string())],
        )
        .into());
    }
    if resumed.is_empty() {
        return Err(agent_runtime::Error::refused("handoff-none", &[("issue", item)]).into());
    }
    Ok(serde_json::json!({"resumed": resumed}))
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
    verify::run(
        path,
        r,
        Path::new("gh"),
        env,
        locking,
        verify::Caller::VerifyHead,
    )
}

/// The command's one store entry: the request's transition committed, judged
/// against the host facts a lane transition needs, the cap setting, the claim
/// store and the kernel's own reads.
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

/// The host a fleet transition judges against: the caps a launch judges, the
/// kernel's reads, the programs the admission reads through and the settings
/// the accounts judge reads a launch's account under.
#[allow(
    clippy::disallowed_methods,
    reason = "the command's one construction of the kernel host, handed to the store entries alone"
)]
fn kernel_host(settings: &Settings) -> ops::Host<'_> {
    ops::Host::kernel()
        .caps(settings)
        .admitting(ops::Clis {
            tracker: settings.reads.tracker_cli.clone(),
            gh: PathBuf::from("gh"),
            scope_paths: settings.scope_paths_cli.clone(),
            resolver: orch_runtime::repo::resolver(&settings.roots.project),
        })
        .judging(settings)
}

/// The `admit` verb's one store entry: the judgement committed under the
/// launch lock through the one dispatcher.
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
    // The account renewal re-executes this program for its step, apart
    // from the caller's process group.
    if agent_runtime::accounts::renewal_step(std::env::args_os().nth(1).as_deref()) {
        return;
    }
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
