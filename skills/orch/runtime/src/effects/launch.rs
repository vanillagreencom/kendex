//! The launch effect: resolve everything a launch can refuse before a
//! window opens, open the lane's window on the fleet server through the
//! operation handle, confirm the harness in it, and the launch cells of the
//! reconcile matrix. Every host read and write here goes through
//! [`Operation`].

use std::path::{Path, PathBuf};

use agent_runtime::harness::Harness;
use agent_runtime::launch::{Compaction, LaunchCommand, QuestionTool, Resume};
use agent_runtime::reading::Reading;
use serde_json::{Value, json};

use super::operation::{
    self, Binding, EffectOutcome, Foreground, Observed, OpenRefusal, Operation, Polled,
    ProcessRead, Published, Recovered, Server, SessionFloor, Wire, Word, opening_observation,
};
use super::{
    Run, Spec, Target, build_launch, check_directory, check_program, fleet_tmux_session,
    lane_for_intent, pane_harness, pending_observation, read_brief, refused, up,
};
use crate::error::Result;
use crate::ops::{LaunchLane, Relaunch};
use crate::settings::Settings;
use crate::state::{self, Intent, Lane, LaunchIdentity, OpenedPane, Phase};

/// The session a launch opens (step4-map A1): the lane's bound native
/// session resumed, or a fresh one, with why where a relaunch could not
/// resume. The route is judged from the records alone (decision 92): the
/// bound session id, the harness word and the item's standing handoff; no
/// session file is looked up by its age.
enum Route {
    Fresh {
        cause: Option<&'static str>,
    },
    Resume {
        session_id: String,
    },
    /// The destination home's session store could not be read (decision 115
    /// (G)): the launch refuses before any window rather than resuming a
    /// session it cannot prove present or starting fresh over one that may
    /// stand.
    Refuse {
        cause: &'static str,
    },
}

impl Route {
    fn word(&self) -> &'static str {
        match self {
            Route::Fresh { .. } => "fresh",
            Route::Resume { .. } => "resume",
            Route::Refuse { .. } => "refuse",
        }
    }

    fn cause(&self) -> Option<&'static str> {
        match self {
            Route::Fresh { cause } => *cause,
            Route::Resume { .. } => None,
            Route::Refuse { cause } => Some(cause),
        }
    }
}

/// The fixed-id lookup a route reads the destination store with.
type Present<'a> = &'a dyn Fn(Harness, &Path, &Path, &str) -> Reading<()>;

/// The route a launch of `lane` takes under `r`: a lane bound to no
/// session, or whose harness word differs, or whose item holds a standing
/// handoff that says `fresh` (the legacy `session-retired`, decision 100),
/// starts fresh; a bound session under the same harness and account resumes.
/// Pi resumes by session file, which the record does not carry, so a Pi lane
/// starts fresh and says so. A relaunch on another account than the one the
/// bound session was recorded under, or whose session file is absent from
/// the destination home by its fixed id, starts fresh with
/// `account-switched` (decision 108 (4)): the context continues through the
/// handoff record, never a transcript another account cannot read.
fn relaunch_route(run: &Run, lane: &Lane, r: &LaunchLane) -> Result<Route> {
    let handoff = standing_handoff(run, &lane.item)?;
    let destination = r
        .account
        .as_deref()
        .map(PathBuf::from)
        .or_else(|| Harness::parse(&r.harness).and_then(operation::default_home));
    Ok(route_of(
        lane,
        r,
        handoff,
        destination.as_deref(),
        &operation::session_present,
    ))
}

