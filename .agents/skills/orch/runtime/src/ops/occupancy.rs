//! What charges the fleet's lane cap, judged at admission
//! from the records and the kernel table in one transition, with no release
//! write. The execution charge is derived from the recorded identities
//! before any status word is read: a lane attempt charges one slot while a
//! proven live owned harness identity exists (its recorded launch or wake
//! process, read through the one identity reader), while its launch intent
//! is open (the preparing row an admission wrote), or while an
//! explicit unexpired [`Reservation`] an op wrote stands. A pane, a status
//! word, parked disk, a pending return or a native transcript never charges,
//! and `done`, `stopped` and `parked` are never read as zero: a live
//! identity charges whatever the status says. An identity that could not be
//! read protects its slot as unknown, never zero, and so does a `running` or
//! `preparing` record that names no identity at all.
//!
//! One slot per lane record, the first rule that holds deciding
//! (`lane_charge`). A `kind: claude-cloud` record charges the cloud cap,
//! never this one (`cloud_charge`): it names no process, so its in-flight
//! status word is its evidence, read after its reservation:
//!
//! | Record reads | Charge | Reason, cause |
//! |---|---|---|
//! | `launch.{pid,start}` reads `Live` | 1 | `live`, whatever the status word |
//! | `launch` identity `Unreadable` | 1 | `unknown`, the reader's cause |
//! | `launch` gone or none, `wake.{pid,start}` reads `Live` | 1 | `wake` |
//! | `wake` identity `Unreadable` | 1 | `unknown`, the reader's cause |
//! | `reservation {reason, until}` with `until` after the op clock | 1 | `reservation`, the reason; at or after `until` nothing; an `until` that is no stamp protects as `unknown`, `reservation-until-invalid` |
//! | `preparing` with an open `launch-lane` intent on it | 1 | `preparing` |
//! | no identity recorded at all and status `running` or `preparing` | 1 | `unknown`, `identity-unrecorded` |
//! | identities gone (a pid live under another start among them), or no identity on `stopped`, `parked` or `done` | none | released by derivation; disk, worktree, mailbox, `pending_pr`, `parked`, `launch`, `recovery`, counters untouched |
//!
//! A relaunch replaces its own record's `launch` and `reservation`, so the
//! charges derived from those are left out of its count; a charge its wake
//! identity derives is owned execution the relaunch does not replace, and
//! the relaunch is refused beside it (`retained_charge`).
use std::fs;
use std::path::{Path, PathBuf};

use agent_runtime::clock;
use agent_runtime::process::{self, Identity};
use agent_runtime::reading::Reading;
use serde::{Deserialize, Serialize};

use super::admission::{AdmissionReads, Clis};
use crate::settings::Settings;
use crate::state::{EffectOp, Intent, Lane, LaneStatus, LaunchIdentity};

/// The `kind` a Claude cloud lane records: hosted, its `mail_root` the
/// item's worktree on this machine. The cloud cap counts it, not the lane
/// cap; the lane observation duty does not observe it; the close owes its
/// worktree.
pub(crate) const CLOUD_KIND: &str = "claude-cloud";

/// The host facts a fleet transition judges beside the record: the lane cap
/// setting and the liveness read of the one identity reader. The read is
/// injected so a transition is a function of the record and what the
/// kernel answered; production takes [`Host::kernel`]. The reader is
/// private to `ops`: an effect file receives the operation handle and no
/// primitive function pointer. No read takes a pid alone: a pid alone is
/// no identity.
pub struct Host<'a> {
    pub lane_cap: u32,
    /// The cloud sessions the overseer holds at once, bounding a
    /// `claude-cloud` launch alone. `None` on a host built for an entry
    /// that launches no lane, which judges no cloud cap.
    pub cloud_lane_cap: Option<u32>,
    /// Whether a recorded identity still runs under its recorded start.
    pub(super) still_runs: &'a dyn Fn(&Identity) -> Reading<Identity>,
    /// The admission's reads: the item read
    /// eligibility and the Location paths are judged from, for the
    /// launching item and for a holder with no recorded touched set, and
    /// the changed paths of a diff range. `None` on a host built for an
    /// entry that launches no lane.
    pub(super) admission: Option<AdmissionReads<'a>>,
    /// The settings the accounts judge reads a launch's account under
    /// the listing reader and the account bounds. `None`
    /// on a host built for an entry that launches no lane, which judges no
    /// account.
    pub(super) accounts: Option<&'a Settings>,
}

