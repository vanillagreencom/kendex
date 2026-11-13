//! Who a session with no lane item is at its turn end. The role decides the
//! marks a session meets and the hand-over it is told; the fleet record's
//! binding decides the facts the watch reads of it, so a session carries
//! both: a managed Jarvis session the record binds as its home's overseer
//! is judged as Jarvis and still keeps the binding's duties.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::rc::Rc;

use agent_runtime::controller::heal::Heal;
use agent_runtime::controller::status::{self, CallerKey};
use agent_runtime::host::{self, Place, tmux};
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

/// Jarvis's identity of a session, read by Jarvis's own record reader and
/// terminal check: `Session(DIR)` of `lib/session.py` reads the record the
/// launch names and asks the session's terminal whether it is the record's
/// live pane. Arguments: the owner's path, the directory, the launch's record
/// and generation, the harness, the native session, the caller's socket, its
/// pane, and `default` where the session names no launch, so the record is
/// the one `Session(DIR)` finds. Exit 1 where it names no session for the
/// caller; a record it cannot read raises, and its words are on stderr.
const JARVIS_IDENTITY: &str = r#"import json
from pathlib import Path
import runpy
import sys

owner = runpy.run_path(sys.argv[1])
session = owner["Session"](sys.argv[2])
default = sys.argv[9] == "default"
if (not default or sys.argv[3]) and session.path != Path(sys.argv[3]):
    sys.exit(1)
record = session.read()
if not record or record["state"] not in ("starting", "running") or record.get("harness") != sys.argv[5]:
    sys.exit(1)
identity = record.get("pending") or {}
terminal = record.get("terminal") or {}
if (((not default or sys.argv[4]) and str(identity.get("generation")) != sys.argv[4])
        or identity.get("native_session_id") != sys.argv[6]
        or terminal.get("server") != sys.argv[7]
        or (sys.argv[8] and terminal.get("pane") != sys.argv[8])
        or not session.terminal(record)):
    sys.exit(1)
print(json.dumps({"home": session.home, "account_home": record.get("effective_home") or record.get("account"),
                  "pane": terminal["pane"], "state": record["state"],
                  "record": str(session.path), "generation": identity.get("generation")}))
"#;

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

/// The Jarvis runtime record a launch names, and the generation it launched.
#[allow(dead_code, reason = "read by the rows' writer")]
#[derive(Debug, Clone)]
pub(super) struct Launch {
    pub record: PathBuf,
    pub generation: Option<String>,
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
    /// The Jarvis record named by the launch, or by the pane recovery.
    pub jarvis: Option<Launch>,
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

/// A managed Jarvis session as Jarvis's own record reader names it.
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
/// to its native session, else the pane of the managed Jarvis session
/// Jarvis's own reader finds for it. A session neither names is unjudged:
/// a context reading or a compaction is refused, and any other event tells
/// it once, the told file under the home's cache keeping it from being
/// told again; a later recovery judges it again.
pub(super) fn session_pane(turn: &mut Turn, vars: &Vars, lane: &Lane, payload: &Payload) -> Flow {
    if lane.item.is_some() {
        return Ok(());
    }
    let launch = vars.jarvis_record.clone().map(|record| Launch {
        record,
        generation: vars.jarvis_generation.clone(),
    });
    let recovers = match &turn.arm {
        Some(Arm::Row { .. } | Arm::Stop | Arm::Deliver | Arm::Halt | Arm::Usage) => true,
        Some(Arm::Compact) => payload.trigger == "auto",
        _ => false,
    };
    let (key, jarvis) = match vars.tmux_pane.as_deref() {
        Some(pane) => (key_on(vars, pane), launch),
        None if vars.tmux_socket.is_some() && recovers && turn.caller != Caller::Subagent => {
            match recovered(turn, vars, lane, payload, launch.as_ref()) {
                Ok((key, Some(jarvis))) => (Some(key), Some(jarvis)),
                Ok((key, None)) => (Some(key), launch),
                Err(cause) => return unjudged(turn, vars, lane, payload, &cause),
            }
        }
        None => (None, launch),
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
        jarvis,
        ..Role::default()
    });
    Ok(())
}

