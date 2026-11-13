//! A Claude session's model switch, judged at `PostModelSwitch`: the model
//! its launch recorded against the one the event names, through the one
//! Claude model-id rule. A switch, or a model that cannot be read, is
//! recorded once per launch where the record still runs that launch; an
//! unavailable model is handed to the session once per session. The
//! controller's acquired switch is marked started before its recovery, then
//! recovered on its own launch's model: the successor, the handoff snapshot
//! and the transfer's job. A fleet lane's acquired switch writes the handoff
//! its replacement resumes from and starts its recovery in process. A
//! hosted lane, which no fleet record names, is judged only where its turn
//! end is its recorded process group's: the check, the start mark and the
//! handoff on its item record, then its predecessor stop's job.

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::Output;
use std::rc::Rc;
use std::time::Duration;

use agent_runtime::controller::model::{self as rule, Check, Place};
use agent_runtime::controller::{self, MEMBER};
use agent_runtime::harness::{self, ModelWord, claude_model_id};
use agent_runtime::host::{self, tmux};
use agent_runtime::journal::Env;
use agent_runtime::record::{self, Locking};
use serde_json::{Value, json};

use super::agents;
use super::answer::{self, Harness, Hosted, Recovered, Said};
use super::identity::Lane;
use super::marks;
use super::payload::Payload;
use super::role::{Binding, Kind};
use super::{Answer, Flow, Turn, Vars};
use crate::marker;
use crate::ops::lane_model::{RecoverLaneModel, StopModelPredecessor};
use crate::ops::store::{self, ModelCheck, Write};
use crate::ops::successor;
use crate::ops::{self, Request};
use crate::protocol::Reply;
use crate::settings::Settings;
use crate::state;

/// The event a model switch's context answer is handed under.
const EVENT: &str = "PostModelSwitch";

/// The item key the fleet record's own slots are kept under.
const FLEET_ITEM: &str = "oversee";

/// How long past the transfer's own job bound its verb is given to answer.
const TRANSFER_MARGIN: std::time::Duration = std::time::Duration::from_secs(30);

/// What the account read is given: a read inside a token renewal or a
/// provider's answer can outlast the turn end, and a turn end its harness
/// kills tells nothing, so the read is killed at this ceiling and told.
const ACCOUNT_CEILING: Duration = Duration::from_secs(20);

/// Whose switch it is: a launched lane's, by its item, or the controller
/// the fleet record binds this session as.
enum Seat {
    Lane(String),
    Controller,
}

/// How a lane's recorded launch stands to the session that switched: the
/// launch it runs, another one, or one this session cannot be bound to.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Association {
    Current,
    Stale,
    Unbound,
}

/// One switch's judgement: its settings, the item its once-only notice
/// slot is kept for, and the session and model the event names.
struct Switch<'a> {
    settings: Settings,
    root: &'a Path,
    item: String,
    session: &'a str,
    observed: &'a str,
    /// Whether the switch's own settings read the private env file, which
    /// a program it starts of this binary reads alike.
    private_env: bool,
}

/// The switch a lead's `PostModelSwitch` names (a subagent's passed before
/// any place), judged for a Claude session that is a launched lane or the
/// bound controller; any other session passes silently.
pub(super) fn switch(turn: &mut Turn, vars: &Vars, lane: &Lane, payload: &Payload) -> Flow {
    if turn.harness != Harness::Claude {
        return Ok(());
    }
    let role = Rc::clone(&turn.role);
    let seat = match (&lane.item, &role.kind, &role.binding) {
        (Some(item), _, _) => {
            if !lane.launched(turn)? {
                return Ok(());
            }
            Seat::Lane(item.clone())
        }
        (None, Kind::Overseer, Binding::Bound(_)) => Seat::Controller,
        (None, _, _) => return Ok(()),
    };
    let settings = match marks::marks_settings(&lane.root, vars.private_env) {
        Ok(settings) => settings,
        Err(cause) => {
            return Err(handed(
                turn,
                &Said::ModelUnavailable("state-unread"),
                &cause,
            ));
        }
    };
    let item = match &seat {
        Seat::Lane(item) => item.clone(),
        Seat::Controller => FLEET_ITEM.to_owned(),
    };
    let judged = Switch {
        settings,
        root: &lane.root,
        item,
        session: &payload.session,
        observed: &payload.observed,
        private_env: vars.private_env,
    };
    judged.judge(turn, vars, lane, payload, &seat)
}

/// A replacement's first Stop: a native resume keeps the session id, so no
/// switch tells the replacement from its predecessor, and the lane's
/// switched check whose recovery started under an earlier launch is reset
/// once this session runs the launch the record now names. A failure is a
/// note; the turn's own judgement goes on.
pub(super) fn reset(turn: &mut Turn, vars: &Vars, lane: &Lane, payload: &Payload) {
    let Some(item) = &lane.item else {
        return;
    };
    if turn.harness != Harness::Claude || matches!(turn.role.kind, Kind::Overseer) {
        return;
    }
    if let Err((cause, detail)) = reset_lane(vars, lane, item, &payload.session) {
        turn.note(&Said::ModelUnavailable(cause), &detail);
    }
}

/// The reset's reads and its one write, the cause and the words of the
/// step that failed where one did.
fn reset_lane(
    vars: &Vars,
    lane: &Lane,
    item: &str,
    session: &str,
) -> Result<(), (&'static str, String)> {
    let settings = marks::marks_settings(&lane.root, vars.private_env)
        .map_err(|e| ("reset-state-unread", e))?;
    let fleet = record::fleet_path(&settings.state_dir);
    if std::fs::symlink_metadata(&fleet).is_err() {
        return Ok(());
    }
    let doc = store::read(&fleet).map_err(|e| ("reset-launch-unread", e.to_string()))?;
    let Some(entry) = awaiting_reset(&doc, item) else {
        return Ok(());
    };
    let server = match vars.tmux_pane {
        None => String::new(),
        Some(_) => caller_server(vars).ok_or(("reset-launch-unbound", String::new()))?,
    };
    if association(&entry, session, vars.tmux_pane.as_deref(), &server) != Association::Current {
        return Ok(());
    }
    let unwritten = |e: &dyn std::fmt::Display| ("reset-record-unwritten", e.to_string());
    let expected = Scratch::create(&settings.state_dir, "model-expected", &entry.to_string())
        .map_err(|e| unwritten(&e))?;
    let env = Env::system().map_err(|e| unwritten(&e))?;
    let write = Write::ModelReset {
        lane: item.to_owned(),
        session: session.to_owned(),
        expected: expected.0.clone(),
    };
    store::run_write(&fleet, Locking::FLOCK, &settings.store, &env, &write)
        .map_err(|e| unwritten(&e))?;
    Ok(())
}

/// The lane `item`'s first record whose switched check had its recovery
/// started under a launch other than the one the record now names.
fn awaiting_reset(doc: &serde_json::Map<String, Value>, item: &str) -> Option<Value> {
    let place = Place::Lane(item.to_owned());
    doc.get("lanes")?
        .as_array()?
        .iter()
        .find(|l| {
            let check = &l["model_check"];
            l.get("item").and_then(Value::as_str) == Some(item)
                && check["outcome"] == "switched"
                && check["recovery_started"] == true
                && check["launch_identity"] != rule::launch_of(&place, l)
        })
        .cloned()
}