impl Host<'static> {
    /// The host as production judges it: the kernel's own identity read.
    #[allow(
        clippy::disallowed_methods,
        reason = "the one site that hands the kernel's identity reader to a fleet transition, which judges live processes beside the record and never acts on one"
    )]
    pub fn kernel(lane_cap: u32) -> Host<'static> {
        Host {
            lane_cap,
            cloud_lane_cap: None,
            still_runs: &process::still_runs,
            admission: None,
            accounts: None,
        }
    }
}

impl<'a> Host<'a> {
    /// The host with the cloud cap a `claude-cloud` launch is judged
    /// against.
    pub fn cloud_cap(self, cap: u32) -> Host<'a> {
        Host {
            cloud_lane_cap: Some(cap),
            ..self
        }
    }

    /// The kernel host with the admission's reads through the named
    /// programs: what the launch and admit entries judge against.
    pub fn admitting(self, clis: Clis) -> Host<'a> {
        Host {
            admission: Some(AdmissionReads::through(clis)),
            ..self
        }
    }

    /// The host with the accounts judge's settings: a launch that names
    /// an account is judged on that account's room.
    pub fn judging(self, settings: &'a Settings) -> Host<'a> {
        Host {
            accounts: Some(settings),
            ..self
        }
    }
}

/// Why a slot is charged.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ChargeReason {
    /// The lane's recorded harness runs under its recorded start.
    Live,
    /// The lane's recorded detached wake turn runs.
    Wake,
    /// The lane is `preparing` under an open launch intent.
    Preparing,
    /// The lane's cloud session is recorded running: no process read can
    /// release it, so the record's word stands until its close.
    Session,
    /// An explicit reservation stands and has not lapsed.
    Reservation,
    /// Ownership could not be established: an unreadable identity, a record
    /// in flight with no identity, or a reservation with no readable term.
    /// Protected, never released.
    Unknown,
}

/// What a charge is attributed to.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "source", rename_all = "kebab-case")]
pub enum ChargeSource {
    Lane { item: String },
}

/// One slot charged, and why.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Charge {
    #[serde(flatten)]
    pub source: ChargeSource,
    pub reason: ChargeReason,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cause: Option<String>,
}

/// The cap and what charges it at one admission; `occupancy` is the number
/// of charges, one per lane, never per pid.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Occupancy {
    pub cap: u32,
    pub occupancy: u32,
    pub charges: Vec<Charge>,
}

/// The process identity a lane's `launch` names, where it names one.
pub(super) fn identity_of(launch: &LaunchIdentity) -> Option<Identity> {
    Some(Identity {
        pid: u32::try_from(launch.pid?).ok()?,
        start: launch.start.clone()?,
    })
}

/// One recorded identity and what the kernel answered for it.
#[derive(Debug, Clone)]
pub(super) struct Read {
    pub id: Identity,
    pub reading: Reading<Identity>,
}

/// The identities a lane record names, each read once through the one
/// identity reader: the harness its `launch` names and the detached wake
/// turn its `wake` names. `None` where the record names no such identity.
#[derive(Debug, Clone, Default)]
pub(super) struct Identities {
    pub launch: Option<Read>,
    pub wake: Option<Read>,
}

impl Identities {
    /// Whether the record names any identity at all.
    fn recorded(&self) -> bool {
        self.launch.is_some() || self.wake.is_some()
    }
}

