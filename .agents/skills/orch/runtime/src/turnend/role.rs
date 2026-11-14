//! Who a session with no lane item is at its turn end. The role decides the
//! marks a session meets and the hand-over it is told; the fleet record's
//! binding decides the facts the watch reads of it, so a session carries
//! both: a managed Jarvis session the record binds as its home's overseer
//! is judged as Jarvis and still keeps the binding's duties.

use std::path::{Path, PathBuf};
use std::rc::Rc;

use agent_runtime::controller::heal::Heal;
use agent_runtime::controller::status::{self, CallerKey};
use agent_runtime::host::tmux;
use agent_runtime::journal::Env;
use agent_runtime::record::{self, Locking};
use serde_json::Value;

use super::answer::{self, Harness, Said};
use super::identity::Lane;
use super::marks;
use super::payload::{Caller, Payload};
use super::{Arm, Flow, Turn, Vars};
use crate::ops::store::{self, Write};
use crate::settings::Settings;

/// The caller's session as every record keys it: the tmux server answering
/// the socket `$TMUX` names, its start, and the pane the caller sits on.
#[allow(
    dead_code,
    reason = "read by the rows' writer and the controllers' turn ends"
)]
#[derive(Debug, Clone)]
pub(super) struct Key {
    pub socket: PathBuf,
    pub server: u32,
    pub start: u64,
    pub pane: String,
}

/// What a session with no lane item is.
#[allow(
    dead_code,
    reason = "read by the controllers' turn ends and Copilot usage"
)]
#[derive(Debug, Default)]
pub(super) struct Role {
    /// `None` outside tmux, or where no pane is named or recovered.
    pub key: Option<Key>,
    /// Why no key was made for the pane `TMUX_PANE` names: the server
    /// `$TMUX` names did not answer.
    pub unkeyed: Option<String>,
    pub kind: Kind,
    pub binding: Binding,
}

/// Who the session is: the marks and the hand-over follow it.
#[allow(
    dead_code,
    reason = "read by the controllers' turn ends and Copilot usage"
)]
#[derive(Debug, Default)]
pub(super) enum Kind {
    #[default]
    None,
    /// The fleet record binds this session at a repository's root.
    Overseer,
    Jarvis(Jarvis),
}

/// What the fleet record binds: the watch's facts follow it.
#[allow(dead_code, reason = "read by the controllers' turn ends")]
#[derive(Debug, Default)]
pub(super) enum Binding {
    #[default]
    None,
    /// The record names this session's pane on its server and its native
    /// identity admits this session.
    Bound(Controller),
    /// The record names this session's native identity on another pane:
    /// the controller the record lost.
    Lost(Controller),
}

/// The fleet record's controller as this session read it.
#[allow(dead_code, reason = "read by the controllers' turn ends")]
#[derive(Debug)]
pub(super) struct Controller {
    pub fleet: PathBuf,
    /// The controller member, as healed where the heal wrote.
    pub recorded: Value,
    /// The launch home: the recorded one, else the caller's own.
    pub home: String,
}

/// A managed Jarvis session: the bound controller whose record names the
/// Jarvis seat, its home the record's working directory.
#[allow(dead_code, reason = "read by the controllers' turn ends")]
#[derive(Debug)]
pub(super) struct Jarvis {
    pub home: PathBuf,
    pub account_home: String,
}

