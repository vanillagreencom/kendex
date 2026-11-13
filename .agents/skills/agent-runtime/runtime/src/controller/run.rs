//! The hand-over's own dispatcher: a controller request's settings judged
//! and the request admitted, its transition committed, then its live
//! effect run here (a start), handed to the detached job that takes the
//! intent's lease (a transfer, a stop) or, for a repeat that found its
//! intent open, reconciled; the job's side; and the reconcile of every
//! open controller intent. An intent whose recorded owner still runs, or
//! cannot be read, is that owner's: its reconcile records nothing.

use std::path::Path;
use std::time::Duration;

use serde::Serialize;
use serde_json::{Value, json};

use super::effect::{self, Run, Settings};
use super::transition::{OutcomeRecorded, Report, Request, admit, apply};
use crate::clock::Clock;
use crate::effects::job::{self, JobStarted, NoticeUnmarked};
use crate::effects::{Reading, UNCONFIRMED_EXIT, read_intent};
use crate::error::{Error, Result};
use crate::intent::{EffectOp, Intent, OWNER_LIVE, OWNER_UNREAD};
use crate::journal::Effect;
use crate::protocol::{Outcome, Refusal};
use crate::record;
use crate::settings::{EngineSettings, Judged};

/// agent-runtime's own `controller job` command for an intent's detached
/// job, after the executable: the job reaches the mailbox and the server
/// its launcher was given, named on its own command line.
pub fn job_words(run: &crate::effects::Run, intent: &str) -> Vec<String> {
    let mut words = vec![
        "controller".to_owned(),
        "job".to_owned(),
        "--record".to_owned(),
        run.path.display().to_string(),
        "--intent".to_owned(),
        intent.to_owned(),
    ];
    words.extend(reach_words(&run.reach));
    words
}

/// The flags that name `reach` to a command that takes it.
pub fn reach_words(reach: &crate::effects::Reach) -> Vec<String> {
    let mut words = vec![
        "--mail-program".to_owned(),
        reach.mail_program.display().to_string(),
        "--mail-root".to_owned(),
        reach.mail_root.display().to_string(),
    ];
    if let Some(socket) = &reach.socket {
        words.extend(["--socket".to_owned(), socket.display().to_string()]);
    }
    words
}

/// How far a request's live effect got in this process: its outcome
/// recorded here, or handed to the detached job, whose outcome a later read
/// or reconcile sees.
#[derive(Debug, Serialize)]
#[serde(untagged)]
pub enum Effected {
    Recorded(Box<OutcomeRecorded>),
    Started(JobStarted),
}

/// What a controller request answers: its committed report, the live
/// effect's progress, and the owed notices of closed intents sent before
/// it whose mark the store refused.
#[derive(Debug, Serialize)]
pub struct Answered {
    pub persisted: Report,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub effect: Option<Effected>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub notices_unmarked: Vec<NoticeUnmarked>,
}

/// The keys a request's effect reads, judged before its intent persists and
/// again by its job before the claim, so no intent stands under a value its
/// effect would refuse: the bounds, the posture and the harness programs of
/// every live effect, a controller launch's question dialog, a job's claim
/// bound. The one list for every caller of a controller request, the
/// opener's own admission too.
pub fn judge_settings(
    settings: &Settings,
    close_grace: &Judged<Duration>,
    request: &Request,
) -> Result<()> {
    let (launch, job) = match request {
        Request::RequestTransfer(_) => (true, true),
        Request::StartController(_) => (true, false),
        Request::StopController(_) => (false, true),
        Request::ClaimIntent(_) | Request::RecordProgress(_) | Request::RecordOutcome(_) => {
            return Ok(());
        }
    };
    settings.engine.verify.get()?;
    close_grace.get()?;
    settings.launch.permission.get()?;
    settings.engine.harness_binaries.get()?;
    if launch {
        settings.controller.question_tool.get()?;
    }
    if job {
        settings.engine.claim.get()?;
    }
    Ok(())
}

/// A refusal met after the request's intent stood: its key and fields with
/// `persisted_intent` beside them, so a caller reads the request as
/// unconfirmed, the intent its reconcile's.
fn persisted(intent: &str, error: Error) -> Error {
    let mut fields = Refusal::from(&error).fields;
    fields.push(("persisted_intent".to_owned(), intent.to_owned()));
    Error::Refused {
        key: error.key(),
        fields,
    }
}