/// The pane a session that lost `TMUX_PANE` sits on, on the server
/// `$TMUX`'s socket answers: the fleet record's controller pane where the
/// record names this native session and, read again with that pane as the
/// caller's, binds it there; else the pane of the managed Jarvis session
/// Jarvis's own reader finds running for this session by its home, with
/// its record and generation. `Err` with why neither was recovered.
fn recovered(
    turn: &mut Turn,
    vars: &Vars,
    lane: &Lane,
    payload: &Payload,
    launch: Option<&Launch>,
) -> Result<(Key, Option<Launch>), String> {
    let mut cause = "no controller record binds this native session to a live pane".to_owned();
    let settings = marks::marks_settings(&lane.root, vars.private_env)
        .map_err(|e| format!("{cause}; the settings could not be loaded: {e}"))?;
    if let Some(key) = controller_pane(turn, vars, &settings, payload) {
        return Ok((key, None));
    }
    let ask = Ask {
        launch,
        pane: "",
        default: true,
    };
    match jarvis_identity(turn, vars, &settings, &lane.root, payload, &ask) {
        Ok(Some(identity)) => {
            let key = key_on(vars, &identity.pane);
            if let (Some(key), Some(generation)) = (key, identity.generation) {
                let jarvis = Launch {
                    record: identity.record,
                    generation: Some(generation),
                };
                return Ok((key, Some(jarvis)));
            }
        }
        Ok(None) => {}
        Err(words) => cause = format!("{cause}; {}", words.trim_end()),
    }
    Err(cause)
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
/// loaded place none. Who the session is comes after: a managed Jarvis
/// session is Jarvis whatever the record binds; else the controller the
/// record binds at a repository's root is the overseer; else the session
/// is no controller.
pub(super) fn read(turn: &mut Turn, vars: &Vars, lane: &Lane, payload: &Payload) {
    if lane.item.is_some() || turn.caller == Caller::Subagent {
        return;
    }
    let Some(key) = turn.role.key.clone() else {
        return;
    };
    let Ok(settings) = marks::marks_settings(&lane.root, vars.private_env) else {
        return;
    };
    let binding = controller(turn, vars, &settings, payload, &key);
    let kind = match jarvis(turn, vars, &settings, lane, payload, &key) {
        Some(jarvis) => Kind::Jarvis(jarvis),
        None => match (&binding, &lane.common) {
            (Binding::Bound(_), Some(_)) => Kind::Overseer,
            _ => Kind::None,
        },
    };
    turn.role = Rc::new(Role {
        key: Some(key),
        unkeyed: turn.role.unkeyed.clone(),
        jarvis: turn.role.jarvis.clone(),
        kind,
        binding,
    });
}

/// The managed Jarvis session the caller is, at a turn end or a context
/// reading of a session whose launch names its Jarvis record: the record
/// Jarvis's own reader finds running for this session on its live pane. A
/// record that reader cannot read is told and names no session.
fn jarvis(
    turn: &mut Turn,
    vars: &Vars,
    settings: &Settings,
    lane: &Lane,
    payload: &Payload,
    key: &Key,
) -> Option<Jarvis> {
    if !matches!(turn.arm, Some(Arm::Stop | Arm::Usage)) || payload.session.is_empty() {
        return None;
    }
    let launch = turn.role.jarvis.clone()?;
    let ask = Ask {
        launch: Some(&launch),
        pane: &key.pane,
        default: false,
    };
    match jarvis_identity(turn, vars, settings, &lane.root, payload, &ask) {
        Ok(Some(identity)) if identity.state == "running" => Some(Jarvis {
            home: identity.home,
            account_home: identity.account_home,
        }),
        Ok(_) => None,
        Err(cause) => {
            turn.note(&Said::JarvisRecordUnread(launch.record), &cause);
            None
        }
    }
}

/// A managed session as Jarvis's own reader names it.
struct Identity {
    home: PathBuf,
    account_home: String,
    state: String,
    pane: String,
    record: PathBuf,
    /// The launching generation where the record spells it as a number.
    generation: Option<String>,
}

/// What Jarvis's reader is asked to match: the launch's record and
/// generation, the caller's pane (empty: any), and whether a session that
/// names no launch is found by its home.
struct Ask<'a> {
    launch: Option<&'a Launch>,
    pane: &'a str,
    default: bool,
}

