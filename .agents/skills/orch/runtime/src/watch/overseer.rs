//! The overseer observation duty: one verdict of the controller's session
//! per pass, in one reading order (the login wall, the exit record, the
//! session rows, the pane as the fallback), each reading three-valued,
//! stored in the one [`Slot`] the lanes' observation reads in the same
//! pass, so the controller is judged once per pass and the mail duty takes
//! no gate from it.
//!
//! A death is counted on `ORCH_OVERSEER_DEAD_PASSES` consecutive passes
//! that read the session gone, never on an unreadable read; a wall the rows
//! or the account state needs one pass, a wall the screen alone shows takes
//! the same count and the account judgement's confirmation. The case is
//! said on the log before anything moves, then the one existing request,
//! `request-transfer` with its cause and the spent account, asks for the
//! succession, whose terminal proof runs inside that transfer; a
//! controller whose record names its own succession owner has that owner's
//! command run in its place. The controller's own marks are judged here
//! ([`judge_marks`]): the watch asks in-process every pass with the
//! overseer's own context reading, and the turn-end hook asks through the
//! `marks` verb; the successor of a walled succession is the overseer
//! walk's choice (`ops::walk`).
//!
//! The overseer's context record (`watch::context`) is judged beside a
//! live session: a reading that fills the window with no Stop row after it
//! is the session gone with `source=context`, on the death's count of
//! passes; a working overseer's stale record and its gap are said every
//! pass, the gap's owner alert sent once it stood two passes and marked
//! only once sent.
//!
//! The wall relaunch the lanes pass starts runs detached and lands its
//! exit status beside its marker; every pass reads each outcome
//! (`relaunch_outcomes`) independent of the pane observation, since a
//! completed launch can leave a healthy window with a failed record write.

// Every reading is matched variant by variant.
#![deny(clippy::wildcard_enum_match_arm)]

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use agent_runtime::harness::Harness;
use agent_runtime::host;
use agent_runtime::launch::Permission;
use agent_runtime::observe::{self, ProcessReading, State, WallKind};
use agent_runtime::process::{Identity, Memory};
use agent_runtime::reading::Reading;
use agent_runtime::rows::{self, SessionVerdict};
use serde::Serialize;
use serde_json::{Value, json};

use super::baseline::{Baseline, Change};
use super::context::{self, Owned, Times};
use super::events::{Event, OverseerCase};
use super::lanes::{Readers as LaneReaders, Relaunch, WallRoute, banner_payload, watch_state_dir};
use super::owner_alert::{self, Word};
use super::{Body, Produced, Runner, Tick};
use crate::ops::accounts::{self, PickAnswer, PickRequest};
use crate::ops::walk::{self, WalkRequest};
use crate::ops::{OverseerExpected, RequestTransfer};
use crate::settings::{MarkSettings, Settings, Succession, WatchSettings};
use crate::state::{FleetState, Pending, TransferCause};

/// The gap alert's notice file under the state directory.
const GAP_ALERT_FILE: &str = "overseer-context-gap.txt";

/// Where the verdict was read, the `source=` word of the line.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Source {
    Auth,
    Record,
    Rows,
    Context,
    Process,
    Pane,
    Account,
}

impl Source {
    pub fn word(self) -> &'static str {
        match self {
            Source::Auth => "auth",
            Source::Record => "record",
            Source::Rows => "rows",
            Source::Context => "context",
            Source::Process => "process",
            Source::Pane => "pane",
            Source::Account => "account",
        }
    }
}

/// The one verdict of the controller's session a pass gives.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "verdict", rename_all = "kebab-case")]
pub enum Verdict {
    /// The harness runs and may be working.
    Live,
    /// The harness is gone from its pane.
    Exited { source: Source },
    /// The harness runs and its account refuses every turn.
    Walled {
        source: Source,
        kind: WallKind,
        /// The wall's own words: the row's message, the screen's banner, or
        /// the account line.
        text: String,
    },
    /// A controller operation the runtime holds open is replacing the
    /// session; nothing is judged beside it.
    Transferring { intent: String },
    /// No controller record names a pane to read.
    Unwatched { cause: &'static str },
    /// The pane, its process or its screen could not be read; nothing is
    /// counted on it.
    Unreadable { cause: String },
}

/// The verdict with the pass that gave it and the pane it was read from.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Judged {
    pub verdict: Verdict,
    /// `<server pid> <pane id>`, the key the rows are kept under.
    pub pane_key: Option<String>,
    /// The epoch second of the pass.
    pub at: u64,
}

/// The slot the observation duty stores each pass's verdict in, read by
/// the wall relaunch's gate; the mail duty reads no gate from it.
#[derive(Debug, Clone, Default)]
pub struct Slot(Arc<Mutex<Option<Judged>>>);

impl Slot {
    pub fn new() -> Slot {
        Slot::default()
    }

    pub fn store(&self, judged: Judged) {
        *self.0.lock().unwrap_or_else(|p| p.into_inner()) = Some(judged);
    }

    /// The last verdict stored, or `None` before the first observation.
    pub fn read(&self) -> Option<Judged> {
        self.0.lock().unwrap_or_else(|p| p.into_inner()).clone()
    }
}

/// The token count every context reading is due at, whatever its window.
const CONTEXT_CAP: u64 = 400_000;
/// The share of the window a reading is due strictly past; a larger
/// setting cannot weaken it.
const CONTEXT_PCT_CEILING: u32 = 90;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum MarkKind {
    Context,
    Headroom,
    Rate,
    Memory,
}

impl MarkKind {
    pub fn word(self) -> &'static str {
        match self {
            MarkKind::Context => "context",
            MarkKind::Headroom => "headroom",
            MarkKind::Rate => "rate",
            MarkKind::Memory => "memory",
        }
    }

    pub fn parse(word: &str) -> Option<MarkKind> {
        [
            MarkKind::Context,
            MarkKind::Headroom,
            MarkKind::Rate,
            MarkKind::Memory,
        ]
        .into_iter()
        .find(|kind| kind.word() == word)
    }
}

/// The judge's answer: a mark reached, a figure one mark needed that could
/// not be taken while no other fired (never a mark that lifted), or every
/// mark read and none reached.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarkKey {
    Reached(MarkKind),
    Unmeasured(MarkKind),
    Below,
}

/// What the context reading settled, carried on a below-mark answer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ContextRead {
    /// No reading was handed in: the account marks alone were judged.
    Unjudged,
    /// A reading whose window nothing named, below the token cap.
    Unmeasured,
    /// Below both marks.
    Room {
        tokens: u64,
        window: u64,
    },
    Due {
        tokens: u64,
        window: Option<u64>,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub struct Marks {
    pub key: MarkKey,
    /// The figure read at the mark, as the line prints it.
    pub value: String,
    pub mark: String,
    pub succession: Succession,
    /// The caller's own account and its binding reset, on an account mark.
    pub account: String,
    pub resets: String,
    /// `plan_ended` where the caller's own account ended.
    pub status: String,
    /// A headroom mark where spendable credits remain below their floor.
    pub reserve_only: bool,
    /// The figure an unmeasured answer could not take.
    pub reason: String,
    /// The caller's own headroom as read: a figure, `none` for an account
    /// nothing measured, `unreadable` for a judge that could not answer.
    pub headroom: String,
    pub context: ContextRead,
    /// The judged reading as the handoff record carries it.
    pub decision: Option<Value>,
}

impl Marks {
    fn new(key: MarkKey, succession: Succession) -> Marks {
        Marks {
            key,
            value: String::new(),
            mark: String::new(),
            succession,
            account: String::new(),
            resets: String::new(),
            status: String::new(),
            reserve_only: false,
            reason: String::new(),
            headroom: String::new(),
            context: ContextRead::Unjudged,
            decision: None,
        }
    }

    /// A non-reserve headroom mark reached: the account judgement that
    /// confirms a wall read off the screen.
    fn confirms_wall(&self) -> bool {
        self.key == MarkKey::Reached(MarkKind::Headroom) && !self.reserve_only
    }

    /// The reply the `marks` verb prints, which the turn-end hook reads.
    pub fn reply(&self) -> Value {
        let (key, kind) = match self.key {
            MarkKey::Reached(kind) => ("mark-reached", Some(kind.word())),
            MarkKey::Unmeasured(kind) => ("mark-unmeasured", Some(kind.word())),
            MarkKey::Below => ("below-mark", None),
        };
        let mut reply = serde_json::Map::new();
        reply.insert("key".to_owned(), json!(key));
        reply.insert("kind".to_owned(), json!(kind));
        reply.insert("succession".to_owned(), json!(self.succession.word()));
        let text = |value: &str| (!value.is_empty()).then(|| json!(value));
        for (name, value) in [
            ("value", &self.value),
            ("mark", &self.mark),
            ("account", &self.account),
            ("resets", &self.resets),
            ("status", &self.status),
            ("reason", &self.reason),
            ("headroom", &self.headroom),
        ] {
            if let Some(value) = text(value) {
                reply.insert(name.to_owned(), value);
            }
        }
        if self.reserve_only {
            reply.insert("reserve_only".to_owned(), json!(true));
        }
        let context = match &self.context {
            ContextRead::Unjudged => json!("unjudged"),
            ContextRead::Unmeasured => json!("unmeasured"),
            ContextRead::Room { tokens, window } => {
                reply.insert("tokens".to_owned(), json!(tokens));
                reply.insert("window".to_owned(), json!(window));
                json!("room")
            }
            ContextRead::Due { tokens, window } => {
                reply.insert("tokens".to_owned(), json!(tokens));
                reply.insert("window".to_owned(), json!(window));
                json!("due")
            }
        };
        reply.insert("context".to_owned(), context);
        if let Some(decision) = &self.decision {
            reply.insert("context_decision".to_owned(), decision.clone());
        }
        Value::Object(reply)
    }
}

/// The handoff marks of one context reading: due at [`CONTEXT_CAP`] tokens,
/// or strictly past `pct` percent of the window, `pct` held to
/// [`CONTEXT_PCT_CEILING`]. `None` is a reading with no window below the cap:
/// unmeasured, never room.
pub fn handoff_due(tokens: u64, window: Option<u64>, pct: u32) -> Option<bool> {
    if tokens >= CONTEXT_CAP {
        return Some(true);
    }
    let window = window.filter(|w| *w > 0)?;
    let pct = u64::from(pct.min(CONTEXT_PCT_CEILING));
    Some(tokens > window * pct / 100)
}

/// The reading as the handoff record carries it, the marks it was judged
/// against beside it.
fn handoff_decision(tokens: u64, window: Option<u64>, pct: u32) -> Value {
    let pct = pct.min(CONTEXT_PCT_CEILING);
    let window = window.filter(|w| *w > 0);
    json!({
        "tokens": tokens,
        "window": window,
        "cap": CONTEXT_CAP,
        "mark_pct": pct,
        "cap_mark": CONTEXT_CAP,
        "window_mark": window.map(|w| w * u64::from(pct) / 100),
        "reserve_applied": false,
        "reserve_tokens": 0,
    })
}

/// `TOKENS:WINDOW`, the window empty where no adapter named one.
fn parse_context(text: &str) -> Option<(u64, Option<u64>)> {
    let (tokens, window) = text.split_once(':')?;
    let digits = |s: &str, zero: bool| {
        (!s.is_empty()
            && s.bytes().all(|b| b.is_ascii_digit())
            && (s == "0" && zero || !s.starts_with('0')))
        .then(|| s.parse::<u64>().ok())
        .flatten()
    };
    let tokens = digits(tokens, true)?;
    let window = if window.is_empty() {
        None
    } else {
        Some(digits(window, false)?)
    };
    Some((tokens, window))
}

/// The session the marks are judged for: the recorded controller's own
/// launch fields.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Caller {
    pub harness: Option<Harness>,
    pub account: Option<String>,
    pub home: Option<String>,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub cwd: Option<String>,
    pub permission: Option<Permission>,
    pub extra_args: Vec<String>,
    /// The handoff the controller's brief named, kept by its successor.
    pub handoff: Option<String>,
    pub identity: Option<Identity>,
}