/// The route from the records alone (decision 92): `handoff` is the item's
/// standing handoff route, `destination` the home the relaunch reads its
/// sessions under through `present`, the session owner's fixed-id lookup.
/// The working directory is the Claude arm's alone (decision 120, L3): the
/// Codex and Copilot stores are keyed by id, so a lane with no recorded
/// `mail_root` is still looked up there.
fn route_of(
    lane: &Lane,
    r: &LaunchLane,
    handoff: Option<Relaunch>,
    destination: Option<&Path>,
    present: Present,
) -> Route {
    let Some(session_id) = lane.session_id.clone() else {
        return Route::Fresh { cause: None };
    };
    if lane.harness.as_deref() != Some(r.harness.as_str()) {
        return Route::Fresh {
            cause: Some("harness-switched"),
        };
    }
    let Some(harness) = Harness::parse(&r.harness) else {
        return Route::Fresh {
            cause: Some("harness-switched"),
        };
    };
    if harness == Harness::Pi {
        return Route::Fresh {
            cause: Some("resume-file-unknown"),
        };
    }
    if lane.account != r.account {
        return Route::Fresh {
            cause: Some("account-switched"),
        };
    }
    // A session the destination home does not hold by its fixed id cannot
    // be resumed there, whatever the record says of the account; a store
    // that cannot be read refuses before any window (decision 115 (G)),
    // never a resume of an unproven session nor a fresh start over one that
    // may stand.
    let cwd = match harness {
        Harness::Claude => lane.mail_root.as_deref().map(Path::new),
        Harness::Codex | Harness::Copilot | Harness::Pi => Some(Path::new("")),
    };
    if let (Some(home), Some(cwd)) = (destination, cwd) {
        match present(harness, home, cwd, &session_id) {
            Reading::Live(()) => {}
            Reading::Gone => {
                return Route::Fresh {
                    cause: Some("account-switched"),
                };
            }
            Reading::Unreadable { cause } => return Route::Refuse { cause },
        }
    }
    match handoff {
        Some(Relaunch::Resume) | None => Route::Resume { session_id },
        Some(Relaunch::Fresh) => Route::Fresh {
            cause: Some("session-retired"),
        },
    }
}

/// The item's standing handoff route, where its state file holds a
/// `handoff` record no session has resumed (`resumed_at` unset, decision
/// 100): the record's `relaunch` word, `fresh` where it names none, as the
/// legacy `handoff-standing` judges a standing handoff. `None` with no
/// state file, no record, or a consumed one.
fn standing_handoff(run: &Run, item: &str) -> Result<Option<Relaunch>> {
    let path = state::item_path(&run.settings.state_dir, item);
    let Some(snapshot) = operation::load(&path)? else {
        return Ok(None);
    };
    let Some(handoff) = state::field::<Value>(&path, &snapshot.doc, "handoff")? else {
        return Ok(None);
    };
    if handoff.get("resumed_at").is_some_and(|v| !v.is_null()) {
        return Ok(None);
    }
    let route = handoff
        .get("relaunch")
        .cloned()
        .and_then(|v| serde_json::from_value::<Relaunch>(v).ok())
        .unwrap_or(Relaunch::Fresh);
    Ok(Some(route))
}

/// What a launch resolved before any window opened: the harness, the fleet
/// server and session, and the spelled command.
struct LaunchPrep {
    target: Target,
    home: Option<PathBuf>,
    server: Server,
    session: String,
    command: LaunchCommand,
    floor: SessionFloor,
}

