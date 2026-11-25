//! The ended lanes: every lane record whose harness ended while no tracker
//! read says its item ended, named on each heartbeat as one `lane-ended`
//! line with what the lane waits for, so no such lane holds its sandbox,
//! files and account room unnamed until its pull request closes.
//!
//! A harness has ended on a `stopped` or `parked` record by its status. On a
//! `running` record it has ended where the lane duty reported the lane
//! exited (its `lane-exited` row reads `|reported`), or where the fleet's
//! provider stopped its sandbox after the lane's current session began. That
//! stop comes as the provider's `sandbox-stopped` notice in the overseer's
//! mailbox from a sender on the owner's channel ([`notice`]), which the mail
//! duty keeps as a [`STOP_ROW`] row per item, and as
//! the `stop` member of the item's row in the provider's `list --json`,
//! which the heartbeat asks of each `park=verb` host of a `running` or
//! `stopped` record ([`listed`]). The list's member stands only while the
//! sandbox is stopped, so it ends the current session whenever it came; a
//! notice ends it only where it came at or after the session began.
//!
//! What the tracker says of an item is one [`ItemRead`] ([`Items::read`]):
//! open where the tracker duty's last team read holds it among the team's
//! open items, or where the terminal read of a `stopped` or `parked`
//! record answered open; ended where that terminal read answered ended; and
//! unread otherwise. The heartbeat holds the terminal reads only once a team
//! read ran, so unread covers a `running` record whose item is GitHub-tracked
//! or not among the team's open items, every item before the first team
//! read, and every item on a fleet with no `linear_team`. An ended item is
//! not named; an unread one is named with `tracker=unread`, never taken as
//! ended.
//!
//! An active `blocked` label holds the lane until it clears. Otherwise the
//! record's saved wait takes precedence over a blocking relation: a pull
//! request of the lane's own is a merge, an ask an owner answer, and a hold
//! or a dependency's pull request a blocker. A wait record that does not
//! parse is `unread`; no recorded wait on an item whose blockers no read answered
//! (an unread item, or one a terminal read alone holds open) is `unknown`;
//! neither is ever `nothing`.

use std::collections::BTreeMap;
use std::path::Path;

use serde_json::Value;

use super::baseline::{Baseline, Change};
use super::events::Event;
use super::hosted::{self, Hosts, ParkKind, epoch_of, host_of};
use super::lanes::lane_name;
use super::tracker::{OpenHold, TerminalState};
use crate::mailbox::Envelope;
use crate::ops::ParkWait;
use crate::state::{FleetState, Lane, LaneStatus, PARK_OWED};

/// `sandbox-stopped<TAB><item><TAB><at>|<why>`: the last stop the provider's
/// notice reported for the item, written by the mail duty and pruned by it
/// once no record of the item stands short of `done`.
pub const STOP_ROW: &str = "sandbox-stopped";

/// The lane duty's row whose value ends `|reported` once it said the lane
/// exited.
const EXITED_ROW: &str = "lane-exited";

/// What an ended lane waits for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Wait {
    Merge,
    Owner,
    Blocker,
    Nothing,
    /// The record's wait did not parse.
    Unread,
    /// No wait is recorded, and no tracker read answered for the item's
    /// blockers.
    Unknown,
}

impl Wait {
    pub fn word(self) -> &'static str {
        match self {
            Wait::Merge => "merge",
            Wait::Owner => "owner",
            Wait::Blocker => "blocker",
            Wait::Nothing => "nothing",
            Wait::Unread => "unread",
            Wait::Unknown => "unknown",
        }
    }
}

/// A sandbox stop the provider reported: when, and its own word for why.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Stop {
    pub at: String,
    pub why: String,
}

impl Stop {
    fn row(&self) -> String {
        format!("{}|{}", self.at, self.why)
    }

    fn of_row(value: &str) -> Option<Stop> {
        let (at, why) = value.split_once('|')?;
        Some(Stop {
            at: at.to_owned(),
            why: why.to_owned(),
        })
    }
}