impl Caller {
    pub fn of(record: &Record) -> Caller {
        Caller {
            harness: record.harness,
            account: record.account.clone(),
            home: text(record.raw.get("home")),
            model: text(record.raw.get("model")),
            effort: text(record.raw.get("effort")),
            cwd: text(record.raw.get("cwd")),
            permission: record
                .raw
                .get("permission")
                .and_then(|p| serde_json::from_value(p.clone()).ok()),
            extra_args: record
                .raw
                .get("extra_args")
                .and_then(|a| serde_json::from_value(a.clone()).ok())
                .unwrap_or_default(),
            handoff: text(record.raw.get("handoff")),
            identity: record.identity.clone(),
        }
    }

    /// The model the account is judged on: a Claude or Pi session on its
    /// model, a Codex or Copilot session on the account's binding bucket.
    fn mark_model(&self) -> Option<String> {
        match self.harness {
            Some(Harness::Claude | Harness::Pi) => self.model.clone().filter(|m| !m.is_empty()),
            Some(Harness::Codex | Harness::Copilot) | None => None,
        }
    }

    /// The walk's caller entry: this session's own harness and lane, its
    /// model and effort where the record names them.
    pub(crate) fn walk_entry(&self, harness: Harness) -> walk::Caller {
        walk::Caller {
            harness: harness.name().to_owned(),
            lane: self.account.clone(),
            model: self.model.clone().filter(|m| !m.is_empty()),
            effort: self.effort.clone().filter(|e| !e.is_empty()),
            pick_model: self.mark_model(),
            keep: false,
        }
    }

    /// This session's own account through the judge's named form at the
    /// trigger: the judged record's wall, alias, reset, rate and status,
    /// read as the state the marks and a mark's succession dispatch on.
    fn own_account(
        &self,
        harness: Harness,
        settings: &Settings,
        fleet_path: &Path,
        host: &crate::ops::Host<'_>,
        now: u64,
    ) -> AccountRead {
        let trigger = settings.accounts.overseer_headroom_pct;
        match self.account.as_deref() {
            Some(account) => {
                let answer = accounts::pick_fleet(
                    settings,
                    fleet_path,
                    host,
                    &PickRequest {
                        harness: harness.name().to_owned(),
                        model: self.mark_model(),
                        lane: Some(account.to_owned()),
                        for_overseer: true,
                        min_headroom_pct: Some(trigger),
                        ..PickRequest::default()
                    },
                    now,
                );
                match answer {
                    PickAnswer::Lane(j) => read_account(&j, AccountState::HasRoom, false, now),
                    PickAnswer::Walled(j)
                    | PickAnswer::Reserved(j)
                    | PickAnswer::Retired { judged: j, .. }
                    | PickAnswer::Excluded(j)
                    | PickAnswer::CloudRepoUnset(j) => {
                        read_account(&j, AccountState::AtTrigger, true, now)
                    }
                    PickAnswer::Unmeasured(j) => {
                        read_account(&j, AccountState::Unmeasured, false, now)
                    }
                    PickAnswer::NoRecord
                    | PickAnswer::ProviderUnmeasured { .. }
                    | PickAnswer::Unbilled { .. } => unmeasured_account(),
                    PickAnswer::None { .. } | PickAnswer::Unjudged { .. } => unreadable_account(),
                }
            }
            None => unmeasured_account(),
        }
    }

    /// This session's own account as [`judge_marks`] reads it: its state,
    /// and the account mark it reaches, which a succession leaves the
    /// account by whatever mark sent it.
    pub(crate) fn account_departure(
        &self,
        harness: Harness,
        settings: &Settings,
        fleet_path: &Path,
        host: &crate::ops::Host<'_>,
        now: u64,
    ) -> (AccountState, Option<MarkKind>) {
        let read = self.own_account(harness, settings, fleet_path, host, now);
        let reached = read.reached(&settings.marks);
        (read.state, reached)
    }