/// Judge, admit and commit `request`, then run, hand off or reconcile the
/// live effect its intent names.
pub fn request(run: &Run, request: &Request) -> Result<Answered> {
    judge_settings(run.settings, &run.engine.close_grace, request)?;
    admit(request, run.settings.controller)?;
    let live = matches!(
        request,
        Request::RequestTransfer(_) | Request::StartController(_) | Request::StopController(_)
    );
    // The continuation a crash between an earlier outcome's write and its
    // send left behind, run before this request's own transition.
    let notices_unmarked = if live {
        job::send_owed_notices(&run.engine)?
    } else {
        Vec::new()
    };
    let persisted_report = apply(run.engine.path, request, run.engine.env, run.engine.locking)?;
    let standing = match &persisted_report {
        Report::RequestTransfer(t) => Some(&t.effect),
        Report::StartController(s) => Some(&s.effect),
        Report::StopController(s) => Some(&s.effect),
        Report::ClaimIntent(_) | Report::RecordProgress(_) | Report::RecordOutcome(_) => None,
    };
    let effect = match standing {
        None => None,
        Some(effect) => {
            let id = match effect {
                Effect::Reconciled { intent }
                | Effect::Persisted { intent }
                | Effect::Supersedes { intent } => intent.id.clone(),
            };
            Some(live_effect(run, request, effect).map_err(|e| persisted(&id, e))?)
        }
    };
    Ok(Answered {
        persisted: persisted_report,
        effect,
        notices_unmarked,
    })
}

/// The live effect `effect` names: a start run and recorded here, a
/// transfer or a stop handed to its job, a repeat reconciled.
pub fn live_effect(run: &Run, request: &Request, effect: &Effect) -> Result<Effected> {
    let intent = match effect {
        Effect::Reconciled { intent } => {
            let applied = reconcile_intent(run, &intent.id)?;
            // A stop whose reconcile still reads a stop to run is a stop never
            // completed: the repeat runs it again in a detached job, as its
            // first run did, the prior job's owner read dead.
            if let Request::StopController(_) = request
                && stop_route_open(&applied)
            {
                let current = read_intent(run.engine.path, &intent.id)?;
                return job::start(&run.engine, &current, request, job::Start::Repeat)
                    .map(Effected::Started);
            }
            return Ok(Effected::Recorded(Box::new(applied)));
        }
        Effect::Supersedes { .. } => {
            unreachable!("only a close supersedes a launch")
        }
        Effect::Persisted { intent } => intent,
    };
    let outcome = match request {
        // A transfer's or a stop's effect ends the controller's pane, this
        // process's own as often as not: each runs in a detached job that
        // takes the intent's lease. A start retires nothing and stays here.
        Request::RequestTransfer(_) | Request::StopController(_) => {
            return job::start(&run.engine, intent, request, job::Start::First)
                .map(Effected::Started);
        }
        Request::StartController(r) => effect::start_effect(run, &intent.id, r)?,
        Request::ClaimIntent(_) | Request::RecordProgress(_) | Request::RecordOutcome(_) => {
            unreachable!("a request without a live effect reports no effect")
        }
    };
    recorded(run, outcome).map(|r| Effected::Recorded(Box::new(r)))
}

/// An outcome through the engine's recording boundary, as the report the
/// controller's arm moved.
fn recorded(run: &Run, outcome: crate::effects::EffectOutcome) -> Result<OutcomeRecorded> {
    Ok(OutcomeRecorded::of(crate::effects::apply_outcome(
        &run.engine,
        outcome,
    )?))
}

/// Whether a reconciled stop left a stop to run: the recorded identity live
/// under its recorded start (`stop: pending`), or a recorded pane present
/// whose foreground the stop stops by (`pane: present`).
fn stop_route_open(applied: &OutcomeRecorded) -> bool {
    if applied.intent.outcome != Outcome::Unconfirmed {
        return false;
    }
    let read = |key: &str| {
        applied
            .intent
            .observation
            .as_ref()
            .and_then(|o| o.get(key))
            .and_then(Value::as_str)
            .map(str::to_owned)
    };
    read("stop").as_deref() == Some("pending") || read("pane").as_deref() == Some("present")
}

