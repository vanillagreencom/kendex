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
//! Before each wait an effect writes its progress into its intent as a
//! phase, with the pane it holds (decision 62), so a `reconcile` after the
//! effect's process ended completes the effect from that step. The one
//! reading that confirms a launch or lets a brief be delivered is the judge's
//! `idle` or `working` with the harness itself in the pane's foreground
//! (decision 60); a shell at its prompt, whatever it draws, confirms nothing.
//! A delivered brief is confirmed from the runner's own native session file,
//! bound once before the paste: the file its fixed session id names, or the
//! one lead file that appeared after the window opened and stood in no
//! baseline read before it (decision 65). A neighbouring session in the same
//! home and directory is never read.
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

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use agent_runtime::harness::Harness;
use agent_runtime::host::tmux::{self, Pane, Server};
use agent_runtime::launch::{self, Brief, Compaction, LaunchCommand, LaunchIntent, QuestionTool};
use agent_runtime::observe::{self, ProcessReading, State};
use agent_runtime::process::{self, Identity, Liveness, Stop};
use agent_runtime::protocol::Outcome;
use agent_runtime::session;
use serde_json::{Value, json};

use crate::error::{Error, Result};
use crate::ops::{
    self, Applied, Effect, Env, LaunchLane, RecordOutcome, RecordPhase, Report, Request,
    RequestTransfer, overseer_target,
};
use crate::settings::Settings;
use crate::state::{
    self, BoundSession, EffectOp, Intent, Lane, LaunchIdentity, Locking, OpenedPane, Overseer,
    Phase,
};

/// The clock the poll loops read, injected so a bound can be waited without
/// real time passing. Production is the system clock.
pub trait Clock: Sync {
    fn now(&self) -> Instant;
    fn sleep(&self, d: Duration);
}

/// `Instant::now` and `std::thread::sleep`.
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> Instant {
        Instant::now()
    }
    fn sleep(&self, d: Duration) {
        std::thread::sleep(d);
    }
}

/// How often a poll re-reads the pane or the session file within its bound.
const POLL: Duration = Duration::from_millis(200);

/// What one effect run or reconcile acts with: the record, the settings,
/// the writer's stamp and lock policy, and the clock its waits read.
struct Run<'a> {
    path: &'a Path,
    settings: &'a Settings,
    env: &'a Env,
    locking: Locking,
    clock: &'a dyn Clock,
}

impl Run<'_> {
    /// Write the effect's phase into its intent, committed before the wait
    /// that follows (decision 62).
    fn record_phase(&self, intent_id: &str, phase: Phase) -> Result<()> {
        ops::apply(
            self.path,
            &Request::RecordPhase(RecordPhase {
                intent_id: intent_id.to_owned(),
                phase,
            }),
            self.env,
            self.locking,
        )?;
        Ok(())
    }

    /// The record-outcome request an effect's observation builds, applied on
    /// the same file as a second committed transition.
    fn apply_outcome(&self, outcome: RecordOutcome) -> Result<Applied> {
        ops::apply(
            self.path,
            &Request::RecordOutcome(Box::new(outcome)),
            self.env,
            self.locking,
        )
    }
}

/// Stop the recorded identity itself and the harness-named processes below
/// it, each only while its start still matches: the exact TERM then KILL on
/// the recorded pid+start tree. `agent_runtime::process::stop_tree` stops
/// only the matching descendants; the recorded identity is the harness, so
/// it is always a target. An identity the pid no longer carries is
/// `IdentityStale`, never a name-based kill.
fn stop_recorded(root: &Identity, owns: &dyn Fn(&str) -> bool, grace: Duration) -> Result<Stop> {
    match process::still_runs(root)? {
        Liveness::Gone => {
            return Ok(match process::start(root.pid)? {
                Some(_) => Stop::IdentityStale,
                None => Stop::AlreadyGone,
            });
        }
        Liveness::Zombie => return Ok(Stop::AlreadyGone),
        Liveness::Live => {}
    }
    let rows = process::table()?;
    let mut targets = vec![root.clone()];
    for (_, pid) in process::below(&rows, root.pid, owns) {
        if pid != root.pid
            && let Some(id) = process::identity(pid)?
        {
            targets.push(id);
        }
    }
    Ok(process::stop_identities(&targets, grace)?)
}

/// Run the effect a just-persisted intent names and record its outcome, or
/// reconcile an intent a repeated request found open. The returned value is
/// the `record-outcome` transition, so a caller sees the committed record.
/// A request with no live effect returns `None`.
pub fn run(
    path: &Path,
    request: &Request,
    report: &Report,
    settings: &Settings,
    env: &Env,
    locking: Locking,
    clock: &dyn Clock,
) -> Result<Option<Applied>> {
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
        _ => return Ok(None),
    };
    let intent = match effect {
        // A repeated request found an open intent: reconcile it rather than
        // start a second effect (plan § Records).
        Effect::Reconciled { intent } => {
            let applied = reconcile_intent(&run, &intent.id)?;
            // A close whose reconcile still reads a stop to run, the recorded
            // identity live and unchanged or a recorded pane present, is a
            // stop never completed. The request asked for that stop, and the
            // stop is exact on the identity it reads, so the repeat runs it
            // rather than leaving the lane with no route (decisions 64, 67).
            if matches!(request, Request::CloseOwnedResources(_)) && stop_route_open(&applied) {
                let outcome = stop_effect(&run, &intent.id)?;
                return run.apply_outcome(outcome).map(Some);
            }
            return Ok(Some(applied));
        }
        // A close over an open launch intent (decision 67).
        Effect::Supersedes { intent } => return supersede_launch(&run, request, &intent.id),
        Effect::Persisted { intent } => intent.clone(),
    };
    let outcome = match request {
        Request::LaunchLane(r) => launch_effect(&run, &intent.id, r),
        Request::CloseOwnedResources(_) => stop_effect(&run, &intent.id),
        Request::RequestTransfer(r) => transfer_effect(&run, &intent.id, r),
        _ => return Ok(None),
    }?;
    let applied = run.apply_outcome(outcome)?;
    Ok(Some(applied))
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
    read("stop").as_deref() == Some("pending") || read("pane").as_deref() == Some("present")
}

/// A close asked for over an open launch intent (decision 67). The launch
/// is reconciled first: an outcome of its own leaves the lane as any close
/// finds it. One still unconfirmed with its pane present is closed `failed`
/// with `superseded-by-close`, since a hung launch would otherwise have
/// neither a close nor a relaunch, and the close then stops what that pane
/// holds. One whose pane cannot be observed is left open, and the close
/// refuses `intent-open` as before: there is nothing to stop by.
fn supersede_launch(run: &Run, request: &Request, launch_id: &str) -> Result<Option<Applied>> {
    let reconciled = reconcile_intent(run, launch_id)?;
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
            .map(|p| p.opened().pane.clone());
        run.apply_outcome(RecordOutcome {
            observation: Some(json!({
                "reconcile": "launch",
                "cause": "superseded-by-close",
                "pane": pane,
            })),
            ..failed_before_window(launch_id, "superseded-by-close")
        })?;
    }
    // The launch intent is closed either way: the close now persists its
    // own intent and runs, as a close with nothing open does.
    let applied = ops::apply(run.path, request, run.env, run.locking)?;
    let Report::CloseOwnedResources(close) = &applied.report else {
        unreachable!("a close request reports a close")
    };
    let Effect::Persisted { intent } = &close.effect else {
        unreachable!("the launch intent was closed above and no close stood open")
    };
    let outcome = stop_effect(run, &intent.id)?;
    run.apply_outcome(outcome).map(Some)
}

// ---------------------------------------------------------------------------
// The fleet's tmux server
// ---------------------------------------------------------------------------

/// The tmux server a fleet window opens on and the session it opens in: the
/// socket the runtime's own `$TMUX` names or the user's default, as
/// `lib/tmux-server.sh` resolves it, and the session the settings name, else
/// the fleet record's `tmux.session`.
fn fleet_server(settings: &Settings, doc_session: Option<&str>) -> Result<(Server, String)> {
    let session = settings
        .tmux_session
        .as_deref()
        .or(doc_session)
        .map(str::to_owned)
        .ok_or_else(|| {
            Error::from(agent_runtime::Error::refused(
                "tmux-session-unresolved",
                &[],
            ))
        })?;
    let socket = tmux::ambient_socket();
    let server = tmux::server(&socket)?;
    if !tmux::session_present(&server, &session)? {
        return Err(agent_runtime::Error::refused(
            "tmux-session-missing",
            &[
                ("session", &session),
                ("socket", &socket.display().to_string()),
            ],
        )
        .into());
    }
    Ok((server, session))
}

