//! The lane transitions: a lane admitted against the fleet cap and opened
//! `preparing` with its launch intent, a session this runtime did not
//! launch bound to a lane under a confirmed identity, a close asked for on
//! a ground that authorizes it, a park, a reservation and its release, an
//! effect's phase written onto its open intent, and the arms of
//! `record-outcome` that move a lane when its launch or close ends.

use std::fs;
use std::path::{Path, PathBuf};

use agent_runtime::clock;
use agent_runtime::process::Identity;
use agent_runtime::protocol::Outcome;
use agent_runtime::reading::Reading;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::admission::{self, Admission, ScopeRange};
use super::occupancy::{self, Host, Identities, Occupancy, Read};
use super::{
    Effect, Env, OutcomeRecorded, RecordOutcome, Standing, intents, lane_at, lane_doc_mut, lanes,
    new_intent, no_open_intent, open_intent, push_intent, same_open_intent, string_or_null,
};
use crate::error::{Error, Result};
use crate::state::{
    self, CloseGround, Document, EffectOp, Intent, Lane, LaneKeys, LaneStatus, LaunchIdentity,
    ObligationRecord, Phase, Reservation, Selection, TerminalVerdict,
};

/// Open a lane for an item: judge the fleet cap, write its record as
/// `preparing` and the intent to launch it. On a relaunch every optional
/// field left out keeps the record's value, and `harness`, `account`,
/// `model` and `effort` reach the record only when the launch confirms, as
/// the legacy launcher writes them at `running`; on a first launch the
/// record carries them from the start, and `kind` and `surface` left out
/// are `local` and `tmux`, the one launch route this runtime has.
/// `exclude_account` is the account a wall spent (step4-map A11): a launch
/// whose `account` canonicalizes to it is refused. `over_cap` admits the
/// launch past the cap and is recorded, as the legacy `--over-cap` is.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LaunchLane {
    pub item: String,
    pub harness: String,
    pub mail_root: String,
    #[serde(default)]
    pub tracker: Option<String>,
    #[serde(default)]
    pub repo: Option<String>,
    #[serde(default)]
    pub account: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub effort: Option<String>,
    #[serde(default)]
    pub kind: Option<String>,
    #[serde(default)]
    pub surface: Option<String>,
    #[serde(default)]
    pub over_cap: Option<String>,
    #[serde(default)]
    pub exclude_account: Option<String>,
    /// The opening instruction, read by the harness at its start. Not a
    /// record field: the effect carries it to the launch, and the
    /// admission reads the paths it names (decision 118 (4)).
    #[serde(default)]
    pub brief_file: Option<PathBuf>,
    /// The checkout the change-scope paths are read in, for `scope_range`.
    #[serde(default)]
    pub repo_dir: Option<PathBuf>,
    /// The diff range whose changed paths join the touched set.
    #[serde(default)]
    pub scope_range: Option<ScopeRange>,
    /// The paths the brief names in scope as append-only additions: a
    /// holder of one does not hold the launch. Recorded as `in_scope`.
    #[serde(default)]
    pub in_scope: Vec<String>,
}

impl LaunchLane {
    /// The optional fields a relaunch writes at `preparing`, in the lane
    /// record's order.
    fn prepared(&self) -> [(&'static str, &Option<String>); 5] {
        [
            ("tracker", &self.tracker),
            ("repo", &self.repo),
            ("kind", &self.kind),
            ("surface", &self.surface),
            ("over_cap", &self.over_cap),
        ]
    }

    /// The fields the launch writes when it confirms.
    fn selection(&self) -> Selection {
        Selection {
            harness: self.harness.clone(),
            account: self.account.clone(),
            model: self.model.clone(),
            effort: self.effort.clone(),
        }
    }
}

/// Bind a session this runtime did not launch to the item's lane record.
/// A `launch` left out keeps the recorded identity, as the legacy wake does.
/// The identity bound, given or recorded, is confirmed live through the one
/// identity reader before the lane reads `running` (decision 60); no name
/// is read in its place.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AdoptSession {
    pub item: String,
    pub session_id: String,
    #[serde(default)]
    pub harness: Option<String>,
    #[serde(default)]
    pub launch: Option<LaunchIdentity>,
}

/// The tracker's terminal verdict on the lane's item, carried as evidence
/// by the package that read it (decision 83).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Terminal {
    pub verdict: TerminalVerdict,
    pub source: String,
}

/// An explicit disposition that ends the attempt with no landing while the
/// item stays open (decision 98).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NoLanding {
    pub reason: String,
    pub source: String,
}

/// Ask for a lane's owned processes and window to be closed. Without a
/// ground the lane must read exited; `terminal` closes it whatever it reads;
/// `no_landing` retires the attempt on idle-or-gone proof and keeps the
/// item's work (decisions 83, 98).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CloseOwnedResources {
    pub item: String,
    #[serde(default)]
    pub terminal: Option<Terminal>,
    #[serde(default)]
    pub no_landing: Option<NoLanding>,
}

/// Record a hosted lane parked: its clean merge wait ended with its disk
/// kept, as `lane-close --park` records it after the sandbox stop. The
/// sandbox stop itself is the host adapter's (decision 57), so the lane
/// must already read `stopped`; a local lane has no sandbox to park.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ParkLane {
    pub item: String,
    pub head: String,
    pub repo: String,
    #[serde(default)]
    pub pr: Option<u64>,
    #[serde(default)]
    pub until_pr: Option<u64>,
    #[serde(default)]
    pub until_repo: Option<String>,
    /// A finite hold on the lane's cap slot through the park, where the
    /// caller wants one; parked disk alone charges nothing (decision 97).
    #[serde(default)]
    pub reservation: Option<Reservation>,
}

/// Hold a lane's cap slot deliberately until `until`, an ISO 8601 UTC stamp
/// after now (decision 97).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReserveLane {
    pub item: String,
    pub reason: String,
    pub until: String,
}

/// Drop the reservation of one attempt of a lane, named by its
/// `session_since`: a request bound to an earlier attempt changes nothing.
/// Repeating it is a no-op.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReleaseLane {
    pub item: String,
    pub session_since: String,
}

/// Record how far an open effect has got: its phase and the pane it holds,
/// written before the effect waits on its next step (decision 62). Refused
/// on an intent that has ended.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RecordPhase {
    pub intent_id: String,
    pub phase: Phase,
}

/// A lane written `preparing` with its launch intent, and what charged the
/// cap when it was admitted.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LaneLaunched {
    pub lane: Lane,
    pub effect: Effect,
    pub admission: Occupancy,
}

/// A lane bound to a session.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LaneAdopted {
    pub lane: Lane,
    /// False when the lane already ran this session.
    pub adopted_now: bool,
}

/// A close asked for, with the lane as it stands until the stop confirms.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CloseRequested {
    pub lane: Lane,
    pub effect: Effect,
}

/// A lane recorded parked.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LaneParked {
    pub lane: Lane,
    /// False when the record already read parked.
    pub parked_now: bool,
}

/// A reservation written on a lane.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LaneReserved {
    pub lane: Lane,
}

/// A reservation dropped, or found already gone.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LaneReleased {
    pub lane: Lane,
    pub released_now: bool,
}

/// A phase written onto its open intent.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PhaseRecorded {
    pub intent: Intent,
}

/// The record a first launch appends, in `lane_record_write`'s key order
/// with `null` where the launch knows no value, as that writer emits it.
fn new_lane_record(r: &LaunchLane, at: &str) -> Value {
    json!({
        "item": r.item,
        "tracker": string_or_null(&r.tracker),
        "repo": string_or_null(&r.repo),
        "harness": r.harness,
        "window": Value::Null,
        "account": string_or_null(&r.account),
        "host": Value::Null,
        "kind": r.kind.as_deref().unwrap_or("local"),
        "mail_root": r.mail_root,
        "surface": r.surface.as_deref().unwrap_or("tmux"),
        "model": string_or_null(&r.model),
        "effort": string_or_null(&r.effort),
        "session_id": Value::Null,
        "session_since": at,
        "launched_at": at,
        "running_at": Value::Null,
        "status": LaneStatus::Preparing.word(),
        "over_cap": string_or_null(&r.over_cap),
        "launch": Value::Null,
    })
}

/// The legacy `unpark($at)`: a standing `parked` moves into `pending_pr`
/// (`{pr, repo, head}` plus `until_pr` and `until_repo` where set) and
/// appends `{from: parked.at, to: $at, cause: "parked"}` to `pauses`; the
/// `parked` key is removed either way.
fn unpark(path: &Path, lane: &mut Document, index: usize, at: &str) -> Result<()> {
    let parked = match lane.get("parked") {
        None => return Ok(()),
        Some(Value::Null) => {
            state::delete(lane, "parked");
            return Ok(());
        }
        Some(Value::Object(parked)) => parked.clone(),
        Some(other) => {
            return Err(Error::Shape {
                path: path.to_path_buf(),
                field: format!("lanes/{index}/parked"),
                reason: crate::error::ShapeReason::NotObject,
                cause: format!("found {other}"),
            });
        }
    };
    if parked.get("at").is_some_and(|v| !v.is_null()) {
        let pause = json!({"from": parked["at"], "to": at, "cause": "parked"});
        state::array_mut(path, lane, "pauses")?.push(pause);
    }
    let mut pending = Map::new();
    for key in ["pr", "repo", "head"] {
        pending.insert(
            key.to_owned(),
            parked.get(key).cloned().unwrap_or(Value::Null),
        );
    }
    for key in ["until_pr", "until_repo"] {
        if let Some(value) = parked.get(key).filter(|v| !v.is_null()) {
            pending.insert(key.to_owned(), value.clone());
        }
    }
    state::set(lane, "pending_pr", Value::Object(pending));
    state::delete(lane, "parked");
    Ok(())
}

/// One spelling per account, as the legacy claim store compares them
/// (`lane_claims_canon`): the directory resolved physically, else its own
/// spelling with trailing slashes off.
fn canonical_account(account: &str) -> String {
    match fs::canonicalize(account) {
        Ok(resolved) => resolved.display().to_string(),
        Err(_) => {
            let mut spelled = account.to_owned();
            while spelled.len() > 1 && spelled.ends_with('/') {
                spelled.pop();
            }
            spelled
        }
    }
}

/// What the lane's recorded harness reads as, through the one identity
/// reader: live, gone, or unreadable, with no identity recorded as `None`.
fn recorded_harness(lane: &Lane, host: &Host) -> Option<Reading<Identity>> {
    let id = lane.launch.as_ref().and_then(occupancy::identity_of)?;
    Some((host.still_runs)(&id))
}

/// Refuse to start a second harness over the lane's recorded execution,
/// its launched harness or its detached wake turn, while either runs or
/// cannot be read, whatever the status word says: a live wake is owned
/// execution, and a relaunch beside it would be a second (decision 108).
fn no_live_harness(lane: &Lane, ids: &Identities) -> Result<()> {
    for read in [&ids.launch, &ids.wake].into_iter().flatten() {
        let Read { id, reading } = read;
        match reading {
            Reading::Gone => {}
            Reading::Live(_) => {
                return Err(Error::HarnessLive {
                    item: lane.item.clone(),
                    pid: id.pid as u64,
                });
            }
            Reading::Unreadable { cause } => {
                return Err(Error::HarnessUnreadable {
                    item: lane.item.clone(),
                    pid: id.pid as u64,
                    cause: (*cause).to_owned(),
                });
            }
        }
    }
    Ok(())
}

