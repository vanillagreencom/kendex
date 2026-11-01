//! The controller effects. A succession: every precondition before
//! retirement, the waiting runner brought to its composer, the predecessor
//! retired and confirmed terminal, the held brief delivered and confirmed in
//! the runner's own session file, the runner's identity read and published.
//! A start runs the same steps with no predecessor to retire. A predecessor
//! with no recorded identity is proven terminal by the generation-bound exit
//! record or by its pane gone on the proven recorded server, never by
//! absence on a server that is not proven (decision 77). The explicit stop
//! retires the controller exactly by identity. A transfer's and a stop's
//! effect run in the detached job of `operation::job`; the controller cells
//! of the reconcile matrix complete any of them from the recorded phase. The
//! predecessor's recorded handles join the intent's set at the start of its
//! retirement, before the first signal, and every terminal outcome after
//! that consumes them with the runner's.

use std::path::{Path, PathBuf};

use agent_runtime::harness::Harness;
use agent_runtime::launch::{Compaction, LaunchCommand, Permission};
use agent_runtime::reading::Reading;
use serde_json::{Value, json};

use super::operation::{
    self, Binding, EffectOutcome, Identity, Observed, OpenRefusal, Operation, Pane, Polled,
    ProcessRead, Proof, Published, Recovered, State, Stop, TurnConfirm, WindowClose, Wire, Word,
    opening_observation,
};
use super::{
    Run, Spec, Target, build_launch, check_directory, check_program, fleet_tmux_session, idle,
    overseer_target_of, pending_observation, read_brief, read_intent, read_overseer, refused, up,
};
use crate::error::{Error, Result};
use crate::ops::{RequestTransfer, StartController, overseer_target};
use crate::settings::Settings;
use crate::state::{
    self, BoundSession, EffectOp, Intent, LaunchIdentity, OpenedPane, Overseer, Phase,
};

/// Which controller lifetime a succession effect serves: a transfer retires
/// the recorded predecessor; a start has none to retire and refuses over a
/// controller it reads live.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    Transfer,
    Start,
}

impl Mode {
    fn of(op: EffectOp) -> Mode {
        match op {
            EffectOp::RequestTransfer => Mode::Transfer,
            EffectOp::StartController => Mode::Start,
            EffectOp::LaunchLane | EffectOp::CloseOwnedResources | EffectOp::StopController => {
                unreachable!("a succession reconcile is dispatched for a transfer or a start")
            }
        }
    }
}

/// A `failed` succession outcome before retirement, the predecessor left in
/// control: the `record-outcome` transfer-failed arm restores the pending
/// this request overwrote, since `retired` is false. The set the succession
/// recorded must be discharged, else the intent holds with what stands.
fn failed_before_retirement(operation: Operation, note: &str) -> EffectOutcome {
    operation.settle(Word::Failed, json!({"retired": false, "note": note}))
}

/// The same, with the reading's cause beside the note.
fn failed_before_retirement_cause(operation: Operation, note: &str, cause: &str) -> EffectOutcome {
    operation.settle(
        Word::Failed,
        json!({"retired": false, "note": note, "cause": cause}),
    )
}

/// A refusal a precondition met, as the outcome: its key is the note and
/// the values it acted on (the program and operation of an external
/// failure, the path of a missing directory) stand beside it, so the record
/// says what failed without the host's own text.
fn failed_before_retirement_refused(operation: Operation, e: &Error) -> EffectOutcome {
    let fields: serde_json::Map<String, Value> = e
        .fields()
        .into_iter()
        .map(|(k, v)| (k, Value::from(v)))
        .collect();
    operation.settle(
        Word::Failed,
        json!({"retired": false, "note": e.key(), "fields": fields}),
    )
}

/// The runner's identities, where the attempt recorded any, each read through
/// the one identity reader and discharged by its own read, never by the
/// pane's disappearance.
fn read_runner(
    operation: &mut Operation,
    opened: &OpenedPane,
    runner: Option<&Identity>,
) -> Result<()> {
    let mut read = Vec::new();
    for identity in opened.identity.iter().chain(runner) {
        if read.contains(&identity) {
            continue;
        }
        read.push(identity);
        operation.read_process(identity)?;
    }
    Ok(())
}

/// The runner's pane and identity on the wire, so `record-outcome` keeps
/// them for a reconcile.
fn runner_wire(opened: &OpenedPane, identity: Option<&Identity>) -> LaunchIdentity {
    LaunchIdentity {
        pane: Some(opened.pane.clone()),
        server: Some(opened.server),
        server_start: Some(opened.server_start),
        pid: identity.map(|i| i.pid as u64),
        start: identity.map(|i| i.start.clone()),
    }
}

/// The outcome of abandoning the waiting runner before retirement with the
/// predecessor in control: the runner stopped exactly and its window closed
/// through the handle, then `failed` once every obligation is discharged
/// (`runner` says what the stop found), `unconfirmed` with the cause while
/// any stands, the runner's pane and identity kept on the intent for a later
/// reconcile.
fn abandoned_before_retirement(
    mut operation: Operation,
    opened: &OpenedPane,
    identity: Option<&Identity>,
    pane: &Pane,
    target: Option<&Target>,
    note: &str,
) -> Result<EffectOutcome> {
    let stop = stop_runner(&mut operation, pane, target, identity)?;
    operation.read_receipt()?;
    let mut outcome = operation.settle(
        Word::Failed,
        json!({"retired": false, "note": note, "runner": stop}),
    );
    if !outcome.ended() {
        outcome.annotate("runner", json!("unsettled"));
        outcome = outcome.with_wire(Wire {
            launch: Some(runner_wire(opened, identity)),
            ..Wire::default()
        });
    }
    Ok(outcome)
}

/// The runner's pane read gone before retirement: `failed` once the runner's
/// identity is read gone with it, the predecessor in control; the identity
/// read live or unread holds the intent with it.
fn runner_gone_before_retirement(
    mut operation: Operation,
    opened: &OpenedPane,
    runner: Option<&Identity>,
    note: &str,
    cause: &'static str,
) -> Result<EffectOutcome> {
    read_runner(&mut operation, opened, runner)?;
    operation.read_receipt()?;
    operation.read_standing_processes()?;
    Ok(operation.settle(
        Word::Failed,
        json!({"retired": false, "note": note, "runner": "gone", "cause": cause}),
    ))
}

/// The runner's pane read gone after retirement, the whole recorded set
/// consumed: the runner's identity read, its pane closed where it still
/// stands, the predecessor's identity read and its own window closed on the
/// proven server, each discharged by its own evidence. `successor-exited`
/// once every one settles, else the set kept `unconfirmed` with the cause.
fn successor_exited(
    mut operation: Operation,
    opened: &OpenedPane,
    runner: Option<&Identity>,
    session_id: Option<String>,
    retired: &Retired,
    cause: &'static str,
) -> Result<EffectOutcome> {
    read_runner(&mut operation, opened, runner)?;
    // The runner's pane: closed where it still stands by its own token, read
    // gone where it does not, so the window it holds is not left open.
    if let Observed::Present(pane) = operation.observe_pane(opened)?
        && let Ok(token) = operation.standing_pane(pane)
    {
        let _ = operation.close_window(token)?;
    }
    operation.read_receipt()?;
    operation.read_standing_processes()?;
    if let Some(prior) = operation::predecessor_identity(retired.overseer) {
        operation.read_process(&prior)?;
    }
    operation.close_overseer_window(retired.overseer)?;
    let mut outcome = operation.settle(
        Word::Failed,
        json!({
            "cause": cause,
            "retired": true,
            "retired_by": retired.by,
            "note": "successor-exited",
        }),
    );
    if !outcome.ended() {
        outcome = outcome.with_wire(Wire {
            launch: Some(runner_wire(opened, runner)),
            session_id,
            server_start: Some(opened.server_start),
            server_socket: Some(opened.socket.clone()),
            ..Wire::default()
        });
    }
    Ok(outcome)
}