/// What a launch fixed about the runner's native session before its window
/// opened (decision 65): the id it passed on the command line, or the lead
/// sessions that already stood for the cwd, so the one that appears can be
/// told from them.
enum SessionFloor {
    Fixed(String),
    Baseline(Vec<String>),
}

impl SessionFloor {
    /// Mint the id where the harness takes one, else read the baseline.
    fn read(harness: Harness, home: &Path, cwd: &Path) -> Result<SessionFloor> {
        if harness.fixes_session_id() {
            return Ok(SessionFloor::Fixed(session::fresh_session_id()?));
        }
        Ok(SessionFloor::Baseline(session::lead_ids(
            harness, home, cwd,
        )?))
    }

    fn session_id(&self) -> Option<&str> {
        match self {
            SessionFloor::Fixed(id) => Some(id),
            SessionFloor::Baseline(_) => None,
        }
    }
}

/// The pane an effect opened, as its phases record it: the pane on its
/// server by socket, pid, start and the server process's identity, the
/// floor its native session is read above, the session floor the launch
/// fixed, and the brief a succession holds for it.
fn opened_pane(
    pane: &Pane,
    since: SystemTime,
    floor: &SessionFloor,
    brief: Option<&Path>,
) -> Result<OpenedPane> {
    let (session_id, baseline) = match floor {
        SessionFloor::Fixed(id) => (Some(id.clone()), Vec::new()),
        SessionFloor::Baseline(ids) => (None, ids.clone()),
    };
    Ok(OpenedPane {
        pane: pane.id.clone(),
        server: pane.server.pid as u64,
        server_start: pane.server.start,
        server_process_start: process::identity(pane.server.pid)?.map(|i| i.start),
        socket: pane.server.socket.display().to_string(),
        since_ms: since
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0),
        brief: brief.map(|b| b.display().to_string()),
        session_id,
        baseline,
    })
}

/// The session floor a recorded pane carries.
fn since_of(opened: &OpenedPane) -> SystemTime {
    UNIX_EPOCH + Duration::from_millis(opened.since_ms)
}

