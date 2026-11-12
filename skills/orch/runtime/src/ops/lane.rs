//! The lane transitions: a lane admitted against the fleet cap and opened
//! `preparing` with its launch intent, a session this runtime did not
//! launch bound to a lane under a confirmed identity, a close asked for on
//! a ground that authorizes it, a park, a reservation and its release, an
//! effect's phase written onto its open intent, and the arms of
//! `record-outcome` that move a lane when its launch or close ends.

use agent_runtime::intent::LaunchIdentity;
use agent_runtime::record::{self, Document};
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use agent_runtime::clock;
use agent_runtime::harness::{Harness, PermissionMeaning};
use agent_runtime::launch::Permission;
use agent_runtime::process::Identity;
use agent_runtime::protocol::Outcome;
use agent_runtime::reading::Reading;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

mod lane_obligations;

pub(super) use lane_obligations::record_lane_progress;
pub use lane_obligations::{
    LaneDischarged, LaneObligation, LaneObligationRecord, RecordLaneProgress, WORKTREE_KEPT,
    WORKTREE_MAIL_KEPT,
};

use super::accounts;
use super::admission::{self, Admission, ScopeRange};
use super::occupancy::{self, CLOUD_KIND, Host, Identities, Occupancy, Read};
use super::{
    Effect, Standing, TargetMoved, lane_at, lane_doc_mut, lanes, open_intent, string_or_null,
};
use crate::error::{Error, Result, RetiredEnd, WalledWindow};
use crate::settings::{CLOUD_LANE_CAP_KEY, LANE_CAP_KEY};
use crate::state::{
    self, CloseGround, Lane, LaneMembers, LaneStatus, Reservation, Selection, TerminalVerdict,
};
use agent_runtime::accounts::{PickAnswer, PickRequest};
use agent_runtime::intent::Intent;
use agent_runtime::intent::{EffectOp, Phase, PrincipalKeys, Role};
use agent_runtime::journal::{self, Env, RecordOutcome, intents};
use agent_runtime::journal::{new_intent, push_intent};

/// Open a lane for an item: judge the fleet cap, write its record as
/// `preparing` and the intent to launch it. On a relaunch every optional
/// field left out keeps the record's value, bar `host` and `kind`, which
/// are always the launch's own, and `harness`, `account`,
/// `model` and `effort` reach the record only when the launch confirms,
/// since the session that runs is the one that confirmed; on a first
/// launch the record carries them from the start. `host` names where the
/// lane runs: nothing for a window on this machine, `claude-cloud` for a
/// cloud session, else a provider's path; `kind` left out follows it
/// (`local`, `claude-cloud`, `ssh`), and `surface` is `tmux`, the one
/// surface a lane has. `exclude_account` is the account a wall spent: a
/// launch whose `account` canonicalizes to it is refused. `over_cap` admits
/// the launch past the cap and is recorded. `judge_account` asks the
/// accounts judge for the named account's room before the admission, the
/// gate on a lane the caller named rather than one a pick answered; left
/// out, the account is taken as a pick's answer, judged already. `refresh`
/// marks a refresh lane, whose brief runs `kendex refresh` or `kendex
/// apply` with `--lane-refresh`: the launch writes the refresh record the
/// drift hooks read. `permission` is the harness's permission word the
/// lane runs under, spelled as agent-runtime's table spells it (one word,
/// or `FLAG VALUE` as two) and recorded on the lane; left out, the launch
/// runs the settings' posture, and a word the table lacks is refused
/// before any intent. `obligation` is the item's accepted lineage, written
/// onto a record that carries none; one that differs from the record's is
/// refused `obligation-conflict` before any intent.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LaunchLane {
    pub item: String,
    pub harness: String,
    pub mail_root: String,
    #[serde(default)]
    pub permission: Option<String>,
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
    pub host: Option<String>,
    #[serde(default)]
    pub surface: Option<String>,
    #[serde(default)]
    pub over_cap: Option<String>,
    #[serde(default)]
    pub exclude_account: Option<String>,
    #[serde(default)]
    pub judge_account: bool,
    #[serde(default)]
    pub refresh: bool,
    /// The opening instruction, read by the harness at its start. Not a
    /// record field: the effect carries it to the launch, and the
    /// admission reads the paths it names.
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
    #[serde(default)]
    pub obligation: Option<Obligation>,
}

/// The item's original obligation as the overseer's accepted launch or
/// transfer mapping states it, recorded as `lanes[].obligation` for the
/// cycle reader: the four keys, each present, the parent pair named
/// together or null together. Nothing else maps it: a tracker's current
/// parent is no original mapping.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "ObligationKeys")]
pub struct Obligation {
    repo: String,
    item: String,
    parent_repo: Option<String>,
    parent_item: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ObligationKeys {
    repo: String,
    item: String,
    // A nullable key the request must still name: serde's own reading
    // of an `Option` would take a missing key as null.
    #[serde(deserialize_with = "Option::deserialize")]
    parent_repo: Option<String>,
    #[serde(deserialize_with = "Option::deserialize")]
    parent_item: Option<String>,
}

impl TryFrom<ObligationKeys> for Obligation {
    type Error = &'static str;

    fn try_from(keys: ObligationKeys) -> std::result::Result<Self, Self::Error> {
        if keys.parent_repo.is_some() != keys.parent_item.is_some() {
            return Err("an obligation names parent_repo and parent_item together or neither");
        }
        Ok(Obligation {
            repo: keys.repo,
            item: keys.item,
            parent_repo: keys.parent_repo,
            parent_item: keys.parent_item,
        })
    }
}

impl LaunchLane {
    /// Where the lane runs, as the record spells it: `host` empty or
    /// `local` is a window on this machine, recorded as no host.
    fn host(&self) -> Option<&str> {
        self.host
            .as_deref()
            .filter(|h| !h.is_empty() && *h != "local")
    }

    /// The host kind the record carries: the request's word, else the one
    /// its host implies.
    fn kind(&self) -> &str {
        match (self.kind.as_deref(), self.host()) {
            (Some(kind), _) => kind,
            (None, None) => "local",
            (None, Some(CLOUD_KIND)) => CLOUD_KIND,
            (None, Some(_)) => "ssh",
        }
    }

    /// The permission word as the launch line takes it, split at its
    /// blanks.
    pub fn permission_words(&self) -> Vec<String> {
        self.permission
            .as_deref()
            .map(|p| p.split_whitespace().map(str::to_owned).collect())
            .unwrap_or_default()
    }

    /// The permission choice as the record carries it: the line's words
    /// joined by one blank, so a relaunch composed from the record (the
    /// model-switch recovery) runs the replacement under the same choice;
    /// `null` where the launch runs the settings' posture.
    fn permission_recorded(&self) -> Value {
        let words = self.permission_words();
        if words.is_empty() {
            Value::Null
        } else {
            Value::from(words.join(" "))
        }
    }

    /// The permission word judged against the harness's table: `Ok` with
    /// the meaning of the word that stands (`None` for no word), `Err` for
    /// a word the table lacks, which no launch line can carry faithfully.
    fn permission_meaning(&self) -> std::result::Result<Option<PermissionMeaning>, ()> {
        let words = self.permission_words();
        if words.is_empty() {
            return Ok(None);
        }
        let Some(harness) = Harness::parse(&self.harness) else {
            return Ok(None);
        };
        match harness.permission_word_in(&words) {
            Some((spelling, meaning)) if spelling.split_whitespace().count() == words.len() => {
                Ok(Some(meaning))
            }
            Some(_) | None => Err(()),
        }
    }

    /// The record's `allow_all`: whether a Copilot lane's line grants the
    /// full allow-all mode, which a policy block can take away; `None` on
    /// every other harness, and where no posture is known to judge by.
    fn allow_all(&self, posture: Option<Permission>) -> Option<bool> {
        if Harness::parse(&self.harness) != Some(Harness::Copilot) {
            return None;
        }
        let narrower = matches!(
            self.permission_meaning(),
            Ok(Some(PermissionMeaning::Narrower))
        );
        posture.map(|posture| posture == Permission::Bypass && !narrower)
    }

    /// The optional fields a relaunch writes at `preparing`, in the lane
    /// record's order.
    fn prepared(&self) -> [(&'static str, &Option<String>); 4] {
        [
            ("tracker", &self.tracker),
            ("repo", &self.repo),
            ("surface", &self.surface),
            ("over_cap", &self.over_cap),
        ]
    }

    /// The fields the launch writes when it confirms, and whether the
    /// launch re-enters a standing record.
    fn selection(&self, relaunch: bool) -> Selection {
        Selection {
            harness: self.harness.clone(),
            account: self.account.clone(),
            model: self.model.clone(),
            effort: self.effort.clone(),
            relaunch,
        }
    }
}

/// Bind a session this runtime did not launch to the item's lane record.
/// A `launch` left out keeps the recorded identity.
/// The identity bound, given or recorded, is confirmed live through the one
/// identity reader before the lane reads `running`; no name
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
/// by the package that read it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Terminal {
    pub verdict: TerminalVerdict,
    pub source: String,
}

/// An explicit disposition that ends the attempt with no landing while the
/// item stays open. `interrupt` stops the harness mid-turn, its idle proof
/// not asked for: the session it runs is unusable, as after a model switch.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NoLanding {
    pub reason: String,
    pub source: String,
    #[serde(default)]
    pub interrupt: bool,
}