/// The caller's key, for a session with no lane item: a lane's item
/// already names it, and no record keys a lane by its pane. Where a session
/// in tmux has no pane named, its lead's row, turn end, tool call, context
/// reading or automatic compaction recovers the pane the fleet record binds
/// to its native session. A session it names on no pane is unjudged:
/// a context reading or a compaction is refused, and any other event tells
/// it once, the told file under the home's cache keeping it from being
/// told again; a later recovery judges it again.
pub(super) fn session_pane(turn: &mut Turn, vars: &Vars, lane: &Lane, payload: &Payload) -> Flow {
    if lane.item.is_some() {
        return Ok(());
    }
    let recovers = match &turn.arm {
        Some(Arm::Row { .. } | Arm::Stop | Arm::Deliver | Arm::Halt | Arm::Usage) => true,
        Some(Arm::Compact) => payload.trigger == "auto",
        _ => false,
    };
    let key = match vars.tmux_pane.as_deref() {
        Some(pane) => key_on(vars, pane),
        None if vars.tmux_socket.is_some() && recovers && turn.caller != Caller::Subagent => {
            match recovered(turn, vars, lane, payload) {
                Ok(key) => Some(key),
                Err(cause) => return unjudged(turn, vars, lane, payload, &cause),
            }
        }
        None => None,
    };
    // A named pane on a socket that is set keys nothing only where its
    // server did not answer.
    let unkeyed = match (&key, vars.tmux_pane.as_deref(), &vars.tmux_socket) {
        (None, Some(pane), Some(_)) => Some(format!("pane=unkeyed tmux_pane={pane}")),
        _ => None,
    };
    turn.role = Rc::new(Role {
        key,
        unkeyed,
        ..Role::default()
    });
    Ok(())
}

/// The pane a session that lost `TMUX_PANE` sits on, on the server
/// `$TMUX`'s socket answers: the fleet record's controller pane where the
/// record names this native session and, read again with that pane as the
/// caller's, binds it there. `Err` with why none was recovered.
fn recovered(turn: &mut Turn, vars: &Vars, lane: &Lane, payload: &Payload) -> Result<Key, String> {
    let cause = "no controller record binds this native session to a live pane";
    let settings = marks::marks_settings(turn, &lane.root, vars.private_env)
        .map_err(|e| format!("{cause}; the settings could not be loaded: {e}"))?;
    controller_pane(turn, vars, &settings, payload).ok_or_else(|| cause.to_owned())
}

/// The fleet record's controller pane for this native session: one status
/// read with no caller names the session's pane, and a second, with that
/// pane on the caller's own server as the caller, holds it only where the
/// record binds it there, on its server's start or on none, and its native
/// identity admits this session.
fn controller_pane(
    turn: &Turn,
    vars: &Vars,
    settings: &Settings,
    payload: &Payload,
) -> Option<Key> {
    let fleet = record::fleet_path(&settings.state_dir);
    let named = status::status(&fleet, &settings.engine, None)
        .ok()?
        .recorded?;
    if named["session_id"].as_str() != Some(payload.session.as_str()) {
        return None;
    }
    let key = key_on(
        vars,
        named["pane"].as_str().filter(|pane| !pane.is_empty())?,
    )?;
    let server = key.server.to_string();
    let home = caller_home(turn.harness, vars);
    let caller = CallerKey {
        server: &server,
        socket: Some(&key.socket),
        pane: &key.pane,
        harness: marks::harness_word(turn.harness),
        home: &home,
        session: &payload.session,
    };
    let answer = status::status(&fleet, &settings.engine, Some(&caller))
        .ok()?
        .caller?;
    let held = matches!(
        answer.binding,
        status::Binding::Bound | status::Binding::Unstarted
    );
    (held && answer.native_match).then_some(key)
}

/// The answer for a session in tmux that names no pane and recovered none:
/// a context reading or a compaction is refused; any other event is told
/// once, through the harness's visible warning on Claude Code and Codex and
/// as context on any other, and the told file under the home's cache is
/// written, so a later event passes on.
fn unjudged(turn: &mut Turn, vars: &Vars, lane: &Lane, payload: &Payload, cause: &str) -> Flow {
    if matches!(turn.arm, Some(Arm::Usage | Arm::Compact)) {
        return Err(turn.refuse(Said::SessionUnjudged, cause));
    }
    let session = if payload.session.is_empty() {
        "unknown"
    } else {
        &payload.session
    };
    let home = if vars.home.is_empty() {
        lane.root.clone()
    } else {
        PathBuf::from(&vars.home)
    };
    let told = home
        .join(".cache/lane-mail/unjudged")
        .join(format!("{}-{session}", marks::harness_word(turn.harness)));
    if std::fs::metadata(&told).is_ok_and(|meta| meta.is_file()) {
        return Ok(());
    }
    let notice = Said::SessionUnjudged.text(cause);
    let stdout = match turn.harness {
        Harness::Claude | Harness::Codex => {
            format!("{}\n", serde_json::json!({ "systemMessage": notice }))
        }
        Harness::Copilot | Harness::Pi | Harness::Unlisted => {
            let event = turn.arm.as_ref().and_then(Arm::context_event);
            answer::context(turn.harness, event.unwrap_or_default(), &notice, None)
        }
    };
    if let Err(e) = told_once(&told) {
        turn.note(&Said::SessionUnjudgedCache(told), &e.to_string());
    }
    Err(turn.said(&stdout))
}