pub(super) fn launch_lane(
    path: &Path,
    doc: &mut Document,
    r: &LaunchLane,
    env: &Env,
    host: &Host,
) -> Result<LaneLaunched> {
    // The one launch route is a local tmux window; a non-local kind or a
    // non-tmux surface is refused before any intent persists (decision 57).
    if let Some(kind) = r.kind.as_deref().filter(|k| *k != "local") {
        return Err(Error::HostUnsupported {
            kind: kind.to_owned(),
            surface: r.surface.clone().unwrap_or_else(|| "tmux".to_owned()),
        });
    }
    if let Some(surface) = r.surface.as_deref().filter(|s| *s != "tmux") {
        return Err(Error::HostUnsupported {
            kind: r.kind.clone().unwrap_or_else(|| "local".to_owned()),
            surface: surface.to_owned(),
        });
    }
    let lanes = lanes(path, doc)?;
    let intents = intents(path, doc)?;
    let position = lanes.iter().position(|l| l.item == r.item);
    // The identities the lane a relaunch replaces still names, read once:
    // they decide what of its record the count keeps and whether the
    // relaunch is refused beside a harness that still runs.
    let own = position.map(|index| occupancy::read_identities(&lanes[index], host));
    // The cap as it stands, read once for the reply whether this request
    // admits a launch or finds its own standing (decision 97): every local
    // lane, the one a relaunch replaces counted for what the relaunch does
    // not replace, plus the legacy rows no live record accounts for.
    let claims = match &host.claim_store {
        Some(store) => occupancy::read_claims(store, &occupancy::canonical_fleet(path))?,
        None => Vec::new(),
    };
    let admission = occupancy::occupancy(
        &lanes,
        &intents,
        own.as_ref().map(|ids| (r.item.as_str(), ids)),
        &claims,
        env.now_secs,
        host,
    );
    if let Some(intent) = same_open_intent(&intents, EffectOp::LaunchLane, &r.item)? {
        let index = position.ok_or_else(|| Error::LaneMissing {
            item: r.item.clone(),
        })?;
        return Ok(LaneLaunched {
            lane: lane_at(path, doc, index)?,
            effect: Effect::Reconciled { intent },
            admission,
        });
    }
    // The account boundary (step4-map A11): the account judge stays legacy
    // (decision 75), and the one thing this op refuses is the account the
    // wall spent, compared the way the claim store compares accounts.
    if let (Some(account), Some(spent)) = (&r.account, &r.exclude_account)
        && canonical_account(account) == canonical_account(spent)
    {
        return Err(Error::AccountSpent {
            item: r.item.clone(),
            account: account.clone(),
        });
    }
    if let (Some(index), Some(ids)) = (position, &own) {
        let previous = &lanes[index];
        if previous.status.in_flight() {
            return Err(Error::LaneLive {
                item: r.item.clone(),
                status: previous.status,
            });
        }
        // A returned turn alone does not end a live harness or its wake
        // (decision 97): a relaunch over one would make a second.
        no_live_harness(previous, ids)?;
    }
    // The admission judgement (decisions 118 (3), (4), (6)), under the
    // same launch lock and before the cap, so one transition admits or
    // refuses with one cause: a first launch is judged on its item, its
    // brief and the range it names; a relaunch keeps the record's sets,
    // as the legacy launcher passes a recorded lane's relaunch unjudged.
    let judged = match position {
        Some(_) => None,
        None => Some(admission::judge(
            path,
            &lanes,
            &intents,
            &Admission {
                item: &r.item,
                tracker: r.tracker.as_deref(),
                repo: r.repo.as_deref(),
                brief_file: r.brief_file.as_deref(),
                repo_dir: r.repo_dir.as_deref(),
                scope_range: r.scope_range.as_ref(),
                in_scope: &r.in_scope,
                paths: &[],
            },
            env,
            host,
        )?),
    };
    if admission.occupancy >= host.lane_cap && r.over_cap.is_none() {
        let lanes = admission
            .charges
            .iter()
            .filter(|c| matches!(c.source, occupancy::ChargeSource::Lane { .. }))
            .count();
        return Err(Error::CapReached {
            occupancy: admission.occupancy,
            cap: host.lane_cap,
            lanes: u32::try_from(lanes).unwrap_or(u32::MAX),
            claims: admission
                .occupancy
                .saturating_sub(u32::try_from(lanes).unwrap_or(u32::MAX)),
        });
    }
    let at = env.iso();
    let index = match position {
        Some(index) => {
            // The relaunch patch: what this launch knows, over a record that
            // keeps every other field (its first `launched_at` included, the
            // fleet start the watch reads). `prepare` and `live_display`
            // belong to the earlier session, and so does a reservation: the
            // new attempt takes the slot itself; `running_at` and `launch`
            // are written empty until the launch confirms, and the selection
            // (harness, account, model, effort) waits on the intent until
            // then, as the legacy writer records it at `running`.
            let lane = lane_doc_mut(path, doc, index)?;
            state::set(lane, "mail_root", r.mail_root.as_str());
            for (key, value) in r.prepared() {
                if let Some(value) = value {
                    state::set(lane, key, value.as_str());
                }
            }
            state::set(lane, "session_since", at.as_str());
            state::set(lane, "running_at", Value::Null);
            state::set(lane, "status", LaneStatus::Preparing.word());
            state::set(lane, "launch", Value::Null);
            state::delete(lane, "prepare");
            state::delete(lane, "live_display");
            state::delete(lane, "reservation");
            unpark(path, lane, index, &at)?;
            index
        }
        None => {
            let rows = state::array_mut(path, doc, "lanes")?;
            rows.push(new_lane_record(r, &at));
            let index = rows.len() - 1;
            if let Some(judged) = &judged {
                admission::record(path, doc, index, judged)?;
            }
            index
        }
    };
    let mut intent = new_intent(EffectOp::LaunchLane, &r.item, env)?;
    intent.lane_since = Some(at);
    intent.selection = Some(r.selection());
    intent.exclude_account = r.exclude_account.as_deref().map(canonical_account);
    push_intent(path, doc, &intent)?;
    Ok(LaneLaunched {
        lane: lane_at(path, doc, index)?,
        effect: Effect::Persisted { intent },
        admission,
    })
}

pub(super) fn adopt_session(
    path: &Path,
    doc: &mut Document,
    r: &AdoptSession,
    env: &Env,
    host: &Host,
) -> Result<LaneAdopted> {
    let lanes = lanes(path, doc)?;
    let index = lanes
        .iter()
        .position(|l| l.item == r.item)
        .ok_or_else(|| Error::LaneMissing {
            item: r.item.clone(),
        })?;
    no_open_intent(&intents(path, doc)?, &r.item)?;
    let previous = &lanes[index];
    match previous.status {
        LaneStatus::Running => {
            if previous.session_id.as_deref() == Some(&r.session_id) {
                return Ok(LaneAdopted {
                    lane: previous.clone(),
                    adopted_now: false,
                });
            }
            Err(Error::LaneLive {
                item: r.item.clone(),
                status: previous.status,
            })
        }
        LaneStatus::Done => Err(Error::LaneDone {
            item: r.item.clone(),
        }),
        LaneStatus::Preparing | LaneStatus::Stopped | LaneStatus::Parked => {
            // The identity the lane will run under, given or kept, is read
            // through the one identity reader before anything binds: a pid
            // that holds no process under its start is no execution to
            // adopt, and one that cannot be read authorizes nothing.
            let bound = r
                .launch
                .as_ref()
                .or(previous.launch.as_ref())
                .and_then(occupancy::identity_of);
            if let Some(id) = bound {
                match (host.still_runs)(&id) {
                    Reading::Live(_) => {}
                    Reading::Gone => {
                        return Err(Error::IdentityGone {
                            item: r.item.clone(),
                            pid: id.pid as u64,
                        });
                    }
                    Reading::Unreadable { cause } => {
                        return Err(Error::HarnessUnreadable {
                            item: r.item.clone(),
                            pid: id.pid as u64,
                            cause: cause.to_owned(),
                        });
                    }
                }
            }
            let at = env.iso();
            let lane = lane_doc_mut(path, doc, index)?;
            state::set(lane, "session_id", r.session_id.as_str());
            if let Some(harness) = &r.harness {
                state::set(lane, "harness", harness.as_str());
            }
            if let Some(launch) = &r.launch {
                state::set(lane, "launch", serde_json::to_value(launch)?);
            }
            state::set(lane, "status", LaneStatus::Running.word());
            state::set(lane, "running_at", at.as_str());
            // The harness charges the slot from here; a hold over the gap
            // before it is spent.
            state::delete(lane, "reservation");
            unpark(path, lane, index, &at)?;
            Ok(LaneAdopted {
                lane: lane_at(path, doc, index)?,
                adopted_now: true,
            })
        }
    }
}

/// The ground a close request stands on (decisions 83, 98), judged on the
/// lane's recorded harness through the one identity reader. Without a
/// stated ground the harness must read gone; a recorded pane with no
/// identity is a lane not known exited. A `no-landing` disposition needs a
/// readable harness, idle or gone; the idle proof is the effect's, where the
/// screen is read.
fn close_ground(lane: &Lane, r: &CloseOwnedResources, host: &Host) -> Result<CloseGround> {
    let reading = recorded_harness(lane, host);
    let unreadable = |cause: &str| Error::HarnessUnreadable {
        item: lane.item.clone(),
        pid: lane.launch.as_ref().and_then(|l| l.pid).unwrap_or(0),
        cause: cause.to_owned(),
    };
    match (&r.terminal, &r.no_landing) {
        (Some(_), Some(_)) => Err(Error::CloseGroundAmbiguous {
            item: lane.item.clone(),
        }),
        (Some(terminal), None) => Ok(CloseGround::Terminal {
            verdict: terminal.verdict,
            source: terminal.source.clone(),
        }),
        (None, Some(disposition)) => match reading {
            Some(Reading::Unreadable { cause }) => Err(unreadable(cause)),
            None | Some(Reading::Live(_) | Reading::Gone) => Ok(CloseGround::NoLanding {
                reason: disposition.reason.clone(),
                source: disposition.source.clone(),
            }),
        },
        (None, None) => match reading {
            Some(Reading::Gone) => Ok(CloseGround::Exited),
            Some(Reading::Live(_)) => Err(Error::LaneLive {
                item: lane.item.clone(),
                status: lane.status,
            }),
            Some(Reading::Unreadable { cause }) => Err(unreadable(cause)),
            None => {
                let pane_recorded = lane.launch.as_ref().is_some_and(|l| l.pane.is_some());
                if pane_recorded {
                    Err(Error::LaneLive {
                        item: lane.item.clone(),
                        status: lane.status,
                    })
                } else {
                    Ok(CloseGround::Exited)
                }
            }
        },
    }
}