/// A launched lane's account mark at its turn end, once its context mark
/// held nothing: the account its credential bills, judged by the one account
/// judge, this binary's `lane pick`, asked as one child under the ceiling. A
/// hosted lane's account is the controller's to measure. An account at its
/// mark is refused with the handoff; every other answer but room is told and
/// passed, never read as room.
pub(super) fn account_mark(
    turn: &mut Turn,
    judge: &marks::Judge<'_>,
    lane: &Lane,
    vars: &Vars,
    model: &str,
) -> Flow {
    if matches!(turn.harness, Harness::Claude | Harness::Pi) {
        match hosted(lane, turn.harness, model) {
            Ok(None) => {}
            Ok(Some(hosted)) => {
                turn.note(&Said::HostMeasured(hosted), "");
                return Ok(());
            }
            Err(cause) => {
                turn.note(&Said::Account("unmeasured"), &cause);
                return Ok(());
            }
        }
    }
    let (account, native_model) = match turn.harness {
        Harness::Claude => (
            caller_account(harness::Harness::Claude, vars),
            Some(model).filter(|m| !m.is_empty()),
        ),
        Harness::Codex => {
            let home = caller_account(harness::Harness::Codex, vars);
            (agent_runtime::trust::account_of(&home).to_path_buf(), None)
        }
        Harness::Copilot => (caller_account(harness::Harness::Copilot, vars), None),
        Harness::Pi => match pi_billed(model) {
            Ok(billed) => (caller_account(billed, vars), Some(model)),
            Err(cause) => {
                turn.note(&Said::Account("unmeasured"), &cause);
                return Ok(());
            }
        },
        Harness::Unlisted => {
            let cause = format!(
                "{} is no harness lanes keeps an inventory for",
                turn.hook_dir.display()
            );
            turn.note(&Said::Account("unlisted"), &cause);
            return Ok(());
        }
    };
    let mark = match &judge.settings.marks.headroom_pct.read {
        Ok(pct) => *pct,
        Err((key, value)) => {
            let instruction = judge.instruction(turn, Value::Null, None)?;
            let said = Said::SettingRange {
                value: format!("{key}={value}"),
                instruction,
            };
            return Err(turn.refuse(said, ""));
        }
    };
    let word = marks::harness_word(turn.harness);
    match told(pick(lane, vars, word, &account, native_model, mark)) {
        Told::Room => Ok(()),
        Told::Headroom { headroom, bucket } => {
            let instruction = judge.instruction(turn, Value::Null, None)?;
            let said = Said::Headroom {
                headroom,
                bucket,
                mark,
                instruction,
            };
            Err(turn.refuse(said, ""))
        }
        Told::SeatReserve {
            headroom,
            bucket,
            need,
        } => {
            let instruction = judge.instruction(turn, Value::Null, None)?;
            let said = Said::SeatReserve {
                headroom,
                bucket,
                need,
                instruction,
            };
            Err(turn.refuse(said, ""))
        }
        Told::Gap(word, cause) => {
            turn.note(&Said::Account(word), &cause);
            Ok(())
        }
    }
}

/// What a hosted lane's account is, where `lane`'s launch record names the
/// native identity file a hosted provider records; `None` for a local lane,
/// and the cause where the record stands and cannot be read.
fn hosted(lane: &Lane, harness: Harness, model: &str) -> Result<Option<Hosted>, String> {
    let Some(record) = launch_record(lane)? else {
        return Ok(None);
    };
    if identity_file(&record).is_none() {
        return Ok(None);
    }
    Ok(Some(match harness {
        Harness::Pi if model.starts_with("anthropic/") => Hosted::PiGrant,
        Harness::Pi => Hosted::Pi,
        Harness::Claude | Harness::Codex | Harness::Copilot | Harness::Unlisted => Hosted::Claude,
    }))
}

/// The lane's launch record where one stands as a regular file, not a
/// link; `None` for a lane with no launch directory or none for its item,
/// and the cause, naming the record, where it stands and cannot be read.
fn launch_record(lane: &Lane) -> Result<Option<serde_json::Map<String, Value>>, String> {
    let (Some(common), Some(item)) = (&lane.common, &lane.item) else {
        return Ok(None);
    };
    let item = marker::item_name(item).map_err(|e| e.to_string())?;
    let path = marker::launch_path(common, item);
    if !std::fs::symlink_metadata(&path).is_ok_and(|meta| meta.is_file()) {
        return Ok(None);
    }
    let unread = |cause: &dyn std::fmt::Display| format!("{}: {cause}", path.display());
    let text = std::fs::read_to_string(&path).map_err(|e| unread(&e))?;
    let record: Value = serde_json::from_str(&text).map_err(|e| unread(&e))?;
    let Value::Object(record) = record else {
        return Err(unread(&"no launch record object"));
    };
    Ok(Some(record))
}

/// The absolute identity file a launch record names: the process group a
/// hosted provider's launch recorded, which makes the lane a hosted one.
fn identity_file(record: &serde_json::Map<String, Value>) -> Option<&str> {
    record
        .get("identity_file")
        .and_then(Value::as_str)
        .filter(|file| file.starts_with('/'))
}

/// A hosted lane's switch as its member read found it: the launch record
/// with the session and the leader's launch, the item record the switch is
/// kept on, the handoff standing there, the group record and its leader.
struct Hosting {
    entry: Value,
    record: PathBuf,
    prior: Option<Value>,
    file: PathBuf,
    leader: agent_runtime::process::Identity,
}

/// The account a Pi lane spends, by the provider its model names; the cause
/// where no reading named a model or nothing measures its provider.
fn pi_billed(model: &str) -> Result<harness::Harness, String> {
    if model.is_empty() {
        return Err("no reading of this Pi session's transcript named its model, so the provider whose account it spends is unknown".to_owned());
    }
    harness::Harness::Pi
        .billed(model)
        .ok_or_else(|| format!("the provider of {model} bills no account lanes measures"))
}

/// The account directory a session of `harness` runs its credential out
/// of: its home variable, else the harness's own directory under the home.
fn caller_account(harness: harness::Harness, vars: &Vars) -> PathBuf {
    if let Some(dir) = std::env::var_os(harness.home_var()).filter(|d| !d.is_empty()) {
        return PathBuf::from(dir);
    }
    let home = std::env::var_os("LANES_HOME")
        .filter(|h| !h.is_empty())
        .map_or_else(|| PathBuf::from(&vars.home), PathBuf::from);
    match harness {
        harness::Harness::Claude => home.join(".claude"),
        harness::Harness::Codex => home.join(".codex"),
        harness::Harness::Copilot => home.join(".copilot"),
        harness::Harness::Pi => home.join(".pi").join("agent"),
    }
}