/// The empty file that records a session told it is unjudged.
#[allow(
    clippy::disallowed_methods,
    reason = "the unjudged notice's told file, its one writer: the user's cache, outside every source tree and every workflow record"
)]
fn told_once(told: &Path) -> std::io::Result<()> {
    if let Some(dir) = told.parent() {
        std::fs::create_dir_all(dir)?;
    }
    std::fs::write(told, "")
}

/// The caller's own key, `<server pid> <pane>`, which every record a lane's
/// session writes carries, so the review admission tells this session's
/// record from a predecessor's at another pane; `None` outside tmux or where
/// the server does not answer.
pub(super) fn pane_key(vars: &Vars) -> Option<String> {
    let key = key_on(vars, vars.tmux_pane.as_deref()?)?;
    Some(super::controller::caller_key(&key))
}

/// The key of `pane` on the server `$TMUX`'s socket names; `None` outside
/// tmux or where that server does not answer, which keys no record.
#[allow(
    clippy::disallowed_methods,
    reason = "the turn end's one read of the caller's own server: the pid and start its pane is keyed on, never an effect on it"
)]
fn key_on(vars: &Vars, pane: &str) -> Option<Key> {
    let socket = vars.tmux_socket.as_ref()?;
    let server = tmux::server(socket).ok()?;
    Some(Key {
        socket: server.socket,
        server: server.pid,
        start: server.start,
        pane: pane.to_owned(),
    })
}

/// The role, read once for every place after the row arm, for the lead of
/// a session with no lane item that sits on a keyed pane. The fleet record
/// is read through the controller's own status read; a record that is
/// missing or cannot be read binds nothing, as settings that cannot be
/// loaded place none. Who the session is comes after: at a turn end or a
/// context reading, the bound controller whose record names the Jarvis
/// seat is Jarvis; else the controller the record binds at a repository's
/// root is the overseer; else the session is no controller.
pub(super) fn read(turn: &mut Turn, vars: &Vars, lane: &Lane, payload: &Payload) {
    if lane.item.is_some() || turn.caller == Caller::Subagent {
        return;
    }
    let Some(key) = turn.role.key.clone() else {
        return;
    };
    let Ok(settings) = marks::marks_settings(turn, &lane.root, vars.private_env) else {
        return;
    };
    let binding = controller(turn, vars, &settings, payload, &key);
    let kind = match (&binding, &lane.common) {
        (Binding::Bound(bound), _) if jarvis_seat(turn, payload, bound) => Kind::Jarvis(Jarvis {
            home: PathBuf::from(bound.recorded["cwd"].as_str().unwrap_or_default()),
            account_home: bound.home.clone(),
        }),
        (Binding::Bound(_), Some(_)) => Kind::Overseer,
        _ => Kind::None,
    };
    turn.role = Rc::new(Role {
        key: Some(key),
        unkeyed: turn.role.unkeyed.clone(),
        kind,
        binding,
    });
}

/// Whether the bound controller is the Jarvis seat, read at a turn end or a
/// context reading: its record names the seat its start named, which every
/// hand-over keeps.
fn jarvis_seat(turn: &Turn, payload: &Payload, bound: &Controller) -> bool {
    matches!(turn.arm, Some(Arm::Stop | Arm::Usage))
        && !payload.session.is_empty()
        && bound.recorded["seat"].as_str() == Some(JARVIS_SEAT)
}

/// The seat word a Jarvis start names on its controller record.
const JARVIS_SEAT: &str = "jarvis";

