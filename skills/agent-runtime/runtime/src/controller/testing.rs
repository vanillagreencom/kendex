//! The controller rows' world: a fleet record with a controller at
//! generation 3, the stamp every row mints with, the request builders and
//! the typed readbacks of a written record.

use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};

use serde_json::{Value, json};

use super::transition::{OverseerExpected, Report, Request, RequestTransfer, apply_interleaved};
use super::{MEMBER, Overseer, Pending, TransferCause};
use crate::error::Result;
use crate::intent::{Intent, LaunchIdentity, Owner};
use crate::journal::{Effect, Env, RecordOutcome};
use crate::protocol::Outcome;
use crate::record::{self, Document, Locking};
use crate::settings::{ControllerSettings, ENGINE_KEYS, Keys};

/// A fleet record with a controller at generation 3 and its lanes.
pub(super) const FLEET: &str =
    include_str!("../../../tests/rust/fixtures/workflow-state-oversee.json");

pub(super) const NOW_SECS: u64 = 1_769_700_000;
pub(super) const NOW_NANOS: u128 = 1_769_700_000_123_456_789;
pub(super) const BASE_NONCE: u32 = 4242;
pub(super) const LOCK: Locking = Locking::FLOCK;

/// The owner every row persists its intents with: a synthetic identity,
/// since these rows never judge an owner's liveness.
pub(super) fn owner() -> Owner {
    Owner {
        pid: 424_242,
        start: "ticks:424242".to_owned(),
    }
}

/// The base stamp a row mints with.
pub(super) fn env() -> Env {
    Env {
        now_secs: NOW_SECS,
        now_nanos: NOW_NANOS,
        nonce: BASE_NONCE,
        owner: Some(owner()),
    }
}

/// The nonces `run` mints: one per call, as one process mints one `Env`
/// per request, so two calls never replay a stamp.
pub(super) static NONCES: AtomicU32 = AtomicU32::new(BASE_NONCE + 1);

/// What one committed request answered.
#[derive(Debug)]
pub(super) struct Applied {
    pub report: Report,
}

pub(super) fn fleet_file(dir: &Path) -> PathBuf {
    let path = dir.join(record::FLEET_FILE_NAME);
    fs::write(&path, FLEET).unwrap();
    path
}

/// Apply `request` under `env`, committing as the runtime does.
pub(super) fn apply_as(
    path: &Path,
    request: &Request,
    env: &Env,
    locking: Locking,
) -> Result<Applied> {
    interleaved(path, request, env, locking, &|| {})
}

/// Apply `request` under `env` with `between` run after the transition and
/// before the store on each attempt.
pub(super) fn interleaved(
    path: &Path,
    request: &Request,
    env: &Env,
    locking: Locking,
    between: &dyn Fn(),
) -> Result<Applied> {
    apply_interleaved(path, request, env, locking, between).map(|report| Applied { report })
}

/// Apply `request` as one call of the runtime: a fresh stamp each time.
pub(super) fn run(path: &Path, request: &Request) -> Result<Applied> {
    let env = Env {
        nonce: NONCES.fetch_add(1, Ordering::Relaxed),
        ..env()
    };
    apply_as(path, request, &env, LOCK)
}

pub(super) fn keys(doc: &Document) -> Vec<String> {
    doc.keys().cloned().collect()
}

/// The id of the intent a start, transfer or stop report carries.
pub(super) fn intent_id(applied: &Applied) -> String {
    let effect = match &applied.report {
        Report::RequestTransfer(t) => &t.effect,
        Report::StartController(s) => &s.effect,
        Report::StopController(s) => &s.effect,
        other => panic!("no intent on {other:?}"),
    };
    match effect {
        Effect::Reconciled { intent }
        | Effect::Persisted { intent }
        | Effect::Supersedes { intent } => intent.id.clone(),
    }
}

/// Run `request`, which creates or reconciles an intent, and return its
/// id.
pub(super) fn intend(path: &Path, request: &Request) -> String {
    intent_id(&run(path, request).unwrap())
}

pub(super) fn object(path: &Path) -> Document {
    match serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap() {
        Value::Object(map) => map,
        other => panic!("not an object: {other}"),
    }
}

/// The record's members these rows read back.
pub(super) struct Fleet {
    pub overseer: Option<Overseer>,
    pub intents: Vec<Intent>,
    pub fleet_log: Vec<Value>,
}

pub(super) fn fleet(path: &Path) -> Fleet {
    let doc = object(path);
    Fleet {
        overseer: record::field(path, &doc, MEMBER).unwrap(),
        intents: record::field(path, &doc, "intents")
            .unwrap()
            .unwrap_or_default(),
        fleet_log: record::field(path, &doc, "fleet_log")
            .unwrap()
            .unwrap_or_default(),
    }
}

