//! The controller record as the hand-over and its opener read it: the
//! record's fields ([`Record`]), the session they describe ([`Caller`]), its
//! own account through the judge ([`Caller::own_account`]) and the marks a
//! succession is sent by ([`MarkKind`]).

use std::path::PathBuf;

use serde::Serialize;
use serde_json::Value;

use super::transition::OverseerExpected;
use super::{Overseer, Pending};
use crate::accounts::walk;
use crate::accounts::{PickAnswer, PickRequest};
use crate::harness::Harness;
use crate::launch::Permission;
use crate::process::Identity;

/// The mark a succession is sent by.
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
    pub fn walk_entry(&self, harness: Harness) -> walk::Caller {
        walk::Caller {
            harness,
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
    pub fn own_account(
        &self,
        harness: Harness,
        pick: &mut dyn FnMut(&PickRequest) -> PickAnswer,
        trigger: u32,
        now: u64,
    ) -> AccountRead {
        match self.account.as_deref() {
            Some(account) => {
                let answer = pick(&PickRequest {
                    model: self.mark_model(),
                    lane: Some(account.to_owned()),
                    for_overseer: true,
                    min_headroom_pct: Some(trigger),
                    ..PickRequest::new(harness)
                });
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
    pub fn account_departure(
        &self,
        harness: Harness,
        wall_minutes: u32,
        trigger: u32,
        pick: &mut dyn FnMut(&PickRequest) -> PickAnswer,
        now: u64,
    ) -> (AccountState, Option<MarkKind>) {
        let read = self.own_account(harness, pick, trigger, now);
        let reached = read.reached(wall_minutes);
        (read.state, reached)
    }

    /// The pending the walk's choice opens: its harness, account, model,
    /// effort and class, in this session's directory; a same-harness entry
    /// keeps this session's posture and words, another harness runs the
    /// full bypass the walk admitted with none of them. The launch prepares
    /// the home its harness and account run under; the one home named is
    /// this session's own root, kept by a same-harness successor whose
    /// account is not its home (a Pi seat). An account the walk admitted
    /// with its model's window unread carries `scope: unread` to the launch.
    pub fn successor_of(&self, chosen: &walk::Chosen) -> Pending {
        let same = self.harness == Some(chosen.harness);
        Pending {
            harness: Some(chosen.harness.name().to_owned()),
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
            extra: chosen
                .record
                .as_ref()
                .and_then(|r| r.get("scope"))
                .filter(|scope| scope.as_str() == Some("unread"))
                .map(|scope| serde_json::Map::from_iter([("scope".to_owned(), scope.clone())]))
                .unwrap_or_default(),
        }
    }
}

/// The state of a session's own account as the judge read it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AccountState {
    HasRoom,
    AtTrigger,
    Unmeasured,
    Unreadable,
}

/// A session's own account as the judge read it at the trigger.
pub struct AccountRead {
    pub state: AccountState,
    pub headroom: Option<u32>,
    pub account: String,
    pub resets: String,
    pub ended: bool,
    pub reserve_only: bool,
    pub rate_state: String,
    /// The minutes to the wall at the measured rate, counted from the
    /// sample's instant.
    pub projected: Option<u64>,
}

impl AccountRead {
    /// The account mark this reading reaches: the headroom trigger, else a
    /// wall the measured rate projects inside the setting. Headroom leads,
    /// since it names the account to leave.
    pub fn reached(&self, wall_minutes: u32) -> Option<MarkKind> {
        if self.state == AccountState::AtTrigger {
            return Some(MarkKind::Headroom);
        }
        (wall_minutes > 0
            && self.rate_state == "measured"
            && self
                .projected
                .is_some_and(|projected| projected <= u64::from(wall_minutes)))
        .then_some(MarkKind::Rate)
    }

    pub fn headroom_field(&self) -> String {
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
    judged: &crate::accounts::Judged,
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
        reserve_only: at_trigger && crate::accounts::credit_room(&judged.row, 0.0),
        rate_state: record_text(&record, "usage_rate_state"),
        projected,
    }
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

/// A member's number, a numeric string read as one.
pub fn number(value: Option<&Value>) -> Option<u64> {
    match value? {
        Value::Number(n) => n.as_u64(),
        Value::String(s) => s.parse().ok(),
        Value::Null | Value::Bool(_) | Value::Array(_) | Value::Object(_) => None,
    }
}

/// A member's text, a number spelled as one.
pub fn text(value: Option<&Value>) -> Option<String> {
    match value? {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        Value::Null | Value::Bool(_) | Value::Array(_) | Value::Object(_) => None,
    }
}

impl Record {
    /// The record as the controller member holds it; `None` where it names
    /// no server or pane.
    pub fn read(overseer: Option<&Overseer>) -> Option<Record> {
        let overseer = overseer?;
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

    pub fn pane_key(&self) -> String {
        format!("{} {}", self.server, self.pane)
    }

    /// The successor a dead session's recovery replays: the pending the
    /// fleet last chose, else this record's own launch fields, a fresh
    /// session in the same place on the home its launch prepares, its own
    /// root kept where its account is not its home. The dead session's
    /// handoff is what its successor reads, so no held successor resumes the
    /// dead session.
    pub fn held_successor(&self) -> Option<Pending> {
        if let Some(pending) = &self.pending {
            return Some(pending.clone());
        }
        self.own_successor()
    }

    /// This record's own launch fields as a fresh session's: the same
    /// harness, account, model, effort, directory, posture and handoff, on
    /// the home its launch prepares.
    pub fn own_successor(&self) -> Option<Pending> {
        let caller = Caller::of(self);
        let harness = caller.harness?;
        Some(Pending {
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

    /// The compare-and-swap set the request carries: the record as read.
    pub fn expected(&self) -> OverseerExpected {
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