/// Ask for a lane's owned processes and window to be closed. Without a
/// ground the lane must read exited; `terminal` closes it whatever it reads;
/// `no_landing` retires the attempt on idle-or-gone proof and keeps the
/// item's work.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CloseOwnedResources {
    pub item: String,
    #[serde(default)]
    pub terminal: Option<Terminal>,
    #[serde(default)]
    pub no_landing: Option<NoLanding>,
    /// The lane judged ended while its item stays open (`CloseGround::Ended`):
    /// it closes done with the item's files kept, whatever the harness reads.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ended: Option<Ended>,
    /// The harness, tracker and repository a close names for a record that
    /// carries none: each fills only an empty field, and one that
    /// contradicts the record refuses `record-invalid`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub identity: Option<CloseIdentity>,
    /// The merge cycle the close records on the lane when it confirms
    /// (`ops::cycle`), with the fleet-log rows it prints.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cycle: Option<state::CycleRow>,
}

/// The reading an ended close rests on.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Ended {
    pub source: String,
}

/// The identity fields a close supplies for a record that left them empty.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CloseIdentity {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tracker: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo: Option<String>,
}

/// The close verb (`effects::close`): one lane ended by what its record and
/// its host say, its harness stopped by its recorded identity and through
/// its provider, its item's files archived and removed where its tracker
/// ended it, its sandbox closed, kept or parked, its record moved, and the
/// merge cycle the delivery names written with the close.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CloseLane {
    pub item: String,
    #[serde(default)]
    pub mode: CloseMode,
    #[serde(default, flatten)]
    pub identity: CloseIdentity,
    /// The merge the lane delivered, where the caller read it (the watch's
    /// merged index, the overseer's direct push): the cycle the close
    /// records, and the delivery a merged-and-gone close rests on.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub delivery: Option<Delivery>,
}

/// What the close does: end the lane (`close`), end its harness and keep
/// its sandbox (`keep-sandbox`), park its merge wait (`park`), print the
/// tracker's verdict alone (`terminal-state`), or close only where that
/// verdict is terminal (`if-terminal`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum CloseMode {
    #[default]
    Close,
    KeepSandbox,
    Park(ParkWait),
    TerminalState,
    IfTerminal,
}

/// The pull request a park waits on: the lane's own, a dependency, or both;
/// a dependency in another repository names it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ParkWait {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pr: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub until_pr: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub until_repo: Option<String>,
}

/// A lane's delivery: its merged pull request, or a direct push's commit.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Delivery {
    Pr {
        pr: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        repo: Option<String>,
    },
    Commit {
        commit: String,
    },
}

/// Record a hosted lane parked: its clean merge wait ended with its disk
/// kept, as `close-lane`'s park records it after the sandbox stop. The
/// sandbox stop itself is the host adapter's, so the lane
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
    /// caller wants one; parked disk alone charges nothing.
    #[serde(default)]
    pub reservation: Option<Reservation>,
}

/// Hold a lane's cap slot deliberately until `until`, an ISO 8601 UTC stamp
/// after now.
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
/// written before the effect waits on its next step. Refused
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

/// The record a first launch appends, in the lane record's key order with
/// `null` where the launch knows no value, the order every reader of the
/// fleet record meets. `permission` is the permission choice the line
/// carries, `allow_all` the Copilot grant, `tier` and `tier_inputs` what
/// the brief states of the item's tier.
fn new_lane_record(r: &LaunchLane, at: &str, allow_all: Option<bool>, tier: &Tier) -> Value {
    json!({
        "item": r.item,
        "tracker": string_or_null(&r.tracker),
        "repo": string_or_null(&r.repo),
        "harness": r.harness,
        "window": Value::Null,
        "account": string_or_null(&r.account),
        "host": r.host().map_or(Value::Null, Value::from),
        "kind": r.kind(),
        "mail_root": r.mail_root,
        "surface": r.surface.as_deref().unwrap_or("tmux"),
        "model": string_or_null(&r.model),
        "effort": string_or_null(&r.effort),
        "permission": r.permission_recorded(),
        "session_id": Value::Null,
        "session_since": at,
        "launched_at": at,
        "running_at": Value::Null,
        "status": LaneStatus::Preparing.word(),
        "over_cap": string_or_null(&r.over_cap),
        "allow_all": allow_all,
        "tier": tier.tier,
        "tier_inputs": tier.inputs(),
        "launch": Value::Null,
    })
}

/// What a launch states of its item's tier: the workflow verb its brief
/// opens with (`start` is the standard tier), else the one tier line
/// the brief carries whole, and the inputs that line names. A launch that
/// states none records `null`: it judges no tier it did not read.
#[derive(Debug, Default, PartialEq, Eq)]
struct Tier {
    tier: Option<&'static str>,
    estimate: Option<u64>,
    delta: Option<u64>,
    paths: Option<u64>,
}

impl Tier {
    /// The brief's tier: the verb where the run text opens the orch
    /// workflow with one (`/orch`, `/skill:orch`, `$orch` or `execute the
    /// orch`, then `micro`, `small` or `start`), with the first tier
    /// line's inputs; else the tier and inputs of the brief's one whole
    /// tier line, none where it has none or two that differ. A cloud
    /// session runs no orch workflow, so its text is read for the line
    /// alone.
    fn of(brief: &str, cloud: bool) -> Tier {
        let verb = if cloud { None } else { workflow_verb(brief) };
        let line = match verb {
            Some(_) => brief
                .match_indices("tier=")
                .find_map(|(at, _)| tier_line(&brief[at..])),
            None => {
                let whole: BTreeSet<TierLine> = brief
                    .lines()
                    .filter_map(|line| {
                        let line = line.trim();
                        tier_line(line).filter(|parsed| parsed.len == line.len())
                    })
                    .collect();
                (whole.len() == 1)
                    .then(|| whole.into_iter().next())
                    .flatten()
            }
        };
        let tier = match verb {
            Some("start") => Some("standard"),
            Some(verb) => Some(verb),
            None => line.as_ref().map(|l| l.tier),
        };
        Tier {
            tier,
            estimate: line.as_ref().and_then(|l| l.estimate),
            delta: line.as_ref().and_then(|l| l.delta),
            paths: line.as_ref().map(|l| l.paths),
        }
    }

    fn inputs(&self) -> Value {
        json!({"estimate": self.estimate, "delta": self.delta, "paths": self.paths})
    }
}

/// One tier line as a brief states it: `tier=T brief=B cause=...
/// estimate=N|- delta=N|- paths=N`, `len` the bytes it spans.
#[derive(Debug, PartialEq, Eq, PartialOrd, Ord)]
struct TierLine {
    tier: &'static str,
    estimate: Option<u64>,
    delta: Option<u64>,
    paths: u64,
    len: usize,
}