/// The provider's notice of a sandbox it stopped, from the first line of a
/// message's text: `sandbox-stopped item=ITEM why=WHY at=UTC` with the
/// provider's other fields after them. The shape is fleet's (FLT-1791,
/// `bin/lane_host/lifecycle.py::stop_ended`, recorded on KEN-5527). A line
/// naming no `why` or `at`, such as the `stop-sandbox` verb's own
/// `sandbox-stopped item=ID`, is no notice.
///
/// A notice ends a lane's session, and the overseer's relaunch then stops an
/// idle harness, so it is read only from a sender on the owner's channel:
/// an `owner-note`, which `lane-mail send --item overseer --directive`
/// writes, or a `peer` envelope that no other repository's overseer
/// (`overseer:` prefix) wrote. A `data` envelope carries text from outside
/// input, such as an email's summary, and is never read. A stop later than
/// `wall`, the turn's own clock, is refused, so no stored stop can postdate
/// a later session's start.
pub fn notice(envelope: &Envelope, wall: u64) -> Option<(String, Stop)> {
    let trusted = match envelope.mail_class.as_deref() {
        Some("owner-note") => true,
        Some("peer") => !envelope
            .from
            .as_deref()
            .is_some_and(|from| from.starts_with("overseer:")),
        Some(_) | None => false,
    };
    if !trusted {
        return None;
    }
    let mut words = envelope.text.as_deref()?.lines().next()?.split_whitespace();
    if words.next() != Some("sandbox-stopped") {
        return None;
    }
    let fields: BTreeMap<&str, &str> = words.filter_map(|w| w.split_once('=')).collect();
    let field = |key: &str| fields.get(key).filter(|v| !v.is_empty()).copied();
    let (item, why, at) = (field("item")?, field("why")?, field("at")?);
    if epoch_of(at)? > wall {
        return None;
    }
    Some((
        item.to_owned(),
        Stop {
            at: at.to_owned(),
            why: why.to_owned(),
        },
    ))
}

/// The row change the notice of `item` asks for.
pub fn stop_change(item: &str, stop: &Stop) -> Change {
    Change::Set {
        kind: STOP_ROW.to_owned(),
        identity: item.to_owned(),
        value: stop.row(),
    }
}

/// The [`STOP_ROW`] rows no record of the fleet still needs: their item has
/// no record short of `done`.
pub fn stale_stops(baseline: &Baseline, fleet: &FleetState) -> Vec<Change> {
    baseline
        .identities(STOP_ROW)
        .into_iter()
        .filter(|item| {
            !fleet
                .lanes
                .iter()
                .any(|l| &l.item == item && l.status != LaneStatus::Done)
        })
        .map(|identity| Change::Clear {
            kind: STOP_ROW.to_owned(),
            identity,
        })
        .collect()
}

/// The `stop` member of a `list --json` row, read as fleet's FLT-1791 lists
/// it (recorded on KEN-5527): `{"at": UTC, "why": WORD}`, or
/// `{"unreadable": TEXT}` for a stop label the provider could not parse,
/// which keeps its words out of the line. Any other member is unreadable
/// too: the provider says the sandbox stopped, whatever it could not say of
/// the stop.
fn listed_stop(member: &Value) -> Stop {
    let word = |key: &str| {
        member
            .get(key)
            .and_then(Value::as_str)
            .filter(|v| !v.is_empty() && !v.contains(char::is_whitespace))
    };
    match (word("at"), word("why")) {
        (Some(at), Some(why)) => Stop {
            at: at.to_owned(),
            why: why.to_owned(),
        },
        (Some(_) | None, Some(_) | None) => Stop {
            at: "unreadable".to_owned(),
            why: "unreadable".to_owned(),
        },
    }
}

/// The stops the provider lists, by item, and the reads that failed, each
/// the heartbeat's partial failure with its host.
#[derive(Debug, Default)]
pub struct Listed {
    pub stops: BTreeMap<String, Stop>,
    pub failed: Vec<String>,
}