/// The judge's answer on `account`, asked of this binary's own `lane pick`
/// as one child in a process group of its own, from the lane's root where
/// its settings and fleet record resolve; the ceiling's end kills the group.
#[allow(
    clippy::disallowed_methods,
    reason = "the account mark's one read, this binary's own pick verb through the one runner, killed with its group at the ceiling"
)]
fn pick(
    lane: &Lane,
    vars: &Vars,
    harness: &str,
    account: &Path,
    model: Option<&str>,
    mark: u32,
) -> agent_runtime::Result<Output> {
    let exe = std::env::current_exe()
        .map_err(|e| agent_runtime::Error::io("exe", PathBuf::from("."), e))?;
    let account = account.display().to_string();
    let mark = mark.to_string();
    let mut args = Vec::new();
    if !vars.private_env {
        args.push("--no-private-env");
    }
    args.extend([
        "lane",
        "pick",
        "--fleet",
        "--lane",
        &account,
        "--harness",
        harness,
    ]);
    if let Some(model) = model {
        args.extend(["--native-model", model]);
    }
    args.extend(["--min-headroom-pct", &mark]);
    let place = host::Place {
        cwd: Some(&lane.root),
        env: &[],
    };
    host::run_tagged_in_own_group(
        "account-mark",
        "orch-runtime",
        &exe,
        "lane pick",
        &args,
        place,
        ACCOUNT_CEILING,
    )
}

/// What the account mark tells.
#[derive(Debug, PartialEq, Eq)]
enum Told {
    Room,
    /// At the headroom mark: the binding bucket's headroom and the bucket.
    Headroom {
        headroom: String,
        bucket: String,
    },
    /// An overseer's seat at the room it keeps, `need`.
    SeatReserve {
        headroom: String,
        bucket: String,
        need: String,
    },
    /// Unjudged: the account line's word and the words the read left.
    Gap(&'static str, String),
}

/// The pick's run read as the mark's answer. The verb answers every
/// judgement at status 0, the judge's exit inside its reply: 0 room; 3 a
/// mark reached, or the owner's word refusing the account; 4 no account
/// of the inventory; 7 a cloud account no repository rule gives this
/// checkout. A run killed at the ceiling is a timeout; any other status,
/// exit or reply nobody can read is an account nothing measured.
fn told(read: agent_runtime::Result<Output>) -> Told {
    let out = match read {
        Ok(out) => out,
        Err(agent_runtime::Error::External { .. }) => {
            let cause = format!(
                "the read was abandoned after {} seconds",
                ACCOUNT_CEILING.as_secs()
            );
            return Told::Gap("timeout", cause);
        }
        Err(e) => return Told::Gap("unmeasured", e.to_string()),
    };
    let stderr = host::stderr_text(&out);
    if !out.status.success() {
        return Told::Gap("unmeasured", stderr);
    }
    let result = serde_json::from_slice::<Reply<Value>>(&out.stdout)
        .ok()
        .and_then(|reply| reply.result);
    let Some((exit, record)) = result
        .as_ref()
        .and_then(|r| Some((r["exit"].as_i64()?, &r["record"])))
    else {
        let cause = format!("{stderr}\nthe reply carries no judgement");
        return Told::Gap("unmeasured", cause.trim_start().to_owned());
    };
    let text = |key: &str| match &record[key] {
        Value::Null => "unknown".to_owned(),
        Value::String(text) => text.clone(),
        other => other.to_string(),
    };
    let detail = record["detail"].as_str().unwrap_or_default().to_owned();
    match exit {
        0 => Told::Room,
        3 => {
            let headroom = record["wall"]
                .as_f64()
                .map_or_else(|| "unknown".to_owned(), |wall| figure(100.0 - wall));
            let bucket = text("binding_bucket");
            match record["verdict"].as_str().unwrap_or("walled") {
                "seat-reserve" => Told::SeatReserve {
                    headroom,
                    bucket,
                    need: text("need"),
                },
                "walled" => Told::Headroom { headroom, bucket },
                "excluded" => Told::Gap("excluded", detail),
                "reserved" => Told::Gap("reserved", detail),
                "retired" => Told::Gap("retired", detail),
                _ => Told::Gap(
                    "unmeasured",
                    "the account judge returned an unreadable refusal record".to_owned(),
                ),
            }
        }
        4 => Told::Gap("unlisted", stderr),
        7 => Told::Gap("cloud-repo-unset", detail),
        _ => Told::Gap("unmeasured", stderr),
    }
}

/// A percentage as the judge's record spells its figures: an integral
/// value as an integer.
fn figure(pct: f64) -> String {
    if pct.fract() == 0.0 {
        format!("{pct:.0}")
    } else {
        pct.to_string()
    }
}

impl Switch<'_> {
    fn fleet(&self) -> PathBuf {
        record::fleet_path(&self.settings.state_dir)
    }

    fn judge(
        &self,
        turn: &mut Turn,
        vars: &Vars,
        lane: &Lane,
        payload: &Payload,
        seat: &Seat,
    ) -> Flow {
        let fleet = self.fleet();
        let (entry, place, record, hosting) =
            if matches!(seat, Seat::Lane(_)) && std::fs::symlink_metadata(&fleet).is_err() {
                let Some(hosting) = self.hosting(turn, lane)? else {
                    return Ok(());
                };
                let entry = hosting.entry.clone();
                (entry, Place::Item, hosting.record.clone(), Some(hosting))
            } else {
                let doc = match store::read(&fleet) {
                    Ok(doc) => doc,
                    Err(_) => return self.unavailable(turn, "launch-unread", ""),
                };
                let (entry, place) = match seat {
                    Seat::Lane(item) => {
                        let entry = doc
                            .get("lanes")
                            .and_then(Value::as_array)
                            .and_then(|lanes| {
                                lanes
                                    .iter()
                                    .find(|l| l.get("item").and_then(Value::as_str) == Some(item))
                            })
                            .cloned();
                        (entry, Place::Lane(item.clone()))
                    }
                    Seat::Controller => (
                        doc.get(MEMBER).filter(|m| m.is_object()).cloned(),
                        Place::Controller,
                    ),
                };
                let Some(entry) = entry else {
                    return self.unavailable(turn, "launch-missing", "");
                };
                (entry, place, fleet.clone(), None)
            };
        if let Place::Lane(_) = place {
            let server = match vars.tmux_pane {
                None => String::new(),
                Some(_) => match caller_server(vars) {
                    Some(server) => server,
                    None => return self.unavailable(turn, "launch-unbound", ""),
                },
            };
            match association(&entry, self.session, vars.tmux_pane.as_deref(), &server) {
                Association::Current => {}
                Association::Unbound => return self.unavailable(turn, "launch-unbound", ""),
                Association::Stale => return Ok(()),
            }
        }
        let launched = entry
            .get("model")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let launch_id = claude_model_id(launched, ModelWord::Recorded);
        let observed_id = claude_model_id(self.observed, ModelWord::Observed { launched });
        let cause = match (launched.is_empty(), launch_id, observed_id) {
            (true, _, _) => Some("launch-missing"),
            (false, None, _) => Some("launch-unresolved"),
            (false, Some(_), None) => Some("observed-unread"),
            (false, Some(launch), Some(observed)) if launch == observed => return Ok(()),
            (false, Some(_), Some(_)) => None,
        };
        let check = Check {
            session: self.session.to_owned(),
            outcome: if cause.is_some() {
                "unavailable"
            } else {
                "switched"
            }
            .to_owned(),
            cause: cause.unwrap_or_default().to_owned(),
            launched: launched.to_owned(),
            observed: self.observed.to_owned(),
        };
        let env = match Env::system() {
            Ok(env) => env,
            Err(e) => return self.unavailable(turn, "record-unwritten", &e.to_string()),
        };
        let report = match &place {
            Place::Controller => controller::rewrite(&fleet, Locking::FLOCK, |doc| {
                rule::record_model_check(&fleet, doc, &env.iso(), &place, &check, &entry)
            })
            .map_err(|e| e.to_string()),
            Place::Lane(_) | Place::Item => {
                let Ok(expected) = Scratch::create(
                    &self.settings.state_dir,
                    "model-expected",
                    &entry.to_string(),
                ) else {
                    return self.unavailable(turn, "record-unwritten", "");
                };
                let write = Write::ModelCheck(ModelCheck {
                    place: place.clone(),
                    check: check.clone(),
                    expected: expected.0.clone(),
                });
                store::run_write(&record, Locking::FLOCK, &self.settings.store, &env, &write)
                    .map_err(|e| e.to_string())
            }
        };
        let report = match report {
            Ok(report) => report,
            Err(cause) => return self.unavailable(turn, "record-unwritten", &cause),
        };
        if report["result"].as_str() != Some("acquired") {
            return Ok(());
        }
        if let Some(cause) = cause {
            return Err(handed(turn, &Said::ModelUnavailable(cause), ""));
        }
        match place {
            Place::Controller => self.recover(turn, payload, &entry, &check, &env),
            Place::Lane(item) => {
                self.recover_lane(turn, lane, payload, &item, &entry, &check, &env)
            }
            Place::Item => match hosting {
                Some(hosting) => self.recover_item(turn, lane, payload, hosting, &check, &env),
                None => unreachable!("a check at the item place is a hosted switch's"),
            },
        }
    }

