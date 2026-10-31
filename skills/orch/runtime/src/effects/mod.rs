//! The live effects an operation's intent names, run against the host and
//! recorded through `record-outcome`.
//!
//! A transition persists an intent and returns [`crate::ops::Effect`]; this
//! module turns that intent into a real launch, stop or succession on the
//! fleet's tmux server through `agent-runtime`, observes how far it got, and
//! applies a [`crate::ops::RecordOutcome`] with the outcome it saw. It starts
//! no process of its own beyond that crate's one runner, reads process and
//! native-session identity only through it, and never kills by name: a stop
//! whose recorded identity no longer matches records `unconfirmed`, never a
//! second effect.
//!
//! Every effect runs through one [`operation::Operation`] handle per intent
//! (decision 120): the handle owns the intent's recorded obligation set and
//! every primitive that acts on the host, writes the record before each
//! action and before each wait (decisions 62, 115 (A)), and is consumed by
//! the one terminal outcome the effect reaches. Nothing in `launch`, `stop`
//! or `transfer` names an obligation, builds a set or calls a tmux, process,
//! observe, session, receipt or job primitive: the set and its tokens are
//! private to `operation`, and the compiler's `disallowed-methods` list
//! (`clippy.toml`) refuses the primitives outside it. The pane an effect
//! opens registers itself
//! (decision 96); every process and pane read is three-valued (decision 99);
//! the identity a receipt proves, or the judge first reads, is the one
//! identity every later read, publication and retirement of that attempt
//! uses; the one reading that confirms a launch or lets a brief be delivered
//! is the judge's `idle` or `working` with the harness itself in the pane's
//! foreground (decision 60). A delivered brief is confirmed from the runner's
//! own native session file, bound once before the paste (decision 65).
//!
//! The outcomes follow the plan's effect contract. A launch confirms when
//! the harness holds the pane and is drawn at its composer or working within
//! the bound, fails when its pane is gone (the exec'd harness exited), and is
//! unconfirmed when the pane stands but neither was read within the bound. A
//! stop confirms when the recorded identity is gone after the exact
//! TERM/KILL, and is unconfirmed on an identity mismatch. A succession
//! checks every precondition and brings its runner to the composer before it
//! retires the predecessor, so a failure there leaves the predecessor in
//! control (`failed`); after retirement it delivers the held brief, confirms
//! the runner recorded that turn in its own session file, reads the runner's
//! identity and publishes it (decision 61), and a failure there is a
//! recoverable stopped transition (`unconfirmed` with the runner kept), never
//! a second controller.
//!
//! The effects are grouped by what they do to the host: `launch` opens a
//! lane's window and confirms the harness in it, `stop` ends a lane's owned
//! processes and window, `transfer` runs an overseer succession. This module
//! holds what they share: the run context, the dispatch, the launch spec and
//! command, the reconcile dispatch and the record reads. Every enum read
//! here is matched by its variants; the lint below holds that over the whole
//! module tree.

#![deny(clippy::wildcard_enum_match_arm)]

mod launch;
#[allow(
    clippy::disallowed_methods,
    reason = "the operation handle is the one owner of every effect primitive and of the clock's waits (decisions 120, 124e)"
)]
mod operation;
mod stop;
mod transfer;

pub(crate) use operation::Recorded;
pub use operation::job::{JobStarted, NoticeUnmarked};

use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::harness::Harness;
use agent_runtime::launch::{
    Brief, Compaction, LaunchCommand, LaunchIntent, Permission, QuestionTool,
};
use agent_runtime::protocol::Outcome;
use agent_runtime::reading::Reading;
use serde::Serialize;
use serde_json::{Value, json};

use crate::error::{Error, Result};
use crate::ops::{self, AdoptController, Applied, Effect, Env, OutcomeRecorded, Report, Request};
use crate::schedule::Clock;
use crate::settings::Settings;
use crate::state::{self, EffectOp, Intent, Lane, Locking, Overseer};

use operation::{EffectOutcome, Identity, Operation, ProcessReading, State, job};

