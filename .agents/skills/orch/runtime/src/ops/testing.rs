//! Fixtures and helpers the `ops` test modules share: the stamp every row
//! mints with, the request builders and the typed readbacks of a written
//! file.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};

use agent_runtime::process::Identity;
use agent_runtime::protocol::Outcome;
use agent_runtime::reading::Reading;
use serde_json::{Value, json};

use super::admission::{AdmissionReads, Clis, ItemRead, ScopeRange};
use super::{
    AdoptSession, Applied, CloseOwnedResources, Effect, Env, Host, LaunchLane, OverseerExpected,
    RecordOutcome, Report, Request, RequestTransfer, apply_on,
};
use crate::error::Result;
use crate::state::{
    self, Document, FleetState, ItemState, Lane, LaunchIdentity, Locking, Owner, Pending, Record,
    TransferCause, fixtures,
};

pub(super) const NOW_SECS: u64 = 1_769_700_000;
pub(super) const NOW_NANOS: u128 = 1_769_700_000_123_456_789;
pub(super) const BASE_NONCE: u32 = 4242;
pub(super) const LOCK: Locking = Locking::FLOCK;

/// The owner every test op persists its intents with: a
/// synthetic identity, since the `ops` rows never judge an owner's liveness;
/// that is the effects suite's, through the executable's own identity.
pub(super) fn owner() -> Owner {
    Owner {
        pid: 424_242,
        start: "ticks:424242".to_owned(),
    }
}

/// The base stamp a test op mints with; the `Env` holds a `String`, so it
/// is a value, not a const.
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

fn gone(_: &Identity) -> Reading<Identity> {
    Reading::Gone
}

/// The host every row judges against unless it plants its own: a cap of
/// four and a kernel that holds none of the fixtures' pids, so a fixture
/// lane never charges and a close reads its lane exited. Rows about
/// liveness hold their own children or plant their readings.
pub(super) fn host() -> Host<'static> {
    Host {
        lane_cap: 4,
        cloud_lane_cap: Some(4),
        still_runs: &gone,
        admission: Some(no_reads()),
        accounts: None,
    }
}

/// Programs no row here runs: the admission reads are planted.
pub(super) fn no_clis() -> Clis {
    Clis {
        tracker: PathBuf::from("/nonexistent/linear.sh"),
        gh: PathBuf::from("/nonexistent/gh"),
        scope_paths: PathBuf::from("/nonexistent/harness-only"),
    }
}

/// The admission reads of a fixture launch: an item whose body names no
/// Location, with no label and no child, a range with no path, and a fleet
/// in no checkout, so the admission judges nothing from them.
pub(super) fn no_reads() -> AdmissionReads<'static> {
    AdmissionReads {
        clis: no_clis(),
        item: Box::new(|_: &Clis, _: &str, _: &str, _: Option<&str>| {
            Ok(ItemRead {
                blocked_by_launch: Some(Vec::new()),
                ..ItemRead::default()
            })
        }),
        range_paths: Box::new(|_: &Clis, _: &Path, _: &ScopeRange| Ok(Vec::new())),
        pulls: Box::new(|_: &Clis, _: Option<&str>, _: Option<&Path>| Ok(None)),
        checkout: Box::new(|_: &Path| Ok(None)),
        team_key: Box::new(|_: &Clis, _: &str| Err("unplanted".to_owned())),
    }
}

pub(super) fn item_file(dir: &Path) -> PathBuf {
    let path = dir.join("workflow-state-KEN-4687.json");
    fs::write(&path, fixtures::ITEM).unwrap();
    path
}

pub(super) fn fleet_file(dir: &Path) -> PathBuf {
    let path = dir.join(state::FLEET_FILE_NAME);
    fs::write(&path, fixtures::FLEET).unwrap();
    path
}

/// Apply `request` as one call of the runtime: a fresh stamp each time.
pub(super) fn run(path: &Path, request: &Request) -> Result<Applied> {
    let env = Env {
        nonce: NONCES.fetch_add(1, Ordering::Relaxed),
        ..env()
    };
    apply_on(path, request, &env, LOCK, &host())
}