/// Resolve everything a launch can refuse before it opens a window: the
/// harness, the fleet server and session, the working directory, the
/// program and the brief file, and the command. A failure here is knowable
/// before the effect starts anything. A resumed session is the floor the
/// outcome binds (its id is known), and the command continues it rather
/// than fixing a fresh id.
fn prepare_launch(
    operation: &Operation,
    settings: &Settings,
    r: &LaunchLane,
    doc_session: Option<&str>,
    route: &Route,
) -> Result<LaunchPrep> {
    let harness = Harness::parse(&r.harness)
        .ok_or_else(|| refused("harness-unknown", &[("harness", &r.harness)]))?;
    let (server, session) = operation.fleet_server(doc_session)?;
    let cwd = PathBuf::from(&r.mail_root);
    check_directory("cwd-missing", &cwd)?;
    if let Some(brief) = &r.brief_file {
        read_brief(brief)?;
    }
    // The account home, else the harness's default home, never the cwd.
    let home = r
        .account
        .as_deref()
        .map(PathBuf::from)
        .or_else(|| operation::default_home(harness));
    let floor = match (route, &home) {
        (Route::Resume { session_id }, _) => SessionFloor::Fixed(session_id.clone()),
        (Route::Fresh { .. }, Some(home)) => operation.session_floor(harness, home, &cwd)?,
        (Route::Fresh { .. }, None) => SessionFloor::Baseline(Vec::new()),
        (Route::Refuse { .. }, _) => {
            unreachable!("a refuse route fails before prepare_launch")
        }
    };
    // A lane's account is its home on every harness but Pi, whose lane
    // launches route the account by the model's provider; the home the
    // sessions are read under is the account where the two share a
    // variable, else the harness's default.
    let account = r.account.as_deref().map(Path::new);
    let (mut intent, mut command) = build_launch(
        settings,
        &Spec {
            harness,
            home: None,
            account,
            model: r.model.as_deref(),
            effort: r.effort.as_deref(),
            cwd: &cwd,
            brief: r.brief_file.as_deref(),
            permission: None,
            question_tool: QuestionTool::Off,
            compaction: Compaction::Native,
            session_id: match route {
                Route::Fresh { .. } => floor.session_id(),
                Route::Resume { .. } | Route::Refuse { .. } => None,
            },
            extra_args: &[],
        },
    )?;
    if let Route::Resume { session_id } = route {
        intent.resume = Some(Resume {
            session_id: session_id.clone(),
            session_file: None,
        });
        command = agent_runtime::launch::build(&intent)?;
    }
    check_program(&command)?;
    Ok(LaunchPrep {
        target: Target::new(settings, harness),
        home,
        server,
        session,
        command,
        floor,
    })
}

/// An outcome once the window exists: the pane is carried on `launch` so a
/// reconcile can re-observe it, and written on the observation. The server
/// start travels with the pane, so the lane's pane key carries it.
fn with_pane(opened: &OpenedPane, outcome: EffectOutcome) -> EffectOutcome {
    let mut outcome = outcome;
    outcome.annotate("pane", json!(opened.pane));
    outcome.annotate("server", json!(opened.server));
    outcome.with_wire(Wire {
        launch: Some(LaunchIdentity {
            pane: Some(opened.pane.clone()),
            server: Some(opened.server),
            server_start: Some(opened.server_start),
            pid: None,
            start: None,
        }),
        ..Wire::default()
    })
}

/// The pane stands but nothing is settled: `unconfirmed`, the pane kept for
/// the next reconcile with the obligations the intent recorded.
fn launch_pane_unconfirmed(
    operation: Operation,
    opened: &OpenedPane,
    observation: Value,
) -> EffectOutcome {
    with_pane(opened, operation.hold(observation))
}

/// The recorded pane read gone, or its server gone or replaced with it: the
/// pane was discharged by that read, and the identity the set recorded is
/// read here through the one identity reader, never settled by the pane's
/// disappearance: `failed` once both are discharged, else `unconfirmed` with
/// the identity standing. The pane stays on `launch` for the record.
fn launch_pane_gone(
    mut operation: Operation,
    opened: &OpenedPane,
    cause: &'static str,
    observation: Value,
) -> Result<EffectOutcome> {
    let mut observation = observation;
    observation["cause"] = json!(cause);
    if let Some(identity) = &opened.identity {
        observation["identity"] = json!(match operation.read_process(identity)? {
            ProcessRead::Live => "live",
            ProcessRead::Gone => "gone",
            ProcessRead::Stale { .. } => "stale",
            ProcessRead::Unreadable { .. } => "unreadable",
        });
    }
    operation.read_receipt()?;
    // Every recorded process is read by its own key, the receipt's registered
    // pid and any foreground read on the way included: a survivor still live
    // holds the launch, one read gone lets it settle.
    operation.read_standing_processes()?;
    Ok(with_pane(
        opened,
        operation.settle(Word::Failed, observation),
    ))
}