/// What the fleet record at this root binds of the caller: its controller
/// where the record names the caller's pane on its server's start, or on no
/// start, and its native identity admits the caller's session, healed of
/// what it lacks; the controller the record lost where it names the
/// caller's native identity on another pane. A native mismatch on the
/// caller's own pane is told, since the remedy is this session's to run; on
/// another pane it is silent, since the remedy is that pane's.
fn controller(
    turn: &mut Turn,
    vars: &Vars,
    settings: &Settings,
    payload: &Payload,
    key: &Key,
) -> Binding {
    let fleet = record::fleet_path(&settings.state_dir);
    let harness = marks::harness_word(turn.harness);
    let home = caller_home(turn.harness, vars);
    let server = key.server.to_string();
    let caller = CallerKey {
        server: &server,
        socket: Some(&key.socket),
        pane: &key.pane,
        harness,
        home: &home,
        session: &payload.session,
    };
    let Ok(read) = status::status(&fleet, &settings.engine, Some(&caller)) else {
        return Binding::None;
    };
    let (Some(recorded), Some(answer)) = (read.recorded, read.caller) else {
        return Binding::None;
    };
    let word = |field: &str| match &recorded[field] {
        Value::String(text) => text.clone(),
        Value::Number(number) => number.to_string(),
        _ => String::new(),
    };
    let held = matches!(
        answer.binding,
        status::Binding::Bound | status::Binding::Unstarted
    );
    if !answer.native_match {
        if held {
            let none = |text: String| {
                if text.is_empty() {
                    "none".to_owned()
                } else {
                    text
                }
            };
            let unbound = Said::SessionUnbound {
                session: none(payload.session.clone()),
                harness: none(word("harness")),
                home: none(word("home")),
            };
            turn.note(&unbound, "");
        }
        return Binding::None;
    }
    let recorded_home = word("home");
    let controller = |recorded: Value| Controller {
        fleet: fleet.clone(),
        recorded,
        home: if recorded_home.is_empty() {
            home.clone()
        } else {
            recorded_home.clone()
        },
    };
    if !held {
        if answer.binding == status::Binding::Other && !word("session_id").is_empty() {
            return Binding::Lost(controller(recorded));
        }
        return Binding::None;
    }
    let lacks = answer.binding != status::Binding::Bound
        || (word("harness").is_empty() && !harness.is_empty())
        || word("session_id").is_empty()
        || (recorded_home.is_empty() && transcript_home(turn.harness));
    if !lacks {
        return Binding::Bound(controller(recorded));
    }
    let heal = Heal {
        server,
        pane: key.pane.clone(),
        start: key.start.to_string(),
        harness: harness.to_owned(),
        home: home.clone(),
        session: payload.session.clone(),
    };
    let written = Env::system().map_err(crate::Error::from).and_then(|env| {
        store::run_write(
            &fleet,
            Locking::FLOCK,
            &settings.store,
            &env,
            &Write::Heal(heal),
        )
    });
    match written {
        Ok(healed) => Binding::Bound(controller(healed["overseer"].clone())),
        Err(e) => {
            let caller_key = format!("{} {}", key.server, key.pane);
            turn.note(&Said::RecordUnhealed(caller_key), &e.to_string());
            Binding::None
        }
    }
}

/// Whether a session of `harness` has a transcript bound to its launch
/// home, so a record naming no home lacks one.
fn transcript_home(harness: Harness) -> bool {
    matches!(harness, Harness::Claude | Harness::Codex | Harness::Copilot)
}

/// The launch home a session of `harness` runs from, off its own
/// environment: the directory its harness variable names, else the
/// harness's own default under `LANES_HOME`, else the home; Codex's is
/// `CODEX_HOME` as it stands, where its rollouts are written. A harness with
/// no transcript shape has none.
fn caller_home(harness: Harness, vars: &Vars) -> String {
    let (variable, default) = match harness {
        Harness::Claude => ("CLAUDE_CONFIG_DIR", ".claude"),
        Harness::Codex => ("CODEX_HOME", ".codex"),
        Harness::Copilot => ("COPILOT_HOME", ".copilot"),
        Harness::Pi | Harness::Unlisted => return String::new(),
    };
    let set = |name: &str| std::env::var_os(name).filter(|value| !value.is_empty());
    if let Some(home) = set(variable) {
        return home.to_string_lossy().into_owned();
    }
    let base = set("LANES_HOME").map_or_else(|| PathBuf::from(&vars.home), PathBuf::from);
    base.join(default).display().to_string()
}
