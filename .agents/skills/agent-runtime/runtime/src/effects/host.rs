//! The handle's host methods: every read, signal and close of a process, a
//! pane, a window or a session store, and the controller's terminal proof.
//! A read that settles a recorded handle discharges it by that read; an
//! acting method takes a [`Standing`] token, writes `signalled` before it
//! acts and discharges the token's key by its own answer.

use crate::accounts::wall::canon;
use crate::controller::{Overseer, views};
use crate::record::Locking;
use crate::settings::EngineSettings;
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::harness::Harness;
use crate::host::tmux;
use crate::launch::Permission;
use crate::observe::{self, ProcessReading, State};
use crate::process::{self, Identity, Stop};
use crate::reading::Reading;
use crate::session;
use serde_json::{Value, json};

use super::obligations::{Discharge, PaneEnd, PaneRef, ProcessEnd, Standing};
use super::prepare::Kept;
use super::{
    Close, Operation, POLL, Pane, Run, Server, Target, fleet_view, overseer_target_of, pid_value,
    predecessor_identity,
};
use crate::controller::{AdoptController, AdoptionRead, ControllerAdopted};
use crate::error::{Error, Result};
use crate::intent::Intent;
use crate::intent::{BoundSession, Obligation, OpenedPane, Phase, Role};

/// The job record of the tmux server a fleet start made, beside the fleet
/// state: the server's lifetime owner.
pub const SERVER_RECORD: &str = "tmux-server.runner";

/// The stderr of the tmux server a fleet start made, beside its record: the
/// one place a server that exits at once says why, which the unit's journal
/// or a detached group would otherwise keep from the start's refusal.
pub const SERVER_ERR: &str = "tmux-server.err";