/// An `unconfirmed` succession outcome after retirement: a recoverable
/// stopped transition, the runner carried under `overseer.pending.runner`
/// for a reconcile.
fn unconfirmed_after_retirement(
    operation: Operation,
    opened: &OpenedPane,
    identity: Option<&Identity>,
    session_id: Option<String>,
    note: &str,
    by: &str,
    observation: Value,
) -> EffectOutcome {
    let mut observation = observation;
    observation["retired"] = json!(true);
    observation["retired_by"] = json!(by);
    observation["note"] = json!(note);
    operation.hold(observation).with_wire(Wire {
        launch: Some(runner_wire(opened, identity)),
        session_id,
        server_start: Some(opened.server_start),
        server_socket: Some(opened.socket.clone()),
        ..Wire::default()
    })
}

/// What a succession resolved about its successor before anything opened,
/// and what a reconcile rebuilds from the record: the harness, the home its
/// native session is read under, the account it spends, its working
/// directory and the typed launch fields the command is built from
/// (decision 109 (5)). The pending line is kept for display alone.
#[derive(Clone)]
struct Successor {
    harness: Harness,
    target: Target,
    home: PathBuf,
    account: Option<PathBuf>,
    cwd: PathBuf,
    model: Option<String>,
    effort: Option<String>,
    permission: Option<Permission>,
    extra_args: Vec<String>,
    launch_line: Option<String>,
}

impl Successor {
    /// The successor `pending` names, with every precondition a succession
    /// reads before retirement (decision 61): the harness word, the working
    /// directory, the home its sessions are read under and the account it
    /// spends, which must exist. The program and brief are checked by the
    /// effect that builds the command.
    fn from_pending(settings: &Settings, pending: &state::Pending) -> Result<Successor> {
        let harness = pending
            .harness
            .as_deref()
            .and_then(Harness::parse)
            .ok_or_else(|| {
                refused(
                    "harness-unknown",
                    &[("harness", pending.harness.as_deref().unwrap_or_default())],
                )
            })?;
        let cwd = PathBuf::from(pending.cwd.clone().unwrap_or_default());
        check_directory("cwd-missing", &cwd)?;
        let account = match pending.account.as_deref() {
            Some(account) => {
                let account = PathBuf::from(account);
                check_directory("account-missing", &account)?;
                Some(account)
            }
            None => None,
        };
        // The home the harness reads its sessions under: the one named, else
        // the account on a harness whose account is its home, else the
        // harness's default. A Pi launch on another provider's seat names
        // its own root here and the seat as the account.
        let same_var = harness.account_var(pending.model.as_deref()) == harness.home_var();
        let home = match (pending.home.as_deref(), &account) {
            (Some(home), _) => {
                let home = PathBuf::from(home);
                check_directory("home-missing", &home)?;
                home
            }
            (None, Some(account)) if same_var => account.clone(),
            (None, _) => operation::default_home(harness)
                .ok_or_else(|| refused("home-unresolved", &[("harness", harness.name())]))?,
        };
        Ok(Successor {
            harness,
            target: Target::new(settings, harness),
            home,
            account,
            cwd,
            model: pending.model.clone(),
            effort: pending.effort.clone(),
            permission: pending.permission,
            extra_args: pending.extra_args.clone(),
            launch_line: pending.launch_line.clone(),
        })
    }

    /// The launch the successor runs, built from its typed fields through
    /// agent-runtime's one builder: the effective home is passed for every
    /// harness, the prepared Codex trust home and Pi's own root among them,
    /// and the account routes billing only where its variable differs from
    /// the home's; the caller's permission posture and words are kept, the
    /// harness's own compaction off where it has a word for it, since orch's
    /// handoff mark judges the window, and the brief held for delivery after
    /// retirement.
    fn command(&self, settings: &Settings, session_id: Option<&str>) -> Result<LaunchCommand> {
        let compaction = match self.harness.compaction_off_words() {
            Some(_) => Compaction::Off,
            None => Compaction::Native,
        };
        let one_variable =
            self.harness.account_var(self.model.as_deref()) == self.harness.home_var();
        let account = match (&self.account, one_variable) {
            (Some(_), true) | (None, _) => None,
            (Some(account), false) => Some(account.as_path()),
        };
        build_launch(
            settings,
            &Spec {
                harness: self.harness,
                home: Some(self.home.as_path()),
                account,
                model: self.model.as_deref(),
                effort: self.effort.as_deref(),
                cwd: &self.cwd,
                brief: None,
                permission: self.permission,
                question_tool: settings.question_tool.for_overseer(),
                compaction,
                session_id,
                extra_args: &self.extra_args,
            },
        )
        .map(|(_, command)| command)
    }

    /// The runner's own native session file (decision 65): the file its
    /// fixed id names, or the one lead session for its cwd that appeared
    /// since the window opened and stood in no baseline before it. A
    /// neighbour in the same home and directory is never a candidate.
    fn bind_session(&self, operation: &Operation, opened: &OpenedPane) -> Result<Binding> {
        if let Some(id) = &opened.session_id {
            let file = operation::fixed_file(self.harness, &self.home, &self.cwd, id).ok_or_else(
                || refused("session-id-unfixable", &[("harness", self.harness.name())]),
            )?;
            return Ok(Binding::Bound(BoundSession {
                session_id: id.clone(),
                file: file.display().to_string(),
            }));
        }
        Ok(operation.appeared_session(self.harness, &self.home, &self.cwd, opened))
    }
}

// ---------------------------------------------------------------------------
// The predecessor's terminal state (decision 77)
// ---------------------------------------------------------------------------

/// What a succession has to retire, settled before anything opens.
enum Predecessor {
    /// A recorded identity, retired exactly after the runner is ready.
    Identity(Identity),
    /// Nothing to retire: no controller runs, established `by` the reading
    /// named.
    Absent { by: &'static str },
}

/// The predecessor as `mode` needs it, or the note and cause the effect
/// fails with before retirement. A transfer retires a recorded identity, or
/// takes decision 77's proof; one with a standing pane and no identity is
/// an unknown stop, which cannot authorize a second controller. A start
/// refuses `overseer-live` over an identity read live or a pane standing on
/// the proven server, and proceeds over an empty record. A record that
/// names a session nothing can resolve refuses `predecessor-unproven` under
/// both (decision 109 (1)): unproven is not absent, and the remedy is
/// adoption from its pane.
fn resolve_predecessor(
    operation: &mut Operation,
    overseer: &Overseer,
    mode: Mode,
) -> Result<std::result::Result<Predecessor, (&'static str, Option<&'static str>)>> {
    Ok(match (mode, operation::predecessor_identity(overseer)) {
        (Mode::Transfer, Some(identity)) => Ok(Predecessor::Identity(identity)),
        (Mode::Start, Some(identity)) => match operation.read_process(&identity)? {
            ProcessRead::Live => Err(("overseer-live", None)),
            ProcessRead::Gone | ProcessRead::Stale { .. } => Ok(Predecessor::Absent {
                by: "identity-gone",
            }),
            ProcessRead::Unreadable { cause } => Err(("overseer-unreadable", Some(cause))),
        },
        (mode, None) => match operation.terminal_proof(overseer)? {
            Proof::Proven { by } => Ok(Predecessor::Absent { by }),
            Proof::Standing { .. } => Err(match mode {
                Mode::Transfer => ("predecessor-identity-missing", None),
                Mode::Start => ("overseer-live", None),
            }),
            Proof::Empty => match mode {
                Mode::Transfer => Err(("predecessor-unproven", Some("record-empty"))),
                Mode::Start => Ok(Predecessor::Absent { by: "record-empty" }),
            },
            Proof::Unproven { cause } => Err(("predecessor-unproven", Some(cause))),
            Proof::Unreadable { cause } => Err(match mode {
                Mode::Transfer => ("predecessor-unreadable", Some(cause)),
                Mode::Start => ("overseer-unreadable", Some(cause)),
            }),
        },
    })
}

/// What a reconcile reads of the predecessor's retirement: never asserted,
/// always from the identity or decision 77's proof.
enum Retirement {
    Retired {
        by: &'static str,
    },
    Standing,
    /// The recorded pid holds another process: one reading towards decision
    /// 68, the second settling the identity as gone.
    Stale {
        readings: u64,
    },
    /// The record names a session nothing resolves (decision 109 (1)).
    Unproven {
        cause: &'static str,
    },
    Unreadable {
        cause: &'static str,
    },
}

/// The predecessor's retirement as the identity or decision 77's proof reads
/// it; a stale reading's count is written on `observation`.
fn read_retirement(
    operation: &mut Operation,
    overseer: &Overseer,
    mode: Mode,
    observation: &mut Value,
) -> Result<Retirement> {
    let by = match mode {
        Mode::Transfer => "identity",
        Mode::Start => "identity-gone",
    };
    Ok(match operation::predecessor_identity(overseer) {
        Some(identity) => match operation.read_process(&identity)? {
            ProcessRead::Live => Retirement::Standing,
            ProcessRead::Gone => Retirement::Retired { by },
            ProcessRead::Stale { .. } => {
                let readings = operation.count_stale(&identity, observation)?;
                if readings >= 2 {
                    Retirement::Retired { by }
                } else {
                    Retirement::Stale { readings }
                }
            }
            ProcessRead::Unreadable { cause } => Retirement::Unreadable { cause },
        },
        None => match operation.terminal_proof(overseer)? {
            Proof::Proven { by } => Retirement::Retired { by },
            Proof::Standing { .. } => Retirement::Standing,
            Proof::Empty => match mode {
                Mode::Transfer => Retirement::Unproven {
                    cause: "record-empty",
                },
                Mode::Start => Retirement::Retired { by: "record-empty" },
            },
            Proof::Unproven { cause } => Retirement::Unproven { cause },
            Proof::Unreadable { cause } => Retirement::Unreadable { cause },
        },
    })
}

/// The predecessor as retired, carried to the publication (decision 109
/// (2)): what retired it, the record whose handles the publication settles,
/// and the close of its window where this run already attempted one. A
/// reconcile closes the window at publication.
struct Retired<'a> {
    by: &'a str,
    overseer: &'a Overseer,
    window: Option<WindowClose>,
}

