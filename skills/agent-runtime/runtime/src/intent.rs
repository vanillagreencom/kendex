//! The intent row's frame and its parts, which name no lane field or
//! worktree: the operation, how far its effect got, the obligation set it stands under,
//! the process that persisted an intent, the identity of what a launch
//! opened, the failure notice an intent makes and why a reconcile closed it,
//! in the shape the fleet record holds them.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::controller::TransferCause;
use crate::harness::Harness;
use crate::process::Identity;
use crate::protocol::Outcome;

/// The observation note a reconcile writes when it found the intent's owner
/// still live and deferred to it. The outcome records only
/// this observation; it moves no record.
pub const OWNER_LIVE: &str = "owner-live";
/// The observation note a reconcile writes when the intent's owner could
/// not be read: neither live nor dead is established, so the
/// outcome records the observation and its cause and moves no record, as
/// [`OWNER_LIVE`] does.
pub const OWNER_UNREAD: &str = "owner-unreadable";

/// A lane's launch identity `{pane, server, server_start, pid, start}`.
/// `server_start` is the tmux server's start the runtime's launch published,
/// so the pane is keyed on the server's pid and start; a
/// record the released launcher wrote carries none.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LaunchIdentity {
    #[serde(default)]
    pub pane: Option<String>,
    #[serde(default)]
    pub server: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub server_start: Option<u64>,
    #[serde(default)]
    pub pid: Option<u64>,
    #[serde(default)]
    pub start: Option<String>,
}

/// The process that persisted an intent: its pid and start, read through
/// agent-runtime's one identity reader when the intent was written.
/// A reconcile that finds this process still live defers to
/// it and touches nothing; only a dead or absent owner lets a reconcile
/// complete or fail the intent. An intent may carry none.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Owner {
    /// The runtime writes the number; a string form is read too, so a
    /// record a jq writer produced is not refused.
    #[serde(deserialize_with = "de_pid")]
    pub pid: u64,
    pub start: String,
}

/// Read a pid written as a JSON number or the string a jq `--arg` produced.
fn de_pid<'de, D: serde::Deserializer<'de>>(d: D) -> std::result::Result<u64, D::Error> {
    match Value::deserialize(d)? {
        Value::Number(n) => n
            .as_u64()
            .ok_or_else(|| serde::de::Error::custom("pid is not a non-negative integer")),
        Value::String(s) => s
            .parse()
            .map_err(|_| serde::de::Error::custom(format!("pid {s:?} is not an integer"))),
        other => Err(serde::de::Error::custom(format!(
            "pid is {other}, not a number or string"
        ))),
    }
}

/// The one failure announcement an intent makes: the keyed line the fleet
/// log holds under `item: overseer`, a `<opener>: <note> op=<op>
/// intent=<id> outcome=<outcome>` row, and how the owner notice went. The outcome's own
/// write records the notice `owed`, with its row; the send follows, and a
/// later write marks it `sent`, `unsent:<cause>` where the mailbox CLI
/// refused, or `unanswered:<cause>` where it gave no answer. A notice still
/// `owed` on a closed intent is a continuation every reconcile and request
/// runs once, under the owner; an `unanswered` one is sent once more by the
/// watch's heartbeat. `to` names the item whose lane the notice goes to;
/// absent, it goes to the owner through the overseer's box, the shape every
/// intent notice has.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Notice {
    pub key: String,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to: Option<String>,
    pub owner: String,
}

/// The `owner` word of a notice recorded with its outcome and not yet sent.
pub const NOTICE_OWED: &str = "owed";

/// The `owner` word's prefix for a notice whose send got no answer.
pub const NOTICE_UNANSWERED: &str = "unanswered:";

impl Notice {
    /// Whether the notice is recorded and still to be sent.
    pub fn owed(&self) -> bool {
        self.owner == NOTICE_OWED
    }

    /// Whether the notice's send got no answer, so it may not have gone.
    pub fn unanswered(&self) -> bool {
        self.owner.starts_with(NOTICE_UNANSWERED)
    }
}