/// The tier line at the start of `text`, where one stands.
fn tier_line(text: &str) -> Option<TierLine> {
    let tiers: [&'static str; 3] = ["micro", "small", "standard"];
    let rest = text.strip_prefix("tier=")?;
    let tier = tiers
        .iter()
        .copied()
        .find(|t| rest.starts_with(t) && rest[t.len()..].starts_with(" brief="))?;
    let rest = &rest[tier.len() + " brief=".len()..];
    let brief = ["micro", "small", "start"]
        .iter()
        .find(|b| rest.starts_with(*b) && rest[b.len()..].starts_with(" cause="))?;
    let rest = &rest[brief.len() + " cause=".len()..];
    let line_end = rest.find('\n').unwrap_or(rest.len());
    let cause_at = rest[..line_end].find(" estimate=")?;
    let rest = &rest[cause_at + " estimate=".len()..];
    let count = |rest: &str| -> Option<(Option<u64>, usize)> {
        if let Some(after) = rest.strip_prefix('-') {
            return Some((None, rest.len() - after.len()));
        }
        let digits = rest.bytes().take_while(u8::is_ascii_digit).count();
        (digits > 0).then(|| (rest[..digits].parse().ok(), digits))
    };
    let (estimate, used) = count(rest)?;
    let rest = rest[used..].strip_prefix(" delta=")?;
    let (delta, used) = count(rest)?;
    let rest = rest[used..].strip_prefix(" paths=")?;
    let digits = rest.bytes().take_while(u8::is_ascii_digit).count();
    let paths = rest[..digits].parse().ok()?;
    let consumed = text.len() - rest.len() + digits;
    Some(TierLine {
        tier,
        estimate,
        delta,
        paths,
        len: consumed,
    })
}

/// The orch workflow verb the run text opens with, case folded: the first
/// `/orch`, `/skill:orch`, `$orch` or `execute the orch` followed by
/// `micro`, `small` or `start` and a blank or the end.
fn workflow_verb(text: &str) -> Option<&'static str> {
    let folded = text.to_ascii_lowercase();
    let verbs: [&'static str; 3] = ["micro", "small", "start"];
    let mut found: Option<(usize, &'static str)> = None;
    for prefix in ["/orch ", "/skill:orch ", "$orch ", "execute the orch "] {
        for (at, _) in folded.match_indices(prefix) {
            let rest = &folded[at + prefix.len()..];
            let verb = verbs.iter().copied().find(|v| {
                rest.starts_with(v)
                    && rest[v.len()..]
                        .chars()
                        .next()
                        .is_none_or(char::is_whitespace)
            });
            if let Some(verb) = verb
                && found.is_none_or(|(first, _)| at < first)
            {
                found = Some((at, verb));
            }
        }
    }
    found.map(|(_, verb)| verb)
}

/// Unpark at `at`: a standing `parked` moves into `pending_pr`
/// (`{pr, repo, head}` plus `until_pr` and `until_repo` where set) and
/// appends `{from: parked.at, to: $at, cause: "parked"}` to `pauses`; the
/// `parked` key is removed either way.
fn unpark(path: &Path, lane: &mut Document, index: usize, at: &str) -> Result<()> {
    let parked = match lane.get("parked") {
        None => return Ok(()),
        Some(Value::Null) => {
            record::delete(lane, "parked");
            return Ok(());
        }
        Some(Value::Object(parked)) => parked.clone(),
        Some(other) => {
            return Err(Error::Runtime(agent_runtime::Error::RecordShape {
                path: path.to_path_buf(),
                field: format!("lanes/{index}/parked"),
                reason: agent_runtime::error::ShapeReason::NotObject,
                cause: format!("found {other}"),
            }));
        }
    };
    if parked.get("at").is_some_and(|v| !v.is_null()) {
        let pause = json!({"from": parked["at"], "to": at, "cause": "parked"});
        record::array_mut(path, lane, "pauses")?.push(pause);
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
    record::set(lane, "pending_pr", Value::Object(pending));
    record::delete(lane, "parked");
    Ok(())
}

/// Whether a launch refusal is a wait for a slot: the lane cap reached, or
/// the named account with no room for the lane. An account refused by its
/// word, or one the judge could not read, is no wait for capacity.
pub(super) fn held_for_capacity(refusal: &Error) -> bool {
    matches!(
        refusal,
        Error::CapReached { .. } | Error::AccountWalled { .. }
    )
}

/// The wait of a stopped lane whose relaunch [`held_for_capacity`] refused:
/// the first such refusal stamps `capacity_wait {at}` on the record, and a
/// later one leaves the first stamp, so the wait runs from the first refusal
/// to the admitted relaunch. Any other record, or none, is left as it
/// stands: a first launch waits in the launch queue before it has lane time,
/// and a parked record's wait is its park.
pub(super) fn hold_for_capacity(
    path: &Path,
    doc: &mut Document,
    item: &str,
    at: &str,
) -> Result<()> {
    let lanes = lanes(path, doc)?;
    let Some(index) = lanes.iter().position(|l| l.item == item) else {
        return Ok(());
    };
    let lane = lane_doc_mut(path, doc, index)?;
    let standing = lane.get("capacity_wait").is_some_and(|v| !v.is_null());
    if lanes[index].status == LaneStatus::Stopped && !standing {
        record::set(lane, "capacity_wait", json!({"at": at}));
    }
    Ok(())
}

/// The admitted relaunch closes a standing `capacity_wait` into `pauses` as
/// `{from: capacity_wait.at, to: $at, cause: "capacity"}`. The pause goes in
/// before a trailing park, never after it: the hosted relaunch reads the
/// last pause as the sandbox's standing (`parked_last` in
/// `effects/launch.rs`), and a wait for a slot brings no sandbox back.
fn close_capacity_wait(path: &Path, lane: &mut Document, at: &str) -> Result<()> {
    let Some(from) = lane
        .get("capacity_wait")
        .and_then(|w| w.get("at"))
        .filter(|v| !v.is_null())
        .cloned()
    else {
        record::delete(lane, "capacity_wait");
        return Ok(());
    };
    let pauses = record::array_mut(path, lane, "pauses")?;
    let parked_last = pauses
        .last()
        .is_some_and(|p| p.get("cause").and_then(Value::as_str) == Some("parked"));
    let place = if parked_last {
        pauses.len() - 1
    } else {
        pauses.len()
    };
    pauses.insert(place, json!({"from": from, "to": at, "cause": "capacity"}));
    record::delete(lane, "capacity_wait");
    Ok(())
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
/// execution, and a relaunch beside it would be a second.
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

/// The account's room: a
/// launch that asks (`judge_account`) and names an account `lanes`
/// measures is judged on that account's projection through the accounts
/// judge, with the charge of the lane this relaunch replaces, its own
/// record, left out, since the relaunch takes that record's slot (its
/// reservation goes with the relaunch patch): a replacement adds no lane.
/// A launch with no record is judged fresh. A host built without the
/// judge's settings judges no account. Room, or no row to
/// judge, proceeds; walled, unmeasured and unjudged refuse with their
/// cause, an unread window being no empty one; an account
/// the word refuses, reserved, retired or excluded, refuses by its word
/// with no window's figure. The walled line's figures are the record's:
/// the projected window where one was projected, else
/// the reading's wall and binding bucket.
fn room(
    path: &Path,
    r: &LaunchLane,
    harness: Harness,
    replaces: Option<&str>,
    env: &Env,
    host: &Host,
) -> Result<()> {
    let (true, Some(settings), Some(account)) = (r.judge_account, host.accounts, &r.account) else {
        return Ok(());
    };
    settings.accounts.get()?;
    let model = r.model.clone().unwrap_or_default();
    let refused = |cause: &str| Error::AccountUnjudged {
        item: r.item.clone(),
        account: account.clone(),
        cause: cause.to_owned(),
    };
    let request = PickRequest {
        model: r.model.clone(),
        lane: Some(account.clone()),
        projected: true,
        ..PickRequest::new(harness)
    };
    match accounts::pick_fleet(settings, path, host, None, replaces, &request, env.now_secs) {
        PickAnswer::Lane(_) | PickAnswer::NoRecord => Ok(()),
        PickAnswer::Walled(judged) => {
            let record = judged.record();
            let projected = record.get("projected_window").filter(|w| !w.is_null());
            // A walled record with no wall is the judge failing, never a
            // verdict.
            let Some(pct) = projected
                .and_then(|w| w.get("pct"))
                .or_else(|| record.get("wall"))
                .and_then(Value::as_f64)
            else {
                return Err(refused("wall-unread"));
            };
            Err(Error::AccountWalled {
                item: r.item.clone(),
                account: account.clone(),
                model,
                window: Box::new(WalledWindow {
                    pct,
                    bucket: projected
                        .and_then(|w| w.get("bucket"))
                        .or_else(|| record.get("binding_bucket"))
                        .and_then(Value::as_str)
                        .unwrap_or("none")
                        .to_owned(),
                    projected_headroom: record
                        .get("projected_headroom_pct")
                        .and_then(Value::as_f64),
                }),
            })
        }
        PickAnswer::Reserved(_) => Err(Error::AccountReserved {
            item: r.item.clone(),
            account: account.clone(),
            model,
        }),
        PickAnswer::Retired { ends, source, .. } => Err(Error::AccountRetired {
            item: r.item.clone(),
            account: account.clone(),
            model,
            end: Box::new(RetiredEnd {
                ends,
                stated_by: source.stated_by().to_owned(),
            }),
        }),
        PickAnswer::Unmeasured(judged) => Err(Error::AccountUnmeasured {
            item: r.item.clone(),
            account: account.clone(),
            model,
            status: judged.row.status.clone(),
            detail: judged
                .row
                .detail
                .clone()
                .unwrap_or_else(|| "none".to_owned()),
        }),
        PickAnswer::Excluded(judged) => Err(refused(&format!(
            "account-excluded account={}",
            judged.row.config_dir
        ))),
        PickAnswer::Unjudged { cause } => Err(refused(&cause)),
        PickAnswer::CloudRepoUnset(judged) => Err(refused(&format!(
            "cloud-repo-unset account={}",
            judged.row.config_dir
        ))),
        PickAnswer::Unbilled { .. } => Err(Error::AccountUnmeasured {
            item: r.item.clone(),
            account: account.clone(),
            model,
            status: "provider-unmeasured".to_owned(),
            detail: "none".to_owned(),
        }),
        // The chooser's answers to a named account: no judge gives one.
        PickAnswer::None { .. } | PickAnswer::ProviderUnmeasured { .. } => {
            Err(refused("answer-unnamed"))
        }
    }
}

/// A launch on a named account names the model and the effort it spends
/// that account on, on every harness, a relaunch alike: one naming no model
/// runs the harness's default, whose window the account's judge never read,
/// and one naming no effort its default level. Refused before any intent,
/// the model first; the spellings are the words the harness's line takes.
fn choice_named(r: &LaunchLane, harness: Harness) -> Result<()> {
    let Some(account) = &r.account else {
        return Ok(());
    };
    let named = |word: &Option<String>| word.as_deref().is_some_and(|w| !w.is_empty());
    let (models, efforts) = match harness {
        Harness::Claude => ("--model", "--effort"),
        Harness::Codex => ("-m,--model", "model_reasoning_effort="),
        Harness::Copilot => ("--model", "--reasoning-effort"),
        Harness::Pi => ("--model", "--thinking"),
    };
    let refused = |key: &'static str, spellings: &str| {
        Error::from(agent_runtime::Error::refused(
            key,
            &[
                ("harness", harness.name()),
                ("lane", account),
                ("spellings", spellings),
            ],
        ))
    };
    if !named(&r.model) {
        return Err(refused("launch-model-missing", models));
    }
    // Pi spells its level on the model word, `provider/id:level`.
    let level_on_model = harness == Harness::Pi
        && r.model
            .as_deref()
            .and_then(|m| m.rsplit('/').next())
            .is_some_and(|id| id.contains(':'));
    if !named(&r.effort) && !level_on_model {
        return Err(refused("launch-effort-missing", efforts));
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
    // A lane runs in a tmux window, on this machine or over ssh, or as a
    // cloud session; a kind nothing builds or another surface is refused
    // before any intent persists.
    let kind = r.kind();
    if !matches!(kind, "local" | "ssh" | CLOUD_KIND) {
        return Err(Error::HostUnsupported {
            kind: kind.to_owned(),
            surface: r.surface.clone().unwrap_or_else(|| "tmux".to_owned()),
        });
    }
    if let Some(surface) = r.surface.as_deref().filter(|s| *s != "tmux") {
        return Err(Error::HostUnsupported {
            kind: kind.to_owned(),
            surface: surface.to_owned(),
        });
    }
    // A lane runs one of the four harnesses: any other is refused by its
    // name before any intent, so no record names a harness nothing launches.
    let harness = Harness::named(&r.harness)?;
    // A permission word no launch line of the harness carries faithfully
    // is refused before any intent, never widened to the posture's own.
    if r.permission_meaning().is_err() {
        return Err(Error::from(agent_runtime::Error::refused(
            "permission-unrepresentable",
            &[
                ("harness", &r.harness),
                ("permission", r.permission.as_deref().unwrap_or("")),
            ],
        )));
    }
    choice_named(r, harness)?;
    let cloud = kind == CLOUD_KIND;
    // The cap the request's kind is bounded by: a cloud session the cloud
    // cap, every other lane the lane cap, judged here before the transition
    // writes.
    let (cap, setting, read) = if cloud {
        (&host.cloud_lane_cap, CLOUD_LANE_CAP_KEY, "cloud-cap")
    } else {
        (&host.lane_cap, LANE_CAP_KEY, "lane-cap")
    };
    let cap = cap
        .as_ref()
        .ok_or_else(|| Error::CapUnreadable {
            read,
            path: path.to_path_buf(),
            cause: "no cap on this host".to_owned(),
        })?
        .get()?;
    let lanes = lanes(path, doc)?;
    let intents = intents(path, doc)?;
    let position = lanes.iter().position(|l| l.item == r.item);
    // A record reading `done` holds no admission: the item's next phase is
    // judged as a first launch, over the record's slot; a stopped or parked
    // record's launch is the same phase, judged when it was admitted.
    let relaunch = position.filter(|&index| lanes[index].status != LaneStatus::Done);
    // The identities the lane a relaunch replaces still names, read once:
    // they decide what of its record the count keeps and whether the
    // relaunch is refused beside a harness that still runs.
    let own = position.map(|index| occupancy::read_identities(&lanes[index], host));
    // The cap as it stands, read once for the reply whether this request
    // admits a launch or finds its own standing: every lane of the
    // request's kind, the one a relaunch replaces counted for what the
    // relaunch does not replace.
    let replacing = own.as_ref().map(|ids| (r.item.as_str(), ids));
    let admission = if cloud {
        occupancy::cloud_occupancy(&lanes, &intents, replacing, env.now_secs, host, cap)
    } else {
        occupancy::occupancy(&lanes, &intents, replacing, env.now_secs, host, cap)
    };
    if let Some(intent) = journal::open_intent(&intents, EffectOp::LaunchSession, &r.item)? {
        let index = position.ok_or_else(|| Error::LaneMissing {
            item: r.item.clone(),
        })?;
        return Ok(LaneLaunched {
            lane: lane_at(path, doc, index)?,
            effect: Effect::Reconciled { intent },
            admission,
        });
    }
    // The account boundary: the one thing this op refuses of the account is
    // the one the
    // wall spent, compared the way the claim store compares accounts.
    if let (Some(account), Some(spent)) = (&r.account, &r.exclude_account)
        && agent_runtime::accounts::wall::canon(account)
            == agent_runtime::accounts::wall::canon(spent)
    {
        return Err(Error::AccountSpent {
            item: r.item.clone(),
            account: account.clone(),
        });
    }
    // The item's lineage is bound once: a record's obligation stands over
    // every later launch, and a request stating another is refused.
    let obligation = r
        .obligation
        .as_ref()
        .map(serde_json::to_value)
        .transpose()?;
    if let (Some(index), Some(stated)) = (position, &obligation)
        && lanes[index]
            .extra
            .get("obligation")
            .is_some_and(|known| !known.is_null() && known != stated)
    {
        return Err(Error::from(agent_runtime::Error::refused(
            "obligation-conflict",
            &[("item", &r.item)],
        )));
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
        // a relaunch over one would make a second.
        no_live_harness(previous, ids)?;
    }
    // The account's room, judged before the admission and the cap; a
    // relaunch is judged with its own record's charge left out.
    room(
        path,
        r,
        harness,
        position.map(|_| r.item.as_str()),
        env,
        host,
    )?;
    // The admission judgement, under the
    // same launch lock and before the cap, so one transition admits or
    // refuses with one cause: a first launch is judged on its item, its
    // brief and the range it names; a relaunch keeps the record's sets,
    // since a recorded lane's relaunch was judged when it was admitted.
    let judged = match relaunch {
        // A relaunch was judged when first admitted, bar where it runs and
        // whose item it is: the binding, on its effective tracker and
        // repository, before the patch writes them.
        Some(index) => {
            let record = &lanes[index];
            admission::bound(
                path,
                &r.item,
                r.tracker.as_deref().or(record.tracker.as_deref()),
                r.repo.as_deref().or(record.repo.as_deref()),
                Path::new(&r.mail_root),
                host,
            )?;
            None
        }
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
                checkout: Some(Path::new(&r.mail_root)),
            },
            env,
            host,
        )?),
    };
    if admission.occupancy >= cap && r.over_cap.is_none() {
        let lanes = admission
            .charges
            .iter()
            .filter(|c| matches!(c.source, occupancy::ChargeSource::Lane { .. }))
            .count();
        return Err(Error::CapReached {
            occupancy: admission.occupancy,
            cap,
            lanes: u32::try_from(lanes).unwrap_or(u32::MAX),
            setting,
        });
    }
    // What the launch states of the lane beyond its selection: the Copilot
    // grant its line carries and the tier its brief names, as the record
    // reads them.
    let allow_all = r.allow_all(
        host.accounts
            .map(|s| s.launch.permission.get())
            .transpose()?,
    );
    let brief = match &r.brief_file {
        Some(file) => fs::read_to_string(file).map_err(|e| {
            Error::from(agent_runtime::Error::refused(
                "brief-unreadable",
                &[
                    ("path", &file.display().to_string()),
                    ("cause", &e.to_string()),
                ],
            ))
        })?,
        None => String::new(),
    };
    let tier = Tier::of(&brief, cloud);
    if let (Some(judged), Some(requested)) = (&judged, tier.tier) {
        admission::tier_judged(
            &r.item,
            requested,
            &judged.touched,
            Path::new(&r.mail_root),
            host,
        )?;
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
            // then, as the record reads it at `running`.
            //
            // A cloud record's session would leave with its fields: its close
            // row is written first, unless a close already wrote one naming
            // that session and account.
            let previous = lane_doc_mut(path, doc, index)?.clone();
            if let Some(row) = cloud_close_row(&previous, &r.item, &at)
                && !cloud_close_logged(doc, &r.item, &previous)
            {
                record::array_mut(path, doc, "fleet_log")?.push(row);
            }
            let lane = lane_doc_mut(path, doc, index)?;
            record::set(lane, "mail_root", r.mail_root.as_str());
            for (key, value) in r.prepared() {
                if let Some(value) = value {
                    record::set(lane, key, value.as_str());
                }
            }
            // The lane runs where this launch opens it, a request naming no
            // host in a window here, whatever host the record named before.
            record::set(lane, "host", r.host().map_or(Value::Null, Value::from));
            record::set(lane, "kind", kind);
            // A hosted lane's root moves to its host once the host answers;
            // the checkout the launch ran from is where a relaunch runs again.
            if r.host().is_some() {
                record::set(lane, "checkout", r.mail_root.as_str());
            } else {
                record::delete(lane, "checkout");
            }
            if r.refresh {
                record::set(lane, "refresh", true);
            } else {
                record::delete(lane, "refresh");
            }
            record::set(lane, "session_since", at.as_str());
            record::set(lane, "running_at", Value::Null);
            record::set(lane, "status", LaneStatus::Preparing.word());
            // What this launch states of the lane, over what the record
            // keeps: a permission choice and a grant judged now, and the
            // lineage where the record binds none. A relaunch keeps the
            // first launch's tier, since its brief opens the workflow with
            // `start` whatever tier the item runs at; a launch over a `done`
            // record opens the item's next phase, whose brief states its own.
            if let Value::String(permission) = r.permission_recorded() {
                record::set(lane, "permission", permission.as_str());
            }
            if allow_all.is_some() {
                record::set(lane, "allow_all", allow_all);
            }
            if let Some(obligation) = &obligation {
                record::set(lane, "obligation", obligation.clone());
            }
            if relaunch.is_none() {
                record::set(lane, "tier", tier.tier);
                record::set(lane, "tier_inputs", tier.inputs());
            }
            record::set(lane, "launch", Value::Null);
            record::delete(lane, "prepare");
            record::delete(lane, "live_display");
            record::delete(lane, "reservation");
            close_capacity_wait(path, lane, &at)?;
            unpark(path, lane, index, &at)?;
            if let Some(judged) = &judged {
                admission::record(path, doc, index, judged)?;
            }
            index
        }
        None => {
            let rows = record::array_mut(path, doc, "lanes")?;
            let mut record = new_lane_record(r, &at, allow_all, &tier);
            if r.refresh {
                record["refresh"] = Value::Bool(true);
            }
            if r.host().is_some() {
                record["checkout"] = Value::String(r.mail_root.clone());
            }
            if let Some(obligation) = &obligation {
                record["obligation"] = obligation.clone();
            }
            rows.push(record);
            let index = rows.len() - 1;
            if let Some(judged) = &judged {
                admission::record(path, doc, index, judged)?;
            }
            index
        }
    };
    let mut intent = new_intent(EffectOp::LaunchSession, &r.item, env)?;
    LaneMembers {
        lane_since: Some(at),
        selection: Some(r.selection(position.is_some())),
        exclude_account: r
            .exclude_account
            .as_deref()
            .map(agent_runtime::accounts::wall::canon),
        ..LaneMembers::default()
    }
    .write(&mut intent.extra)?;
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
    journal::no_open_intent(&intents(path, doc)?, &r.item)?;
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
            record::set(lane, "session_id", r.session_id.as_str());
            if let Some(harness) = &r.harness {
                record::set(lane, "harness", harness.as_str());
            }
            if let Some(launch) = &r.launch {
                record::set(lane, "launch", serde_json::to_value(launch)?);
            }
            record::set(lane, "status", LaneStatus::Running.word());
            record::set(lane, "running_at", at.as_str());
            // The harness charges the slot from here; a hold over the gap
            // before it is spent.
            record::delete(lane, "reservation");
            unpark(path, lane, index, &at)?;
            Ok(LaneAdopted {
                lane: lane_at(path, doc, index)?,
                adopted_now: true,
            })
        }
    }
}