/// One `list --json` per `park=verb` host of the latest `running` or
/// `stopped` provider record of each item whose item no read answered
/// ended: a host of any other kind stops no sandbox with its disk kept. A
/// row names its lane by its whole `label`, `OWNER/REPO/ITEM` in any case,
/// as the protocol's `list` row does, `OWNER/REPO` the record's `repo`: two
/// repositories' lanes can share an item key on one host. A record naming
/// no repository takes no listed stop; a hosted launch refuses a request
/// naming none. A host answering exit `2` lists no stop.
///
/// A `stopped` record's host is read here although [`Hosts`] serves the
/// lane duty's in-flight lanes: the heartbeat asks it once per heartbeat,
/// not once per pass, and a host that is gone is the heartbeat's named
/// failure until the record closes, which is the stopped lane the line
/// exists to name.
pub fn listed(scripts: &Path, fleet: &FleetState, items: &Items) -> Listed {
    let lanes: Vec<&Lane> = latest(fleet)
        .into_values()
        .filter(|l| matches!(l.status, LaneStatus::Running | LaneStatus::Stopped))
        .filter(|l| l.provider_hosted() && items.read(&l.item) != ItemRead::Ended)
        .collect();
    let hosts = Hosts::read(scripts, lanes.iter().copied());
    let mut out = Listed::default();
    out.failed.extend(hosts.unreadable().map(str::to_owned));
    let mut by_host: BTreeMap<&str, Vec<&Lane>> = BTreeMap::new();
    for lane in lanes {
        if let Ok(caps) = hosts.of(lane)
            && caps.park == ParkKind::Verb
        {
            by_host.entry(host_of(lane)).or_default().push(lane);
        }
    }
    for (host, lanes) in by_host {
        let rows = match hosted::list_rows(scripts, host) {
            Ok(Some(rows)) => rows,
            Ok(None) => continue,
            Err(cause) => {
                out.failed
                    .push(format!("lane-list-unread host={host} cause={cause}"));
                continue;
            }
        };
        for lane in lanes {
            let Some(repo) = lane.repo.as_deref().filter(|r| !r.is_empty()) else {
                continue;
            };
            let label = format!("{repo}/{}", lane.item);
            let member = rows
                .iter()
                .filter(|row| {
                    row.get("label")
                        .and_then(Value::as_str)
                        .is_some_and(|l| l.eq_ignore_ascii_case(&label))
                })
                .find_map(|row| row.get("stop"));
            if let Some(member) = member {
                out.stops.insert(lane.item.clone(), listed_stop(member));
            }
        }
    }
    out
}

/// Each item's latest record.
fn latest(fleet: &FleetState) -> BTreeMap<&str, &Lane> {
    let mut latest: BTreeMap<&str, &Lane> = BTreeMap::new();
    for lane in &fleet.lanes {
        latest.insert(lane.item.as_str(), lane);
    }
    latest
}

/// What the tracker duty's last read says of the lanes' items.
pub struct Items<'a> {
    /// The team's open items, each with what holds it; `None`
    /// before the tracker duty's first team read.
    pub open: Option<&'a BTreeMap<String, OpenHold>>,
    /// The terminal reads of the `stopped` and `parked` records' items.
    pub terminal: &'a BTreeMap<String, TerminalState>,
}

/// What the tracker's reads say of one item.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ItemRead {
    /// Among the team's open items, with what holds it.
    Open(OpenHold),
    /// Open by a terminal read alone, which reads no blocker.
    OpenUnjudged,
    Ended,
    Unread,
}

impl Items<'_> {
    /// The one answer for `item`: the team's open list first, then the
    /// terminal read.
    pub fn read(&self, item: &str) -> ItemRead {
        if let Some(hold) = self.open.and_then(|open| open.get(item)) {
            return ItemRead::Open(*hold);
        }
        match self.terminal.get(item) {
            Some(TerminalState::Open) => ItemRead::OpenUnjudged,
            Some(TerminalState::Completed | TerminalState::Canceled) => ItemRead::Ended,
            None => ItemRead::Unread,
        }
    }
}