/// Why an intent was closed apart from its effect's own outcome.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Reconciled {
    /// The target's record moved under the open intent: a lane relaunched,
    /// closed or removed since, or an overseer whose generation moved past
    /// the one the intent names. The record is left as found.
    IntentStale,
}

/// The operations that start an external effect, each named for the act the
/// engine performs, never for who asked for it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum EffectOp {
    /// A launch that opens a pane and binds its session, on the target the
    /// opener names.
    LaunchSession,
    RequestTransfer,
    /// A close of the resources the operation owns, on the target the
    /// opener names.
    CloseResources,
    /// A controller's first launch, or its launch after an explicit `off`:
    /// a succession with no predecessor to retire.
    StartController,
    /// The explicit off: the controller retired exactly by
    /// identity and the record marked so no recovery relaunches it.
    StopController,
}

impl EffectOp {
    /// The operation's word, the `op` of a request.
    pub fn word(self) -> &'static str {
        match self {
            EffectOp::LaunchSession => "launch-session",
            EffectOp::RequestTransfer => "request-transfer",
            EffectOp::CloseResources => "close-resources",
            EffectOp::StartController => "start-controller",
            EffectOp::StopController => "stop-controller",
        }
    }

    /// Whether the operation moves the controller record, its target an
    /// `overseer:<generation>`.
    pub fn on_controller(self) -> bool {
        match self {
            EffectOp::RequestTransfer | EffectOp::StartController | EffectOp::StopController => {
                true
            }
            EffectOp::LaunchSession | EffectOp::CloseResources => false,
        }
    }
}

/// What an effect recorded around opening its window:
/// the server a window is about to open on and the floor its native session
/// is read above, every field of [`OpenedPane`] but the pane, and then the
/// pane id the creating `new-window` call printed, written before anything
/// is typed into it. A reconcile at this phase reads the pane's own receipt
/// first, else judges the recorded pane; a window neither receipted nor
/// recorded is never adopted.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Opening {
    pub server: u64,
    pub server_start: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub server_process_start: Option<String>,
    pub socket: String,
    pub since_ms: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub brief: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub baseline: Vec<String>,
    /// The pane the effect's own `new-window` created, or the session's idle
    /// shell it types into (`adopted`), recorded before the launch line is
    /// typed into it; `None` until then.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pane: Option<String>,
    /// `pane` is a shell the effect did not open: it becomes the effect's
    /// only once its receipt names it, so no close of the effect's reaches
    /// it before the line ran there.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub adopted: bool,
    /// Whether the launcher has been asked for the window: written before
    /// `new-window` runs, so a phase with no pane and
    /// `asked` names a window possibly opened, and one without it nothing.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub asked: bool,
    /// The home the runner's native sessions are read under, as its launch
    /// prepared it: every reconcile reads the runner there, never a home
    /// resolved again in its own process.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub home: Option<String>,
    /// The launch named no home: an accountless Claude launch on its
    /// implicit default config dir, which a resume repeats.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub home_implicit: bool,
}

impl Opening {
    /// The [`OpenedPane`] this opening becomes once its window is found: the
    /// recorded server and floor with the pane, and the
    /// identity the pane's receipt proved where a reconcile adopted it.
    pub fn into_opened(&self, pane: String, identity: Option<Identity>) -> OpenedPane {
        OpenedPane {
            pane,
            server: self.server,
            server_start: self.server_start,
            server_process_start: self.server_process_start.clone(),
            socket: self.socket.clone(),
            since_ms: self.since_ms,
            brief: self.brief.clone(),
            session_id: self.session_id.clone(),
            baseline: self.baseline.clone(),
            identity,
            home: self.home.clone(),
            home_implicit: self.home_implicit,
        }
    }
}