/// The ground a close request stands on, judged on the
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
    let grounds = [
        r.terminal.is_some(),
        r.no_landing.is_some(),
        r.ended.is_some(),
    ];
    if grounds.iter().filter(|g| **g).count() > 1 {
        return Err(Error::CloseGroundAmbiguous {
            item: lane.item.clone(),
        });
    }
    if let Some(ended) = &r.ended {
        return Ok(CloseGround::Ended {
            source: ended.source.clone(),
        });
    }
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
                interrupt: disposition.interrupt,
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
    match open_intent(&intents(path, doc)?, EffectOp::CloseResources, &r.item)? {
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
    let lane = match &r.identity {
        Some(identity) => fill_identity(path, doc, &lane, identity)?,
        None => lane,
    };
    let ground = close_ground(&lane, r, host)?;
    let mut intent = new_intent(EffectOp::CloseResources, &r.item, env)?;
    LaneMembers {
        lane_since: lane.session_since.clone(),
        close: Some(ground),
        cycle: r.cycle.clone(),
        ..LaneMembers::default()
    }
    .write(&mut intent.extra)?;
    push_intent(path, doc, &intent)?;
    Ok(CloseRequested {
        lane,
        effect: Effect::Persisted { intent },
    })
}

/// The lane record with each identity field the close names written where
/// the record leaves it empty; a value the record already carries wins, and
/// a different one refuses `record-invalid field= recorded= option=`, since
/// the caller and the record disagree about which lane this is.
fn fill_identity(
    path: &Path,
    doc: &mut Document,
    lane: &Lane,
    identity: &CloseIdentity,
) -> Result<Lane> {
    let fills = identity_fills(lane, identity)?;
    if fills.is_empty() {
        return Ok(lane.clone());
    }
    let lanes = lanes(path, doc)?;
    let index = lanes
        .iter()
        .position(|l| l.item == lane.item)
        .ok_or_else(|| Error::LaneMissing {
            item: lane.item.clone(),
        })?;
    let record = lane_doc_mut(path, doc, index)?;
    for (field, value) in fills {
        record::set(record, field, Value::from(value));
    }
    lane_at(path, doc, index)
}