// ---------------------------------------------------------------------------
// The succession
// ---------------------------------------------------------------------------

pub(super) fn transfer_effect(
    run: &Run,
    intent_id: &str,
    r: &RequestTransfer,
) -> Result<EffectOutcome> {
    succeed(run, intent_id, Mode::Transfer, r.brief_file.as_deref())
}

pub(super) fn start_effect(
    run: &Run,
    intent_id: &str,
    r: &StartController,
) -> Result<EffectOutcome> {
    succeed(run, intent_id, Mode::Start, r.brief_file.as_deref())
}

fn succeed(run: &Run, intent_id: &str, mode: Mode, brief: Option<&Path>) -> Result<EffectOutcome> {
    let intent = read_intent(run.path, intent_id)?;
    let mut operation = Operation::open(run, &intent)?;
    let overseer = read_overseer(run.path)?;
    let doc_session = fleet_tmux_session(run.path)?;

    // --- Preconditions, all before retirement. A failure here is `failed`,
    // the predecessor in control, no waiting runner opened (decision 61). ---
    // What there is to retire: an identity, or nothing proven to run. An
    // unknown stop cannot authorize a second controller.
    let predecessor = match resolve_predecessor(&mut operation, &overseer, mode)? {
        Ok(predecessor) => predecessor,
        Err((note, None)) => return Ok(failed_before_retirement(operation, note)),
        Err((note, Some(cause))) => {
            return Ok(failed_before_retirement_cause(operation, note, cause));
        }
    };
    let Some(pending) = overseer.pending.clone() else {
        return Ok(failed_before_retirement(operation, "pending-missing"));
    };
    let successor = match Successor::from_pending(run.settings, &pending) {
        Ok(successor) => successor,
        Err(e) => return Ok(failed_before_retirement_refused(operation, &e)),
    };
    let (server, session) = match operation.fleet_server(doc_session.as_deref()) {
        Ok(resolved) => resolved,
        Err(e) => return Ok(failed_before_retirement_refused(operation, &e)),
    };
    // The runner's session is fixed, or the sessions that already stand
    // are read, before the window opens (decision 65).
    let floor = match operation.session_floor(successor.harness, &successor.home, &successor.cwd) {
        Ok(floor) => floor,
        Err(e) => return Ok(failed_before_retirement_refused(operation, &e)),
    };
    // The brief is held, not spelled into the launch: the waiting runner
    // opens at its prompt and is delivered the handoff after retirement.
    let command = match successor
        .command(run.settings, floor.session_id())
        .and_then(|command| check_program(&command).map(|()| command))
    {
        Ok(command) => command,
        Err(e) => return Ok(failed_before_retirement_refused(operation, &e)),
    };
    if let Some(brief) = brief
        && let Err(e) = read_brief(brief)
    {
        return Ok(failed_before_retirement_refused(operation, &e));
    }

    // --- Prepare the waiting runner: open its window and bring it to its
    // composer. It has no controller-mail authority, since the fleet record
    // still publishes the predecessor's generation. ---
    // The server and floor are recorded before the window opens (decision
    // 73); a reconcile at `opening` with a dead owner adopts the runner by
    // its receipt (decision 96), and before retirement that is still an
    // abandon.
    let opening = match operation.opening(&server, &floor, brief) {
        Ok(opening) => opening,
        Err(e) => return Ok(failed_before_retirement_refused(operation, &Error::from(e))),
    };
    operation.record_phase(Phase::Opening {
        opening: opening.clone(),
    })?;
    let pane = match operation.open_window(&server, &session, "overseer", &command, &opening)? {
        Ok(pane) => pane,
        // Refused before the launcher was asked: `arm` failed before the
        // receipt or window was recorded, so nothing stands and the
        // succession fails with the predecessor in control.
        Err(OpenRefusal::Refused(e)) => {
            return Ok(failed_before_retirement_refused(operation, &Error::from(e)));
        }
        // The launcher was asked and did not answer: a window may stand
        // that nothing registers (decision 111 (5)); the intent stays open
        // with that obligation for the reconcile.
        Err(OpenRefusal::Unanswered { refusal }) => {
            return Ok(operation.hold(json!({
                "retired": false,
                "note": "window-unread",
                "cause": refusal.key(),
            })));
        }
        // A window that opened and could not be typed into: closed again by
        // its exact id, the failure completes; a close the host did not
        // answer leaves the recorded pane for the reconcile at `opening`.
        Err(OpenRefusal::LineUnsent { refusal }) => {
            let mut outcome = operation.settle(
                Word::Failed,
                json!({
                    "retired": false,
                    "note": "launch-line-unsent",
                    "refusal": refusal.key(),
                }),
            );
            if !outcome.notes("cause") {
                outcome.annotate("cause", json!("launch-line-unsent"));
            }
            return Ok(outcome);
        }
    };
    let mut opened = opening.into_opened(pane.id.clone(), None);
    // The line is typed: the window-opened phase is recorded before the
    // wait, the receipt standing until read (decisions 62, 115 (A), 120 (5)).
    operation.record_phase(Phase::WindowOpened {
        opened: opened.clone(),
    })?;
    let runner = match operation.await_state(
        &pane,
        successor.harness,
        &|name| successor.target.owns(name),
        None,
        &idle,
    )? {
        Polled::Ready { identity } => identity,
        // A runner that exited or never reached its composer is a failure
        // before retirement: the predecessor keeps control.
        Polled::Gone => {
            return runner_gone_before_retirement(
                operation,
                &opened,
                None,
                "successor-exited",
                "pane-gone",
            );
        }
        Polled::Pending { .. } => {
            return abandoned_before_retirement(
                operation,
                &opened,
                None,
                &pane,
                Some(&successor.target),
                "successor-not-ready",
            );
        }
        Polled::Unobservable { .. } => {
            return abandoned_before_retirement(
                operation,
                &opened,
                None,
                &pane,
                Some(&successor.target),
                "successor-unobservable",
            );
        }
    };
    // The runner's identity is the attempt's from here (decision 99): every
    // later phase carries it, and the retirement and publication use no
    // other.
    operation.record_identity(&mut opened, &runner)?;

    // --- Retire the predecessor and confirm its exact terminal state. A
    // failure here is before the successor takes over: stop the waiting
    // runner exactly and leave the predecessor in control. ---
    // The process that asked for the succession answers from the
    // predecessor's own pane as often as not; retiring that pane ends it.
    // It has only its reply left to make once the job holds the lease, so
    // the job lets it exit first, within the bound (decision 76).
    operation.await_caller_gone()?;
    // The predecessor's recorded handles become obligations of the intent at
    // the start of its retirement, written before the first signal; the
    // publication or a failure after retirement consumes them.
    operation.begin_retirement(&overseer)?;
    let retired_by = match predecessor {
        Predecessor::Identity(identity) => {
            let predecessor_target = overseer_target_of(run.settings, &overseer);
            let owns = |name: &str| predecessor_target.as_ref().is_some_and(|t| t.owns(name));
            // The predecessor's identity stands in the set from the start of
            // retirement; its stop acts only through that token.
            let Some(token) = operation.standing_process(&identity) else {
                return abandoned_before_retirement(
                    operation,
                    &opened,
                    Some(runner.identity()),
                    &pane,
                    Some(&successor.target),
                    "predecessor-unrecorded",
                );
            };
            let stop = operation.stop_process(token, &owns)?;
            let note = match stop.answer() {
                Stop::Stopped { .. } | Stop::AlreadyGone => None,
                Stop::IdentityStale | Stop::Timeout { .. } => Some("predecessor-not-retired"),
                Stop::Unreadable { .. } => Some("predecessor-unreadable"),
            };
            let stale = matches!(stop.answer(), Stop::IdentityStale);
            // A stop that read unreadable before sending any signal left the
            // predecessor as it was: its handles return to its record,
            // discharged by that answer, and the succession fails before
            // retirement with the pending restored.
            operation.release_retirement(&overseer, &stop)?;
            if let Some(note) = note {
                // The predecessor was not retired: the runner is abandoned and
                // the predecessor's handles stand with the stop's cause until
                // a reconcile reads them. A pid holding another process is one
                // stale reading, counted for the reconcile's second.
                let mut stale_obs = json!({});
                if stale {
                    operation.count_stale(&identity, &mut stale_obs)?;
                    stale_obs["identity"] = json!("stale");
                }
                let mut outcome = abandoned_before_retirement(
                    operation,
                    &opened,
                    Some(runner.identity()),
                    &pane,
                    Some(&successor.target),
                    note,
                )?;
                if let Some(fields) = stale_obs.as_object() {
                    for (key, value) in fields {
                        outcome.annotate(key, value.clone());
                    }
                }
                return Ok(outcome);
            }
            "identity"
        }
        Predecessor::Absent { by } => {
            if let Some(prior) = operation::predecessor_identity(&overseer)
                && let ProcessRead::Stale { .. } = operation.read_process(&prior)?
            {
                // The recorded pid holds another process: one reading that
                // cannot retire the record alone; the reconcile's second
                // reading settles it and completes the succession from the
                // runner left standing.
                let mut observation = json!({
                    "retired": false,
                    "note": "predecessor-stale",
                    "identity": "stale",
                });
                let readings = operation.count_stale(&prior, &mut observation)?;
                if readings < 2 {
                    return Ok(operation.hold(observation).with_wire(Wire {
                        launch: Some(runner_wire(&opened, Some(runner.identity()))),
                        ..Wire::default()
                    }));
                }
            }
            by
        }
    };
    // The predecessor's own window, closed by exact id on its proven server:
    // a handle of the record the publication settles (decision 109 (2)).
    let window = operation.close_overseer_window(&overseer)?;
    operation.record_phase(Phase::Retired {
        opened: opened.clone(),
    })?;

    // --- Retired. From here a failure is a recoverable stopped transition. ---
    complete_transfer(
        operation,
        &successor,
        &pane,
        Some(runner.identity()),
        &Phase::Retired { opened },
        Retired {
            by: retired_by,
            overseer: &overseer,
            window: Some(window),
        },
        intent.watch.as_deref(),
    )
}