/// What a recorded pane reads as on its own server, reached by the recorded
/// socket whatever the caller's `$TMUX` names. One socket is held by one
/// server: another server answering on it, or no answer with the recorded
/// server process gone, proves the recorded server and every pane it held
/// gone. Only an unanswering socket whose server process still runs is
/// unobservable (decision 66).
enum Observed {
    Unobservable { cause: &'static str },
    Gone { cause: &'static str },
    Present(Pane),
}

/// Whether the recorded server process is gone, by its pid and start
/// through the one identity reader; a record carrying the pid alone is
/// read by liveness, which never reads a dead pid live.
fn server_gone(server: u64, process_start: Option<&str>) -> Result<Option<bool>> {
    let Ok(pid) = u32::try_from(server) else {
        return Ok(None);
    };
    let liveness = match process_start {
        Some(start) => process::still_runs(&Identity {
            pid,
            start: start.to_owned(),
        })?,
        None => process::liveness(pid)?,
    };
    Ok(Some(liveness != Liveness::Live))
}

/// The reading of a socket that does not answer: gone with its server
/// process, else unobservable.
fn unanswering(server: u64, process_start: Option<&str>) -> Result<Observed> {
    Ok(match server_gone(server, process_start)? {
        Some(true) => Observed::Gone {
            cause: "server-gone",
        },
        Some(false) => Observed::Unobservable {
            cause: "server-unreachable",
        },
        None => Observed::Unobservable {
            cause: "server-pid-invalid",
        },
    })
}

fn observe_pane(opened: &OpenedPane) -> Result<Observed> {
    let server = match tmux::server(Path::new(&opened.socket)) {
        Ok(server) => server,
        Err(_) => return unanswering(opened.server, opened.server_process_start.as_deref()),
    };
    if server.pid as u64 != opened.server || server.start != opened.server_start {
        return Ok(Observed::Gone {
            cause: "server-replaced",
        });
    }
    Ok(match tmux::pane_by_id(&server, &opened.pane)? {
        Some(pane) => Observed::Present(pane),
        None => Observed::Gone { cause: "pane-gone" },
    })
}

/// The pane a lane's `launch` names, on the caller's ambient server: a lane
/// record carries the server's pid alone, so another server at the ambient
/// socket, or none, is read against that pid's liveness: a dead pid is a
/// server gone with its panes, a live one a server this caller cannot see.
fn observe_launch(launch: &LaunchIdentity) -> Result<Observed> {
    let (Some(server_pid), Some(pane_id)) = (launch.server, launch.pane.clone()) else {
        return Ok(Observed::Unobservable {
            cause: "pane-unrecorded",
        });
    };
    let server = match tmux::server(&tmux::ambient_socket()) {
        Ok(server) if server.pid as u64 == server_pid => server,
        Ok(_) | Err(_) => return unanswering(server_pid, None),
    };
    Ok(match tmux::pane_by_id(&server, &pane_id)? {
        Some(pane) => Observed::Present(pane),
        None => Observed::Gone { cause: "pane-gone" },
    })
}

// ---------------------------------------------------------------------------
// Launch
// ---------------------------------------------------------------------------

/// What one launch runs: the harness, account home, model, effort, working
/// directory, opening brief and question-tool posture a launch or a
/// succession resolved.
struct Spec<'a> {
    harness: Harness,
    account: Option<&'a str>,
    model: Option<&'a str>,
    effort: Option<&'a str>,
    cwd: &'a Path,
    brief: Option<&'a Path>,
    question_tool: QuestionTool,
    /// The session id the launch fixes, for a harness that takes one.
    session_id: Option<&'a str>,
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
/// test selects its stub through the one binary-path setting.
fn build_launch(settings: &Settings, spec: &Spec) -> Result<(LaunchIntent, LaunchCommand)> {
    let intent = LaunchIntent {
        harness: spec.harness,
        home: spec.account.map(PathBuf::from),
        cwd: spec.cwd.to_path_buf(),
        model: spec.model.map(str::to_owned),
        effort: spec.effort.map(str::to_owned),
        permission: settings.permission,
        question_tool: spec.question_tool,
        compaction: Compaction::Native,
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
        extra_args: Vec::new(),
        program: settings.harness_binaries.get(&spec.harness).cloned(),
    };
    let command = launch::build(&intent)?;
    Ok((intent, command))
}

fn refused(key: &'static str, fields: &[(&str, &str)]) -> Error {
    Error::from(agent_runtime::Error::refused(key, fields))
}

/// Whether the command's program will run: a path names an existing file,
/// a bare name is found on this process's `PATH`, the same lookup the
/// pane's shell makes.
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

/// Open a window on `server` running `command` and return its pane.
fn open_window(
    server: &Server,
    session: &str,
    name: &str,
    command: &LaunchCommand,
) -> Result<Pane> {
    let pane = tmux::new_window(server, session, name, &command.cwd, &command.shell_line())?;
    Ok(pane)
}

/// What a poll of a pane settled on.
enum Settled {
    /// The harness holds the pane under `identity` and the screen reads a
    /// state the caller accepts.
    Ready { identity: Identity },
    /// The pane is gone: the exec'd harness exited.
    Gone,
    /// The bound passed; the last reading is carried for the record.
    Pending {
        reading: ProcessReading,
        state: State,
    },
}

/// One reading of a pane: who holds its terminal and what the screen says.
/// `None` when the pane went between reads.
fn read_pane(
    pane: &Pane,
    target: &Target,
    recorded: Option<&Identity>,
) -> Result<Option<(ProcessReading, State)>> {
    if !tmux::pane_present(pane)? {
        return Ok(None);
    }
    let pane_pid = match tmux::pane_process(pane) {
        Ok((_, pid)) => pid,
        Err(e) => {
            if !tmux::pane_present(pane).unwrap_or(false) {
                return Ok(None);
            }
            return Err(e.into());
        }
    };
    let reading = observe::foreground(pane_pid, &|name| target.owns(name), recorded)?;
    let screen = match tmux::capture(pane) {
        Ok(screen) => screen,
        Err(e) => {
            // The pane may have gone between the present check and the
            // capture: a harness exit. A capture that fails with the pane
            // still present is a real error.
            if !tmux::pane_present(pane).unwrap_or(false) {
                return Ok(None);
            }
            return Err(e.into());
        }
    };
    let state = observe::judge(&screen, target.harness, &reading, None);
    Ok(Some((reading, state)))
}

/// Poll the pane until the harness holds it and the screen reads a state
/// `accept` takes, the pane goes, or the bound passes. With `recorded`, only
/// that identity is the harness (decision 60).
fn await_state(
    run: &Run,
    pane: &Pane,
    target: &Target,
    recorded: Option<&Identity>,
    accept: &dyn Fn(&State) -> bool,
) -> Result<Settled> {
    let deadline = run.clock.now() + run.settings.verify;
    loop {
        let Some((reading, state)) = read_pane(pane, target, recorded)? else {
            return Ok(Settled::Gone);
        };
        if let ProcessReading::Harness { identity } = &reading
            && accept(&state)
        {
            return Ok(Settled::Ready {
                identity: identity.clone(),
            });
        }
        if run.clock.now() >= deadline {
            return Ok(Settled::Pending { reading, state });
        }
        run.clock.sleep(POLL);
    }
}

fn up(state: &State) -> bool {
    matches!(state, State::Idle | State::Working)
}

fn idle(state: &State) -> bool {
    *state == State::Idle
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
/// before the effect starts anything.
fn prepare_launch(
    settings: &Settings,
    r: &LaunchLane,
    doc_session: Option<&str>,
) -> Result<LaunchPrep> {
    let harness = Harness::parse(&r.harness)
        .ok_or_else(|| refused("harness-unknown", &[("harness", &r.harness)]))?;
    let (server, session) = fleet_server(settings, doc_session)?;
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
        .or_else(|| session::default_home(harness));
    let floor = match &home {
        Some(home) => SessionFloor::read(harness, home, &cwd)?,
        None => SessionFloor::Baseline(Vec::new()),
    };
    let (_, command) = build_launch(
        settings,
        &Spec {
            harness,
            account: r.account.as_deref(),
            model: r.model.as_deref(),
            effort: r.effort.as_deref(),
            cwd: &cwd,
            brief: r.brief_file.as_deref(),
            question_tool: QuestionTool::Off,
            session_id: floor.session_id(),
        },
    )?;
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

/// A `failed` launch outcome with the cause, for a refusal knowable before
/// the window opens: the lane records `stopped`, a relaunch is clean, and the
/// intent closes rather than wedging at `not-started`.
fn failed_before_window(intent_id: &str, cause: &str) -> RecordOutcome {
    RecordOutcome {
        intent_id: intent_id.to_owned(),
        outcome: Outcome::Failed,
        launch: None,
        session_id: None,
        server_start: None,
        server_socket: None,
        window: None,
        tmux_session: None,
        launch_line: None,
        observation: Some(json!({"cause": cause})),
    }
}

/// An outcome once the window exists: the pane is carried on `launch` so a
/// reconcile can re-observe it, with what was observed.
fn launch_pane_outcome(
    intent_id: &str,
    opened: &OpenedPane,
    outcome: Outcome,
    observation: Value,
) -> RecordOutcome {
    let mut observation = observation;
    observation["pane"] = json!(opened.pane);
    observation["server"] = json!(opened.server);
    RecordOutcome {
        intent_id: intent_id.to_owned(),
        outcome,
        launch: Some(LaunchIdentity {
            pane: Some(opened.pane.clone()),
            server: Some(opened.server),
            pid: None,
            start: None,
        }),
        session_id: None,
        server_start: None,
        server_socket: None,
        window: None,
        tmux_session: None,
        launch_line: None,
        observation: Some(observation),
    }
}

/// The observation a pending reading leaves on the record.
fn pending_observation(reading: &ProcessReading, state: &State) -> Value {
    json!({
        "process": serde_json::to_value(reading).unwrap_or(Value::Null),
        "state": serde_json::to_value(state).unwrap_or(Value::Null),
    })
}

fn launch_effect(run: &Run, intent_id: &str, r: &LaunchLane) -> Result<RecordOutcome> {
    let doc_session = fleet_tmux_session(run.path)?;
    let cwd = PathBuf::from(&r.mail_root);
    let prep = match prepare_launch(run.settings, r, doc_session.as_deref()) {
        Ok(prep) => prep,
        // A harness, session, directory, program or brief the effect cannot
        // resolve: `failed` before anything opens, never a bare refusal.
        Err(e) => return Ok(failed_before_window(intent_id, e.key())),
    };
    // The floor excludes a session an earlier run retired.
    let since = SystemTime::now();
    let pane = match open_window(&prep.server, &prep.session, &r.item, &prep.command) {
        Ok(pane) => pane,
        Err(e) => return Ok(failed_before_window(intent_id, e.key())),
    };
    let opened = opened_pane(&pane, since, &prep.floor, None)?;
    // The window exists: it is recorded before the wait, so a reconcile
    // finds it whatever ends this process (decision 62).
    run.record_phase(
        intent_id,
        Phase::WindowOpened {
            opened: opened.clone(),
        },
    )?;
    let settled = await_state(run, &pane, &prep.target, None, &up)?;
    launch_outcome(
        intent_id,
        prep.target.harness,
        prep.home.as_deref(),
        &prep.session,
        &r.item,
        &opened,
        &cwd,
        settled,
    )
}

#[allow(clippy::too_many_arguments)]
fn launch_outcome(
    intent_id: &str,
    harness: Harness,
    home: Option<&Path>,
    tmux_session: &str,
    item: &str,
    opened: &OpenedPane,
    cwd: &Path,
    settled: Settled,
) -> Result<RecordOutcome> {
    Ok(match settled {
        Settled::Ready { identity } => {
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
                        .or_else(|| session::default_home(harness));
                    match home {
                        None => {
                            observation["note"] = json!("home-unresolved");
                            None
                        }
                        Some(home) => match appeared_session(harness, &home, cwd, opened)? {
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
                        },
                    }
                }
            };
            RecordOutcome {
                intent_id: intent_id.to_owned(),
                outcome: Outcome::Confirmed,
                launch: Some(LaunchIdentity {
                    pane: Some(opened.pane.clone()),
                    server: Some(opened.server),
                    pid: Some(identity.pid as u64),
                    start: Some(identity.start.clone()),
                }),
                session_id,
                server_start: None,
                server_socket: None,
                window: Some(format!("{tmux_session}:{item}")),
                tmux_session: Some(tmux_session.to_owned()),
                launch_line: None,
                observation: Some(observation),
            }
        }
        Settled::Gone => launch_pane_outcome(
            intent_id,
            opened,
            Outcome::Failed,
            json!({"cause": "pane-gone"}),
        ),
        Settled::Pending { reading, state } => launch_pane_outcome(
            intent_id,
            opened,
            Outcome::Unconfirmed,
            pending_observation(&reading, &state),
        ),
    })
}

// ---------------------------------------------------------------------------
// Stop
// ---------------------------------------------------------------------------

fn stop_effect(run: &Run, intent_id: &str) -> Result<RecordOutcome> {
    let (lane, item) = lane_for_intent(run.path, intent_id)?;
    let prior = read_intent(run.path, intent_id)?.observation;
    let launch = lane.launch.as_ref();
    let recorded = launch.and_then(launch_identity);
    let harness = pane_harness(&lane, launch_intent_of(run.path, &item)?.as_ref());
    let close = Close {
        run,
        intent_id,
        item: &item,
        lane: &lane,
        launch,
        target: harness.map(|h| Target::new(run.settings, h)),
        prior: prior.as_ref(),
    };
    let Some(identity) = recorded else {
        // No recorded process identity: the pane the record names is the
        // one handle left, and what it holds is stopped by the identity
        // read there (decision 67).
        return close.by_pane(json!({"identity": "none"}));
    };
    // Copilot writes its session totals on `/exit`; give it that before the
    // signal, as `lane-close` does. Best effort: the signal stop below
    // handles a pane that did not exit.
    if harness == Some(Harness::Copilot) {
        copilot_exit(launch, run.settings.close_grace);
    }
    let stop = stop_recorded(
        &identity,
        &|name| close.owns(name),
        run.settings.close_grace,
    )?;
    match stop {
        Stop::Stopped { .. } | Stop::AlreadyGone => {
            // The detached wake turn runs outside the pane's process tree; it
            // keeps calling tools after the lane closes unless it is stopped
            // here, before the record reads done.
            stop_wake(&lane, close.target.as_ref(), run.settings.close_grace)?;
            close_window(launch)?;
            Ok(close.outcome(Outcome::Confirmed, json!({"identity": "stopped"})))
        }
        // The pid now holds another process: never a name-based kill. The
        // recorded pane, where there is one, is stopped by what it holds
        // (decision 67); with none the reading counts towards decision 68.
        Stop::IdentityStale => close.by_pane(json!({"identity": "stale"})),
        Stop::Timeout { pid } => Ok(close.outcome(
            Outcome::Unconfirmed,
            json!({"identity": "live", "timeout_pid": pid}),
        )),
    }
}

/// One close in progress: the lane, its recorded pane and harness, and the
/// intent's prior observation, which a repeated stale reading counts from.
struct Close<'a> {
    run: &'a Run<'a>,
    intent_id: &'a str,
    item: &'a str,
    lane: &'a Lane,
    launch: Option<&'a LaunchIdentity>,
    target: Option<Target>,
    prior: Option<&'a Value>,
}

impl Close<'_> {
    fn owns(&self, name: &str) -> bool {
        self.target.as_ref().is_some_and(|t| t.owns(name))
    }