/// The identity fields a close writes onto `lane`: each named field the
/// record leaves empty; a named value the record contradicts refuses
/// `record-invalid field= recorded= option=`.
pub fn identity_fills(
    lane: &Lane,
    identity: &CloseIdentity,
) -> Result<Vec<(&'static str, String)>> {
    let fields = [
        (
            "harness",
            lane.harness.as_deref(),
            identity.harness.as_deref(),
        ),
        (
            "tracker",
            lane.tracker.as_deref(),
            identity.tracker.as_deref(),
        ),
        ("repo", lane.repo.as_deref(), identity.repo.as_deref()),
    ];
    let mut fills = Vec::new();
    for (field, recorded, option) in fields {
        match (
            recorded.filter(|v| !v.is_empty()),
            option.filter(|v| !v.is_empty()),
        ) {
            (Some(recorded), Some(option)) if recorded != option => {
                return Err(agent_runtime::Error::refused(
                    "record-invalid",
                    &[
                        ("item", &lane.item),
                        ("field", field),
                        ("recorded", recorded),
                        ("option", option),
                    ],
                )
                .into());
            }
            (None, Some(option)) => fills.push((field, option.to_owned())),
            (Some(_) | None, _) => {}
        }
    }
    Ok(fills)
}

/// A reservation's term must be a stamp after the clock.
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
    journal::no_open_intent(&intents(path, doc)?, &r.item)?;
    let lane = &lanes[index];
    // A park stops a hosted sandbox with its disk kept; a local lane has
    // none, as `close-lane`'s park refuses it.
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
        // the host adapter's, and this record moves only a lane they ended.
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
            record::set(lane, "status", LaneStatus::Parked.word());
            record::set(lane, "parked", Value::Object(parked));
            record::delete(lane, "pending_pr");
            if let Some(reservation) = &r.reservation {
                record::set(lane, "reservation", serde_json::to_value(reservation)?);
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
    record::set(lane, "reservation", serde_json::to_value(&reservation)?);
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
    let released_now = record::delete(lane, "reservation");
    Ok(LaneReleased {
        lane: lane_at(path, doc, index)?,
        released_now,
    })
}

/// The lane an intent targets, as it stands, or the reading that its record
/// moved under the intent: the lane is gone, moved under the intent's keys
/// ([`lane_moved`]), or closed under a launch intent, which an earlier
/// close does from any status.
pub(super) enum IntentTarget {
    Current { index: usize },
    Moved { observed: Option<LaneStatus> },
}

/// Whether `lane` moved under an intent written at `keys`: its
/// `session_since` is not the intent's, or its launch names a
/// pane or an identity the intent's set did not record under the harness
/// role. The one judgement: the handle applies it before it acts, and the
/// store applies it before it moves the lane, on the same inputs. A stamp
/// alone never decides, since a record may carry whole seconds.
pub fn lane_moved(lane: &Lane, keys: &PrincipalKeys) -> bool {
    lane.session_since != keys.since
        || agent_runtime::intent::launch_obligations(lane.launch.as_ref())
            .iter()
            .any(|named| !keys.keys.contains(named))
}

/// The target of `intent` under `keys`, the terminal's where it carries
/// them, else the intent's own recorded set's; an intent with neither is
/// judged by its stamp alone, the one reading a hand-written outcome
/// has.
pub(super) fn intent_lane(
    path: &Path,
    doc: &Document,
    intent: &Intent,
    keys: Option<&PrincipalKeys>,
) -> Result<IntentTarget> {
    let lanes = lanes(path, doc)?;
    let Some(index) = lanes.iter().position(|l| l.item == intent.target) else {
        return Ok(IntentTarget::Moved { observed: None });
    };
    let lane = &lanes[index];
    let since = LaneMembers::of(path, intent)?.lane_since;
    let recorded = intent.obligations.as_ref().map(|record| PrincipalKeys {
        since: since.clone(),
        keys: record.principal_keys(Role::Harness),
    });
    let moved = match keys.or(recorded.as_ref()) {
        Some(keys) => lane_moved(lane, keys),
        None => lane.session_since != since,
    } || (intent.op == EffectOp::LaunchSession && lane.status == LaneStatus::Done);
    if moved {
        return Ok(IntentTarget::Moved {
            observed: Some(lane.status),
        });
    }
    Ok(IntentTarget::Current { index })
}

/// Note on a lane intent the status its lane read when the lane had moved
/// under it: on the intent as the outcome reports it, and on its row where a
/// status was read. orch's arm is the one writer of the member.
pub(super) fn observe_status(
    path: &Path,
    doc: &mut Document,
    intent: &mut Intent,
    observed: Option<LaneStatus>,
) -> Result<()> {
    let mut members = LaneMembers::of(path, intent)?;
    members.observed_status = observed;
    members.write(&mut intent.extra)?;
    if observed.is_some() {
        let rows = record::array_mut(path, doc, "intents")?;
        let index = rows
            .iter()
            .position(|row| row.get("id").and_then(Value::as_str) == Some(intent.id.as_str()))
            .ok_or_else(|| {
                Error::Runtime(agent_runtime::Error::IntentUnknown {
                    id: intent.id.clone(),
                })
            })?;
        members.write(record::element_mut(path, rows, index, "intents")?)?;
    }
    Ok(())
}