/// Jarvis's identity of the caller ([`JARVIS_IDENTITY`]), by the owner
/// beside the mailbox reader the settings name, within what is left of the
/// turn end's deadline: `Ok(None)` where no owner is installed there or it
/// names no session for the caller, `Err` with its words where it could not
/// answer.
#[allow(
    clippy::disallowed_methods,
    reason = "the turn end's one read of Jarvis's identity, Jarvis's own record reader and terminal check through the one runner, until the Jarvis callers move onto the controller's status read; it acts on nothing"
)]
fn jarvis_identity(
    turn: &Turn,
    vars: &Vars,
    settings: &Settings,
    root: &Path,
    payload: &Payload,
    ask: &Ask,
) -> Result<Option<Identity>, String> {
    let Ask {
        launch,
        pane,
        default,
    } = *ask;
    let skills = settings
        .lane_mail_cli
        .parent()
        .filter(|scripts| scripts.ends_with("mailbox/scripts"))
        .and_then(Path::parent)
        .and_then(Path::parent);
    let Some(owner) = skills.map(|skills| skills.join("jarvis/scripts/lib/session.py")) else {
        return Ok(None);
    };
    let socket = vars.tmux_socket.as_deref().unwrap_or(Path::new(""));
    let record = launch.map_or(Some(""), |launch| launch.record.to_str());
    let generation = launch.and_then(|launch| launch.generation.as_deref());
    let (Some(owner_word), Some(root), Some(record), Some(socket)) =
        (owner.to_str(), root.to_str(), record, socket.to_str())
    else {
        return Ok(None);
    };
    match std::fs::metadata(&owner) {
        Ok(meta) if meta.is_file() => {}
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
            return Err(format!("{}: {e}", owner.display()));
        }
        Ok(_) | Err(_) => return Ok(None),
    }
    let Some(bound) = turn.deadline.left() else {
        return Ok(None);
    };
    let mode = if default { "default" } else { "" };
    let args = [
        "-I",
        "-c",
        JARVIS_IDENTITY,
        owner_word,
        root,
        record,
        generation.unwrap_or_default(),
        marks::harness_word(turn.harness),
        &payload.session,
        socket,
        pane,
        mode,
    ];
    let env = [("JARVIS_BASH", OsStr::new("bash"))];
    let out = host::run_tagged_in(
        "turn-end",
        "python3",
        Path::new("python3"),
        "jarvis-identity",
        &args,
        Place {
            cwd: None,
            env: &env,
        },
        bound,
    )
    .map_err(|e| e.to_string())?;
    if !out.status.success() {
        let words = host::stderr_text(&out);
        return if words.trim().is_empty() {
            Ok(None)
        } else {
            Err(words)
        };
    }
    let Ok(answer) = serde_json::from_str::<Value>(&host::stdout_text(&out)) else {
        return Ok(None);
    };
    let text = |field: &str| answer[field].as_str().unwrap_or_default().to_owned();
    let generation = &answer["generation"];
    Ok(Some(Identity {
        home: PathBuf::from(text("home")),
        account_home: text("account_home"),
        state: text("state"),
        pane: text("pane"),
        record: PathBuf::from(text("record")),
        generation: generation.is_number().then(|| generation.to_string()),
    }))
}

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