    /// A fleet lane's acquired switch: the handoff its replacement resumes
    /// from, then its recovery started in process, once whatever it answers.
    /// A handoff that cannot be written is told and the recovery still
    /// starts, since the replacement resumes the item's workflow state either
    /// way; a recovery that refuses is told in one form with its key line,
    /// under the handoff's notice where both failed. Each is told once per
    /// session through the item's slot.
    #[allow(
        clippy::too_many_arguments,
        reason = "the switch's own judgement and the turn, lane, payload, check and environment it was taken under"
    )]
    fn recover_lane(
        &self,
        turn: &mut Turn,
        lane: &Lane,
        payload: &Payload,
        item: &str,
        entry: &Value,
        check: &Check,
        env: &Env,
    ) -> Flow {
        let handoff = match self.handoff_place() {
            Ok((path, prior)) => self
                .handoff_request(turn, lane, payload, prior, &check.launched)?
                .and_then(|request| apply_handoff(&path, self.root, &self.settings, &request, env)),
            Err(words) => Err(words),
        };
        let request = RecoverLaneModel {
            item: item.to_owned(),
            session: self.session.to_owned(),
            launch_identity: rule::launch_of(&Place::Lane(item.to_owned()), entry),
            mark: None,
            limit: None,
        };
        let started = crate::effects::lane_model::start(
            &self.settings,
            &self.fleet(),
            &request,
            env,
            Locking::FLOCK,
        );
        let refused = match started {
            Ok(_) => {
                turn.note(&switched(check, Recovered::Lane), "");
                None
            }
            Err(e) => Some(key_line(&e)),
        };
        match (handoff, refused) {
            (Ok(()), None) => Ok(()),
            (Ok(()), Some(line)) => self.unavailable(turn, "recovery-unstarted", &line),
            (Err(words), refused) => {
                if let Some(line) = refused {
                    turn.note(&Said::ModelUnavailable("recovery-unstarted"), &line);
                }
                self.unavailable(turn, "handoff-unwritten", &words)
            }
        }
    }

    /// A lane no fleet record names, read before anything is written: a
    /// hosted lane on its host, whose launch record names the group its
    /// launch recorded, judged only where this turn end is that group's
    /// (`group::reading`'s member rule), with the item record its check,
    /// start mark, handoff and stop are kept on. `None` for a lane whose
    /// launch record names no identity file, which nothing here recovers;
    /// each read that fails is told once through the item's slot.
    fn hosting(&self, turn: &mut Turn, lane: &Lane) -> Flow<Option<Hosting>> {
        let unread = |cause: String| ("launch-unread", cause);
        let read = launch_record(lane).and_then(|record| {
            let Some(record) = record else {
                return Ok(None);
            };
            let Some(file) = identity_file(&record) else {
                return Ok(None);
            };
            let file = PathBuf::from(file);
            if !std::fs::symlink_metadata(&file).is_ok_and(|meta| meta.is_file()) {
                return Err(format!("{}: no regular identity file", file.display()));
            }
            let reading = agent_runtime::group::reading(&file, Some(std::process::id()))
                .map_err(|e| e.to_string())?;
            let leader = match (&reading["reading"], &reading["member"]) {
                (Value::String(live), Value::Bool(true)) if live == "live" => {
                    serde_json::from_value::<agent_runtime::process::Identity>(reading.clone())
                        .map_err(|e| e.to_string())?
                }
                _ => {
                    return Err(format!(
                        "{}: this turn end is no member of the recorded group: {reading}",
                        file.display()
                    ));
                }
            };
            Ok(Some((record, file, leader)))
        });
        let (record, file, leader) = match read.map_err(unread) {
            Ok(Some(read)) => read,
            Ok(None) => return Ok(None),
            Err((cause, words)) => return self.unavailable(turn, cause, &words).map(|()| None),
        };
        if self.session.is_empty() {
            return self.unavailable(turn, "launch-unbound", "").map(|()| None);
        }
        let place = self.handoff_place().and_then(|(path, prior)| {
            item_record(&path, self.root).map_err(|e| e.to_string())?;
            Ok((path, prior))
        });
        let (path, prior) = match place {
            Ok(place) => place,
            Err(words) => {
                return self
                    .unavailable(turn, "state-unread", &words)
                    .map(|()| None);
            }
        };
        let mut entry = record;
        entry.insert("session_id".to_owned(), json!(self.session));
        entry.insert(
            "launch".to_owned(),
            json!({"pid": leader.pid.to_string(), "start": leader.start}),
        );
        Ok(Some(Hosting {
            entry: Value::Object(entry),
            record: path,
            prior,
            file,
            leader,
        }))
    }

    /// A hosted lane's acquired switch, after its check on the item record:
    /// the start mark, so a lost answer is acquired again and a started
    /// recovery is not; the handoff the controller relaunches from; then the
    /// stop of the predecessor's group by its own job, whose TERM can reach
    /// this turn end before it tells the switch. The acquired check holds the
    /// item's once-only slot, so each failure is handed directly, and nothing
    /// stops where the mark or the handoff was not written.
    fn recover_item(
        &self,
        turn: &mut Turn,
        lane: &Lane,
        payload: &Payload,
        hosting: Hosting,
        check: &Check,
        env: &Env,
    ) -> Flow {
        let unavailable = |turn: &mut Turn, cause: &'static str, words: &str| {
            Err(handed(turn, &Said::ModelUnavailable(cause), words))
        };
        let mark = Write::ModelStart {
            place: Place::Item,
            session: self.session.to_owned(),
        };
        let path = &hosting.record;
        if let Err(e) = store::run_write(path, Locking::FLOCK, &self.settings.store, env, &mark) {
            return unavailable(turn, "recovery-unstarted", &e.to_string());
        }
        let written = self
            .handoff_request(turn, lane, payload, hosting.prior, &check.launched)?
            .and_then(|request| apply_handoff(path, self.root, &self.settings, &request, env));
        if let Err(words) = written {
            return unavailable(turn, "handoff-unwritten", &words);
        }
        let request = StopModelPredecessor {
            session: self.session.to_owned(),
            launch_identity: rule::launch_of(&Place::Item, &hosting.entry),
            file: hosting.file,
            leader: hosting.leader,
            job: false,
            failure: None,
        };
        match crate::effects::lane_model::stop_predecessor(&self.settings, path, &request, env) {
            Ok(_) => {
                turn.note(&switched(check, Recovered::Hosted), "");
                Ok(())
            }
            Err(e) => unavailable(turn, "recovery-unstarted", &key_line(&e)),
        }
    }

    /// The item record a lane's handoff is kept on and the record standing
    /// there: the place the item's standing handoff is read from, else the
    /// state directory's own record with none.
    fn handoff_place(&self) -> Result<(PathBuf, Option<Value>), String> {
        let standing =
            store::handoff_standing(&self.settings.state_dir, &self.item, Some(self.root))
                .map_err(|e| e.to_string())?;
        Ok(
            match (standing["standing"].as_str(), standing["file"].as_str()) {
                (Some("stands"), Some(file)) => {
                    (PathBuf::from(file), Some(standing["record"].clone()))
                }
                _ => (state::item_path(&self.settings.state_dir, &self.item), None),
            },
        )
    }

    /// The `record-handoff` a recovered lane resumes from, superseding the
    /// standing record `prior`: its work, or the default a model recovery
    /// resumes from on the lane's branch and checkout; the attached agents'
    /// rows among its traps; no stop failure or resume stamp of an earlier
    /// life; and the session, caller key, cause and launched model the
    /// relaunch reads. A branch git cannot read stalls the turn before
    /// anything is written, so the next switch is acquired again.
    fn handoff_request(
        &self,
        turn: &mut Turn,
        lane: &Lane,
        payload: &Payload,
        prior: Option<Value>,
        launched: &str,
    ) -> Flow<Result<Request, String>> {
        let mut record = match prior {
            Some(Value::Object(prior)) => prior,
            _ => {
                let branch = lane.branch(turn)?;
                let mut fresh = serde_json::Map::new();
                fresh.insert("merged".to_owned(), json!([]));
                fresh.insert(
                    "remaining".to_owned(),
                    json!(["Resume durable workflow state after model recovery."]),
                );
                fresh.insert("branch".to_owned(), json!(branch));
                fresh.insert(
                    "worktree".to_owned(),
                    json!(self.root.display().to_string()),
                );
                fresh.insert("open_pr".to_owned(), Value::Null);
                fresh
            }
        };
        let mut traps: Vec<Value> = record
            .get("traps")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        traps.push(json!(agents::claude_roster(payload, &turn.deadline).rows));
        traps.sort_by_key(Value::to_string);
        traps.dedup();
        record.insert("traps".to_owned(), Value::Array(traps));
        record.remove("stop_failure");
        record.remove("resumed_at");
        let key = turn.role.key.as_ref().map(super::controller::caller_key);
        for (field, value) in [
            ("session_id", json!(self.session)),
            ("pane_key", json!(key.unwrap_or_default())),
            ("cause", json!("model-switched")),
            ("model", json!(launched)),
            ("op", json!("record-handoff")),
            ("supersede", json!(true)),
        ] {
            record.insert(field.to_owned(), value);
        }
        Ok(serde_json::from_value(Value::Object(record)).map_err(|e| e.to_string()))
    }

    /// The controller's recovery, marked started before it starts, so a
    /// check whose answer was lost is acquired again on the next switch
    /// and one whose recovery began is not: the successor on its own
    /// launch's model, the handoff snapshot it is admitted on with the
    /// installed one kept ahead of this body, and the transfer, whose
    /// detached job retires this session once the successor stands.
    fn recover(
        &self,
        turn: &mut Turn,
        payload: &Payload,
        entry: &Value,
        check: &Check,
        env: &Env,
    ) -> Flow {
        let fleet = self.fleet();
        let started = controller::rewrite(&fleet, Locking::FLOCK, |doc| {
            rule::start_model_recovery(&fleet, doc, &Place::Controller, self.session)
        });
        if let Err(e) = started {
            return self.unavailable(turn, "recovery-unstarted", &e.to_string());
        }
        let pane = entry
            .get("pane")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let answer = match successor::recovery(&self.settings, &fleet, pane) {
            Ok(answer) => answer,
            Err(e) => return self.unavailable(turn, "recovery-unstarted", &e.to_string()),
        };
        let Some(snapshot) = answer["successor"]["handoff"].as_str() else {
            let cause = "the successor names no handoff";
            return self.unavailable(turn, "recovery-unstarted", cause);
        };
        let roster = agents::claude_roster(payload, &turn.deadline);
        let text = format!(
            "Resume the durable fleet state at {}. The predecessor changed from {} to {}. Read pending agent outputs and lane mail before repeating work.\n{}\n",
            fleet.display(),
            check.launched,
            check.observed,
            roster.rows
        );
        let dir = &self.settings.state_dir;
        let Ok(body) = Scratch::create(dir, "model-handoff", &text) else {
            return self.unavailable(turn, "handoff-unwritten", "");
        };
        let snapshot = self.root.join(snapshot);
        let written =
            successor::write_handoff(&self.settings, &fleet, &body.0, &snapshot, true, env);
        drop(body);
        if let Err(e) = written {
            return self.unavailable(turn, "handoff-unwritten", &e.to_string());
        }
        let request = json!({
            "op": "request-transfer",
            "cause": "live",
            "successor": answer["successor"],
            "expected": answer["expected"],
            "recovery": answer["recovery"],
        });
        let Ok(request) = Scratch::create(dir, "model-recovery", &request.to_string()) else {
            return self.unavailable(turn, "recovery-unstarted", "");
        };
        match self.transfer(&request.0) {
            Transferred::Confirmed => {
                turn.note(&switched(check, Recovered::Controller), "");
                Ok(())
            }
            Transferred::Failed(note) => self.unavailable(turn, "recovery-failed", &note),
            Transferred::Unconfirmed(words) => {
                self.unavailable(turn, "recovery-unconfirmed", &words)
            }
            Transferred::Unstarted(words) => self.unavailable(turn, "recovery-unstarted", &words),
        }
    }

    /// The fleet's `request-transfer` on the request file through this
    /// binary's own `op --fleet --effect-exit`, from the root under the
    /// switch's state directory, so the overseer's takeover brief and session
    /// are added and the hand-over runs as the command runs it; exiting by
    /// the effect's outcome, in a process group of its own so a signal that
    /// ends this turn end leaves the transfer to finish: 0 confirmed or the
    /// successor up and waiting for this session to end; 3 failed and
    /// closed, this session still the controller; 75, a refusal naming its
    /// persisted intent, or no answer within the bound, open with the
    /// outcome unknown, the intent's reconcile its owner; any other refusal
    /// started nothing.
    #[allow(
        clippy::disallowed_methods,
        reason = "the model recovery's one transfer, this binary's own fleet entry through the one runner, since the hand-over's run takes settings only orch's effect module builds"
    )]
    fn transfer(&self, request: &Path) -> Transferred {
        let bound = match controller::run::job_bound(&self.settings.engine) {
            Ok(bound) => bound + TRANSFER_MARGIN,
            Err(e) => return Transferred::Unstarted(e.to_string()),
        };
        let exe = match std::env::current_exe() {
            Ok(exe) => exe,
            Err(e) => return Transferred::Unstarted(e.to_string()),
        };
        let state_dir = self.settings.state_dir.display().to_string();
        let request = request.display().to_string();
        let mut args = Vec::new();
        if !self.private_env {
            args.push("--no-private-env");
        }
        args.extend([
            "--state-dir",
            &state_dir,
            "op",
            "--fleet",
            "--effect-exit",
            "--request",
            &request,
        ]);
        let place = host::Place {
            cwd: Some(self.root),
            env: &[],
        };
        let output = match host::run_tagged_in_own_group(
            "model-switch",
            "orch-runtime",
            &exe,
            "request-transfer",
            &args,
            place,
            bound,
        ) {
            Ok(output) => output,
            Err(e) => return Transferred::Unconfirmed(e.to_string()),
        };
        let stdout = String::from_utf8_lossy(&output.stdout);
        let words = format!("{}{}", host::stderr_text(&output), stdout.trim_end());
        match output.status.code() {
            Some(0) => Transferred::Confirmed,
            Some(3) => {
                let reply: Value = serde_json::from_str(stdout.trim_end()).unwrap_or(Value::Null);
                let note = reply["result"]["settled"]["observation"]["note"]
                    .as_str()
                    .unwrap_or_default();
                Transferred::Failed(note.to_owned())
            }
            Some(75) => Transferred::Unconfirmed(words),
            Some(_) if words.contains("persisted_intent") => Transferred::Unconfirmed(words),
            Some(_) | None => Transferred::Unstarted(words),
        }
    }

    /// The once-only notice of an unavailable model: handed to the session
    /// where the item's slot for this session takes it, nothing where the
    /// slot already holds a check of the session, and handed with the
    /// store's words where the slot cannot be reached.
    fn unavailable(&self, turn: &mut Turn, cause: &'static str, detail: &str) -> Flow {
        let said = Said::ModelUnavailable(cause);
        let path = state::item_path(&self.settings.state_dir, &self.item);
        let slot = item_record(&path, self.root).and_then(|()| {
            let env = Env::system().map_err(crate::Error::from)?;
            let write = Write::ModelSlot {
                session: self.session.to_owned(),
                cause: cause.to_owned(),
                observed: self.observed.to_owned(),
            };
            store::run_write(&path, Locking::FLOCK, &self.settings.store, &env, &write)
        });
        match slot {
            Ok(report) if report["recorded"] == json!(true) => Err(handed(turn, &said, detail)),
            Ok(_) => Ok(()),
            Err(e) => {
                let words = [detail, &e.to_string()]
                    .iter()
                    .filter(|w| !w.is_empty())
                    .copied()
                    .collect::<Vec<_>>()
                    .join("\n");
                Err(handed(turn, &said, &words))
            }
        }
    }
}