/// The pane an effect opened and the floor its native session is read
/// above: the data every phase after `window-opened` carries. The server is
/// named by its socket, pid and start, so a reconcile observes the pane on
/// the recorded server whatever socket its own `$TMUX` names. Another
/// server answering on that socket, or no server with the recorded server
/// process gone, proves the pane gone; only an unanswering socket whose
/// server process still runs is unobservable.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OpenedPane {
    pub pane: String,
    pub server: u64,
    pub server_start: u64,
    /// The server process's start as the one identity reader records it,
    /// read when the window opened, so a socket that stops answering can be
    /// told from a server that is gone.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub server_process_start: Option<String>,
    pub socket: String,
    /// Milliseconds since the epoch just before the window opened: the
    /// floor a native session must be created above to be this launch's.
    pub since_ms: u64,
    /// The handoff a succession holds for the runner, delivered after
    /// retirement; a launch spells its brief into the command and holds
    /// none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub brief: Option<String>,
    /// The session id the launch fixed on the command line, for a harness
    /// that takes one: the runner's own native file is then known by name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// The lead sessions for the runner's cwd that stood before the window
    /// opened, for a harness whose launch fixes no id: the runner's own
    /// file is the one lead that appears and is absent here.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub baseline: Vec<String>,
    /// The harness identity this attempt runs under, once read: the
    /// receipt's pid confirmed live at adoption, or the identity the judge
    /// read in the pane. It is the one identity every later
    /// read, publication and retirement of the attempt uses; none selects
    /// another process in its place.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub identity: Option<Identity>,
    /// The home the runner's native sessions are read under, as its launch
    /// prepared it ([`Opening::home`]).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub home: Option<String>,
    /// The launch named no home ([`Opening::home_implicit`]).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub home_implicit: bool,
}

/// The runner's own native session file, bound once before the brief is
/// pasted: the effect and every reconcile count that file alone, never a
/// neighbour in the same home and directory.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BoundSession {
    pub session_id: String,
    pub file: String,
}

/// How far an effect got, written into its intent before each wait so a
/// `reconcile` completes the effect from the recorded step.
/// A launch reaches `window-opened` and then its outcome; a succession
/// passes `delivered` (the brief pasted while the predecessor still runs,
/// with the runner's own session file and its user-turn count before the
/// paste), retires the predecessor, which a reconcile reads from the
/// predecessor itself, and reaches `identity-read` (the runner's own
/// process identity, the last read before publication).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "phase", rename_all = "kebab-case")]
pub enum Phase {
    /// Written before any window opens and again with the
    /// pane once one is created. A reconcile here adopts the
    /// pane the intent's receipt names, fails the recorded pane that never
    /// registered, or fails `nothing-opened` with neither.
    Opening {
        #[serde(flatten)]
        opening: Opening,
    },
    WindowOpened {
        #[serde(flatten)]
        opened: OpenedPane,
    },
    /// Written before the brief is typed: a reconcile
    /// that finds it reads the brief as possibly delivered and waits for the
    /// turn, never pasting again.
    Delivering {
        #[serde(flatten)]
        opened: OpenedPane,
        /// The user turns the bound file held before the paste.
        turns_before: u64,
        session: BoundSession,
        /// The lines the brief holds, as typed.
        lines: u64,
    },
    Delivered {
        #[serde(flatten)]
        opened: OpenedPane,
        /// The user turns the bound file held before the paste.
        turns_before: u64,
        session: BoundSession,
    },
    IdentityRead {
        #[serde(flatten)]
        opened: OpenedPane,
        pid: u64,
        start: String,
    },
    /// Written before a cloud session's create is asked: a create whose
    /// answer is lost, the asking process ended included, may have made a
    /// session nothing here can name, so a reconcile holds the launch
    /// rather than reading nothing opened. `answer_by` is when the create's
    /// bound ends: a session it makes may appear until then.
    CloudCreate {
        worktree: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        answer_by: Option<String>,
    },
    /// Written before a launch asks a preparation whose answer can be lost:
    /// a hosted provider's `start` and `create` (`step` `host-start` or
    /// `host-create`, `at` the host; the `wait` after a create included), a
    /// cloud lane's worktree `create` and branch `push` (`worktree-create`
    /// at the claim root, `worktree-push` at the worktree). Its effect may
    /// stand though nothing answered, so a reconcile holds every step until
    /// a close settles it.
    Preparing { step: String, at: String },
}

