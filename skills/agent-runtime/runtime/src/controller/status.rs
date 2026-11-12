//! The controller's identity read: what the record holds for its controller,
//! whether that controller still runs, the open controller intents, and,
//! for a caller that names its own pane, whether the record is that pane's
//! session. The turn-end check, the mailbox's peer reader and Jarvis's
//! status read it.

use std::path::Path;

use serde::Serialize;
use serde_json::Value;

use super::{MEMBER, Overseer};
use crate::effects::{Proof, overseer_socket, overseer_target_of, predecessor_identity, proof_of};
use crate::error::{Error, Result};
use crate::host::tmux;
use crate::process;
use crate::reading::Reading;
use crate::record;
use crate::settings::EngineSettings;

/// The caller's own session: its tmux server and pane, the socket its
/// server answers on, and its harness, launch home and native session id.
pub struct CallerKey<'a> {
    pub server: &'a str,
    pub socket: Option<&'a Path>,
    pub pane: &'a str,
    pub harness: &'a str,
    pub home: &'a str,
    pub session: &'a str,
}

/// How the record's controller stands to the caller's pane: `bound` names
/// that pane on the caller's server started at the recorded start;
/// `unstarted` names it on a record that carries no start; `other` names
/// anything else; `none` is a record with no controller.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Binding {
    Bound,
    Unstarted,
    Other,
    None,
}

/// What the caller group adds: the binding, whether the record's native
/// identity admits the caller's session, and the launch a model check is
/// bound to.
#[derive(Debug, Serialize)]
pub struct CallerAnswer {
    pub binding: Binding,
    pub native_match: bool,
    pub model_launch: Value,
}

/// An open controller intent.
#[derive(Debug, Serialize)]
pub struct OpenIntent {
    pub id: String,
    pub op: &'static str,
    pub target: String,
}

/// The status reply. `recorded` is the controller member as the record
/// holds it, null where the document holds none; `server_start` is the
/// recorded start.
#[derive(Debug, Serialize)]
pub struct Status {
    pub recorded: Option<Value>,
    pub live: bool,
    pub server_start: Value,
    pub open_intents: Vec<OpenIntent>,
    #[serde(flatten)]
    pub caller: Option<CallerAnswer>,
}

/// The fields of the launch a model check is bound to.
const MODEL_LAUNCH_KEYS: &[&str] = &[
    "server",
    "server_start",
    "pane",
    "generation",
    "launch_line",
    "cwd",
    "session_id",
];

/// The status of the controller the record at `path` holds; `record-missing`
/// where no document stands. A server is asked only on the socket the record
/// names or the caller's own.
pub fn status(
    path: &Path,
    settings: &EngineSettings,
    caller: Option<&CallerKey>,
) -> Result<Status> {
    let doc = record::read_document(path)?.ok_or_else(|| Error::RecordMissing {
        path: path.to_path_buf(),
    })?;
    let member: Option<Value> = record::field(path, &doc, MEMBER)?;
    let overseer: Option<Overseer> = record::field(path, &doc, MEMBER)?;
    let open_intents = crate::journal::intents(path, &doc)?
        .into_iter()
        .filter(|i| i.open() && i.op.on_controller())
        .map(|i| OpenIntent {
            id: i.id,
            op: i.op.word(),
            target: i.target,
        })
        .collect();
    let live = match &overseer {
        Some(overseer) => live(overseer, settings, caller.and_then(|c| c.socket))?,
        None => false,
    };
    let word = |key: &str| member.as_ref().map_or_else(String::new, |m| text(&m[key]));
    let caller = caller.map(|c| {
        let binding = match &overseer {
            None => Binding::None,
            Some(overseer) if word("server") == c.server && pane_of(&member) == c.pane => {
                match member.as_ref().map(|m| &m["server_start"]) {
                    None | Some(Value::Null) => Binding::Unstarted,
                    Some(recorded) => match caller_start(overseer, c) {
                        Some(start) if text(recorded) == start.to_string() => Binding::Bound,
                        Some(_) | None => Binding::Other,
                    },
                }
            }
            Some(_) => Binding::Other,
        };
        let either = |key: &str, given: &str| {
            let held = word(key);
            held.is_empty() || given.is_empty() || held == given
        };
        let native_match = !c.session.is_empty()
            && (word("harness").is_empty() || word("harness") == c.harness)
            && either("home", c.home)
            && (word("session_id").is_empty() || word("session_id") == c.session);
        let model_launch = member.as_ref().map_or(Value::Null, |m| {
            MODEL_LAUNCH_KEYS
                .iter()
                .map(|key| ((*key).to_owned(), m[*key].clone()))
                .collect::<serde_json::Map<_, _>>()
                .into()
        });
        CallerAnswer {
            binding,
            native_match,
            model_launch,
        }
    });
    Ok(Status {
        server_start: member
            .as_ref()
            .map_or(Value::Null, |m| m["server_start"].clone()),
        recorded: member,
        live,
        open_intents,
        caller,
    })
}

/// A record value as the shell writers compare it: a string as it is, a
/// number in decimal, anything else empty.
fn text(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        _ => String::new(),
    }
}

/// The session the record names: its pane on tmux, its session elsewhere.
fn pane_of(member: &Option<Value>) -> String {
    member.as_ref().map_or_else(String::new, |m| {
        let pane = text(&m["pane"]);
        if pane.is_empty() {
            text(&m["session"])
        } else {
            pane
        }
    })
}

/// The start of the caller's server, read on the caller's socket, else the
/// record's: none where no socket is named, none answers, or another server
/// answers there.
fn caller_start(overseer: &Overseer, caller: &CallerKey) -> Option<u64> {
    let socket = caller
        .socket
        .map(Path::to_path_buf)
        .or_else(|| overseer_socket(overseer))?;
    let server = tmux::server(&socket).ok()?;
    (server.pid.to_string() == caller.server).then_some(server.start)
}

/// Whether the recorded controller still runs: its recorded identity live,
/// else its recorded pane standing on the recorded server with no proof it
/// is gone; a kept-dead pane is no controller. A reading that cannot be
/// made refuses `controller-unreadable` with its cause rather than answer
/// either way.
fn live(overseer: &Overseer, settings: &EngineSettings, named: Option<&Path>) -> Result<bool> {
    let unreadable = |cause: &str| Error::refused("controller-unreadable", &[("cause", cause)]);
    if let Some(identity) = predecessor_identity(overseer) {
        return match process::still_runs(&identity) {
            Reading::Live(_) => Ok(true),
            Reading::Gone => Ok(false),
            Reading::Unreadable { cause } => Err(unreadable(cause)),
        };
    }
    let target = overseer_target_of(&settings.harness_binaries, overseer)?;
    match proof_of(overseer, target.as_ref(), named) {
        Proof::Standing { .. } => Ok(true),
        Proof::Proven { .. } | Proof::Empty | Proof::Unproven { .. } => Ok(false),
        Proof::Unreadable { cause } => Err(unreadable(cause)),
    }
}