/// The job's side of a transfer or a stop: claim the intent `intent_id` and
/// run its effect from the request the caller wrote beside the record,
/// recording the outcome as any effect does.
pub fn run_job(run: &Run, intent_id: &str) -> Result<OutcomeRecorded> {
    let request_path = record::job_request_path(&run.engine.state_dir, intent_id);
    let bytes = std::fs::read(&request_path)
        .map_err(|e| Error::io("read-job-request", &request_path, e))?;
    let shown = request_path.display().to_string();
    let request: Request = serde_json::from_slice(&bytes).map_err(|e| {
        Error::refused(
            "request-invalid",
            &[("path", &shown), ("cause", &e.to_string())],
        )
    })?;
    let transfer = match &request {
        Request::RequestTransfer(r) => Some(r),
        Request::StopController(_) => None,
        Request::StartController(_)
        | Request::ClaimIntent(_)
        | Request::RecordProgress(_)
        | Request::RecordOutcome(_) => {
            return Err(Error::refused(
                "request-invalid",
                &[
                    ("path", &shown),
                    ("op", request.name()),
                    ("cause", "not-a-job"),
                ],
            ));
        }
    };
    // The job's own settings may differ from its caller's: a value its
    // effect would refuse leaves the intent unclaimed.
    judge_settings(run.settings, &run.engine.close_grace, &request)?;
    job::claim(&run.engine, intent_id)?;
    let outcome = match transfer {
        Some(r) => effect::transfer_effect(run, intent_id, r)?,
        None => effect::stop_controller_effect(run, intent_id)?,
    };
    recorded(run, outcome)
}

/// An open intent a reconcile could not complete or mark: the refusal's
/// key and its message. The intent stands as it was for the next one.
#[derive(Debug, Serialize)]
pub struct IntentRefused {
    pub intent: String,
    pub refusal: String,
    pub detail: String,
}

/// What a reconcile answers: the committed outcome of every open controller
/// intent it completed or marked, the ones it could not, the owed notices
/// it sent whose mark the store refused, and the controller record's heal.
#[derive(Debug, Serialize)]
pub struct Reconciled {
    pub reconciled: Vec<OutcomeRecorded>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub refused: Vec<IntentRefused>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub notices_unmarked: Vec<NoticeUnmarked>,
    /// Absent where the controller record had nothing to heal.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub controller: Option<Value>,
}

/// Re-observe every open controller intent by its recorded phase and
/// identity and complete or mark each, send the notices closed intents
/// still owe, and heal the controller record from its pane. One intent's
/// refusal is reported and the walk goes on.
pub fn reconcile(run: &Run) -> Result<Reconciled> {
    let doc = record::read_document(run.engine.path)?.ok_or_else(|| Error::RecordMissing {
        path: run.engine.path.to_path_buf(),
    })?;
    let open: Vec<String> = crate::journal::intents(run.engine.path, &doc)?
        .into_iter()
        .filter(|i| i.open() && i.op.on_controller())
        .map(|i| i.id)
        .collect();
    let mut reconciled = Vec::new();
    let mut refused = Vec::new();
    for id in open {
        match reconcile_intent(run, &id) {
            Ok(applied) => reconciled.push(applied),
            Err(e) => refused.push(IntentRefused {
                intent: id,
                refusal: e.key().to_owned(),
                detail: e.to_string(),
            }),
        }
    }
    let notices_unmarked = job::send_owed_notices(&run.engine)?;
    let controller = match crate::effects::heal_controller(
        run.engine.path,
        run.settings.engine,
        run.engine.reach.socket.as_deref(),
        run.engine.locking,
    ) {
        Ok(None) => None,
        Ok(Some(adopted)) => Some(serde_json::to_value(adopted).map_err(|source| Error::Json {
            path: run.engine.path.to_path_buf(),
            source,
        })?),
        Err(e) => Some(json!({"refusal": e.key(), "detail": e.to_string()})),
    };
    Ok(Reconciled {
        reconciled,
        refused,
        notices_unmarked,
        controller,
    })
}