impl Phase {
    /// The pane a phase names, or `None` at `opening`, before a window
    /// exists.
    pub fn opened(&self) -> Option<&OpenedPane> {
        match self {
            Phase::WindowOpened { opened }
            | Phase::Delivering { opened, .. }
            | Phase::Delivered { opened, .. }
            | Phase::IdentityRead { opened, .. } => Some(opened),
            Phase::Opening { .. } | Phase::CloudCreate { .. } | Phase::Preparing { .. } => None,
        }
    }
}

/// One recorded handle of an operation's target, typed by what it is. A
/// pane and a window carry the server's pid and
/// tmux start, the only form this host addresses a pane in; a lane record
/// the released launcher wrote carries the pid alone, so
/// its pane's start is unknown and `None`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum Obligation {
    /// A process identity (pid and start) the record names or the effect
    /// read.
    Process(Identity),
    /// A pid recorded with no start: no identity reads it, but a pid nothing
    /// holds proves the recorded process gone.
    Pid { pid: u32 },
    Pane {
        pane: String,
        server: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        server_start: Option<u64>,
    },
    /// A pane recorded with no server, which a record may carry: this
    /// host cannot address it, and the record does not prove it absent.
    PaneUnaddressed { pane: String },
    /// A launcher was asked for a window on this server and no pane id was
    /// recorded yet: a window possibly opened.
    Window { server: u64, server_start: u64 },
    /// The pane's receipt was armed: an obligation until read.
    Receipt,
    /// The job launcher was asked and its record not yet read: a job
    /// possibly started. `record` is the launcher record's path
    /// the ask named, the one address the record is read at:
    /// the intent's own job record for a transfer or a stop, the
    /// watch's runner record beside the fleet state for a start's watch.
    JobSidecar { record: String },
    /// The detached job runs as this transient user unit.
    JobUnit { unit: String },
    /// The detached job leads this process group, by the identity its child
    /// wrote before it ran.
    JobGroup(Identity),
    /// The detached job by its group key alone: the launcher ended the launch
    /// `unwound-failed` without reading the leader's start, and the key is
    /// read in the kernel's table, the child whose pid it is and every member
    /// of its group, until neither stands.
    JobPgid { pgid: u32 },
}

/// The part a recorded handle plays in its intent: the target's own harness
/// and pane, the runner a succession opens, the predecessor it retires, the
/// detached job, or an auxiliary process the opener names beside the
/// harness. A selection from the set reads the role and never the target's
/// record.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Role {
    Harness,
    Runner,
    Predecessor,
    Job,
    Auxiliary,
}

/// One standing obligation as the record holds it: the handle, flattened
/// under its `kind`, its role, and, under the harness role, the harness
/// kind the lane ran when the handle was acquired: what
/// names the processes below the recorded root that a stop may signal,
/// never the harness a relaunched session runs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Held {
    #[serde(flatten)]
    pub obligation: Obligation,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<Role>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness: Option<Harness>,
}

/// An obligation settled, with the evidence word that settled it, the role
/// it held and the harness kind recorded on it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Discharged {
    pub obligation: Obligation,
    pub by: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<Role>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness: Option<Harness>,
}

/// The durable obligation set of an intent: what stands,
/// what was discharged and by what, and whether the effect has signalled
/// anything, after which no refusal is expressible on the intent. `revision`
/// counts the set's replacements: the store advances it on every write that
/// changes the set, and a handle whose write names an older revision is
/// refused `set-replaced`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct ObligationRecord {
    #[serde(default)]
    pub standing: Vec<Held>,
    #[serde(default)]
    pub discharged: Vec<Discharged>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub signalled: bool,
    /// Independent stale readings per recorded identity (`pid:start`), one
    /// per run that read the pid live under another start; the second
    /// settles the identity.
    #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub stale: std::collections::BTreeMap<String, u64>,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub revision: u64,
}

fn is_zero(n: &u64) -> bool {
    *n == 0
}

/// The keys a terminal carries for its target's record: the target's stamp
/// when the intent was written and every identity, pid and pane key the
/// intent's set recorded under the principal's role. The store applies a
/// terminal to the target only when the target's record names nothing but
/// these.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrincipalKeys {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub since: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub keys: Vec<Obligation>,
}