/// Complete a succession from a recorded phase after retirement: bring the
/// runner to its composer, bind its own session file, deliver the held
/// brief, confirm the runner wrote that turn into that file, read its
/// identity and publish it. Each step is recorded before the wait that
/// follows, so a reconcile resumes here from the phase it finds. `runner` is
/// the identity the caller already read, or `None` for a reconcile that
/// reads it afresh; `retired` is what retired the predecessor and the record
/// whose handles the publication settles; `watch` is the fleet watch's
/// launch line a start carries, launched before the publication.
#[allow(clippy::too_many_arguments)]
fn complete_transfer(
    mut operation: Operation,
    successor: &Successor,
    pane: &Pane,
    runner: Option<&Identity>,
    phase: &Phase,
    retired: Retired,
    watch: Option<&[String]>,
) -> Result<EffectOutcome> {
    let by = retired.by;
    // Reached only from `retired` on, or a `window-opened`/`identity-read`
    // reconcile; `opening` is resolved to `window-opened` before here.
    let opened = phase
        .opened()
        .expect("complete_transfer runs past the opening phase");
    let owns = |name: &str| successor.target.owns(name);
    let (turns_before, session) = match phase {
        Phase::Opening { .. } => unreachable!("opening is resolved before complete_transfer"),
        Phase::WindowOpened { .. } | Phase::Retired { .. } => {
            let Some(brief) = &opened.brief else {
                // No handoff to deliver: the runner idle at its composer
                // under decision 60 is the successor once its identity is
                // read; a runner held at a dialog is not.
                return publish(
                    operation,
                    successor,
                    pane,
                    runner,
                    opened,
                    opened.session_id.clone(),
                    &idle,
                    "successor-not-idle",
                    retired,
                    watch,
                );
            };
            // The runner must be at its composer, under the identity read
            // before retirement where there is one (decision 60).
            let identity =
                match operation.await_state(pane, successor.harness, &owns, runner, &idle)? {
                    Polled::Ready { identity } => identity,
                    Polled::Gone => {
                        return successor_exited(
                            operation,
                            opened,
                            runner,
                            None,
                            &retired,
                            "pane-gone",
                        );
                    }
                    Polled::Pending { reading, state, .. } => {
                        return Ok(unconfirmed_after_retirement(
                            operation,
                            opened,
                            runner,
                            None,
                            "successor-not-idle",
                            by,
                            pending_observation(&reading, &state),
                        ));
                    }
                    Polled::Unobservable { cause } => {
                        return Ok(unconfirmed_after_retirement(
                            operation,
                            opened,
                            runner,
                            None,
                            "pane-unobservable",
                            by,
                            json!({"cause": cause}),
                        ));
                    }
                };
            // The runner's own session file, bound once before the paste
            // (decision 65); a brief is never pasted without it. A store that
            // could not be read whole holds the succession at this phase with
            // the cause (decisions 95, 99): the runner is live, so this is no
            // refusal.
            let session = match successor.bind_session(&operation, opened)? {
                Binding::Bound(session) => session,
                Binding::Unreadable { cause } => {
                    return Ok(unconfirmed_after_retirement(
                        operation,
                        opened,
                        Some(identity.identity()),
                        None,
                        "session-store-unreadable",
                        by,
                        json!({"cause": cause}),
                    ));
                }
                Binding::Absent => {
                    return Ok(unconfirmed_after_retirement(
                        operation,
                        opened,
                        Some(identity.identity()),
                        None,
                        "session-unbound",
                        by,
                        json!({}),
                    ));
                }
                Binding::Ambiguous(sessions) => {
                    return Ok(unconfirmed_after_retirement(
                        operation,
                        opened,
                        Some(identity.identity()),
                        None,
                        "session-ambiguous",
                        by,
                        json!({"sessions": sessions}),
                    ));
                }
            };
            let turns_before = operation.user_turns(successor.harness, Path::new(&session.file))?;
            let text = match read_brief(Path::new(brief)) {
                Ok(text) => text,
                Err(e) => {
                    return Ok(unconfirmed_after_retirement(
                        operation,
                        opened,
                        Some(identity.identity()),
                        Some(session.session_id),
                        e.key(),
                        by,
                        json!({}),
                    ));
                }
            };
            // The runner's pane stands in the set; the brief is typed through
            // its token, the `delivering` phase written before the paste.
            let text = text.trim_end();
            let delivered = match operation.standing_pane(pane.clone()) {
                Ok(token) => operation.deliver(
                    &token,
                    text,
                    Phase::Delivering {
                        opened: opened.clone(),
                        turns_before,
                        session: session.clone(),
                        lines: text.lines().count() as u64,
                    },
                )?,
                Err(_) => Ok(()),
            };
            if let Err(e) = delivered {
                return Ok(unconfirmed_after_retirement(
                    operation,
                    opened,
                    Some(identity.identity()),
                    Some(session.session_id),
                    "brief-undelivered",
                    by,
                    json!({"cause": e.key()}),
                ));
            }
            operation.record_phase(Phase::Delivered {
                opened: opened.clone(),
                turns_before,
                session: session.clone(),
            })?;
            (turns_before, session)
        }
        // A brief recorded as delivering may have been pasted: it is never
        // pasted again, and the turn is waited for as after a delivery.
        Phase::Delivering {
            turns_before,
            session,
            ..
        }
        | Phase::Delivered {
            turns_before,
            session,
            ..
        } => (*turns_before, session.clone()),
        Phase::IdentityRead { pid, start, .. } => {
            // The last read before publication: the identity stands or the
            // runner is gone, and then its window, the runner's own, is
            // closed by exact id before the failure completes, the whole
            // recorded set consumed (decision 115 (A)).
            let id = Identity {
                pid: u32::try_from(*pid).unwrap_or(u32::MAX),
                start: start.clone(),
            };
            return match operation.read_process(&id)? {
                ProcessRead::Live => publish(
                    operation,
                    successor,
                    pane,
                    Some(&id),
                    opened,
                    opened.session_id.clone(),
                    &up,
                    "successor-not-up",
                    retired,
                    watch,
                ),
                ProcessRead::Gone | ProcessRead::Stale { .. } => successor_exited(
                    operation,
                    opened,
                    Some(&id),
                    opened.session_id.clone(),
                    &retired,
                    "pane-gone",
                ),
                ProcessRead::Unreadable { cause } => Ok(unconfirmed_after_retirement(
                    operation,
                    opened,
                    Some(&id),
                    opened.session_id.clone(),
                    "successor-unreadable",
                    by,
                    json!({"cause": cause}),
                )),
            };
        }
    };
    // The delivery is confirmed by the harness's own record: a user turn
    // beyond the count before the paste, in the one file bound above
    // (decisions 61 and 65). The runner then works that brief, so it is
    // published idle or working, never held at a dialog.
    let file = Path::new(&session.file);
    match operation.await_delivered_turn(successor.harness, pane, file, turns_before)? {
        TurnConfirm::Recorded => publish(
            operation,
            successor,
            pane,
            runner,
            opened,
            Some(session.session_id),
            &up,
            "successor-not-up",
            retired,
            watch,
        ),
        TurnConfirm::PaneGone => successor_exited(
            operation,
            opened,
            runner,
            Some(session.session_id),
            &retired,
            "pane-gone",
        ),
        TurnConfirm::PaneUnobservable { cause } => Ok(unconfirmed_after_retirement(
            operation,
            opened,
            runner,
            Some(session.session_id),
            "pane-unobservable",
            by,
            json!({"cause": cause, "turns_before": turns_before, "file": session.file}),
        )),
        TurnConfirm::Pending => Ok(unconfirmed_after_retirement(
            operation,
            opened,
            runner,
            Some(session.session_id),
            "brief-unconfirmed",
            by,
            json!({"turns_before": turns_before, "file": session.file}),
        )),
    }
}