/// What a recorded pane reads as on its own server: present as `P` (the
/// pane, or the standing token for it), gone with the cause (the pane by
/// exact id, or its server gone or replaced with every pane it held), or
/// unobservable with the cause (an unanswering socket whose server process
/// still runs, or a failed read).
pub enum Observed<P> {
    Unobservable { cause: &'static str },
    Gone { cause: &'static str },
    Present(P),
}

/// What closing a recorded window established; the close discharged the
/// recorded pane where it answered.
pub enum WindowClose {
    /// The set holds no addressable pane.
    Unrecorded,
    /// The pane read gone by exact id, or its server gone or replaced.
    Gone {
        cause: &'static str,
    },
    /// The host did not answer for the pane: the window may still stand.
    Unobservable {
        cause: &'static str,
    },
    Window(Close),
}

impl WindowClose {
    pub fn word(&self) -> String {
        match self {
            WindowClose::Unrecorded => "unrecorded".to_owned(),
            WindowClose::Gone { cause } => (*cause).to_owned(),
            WindowClose::Unobservable { cause } => format!("unreadable:{cause}"),
            WindowClose::Window(Close::Closed) => "closed".to_owned(),
            WindowClose::Window(Close::AlreadyGone) => "gone".to_owned(),
            WindowClose::Window(Close::Unreadable { cause }) => format!("unreadable:{cause}"),
        }
    }
}

/// A stop's answer, carrying the identity [`Operation::stop_process`] acted
/// on: the one evidence [`Operation::release_retirement`] takes, so a caller
/// supplies no stop answer of its own.
#[must_use]
#[derive(Debug)]
pub struct Stopped {
    identity: Identity,
    answer: Stop,
}

impl Stopped {
    pub fn answer(&self) -> &Stop {
        &self.answer
    }
}

/// Evidence this module's own reader produced, handed on as a token: an
/// identity this handle read and wrote into the set before returning it,
/// what [`Operation::record_identity`] and [`Operation::publish`] take; or
/// the adoption's pane read, what the adoption's one store write takes.
/// Constructible here alone, so a transition that takes one takes no
/// caller-supplied evidence.
pub struct Recorded<T> {
    value: T,
}

impl Recorded<Identity> {
    pub fn identity(&self) -> &Identity {
        &self.value
    }
}

impl Recorded<AdoptionRead> {
    /// What the pane read found, for the adoption's one transition.
    pub fn evidence(&self) -> &AdoptionRead {
        &self.value
    }

    /// A token a store test plants: the production build has no constructor
    /// outside this module.
    #[cfg(test)]
    pub fn planted(value: AdoptionRead) -> Recorded<AdoptionRead> {
        Recorded { value }
    }
}

/// Who holds a pane's terminal, through the one judge; `harness` is the
/// recorded token where the reading is a harness identity.
pub struct Foreground {
    pub reading: ProcessReading,
    pub harness: Option<Recorded<Identity>>,
}

/// What a read of a recorded process identity found: live under its
/// recorded start; gone, nothing holding its pid; another process under the
/// pid, one reading towards the stale count; or unreadable. The live reading
/// mints no acting token: a stop acquires its own from the standing set, and
/// a publication reads its identity through the acquiring poll.
pub enum ProcessRead {
    Live,
    Gone,
    Stale { other: Identity },
    Unreadable { cause: &'static str },
}

/// What proves a predecessor with no recorded identity terminal, or does
/// not.
pub enum Proof {
    /// Proven terminal `by` the generation-bound exit record, the pane gone
    /// on the proven recorded server, or the pane there holding no harness.
    Proven { by: &'static str },
    /// The recorded pane stands on the proven server, holding `pid`.
    Standing { pid: u32 },
    /// The record names no session at all.
    Empty,
    /// The record names a session that cannot be resolved: absence here
    /// proves nothing, and nothing replaces what it names.
    Unproven { cause: &'static str },
    /// A read the proof depends on failed.
    Unreadable { cause: &'static str },
}

/// What a launch fixed about the runner's native session before its window
/// opened: the id it passed on the command line, or the lead sessions that
/// already stood for the cwd.
pub enum SessionFloor {
    Fixed(String),
    Baseline(Vec<String>),
}

impl SessionFloor {
    pub fn session_id(&self) -> Option<&str> {
        match self {
            SessionFloor::Fixed(id) => Some(id),
            SessionFloor::Baseline(_) => None,
        }
    }
}

/// The runner's own native session file as the binding read it: bound, not
/// yet appeared, two or more appeared and nothing tells the runner's from
/// the others, or a store that could not be read whole.
pub enum Binding {
    Bound(BoundSession),
    Absent,
    Ambiguous(Vec<String>),
    Unreadable { cause: &'static str },
}

/// Whether the process that persisted the intent still runs under its
/// recorded start. An intent that records no owner reads `Gone`; so
/// does an owner pid outside the kernel's range.
pub fn owner(intent: &Intent) -> Reading<Identity> {
    let Some(owner) = &intent.owner else {
        return Reading::Gone;
    };
    let Ok(pid) = u32::try_from(owner.pid) else {
        return Reading::Gone;
    };
    process::still_runs(&Identity {
        pid,
        start: owner.start.clone(),
    })
}

/// The reading of a socket that does not answer, from the recorded server
/// process through the one identity reader: gone with its process, else
/// unobservable, as a client of another tmux build where `refused` says so.
/// A record carrying the pid alone is read by that pid.
pub fn unanswering(
    server: u64,
    process_start: Option<&str>,
    refused: Option<&Error>,
) -> Observed<Pane> {
    let Ok(pid) = u32::try_from(server) else {
        return Observed::Unobservable {
            cause: "server-pid-invalid",
        };
    };
    let reading = match process_start {
        Some(start) => process::still_runs(&Identity {
            pid,
            start: start.to_owned(),
        }),
        None => process::identity(pid),
    };
    match reading {
        Reading::Live(_) if refused.is_some_and(|e| e.key() == tmux::VERSION_MISMATCH) => {
            Observed::Unobservable {
                cause: tmux::VERSION_MISMATCH,
            }
        }
        Reading::Live(_) => Observed::Unobservable {
            cause: "server-unreachable",
        },
        Reading::Gone => Observed::Gone {
            cause: "server-gone",
        },
        Reading::Unreadable { cause } => Observed::Unobservable { cause },
    }
}

/// The pane `id` on a server that answered, by its exact id. A pane the
/// server keeps after its process exited still stands, with a window to
/// close; a reader of its process reads it `pane-dead`.
pub(super) fn observe_fields(server: &Server, id: &str) -> Observed<Pane> {
    match tmux::pane_state(server, id) {
        Reading::Live(
            tmux::PaneState::Running(tmux::PaneFields { pane, .. }) | tmux::PaneState::Dead(pane),
        ) => Observed::Present(pane),
        Reading::Gone => Observed::Gone { cause: "pane-gone" },
        Reading::Unreadable { cause } => Observed::Unobservable { cause },
    }
}

fn observe_pane(opened: &OpenedPane) -> Observed<Pane> {
    let server = match tmux::recorded_server(Path::new(&opened.socket), opened.server) {
        Ok(server) => server,
        Err(e) => {
            return unanswering(
                opened.server,
                opened.server_process_start.as_deref(),
                Some(&e),
            );
        }
    };
    if server.pid as u64 != opened.server || server.start != opened.server_start {
        return Observed::Gone {
            cause: "server-replaced",
        };
    }
    observe_fields(&server, &opened.pane)
}

/// The pane `key` names, on the server among `sockets` its key names.
fn observe_key(sockets: &[PathBuf], key: &PaneRef) -> Observed<Pane> {
    match server_at(sockets, key.server, key.server_start) {
        Observed::Present(server) => observe_fields(&server, &key.pane),
        Observed::Gone { cause } => Observed::Gone { cause },
        Observed::Unobservable { cause } => Observed::Unobservable { cause },
    }
}

/// The server a recorded pane is on, found among `sockets` by the pid the
/// record names and, where it records one, its start. A record names its
/// server by pid and start alone, never by socket, so every candidate is
/// asked: one answering with that pid under its recorded start is present;
/// one answering with that pid under another start is a reused pid, the
/// recorded server gone with every pane it held (`server-unmatched`); none
/// answering with that pid is read by the pid alone through the one
/// identity reader: dead, the server and its panes are gone; live or
/// unreadable, it is unobservable.
pub fn server_at(
    sockets: &[PathBuf],
    server_pid: u64,
    server_start: Option<u64>,
) -> Observed<Server> {
    let mut refused = None;
    let answering =
        sockets
            .iter()
            .find_map(|socket| match tmux::recorded_server(socket, server_pid) {
                Ok(s) if s.pid as u64 == server_pid => Some(s),
                Ok(_) => None,
                Err(e) => {
                    if e.key() == tmux::VERSION_MISMATCH {
                        refused = Some(e);
                    }
                    None
                }
            });
    match answering {
        Some(server) if server_start.is_none_or(|st| st == server.start) => {
            Observed::Present(server)
        }
        Some(_) => Observed::Gone {
            cause: "server-unmatched",
        },
        None => match unanswering(server_pid, None, refused.as_ref()) {
            Observed::Gone { cause } => Observed::Gone { cause },
            Observed::Unobservable { cause } => Observed::Unobservable { cause },
            Observed::Present(_) => unreachable!("unanswering never returns a pane"),
        },
    }
}

/// The candidate sockets of a pane the fleet records: the one the
/// controller record names, then `ambient`, each once.
pub fn fleet_sockets(recorded: Option<PathBuf>, ambient: Option<PathBuf>) -> Vec<PathBuf> {
    let mut sockets: Vec<PathBuf> = recorded.into_iter().collect();
    if let Some(ambient) = ambient
        && !sockets.contains(&ambient)
    {
        sockets.push(ambient);
    }
    sockets
}

/// Whether the record names a session: any of the keys a launch, a
/// registration or a watch start writes for one. `{}` and a record holding
/// only a generation or an `off` mark name none.
fn names_session(overseer: &Overseer) -> bool {
    [
        "server",
        "pane",
        "harness_pid",
        "launch_line",
        "harness",
        "window",
    ]
    .iter()
    .any(|key| overseer.extra.get(*key).is_some_and(|v| !v.is_null()))
}

fn overseer_pane(overseer: &Overseer) -> Option<(u64, String)> {
    Some((
        overseer.extra.get("server").and_then(pid_value)?,
        overseer
            .extra
            .get("pane")
            .and_then(Value::as_str)?
            .to_owned(),
    ))
}

/// The socket the controller record names, where it names one.
pub fn overseer_socket(overseer: &Overseer) -> Option<PathBuf> {
    overseer
        .extra
        .get("server_socket")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
}

/// The socket the controller record names, else the one the run's opener
/// names, else `tmux-server-unnamed` before any server is asked.
fn controller_socket(overseer: &Overseer, named: Option<&Path>) -> crate::Result<PathBuf> {
    overseer_socket(overseer)
        .or_else(|| named.map(Path::to_path_buf))
        .ok_or_else(|| Error::refused("tmux-server-unnamed", &[]))
}

/// The proof for a predecessor whose record carries no identity:
/// `exit.run.generation` equal to the record's generation, else the recorded
/// pane read gone by exact id on the server the record names at its recorded
/// pid and start, kept there dead after its process exited, or read there
/// holding no harness by the names of `target`,
/// the recorded harness. Another server on that socket, no server, or a
/// record naming no server, start or pane proves nothing; with no recorded
/// harness a listed pane stands, since nothing names what would run in it.
/// `named` is the server the opener names, asked where the record names
/// none.
pub fn proof_of(overseer: &Overseer, target: Option<&Target>, named: Option<&Path>) -> Proof {
    let generation = overseer.generation.unwrap_or(0);
    let exited = overseer
        .extra
        .get("exit")
        .and_then(|e| e.get("run"))
        .and_then(|r| r.get("generation"))
        .and_then(pid_value);
    if exited == Some(generation) {
        return Proof::Proven { by: "exit-record" };
    }
    if !names_session(overseer) {
        return Proof::Empty;
    }
    let Some((server, pane)) = overseer_pane(overseer) else {
        return Proof::Unproven {
            cause: "record-unbound",
        };
    };
    let Some(start) = overseer.extra.get("server_start").and_then(pid_value) else {
        return Proof::Unproven {
            cause: "server-start-unrecorded",
        };
    };
    match controller_socket(overseer, named)
        .and_then(|socket| tmux::recorded_server(&socket, server))
    {
        Ok(answering) if answering.pid as u64 == server && answering.start == start => {
            match tmux::pane_state(&answering, &pane) {
                Reading::Live(tmux::PaneState::Running(fields)) => match target {
                    Some(target) => standing_or_gone(fields.pid, target),
                    None => Proof::Standing { pid: fields.pid },
                },
                // The server keeps the pane after its process exited: no
                // session runs in it.
                Reading::Live(tmux::PaneState::Dead(_)) => Proof::Proven { by: "pane-dead" },
                Reading::Gone => Proof::Proven { by: "pane-gone" },
                Reading::Unreadable { cause } => Proof::Unreadable { cause },
            }
        }
        Ok(_) => Proof::Unproven {
            cause: "server-replaced",
        },
        Err(e) => match unanswering(server, None, Some(&e)) {
            Observed::Gone { cause } => Proof::Unproven { cause },
            Observed::Unobservable { cause } => Proof::Unreadable { cause },
            Observed::Present(_) => unreachable!("unanswering never returns a pane"),
        },
    }
}

/// A listed pane by who holds its terminal: nothing but shells with no
/// harness process under it is the harness gone from it. A process that is
/// no shell may be the harness under a name the target does not know, so it
/// stands, as the harness does.
fn standing_or_gone(pane_pid: u32, target: &Target) -> Proof {
    match observe::foreground(pane_pid, &|name| target.owns(name), None) {
        ProcessReading::ShellsOnly => Proof::Proven { by: "harness-gone" },
        ProcessReading::Unread { cause } => Proof::Unreadable { cause },
        ProcessReading::Harness { .. }
        | ProcessReading::HarnessUp
        | ProcessReading::ForegroundShell { .. }
        | ProcessReading::ForegroundOther { .. } => Proof::Standing { pid: pane_pid },
    }
}

/// The directory the session `id` under `home` for `cwd` was recorded in,
/// read three-valued through the session owner's fixed-id lookup: absent,
/// unreadable, or the directory its own file names.
pub fn session_owner(
    harness: Harness,
    home: &Path,
    cwd: &Path,
    id: &str,
) -> Reading<Option<PathBuf>> {
    session::resume_owner(harness, home, cwd, id)
}

/// The harness's default home, where its sessions are read with no account
/// named.
pub fn default_home(harness: Harness) -> Option<PathBuf> {
    session::default_home(harness)
}

/// The home variable of `harness` a pane opened in `session` on `server`
/// inherits from the server, where it holds one: a window's process takes
/// the server's environment, never that of the process that asked for the
/// window.
pub fn server_home(server: &Server, session: &str, harness: Harness) -> Result<Option<PathBuf>> {
    Ok(tmux::inherited(server, session, harness.home_var())?
        .filter(|home| !home.is_empty())
        .map(PathBuf::from))
}

/// The file the harness records the session `id` for `cwd` in under `home`,
/// for a harness whose launch fixes the id.
pub fn fixed_file(harness: Harness, home: &Path, cwd: &Path, id: &str) -> Option<PathBuf> {
    session::fixed_file(harness, home, cwd, id)
}

/// `check` read on the one clock until it answers or `bound` passes,
/// `poll` between reads: `None` at the bound.
pub fn poll_until<T>(
    clock: &dyn crate::clock::Clock,
    bound: Duration,
    poll: Duration,
    mut check: impl FnMut() -> Option<T>,
) -> Option<T> {
    let deadline = clock.now() + bound;
    loop {
        if let Some(answer) = check() {
            return Some(answer);
        }
        if clock.now() >= deadline {
            return None;
        }
        clock.sleep(poll);
    }
}

/// The last line `path` holds with any text on it; none where it holds
/// none or cannot be read.
fn last_line(path: &Path) -> Option<String> {
    let text = std::fs::read(path).ok()?;
    String::from_utf8_lossy(&text)
        .lines()
        .rev()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .map(str::to_owned)
}

/// The session a window opens in, first of the request's, the setting's
/// and the opener's fallback, else `tmux-session-unresolved`.
fn session_of(
    named: Option<&str>,
    setting: Option<&str>,
    fallback: Option<&str>,
) -> Result<String> {
    named
        .or(setting)
        .or(fallback)
        .map(str::to_owned)
        .ok_or_else(|| Error::refused("tmux-session-unresolved", &[]))
}

/// Whether `pane_id` on `server` is one tmux may name: `%` then digits.
fn is_pane_id(id: &str) -> bool {
    id.strip_prefix('%')
        .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
}

impl Run<'_> {
    /// The tmux server a window opens on and the session it opens in: the
    /// socket the opener names, and the session [`Operation::fleet_session`]
    /// resolves. Both are read from the run alone, so a caller that must
    /// refuse before an earlier act, as a relaunch must before its close,
    /// asks the very resolve its launch asks. The controller record's own
    /// `server_socket` is the fleet's: where no server listens there, as
    /// after a restart, one is started with the session
    /// ([`Run::started_server`]), and where a server stands there without
    /// the session, as a user's tmux service starts one at boot, the session
    /// is made in it ([`Run::made_session`]), which changes no session the
    /// server holds. A socket the record does not name is a caller's own: no
    /// server is started there, since one would split the fleet across two
    /// servers, and a server standing there without the session refuses
    /// `tmux-session-missing`, since it may hold another fleet's sessions
    /// under names this one cannot judge.
    pub fn fleet_server(
        &self,
        named: Option<&str>,
        fallback: Option<&str>,
    ) -> Result<(Server, String)> {
        let socket = self.reach.socket()?.to_path_buf();
        let session = session_of(named, self.settings.tmux_session.as_deref(), fallback)?;
        let server = match tmux::server(&socket) {
            Ok(server) => server,
            Err(e) => {
                if !tmux::server_absent(&e) || !self.recorded_socket(&socket)? {
                    return Err(e);
                }
                self.started_server(&socket, &session)?
            }
        };
        if !tmux::session_present(&server, &session)? {
            if !self.recorded_socket(&socket)? {
                return Err(crate::Error::refused(
                    "tmux-session-missing",
                    &[
                        ("session", &session),
                        ("socket", &socket.display().to_string()),
                    ],
                ));
            }
            self.made_session(&server, &session)?;
        }
        Ok((server, session))
    }

    /// Whether `socket` is the one the fleet's controller record names, the
    /// server its panes stood on; a fleet with no such record names none.
    fn recorded_socket(&self, socket: &Path) -> Result<bool> {
        Ok(super::fleet_view(self.path)?
            .overseer
            .as_ref()
            .and_then(overseer_socket)
            .is_some_and(|recorded| recorded == socket))
    }

    /// `session` made on `server`, which stands on the recorded socket and
    /// which this process did not start, so its `exit-empty` stays as its
    /// starter set it. The making runs under the server record's lock with
    /// the session read again once the lock is held, so two launches of one
    /// fleet, such as a watch's recovery beside a person's resume, make it
    /// once. Its first window opens in the fleet state's directory, as a
    /// started server's does.
    fn made_session(&self, server: &Server, session: &str) -> Result<()> {
        crate::record::lock(&self.state_dir.join(SERVER_RECORD))?.with(|| {
            if !tmux::session_present(server, session)? {
                tmux::new_session(server, session, &self.state_dir, tmux::Started::Elsewhere)?;
            }
            Ok(())
        })
    }

    /// A tmux server started on `socket` holding `session`: `tmux -D`, the
    /// server in the foreground as the job's main process, run by the job
    /// launcher as a user unit or a `setsid` group and recorded in
    /// [`SERVER_RECORD`] beside the fleet state, its stderr in
    /// [`SERVER_ERR`]. The job stands outside the caller's process group,
    /// and a unit outside its cgroup too, so stopping the caller leaves the
    /// server standing; the unit outlives an OOM kill in any pane, since
    /// every pane runs in its cgroup. The socket's directory is made first
    /// where it is gone ([`tmux::socket_dir`]). The start runs under the
    /// record's lock with the socket read again once the lock is held, so
    /// two starts of one fleet start one server; tmux's own lock beside the
    /// socket holds a racing start from another fleet, whose second `-D`
    /// exits on the first server. No intent records the server, so no close
    /// ends it: it ends with its last session. A stderr file it cannot
    /// empty, a launch refused, a server that exits, or one that never
    /// answers within the verify bound refuses `tmux-server-unstarted`.
    /// `launch` is the launcher's answer (`refused`, `started`,
    /// `unanswered`), `exited` where the server ended before it answered,
    /// or `unrun` where the stderr file could not be written. `runner` is
    /// the launcher's line, or its cause where it refused or did not answer.
    /// `cause` is the server's own last stderr line, else the last tmux
    /// error the wait read, else `unanswered`.
    fn started_server(&self, socket: &Path, session: &str) -> Result<Server> {
        let record = self.state_dir.join(SERVER_RECORD);
        let err = self.state_dir.join(SERVER_ERR);
        crate::record::lock(&record)?.with(|| {
            match tmux::server(socket) {
                Ok(server) => return Ok(server),
                Err(e) if !tmux::server_absent(&e) => return Err(e),
                Err(_) => {}
            }
            tmux::socket_dir(socket)?;
            let word = socket.display().to_string();
            let unstarted = |launched: &str, runner: &str, cause: String| {
                Error::refused(
                    "tmux-server-unstarted",
                    &[
                        ("socket", &word),
                        ("session", session),
                        ("launch", launched),
                        ("runner", runner),
                        ("cause", &cause),
                    ],
                )
            };
            // The file holds this start's stderr alone, so a refusal never
            // names an earlier server's line.
            if let Err(e) = std::fs::write(&err, b"") {
                let cause = format!("stderr-unwritable path={} {e}", err.display());
                return Err(unstarted("unrun", "-", cause));
            }
            let launch = super::job::launch_recorded(
                "tmux-server",
                &format!("{}-{}", wall_secs(self.clock), std::process::id()),
                &record,
                &["tmux", "-S", &word, "-D"],
                Some(&err),
                super::job::Bounds {
                    memory: None,
                    outlives_oom: true,
                },
                self.clock,
            )
            .answer();
            let said = |tmux_error: Option<String>| {
                last_line(&err)
                    .or(tmux_error)
                    .unwrap_or_else(|| "unanswered".to_owned())
            };
            let (launched, runner) = match &launch {
                super::job::Launch::Refused { cause } => {
                    return Err(unstarted("refused", cause, said(None)));
                }
                super::job::Launch::Started { line, .. } => ("started", line.as_str()),
                super::job::Launch::Unanswered { cause } => ("unanswered", cause.as_str()),
            };
            let bound = self.settings.verify.get()?;
            let mut tmux_error = None;
            let answered = poll_until(self.clock, bound, POLL, || {
                match tmux::server(socket) {
                    Ok(server) => return Some(Some(server)),
                    Err(e) if !tmux::server_absent(&e) => tmux_error = Some(e.to_string()),
                    Err(_) => {}
                }
                // A server that exited answers no later read: its end is
                // the answer, with no wait for the bound.
                matches!(super::job::recorded_live(&record), Reading::Gone).then_some(None)
            });
            let server = match answered {
                Some(Some(server)) => server,
                Some(None) => return Err(unstarted("exited", runner, said(tmux_error))),
                None => return Err(unstarted(launched, runner, said(tmux_error))),
            };
            // The session's first window opens in the fleet state's
            // directory, which stands for every opener; a detached job's
            // own directory is whatever started it.
            tmux::new_session(&server, session, &self.state_dir, tmux::Started::Here)?;
            Ok(server)
        })
    }
}

/// The wall clock in seconds since the epoch.
fn wall_secs(clock: &dyn crate::clock::Clock) -> u64 {
    clock
        .wall()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

impl Operation<'_> {
    /// The session a window opens in: the one the opener's request names,
    /// else the one the settings name, else `fallback` (the opener's own:
    /// a lane's fleet record's `tmux.session`, a controller's predecessor's
    /// session), else `tmux-session-unresolved`.
    pub fn fleet_session(&self, named: Option<&str>, fallback: Option<&str>) -> Result<String> {
        session_of(named, self.run.settings.tmux_session.as_deref(), fallback)
    }

    /// The session the pane `id` stands in on the server the opener names;
    /// none where none is named or that pane or server cannot be read.
    pub fn pane_session(&self, id: &str) -> Option<String> {
        let server = tmux::server(self.run.reach.socket.as_deref()?).ok()?;
        match tmux::pane_state(&server, id) {
            crate::reading::Reading::Live(tmux::PaneState::Running(fields)) => {
                Some(fields.pane.session)
            }
            crate::reading::Reading::Live(tmux::PaneState::Dead(pane)) => Some(pane.session),
            crate::reading::Reading::Gone | crate::reading::Reading::Unreadable { .. } => None,
        }
    }

    /// The tmux server a window opens on and the session it opens in, as
    /// [`Run::fleet_server`] resolves them for this handle's run.
    pub fn fleet_server(
        &self,
        named: Option<&str>,
        fallback: Option<&str>,
    ) -> Result<(Server, String)> {
        self.run.fleet_server(named, fallback)
    }

    /// The server's own process identity, read live before a window opens on
    /// it, so a socket that stops answering can later be told from a server
    /// that is gone.
    pub fn server_process_start(
        &self,
        server: &Server,
    ) -> std::result::Result<String, crate::Error> {
        match process::identity(server.pid) {
            Reading::Live(identity) => Ok(identity.start),
            Reading::Gone => Err(crate::Error::refused(
                "server-gone",
                &[("pid", &server.pid.to_string())],
            )),
            Reading::Unreadable { cause } => Err(crate::Error::refused(
                "server-process-unreadable",
                &[("pid", &server.pid.to_string()), ("cause", cause)],
            )),
        }
    }

    /// Read the recorded identity `id` through the one identity reader and
    /// discharge it by that read where it stands: gone, nothing holds the
    /// pid; live, it stands with the token; another process under the pid is
    /// one stale reading, left standing for the count.
    pub fn read_process(&mut self, id: &Identity) -> Result<ProcessRead> {
        let read = match process::still_runs(id) {
            Reading::Live(_) => ProcessRead::Live,
            Reading::Unreadable { cause } => ProcessRead::Unreadable { cause },
            Reading::Gone => match process::identity(id.pid) {
                Reading::Gone => ProcessRead::Gone,
                Reading::Live(other) => ProcessRead::Stale { other },
                Reading::Unreadable { cause } => ProcessRead::Unreadable { cause },
            },
        };
        let end = match &read {
            ProcessRead::Live => None,
            ProcessRead::Gone => Some(ProcessEnd::Read(Reading::Gone)),
            ProcessRead::Unreadable { cause } => {
                Some(ProcessEnd::Read(Reading::Unreadable { cause }))
            }
            ProcessRead::Stale { .. } => {
                self.note_stale(id)?;
                None
            }
        };
        if let Some(end) = end {
            self.discharge(Discharge::Process {
                identity: id.clone(),
                end,
            })?;
        }
        Ok(read)
    }

    /// This run read `id` stale: counted once per run as one independent
    /// reading, written; the second reading settles the identity, never a
    /// signal to the reused pid.
    fn note_stale(&mut self, id: &Identity) -> Result<u64> {
        if self.stale.contains(id) {
            return Ok(self.obligations.stale_readings(id));
        }
        self.stale.push(id.clone());
        let readings = self.obligations.note_stale(id);
        if readings >= 2 {
            self.discharge(Discharge::Process {
                identity: id.clone(),
                end: ProcessEnd::Stale { readings },
            })?;
        } else {
            self.write()?;
        }
        Ok(readings)
    }

    /// The clock the handle's waits read.
    pub fn now(&self) -> std::time::Instant {
        self.clock.now()
    }

    /// The wall-clock time `after` from now, as the record's stamps spell
    /// one.
    pub fn stamp_after(&self, after: Duration) -> String {
        crate::clock::iso_utc(self.wall_secs() + after.as_secs())
    }

    /// The wall clock in seconds since the epoch.
    pub fn wall_secs(&self) -> u64 {
        wall_secs(self.clock)
    }

    pub fn sleep(&self, d: Duration) {
        self.clock.sleep(d);
    }

    /// The token for `id` where `Process(id)` stands in the set.
    pub fn standing_process(&self, id: &Identity) -> Option<Standing<Identity>> {
        self.obligations.standing_process(id)
    }

    /// The token for `pane` where its key stands in the set; the pane comes
    /// back where the set does not hold it, and nothing acts on it.
    pub fn standing_pane(&self, pane: Pane) -> std::result::Result<Standing<Pane>, Pane> {
        self.obligations.standing_pane(pane)
    }

    /// The harness identity the set recorded under the harness role, standing
    /// or discharged: what a lane close reads and stops.
    pub fn harness_identity(&self) -> Option<Identity> {
        self.obligations.harness_identity()
    }

    /// The standing pid-only harness a lane record named with no start.
    pub fn harness_pid(&self) -> Option<u32> {
        self.obligations.harness_pid()
    }

    /// The pane id the set records under the harness role, standing, for the
    /// observation a close writes.
    pub fn harness_pane_id(&self) -> Option<String> {
        self.obligations.pane(Role::Harness).map(|key| key.pane)
    }

    /// Refuse `token-stale` where the process token's key no longer stands
    /// in this handle's set.
    fn check_process_token(
        &self,
        token: &Standing<Identity>,
    ) -> std::result::Result<(), crate::Error> {
        if self
            .obligations
            .stands(&Obligation::Process(token.key().clone()))
        {
            return Ok(());
        }
        Err(crate::Error::refused(
            "token-stale",
            &[
                ("intent", &self.intent_id),
                ("cause", "not-standing"),
                ("pid", &token.key().pid.to_string()),
            ],
        ))
    }

    /// Refuse `token-stale` where the pane token's key no longer stands in
    /// this handle's set.
    pub(super) fn check_pane_token(
        &self,
        token: &Standing<Pane>,
    ) -> std::result::Result<(), crate::Error> {
        if self.key_of(token.key()).is_some() {
            return Ok(());
        }
        Err(crate::Error::refused(
            "token-stale",
            &[
                ("intent", &self.intent_id),
                ("cause", "not-standing"),
                ("pane", &token.key().id),
            ],
        ))
    }

    /// The sockets a standing pane or window key may answer on: the phase's,
    /// the overseer record's and the one the opener names, each once.
    fn sockets(&self, overseer: Option<&Overseer>) -> Vec<PathBuf> {
        let mut sockets: Vec<PathBuf> = Vec::new();
        let mut push = |socket: PathBuf| {
            if !sockets.contains(&socket) {
                sockets.push(socket);
            }
        };
        match &self.phase {
            Some(crate::intent::Phase::Opening { opening }) => push(PathBuf::from(&opening.socket)),
            Some(
                crate::intent::Phase::WindowOpened { opened }
                | crate::intent::Phase::Delivering { opened, .. }
                | crate::intent::Phase::Delivered { opened, .. }
                | crate::intent::Phase::IdentityRead { opened, .. },
            ) => push(PathBuf::from(&opened.socket)),
            Some(
                crate::intent::Phase::CloudCreate { .. } | crate::intent::Phase::Preparing { .. },
            )
            | None => {}
        }
        // A socket that cannot be named is no candidate: a key no socket
        // answers for is read by its server's pid.
        for socket in fleet_sockets(
            overseer.and_then(overseer_socket),
            self.run.reach.socket.clone(),
        ) {
            push(socket);
        }
        sockets
    }

    /// Read every standing obligation by its own recorded key, discharging
    /// what reads gone and leaving what reads live or unreadable standing:
    /// each `Process` and `Pid` through the one identity reader, each `Pane`
    /// and `Window` on the server its key names, each job through its unit
    /// or group. Run first by every reconcile.
    pub fn read_standing(&mut self, overseer: Option<&Overseer>) -> Result<()> {
        self.read_standing_processes()?;
        let sockets = self.sockets(overseer);
        let panes: Vec<(Option<String>, u64, Option<u64>)> = self
            .obligations
            .record()
            .standing_obligations()
            .filter_map(|o| match o {
                Obligation::Pane {
                    pane,
                    server,
                    server_start,
                } => Some((Some(pane.clone()), *server, *server_start)),
                Obligation::Window {
                    server,
                    server_start,
                } => Some((None, *server, Some(*server_start))),
                Obligation::Process(_)
                | Obligation::Pid { .. }
                | Obligation::PaneUnaddressed { .. }
                | Obligation::Receipt
                | Obligation::JobSidecar { .. }
                | Obligation::JobUnit { .. }
                | Obligation::JobGroup(_)
                | Obligation::JobPgid { .. } => None,
            })
            .collect();
        for (pane, server_pid, server_start) in panes {
            let end = match (server_at(&sockets, server_pid, server_start), &pane) {
                (Observed::Present(server), Some(id)) => match tmux::pane_fields(&server, id) {
                    Reading::Gone => Some(PaneEnd::Gone),
                    Reading::Live(_) | Reading::Unreadable { .. } => None,
                },
                // A window with no pane recorded may stand unregistered on a
                // server that answers; nothing enumerates panes to find it,
                // so it stands until the server's end.
                (Observed::Present(_), None) => None,
                (Observed::Gone { .. }, _) => Some(PaneEnd::Gone),
                (Observed::Unobservable { .. }, _) => None,
            };
            if let Some(end) = end {
                match pane {
                    Some(id) => {
                        let key = PaneRef {
                            pane: id,
                            server: server_pid,
                            server_start,
                        };
                        self.discharge(Discharge::Pane { pane: key, end })?;
                    }
                    None => {
                        if let Some(server_start) = server_start {
                            self.discharge(Discharge::Window {
                                server: server_pid,
                                server_start,
                            })?;
                        }
                    }
                }
            }
        }
        self.read_standing_jobs()
    }

    /// Read every standing `Process` and `Pid` obligation by its own key
    /// through the one identity reader, discharging each read gone.
    pub fn read_standing_processes(&mut self) -> Result<()> {
        for id in self.obligations.standing_processes() {
            self.read_process(&id)?;
        }
        let pids: Vec<u32> = self
            .obligations
            .record()
            .standing_obligations()
            .filter_map(|o| match o {
                Obligation::Pid { pid } => Some(*pid),
                Obligation::Process(_)
                | Obligation::Pane { .. }
                | Obligation::PaneUnaddressed { .. }
                | Obligation::Window { .. }
                | Obligation::Receipt
                | Obligation::JobSidecar { .. }
                | Obligation::JobUnit { .. }
                | Obligation::JobGroup(_)
                | Obligation::JobPgid { .. } => None,
            })
            .collect();
        for pid in pids {
            let _ = self.read_pid(pid)?;
        }
        Ok(())
    }

    /// A recorded pid live under another start is a reused pid. This run read
    /// `id` stale, counted in the record once per request; the second
    /// independent reading, a later request's, settles the identity. The
    /// count is written on `observation` and returned.
    pub fn count_stale(&mut self, id: &Identity, observation: &mut Value) -> Result<u64> {
        assert!(
            self.stale.contains(id),
            "a stale count follows this run's own stale reading of {}",
            id.pid
        );
        let readings = self.obligations.stale_readings(id);
        observation["readings"] = json!(readings);
        self.discharge(Discharge::Process {
            identity: id.clone(),
            end: ProcessEnd::Stale { readings },
        })?;
        Ok(readings)
    }

    /// Read a pid-only obligation by that pid through the one identity reader
    /// and discharge it where nothing holds it.
    pub fn read_pid(&mut self, pid: u32) -> Result<Reading<Identity>> {
        let read = process::identity(pid);
        self.discharge(Discharge::Pid {
            pid,
            read: read.clone(),
        })?;
        Ok(read)
    }

    /// The recorded phase pane as it reads on its own server; one gone, or
    /// its server with it, discharges the recorded pane by that read.
    pub fn observe_pane(&mut self, opened: &OpenedPane) -> Result<Observed<Pane>> {
        let observed = observe_pane(opened);
        if let Observed::Gone { .. } = &observed {
            self.discharge(Discharge::Pane {
                pane: PaneRef::of_opened(opened),
                end: PaneEnd::Gone,
            })?;
        }
        Ok(observed)
    }

    /// The standing pane of the set under the harness role as it reads on the
    /// server its key names among [`Self::sockets`], the socket `overseer`
    /// records before the ambient one: `None` where the set holds none;
    /// present as its token; gone, discharged by that read; or unobservable,
    /// standing.
    pub fn observe_target_pane(
        &mut self,
        overseer: Option<&Overseer>,
    ) -> Result<Option<Observed<Standing<Pane>>>> {
        let Some(key) = self.obligations.pane(Role::Harness) else {
            return Ok(None);
        };
        let sockets = self.sockets(overseer);
        Ok(Some(match observe_key(&sockets, &key) {
            Observed::Present(pane) => match self.standing_pane(pane) {
                Ok(token) => Observed::Present(token),
                Err(_) => unreachable!("the pane read by its standing key stands"),
            },
            Observed::Gone { cause } => {
                self.discharge(Discharge::Pane {
                    pane: key,
                    end: PaneEnd::Gone,
                })?;
                Observed::Gone { cause }
            }
            Observed::Unobservable { cause } => Observed::Unobservable { cause },
        }))
    }

    /// The standing pane key `pane` is recorded under: its id and server, at
    /// the server's start or a start the record never knew.
    fn key_of(&self, pane: &Pane) -> Option<PaneRef> {
        self.obligations
            .pane_key(&pane.id, pane.server.pid as u64, Some(pane.server.start))
    }

    /// Discharge the recorded pane `pane` is, where one stands, by `end`.
    fn pane_end(&mut self, pane: &Pane, end: PaneEnd) -> Result<()> {
        if let Some(key) = self.key_of(pane) {
            self.discharge(Discharge::Pane { pane: key, end })?;
        }
        Ok(())
    }

    /// The pane's own process pid by exact id; the pane gone discharges it.
    pub fn pane_pid(&mut self, pane: &Pane) -> Result<Reading<u32>> {
        let read = tmux::pane_fields(&pane.server, &pane.id).map(|fields| fields.pid);
        if read == Reading::Gone {
            self.pane_end(pane, PaneEnd::Gone)?;
        }
        Ok(read)
    }

    /// Who holds the pane's terminal under `pane_pid`, through the one judge:
    /// a harness identity read here is added to the set, written, and
    /// returned as the recorded token.
    pub fn foreground_of(
        &mut self,
        pane_pid: u32,
        owns: &dyn Fn(&str) -> bool,
        recorded: Option<&Identity>,
    ) -> Result<Foreground> {
        let reading = observe::foreground(pane_pid, owns, recorded);
        let harness = match &reading {
            ProcessReading::Harness { identity } => {
                self.add(Obligation::Process(identity.clone()))?;
                Some(Recorded {
                    value: identity.clone(),
                })
            }
            ProcessReading::ShellsOnly
            | ProcessReading::HarnessUp
            | ProcessReading::ForegroundShell { .. }
            | ProcessReading::ForegroundOther { .. }
            | ProcessReading::Unread { .. } => None,
        };
        Ok(Foreground { reading, harness })
    }

    /// The process a runner's pane runs now, read by exact pane id through
    /// the one identity reader: added to the set, written, before the stop
    /// that follows; the pane gone discharges the pane.
    pub fn pane_process(&mut self, pane: &Pane) -> Result<Reading<Identity>> {
        let read = match tmux::pane_fields(&pane.server, &pane.id) {
            Reading::Live(fields) => process::identity(fields.pid),
            Reading::Gone => {
                self.pane_end(pane, PaneEnd::Gone)?;
                Reading::Gone
            }
            Reading::Unreadable { cause } => Reading::Unreadable { cause },
        };
        if let Reading::Live(id) = &read {
            self.add(Obligation::Process(id.clone()))?;
        }
        Ok(read)
    }

    /// One reading of a pane: who holds its terminal and what the screen says.
    /// A harness identity is written before capture and checked again after it.
    /// With `recorded`, only that identity is the harness. The pane gone
    /// discharges the pane; a host that does not answer is `Unreadable`.
    pub fn read_pane(
        &mut self,
        pane: &Pane,
        harness: Harness,
        owns: &dyn Fn(&str) -> bool,
        recorded: Option<&Identity>,
    ) -> Result<Reading<(Foreground, State)>> {
        let pid = match self.pane_pid(pane)? {
            Reading::Live(pid) => pid,
            Reading::Gone => return Ok(Reading::Gone),
            Reading::Unreadable { cause } => return Ok(Reading::Unreadable { cause }),
        };
        let foreground = self.foreground_of(pid, owns, recorded)?;
        let (screen, foreground) = match tmux::capture(pane) {
            Ok(screen) if foreground.harness.is_none() => (screen, foreground),
            capture => {
                // The pane can vanish during capture, or a shell can take
                // over and draw a prompt that looks like the composer.
                let after_pid = match self.pane_pid(pane)? {
                    Reading::Live(pid) => pid,
                    Reading::Gone => return Ok(Reading::Gone),
                    Reading::Unreadable { cause } => return Ok(Reading::Unreadable { cause }),
                };
                let Ok(screen) = capture else {
                    return Ok(Reading::Unreadable {
                        cause: "capture-failed",
                    });
                };
                if after_pid != pid {
                    return Ok(Reading::Unreadable {
                        cause: "pane-process-changed",
                    });
                }
                let reading = observe::foreground(after_pid, owns, recorded);
                let foreground = match reading {
                    ProcessReading::Harness { .. } if reading == foreground.reading => foreground,
                    ProcessReading::Harness { .. } => {
                        return Ok(Reading::Unreadable {
                            cause: "foreground-changed",
                        });
                    }
                    reading => Foreground {
                        reading,
                        harness: None,
                    },
                };
                (screen, foreground)
            }
        };
        let state = observe::judge(&screen, harness, &foreground.reading, None);
        Ok(Reading::Live((foreground, state)))
    }

    /// Close the window the standing pane is in, `signalled` written before
    /// the kill, and discharge the pane by the close's own answer.
    pub fn close_window(&mut self, pane: Standing<Pane>) -> Result<Close> {
        self.check_pane_token(&pane)?;
        self.write_signal()?;
        let close = tmux::kill_window(pane.key());
        self.pane_end(pane.key(), PaneEnd::Close(close.clone()))?;
        Ok(close)
    }

    /// Close the standing pane alone by exact id, as `close_window` closes
    /// its window.
    pub(super) fn close_pane(&mut self, pane: Standing<Pane>) -> Result<Close> {
        self.check_pane_token(&pane)?;
        self.write_signal()?;
        let close = tmux::kill_pane(pane.key());
        self.pane_end(pane.key(), PaneEnd::Close(close.clone()))?;
        Ok(close)
    }

    /// Keep the standing pane on its server once its harness exits. A
    /// controller's pane is kept so the session it holds outlives the
    /// harness: the dead-overseer recovery opens the successor in that
    /// session, and the retirement closes the dead pane's window. Only a
    /// pane nothing of the effect polls again is kept, since the polls read
    /// a kept pane as unreadable, never gone.
    pub fn keep_pane(&self, pane: &Standing<Pane>) -> std::result::Result<(), crate::Error> {
        self.check_pane_token(pane)?;
        tmux::keep_on_exit(pane.key())
    }

    /// Close the window of the set's standing pane on the server
    /// [`Self::observe_target_pane`] reads it on: one
    /// present is killed by its token; one gone stands no more; none standing
    /// is no window to close; one the host did not answer for stands with
    /// that cause.
    pub fn close_target_window(&mut self, overseer: Option<&Overseer>) -> Result<WindowClose> {
        Ok(match self.observe_target_pane(overseer)? {
            None => WindowClose::Unrecorded,
            Some(Observed::Gone { cause }) => WindowClose::Gone { cause },
            Some(Observed::Present(pane)) => WindowClose::Window(self.close_window(pane)?),
            Some(Observed::Unobservable { cause }) => {
                if let Some(key) = self.obligations.pane(Role::Harness) {
                    self.discharge(Discharge::Pane {
                        pane: key,
                        end: PaneEnd::Close(Close::Unreadable {
                            cause: cause.to_owned(),
                        }),
                    })?;
                }
                WindowClose::Unobservable { cause }
            }
        })
    }

    /// The standing pane key the overseer record names, at any start.
    fn overseer_pane_key(&self, overseer: &Overseer) -> Option<PaneRef> {
        let (server, pane) = overseer_pane(overseer)?;
        self.obligations.pane_key(&pane, server, None)
    }

    /// Close the predecessor's window on the server the record names, by its
    /// recorded socket, through the standing token for its pane; a record
    /// with no server start names a pane this runtime cannot prove is the one
    /// it means, so nothing is closed. Another server answering on that
    /// socket, or none with the recorded server's process gone, proves the
    /// window gone with its server, discharged by that read.
    pub fn close_overseer_window(&mut self, overseer: &Overseer) -> Result<WindowClose> {
        let Some(key) = self.overseer_pane_key(overseer) else {
            return Ok(WindowClose::Unrecorded);
        };
        let Some(server_start) = overseer.extra.get("server_start").and_then(pid_value) else {
            return Ok(WindowClose::Unobservable {
                cause: "server-start-unrecorded",
            });
        };
        let named = self.run.reach.socket.as_deref();
        let observed = match controller_socket(overseer, named)
            .and_then(|s| tmux::recorded_server(&s, key.server))
        {
            Ok(server) if server.pid as u64 == key.server && server.start == server_start => {
                observe_fields(&server, &key.pane)
            }
            Ok(_) => Observed::Gone {
                cause: "server-replaced",
            },
            Err(e) => unanswering(key.server, None, Some(&e)),
        };
        Ok(match observed {
            Observed::Present(pane) => match self.standing_pane(pane) {
                Ok(token) => WindowClose::Window(self.close_window(token)?),
                Err(_) => unreachable!("the pane read by its standing key stands"),
            },
            Observed::Gone { cause } => {
                self.discharge(Discharge::Pane {
                    pane: key,
                    end: PaneEnd::Gone,
                })?;
                WindowClose::Gone { cause }
            }
            Observed::Unobservable { cause } => {
                self.discharge(Discharge::Pane {
                    pane: key,
                    end: PaneEnd::Close(Close::Unreadable {
                        cause: cause.to_owned(),
                    }),
                })?;
                WindowClose::Unobservable { cause }
            }
        })
    }

    /// A predecessor stop that read unreadable before it sent any signal
    /// leaves the predecessor as it was: its identity and its window return
    /// to the record they came from, each discharged `not-signalled` by that
    /// answer. `true` where `stopped` was such a stop.
    pub fn release_retirement(&mut self, overseer: &Overseer, stopped: &Stopped) -> Result<bool> {
        let Stop::Unreadable {
            signalled: false, ..
        } = &stopped.answer
        else {
            return Ok(false);
        };
        self.discharge(Discharge::Process {
            identity: stopped.identity.clone(),
            end: ProcessEnd::NotSignalled,
        })?;
        if let Some(key) = self.overseer_pane_key(overseer) {
            self.discharge(Discharge::Pane {
                pane: key,
                end: PaneEnd::NotSignalled,
            })?;
        }
        Ok(true)
    }

    /// The proof for a predecessor whose record carries no identity; its pane
    /// read gone on the proven server discharges the predecessor's pane
    /// where the set holds it.
    pub fn terminal_proof(&mut self, overseer: &Overseer) -> Result<Proof> {
        let target = overseer_target_of(&self.run.settings.harness_binaries, overseer)?;
        let proof = proof_of(overseer, target.as_ref(), self.run.reach.socket.as_deref());
        if let Proof::Proven { by: "pane-gone" } = &proof
            && let Some(key) = self.overseer_pane_key(overseer)
        {
            self.discharge(Discharge::Pane {
                pane: key,
                end: PaneEnd::Gone,
            })?;
        }
        Ok(proof)
    }

    /// Stop the standing identity and the processes `owns` names below it
    /// exactly, `signalled` written before the first signal, and discharge
    /// the identity by the stop's own answer: stopped or already gone settles
    /// it, a timeout or an unreadable read leaves it standing with the cause,
    /// a pid now holding another process is one stale reading.
    pub fn stop_process(
        &mut self,
        target: Standing<Identity>,
        owns: &dyn Fn(&str) -> bool,
    ) -> Result<Stopped> {
        self.check_process_token(&target)?;
        let id = target.key().clone();
        self.write_signal()?;
        let answer = process::stop_tree(&id, owns, self.run.close_grace.get()?)?;
        match &answer {
            Stop::IdentityStale => {
                self.note_stale(&id)?;
            }
            Stop::Stopped { .. }
            | Stop::AlreadyGone
            | Stop::Timeout { .. }
            | Stop::Unreadable { .. } => {
                self.discharge(Discharge::Process {
                    identity: id.clone(),
                    end: ProcessEnd::Stop(answer.clone()),
                })?;
            }
        }
        Ok(Stopped {
            identity: id,
            answer,
        })
    }

    /// already over. `Some(cause)` where one outlived its grace or could not
    /// be read. A moved intent retries this sweep on its own set alone:
    /// nothing the lane names now is read here.
    pub fn stop_standing_processes(
        &mut self,
        owns: &dyn Fn(&str) -> bool,
        wake: Option<&Identity>,
    ) -> Result<Option<String>> {
        let mut held: Option<String> = None;
        for id in self.obligations.standing_processes() {
            if self.stale.contains(&id) {
                continue;
            }
            let Some(token) = self.standing_process(&id) else {
                continue;
            };
            let stopped = self.stop_process(token, owns)?;
            match stopped.answer() {
                Stop::Stopped { .. } | Stop::AlreadyGone => {}
                Stop::IdentityStale if wake == Some(&id) => {
                    self.discharge(Discharge::Process {
                        identity: id.clone(),
                        end: ProcessEnd::Read(process::still_runs(&id)),
                    })?;
                }
                Stop::IdentityStale => {}
                Stop::Timeout { .. } => {
                    held.get_or_insert_with(|| "wake-timeout".to_owned());
                }
                Stop::Unreadable { cause, .. } => {
                    held.get_or_insert_with(|| cause.clone());
                }
            }
        }
        Ok(held)
    }

    /// Close every standing addressable pane of the set by its full key, on
    /// the server the key names at the caller's sockets:
    /// a pane present is killed by exact id through its token; one gone, or
    /// on a server gone or replaced at the key's pid,
    /// is discharged by that read; one the host does not answer for stands.
    /// A pane id is never reused within a server's lifetime, so the key
    /// names the pane the set recorded and no other. The one close a moved
    /// intent retries on its own set with: nothing the target names now is
    /// read.
    pub fn close_standing_panes(&mut self, overseer: Option<&Overseer>) -> Result<()> {
        let sockets = self.sockets(overseer);
        for key in self.obligations.standing_panes() {
            let observed = match server_at(&sockets, key.server, key.server_start) {
                Observed::Present(server) => observe_fields(&server, &key.pane),
                Observed::Gone { cause } => Observed::Gone { cause },
                Observed::Unobservable { cause } => Observed::Unobservable { cause },
            };
            match observed {
                Observed::Present(pane) => {
                    if let Ok(token) = self.standing_pane(pane) {
                        let _ = self.close_pane(token)?;
                    }
                }
                Observed::Gone { .. } => {
                    self.discharge(Discharge::Pane {
                        pane: key,
                        end: PaneEnd::Gone,
                    })?;
                }
                Observed::Unobservable { .. } => {}
            }
        }
        Ok(())
    }

    /// Read the standing process `id` through the one identity reader,
    /// signalling nothing, and discharge it by that read: a reconcile's read
    /// of a process the set holds.
    pub fn read_process_end(&mut self, id: &Identity) -> Result<Reading<Identity>> {
        let read = process::still_runs(id);
        self.discharge(Discharge::Process {
            identity: id.clone(),
            end: ProcessEnd::Read(read.clone()),
        })?;
        Ok(read)
    }

    /// Send Copilot `C-c` then `/exit` on the standing pane and wait up to the
    /// close grace, on the injected clock, for it to exit, so it writes its
    /// session totals. The keystrokes are a signal, written before they are
    /// sent. Best effort: the stop that follows ends a pane that stands.
    pub fn copilot_exit(&mut self, pane: &Standing<Pane>) -> Result<()> {
        self.check_pane_token(pane)?;
        self.write_signal()?;
        let pane = pane.key();
        let _ = tmux::send_key(pane, "C-c");
        let _ = tmux::send_line(pane, "/exit");
        let deadline = self.now() + self.run.close_grace.get()?;
        while self.now() < deadline {
            if tmux::pane_fields(&pane.server, &pane.id) == Reading::Gone {
                break;
            }
            self.sleep(Duration::from_millis(100));
        }
        Ok(())
    }

    /// Wait for the process that handed this intent to the job to exit,
    /// within the launch bound: the pane about to be retired is its own as
    /// often as not. A caller still live past the bound, or one that cannot
    /// be read, holds the succession no longer.
    pub fn await_caller_gone(&self) -> Result<()> {
        let Some(caller) = super::read_intent(self.run.path, &self.intent_id)?.handed_from else {
            return Ok(());
        };
        let Ok(pid) = u32::try_from(caller.pid) else {
            return Ok(());
        };
        let identity = Identity {
            pid,
            start: caller.start,
        };
        let deadline = self.now() + self.run.settings.verify.get()?;
        while self.now() < deadline {
            match process::still_runs(&identity) {
                Reading::Live(_) => self.sleep(POLL),
                Reading::Gone | Reading::Unreadable { .. } => break,
            }
        }
        Ok(())
    }

    /// Mint the session id where the harness takes one, else read the
    /// baseline of lead sessions for `cwd` under `home`. A store with no root
    /// is an empty baseline; one that could not be read refuses before any
    /// window opens.
    pub fn session_floor(&self, harness: Harness, home: &Path, cwd: &Path) -> Result<SessionFloor> {
        if harness.fixes_session_id() {
            return Ok(SessionFloor::Fixed(session::fresh_session_id()?));
        }
        match session::lead_ids(harness, home, cwd) {
            Reading::Live(ids) => Ok(SessionFloor::Baseline(ids)),
            Reading::Gone => Ok(SessionFloor::Baseline(Vec::new())),
            Reading::Unreadable { cause } => {
                Err(Error::refused("baseline-unreadable", &[("cause", cause)]))
            }
        }
    }

    /// The one lead session for `cwd` under `home` that appeared since the
    /// window opened and stood in no baseline before it: a neighbour in the
    /// same home and directory is never a candidate. A set read whole or not
    /// at all; an unread candidate binds nothing and names its cause. A
    /// harness ready at its composer may write its session moments later
    /// (Codex its rollout), so none found is read again within the launch
    /// bound before it binds nothing.
    pub fn appeared_session(
        &self,
        harness: Harness,
        home: &Path,
        cwd: &Path,
        opened: &OpenedPane,
    ) -> Result<Binding> {
        let since = std::time::UNIX_EPOCH + Duration::from_millis(opened.since_ms);
        let deadline = self.now() + self.run.settings.verify.get()?;
        let mut found = loop {
            match session::new_leads(harness, home, cwd, since, &opened.baseline) {
                Reading::Live(found) if !found.is_empty() => break found,
                Reading::Live(_) | Reading::Gone if self.now() < deadline => self.sleep(POLL),
                Reading::Live(_) | Reading::Gone => break Vec::new(),
                Reading::Unreadable { cause } => return Ok(Binding::Unreadable { cause }),
            }
        };
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

    /// Type `text` and Enter into the standing pane: the held brief delivered
    /// to the runner at its composer. The `delivering` phase is written
    /// once the line is loaded and before the paste, so a repeat after a
    /// crash or an unanswered paste reads the brief as possibly delivered
    /// and never pastes twice, while a line refused before the paste leaves
    /// the phase where it stood for a repeat to deliver. No obligation
    /// changes: the pane and its process stand as before.
    pub fn deliver(
        &mut self,
        pane: &Standing<Pane>,
        text: &str,
        delivering: Phase,
    ) -> Result<Delivery> {
        self.check_pane_token(pane)?;
        let loaded = match tmux::load_line(pane.key(), text) {
            Ok(loaded) => loaded,
            Err(e) => return Ok(Delivery::Unsent(e)),
        };
        self.record_phase(delivering)?;
        Ok(match loaded.paste() {
            Ok(()) => Delivery::Pasted,
            Err(e) => Delivery::Unanswered(e),
        })
    }

    /// The user turns the session file `file` records.
    pub fn user_turns(&self, harness: Harness, file: &Path) -> Result<u64> {
        Ok(session::user_turns(harness, file)? as u64)
    }
}

/// How a brief's paste went: pasted, refused before anything reached the
/// pane, or asked with no answer, the text possibly in the pane.
pub enum Delivery {
    Pasted,
    Unsent(crate::Error),
    Unanswered(crate::Error),
}

/// Read the pane an adoption names and record the controller in it: the
/// harness identity in the pane's foreground, through the one judge,
/// never the caller's word for it. A record naming
/// another session refuses `overseer-live` while that session's identity
/// reads live, or its pane stands on the proven server holding anything
/// but shells with no identity recorded; one it cannot read refuses
/// `overseer-unreadable`; one nothing
/// resolves refuses `predecessor-unproven`. A request naming neither the
/// permission nor its words records the posture that harness was launched
/// under ([`launched_posture`]), keeping the recorded one where those words
/// cannot be read on the process the record names ([`adopted_posture`]);
/// one naming either records the pair it states ([`stated_posture`]). A
/// Claude adoption records the config dir that process runs on and whether
/// it names it ([`adopted_home`]), with a `home-unread` notice where nothing
/// read for that process gives its mode. The one
/// read-then-record operation of the fleet: no intent, so no
/// handle, and nothing it reads is an obligation.
pub fn adopt_controller(
    path: &Path,
    r: &AdoptController,
    settings: &EngineSettings,
    locking: Locking,
) -> Result<ControllerAdopted> {
    adopt_on(path, r, None, Unnamed::Launched, None, settings, locking)
}

/// The posture an adoption records where its request names neither the
/// permission nor its words.
#[derive(Clone, Copy)]
enum Unnamed {
    /// The one the harness in the pane was launched under.
    Launched,
    /// The one the record keeps: a heal of the pane it already names.
    Kept,
}

/// [`adopt_controller`] on `confirmed`, the server a caller already read at
/// the request's socket through the program of the pid its record names, so
/// the adoption reaches the server that read did; `None` reads the server at
/// the socket afresh. `registered` is the Claude home a registration read
/// for the process in the pane ([`vouched_home`]).
fn adopt_on(
    path: &Path,
    r: &AdoptController,
    confirmed: Option<tmux::Server>,
    unnamed: Unnamed,
    registered: Option<Kept>,
    settings: &EngineSettings,
    locking: Locking,
) -> Result<ControllerAdopted> {
    let overseer = fleet_view(path)?.overseer;
    let harness = Harness::named(&r.harness)?;
    if !is_pane_id(&r.pane) {
        return Err(Error::refused("pane-invalid", &[("pane", &r.pane)]));
    }
    let socket = match &r.socket {
        Some(socket) => socket.clone(),
        None => caller_socket()?,
    };
    let server = match confirmed {
        Some(server) => server,
        None => tmux::server(&socket)?,
    };
    let fields = pane_read(&server, &r.pane)?;
    let target = Target::new(&settings.harness_binaries, harness)?;
    let identity = match observe::foreground(fields.pid, &|name| target.owns(name), None) {
        ProcessReading::Harness { identity } => identity,
        ProcessReading::Unread { cause } => {
            return Err(Error::refused(
                "pane-unreadable",
                &[("pane", &r.pane), ("cause", cause)],
            ));
        }
        reading @ (ProcessReading::ShellsOnly
        | ProcessReading::HarnessUp
        | ProcessReading::ForegroundShell { .. }
        | ProcessReading::ForegroundOther { .. }) => {
            return Err(Error::PaneNotHarness {
                pane: r.pane.clone(),
                reading: reading_word(&reading),
            });
        }
    };
    let same = overseer
        .as_ref()
        .is_some_and(|o| names_pane(o, server.pid, server.start, &r.pane));
    if !same && let Some(recorded) = &overseer {
        let live = |pid: u64| Error::OverseerLive {
            path: path.to_path_buf(),
            pid,
        };
        let unreadable = |cause: &str| Error::OverseerUnreadable {
            path: path.to_path_buf(),
            cause: cause.to_owned(),
        };
        match predecessor_identity(recorded) {
            Some(prior) => match process::still_runs(&prior) {
                Reading::Live(_) => return Err(live(prior.pid as u64)),
                Reading::Gone => {}
                Reading::Unreadable { cause } => return Err(unreadable(cause)),
            },
            None => match proof_of(
                recorded,
                overseer_target_of(&settings.harness_binaries, recorded)?.as_ref(),
                Some(&socket),
            ) {
                Proof::Standing { pid } => return Err(live(pid as u64)),
                Proof::Unreadable { cause } => return Err(unreadable(cause)),
                // Nothing resolves the recorded session: it is not replaced;
                // adoption from its own pane heals it.
                Proof::Unproven { cause } => {
                    return Err(Error::PredecessorUnproven {
                        path: path.to_path_buf(),
                        cause: cause.to_owned(),
                    });
                }
                Proof::Proven { .. } | Proof::Empty => {}
            },
        }
    }
    let posture = adopted_posture(
        stated_posture(harness, r),
        unnamed,
        || launched_posture(harness, identity.pid),
        same,
        overseer.as_ref(),
        &identity,
    );
    let adopted;
    let r = match posture {
        Some((permission, words)) => {
            adopted = AdoptController {
                permission: Some(permission),
                extra_args: Some(words),
                ..r.clone()
            };
            &adopted
        }
        None => r,
    };
    let (home, home_unread) = match harness {
        Harness::Claude => adopted_home(
            r.home.as_deref().or(r.account.as_deref()),
            claude_home_of(&identity),
            vouched_home(registered, overseer.as_ref(), same, unnamed, &identity),
        ),
        Harness::Codex | Harness::Copilot | Harness::Pi => (None, None),
    };
    let read = Recorded {
        value: AdoptionRead {
            identity,
            home,
            server: server.pid as u64,
            server_start: server.start,
            socket: socket.display().to_string(),
            window: fields.pane.window.clone(),
            same,
        },
    };
    let mut adopted =
        super::adoption::apply_adoption(path, r, &read, &settings.account_state, locking)?;
    if let Some(cause) = home_unread {
        adopted
            .notices
            .push(format!("home-unread pane={} cause={cause}", r.pane));
    }
    Ok(adopted)
}

/// The Claude home a record keeps with its mode; `None` where it keeps no
/// mode.
fn recorded_home(overseer: &Overseer) -> Option<Kept> {
    let home = views::text(overseer.extra.get("home"))?;
    let implicit = overseer.extra.get("home_implicit")?.as_bool()?;
    Some(Kept {
        home: PathBuf::from(home),
        named: !implicit,
    })
}

/// The config dir a Claude process runs on from the environment it was
/// started with: `config_dir`, its `CLAUDE_CONFIG_DIR`, named, else the
/// implicit default under its `HOME`; `None` with neither.
fn claude_home(config_dir: Option<String>, home: Option<&Path>) -> Option<Kept> {
    match config_dir {
        Some(dir) => Some(Kept {
            home: PathBuf::from(dir),
            named: true,
        }),
        None => home.map(|home| Kept {
            home: session::default_home_at(Harness::Claude, home),
            named: false,
        }),
    }
}

/// The config dir the Claude process `identity` names runs on, read from
/// its own environment ([`claude_home`]). `Err` names why it was not read,
/// as on a host with no `/proc`. The identity is read live after, so a
/// reused pid never answers for another process's environment.
fn claude_home_of(identity: &Identity) -> std::result::Result<Kept, &'static str> {
    let kept = claude_home(
        process_var(identity.pid, Harness::Claude.home_var())?,
        process_var(identity.pid, "HOME")?.as_deref().map(Path::new),
    )
    .ok_or("home-unset")?;
    match process::still_runs(identity) {
        Reading::Live(_) => Ok(kept),
        Reading::Gone => Err("process-gone"),
        Reading::Unreadable { cause } => Err(cause),
    }
}

/// The Claude home vouched for the process `identity` in the pane, which
/// stands where that process's own environment is unread: the one a
/// registration read for it (`registered`), else the record's, only where
/// that record is this process's: a heal of the pane it names, or the
/// identity it records. A replacement in the same pane gets none.
fn vouched_home(
    registered: Option<Kept>,
    overseer: Option<&Overseer>,
    same: bool,
    unnamed: Unnamed,
    identity: &Identity,
) -> Option<Kept> {
    registered.or_else(|| {
        overseer
            .filter(|o| {
                same && match unnamed {
                    Unnamed::Kept => true,
                    Unnamed::Launched => predecessor_identity(o).as_ref() == Some(identity),
                }
            })
            .and_then(recorded_home)
    })
}

/// The Claude home an adoption records for the process it read, and why
/// that process was not read where nothing gives its mode. The process's
/// own reading stands where the request supplies no path or the same one,
/// so equal paths keep the mode the process runs in; a supplied path it does
/// not run on is named. Unread, the home vouched for this process stands on
/// the same terms; with none that agrees, the request's home is recorded
/// with no mode, since the path alone cannot tell the implicit default from
/// `$HOME/.claude` named, and the cause is said. Paths agree by where they
/// resolve, since a caller may supply a link's target; the recorded home
/// keeps the process's spelling, whose parent a resumed implicit home pins
/// as `HOME`.
fn adopted_home(
    supplied: Option<&str>,
    observed: std::result::Result<Kept, &'static str>,
    vouched: Option<Kept>,
) -> (Option<Kept>, Option<&'static str>) {
    let agrees = |kept: &Kept| {
        supplied.is_none_or(|path| {
            kept.home
                .to_str()
                .is_some_and(|home| canon(path) == canon(home))
        })
    };
    match observed {
        Ok(seen) if agrees(&seen) => (Some(seen), None),
        Ok(_) => (
            supplied.map(|path| Kept {
                home: PathBuf::from(path),
                named: true,
            }),
            None,
        ),
        Err(cause) => match vouched.filter(|kept| agrees(kept)) {
            Some(kept) => (Some(kept), None),
            None => (None, Some(cause)),
        },
    }
}

/// Whether the record names `pane` on `server`, with a matching start
/// where recorded. A record with no server start accepts that pane
/// on the named server.
fn names_pane(overseer: &Overseer, server: u32, start: u64, pane: &str) -> bool {
    overseer.extra.get("server").and_then(pid_value) == Some(server as u64)
        && overseer.extra.get("pane").and_then(Value::as_str) == Some(pane)
        && overseer
            .extra
            .get("server_start")
            .and_then(pid_value)
            .is_none_or(|recorded| recorded == start)
}

/// The controller record's process identity and server start, filled from
/// the pane it names where a write left them out. Only a record that names
/// that pane on the answering server is healed, in place, and only when it
/// is not off and no controller intent is open. The native session id is
/// never bound here: a session file found beside the process does not say
/// which session the process runs, since an older session in the same
/// directory reads the same. The adoption that names the id, or the
/// turn-end hook reading its own session's id, binds it. The pane is read
/// on the server the record names, else on `named`, the opener's.
pub fn heal_controller(
    path: &Path,
    settings: &EngineSettings,
    named: Option<&Path>,
    locking: Locking,
) -> Result<Option<ControllerAdopted>> {
    let body = fleet_view(path)?;
    let Some(overseer) = body.overseer else {
        return Ok(None);
    };
    let word = |key: &str| {
        overseer
            .extra
            .get(key)
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
    };
    let (Some(pane), Some(harness_word)) = (word("pane"), word("harness")) else {
        return Ok(None);
    };
    let bound = predecessor_identity(&overseer).is_some()
        && overseer
            .extra
            .get("server_start")
            .is_some_and(|v| !v.is_null());
    let off = overseer.extra.get("off").is_some_and(|v| !v.is_null());
    let open = body
        .intents
        .iter()
        .any(|i| i.open() && i.op.on_controller());
    if bound || off || open {
        return Ok(None);
    }
    if Harness::parse(&harness_word).is_none() {
        return Ok(None);
    }
    let socket = controller_socket(&overseer, named)?;
    let server = match overseer.extra.get("server").and_then(pid_value) {
        Some(pid) => tmux::recorded_server(&socket, pid)?,
        None => tmux::server(&socket)?,
    };
    if !names_pane(&overseer, server.pid, server.start, &pane) {
        return Ok(None);
    }
    let request = AdoptController {
        pane,
        socket: Some(socket),
        harness: harness_word,
        // The heal binds no session: the recorded binding, an empty one
        // included, is written back as it stands.
        session_id: overseer.session_id.clone(),
        account: word("account"),
        home: word("home").or_else(|| word("account")),
        model: word("model"),
        effort: word("effort"),
        cwd: word("cwd"),
        session_rows: word("session_rows").map(PathBuf::from),
        // The heal names no posture: the same pane keeps the recorded one.
        permission: None,
        extra_args: None,
    };
    adopt_on(
        path,
        &request,
        Some(server),
        Unnamed::Kept,
        None,
        settings,
        locking,
    )
    .map(Some)
}

/// The fields of `pane` on `server`: gone refuses `pane-gone`, a failed
/// read `pane-unreadable` with its cause.
fn pane_read(server: &tmux::Server, pane: &str) -> Result<tmux::PaneFields> {
    match tmux::pane_fields(server, pane) {
        Reading::Live(fields) => Ok(fields),
        Reading::Gone => Err(Error::refused("pane-gone", &[("pane", pane)])),
        Reading::Unreadable { cause } => Err(Error::refused(
            "pane-unreadable",
            &[("pane", pane), ("cause", cause)],
        )),
    }
}

/// The word a foreground reading carries as its `reading` field.
fn reading_word(reading: &ProcessReading) -> String {
    serde_json::to_value(reading)
        .ok()
        .and_then(|v| v.get("reading").and_then(Value::as_str).map(str::to_owned))
        .unwrap_or_default()
}

/// The launch identity a hand-opened controller's harness stated at its
/// start, from the last `SessionStart` row of its rows file.
struct StartRow {
    harness: String,
    account: Option<String>,
    model: Option<String>,
    cwd: String,
}

/// The last `SessionStart` row of `file` that names a harness and a
/// directory, over the last [`crate::rows::SPAN`] such rows: `Gone`
/// where the file is absent or holds none, `Unreadable` where it cannot be
/// read. A line that is no object is skipped, as a killed writer's fragment.
fn start_row(file: &Path) -> Reading<StartRow> {
    let text = match std::fs::read_to_string(file) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Reading::Gone,
        Err(_) => {
            return Reading::Unreadable {
                cause: "rows-file-unreadable",
            };
        }
    };
    let starts: Vec<&str> = text
        .lines()
        .filter(|line| line.contains("\"event\":\"SessionStart\""))
        .collect();
    let from = starts.len().saturating_sub(crate::rows::SPAN);
    let Some(row) = starts[from..].iter().rev().find_map(|line| {
        serde_json::from_str::<Value>(line)
            .ok()
            .filter(|row| row.get("event").and_then(Value::as_str) == Some("SessionStart"))
    }) else {
        return Reading::Gone;
    };
    let text_of = |key: &str| {
        row.get(key)
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
    };
    match (text_of("harness"), text_of("cwd")) {
        (Some(harness), Some(cwd)) => Reading::Live(StartRow {
            harness,
            account: text_of("account"),
            model: text_of("model"),
            cwd,
        }),
        (None, _) | (_, None) => Reading::Gone,
    }
}

/// The harness whose own process holds the pane's terminal, judged against
/// every harness in turn, Copilot first since a Copilot CLI runs under a
/// `node` launcher; none refuses `pane-not-harness`.
fn foreground_harness(
    settings: &EngineSettings,
    pane: &str,
    pane_pid: u32,
) -> Result<(Harness, Identity)> {
    let mut last = String::new();
    for harness in [
        Harness::Copilot,
        Harness::Claude,
        Harness::Codex,
        Harness::Pi,
    ] {
        match harness_in_pane(settings, harness, pane, pane_pid)? {
            Ok(identity) => return Ok((harness, identity)),
            Err(reading) => last = reading_word(&reading),
        }
    }
    Err(Error::PaneNotHarness {
        pane: pane.to_owned(),
        reading: last,
    })
}

/// The process of `harness` that holds the pane's terminal, or the reading
/// that says another holds it; a process table that cannot be read refuses
/// `pane-unreadable`.
fn harness_in_pane(
    settings: &EngineSettings,
    harness: Harness,
    pane: &str,
    pane_pid: u32,
) -> Result<std::result::Result<Identity, ProcessReading>> {
    let target = Target::new(&settings.harness_binaries, harness)?;
    match observe::foreground(pane_pid, &|name| target.owns(name), None) {
        ProcessReading::Harness { identity } => Ok(Ok(identity)),
        ProcessReading::Unread { cause } => Err(Error::refused(
            "pane-unreadable",
            &[("pane", pane), ("cause", cause)],
        )),
        reading @ (ProcessReading::ShellsOnly
        | ProcessReading::HarnessUp
        | ProcessReading::ForegroundShell { .. }
        | ProcessReading::ForegroundOther { .. }) => Ok(Err(reading)),
    }
}

/// A variable of this process's environment, where it is set and not empty.
fn caller_var(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|value| !value.is_empty())
}

/// The server of the caller's own pane, the first field of `$TMUX`. An
/// adoption or a registration is made from the session's own pane, which
/// always has it: with none it refuses `tmux-missing` before it asks any
/// server, never falling back to the user's default socket.
fn caller_socket() -> Result<PathBuf> {
    caller_var("TMUX")
        .and_then(|value| value.split(',').next().map(PathBuf::from))
        .filter(|socket| !socket.as_os_str().is_empty())
        .ok_or_else(|| Error::refused("tmux-missing", &[("var", "TMUX")]))
}

/// The account a session of `harness` runs on whose home variable reads
/// `home`: that home, else the harness's default home; a Codex home a
/// folder-trust launch built under an account names that account.
fn account_of_home(harness: Harness, home: Option<String>) -> Option<String> {
    let home = home
        .map(PathBuf::from)
        .or_else(|| session::default_home(harness))?;
    let account = match harness {
        Harness::Codex => crate::trust::account_of(&home).to_path_buf(),
        Harness::Claude | Harness::Copilot | Harness::Pi => home,
    };
    Some(account.display().to_string())
}

/// A file of process `pid`'s `/proc` entry as its NUL-separated words: the
/// environment the process was started with, or its argument words. `Err`
/// names why it could not be read: a host with no `/proc`, or the process
/// gone.
fn proc_words(pid: u32, file: &str) -> std::result::Result<Vec<String>, &'static str> {
    let bytes = match std::fs::read(format!("/proc/{pid}/{file}")) {
        Ok(bytes) => bytes,
        // A host with no `/proc` has no entry for a live process either.
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Err(if Path::new("/proc/self").exists() {
                "process-gone"
            } else {
                "proc-absent"
            });
        }
        Err(_) => return Err("proc-unreadable"),
    };
    Ok(bytes
        .split(|byte| *byte == 0)
        .filter(|word| !word.is_empty())
        .map(|word| String::from_utf8_lossy(word).into_owned())
        .collect())
}

/// The value `name` holds in the environment process `pid` was started
/// with, `None` where it holds none or an empty one.
pub fn process_var(pid: u32, name: &str) -> std::result::Result<Option<String>, &'static str> {
    Ok(proc_words(pid, "environ")?.into_iter().find_map(|entry| {
        entry
            .strip_prefix(name)
            .and_then(|rest| rest.strip_prefix('='))
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
    }))
}

/// The launch choices a running session's argument words spell for its
/// harness, read with the harness's own word table: the model after its
/// model flag, the effort its effort words carry, the full bypass where a
/// full-bypass spelling stands (else the native posture), and the
/// permission spelling's words, the one part of the line orch carries as
/// the session's own; every other word is the builder's or of an arity no
/// table states.
#[derive(Debug, PartialEq, Eq)]
struct Spelled {
    model: Option<String>,
    effort: Option<String>,
    permission: Permission,
    words: Vec<String>,
}

fn spelled(harness: Harness, argv: &[String]) -> Spelled {
    // Every value `flag` takes in `argv`, as the next word or after `=`.
    let values = |flag: &str| -> Vec<String> {
        argv.iter()
            .enumerate()
            .filter_map(|(i, word)| {
                if word == flag {
                    return argv.get(i + 1).cloned();
                }
                word.strip_prefix(flag)
                    .and_then(|rest| rest.strip_prefix('='))
                    .map(str::to_owned)
            })
            .collect()
    };
    let effort = match harness.effort_words("\0").as_slice() {
        [flag, value] => value.split_once('\0').and_then(|(before, after)| {
            values(flag).into_iter().find_map(|v| {
                v.strip_prefix(before)
                    .and_then(|v| v.strip_suffix(after))
                    .map(|v| v.trim_matches('"').to_owned())
            })
        }),
        _ => None,
    };
    Spelled {
        model: values(harness.model_flag()).into_iter().next(),
        effort,
        permission: posture_of(harness, argv),
        words: harness
            .permission_word_in(argv)
            .map(|(spelling, _)| spelling.split_whitespace().map(str::to_owned).collect())
            .unwrap_or_default(),
    }
}

/// The posture `words` spell for `harness`: the full bypass where a
/// full-bypass spelling stands, else the native posture.
fn posture_of(harness: Harness, words: &[String]) -> Permission {
    match harness.bypass_word_in(words) {
        Some(_) => Permission::Bypass,
        None => Permission::Native,
    }
}

/// The posture and permission words a request states, from its one half
/// where it names only one, so the record never pairs a posture with words
/// the builder refuses beside it (`permission-mismatch`): named words
/// spell the posture ([`posture_of`]), a named posture carries no words
/// but those named. `None` where it names neither.
fn stated_posture(harness: Harness, r: &AdoptController) -> Option<(Permission, Vec<String>)> {
    match (r.permission, &r.extra_args) {
        (Some(permission), words) => Some((permission, words.clone().unwrap_or_default())),
        (None, Some(words)) => Some((posture_of(harness, words), words.clone())),
        (None, None) => None,
    }
}

/// The posture the harness process `pid` was launched under and its own
/// permission words, as its argument words spell them; `None` where they
/// cannot be read, as on a host with no `/proc`.
fn launched_posture(harness: Harness, pid: u32) -> Option<(Permission, Vec<String>)> {
    let argv = proc_words(pid, "cmdline").ok()?;
    let spelled = spelled(harness, &argv);
    Some((spelled.permission, spelled.words))
}

/// The posture and words an adoption records, `None` keeping the record's:
/// the pair its request states, else under [`Unnamed::Launched`] the pair
/// `launched` reads off the harness's launch. Where those words cannot be
/// read, a `recorded` record that already names the pane (`same`), whose
/// harness pid and start are `identity`, the process read in it, and that
/// names a permission keeps its posture, as a heal does, since nothing read
/// contradicts it; any other takes the harness's native defaults with no
/// words, since nobody chose the launch setting's posture, a full bypass by
/// default, for a session they started by hand, and a record with no
/// permission would hand its successor exactly that setting.
fn adopted_posture(
    stated: Option<(Permission, Vec<String>)>,
    unnamed: Unnamed,
    launched: impl FnOnce() -> Option<(Permission, Vec<String>)>,
    same: bool,
    recorded: Option<&Overseer>,
    identity: &Identity,
) -> Option<(Permission, Vec<String>)> {
    let recorded_process = || {
        same && recorded.is_some_and(|recorded| {
            views::permission(recorded.extra.get("permission")).is_some()
                && predecessor_identity(recorded).is_some_and(|prior| prior == *identity)
        })
    };
    match (stated, unnamed) {
        (Some(pair), _) => Some(pair),
        (None, Unnamed::Kept) => None,
        (None, Unnamed::Launched) => match launched() {
            Some(pair) => Some(pair),
            None if recorded_process() => None,
            None => Some((Permission::Native, Vec::new())),
        },
    }
}

/// Register the controller a person opened by hand in the caller's own
/// pane, `$TMUX_PANE` on the server `$TMUX` names: its launch identity from
/// the last `SessionStart` row its harness wrote to the rows file the hook
/// keeps for that pane, else read off the pane, the named fallback said as
/// `identity-fallback` (the harness its foreground process is, the
/// directory it runs in); then what the running harness process itself was
/// started with, so the next hand-over launches the session that runs: the
/// account its environment names, ahead of the row's, and the model and
/// effort its argument words spell, the row's model first
/// (`launch-unread` where that process cannot be read, the row and the
/// caller's own environment standing in); `account` ahead of every reading.
/// Then the one adoption, which reads the permission posture and writes the
/// rows file as the record's `session_rows`. Answers the reply with the harness it registered.
pub fn register_controller(
    path: &Path,
    account: Option<&str>,
    settings: &EngineSettings,
    root: &Path,
    locking: Locking,
) -> Result<(Value, Harness)> {
    let pane = caller_var("TMUX_PANE")
        .ok_or_else(|| Error::refused("tmux-missing", &[("var", "TMUX_PANE")]))?;
    if !is_pane_id(&pane) {
        return Err(Error::refused("pane-invalid", &[("pane", &pane)]));
    }
    let socket = caller_socket()?;
    let server = tmux::server(&socket)?;
    let fields = pane_read(&server, &pane)?;
    let rows = root.join("tmp/lane-mail/overseer").join(format!(
        "session-{}-{}.jsonl",
        server.pid,
        pane.trim_start_matches('%')
    ));
    let given = account.map(str::to_owned);
    let mut notices = Vec::new();
    let stated = match start_row(&rows) {
        Reading::Live(row) => Ok(row),
        Reading::Gone => Err("no-start-row"),
        Reading::Unreadable { .. } => Err("unreadable"),
    };
    let (harness, identity, row_account, row_model, cwd) = match stated {
        Ok(row) => {
            let harness = Harness::named(&row.harness)?;
            let identity =
                harness_in_pane(settings, harness, &pane, fields.pid)?.map_err(|reading| {
                    Error::PaneNotHarness {
                        pane: pane.clone(),
                        reading: reading_word(&reading),
                    }
                })?;
            (harness, identity, row.account, row.model, row.cwd)
        }
        Err(cause) => {
            notices.push(format!("identity-fallback session={pane} cause={cause}"));
            let (harness, identity) = foreground_harness(settings, &pane, fields.pid)?;
            let cwd = std::fs::read_link(format!("/proc/{}/cwd", identity.pid))
                .or_else(|_| std::env::current_dir())
                .map_err(|e| Error::io("cwd", Path::new("."), e))?;
            (harness, identity, None, None, cwd.display().to_string())
        }
    };
    // The process's own environment and words where the host keeps them;
    // where it does not, the row and the caller's own environment, which the
    // harness's shell tool handed down, stand in.
    // The model is read first: the account a session spends is the variable
    // its model routes it through, which for a Pi session on a Claude seat
    // is not the variable its own home is under.
    let words = proc_words(identity.pid, "cmdline").map(|argv| spelled(harness, &argv));
    let model = row_model.or_else(|| words.as_ref().ok().and_then(|s| s.model.clone()));
    let seat = harness.account_var(model.as_deref());
    let started = words.and_then(|spelled| {
        Ok((
            process_var(identity.pid, harness.home_var())?,
            process_var(identity.pid, seat)?,
            spelled,
        ))
    });
    let (home_var, seat_var, spelled, stated_account) = match started {
        Ok((home, seat, spelled)) => (home, seat, Some(spelled), None),
        Err(cause) => {
            notices.push(format!("launch-unread session={pane} cause={cause}"));
            // The process's `/proc` files did not read, as on a host with no
            // `/proc`. A start row's account is its harness's own root, which
            // is the seat only where the model bills through the harness's
            // home variable.
            (
                caller_var(harness.home_var()),
                caller_var(seat),
                None,
                row_account.filter(|_| seat == harness.home_var()),
            )
        }
    };
    let seat_harness = Harness::ALL
        .into_iter()
        .find(|h| h.home_var() == seat)
        .unwrap_or(harness);
    let account = given
        .or(stated_account)
        .or_else(|| account_of_home(seat_harness, seat_var));
    // The Claude home this registration read, the caller's environment
    // standing in where the process's did not read.
    let registered = match harness {
        Harness::Claude => claude_home(
            home_var.clone(),
            caller_var("HOME").as_deref().map(Path::new),
        ),
        Harness::Codex | Harness::Copilot | Harness::Pi => None,
    };
    let home = match harness {
        Harness::Codex => home_var.or_else(|| account.clone()),
        Harness::Claude | Harness::Copilot | Harness::Pi if seat == harness.home_var() => {
            account.clone()
        }
        Harness::Claude | Harness::Copilot | Harness::Pi => home_var
            .or_else(|| session::default_home(harness).map(|home| home.display().to_string())),
    };
    let effort = spelled.and_then(|s| s.effort);
    let request = AdoptController {
        pane: pane.clone(),
        socket: Some(socket),
        harness: harness.name().to_owned(),
        session_id: None,
        account: account.clone(),
        home,
        model,
        effort,
        cwd: Some(cwd),
        session_rows: Some(rows),
        permission: None,
        extra_args: None,
    };
    let adopted = adopt_on(
        path,
        &request,
        None,
        Unnamed::Launched,
        registered,
        settings,
        locking,
    )?;
    Ok((
        json!({
            "adopted": adopted,
            "pane": pane,
            "window": fields.pane.window,
            "server": server.pid,
            "account": account,
            "notices": notices,
        }),
        harness,
    ))
}

/// The file the harness holds the session `id` for `cwd` in under `home`,
/// found by that id and read three-valued: absent is a session the home
/// never held, unreadable is a store that could not be listed.
pub fn fixed_id_file(harness: Harness, home: &Path, cwd: &Path, id: &str) -> Reading<PathBuf> {
    session::fixed_id_file(harness, home, cwd, id)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A window opens in the session the opener's request names, over the
    /// setting's, over the opener's fallback (a lane's fleet record's, a
    /// controller's predecessor's); with none named,
    /// `tmux-session-unresolved`.
    #[test]
    fn the_requests_session_comes_before_the_settings_before_the_openers_fallback() {
        let named = Some("asked");
        let setting = Some("set");
        let fallback = Some("predecessor");
        assert_eq!(session_of(named, setting, fallback).unwrap(), "asked");
        assert_eq!(session_of(None, setting, fallback).unwrap(), "set");
        assert_eq!(session_of(None, None, fallback).unwrap(), "predecessor");
        let err = session_of(None, None, None).unwrap_err();
        assert_eq!(err.key(), "tmux-session-unresolved");
    }

    /// A Claude adoption records the process's own home and mode where the
    /// request names no path or the same one, so a named `$HOME/.claude` and
    /// the implicit default stay apart; a path the process does not run on
    /// is named. Where the process's environment is unread, as on a host
    /// with no `/proc`, a home vouched for that process stands on the same
    /// terms; with none that agrees, no mode, and the cause.
    #[test]
    fn a_claude_adoption_records_the_home_and_mode_its_process_runs_on() {
        let kept = |home: &str, named: bool| Kept {
            home: PathBuf::from(home),
            named,
        };
        let implicit = kept("/h/.claude", false);
        let explicit = kept("/h/.claude", true);
        // `$HOME/.claude` a link to a config dir elsewhere, the caller
        // supplying the link's target.
        let root = tempfile::tempdir().unwrap();
        let target = root.path().join("data").join("claude");
        std::fs::create_dir_all(&target).unwrap();
        let linked_home = root.path().join("home");
        std::fs::create_dir_all(&linked_home).unwrap();
        std::os::unix::fs::symlink(&target, linked_home.join(".claude")).unwrap();
        let linked = Kept {
            home: linked_home.join(".claude"),
            named: false,
        };
        type Row<'a> = (
            &'a str,
            Option<&'a str>,
            std::result::Result<Kept, &'static str>,
            Option<Kept>,
            Option<Kept>,
            Option<&'static str>,
        );
        let rows: [Row; 10] = [
            (
                "read through a link, its target named",
                target.to_str(),
                Ok(linked.clone()),
                None,
                Some(linked.clone()),
                None,
            ),
            (
                "read, none named",
                None,
                Ok(implicit.clone()),
                None,
                Some(implicit.clone()),
                None,
            ),
            (
                "read, its default path named",
                Some("/h/.claude"),
                Ok(implicit.clone()),
                None,
                Some(implicit.clone()),
                None,
            ),
            (
                "read named, the same path named",
                Some("/h/.claude/"),
                Ok(explicit.clone()),
                None,
                Some(explicit.clone()),
                None,
            ),
            (
                "read, another path named",
                Some("/x"),
                Ok(implicit.clone()),
                Some(implicit.clone()),
                Some(kept("/x", true)),
                None,
            ),
            (
                "unread, vouched, none named",
                None,
                Err("proc-absent"),
                Some(implicit.clone()),
                Some(implicit.clone()),
                None,
            ),
            (
                "unread, vouched, its path named",
                Some("/h/.claude"),
                Err("proc-absent"),
                Some(implicit.clone()),
                Some(implicit.clone()),
                None,
            ),
            (
                "unread, vouched, another path named",
                Some("/x"),
                Err("proc-absent"),
                Some(implicit.clone()),
                None,
                Some("proc-absent"),
            ),
            (
                "unread, a path named",
                Some("/h/.claude"),
                Err("proc-absent"),
                None,
                None,
                Some("proc-absent"),
            ),
            (
                "unread, nothing named",
                None,
                Err("proc-absent"),
                None,
                None,
                Some("proc-absent"),
            ),
        ];
        for (case, supplied, observed, vouched, home, cause) in rows {
            assert_eq!(
                adopted_home(supplied, observed, vouched),
                (home, cause),
                "{case}"
            );
        }
    }