/// Record the fleet's tmux session where none is recorded yet, the
/// first launch's `.tmux.session //= $s`.
fn record_tmux_session(path: &Path, doc: &mut Document, session: &str) -> Result<()> {
    if matches!(doc.get("tmux"), None | Some(Value::Null)) {
        record::set(doc, "tmux", json!({"session": session}));
        return Ok(());
    }
    let tmux = record::object_mut(path, doc, "tmux")?;
    if matches!(tmux.get("session"), None | Some(Value::Null)) {
        record::set(tmux, "session", session);
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
        .ok_or_else(|| {
            Error::Runtime(agent_runtime::Error::IntentUnknown {
                id: r.intent_id.clone(),
            })
        })?;
    let mut intent = intents[index].clone();
    if !intent.open() {
        return Err(Error::Runtime(agent_runtime::Error::IntentComplete {
            id: intent.id.clone(),
            outcome: intent.outcome,
        }));
    }
    intent.phase = Some(r.phase.clone());
    let rows = record::array_mut(path, doc, "intents")?;
    let row = record::element_mut(path, rows, index, "intents")?;
    record::set(row, "phase", serde_json::to_value(&r.phase)?);
    Ok(PhaseRecorded { intent })
}

/// The lane's own members of a launch's `record-outcome` request, carried
/// in the request's `members`, which the engine and the journal never read:
/// the one view the launch writes them through and the arm reads them
/// through.
#[derive(Debug, Default, Serialize, Deserialize)]
pub struct LaneOutcome {
    /// The tmux session a confirmed launch opened in; the fleet records the
    /// first as `tmux.session`, as the first launch does.
    #[serde(default)]
    pub tmux_session: Option<String>,
    /// The root a confirmed lane's files are read under, where its host
    /// named one: a hosted lane's worktree on its host, a cloud lane's
    /// worktree the launch made.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mail_root: Option<String>,
    /// The launch named no home, written as the lane's `home_implicit`.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub home_implicit: bool,
}

impl LaneOutcome {
    /// The members as the request carries them; one that is not the shape
    /// the arm reads refuses `request-invalid`.
    fn of(path: &Path, r: &RecordOutcome) -> Result<LaneOutcome> {
        serde_json::from_value(Value::Object(r.members.clone())).map_err(|e| Error::Request {
            path: path.to_path_buf(),
            cause: e.to_string(),
        })
    }

    /// The members the launch writes into its outcome's request.
    pub fn members(&self) -> Map<String, Value> {
        match serde_json::to_value(self) {
            Ok(Value::Object(members)) => members,
            Ok(_) | Err(_) => unreachable!("a struct of strings and a flag is a JSON object"),
        }
    }
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
    recorded: &mut TargetMoved,
) -> Result<()> {
    let selection = LaneMembers::of(path, intent)?.selection;
    let members = LaneOutcome::of(path, r)?;
    match r.outcome {
        Outcome::Confirmed => {
            if let Some(session) = &members.tmux_session {
                record_tmux_session(path, doc, session)?;
            }
            let lane = lane_doc_mut(path, doc, index)?;
            // The whole selection, null where the request named none: the
            // session that runs is this request's, so no account, model or
            // effort of the earlier session survives into its record.
            if let Some(selection) = &selection {
                record::set(lane, "harness", selection.harness.as_str());
                for (key, value) in [
                    ("account", &selection.account),
                    ("model", &selection.model),
                    ("effort", &selection.effort),
                ] {
                    record::set(lane, key, string_or_null(value));
                }
            }
            if let Some(window) = &r.window {
                record::set(lane, "window", window.as_str());
            }
            // The root a hosted or cloud lane's files are read under is
            // known only once its host answered.
            if let Some(mail_root) = &members.mail_root {
                record::set(lane, "mail_root", mail_root.as_str());
            }
            record::set(lane, "status", LaneStatus::Running.word());
            record::set(lane, "running_at", at);
            record::set(lane, "launch", serde_json::to_value(&r.launch)?);
            record::set(lane, "session_id", string_or_null(&r.session_id));
            // The home a local launch read its sessions under, which a
            // relaunch reads the bound session from, and whether it named it.
            if let Some(home) = &r.home {
                record::set(lane, "home", home.as_str());
                if members.home_implicit {
                    record::set(lane, "home_implicit", true);
                } else {
                    record::delete(lane, "home_implicit");
                }
            }
            recorded.lane = Some(Box::new(lane_at(path, doc, index)?));
        }
        Outcome::Failed => {
            let lane = lane_doc_mut(path, doc, index)?;
            record::set(lane, "status", LaneStatus::Stopped.word());
            recorded.lane = Some(Box::new(lane_at(path, doc, index)?));
        }
        Outcome::Unconfirmed => {
            // The window opened but the composer was not read in the bound.
            // Persist the pane the effect holds on the lane's `launch` so a
            // reconcile can re-observe it; the lane stays `preparing`. A
            // relaunch that wrote `launch: null` keeps that until the effect
            // names a pane.
            if r.launch.is_some() {
                let lane = lane_doc_mut(path, doc, index)?;
                record::set(lane, "launch", serde_json::to_value(&r.launch)?);
                recorded.lane = Some(Box::new(lane_at(path, doc, index)?));
            }
        }
        Outcome::NotStarted => {}
    }
    Ok(())
}

/// The cloud session's close row a cloud lane's close writes beside its own:
/// the session and account the record names, `none` where it names none,
/// and the last directive's send result, credit and the CLI's words where
/// the record carries one, so the session the operator archives stays named
/// once the record is done.
fn cloud_close_row(lane: &Document, item: &str, at: &str) -> Option<Value> {
    if lane.get("kind").and_then(Value::as_str) != Some(super::CLOUD_KIND) {
        return None;
    }
    let mut text = format!(
        "cloud lane closed; session={} account={}",
        cloud_word(lane, "session_id"),
        cloud_word(lane, "account")
    );
    if let Some(send) = lane.get("directive_send").filter(|v| v.is_object()) {
        let field = |v: Option<&Value>| match v {
            Some(Value::String(s)) => s.clone(),
            None | Some(Value::Null) => "none".to_owned(),
            Some(other) => other.to_string(),
        };
        let credit = match send.get("credit").filter(|v| v.is_object()) {
            Some(credit) => format!(
                "credit={} locked={}",
                field(credit.get("remaining_dollars")),
                field(credit.get("locked_reason"))
            ),
            None => "credit=unread".to_owned(),
        };
        // Each run of white space is one space, as jq's `gsub("\\s+"; " ")`.
        let mut collapsed = String::new();
        for c in field(send.get("text")).chars() {
            if !c.is_whitespace() {
                collapsed.push(c);
            } else if !collapsed.ends_with(' ') {
                collapsed.push(' ');
            }
        }
        let cli: String = collapsed.chars().take(300).collect();
        text.push_str(&format!(
            " send={} {credit} cli={cli}",
            field(send.get("result"))
        ));
    }
    Some(json!({"at": at, "kind": "close", "item": item, "text": text}))
}

/// A cloud record's field as its close row names it, `none` where the
/// record names none.
fn cloud_word<'a>(lane: &'a Document, key: &str) -> &'a str {
    lane.get(key).and_then(Value::as_str).unwrap_or("none")
}

/// Whether a `close` row for `item` already names the cloud record's
/// session and account, read from the first `session=S account=A` of its
/// text as the close rows every launcher and close wrote spell it.
fn cloud_close_logged(doc: &Document, item: &str, lane: &Document) -> bool {
    let (session, account) = (cloud_word(lane, "session_id"), cloud_word(lane, "account"));
    doc.get("fleet_log")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|row| row.get("kind").and_then(Value::as_str) == Some("close"))
        .filter(|row| row.get("item").and_then(Value::as_str) == Some(item))
        .filter_map(|row| row.get("text").and_then(Value::as_str))
        .any(|text| {
            let Some((_, rest)) = text.split_once("session=") else {
                return false;
            };
            let mut words = rest.split(' ');
            words.next() == Some(session)
                && words.next().and_then(|w| w.strip_prefix("account=")) == Some(account)
        })
}

/// The close arms of `record-outcome` on the lane at `index`, judged
/// current by the caller. `confirmed` on an exited or terminal ground reads
/// the lane done and drops the PR identities and the reservation a close
/// ends, and records the reason the close kept the lane's worktree as
/// `kept` where its set says it did; on a `no-landing`
/// ground it reads the lane stopped and keeps everything else, the attempt
/// retired with the item's work and history intact. `failed`
/// and `unconfirmed` move nothing.
pub(super) fn record_close_outcome(
    path: &Path,
    doc: &mut Document,
    intent: &Intent,
    r: &RecordOutcome,
    at: &str,
    index: usize,
    recorded: &mut TargetMoved,
) -> Result<()> {
    let members = LaneMembers::of(path, intent)?;
    match r.outcome {
        Outcome::Confirmed => {
            let mut row = json!({
                "at": at,
                "kind": "close",
                "item": intent.target,
            });
            let lane = lane_doc_mut(path, doc, index)?;
            match &members.close {
                Some(CloseGround::NoLanding { reason, source, .. }) => {
                    record::set(lane, "status", LaneStatus::Stopped.word());
                    row["text"] =
                        json!(format!("attempt retired, no landing; intent {}", intent.id));
                    row["disposition"] = json!("no-landing");
                    row["reason"] = json!(reason);
                    row["source"] = json!(source);
                }
                Some(
                    CloseGround::Exited | CloseGround::Terminal { .. } | CloseGround::Ended { .. },
                )
                | None => {
                    record::set(lane, "status", LaneStatus::Done.word());
                    record::delete(lane, "pending_pr");
                    record::delete(lane, "parked");
                    record::delete(lane, "reservation");
                    // This close is the one writer of both: an earlier
                    // close's reason, which a relaunch keeps, never outlives
                    // a release.
                    record::delete(lane, "kept");
                    record::delete(lane, "kept_mail");
                    let owed = LaneObligationRecord::of(path, intent)?;
                    if let Some(reason) =
                        owed.as_ref().and_then(LaneObligationRecord::worktree_kept)
                    {
                        record::set(lane, "kept", reason);
                    }
                    if let Some(mail) = owed
                        .as_ref()
                        .and_then(LaneObligationRecord::worktree_mail_kept)
                    {
                        record::set(lane, "kept_mail", mail);
                    }
                    row["text"] = json!(format!("lane closed; intent {}", intent.id));
                    match &members.close {
                        Some(CloseGround::Terminal { verdict, source }) => {
                            row["verdict"] = serde_json::to_value(verdict)?;
                            row["source"] = json!(source);
                        }
                        Some(CloseGround::Ended { source }) => {
                            row["disposition"] = json!("ended");
                            row["source"] = json!(source);
                        }
                        Some(CloseGround::Exited | CloseGround::NoLanding { .. }) | None => {}
                    }
                }
            }
            let cloud = cloud_close_row(lane, &intent.target, at);
            let cycle = members.cycle.as_ref().map(|c| c.rows(&intent.target, at));
            if let Some(cycle_row) = &members.cycle {
                record::set(lane, "cycle", cycle_row.cycle.clone());
            }
            let log = record::array_mut(path, doc, "fleet_log")?;
            log.push(row);
            log.extend(cloud);
            log.extend(cycle.into_iter().flatten());
            recorded.lane = Some(Box::new(lane_at(path, doc, index)?));
        }
        Outcome::Failed | Outcome::Unconfirmed | Outcome::NotStarted => {}
    }
    Ok(())
}