/// The hand-over's settings under `pairs` and nothing else set.
pub(super) fn settings(dir: &Path, pairs: &[(&str, &str)]) -> ControllerSettings {
    let environment: Vec<(OsString, OsString)> = pairs
        .iter()
        .map(|(k, v)| (OsString::from(k), OsString::from(v)))
        .collect();
    let keys = Keys {
        read: &[ENGINE_KEYS],
        load: &[],
    };
    ControllerSettings::read(&crate::settings::layered(dir, &environment, false, &keys).unwrap())
}

pub(super) fn identity(pane: &str, pid: u64) -> LaunchIdentity {
    LaunchIdentity {
        pane: Some(pane.into()),
        server: Some(41020),
        server_start: None,
        pid: Some(pid),
        start: Some(format!("ticks:{pid}")),
    }
}

pub(super) fn outcome(id: &str, outcome: Outcome) -> Request {
    Request::RecordOutcome(Box::new(RecordOutcome {
        intent_id: id.into(),
        outcome,
        launch: Some(identity("%12", 6000)),
        session_id: Some("native-1".into()),
        server_start: None,
        server_socket: None,
        window: None,
        home: None,
        watch: None,
        members: serde_json::Map::new(),
        observation: None,
        while_owner: None,
        principal_keys: None,
        notice: None,
        set_revision: None,
    }))
}

/// A confirmation whose `launch` is `launch`, with or without the tmux
/// server's start.
pub(super) fn confirmed_with(
    id: &str,
    launch: Option<LaunchIdentity>,
    server_start: Option<u64>,
) -> Request {
    Request::RecordOutcome(Box::new(RecordOutcome {
        intent_id: id.into(),
        outcome: Outcome::Confirmed,
        launch,
        session_id: None,
        server_start,
        server_socket: None,
        window: None,
        home: None,
        watch: None,
        members: serde_json::Map::new(),
        observation: None,
        while_owner: None,
        principal_keys: None,
        notice: None,
        set_revision: None,
    }))
}

/// jq's `. // ""` on one member: the member unless it is absent, `null`
/// or `false`.
pub(super) fn alt(record: &Document, key: &str) -> Value {
    match record.get(key) {
        None | Some(Value::Null) | Some(Value::Bool(false)) => Value::from(""),
        Some(v) => v.clone(),
    }
}

/// `ol_owns($server; $start; $session)`, member for member, with jq's typed
/// equality: `ol_names`, the record naming `$server` as the string `--arg`
/// hands jq, `$session` as its `pane` (or `session`), and `$start` as its
/// `server_start`'s `tostring`; or `ol_unstarted`, the same server and
/// session with `server_start` null.
pub(super) fn ol_owns(record: &Document, server: &str, start: &str, session: &str) -> bool {
    let names_server_and_session = alt(record, "server") == server
        && (match record.get("pane") {
            None | Some(Value::Null) | Some(Value::Bool(false)) => alt(record, "session"),
            Some(pane) => pane.clone(),
        }) == session;
    let jq_tostring = |v: &Value| match v {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    };
    let ol_names = names_server_and_session
        && jq_tostring(record.get("server_start").unwrap_or(&Value::Null)) == start;
    let ol_unstarted =
        names_server_and_session && record.get("server_start").is_none_or(Value::is_null);
    ol_names || ol_unstarted
}

pub(super) fn successor() -> Pending {
    Pending {
        harness: Some("codex".into()),
        account: Some("/a/c2".into()),
        home: Some("/a/c2".into()),
        model: Some("gpt-5.5-codex".into()),
        effort: Some("high".into()),
        cwd: Some("/r".into()),
        class: None,
        resume: None,
        resume_file: None,
        permission: None,
        extra_args: Vec::new(),
        handoff: None,
        extra: Default::default(),
    }
}

/// The fixture controller as the requester saw it. `server` is the string
/// the shell writers hand jq through `--arg`; a lane's `launch.server` is a
/// number.
pub(super) fn expected() -> OverseerExpected {
    OverseerExpected {
        server: json!("41020"),
        server_start: json!(1769590000),
        pane: json!("%7"),
        generation: json!(3),
        launch_line: json!(
            "cd /home/u/dev/kendex && CLAUDE_CONFIG_DIR=/home/u/.claude-lanes/a1 claude --model claude-opus-5-5 --effort high"
        ),
        cwd: json!("/home/u/dev/kendex"),
        session_id: None,
        pending: Value::Null,
    }
}

pub(super) fn transfer(expected: OverseerExpected) -> Request {
    Request::RequestTransfer(Box::new(RequestTransfer {
        expected,
        successor: successor(),
        brief_file: None,
        session: None,
        cause: TransferCause::Live,
        exclude_account: None,
        handoff_session_id: None,
        recovery: None,
        death: None,
    }))
}