    /// The pending the walk's choice opens: its harness, account, model,
    /// effort and class, in this session's directory; a same-harness entry
    /// keeps this session's posture and words, another harness runs the
    /// full bypass the walk admitted with none of them. The launch prepares
    /// the home its harness and account run under; the one home named is
    /// this session's own root, kept by a same-harness successor whose
    /// account is not its home (a Pi seat).
    pub fn successor_of(&self, chosen: &walk::Chosen) -> Pending {
        let same = self.harness.is_some_and(|h| h.name() == chosen.harness);
        Pending {
            launch_line: None,
            harness: Some(chosen.harness.clone()),
            account: chosen.account.clone(),
            home: self
                .harness
                .filter(|h| same && h.account_var(Some(&chosen.model)) != h.home_var())
                .and(self.home.clone()),
            model: Some(chosen.model.clone()).filter(|m| !m.is_empty()),
            effort: Some(chosen.effort.clone()).filter(|e| !e.is_empty()),
            cwd: self.cwd.clone(),
            class: chosen.class.clone(),
            resume: None,
            permission: if same {
                self.permission
            } else {
                Some(Permission::Bypass)
            },
            extra_args: if same {
                self.extra_args.clone()
            } else {
                Vec::new()
            },
            handoff: self.handoff.clone(),
            extra: serde_json::Map::new(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AccountState {
    HasRoom,
    AtTrigger,
    Unmeasured,
    Unreadable,
}

struct AccountRead {
    state: AccountState,
    headroom: Option<u32>,
    account: String,
    resets: String,
    ended: bool,
    reserve_only: bool,
    rate_state: String,
    /// The minutes to the wall at the measured rate, counted from the
    /// sample's instant.
    projected: Option<u64>,
}

impl AccountRead {
    /// The account mark this reading reaches: the headroom trigger, else a
    /// wall the measured rate projects inside the setting. Headroom leads,
    /// since it names the account to leave.
    fn reached(&self, marks: &MarkSettings) -> Option<MarkKind> {
        if self.state == AccountState::AtTrigger {
            return Some(MarkKind::Headroom);
        }
        (marks.wall_minutes > 0
            && self.rate_state == "measured"
            && self
                .projected
                .is_some_and(|projected| projected <= u64::from(marks.wall_minutes)))
        .then_some(MarkKind::Rate)
    }

    fn headroom_field(&self) -> String {
        match (self.state, self.headroom) {
            (AccountState::HasRoom | AccountState::AtTrigger, Some(h)) => h.to_string(),
            (AccountState::Unmeasured, _) => "none".to_owned(),
            (AccountState::HasRoom | AccountState::AtTrigger | AccountState::Unreadable, _) => {
                "unreadable".to_owned()
            }
        }
    }
}

fn record_text(record: &Value, key: &str) -> String {
    match record.get(key) {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::Null | Value::Bool(_) | Value::Array(_) | Value::Object(_)) | None => {
            String::new()
        }
    }
}

/// A percentage figure as the shell callers read one: a whole number of
/// at most three digits; anything else is unreadable.
fn whole_pct(record: &Value, key: &str) -> Option<u32> {
    let text = record_text(record, key);
    (text.len() <= 3 && !text.is_empty() && text.bytes().all(|b| b.is_ascii_digit()))
        .then(|| text.parse().ok())
        .flatten()
}

/// The caller's own account through the judge's named form at the
/// trigger: the judged record's wall, alias, reset, rate and status, read
/// as the account state the marks dispatch on.
fn read_account(
    judged: &accounts::Judged,
    answer: AccountState,
    at_trigger: bool,
    now: u64,
) -> AccountRead {
    let record = judged.record();
    let headroom = whole_pct(&record, "wall").map(|wall| 100 - wall);
    let state = match (answer, headroom) {
        (AccountState::HasRoom | AccountState::AtTrigger, None) => AccountState::Unreadable,
        (state, _) => state,
    };
    let projected = (record_text(&record, "usage_rate_state") == "measured")
        .then(|| {
            let age = record.get("usage_age_s")?.as_f64()?;
            let minutes = record.get("projected_wall_minutes")?.as_f64()?;
            let wall_at = now as f64 - age + minutes * 60.0;
            Some(((wall_at - now as f64 + 59.0) / 60.0).floor().max(0.0) as u64)
        })
        .flatten();
    AccountRead {
        state,
        headroom,
        account: record_text(&record, "alias"),
        resets: record_text(&record, "binding_resets_at"),
        ended: judged.row.plan_ended(),
        reserve_only: at_trigger && accounts::credit_room(&judged.row, 0.0),
        rate_state: record_text(&record, "usage_rate_state"),
        projected,
    }
}

/// One ask of the judge: the caller, its context reading, and the reads
/// the judge makes beyond the fleet's own state.
pub struct MarksAsk<'a> {
    pub settings: &'a Settings,
    pub fleet_path: &'a Path,
    pub host: &'a crate::ops::Host<'a>,
    pub caller: &'a Caller,
    /// `TOKENS:WINDOW` as the turn-end hook took it; none judges the
    /// account marks alone.
    pub context: Option<&'a str>,
    /// The memory of the caller's harness process, read only where the
    /// memory mark is set.
    pub memory: &'a dyn Fn(&Identity) -> Reading<Option<Memory>>,
    pub now: u64,
}

/// The controller's own marks, judged once: the context mark on the
/// reading handed in, then the account marks on the account the session
/// spends and the memory mark on its process. One answer names one mark;
/// the account marks lead where several fire on one reading, since they
/// name the account to leave. An unmeasured figure is its own answer, never
/// a mark that lifted and never zero.
pub fn judge_marks(ask: &MarksAsk) -> crate::error::Result<Marks> {
    let settings = ask.settings;
    let marks = &settings.marks;
    let succession = settings.succession;
    let context = match ask.context {
        Some(text) => Some(parse_context(text).ok_or_else(|| {
            crate::error::Error::from(agent_runtime::Error::refused(
                "context-invalid",
                &[("value", text)],
            ))
        })?),
        None => None,
    };
    let (context_read, decision) = match context {
        None => (ContextRead::Unjudged, None),
        Some((tokens, window)) => {
            let decision = handoff_decision(tokens, window, marks.context_pct);
            let read = match handoff_due(tokens, window, marks.context_pct) {
                Some(true) => ContextRead::Due { tokens, window },
                Some(false) => ContextRead::Room {
                    tokens,
                    window: window.unwrap_or(0),
                },
                None => ContextRead::Unmeasured,
            };
            (read, Some(decision))
        }
    };
    // A due reading answers before the account is read: the mark that
    // fired is what the caller acts on, whatever the account would say.
    if let ContextRead::Due { tokens, .. } = &context_read {
        let mut m = Marks::new(MarkKey::Reached(MarkKind::Context), succession);
        m.value = tokens.to_string();
        m.mark = marks.context_pct.min(CONTEXT_PCT_CEILING).to_string();
        m.headroom = "unreadable".to_owned();
        m.context = context_read;
        m.decision = decision;
        return Ok(m);
    }
    let Some(harness) = ask.caller.harness else {
        return Err(agent_runtime::Error::refused("harness-unnamed", &[]).into());
    };
    let trigger = settings.accounts.overseer_headroom_pct;
    let account = ask
        .caller
        .own_account(harness, settings, ask.fleet_path, ask.host, ask.now);
    let memory = match (marks.memory_pct, &ask.caller.identity) {
        (None, _) => MemoryRead::Inert,
        (Some(_), None) => MemoryRead::Unmeasured("identity-unrecorded".to_owned()),
        (Some(pct), Some(identity)) => match (ask.memory)(identity) {
            Reading::Live(Some(m)) if m.max > 0 => {
                let used = u32::try_from(m.current.saturating_mul(100) / m.max).unwrap_or(u32::MAX);
                if used >= pct {
                    MemoryRead::Reached { used, mark: pct }
                } else {
                    MemoryRead::Below
                }
            }
            Reading::Live(Some(_)) => MemoryRead::Unmeasured("cap-zero".to_owned()),
            Reading::Live(None) => MemoryRead::Inert,
            Reading::Gone => MemoryRead::Unmeasured("process-gone".to_owned()),
            Reading::Unreadable { cause } => MemoryRead::Unmeasured(cause.to_owned()),
        },
    };
    let reached = |kind: MarkKind, value: String, mark: String| {
        let mut m = Marks::new(MarkKey::Reached(kind), succession);
        m.value = value;
        m.mark = mark;
        m.account = if account.account.is_empty() {
            "unknown".to_owned()
        } else {
            account.account.clone()
        };
        m.resets = if account.resets.is_empty() {
            "none".to_owned()
        } else {
            account.resets.clone()
        };
        m.context = context_read.clone();
        m.decision = decision.clone();
        m
    };
    let account_mark = account.reached(marks);
    if account_mark == Some(MarkKind::Headroom) {
        let mut m = reached(
            MarkKind::Headroom,
            account.headroom.unwrap_or(0).to_string(),
            trigger.to_string(),
        );
        m.reserve_only = account.reserve_only;
        if account.ended {
            m.status = "plan_ended".to_owned();
        }
        return Ok(m);
    }
    if account_mark == Some(MarkKind::Rate)
        && let Some(projected) = account.projected
    {
        let mut m = reached(
            MarkKind::Rate,
            projected.to_string(),
            marks.wall_minutes.to_string(),
        );
        m.resets = String::new();
        return Ok(m);
    }
    if let MemoryRead::Reached { used, mark } = memory {
        let mut m = reached(MarkKind::Memory, used.to_string(), mark.to_string());
        m.resets = String::new();
        return Ok(m);
    }
    let unmeasured = |kind: MarkKind, reason: String| {
        let mut m = Marks::new(MarkKey::Unmeasured(kind), succession);
        m.reason = reason;
        m.context = context_read.clone();
        m.decision = decision.clone();
        m
    };
    let headroom_field = account.headroom_field();
    // The unmeasured figures, each its own answer where no mark fired: a
    // caller holding a standing mark keeps it across a pass that could not
    // measure.
    match account.state {
        AccountState::Unmeasured | AccountState::Unreadable => {
            return Ok(unmeasured(
                MarkKind::Headroom,
                format!("headroom-{headroom_field}"),
            ));
        }
        AccountState::HasRoom | AccountState::AtTrigger => {}
    }
    if context_read == ContextRead::Unmeasured {
        return Ok(unmeasured(MarkKind::Context, "window-unnamed".to_owned()));
    }
    if marks.wall_minutes > 0 && account.rate_state != "measured" && account.rate_state != "credits"
    {
        let reason = if account.rate_state.is_empty() {
            "unreadable".to_owned()
        } else {
            account.rate_state.clone()
        };
        return Ok(unmeasured(MarkKind::Rate, reason));
    }
    if let MemoryRead::Unmeasured(reason) = memory {
        return Ok(unmeasured(MarkKind::Memory, reason));
    }
    let mut m = Marks::new(MarkKey::Below, succession);
    m.headroom = headroom_field;
    m.mark = marks.context_pct.min(CONTEXT_PCT_CEILING).to_string();
    m.context = context_read;
    m.decision = decision;
    Ok(m)
}

fn unmeasured_account() -> AccountRead {
    AccountRead {
        state: AccountState::Unmeasured,
        headroom: None,
        account: String::new(),
        resets: String::new(),
        ended: false,
        reserve_only: false,
        rate_state: String::new(),
        projected: None,
    }
}

fn unreadable_account() -> AccountRead {
    AccountRead {
        state: AccountState::Unreadable,
        ..unmeasured_account()
    }
}

enum MemoryRead {
    /// No mark set, or no cap on the process's path.
    Inert,
    Below,
    Reached {
        used: u32,
        mark: u32,
    },
    Unmeasured(String),
}

/// The calls the duty makes beyond its own reads, injected so a row plants
/// the answers; production assembles them in [`register`]'s body from
/// [`judge_marks`], the walk, the accounts judge, the job-unit launcher and
/// the one runner.
pub struct Judges<'a> {
    /// The directory the lanes pass's scripts run from.
    pub scripts: PathBuf,
    /// The controller's own marks for the caller and its context reading.
    pub marks: MarksRead<'a>,
    /// The overseer walk a walled succession chooses its successor by.
    pub walk: WalkRead<'a>,
    /// The wall route's pick for a lane's model, the spent account
    /// excluded.
    pub wall_pick: WallPickRead<'a>,
    /// The wall relaunch, the walled lane's close and its `launch-lane`
    /// (`lanes::Relaunch`), started detached through the job-unit launcher
    /// at the path given.
    pub relaunch: RelaunchStart<'a>,
    /// The succession command a controller's own owner recorded, run in
    /// place of a transfer; `Err` is its failure.
    pub succeed: SuccessionRun<'a>,
}

pub type MarksRead<'a> = &'a dyn Fn(&Caller, Option<&str>) -> Result<Marks, String>;
pub type WalkRead<'a> = &'a dyn Fn(&WalkRequest) -> Result<walk::Walked, String>;
/// The walk's pick for a harness and model, the spent account excluded.
pub type WallPickRead<'a> = &'a dyn Fn(&Path, Harness, &str, &str) -> Pick;
/// The relaunch started through the job-unit launcher; `Err` its refusal.
pub type RelaunchStart<'a> = &'a dyn Fn(&Path, &Relaunch) -> Result<(), String>;
pub type SuccessionRun<'a> = &'a dyn Fn(&[String]) -> Result<SuccessionAnswer, String>;

/// What a succession owner's command answered short of a failure: it ran
/// to its end, or it started and gave no answer within the bound, so
/// whether it succeeded is the record's to say.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SuccessionAnswer {
    Done,
    Unanswered { cause: String },
}

/// The wall route's answer as the lanes pass reads it: the `config_dir`
/// of the account picked, none where no account qualifies, else unjudged
/// with the cause. A named-lane answer never reaches a walk; it is
/// unjudged by name so nothing is relaunched on it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Pick {
    Lane(String),
    None,
    Unjudged { cause: String },
}

pub fn picked_by_judge(answer: PickAnswer) -> Pick {
    match answer {
        PickAnswer::Lane(judged) => Pick::Lane(judged.row.config_dir),
        PickAnswer::None { .. } => Pick::None,
        PickAnswer::Unjudged { cause } => Pick::Unjudged { cause },
        PickAnswer::ProviderUnmeasured { .. } => Pick::None,
        PickAnswer::Walled(_)
        | PickAnswer::Reserved(_)
        | PickAnswer::Retired { .. }
        | PickAnswer::Excluded(_)
        | PickAnswer::Unmeasured(_)
        | PickAnswer::CloudRepoUnset(_)
        | PickAnswer::Unbilled { .. }
        | PickAnswer::NoRecord => Pick::Unjudged {
            cause: "named-lane-answer".to_owned(),
        },
    }
}

/// The bound on the detached relaunch's start and a recorded succession
/// command, each one process.
const RUNNER_BOUND: Duration = Duration::from_secs(120);

/// How long after the pass that ran it a succession command that gave no
/// answer has to move the record: its own bound, then as long again.
const SUCCESSION_SETTLE: Duration = Duration::from_secs(2 * RUNNER_BOUND.as_secs());

/// The job-unit name and record of a wall relaunch, beside its log.
fn relaunch_record(r: &Relaunch) -> (String, PathBuf) {
    (
        format!("wall-relaunch-{}", r.item),
        r.log.with_extension("unit"),
    )
}

/// Where a relaunch's exit status lands: `<marker>.exit`, the file its
/// wrapper writes last.
pub fn relaunch_exit_path(marker: &Path) -> PathBuf {
    PathBuf::from(format!("{}.exit", marker.display()))
}

/// The shell line the relaunch runs under: the launcher in the recovered
/// checkout with the recovered session, its output appended to the log,
/// its exit status written beside the marker.
const RELAUNCH_WRAPPER: &str = "log=\"$1\"; exit_file=\"$2\"; launch_cwd=\"$3\"; export ORCH_TMUX_SESSION=\"$4\"; shift 4; exec >>\"$log\" 2>&1; rc=0; (cd -- \"$launch_cwd\" && \"$@\") || rc=$?; printf \"%s\\n\" \"$rc\" > \"$exit_file\"";

/// The scripts directory under the project's orch install.
pub fn scripts_dir(project: &Path) -> PathBuf {
    project.join(".agents/skills/orch/scripts")
}

/// A controller's own succession command through the one runner: the
/// first word the program, the rest its arguments. A command that never
/// started, or that exited with a failure, is `Err`; one that started and
/// gave no answer, past the bound or ended by a signal, may have moved the
/// record, so it is `Unanswered`.
#[allow(
    clippy::disallowed_methods,
    reason = "the recorded owner's succession command, run once through the one runner in place of a transfer"
)]
pub fn succeed_through_runner(words: &[String]) -> Result<SuccessionAnswer, String> {
    let Some((program, args)) = words.split_first() else {
        return Err("succession command empty".to_owned());
    };
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let out = match host::run_tagged(
        "succession-owner",
        "succession-owner",
        Path::new(program),
        "succeed",
        &args,
        RUNNER_BOUND,
    ) {
        Ok(out) => out,
        Err(e @ agent_runtime::Error::NotStarted { .. }) => return Err(e.to_string()),
        Err(e) => {
            return Ok(SuccessionAnswer::Unanswered {
                cause: e.to_string(),
            });
        }
    };
    match out.status.code() {
        Some(0) => Ok(SuccessionAnswer::Done),
        Some(_) => Err(host::stderr_text(&out)),
        None => Ok(SuccessionAnswer::Unanswered {
            cause: "signal".to_owned(),
        }),
    }
}