pub(super) fn close_owned_resources(
    path: &Path,
    doc: &mut Document,
    r: &CloseOwnedResources,
    env: &Env,
    host: &Host,
) -> Result<CloseRequested> {
    let lanes = lanes(path, doc)?;
    let lane = lanes
        .iter()
        .find(|l| l.item == r.item)
        .cloned()
        .ok_or_else(|| Error::LaneMissing {
            item: r.item.clone(),
        })?;
    if lane.status == LaneStatus::Done {
        return Err(Error::LaneDone {
            item: r.item.clone(),
        });
    }
    match open_intent(&intents(path, doc)?, EffectOp::CloseOwnedResources, &r.item)? {
        Standing::Clear => {}
        Standing::Same(intent) => {
            return Ok(CloseRequested {
                lane,
                effect: Effect::Reconciled { intent },
            });
        }
        Standing::Supersedable(intent) => {
            return Ok(CloseRequested {
                lane,
                effect: Effect::Supersedes { intent },
            });
        }
    }
    let ground = close_ground(&lane, r, host)?;
    let mut intent = new_intent(EffectOp::CloseOwnedResources, &r.item, env)?;
    intent.lane_since = lane.session_since.clone();
    intent.close = Some(ground);
    push_intent(path, doc, &intent)?;
    Ok(CloseRequested {
        lane,
        effect: Effect::Persisted { intent },
    })
}

/// A reservation's term must be a stamp after the clock (decision 97).
fn check_reservation(item: &str, reservation: &Reservation, env: &Env) -> Result<()> {
    match clock::epoch_secs(&reservation.until) {
        Some(until) if until > env.now_secs => Ok(()),
        Some(_) | None => Err(Error::ReservationInvalid {
            item: item.to_owned(),
            until: reservation.until.clone(),
        }),
    }
}

pub(super) fn park_lane(
    path: &Path,
    doc: &mut Document,
    r: &ParkLane,
    env: &Env,
) -> Result<LaneParked> {
    let lanes = lanes(path, doc)?;
    let index = lanes
        .iter()
        .position(|l| l.item == r.item)
        .ok_or_else(|| Error::LaneMissing {
            item: r.item.clone(),
        })?;
    no_open_intent(&intents(path, doc)?, &r.item)?;
    let lane = &lanes[index];
    // A park stops a hosted sandbox with its disk kept; a local lane has
    // none, as `lane-close --park` refuses it.
    if lane.host.is_none() || lane.kind.as_deref() == Some("local") {
        return Err(Error::ParkRefused {
            item: r.item.clone(),
            reason: "local",
        });
    }
    match lane.status {
        LaneStatus::Done => Err(Error::LaneDone {
            item: r.item.clone(),
        }),
        LaneStatus::Parked => Ok(LaneParked {
            lane: lane.clone(),
            parked_now: false,
        }),
        // The hosted harness stop and sandbox stop precede the park and are
        // the host adapter's (decision 57); until it lands they stay with
        // the legacy script, and this record moves only a lane they ended.
        LaneStatus::Preparing | LaneStatus::Running => Err(Error::LaneLive {
            item: r.item.clone(),
            status: lane.status,
        }),
        LaneStatus::Stopped => {
            if let Some(reservation) = &r.reservation {
                check_reservation(&r.item, reservation, env)?;
            }
            let mut parked = Map::new();
            parked.insert("head".to_owned(), Value::from(r.head.as_str()));
            parked.insert("repo".to_owned(), Value::from(r.repo.as_str()));
            parked.insert("at".to_owned(), Value::from(env.iso()));
            if let Some(pr) = r.pr {
                parked.insert("pr".to_owned(), Value::from(pr));
            }
            if let Some(until_pr) = r.until_pr {
                parked.insert("until_pr".to_owned(), Value::from(until_pr));
            }
            if let Some(until_repo) = &r.until_repo {
                parked.insert("until_repo".to_owned(), Value::from(until_repo.as_str()));
            }
            let lane = lane_doc_mut(path, doc, index)?;
            state::set(lane, "status", LaneStatus::Parked.word());
            state::set(lane, "parked", Value::Object(parked));
            state::delete(lane, "pending_pr");
            if let Some(reservation) = &r.reservation {
                state::set(lane, "reservation", serde_json::to_value(reservation)?);
            }
            Ok(LaneParked {
                lane: lane_at(path, doc, index)?,
                parked_now: true,
            })
        }
    }
}

pub(super) fn reserve_lane(
    path: &Path,
    doc: &mut Document,
    r: &ReserveLane,
    env: &Env,
) -> Result<LaneReserved> {
    let lanes = lanes(path, doc)?;
    let index = lanes
        .iter()
        .position(|l| l.item == r.item)
        .ok_or_else(|| Error::LaneMissing {
            item: r.item.clone(),
        })?;
    if lanes[index].status == LaneStatus::Done {
        return Err(Error::LaneDone {
            item: r.item.clone(),
        });
    }
    let reservation = Reservation {
        reason: r.reason.clone(),
        until: r.until.clone(),
    };
    check_reservation(&r.item, &reservation, env)?;
    let lane = lane_doc_mut(path, doc, index)?;
    state::set(lane, "reservation", serde_json::to_value(&reservation)?);
    Ok(LaneReserved {
        lane: lane_at(path, doc, index)?,
    })
}

pub(super) fn release_lane(
    path: &Path,
    doc: &mut Document,
    r: &ReleaseLane,
) -> Result<LaneReleased> {
    let lanes = lanes(path, doc)?;
    let index = lanes
        .iter()
        .position(|l| l.item == r.item)
        .ok_or_else(|| Error::LaneMissing {
            item: r.item.clone(),
        })?;
    // The request names the attempt it releases; the lane on a later
    // attempt is not that one, and the request changes nothing.
    if lanes[index].session_since.as_deref() != Some(r.session_since.as_str()) {
        return Err(Error::AttemptStale {
            item: r.item.clone(),
            session_since: r.session_since.clone(),
            current: lanes[index].session_since.clone(),
        });
    }
    let lane = lane_doc_mut(path, doc, index)?;
    let released_now = state::delete(lane, "reservation");
    Ok(LaneReleased {
        lane: lane_at(path, doc, index)?,
        released_now,
    })
}

/// The lane an intent targets, as it stands, or the reading that its record
/// moved under the intent: the lane is gone, moved under the intent's keys
/// ([`lane_moved`]), or closed under a launch intent, which a legacy
/// `lane-close` does from any status.
pub(super) enum IntentTarget {
    Current { index: usize },
    Moved { observed: Option<LaneStatus> },
}

/// Whether `lane` moved under an intent written at `keys` (decision 124d
/// (14)): its `session_since` is not the intent's, or its launch names a
/// pane or an identity the intent's set did not record under the harness
/// role. The one judgement: the handle applies it before it acts, and the
/// store applies it before it moves the lane, on the same inputs. A stamp
/// alone never decides, since the legacy launcher writes whole seconds.
pub fn lane_moved(lane: &Lane, keys: &LaneKeys) -> bool {
    lane.session_since != keys.lane_since
        || state::launch_obligations(lane.launch.as_ref())
            .iter()
            .any(|named| !keys.harness.contains(named))
}

/// The target of `intent` under `keys`, the terminal's where it carries
/// them, else the intent's own recorded set's; an intent with neither is
/// judged by its stamp alone, the one reading a hand-written outcome
/// (decision 111 (A) (4)) has.
pub(super) fn intent_lane(
    path: &Path,
    doc: &Document,
    intent: &Intent,
    keys: Option<&LaneKeys>,
) -> Result<IntentTarget> {
    let lanes = lanes(path, doc)?;
    let Some(index) = lanes.iter().position(|l| l.item == intent.target) else {
        return Ok(IntentTarget::Moved { observed: None });
    };
    let lane = &lanes[index];
    let recorded = intent
        .obligations
        .as_ref()
        .map(|record| record.lane_keys(intent.lane_since.clone()));
    let moved = match keys.or(recorded.as_ref()) {
        Some(keys) => lane_moved(lane, keys),
        None => lane.session_since != intent.lane_since,
    } || (intent.op == EffectOp::LaunchLane && lane.status == LaneStatus::Done);
    if moved {
        return Ok(IntentTarget::Moved {
            observed: Some(lane.status),
        });
    }
    Ok(IntentTarget::Current { index })
}

/// Record the fleet's tmux session where none is recorded yet, the legacy
/// first launch's `.tmux.session //= $s`.
fn record_tmux_session(path: &Path, doc: &mut Document, session: &str) -> Result<()> {
    if matches!(doc.get("tmux"), None | Some(Value::Null)) {
        state::set(doc, "tmux", json!({"session": session}));
        return Ok(());
    }
    let tmux = state::object_mut(path, doc, "tmux")?;
    if matches!(tmux.get("session"), None | Some(Value::Null)) {
        state::set(tmux, "session", session);
    }
    Ok(())
}

/// Write an open intent's phase. A closed intent refuses `intent-complete`:
/// its effect has no next step to wait on.
pub(super) fn record_phase(
    path: &Path,
    doc: &mut Document,
    r: &RecordPhase,
) -> Result<PhaseRecorded> {
    let intents = intents(path, doc)?;
    let index = intents
        .iter()
        .position(|i| i.id == r.intent_id)
        .ok_or_else(|| Error::IntentUnknown {
            id: r.intent_id.clone(),
        })?;
    let mut intent = intents[index].clone();
    if !intent.open() {
        return Err(Error::IntentComplete {
            id: intent.id.clone(),
            outcome: intent.outcome,
        });
    }
    intent.phase = Some(r.phase.clone());
    let rows = state::array_mut(path, doc, "intents")?;
    let row = state::element_mut(path, rows, index, "intents")?;
    state::set(row, "phase", serde_json::to_value(&r.phase)?);
    Ok(PhaseRecorded { intent })
}

