//! The ended lanes: every lane record whose harness has ended while its
//! item is open, named on each heartbeat as one `lane-ended` line with
//! what the lane waits for, so no such lane holds its sandbox, files and
//! account room unnamed until its pull request closes.
//!
//! A harness has ended on a `stopped` or `parked` record by its status. On a
//! `running` record it has ended where the lane duty reported the lane
//! exited (its `lane-exited` row reads `|reported`), or where the fleet's
//! provider stopped its sandbox after the lane's current session began. That
//! stop comes as the provider's `sandbox-stopped` notice in the overseer's
//! mailbox, which the mail duty keeps as a [`STOP_ROW`] row per item.
//!
//! The item is open where the tracker duty's last read holds it among the
//! team's open items, or, for a `stopped` or `parked` record, where its
//! terminal read answered open. A lane whose item no tracker read answered
//! for is not judged: the heartbeat's `owed unread` line names a tracker
//! that read nothing.
//!
//! What the lane waits for is its record's recorded wait (the park, the park
//! it owes, or the pull request a relaunch carried from its park), then the
//! tracker's blocker: a pull request is a merge, an ask an owner answer, a
//! hold or a blocking item a blocker. A wait record that does not parse is
//! `unread`, never `nothing`.

use std::collections::BTreeMap;

use serde_json::Value;

use super::baseline::{Baseline, Change};
use super::events::Event;
use super::hosted::epoch_of;
use super::lanes::lane_name;
use super::tracker::TerminalState;
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
}

impl Wait {
    pub fn word(self) -> &'static str {
        match self {
            Wait::Merge => "merge",
            Wait::Owner => "owner",
            Wait::Blocker => "blocker",
            Wait::Nothing => "nothing",
            Wait::Unread => "unread",
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
/// The notice is read whatever class the mailbox gave its message: it only
/// names a lane to the overseer, and a relaunch it leads to refuses a lane
/// whose harness still runs.
pub fn notice(text: &str) -> Option<(String, Stop)> {
    let mut words = text.lines().next()?.split_whitespace();
    if words.next() != Some("sandbox-stopped") {
        return None;
    }
    let fields: BTreeMap<&str, &str> = words.filter_map(|w| w.split_once('=')).collect();
    let field = |key: &str| fields.get(key).filter(|v| !v.is_empty()).copied();
    let (item, why, at) = (field("item")?, field("why")?, field("at")?);
    epoch_of(at)?;
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

/// What the tracker duty's last read says of the lanes' items.
pub struct Items<'a> {
    /// The team's open items, each with whether a blocker holds it.
    pub open: &'a BTreeMap<String, bool>,
    /// The terminal reads of the `stopped` and `parked` records' items.
    pub terminal: &'a BTreeMap<String, TerminalState>,
}

/// The `lane-ended` lines, one per item whose latest record's harness has
/// ended while the item is open, in item order.
pub fn events(fleet: &FleetState, items: &Items, baseline: &Baseline) -> Vec<Event> {
    let mut latest: BTreeMap<&str, &Lane> = BTreeMap::new();
    for lane in &fleet.lanes {
        latest.insert(lane.item.as_str(), lane);
    }
    latest
        .into_values()
        .filter_map(|lane| ended(lane, items, baseline))
        .collect()
}

fn ended(lane: &Lane, items: &Items, baseline: &Baseline) -> Option<Event> {
    let stop = baseline
        .get(STOP_ROW, &lane.item)
        .and_then(Stop::of_row)
        .filter(|stop| this_session(lane, stop));
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
    let blocked = match items.open.get(&lane.item) {
        Some(blocked) => *blocked,
        None => match items.terminal.get(&lane.item) {
            Some(TerminalState::Open) => false,
            Some(TerminalState::Completed | TerminalState::Canceled) | None => return None,
        },
    };
    Some(Event::LaneEnded {
        item: lane.item.clone(),
        lane: lane.status,
        waits: wait_of(lane, blocked),
        stop,
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

/// The recorded wait first, the pull request before the ask before the
/// hold, then the tracker's blocker.
fn wait_of(lane: &Lane, blocked: bool) -> Wait {
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
        None if lane.status == LaneStatus::Parked => return Wait::Unread,
        None => None,
        Some(value) => match serde_json::from_value::<ParkWait>(Value::clone(value)) {
            Ok(wait) => Some(wait),
            Err(_) => return Wait::Unread,
        },
    };
    if let Some(wait) = wait {
        if wait.pr.is_some() || wait.until_pr.is_some() {
            return Wait::Merge;
        }
        if wait.ask.as_deref().is_some_and(|a| !a.is_empty()) {
            return Wait::Owner;
        }
        if wait.hold {
            return Wait::Blocker;
        }
    }
    if blocked {
        Wait::Blocker
    } else {
        Wait::Nothing
    }
}