/// The wall relaunch through the job-unit launcher at `job_unit`: the
/// record's own line, detached, its exit status landing beside the marker.
#[allow(
    clippy::disallowed_methods,
    reason = "the wall relaunch started detached through the one runner and the job-unit launcher"
)]
pub fn relaunch_through_launcher(job_unit: &Path, r: &Relaunch) -> Result<(), String> {
    let (name, record) = relaunch_record(r);
    let record = record.display().to_string();
    let log = r.log.display().to_string();
    let exit = relaunch_exit_path(&r.marker).display().to_string();
    let cwd = r.cwd.display().to_string();
    let mut args = vec![
        "launch",
        &name,
        &record,
        "--",
        "bash",
        "-c",
        RELAUNCH_WRAPPER,
        "wall-relaunch",
        &log,
        &exit,
        &cwd,
        &r.session,
    ];
    args.extend(r.args.iter().map(String::as_str));
    let out = host::run_tagged(
        "wall-relaunch",
        "job-unit",
        job_unit,
        "launch",
        &args,
        RUNNER_BOUND,
    );
    // A launch the launcher answers possibly started, or that gave no
    // answer, is read as started: the marker written before it owns its
    // outcome, said from the relaunch's status or as stuck past the prepare
    // bound. One that never started, or a refusal, ran nothing.
    let out = match out {
        Ok(out) => out,
        Err(e @ agent_runtime::Error::NotStarted { .. }) => return Err(e.to_string()),
        Err(_) => return Ok(()),
    };
    match out.status.code() {
        Some(0) | None => Ok(()),
        Some(crate::validate::JOB_UNIT_UNCONFIRMED) => Ok(()),
        Some(_) => Err(host::stderr_text(&out)),
    }
}

/// The controller record's fields the duty reads: the server by pid, its
/// start where recorded, the pane, and the harness identity the watch
/// start recorded.
#[derive(Debug, Clone, PartialEq)]
pub struct Record {
    pub server: u64,
    pub server_start: Option<u64>,
    pub pane: String,
    pub window: String,
    pub generation: Option<u64>,
    pub harness: Option<Harness>,
    pub identity: Option<Identity>,
    pub session_rows: Option<PathBuf>,
    pub exit_status: Option<String>,
    pub account: Option<String>,
    pub pending: Option<Pending>,
    pub raw: serde_json::Map<String, Value>,
}

fn number(value: Option<&Value>) -> Option<u64> {
    match value? {
        Value::Number(n) => n.as_u64(),
        Value::String(s) => s.parse().ok(),
        Value::Null | Value::Bool(_) | Value::Array(_) | Value::Object(_) => None,
    }
}

fn text(value: Option<&Value>) -> Option<String> {
    match value? {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        Value::Null | Value::Bool(_) | Value::Array(_) | Value::Object(_) => None,
    }
}

impl Record {
    /// The record as the fleet state holds it; `None` where it names no
    /// server or pane.
    pub fn read(fleet: &FleetState) -> Option<Record> {
        let overseer = fleet.overseer.as_ref()?;
        let raw = &overseer.extra;
        let server = number(raw.get("server"))?;
        let pane = text(raw.get("pane"))?;
        let pid = number(raw.get("harness_pid")).and_then(|p| u32::try_from(p).ok());
        let start = text(raw.get("harness_start"));
        let identity = match (pid, start) {
            (Some(pid), Some(start)) => Some(Identity { pid, start }),
            (Some(_), None) | (None, Some(_)) | (None, None) => None,
        };
        Some(Record {
            server,
            server_start: number(raw.get("server_start")),
            pane,
            window: text(raw.get("window")).unwrap_or_default(),
            generation: overseer.generation,
            harness: text(raw.get("harness")).as_deref().and_then(Harness::parse),
            identity,
            session_rows: text(raw.get("session_rows")).map(PathBuf::from),
            exit_status: raw
                .get("exit")
                .and_then(|e| e.get("status"))
                .and_then(|s| text(Some(s))),
            account: text(raw.get("account")),
            pending: overseer.pending.clone(),
            raw: raw.clone(),
        })
    }

    fn pane_key(&self) -> String {
        format!("{} {}", self.server, self.pane)
    }

    /// The successor a dead session's recovery replays: the pending the
    /// fleet last chose, else this record's own launch fields, a fresh
    /// session in the same place on the home its launch prepares, its own
    /// root kept where its account is not its home. The dead session's
    /// handoff is what its successor reads, so no held successor resumes the
    /// dead session.
    fn held_successor(&self) -> Option<Pending> {
        if let Some(pending) = &self.pending {
            return Some(pending.clone());
        }
        let caller = Caller::of(self);
        let harness = caller.harness?;
        Some(Pending {
            launch_line: text(self.raw.get("launch_line")),
            harness: Some(harness.name().to_owned()),
            account: caller.account,
            home: caller
                .home
                .filter(|_| harness.account_var(caller.model.as_deref()) != harness.home_var()),
            model: caller.model,
            effort: caller.effort,
            cwd: caller.cwd,
            class: text(self.raw.get("class")),
            resume: None,
            permission: caller.permission,
            extra_args: caller.extra_args,
            handoff: caller.handoff,
            extra: serde_json::Map::new(),
        })
    }

    fn succession(&self) -> Option<Vec<String>> {
        crate::state::succession_command(self.raw.get("succession"))
    }

    /// The compare-and-swap set the request carries: the record as read.
    pub(crate) fn expected(&self) -> OverseerExpected {
        let get = |key: &str| self.raw.get(key).cloned().unwrap_or(Value::Null);
        OverseerExpected {
            server: get("server"),
            server_start: get("server_start"),
            pane: get("pane"),
            // The typed fields of the record are not in `raw`.
            generation: self.generation.map_or(Value::Null, Value::from),
            launch_line: get("launch_line"),
            cwd: get("cwd"),
            session_id: None,
            pending: self
                .pending
                .as_ref()
                .and_then(|p| serde_json::to_value(p).ok())
                .unwrap_or(Value::Null),
        }
    }
}

/// The reads of one pass, three-valued each.
struct Reads {
    process: ProcessReading,
    screen: Result<String, String>,
    rows: Option<Reading<SessionVerdict>>,
}

/// One pass's inputs.
pub struct Pass<'a> {
    pub fleet: &'a FleetState,
    pub readers: &'a LaneReaders<'a>,
    pub judges: &'a Judges<'a>,
    pub baseline: &'a Baseline,
    pub settings: &'a WatchSettings,
    pub succession: Succession,
    /// `ORCH_OVERSEER_PREFERENCE`, which the mark line's payload names;
    /// `None` where the setting names none.
    pub preference: Option<&'a str>,
    pub now: u64,
    /// The one request the duty makes: `request-transfer`, as the `op`
    /// command runs it; `Ok` is the intent it persisted, `Err` the
    /// refusal's text.
    pub transfer: &'a dyn Fn(RequestTransfer) -> Result<String, String>,
    /// The overseer's context record, `context.json` in the overseer
    /// mailbox; `None` where the fleet has no mailbox root to read it in.
    pub context_record: Option<&'a Path>,
    /// The owner's alert for a standing gap, one notice through the
    /// overseer mailbox (`lane-mail notice --item overseer --to owner`);
    /// `Ok` once the owner holds the words, `Err` with the cause where it
    /// was not sent.
    pub alert: &'a dyn Fn(&str) -> Result<(), String>,
}

/// The verdict of the record's session from the reads: the login wall
/// first, then the exit record over a bare shell, then the rows, then the
/// pane.
fn judge(record: &Record, reads: &Reads, marks: &mut dyn FnMut() -> Option<Marks>) -> Verdict {
    let bare = matches!(reads.process, ProcessReading::ShellsOnly);
    let screen = match &reads.screen {
        Ok(screen) => screen.as_str(),
        Err(cause) => {
            return Verdict::Unreadable {
                cause: cause.clone(),
            };
        }
    };
    if let ProcessReading::Unread { cause } = reads.process {
        return Verdict::Unreadable {
            cause: cause.to_owned(),
        };
    }
    let Some(harness) = record.harness else {
        return Verdict::Unreadable {
            cause: "harness-unrecorded".to_owned(),
        };
    };
    let state = observe::judge(screen, harness, &reads.process, None);
    if let State::Walled {
        kind: WallKind::Auth,
        banner,
    } = &state
    {
        return Verdict::Walled {
            source: Source::Auth,
            kind: WallKind::Auth,
            text: banner.clone(),
        };
    }
    if record.exit_status.is_some() && bare {
        return Verdict::Exited {
            source: Source::Record,
        };
    }
    if let Some(rows) = &reads.rows {
        match rows {
            Reading::Live(SessionVerdict::Ended) if bare => {
                return Verdict::Exited {
                    source: Source::Rows,
                };
            }
            Reading::Live(SessionVerdict::Walled { kind }) => {
                let message = record
                    .session_rows
                    .as_deref()
                    .map(rows::last_row)
                    .and_then(|r| match r {
                        Reading::Live(row) => row.message,
                        Reading::Gone | Reading::Unreadable { .. } => None,
                    })
                    .unwrap_or_else(|| "message=unrecorded".to_owned());
                // A rows usage wall stands unless the account judgement
                // measures room (`overseer-wall-lifted`); an auth wall
                // stands whatever it reads.
                if *kind == WallKind::Usage && marks().is_some_and(|m| m.key == MarkKey::Below) {
                    return Verdict::Live;
                }
                return Verdict::Walled {
                    source: Source::Rows,
                    kind: *kind,
                    text: message,
                };
            }
            Reading::Live(SessionVerdict::Wedged) => {
                return Verdict::Exited {
                    source: if bare {
                        Source::Process
                    } else {
                        Source::Context
                    },
                };
            }
            Reading::Live(SessionVerdict::Ended | SessionVerdict::Live) => {
                return if bare {
                    Verdict::Exited {
                        source: Source::Process,
                    }
                } else {
                    Verdict::Live
                };
            }
            Reading::Live(SessionVerdict::Unsupported)
            | Reading::Gone
            | Reading::Unreadable { .. } => {}
        }
    }
    match state {
        State::Exited => Verdict::Exited {
            source: Source::Process,
        },
        State::Walled {
            kind: WallKind::Usage,
            banner,
        } => {
            // The screen never decides alone: the overseer's pane carries
            // every lane's banner it relayed. The account judgement
            // confirms it or the session reads as the working overseer it
            // looks like.
            if marks().is_some_and(|m| m.confirms_wall()) {
                Verdict::Walled {
                    source: Source::Pane,
                    kind: WallKind::Usage,
                    text: banner,
                }
            } else {
                Verdict::Live
            }
        }
        State::Walled {
            kind: WallKind::Auth,
            ..
        }
        | State::Idle
        | State::Working
        | State::Asking
        | State::RateLimitSwitch
        | State::Unjudged { .. } => Verdict::Live,
    }
}