/// Read the runner holding its pane in a state `accept` takes within the
/// bound, record its identity, settle the predecessor's recorded handles and
/// publish the runner as the successor. The identity is recorded before the
/// outcome, so a reconcile after this process ends publishes the same
/// process or reads it gone. `not_accepted` is the note an outcome within
/// the bound that `accept` refuses carries. The predecessor's window is a
/// handle of the record the publication moves: a close the host did not
/// answer for keeps the succession `unconfirmed` at this phase, the
/// successor live and the brief delivered, and the reconcile closes it again
/// before it publishes. A start's fleet watch (`watch`, step6-map A7) is
/// launched here, after the runner's identity is read and before the
/// publication, through the handle's job launch: a launch that refuses or
/// never claims holds the start `unconfirmed` naming it, the runner live
/// and the record naming no controller, and the reconcile runs the step
/// again; the watch found or launched goes on the wire as `overseer.watch`.
#[allow(clippy::too_many_arguments)]
fn publish(
    mut operation: Operation,
    successor: &Successor,
    pane: &Pane,
    runner: Option<&Identity>,
    opened: &OpenedPane,
    session_id: Option<String>,
    accept: &dyn Fn(&State) -> bool,
    not_accepted: &str,
    retired: Retired,
    watch: Option<&[String]>,
) -> Result<EffectOutcome> {
    let by = retired.by;
    let identity = match operation.await_state(
        pane,
        successor.harness,
        &|name| successor.target.owns(name),
        runner,
        accept,
    )? {
        Polled::Ready { identity } => identity,
        Polled::Gone => {
            return successor_exited(operation, opened, runner, session_id, &retired, "pane-gone");
        }
        Polled::Pending { reading, state, .. } => {
            return Ok(unconfirmed_after_retirement(
                operation,
                opened,
                runner,
                session_id,
                not_accepted,
                by,
                pending_observation(&reading, &state),
            ));
        }
        Polled::Unobservable { cause } => {
            return Ok(unconfirmed_after_retirement(
                operation,
                opened,
                runner,
                session_id,
                "pane-unobservable",
                by,
                json!({"cause": cause}),
            ));
        }
    };
    operation.record_phase(Phase::IdentityRead {
        opened: opened.clone(),
        pid: identity.identity().pid as u64,
        start: identity.identity().start.clone(),
    })?;
    // The whole recorded set is consumed. The predecessor's handles the
    // retirement added are discharged first: its identity by this run's
    // read, its window by the close made in this run or now. The runner's
    // pane and identity then pass to the record the publication writes.
    if let Some(recorded) = operation::predecessor_identity(retired.overseer) {
        operation.read_process(&recorded)?;
    }
    let window = match retired.window {
        Some(window) => window,
        None => operation.close_overseer_window(retired.overseer)?,
    };
    let window_word = window.word();
    let mut watch_job = None;
    if let Some(words) = watch {
        match operation.ensure_watch(words)?.held() {
            Ok(job) => watch_job = Some(job),
            Err((note, mut observation)) => {
                observation["predecessor_window"] = json!(window_word);
                return Ok(unconfirmed_after_retirement(
                    operation,
                    opened,
                    Some(identity.identity()),
                    session_id,
                    note,
                    by,
                    observation,
                ));
            }
        }
    }
    let observation = json!({
        "retired": true,
        "retired_by": by,
        "predecessor_window": window_word,
        "note": "successor-confirmed",
    });
    match operation.publish(Published::Successor, opened, &identity, observation)? {
        Ok(outcome) => Ok(outcome.with_wire(Wire {
            launch: Some(runner_wire(opened, Some(identity.identity()))),
            session_id,
            server_start: Some(opened.server_start),
            server_socket: Some(opened.socket.clone()),
            launch_line: successor.launch_line.clone(),
            watch: watch_job,
            ..Wire::default()
        })),
        Err(operation) => Ok(unconfirmed_after_retirement(
            *operation,
            opened,
            Some(identity.identity()),
            session_id,
            "predecessor-window-unread",
            by,
            json!({"predecessor_window": window_word}),
        )),
    }
}