/// How often a poll re-reads the record within its bound.
const POLL: Duration = Duration::from_millis(200);

/// What one effect run or reconcile acts with: the record, the settings,
/// the writer's stamp and lock policy, and the one clock every wait reads
/// (decision 121, Q16), reached only through the operation handle.
struct Run<'a> {
    path: &'a Path,
    settings: &'a Settings,
    env: &'a Env,
    locking: Locking,
    clock: &'a dyn Clock,
}

impl Run<'_> {
    /// The one recording boundary (decision 111 (A) (4)): the effect's
    /// outcome becomes the wire record in `operation` and nowhere else.
    fn apply_outcome(&self, outcome: EffectOutcome) -> Result<Applied> {
        operation::apply_outcome(self, outcome)
    }

    /// Where the pane of `intent_id` registers itself (decision 96).
    fn receipt_path(&self, intent_id: &str) -> PathBuf {
        state::receipt_path(&self.settings.state_dir, intent_id)
    }
}

/// How far a request's live effect got in this process: its outcome
/// recorded here, or handed to the detached job that runs a transfer or a
/// stop (decisions 76, 109 (3)), whose outcome a later read or reconcile
/// sees. Serialized as the record-outcome transition or as the job's start,
/// untagged, so a recorded effect reads as it always did.
#[derive(Debug, Serialize)]
#[serde(untagged)]
pub enum Effected {
    Recorded(Applied),
    Started(JobStarted),
}

/// Whether `request` names a live effect: one this module runs or hands to
/// a job once the request's transition persisted it.
fn has_live_effect(request: &Request) -> bool {
    match request {
        Request::LaunchLane(_)
        | Request::CloseOwnedResources(_)
        | Request::RequestTransfer(_)
        | Request::StartController(_)
        | Request::StopController(_) => true,
        Request::AdoptSession(_)
        | Request::BeginRound(_)
        | Request::RecordValidationAdmission(_)
        | Request::AdoptController(_)
        | Request::ClaimIntent(_)
        | Request::AcceptResult(_)
        | Request::RecordVerification(_)
        | Request::VerifyHead(_)
        | Request::ReconcileRound(_)
        | Request::RecordHandoff(_)
        | Request::ResumeHandoff(_)
        | Request::ParkLane(_)
        | Request::ReserveLane(_)
        | Request::ReleaseLane(_)
        | Request::RecordOutcome(_)
        | Request::RecordPhase(_)
        | Request::RecordProgress(_) => false,
    }
}

/// Send the notices earlier outcomes still owe, before a request with a
/// live effect is persisted (decision 124f (28)): the continuation a crash
/// between an outcome's write and its send left behind. It runs before the
/// request's own transition, so its mark is a write of its own and never
/// part of the request's; a mark the store refused is returned for the
/// reply and never fails the request (decision 124i (36)). A request with
/// no live effect walks nothing.
pub fn send_owed_notices(
    path: &Path,
    request: &Request,
    settings: &Settings,
    env: &Env,
    locking: Locking,
    clock: &dyn Clock,
) -> Result<Vec<NoticeUnmarked>> {
    if !has_live_effect(request) {
        return Ok(Vec::new());
    }
    let run = Run {
        path,
        settings,
        env,
        locking,
        clock,
    };
    job::send_owed_notices(&run)
}

/// What a reconcile answers: the committed outcome of every open intent it
/// completed or marked, the open intents it could not (decision 124l
/// (45)), and the owed notices of closed intents it sent whose mark the
/// store refused (decision 124i (36)).
#[derive(Debug, Serialize)]
pub struct ReconcileRun {
    pub reconciled: Vec<Applied>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub refused: Vec<IntentRefused>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub notices_unmarked: Vec<NoticeUnmarked>,
}