/// The record of a lane a harness's own launcher runs, surface 2 or 3: no
/// tmux pane, so no lane operation reads or writes it. `create` adds the
/// whole record after the item's first launch; `merge` replaces the fields
/// the file names on the standing record. A tmux lane is the lane
/// operations' own, and either step refuses `surface-lane` on one.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "step", rename_all = "kebab-case", deny_unknown_fields)]
pub enum RecordSurfaceLane {
    Create { lane: Value },
    Merge { item: String, file: PathBuf },
}

fn surface_refused(key: &'static str, fields: &[(&str, &str)]) -> Error {
    agent_runtime::Error::refused(key, fields).into()
}

/// A record's surface is tmux where it names none: the launch writes `tmux`
/// as the one surface its lanes have.
fn tmux_refused(item: &str, record: &Value) -> Result<()> {
    let surface = record
        .get("surface")
        .and_then(Value::as_str)
        .unwrap_or("tmux");
    if surface == "tmux" {
        return Err(surface_refused(
            "surface-lane",
            &[("item", item), ("surface", surface)],
        ));
    }
    Ok(())
}

fn obligation_held(item: &str, stated: &Value) -> Result<()> {
    if stated.is_null() {
        return Ok(());
    }
    serde_json::from_value::<Obligation>(stated.clone())
        .map(drop)
        .map_err(|e| {
            surface_refused(
                "obligation-invalid",
                &[("lane", item), ("cause", &e.to_string())],
            )
        })
}

fn lane_index(doc: &Document, item: &str) -> Option<usize> {
    doc.get("lanes")
        .and_then(Value::as_array)
        .and_then(|lanes| {
            lanes
                .iter()
                .position(|l| l.get("item").and_then(Value::as_str) == Some(item))
        })
}

pub(crate) fn record_surface_lane(
    path: &Path,
    doc: &mut Document,
    r: &RecordSurfaceLane,
) -> Result<Value> {
    match r {
        RecordSurfaceLane::Create { lane } => {
            let read: Lane = serde_json::from_value(lane.clone())
                .map_err(|e| surface_refused("lane-invalid", &[("cause", &e.to_string())]))?;
            tmux_refused(&read.item, lane)?;
            obligation_held(&read.item, lane.get("obligation").unwrap_or(&Value::Null))?;
            if lane_index(doc, &read.item).is_some() {
                return Err(surface_refused("lane-standing", &[("item", &read.item)]));
            }
            let rows = record::array_mut(path, doc, "lanes")?;
            rows.push(lane.clone());
            let pointer = format!("/lanes/{}", rows.len() - 1);
            Ok(json!({"step": "create", "pointer": pointer, "value": lane}))
        }
        RecordSurfaceLane::Merge { item, file } => {
            let index =
                lane_index(doc, item).ok_or_else(|| Error::LaneMissing { item: item.clone() })?;
            tmux_refused(
                item,
                &Value::Object(lane_doc_mut(path, doc, index)?.clone()),
            )?;
            let mut merged = merge_lane(path, doc, item, super::store::one_value(file)?)?;
            tmux_refused(item, &merged["value"])?;
            merged["step"] = json!("merge");
            Ok(merged)
        }
    }
}