/// What the transfer's verb answered.
enum Transferred {
    Confirmed,
    Failed(String),
    Unconfirmed(String),
    Unstarted(String),
}

/// The switch `check` names, told as recovering by `recovered`.
fn switched(check: &Check, recovered: Recovered) -> Said {
    Said::ModelSwitched {
        launched: check.launched.clone(),
        observed: check.observed.clone(),
        recovered,
    }
}

/// The keyed line of a refusal, as the runtime's diagnostic writes it,
/// without the program's prefix.
fn key_line(e: &crate::Error) -> String {
    let line = crate::protocol::diagnostic_line(e);
    line.strip_prefix("orch-runtime: ")
        .unwrap_or(&line)
        .to_owned()
}

/// One `record-handoff` admitted and applied to the item record at `path`,
/// made first where a launch predates it; `Err` is the step's words.
#[allow(
    clippy::disallowed_methods,
    reason = "a switch's handoff: the one `record-handoff` the command's `op --item` applies, admitted and applied as the command applies it"
)]
fn apply_handoff(
    path: &Path,
    root: &Path,
    settings: &Settings,
    request: &Request,
    env: &Env,
) -> Result<(), String> {
    item_record(path, root).map_err(|e| e.to_string())?;
    ops::admit(request, settings).map_err(|e| e.to_string())?;
    ops::apply(path, request, env, Locking::FLOCK)
        .map(drop)
        .map_err(|e| e.to_string())
}