/// Run the effect a just-persisted intent names and record its outcome, or
/// reconcile an intent a repeated request found open, or hand a transfer to
/// its detached job. The returned value is the `record-outcome` transition,
/// so a caller sees the committed record, or the job's start. A request
/// with no live effect returns `None`.
pub fn run(
    path: &Path,
    request: &Request,
    report: &Report,
    settings: &Settings,
    env: &Env,
    locking: Locking,
    clock: &dyn Clock,
) -> Result<Option<Effected>> {
    let run = Run {
        path,
        settings,
        env,
        locking,
        clock,
    };
    let effect = match report {
        Report::LaunchLane(l) => &l.effect,
        Report::CloseOwnedResources(c) => &c.effect,
        Report::RequestTransfer(t) => &t.effect,
        Report::StartController(s) => &s.effect,
        Report::StopController(s) => &s.effect,
        Report::AdoptSession(_)
        | Report::BeginRound(_)
        | Report::RecordValidationAdmission(_)
        | Report::AdoptController(_)
        | Report::ClaimIntent(_)
        | Report::AcceptResult(_)
        | Report::RecordVerification(_)
        | Report::ReconcileRound(_)
        | Report::RecordHandoff(_)
        | Report::ResumeHandoff(_)
        | Report::ParkLane(_)
        | Report::ReserveLane(_)
        | Report::ReleaseLane(_)
        | Report::RecordOutcome(_)
        | Report::RecordPhase(_)
        | Report::RecordProgress(_) => return Ok(None),
    };
    run_effect(&run, request, effect).map(Some)
}

/// The live effect `effect` names, run and recorded, or handed to its job.
fn run_effect(run: &Run, request: &Request, effect: &Effect) -> Result<Effected> {
    let intent = match effect {
        // A repeated request found an open intent: reconcile it rather than
        // start a second effect (plan § Records).
        Effect::Reconciled { intent } => {
            let Reconciled { applied, stale } = reconcile_intent(run, &intent.id)?;
            // A close or a controller stop whose reconcile still reads a
            // stop to run, the recorded identity live and unchanged or a
            // recorded pane present, is a stop never completed. The request
            // asked for that stop, and the stop is exact on the identity it
            // reads, so the repeat runs it rather than leaving the target
            // with no route (decisions 64, 67). A controller stop runs again
            // in a detached job, as its first run did (decision 109 (3)):
            // the reconcile read the prior job's owner dead.
            if stop_route_open(&applied) {
                let outcome = match request {
                    // The stop this request reruns takes the reconcile's stale
                    // readings: one request counts each identity once
                    // (decision 124e (22)).
                    Request::CloseOwnedResources(_) => {
                        Some(stop::stop_effect(run, &intent.id, &stale)?)
                    }
                    Request::StopController(_) => {
                        let current = read_intent(run.path, &intent.id)?;
                        return job::start(run, &current, request, job::Start::Repeat)
                            .map(Effected::Started);
                    }
                    Request::LaunchLane(_)
                    | Request::RequestTransfer(_)
                    | Request::StartController(_) => None,
                    Request::AdoptSession(_)
                    | Request::BeginRound(_)
                    | Request::RecordValidationAdmission(_)
                    | Request::AdoptController(_)
                    | Request::ClaimIntent(_)
                    | Request::AcceptResult(_)
                    | Request::RecordVerification(_)
                    | Request::VerifyHead(_)
                    | Request::ReconcileRound(_)
                    | Request::RecordHandoff(_)
                    | Request::ResumeHandoff(_)
                    | Request::ParkLane(_)
                    | Request::ReserveLane(_)
                    | Request::ReleaseLane(_)
                    | Request::RecordOutcome(_)
                    | Request::RecordPhase(_)
                    | Request::RecordProgress(_) => {
                        unreachable!("a request without a live effect reports no effect")
                    }
                };
                if let Some(outcome) = outcome {
                    return run.apply_outcome(outcome).map(Effected::Recorded);
                }
            }
            return Ok(Effected::Recorded(applied));
        }
        // A close over an open launch intent (decision 67).
        Effect::Supersedes { intent } => {
            let Request::CloseOwnedResources(close) = request else {
                unreachable!("only a close supersedes a launch")
            };
            return supersede_launch(run, close, &intent.id).map(Effected::Recorded);
        }
        Effect::Persisted { intent } => intent.clone(),
    };
    let outcome = match request {
        Request::LaunchLane(r) => launch::launch_effect(run, &intent, r),
        Request::CloseOwnedResources(_) => stop::stop_effect(run, &intent.id, &[]),
        // A transfer's or a stop's effect ends the controller's pane, this
        // process's own as often as not: each runs in a detached job that
        // takes the intent's lease (decisions 76, 109 (3)). A start retires
        // nothing and stays here.
        Request::RequestTransfer(_) | Request::StopController(_) => {
            return job::start(run, &intent, request, job::Start::First).map(Effected::Started);
        }
        Request::StartController(r) => transfer::start_effect(run, &intent.id, r),
        Request::AdoptSession(_)
        | Request::BeginRound(_)
        | Request::RecordValidationAdmission(_)
        | Request::AdoptController(_)
        | Request::ClaimIntent(_)
        | Request::AcceptResult(_)
        | Request::RecordVerification(_)
        | Request::VerifyHead(_)
        | Request::ReconcileRound(_)
        | Request::RecordHandoff(_)
        | Request::ResumeHandoff(_)
        | Request::ParkLane(_)
        | Request::ReserveLane(_)
        | Request::ReleaseLane(_)
        | Request::RecordOutcome(_)
        | Request::RecordPhase(_)
        | Request::RecordProgress(_) => {
            unreachable!("a request without a live effect reports no effect")
        }
    }?;
    let applied = run.apply_outcome(outcome)?;
    Ok(Effected::Recorded(applied))
}