    fn outcome(&self, outcome: Outcome, observation: Value) -> RecordOutcome {
        let mut observation = observation;
        observation["item"] = json!(self.item);
        observation["pane"] = json!(self.launch.and_then(|l| l.pane.clone()));
        RecordOutcome {
            intent_id: self.intent_id.to_owned(),
            outcome,
            launch: None,
            session_id: None,
            server_start: None,
            server_socket: None,
            window: None,
            tmux_session: None,
            launch_line: None,
            observation: Some(observation),
        }
    }

    /// The pane route (decision 67): the recorded pane present is stopped
    /// by the harness identity read in its foreground now, or closed alone
    /// when no harness holds it. With no identity recorded, a pane gone
    /// took its processes with it. A stale identity never confirms on one
    /// reading, whatever the pane shows (decision 59): the pane gone or
    /// unobservable counts one reading towards decision 68.
    fn by_pane(&self, mut observation: Value) -> Result<RecordOutcome> {
        let grace = self.run.settings.close_grace;
        let stale = observation["identity"] == json!("stale");
        let observed = match self.launch {
            Some(launch) => observe_launch(launch)?,
            None => Observed::Unobservable {
                cause: "pane-unrecorded",
            },
        };
        let pane = match observed {
            Observed::Gone { cause } => {
                observation["pane"] = json!("gone");
                observation["cause"] = json!(cause);
                let outcome = if stale {
                    stale_reading(self.prior, &mut observation)
                } else {
                    Outcome::Confirmed
                };
                if outcome == Outcome::Confirmed {
                    stop_wake(self.lane, self.target.as_ref(), grace)?;
                }
                return Ok(self.outcome(outcome, observation));
            }
            Observed::Unobservable { cause } => {
                observation["pane"] = json!("unobservable");
                observation["cause"] = json!(cause);
                let outcome = if stale {
                    stale_reading(self.prior, &mut observation)
                } else {
                    Outcome::Unconfirmed
                };
                return Ok(self.outcome(outcome, observation));
            }
            Observed::Present(pane) => pane,
        };
        let pane_pid = match tmux::pane_process(&pane) {
            Ok((_, pid)) => pid,
            Err(e) => {
                // The pane went between the two reads: its processes with it.
                if !tmux::pane_present(&pane).unwrap_or(false) {
                    stop_wake(self.lane, self.target.as_ref(), grace)?;
                    observation["pane"] = json!("gone");
                    return Ok(self.outcome(Outcome::Confirmed, observation));
                }
                return Err(e.into());
            }
        };
        let reading = observe::foreground(pane_pid, &|name| self.owns(name), None)?;
        observation["process"] = serde_json::to_value(&reading).unwrap_or(Value::Null);
        match reading {
            ProcessReading::Harness { identity } => {
                if self.target.as_ref().map(|t| t.harness) == Some(Harness::Copilot) {
                    copilot_exit(self.launch, grace);
                }
                match stop_recorded(&identity, &|name| self.owns(name), grace)? {
                    Stop::Stopped { .. } | Stop::AlreadyGone => {
                        stop_wake(self.lane, self.target.as_ref(), grace)?;
                        tmux::kill_window(&pane)?;
                        observation["stop"] = json!("pane-foreground");
                        Ok(self.outcome(Outcome::Confirmed, observation))
                    }
                    Stop::IdentityStale => {
                        observation["stop"] = json!("pane-foreground");
                        observation["result"] = json!("identity-stale");
                        Ok(self.outcome(Outcome::Unconfirmed, observation))
                    }
                    Stop::Timeout { pid } => {
                        observation["stop"] = json!("pane-foreground");
                        observation["timeout_pid"] = json!(pid);
                        Ok(self.outcome(Outcome::Unconfirmed, observation))
                    }
                }
            }
            // No harness holds the pane: the window is closed alone.
            // `harness-up` is a caller's assertion `foreground` never
            // returns, read here as no identity to stop by.
            ProcessReading::ShellsOnly
            | ProcessReading::HarnessUp
            | ProcessReading::ForegroundShell { .. }
            | ProcessReading::ForegroundOther { .. }
            | ProcessReading::Unread => {
                stop_wake(self.lane, self.target.as_ref(), grace)?;
                tmux::kill_window(&pane)?;
                observation["stop"] = json!("window-only");
                Ok(self.outcome(Outcome::Confirmed, observation))
            }
        }
    }
}