/// Read the lane's recorded identities through the host's reader.
pub(super) fn read_identities(lane: &Lane, host: &Host) -> Identities {
    let read = |id: Option<Identity>| {
        id.map(|id| Read {
            reading: (host.still_runs)(&id),
            id,
        })
    };
    Identities {
        launch: read(lane.launch.as_ref().and_then(identity_of)),
        wake: read(super::wake::wake_identity(lane)),
    }
}

fn lane_source(lane: &Lane) -> ChargeSource {
    ChargeSource::Lane {
        item: lane.item.clone(),
    }
}

/// The charge one recorded identity derives: live charges `reason`, an
/// unreadable one protects as unknown with the reader's cause, a gone one
/// derives nothing.
fn execution_charge(lane: &Lane, read: Option<&Read>, reason: ChargeReason) -> Option<Charge> {
    match &read?.reading {
        Reading::Live(_) => Some(Charge {
            source: lane_source(lane),
            reason,
            cause: None,
        }),
        Reading::Unreadable { cause } => Some(Charge {
            source: lane_source(lane),
            reason: ChargeReason::Unknown,
            cause: Some((*cause).to_owned()),
        }),
        Reading::Gone => None,
    }
}

/// The slot one lane attempt charges, or none, from its identities as
/// read and its record. `launch_open` says whether a launch intent on the
/// lane is open. Each rule is read in order and the first that holds
/// decides, so a lane charges at most once; the identities come first, so
/// no status word is read as zero over a live or unreadable harness.
pub(super) fn lane_charge(
    lane: &Lane,
    launch_open: bool,
    now_secs: u64,
    ids: &Identities,
) -> Option<Charge> {
    let charge = |reason: ChargeReason, cause: Option<String>| Charge {
        source: lane_source(lane),
        reason,
        cause,
    };
    if let Some(charge) = execution_charge(lane, ids.launch.as_ref(), ChargeReason::Live) {
        return Some(charge);
    }
    if let Some(charge) = execution_charge(lane, ids.wake.as_ref(), ChargeReason::Wake) {
        return Some(charge);
    }
    if let Some(reservation) = &lane.reservation {
        match clock::epoch_secs(&reservation.until) {
            Some(until) if now_secs < until => {
                return Some(charge(
                    ChargeReason::Reservation,
                    Some(reservation.reason.clone()),
                ));
            }
            Some(_) => {}
            None => {
                return Some(charge(
                    ChargeReason::Unknown,
                    Some("reservation-until-invalid".to_owned()),
                ));
            }
        }
    }
    // A launch in progress holds its slot while its intent is open; expiry
    // alone cannot release a still-authorized launcher.
    if lane.status == LaneStatus::Preparing && launch_open {
        return Some(charge(ChargeReason::Preparing, None));
    }
    // A record in flight that names no identity claims execution this
    // reader cannot prove or disprove: protected. A stopped, parked or done
    // record with none was written after an authorized stop and holds
    // nothing.
    if !ids.recorded() && lane.status.in_flight() {
        return Some(charge(
            ChargeReason::Unknown,
            Some("identity-unrecorded".to_owned()),
        ));
    }
    None
}

/// What a lane's record still charges once a relaunch replaces its
/// `launch` and its `reservation`: the detached wake turn, which the
/// relaunch does not replace and which refuses it while it reads live or
/// unreadable.
fn retained_charge(lane: &Lane, ids: &Identities) -> Option<Charge> {
    execution_charge(lane, ids.wake.as_ref(), ChargeReason::Wake)
}

/// The fleet's one spelling, which its launch lock is named by: the state
/// file's directory resolved physically, else its own spelling with
/// trailing slashes off, then the file name.
fn canonical_fleet(path: &Path) -> String {
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let dir = path.parent().unwrap_or(Path::new(""));
    let dir = match fs::canonicalize(dir) {
        Ok(resolved) => resolved.display().to_string(),
        Err(_) => {
            let mut spelled = dir.display().to_string();
            while spelled.len() > 1 && spelled.ends_with('/') {
                spelled.pop();
            }
            spelled
        }
    };
    format!("{dir}/{name}")
}