/// The job's side of a transfer or a stop (decisions 76, 109 (3)): claim the
/// intent `intent_id` and run its effect from the request the caller wrote
/// beside the record, recording the outcome as any effect does.
pub fn run_job(
    path: &Path,
    intent_id: &str,
    settings: &Settings,
    env: &Env,
    locking: Locking,
    clock: &dyn Clock,
) -> Result<Applied> {
    let run = Run {
        path,
        settings,
        env,
        locking,
        clock,
    };
    job::run_job(&run, intent_id)
}

/// Read the pane an adoption names and record the controller in it: the
/// one read-then-record operation of the fleet (step4-map A3).
pub fn adopt_controller(
    path: &Path,
    r: &AdoptController,
    settings: &Settings,
    locking: Locking,
) -> Result<Applied> {
    operation::adopt_controller(path, r, settings, locking)
}

/// Whether a reconciled close left a stop to run: the recorded identity
/// live under its recorded start (`stop: pending`), or a recorded pane
/// present whose foreground the close stops by (`pane: present`).
fn stop_route_open(applied: &Applied) -> bool {
    let Report::RecordOutcome(r) = &applied.report else {
        return false;
    };
    if r.intent.outcome != Outcome::Unconfirmed {
        return false;
    }
    let read = |key: &str| {
        r.intent
            .observation
            .as_ref()
            .and_then(|o| o.get(key))
            .and_then(Value::as_str)
            .map(str::to_owned)
    };
    read("stop").as_deref() == Some("pending")
        || read("pane").as_deref() == Some("present")
        // The harness ended but the worktree's validation runs could not be
        // stopped, or its detached wake turn still runs: the repeat runs
        // that stop again (decision 108 (7)).
        || read("validate").as_deref() == Some("stop-failed")
        || read("wake").as_deref() == Some("live")
}