/// One controller intent reconciled; an intent whose recorded owner still
/// runs, or cannot be read, answers as it stands with the reading, and
/// nothing is written: the record is that owner's to move.
pub fn reconcile_intent(run: &Run, intent_id: &str) -> Result<OutcomeRecorded> {
    let intent = read_intent(run.engine.path, intent_id)?;
    let own = intent.owner.is_some() && intent.owner == run.engine.env.owner;
    match crate::effects::owner(&intent) {
        Reading::Live(_) if own => {}
        Reading::Live(_) => {
            return Ok(deferred(
                intent,
                json!({"note": OWNER_LIVE, "owner": "live"}),
            ));
        }
        Reading::Unreadable { cause } => {
            return Ok(deferred(
                intent,
                json!({"note": OWNER_UNREAD, "owner": "unreadable", "cause": cause}),
            ));
        }
        Reading::Gone => {}
    }
    let outcome = match intent.op {
        EffectOp::RequestTransfer | EffectOp::StartController => {
            effect::reconcile_transfer(run, &intent)?
        }
        EffectOp::StopController => effect::reconcile_stop(run, &intent)?,
        EffectOp::LaunchSession | EffectOp::CloseResources => {
            unreachable!("only controller intents are reconciled here")
        }
    };
    recorded(run, outcome)
}

/// The intent as it stands, `unconfirmed` with `observation` on it, nothing
/// written.
fn deferred(mut intent: Intent, observation: Value) -> OutcomeRecorded {
    intent.outcome = Outcome::Unconfirmed;
    intent.observation = Some(observation);
    OutcomeRecorded {
        intent,
        recorded_now: false,
        generation: None,
        reconciled: None,
    }
}

/// How an effect a caller waited for settled: its outcome recorded in this
/// process, or the intent of the job it handed off as read when the wait
/// ended.
pub enum Settled {
    Recorded(Intent),
    Job(Intent),
}

impl Settled {
    pub fn intent(&self) -> &Intent {
        match self {
            Settled::Recorded(intent) | Settled::Job(intent) => intent,
        }
    }

    /// 0 confirmed, or a job's runner up and waiting for this caller's exit;
    /// 3 failed; 75 open with its outcome unknown, the intent's reconcile its
    /// owner.
    pub fn status(&self) -> i32 {
        const FAILED: i32 = 3;
        let (intent, job) = match self {
            Settled::Recorded(intent) => (intent, false),
            Settled::Job(intent) => (intent, true),
        };
        if intent.open() {
            return if job && runner_recorded(intent) {
                0
            } else {
                UNCONFIRMED_EXIT
            };
        }
        match intent.outcome {
            Outcome::Confirmed => 0,
            Outcome::Failed | Outcome::Unconfirmed | Outcome::NotStarted => FAILED,
        }
    }
}

/// The part of `--effect-exit`'s wait on a job beyond twice the verify
/// bound: the job's start, its launch gate and its window.
const JOB_ANSWER_MARGIN: Duration = Duration::from_secs(60);

/// How long a caller that waits on a handed-off job reads it.
pub fn job_bound(settings: &EngineSettings) -> Result<Duration> {
    Ok(settings.verify.get()? * 2 + JOB_ANSWER_MARGIN)
}

/// What an effect settled as, read for a caller that waits: a recorded
/// outcome's intent as it is, a job's read until its outcome settles, its
/// runner's identity is recorded, or `bound` passes.
pub fn settle(
    path: &Path,
    effected: &Effected,
    bound: Duration,
    clock: &dyn Clock,
) -> Result<Settled> {
    Ok(match effected {
        Effected::Recorded(applied) => Settled::Recorded(applied.intent.clone()),
        Effected::Started(started) => Settled::Job(await_job(path, &started.intent, bound, clock)?),
    })
}

/// The intent of a job this process started, read until its outcome
/// settles, or until its runner's identity is recorded, or until `bound`
/// passes. A transfer's job records the runner it opened and then waits for
/// the process that handed it the intent to exit before it retires the
/// predecessor, so the caller waits no longer than that: the rest of the
/// outcome is the job's, which owes the owner a notice where it fails.
pub fn await_job(
    path: &Path,
    intent_id: &str,
    bound: Duration,
    clock: &dyn Clock,
) -> Result<Intent> {
    const POLL: Duration = Duration::from_millis(200);
    let deadline = clock.now() + bound;
    loop {
        let intent = read_intent(path, intent_id)?;
        if !intent.open() || runner_recorded(&intent) || clock.now() >= deadline {
            return Ok(intent);
        }
        clock.sleep(POLL);
    }
}

/// Whether an open intent records the runner its effect opened, under the
/// identity read once that runner stood at its composer.
pub fn runner_recorded(intent: &Intent) -> bool {
    intent
        .phase
        .as_ref()
        .and_then(crate::intent::Phase::opened)
        .is_some_and(|opened| opened.identity.is_some())
}