/// A lane record's merge: the lane is found by its `item` inside the
/// transition, every field the mapping names replaces the lane's, and the
/// item's lineage is bound once, as the launch binds it: an absent or null
/// `obligation` keeps the lane's, one differing from a known binding refuses
/// `obligation-conflict`, and an unknown binding takes the one stated, held
/// to the launch request's shape.
pub(crate) fn merge_lane(
    path: &Path,
    doc: &mut Document,
    lane: &str,
    value: Value,
) -> Result<Value> {
    let Value::Object(mapping) = value else {
        return Err(surface_refused("merge-value", &[("lane", lane)]));
    };
    if let Some(item) = mapping.get("item")
        && item.as_str() != Some(lane)
    {
        let named = item
            .as_str()
            .map_or_else(|| item.to_string(), str::to_owned);
        return Err(surface_refused(
            "merge-item",
            &[("lane", lane), ("item", &named)],
        ));
    }
    let index = lane_index(doc, lane).ok_or_else(|| Error::LaneMissing {
        item: lane.to_owned(),
    })?;
    let record = lane_doc_mut(path, doc, index)?;
    for (key, stated) in mapping {
        if key == "obligation" {
            if stated.is_null() {
                continue;
            }
            obligation_held(lane, &stated)?;
            if record
                .get("obligation")
                .is_some_and(|known| !known.is_null() && *known != stated)
            {
                return Err(surface_refused("obligation-conflict", &[("item", lane)]));
            }
        }
        record.insert(key, stated);
    }
    Ok(json!({"pointer": format!("/lanes/{index}"), "value": record.clone()}))
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
    use crate::state::{LaneStatus, fixtures};
    use agent_runtime::intent::{EffectOp, Phase};
    use agent_runtime::settings::Judged;

    #[test]
    fn launch_lane_writes_the_released_record_and_the_intent_then_reconciles() {
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
        assert_eq!(
            intent.id,
            "launch-session:KEN-4468:1769700000123456789-4242"
        );
        assert_eq!(intent.outcome, Outcome::NotStarted);
        assert_eq!(
            LaneMembers::of(&path, intent)
                .unwrap()
                .lane_since
                .as_deref(),
            Some("2026-01-29T15:20:00Z")
        );
        assert_eq!(
            LaneMembers::of(&path, intent).unwrap().selection,
            Some(Selection {
                harness: "claude".into(),
                account: Some("/a/a1".into()),
                model: Some("claude-opus-5-5".into()),
                effort: Some("high".into()),
                relaunch: false,
            })
        );
        // The appended record carries the lane record's keys in their order.
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
                "permission",
                "session_id",
                "session_since",
                "launched_at",
                "running_at",
                "status",
                "over_cap",
                "allow_all",
                "tier",
                "tier_inputs",
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

    /// A parked lane relaunches;
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

    /// A lane launch naming a kind nothing builds or a surface other than a
    /// tmux window is refused before any intent persists.
    #[test]
    fn launch_lane_refuses_an_unbuilt_kind_or_another_surface() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let before = fs::read_to_string(&path).unwrap();
        let rows: [(Option<&str>, Option<&str>); 3] = [
            (Some("codex-cloud"), None),
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
        // `local`/`tmux` named explicitly is admitted; a provider host
        // records `ssh` and the cloud host its own kind.
        let req = Request::LaunchLane(Box::new(LaunchLane {
            kind: Some("local".into()),
            surface: Some("tmux".into()),
            ..launch_fields("KEN-9")
        }));
        assert!(run(&path, &req).is_ok());
        let Report::LaunchLane(hosted) = run(
            &path,
            &Request::LaunchLane(Box::new(LaunchLane {
                host: Some("/opt/provider".into()),
                refresh: true,
                ..launch_fields("KEN-10")
            })),
        )
        .unwrap()
        .report
        else {
            panic!()
        };
        assert_eq!(hosted.lane.host.as_deref(), Some("/opt/provider"));
        assert_eq!(hosted.lane.kind.as_deref(), Some("ssh"));
        assert_eq!(hosted.lane.extra.get("refresh"), Some(&Value::Bool(true)));
        let Report::LaunchLane(cloud) = run(
            &path,
            &Request::LaunchLane(Box::new(LaunchLane {
                host: Some(CLOUD_KIND.into()),
                ..launch_fields("KEN-11")
            })),
        )
        .unwrap()
        .report
        else {
            panic!()
        };
        assert_eq!(cloud.lane.kind.as_deref(), Some(CLOUD_KIND));
        assert_eq!(cloud.lane.host.as_deref(), Some(CLOUD_KIND));
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

    /// The tier a brief states, by the one reader of its words: the
    /// workflow verb in any of its spellings, case folded, with the first
    /// tier line's inputs; no verb and one whole tier line; no
    /// verb and two lines that differ, or none; and a cloud session's text
    /// read for the line alone.
    #[test]
    fn the_tier_a_brief_states_is_read_from_its_verb_or_its_one_tier_line() {
        let line = "tier=small brief=small cause=estimate 3 over estimate=3 delta=10 paths=2";
        type Row<'a> = (
            &'a str,
            bool,
            Option<&'static str>,
            (Option<u64>, Option<u64>, Option<u64>),
        );
        let rows: [Row; 9] = [
            (
                "/orch start KEN-1 and more",
                false,
                Some("standard"),
                (None, None, None),
            ),
            (
                "/skill:orch small KEN-1",
                false,
                Some("small"),
                (None, None, None),
            ),
            (
                "$orch MICRO KEN-1\n",
                false,
                Some("micro"),
                (None, None, None),
            ),
            (
                "Read SKILL.md and execute the orch start workflow for KEN-1",
                false,
                Some("standard"),
                (None, None, None),
            ),
            ("/orch starter KEN-1", false, None, (None, None, None)),
            (
                &format!("/orch micro KEN-1\nnotes {line} and {line}"),
                false,
                Some("micro"),
                (Some(3), Some(10), Some(2)),
            ),
            (
                &format!("Resume.\n  {line}  \n"),
                false,
                Some("small"),
                (Some(3), Some(10), Some(2)),
            ),
            (
                &format!("{line}\ntier=micro brief=micro cause=x estimate=- delta=- paths=0"),
                false,
                None,
                (None, None, None),
            ),
            (
                &format!("/orch start KEN-1\n{line}"),
                true,
                Some("small"),
                (Some(3), Some(10), Some(2)),
            ),
        ];
        for (brief, cloud, tier, (estimate, delta, paths)) in rows {
            assert_eq!(
                Tier::of(brief, cloud),
                Tier {
                    tier,
                    estimate,
                    delta,
                    paths,
                },
                "{brief:?} cloud={cloud}"
            );
        }
        assert_eq!(
            Tier::of(
                "tier=micro brief=micro cause=x estimate=- delta=4 paths=1",
                false
            ),
            Tier {
                tier: Some("micro"),
                estimate: None,
                delta: Some(4),
                paths: Some(1),
            }
        );
    }

    /// The production host: the kernel's own reader.
    fn kernel(cap: u32) -> Host<'static> {
        Host {
            lane_cap: Some(Judged { read: Ok(cap) }),
            cloud_lane_cap: Some(Judged { read: Ok(cap) }),
            still_runs: &process::still_runs,
            admission: Some(no_reads()),
            accounts: None,
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
                };
                (source, c.reason)
            })
            .collect()
    }

    /// The cap, against processes this test holds: a lane
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
                ("setting".to_owned(), "ORCH_OVERSEER_LANES".to_owned())
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

    /// Five stopped attempts, each with a surviving window and
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
            lane_cap: Some(Judged { read: Ok(1) }),
            cloud_lane_cap: None,
            admission: Some(no_reads()),
            still_runs: &unread,
            accounts: None,
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

    /// A first launch's brief requests a cycle; the touched set its brief
    /// names earns a wider one through the tier reader, and the launch is
    /// refused naming both, with no intent recorded; a reader that earns
    /// the requested cycle admits it.
    #[test]
    fn a_launch_requesting_a_cycle_narrower_than_its_touched_set_earns_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        fleet_with(&path, &[]);
        let brief = dir.path().join("brief");
        fs::write(
            &brief,
            "tier=micro brief=micro cause=estimate-within-micro production=1 estimate=1 delta=- paths=1\nChange `src/a.rs` and `skills/x/SKILL.md`.\n",
        )
        .unwrap();
        let request = Request::LaunchLane(Box::new(LaunchLane {
            brief_file: Some(brief),
            ..launch_fields("KEN-T")
        }));
        let wider = admission::AdmissionReads {
            tier: Box::new(|_: &admission::Clis, _: &str, paths: &[String], _: &Path| {
                assert_eq!(paths, ["skills/x/SKILL.md", "src/a.rs"]);
                Ok(super::super::tier::Classified {
                    cycle: super::super::tier::Cycle::Small,
                    cause: "instruction-file path=skills/x/SKILL.md glob=*/SKILL.md".into(),
                    delta: None,
                    notes: Vec::new(),
                })
            }),
            ..no_reads()
        };
        let host = Host {
            admission: Some(wider),
            ..kernel(4)
        };
        let err = apply_on(&path, &request, &env(), LOCK, &host).unwrap_err();
        assert_eq!(
            (err.key(), err.fields()),
            (
                "tier-narrower",
                vec![
                    ("item".to_owned(), "KEN-T".to_owned()),
                    ("requested".to_owned(), "micro".to_owned()),
                    ("judged".to_owned(), "small".to_owned()),
                    ("cause".to_owned(), "instruction-file".to_owned()),
                ]
            )
        );
        assert!(fleet(&path).intents.is_empty());
        assert!(fleet(&path).lanes.is_empty());
        apply_on(&path, &request, &env(), LOCK, &kernel(4)).unwrap();
        assert_eq!(lane(&path, "KEN-T").extra["tier"], Value::from("micro"));
    }

    /// A deliberate hold and its release: a stopped lane with a
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

    /// A stopped lane whose parent is gone but whose detached
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

    /// The account boundary: a relaunch naming
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
                model: Some("opus".into()),
                effort: Some("high".into()),
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
        assert_eq!(
            LaneMembers::of(&path, intent)
                .unwrap()
                .exclude_account
                .as_deref(),
            Some(spent.as_str())
        );
    }

    /// A relaunch keeps every field
    /// it does not write, drops `prepare` and `live_display`, and keeps the
    /// key sequence of what it keeps; its host and kind are its own, a
    /// window here for a request naming no host. The harness, account,
    /// model and effort it was asked for reach the record when the launch
    /// confirms, not at `preparing`. The confirmation
    /// writes all four, null where the
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
        assert_eq!(view.kind.as_deref(), Some("local"));
        assert_eq!(view.host, None);
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
        // request left out. A claude session after a codex one carries no
        // codex account.
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
        assert_eq!(
            view.kind.as_deref(),
            Some("local"),
            "the launch's own, its request naming no host"
        );
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

    /// A confirmed local launch writes the home its sessions ran under and
    /// whether it named it, and a named launch's confirmation takes the
    /// mark off: a later resume repeats the mode the last launch ran in.
    #[test]
    fn a_confirmed_launch_records_its_home_and_whether_it_named_it() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let stopped =
            fixtures::FLEET.replacen("\"status\": \"done\"", "\"status\": \"stopped\"", 1);
        for (implicit, prior) in [(true, false), (false, true)] {
            let text = if prior {
                stopped.replacen(
                    "      \"launch\": {",
                    "      \"home\": \"/h/.claude\",\n      \"home_implicit\": true,\n      \"launch\": {",
                    1,
                )
            } else {
                stopped.clone()
            };
            fs::write(&path, &text).unwrap();
            let id = intend(&path, &launch("KEN-4437"));
            let Request::RecordOutcome(mut confirmed) = outcome(&id, Outcome::Confirmed) else {
                unreachable!("outcome builds a record-outcome request")
            };
            confirmed.home = Some("/h/.claude".into());
            confirmed.members = LaneOutcome {
                home_implicit: implicit,
                ..LaneOutcome::default()
            }
            .members();
            run(&path, &Request::RecordOutcome(confirmed)).unwrap();
            let view = lane(&path, "KEN-4437");
            assert_eq!(view.home.as_deref(), Some("/h/.claude"));
            assert_eq!(view.home_implicit, implicit, "implicit={implicit}");
        }
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

    /// Adopting a parked lane runs
    /// the unpark, and adopting without `launch` keeps the recorded
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

    /// An effect's phase is written onto its open intent before
    /// the effect waits, a later phase replaces it, and a closed intent
    /// takes none.
    #[test]
    fn record_phase_writes_the_open_intent_s_phase_and_refuses_a_closed_one() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        fs::write(&path, fixtures::FLEET).unwrap();
        let id = intend(&path, &transfer(expected()));
        let opened = agent_runtime::intent::OpenedPane {
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
            home: None,
            home_implicit: false,
        };
        let session = agent_runtime::intent::BoundSession {
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
        let err = run(&path, &phase(Phase::WindowOpened { opened })).unwrap_err();
        assert!(
            matches!(
                err,
                Error::Runtime(agent_runtime::Error::IntentComplete { .. })
            ),
            "{err:?}"
        );
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
        assert_eq!(intent.op, EffectOp::CloseResources);
        assert_eq!(
            LaneMembers::of(&path, intent)
                .unwrap()
                .lane_since
                .as_deref(),
            Some("2026-01-29T15:20:00Z")
        );
        assert_eq!(
            LaneMembers::of(&path, intent).unwrap().selection,
            None,
            "a close carries no selection"
        );
        assert_eq!(
            LaneMembers::of(&path, intent).unwrap().close,
            Some(CloseGround::Exited)
        );
        let again = run(&path, &close("KEN-4468")).unwrap();
        let Report::CloseOwnedResources(c) = &again.report else {
            panic!()
        };
        assert!(matches!(&c.effect, Effect::Reconciled { .. }));
        let body = fleet(&path);
        assert_eq!(body.intents.len(), 2);
        assert_eq!(body.lanes[1].status, LaneStatus::Running);
    }

    /// The live-harness guard: a lane whose recorded harness runs refuses a
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
                interrupt: false,
            }),
            ended: None,
            identity: None,
            cycle: None,
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
            ended: None,
            identity: None,
            cycle: None,
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
            LaneMembers::of(&path, intent).unwrap().close,
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
        assert_eq!(
            LaneMembers::of(&path, intent).unwrap().close,
            Some(CloseGround::Exited)
        );
    }

    /// A confirmed close removes `pending_pr`,
    /// `parked` and the reservation, as a `done` status
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
            ended: None,
            identity: None,
            cycle: None,
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

    /// A close on the `no-landing` disposition retires the
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
                interrupt: false,
            }),
            ended: None,
            identity: None,
            cycle: None,
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
            LaneMembers::of(&path, intent).unwrap().close,
            Some(CloseGround::NoLanding {
                reason: "diagnosis-complete".into(),
                source: "overseer".into(),
                interrupt: false,
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

    /// `park-lane` records the park `close-lane` writes after the
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