/// A close asked for over an open launch intent (decision 67). The launch
/// is reconciled first: an outcome of its own leaves the lane as any close
/// finds it. One still unconfirmed with its pane present is closed `failed`
/// with `superseded-by-close`, since a hung launch would otherwise have
/// neither a close nor a relaunch, and the close then stops what that pane
/// holds. One whose pane cannot be observed is left open, and the close
/// refuses `intent-open` as before: there is nothing to stop by. The close
/// is then persisted through `operation`, the one store entry of the effect
/// files.
fn supersede_launch(
    run: &Run,
    close: &ops::CloseOwnedResources,
    launch_id: &str,
) -> Result<Applied> {
    let reconciled = reconcile_intent(run, launch_id)?.applied;
    let Report::RecordOutcome(launch) = &reconciled.report else {
        unreachable!("record-outcome returns its own report")
    };
    if launch.intent.open() {
        let present = launch
            .intent
            .observation
            .as_ref()
            .and_then(|o| o.get("observed"))
            .and_then(Value::as_str)
            == Some("present");
        if !present {
            return Err(Error::IntentOpen {
                intent: launch.intent.id.clone(),
                op: launch.intent.op,
                target: launch.intent.target.clone(),
            });
        }
        let pane = launch
            .intent
            .phase
            .as_ref()
            .and_then(|p| p.opened())
            .map(|o| o.pane.clone());
        // The pane passes to the close that follows, which stops what it
        // holds (decision 67): nothing is closed or signalled here, so the
        // launch intent ends refused with its handles untouched.
        let operation = Operation::open(run, &launch.intent)?;
        run.apply_outcome(operation.refuse(
            "superseded-by-close",
            json!({"reconcile": "launch", "pane": pane}),
        ))?;
    }
    // The launch intent is closed either way: the close now persists its
    // own intent and runs, as a close with nothing open does.
    let applied = operation::persist_close(run, close)?;
    let Report::CloseOwnedResources(persisted) = &applied.report else {
        unreachable!("a close request reports a close")
    };
    let Effect::Persisted { intent } = &persisted.effect else {
        unreachable!("the launch intent was closed above and no close stood open")
    };
    let outcome = stop::stop_effect(run, &intent.id, &[])?;
    run.apply_outcome(outcome)
}

/// What one launch runs: the harness, its home and the account it spends,
/// model, effort, working directory, opening brief, the permission posture
/// and question-tool posture, its own compaction and the caller's own words,
/// as a launch or a succession resolved them. The command is spelled from
/// these by agent-runtime's one builder (decision 109 (5)); no recorded line
/// is executed.
struct Spec<'a> {
    harness: Harness,
    /// The harness's own home, where its native sessions are read.
    home: Option<&'a Path>,
    /// The account the launch spends, routed by the builder's table.
    account: Option<&'a Path>,
    model: Option<&'a str>,
    effort: Option<&'a str>,
    cwd: &'a Path,
    brief: Option<&'a Path>,
    /// The posture the caller judged; `None` takes the settings' posture.
    permission: Option<Permission>,
    question_tool: QuestionTool,
    compaction: Compaction,
    /// The session id the launch fixes, for a harness that takes one.
    session_id: Option<&'a str>,
    /// The caller's own words, appended as given.
    extra_args: &'a [String],
}

/// The harness a pane runs and the executable configured for it: together
/// they name the processes that are the harness's own, its own names and
/// the configured program's basename (`Harness::owns_process_of`).
#[derive(Clone)]
struct Target {
    harness: Harness,
    program: Option<PathBuf>,
}

impl Target {
    fn new(settings: &Settings, harness: Harness) -> Target {
        Target {
            harness,
            program: settings.harness_binaries.get(&harness).cloned(),
        }
    }

    fn owns(&self, name: &str) -> bool {
        self.harness.owns_process_of(self.program.as_deref(), name)
    }
}

