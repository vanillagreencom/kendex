//! The controller record's parts: the successor a succession is about to
//! open, the keys a succession writes, compares and drops, the record as a
//! succession reads it, the watch job it names, why a succession was
//! asked for, and the adoption of a controller this runtime did not launch.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::launch::Permission;
use crate::process::Identity;

/// The successor a succession is about to open, `overseer.pending`: the
/// identity fields the record carries, the typed launch fields the runtime
/// builds the command from (the permission posture and the caller's own
/// words) and the native session it continues where it resumes one.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Pending {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub home: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub class: Option<String>,
    /// The native session the launch continues in place of starting one:
    /// its file must stand under `home` for `cwd`, and Pi has no form for it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume: Option<String>,
    /// The permission posture the launch runs under: `bypass`, or `native`
    /// with the caller's own permission words among `extra_args`. Left out,
    /// the runtime's launch permission setting decides.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission: Option<Permission>,
    /// The caller's own launch words beyond what the builder spells from the
    /// typed fields: its permission words under `native`, and whatever else
    /// the walk carried over, as given.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub extra_args: Vec<String>,
    /// The overseer handoff the controller's brief names, the launch's own
    /// `--handoff`; left out, the default handoff. The record keeps it, so a
    /// recovery the watch asks names the same file.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub handoff: Option<String>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

/// The keys a confirmed succession writes from `pending` onto the overseer
/// record, and nulls where the pending names none: the launch's identity.
/// `class` is not among them: a record carries it
/// only where its launch knew it, so the successor record has the key only
/// when `pending` does.
pub const SUCCESSOR_IDENTITY_KEYS: &[&str] =
    &["harness", "account", "home", "model", "effort", "cwd"];

/// The binding `ol_record_write` reads afresh from the session it writes for
/// and a transfer confirmation does not know: a different session inherits
/// none of the prior's. The successor's watch start fills them; until then a
/// confirmed succession nulls each the record holds. `pane`, `server` and
/// `server_start` are not among them: the confirmation writes the first two
/// from the successor's launch identity, and the third where it carries it,
/// so the record passes `ol_owns` from the successor's pane and that watch
/// start keeps it.
pub const SUCCESSOR_BINDING_KEYS: &[&str] = &["window", "session_rows"];

/// The keys of the session that ended, which a different session's record
/// leaves out: the native session id, the harness process and its model
/// check, the recorded exit, the pending it just opened, and the display
/// line a released launcher wrote for it.
pub const PREDECESSOR_SESSION_KEYS: &[&str] = &[
    "session_id",
    "harness_pid",
    "harness_start",
    "model_check",
    "exit",
    "pending",
    "launch_line",
];

/// The keys the succession compare-and-swap requires equal, less
/// `session_id` and `pending`, which it judges on their own.
pub const OVERSEER_COMPARE_KEYS: &[&str] = &[
    "server",
    "server_start",
    "pane",
    "generation",
    "launch_line",
    "cwd",
];

/// The overseer session record as read: the fields a succession reads.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Overseer {
    #[serde(default)]
    pub generation: Option<u64>,
    #[serde(default)]
    pub session_id: Option<String>,
    #[serde(default)]
    pub pending: Option<Pending>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

/// The fleet watch the controller record carries as `overseer.watch`:
/// the job identity the launcher recorded for the watch a
/// start launched (`runner=systemd` with its unit, or `runner=setsid` with
/// the leader's pid and start), or `runner=claimed` with the claim's own
/// identity where a start found the watch already claimed. The claim beside
/// the fleet state stays the watch's liveness record; this field names what
/// started it. An additive field: a succession keeps it as it stands.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WatchJob {
    pub runner: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unit: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pid: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start: Option<String>,
}

/// Why a succession was asked for: the cause tells the effect
/// what proves the predecessor terminal and the transition what it must
/// refuse.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum TransferCause {
    /// The controller succeeds itself at one of its marks.
    #[default]
    Live,
    /// The watch read the controller dead: the held line is the successor
    /// and a predecessor with no recorded identity is proven terminal by
    /// the exit record or the pane.
    Dead,
    /// The controller's account is walled: the successor must not run on
    /// the spent account.
    Walled,
    /// A refused succession left a standing handoff; a fresh session takes
    /// over from it, retiring the still-live predecessor first.
    RefusedRecovery,
}

impl TransferCause {
    /// The cause's word as a request and the record carry it.
    pub fn word(self) -> &'static str {
        match self {
            TransferCause::Live => "live",
            TransferCause::Dead => "dead",
            TransferCause::Walled => "walled",
            TransferCause::RefusedRecovery => "refused-recovery",
        }
    }
}

/// Bind a controller this runtime did not launch: the pane a person opened
/// it in, on the fleet server (or the one `socket` names), and what the
/// person knows of its launch. The identity is read in that pane by the
/// effects, never taken from the caller.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AdoptController {
    pub pane: String,
    #[serde(default)]
    pub socket: Option<PathBuf>,
    pub harness: String,
    #[serde(default)]
    pub session_id: Option<String>,
    #[serde(default)]
    pub account: Option<String>,
    #[serde(default)]
    pub home: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub effort: Option<String>,
    #[serde(default)]
    pub cwd: Option<String>,
    /// The file the pane's own harness writes its session rows to, which
    /// the watch judges the controller's death and wall from.
    #[serde(default)]
    pub session_rows: Option<PathBuf>,
    /// The permission posture the session runs under and its own permission
    /// words, which the next succession launches with.
    #[serde(default)]
    pub permission: Option<Permission>,
    #[serde(default)]
    pub extra_args: Option<Vec<String>>,
}

/// What the effects read of the pane an adoption names, handed to the
/// transition: the harness identity in its foreground and the server and
/// window the pane is on.
#[derive(Debug, Clone, PartialEq)]
pub struct AdoptionRead {
    pub identity: Identity,
    pub server: u64,
    pub server_start: u64,
    pub socket: String,
    pub window: String,
    /// Whether the record already names this pane on this server
    /// (`ol_owns`): the record is healed, not replaced.
    pub same: bool,
}

/// A controller bound.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ControllerAdopted {
    pub generation: u64,
    /// True when the record already named this pane and was healed in
    /// place; false when the record was written for this session.
    pub healed: bool,
}