/// The item's record made where a launch predates it, through the store's
/// one creation; one already standing is the record.
#[allow(
    clippy::disallowed_methods,
    reason = "the notice slot's item record where a launch predates it: the same creation the `state init` command makes, so the slot is kept in a record of the item's own"
)]
fn item_record(path: &Path, root: &Path) -> crate::Result<()> {
    if std::fs::symlink_metadata(path).is_ok() {
        return Ok(());
    }
    let fields = state::InitFields {
        agent: String::new(),
        worktree: root.display().to_string(),
        branch: String::new(),
        qa_labels: None,
        sub_issues: None,
    };
    match state::init(path, &fields) {
        Ok(_) => Ok(()),
        Err(e) if e.key() == "state-exists" => Ok(()),
        Err(e) => Err(e),
    }
}

/// The pid of the server `$TMUX`'s socket names, which a lane's launch
/// records beside its pane; `None` where it cannot be read.
#[allow(
    clippy::disallowed_methods,
    reason = "the switch's one read of the caller's own server: the pid a lane's launch is keyed on, never an effect on it"
)]
fn caller_server(vars: &Vars) -> Option<String> {
    let socket = vars.tmux_socket.as_ref()?;
    tmux::server(socket)
        .ok()
        .map(|server| server.pid.to_string())
}