fn set(kind: &str, identity: &str, value: String) -> Change {
    Change::Set {
        kind: kind.to_owned(),
        identity: identity.to_owned(),
        value,
    }
}

fn clear(kind: &str, identity: &str) -> Change {
    Change::Clear {
        kind: kind.to_owned(),
        identity: identity.to_owned(),
    }
}

/// The rows this duty keeps, keyed by the pane key.
const ROWS: [&str; 5] = [
    "overseer-dead",
    "overseer-walled",
    "overseer-mark",
    TRANSFER_ROW,
    context::GAP_ROW,
];

/// The row naming the transfer a `requested` case row asked for,
/// `<attempt>:<intent>`: the case row is the admission, and the intent's
/// own outcome is what the next pass reads.
const TRANSFER_ROW: &str = "overseer-transfer";

/// A recovery's transfers: the first and one more after a failure, as the
/// recovery's bounded retry runs them.
const TRANSFER_ATTEMPTS: u32 = 2;

/// The duty's pass: the one verdict, stored in `slot`, then the count, the
/// line and the request.
pub fn observe(pass: &Pass, slot: &Slot) -> Produced {
    let mut out = Produced::default();
    let judged = pass_verdict(pass, &mut out);
    slot.store(judged);
    out
}

fn pass_verdict(pass: &Pass, out: &mut Produced) -> Judged {
    let at = pass.now;
    let judged = |verdict: Verdict, pane_key: Option<String>| Judged {
        verdict,
        pane_key,
        at,
    };
    if let Some(intent) = pass
        .fleet
        .intents
        .iter()
        .find(|i| i.open() && i.op.on_controller())
    {
        return judged(
            Verdict::Transferring {
                intent: intent.id.clone(),
            },
            None,
        );
    }
    let Some(record) = Record::read(pass.fleet) else {
        return judged(
            Verdict::Unwatched {
                cause: "record-unnamed",
            },
            None,
        );
    };
    let key = record.pane_key();
    // Rows of a pane that is no longer the controller's go with it.
    for kind in ROWS {
        for identity in pass.baseline.identities(kind) {
            if identity != key {
                out.changes.push(clear(kind, &identity));
            }
        }
    }
    let reads = match (pass.readers.pane)(record.server, record.server_start, &record.pane) {
        Reading::Live(fields) => Reads {
            process: (pass.readers.foreground)(
                fields.pid,
                record.harness,
                record.identity.as_ref(),
            ),
            screen: (pass.readers.capture)(&fields.pane),
            rows: record.session_rows.as_deref().map(rows::session_verdict),
        },
        Reading::Gone => {
            return judged(
                Verdict::Unreadable {
                    cause: "pane-gone".to_owned(),
                },
                Some(key),
            );
        }
        Reading::Unreadable { cause } => {
            return judged(
                Verdict::Unreadable {
                    cause: cause.to_owned(),
                },
                Some(key),
            );
        }
    };
    // The overseer's own context record, read once per pass where the
    // fleet has a mailbox root: the reading the judge is handed, the
    // wedge and the stale and gap judgements all read this one record.
    let context = pass
        .context_record
        .map(|p| context::own(p, record.session_rows.as_deref(), &key, record.harness));
    let context_arg = match &context {
        Some(Owned::Own(r)) => r.context_arg(),
        Some(Owned::Other | Owned::Absent | Owned::Unreadable { .. }) | None => None,
    };
    // The account judgement, read at most once per pass and only where a
    // reading asks for it.
    let caller = Caller::of(&record);
    let mut marks_read: Option<Option<Marks>> = None;
    let mut marks = || -> Option<Marks> {
        if marks_read.is_none() {
            marks_read = Some((pass.judges.marks)(&caller, context_arg.as_deref()).ok());
        }
        marks_read.clone().flatten()
    };
    let mut verdict = judge(&record, &reads, &mut marks);
    let mut reserve = false;
    if verdict == Verdict::Live
        && let Some(m) = marks()
        && m.key == MarkKey::Reached(MarkKind::Headroom)
        && m.value == "0"
    {
        if m.reserve_only {
            reserve = true;
        } else {
            verdict = Verdict::Walled {
                source: Source::Account,
                kind: WallKind::Usage,
                text: format!(
                    "account={} headroom=0 resets={}",
                    if m.account.is_empty() {
                        "unknown"
                    } else {
                        &m.account
                    },
                    if m.resets.is_empty() {
                        "none"
                    } else {
                        &m.resets
                    }
                ),
            };
        }
    }
    // A harness whose recorded context fills its window takes no turn
    // again, and nothing but a relaunch ends that: read as dead,
    // `source=context`, on the same count of passes a death takes, so one
    // reading caught between a turn's reading and its failure never
    // relaunches a session.
    if verdict == Verdict::Live
        && let Some(Owned::Own(r)) = &context
        && r.gap.is_none()
        && wedged(r, &record, pass)
    {
        verdict = Verdict::Exited {
            source: Source::Context,
        };
    }
    let marks_now = marks_read.clone().flatten();
    let (case, source, passes_needed) = match &verdict {
        Verdict::Exited { source } => {
            (Some(OverseerCase::Dead), *source, pass.settings.dead_passes)
        }
        Verdict::Walled { source, .. } => (
            Some(OverseerCase::Walled),
            *source,
            if *source == Source::Pane {
                pass.settings.dead_passes
            } else {
                1
            },
        ),
        Verdict::Live if reserve => (Some(OverseerCase::Reserve), Source::Account, 1),
        Verdict::Live
        | Verdict::Transferring { .. }
        | Verdict::Unwatched { .. }
        | Verdict::Unreadable { .. } => (None, Source::Pane, 0),
    };
    let Some(case) = case else {
        // Live, or a read that settles nothing: the death count is dropped
        // only on a live reading, never on an unreadable one.
        if verdict == Verdict::Live {
            out.changes.push(clear("overseer-dead", &key));
            out.changes.push(clear(TRANSFER_ROW, &key));
            let prior = pass.baseline.get("overseer-walled", &key).unwrap_or("");
            if !prior.starts_with("reserve:")
                || marks_now.as_ref().is_some_and(|m| m.key == MarkKey::Below)
            {
                out.changes.push(clear("overseer-walled", &key));
            }
            mark_check(&record, &key, marks_now.as_ref(), pass, out);
            context_check(&record, &key, context.as_ref(), pass, out);
        }
        return judged(verdict, Some(key));
    };
    let (row, other) = match case {
        OverseerCase::Dead => ("overseer-dead", "overseer-walled"),
        OverseerCase::Walled | OverseerCase::Reserve => ("overseer-walled", "overseer-dead"),
    };
    out.changes.push(clear(other, &key));
    out.changes.push(clear("overseer-mark", &key));
    // A working overseer on its reserve is the only cased one with a
    // context to judge: neither a dead nor a walled one runs a turn.
    if case == OverseerCase::Reserve {
        context_check(&record, &key, context.as_ref(), pass, out);
    }
    let prefix = if case == OverseerCase::Reserve {
        "reserve:"
    } else {
        ""
    };
    let prior = pass.baseline.get(row, &key).unwrap_or("").to_owned();
    // A reserve attempt neither consumes nor suppresses a real failure's
    // recovery.
    let prior = match (case, prior.strip_prefix("reserve:")) {
        (OverseerCase::Reserve, Some(p)) => p.to_owned(),
        (OverseerCase::Reserve, None) => prior,
        (OverseerCase::Dead | OverseerCase::Walled, Some(_)) => String::new(),
        (OverseerCase::Dead | OverseerCase::Walled, None) => prior,
    };
    match prior.as_str() {
        "reported" => return judged(verdict, Some(key)),
        "requested" => {
            transfer_settled(&record, row, &key, prefix, pass, out);
            return judged(verdict, Some(key));
        }
        "announced" => {
            transfer(&record, case, &verdict, &key, prefix, pass, out);
            return judged(verdict, Some(key));
        }
        _ => {}
    }
    let count = prior.parse::<u32>().unwrap_or(0) + 1;
    if count < passes_needed {
        out.changes.push(set(row, &key, format!("{prefix}{count}")));
        return judged(verdict, Some(key));
    }
    // The line, with the wall's own words under it, before anything moves.
    let plan_relaunch = pass.succession == Succession::On
        && match case {
            OverseerCase::Dead => record.held_successor().is_some(),
            OverseerCase::Walled | OverseerCase::Reserve => true,
        };
    let record_field = match case {
        OverseerCase::Dead if record.held_successor().is_none() => {
            Some(format!("{}:{}", record.server, record.pane))
        }
        OverseerCase::Dead | OverseerCase::Walled | OverseerCase::Reserve => None,
    };
    // A new episode counts its own transfers.
    out.changes.push(clear(TRANSFER_ROW, &key));
    out.events.push(Event::OverseerSession {
        case,
        pane: record.pane.clone(),
        window: record.window.clone(),
        passes: passes_needed,
        succession: pass.succession,
        source: source.word().to_owned(),
        record: record_field,
    });
    if let Verdict::Walled { source, text, .. } = &verdict {
        let lines: Vec<String> = match source {
            Source::Pane => {
                let slice = reads
                    .screen
                    .as_deref()
                    .map(observe::below_last_turn)
                    .unwrap_or_default();
                banner_payload(&slice, text, pass.settings.tail_lines as usize).unwrap_or_default()
            }
            Source::Auth
            | Source::Record
            | Source::Rows
            | Source::Context
            | Source::Process
            | Source::Account => text.lines().map(str::to_owned).collect(),
        };
        out.events.extend(lines.into_iter().map(Event::Tail));
    }
    // The request follows on the duty's next run, after the line is on
    // disk: the row says it is owed and the duty asks to run again at once.
    out.changes.push(set(
        row,
        &key,
        format!(
            "{prefix}{}",
            if plan_relaunch {
                "announced"
            } else {
                "reported"
            }
        ),
    ));
    out.next_due = plan_relaunch.then_some(pass_next_due());
    judged(verdict, Some(key))
}

/// The session's own reading read as wedged: the window full by the
/// record's own figure or the harness's declared capacity, and
/// no Stop row after the reading. A reading the judge cannot take is
/// noted and settles nothing.
fn wedged(r: &context::ContextRecord, record: &Record, pass: &Pass) -> bool {
    let Some(path) = pass.context_record else {
        return false;
    };
    let harness = r.harness.as_deref().and_then(Harness::parse);
    match harness.and_then(|h| r.window_full(h)) {
        Some(true) => {}
        Some(false) => return false,
        None => {
            context::note(
                "overseer-context-unread",
                &format!(
                    "path={} harness={}",
                    path.display(),
                    r.harness.as_deref().unwrap_or("none")
                ),
            );
            return false;
        }
    }
    match context::times(r, path, record.session_rows.as_deref()) {
        Times::Read { at, stop } => stop <= at,
        Times::Unread { path, cause } => {
            context::note(
                "overseer-context-unread",
                &format!("path={} {cause}", path.display()),
            );
            false
        }
    }
}

