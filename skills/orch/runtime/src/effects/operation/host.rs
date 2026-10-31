//! The handle's host methods: every read, signal and close of a process, a
//! pane, a window or a session store, and the controller's terminal proof.
//! A read that settles a recorded handle discharges it by that read; an
//! acting method takes a [`Standing`] token, writes `signalled` before it
//! acts and discharges the token's key by its own answer.

use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::harness::Harness;
use agent_runtime::host::{self, tmux};
use agent_runtime::observe::{self, ProcessReading, State};
use agent_runtime::process::{self, Identity, Stop};
use agent_runtime::reading::Reading;
use agent_runtime::session;
use serde_json::{Value, json};

use super::obligations::{Discharge, PaneEnd, PaneRef, ProcessEnd, Standing, ValidationEnd};
use super::{Close, Operation, Pane, Server, WatchHandoverCall};
use crate::error::{Error, Result};
use crate::ops::{self, AdoptController, AdoptionRead, Applied};
use crate::settings::Settings;
use crate::state::{
    self, BoundSession, Intent, Lane, Locking, Obligation, OpenedPane, Overseer, Phase, Role,
    WatchHandover,
};

/// How long a CLI the close asks is given to answer.
const CLI_TIMEOUT: Duration = Duration::from_secs(60);

/// How long the watch handover owner is given to answer: it starts the
/// restart helper through job-unit and returns, or starts a watch and waits
/// for its claim, each bounded by its own stop seconds.
const WATCH_HANDOVER_TIMEOUT: Duration = Duration::from_secs(180);

/// How often a poll re-reads a process within its bound.
const POLL: Duration = Duration::from_millis(200);