/// The path the fleet launch lock is taken beside: the admission holds
/// `flock` on `<fleet>.launch.lock`, and `record::lock` names its file
/// `<base>.lock`, so the base is `<fleet>.launch` in the fleet's spelling.
pub(super) fn launch_lock_base(path: &Path) -> PathBuf {
    PathBuf::from(format!("{}.launch", canonical_fleet(path)))
}

/// Whether an open launch intent stands on `item`.
pub(super) fn launch_open(intents: &[Intent], item: &str) -> bool {
    intents
        .iter()
        .any(|i| i.open() && i.op == EffectOp::LaunchLane && i.target == item)
}

/// The slot one cloud session's record charges, or none: a standing
/// reservation as [`lane_charge`] reads it, a `preparing` row under its
/// open launch intent, a `running` session; a stopped, parked or done
/// record holds nothing.
pub(super) fn cloud_charge(lane: &Lane, launch_open: bool, now_secs: u64) -> Option<Charge> {
    let charge = |reason: ChargeReason, cause: Option<String>| Charge {
        source: lane_source(lane),
        reason,
        cause,
    };
    if let Some(reservation) = &lane.reservation {
        match clock::epoch_secs(&reservation.until) {
            Some(until) if now_secs < until => {
                return Some(charge(
                    ChargeReason::Reservation,
                    Some(reservation.reason.clone()),
                ));
            }
            Some(_) => {}
            None => {
                return Some(charge(
                    ChargeReason::Unknown,
                    Some("reservation-until-invalid".to_owned()),
                ));
            }
        }
    }
    match lane.status {
        LaneStatus::Preparing if launch_open => Some(charge(ChargeReason::Preparing, None)),
        LaneStatus::Running => Some(charge(ChargeReason::Session, None)),
        LaneStatus::Preparing | LaneStatus::Stopped | LaneStatus::Parked | LaneStatus::Done => None,
    }
}

/// What charges the lane cap now: every lane but the cloud sessions,
/// judged by [`lane_charge`] from identities read once each, except the
/// lane a relaunch replaces (`replacing`: its item and the identities the
/// caller read), which charges only what the relaunch does not replace.
pub(super) fn occupancy(
    lanes: &[Lane],
    intents: &[Intent],
    replacing: Option<(&str, &Identities)>,
    now_secs: u64,
    host: &Host,
) -> Occupancy {
    counted(
        lanes,
        intents,
        replacing,
        now_secs,
        host,
        host.lane_cap,
        false,
    )
}

/// What charges the cloud cap `cap` now: every cloud session's record
/// judged by [`cloud_charge`], except the one a relaunch replaces.
pub(super) fn cloud_occupancy(
    lanes: &[Lane],
    intents: &[Intent],
    replacing: Option<(&str, &Identities)>,
    now_secs: u64,
    host: &Host,
    cap: u32,
) -> Occupancy {
    counted(lanes, intents, replacing, now_secs, host, cap, true)
}

fn counted(
    lanes: &[Lane],
    intents: &[Intent],
    replacing: Option<(&str, &Identities)>,
    now_secs: u64,
    host: &Host,
    cap: u32,
    cloud: bool,
) -> Occupancy {
    let mut charges = Vec::new();
    for lane in lanes {
        if (lane.kind.as_deref() == Some(CLOUD_KIND)) != cloud {
            continue;
        }
        let own = replacing
            .filter(|(item, _)| *item == lane.item)
            .map(|(_, ids)| ids);
        let open = launch_open(intents, &lane.item);
        let charge = match (own, cloud) {
            (Some(ids), _) => retained_charge(lane, ids),
            (None, true) => cloud_charge(lane, open, now_secs),
            (None, false) => lane_charge(lane, open, now_secs, &read_identities(lane, host)),
        };
        charges.extend(charge);
    }
    Occupancy {
        cap,
        occupancy: u32::try_from(charges.len()).unwrap_or(u32::MAX),
        charges,
    }
}