/// The intent the harness launches under, built from a spec and the settings
/// posture. `program` is the configured executable for the harness, so a
/// test selects its stub through the one binary-path setting. The caller's
/// words and the judged posture must agree under the builder's table
/// (decision 120, M1): a `native` posture whose words carry the harness's
/// bypass word refuses `permission-mismatch` before any window; under
/// `bypass` the words are preserved as given and the builder adds no
/// duplicate permission word.
fn build_launch(settings: &Settings, spec: &Spec) -> Result<(LaunchIntent, LaunchCommand)> {
    let permission = spec.permission.unwrap_or(settings.permission);
    if permission == Permission::Native
        && let Some(word) = spec.harness.bypass_word_in(spec.extra_args)
    {
        return Err(refused(
            "permission-mismatch",
            &[
                ("harness", spec.harness.name()),
                ("posture", "native"),
                ("word", &word),
            ],
        ));
    }
    let intent = LaunchIntent {
        harness: spec.harness,
        home: spec.home.map(Path::to_path_buf),
        account: spec.account.map(Path::to_path_buf),
        cwd: spec.cwd.to_path_buf(),
        model: spec.model.map(str::to_owned),
        effort: spec.effort.map(str::to_owned),
        permission,
        question_tool: spec.question_tool,
        compaction: spec.compaction,
        brief: match spec.brief {
            Some(path) => Brief::File {
                path: path.to_path_buf(),
            },
            None => Brief::None,
        },
        resume: None,
        session_id: spec.session_id.map(str::to_owned),
        env: Default::default(),
        env_remove: Vec::new(),
        extra_args: spec.extra_args.to_vec(),
        program: settings.harness_binaries.get(&spec.harness).cloned(),
    };
    let command = agent_runtime::launch::build(&intent)?;
    Ok((intent, command))
}

fn refused(key: &'static str, fields: &[(&str, &str)]) -> Error {
    Error::from(agent_runtime::Error::refused(key, fields))
}

/// Whether the command's program will run: a path names an existing file,
/// a bare name is found on this process's `PATH`, the same lookup the
/// pane's shell makes. The shell reads an unreadable path as no program,
/// so this preflight answers the same and refuses `harness-binary-missing`.
#[allow(
    clippy::disallowed_methods,
    reason = "the launch line's program preflight answers as the pane's shell will: an unreadable path is no program"
)]
fn check_program(command: &LaunchCommand) -> Result<()> {
    let program = Path::new(&command.program);
    let found = if program.components().count() > 1 {
        program.is_file()
    } else {
        std::env::var_os("PATH")
            .is_some_and(|path| std::env::split_paths(&path).any(|dir| dir.join(program).is_file()))
    };
    if found {
        Ok(())
    } else {
        Err(refused(
            "harness-binary-missing",
            &[("program", &command.program)],
        ))
    }
}

/// Whether the launch can start in `dir`: the shell's `cd` reads an
/// unreadable path as no directory, so this preflight refuses `key` for one
/// too.
#[allow(
    clippy::disallowed_methods,
    reason = "the launch directory's preflight answers as the pane's shell will: an unreadable path is no directory"
)]
fn check_directory(key: &'static str, dir: &Path) -> Result<()> {
    if dir.is_dir() {
        Ok(())
    } else {
        Err(refused(key, &[("path", &dir.display().to_string())]))
    }
}

/// The brief's text, or `brief-unreadable` naming the file.
fn read_brief(brief: &Path) -> Result<String> {
    std::fs::read_to_string(brief).map_err(|e| {
        refused(
            "brief-unreadable",
            &[
                ("path", &brief.display().to_string()),
                ("cause", &e.to_string()),
            ],
        )
    })
}

fn up(state: &State) -> bool {
    matches!(state, State::Idle | State::Working)
}

fn idle(state: &State) -> bool {
    *state == State::Idle
}

/// The observation a pending reading leaves on the record.
fn pending_observation(reading: &ProcessReading, state: &State) -> Value {
    json!({
        "process": serde_json::to_value(reading).unwrap_or(Value::Null),
        "state": serde_json::to_value(state).unwrap_or(Value::Null),
    })
}

/// Re-observe every open intent on `path` by its recorded phase and
/// identity and complete or mark each, then send the notice any closed
/// intent still records owed. Nothing starts here that the intent did not
/// already record as its next step. An intent whose reconcile refused or
/// failed is reported in the reply by its cause and the walk goes on to
/// the next (decision 124l (45)): one intent's refused write never fails
/// the verb or holds the others back.
pub fn reconcile(
    path: &Path,
    settings: &Settings,
    env: &Env,
    locking: Locking,
    clock: &dyn Clock,
) -> Result<ReconcileRun> {
    let run = Run {
        path,
        settings,
        env,
        locking,
        clock,
    };
    let open = open_intents(path)?;
    let mut reconciled = Vec::new();
    let mut refused = Vec::new();
    for id in open {
        match reconcile_intent(&run, &id) {
            Ok(outcome) => reconciled.push(outcome.applied),
            Err(e) => refused.push(IntentRefused {
                intent: id,
                refusal: e.key().to_owned(),
                detail: e.to_string(),
            }),
        }
    }
    // The closed intents whose outcome still owes its notice are walked
    // too: the continuation a crash between the outcome's write and the
    // send left behind is run once here (decision 124f (28)); a mark the
    // store refused goes into the reply (decision 124i (36)).
    let notices_unmarked = job::send_owed_notices(&run)?;
    Ok(ReconcileRun {
        reconciled,
        refused,
        notices_unmarked,
    })
}