/// Stop a waiting runner exactly through the handle: the recorded
/// `identity` where the attempt carries one, else the pane's own process,
/// read by exact pane id and acquired as its own obligation before its stop;
/// then its window, the runner's own. Used when a failure before the
/// successor takes over must leave the predecessor in control, or when
/// nothing could publish it. With no `target` only that process is
/// signalled. Each process the stop names is discharged by its own stop and
/// nothing else: a recorded identity whose pid another process now holds
/// stays standing on that one stale reading. A stop that timed out or could
/// not read closes no window over it. The word is what the stop found.
fn stop_runner(
    operation: &mut Operation,
    pane: &Pane,
    target: Option<&Target>,
    identity: Option<&Identity>,
) -> Result<&'static str> {
    let owns = |name: &str| target.is_some_and(|t| t.owns(name));
    // The pane's own process, read by exact pane id and acquired as its own
    // obligation before its stop; its token mints from that acquisition.
    let stop_pane_process = |operation: &mut Operation| -> Result<Option<Stop>> {
        Ok(match operation.pane_process(pane)? {
            Reading::Live(id) => match operation.standing_process(&id) {
                Some(token) => Some(operation.stop_process(token, &owns)?.answer().clone()),
                None => None,
            },
            Reading::Gone => Some(Stop::AlreadyGone),
            Reading::Unreadable { .. } => None,
        })
    };
    // The recorded identity where the attempt carries one. One that still
    // stands is stopped by its token; one already discharged (read gone) is
    // nothing to stop by, and its window is closed below. Only a reused pid
    // falls to the pane's own process.
    let stop = match identity {
        Some(id) => match operation.standing_process(id) {
            Some(token) => match operation.stop_process(token, &owns)?.answer().clone() {
                Stop::IdentityStale => stop_pane_process(operation)?,
                stop @ (Stop::Stopped { .. }
                | Stop::AlreadyGone
                | Stop::Timeout { .. }
                | Stop::Unreadable { .. }) => Some(stop),
            },
            None => Some(Stop::AlreadyGone),
        },
        None => stop_pane_process(operation)?,
    };
    let Some(stop) = stop else {
        return Ok("unreadable");
    };
    let word = match &stop {
        Stop::Stopped { .. } => "stopped",
        Stop::AlreadyGone => "gone",
        Stop::IdentityStale => "stale",
        Stop::Timeout { .. } => "timeout",
        Stop::Unreadable { .. } => "unreadable",
    };
    match &stop {
        Stop::Stopped { .. } | Stop::AlreadyGone | Stop::IdentityStale => {
            if let Ok(token) = operation.standing_pane(pane.clone()) {
                let _ = operation.close_window(token)?;
            }
        }
        Stop::Timeout { .. } | Stop::Unreadable { .. } => {}
    }
    Ok(word)
}

// ---------------------------------------------------------------------------
// The explicit stop (decision 78)
// ---------------------------------------------------------------------------

/// The controller's recorded identity ended, or proven terminal with none
/// recorded: its window is closed through the handle, and the stop is
/// `confirmed` once every obligation of the record is discharged, else
/// `unconfirmed` with the cause and what stands, which the reconcile reads
/// again.
fn controller_retired(
    mut operation: Operation,
    overseer: &Overseer,
    mut observation: Value,
) -> Result<EffectOutcome> {
    let window = operation.close_overseer_window(overseer)?;
    observation["window"] = json!(window.word());
    Ok(operation.settle(Word::Confirmed, observation))
}

/// Retire the recorded controller exactly: its handles acquired at the
/// start, its identity stopped, or, with none recorded, proven terminal by
/// decision 77, then its window closed. A stale identity, a timeout or an
/// unreadable read is `unconfirmed`, never a name-based kill; a standing
/// pane with no identity is refused, since nothing names what to stop. Runs
/// in the detached job: the process that asked answers from the controller's
/// own pane as often as not, so it is let exit before the pane is retired.
pub(super) fn stop_controller_effect(run: &Run, intent_id: &str) -> Result<EffectOutcome> {
    let intent = read_intent(run.path, intent_id)?;
    let mut operation = Operation::open(run, &intent)?;
    operation.await_caller_gone()?;
    let overseer = read_overseer(run.path)?;
    let target = overseer_target_of(run.settings, &overseer);
    operation.begin_retirement(&overseer)?;
    match operation::predecessor_identity(&overseer) {
        Some(identity) => {
            let owns = |name: &str| target.as_ref().is_some_and(|t| t.owns(name));
            let Some(token) = operation.standing_process(&identity) else {
                return stop_without_identity(operation, &overseer, json!({}));
            };
            let stop = operation.stop_process(token, &owns)?;
            match stop.answer() {
                Stop::Stopped { .. } | Stop::AlreadyGone => controller_retired(
                    operation,
                    &overseer,
                    json!({"stop": "identity", "retired_by": "identity"}),
                ),
                Stop::IdentityStale => {
                    Ok(operation.hold(json!({"stop": "pending", "identity": "stale"})))
                }
                Stop::Timeout { pid } => Ok(operation
                    .hold(json!({"stop": "pending", "identity": "live", "timeout_pid": pid}))),
                Stop::Unreadable { pid, cause, .. } => Ok(operation.hold(json!({
                    "stop": "pending",
                    "identity": "unreadable",
                    "pid": pid,
                    "cause": cause,
                }))),
            }
        }
        None => stop_without_identity(operation, &overseer, json!({})),
    }
}

/// The stop's outcome for a record with no identity: decision 77's proof
/// confirms it, a standing pane or a record nothing proves refuses it with
/// nothing signalled, an unreadable read holds it.
fn stop_without_identity(
    mut operation: Operation,
    overseer: &Overseer,
    mut observation: Value,
) -> Result<EffectOutcome> {
    Ok(match operation.terminal_proof(overseer)? {
        Proof::Proven { by } => {
            observation["stop"] = json!("none");
            observation["retired_by"] = json!(by);
            return controller_retired(operation, overseer, observation);
        }
        Proof::Standing { pid } => {
            observation["note"] = json!("identity-missing");
            observation["observed"] = json!("pane-present");
            observation["pid"] = json!(pid);
            operation.refuse("identity-missing", observation)
        }
        Proof::Empty => {
            observation["note"] = json!("identity-missing");
            operation.refuse("record-empty", observation)
        }
        Proof::Unproven { cause } => {
            observation["note"] = json!("identity-missing");
            operation.refuse(cause, observation)
        }
        Proof::Unreadable { cause } => {
            observation["stop"] = json!("pending");
            observation["note"] = json!("predecessor-unreadable");
            observation["cause"] = json!(cause);
            operation.hold(observation)
        }
    })
}

/// The stop cell of the reconcile matrix: the recorded identity read gone
/// confirms once its window is closed, live is a stop still to run (`stop:
/// pending`, which a repeated request runs), unreadable holds; with no
/// identity, decision 77's proof decides as the effect does. A generation
/// moved past the intent's is `target-moved`.
pub(super) fn reconcile_stop(run: &Run, intent: &Intent) -> Result<EffectOutcome> {
    let overseer = read_overseer(run.path)?;
    let generation = overseer.generation.unwrap_or(0);
    let mut operation = Operation::open(run, intent)?;
    operation.read_standing(Some(&overseer))?;
    if intent.target != overseer_target(generation) {
        // The record the stop named has moved on (decision 44): before any
        // signal it is refused; after one it retries on its own set alone
        // (decision 124d (20)) and settles once every handle is read gone,
        // else it holds (decision 124a (1)).
        let observation = json!({"reconcile": "stop-controller", "generation": generation});
        return moved_target(operation, run, &overseer, observation);
    }
    // The outstanding-job predicate, the same both routes apply: a stop
    // handed to a detached job that never claimed stands as that job until it
    // claims or is read ended, so a repeated stop reconciles it rather than
    // starting a second job. Only once the job reads ended does the identity
    // judgement below let a repeat run the stop again.
    if operation.job_standing(intent)? {
        return Ok(
            operation.hold(json!({"reconcile": "stop-controller", "job": "possibly-started"}))
        );
    }
    // A stop that never began its retirement acquires the controller's
    // handles now: nothing below closes a window the record does not owe.
    if !operation.retirement_begun(&overseer) {
        operation.begin_retirement(&overseer)?;
    }
    let observation = json!({"reconcile": "stop-controller"});
    match operation::predecessor_identity(&overseer) {
        Some(identity) => match operation.read_process(&identity)? {
            ProcessRead::Gone => controller_retired(
                operation,
                &overseer,
                json!({"reconcile": "stop-controller", "stop": "identity", "retired_by": "identity"}),
            ),
            ProcessRead::Stale { other } => {
                let mut observation = json!({
                    "reconcile": "stop-controller",
                    "stop": "pending",
                    "identity": "stale",
                    "observed_start": other.start,
                    "retired_by": "identity",
                });
                let readings = operation.count_stale(&identity, &mut observation)?;
                if readings >= 2 {
                    observation["stop"] = json!("identity");
                    controller_retired(operation, &overseer, observation)
                } else {
                    Ok(operation.hold(observation))
                }
            }
            ProcessRead::Live => Ok(operation.hold(
                json!({"reconcile": "stop-controller", "stop": "pending", "identity": "live"}),
            )),
            ProcessRead::Unreadable { cause } => Ok(operation.hold(json!({
                "reconcile": "stop-controller",
                "stop": "pending",
                "identity": "unreadable",
                "cause": cause,
            }))),
        },
        None => stop_without_identity(operation, &overseer, observation),
    }
}

