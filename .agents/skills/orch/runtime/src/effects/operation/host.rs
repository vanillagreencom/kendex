//! The handle's host methods: every read, signal and close of a process, a
//! pane, a window or a session store, and the controller's terminal proof.
//! A read that settles a recorded handle discharges it by that read; an
//! acting method takes a [`Standing`] token, writes `signalled` before it
//! acts and discharges the token's key by its own answer.

use agent_runtime::controller::Overseer;
use agent_runtime::record::Locking;
use agent_runtime::settings::EngineSettings;
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::harness::Harness;
use agent_runtime::host::tmux;
use agent_runtime::launch::Permission;
use agent_runtime::observe::{self, ProcessReading, State};
use agent_runtime::process::{self, Identity, Stop};
use agent_runtime::reading::Reading;
use agent_runtime::session;
use serde_json::{Value, json};

use super::obligations::{Discharge, PaneEnd, PaneRef, ProcessEnd, Standing};
use super::{
    Close, Operation, POLL, Pane, Server, Target, fleet_view, overseer_target_of, pid_value,
    predecessor_identity, refused,
};
use crate::error::{Error, Result};
use crate::ops::accounts::usage::Credential;
use crate::ops::{self, AdoptController, AdoptionRead, ControllerAdopted};
use crate::state::Intent;
use agent_runtime::intent::{BoundSession, Obligation, OpenedPane, Phase, Role};

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
/// the adoption's pane read, what [`crate::ops::apply_adoption`] takes.
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
/// unobservable. A record carrying the pid alone is read by that pid.
pub fn unanswering(server: u64, process_start: Option<&str>) -> Observed<Pane> {
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
    let server = match tmux::server(Path::new(&opened.socket)) {
        Ok(server) => server,
        Err(_) => return unanswering(opened.server, opened.server_process_start.as_deref()),
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
    let answering = sockets
        .iter()
        .find_map(|socket| match tmux::server(socket) {
            Ok(s) if s.pid as u64 == server_pid => Some(s),
            Ok(_) | Err(_) => None,
        });
    match answering {
        Some(server) if server_start.is_none_or(|st| st == server.start) => {
            Observed::Present(server)
        }
        Some(_) => Observed::Gone {
            cause: "server-unmatched",
        },
        None => match unanswering(server_pid, None) {
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

/// The socket the controller record names, else the ambient one, which an
/// unread uid refuses.
fn controller_socket(overseer: &Overseer) -> agent_runtime::Result<PathBuf> {
    overseer_socket(overseer).map_or_else(tmux::ambient_socket, Ok)
}

/// The proof for a predecessor whose record carries no identity:
/// `exit.run.generation` equal to the record's generation, else the recorded
/// pane read gone by exact id on the server the record names at its recorded
/// pid and start, kept there dead after its process exited, or read there
/// holding no harness by the names of `target`,
/// the recorded harness. Another server on that socket, no server, or a
/// record naming no server, start or pane proves nothing; with no recorded
/// harness a listed pane stands, since nothing names what would run in it.
pub(super) fn proof_of(overseer: &Overseer, target: Option<&Target>) -> Proof {
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
    match controller_socket(overseer).and_then(|socket| tmux::server(&socket)) {
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
        Err(_) => match unanswering(server, None) {
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

/// The sign-in a launch starts with, as `Operation::sign_in` reads it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SignIn {
    /// The account holds a credential the harness signs in with.
    Held,
    /// The launch environment carries this token variable.
    Token(&'static str),
    /// The account holds nothing the harness signs in with.
    Missing { cause: &'static str },
    /// Nothing here reads this sign-in: the first turn alone judges it.
    Unjudged { cause: &'static str },
}

/// The file the harness records the session `id` for `cwd` in under `home`,
/// for a harness whose launch fixes the id.
pub fn fixed_file(harness: Harness, home: &Path, cwd: &Path, id: &str) -> Option<PathBuf> {
    session::fixed_file(harness, home, cwd, id)
}

/// `check` read on the one clock until it answers or `bound` passes,
/// `poll` between reads: `None` at the bound.
pub fn poll_until<T>(
    clock: &dyn agent_runtime::clock::Clock,
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

/// Whether `pane_id` on `server` is one tmux may name: `%` then digits.
fn is_pane_id(id: &str) -> bool {
    id.strip_prefix('%')
        .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
}

impl Operation<'_> {
    /// The session a fleet window opens in: the one the settings name, else
    /// the fleet record's `tmux.session`.
    pub fn fleet_session(&self, doc_session: Option<&str>) -> Result<String> {
        self.run
            .settings
            .tmux_session
            .as_deref()
            .or(doc_session)
            .map(str::to_owned)
            .ok_or_else(|| {
                Error::from(agent_runtime::Error::refused(
                    "tmux-session-unresolved",
                    &[],
                ))
            })
    }

    /// The tmux server a fleet window opens on and the session it opens in:
    /// the socket the runtime's own `$TMUX` names or the user's default, as
    /// `lib/tmux-server.sh` resolves it, and the session the settings name,
    /// else the fleet record's `tmux.session`.
    pub fn fleet_server(&self, doc_session: Option<&str>) -> Result<(Server, String)> {
        let session = self.fleet_session(doc_session)?;
        let socket = tmux::ambient_socket()?;
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

    /// The server's own process identity, read live before a window opens on
    /// it, so a socket that stops answering can later be told from a server
    /// that is gone.
    pub fn server_process_start(
        &self,
        server: &Server,
    ) -> std::result::Result<String, agent_runtime::Error> {
        match process::identity(server.pid) {
            Reading::Live(identity) => Ok(identity.start),
            Reading::Gone => Err(agent_runtime::Error::refused(
                "server-gone",
                &[("pid", &server.pid.to_string())],
            )),
            Reading::Unreadable { cause } => Err(agent_runtime::Error::refused(
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
        let now = self
            .clock
            .wall()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_secs());
        agent_runtime::clock::iso_utc(now + after.as_secs())
    }

    /// The sign-in a successor's launch on `account` starts with, read
    /// before anything is written for it: a token variable the window on
    /// `server` inherits in `session`, which signs the harness in whatever
    /// the account holds; else the credential file the account listing
    /// reads (`ops::accounts::usage`), Claude's on Linux alone, since
    /// another platform keeps it in its own store.
    pub fn sign_in(
        &self,
        server: &Server,
        session: &str,
        harness: Harness,
        account: &Path,
    ) -> SignIn {
        let tokens: &[&'static str] = match harness {
            Harness::Claude => &["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY"],
            Harness::Codex => &["OPENAI_API_KEY"],
            Harness::Copilot | Harness::Pi => {
                return SignIn::Unjudged {
                    cause: "harness-unread",
                };
            }
        };
        // An environment that cannot be read may hold a token: no account
        // is refused on a read that did not answer.
        for token in tokens {
            match tmux::inherited(server, session, token) {
                Ok(Some(value)) if !value.is_empty() => return SignIn::Token(token),
                Ok(_) => {}
                Err(_) => {
                    return SignIn::Unjudged {
                        cause: "environment-unread",
                    };
                }
            }
        }
        if harness == Harness::Claude && !cfg!(target_os = "linux") {
            return SignIn::Unjudged {
                cause: "platform-store",
            };
        }
        let dir = account.display().to_string();
        match crate::ops::accounts::usage::credential(harness.name(), &dir) {
            Credential::Missing(_) => SignIn::Missing {
                cause: "no-credential",
            },
            Credential::NoToken { .. } => SignIn::Missing { cause: "no-token" },
            Credential::Invalid(_) => SignIn::Unjudged {
                cause: "credential-invalid",
            },
            Credential::Token {
                refresh_expires_ms, ..
            } => {
                let now = self
                    .clock
                    .wall()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map_or(0, |d| d.as_secs());
                if crate::ops::accounts::usage::expired(refresh_expires_ms, now) {
                    SignIn::Missing {
                        cause: "login-expired",
                    }
                } else {
                    SignIn::Held
                }
            }
        }
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
    ) -> std::result::Result<(), agent_runtime::Error> {
        if self
            .obligations
            .stands(&Obligation::Process(token.key().clone()))
        {
            return Ok(());
        }
        Err(agent_runtime::Error::refused(
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
    fn check_pane_token(
        &self,
        token: &Standing<Pane>,
    ) -> std::result::Result<(), agent_runtime::Error> {
        if self.key_of(token.key()).is_some() {
            return Ok(());
        }
        Err(agent_runtime::Error::refused(
            "token-stale",
            &[
                ("intent", &self.intent_id),
                ("cause", "not-standing"),
                ("pane", &token.key().id),
            ],
        ))
    }

    /// The sockets a standing pane or window key may answer on: the phase's,
    /// the overseer record's and the caller's ambient one, each once.
    fn sockets(&self, overseer: Option<&Overseer>) -> Vec<PathBuf> {
        let mut sockets: Vec<PathBuf> = Vec::new();
        let mut push = |socket: PathBuf| {
            if !sockets.contains(&socket) {
                sockets.push(socket);
            }
        };
        match &self.phase {
            Some(agent_runtime::intent::Phase::Opening { opening }) => {
                push(PathBuf::from(&opening.socket))
            }
            Some(
                agent_runtime::intent::Phase::WindowOpened { opened }
                | agent_runtime::intent::Phase::Delivering { opened, .. }
                | agent_runtime::intent::Phase::Delivered { opened, .. }
                | agent_runtime::intent::Phase::IdentityRead { opened, .. },
            ) => push(PathBuf::from(&opened.socket)),
            Some(
                agent_runtime::intent::Phase::CloudCreate { .. }
                | agent_runtime::intent::Phase::Preparing { .. },
            )
            | None => {}
        }
        // A socket that cannot be named is no candidate: a key no socket
        // answers for is read by its server's pid.
        for socket in fleet_sockets(
            overseer.and_then(overseer_socket),
            tmux::ambient_socket().ok(),
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
    pub fn observe_lane_pane(
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

    /// One reading of a pane: who holds its terminal, written before the
    /// capture, and what the screen says. With `recorded`, only that identity
    /// is the harness. The pane gone discharges the pane; a host that does
    /// not answer for a pane that stands is `Unreadable`, never an absence.
    pub fn read_pane(
        &mut self,
        pane: &Pane,
        harness: Harness,
        owns: &dyn Fn(&str) -> bool,
        recorded: Option<&Identity>,
    ) -> Result<Reading<(Foreground, State)>> {
        let fields = match tmux::pane_fields(&pane.server, &pane.id) {
            Reading::Live(fields) => fields,
            Reading::Gone => {
                self.pane_end(pane, PaneEnd::Gone)?;
                return Ok(Reading::Gone);
            }
            Reading::Unreadable { cause } => return Ok(Reading::Unreadable { cause }),
        };
        let foreground = self.foreground_of(fields.pid, owns, recorded)?;
        let screen = match tmux::capture(pane) {
            Ok(screen) => screen,
            // The pane may have gone between the read and the capture: a
            // harness exit. One that still stands was not captured.
            Err(_) => {
                return Ok(match tmux::pane_fields(&pane.server, &pane.id) {
                    Reading::Live(_) => Reading::Unreadable {
                        cause: "capture-failed",
                    },
                    Reading::Gone => {
                        self.pane_end(pane, PaneEnd::Gone)?;
                        Reading::Gone
                    }
                    Reading::Unreadable { cause } => Reading::Unreadable { cause },
                });
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
    pub fn keep_pane(
        &self,
        pane: &Standing<Pane>,
    ) -> std::result::Result<(), agent_runtime::Error> {
        self.check_pane_token(pane)?;
        tmux::keep_on_exit(pane.key())
    }

    /// Close the window of the set's standing pane on the server
    /// [`Self::observe_lane_pane`] reads it on: one
    /// present is killed by its token; one gone stands no more; none standing
    /// is no window to close; one the host did not answer for stands with
    /// that cause.
    pub fn close_lane_window(&mut self, overseer: Option<&Overseer>) -> Result<WindowClose> {
        Ok(match self.observe_lane_pane(overseer)? {
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
        let observed = match controller_socket(overseer).and_then(|socket| tmux::server(&socket)) {
            Ok(server) if server.pid as u64 == key.server && server.start == server_start => {
                observe_fields(&server, &key.pane)
            }
            Ok(_) => Observed::Gone {
                cause: "server-replaced",
            },
            Err(_) => unanswering(key.server, None),
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
        let proof = proof_of(overseer, target.as_ref());
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
            Reading::Unreadable { cause } => Err(agent_runtime::Error::refused(
                "baseline-unreadable",
                &[("cause", cause)],
            )
            .into()),
        }
    }

    /// The one lead session for `cwd` under `home` that appeared since the
    /// window opened and stood in no baseline before it: a neighbour in the
    /// same home and directory is never a candidate. A set read whole or not
    /// at all; an unread candidate binds nothing and names its cause. A
    /// harness ready at its composer may write its session moments later
    /// (Codex its rollout, Copilot its first event), so none found is read
    /// again within the launch bound before it binds nothing.
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
    Unsent(agent_runtime::Error),
    Unanswered(agent_runtime::Error),
}

/// Read the pane an adoption names and record the controller in it: the
/// harness identity in the pane's foreground, through the one judge,
/// never the caller's word for it. A record naming
/// another session refuses `overseer-live` while that session's identity
/// reads live, or its pane stands on the proven server holding anything
/// but shells with no identity recorded; one it cannot read refuses
/// `overseer-unreadable`; one nothing
/// resolves refuses `predecessor-unproven`. The one
/// read-then-record operation of the fleet: no intent, so no
/// handle, and nothing it reads is an obligation.
pub fn adopt_controller(
    path: &Path,
    r: &AdoptController,
    settings: &EngineSettings,
    locking: Locking,
) -> Result<ControllerAdopted> {
    let overseer = fleet_view(path)?.overseer;
    let harness = Harness::named(&r.harness)?;
    if !is_pane_id(&r.pane) {
        return Err(refused("pane-invalid", &[("pane", &r.pane)]));
    }
    let socket = match &r.socket {
        Some(socket) => socket.clone(),
        None => tmux::ambient_socket()?,
    };
    let server = tmux::server(&socket)?;
    let fields = pane_read(&server, &r.pane)?;
    let target = Target::new(&settings.harness_binaries, harness)?;
    let identity = match observe::foreground(fields.pid, &|name| target.owns(name), None) {
        ProcessReading::Harness { identity } => identity,
        ProcessReading::Unread { cause } => {
            return Err(refused(
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
    let read = Recorded {
        value: AdoptionRead {
            identity,
            server: server.pid as u64,
            server_start: server.start,
            socket: socket.display().to_string(),
            window: fields.pane.window.clone(),
            same,
        },
    };
    ops::apply_adoption(path, r, &read, locking)
}

/// Whether the record names `pane` on the server `pid` at `start`, or at
/// no start (`ol_owns`): the pane is the recorded controller's own.
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
/// turn-end hook reading its own session's id, binds it.
pub fn heal_controller(
    path: &Path,
    settings: &EngineSettings,
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
    let socket = controller_socket(&overseer)?;
    let server = tmux::server(&socket)?;
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
        succession: None,
        session_rows: word("session_rows").map(PathBuf::from),
        // The heal names no posture: the same pane keeps the recorded one.
        permission: None,
        extra_args: None,
    };
    adopt_controller(path, &request, settings, locking).map(Some)
}

/// The fields of `pane` on `server`: gone refuses `pane-gone`, a failed
/// read `pane-unreadable` with its cause.
fn pane_read(server: &tmux::Server, pane: &str) -> Result<tmux::PaneFields> {
    match tmux::pane_fields(server, pane) {
        Reading::Live(fields) => Ok(fields),
        Reading::Gone => Err(refused("pane-gone", &[("pane", pane)])),
        Reading::Unreadable { cause } => Err(refused(
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
/// directory, over the last [`agent_runtime::rows::SPAN`] such rows: `Gone`
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
    let from = starts.len().saturating_sub(agent_runtime::rows::SPAN);
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
        ProcessReading::Unread { cause } => Err(refused(
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

/// The account a session of `harness` runs on whose home variable reads
/// `home`: that home, else the harness's default home; a Codex home a
/// folder-trust launch built under an account names that account.
fn account_of_home(harness: Harness, home: Option<String>) -> Option<String> {
    let home = home
        .map(PathBuf::from)
        .or_else(|| session::default_home(harness))?;
    let account = match harness {
        Harness::Codex => agent_runtime::trust::account_of(&home).to_path_buf(),
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
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Err("process-gone"),
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
        permission: if harness.bypass_word_in(argv).is_some() {
            Permission::Bypass
        } else {
            Permission::Native
        },
        words: harness
            .permission_word_in(argv)
            .map(|(spelling, _)| spelling.split_whitespace().map(str::to_owned).collect())
            .unwrap_or_default(),
    }
}

/// Register the controller a person opened by hand in the caller's own
/// pane, `$TMUX_PANE` on the server `$TMUX` names: its launch identity from
/// the last `SessionStart` row its harness wrote to the rows file the hook
/// keeps for that pane, else read off the pane, the named fallback said as
/// `identity-fallback` (the harness its foreground process is, the
/// directory it runs in); then what the running harness process itself was
/// started with, so the next hand-over launches the session that runs: the
/// account its environment names, ahead of the row's, and the model, effort
/// and permission posture its argument words spell, the row's model first
/// (`launch-unread` where that process cannot be read, the row and the
/// caller's own environment standing in); `account` ahead of every reading.
/// Then the one adoption, which writes the rows file as the record's
/// `session_rows`. Answers the reply with the harness it registered.
pub fn register_controller(
    path: &Path,
    account: Option<&str>,
    settings: &EngineSettings,
    root: &Path,
    locking: Locking,
) -> Result<(Value, Harness)> {
    let pane =
        caller_var("TMUX_PANE").ok_or_else(|| refused("tmux-missing", &[("var", "TMUX_PANE")]))?;
    if !is_pane_id(&pane) {
        return Err(refused("pane-invalid", &[("pane", &pane)]));
    }
    let socket = tmux::ambient_socket()?;
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
                .map_err(|e| Error::Runtime(agent_runtime::Error::io("cwd", Path::new("."), e)))?;
            (harness, identity, None, None, cwd.display().to_string())
        }
    };
    // The process's own environment and words where the host keeps them;
    // where it does not, the row and the caller's own environment, which the
    // harness's shell tool handed down, stand in, and no posture is recorded.
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
    let home = match harness {
        Harness::Codex => home_var.or_else(|| account.clone()),
        Harness::Claude | Harness::Copilot | Harness::Pi if seat == harness.home_var() => {
            account.clone()
        }
        Harness::Claude | Harness::Copilot | Harness::Pi => home_var
            .or_else(|| session::default_home(harness).map(|home| home.display().to_string())),
    };
    let (effort, permission, extra_args) = match spelled {
        Some(s) => (s.effort, Some(s.permission), Some(s.words)),
        None => (None, None, None),
    };
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
        succession: None,
        session_rows: Some(rows),
        permission,
        extra_args,
    };
    let adopted = adopt_controller(path, &request, settings, locking)?;
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