/// An open intent a reconcile could not complete or mark: the refusal's
/// key and its message, recorded in the reply (decision 124l (45)). The
/// intent stands as it was for the next reconcile.
#[derive(Debug, Serialize)]
pub struct IntentRefused {
    pub intent: String,
    pub refusal: String,
    pub detail: String,
}

/// One intent reconciled: the committed outcome, and the identities the
/// reconcile read stale, which the stop the same request reruns takes as
/// already read (decision 124e (22)).
struct Reconciled {
    applied: Applied,
    stale: Vec<Identity>,
}

fn reconcile_intent(run: &Run, intent_id: &str) -> Result<Reconciled> {
    let intent = read_intent(run.path, intent_id)?;
    // The owner the intent recorded at persist (decision 72): a reconcile
    // that finds that process still live defers to it and records only the
    // observation, so a contender racing the owner before its first phase
    // never fails the intent out from under it (step4-map F1). One it
    // cannot read defers the same way, with the cause (decision 99). A dead
    // or absent owner (legacy intents have none) lets the reconcile proceed.
    match operation::owner(&intent) {
        Reading::Live(_) => {
            return deferred(
                run,
                intent,
                json!({"note": state::OWNER_LIVE, "owner": "live"}),
            )
            .map(|applied| Reconciled {
                applied,
                stale: Vec::new(),
            });
        }
        Reading::Unreadable { cause } => {
            return deferred(
                run,
                intent,
                json!({"note": state::OWNER_UNREAD, "owner": "unreadable", "cause": cause}),
            )
            .map(|applied| Reconciled {
                applied,
                stale: Vec::new(),
            });
        }
        Reading::Gone => {}
    }
    let outcome = match intent.op {
        state::EffectOp::LaunchLane => launch::reconcile_launch(run, &intent)?,
        state::EffectOp::CloseOwnedResources => stop::reconcile_close(run, &intent)?,
        state::EffectOp::RequestTransfer | state::EffectOp::StartController => {
            transfer::reconcile_transfer(run, &intent)?
        }
        state::EffectOp::StopController => transfer::reconcile_stop(run, &intent)?,
    };
    let stale = outcome.stale_read();
    Ok(Reconciled {
        applied: run.apply_outcome(outcome)?,
        stale,
    })
}

/// The reply a reconcile gives when it defers to the owner (decisions 72, 99,
/// 109 (4)): the intent as it stands, `unconfirmed` with `observation` on
/// it, and nothing written. The owner is live or unreadable, so the record
/// is its to move; a reconcile that wrote even its observation would move
/// the file under the owner for no change the owner made.
fn deferred(run: &Run, intent: Intent, observation: Value) -> Result<Applied> {
    let snapshot = load(run.path)?;
    let mut intent = intent;
    intent.outcome = Outcome::Unconfirmed;
    intent.observation = Some(observation);
    Ok(Applied {
        kind: snapshot.kind,
        report: Report::RecordOutcome(Box::new(OutcomeRecorded {
            intent,
            recorded_now: false,
            lane: None,
            generation: None,
            reconciled: None,
        })),
    })
}

fn load(path: &Path) -> Result<state::Snapshot> {
    operation::load(path)?.ok_or_else(|| Error::RecordMissing {
        path: path.to_path_buf(),
    })
}