// ---------------------------------------------------------------------------
// The succession cells of the reconcile matrix
// ---------------------------------------------------------------------------

/// The succession cells of the reconcile matrix, for a transfer and for a
/// start. The record moved past the intent's generation: refused before any
/// signal, retried on the intent's own set after one. Otherwise `retired` is
/// read from the
/// predecessor's identity or decision 77's proof, never asserted. No phase,
/// or a runner opened with the predecessor still live: `failed` before
/// retirement, the runner stopped, the original pending restored. From
/// `retired` on, the succession completes as the effect would: the runner's
/// pane gone, or its server replaced or gone, is `failed`; an unanswering
/// server still running is `unconfirmed`; a successor the pending no longer
/// resolves is `unconfirmed` with the runner kept, and a pending gone
/// altogether stops the runner, since nothing could publish it; the brief,
/// turn and identity steps give `confirmed` or `unconfirmed` with the
/// runner kept.
pub(super) fn reconcile_transfer(run: &Run, intent: &Intent) -> Result<EffectOutcome> {
    let overseer = read_overseer(run.path)?;
    let generation = overseer.generation.unwrap_or(0);
    let mode = Mode::of(intent.op);
    let mut operation = Operation::open(run, intent)?;
    // Every standing handle is read by its own key first (decision 124a (2)).
    operation.read_standing(Some(&overseer))?;
    // The record moved past the generation the intent named: decision 44, an
    // intent-stale reconciliation. Before any signal it is refused, nothing
    // signalled; after one it retries on its own set alone (decision 124d
    // (20)) and settles once every handle is read gone, else it holds with
    // what stands (decision 124a (1)).
    if intent.target != overseer_target(generation) {
        let observation = unbound_transfer_observation(generation, json!({}));
        return moved_target(operation, run, &overseer, observation);
    }
    // Retirement is read, never asserted; a read that fails settles nothing,
    // a record nothing resolves retires nothing: the runner, where one was
    // opened, is abandoned below; one stale reading of the recorded pid holds
    // until the second.
    let mut stale = json!({});
    let (retirement, unproven) = match read_retirement(&mut operation, &overseer, mode, &mut stale)?
    {
        Retirement::Retired { by } => (Some(by), None),
        Retirement::Standing => (None, None),
        Retirement::Unproven { cause } => (None, Some(cause)),
        Retirement::Stale { readings } => {
            let mut outcome = unbound_transfer_unconfirmed(
                operation,
                generation,
                json!({
                    "note": "predecessor-stale",
                    "identity": "stale",
                    "readings": readings,
                    "retired": false,
                }),
            );
            if let Some(opened) = intent.phase.as_ref().and_then(Phase::opened) {
                outcome = outcome.with_wire(Wire {
                    launch: Some(runner_wire(opened, recorded_runner_of(intent).as_ref())),
                    ..Wire::default()
                });
            }
            return Ok(outcome);
        }
        Retirement::Unreadable { cause } => {
            return Ok(unbound_transfer_unconfirmed(
                operation,
                generation,
                json!({"note": "predecessor-unreadable", "cause": cause}),
            ));
        }
    };
    let retired = retirement.is_some();
    let Some(phase) = &intent.phase else {
        let mut observation = json!({"retired": retired, "note": "nothing-opened"});
        if let Some(by) = retirement {
            observation["retired_by"] = json!(by);
        }
        if let Some(cause) = unproven {
            observation["cause"] = json!(cause);
        }
        // No phase: the job that would write one has not. The outstanding-job
        // predicate reads the recorded set's job obligations: one the launcher
        // was asked for and that never claimed stands until its unit or group
        // reads ended; one never asked for, or one that claimed and died, left
        // nothing standing.
        if operation.job_standing(intent)? {
            observation["job"] = json!("possibly-started");
        } else if operation.job_ended() {
            observation["job"] = json!("ended");
        }
        return Ok(operation.settle(
            Word::Failed,
            unbound_transfer_observation(generation, observation),
        ));
    };
    // At `opening` the runner's window may or may not have opened before
    // this process ended: adopt the pane the intent's receipt names and
    // record it `window-opened`, fail the recorded pane that never
    // registered, or fail `nothing-opened` (decision 96). Before retirement
    // an adopted runner is abandoned below, as a `window-opened` reconcile
    // abandons it. A pending reading binds no runner: the pending and the
    // panes stand as found, whether or not the predecessor retired, since
    // `record-outcome` moves nothing on an `unconfirmed` that names no
    // launch.
    let resolved;
    let mut receipted = None;
    let phase: &Phase = match phase {
        Phase::Opening { opening } => match operation.recover_opening(opening)? {
            Recovered::Adopted {
                pane,
                identity,
                registered,
            } => {
                let opened = opening.into_opened(pane.id.clone(), Some(identity));
                operation.record_phase(Phase::WindowOpened {
                    opened: opened.clone(),
                })?;
                resolved = Phase::WindowOpened { opened };
                receipted = Some(registered);
                &resolved
            }
            Recovered::Pending { note, cause } => {
                let mut observation = opening_observation("transfer", note, cause.as_deref());
                observation["retired"] = json!(retired);
                return Ok(unbound_transfer_unconfirmed(
                    operation,
                    generation,
                    observation,
                ));
            }
            Recovered::Failed { note, cause } => {
                let mut observation = opening_observation("transfer", note, cause);
                observation["retired"] = json!(retired);
                return Ok(operation.settle(
                    Word::Failed,
                    unbound_transfer_observation(generation, observation),
                ));
            }
        },
        resolved @ (Phase::WindowOpened { .. }
        | Phase::Retired { .. }
        | Phase::Delivering { .. }
        | Phase::Delivered { .. }
        | Phase::IdentityRead { .. }) => resolved,
    };
    let mut outcome = judge_resolved(
        operation,
        run,
        &overseer,
        mode,
        retirement,
        unproven,
        phase,
        intent.watch.as_deref(),
    )?;
    if let Some(registered) = receipted {
        outcome.annotate("registered", registered);
    }
    Ok(outcome)
}

/// An `unconfirmed` transfer outcome that binds no runner: what stands as the
/// record holds it.
fn unbound_transfer_unconfirmed(
    operation: Operation,
    generation: u64,
    observation: Value,
) -> EffectOutcome {
    operation.hold(unbound_transfer_observation(generation, observation))
}

/// A controller target whose generation moved past the intent's (decision
/// 124d (20)): before any signal the intent refuses `target-moved` with no
/// effect; after one it retries on its own recorded set alone, every standing
/// process stopped by its own token and every standing pane closed by its
/// full key, then settles `failed` once nothing stands, else holds. Nothing
/// the record names now is read or acted on; the harness word the record
/// carries only names the processes an exact stop may reach below a recorded
/// root.
fn moved_target(
    mut operation: Operation,
    run: &Run,
    overseer: &Overseer,
    mut observation: Value,
) -> Result<EffectOutcome> {
    if !operation.signalled() {
        return Ok(operation.refuse("target-moved", observation));
    }
    let target = overseer_target_of(run.settings, overseer);
    let owns = |name: &str| target.as_ref().is_some_and(|t| t.owns(name));
    if let Some(cause) = operation.stop_standing_processes(&owns, None)? {
        observation["stop"] = json!(cause);
    }
    operation.close_standing_panes(Some(overseer))?;
    observation["cause"] = json!("target-moved");
    observation["signalled"] = json!(true);
    Ok(operation.settle(Word::Failed, observation))
}

/// The reconcile's word and the generation it read, on the observation.
fn unbound_transfer_observation(generation: u64, observation: Value) -> Value {
    let mut observation = observation;
    observation["reconcile"] = json!("transfer");
    observation["generation"] = json!(generation);
    observation
}