/// How the lane's recorded launch stands to `session` on `pane` of
/// `server`: a launch keyed by its pane is the caller's only on that pane
/// of that server, one keyed by its native process only for the session it
/// recorded; a session the record names that is another is stale, and a
/// caller the launch cannot be matched with is unbound.
pub(super) fn association(
    entry: &Value,
    session: &str,
    pane: Option<&str>,
    server: &str,
) -> Association {
    let text = |value: Option<&Value>| match value {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(text)) => text.clone(),
        Some(other) => other.to_string(),
    };
    let recorded = text(entry.get("session_id"));
    let launch = |key: &str| text(entry.get("launch").and_then(|l| l.get(key)));
    let pane = pane.unwrap_or_default();
    if session.is_empty() {
        Association::Unbound
    } else if !recorded.is_empty() && recorded != session {
        Association::Stale
    } else if !launch("pane").is_empty() {
        if pane.is_empty() || server.is_empty() || launch("server").is_empty() {
            Association::Unbound
        } else if launch("pane") == pane && launch("server") == server {
            Association::Current
        } else {
            Association::Stale
        }
    } else if recorded == session && !launch("pid").is_empty() && !launch("start").is_empty() {
        Association::Current
    } else {
        Association::Unbound
    }
}

/// The context answer handing `said` to the session, with `cause` under
/// it; one stdout cannot take is refused as the arm refuses.
fn handed(turn: &mut Turn, said: &Said, cause: &str) -> Answer {
    Answer {
        stdout: answer::context(turn.harness, EVENT, &said.text(cause), None),
        stderr: std::mem::take(&mut turn.stderr),
        code: 0,
        ack: None,
        unwritten: Some(answer::refusal(turn.harness, turn.arm.as_ref(), "").1),
    }
}

/// A file of the switch's own beside the records, made exclusively and
/// removed when dropped: the record a check is bound to, a handoff body, a
/// transfer request.
struct Scratch(PathBuf);

impl Scratch {
    #[allow(
        clippy::disallowed_methods,
        reason = "the switch's own input files beside the records, made exclusively and removed once read"
    )]
    fn create(dir: &Path, stem: &str, text: &str) -> std::io::Result<Scratch> {
        for n in 0..64_u32 {
            let path = dir.join(format!("{stem}.{}.{n}", std::process::id()));
            match std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&path)
            {
                Ok(mut file) => {
                    let scratch = Scratch(path);
                    file.write_all(text.as_bytes())?;
                    return Ok(scratch);
                }
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
                Err(e) => return Err(e),
            }
        }
        Err(std::io::Error::from(std::io::ErrorKind::AlreadyExists))
    }
}

impl Drop for Scratch {
    #[allow(
        clippy::disallowed_methods,
        reason = "the removal of the switch's own input file, made exclusively above"
    )]
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

#[cfg(test)]
#[allow(
    clippy::disallowed_methods,
    reason = "the hosted rows plant a launch record, a link and a directory"
)]
mod tests {
    use std::os::unix::process::ExitStatusExt;
    use std::path::PathBuf;
    use std::process::{ExitStatus, Output};

    use agent_runtime::harness::Harness as Billed;
    use serde_json::{Value, json};

    use super::{Told, awaiting_reset, hosted, pi_billed, told};
    use crate::turnend::answer::{Harness, Hosted};
    use crate::turnend::identity::Lane;

    /// The pick's run ending at `status` with `stdout` and `stderr`.
    fn ran(status: i32, stdout: &str, stderr: &str) -> agent_runtime::Result<Output> {
        Ok(Output {
            status: ExitStatus::from_raw(status << 8),
            stdout: stdout.as_bytes().to_vec(),
            stderr: stderr.as_bytes().to_vec(),
        })
    }

    /// The verb's reply carrying the judge's `exit` and `record`.
    fn judged(exit: i64, record: Value) -> String {
        json!({"protocol": "orch-runtime-v1", "ok": true,
               "result": {"answer": "lane", "exit": exit, "record": record}})
        .to_string()
    }

    fn gap(word: &'static str, cause: &str) -> Told {
        Told::Gap(word, cause.to_owned())
    }

    /// Each judgement the verb answers at status 0 is told by its exit and,
    /// at 3, by the record's verdict and figures; a ceiling's kill is a
    /// timeout; any other status, exit or reply is an account nothing
    /// measured, never room.
    #[test]
    fn a_pick_reply_is_told_by_its_exit_and_verdict() {
        let walled =
            |wall: Value| json!({"verdict": "walled", "wall": wall, "binding_bucket": "weekly"});
        let word =
            |verdict: &str| json!({"verdict": verdict, "wall": 10, "detail": "the owner's word"});
        let unreadable = "the account judge returned an unreadable refusal record";
        let killed = agent_runtime::Error::External {
            program: "orch-runtime",
            operation: "lane pick",
            cause: "no answer within 20s".to_owned(),
        };
        let unstarted = || agent_runtime::Error::NotStarted {
            program: "orch-runtime",
            operation: "lane pick",
            cause: "gone".to_owned(),
        };
        let rows: Vec<(&str, agent_runtime::Result<Output>, Told)> = vec![
            (
                "room",
                ran(0, &judged(0, json!({"verdict": "room"})), ""),
                Told::Room,
            ),
            (
                "walled",
                ran(0, &judged(3, walled(json!(98))), ""),
                Told::Headroom {
                    headroom: "2".to_owned(),
                    bucket: "weekly".to_owned(),
                },
            ),
            (
                "walled on a fraction",
                ran(0, &judged(3, walled(json!(97.5))), ""),
                Told::Headroom {
                    headroom: "2.5".to_owned(),
                    bucket: "weekly".to_owned(),
                },
            ),
            (
                "a record naming nothing",
                ran(0, &judged(3, json!({})), ""),
                Told::Headroom {
                    headroom: "unknown".to_owned(),
                    bucket: "unknown".to_owned(),
                },
            ),
            (
                "seat",
                ran(
                    0,
                    &judged(
                        3,
                        json!({"verdict": "seat-reserve", "wall": 92, "binding_bucket": "weekly", "need": 11}),
                    ),
                    "",
                ),
                Told::SeatReserve {
                    headroom: "8".to_owned(),
                    bucket: "weekly".to_owned(),
                    need: "11".to_owned(),
                },
            ),
            (
                "excluded",
                ran(0, &judged(3, word("excluded")), ""),
                gap("excluded", "the owner's word"),
            ),
            (
                "reserved",
                ran(0, &judged(3, word("reserved")), ""),
                gap("reserved", "the owner's word"),
            ),
            (
                "retired",
                ran(0, &judged(3, word("retired")), ""),
                gap("retired", "the owner's word"),
            ),
            (
                "another verdict",
                ran(0, &judged(3, word("room")), ""),
                gap("unmeasured", unreadable),
            ),
            (
                "no record",
                ran(0, &judged(4, Value::Null), "w"),
                gap("unlisted", "w"),
            ),
            (
                "cloud",
                ran(
                    0,
                    &judged(
                        7,
                        json!({"verdict": "cloud-repo-unset", "detail": "no rule"}),
                    ),
                    "",
                ),
                gap("cloud-repo-unset", "no rule"),
            ),
            (
                "unmeasured",
                ran(0, &judged(5, json!({"verdict": "unmeasured"})), "w"),
                gap("unmeasured", "w"),
            ),
            (
                "unjudged",
                ran(0, &judged(1, json!({"cause": "c"})), "w"),
                gap("unmeasured", "w"),
            ),
            (
                "refused",
                ran(1, "{}", "orch-runtime: refused"),
                gap("unmeasured", "orch-runtime: refused"),
            ),
            (
                "unread",
                ran(0, "no reply", ""),
                gap("unmeasured", "the reply carries no judgement"),
            ),
            (
                "a refusal's reply",
                ran(
                    0,
                    &json!({"protocol": "orch-runtime-v1", "ok": false}).to_string(),
                    "",
                ),
                gap("unmeasured", "the reply carries no judgement"),
            ),
            (
                "a result naming no exit",
                ran(
                    0,
                    &json!({"protocol": "orch-runtime-v1", "ok": true,
                            "result": {"answer": "lane", "record": {"verdict": "room"}}})
                    .to_string(),
                    "",
                ),
                gap("unmeasured", "the reply carries no judgement"),
            ),
            (
                "killed at the ceiling",
                Err(killed),
                gap("timeout", "the read was abandoned after 20 seconds"),
            ),
            (
                "unstarted",
                Err(unstarted()),
                gap("unmeasured", &unstarted().to_string()),
            ),
        ];
        for (case, read, want) in rows {
            assert_eq!(told(read), want, "{case}");
        }
    }