    /// Where a process's environment is unread, the home vouched for it is
    /// the one its registration read from the caller's environment, else
    /// the record's where that record is this process's: a heal of the pane
    /// it names, or the identity it records. A replacement in the same
    /// pane, another pane's record and a record with no mode vouch nothing,
    /// so a replaced process's mode never carries over.
    #[test]
    fn a_home_is_vouched_only_for_the_process_its_reading_was_of() {
        let id = |start: &str| Identity {
            pid: 4242,
            start: start.to_owned(),
        };
        let implicit = Kept {
            home: PathBuf::from("/h/.claude"),
            named: false,
        };
        let record = |mode: Value| -> Overseer {
            serde_json::from_value(json!({
                "home": "/h/.claude",
                "home_implicit": mode,
                "harness_pid": 4242,
                "harness_start": "ticks:100",
            }))
            .unwrap()
        };
        let moded = record(json!(true));
        let unmoded = record(Value::Null);
        type Row<'a> = (
            &'a str,
            Option<Kept>,
            Option<&'a Overseer>,
            bool,
            Unnamed,
            Identity,
            Option<Kept>,
        );
        let rows: [Row; 8] = [
            (
                "a heal of the pane the record names",
                None,
                Some(&moded),
                true,
                Unnamed::Kept,
                id("ticks:200"),
                Some(implicit.clone()),
            ),
            (
                "the process the record names",
                None,
                Some(&moded),
                true,
                Unnamed::Launched,
                id("ticks:100"),
                Some(implicit.clone()),
            ),
            (
                "a replacement in the same pane",
                None,
                Some(&moded),
                true,
                Unnamed::Launched,
                id("ticks:200"),
                None,
            ),
            (
                "another pane's record",
                None,
                Some(&moded),
                false,
                Unnamed::Launched,
                id("ticks:100"),
                None,
            ),
            (
                "another pane's record, healed",
                None,
                Some(&moded),
                false,
                Unnamed::Kept,
                id("ticks:100"),
                None,
            ),
            (
                "a record with no mode",
                None,
                Some(&unmoded),
                true,
                Unnamed::Launched,
                id("ticks:100"),
                None,
            ),
            (
                "no record",
                None,
                None,
                false,
                Unnamed::Launched,
                id("ticks:100"),
                None,
            ),
            (
                "a registration's reading, over a replaced process's record",
                claude_home(Some("/c".to_owned()), Some(Path::new("/h"))),
                Some(&moded),
                true,
                Unnamed::Launched,
                id("ticks:200"),
                Some(Kept {
                    home: PathBuf::from("/c"),
                    named: true,
                }),
            ),
        ];
        for (case, registered, overseer, same, unnamed, identity, expected) in rows {
            assert_eq!(
                vouched_home(registered, overseer, same, unnamed, &identity),
                expected,
                "{case}"
            );
        }
        // A registration on a host with no `/proc` reads the caller's
        // `HOME` with no config dir named: that implicit default is what
        // the adoption records for a request naming its path.
        let registered = claude_home(None, Some(Path::new("/h")));
        assert_eq!(
            adopted_home(
                Some("/h/.claude"),
                Err("proc-absent"),
                vouched_home(registered, None, false, Unnamed::Launched, &id("ticks:100")),
            ),
            (Some(implicit), None)
        );
    }

    /// An adoption request states its posture and words as one pair: named
    /// words spell the posture, a named posture carries only the words
    /// named, and a request naming neither states none.
    #[test]
    fn an_adoption_request_states_its_posture_and_words_as_one_pair() {
        type Row<'a> = (
            Option<Permission>,
            Option<&'a [&'a str]>,
            Option<(Permission, &'a [&'a str])>,
        );
        let words = |w: &[&str]| w.iter().map(|w| (*w).to_owned()).collect::<Vec<_>>();
        let bypass: &[&str] = &["--dangerously-skip-permissions"];
        let narrow: &[&str] = &["--permission-mode", "dontAsk"];
        let rows: [Row; 7] = [
            (None, None, None),
            (None, Some(bypass), Some((Permission::Bypass, bypass))),
            (None, Some(narrow), Some((Permission::Native, narrow))),
            (None, Some(&[]), Some((Permission::Native, &[]))),
            (
                Some(Permission::Native),
                None,
                Some((Permission::Native, &[])),
            ),
            (
                Some(Permission::Bypass),
                None,
                Some((Permission::Bypass, &[])),
            ),
            (
                Some(Permission::Native),
                Some(narrow),
                Some((Permission::Native, narrow)),
            ),
        ];
        for (permission, extra_args, stated) in rows {
            let request = AdoptController {
                pane: "%1".to_owned(),
                socket: None,
                harness: "claude".to_owned(),
                session_id: None,
                account: None,
                home: None,
                model: None,
                effort: None,
                cwd: None,
                session_rows: None,
                permission,
                extra_args: extra_args.map(words),
            };
            assert_eq!(
                stated_posture(Harness::Claude, &request),
                stated.map(|(p, w)| (p, words(w))),
                "{permission:?} {extra_args:?}"
            );
        }
    }

    /// An adoption naming no posture whose harness's launch words cannot be
    /// read keeps the posture recorded for that same pane and process,
    /// a full bypass included, and gives any other process its harness's
    /// native defaults with no words: a respawn in the pane, another pane,
    /// a record with no harness identity, a record with no permission.
    #[test]
    fn unreadable_launch_words_keep_the_recorded_process_posture_and_default_any_other() {
        let read = Identity {
            pid: 4242,
            start: "ticks:100".to_owned(),
        };
        let record = |extra: Value| -> Overseer {
            let mut fields = json!({
                "generation": 1,
                "permission": "bypass",
                "extra_args": ["--dangerously-skip-permissions"],
            });
            let fields_map = fields.as_object_mut().unwrap();
            for (key, value) in extra.as_object().unwrap() {
                // A null member leaves the field out, as a record written
                // before the field existed does.
                match value {
                    Value::Null => fields_map.remove(key),
                    _ => fields_map.insert(key.clone(), value.clone()),
                };
            }
            serde_json::from_value(fields).unwrap()
        };
        let native = Some((Permission::Native, Vec::new()));
        let rows = [
            (
                "same pane, pid and start",
                true,
                json!({"harness_pid": 4242, "harness_start": "ticks:100"}),
                None,
            ),
            (
                "same pane and pid, respawned start",
                true,
                json!({"harness_pid": 4242, "harness_start": "ticks:200"}),
                native.clone(),
            ),
            (
                "another pane, same pid and start",
                false,
                json!({"harness_pid": 4242, "harness_start": "ticks:100"}),
                native.clone(),
            ),
            (
                "same pane, no harness pid",
                true,
                json!({"harness_start": "ticks:100"}),
                native.clone(),
            ),
            (
                "same pane, pid and start, record with no permission",
                true,
                json!({
                    "harness_pid": 4242,
                    "harness_start": "ticks:100",
                    "permission": null,
                    "extra_args": null,
                }),
                native.clone(),
            ),
        ];
        for (case, same, extra, expected) in rows {
            let recorded = record(extra);
            assert_eq!(
                adopted_posture(
                    None,
                    Unnamed::Launched,
                    || None,
                    same,
                    Some(&recorded),
                    &read,
                ),
                expected,
                "{case}"
            );
        }
    }

    /// The words each harness spells its launch choices with, as its own
    /// launch writes them and as a person types them by hand.
    #[test]
    fn a_running_sessions_words_spell_its_model_effort_and_posture() {
        type Row<'a> = (
            Harness,
            &'a [&'a str],
            Option<&'a str>,
            Option<&'a str>,
            Permission,
            &'a [&'a str],
        );
        let words = |w: &[&str]| w.iter().map(|w| (*w).to_owned()).collect::<Vec<_>>();
        let rows: [Row; 6] = [
            (
                Harness::Claude,
                &[
                    "claude",
                    "--model",
                    "opus",
                    "--effort",
                    "high",
                    "--permission-mode",
                    "dontAsk",
                    "Read the handoff",
                ],
                Some("opus"),
                Some("high"),
                Permission::Native,
                &["--permission-mode", "dontAsk"],
            ),
            (
                Harness::Claude,
                &[
                    "node",
                    "/opt/claude/cli.js",
                    "--dangerously-skip-permissions",
                    "--model=fable",
                ],
                Some("fable"),
                None,
                Permission::Bypass,
                &["--dangerously-skip-permissions"],
            ),
            (
                Harness::Codex,
                &[
                    "codex",
                    "-m",
                    "gpt-5",
                    "-c",
                    "check_for_update_on_startup=false",
                    "-c",
                    "model_reasoning_effort=xhigh",
                    "--dangerously-bypass-approvals-and-sandbox",
                ],
                Some("gpt-5"),
                Some("xhigh"),
                Permission::Bypass,
                &["--dangerously-bypass-approvals-and-sandbox"],
            ),
            (
                Harness::Copilot,
                &[
                    "node",
                    "/opt/copilot/index.js",
                    "--model",
                    "gpt-5",
                    "--reasoning-effort",
                    "low",
                    "--allow-all-tools",
                ],
                Some("gpt-5"),
                Some("low"),
                Permission::Native,
                &["--allow-all-tools"],
            ),
            (
                Harness::Pi,
                &["pi", "--model", "anthropic/claude-opus-5-5:high"],
                Some("anthropic/claude-opus-5-5:high"),
                None,
                Permission::Native,
                &[],
            ),
            (Harness::Claude, &[], None, None, Permission::Native, &[]),
        ];
        for (harness, argv, model, effort, permission, kept) in rows {
            assert_eq!(
                spelled(harness, &words(argv)),
                Spelled {
                    model: model.map(str::to_owned),
                    effort: effort.map(str::to_owned),
                    permission,
                    words: words(kept),
                },
                "{harness:?} {argv:?}"
            );
        }
    }
}