/// The context record of a working overseer: a gap is one standing gap's
/// turn (`gap_turn`); a
/// reading clears the gap row and is `overseer-context-stale` where the
/// record's `at` is more than [`context::STALE_SECS`] old and a Stop row
/// came after it, on every pass it stands. A record that is not this
/// session's, or none, settles nothing and moves no row; one that could
/// not be read is noted.
fn context_check(
    record: &Record,
    key: &str,
    context: Option<&Owned>,
    pass: &Pass,
    out: &mut Produced,
) {
    let (Some(path), Some(owned)) = (pass.context_record, context) else {
        return;
    };
    let r = match owned {
        Owned::Own(r) => r,
        Owned::Other | Owned::Absent => return,
        Owned::Unreadable { path, cause } => {
            context::note(
                "overseer-context-unread",
                &format!("path={} cause={cause}", path.display()),
            );
            return;
        }
    };
    if let Some(gap) = &r.gap {
        gap_turn(record, key, gap, pass, out);
        return;
    }
    out.changes.push(clear(context::GAP_ROW, key));
    let (at, stop) = match context::times(r, path, record.session_rows.as_deref()) {
        Times::Read { at, stop } => (at, stop),
        Times::Unread { path, cause } => {
            context::note(
                "overseer-context-unread",
                &format!("path={} {cause}", path.display()),
            );
            return;
        }
    };
    let age = pass.now.saturating_sub(at);
    if age > context::STALE_SECS && stop > at {
        out.events.push(Event::OverseerContextStale {
            pane: record.pane.clone(),
            age,
        });
    }
}

/// One standing gap's turn (the owner's turn of `super::owner_alert`):
/// the event on its first pass, the owner's alert
/// on its second, nothing after. The row is the owed mark: `<gap>|told` is
/// written before the alert is owed, and advanced to `<gap>|alerted` only
/// once the owner holds the words, so an alert the owner did not get is
/// sent again on the next pass. A different gap starts the turn again.
fn gap_turn(record: &Record, key: &str, gap: &str, pass: &Pass, out: &mut Produced) {
    let prior = pass.baseline.get(context::GAP_ROW, key).unwrap_or("");
    match Word::of_row(prior, gap) {
        Some(Word::Alerted) => {}
        Some(Word::Told) => match (pass.alert)(&context::alert_text(&record.pane, gap)) {
            Ok(()) => {
                context::note(
                    "overseer-context-alerted",
                    &format!("pane={} gap={gap}", record.pane),
                );
                out.changes
                    .push(set(context::GAP_ROW, key, Word::Alerted.row(gap)));
            }
            Err(cause) => context::note(
                "overseer-notice-failed",
                &format!("channel=owner cause={cause}"),
            ),
        },
        None => {
            out.events.push(Event::OverseerContextUnmeasured {
                pane: record.pane.clone(),
                gap: gap.to_owned(),
            });
            out.changes
                .push(set(context::GAP_ROW, key, Word::Told.row(gap)));
        }
    }
}

/// The instant the announced request is made at: the duty's next slice.
#[allow(
    clippy::disallowed_methods,
    reason = "the one instant the duty asks to run again at, which the runner floors at its next slice"
)]
fn pass_next_due() -> std::time::Instant {
    std::time::Instant::now()
}

/// The transfer a `requested` row asked for, read by its outcome: in
/// flight, or confirmed, it holds, a confirmed transfer having moved the
/// record; failed, it is said as `overseer-relaunch-failed` with the
/// intent's note as its step and asked again on the next run while the
/// recovery's attempts last, else the row is `reported`. A row naming no
/// transfer is a succession owner's command, whose outcome is the
/// owner's. A succession command that gave no answer is read by the
/// record: one that moved it names another session, which this row never
/// reads again; one that still names this session once the settle bound
/// has passed is the owner's failure, said and `reported`.
fn transfer_settled(
    record: &Record,
    row: &str,
    key: &str,
    prefix: &str,
    pass: &Pass,
    out: &mut Produced,
) {
    if let Some(asked) = pass
        .baseline
        .get(TRANSFER_ROW, key)
        .and_then(|v| v.strip_prefix("succession:"))
    {
        let asked = asked.parse::<u64>().unwrap_or(0);
        if pass.now >= asked.saturating_add(SUCCESSION_SETTLE.as_secs()) {
            out.failed.get_or_insert(format!(
                "succession-owner-failed cause=unanswered pane={} record=unmoved",
                record.pane
            ));
            out.changes.push(set(row, key, format!("{prefix}reported")));
            out.changes.push(clear(TRANSFER_ROW, key));
        }
        return;
    }
    let Some((attempt, intent_id)) = pass
        .baseline
        .get(TRANSFER_ROW, key)
        .and_then(|v| v.split_once(':'))
        .and_then(|(n, id)| Some((n.parse::<u32>().ok()?, id.to_owned())))
    else {
        return;
    };
    let Some(intent) = pass.fleet.intents.iter().find(|i| i.id == intent_id) else {
        return;
    };
    if intent.open() || intent.outcome == agent_runtime::protocol::Outcome::Confirmed {
        return;
    }
    let observed = |field: &str| {
        intent
            .observation
            .as_ref()
            .and_then(|o| o.get(field))
            .and_then(Value::as_str)
            .map(str::to_owned)
    };
    let step = observed("note")
        .or_else(|| observed("cause"))
        .unwrap_or_else(|| "failed".to_owned());
    let retry = attempt < TRANSFER_ATTEMPTS;
    context::note(
        if prefix.is_empty() {
            "overseer-relaunch-failed"
        } else {
            "overseer-capacity-failed"
        },
        &format!(
            "pane={} attempt={attempt} retry={} step={step}",
            record.pane,
            if retry { "pending" } else { "exhausted" }
        ),
    );
    if retry {
        out.changes
            .push(set(row, key, format!("{prefix}announced")));
        out.next_due = Some(pass_next_due());
    } else {
        out.changes.push(set(row, key, format!("{prefix}reported")));
        out.changes.push(clear(TRANSFER_ROW, key));
    }
}

/// The announced succession: `request-transfer` with the case's cause and
/// the spent account, the successor a walled case takes from the overseer
/// walk with the spent account excluded; a refusal is the duty's failure,
/// said on the log by the runner, and the row stays announced so the next
/// pass asks again. An admitted transfer is `requested`, its intent and
/// attempt on the transfer row for the next pass to read its outcome. A
/// controller whose record names its own succession
/// owner has that owner's command run instead, once: the row is
/// `requested` on its success and `reported` on its failure, so a command
/// that fails is not run again every pass. A command that gave no answer is
/// `requested` with its pass on the transfer row: the record settles it.
fn transfer(
    record: &Record,
    case: OverseerCase,
    verdict: &Verdict,
    key: &str,
    prefix: &str,
    pass: &Pass,
    out: &mut Produced,
) {
    let row = match case {
        OverseerCase::Dead => "overseer-dead",
        OverseerCase::Walled | OverseerCase::Reserve => "overseer-walled",
    };
    let (cause, exclude_account, successor) = match case {
        OverseerCase::Dead => (TransferCause::Dead, None, record.held_successor()),
        OverseerCase::Walled | OverseerCase::Reserve => {
            let spent = match verdict {
                Verdict::Walled {
                    source: Source::Account,
                    ..
                }
                | Verdict::Live => record.account.clone(),
                Verdict::Walled { .. } => record.account.clone(),
                Verdict::Exited { .. }
                | Verdict::Transferring { .. }
                | Verdict::Unwatched { .. }
                | Verdict::Unreadable { .. } => None,
            };
            let caller = Caller::of(record);
            let successor = match (record.harness, spent.as_deref()) {
                (Some(harness), Some(spent)) => {
                    let request = WalkRequest {
                        scope: walk::Scope::Overseer,
                        preference: None,
                        lane: None,
                        exclude: vec![spent.to_owned()],
                        replaces: None,
                        max_pct: None,
                        min_headroom_pct: None,
                        source: Some(crate::ops::successor::source(&caller, harness)),
                        caller: Some(caller.walk_entry(harness)),
                        keep_unmeasured: false,
                    };
                    match (pass.judges.walk)(&request) {
                        Ok(walked) => match &walked.answer {
                            walk::WalkAnswer::Lane(chosen) => Some(caller.successor_of(chosen)),
                            walk::WalkAnswer::None | walk::WalkAnswer::Held { .. } => None,
                        },
                        Err(_) => None,
                    }
                }
                (None, _) | (_, None) => None,
            };
            (TransferCause::Walled, spent, successor)
        }
    };
    if let Some(words) = record.succession() {
        out.events
            .push(Event::Tail(format!("succession owner={}", words.join(" "))));
        let word = match (pass.judges.succeed)(&words) {
            Ok(SuccessionAnswer::Done) => "requested",
            Ok(SuccessionAnswer::Unanswered { cause }) => {
                context::note(
                    "succession-owner-unanswered",
                    &format!("pane={} cause={cause}", record.pane),
                );
                out.changes
                    .push(set(TRANSFER_ROW, key, format!("succession:{}", pass.now)));
                "requested"
            }
            Err(cause) => {
                out.failed
                    .get_or_insert(format!("succession-owner-failed cause={cause}"));
                "reported"
            }
        };
        out.changes.push(set(row, key, format!("{prefix}{word}")));
        return;
    }
    let Some(successor) = successor else {
        out.changes.push(set(row, key, format!("{prefix}reported")));
        return;
    };
    let request = RequestTransfer {
        expected: record.expected(),
        successor,
        brief_file: None,
        cause,
        exclude_account,
        handoff_session_id: None,
        recovery: None,
    };
    match (pass.transfer)(request) {
        Ok(intent) => {
            let attempt = pass
                .baseline
                .get(TRANSFER_ROW, key)
                .and_then(|v| v.split_once(':'))
                .and_then(|(n, _)| n.parse::<u32>().ok())
                .unwrap_or(0)
                + 1;
            out.changes
                .push(set(row, key, format!("{prefix}requested")));
            out.changes
                .push(set(TRANSFER_ROW, key, format!("{attempt}:{intent}")));
        }
        Err(cause) => {
            out.failed
                .get_or_insert(format!("transfer-refused cause={cause}"));
        }
    }
}

/// One relaunch marker as the lanes pass wrote it (`ops::wall`,
/// `write_relaunch_marker`).
#[derive(serde::Deserialize)]
struct Marker {
    item: String,
    since: u64,
    log: String,
}

/// The relaunch markers under the watch state directory, each a regular
/// file `wall-relaunch.<lane>` in name order; an absent directory holds
/// none.
fn relaunch_markers(dir: &Path) -> Result<Vec<PathBuf>, String> {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e.to_string()),
    };
    let mut markers = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|e| e.to_string())?;
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !name.starts_with("wall-relaunch.") || name.ends_with(".exit") {
            continue;
        }
        let path = entry.path();
        if std::fs::metadata(&path).is_ok_and(|m| m.is_file()) {
            markers.push(path);
        }
    }
    markers.sort();
    Ok(markers)
}