pub(super) fn launch_effect(run: &Run, intent: &Intent, r: &LaunchLane) -> Result<EffectOutcome> {
    let mut operation = Operation::open(run, intent)?;
    let doc_session = fleet_tmux_session(run.path)?;
    let cwd = PathBuf::from(&r.mail_root);
    let (lane, _) = lane_for_intent(run.path, &intent.id)?;
    let route = relaunch_route(run, &lane, r)?;
    // A destination session store that could not be read refuses before any
    // window opens (decision 115 (G)), nothing recorded.
    if let Route::Refuse { cause } = &route {
        return Ok(operation.settle(Word::Failed, json!({"cause": cause})));
    }
    let prep = match prepare_launch(&operation, run.settings, r, doc_session.as_deref(), &route) {
        Ok(prep) => prep,
        // A harness, session, directory, program or brief the effect cannot
        // resolve: `failed` before anything opens, never a bare refusal.
        Err(e) => return Ok(operation.settle(Word::Failed, json!({"cause": e.key()}))),
    };
    // The server and floor are recorded before the window opens, so a crash
    // in the open leaves a phase a reconcile can resume: it adopts the pane
    // this launch's receipt names, fails the recorded pane that never
    // registered, or fails `nothing-opened`.
    let opening = match operation.opening(&prep.server, &prep.floor, None) {
        Ok(opening) => opening,
        Err(e) => return Ok(operation.settle(Word::Failed, json!({"cause": e.key()}))),
    };
    operation.record_phase(Phase::Opening {
        opening: opening.clone(),
    })?;
    let pane = match operation.open_window(
        &prep.server,
        &prep.session,
        &r.item,
        &prep.command,
        &opening,
    )? {
        Ok(pane) => pane,
        // Refused before the launcher was asked: `arm` failed before the
        // receipt or window was recorded, so nothing stands and the launch
        // fails with its cause.
        Err(OpenRefusal::Refused(e)) => {
            return Ok(operation.settle(Word::Failed, json!({"cause": e.key()})));
        }
        // The launcher was asked and did not answer: a window may stand
        // that nothing registers, an obligation the reconcile reads; the
        // intent stays open with it.
        Err(OpenRefusal::Unanswered { refusal }) => {
            return Ok(operation.hold(json!({
                "phase": "opening",
                "note": "window-unread",
                "cause": refusal.key(),
            })));
        }
        // The window opened and its line did not type. Its one pane was
        // closed by exact id: closed or gone, the launch fails with nothing
        // standing; a close the host did not answer for leaves the recorded
        // pane for the reconcile at `opening`, the intent open.
        Err(OpenRefusal::LineUnsent { refusal }) => {
            let mut outcome = operation.settle(
                Word::Failed,
                json!({
                    "phase": "opening",
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
    // The window exists and the line is typed: the window-opened phase is
    // recorded before the wait, the receipt standing until it is read.
    operation.record_phase(Phase::WindowOpened {
        opened: opened.clone(),
    })?;
    let polled = operation.await_state(
        &pane,
        prep.target.harness,
        &|name| prep.target.owns(name),
        None,
        &up,
    )?;
    // The identity the judge read is the attempt's from here: written into
    // the phase with the receipt read, so a reconcile of an intent left open
    // confirms that process and no other.
    if let Polled::Ready { identity }
    | Polled::Pending {
        identity: Some(identity),
        ..
    } = &polled
    {
        operation.record_identity(&mut opened, identity)?;
    }
    let mut outcome = launch_outcome(
        operation,
        prep.target.harness,
        prep.home.as_deref(),
        &prep.session,
        &r.item,
        &opened,
        &cwd,
        polled,
    )?;
    outcome.annotate("route", json!(route.word()));
    if let Some(cause) = route.cause() {
        outcome.annotate("route_cause", json!(cause));
    }
    Ok(outcome)
}

#[allow(clippy::too_many_arguments)]
fn launch_outcome(
    operation: Operation,
    harness: Harness,
    home: Option<&Path>,
    tmux_session: &str,
    item: &str,
    opened: &OpenedPane,
    cwd: &Path,
    polled: Polled,
) -> Result<EffectOutcome> {
    Ok(match polled {
        Polled::Ready { identity } => {
            let mut observation = json!({"pane": opened.pane, "server": opened.server});
            // The id the launch fixed, else the one lead session that
            // appeared for the cwd since the window opened, under the
            // account home or the harness's default home (decision 71).
            // Zero or several bind none, noted as a succession notes them:
            // a lane without a session id never runs under a neighbour's.
            let session_id = match &opened.session_id {
                Some(id) => Some(id.clone()),
                None => {
                    let home = home
                        .map(Path::to_path_buf)
                        .or_else(|| operation::default_home(harness));
                    match home {
                        None => {
                            observation["note"] = json!("home-unresolved");
                            None
                        }
                        Some(home) => match operation.appeared_session(harness, &home, cwd, opened)
                        {
                            Binding::Bound(session) => Some(session.session_id),
                            Binding::Absent => {
                                observation["note"] = json!("session-unbound");
                                None
                            }
                            Binding::Ambiguous(sessions) => {
                                observation["note"] = json!("session-ambiguous");
                                observation["sessions"] = json!(sessions);
                                None
                            }
                            // The harness is up in its pane and its store
                            // could not be read whole (decisions 95, 99): the
                            // launch is held at this phase with the cause,
                            // the pane kept, and the reconcile reads again.
                            Binding::Unreadable { cause } => {
                                observation["note"] = json!("session-store-unreadable");
                                observation["cause"] = json!(cause);
                                return Ok(launch_pane_unconfirmed(operation, opened, observation));
                            }
                        },
                    }
                }
            };
            // The lane launch publishes: its pane and identity pass to the
            // lane record and the whole set is consumed. A handle still
            // standing holds the launch at this phase.
            let wire_identity = identity.identity().clone();
            match operation.publish(Published::Lane, opened, &identity, observation.clone())? {
                Ok(outcome) => outcome.with_wire(Wire {
                    launch: Some(LaunchIdentity {
                        pane: Some(opened.pane.clone()),
                        server: Some(opened.server),
                        server_start: Some(opened.server_start),
                        pid: Some(wire_identity.pid as u64),
                        start: Some(wire_identity.start.clone()),
                    }),
                    session_id,
                    window: Some(format!("{tmux_session}:{item}")),
                    tmux_session: Some(tmux_session.to_owned()),
                    ..Wire::default()
                }),
                Err(operation) => {
                    observation["note"] = json!("launch-handles-standing");
                    launch_pane_unconfirmed(*operation, opened, observation)
                }
            }
        }
        Polled::Gone => launch_pane_gone(operation, opened, "pane-gone", json!({}))?,
        Polled::Pending { reading, state, .. } => {
            launch_pane_unconfirmed(operation, opened, pending_observation(&reading, &state))
        }
        Polled::Unobservable { cause } => launch_pane_unconfirmed(
            operation,
            opened,
            json!({"observed": "unobservable", "cause": cause}),
        ),
    })
}

/// The launch cells of the reconcile matrix: no phase means nothing opened,
/// `failed`; a recorded pane gone, or its server
/// replaced or gone, is `failed`; one an unanswering server still holds is
/// `unconfirmed`; one the harness holds at its composer or working is
/// `confirmed` with the identity read; any other reading is `unconfirmed`
/// with that reading and the pane marked present, which a close may
/// supersede (decision 67).
pub(super) fn reconcile_launch(run: &Run, intent: &Intent) -> Result<EffectOutcome> {
    let (lane, item) = lane_for_intent(run.path, &intent.id)?;
    let mut operation = Operation::open(run, intent)?;
    // Every standing handle is read by its own key first.
    operation.read_standing(None)?;
    let Some(phase) = &intent.phase else {
        return Ok(operation.settle(
            Word::Failed,
            json!({"reconcile": "launch", "phase": "none", "cause": "nothing-opened"}),
        ));
    };
    // At `opening` the window may or may not have opened before this
    // process ended: adopt the pane the intent's receipt names, fail the
    // recorded pane that never registered, or fail `nothing-opened`. The
    // adopted pane is recorded as `window-opened` under the identity the
    // receipt proved and judged as any other, its receipt noted on the
    // outcome; a pending reading binds no pane and leaves the lane as found
    // for the next reconcile.
    let (opened, registered) = match phase {
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
                (opened, Some(registered))
            }
            Recovered::Pending { note, cause } => {
                return Ok(operation.hold(opening_observation("launch", note, cause.as_deref())));
            }
            Recovered::Failed { note, cause } => {
                return Ok(
                    operation.settle(Word::Failed, opening_observation("launch", note, cause))
                );
            }
        },
        Phase::WindowOpened { opened }
        | Phase::Retired { opened }
        | Phase::Delivering { opened, .. }
        | Phase::Delivered { opened, .. }
        | Phase::IdentityRead { opened, .. } => (opened.clone(), None),
    };
    let mut outcome = judge_opened(operation, run, intent, &lane, &item, &opened)?;
    if let Some(registered) = registered {
        outcome.annotate("registered", registered);
    }
    Ok(outcome)
}

/// Judge the pane a launch intent names past `opening`: gone, or its server
/// replaced or gone, is `failed`; one an unanswering server still holds, or
/// one the host did not answer for, is `unconfirmed` with the cause; one
/// the harness holds at its composer or working is `confirmed` with the
/// identity read; any other reading is `unconfirmed` with that reading and
/// the pane marked present. With an identity in the phase, only that
/// process is the harness.
fn judge_opened(
    mut operation: Operation,
    run: &Run,
    intent: &Intent,
    lane: &Lane,
    item: &str,
    opened: &OpenedPane,
) -> Result<EffectOutcome> {
    let pane = match operation.observe_pane(opened)? {
        Observed::Unobservable { cause } => {
            return Ok(launch_pane_unconfirmed(
                operation,
                opened,
                json!({"reconcile": "launch", "observed": "unobservable", "cause": cause}),
            ));
        }
        Observed::Gone { cause } => {
            return launch_pane_gone(
                operation,
                opened,
                cause,
                json!({"reconcile": "launch", "observed": "gone"}),
            );
        }
        Observed::Present(pane) => pane,
    };
    let Some(harness) = pane_harness(lane, Some(intent)) else {
        return Ok(launch_pane_unconfirmed(
            operation,
            opened,
            json!({"reconcile": "launch", "observed": "present", "cause": "harness-unknown"}),
        ));
    };
    let target = Target::new(run.settings, harness);
    let (foreground, state) = match operation.read_pane(
        &pane,
        harness,
        &|name| target.owns(name),
        opened.identity.as_ref(),
    )? {
        Reading::Live(read) => read,
        Reading::Gone => {
            return launch_pane_gone(
                operation,
                opened,
                "pane-gone",
                json!({"reconcile": "launch", "observed": "gone"}),
            );
        }
        Reading::Unreadable { cause } => {
            return Ok(launch_pane_unconfirmed(
                operation,
                opened,
                json!({"reconcile": "launch", "observed": "unobservable", "cause": cause}),
            ));
        }
    };
    let Foreground {
        reading,
        harness: read,
    } = foreground;
    // An identity first read here is the attempt's from now on, written into
    // the phase and the set before the outcome.
    let mut opened = opened.clone();
    if opened.identity.is_none()
        && let Some(identity) = &read
    {
        operation.record_identity(&mut opened, identity)?;
    }
    let opened = &opened;
    if up(&state)
        && let Some(identity) = read
    {
        let home = lane
            .account
            .as_deref()
            .map(PathBuf::from)
            .or_else(|| operation::default_home(harness));
        let cwd = lane
            .mail_root
            .as_deref()
            .map(PathBuf::from)
            .unwrap_or_default();
        let mut outcome = launch_outcome(
            operation,
            harness,
            home.as_deref(),
            &pane.session,
            item,
            opened,
            &cwd,
            Polled::Ready { identity },
        )?;
        outcome.annotate("reconcile", json!("launch"));
        return Ok(outcome);
    }
    let mut observation = pending_observation(&reading, &state);
    observation["reconcile"] = json!("launch");
    observation["observed"] = json!("present");
    Ok(launch_pane_unconfirmed(operation, opened, observation))
}

#[allow(
    clippy::disallowed_methods,
    reason = "the rows write the item files and directories the launch reads"
)]
#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;
    use crate::state::LaneStatus;

    fn bound_lane(account: &str, mail_root: Option<&Path>) -> Lane {
        Lane {
            item: "KEN-7".to_owned(),
            tracker: None,
            repo: None,
            harness: Some("claude".to_owned()),
            window: None,
            account: Some(account.to_owned()),
            host: None,
            kind: None,
            mail_root: mail_root.map(|p| p.display().to_string()),
            surface: None,
            model: None,
            effort: None,
            session_id: Some("0f6e2c1a-7d1b-4a0e-9f3c-2b5d8e1f4a6c".to_owned()),
            session_since: None,
            launched_at: None,
            running_at: None,
            status: LaneStatus::Stopped,
            over_cap: None,
            launch: None,
            reservation: None,
            touched: None,
            in_scope: None,
            rebase: Vec::new(),
            extra: Default::default(),
        }
    }

    fn request(account: &str, mail_root: &Path) -> LaunchLane {
        LaunchLane {
            item: "KEN-7".to_owned(),
            harness: "claude".to_owned(),
            mail_root: mail_root.display().to_string(),
            tracker: None,
            repo: None,
            account: Some(account.to_owned()),
            model: None,
            effort: None,
            kind: None,
            surface: None,
            over_cap: None,
            exclude_account: None,
            brief_file: None,
            repo_dir: None,
            scope_range: None,
            in_scope: Vec::new(),
        }
    }

    /// Decision 108 (4): the relaunch router. A bound session resumes under
    /// the same harness and account when the destination home holds its
    /// file; a request on another account, or a destination with no file
    /// for the fixed id, starts fresh with `account-switched`; a standing
    /// handoff that says `fresh` and a changed harness keep their causes.
    #[test]
    fn a_relaunch_on_another_account_or_without_its_session_file_starts_fresh() {
        let dir = tempfile::tempdir().unwrap();
        let cwd = dir.path().join("w");
        fs::create_dir_all(&cwd).unwrap();
        let a = dir.path().join("a");
        let b = dir.path().join("b");
        let id = "0f6e2c1a-7d1b-4a0e-9f3c-2b5d8e1f4a6c";
        let file = operation::fixed_file(Harness::Claude, &a, &cwd, id).unwrap();
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(&file, "{}\n").unwrap();
        let lane = bound_lane(&a.display().to_string(), Some(&cwd));
        let same = request(&a.display().to_string(), &cwd);
        let other = request(&b.display().to_string(), &cwd);
        let present = &operation::session_present;
        assert!(matches!(
            route_of(&lane, &same, None, Some(&a), present),
            Route::Resume { session_id } if session_id == id
        ));
        assert!(matches!(
            route_of(&lane, &same, Some(Relaunch::Resume), Some(&a), present),
            Route::Resume { .. }
        ));
        assert!(matches!(
            route_of(&lane, &other, None, Some(&b), present),
            Route::Fresh {
                cause: Some("account-switched")
            }
        ));
        // The same account recorded, the file gone from the destination.
        fs::remove_file(&file).unwrap();
        assert!(matches!(
            route_of(&lane, &same, None, Some(&a), present),
            Route::Fresh {
                cause: Some("account-switched")
            }
        ));
        fs::write(&file, "{}\n").unwrap();
        assert!(matches!(
            route_of(&lane, &same, Some(Relaunch::Fresh), Some(&a), present),
            Route::Fresh {
                cause: Some("session-retired")
            }
        ));
        let mut codex = same.clone();
        codex.harness = "codex".to_owned();
        assert!(matches!(
            route_of(&lane, &codex, None, Some(&a), present),
            Route::Fresh {
                cause: Some("harness-switched")
            }
        ));
        let mut unbound = lane.clone();
        unbound.session_id = None;
        assert!(matches!(
            route_of(&unbound, &same, None, Some(&a), present),
            Route::Fresh { cause: None }
        ));
    }

    /// Decision 115 (G): the relaunch route reads the destination session
    /// store for the bound id through the session owner's fixed-id lookup,
    /// for every resumable harness and three-valued: absent starts fresh
    /// `account-switched`, present resumes, unreadable refuses before any
    /// window. The working directory reaches the Claude arm alone (decision
    /// 120, L3): a Codex lane with no `mail_root` is still looked up.
    #[test]
    fn a_relaunch_reads_the_destination_store_for_each_resumable_harness() {
        let dir = tempfile::tempdir().unwrap();
        let cwd = dir.path().join("w");
        fs::create_dir_all(&cwd).unwrap();
        let home = dir.path().join("home");
        fs::create_dir_all(&home).unwrap();
        let id = "0f6e2c1a-7d1b-4a0e-9f3c-2b5d8e1f4a6c";
        let account = home.display().to_string();
        let bound = |harness: &str, root: Option<&Path>| {
            let mut lane = bound_lane(&account, root);
            lane.harness = Some(harness.to_owned());
            lane
        };
        let request = |harness: &str| {
            let mut r = request(&account, &cwd);
            r.harness = harness.to_owned();
            r
        };
        // The lookup as the route sees it: each row's reading, and which
        // working directory the route handed it.
        let asked: std::cell::RefCell<Vec<(Harness, PathBuf)>> = Default::default();
        let answer = std::cell::RefCell::new(Reading::Gone);
        let present = |harness: Harness, _: &Path, cwd: &Path, _: &str| {
            asked.borrow_mut().push((harness, cwd.to_path_buf()));
            answer.borrow().clone()
        };
        assert!(matches!(
            route_of(
                &bound("codex", None),
                &request("codex"),
                None,
                Some(&home),
                &present
            ),
            Route::Fresh {
                cause: Some("account-switched")
            }
        ));
        assert!(matches!(
            route_of(
                &bound("copilot", None),
                &request("copilot"),
                None,
                Some(&home),
                &present
            ),
            Route::Fresh {
                cause: Some("account-switched")
            }
        ));
        assert!(matches!(
            route_of(
                &bound("claude", None),
                &request("claude"),
                None,
                Some(&home),
                &present
            ),
            Route::Resume { .. }
        ));
        assert_eq!(
            asked.borrow().clone(),
            vec![
                (Harness::Codex, PathBuf::from("")),
                (Harness::Copilot, PathBuf::from("")),
            ],
            "Codex and Copilot are looked up with no directory; Claude with none recorded is not"
        );
        asked.borrow_mut().clear();
        *answer.borrow_mut() = Reading::Live(());
        assert!(matches!(
            route_of(&bound("claude", Some(&cwd)), &request("claude"), None, Some(&home), &present),
            Route::Resume { session_id } if session_id == id
        ));
        assert!(matches!(
            route_of(
                &bound("codex", Some(&cwd)),
                &request("codex"),
                None,
                Some(&home),
                &present
            ),
            Route::Resume { .. }
        ));
        assert_eq!(
            asked.borrow().clone(),
            vec![
                (Harness::Claude, cwd.clone()),
                (Harness::Codex, PathBuf::from(""))
            ],
            "the working directory reaches the Claude arm alone"
        );
        *answer.borrow_mut() = Reading::Unreadable {
            cause: "store-unreadable",
        };
        assert!(
            matches!(
                route_of(
                    &bound("copilot", Some(&cwd)),
                    &request("copilot"),
                    None,
                    Some(&home),
                    &present
                ),
                Route::Refuse { .. }
            ),
            "an unreadable store refuses before any window"
        );
    }
}