/// What a lane's `launch` record names as obligations: a pane with its
/// server, else the pane unaddressable; an identity with its start, else
/// the pid alone. The one reading of a launch record both the store's
/// moved-lane judgement and the handle's bootstrap take.
pub fn launch_obligations(launch: Option<&LaunchIdentity>) -> Vec<Obligation> {
    let Some(launch) = launch else {
        return Vec::new();
    };
    let mut named = Vec::new();
    match (&launch.pane, launch.server) {
        (Some(pane), Some(server)) => named.push(Obligation::Pane {
            pane: pane.clone(),
            server,
            server_start: launch.server_start,
        }),
        (Some(pane), None) => named.push(Obligation::PaneUnaddressed { pane: pane.clone() }),
        (None, Some(_) | None) => {}
    }
    match (
        launch.pid.and_then(|pid| u32::try_from(pid).ok()),
        &launch.start,
    ) {
        (Some(pid), Some(start)) => named.push(Obligation::Process(Identity {
            pid,
            start: start.clone(),
        })),
        (Some(pid), None) => named.push(Obligation::Pid { pid }),
        (None, _) => {}
    }
    named
}

impl ObligationRecord {
    /// Move every standing obligation `which` selects to the discharged set
    /// under `by`, each keeping its role; how many moved.
    pub fn discharge_where(&mut self, which: impl Fn(&Obligation) -> bool, by: &str) -> usize {
        let (moved, kept): (Vec<Held>, Vec<Held>) = std::mem::take(&mut self.standing)
            .into_iter()
            .partition(|h| which(&h.obligation));
        self.standing = kept;
        let count = moved.len();
        self.discharged
            .extend(moved.into_iter().map(|held| Discharged {
                obligation: held.obligation,
                by: by.to_owned(),
                role: held.role,
                harness: held.harness,
            }));
        count
    }

    /// The harness kind recorded under the harness role, standing or
    /// discharged.
    pub fn recorded_harness(&self) -> Option<Harness> {
        self.standing
            .iter()
            .filter(|h| h.role == Some(Role::Harness))
            .find_map(|h| h.harness)
            .or_else(|| {
                self.discharged
                    .iter()
                    .filter(|d| d.role == Some(Role::Harness))
                    .find_map(|d| d.harness)
            })
    }

    /// Whether `obligation` stands.
    pub fn stands(&self, obligation: &Obligation) -> bool {
        self.standing.iter().any(|h| h.obligation == *obligation)
    }

    /// Whether the record carries `obligation`, standing or discharged.
    pub fn holds(&self, obligation: &Obligation) -> bool {
        self.stands(obligation) || self.discharged.iter().any(|d| d.obligation == *obligation)
    }

    /// The role `obligation` holds or held, where the record names one.
    pub fn role_of(&self, obligation: &Obligation) -> Option<Role> {
        self.standing
            .iter()
            .find(|h| h.obligation == *obligation)
            .and_then(|h| h.role)
            .or_else(|| {
                self.discharged
                    .iter()
                    .find(|d| d.obligation == *obligation)
                    .and_then(|d| d.role)
            })
    }

    /// Every standing obligation, in record order.
    pub fn standing_obligations(&self) -> impl Iterator<Item = &Obligation> {
        self.standing.iter().map(|h| &h.obligation)
    }

    /// Whether the two records hold the same set: everything but the
    /// revision the store assigns.
    pub fn same_set(&self, other: &ObligationRecord) -> bool {
        self.standing == other.standing
            && self.discharged == other.discharged
            && self.signalled == other.signalled
            && self.stale == other.stale
    }

    /// The keys the record holds under `role`, standing or discharged:
    /// every process, pid and pane key.
    pub fn principal_keys(&self, role: Role) -> Vec<Obligation> {
        self.standing_obligations()
            .chain(self.discharged.iter().map(|d| &d.obligation))
            .filter(|o| self.role_of(o) == Some(role))
            .filter(|o| match o {
                Obligation::Process(_)
                | Obligation::Pid { .. }
                | Obligation::Pane { .. }
                | Obligation::PaneUnaddressed { .. } => true,
                Obligation::Window { .. }
                | Obligation::Receipt
                | Obligation::JobSidecar { .. }
                | Obligation::JobUnit { .. }
                | Obligation::JobGroup(_)
                | Obligation::JobPgid { .. } => false,
            })
            .cloned()
            .collect()
    }