    /// A Pi lane spends the account its model's provider bills; a reading
    /// that named no model, or a provider nothing bills, measures none.
    #[test]
    fn a_pi_lane_is_judged_on_the_account_its_model_bills() {
        for (model, want) in [
            ("pi-claude/claude-opus-4-1", Some(Billed::Claude)),
            ("anthropic/claude-opus-4-1", Some(Billed::Pi)),
            ("github-copilot/gpt-5", Some(Billed::Pi)),
            ("openai/gpt-5", None),
            ("", None),
        ] {
            assert_eq!(pi_billed(model).ok(), want, "{model}");
        }
        assert!(pi_billed("").unwrap_err().starts_with("no reading"));
        assert!(
            pi_billed("openai/gpt-5")
                .unwrap_err()
                .starts_with("the provider of openai/gpt-5")
        );
    }

    /// A launch record naming an absolute identity file is a hosted lane's,
    /// told by what its harness and model spend; a record naming none, a
    /// link and a lane with no launch directory are local; a record that
    /// stands and cannot be read, each naming why, and an item no path can
    /// name, are causes.
    #[test]
    fn hosted_launch_is_told_by_its_identity_file() {
        let dir = tempfile::tempdir().unwrap();
        let common = dir.path().join("common");
        let lane = |item: &str| Lane {
            root: dir.path().to_path_buf(),
            common: Some(common.clone()),
            mail_root: dir.path().join("mail"),
            item: Some(item.to_owned()),
        };
        let record = common.join("lane-launch").join("ken-1.json");
        let plant = |text: &str| {
            std::fs::create_dir_all(record.parent().unwrap()).unwrap();
            let _ = std::fs::remove_file(&record);
            std::fs::write(&record, text).unwrap();
        };
        assert_eq!(
            hosted(&lane("KEN-1"), Harness::Claude, ""),
            Ok(None),
            "no launch directory"
        );
        let identity = r#"{"identity_file": "/sandbox/identity"}"#;
        plant(identity);
        for (harness, model, want) in [
            (Harness::Claude, "", Hosted::Claude),
            (Harness::Pi, "anthropic/claude-opus-4-1", Hosted::PiGrant),
            (Harness::Pi, "github-copilot/gpt-5", Hosted::Pi),
        ] {
            assert_eq!(
                hosted(&lane("KEN-1"), harness, model),
                Ok(Some(want)),
                "{model}"
            );
        }
        for (case, text) in [
            ("relative", r#"{"identity_file": "identity"}"#),
            ("none", r#"{"identity_file": null}"#),
            ("not a string", r#"{"identity_file": 7}"#),
        ] {
            plant(text);
            assert_eq!(
                hosted(&lane("KEN-1"), Harness::Claude, ""),
                Ok(None),
                "{case}"
            );
        }
        for (case, text, why) in [
            (
                "no JSON",
                "{",
                "EOF while parsing an object at line 1 column 1",
            ),
            ("no object", "[]", "no launch record object"),
        ] {
            plant(text);
            let cause = hosted(&lane("KEN-1"), Harness::Claude, "").unwrap_err();
            assert_eq!(cause, format!("{}: {why}", record.display()), "{case}");
        }
        let elsewhere: PathBuf = dir.path().join("elsewhere.json");
        std::fs::write(&elsewhere, identity).unwrap();
        std::fs::remove_file(&record).unwrap();
        std::os::unix::fs::symlink(&elsewhere, &record).unwrap();
        assert_eq!(
            hosted(&lane("KEN-1"), Harness::Claude, ""),
            Ok(None),
            "a link"
        );
        let refused = hosted(&lane("../ken-1"), Harness::Claude, "");
        assert!(refused.is_err(), "an item no path names");
    }

    const NOW: &str = "pane %5";
    const BEFORE: &str = "pane %4";

    /// A lane record of `item` launched as `launch`, its check `outcome`
    /// with its recovery `started` under the launch `bound`.
    fn lane(item: &str, launch: &str, outcome: &str, started: bool, bound: &str) -> Value {
        json!({
            "item": item,
            "launch": { "pane": launch },
            "launched_at": "2026-11-12T00:00:00Z",
            "model_check": {
                "outcome": outcome,
                "recovery_started": started,
                "launch_identity": {
                    "launch": { "pane": bound },
                    "launched_at": "2026-11-12T00:00:00Z",
                },
            },
        })
    }

    /// Only a switched check whose recovery started under an earlier launch
    /// of the item awaits its reset; the first such record of the item is it.
    #[test]
    fn a_reset_awaits_only_a_started_switch_bound_to_an_earlier_launch() {
        for (case, lanes, reset) in [
            (
                "replaced",
                vec![lane("ken-1", NOW, "switched", true, BEFORE)],
                Some(NOW),
            ),
            (
                "the same launch",
                vec![lane("ken-1", NOW, "switched", true, NOW)],
                None,
            ),
            (
                "not started",
                vec![lane("ken-1", NOW, "switched", false, BEFORE)],
                None,
            ),
            (
                "unavailable",
                vec![lane("ken-1", NOW, "unavailable", true, BEFORE)],
                None,
            ),
            (
                "another item",
                vec![lane("ken-2", NOW, "switched", true, BEFORE)],
                None,
            ),
            (
                "the first that awaits",
                vec![
                    lane("ken-1", BEFORE, "switched", true, BEFORE),
                    lane("ken-1", NOW, "switched", true, BEFORE),
                ],
                Some(NOW),
            ),
            ("no lanes", Vec::new(), None),
        ] {
            let mut doc = serde_json::Map::new();
            doc.insert("lanes".to_owned(), Value::Array(lanes));
            let found = awaiting_reset(&doc, "ken-1");
            let pane = found.as_ref().map(|l| l["launch"]["pane"].clone());
            assert_eq!(pane, reset.map(|p| json!(p)), "{case}");
        }
    }
}