/// The `lane-ended` lines, one per item whose latest record's harness ended
/// while no tracker read says the item ended, in item order.
pub fn events(
    fleet: &FleetState,
    items: &Items,
    listed: &BTreeMap<String, Stop>,
    baseline: &Baseline,
) -> Vec<Event> {
    latest(fleet)
        .into_values()
        .filter_map(|lane| ended(lane, items, listed.get(&lane.item), baseline))
        .collect()
}

fn ended(lane: &Lane, items: &Items, listed: Option<&Stop>, baseline: &Baseline) -> Option<Event> {
    let stop = listed.cloned().or_else(|| {
        baseline
            .get(STOP_ROW, &lane.item)
            .and_then(Stop::of_row)
            .filter(|stop| this_session(lane, stop))
    });
    let harness_ended = match lane.status {
        LaneStatus::Stopped | LaneStatus::Parked => true,
        LaneStatus::Running => {
            stop.is_some()
                || baseline
                    .get(EXITED_ROW, &lane_name(lane))
                    .is_some_and(|row| row.ends_with("|reported"))
        }
        LaneStatus::Preparing | LaneStatus::Done => false,
    };
    if !harness_ended {
        return None;
    }
    let read = items.read(&lane.item);
    let saved = || recorded_wait(lane);
    let waits = match read {
        ItemRead::Open(OpenHold::Label) => Wait::Blocker,
        ItemRead::Open(OpenHold::Relation) => saved().unwrap_or(Wait::Blocker),
        ItemRead::Open(OpenHold::Unblocked) => saved().unwrap_or(Wait::Nothing),
        ItemRead::OpenUnjudged | ItemRead::Unread => saved().unwrap_or(Wait::Unknown),
        ItemRead::Ended => return None,
    };
    Some(Event::LaneEnded {
        item: lane.item.clone(),
        lane: lane.status,
        waits,
        stop,
        tracker_read: read != ItemRead::Unread,
    })
}

/// Whether the stop ended the record's current session: it came at or after
/// the session began. A record naming no session start takes any stop.
fn this_session(lane: &Lane, stop: &Stop) -> bool {
    let Some(at) = epoch_of(&stop.at) else {
        return false;
    };
    let since = lane
        .session_since
        .as_deref()
        .or(lane.launched_at.as_deref());
    since.and_then(epoch_of).is_none_or(|since| at >= since)
}

/// The wait the record names, the pull request before the ask before the
/// hold; `None` where it names none.
fn recorded_wait(lane: &Lane) -> Option<Wait> {
    let record = match lane.status {
        LaneStatus::Parked => lane.extra.get("parked"),
        LaneStatus::Preparing | LaneStatus::Running | LaneStatus::Stopped | LaneStatus::Done => {
            lane.extra
                .get(PARK_OWED)
                .or_else(|| lane.extra.get("pending_pr"))
        }
    };
    let wait = match record.filter(|v| !v.is_null()) {
        // A park is its record: a parked lane naming none has no wait read.
        None if lane.status == LaneStatus::Parked => return Some(Wait::Unread),
        None => return None,
        Some(value) => match serde_json::from_value::<ParkWait>(Value::clone(value)) {
            Ok(wait) => wait,
            Err(_) => return Some(Wait::Unread),
        },
    };
    // A dependency wait, `until_pr` with no pull request of the lane's own,
    // waits on another item's merge: a blocker, relaunched once it ends.
    if wait.pr.is_some() {
        Some(Wait::Merge)
    } else if wait.until_pr.is_some() {
        Some(Wait::Blocker)
    } else if wait.ask.as_deref().is_some_and(|a| !a.is_empty()) {
        Some(Wait::Owner)
    } else if wait.hold {
        Some(Wait::Blocker)
    } else {
        None
    }
}