/// Decision 68: a recorded pid live under another start is a reused pid,
/// so the recorded process has exited. One reading records `unconfirmed`
/// with `identity: stale` (decision 59); a second, independent reading of
/// the same stale identity confirms the close with `readings: 2`. `prior` is
/// the intent's observation before this reading.
fn stale_reading(prior: Option<&Value>, observation: &mut Value) -> Outcome {
    let before = prior
        .filter(|o| o.get("identity").and_then(Value::as_str) == Some("stale"))
        .and_then(|o| o.get("readings"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let readings = before + 1;
    observation["readings"] = json!(readings);
    if readings >= 2 {
        Outcome::Confirmed
    } else {
        Outcome::Unconfirmed
    }
}

/// Stop the detached turn the lane's `wake` record names, by the identity it
/// carries, the way `lane-close` stops it before the lane reads done. A wake
/// that is gone or whose pid a later process holds is a turn already over
/// (`lane_stop_wake`), so a stale or absent wake is not a failure.
fn stop_wake(lane: &Lane, target: Option<&Target>, grace: Duration) -> Result<()> {
    let Some(wake) = lane.extra.get("wake").filter(|v| !v.is_null()) else {
        return Ok(());
    };
    let (Some(pid), Some(start)) = (
        wake.get("pid").and_then(pid_value),
        wake.get("start").and_then(Value::as_str),
    ) else {
        return Ok(());
    };
    let Ok(pid) = u32::try_from(pid) else {
        return Ok(());
    };
    let id = Identity {
        pid,
        start: start.to_owned(),
    };
    let owns = |name: &str| target.is_some_and(|t| t.owns(name));
    // A stale (`IdentityStale`) or already-gone wake is a turn over; only a
    // host or process read failure propagates.
    let _ = stop_recorded(&id, &owns, grace)?;
    Ok(())
}

/// Send Copilot `C-c` then `/exit` on the launch's pane and wait briefly for
/// it to exit, so it writes its session totals. Best effort: every step is
/// allowed to fail, and the signal stop that follows ends a pane that stands.
fn copilot_exit(launch: Option<&LaunchIdentity>, grace: Duration) {
    let Some(launch) = launch else {
        return;
    };
    let Ok(Observed::Present(pane)) = observe_launch(launch) else {
        return;
    };
    let _ = tmux::send_key(&pane, "C-c");
    let _ = tmux::send_line(&pane, "/exit");
    let deadline = Instant::now() + grace;
    while Instant::now() < deadline {
        if matches!(tmux::pane_present(&pane), Ok(false)) {
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// Close the window the launch identity names, confirmed on its server. A
/// server that is gone or another took its windows with it.
fn close_window(launch: Option<&LaunchIdentity>) -> Result<()> {
    let Some(launch) = launch else {
        return Ok(());
    };
    if let Observed::Present(pane) = observe_launch(launch)? {
        tmux::kill_window(&pane)?;
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Succession
// ---------------------------------------------------------------------------

/// A `failed` succession outcome, the predecessor left in control: the
/// `record-outcome` transfer-failed arm restores the pending this request
/// overwrote, since `retired` is false (failure before retirement).
fn failed_before_retirement(intent_id: &str, note: &str) -> RecordOutcome {
    RecordOutcome {
        intent_id: intent_id.to_owned(),
        outcome: Outcome::Failed,
        launch: None,
        session_id: None,
        server_start: None,
        server_socket: None,
        window: None,
        tmux_session: None,
        launch_line: None,
        observation: Some(json!({"retired": false, "note": note})),
    }
}

/// A `failed` succession outcome after retirement: no controller stands and
/// the runner is gone, so the succession cannot complete; the pending line
/// stays as the recovery route's own.
fn failed_after_retirement(intent_id: &str, note: &str) -> RecordOutcome {
    RecordOutcome {
        observation: Some(json!({"retired": true, "note": note})),
        ..failed_before_retirement(intent_id, note)
    }
}

/// An `unconfirmed` succession outcome after retirement: a recoverable
/// stopped transition. The runner's pane and identity are carried so
/// `record-outcome` keeps them under `overseer.pending.runner` for a
/// reconcile.
fn unconfirmed_after_retirement(
    intent_id: &str,
    opened: &OpenedPane,
    identity: Option<&Identity>,
    session_id: Option<String>,
    note: &str,
    observation: Value,
) -> RecordOutcome {
    let mut observation = observation;
    observation["retired"] = json!(true);
    observation["note"] = json!(note);
    RecordOutcome {
        intent_id: intent_id.to_owned(),
        outcome: Outcome::Unconfirmed,
        launch: Some(LaunchIdentity {
            pane: Some(opened.pane.clone()),
            server: Some(opened.server),
            pid: identity.map(|i| i.pid as u64),
            start: identity.map(|i| i.start.clone()),
        }),
        session_id,
        server_start: Some(opened.server_start),
        server_socket: Some(opened.socket.clone()),
        window: None,
        tmux_session: None,
        launch_line: None,
        observation: Some(observation),
    }
}

/// What a succession resolved about its successor before anything opened,
/// and what a reconcile rebuilds from the record: the harness, the home its
/// native session is read under, its working directory and the pending line.
struct Successor {
    harness: Harness,
    target: Target,
    home: PathBuf,
    cwd: PathBuf,
    launch_line: Option<String>,
}

/// The runner's own native session file as the binding read it (decision
/// 65): bound, not yet appeared, or two or more appeared since the window
/// opened and nothing tells the runner's from the others.
enum Binding {
    Bound(BoundSession),
    Absent,
    Ambiguous(Vec<String>),
}

impl Successor {
    /// The successor `pending` names, with every precondition a succession
    /// reads before retirement (decision 61): the harness word, the working
    /// directory and the account home, which must exist. The program and
    /// brief are checked by the effect that builds the command.
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
        let home = match pending.home.as_deref().or(pending.account.as_deref()) {
            Some(home) => {
                let home = PathBuf::from(home);
                check_directory("home-missing", &home)?;
                home
            }
            None => session::default_home(harness)
                .ok_or_else(|| refused("home-unresolved", &[("harness", harness.name())]))?,
        };
        Ok(Successor {
            harness,
            target: Target::new(settings, harness),
            home,
            cwd,
            launch_line: pending.launch_line.clone(),
        })
    }

    /// The runner's own native session file (decision 65): the file its
    /// fixed id names, or the one lead session for its cwd that appeared
    /// since the window opened and stood in no baseline before it. A
    /// neighbour in the same home and directory is never a candidate.
    fn bind_session(&self, opened: &OpenedPane) -> Result<Binding> {
        if let Some(id) = &opened.session_id {
            let file =
                session::fixed_file(self.harness, &self.home, &self.cwd, id).ok_or_else(|| {
                    refused("session-id-unfixable", &[("harness", self.harness.name())])
                })?;
            return Ok(Binding::Bound(BoundSession {
                session_id: id.clone(),
                file: file.display().to_string(),
            }));
        }
        appeared_session(self.harness, &self.home, &self.cwd, opened)
    }
}

/// The one lead session for `cwd` under `home` that appeared since the
/// window opened and stood in no baseline before it (decision 65): a
/// neighbour in the same home and directory is never a candidate, however
/// recently it was written.
fn appeared_session(
    harness: Harness,
    home: &Path,
    cwd: &Path,
    opened: &OpenedPane,
) -> Result<Binding> {
    let mut found = session::new_leads(harness, home, cwd, since_of(opened), &opened.baseline)?;
    Ok(match found.len() {
        0 => Binding::Absent,
        1 => {
            let lead = found.remove(0);
            Binding::Bound(BoundSession {
                session_id: lead.id,
                file: lead.file.display().to_string(),
            })
        }
        _ => Binding::Ambiguous(found.into_iter().map(|s| s.id).collect()),
    })
}

fn transfer_effect(run: &Run, intent_id: &str, r: &RequestTransfer) -> Result<RecordOutcome> {
    let overseer = read_overseer(run.path)?;
    let doc_session = fleet_tmux_session(run.path)?;

    // --- Preconditions, all before retirement. A failure here is `failed`,
    // the predecessor in control, no waiting runner opened (decision 61). ---
    // The predecessor must carry a recorded identity to retire by: an
    // unknown stop cannot authorize a second controller.
    let Some(predecessor) = overseer_identity(&overseer) else {
        return Ok(failed_before_retirement(
            intent_id,
            "predecessor-identity-missing",
        ));
    };
    let Some(pending) = overseer.pending.clone() else {
        return Ok(failed_before_retirement(intent_id, "pending-missing"));
    };
    let successor = match Successor::from_pending(run.settings, &pending) {
        Ok(successor) => successor,
        Err(e) => return Ok(failed_before_retirement(intent_id, e.key())),
    };
    let (server, session) = match fleet_server(run.settings, doc_session.as_deref()) {
        Ok(resolved) => resolved,
        Err(e) => return Ok(failed_before_retirement(intent_id, e.key())),
    };
    // The runner's session is fixed, or the sessions that already stand
    // are read, before the window opens (decision 65).
    let floor = match SessionFloor::read(successor.harness, &successor.home, &successor.cwd) {
        Ok(floor) => floor,
        Err(e) => return Ok(failed_before_retirement(intent_id, e.key())),
    };
    // The brief is held, not spelled into the launch: the waiting runner
    // opens at its prompt and is delivered the handoff after retirement.
    let command = match build_launch(
        run.settings,
        &Spec {
            harness: successor.harness,
            account: pending.account.as_deref(),
            model: pending.model.as_deref(),
            effort: pending.effort.as_deref(),
            cwd: &successor.cwd,
            brief: None,
            question_tool: run.settings.question_tool.for_overseer(),
            session_id: floor.session_id(),
        },
    )
    .and_then(|(_, command)| check_program(&command).map(|()| command))
    {
        Ok(command) => command,
        Err(e) => return Ok(failed_before_retirement(intent_id, e.key())),
    };
    if let Some(brief) = &r.brief_file
        && let Err(e) = read_brief(brief)
    {
        return Ok(failed_before_retirement(intent_id, e.key()));
    }

    // --- Prepare the waiting runner: open its window and bring it to its
    // composer. It has no controller-mail authority, since the fleet record
    // still publishes the predecessor's generation. ---
    let since = SystemTime::now();
    let pane = match open_window(&server, &session, "overseer", &command) {
        Ok(pane) => pane,
        Err(e) => return Ok(failed_before_retirement(intent_id, e.key())),
    };
    let opened = opened_pane(&pane, since, &floor, r.brief_file.as_deref())?;
    run.record_phase(
        intent_id,
        Phase::WindowOpened {
            opened: opened.clone(),
        },
    )?;
    let runner = match await_state(run, &pane, &successor.target, None, &idle)? {
        Settled::Ready { identity } => identity,
        // A runner that exited or never reached its composer is a failure
        // before retirement: the predecessor keeps control.
        Settled::Gone => {
            return Ok(failed_before_retirement(intent_id, "successor-exited"));
        }
        Settled::Pending { .. } => {
            stop_runner(&pane, Some(&successor.target), run.settings.close_grace);
            return Ok(failed_before_retirement(intent_id, "successor-not-ready"));
        }
    };

    // --- Retire the predecessor and confirm its exact terminal state. A
    // failure here is before the successor takes over: stop the waiting
    // runner exactly and leave the predecessor in control. ---
    let predecessor_target = overseer_target_of(run.settings, &overseer);
    let stop = stop_recorded(
        &predecessor,
        &|name| predecessor_target.as_ref().is_some_and(|t| t.owns(name)),
        run.settings.close_grace,
    )?;
    match stop {
        Stop::Stopped { .. } | Stop::AlreadyGone => {}
        Stop::IdentityStale | Stop::Timeout { .. } => {
            stop_runner(&pane, Some(&successor.target), run.settings.close_grace);
            return Ok(failed_before_retirement(
                intent_id,
                "predecessor-not-retired",
            ));
        }
    }
    close_overseer_window(&overseer);
    run.record_phase(
        intent_id,
        Phase::Retired {
            opened: opened.clone(),
        },
    )?;

    // --- Retired. From here a failure is a recoverable stopped transition. ---
    complete_transfer(
        run,
        intent_id,
        &successor,
        &pane,
        Some(&runner),
        &Phase::Retired { opened },
    )
}

/// Complete a succession from a recorded phase after retirement: bring the
/// runner to its composer, bind its own session file, deliver the held
/// brief, confirm the runner wrote that turn into that file, read its
/// identity and publish it. Each step is recorded before the wait that
/// follows, so a reconcile resumes here from the phase it finds (decisions
/// 61, 62 and 65). `runner` is the identity the caller already read, or
/// `None` for a reconcile that reads it afresh.
fn complete_transfer(
    run: &Run,
    intent_id: &str,
    successor: &Successor,
    pane: &Pane,
    runner: Option<&Identity>,
    phase: &Phase,
) -> Result<RecordOutcome> {
    let opened = phase.opened();
    let (turns_before, session) = match phase {
        Phase::WindowOpened { .. } | Phase::Retired { .. } => {
            let Some(brief) = &opened.brief else {
                // No handoff to deliver: the runner idle at its composer
                // under decision 60 is the successor once its identity is
                // read; a runner held at a dialog is not.
                return publish(
                    run,
                    intent_id,
                    successor,
                    pane,
                    runner,
                    opened,
                    opened.session_id.clone(),
                    &idle,
                    "successor-not-idle",
                );
            };
            // The runner must be at its composer, under the identity read
            // before retirement where there is one (decision 60).
            let identity = match await_state(run, pane, &successor.target, runner, &idle)? {
                Settled::Ready { identity } => identity,
                Settled::Gone => {
                    return Ok(failed_after_retirement(intent_id, "successor-exited"));
                }
                Settled::Pending { reading, state } => {
                    return Ok(unconfirmed_after_retirement(
                        intent_id,
                        opened,
                        runner,
                        None,
                        "successor-not-idle",
                        pending_observation(&reading, &state),
                    ));
                }
            };
            // The runner's own session file, bound once before the paste
            // (decision 65); a brief is never pasted without it.
            let session = match successor.bind_session(opened)? {
                Binding::Bound(session) => session,
                Binding::Absent => {
                    return Ok(unconfirmed_after_retirement(
                        intent_id,
                        opened,
                        Some(&identity),
                        None,
                        "session-unbound",
                        json!({}),
                    ));
                }
                Binding::Ambiguous(sessions) => {
                    return Ok(unconfirmed_after_retirement(
                        intent_id,
                        opened,
                        Some(&identity),
                        None,
                        "session-ambiguous",
                        json!({"sessions": sessions}),
                    ));
                }
            };
            let turns_before =
                session::user_turns(successor.harness, Path::new(&session.file))? as u64;
            let text = match read_brief(Path::new(brief)) {
                Ok(text) => text,
                Err(e) => {
                    return Ok(unconfirmed_after_retirement(
                        intent_id,
                        opened,
                        Some(&identity),
                        Some(session.session_id),
                        e.key(),
                        json!({}),
                    ));
                }
            };
            if let Err(e) = tmux::send_line(pane, text.trim_end()) {
                return Ok(unconfirmed_after_retirement(
                    intent_id,
                    opened,
                    Some(&identity),
                    Some(session.session_id),
                    "brief-undelivered",
                    json!({"cause": e.key()}),
                ));
            }
            run.record_phase(
                intent_id,
                Phase::Delivered {
                    opened: opened.clone(),
                    turns_before,
                    session: session.clone(),
                },
            )?;
            (turns_before, session)
        }
        Phase::Delivered {
            turns_before,
            session,
            ..
        } => (*turns_before, session.clone()),
        Phase::IdentityRead { pid, start, .. } => {
            // The last read before publication: the identity stands or the
            // runner is gone.
            let id = Identity {
                pid: u32::try_from(*pid).unwrap_or(u32::MAX),
                start: start.clone(),
            };
            return match process::still_runs(&id)? {
                Liveness::Live => publish(
                    run,
                    intent_id,
                    successor,
                    pane,
                    Some(&id),
                    opened,
                    opened.session_id.clone(),
                    &up,
                    "successor-not-up",
                ),
                Liveness::Zombie | Liveness::Gone => {
                    Ok(failed_after_retirement(intent_id, "successor-exited"))
                }
            };
        }
    };
    // The delivery is confirmed by the harness's own record: a user turn
    // beyond the count before the paste, in the one file bound above
    // (decisions 61 and 65). The runner then works that brief, so it is
    // published idle or working, never held at a dialog.
    let file = Path::new(&session.file);
    let deadline = run.clock.now() + run.settings.verify;
    loop {
        if session::user_turns(successor.harness, file)? as u64 > turns_before {
            return publish(
                run,
                intent_id,
                successor,
                pane,
                runner,
                opened,
                Some(session.session_id),
                &up,
                "successor-not-up",
            );
        }
        if !tmux::pane_present(pane)? {
            return Ok(failed_after_retirement(intent_id, "successor-exited"));
        }
        if run.clock.now() >= deadline {
            return Ok(unconfirmed_after_retirement(
                intent_id,
                opened,
                runner,
                Some(session.session_id),
                "brief-unconfirmed",
                json!({"turns_before": turns_before, "file": session.file}),
            ));
        }
        run.clock.sleep(POLL);
    }
}

/// Read the runner holding its pane in a state `accept` takes within the
/// bound, record its identity and publish it as the successor. The identity
/// is recorded before the outcome, so a reconcile after this process ends
/// publishes the same process or reads it gone. `not_accepted` is the note
/// an outcome within the bound that `accept` refuses carries.
#[allow(clippy::too_many_arguments)]
fn publish(
    run: &Run,
    intent_id: &str,
    successor: &Successor,
    pane: &Pane,
    runner: Option<&Identity>,
    opened: &OpenedPane,
    session_id: Option<String>,
    accept: &dyn Fn(&State) -> bool,
    not_accepted: &str,
) -> Result<RecordOutcome> {
    let identity = match await_state(run, pane, &successor.target, runner, accept)? {
        Settled::Ready { identity } => identity,
        Settled::Gone => return Ok(failed_after_retirement(intent_id, "successor-exited")),
        Settled::Pending { reading, state } => {
            return Ok(unconfirmed_after_retirement(
                intent_id,
                opened,
                runner,
                session_id,
                not_accepted,
                pending_observation(&reading, &state),
            ));
        }
    };
    run.record_phase(
        intent_id,
        Phase::IdentityRead {
            opened: opened.clone(),
            pid: identity.pid as u64,
            start: identity.start.clone(),
        },
    )?;
    Ok(RecordOutcome {
        intent_id: intent_id.to_owned(),
        outcome: Outcome::Confirmed,
        launch: Some(LaunchIdentity {
            pane: Some(opened.pane.clone()),
            server: Some(opened.server),
            pid: Some(identity.pid as u64),
            start: Some(identity.start.clone()),
        }),
        session_id,
        server_start: Some(opened.server_start),
        server_socket: Some(opened.socket.clone()),
        window: None,
        tmux_session: None,
        launch_line: successor.launch_line.clone(),
        observation: Some(json!({"retired": true, "note": "successor-confirmed"})),
    })
}

/// Stop a waiting runner exactly: its process tree by its pane pid, then its
/// window, used when a failure before the successor takes over must leave the
/// predecessor in control, or when nothing could publish it. With no
/// `target` only the pane's own process, the harness the pane's shell
/// exec'd, is signalled.
fn stop_runner(pane: &Pane, target: Option<&Target>, grace: Duration) {
    if let Ok((_, pid)) = tmux::pane_process(pane)
        && let Ok(Some(id)) = process::identity(pid)
    {
        let _ = stop_recorded(&id, &|name| target.is_some_and(|t| t.owns(name)), grace);
    }
    let _ = tmux::kill_window(pane);
}

// ---------------------------------------------------------------------------
// Reconciliation
// ---------------------------------------------------------------------------

/// Re-observe every open intent on `path` by its recorded phase and
/// identity and complete or mark each. Nothing starts here that the intent
/// did not already record as its next step.
pub fn reconcile(
    path: &Path,
    settings: &Settings,
    env: &Env,
    locking: Locking,
    clock: &dyn Clock,
) -> Result<Vec<Applied>> {
    let run = Run {
        path,
        settings,
        env,
        locking,
        clock,
    };
    let open = open_intents(path)?;
    let mut applied = Vec::new();
    for id in open {
        applied.push(reconcile_intent(&run, &id)?);
    }
    Ok(applied)
}

fn reconcile_intent(run: &Run, intent_id: &str) -> Result<Applied> {
    let intent = read_intent(run.path, intent_id)?;
    let outcome = match intent.op {
        state::EffectOp::LaunchLane => reconcile_launch(run, &intent)?,
        state::EffectOp::CloseOwnedResources => reconcile_close(run.path, &intent)?,
        state::EffectOp::RequestTransfer => reconcile_transfer(run, &intent)?,
    };
    run.apply_outcome(outcome)
}

/// The launch cells of the reconcile matrix (decisions 64 and 66): no phase
/// means nothing opened, `failed`; a recorded pane gone, or its server
/// replaced or gone, is `failed`; one an unanswering server still holds is
/// `unconfirmed`; one the harness holds at its composer or working is
/// `confirmed` with the identity read; any other reading is `unconfirmed`
/// with that reading and the pane marked present, which a close may
/// supersede (decision 67).
fn reconcile_launch(run: &Run, intent: &Intent) -> Result<RecordOutcome> {
    let (lane, item) = lane_for_intent(run.path, &intent.id)?;
    let Some(phase) = &intent.phase else {
        return Ok(RecordOutcome {
            observation: Some(json!({"reconcile": "launch", "phase": "none"})),
            ..failed_before_window(&intent.id, "nothing-opened")
        });
    };
    let opened = phase.opened();
    let pane = match observe_pane(opened)? {
        Observed::Unobservable { cause } => {
            return Ok(launch_pane_outcome(
                &intent.id,
                opened,
                Outcome::Unconfirmed,
                json!({"reconcile": "launch", "observed": "unobservable", "cause": cause}),
            ));
        }
        Observed::Gone { cause } => {
            return Ok(launch_pane_outcome(
                &intent.id,
                opened,
                Outcome::Failed,
                json!({"reconcile": "launch", "observed": "gone", "cause": cause}),
            ));
        }
        Observed::Present(pane) => pane,
    };
    let Some(harness) = pane_harness(&lane, Some(intent)) else {
        return Ok(launch_pane_outcome(
            &intent.id,
            opened,
            Outcome::Unconfirmed,
            json!({"reconcile": "launch", "observed": "present", "cause": "harness-unknown"}),
        ));
    };
    let Some((reading, state)) = read_pane(&pane, &Target::new(run.settings, harness), None)?
    else {
        return Ok(launch_pane_outcome(
            &intent.id,
            opened,
            Outcome::Failed,
            json!({"reconcile": "launch", "observed": "gone", "cause": "pane-gone"}),
        ));
    };
    if let ProcessReading::Harness { identity } = &reading
        && up(&state)
    {
        let home = lane
            .account
            .as_deref()
            .map(PathBuf::from)
            .or_else(|| session::default_home(harness));
        let cwd = lane
            .mail_root
            .as_deref()
            .map(PathBuf::from)
            .unwrap_or_default();
        let mut outcome = launch_outcome(
            &intent.id,
            harness,
            home.as_deref(),
            &pane.session,
            &item,
            opened,
            &cwd,
            Settled::Ready {
                identity: identity.clone(),
            },
        )?;
        outcome.observation.get_or_insert_with(|| json!({}))["reconcile"] = json!("launch");
        return Ok(outcome);
    }
    let mut observation = pending_observation(&reading, &state);
    observation["reconcile"] = json!("launch");
    observation["observed"] = json!("present");
    Ok(launch_pane_outcome(
        &intent.id,
        opened,
        Outcome::Unconfirmed,
        observation,
    ))
}

/// The close cells of the reconcile matrix (decisions 64, 67 and 68). With
/// a recorded identity: a pid holding no live process is confirmed gone,
/// `confirmed`; a live pid under the recorded start is a stop still owed,
/// `unconfirmed` with `stop: pending`, which a repeated close runs; a live
/// pid under another start is an identity change, `unconfirmed` with
/// `identity: stale` on the first reading and `confirmed` on the second
/// independent one, or the repeated close's pane route while the recorded
/// pane stands. With none: the pane observed gone is `confirmed`,
/// present is `unconfirmed` with `pane: present`, which a repeated close
/// stops through the pane's foreground, and unobservable is `unconfirmed`.
/// A reconcile itself stops nothing.
fn reconcile_close(path: &Path, intent: &Intent) -> Result<RecordOutcome> {
    let (lane, item) = lane_for_intent(path, &intent.id)?;
    let base = |outcome: Outcome, observation: Value| {
        let mut observation = observation;
        observation["reconcile"] = json!("close");
        observation["item"] = json!(item);
        RecordOutcome {
            intent_id: intent.id.clone(),
            outcome,
            launch: None,
            session_id: None,
            server_start: None,
            server_socket: None,
            window: None,
            tmux_session: None,
            launch_line: None,
            observation: Some(observation),
        }
    };
    // The recorded pane as it stands, the handle a close with no usable
    // identity has (decision 67).
    let pane = || -> Result<(&'static str, Option<&'static str>)> {
        Ok(match &lane.launch {
            Some(launch) => match observe_launch(launch)? {
                Observed::Gone { cause } => ("gone", Some(cause)),
                Observed::Present(_) => ("present", None),
                Observed::Unobservable { cause } => ("unobservable", Some(cause)),
            },
            None => ("unobservable", Some("pane-unrecorded")),
        })
    };
    match lane.launch.as_ref().and_then(launch_identity) {
        None => {
            let (pane, cause) = pane()?;
            let outcome = if pane == "gone" {
                Outcome::Confirmed
            } else {
                Outcome::Unconfirmed
            };
            Ok(base(
                outcome,
                json!({"identity": "none", "pane": pane, "cause": cause}),
            ))
        }
        Some(id) => Ok(match process::liveness(id.pid)? {
            Liveness::Gone | Liveness::Zombie => {
                base(Outcome::Confirmed, json!({"identity": "gone"}))
            }
            Liveness::Live => match process::still_runs(&id)? {
                Liveness::Live => base(Outcome::Unconfirmed, json!({"stop": "pending"})),
                Liveness::Gone | Liveness::Zombie => {
                    let (pane, cause) = pane()?;
                    let mut observation = json!({
                        "identity": "stale",
                        "observed_start": process::start(id.pid)?,
                        "pane": pane,
                        "cause": cause,
                    });
                    // A present pane is the repeated close's route; a pane
                    // gone or unobservable is one reading towards decision
                    // 68, never a confirm alone (decision 59).
                    let outcome = match pane {
                        "present" => Outcome::Unconfirmed,
                        _ => stale_reading(intent.observation.as_ref(), &mut observation),
                    };
                    base(outcome, observation)
                }
            },
        }),
    }
}

/// The transfer cells of the reconcile matrix (decisions 64 and 66). The
/// record moved past the intent's generation: `failed`, intent-stale.
/// Otherwise `retired` is read from the predecessor's identity, never
/// asserted. No phase, or a runner opened with the predecessor still live:
/// `failed` before retirement, the runner stopped, the original pending
/// restored. From `retired` on, the succession completes as the effect
/// would: the runner's pane gone, or its server replaced or gone, is
/// `failed`; an unanswering server still running is `unconfirmed`; a
/// successor the pending no longer resolves is `unconfirmed` with the
/// runner kept, and a pending gone altogether stops the runner, since
/// nothing could publish it; the brief, turn and identity steps give
/// `confirmed` or `unconfirmed` with the runner kept.
fn reconcile_transfer(run: &Run, intent: &Intent) -> Result<RecordOutcome> {
    let overseer = read_overseer(run.path)?;
    let generation = overseer.generation.unwrap_or(0);
    let base = |outcome: Outcome, observation: Value| {
        let mut observation = observation;
        observation["reconcile"] = json!("transfer");
        observation["generation"] = json!(generation);
        RecordOutcome {
            intent_id: intent.id.clone(),
            outcome,
            launch: None,
            session_id: None,
            server_start: None,
            server_socket: None,
            window: None,
            tmux_session: None,
            launch_line: None,
            observation: Some(observation),
        }
    };
    // The record moved past the generation the intent named: decision 44, an
    // intent-stale reconciliation. `record-outcome` marks it and leaves the
    // record as found.
    if intent.target != overseer_target(generation) {
        return Ok(base(Outcome::Failed, json!({})));
    }
    let retired = match overseer_identity(&overseer) {
        Some(predecessor) => process::still_runs(&predecessor)? != Liveness::Live,
        None => false,
    };
    let Some(phase) = &intent.phase else {
        return Ok(base(
            Outcome::Failed,
            json!({"retired": retired, "note": "nothing-opened"}),
        ));
    };
    let opened = phase.opened();
    let observed = observe_pane(opened)?;
    let runner = recorded_runner(phase);
    let grace = run.settings.close_grace;
    // The successor the pending names, with its preconditions; what a
    // failure here does with the runner depends on what stands below.
    let successor = match overseer.pending.as_ref() {
        None => Err("pending-missing"),
        Some(pending) => Successor::from_pending(run.settings, pending).map_err(|e| e.key()),
    };
    if let Phase::WindowOpened { .. } = phase
        && !retired
    {
        // The runner was opened and the predecessor still runs: the abandon
        // every refusal before the commit point takes, the runner stopped
        // exactly and the predecessor in control.
        if let Observed::Present(pane) = &observed {
            stop_runner(pane, successor.as_ref().ok().map(|s| &s.target), grace);
        }
        let note = match &successor {
            Ok(_) => "abandoned-before-retirement",
            Err(note) => note,
        };
        return Ok(failed_before_retirement(&intent.id, note));
    }
    let successor = match successor {
        Ok(successor) => successor,
        // No pending: nothing can be published, so the live runner is
        // stopped exactly rather than left standing with no record.
        Err("pending-missing") => {
            if let Observed::Present(pane) = &observed {
                stop_runner(pane, None, grace);
            }
            return Ok(base(
                Outcome::Failed,
                json!({"retired": retired, "note": "pending-missing", "runner": "stopped"}),
            ));
        }
        // The pending stands but no longer resolves (its directory or home
        // gone, its harness word unknown): the runner is kept under
        // `pending.runner` for a reconcile once it does.
        Err(note) => {
            return Ok(unconfirmed_after_retirement(
                &intent.id,
                opened,
                runner.as_ref(),
                opened.session_id.clone(),
                note,
                json!({"reconcile": "transfer"}),
            ));
        }
    };
    let pane = match observed {
        Observed::Unobservable { cause } => {
            return Ok(unconfirmed_after_retirement(
                &intent.id,
                opened,
                runner.as_ref(),
                opened.session_id.clone(),
                "pane-unobservable",
                json!({"reconcile": "transfer", "cause": cause}),
            ));
        }
        Observed::Gone { cause } => {
            return Ok(RecordOutcome {
                observation: Some(
                    json!({"retired": true, "note": "successor-exited", "cause": cause}),
                ),
                ..failed_after_retirement(&intent.id, "successor-exited")
            });
        }
        Observed::Present(pane) => pane,
    };
    complete_transfer(run, &intent.id, &successor, &pane, runner.as_ref(), phase)
}

/// The runner identity a phase recorded, once one was read.
fn recorded_runner(phase: &Phase) -> Option<Identity> {
    match phase {
        Phase::IdentityRead { pid, start, .. } => Some(Identity {
            pid: u32::try_from(*pid).ok()?,
            start: start.clone(),
        }),
        Phase::WindowOpened { .. } | Phase::Retired { .. } | Phase::Delivered { .. } => None,
    }
}

// ---------------------------------------------------------------------------
// Record reads
// ---------------------------------------------------------------------------

fn load(path: &Path) -> Result<state::Snapshot> {
    state::load(path)?.ok_or_else(|| Error::RecordMissing {
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

fn launch_identity(launch: &LaunchIdentity) -> Option<Identity> {
    Some(Identity {
        pid: u32::try_from(launch.pid?).ok()?,
        start: launch.start.clone()?,
    })
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

/// Close the predecessor's window on the server the record names, by its
/// recorded socket where it carries one. Best effort: the window is the
/// retired session's, and the stop already confirmed it ended.
fn close_overseer_window(overseer: &Overseer) {
    let (Some(server_pid), Some(pane_id)) = (
        overseer.extra.get("server").and_then(pid_value),
        overseer.extra.get("pane").and_then(Value::as_str),
    ) else {
        return;
    };
    let socket = overseer
        .extra
        .get("server_socket")
        .and_then(Value::as_str)
        .map(PathBuf::from)
        .unwrap_or_else(tmux::ambient_socket);
    if let Ok(server) = tmux::server(&socket)
        && server.pid as u64 == server_pid
        && let Ok(Some(pane)) = tmux::pane_by_id(&server, pane_id)
    {
        let _ = tmux::kill_window(&pane);
    }
}

/// A pid a record carries as the number the runtime writes or the string a
/// legacy jq `--arg` wrote (the overseer's `server` and `harness_pid`).
fn pid_value(value: &Value) -> Option<u64> {
    match value {
        Value::Number(n) => n.as_u64(),
        Value::String(s) => s.parse().ok(),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;

    /// Decision 71 on the lane route: a confirmed launch of a harness whose
    /// launch fixes no id binds the one lead session for the cwd that
    /// appeared since the window opened and stood in no baseline. A
    /// neighbour the baseline knew is never bound, however recently it was
    /// written; none or two new leads bind nothing and say so.
    #[test]
    fn a_confirmed_launch_binds_only_the_lead_that_appeared_since_the_window_opened() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let day = home.join("sessions").join("2026").join("10").join("26");
        fs::create_dir_all(&day).unwrap();
        let cwd = Path::new("/w");
        let meta = |id: &str| {
            format!(
                r#"{{"type":"session_meta","payload":{{"id":"{id}","cwd":"/w","parent_thread_id":null,"source":"cli"}}}}"#
            )
        };
        let neighbour = day.join("rollout-a-N.jsonl");
        fs::write(&neighbour, meta("N")).unwrap();
        let baseline = session::lead_ids(Harness::Codex, &home, cwd).unwrap();
        assert_eq!(baseline, vec!["N".to_owned()]);
        std::thread::sleep(Duration::from_millis(20));
        let since_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;
        // File stamps come from the kernel's coarse clock, which can trail
        // the precise one by a tick, so the writes follow a pause.
        std::thread::sleep(Duration::from_millis(20));
        let opened = OpenedPane {
            pane: "%1".to_owned(),
            server: 1,
            server_start: 1,
            server_process_start: None,
            socket: "/s".to_owned(),
            since_ms,
            brief: None,
            session_id: None,
            baseline,
        };
        let confirm = || {
            launch_outcome(
                "launch-lane:KEN-M:1-1",
                Harness::Codex,
                Some(&home),
                "fleet",
                "KEN-M",
                &opened,
                cwd,
                Settled::Ready {
                    identity: Identity {
                        pid: 1,
                        start: "ticks:1".to_owned(),
                    },
                },
            )
            .unwrap()
        };
        // The neighbour takes a row after the window opened: it is the newest
        // file for the cwd, and it is not the lane's.
        fs::write(
            &neighbour,
            format!("{}\n{}\n", meta("N"), r#"{"type":"x"}"#),
        )
        .unwrap();
        let unbound = confirm();
        assert_eq!(unbound.outcome, Outcome::Confirmed);
        assert_eq!(unbound.session_id, None);
        assert_eq!(unbound.observation.unwrap()["note"], "session-unbound");
        // The lane's own file appears: the one lead absent from the baseline.
        fs::write(day.join("rollout-b-R.jsonl"), meta("R")).unwrap();
        let bound = confirm();
        assert_eq!(bound.session_id.as_deref(), Some("R"));
        assert_eq!(bound.observation.unwrap().get("note"), None);
        // A second new lead: nothing tells the lane's from the other.
        fs::write(day.join("rollout-c-S.jsonl"), meta("S")).unwrap();
        let ambiguous = confirm();
        assert_eq!(ambiguous.session_id, None);
        let observation = ambiguous.observation.unwrap();
        assert_eq!(observation["note"], "session-ambiguous");
        assert_eq!(observation["sessions"].as_array().unwrap().len(), 2);
    }
}