/// The launch arms of `record-outcome` on the lane at `index`, judged
/// current by the caller. `confirmed` runs the lane with the identity and
/// session the effect read, `failed` stops it, `unconfirmed` keeps the pane
/// the effect holds so a reconcile can re-observe it.
pub(super) fn record_launch_outcome(
    path: &Path,
    doc: &mut Document,
    intent: &Intent,
    r: &RecordOutcome,
    at: &str,
    index: usize,
    recorded: &mut OutcomeRecorded,
) -> Result<()> {
    match r.outcome {
        Outcome::Confirmed => {
            if let Some(session) = &r.tmux_session {
                record_tmux_session(path, doc, session)?;
            }
            let lane = lane_doc_mut(path, doc, index)?;
            // The whole selection, null where the request named none, as
            // the legacy `running` write records it (`open-terminal`,
            // `lane_record_write`): the session that runs is this
            // request's, so no account, model or effort of the earlier
            // session survives into its record.
            if let Some(selection) = &intent.selection {
                state::set(lane, "harness", selection.harness.as_str());
                for (key, value) in [
                    ("account", &selection.account),
                    ("model", &selection.model),
                    ("effort", &selection.effort),
                ] {
                    state::set(lane, key, string_or_null(value));
                }
            }
            if let Some(window) = &r.window {
                state::set(lane, "window", window.as_str());
            }
            state::set(lane, "status", LaneStatus::Running.word());
            state::set(lane, "running_at", at);
            state::set(lane, "launch", serde_json::to_value(&r.launch)?);
            state::set(lane, "session_id", string_or_null(&r.session_id));
            recorded.lane = Some(Box::new(lane_at(path, doc, index)?));
        }
        Outcome::Failed => {
            let lane = lane_doc_mut(path, doc, index)?;
            state::set(lane, "status", LaneStatus::Stopped.word());
            recorded.lane = Some(Box::new(lane_at(path, doc, index)?));
        }
        Outcome::Unconfirmed => {
            // The window opened but the composer was not read in the bound.
            // Persist the pane the effect holds on the lane's `launch` so a
            // reconcile can re-observe it; the lane stays `preparing` (task
            // 3). A relaunch that wrote `launch: null` keeps that until the
            // effect names a pane.
            if r.launch.is_some() {
                let lane = lane_doc_mut(path, doc, index)?;
                state::set(lane, "launch", serde_json::to_value(&r.launch)?);
                recorded.lane = Some(Box::new(lane_at(path, doc, index)?));
            }
        }
        Outcome::NotStarted => {}
    }
    Ok(())
}

/// The close arms of `record-outcome` on the lane at `index`, judged
/// current by the caller. `confirmed` on an exited or terminal ground reads
/// the lane done and drops the PR identities and the reservation a close
/// ends, and records the reason the close kept the lane's worktree as
/// `kept` where its set says it did (decision 128 (9)); on a `no-landing`
/// ground it reads the lane stopped and keeps everything else, the attempt
/// retired with the item's work and history intact (decision 98). `failed`
/// and `unconfirmed` move nothing.
pub(super) fn record_close_outcome(
    path: &Path,
    doc: &mut Document,
    intent: &Intent,
    r: &RecordOutcome,
    at: &str,
    index: usize,
    recorded: &mut OutcomeRecorded,
) -> Result<()> {
    match r.outcome {
        Outcome::Confirmed => {
            let mut row = json!({
                "at": at,
                "kind": "close",
                "item": intent.target,
            });
            let lane = lane_doc_mut(path, doc, index)?;
            match &intent.close {
                Some(CloseGround::NoLanding { reason, source }) => {
                    state::set(lane, "status", LaneStatus::Stopped.word());
                    row["text"] =
                        json!(format!("attempt retired, no landing; intent {}", intent.id));
                    row["disposition"] = json!("no-landing");
                    row["reason"] = json!(reason);
                    row["source"] = json!(source);
                }
                Some(CloseGround::Exited | CloseGround::Terminal { .. }) | None => {
                    state::set(lane, "status", LaneStatus::Done.word());
                    state::delete(lane, "pending_pr");
                    state::delete(lane, "parked");
                    state::delete(lane, "reservation");
                    // This close is the one writer of both: an earlier
                    // close's reason, which a relaunch keeps, never outlives
                    // a release.
                    state::delete(lane, "kept");
                    state::delete(lane, "kept_mail");
                    if let Some(reason) = intent
                        .obligations
                        .as_ref()
                        .and_then(ObligationRecord::worktree_kept)
                    {
                        state::set(lane, "kept", reason);
                    }
                    if let Some(mail) = intent
                        .obligations
                        .as_ref()
                        .and_then(ObligationRecord::worktree_mail_kept)
                    {
                        state::set(lane, "kept_mail", mail);
                    }
                    row["text"] = json!(format!("lane closed; intent {}", intent.id));
                    if let Some(CloseGround::Terminal { verdict, source }) = &intent.close {
                        row["verdict"] = serde_json::to_value(verdict)?;
                        row["source"] = json!(source);
                    }
                }
            }
            state::array_mut(path, doc, "fleet_log")?.push(row);
            recorded.lane = Some(Box::new(lane_at(path, doc, index)?));
        }
        Outcome::Failed | Outcome::Unconfirmed | Outcome::NotStarted => {}
    }
    Ok(())
}

#[allow(
    clippy::disallowed_methods,
    reason = "the rows hold owned children and read them directly, and wait on real time for them"
)]
#[cfg(test)]
mod tests {
    use std::fs;
    use std::process::{Child, Command};

    use agent_runtime::process::{self, Identity};
    use agent_runtime::protocol::Outcome;
    use agent_runtime::reading::Reading;
    use serde_json::{Value, json};

    use super::super::testing::*;
    use super::*;
    use crate::error::Error;
    use crate::ops::occupancy::{ChargeReason, ChargeSource};
    use crate::ops::{Effect, Report, Request, apply_on};
    use crate::state::{self, EffectOp, LaneStatus, Phase, fixtures};