#[allow(
    clippy::disallowed_methods,
    reason = "the fleet-spelling row makes the link it resolves"
)]
#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use serde_json::json;

    use super::super::testing::no_reads;
    use super::*;
    use crate::state::Reservation;

    /// A planted reader: the readings each identity answers with, `Gone`
    /// for one not planted.
    fn planted(
        answers: &HashMap<(u32, String), Reading<Identity>>,
    ) -> impl Fn(&Identity) -> Reading<Identity> + '_ {
        move |id: &Identity| {
            answers
                .get(&(id.pid, id.start.clone()))
                .cloned()
                .unwrap_or(Reading::Gone)
        }
    }

    fn lane(item: &str, status: LaneStatus, launch: Option<(u32, &str)>) -> Lane {
        let mut doc = json!({"item": item, "status": status.word()});
        if let Some((pid, start)) = launch {
            doc["launch"] = json!({"pane": "%7", "server": 41020, "pid": pid, "start": start});
        }
        serde_json::from_value(doc).unwrap()
    }

    fn live(pid: u32, start: &str) -> ((u32, String), Reading<Identity>) {
        (
            (pid, start.to_owned()),
            Reading::Live(Identity {
                pid,
                start: start.to_owned(),
            }),
        )
    }

    fn unreadable(pid: u32, start: &str) -> ((u32, String), Reading<Identity>) {
        (
            (pid, start.to_owned()),
            Reading::Unreadable {
                cause: "stat-unreadable",
            },
        )
    }

    /// The reason and cause `lane_charge` gives `lane` under `host`, with
    /// no launch intent open and the clock at zero.
    fn reason(lane: &Lane, host: &Host) -> Option<(ChargeReason, Option<String>)> {
        lane_charge(lane, false, 0, &read_identities(lane, host)).map(|c| (c.reason, c.cause))
    }

    /// The charge rules, identities before status words, each from
    /// a planted reading: the identities are read before any status word,
    /// so a live recorded identity charges on every status, `done`
    /// included; a gone one releases whatever the status word says; a
    /// reused pid (gone under the recorded start) releases; an unreadable
    /// one protects; a record in flight with no identity protects; a
    /// stopped, parked or done record with none holds nothing; a live or
    /// unreadable wake charges once its parent is gone.
    #[test]
    fn a_lane_charges_by_its_identity_reading_never_by_its_status_word() {
        let answers = HashMap::from([
            live(100, "ticks:1"),
            unreadable(200, "ticks:2"),
            live(300, "ticks:3"),
            unreadable(400, "ticks:4"),
        ]);
        let reader = planted(&answers);
        let host = Host {
            lane_cap: 4,
            cloud_lane_cap: None,
            still_runs: &reader,
            admission: Some(no_reads()),
            accounts: None,
        };
        for status in [
            LaneStatus::Running,
            LaneStatus::Preparing,
            LaneStatus::Stopped,
            LaneStatus::Parked,
            LaneStatus::Done,
        ] {
            assert_eq!(
                reason(&lane("A", status, Some((100, "ticks:1"))), &host),
                Some((ChargeReason::Live, None)),
                "{}: a live identity charges whatever the status word",
                status.word()
            );
            assert_eq!(
                reason(&lane("A", status, Some((200, "ticks:2"))), &host),
                Some((ChargeReason::Unknown, Some("stat-unreadable".to_owned()))),
                "{}: an unreadable identity protects, never zero",
                status.word()
            );
        }
        assert_eq!(
            reason(
                &lane("A", LaneStatus::Running, Some((100, "ticks:9"))),
                &host
            ),
            None,
            "a pid live under another start is a reused pid: released"
        );
        assert_eq!(
            reason(
                &lane("A", LaneStatus::Running, Some((900, "ticks:1"))),
                &host
            ),
            None,
            "an ended attempt releases its slot"
        );
        for status in [LaneStatus::Running, LaneStatus::Preparing] {
            assert_eq!(
                reason(&lane("A", status, None), &host),
                Some((
                    ChargeReason::Unknown,
                    Some("identity-unrecorded".to_owned())
                )),
                "{}: a record in flight with no identity is unknown ownership",
                status.word()
            );
        }
        for status in [LaneStatus::Stopped, LaneStatus::Parked, LaneStatus::Done] {
            assert_eq!(
                reason(&lane("A", status, None), &host),
                None,
                "{}: no identity recorded and not in flight holds nothing",
                status.word()
            );
            assert_eq!(
                reason(&lane("A", status, Some((900, "ticks:1"))), &host),
                None,
                "{}: a gone identity holds nothing",
                status.word()
            );
        }
        // A parent gone with its wake turn still working charges once, on
        // every status; an unreadable wake protects.
        for status in [LaneStatus::Running, LaneStatus::Stopped, LaneStatus::Done] {
            let mut woken = lane("A", status, Some((900, "ticks:1")));
            woken
                .extra
                .insert("wake".into(), json!({"pid": 300, "start": "ticks:3"}));
            assert_eq!(
                reason(&woken, &host),
                Some((ChargeReason::Wake, None)),
                "{}",
                status.word()
            );
            woken
                .extra
                .insert("wake".into(), json!({"pid": 400, "start": "ticks:4"}));
            assert_eq!(
                reason(&woken, &host),
                Some((ChargeReason::Unknown, Some("stat-unreadable".to_owned()))),
                "{}: an unreadable wake protects",
                status.word()
            );
        }
        let mut woken = lane("A", LaneStatus::Running, Some((900, "ticks:1")));
        woken
            .extra
            .insert("wake".into(), json!({"pid": "300", "start": "ticks:3"}));
        assert_eq!(
            reason(&woken, &host),
            Some((ChargeReason::Wake, None)),
            "a wake pid a jq writer wrote as a string reads"
        );
        woken
            .extra
            .insert("wake".into(), json!({"pid": 300, "start": "ticks:0"}));
        assert_eq!(
            reason(&woken, &host),
            None,
            "a wake over a reused pid is a turn over"
        );
        // A wake alone, the parent never recorded: the wake is the identity.
        let mut wake_only = lane("A", LaneStatus::Stopped, None);
        wake_only
            .extra
            .insert("wake".into(), json!({"pid": 300, "start": "ticks:3"}));
        assert_eq!(reason(&wake_only, &host), Some((ChargeReason::Wake, None)));
        // The preparing row an admission wrote charges while its launch
        // intent is open, whatever identity it carries yet.
        let preparing = lane("A", LaneStatus::Preparing, None);
        assert_eq!(
            lane_charge(&preparing, true, 0, &read_identities(&preparing, &host)).map(|c| c.reason),
            Some(ChargeReason::Preparing)
        );
        // A relaunch replacing the record keeps only the wake's charge.
        let relaunched = lane("A", LaneStatus::Stopped, Some((100, "ticks:1")));
        assert_eq!(
            retained_charge(&relaunched, &read_identities(&relaunched, &host)),
            None,
            "the launch identity is what the relaunch replaces"
        );
        assert_eq!(
            retained_charge(&woken, &read_identities(&woken, &host)),
            None
        );
        assert_eq!(
            retained_charge(&wake_only, &read_identities(&wake_only, &host)).map(|c| c.reason),
            Some(ChargeReason::Wake),
            "a live wake is owned execution the relaunch does not replace"
        );
    }

    /// A deliberate reservation holds its slot to its term and no longer:
    /// before `until` it charges whatever the identity reads,
    /// at and after it only a live identity does; a term that is no stamp
    /// protects; the identity is read before the reservation, so a live
    /// harness under a lapsed hold charges `live`.
    #[test]
    fn a_reservation_holds_to_its_term_and_expiry_never_slides() {
        let answers = HashMap::from([live(100, "ticks:1")]);
        let reader = planted(&answers);
        let host = Host {
            lane_cap: 4,
            cloud_lane_cap: None,
            still_runs: &reader,
            admission: Some(no_reads()),
            accounts: None,
        };
        let mut held = lane("A", LaneStatus::Stopped, Some((900, "ticks:1")));
        held.reservation = Some(Reservation {
            reason: "resume".into(),
            until: "2026-01-29T15:20:00Z".into(),
        });
        let until = clock::epoch_secs("2026-01-29T15:20:00Z").unwrap();
        let at = |lane: &Lane, now: u64| {
            lane_charge(lane, false, now, &read_identities(lane, &host))
                .map(|c| (c.reason, c.cause))
        };
        assert_eq!(
            at(&held, until - 1),
            Some((ChargeReason::Reservation, Some("resume".to_owned())))
        );
        assert_eq!(at(&held, until), None, "at the term the hold is over");
        assert_eq!(at(&held, until + 3600), None);
        held.reservation = Some(Reservation {
            reason: "resume".into(),
            until: "soon".into(),
        });
        assert_eq!(
            at(&held, 0),
            Some((
                ChargeReason::Unknown,
                Some("reservation-until-invalid".to_owned())
            ))
        );
        let mut running = lane("A", LaneStatus::Stopped, Some((100, "ticks:1")));
        running.reservation = held.reservation.clone();
        assert_eq!(
            at(&running, until + 3600),
            Some((ChargeReason::Live, None)),
            "the identity is read before the hold"
        );
    }

    /// A cloud session charged against the lane cap, or a local lane against
    /// the cloud cap, would let a full cloud cap admit a session and a full
    /// lane cap refuse one. A stopped session holds nothing.
    #[test]
    fn each_cap_counts_its_own_kind_and_a_cloud_session_charges_by_its_word() {
        let answers = HashMap::from([live(100, "ticks:1")]);
        let reader = planted(&answers);
        let host = Host {
            lane_cap: 1,
            cloud_lane_cap: Some(1),
            still_runs: &reader,
            admission: Some(no_reads()),
            accounts: None,
        };
        let cloud = |item: &str, status: LaneStatus| {
            let mut lane = lane(item, status, None);
            lane.kind = Some(CLOUD_KIND.to_owned());
            lane
        };
        let lanes = [
            lane("L", LaneStatus::Running, Some((100, "ticks:1"))),
            cloud("C", LaneStatus::Running),
            cloud("S", LaneStatus::Stopped),
            cloud("P", LaneStatus::Preparing),
        ];
        let local = occupancy(&lanes, &[], None, 0, &host);
        assert_eq!((local.cap, local.occupancy), (1, 1));
        assert_eq!(local.charges[0].source, lane_source(&lanes[0]));
        let cloud_count = cloud_occupancy(&lanes, &[], None, 0, &host, 1);
        assert_eq!((cloud_count.cap, cloud_count.occupancy), (1, 1));
        assert_eq!(cloud_count.charges[0].source, lane_source(&lanes[1]));
        assert_eq!(cloud_count.charges[0].reason, ChargeReason::Session);
        assert_eq!(
            cloud_charge(&lanes[3], true, 0).map(|c| c.reason),
            Some(ChargeReason::Preparing),
            "a preparing session under its open intent holds its slot"
        );
    }

    #[test]
    fn the_fleet_spelling_is_resolved_and_names_the_launch_lock() {
        let dir = tempfile::tempdir().unwrap();
        let real = fs::canonicalize(dir.path()).unwrap();
        let link = dir.path().join("link");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        assert_eq!(
            canonical_fleet(&link.join("workflow-state-oversee.json")),
            format!("{}/workflow-state-oversee.json", real.display())
        );
        assert_eq!(
            canonical_fleet(Path::new("/no/such/dir//workflow-state-oversee.json")),
            "/no/such/dir/workflow-state-oversee.json"
        );
        assert_eq!(
            launch_lock_base(&link.join("workflow-state-oversee.json")),
            real.join("workflow-state-oversee.json.launch"),
            "the shell launch lock is `<fleet>.launch.lock`"
        );
    }
}