fn fleet(path: &Path) -> Result<state::FleetState> {
    use state::Record;
    let snapshot = load(path)?;
    state::FleetState::view(path, &snapshot.doc)
}

fn fleet_tmux_session(path: &Path) -> Result<Option<String>> {
    let snapshot = load(path)?;
    Ok(snapshot
        .doc
        .get("tmux")
        .and_then(|t| t.get("session"))
        .and_then(Value::as_str)
        .map(str::to_owned))
}

fn read_overseer(path: &Path) -> Result<Overseer> {
    fleet(path)?.overseer.ok_or_else(|| Error::OverseerMissing {
        path: path.to_path_buf(),
    })
}

fn read_intent(path: &Path, intent_id: &str) -> Result<Intent> {
    fleet(path)?
        .intents
        .into_iter()
        .find(|i| i.id == intent_id)
        .ok_or_else(|| Error::IntentUnknown {
            id: intent_id.to_owned(),
        })
}

fn open_intents(path: &Path) -> Result<Vec<String>> {
    Ok(fleet(path)?
        .intents
        .into_iter()
        .filter(|i| i.open())
        .map(|i| i.id)
        .collect())
}

fn lane_for_intent(path: &Path, intent_id: &str) -> Result<(Lane, String)> {
    let body = fleet(path)?;
    let intent = body
        .intents
        .iter()
        .find(|i| i.id == intent_id)
        .ok_or_else(|| Error::IntentUnknown {
            id: intent_id.to_owned(),
        })?;
    let item = intent.target.clone();
    let lane = body
        .lanes
        .into_iter()
        .find(|l| l.item == item)
        .ok_or_else(|| Error::LaneMissing { item: item.clone() })?;
    Ok((lane, item))
}

/// The lane's open launch intent, else its latest: the one whose selection
/// names what runs in the lane's pane, since a relaunch writes the pane and
/// the harness word on the lane only when it confirms.
fn launch_intent_of(path: &Path, item: &str) -> Result<Option<Intent>> {
    let launches: Vec<Intent> = fleet(path)?
        .intents
        .into_iter()
        .filter(|i| i.op == EffectOp::LaunchLane && i.target == item)
        .collect();
    Ok(launches
        .iter()
        .find(|i| i.open())
        .or(launches.last())
        .cloned())
}

/// Which harness runs the lane's pane: the one its launch intent selected,
/// which the lane records only once that launch confirms, else the lane's
/// own word; a lane relaunched keeps its earlier word until then.
fn pane_harness(lane: &Lane, launch: Option<&Intent>) -> Option<Harness> {
    launch
        .and_then(|i| i.selection.as_ref())
        .map(|s| s.harness.as_str())
        .or(lane.harness.as_deref())
        .and_then(Harness::parse)
}

/// The predecessor's identity the overseer record carries. The legacy
/// `ol_record_start` wrote `harness_pid` as the string jq's `--arg` hands
/// it; the runtime writes the number. Both are read (decision 63).
fn overseer_identity(overseer: &Overseer) -> Option<Identity> {
    let pid = overseer.extra.get("harness_pid").and_then(pid_value)?;
    let start = overseer
        .extra
        .get("harness_start")
        .and_then(Value::as_str)?;
    Some(Identity {
        pid: u32::try_from(pid).ok()?,
        start: start.to_owned(),
    })
}

/// The predecessor's harness and configured program, the processes its
/// exact stop may name below the recorded root.
fn overseer_target_of(settings: &Settings, overseer: &Overseer) -> Option<Target> {
    overseer
        .extra
        .get("harness")
        .and_then(Value::as_str)
        .and_then(Harness::parse)
        .map(|h| Target::new(settings, h))
}

/// A pid a record carries as the number the runtime writes or the string a
/// legacy jq `--arg` wrote (the overseer's `server` and `harness_pid`).
fn pid_value(value: &Value) -> Option<u64> {
    match value {
        Value::Number(n) => n.as_u64(),
        Value::String(s) => s.parse().ok(),
        Value::Null | Value::Bool(_) | Value::Array(_) | Value::Object(_) => None,
    }
}