/// What a recorded pane reads as on its own server: present as `P` (the
/// pane, or the standing token for it), gone with the cause (the pane by
/// exact id, or its server gone or replaced with every pane it held), or
/// unobservable with the cause (an unanswering socket whose server process
/// still runs, or a failed read).
pub(in crate::effects) enum Observed<P> {
    Unobservable { cause: &'static str },
    Gone { cause: &'static str },
    Present(P),
}

/// What closing a recorded window established; the close discharged the
/// recorded pane where it answered.
pub(in crate::effects) enum WindowClose {
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
    pub(in crate::effects) fn word(&self) -> String {
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
pub(in crate::effects) struct Stopped {
    identity: Identity,
    answer: Stop,
}

impl Stopped {
    pub(in crate::effects) fn answer(&self) -> &Stop {
        &self.answer
    }
}

/// Evidence this module's own reader produced, handed on as a token: an
/// identity this handle read and wrote into the set before returning it,
/// what [`Operation::record_identity`] and [`Operation::publish`] take; or
/// the adoption's pane read, what [`crate::ops::apply_adoption`] takes.
/// Constructible here alone, so a transition that takes one takes no
/// caller-supplied evidence (decisions 124 (1), 124i (37)).
pub(crate) struct Recorded<T> {
    value: T,
}

impl Recorded<Identity> {
    pub(in crate::effects) fn identity(&self) -> &Identity {
        &self.value
    }
}

impl Recorded<AdoptionRead> {
    /// What the pane read found, for the adoption's one transition.
    pub(crate) fn evidence(&self) -> &AdoptionRead {
        &self.value
    }

    /// A token a store test plants: the production build has no constructor
    /// outside this module.
    #[cfg(test)]
    pub(crate) fn planted(value: AdoptionRead) -> Recorded<AdoptionRead> {
        Recorded { value }
    }
}

/// Who holds a pane's terminal, through the one judge; `harness` is the
/// recorded token where the reading is a harness identity.
pub(in crate::effects) struct Foreground {
    pub reading: ProcessReading,
    pub harness: Option<Recorded<Identity>>,
}

/// What a read of a recorded process identity found: live under its
/// recorded start; gone, nothing holding its pid; another process under the
/// pid, one reading towards the stale count; or unreadable. The live reading
/// mints no acting token: a stop acquires its own from the standing set, and
/// a publication reads its identity through the acquiring poll.
pub(in crate::effects) enum ProcessRead {
    Live,
    Gone,
    Stale { other: Identity },
    Unreadable { cause: &'static str },
}

/// What proves a predecessor with no recorded identity terminal, or does
/// not.
pub(in crate::effects) enum Proof {
    /// Proven terminal `by` the generation-bound exit record or the pane
    /// gone on the proven recorded server.
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
pub(in crate::effects) enum SessionFloor {
    Fixed(String),
    Baseline(Vec<String>),
}

impl SessionFloor {
    pub(in crate::effects) fn session_id(&self) -> Option<&str> {
        match self {
            SessionFloor::Fixed(id) => Some(id),
            SessionFloor::Baseline(_) => None,
        }
    }
}

/// The runner's own native session file as the binding read it: bound, not
/// yet appeared, two or more appeared and nothing tells the runner's from
/// the others, or a store that could not be read whole.
pub(in crate::effects) enum Binding {
    Bound(BoundSession),
    Absent,
    Ambiguous(Vec<String>),
    Unreadable { cause: &'static str },
}

/// Whether the process that persisted the intent still runs under its
/// recorded start. A legacy intent carries no owner and reads `Gone`; so
/// does an owner pid outside the kernel's range.
pub(in crate::effects) fn owner(intent: &Intent) -> Reading<Identity> {
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
pub(in crate::effects) fn unanswering(server: u64, process_start: Option<&str>) -> Observed<Pane> {
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

/// The pane `id` on a server that answered, by its exact id.
pub(super) fn observe_fields(server: &Server, id: &str) -> Observed<Pane> {
    match tmux::pane_fields(server, id) {
        Reading::Live(fields) => Observed::Present(fields.pane),
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

/// The pane `key` names, on the caller's ambient server. A legacy lane
/// record names the server by pid alone, so another server at the ambient
/// socket, or none, is read against that pid's liveness; a key that records
/// the server's start reads a server at that pid under another start as a
/// reused pid, the recorded server gone with its panes.
fn observe_key(key: &PaneRef) -> Observed<Pane> {
    let server = match tmux::server(&tmux::ambient_socket()) {
        Ok(server) if server.pid as u64 == key.server => server,
        Ok(_) | Err(_) => return unanswering(key.server, None),
    };
    if key.server_start.is_some_and(|start| server.start != start) {
        return Observed::Gone {
            cause: "server-unmatched",
        };
    }
    observe_fields(&server, &key.pane)
}

/// The identity a lane's `wake` record names, where it names one.
pub(super) fn wake_identity(lane: &Lane) -> Option<Identity> {
    let wake = lane.extra.get("wake").filter(|v| !v.is_null())?;
    let pid = wake.get("pid").and_then(super::super::pid_value)?;
    let start = wake.get("start").and_then(Value::as_str)?;
    Some(Identity {
        pid: u32::try_from(pid).ok()?,
        start: start.to_owned(),
    })
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
        overseer
            .extra
            .get("server")
            .and_then(super::super::pid_value)?,
        overseer
            .extra
            .get("pane")
            .and_then(Value::as_str)?
            .to_owned(),
    ))
}

fn overseer_socket(overseer: &Overseer) -> PathBuf {
    overseer
        .extra
        .get("server_socket")
        .and_then(Value::as_str)
        .map(PathBuf::from)
        .unwrap_or_else(tmux::ambient_socket)
}

/// The proof for a predecessor whose record carries no identity:
/// `exit.run.generation` equal to the record's generation, else the recorded
/// pane read gone by exact id on the server the record names at its recorded
/// pid and start. Another server on that socket, no server, or a record
/// naming no server, start or pane proves nothing.
pub(super) fn proof_of(overseer: &Overseer) -> Proof {
    let generation = overseer.generation.unwrap_or(0);
    let exited = overseer
        .extra
        .get("exit")
        .and_then(|e| e.get("run"))
        .and_then(|r| r.get("generation"))
        .and_then(super::super::pid_value);
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
    let Some(start) = overseer
        .extra
        .get("server_start")
        .and_then(super::super::pid_value)
    else {
        return Proof::Unproven {
            cause: "server-start-unrecorded",
        };
    };
    match tmux::server(&overseer_socket(overseer)) {
        Ok(answering) if answering.pid as u64 == server && answering.start == start => {
            match tmux::pane_fields(&answering, &pane) {
                Reading::Live(fields) => Proof::Standing { pid: fields.pid },
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

/// Whether the destination home holds the session `id` for `cwd`, read
/// three-valued through the session owner's fixed-id lookup (decision 115
/// (G)).
pub(in crate::effects) fn session_present(
    harness: Harness,
    home: &Path,
    cwd: &Path,
    id: &str,
) -> Reading<()> {
    session::resume_present(harness, home, cwd, id)
}

/// The harness's default home, where its sessions are read with no account
/// named.
pub(in crate::effects) fn default_home(harness: Harness) -> Option<PathBuf> {
    session::default_home(harness)
}

/// The file the harness records the session `id` for `cwd` in under `home`,
/// for a harness whose launch fixes the id.
pub(in crate::effects) fn fixed_file(
    harness: Harness,
    home: &Path,
    cwd: &Path,
    id: &str,
) -> Option<PathBuf> {
    session::fixed_file(harness, home, cwd, id)
}

/// Whether `pane_id` on `server` is one tmux may name: `%` then digits.
fn is_pane_id(id: &str) -> bool {
    id.strip_prefix('%')
        .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
}

impl Operation<'_> {
    /// The tmux server a fleet window opens on and the session it opens in:
    /// the socket the runtime's own `$TMUX` names or the user's default, as
    /// `lib/tmux-server.sh` resolves it, and the session the settings name,
    /// else the fleet record's `tmux.session`.
    pub(in crate::effects) fn fleet_server(
        &self,
        doc_session: Option<&str>,
    ) -> Result<(Server, String)> {
        let session = self
            .run
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

    /// The server's own process identity, read live before a window opens on
    /// it, so a socket that stops answering can later be told from a server
    /// that is gone.
    pub(in crate::effects) fn server_process_start(
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
    pub(in crate::effects) fn read_process(&mut self, id: &Identity) -> Result<ProcessRead> {
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
    pub(in crate::effects) fn now(&self) -> std::time::Instant {
        self.clock.now()
    }

    pub(in crate::effects) fn sleep(&self, d: Duration) {
        self.clock.sleep(d);
    }

    /// The token for `id` where `Process(id)` stands in the set.
    pub(in crate::effects) fn standing_process(&self, id: &Identity) -> Option<Standing<Identity>> {
        self.obligations.standing_process(id)
    }

    /// The token for `pane` where its key stands in the set; the pane comes
    /// back where the set does not hold it, and nothing acts on it.
    pub(in crate::effects) fn standing_pane(
        &self,
        pane: Pane,
    ) -> std::result::Result<Standing<Pane>, Pane> {
        self.obligations.standing_pane(pane)
    }

    /// The harness identity the set recorded under the harness role, standing
    /// or discharged: what a lane close reads and stops (decision 124d (15)).
    pub(in crate::effects) fn harness_identity(&self) -> Option<Identity> {
        self.obligations.harness_identity()
    }

    /// The standing pid-only harness a legacy lane record named with no start.
    pub(in crate::effects) fn harness_pid(&self) -> Option<u32> {
        self.obligations.harness_pid()
    }

    /// The pane id the set records under the harness role, standing, for the
    /// observation a close writes.
    pub(in crate::effects) fn harness_pane_id(&self) -> Option<String> {
        self.obligations.pane(Role::Harness).map(|key| key.pane)
    }

    /// Refuse `token-stale` where the process token's key no longer stands
    /// in this handle's set (decision 124d (16)).
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
    /// this handle's set (decision 124d (16)).
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
            Some(state::Phase::Opening { opening }) => push(PathBuf::from(&opening.socket)),
            Some(
                state::Phase::WindowOpened { opened }
                | state::Phase::Retired { opened }
                | state::Phase::Delivering { opened, .. }
                | state::Phase::Delivered { opened, .. }
                | state::Phase::IdentityRead { opened, .. },
            ) => push(PathBuf::from(&opened.socket)),
            None => {}
        }
        if let Some(overseer) = overseer {
            push(overseer_socket(overseer));
        }
        push(tmux::ambient_socket());
        sockets
    }

    /// The server a standing pane or window key names, at the caller's
    /// sockets: one answering with the key's pid and, where the key records
    /// one, its start, is present; one answering with the key's pid under
    /// another start is a reused pid, the recorded server gone with every
    /// pane it held, `server-unmatched` (decision 66, the rule `observe_key`
    /// applies); none answering with that pid is read by the pid alone
    /// through the one identity reader: dead, the server and its panes are
    /// gone; live or unreadable, the key stands.
    fn server_of_key(
        &self,
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

    /// Read every standing obligation by its own recorded key, discharging
    /// what reads gone and leaving what reads live or unreadable standing:
    /// each `Process` and `Pid` through the one identity reader, each `Pane`
    /// and `Window` on the server its key names, each job through its unit
    /// or group. Run first by every reconcile.
    pub(in crate::effects) fn read_standing(&mut self, overseer: Option<&Overseer>) -> Result<()> {
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
                | Obligation::Validation
                | Obligation::JobSidecar
                | Obligation::JobUnit { .. }
                | Obligation::JobGroup(_)
                | Obligation::JobPgid { .. } => None,
            })
            .collect();
        for (pane, server_pid, server_start) in panes {
            let end = match (
                self.server_of_key(&sockets, server_pid, server_start),
                &pane,
            ) {
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
    pub(in crate::effects) fn read_standing_processes(&mut self) -> Result<()> {
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
                | Obligation::Validation
                | Obligation::JobSidecar
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
    pub(in crate::effects) fn count_stale(
        &mut self,
        id: &Identity,
        observation: &mut Value,
    ) -> Result<u64> {
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
    pub(in crate::effects) fn read_pid(&mut self, pid: u32) -> Result<Reading<Identity>> {
        let read = process::identity(pid);
        self.discharge(Discharge::Pid {
            pid,
            read: read.clone(),
        })?;
        Ok(read)
    }

    /// The recorded phase pane as it reads on its own server; one gone, or
    /// its server with it, discharges the recorded pane by that read.
    pub(in crate::effects) fn observe_pane(
        &mut self,
        opened: &OpenedPane,
    ) -> Result<Observed<Pane>> {
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
    /// ambient server: `None` where the set holds none; present as its token;
    /// gone, discharged by that read; or unobservable, standing.
    pub(in crate::effects) fn observe_lane_pane(
        &mut self,
    ) -> Result<Option<Observed<Standing<Pane>>>> {
        let Some(key) = self.obligations.pane(Role::Harness) else {
            return Ok(None);
        };
        Ok(Some(match observe_key(&key) {
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
    pub(in crate::effects) fn pane_pid(&mut self, pane: &Pane) -> Result<Reading<u32>> {
        let read = tmux::pane_fields(&pane.server, &pane.id).map(|fields| fields.pid);
        if read == Reading::Gone {
            self.pane_end(pane, PaneEnd::Gone)?;
        }
        Ok(read)
    }

    /// Who holds the pane's terminal under `pane_pid`, through the one judge:
    /// a harness identity read here is added to the set, written, and
    /// returned as the recorded token.
    pub(in crate::effects) fn foreground_of(
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
    pub(in crate::effects) fn pane_process(&mut self, pane: &Pane) -> Result<Reading<Identity>> {
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
    pub(in crate::effects) fn read_pane(
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
    pub(in crate::effects) fn close_window(&mut self, pane: Standing<Pane>) -> Result<Close> {
        self.check_pane_token(&pane)?;
        self.signal()?;
        let close = tmux::kill_window(pane.key());
        self.pane_end(pane.key(), PaneEnd::Close(close.clone()))?;
        Ok(close)
    }

    /// Close the standing pane alone by exact id, as `close_window` closes
    /// its window.
    pub(in crate::effects) fn close_pane(&mut self, pane: Standing<Pane>) -> Result<Close> {
        self.check_pane_token(&pane)?;
        self.signal()?;
        let close = tmux::kill_pane(pane.key());
        self.pane_end(pane.key(), PaneEnd::Close(close.clone()))?;
        Ok(close)
    }

    /// Close the window of the set's standing pane on the ambient server: one
    /// present is killed by its token; one gone stands no more; none standing
    /// is no window to close; one the host did not answer for stands with
    /// that cause.
    pub(in crate::effects) fn close_lane_window(&mut self) -> Result<WindowClose> {
        Ok(match self.observe_lane_pane()? {
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
    pub(in crate::effects) fn close_overseer_window(
        &mut self,
        overseer: &Overseer,
    ) -> Result<WindowClose> {
        let Some(key) = self.overseer_pane_key(overseer) else {
            return Ok(WindowClose::Unrecorded);
        };
        let Some(server_start) = overseer
            .extra
            .get("server_start")
            .and_then(super::super::pid_value)
        else {
            return Ok(WindowClose::Unobservable {
                cause: "server-start-unrecorded",
            });
        };
        let observed = match tmux::server(&overseer_socket(overseer)) {
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
    pub(in crate::effects) fn release_retirement(
        &mut self,
        overseer: &Overseer,
        stopped: &Stopped,
    ) -> Result<bool> {
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
    pub(in crate::effects) fn terminal_proof(&mut self, overseer: &Overseer) -> Result<Proof> {
        let proof = proof_of(overseer);
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
    pub(in crate::effects) fn stop_process(
        &mut self,
        target: Standing<Identity>,
        owns: &dyn Fn(&str) -> bool,
    ) -> Result<Stopped> {
        self.check_process_token(&target)?;
        let id = target.key().clone();
        self.signal()?;
        let answer = process::stop_tree(&id, owns, self.run.settings.close_grace)?;
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

    /// Stop the lane's detached wake turn and every other process the set
    /// still holds. The lane's current wake is added to the set under the
    /// wake role, written, before its stop; a wake whose pid a later process
    /// holds is a turn already over, read again through the one identity
    /// reader. Then every standing process this run did not read stale is
    /// stopped by its own token. `Some(cause)` where one outlived its grace
    /// or could not be read: a handle still standing, which the repeated
    /// close stops again.
    pub(in crate::effects) fn stop_wake(
        &mut self,
        lane: &Lane,
        owns: &dyn Fn(&str) -> bool,
    ) -> Result<Option<String>> {
        let wake = wake_identity(lane);
        if let Some(id) = &wake {
            self.add_as(Obligation::Process(id.clone()), Role::Wake)?;
        }
        self.stop_standing_processes(owns, wake.as_ref())
    }

    /// Stop every standing process of the set this run did not read stale,
    /// each by its own token (decision 124c (11)); `wake` is the lane's
    /// current wake where one was just added, whose stale reading is a turn
    /// already over. `Some(cause)` where one outlived its grace or could not
    /// be read. The one sweep a moved intent retries on its own set with
    /// (decision 124d (20)): nothing the lane names now is read here.
    pub(in crate::effects) fn stop_standing_processes(
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
    /// the server the key names at the caller's sockets (decision 124d (20)):
    /// a pane present is killed by exact id through its token; one gone, or
    /// on a server gone or replaced at the key's pid (decision 124g (30)),
    /// is discharged by that read; one the host does not answer for stands.
    /// A pane id is never reused within a server's lifetime, so the key
    /// names the pane the set recorded and no other. The one close a moved
    /// intent retries on its own set with: nothing the target names now is
    /// read.
    pub(in crate::effects) fn close_standing_panes(
        &mut self,
        overseer: Option<&Overseer>,
    ) -> Result<()> {
        let sockets = self.sockets(overseer);
        for key in self.obligations.standing_panes() {
            let observed = match self.server_of_key(&sockets, key.server, key.server_start) {
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

    /// Add the lane's current wake to the set under the wake role, written,
    /// and read it through the one identity reader, signalling nothing: a
    /// reconcile's read.
    pub(in crate::effects) fn read_wake(
        &mut self,
        lane: &Lane,
    ) -> Result<Option<Reading<Identity>>> {
        let Some(id) = wake_identity(lane) else {
            return Ok(None);
        };
        self.add_as(Obligation::Process(id.clone()), Role::Wake)?;
        let read = process::still_runs(&id);
        self.discharge(Discharge::Process {
            identity: id,
            end: ProcessEnd::Read(read.clone()),
        })?;
        Ok(Some(read))
    }

    /// Send Copilot `C-c` then `/exit` on the standing pane and wait up to the
    /// close grace, on the injected clock, for it to exit, so it writes its
    /// session totals. The keystrokes are a signal, written before they are
    /// sent. Best effort: the stop that follows ends a pane that stands.
    pub(in crate::effects) fn copilot_exit(&mut self, pane: &Standing<Pane>) -> Result<()> {
        self.check_pane_token(pane)?;
        self.signal()?;
        let pane = pane.key();
        let _ = tmux::send_key(pane, "C-c");
        let _ = tmux::send_line(pane, "/exit");
        let deadline = self.now() + self.run.settings.close_grace;
        while self.now() < deadline {
            if tmux::pane_fields(&pane.server, &pane.id) == Reading::Gone {
                break;
            }
            self.sleep(Duration::from_millis(100));
        }
        Ok(())
    }

    /// The oldest unanswered ask the lane's mailbox holds, read through the
    /// mailbox CLI (`lane-mail pending --item ITEM --root ROOT [--host]`),
    /// whose lines are JSON rows; only a row of kind `ask` counts, as
    /// `lane-close` reads them. `Err` is a read that did not answer: a
    /// mailbox program that is absent, failed or printed a row that is not
    /// JSON, or a lane with no recorded root. A required gate refuses on it
    /// rather than reading nothing.
    pub(in crate::effects) fn unanswered_ask(
        &self,
        lane: &Lane,
    ) -> std::result::Result<Option<String>, String> {
        let Some(root) = lane.mail_root.as_deref() else {
            return Err("mail-root-unrecorded".to_owned());
        };
        let mut args = vec!["pending", "--item", lane.item.as_str(), "--root", root];
        if lane.host.is_some() {
            args.push("--host");
        }
        let output = host::run(
            "lane-mail",
            &self.run.settings.lane_mail_cli,
            "pending",
            &args,
            CLI_TIMEOUT,
        )
        .map_err(|e| e.to_string())?;
        if !output.status.success() {
            return Err(format!(
                "status={} {}",
                output.status.code().unwrap_or(-1),
                host::stderr_text(&output).trim()
            ));
        }
        for line in host::stdout_text(&output).lines() {
            if line.trim().is_empty() {
                continue;
            }
            let row: Value =
                serde_json::from_str(line).map_err(|e| format!("row-unparsed: {e}"))?;
            if row.get("kind").and_then(Value::as_str) == Some("ask") {
                return Ok(Some(
                    row.get("id")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_owned(),
                ));
            }
        }
        Ok(None)
    }

    /// End every validation run in a local lane's worktree through orch's
    /// own runner (`dev-validate-run --stop --worktree ROOT`), as `lane-close`
    /// does before the window closes, and discharge the validation obligation
    /// by the runner's answer. A hosted lane's runs are its host's; a worktree
    /// that is gone has none. The inner `Err` names why the stop did not
    /// confirm, the obligation standing.
    pub(in crate::effects) fn stop_validations(
        &mut self,
        lane: &Lane,
    ) -> Result<std::result::Result<(), String>> {
        // Nothing to stop discharges Validation with no signal: a hosted
        // lane's runs are its host's, and a worktree with no recorded root
        // or one read gone has none.
        let root = match &lane.host {
            Some(_) => None,
            None => lane.mail_root.as_deref(),
        };
        let Some(root) = root else {
            self.discharge(Discharge::Validation(ValidationEnd::Stopped))?;
            return Ok(Ok(()));
        };
        match std::fs::metadata(root) {
            Ok(meta) if meta.is_dir() => {}
            // A worktree gone, or a path that is not a directory, has no runs.
            Ok(_) => {
                self.discharge(Discharge::Validation(ValidationEnd::Stopped))?;
                return Ok(Ok(()));
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                self.discharge(Discharge::Validation(ValidationEnd::Stopped))?;
                return Ok(Ok(()));
            }
            // A root that cannot be read is no proof of absence: Validation
            // stands, with the cause, and nothing is signalled.
            Err(e) => return Ok(Err(format!("validation-unreadable:{}", e.kind()))),
        }
        // A real stop is the first signal of the close as often as not:
        // recorded before the runner is called, and Validation discharged
        // only by the runner's own answer.
        self.signal()?;
        let answer = run_validation_stop(self.run.settings, root);
        if answer.is_ok() {
            self.discharge(Discharge::Validation(ValidationEnd::Stopped))?;
        }
        Ok(answer)
    }

    /// The worktree's validation runs under a lane that moved belong to the
    /// session that now holds the lane, which owes its own stop: the
    /// obligation is discharged `lane-moved` where it stands (decision 124e
    /// (24)); nothing of this close touches that worktree.
    pub(in crate::effects) fn release_validation_moved(&mut self) -> Result<()> {
        self.discharge(Discharge::Validation(ValidationEnd::LaneMoved))
    }

    /// Wait for the process that handed this intent to the job to exit,
    /// within the launch bound: the pane about to be retired is its own as
    /// often as not. A caller still live past the bound, or one that cannot
    /// be read, holds the succession no longer.
    pub(in crate::effects) fn await_caller_gone(&self) -> Result<()> {
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
        let deadline = self.now() + self.run.settings.verify;
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
    pub(in crate::effects) fn session_floor(
        &self,
        harness: Harness,
        home: &Path,
        cwd: &Path,
    ) -> Result<SessionFloor> {
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
    /// at all; an unread candidate binds nothing and names its cause.
    pub(in crate::effects) fn appeared_session(
        &self,
        harness: Harness,
        home: &Path,
        cwd: &Path,
        opened: &OpenedPane,
    ) -> Binding {
        let since = std::time::UNIX_EPOCH + Duration::from_millis(opened.since_ms);
        let mut found = match session::new_leads(harness, home, cwd, since, &opened.baseline) {
            Reading::Live(found) => found,
            Reading::Gone => Vec::new(),
            Reading::Unreadable { cause } => return Binding::Unreadable { cause },
        };
        match found.len() {
            0 => Binding::Absent,
            1 => {
                let lead = found.remove(0);
                Binding::Bound(BoundSession {
                    session_id: lead.id,
                    file: lead.file.display().to_string(),
                })
            }
            _ => Binding::Ambiguous(found.into_iter().map(|s| s.id).collect()),
        }
    }

    /// Type `text` and Enter into the standing pane: the held brief delivered
    /// to the runner at its composer. The `delivering` phase is written
    /// before the paste (decision 124e (23)), so a repeat after a crash reads
    /// the brief as possibly delivered and never pastes twice. No obligation
    /// changes: the pane and its process stand as before. The inner `Err` is
    /// the host's refusal of the paste.
    pub(in crate::effects) fn deliver(
        &mut self,
        pane: &Standing<Pane>,
        text: &str,
        delivering: Phase,
    ) -> Result<std::result::Result<(), agent_runtime::Error>> {
        self.check_pane_token(pane)?;
        self.record_phase(delivering)?;
        Ok(tmux::send_line(pane.key(), text))
    }

    /// The user turns the session file `file` records (decision 61).
    pub(in crate::effects) fn user_turns(&self, harness: Harness, file: &Path) -> Result<u64> {
        Ok(session::user_turns(harness, file)? as u64)
    }
}

/// Run orch's own validation runner's stop for the worktree `root`
/// (`dev-validate-run --stop --worktree ROOT`), as `lane-close` orders it.
/// The caller gates and signals; this only runs the runner and reads its
/// answer.
fn run_validation_stop(settings: &Settings, root: &str) -> std::result::Result<(), String> {
    let output = host::run(
        "dev-validate-run",
        &settings.dev_validate_cli,
        "stop",
        &["--stop", "--worktree", root],
        CLI_TIMEOUT,
    )
    .map_err(|e| e.to_string())?;
    if output.status.success() {
        return Ok(());
    }
    Err(format!(
        "status={} {}",
        output.status.code().unwrap_or(-1),
        host::stderr_text(&output).trim()
    ))
}

/// Read the pane an adoption names and record the controller in it: the
/// harness identity in the pane's foreground, through the one judge
/// (decisions 60, 99), never the caller's word for it. A record naming
/// another session refuses `overseer-live` while that session's identity
/// reads live, or its pane stands on the proven server with no identity
/// recorded; one it cannot read refuses `overseer-unreadable`; one nothing
/// resolves refuses `predecessor-unproven` (decision 109 (1)). The one
/// read-then-record operation of the fleet (step4-map A3): no intent, so no
/// handle, and nothing it reads is an obligation.
pub(in crate::effects) fn adopt_controller(
    path: &Path,
    r: &AdoptController,
    settings: &Settings,
    locking: Locking,
) -> Result<Applied> {
    let overseer = super::super::fleet(path)?.overseer;
    let harness = Harness::parse(&r.harness)
        .ok_or_else(|| super::super::refused("harness-unknown", &[("harness", &r.harness)]))?;
    if !is_pane_id(&r.pane) {
        return Err(super::super::refused("pane-invalid", &[("pane", &r.pane)]));
    }
    let socket = r.socket.clone().unwrap_or_else(tmux::ambient_socket);
    let server = tmux::server(&socket)?;
    let fields = match tmux::pane_fields(&server, &r.pane) {
        Reading::Live(fields) => fields,
        Reading::Gone => return Err(super::super::refused("pane-gone", &[("pane", &r.pane)])),
        Reading::Unreadable { cause } => {
            return Err(super::super::refused(
                "pane-unreadable",
                &[("pane", &r.pane), ("cause", cause)],
            ));
        }
    };
    let target = super::super::Target::new(settings, harness);
    let identity = match observe::foreground(fields.pid, &|name| target.owns(name), None) {
        ProcessReading::Harness { identity } => identity,
        ProcessReading::Unread { cause } => {
            return Err(super::super::refused(
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
                reading: serde_json::to_value(&reading)
                    .ok()
                    .and_then(|v| v.get("reading").and_then(Value::as_str).map(str::to_owned))
                    .unwrap_or_default(),
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
        match super::super::overseer_identity(recorded) {
            Some(prior) => match process::still_runs(&prior) {
                Reading::Live(_) => return Err(live(prior.pid as u64)),
                Reading::Gone => {}
                Reading::Unreadable { cause } => return Err(unreadable(cause)),
            },
            None => match proof_of(recorded) {
                Proof::Standing { pid } => return Err(live(pid as u64)),
                Proof::Unreadable { cause } => return Err(unreadable(cause)),
                // Nothing resolves the recorded session: it is not replaced
                // (decision 109 (1)); adoption from its own pane heals it.
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
    overseer
        .extra
        .get("server")
        .and_then(super::super::pid_value)
        == Some(server as u64)
        && overseer.extra.get("pane").and_then(Value::as_str) == Some(pane)
        && overseer
            .extra
            .get("server_start")
            .and_then(super::super::pid_value)
            .is_none_or(|recorded| recorded == start)
}

/// The owner's contract, as `lib/watch-handover.sh` states it: sourced with
/// `SCRIPT_DIR`, `DEP_ERR` and `HANDOFF` set and its two libs beside it, then
/// asked `watch_handover PREDECESSOR SUCCESSOR LANE_VAR LANE_HOME HARNESS
/// FLAG...`; its answer is the key and fields it leaves in its two variables,
/// printed as one line. The state directory is handed on so the owner's
/// `workflow-state path oversee` names this fleet's file. The recorded
/// handoff destination is `HANDOFF` alone (decision 120, M2): the owner's
/// `WATCH_HANDOFF_KEEP` would let the running watch's own `--handoff` win
/// over it, so it is never set here.
const WATCH_HANDOVER_SCRIPT: &str = r#"set -u
SCRIPT_DIR=$1 DEP_ERR=$2
export ORCH_STATE_DIR=$3
handoff=$4
lib=$5
shift 5
if [ -n "$handoff" ]; then HANDOFF="$handoff"; else HANDOFF=${HANDOFF:-tmp/handoffs/OVERSEER-HANDOFF.md}; fi
export HANDOFF
unset WATCH_HANDOFF_KEEP
. "$SCRIPT_DIR/lib/watch-pid.sh" && . "$SCRIPT_DIR/lib/job-unit.sh" && . "$lib" || exit 70
rc=0
watch_handover "$@" || rc=$?
printf '%s' "$WATCH_HANDOVER_KEY"
for f in ${WATCH_HANDOVER_FIELDS[@]+"${WATCH_HANDOVER_FIELDS[@]}"}; do printf ' %s' "$f"; done
printf '\n'
exit "$rc"
"#;

/// Hand the fleet watch from the predecessor's pane to the successor's
/// (decision 109 (6)) through the existing owner, orch's
/// `lib/watch-handover.sh` `watch_handover`, sourced into a shell and asked
/// with the call's words. Run by the recording boundary once the confirmed
/// record is committed, and its result recorded on the intent; the
/// publication stands either way, the successor's own `oversee` start the
/// fallback.
pub(super) fn hand_over_watch(settings: &Settings, call: &WatchHandoverCall) -> WatchHandover {
    let (key, line) = match watch_handover(settings, call) {
        Ok((key, line)) => (key, line),
        Err(e) => (
            "watch-restart-failed".to_owned(),
            format!(
                "error={} {}",
                e.key(),
                e.to_string().lines().next().unwrap_or_default()
            ),
        ),
    };
    let full = format!("{key} {line}").trim_end().to_owned();
    match key.as_str() {
        "watch-handover" | "watch-started" | "watch-restarted" => {
            WatchHandover::HandedOver { line: full }
        }
        _ => WatchHandover::Failed {
            cause: key,
            line: full,
        },
    }
}

fn watch_handover(settings: &Settings, call: &WatchHandoverCall) -> Result<(String, String)> {
    let lib = &settings.watch_handover;
    if !lib.is_file() {
        return Err(super::super::refused(
            "watch-handover-missing",
            &[("path", &lib.display().to_string())],
        ));
    }
    // The orch scripts directory the owner's two libs sit under, the one the
    // job-unit launcher setting names: `<scripts>/lib/job-unit.sh`.
    let scripts = settings
        .job_unit
        .parent()
        .and_then(Path::parent)
        .ok_or_else(|| {
            super::super::refused(
                "job-unit-path",
                &[("path", &settings.job_unit.display().to_string())],
            )
        })?;
    let bash = std::env::var_os("PATH")
        .and_then(|path| {
            std::env::split_paths(&path)
                .map(|dir| dir.join("bash"))
                .find(|p| p.is_file())
        })
        .ok_or_else(|| super::super::refused("bash-missing", &[]))?;
    let dep_err = settings
        .state_dir
        .join("intents")
        .join("watch-handover.err")
        .display()
        .to_string();
    let scripts_dir = scripts.display().to_string();
    let state_dir = settings.state_dir.display().to_string();
    let lib_path = lib.display().to_string();
    let handoff = call.handoff.clone().unwrap_or_default();
    let mut args: Vec<&str> = vec![
        "-c",
        WATCH_HANDOVER_SCRIPT,
        "watch-handover",
        &scripts_dir,
        &dep_err,
        &state_dir,
        &handoff,
        &lib_path,
        &call.predecessor_pane,
        &call.pane,
        call.account_var,
        &call.account,
        call.harness,
    ];
    args.extend(call.flags.iter().map(String::as_str));
    let out = host::run(
        "bash",
        &bash,
        "watch-handover",
        &args,
        WATCH_HANDOVER_TIMEOUT,
    )?;
    let line = host::stdout_text(&out);
    let (key, fields) = line.split_once(' ').unwrap_or((line.as_str(), ""));
    if key.is_empty() {
        return Err(agent_runtime::Error::External {
            program: "bash",
            operation: "watch-handover",
            cause: host::stderr_text(&out),
        }
        .into());
    }
    Ok((key.to_owned(), fields.to_owned()))
}

/// The state module's receipt path for the operation (decision 96).
pub(super) fn receipt_path(settings: &Settings, intent_id: &str) -> PathBuf {
    state::receipt_path(&settings.state_dir, intent_id)
}