    /// Whether `obligation` is a detached job's handle or its unread record.
    pub fn is_job(obligation: &Obligation) -> bool {
        matches!(
            obligation,
            Obligation::JobSidecar { .. }
                | Obligation::JobUnit { .. }
                | Obligation::JobGroup(_)
                | Obligation::JobPgid { .. }
        )
    }
}

/// The persisted intent of one external effect: written before the effect
/// starts, its `outcome` written after. The id is
/// `<op>:<target>:<nanos>-<nonce>`, the operation's word, its target and
/// the stamp the caller's `Env` minted for the call, so two intents on one
/// target never share an id whatever the file holds. One intent per
/// target may be open; a repeated request of the same operation finds it
/// and reconciles, a request of another operation on the target refuses.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Intent {
    pub id: String,
    pub op: EffectOp,
    pub target: String,
    pub created_at: String,
    /// The process that persisted the intent; a reconcile
    /// that finds it live defers to it. An intent may carry none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner: Option<Owner>,
    pub outcome: Outcome,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
    /// The `overseer.pending` a transfer request overwrote, put back when
    /// the transfer fails.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub original_pending: Option<Value>,
    /// Why a transfer was asked for; a reconcile reads it to know what
    /// proves the predecessor terminal. Absent on the other
    /// operations and on a transfer recorded without one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cause: Option<TransferCause>,
    /// The owner that persisted the intent and handed it to the detached
    /// job that now owns it, written by the claim: the job
    /// lets that process answer and exit before it retires the pane the
    /// process asked from.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub handed_from: Option<Owner>,
    /// The companion's launch line a start carries: the program and its
    /// arguments, which the start's effect
    /// launches through the job launcher once the controller's lane is
    /// confirmed, and a reconcile launches again where no companion claims.
    /// Absent on the other operations and on a start whose caller holds
    /// the companion's start.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub watch: Option<Vec<String>>,
    /// The failure the detached job's outcome announced:
    /// the fleet-log row and the owner notice,
    /// sent once per intent and recorded here so a repeated
    /// reconcile of the same outcome emits nothing again. Absent until an
    /// outcome of a transfer or a stop failed or stayed unconfirmed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notice: Option<Notice>,
    /// How far the effect got, written before each wait; a
    /// reconciliation completes the effect from it. Absent until the effect
    /// has opened something.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub phase: Option<Phase>,
    /// The obligations the effect stands under: every
    /// handle it acquired, written before the wait that follows the
    /// acquisition, with the discharges made so far and whether anything was
    /// signalled. Every later step and every reconcile reads this set and
    /// never rebuilds it from the lane or the phase. Absent on an intent
    /// recorded without it; its next step writes it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub obligations: Option<ObligationRecord>,
    /// What the effect last observed of its target: the pane it opened or
    /// found, the process and screen it read, and for a succession whether
    /// the predecessor was retired. A reconciliation re-observes from it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub observation: Option<Value>,
    /// Set when the intent was closed because its target's record moved
    /// under it, with the status or generation the record then read; the
    /// outcome word stays what the effect reported.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reconciled: Option<Reconciled>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub observed_generation: Option<u64>,
    /// Members the frame does not own, which the program that records
    /// them reads and writes through its own view of the row: kept as
    /// written across every write of the frame, after the frame's own
    /// members where the whole row is written.
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

impl Intent {
    /// Whether the effect may still be in flight: its outcome is not final
    /// and no reconciliation closed it.
    pub fn open(&self) -> bool {
        if self.reconciled.is_some() {
            return false;
        }
        match self.outcome {
            Outcome::NotStarted | Outcome::Unconfirmed => true,
            Outcome::Confirmed | Outcome::Failed => false,
        }
    }
}