/// The id of the intent a launch, close or transfer report carries.
pub(super) fn intent_id(applied: &Applied) -> String {
    let effect = match &applied.report {
        Report::LaunchLane(l) => &l.effect,
        Report::CloseOwnedResources(c) => &c.effect,
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

pub(super) fn item(path: &Path) -> ItemState {
    ItemState::view(path, &object(path)).unwrap()
}

pub(super) fn fleet(path: &Path) -> FleetState {
    FleetState::view(path, &object(path)).unwrap()
}

pub(super) fn lane(path: &Path, item: &str) -> Lane {
    fleet(path)
        .lanes
        .into_iter()
        .find(|l| l.item == item)
        .unwrap()
}

pub(super) fn lane_doc(path: &Path, item: &str) -> Document {
    let doc = object(path);
    doc["lanes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|l| l["item"] == item)
        .unwrap()
        .as_object()
        .unwrap()
        .clone()
}

pub(super) fn keys(doc: &Document) -> Vec<String> {
    doc.keys().cloned().collect()
}

/// The fields of a launch request that names only what every launch must.
pub(super) fn launch_fields(item: &str) -> LaunchLane {
    LaunchLane {
        item: item.into(),
        harness: "claude".into(),
        mail_root: format!("/w/{item}"),
        permission: None,
        tracker: None,
        repo: None,
        account: None,
        model: None,
        effort: None,
        kind: None,
        host: None,
        surface: None,
        over_cap: None,
        exclude_account: None,
        judge_account: false,
        refresh: false,
        brief_file: None,
        repo_dir: None,
        scope_range: None,
        in_scope: Vec::new(),
        obligation: None,
    }
}

/// A launch request that names only what every launch must.
pub(super) fn launch(item: &str) -> Request {
    Request::LaunchLane(Box::new(launch_fields(item)))
}

pub(super) fn launch_full(item: &str) -> Request {
    Request::LaunchLane(Box::new(LaunchLane {
        tracker: Some("linear".into()),
        account: Some("/a/a1".into()),
        model: Some("claude-opus-5-5".into()),
        effort: Some("high".into()),
        ..launch_fields(item)
    }))
}

/// A bare close: no ground stated, so the lane must read exited.
pub(super) fn close(item: &str) -> Request {
    Request::CloseOwnedResources(CloseOwnedResources {
        item: item.into(),
        terminal: None,
        no_landing: None,
    })
}

pub(super) fn adopt(item: &str, session: &str, launch: Option<LaunchIdentity>) -> Request {
    Request::AdoptSession(Box::new(AdoptSession {
        item: item.into(),
        session_id: session.into(),
        harness: None,
        launch,
    }))
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
        tmux_session: None,
        launch_line: None,
        home: None,
        home_implicit: false,
        watch: None,
        mail_root: None,
        observation: None,
        while_owner: None,
        lane_keys: None,
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
        tmux_session: None,
        launch_line: None,
        home: None,
        home_implicit: false,
        watch: None,
        mail_root: None,
        observation: None,
        while_owner: None,
        lane_keys: None,
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

/// `ol_owns($server; $start; $session)` as `OL_JQ_DEFS` defines it
/// (`overseer-launch.sh`) and the watch start applies it to the record
/// it meets (`watch-overseer-record.sh`'s `overseer_command_record`),
/// member for member, with
/// jq's typed equality: `ol_names`, the record naming `$server` as the
/// string `--arg` hands jq, `$session` as its `pane` (or `session`), and
/// `$start` as its `server_start`'s `tostring`; or `ol_unstarted`, the
/// same server and session with `server_start` null.
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
        launch_line: Some("cd /r && codex".into()),
        harness: Some("codex".into()),
        account: Some("/a/c2".into()),
        home: Some("/a/c2".into()),
        model: Some("gpt-5.5-codex".into()),
        effort: Some("high".into()),
        cwd: Some("/r".into()),
        class: None,
        resume: None,
        permission: None,
        extra_args: Vec::new(),
        handoff: None,
        extra: Default::default(),
    }
}

/// The fixture overseer as the requester saw it. `server` is the string
/// the shell writers hand jq through `--arg`; a lane's `launch.server`
/// is a number.
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
        cause: TransferCause::Live,
        exclude_account: None,
        handoff_session_id: None,
        recovery: None,
    }))
}