    #[test]
    fn launch_lane_writes_the_legacy_record_and_the_intent_then_reconciles() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let applied = apply_on(&path, &launch_full("KEN-4468"), &env(), LOCK, &host()).unwrap();
        let Report::LaunchLane(l) = &applied.report else {
            panic!()
        };
        assert_eq!(l.lane.status, LaneStatus::Preparing);
        assert_eq!(l.lane.launched_at.as_deref(), Some("2026-01-29T15:20:00Z"));
        assert_eq!(l.lane.running_at, None);
        assert_eq!(
            l.lane.harness.as_deref(),
            Some("claude"),
            "a first launch records it"
        );
        assert_eq!(l.lane.account.as_deref(), Some("/a/a1"));
        assert_eq!(l.admission.cap, 4);
        assert_eq!(
            l.admission.occupancy, 0,
            "the fixture's done lane charges nothing"
        );
        let Effect::Persisted { intent } = &l.effect else {
            panic!("{:?}", l.effect)
        };
        // The id is the op, the target and the call's own stamp.
        assert_eq!(intent.id, "launch-lane:KEN-4468:1769700000123456789-4242");
        assert_eq!(intent.outcome, Outcome::NotStarted);
        assert_eq!(intent.lane_since.as_deref(), Some("2026-01-29T15:20:00Z"));
        assert_eq!(
            intent.selection,
            Some(Selection {
                harness: "claude".into(),
                account: Some("/a/a1".into()),
                model: Some("claude-opus-5-5".into()),
                effort: Some("high".into()),
            })
        );
        // The appended record has `lane_record_write`'s keys in its order.
        let record = lane_doc(&path, "KEN-4468");
        assert_eq!(
            keys(&record),
            [
                "item",
                "tracker",
                "repo",
                "harness",
                "window",
                "account",
                "host",
                "kind",
                "mail_root",
                "surface",
                "model",
                "effort",
                "session_id",
                "session_since",
                "launched_at",
                "running_at",
                "status",
                "over_cap",
                "launch",
                "touched",
                "in_scope"
            ]
        );
        assert_eq!(record["kind"], Value::from("local"));
        assert_eq!(record["surface"], Value::from("tmux"));
        assert_eq!(record["repo"], Value::Null);
        // The admission's sets, judged on an item naming no Location: empty,
        // and no obligation key where none was recorded.
        assert_eq!(record["touched"], json!([]));
        assert_eq!(record["in_scope"], json!([]));
        assert!(record.get("rebase").is_none());
        let body = fleet(&path);
        assert_eq!(body.lanes.len(), 2);
        assert_eq!(body.intents.len(), 1);
        // The repeat finds the open intent and creates nothing; its own
        // preparing row is the one charge it reports.
        let again = run(&path, &launch_full("KEN-4468")).unwrap();
        let Report::LaunchLane(l) = &again.report else {
            panic!()
        };
        assert!(matches!(&l.effect, Effect::Reconciled { intent: i } if i.id == intent.id));
        assert_eq!(
            l.admission.occupancy, 0,
            "the lane's own row is the one replaced"
        );
        let body = fleet(&path);
        assert_eq!(body.intents.len(), 1);
        assert_eq!(body.lanes.len(), 2);
    }

    /// Finding 5, probe P12, and decision 37: a parked lane relaunches;
    /// only `preparing` and `running` refuse.
    #[test]
    fn launch_lane_refuses_only_a_preparing_or_running_lane() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let rows = [
            (LaneStatus::Preparing, Some("lane-live")),
            (LaneStatus::Running, Some("lane-live")),
            (LaneStatus::Parked, None),
            (LaneStatus::Stopped, None),
            (LaneStatus::Done, None),
        ];
        for (status, refusal) in rows {
            fs::write(
                &path,
                fixtures::FLEET.replacen("\"done\"", &format!("\"{}\"", status.word()), 1),
            )
            .unwrap();
            let result = run(&path, &launch("KEN-4437"));
            match refusal {
                Some(key) => {
                    let err = result.unwrap_err();
                    assert_eq!(err.key(), key, "{}", status.word());
                    assert!(matches!(err, Error::LaneLive { status: s, .. } if s == status));
                    assert!(fleet(&path).intents.is_empty(), "{}", status.word());
                }
                None => {
                    result.unwrap();
                    let body = fleet(&path);
                    assert_eq!(body.lanes.len(), 1, "{}", status.word());
                    assert_eq!(body.lanes[0].status, LaneStatus::Preparing);
                    assert_eq!(body.intents.len(), 1);
                }
            }
        }
    }

    /// Decision 57: a lane launch naming a non-local `kind` or a non-tmux
    /// `surface` is refused before any intent persists; the one launch route
    /// is a local tmux window.
    #[test]
    fn launch_lane_refuses_a_non_local_kind_or_surface() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let before = fs::read_to_string(&path).unwrap();
        let rows: [(Option<&str>, Option<&str>); 3] = [
            (Some("ssh"), None),
            (None, Some("gui")),
            (Some("managed-cloud"), Some("gui")),
        ];
        for (kind, surface) in rows {
            let req = Request::LaunchLane(Box::new(LaunchLane {
                kind: kind.map(str::to_owned),
                surface: surface.map(str::to_owned),
                ..launch_fields("KEN-9")
            }));
            let err = run(&path, &req).unwrap_err();
            assert_eq!(err.key(), "host-unsupported", "{kind:?} {surface:?}");
        }
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            before,
            "no intent persisted on a refused host"
        );
        // `local`/`tmux` named explicitly is admitted.
        let req = Request::LaunchLane(Box::new(LaunchLane {
            kind: Some("local".into()),
            surface: Some("tmux".into()),
            ..launch_fields("KEN-9")
        }));
        assert!(run(&path, &req).is_ok());
    }

    /// A child this test holds: its pid and start are a live identity the
    /// kernel answers for, and nobody else's while it is held unreaped.
    struct Held(Child);

    impl Held {
        fn sleep() -> Held {
            Held(Command::new("sleep").arg("60").spawn().expect("sleep"))
        }

        fn identity(&self) -> Identity {
            match process::identity(self.0.id()) {
                Reading::Live(id) => id,
                other => panic!("a held child reads live: {other:?}"),
            }
        }

        /// End the child and read it until the kernel answers gone; it is
        /// held unreaped, so its pid is nobody else's.
        fn end(&mut self) {
            self.0.kill().unwrap();
            let id = Identity {
                pid: self.0.id(),
                start: String::new(),
            };
            for _ in 0..200 {
                if process::identity(id.pid) == Reading::Gone {
                    return;
                }
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            panic!("the ended child never read gone");
        }
    }

    impl Drop for Held {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    /// The production host: the kernel's own readers, no legacy store.
    fn kernel(cap: u32) -> Host<'static> {
        Host {
            lane_cap: cap,
            claim_store: None,
            still_runs: &process::still_runs,
            pane_foreground: &no_pane,
            admission: Some(no_reads()),
        }
    }

    /// The fleet fixture with its lanes replaced by `lanes`, each a lane
    /// record document, and no intent standing.
    fn fleet_with(path: &Path, lanes: &[Value]) {
        let mut doc = object(path);
        doc.insert("lanes".into(), Value::Array(lanes.to_vec()));
        doc.insert("intents".into(), Value::Array(Vec::new()));
        fs::write(
            path,
            serde_json::to_string_pretty(&Value::Object(doc)).unwrap(),
        )
        .unwrap();
    }

    fn record(item: &str, status: &str, identity: Option<&Identity>) -> Value {
        let launch = match identity {
            Some(id) => json!({"pane": "%7", "server": 41020, "pid": id.pid, "start": id.start}),
            None => Value::Null,
        };
        json!({
            "item": item,
            "harness": "claude",
            "window": format!("fleet:{item}"),
            "mail_root": format!("/w/{item}"),
            "session_since": "2026-01-29T15:00:00Z",
            "launched_at": "2026-01-29T15:00:00Z",
            "status": status,
            "launch": launch,
            "pending_pr": {"pr": 5814, "repo": "o/r", "head": "abc"},
            "recovery": {"cwd": format!("/w/{item}"), "flags": "", "refresh": true},
            "cycles": 2,
        })
    }

    fn charges(admission: &Occupancy) -> Vec<(String, ChargeReason)> {
        admission
            .charges
            .iter()
            .map(|c| {
                let source = match &c.source {
                    ChargeSource::Lane { item } => item.clone(),
                    ChargeSource::Claim { file } | ChargeSource::Reservation { file } => {
                        file.clone()
                    }
                };
                (source, c.reason)
            })
            .collect()
    }

    /// Decision 97 at the cap, against processes this test holds: a lane
    /// whose recorded harness runs charges a slot and refuses the next lane
    /// at a cap of one; the same lane with its harness ended charges nothing
    /// though its status, pane and pending return still stand, so the next
    /// lane is admitted and every retained field of the ended lane is left
    /// as it was; a stopped lane whose harness still runs holds its slot and
    /// refuses its own relaunch; `over_cap` admits past the cap and is
    /// recorded.
    #[test]
    fn the_cap_charges_live_harnesses_and_releases_ended_attempts() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let mut harness = Held::sleep();
        let id = harness.identity();
        fleet_with(&path, &[record("KEN-A", "running", Some(&id))]);
        let before = lane_doc(&path, "KEN-A");

        let err = apply_on(&path, &launch("KEN-B"), &env(), LOCK, &kernel(1)).unwrap_err();
        assert_eq!(err.key(), "cap-reached");
        assert_eq!(
            err.fields(),
            [
                ("occupancy".to_owned(), "1".to_owned()),
                ("cap".to_owned(), "1".to_owned()),
                ("lanes".to_owned(), "1".to_owned()),
                ("claims".to_owned(), "0".to_owned())
            ]
        );
        assert_eq!(
            fleet(&path).lanes.len(),
            1,
            "a refused launch writes nothing"
        );

        // Between turns the harness sleeps at its barrier: still live, still
        // one slot.
        let err = apply_on(&path, &launch("KEN-B"), &env(), LOCK, &kernel(1)).unwrap_err();
        assert_eq!(err.key(), "cap-reached");

        // The attempt ends: its record reads running with its pane and its
        // pending return, and charges nothing.
        harness.end();
        let applied = apply_on(&path, &launch("KEN-B"), &env(), LOCK, &kernel(1)).unwrap();
        let Report::LaunchLane(l) = &applied.report else {
            panic!()
        };
        assert_eq!(l.admission.occupancy, 0);
        assert_eq!(l.admission.cap, 1);
        assert!(l.admission.charges.is_empty());
        assert_eq!(l.lane.status, LaneStatus::Preparing);
        assert_eq!(
            lane_doc(&path, "KEN-A"),
            before,
            "the ended lane keeps every field: status, pane, pending return, recovery, counters"
        );

        // The committed preparing row charges the cap: a third lane meets it.
        let err = apply_on(&path, &launch("KEN-C"), &env(), LOCK, &kernel(1)).unwrap_err();
        assert_eq!(err.key(), "cap-reached");
        let Report::LaunchLane(l) = apply_on(
            &path,
            &Request::LaunchLane(Box::new(LaunchLane {
                over_cap: Some("fleet".into()),
                ..launch_fields("KEN-C")
            })),
            &env(),
            LOCK,
            &kernel(1),
        )
        .unwrap()
        .report
        else {
            panic!()
        };
        assert_eq!(l.admission.occupancy, 1);
        assert_eq!(
            charges(&l.admission),
            [("KEN-B".to_owned(), ChargeReason::Preparing)]
        );
        assert_eq!(l.lane.over_cap.as_deref(), Some("fleet"));

        // A stopped lane whose harness still runs: a returned turn did not
        // end it. It holds its slot, and its own relaunch is refused rather
        // than doubling it.
        let mut live = Held::sleep();
        let live_id = live.identity();
        fleet_with(&path, &[record("KEN-D", "stopped", Some(&live_id))]);
        let err = apply_on(&path, &launch("KEN-E"), &env(), LOCK, &kernel(1)).unwrap_err();
        assert_eq!(err.key(), "cap-reached");
        let err = apply_on(&path, &launch("KEN-D"), &env(), LOCK, &kernel(4)).unwrap_err();
        assert_eq!(err.key(), "harness-live");
        assert_eq!(err.fields()[1], ("pid".to_owned(), live_id.pid.to_string()));
        live.end();
        let Report::LaunchLane(l) = apply_on(&path, &launch("KEN-D"), &env(), LOCK, &kernel(1))
            .unwrap()
            .report
        else {
            panic!()
        };
        assert_eq!(
            l.admission.occupancy, 0,
            "the relaunch replaces its own lane"
        );
    }

    /// The report's five stopped attempts, each with a surviving window and
    /// no reservation, beside N-1 live lanes at cap N: occupancy is N-1, not
    /// N+4, and the independent candidate is admitted, committed as the Nth
    /// slot, the cap unchanged.
    #[test]
    fn normal_admission_at_cap_n_ignores_stopped_attempts_with_empty_windows() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let live: Vec<Held> = (0..3).map(|_| Held::sleep()).collect();
        let mut ended: Vec<Held> = (0..5).map(|_| Held::sleep()).collect();
        let mut lanes: Vec<Value> = live
            .iter()
            .enumerate()
            .map(|(n, h)| record(&format!("KEN-L{n}"), "running", Some(&h.identity())))
            .collect();
        lanes.extend(
            ended
                .iter()
                .enumerate()
                .map(|(n, h)| record(&format!("KEN-S{n}"), "stopped", Some(&h.identity()))),
        );
        for h in &mut ended {
            h.end();
        }
        fleet_with(&path, &lanes);
        let Report::LaunchLane(l) = apply_on(&path, &launch("KEN-N"), &env(), LOCK, &kernel(4))
            .unwrap()
            .report
        else {
            panic!()
        };
        assert_eq!(l.admission.occupancy, 3);
        assert_eq!(
            charges(&l.admission),
            [
                ("KEN-L0".to_owned(), ChargeReason::Live),
                ("KEN-L1".to_owned(), ChargeReason::Live),
                ("KEN-L2".to_owned(), ChargeReason::Live),
            ]
        );
        // Committed: the next candidate meets the cap.
        let err = apply_on(&path, &launch("KEN-O"), &env(), LOCK, &kernel(4)).unwrap_err();
        assert_eq!(err.key(), "cap-reached");
        assert_eq!(err.fields()[0], ("occupancy".to_owned(), "4".to_owned()));
    }

    /// A planted reader standing in for a kernel that cannot answer: the
    /// unreadable identity protects its slot as unknown and refuses the next
    /// lane; the own lane whose reading is unknown refuses its relaunch
    /// rather than starting a second harness over it.
    #[test]
    fn an_unreadable_identity_protects_its_slot_and_its_lane() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let id = Identity {
            pid: 4242,
            start: "ticks:42".into(),
        };
        fleet_with(&path, &[record("KEN-U", "running", Some(&id))]);
        let unread = |_: &Identity| Reading::Unreadable {
            cause: "stat-unreadable",
        };
        let host = Host {
            lane_cap: 1,
            claim_store: None,
            admission: Some(no_reads()),
            still_runs: &unread,
            pane_foreground: &no_pane,
        };
        let err = apply_on(&path, &launch("KEN-V"), &env(), LOCK, &host).unwrap_err();
        assert_eq!(err.key(), "cap-reached");
        fleet_with(&path, &[record("KEN-U", "stopped", Some(&id))]);
        let err = apply_on(&path, &launch("KEN-U"), &env(), LOCK, &host).unwrap_err();
        assert_eq!(err.key(), "harness-unreadable");
        assert_eq!(
            err.fields()[2],
            ("cause".to_owned(), "stat-unreadable".to_owned())
        );
        assert!(fleet(&path).intents.is_empty());
    }

    /// Decision 97's deliberate hold and its release: a stopped lane with a
    /// `resume` reservation charges until its term under an injected clock
    /// and not at or after it; `release-lane` bound to the attempt drops it,
    /// the repeat is a no-op, and a release bound to an earlier attempt
    /// refuses and changes nothing; a relaunch drops the hold it replaces;
    /// a reservation whose term is not after the clock is refused.
    #[test]
    fn a_reservation_holds_to_its_term_and_releases_once_for_its_attempt() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        fleet_with(&path, &[record("KEN-R", "stopped", None)]);
        let until = "2026-01-29T16:00:00Z";
        let until_secs = clock::epoch_secs(until).unwrap();
        let reserve = Request::ReserveLane(ReserveLane {
            item: "KEN-R".into(),
            reason: "resume".into(),
            until: until.into(),
        });
        let at = |secs: u64| Env {
            now_secs: secs,
            ..env()
        };
        let err = apply_on(&path, &reserve, &at(until_secs), LOCK, &kernel(1)).unwrap_err();
        assert_eq!(err.key(), "reservation-invalid");
        let Report::ReserveLane(r) =
            apply_on(&path, &reserve, &at(until_secs - 600), LOCK, &kernel(1))
                .unwrap()
                .report
        else {
            panic!()
        };
        assert_eq!(
            r.lane.reservation,
            Some(Reservation {
                reason: "resume".into(),
                until: until.into()
            })
        );
        let occupancy_at = |secs: u64| {
            let err = apply_on(&path, &launch("KEN-X"), &at(secs), LOCK, &kernel(1));
            match err {
                Err(Error::CapReached { occupancy, .. }) => occupancy,
                Err(other) => panic!("{other}"),
                Ok(_) => 0,
            }
        };
        assert_eq!(occupancy_at(until_secs - 1), 1, "held before its term");
        assert_eq!(occupancy_at(until_secs), 0, "over at its term");
        // The admitted KEN-X charges from here; judge the release on its own.
        fleet_with(&path, &[record("KEN-R", "stopped", None)]);
        apply_on(&path, &reserve, &at(until_secs - 600), LOCK, &kernel(1)).unwrap();
        let release = |since: &str| {
            Request::ReleaseLane(ReleaseLane {
                item: "KEN-R".into(),
                session_since: since.into(),
            })
        };
        let err = apply_on(
            &path,
            &release("2026-01-01T00:00:00Z"),
            &at(until_secs - 600),
            LOCK,
            &kernel(1),
        )
        .unwrap_err();
        assert_eq!(err.key(), "attempt-stale");
        assert!(
            lane(&path, "KEN-R").reservation.is_some(),
            "a stale release changes nothing"
        );
        let Report::ReleaseLane(r) = apply_on(
            &path,
            &release("2026-01-29T15:00:00Z"),
            &at(until_secs - 600),
            LOCK,
            &kernel(1),
        )
        .unwrap()
        .report
        else {
            panic!()
        };
        assert!(r.released_now);
        assert_eq!(r.lane.reservation, None);
        assert_eq!(occupancy_at(until_secs - 600), 0);
        fleet_with(&path, &[record("KEN-R", "stopped", None)]);
        let Report::ReleaseLane(r) = apply_on(
            &path,
            &release("2026-01-29T15:00:00Z"),
            &at(until_secs - 600),
            LOCK,
            &kernel(1),
        )
        .unwrap()
        .report
        else {
            panic!()
        };
        assert!(!r.released_now, "the repeat is a no-op");
        // A relaunch takes the slot itself and drops the hold it replaces.
        apply_on(&path, &reserve, &at(until_secs - 600), LOCK, &kernel(1)).unwrap();
        apply_on(
            &path,
            &launch("KEN-R"),
            &at(until_secs - 600),
            LOCK,
            &kernel(1),
        )
        .unwrap();
        let after = lane_doc(&path, "KEN-R");
        assert!(!after.contains_key("reservation"));
    }

    /// Decision 108: a stopped lane whose parent is gone but whose detached
    /// wake turn still runs holds its slot by that wake and refuses its own
    /// relaunch `harness-live` naming the wake's pid, so no second harness
    /// starts beside owned execution; an unreadable wake refuses
    /// `harness-unreadable`; with the wake ended the relaunch is admitted,
    /// its own record's launch and reservation left out of the count.
    #[test]
    fn a_relaunch_beside_a_live_wake_is_refused_and_the_wake_charges() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let mut parent = Held::sleep();
        let parent_id = parent.identity();
        let mut wake = Held::sleep();
        let wake_id = wake.identity();
        parent.end();
        let mut rec = record("KEN-W", "stopped", Some(&parent_id));
        rec["wake"] = json!({"pid": wake_id.pid, "start": wake_id.start});
        rec["reservation"] = json!({"reason": "resume", "until": "2027-01-01T00:00:00Z"});
        fleet_with(&path, &[rec.clone()]);
        let before = fs::read_to_string(&path).unwrap();
        let err = apply_on(&path, &launch("KEN-X"), &env(), LOCK, &kernel(1)).unwrap_err();
        assert_eq!(err.key(), "cap-reached");
        let err = apply_on(&path, &launch("KEN-W"), &env(), LOCK, &kernel(4)).unwrap_err();
        assert_eq!(err.key(), "harness-live");
        assert_eq!(err.fields()[1], ("pid".to_owned(), wake_id.pid.to_string()));
        let unread = |id: &Identity| {
            if *id == wake_id {
                Reading::Unreadable {
                    cause: "stat-unreadable",
                }
            } else {
                process::still_runs(id)
            }
        };
        let unreadable = Host {
            still_runs: &unread,
            ..kernel(4)
        };
        let err = apply_on(&path, &launch("KEN-W"), &env(), LOCK, &unreadable).unwrap_err();
        assert_eq!(err.key(), "harness-unreadable");
        assert_eq!(err.fields()[1], ("pid".to_owned(), wake_id.pid.to_string()));
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            before,
            "refusals write nothing"
        );
        wake.end();
        let Report::LaunchLane(l) = apply_on(&path, &launch("KEN-W"), &env(), LOCK, &kernel(1))
            .unwrap()
            .report
        else {
            panic!()
        };
        assert_eq!(
            l.admission.occupancy, 0,
            "the own record's reservation and launch are what the relaunch replaces"
        );
        assert_eq!(l.lane.status, LaneStatus::Preparing);
        assert!(!lane_doc(&path, "KEN-W").contains_key("reservation"));
    }

    /// The account boundary (step4-map A11, decision 75): a relaunch naming
    /// the account its wall spent is refused, compared on the resolved
    /// directory; another account is admitted and the intent records the
    /// spent one.
    #[test]
    fn a_wall_relaunch_refuses_the_spent_account() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let accounts = dir.path().join("accounts");
        fs::create_dir_all(accounts.join("a1")).unwrap();
        fs::create_dir_all(accounts.join("a2")).unwrap();
        std::os::unix::fs::symlink(accounts.join("a1"), accounts.join("link")).unwrap();
        let spent = accounts.join("a1").display().to_string();
        let relaunch = |account: &Path| {
            Request::LaunchLane(Box::new(LaunchLane {
                account: Some(format!("{}/", account.display())),
                exclude_account: Some(spent.clone()),
                ..launch_fields("KEN-4437")
            }))
        };
        fs::write(
            &path,
            fixtures::FLEET.replacen("\"status\": \"done\"", "\"status\": \"stopped\"", 1),
        )
        .unwrap();
        let err = run(&path, &relaunch(&accounts.join("link"))).unwrap_err();
        assert_eq!(err.key(), "account-spent");
        assert!(fleet(&path).intents.is_empty());
        let Report::LaunchLane(l) = run(&path, &relaunch(&accounts.join("a2"))).unwrap().report
        else {
            panic!()
        };
        let Effect::Persisted { intent } = &l.effect else {
            panic!()
        };
        assert_eq!(intent.exclude_account.as_deref(), Some(spent.as_str()));
    }

    /// Finding 5, probe P13, and decision 37: a relaunch keeps every field
    /// it does not write, drops `prepare` and `live_display`, and keeps the
    /// key sequence of what it keeps. R-U10 finding 3: the harness, account,
    /// model and effort it was asked for reach the record when the launch
    /// confirms, not at `preparing`. R-U13 finding 4: the confirmation
    /// writes all four as the legacy `running` write does, null where the
    /// request named none, so a claude session is never recorded on the
    /// earlier codex session's account.
    #[test]
    fn a_relaunch_keeps_unwritten_fields_and_its_confirmation_writes_the_whole_selection() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let text = fixtures::FLEET
            .replacen("\"status\": \"done\"", "\"status\": \"stopped\"", 1)
            .replacen("\"kind\": \"local\"", "\"kind\": \"claude-cloud\"", 1)
            .replacen("\"surface\": \"tmux\"", "\"surface\": \"cloud\"", 1)
            .replacen("\"over_cap\": null", "\"over_cap\": \"cloud\"", 1)
            .replacen(
                "\"session_id\": null,\n      \"session_since\"",
                "\"session_id\": \"cloud-7\",\n      \"session_since\"",
                1,
            )
            .replacen(
                "      \"launch\": {",
                "      \"prepare\": {\"since\": \"2026-10-24T18:00:00Z\", \"log\": \"/tmp/p.log\", \"reason\": \"sandbox\", \"pid\": 4100},\n      \"live_display\": true,\n      \"launch\": {",
                1,
            );
        fs::write(&path, &text).unwrap();
        let before = lane_doc(&path, "KEN-4437");
        assert!(before.contains_key("prepare") && before.contains_key("live_display"));
        let id = intend(&path, &launch("KEN-4437"));
        let after = lane_doc(&path, "KEN-4437");
        let view = lane(&path, "KEN-4437");
        assert_eq!(view.status, LaneStatus::Preparing);
        assert_eq!(view.kind.as_deref(), Some("claude-cloud"));
        assert_eq!(view.surface.as_deref(), Some("cloud"));
        assert_eq!(view.over_cap.as_deref(), Some("cloud"));
        assert_eq!(view.account.as_deref(), Some("/home/u/.codex-lanes/c2"));
        assert_eq!(view.model.as_deref(), Some("gpt-5.5-codex"));
        assert_eq!(view.effort.as_deref(), Some("high"));
        assert_eq!(view.tracker.as_deref(), Some("linear"));
        assert_eq!(view.session_id.as_deref(), Some("cloud-7"));
        assert_eq!(view.launched_at.as_deref(), Some("2026-10-24T18:02:11Z"));
        assert_eq!(view.session_since.as_deref(), Some("2026-01-29T15:20:00Z"));
        assert_eq!(
            view.harness.as_deref(),
            Some("codex"),
            "the record's until the launch confirms"
        );
        assert_eq!(view.mail_root.as_deref(), Some("/w/KEN-4437"));
        assert_eq!(view.running_at, None);
        assert_eq!(view.launch, None);
        assert_eq!(view.extra["tier"], Value::from("small"));
        assert_eq!(view.extra["recovery"]["refresh"], Value::Bool(true));
        assert!(!after.contains_key("prepare"));
        assert!(!after.contains_key("live_display"));
        let expected: Vec<String> = keys(&before)
            .into_iter()
            .filter(|k| k != "prepare" && k != "live_display")
            .collect();
        assert_eq!(keys(&after), expected, "kept keys keep their sequence");
        // The confirmed launch writes the whole selection: the harness it
        // was asked for, and null for the account, model and effort the
        // request left out, as `lane_record_write` does at `running`
        // (`open-terminal`, `map_values(if . == "" then null …)`). A claude
        // session after a codex one carries no codex account.
        run(&path, &outcome(&id, Outcome::Confirmed)).unwrap();
        let view = lane(&path, "KEN-4437");
        assert_eq!(view.status, LaneStatus::Running);
        assert_eq!(view.harness.as_deref(), Some("claude"));
        let doc = lane_doc(&path, "KEN-4437");
        for key in ["account", "model", "effort"] {
            assert_eq!(doc.get(key), Some(&Value::Null), "{key} written null");
        }
        assert_eq!(keys(&doc), expected, "nulled keys keep their place");
        // A request that supplies a field writes it, at `running` too.
        fs::write(&path, &text).unwrap();
        let id = intend(&path, &launch_full("KEN-4437"));
        let view = lane(&path, "KEN-4437");
        assert_eq!(view.account.as_deref(), Some("/home/u/.codex-lanes/c2"));
        assert_eq!(view.model.as_deref(), Some("gpt-5.5-codex"));
        assert_eq!(view.harness.as_deref(), Some("codex"));
        run(&path, &outcome(&id, Outcome::Confirmed)).unwrap();
        let view = lane(&path, "KEN-4437");
        assert_eq!(view.harness.as_deref(), Some("claude"));
        assert_eq!(view.account.as_deref(), Some("/a/a1"));
        assert_eq!(view.model.as_deref(), Some("claude-opus-5-5"));
        assert_eq!(view.effort.as_deref(), Some("high"));
        assert_eq!(view.kind.as_deref(), Some("claude-cloud"), "not supplied");
        // A relaunch that fails leaves the record's harness, account and
        // model as they were: no session of the requested ones ran.
        fs::write(&path, &text).unwrap();
        let id = intend(&path, &launch_full("KEN-4437"));
        run(&path, &outcome(&id, Outcome::Failed)).unwrap();
        let view = lane(&path, "KEN-4437");
        assert_eq!(view.status, LaneStatus::Stopped);
        assert_eq!(view.harness.as_deref(), Some("codex"));
        assert_eq!(view.account.as_deref(), Some("/home/u/.codex-lanes/c2"));
        assert_eq!(view.model.as_deref(), Some("gpt-5.5-codex"));
    }

    /// An adoption binds the lane under an identity the kernel answers live
    /// for, given or kept: a gone one is no execution to adopt and an
    /// unreadable one authorizes nothing, each refused with the file as it
    /// was; a bound lane refuses another running session.
    #[test]
    fn adopt_session_binds_a_prepared_lane_under_a_live_identity_only() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let id = intend(&path, &launch("KEN-4468"));
        run(&path, &outcome(&id, Outcome::Failed)).unwrap();
        let held = Held::sleep();
        let live = held.identity();
        let bound =
            |item: &str, session: &str, launch: LaunchIdentity| adopt(item, session, Some(launch));
        let as_launch = |id: &Identity| LaunchIdentity {
            pane: Some("%11".into()),
            server: Some(41020),
            server_start: None,
            pid: Some(id.pid as u64),
            start: Some(id.start.clone()),
        };
        let kernel = &kernel(4);
        assert_eq!(
            apply_on(
                &path,
                &bound("KEN-none", "s1", as_launch(&live)),
                &env(),
                LOCK,
                kernel
            )
            .unwrap_err()
            .key(),
            "lane-missing"
        );
        assert_eq!(
            apply_on(
                &path,
                &bound("KEN-4437", "s1", as_launch(&live)),
                &env(),
                LOCK,
                kernel
            )
            .unwrap_err()
            .key(),
            "lane-done"
        );
        let before = fs::read_to_string(&path).unwrap();
        let gone = Identity {
            pid: live.pid,
            start: "ticks:0".into(),
        };
        let err = apply_on(
            &path,
            &bound("KEN-4468", "s1", as_launch(&gone)),
            &env(),
            LOCK,
            kernel,
        )
        .unwrap_err();
        assert_eq!(err.key(), "identity-gone");
        assert_eq!(err.fields()[1], ("pid".to_owned(), live.pid.to_string()));
        let unread = |_: &Identity| Reading::Unreadable {
            cause: "stat-unreadable",
        };
        let unreadable = Host {
            still_runs: &unread,
            ..super::super::testing::host()
        };
        let err = apply_on(
            &path,
            &bound("KEN-4468", "s1", as_launch(&live)),
            &env(),
            LOCK,
            &unreadable,
        )
        .unwrap_err();
        assert_eq!(err.key(), "harness-unreadable");
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            before,
            "refusals write nothing"
        );
        let applied = apply_on(
            &path,
            &bound("KEN-4468", "s1", as_launch(&live)),
            &env(),
            LOCK,
            kernel,
        )
        .unwrap();
        let Report::AdoptSession(a) = applied.report else {
            panic!()
        };
        assert!(a.adopted_now);
        assert_eq!(a.lane.status, LaneStatus::Running);
        assert_eq!(a.lane.running_at.as_deref(), Some("2026-01-29T15:20:00Z"));
        assert_eq!(a.lane.launch.as_ref().unwrap().pid, Some(live.pid as u64));
        let Report::AdoptSession(b) = apply_on(
            &path,
            &bound("KEN-4468", "s1", as_launch(&live)),
            &env(),
            LOCK,
            kernel,
        )
        .unwrap()
        .report
        else {
            panic!()
        };
        assert!(!b.adopted_now);
        let err = apply_on(
            &path,
            &bound("KEN-4468", "s2", as_launch(&live)),
            &env(),
            LOCK,
            kernel,
        )
        .unwrap_err();
        assert!(matches!(
            err,
            Error::LaneLive {
                status: LaneStatus::Running,
                ..
            }
        ));
    }

    /// Finding 8, probe P14, and decision 37: adopting a parked lane runs
    /// the legacy `unpark`, and adopting without `launch` keeps the recorded
    /// identity, which must read live.
    #[test]
    fn adopting_a_parked_lane_unparks_it_and_keeps_the_launch_when_none_is_passed() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let held = Held::sleep();
        let live = held.identity();
        let text = fixtures::FLEET
            .replacen("\"status\": \"done\"", "\"status\": \"parked\"", 1)
            .replacen(
                "      \"launch\": {",
                "      \"parked\": {\"pr\": 5814, \"repo\": \"bmethod/kendex\", \"head\": \"abc123\", \"until_pr\": 5820, \"at\": \"2026-10-24T20:00:00Z\"},\n      \"reservation\": {\"reason\": \"resume\", \"until\": \"2027-01-01T00:00:00Z\"},\n      \"launch\": {",
                1,
            )
            .replacen("\"pid\": 42210", &format!("\"pid\": {}", live.pid), 1)
            .replacen("\"start\": \"ticks:9930001\"", &format!("\"start\": \"{}\"", live.start), 1);
        fs::write(&path, &text).unwrap();
        let before = lane_doc(&path, "KEN-4437");
        apply_on(
            &path,
            &adopt("KEN-4437", "s9", None),
            &env(),
            LOCK,
            &kernel(4),
        )
        .unwrap();
        let after = lane_doc(&path, "KEN-4437");
        assert_eq!(after["status"], Value::from("running"));
        assert_eq!(after["session_id"], Value::from("s9"));
        assert!(!after.contains_key("parked"));
        assert!(
            !after.contains_key("reservation"),
            "the harness charges from here"
        );
        assert_eq!(
            after["pending_pr"],
            json!({"pr": 5814, "repo": "bmethod/kendex", "head": "abc123", "until_pr": 5820})
        );
        assert_eq!(
            after["pauses"],
            json!([{"from": "2026-10-24T20:00:00Z", "to": "2026-01-29T15:20:00Z", "cause": "parked"}])
        );
        assert_eq!(after["launch"], before["launch"], "the wake keeps `launch`");
        assert_eq!(after["launch"]["pid"], Value::from(live.pid));
        // Only `parked` and `reservation` left the sequence; `pending_pr`
        // and `pauses` appended.
        let mut expected: Vec<String> = keys(&before)
            .into_iter()
            .filter(|k| k != "parked" && k != "reservation")
            .collect();
        expected.extend(["pauses".to_owned(), "pending_pr".to_owned()]);
        assert_eq!(keys(&after), expected);
    }

    /// Decision 62: an effect's phase is written onto its open intent before
    /// the effect waits, a later phase replaces it, and a closed intent
    /// takes none.
    #[test]
    fn record_phase_writes_the_open_intent_s_phase_and_refuses_a_closed_one() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        fs::write(&path, fixtures::FLEET).unwrap();
        let id = intend(&path, &transfer(expected()));
        let opened = state::OpenedPane {
            pane: "%12".into(),
            server: 41020,
            server_start: 1_769_590_000,
            server_process_start: Some("ticks:7".into()),
            socket: "/tmp/tmux-1000/default".into(),
            since_ms: 1,
            brief: Some("/h/handoff.md".into()),
            session_id: Some("0f6e".into()),
            baseline: Vec::new(),
            identity: None,
        };
        let session = state::BoundSession {
            session_id: "0f6e".into(),
            file: "/h/projects/-w/0f6e.jsonl".into(),
        };
        let phase = |phase: Phase| {
            Request::RecordPhase(RecordPhase {
                intent_id: id.clone(),
                phase,
            })
        };
        let applied = run(
            &path,
            &phase(Phase::WindowOpened {
                opened: opened.clone(),
            }),
        )
        .unwrap();
        let Report::RecordPhase(p) = &applied.report else {
            panic!()
        };
        let window_opened = Some(Phase::WindowOpened {
            opened: opened.clone(),
        });
        assert_eq!(p.intent.phase, window_opened);
        let stored = fleet(&path)
            .intents
            .into_iter()
            .find(|i| i.id == id)
            .unwrap();
        assert_eq!(stored.phase, window_opened);
        let row = object(&path)["intents"][0]["phase"].clone();
        assert_eq!(row["phase"], json!("window-opened"));
        assert_eq!(row["pane"], json!("%12"));
        assert_eq!(row["brief"], json!("/h/handoff.md"));
        run(
            &path,
            &phase(Phase::Delivered {
                opened: opened.clone(),
                turns_before: 2,
                session: session.clone(),
            }),
        )
        .unwrap();
        let stored = fleet(&path)
            .intents
            .into_iter()
            .find(|i| i.id == id)
            .unwrap();
        assert_eq!(
            stored.phase,
            Some(Phase::Delivered {
                opened: opened.clone(),
                turns_before: 2,
                session,
            })
        );
        let row = object(&path)["intents"][0]["phase"].clone();
        assert_eq!(row["session"]["file"], json!("/h/projects/-w/0f6e.jsonl"));
        assert_eq!(row["server_process_start"], json!("ticks:7"));
        run(&path, &outcome(&id, Outcome::Failed)).unwrap();
        let err = run(&path, &phase(Phase::Retired { opened })).unwrap_err();
        assert!(matches!(err, Error::IntentComplete { .. }), "{err:?}");
    }

    /// A close asked for on a lane whose harness read gone persists its
    /// intent on the `exited` ground and leaves the status; the repeat
    /// reconciles.
    #[test]
    fn close_owned_resources_persists_the_intent_and_leaves_the_status() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        assert_eq!(
            run(&path, &close("KEN-4437")).unwrap_err().key(),
            "lane-done"
        );
        assert_eq!(
            run(&path, &close("KEN-x")).unwrap_err().key(),
            "lane-missing"
        );
        let id = intend(&path, &launch("KEN-4468"));
        run(&path, &outcome(&id, Outcome::Confirmed)).unwrap();
        let applied = run(&path, &close("KEN-4468")).unwrap();
        let Report::CloseOwnedResources(c) = &applied.report else {
            panic!()
        };
        assert_eq!(c.lane.status, LaneStatus::Running);
        let Effect::Persisted { intent } = &c.effect else {
            panic!()
        };
        assert_eq!(intent.op, EffectOp::CloseOwnedResources);
        assert_eq!(intent.lane_since.as_deref(), Some("2026-01-29T15:20:00Z"));
        assert_eq!(intent.selection, None, "a close carries no selection");
        assert_eq!(intent.close, Some(CloseGround::Exited));
        let again = run(&path, &close("KEN-4468")).unwrap();
        let Report::CloseOwnedResources(c) = &again.report else {
            panic!()
        };
        assert!(matches!(&c.effect, Effect::Reconciled { .. }));
        let body = fleet(&path);
        assert_eq!(body.intents.len(), 2);
        assert_eq!(body.lanes[1].status, LaneStatus::Running);
    }

    /// Decision 83's guard: a lane whose recorded harness runs refuses a
    /// bare close `lane-live`, an unreadable one `harness-unreadable`, and
    /// a recorded pane with no identity `lane-live`; `terminal` evidence
    /// admits the close whatever the harness reads, recorded on the intent;
    /// two grounds refuse; a lane with neither identity nor pane reads
    /// exited.
    #[test]
    fn a_close_needs_the_lane_exited_or_terminal_evidence() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let held = Held::sleep();
        let live = held.identity();
        fleet_with(&path, &[record("KEN-W", "running", Some(&live))]);
        let before = fs::read_to_string(&path).unwrap();
        let err = apply_on(&path, &close("KEN-W"), &env(), LOCK, &kernel(4)).unwrap_err();
        assert_eq!(err.key(), "lane-live");
        assert_eq!(err.fields()[1], ("status".to_owned(), "running".to_owned()));
        let unread = |_: &Identity| Reading::Unreadable {
            cause: "stat-unreadable",
        };
        let unreadable = Host {
            still_runs: &unread,
            ..kernel(4)
        };
        let err = apply_on(&path, &close("KEN-W"), &env(), LOCK, &unreadable).unwrap_err();
        assert_eq!(err.key(), "harness-unreadable");
        let both = Request::CloseOwnedResources(CloseOwnedResources {
            item: "KEN-W".into(),
            terminal: Some(Terminal {
                verdict: TerminalVerdict::Completed,
                source: "linear".into(),
            }),
            no_landing: Some(NoLanding {
                reason: "diagnosis".into(),
                source: "overseer".into(),
            }),
        });
        let err = apply_on(&path, &both, &env(), LOCK, &kernel(4)).unwrap_err();
        assert_eq!(err.key(), "close-ground-ambiguous");
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            before,
            "refusals write nothing"
        );
        let terminal = Request::CloseOwnedResources(CloseOwnedResources {
            item: "KEN-W".into(),
            terminal: Some(Terminal {
                verdict: TerminalVerdict::Canceled,
                source: "linear".into(),
            }),
            no_landing: None,
        });
        let Report::CloseOwnedResources(c) = apply_on(&path, &terminal, &env(), LOCK, &kernel(4))
            .unwrap()
            .report
        else {
            panic!()
        };
        let Effect::Persisted { intent } = &c.effect else {
            panic!()
        };
        assert_eq!(
            intent.close,
            Some(CloseGround::Terminal {
                verdict: TerminalVerdict::Canceled,
                source: "linear".into()
            })
        );
        // A recorded pane with no identity is not known exited.
        let mut pane_only = record("KEN-P", "running", None);
        pane_only["launch"] = json!({"pane": "%7", "server": 41020, "pid": null, "start": null});
        fleet_with(&path, &[pane_only]);
        assert_eq!(
            apply_on(&path, &close("KEN-P"), &env(), LOCK, &kernel(4))
                .unwrap_err()
                .key(),
            "lane-live"
        );
        fleet_with(&path, &[record("KEN-N", "running", None)]);
        let Report::CloseOwnedResources(c) =
            apply_on(&path, &close("KEN-N"), &env(), LOCK, &kernel(4))
                .unwrap()
                .report
        else {
            panic!()
        };
        let Effect::Persisted { intent } = &c.effect else {
            panic!()
        };
        assert_eq!(intent.close, Some(CloseGround::Exited));
    }

    /// Finding 8, probe P15: a confirmed close removes `pending_pr`,
    /// `parked` and the reservation, as the legacy `update_status done`
    /// does; its fleet-log row carries the terminal verdict where one was
    /// the ground.
    #[test]
    fn a_confirmed_close_deletes_the_pr_identities() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let text = fixtures::FLEET
            .replacen("\"status\": \"done\"", "\"status\": \"running\"", 1)
            .replacen(
                "      \"launch\": {",
                "      \"pending_pr\": {\"pr\": 5814, \"repo\": \"bmethod/kendex\", \"head\": \"abc123\"},\n      \"parked\": {\"pr\": 5814, \"repo\": \"bmethod/kendex\", \"head\": \"abc123\", \"at\": \"2026-10-24T20:00:00Z\"},\n      \"reservation\": {\"reason\": \"resume\", \"until\": \"2027-01-01T00:00:00Z\"},\n      \"launch\": {",
                1,
            );
        fs::write(&path, &text).unwrap();
        let before = lane_doc(&path, "KEN-4437");
        let terminal = Request::CloseOwnedResources(CloseOwnedResources {
            item: "KEN-4437".into(),
            terminal: Some(Terminal {
                verdict: TerminalVerdict::Completed,
                source: "linear".into(),
            }),
            no_landing: None,
        });
        let id = intend(&path, &terminal);
        run(&path, &outcome(&id, Outcome::Confirmed)).unwrap();
        let after = lane_doc(&path, "KEN-4437");
        assert_eq!(after["status"], Value::from("done"));
        assert!(!after.contains_key("pending_pr"));
        assert!(!after.contains_key("parked"));
        assert!(!after.contains_key("reservation"));
        let expected: Vec<String> = keys(&before)
            .into_iter()
            .filter(|k| k != "pending_pr" && k != "parked" && k != "reservation")
            .collect();
        assert_eq!(keys(&after), expected);
        let log = fleet(&path).fleet_log;
        let row = log.last().unwrap();
        assert_eq!(row["kind"], json!("close"));
        assert_eq!(row["verdict"], json!("completed"));
        assert_eq!(row["source"], json!("linear"));
    }

    /// Decision 98: a close on the `no-landing` disposition retires the
    /// attempt and keeps the item's work: the lane reads stopped, its
    /// pending return, parked record, launch, recovery route and counters
    /// stay, and the fleet log carries the disposition. An unreadable
    /// harness refuses the disposition.
    #[test]
    fn a_no_landing_close_retires_the_attempt_and_keeps_the_item_s_work() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let gone = Identity {
            pid: 2_000_000_000,
            start: "ticks:1".into(),
        };
        let mut rec = record("KEN-D", "running", Some(&gone));
        rec["parked"] = json!({"head": "abc", "repo": "o/r", "at": "2026-10-24T20:00:00Z"});
        fleet_with(&path, &[rec]);
        let before = lane_doc(&path, "KEN-D");
        let disposition = Request::CloseOwnedResources(CloseOwnedResources {
            item: "KEN-D".into(),
            terminal: None,
            no_landing: Some(NoLanding {
                reason: "diagnosis-complete".into(),
                source: "overseer".into(),
            }),
        });
        let unread = |_: &Identity| Reading::Unreadable {
            cause: "stat-unreadable",
        };
        let unreadable = Host {
            still_runs: &unread,
            ..kernel(4)
        };
        assert_eq!(
            apply_on(&path, &disposition, &env(), LOCK, &unreadable)
                .unwrap_err()
                .key(),
            "harness-unreadable"
        );
        let Report::CloseOwnedResources(c) =
            apply_on(&path, &disposition, &env(), LOCK, &kernel(4))
                .unwrap()
                .report
        else {
            panic!()
        };
        let Effect::Persisted { intent } = &c.effect else {
            panic!()
        };
        assert_eq!(
            intent.close,
            Some(CloseGround::NoLanding {
                reason: "diagnosis-complete".into(),
                source: "overseer".into()
            })
        );
        run(&path, &outcome(&intent.id, Outcome::Confirmed)).unwrap();
        let after = lane_doc(&path, "KEN-D");
        assert_eq!(after["status"], json!("stopped"));
        let mut kept = before.clone();
        kept["status"] = json!("stopped");
        assert_eq!(after, kept, "everything but the status is as it was");
        let row = fleet(&path).fleet_log.pop().unwrap();
        assert_eq!(row["kind"], json!("close"));
        assert_eq!(row["disposition"], json!("no-landing"));
        assert_eq!(row["reason"], json!("diagnosis-complete"));
        assert_eq!(row["source"], json!("overseer"));
        // The retired attempt charges nothing; its record is recoverable.
        let Report::LaunchLane(l) = apply_on(&path, &launch("KEN-E"), &env(), LOCK, &kernel(1))
            .unwrap()
            .report
        else {
            panic!()
        };
        assert_eq!(l.admission.occupancy, 0);
    }

    /// `park-lane` records the park `lane-close --park` writes after the
    /// sandbox stop: on a stopped hosted lane, `parked {head, repo, at, pr?,
    /// until_pr?, until_repo?}` with `pending_pr` dropped and the status
    /// parked; a local lane refuses `park-refused reason=local`; a running
    /// lane refuses `lane-live`; a parked lane is left as it is; a given
    /// reservation is written beside it.
    #[test]
    fn park_lane_records_a_stopped_hosted_lane_s_park_and_refuses_a_local_one() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let hosted = |status: &str| {
            let mut rec = record("KEN-H", status, None);
            rec["host"] = json!("fleet-a");
            rec["kind"] = json!("ssh");
            rec
        };
        let park = |reservation: Option<Reservation>| {
            Request::ParkLane(ParkLane {
                item: "KEN-H".into(),
                head: "abc123".into(),
                repo: "o/r".into(),
                pr: Some(5814),
                until_pr: Some(5820),
                until_repo: Some("o/dep".into()),
                reservation,
            })
        };
        fleet_with(&path, &[record("KEN-H", "stopped", None)]);
        let err = run(&path, &park(None)).unwrap_err();
        assert_eq!(err.key(), "park-refused");
        assert_eq!(err.fields()[1], ("reason".to_owned(), "local".to_owned()));
        fleet_with(&path, &[hosted("running")]);
        assert_eq!(run(&path, &park(None)).unwrap_err().key(), "lane-live");
        fleet_with(&path, &[hosted("stopped")]);
        let Report::ParkLane(p) = run(
            &path,
            &park(Some(Reservation {
                reason: "merge-wait".into(),
                until: "2027-01-01T00:00:00Z".into(),
            })),
        )
        .unwrap()
        .report
        else {
            panic!()
        };
        assert!(p.parked_now);
        assert_eq!(p.lane.status, LaneStatus::Parked);
        let after = lane_doc(&path, "KEN-H");
        assert_eq!(
            after["parked"],
            json!({"head": "abc123", "repo": "o/r", "at": "2026-01-29T15:20:00Z", "pr": 5814, "until_pr": 5820, "until_repo": "o/dep"})
        );
        assert!(!after.contains_key("pending_pr"));
        assert_eq!(after["reservation"]["reason"], json!("merge-wait"));
        let Report::ParkLane(p) = run(&path, &park(None)).unwrap().report else {
            panic!()
        };
        assert!(!p.parked_now);
        assert_eq!(
            lane_doc(&path, "KEN-H"),
            after,
            "a parked lane is left as it is"
        );
    }
}
