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
//! mailbox, which the mail duty keeps as a [`STOP_ROW`] row per item, and as
//! the `stop` member of the item's row in the provider's `list --json`,
//! which the heartbeat asks of each `park=verb` host of a `running` or
//! `stopped` record ([`listed`]). The list's member stands only while the
//! sandbox is stopped, so it ends the current session whenever it came; a
//! notice ends it only where it came at or after the session began.
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
use std::path::Path;

use serde_json::Value;

use super::baseline::{Baseline, Change};
use super::events::Event;
use super::hosted::{self, Hosts, ParkKind, epoch_of, host_of};
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
/// `stopped` provider record of each item: a host of any other kind stops
/// no sandbox with its disk kept. A row names its item by its `label`,
/// `OWNER/REPO/ITEM` in any case, as the protocol's `list` row does. A host
/// answering exit `2` lists no stop.
pub fn listed(scripts: &Path, fleet: &FleetState) -> Listed {
    let lanes: Vec<&Lane> = latest(fleet)
        .into_values()
        .filter(|l| matches!(l.status, LaneStatus::Running | LaneStatus::Stopped))
        .filter(|l| l.provider_hosted())
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
            let suffix = format!("/{}", lane.item.to_ascii_lowercase());
            let member = rows
                .iter()
                .filter(|row| {
                    row.get("label")
                        .and_then(Value::as_str)
                        .is_some_and(|l| l.to_ascii_lowercase().ends_with(&suffix))
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
    /// The team's open items, each with whether a blocker holds it.
    pub open: &'a BTreeMap<String, bool>,
    /// The terminal reads of the `stopped` and `parked` records' items.
    pub terminal: &'a BTreeMap<String, TerminalState>,
}

/// The `lane-ended` lines, one per item whose latest record's harness has
/// ended while the item is open, in item order.
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