/// Judge a succession intent whose phase names a pane. Before retirement a
/// runner present is abandoned, unless the retirement has begun, in which
/// case the predecessor's handles stand until they are read; from `retired`
/// on the succession completes as the effect would, or stops the runner
/// where nothing could publish it. `unproven` is the cause a record nothing
/// resolves read with (decision 109 (1)), which abandons a runner opened
/// before retirement under it.
#[allow(clippy::too_many_arguments)]
fn judge_resolved(
    mut operation: Operation,
    run: &Run,
    overseer: &Overseer,
    mode: Mode,
    retirement: Option<&'static str>,
    unproven: Option<&'static str>,
    phase: &Phase,
    watch: Option<&[String]>,
) -> Result<EffectOutcome> {
    let generation = overseer.generation.unwrap_or(0);
    let opened = phase
        .opened()
        .expect("a resolved transfer phase names a pane");
    let observed = operation.observe_pane(opened)?;
    let runner = recorded_runner(phase);
    // The successor the pending names, with its preconditions; what a
    // failure here does with the runner depends on what stands below.
    let successor = match overseer.pending.as_ref() {
        None => Err("pending-missing"),
        Some(pending) => Successor::from_pending(run.settings, pending).map_err(|e| e.key()),
    };
    let by = match (retirement, phase) {
        (Some(by), _) => by,
        (None, Phase::WindowOpened { .. }) => {
            // The runner was opened and the predecessor still runs, or
            // nothing resolves it. Where this intent began the retirement,
            // the predecessor's handles stand signalled in its set: nothing
            // is abandoned over them, and the next reconcile reads them
            // again. Otherwise the abandon every refusal before the commit
            // point takes: the runner stopped exactly and the predecessor in
            // control. A pane the host did not answer for is left as it
            // stands, the intent open; one gone has nothing to stop.
            if operation.retirement_begun(overseer) && unproven.is_none() {
                // The retirement began and the predecessor still reads live:
                // its stop is run again through the signalling method; one
                // that ends it lets the succession go on from the runner, any
                // other answer holds.
                let predecessor_target = overseer_target_of(run.settings, overseer);
                let owns = |name: &str| predecessor_target.as_ref().is_some_and(|t| t.owns(name));
                let token = operation::predecessor_identity(overseer)
                    .and_then(|id| operation.standing_process(&id));
                let stopped = match token {
                    Some(token) => matches!(
                        operation.stop_process(token, &owns)?.answer(),
                        Stop::Stopped { .. } | Stop::AlreadyGone
                    ),
                    None => false,
                };
                if !stopped {
                    return Ok(operation.hold(json!({
                        "reconcile": "transfer",
                        "generation": generation,
                        "retired": false,
                        "note": "predecessor-retiring",
                    })));
                }
                "identity"
            } else {
                let note = match (&successor, mode, unproven) {
                    (_, _, Some(_)) => "predecessor-unproven",
                    (Ok(_), Mode::Transfer, None) => "abandoned-before-retirement",
                    (Ok(_), Mode::Start, None) => "overseer-live",
                    (Err(note), _, None) => note,
                };
                return match observed {
                    Observed::Present(pane) => abandoned_before_retirement(
                        operation,
                        opened,
                        runner.as_ref(),
                        &pane,
                        successor.as_ref().ok().map(|s| &s.target),
                        note,
                    ),
                    Observed::Gone { cause } => runner_gone_before_retirement(
                        operation,
                        opened,
                        runner.as_ref(),
                        note,
                        cause,
                    ),
                    Observed::Unobservable { cause } => Ok(operation.hold(json!({
                        "retired": false,
                        "note": note,
                        "runner": "unobservable",
                        "cause": cause,
                    }))),
                };
            }
        }
        // Past `retired` the predecessor was confirmed terminal when the
        // phase was written; a reading that now finds a controller standing
        // is carried to the publication, which settles the record's handles
        // (decision 109 (2)) and so publishes nothing over a live identity.
        (
            None,
            Phase::Opening { .. }
            | Phase::Retired { .. }
            | Phase::Delivering { .. }
            | Phase::Delivered { .. }
            | Phase::IdentityRead { .. },
        ) => "recorded",
    };
    // What retired the predecessor and the handles its record names, settled
    // at the publication or a failure after retirement; an intent recorded
    // before the handles were acquired at retirement acquires them now.
    if !operation.retirement_begun(overseer) {
        operation.begin_retirement(overseer)?;
        if let Some(prior) = operation::predecessor_identity(overseer) {
            operation.read_process(&prior)?;
        }
    }
    let retired = Retired {
        by,
        overseer,
        window: None,
    };
    let successor = match successor {
        Ok(successor) => successor,
        // No pending: nothing can be published, so the live runner is
        // stopped exactly rather than left standing with no record, the
        // predecessor's handles consumed with the runner's.
        Err("pending-missing") => {
            let word = match observed {
                Observed::Present(pane) => {
                    stop_runner(&mut operation, &pane, None, runner.as_ref())?
                }
                Observed::Gone { .. } => {
                    read_runner(&mut operation, opened, runner.as_ref())?;
                    "gone"
                }
                Observed::Unobservable { cause } => {
                    return Ok(unconfirmed_after_retirement(
                        operation,
                        opened,
                        runner.as_ref(),
                        opened.session_id.clone(),
                        "pending-missing",
                        by,
                        json!({"reconcile": "transfer", "runner": "unobservable", "cause": cause}),
                    ));
                }
            };
            operation.read_receipt()?;
            if let Some(prior) = operation::predecessor_identity(overseer) {
                operation.read_process(&prior)?;
            }
            operation.close_overseer_window(overseer)?;
            let mut outcome = operation.settle(
                Word::Failed,
                unbound_transfer_observation(
                    generation,
                    json!({"retired": true, "retired_by": by, "note": "pending-missing", "runner": word}),
                ),
            );
            if !outcome.ended() {
                outcome = outcome.with_wire(Wire {
                    launch: Some(runner_wire(opened, runner.as_ref())),
                    session_id: opened.session_id.clone(),
                    server_start: Some(opened.server_start),
                    server_socket: Some(opened.socket.clone()),
                    ..Wire::default()
                });
            }
            return Ok(outcome);
        }
        // The pending stands but no longer resolves (its directory or home
        // gone, its harness word unknown): the runner is kept under
        // `pending.runner` for a reconcile once it does.
        Err(note) => {
            return Ok(unconfirmed_after_retirement(
                operation,
                opened,
                runner.as_ref(),
                opened.session_id.clone(),
                note,
                by,
                json!({"reconcile": "transfer"}),
            ));
        }
    };
    let pane = match observed {
        Observed::Unobservable { cause } => {
            return Ok(unconfirmed_after_retirement(
                operation,
                opened,
                runner.as_ref(),
                opened.session_id.clone(),
                "pane-unobservable",
                by,
                json!({"reconcile": "transfer", "cause": cause}),
            ));
        }
        Observed::Gone { cause } => {
            return successor_exited(
                operation,
                opened,
                runner.as_ref(),
                opened.session_id.clone(),
                &retired,
                cause,
            );
        }
        Observed::Present(pane) => pane,
    };
    complete_transfer(
        operation,
        &successor,
        &pane,
        runner.as_ref(),
        phase,
        retired,
        watch,
    )
}

/// The runner identity the intent's phase recorded, where it has one.
fn recorded_runner_of(intent: &Intent) -> Option<Identity> {
    intent.phase.as_ref().and_then(recorded_runner)
}

/// The runner identity a phase recorded, once one was read: the last read
/// before publication, else the one the pane carries since it was adopted or
/// first judged (decision 99).
fn recorded_runner(phase: &Phase) -> Option<Identity> {
    match phase {
        Phase::IdentityRead { pid, start, .. } => Some(Identity {
            pid: u32::try_from(*pid).ok()?,
            start: start.clone(),
        }),
        Phase::WindowOpened { opened }
        | Phase::Retired { opened }
        | Phase::Delivering { opened, .. }
        | Phase::Delivered { opened, .. } => opened.identity.clone(),
        Phase::Opening { .. } => None,
    }
}