/// Whether a lane's gone window is a relaunch the route started still
/// opening it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RelaunchPending {
    /// The marker stands with no status beside it, inside `prepare` of
    /// its start.
    Pending,
    /// No marker, a status beside it, or a start `prepare` or more ago:
    /// the gone window is left to `window-gone`.
    None,
    /// A marker or stamp that could not be read; never "not pending".
    Unreadable { path: PathBuf, cause: String },
}

/// The lane's marker read once, three-valued: an absent marker, or a
/// status beside it, is no pending relaunch; a marker or stamp that cannot
/// be read is unreadable, never "not pending"; otherwise the start inside
/// `prepare` of now is pending (a start ahead of now is inside it).
pub fn relaunch_pending(marker: &Path, prepare: Duration, now: u64) -> RelaunchPending {
    let unreadable = |path: &Path, cause: String| RelaunchPending::Unreadable {
        path: path.to_path_buf(),
        cause,
    };
    let text = match std::fs::read_to_string(marker) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return RelaunchPending::None,
        Err(e) => return unreadable(marker, e.to_string()),
    };
    let exit = relaunch_exit_path(marker);
    match std::fs::metadata(&exit) {
        Ok(_) => return RelaunchPending::None,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return unreadable(&exit, e.to_string()),
    }
    let fields = match serde_json::from_str::<Marker>(&text) {
        Ok(fields) => fields,
        Err(e) => return unreadable(marker, e.to_string()),
    };
    if fields.since > now || now - fields.since < prepare.as_secs() {
        RelaunchPending::Pending
    } else {
        RelaunchPending::None
    }
}

/// The launch a relaunch's chain asked, the one whose status was
/// [`crate::effects::UNCONFIRMED_EXIT`]: the item's latest `launch-lane`
/// intent, since the chain's status is its launch's and no other launch of
/// the item runs while the marker stands.
fn relaunched<'a>(fleet: &'a FleetState, item: &str) -> Option<&'a crate::state::Intent> {
    fleet
        .intents
        .iter()
        .filter(|i| i.op == crate::state::EffectOp::LaunchLane && i.target == item)
        .max_by(|a, b| a.created_at.cmp(&b.created_at))
}

/// Every relaunch marker with an exit status beside it is read once,
/// `lane-prepare-failed ...
/// reason=relaunch-failed exit= log=` for a non-zero status, and the marker
/// and its status leave; a marker with no status `prepare` past its start
/// is `lane-prepare-stuck ... reason=relaunch-pending` once per start (the
/// `wall-relaunch` row keyed `<since>|stuck`, cleared when the status
/// lands). A status of [`crate::effects::UNCONFIRMED_EXIT`] is no outcome
/// yet: the marker stands, read against the item's launch intent, until the
/// intent's reconcile settles it, a failure said once as
/// `lane-prepare-failed ... reason=relaunch-failed log=` and a confirmation
/// saying nothing, and while it stays open the marker reads as one with no
/// status. A marker, a status or a removal that fails is the pass's
/// partial failure, the marker kept for the next pass; a status that is no
/// exit code is such a failure, never a result.
#[allow(
    clippy::disallowed_methods,
    reason = "the relaunch marker and its exit status, the watch's own files written for this reader, removed once their outcome is reported"
)]
pub fn relaunch_outcomes(
    watch_state_dir: &Path,
    fleet: &FleetState,
    prepare: Duration,
    now: u64,
    baseline: &Baseline,
) -> Produced {
    let mut out = Produced::default();
    let markers = match relaunch_markers(watch_state_dir) {
        Ok(markers) => markers,
        Err(cause) => {
            out.failed = Some(format!(
                "state-read-failed path={} cause={cause}",
                watch_state_dir.display()
            ));
            return out;
        }
    };
    fn failed(out: &mut Produced, op: &str, path: &Path, cause: String) {
        out.failed.get_or_insert(format!(
            "state-{op}-failed path={} cause={cause}",
            path.display()
        ));
    }
    for marker in markers {
        let fields = match std::fs::read_to_string(&marker)
            .map_err(|e| e.to_string())
            .and_then(|text| serde_json::from_str::<Marker>(&text).map_err(|e| e.to_string()))
        {
            Ok(fields) => fields,
            Err(cause) => {
                failed(&mut out, "read", &marker, cause);
                continue;
            }
        };
        let exit = relaunch_exit_path(&marker);
        let status = match std::fs::read_to_string(&exit) {
            Ok(text) => Some(text),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
            Err(e) => {
                failed(&mut out, "read", &exit, e.to_string());
                continue;
            }
        };
        // What the relaunch came to: pending (no status yet, or a launch its
        // reconcile has not settled), or ended with the chain's status,
        // `None` for a launch settled failed after its chain ended, which
        // has no status of its own to say.
        let ended = match status {
            None => None,
            Some(text) => match text.trim_end_matches('\n').parse::<i32>() {
                Ok(crate::effects::UNCONFIRMED_EXIT) => match relaunched(fleet, &fields.item) {
                    Some(intent) if intent.open() => None,
                    Some(intent)
                        if intent.outcome == agent_runtime::protocol::Outcome::Confirmed =>
                    {
                        Some(Some(0))
                    }
                    Some(_) => Some(None),
                    None => {
                        failed(&mut out, "read", &exit, "launch-intent-absent".to_owned());
                        continue;
                    }
                },
                Ok(rc) => Some(Some(rc)),
                Err(_) => {
                    failed(&mut out, "read", &exit, format!("no exit status: {text:?}"));
                    continue;
                }
            },
        };
        match ended {
            Some(rc) => {
                if rc != Some(0) {
                    out.events.push(Event::LanePrepareFailed {
                        item: fields.item.clone(),
                        reason: "relaunch-failed".to_owned(),
                        exit: rc,
                        log: fields.log,
                    });
                }
                for path in [&marker, &exit] {
                    if let Err(e) = std::fs::remove_file(path) {
                        failed(&mut out, "write", path, e.to_string());
                    }
                }
                out.changes.push(clear("wall-relaunch", &fields.item));
            }
            None => {
                let age = now.saturating_sub(fields.since);
                if fields.since > now || age < prepare.as_secs() {
                    continue;
                }
                let key = format!("{}|stuck", fields.since);
                if baseline.get("wall-relaunch", &fields.item) == Some(key.as_str()) {
                    continue;
                }
                out.events.push(Event::LanePrepareStuck {
                    item: fields.item.clone(),
                    age,
                    log: fields.log,
                    reason: Some("relaunch-pending".to_owned()),
                });
                out.changes.push(set("wall-relaunch", &fields.item, key));
            }
        }
    }
    out
}

/// The marks of a working overseer: the first crossing is a line, then one
/// every `mark_repeat` passes while it stands; a below-mark answer clears
/// the row; an unmeasured or failed judgement leaves it as it was.
fn mark_check(record: &Record, key: &str, marks: Option<&Marks>, pass: &Pass, out: &mut Produced) {
    let Some(marks) = marks else {
        return;
    };
    let kind = match marks.key {
        MarkKey::Unmeasured(_) => return,
        MarkKey::Below => {
            out.changes.push(clear("overseer-mark", key));
            return;
        }
        MarkKey::Reached(kind) => kind.word(),
    };
    if marks.value.is_empty() || marks.mark.is_empty() {
        return;
    }
    let prior = pass.baseline.get("overseer-mark", key).unwrap_or("");
    let mut passes = 0;
    if let Some(count) = prior.strip_prefix(&format!("{kind}|")) {
        passes = count.parse::<u32>().unwrap_or(0) + 1;
        if passes >= pass.settings.mark_repeat {
            passes = 0;
        }
    }
    if passes == 0 {
        out.events.push(Event::OverseerMark {
            pane: record.pane.clone(),
            kind: kind.to_owned(),
            value: marks.value.clone(),
            mark: marks.mark.clone(),
            succession: marks.succession,
        });
        // The handling under the line: the succession's own words, naming
        // the walk the verb takes for this mark: at a context mark with no
        // preference set, the session's own entry alone, unless the
        // session's account has reached its own mark: the verb reads the
        // account, which the watch does not, and walks as that mark.
        let walks = match (marks.key, pass.preference) {
            (MarkKey::Reached(MarkKind::Context), None) => format!(
                "this session's own entry alone, ORCH_OVERSEER_PREFERENCE being unset; where this session's account has reached its headroom or rate mark, ORCH_OVERSEER_PREFERENCE={} without that account",
                crate::settings::DEFAULT_OVERSEER_PREFERENCE
            ),
            (_, Some("")) => "ORCH_OVERSEER_PREFERENCE=empty".to_owned(),
            (_, preference) => format!(
                "ORCH_OVERSEER_PREFERENCE={}",
                preference.unwrap_or(crate::settings::DEFAULT_OVERSEER_PREFERENCE)
            ),
        };
        // A controller another lifecycle replaces is handed over by that
        // owner alone, whatever the setting: the setting governs orch's own
        // transfer, which refuses this record.
        let sentence = match (record.succession(), marks.succession) {
            (Some(words), Succession::On | Succession::Off) => format!(
                "Hand this session over at the next safe point through the succession owner its record names: run {} and read its outcome; that owner replaces this controller, so choose no successor and ask for no transfer.",
                words.join(" ")
            ),
            (None, Succession::Off) => "ORCH_OVERSEER_SUCCESSION is off, so no successor opens: rewrite the overseer handoff file and ask the user to start a fresh overseer session.".to_owned(),
            (None, Succession::On) => format!(
                "Hand this session over at the next safe point: write the overseer handoff file, choose the successor with orch-runtime successor --fleet --cwd {} --predecessor {} --mark {kind} (it walks {walks}) and ask orch-runtime op --fleet --effect-exit for request-transfer with cause live, its .result.successor as the successor and its .result.expected as the expected record, which answers the transfer's own outcome.",
                text(record.raw.get("cwd")).unwrap_or_else(|| "[CHECKOUT]".to_owned()),
                record.pane,
            ),
        };
        out.events.push(Event::Tail(sentence));
    }
    out.changes
        .push(set("overseer-mark", key, format!("{kind}|{passes}")));
}

/// The `marks` verb: the recorded controller's own marks for the caller
/// its fleet record names, the harness and account the request names
/// standing in where the record names none; the reply is [`Marks::reply`].
#[allow(
    clippy::disallowed_methods,
    reason = "the verb's one read of the fleet state, a snapshot the judge reads; the kernel host for the judge's occupancy read, which acts on nothing"
)]
pub fn marks_verb(
    settings: &Settings,
    path: &Path,
    context: Option<&str>,
    harness: Option<&str>,
    account: Option<&str>,
    now: u64,
) -> crate::error::Result<Value> {
    let harness = match harness {
        Some(word) => Some(Harness::parse(word).ok_or_else(|| {
            crate::error::Error::from(agent_runtime::Error::refused(
                "harness-unknown",
                &[("harness", word)],
            ))
        })?),
        None => None,
    };
    let record = crate::state::load(path)?
        .map(|snapshot| {
            <crate::state::FleetState as crate::state::Record>::view(path, &snapshot.doc)
        })
        .transpose()?
        .as_ref()
        .and_then(Record::read)
        .ok_or_else(|| {
            crate::error::Error::from(agent_runtime::Error::refused(
                "record-missing",
                &[("path", &path.display().to_string())],
            ))
        })?;
    let mut caller = Caller::of(&record);
    caller.harness = caller.harness.or(harness);
    caller.account = caller.account.or_else(|| account.map(str::to_owned));
    let host = crate::ops::Host::kernel(settings.lane_cap);
    let memory = |identity: &Identity| {
        agent_runtime::process::memory_of(
            Path::new("/proc"),
            Path::new("/sys/fs/cgroup"),
            identity.pid,
        )
    };
    let marks = judge_marks(&MarksAsk {
        settings,
        fleet_path: path,
        host: &host,
        caller: &caller,
        context,
        memory: &memory,
        now,
    })?;
    Ok(marks.reply())
}

/// The transfer as the `op` command runs it: its successor's posture the
/// settings' where it carries none, as the `successor` verb fills it,
/// admitted, applied through the store's entry with the host's facts, its
/// effect started.
#[allow(
    clippy::disallowed_methods,
    reason = "the overseer duty's one request, request-transfer with its cause: the same sequence the op command runs (admit, the store's entry with the kernel's readers, the effect's start), from the duty that read the session dead or walled"
)]
pub fn run_transfer(
    path: &Path,
    settings: &Settings,
    env: &crate::ops::Env,
    locking: crate::state::Locking,
    clock: &dyn crate::schedule::Clock,
    mut request: RequestTransfer,
) -> crate::error::Result<String> {
    crate::ops::successor::posture(&mut request.successor, settings);
    let request = crate::ops::Request::RequestTransfer(Box::new(request));
    crate::ops::admit(&request, settings)?;
    let host = crate::ops::Host::kernel(settings.lane_cap);
    let applied = crate::ops::apply_on(path, &request, env, locking, &host)?;
    let crate::ops::Report::RequestTransfer(report) = &applied.report else {
        unreachable!("a transfer request reports its transfer")
    };
    let intent = match &report.effect {
        crate::ops::Effect::Persisted { intent }
        | crate::ops::Effect::Reconciled { intent }
        | crate::ops::Effect::Supersedes { intent } => intent.id.clone(),
    };
    crate::effects::run(
        path,
        &request,
        &applied.report,
        settings,
        env,
        locking,
        clock,
    )?;
    Ok(intent)
}

/// Register the native observation duty: the controller's one verdict
/// first, stored in `slot`; then, where that verdict leaves the fleet
/// watched (live, unwatched or unreadable), the lanes.
/// `env` supplies the request's stamp inputs; the runner's own pane is its
/// `$TMUX_PANE`, never a stray.
pub fn register(
    runner: &mut Runner<'_>,
    path: &Path,
    settings: &Settings,
    env: &crate::ops::Env,
    locking: crate::state::Locking,
    slot: Slot,
) {
    let ctx = Observation {
        path: path.to_path_buf(),
        settings: settings.clone(),
        nonce: env.nonce,
        owner: env.owner.clone(),
        locking,
        slot,
        own_pane: std::env::var("TMUX_PANE").ok(),
    };
    runner.register(crate::schedule::Duty::NativeObservation, body(ctx));
}

/// What the native observation duty runs with: the fleet state it reads,
/// the settings, the stamp inputs of its one request, and the slot the
/// mail duty reads the controller's verdict from.
struct Observation {
    path: PathBuf,
    settings: Settings,
    nonce: u32,
    owner: Option<crate::state::Owner>,
    locking: crate::state::Locking,
    slot: Slot,
    /// The runner's own pane, never a stray.
    own_pane: Option<String>,
}

/// The native observation duty's body: the controller's one verdict
/// first, stored in the slot; then, where that verdict leaves the fleet
/// watched (live, unwatched or unreadable), the lanes.
#[allow(
    clippy::disallowed_methods,
    reason = "the observation duty's one read of the fleet state each pass, a snapshot it judges; its transfer request goes through `run_transfer` and its wall record through `ops::apply`"
)]
fn body<'a>(ctx: Observation) -> Body<'a> {
    Box::new(move |tick: &Tick| {
        let Some(snapshot) = crate::state::load(&ctx.path)? else {
            return Ok(Produced::default());
        };
        let fleet =
            <crate::state::FleetState as crate::state::Record>::view(&ctx.path, &snapshot.doc)?;
        let readers = LaneReaders::kernel();
        // The accounts judge over the fleet's own state and the kernel's
        // identity reader: the marks, the overseer walk and the wall
        // route's pick, each a verdict this duty receives.
        let occupancy_host = crate::ops::Host::kernel(ctx.settings.lane_cap);
        let memory = |identity: &Identity| {
            agent_runtime::process::memory_of(
                Path::new("/proc"),
                Path::new("/sys/fs/cgroup"),
                identity.pid,
            )
        };
        let marks = |caller: &Caller, context: Option<&str>| {
            judge_marks(&MarksAsk {
                settings: &ctx.settings,
                fleet_path: &ctx.path,
                host: &occupancy_host,
                caller,
                context,
                memory: &memory,
                now: tick.wall,
            })
            .map_err(|e| e.to_string())
        };
        let walk = |request: &WalkRequest| {
            walk::walk(
                &ctx.settings,
                &ctx.path,
                &occupancy_host,
                request,
                tick.wall,
            )
            .map_err(|e| e.to_string())
        };
        let wall_pick = |_: &Path, harness: Harness, model: &str, spent: &str| {
            picked_by_judge(accounts::pick_fleet(
                &ctx.settings,
                &ctx.path,
                &occupancy_host,
                &PickRequest {
                    harness: harness.name().to_owned(),
                    model: Some(model.to_owned()),
                    exclude: vec![spent.to_owned()],
                    for_overseer: false,
                    ..PickRequest::default()
                },
                tick.wall,
            ))
        };
        let judges = Judges {
            scripts: scripts_dir(&ctx.settings.roots.project),
            marks: &marks,
            walk: &walk,
            wall_pick: &wall_pick,
            relaunch: &relaunch_through_launcher,
            succeed: &succeed_through_runner,
        };
        let context_record = ctx
            .settings
            .roots
            .common
            .join("tmp/lane-mail/overseer")
            .join("context.json");
        let alert = |text: &str| owner_alert::send(&ctx.settings, GAP_ALERT_FILE, text);
        let env = crate::ops::Env {
            now_secs: tick.wall,
            now_nanos: u128::from(tick.wall) * 1_000_000_000,
            nonce: ctx.nonce,
            owner: ctx.owner.clone(),
        };
        let transfer = |request| {
            run_transfer(
                &ctx.path,
                &ctx.settings,
                &env,
                ctx.locking,
                tick.clock,
                request,
            )
            .map_err(|e| e.to_string())
        };
        let mut produced = observe(
            &Pass {
                fleet: &fleet,
                readers: &readers,
                judges: &judges,
                baseline: tick.baseline,
                settings: &ctx.settings.watch,
                succession: ctx.settings.succession,
                preference: ctx
                    .settings
                    .overseer_preference_set
                    .then_some(ctx.settings.overseer_preference.as_str()),
                now: tick.wall,
                transfer: &transfer,
                context_record: Some(&context_record),
                alert: &alert,
            },
            &ctx.slot,
        );
        // Every detached relaunch's outcome, whatever the controller's
        // verdict.
        absorb(
            &mut produced,
            relaunch_outcomes(
                watch_state_dir(&ctx.settings.claim_store),
                &fleet,
                ctx.settings.watch.prepare,
                tick.wall,
                tick.baseline,
            ),
        );
        let watched = ctx.slot.read().is_some_and(|j| match j.verdict {
            Verdict::Live | Verdict::Unwatched { .. } | Verdict::Unreadable { .. } => true,
            Verdict::Exited { .. } | Verdict::Walled { .. } | Verdict::Transferring { .. } => false,
        });
        if watched {
            let own: Vec<String> = ctx.own_pane.iter().cloned().collect();
            let wall_pick = |harness: Harness, model: &str, spent: &str| {
                (judges.wall_pick)(&judges.scripts, harness, model, spent)
            };
            let start = |r: &Relaunch| (judges.relaunch)(&ctx.settings.job_unit, r);
            let route = WallRoute {
                relaunch: ctx.settings.watch.wall_relaunch,
                pick: &wall_pick,
                start: &start,
            };
            let wall_pauses = |request| {
                let request = crate::ops::Request::RecordWallPauses(request);
                crate::ops::apply(&ctx.path, &request, &env, ctx.locking)
                    .map(|_| ())
                    .map_err(|e| e.to_string())
            };
            // The hosted arms' reads: `gh` as the GitHub duty names it, the
            // account roster for a draft pull request's credit, and the
            // connected repositories for a record naming no repository of
            // its own.
            let gh = std::path::PathBuf::from("gh");
            let roster = || accounts::roster(&ctx.settings, None, tick.wall);
            let hosted_reads = super::hosted::Reads {
                gh: &gh,
                roster: &roster,
                repos: &ctx.settings.reads.connected_repos,
            };
            let copilot_home = super::lanes::copilot_home(&ctx.settings.accounts);
            let lanes = super::lanes::observe(&super::lanes::Pass {
                fleet: &fleet,
                readers: &readers,
                baseline: tick.baseline,
                settings: &ctx.settings.watch,
                now: tick.wall,
                session: ctx.settings.tmux_session.as_deref(),
                own_panes: &own,
                state_dir: &ctx.settings.state_dir,
                claim_store: &ctx.settings.claim_store,
                scripts: &judges.scripts,
                route: &route,
                wall_pauses: &wall_pauses,
                hosted: &hosted_reads,
                copilot_home: copilot_home.as_deref(),
            });
            absorb(&mut produced, lanes);
        }
        Ok(produced)
    })
}

/// Fold a later reading's lines, rows and failure into the pass's; the
/// first failure stands.
fn absorb(into: &mut Produced, from: Produced) {
    into.events.extend(from.events);
    into.changes.extend(from.changes);
    if let Some(failed) = from.failed {
        into.failed.get_or_insert(failed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Room is never read past the token cap, at the window share itself,
    /// under a share the ceiling forbids, or for a reading with no window.
    #[test]
    fn the_context_marks_are_the_token_cap_and_strictly_past_the_window_share() {
        assert_eq!(handoff_due(400_000, None, 90), Some(true));
        assert_eq!(handoff_due(399_999, None, 90), None);
        assert_eq!(handoff_due(399_999, Some(0), 90), None);
        assert_eq!(handoff_due(900, Some(1000), 90), Some(false));
        assert_eq!(handoff_due(901, Some(1000), 90), Some(true));
        assert_eq!(handoff_due(901, Some(1000), 100), Some(true));
        assert_eq!(handoff_due(500, Some(1000), 50), Some(false));
        assert_eq!(parse_context("0:"), Some((0, None)));
        assert_eq!(parse_context("12:34"), Some((12, Some(34))));
        assert_eq!(parse_context("012:34"), None);
        assert_eq!(parse_context("12:0"), None);
        assert_eq!(parse_context("12"), None);
    }
}
