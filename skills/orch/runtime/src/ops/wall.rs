//! The wall records the observation duty keeps (decisions 125 (1), 130,
//! 160 (1)): the account wall record under `walls/` beside the claim store,
//! which `lanes` reads an account walled by until the reset its banner
//! named (`lib/account-wall.sh`), and the lane record's own wall,
//! `lanes[].walled` opened on the first sighting and closed into `pauses`
//! when the wall ends (`oversee-watch:3393`, `wall_pause`).
//!
//! The account record is written only for a wall the duty judged current
//! for the live identity (`watch/lanes.rs`, `wall`): a banner an earlier
//! process drew never reaches this writer, which is how the record is keyed
//! to the process identity while its bytes stay what `lanes` reads. The
//! lane wall is a fleet transition dispatched under its [`super::Request`]
//! variant (decision 153 (3)), applied by the observation duty through
//! `ops::apply`.

// Every reading is matched variant by variant (decision 105).
#![deny(clippy::wildcard_enum_match_arm)]

use std::path::{Path, PathBuf};

use agent_runtime::clock;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::Env;
use crate::error::Result;
use crate::state::{self, Document};

/// POSIX `cksum`: CRC-32 over the bytes then over the byte count, least
/// significant byte first until none is left, complemented (POSIX.1-2017,
/// `cksum`). The legacy names the record by `cksum` of the account's
/// canonical spelling (`lib/account-wall.sh`, `account_wall_file`).
pub fn cksum(bytes: &[u8]) -> u32 {
    fn feed(mut crc: u32, byte: u8) -> u32 {
        crc ^= u32::from(byte) << 24;
        for _ in 0..8 {
            crc = if crc & 0x8000_0000 != 0 {
                (crc << 1) ^ 0x04C1_1DB7
            } else {
                crc << 1
            };
        }
        crc
    }
    let mut crc = bytes.iter().fold(0u32, |crc, b| feed(crc, *b));
    let mut len = bytes.len();
    while len > 0 {
        crc = feed(crc, (len & 0xff) as u8);
        len >>= 8;
    }
    !crc
}

/// One spelling per account (`lib/lane-claims.sh`, `lane_claims_canon`):
/// the resolved path where the directory stands, else the spelling with
/// its trailing slashes off.
pub fn canon(config_dir: &str) -> String {
    if !config_dir.is_empty()
        && let Ok(resolved) = std::fs::canonicalize(config_dir)
    {
        return resolved.display().to_string();
    }
    let mut text = config_dir;
    while text.len() > 1 && text.ends_with('/') {
        text = &text[..text.len() - 1];
    }
    text.to_owned()
}

/// The record file for `config_dir`: `walls/<cksum of the canon>.json`
/// beside the claim store (`account_wall_dir`, `account_wall_file`).
pub fn account_wall_path(claim_store: &Path, config_dir: &str) -> PathBuf {
    let canon = canon(config_dir);
    claim_store
        .parent()
        .unwrap_or(claim_store)
        .join("walls")
        .join(format!("{}.json", cksum(canon.as_bytes())))
}

/// The wall `lanes` reads: the account and the epoch second its weekly
/// window resets at.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountWall {
    pub config_dir: String,
    pub resets_at: u64,
}

/// Where a banner was read, which decides what counts as the harness's own
/// report (`account_wall_record`'s CHANNEL).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WallChannel {
    /// The pane: only a line opening with Claude Code's own message prefix
    /// is the harness's, never one the lane quoted.
    Pane,
    /// A Pi lane's session row, whose error message is the harness's own.
    Row,
}

/// What opens the line Claude Code draws its usage-limit message on,
/// measured in Claude Code 2.1.288 (`ACCOUNT_WALL_DRAWN`).
const DRAWN: &str = "  \u{23bf} \u{a0}";

/// Whether a line of `banner` is the harness's own weekly-limit report on
/// `channel`.
pub fn harness_own_weekly(banner: &str, channel: WallChannel) -> bool {
    banner.lines().any(|line| {
        let body = match channel {
            WallChannel::Pane => match line.strip_prefix(DRAWN) {
                Some(body) => body,
                None => return false,
            },
            WallChannel::Row => line,
        };
        let Some(rest) = body.find("You").map(|at| &body[at + 3..]) else {
            return false;
        };
        rest.contains("ve hit your weekly limit")
    })
}

/// What the duty asks recorded for a walled lane each pass it stands.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountWallWrite {
    pub config_dir: String,
    /// The reset the banner names, `None` where the grammar read none.
    pub reset: Option<u64>,
    pub now: u64,
    pub banner: String,
    pub channel: WallChannel,
}

/// Record the wall where it is one (`account_wall_record`): a named
/// account, a reset ahead of `now`, the harness's own weekly report. The
/// path written, or `None` where nothing is. Renamed into place whole, so
/// `lanes` never reads half a record.
#[allow(
    clippy::disallowed_methods,
    reason = "the account wall record, the watch's own file beside the claim store, written whole and renamed into place as the legacy wrote it (decision 125 (1))"
)]
pub fn record_account_wall(
    claim_store: &Path,
    write: &AccountWallWrite,
) -> Result<Option<PathBuf>> {
    let Some(reset) = write.reset else {
        return Ok(None);
    };
    if write.config_dir.is_empty()
        || reset <= write.now
        || !harness_own_weekly(&write.banner, write.channel)
    {
        return Ok(None);
    }
    let path = account_wall_path(claim_store, &write.config_dir);
    let dir = path.parent().unwrap_or(&path);
    std::fs::create_dir_all(dir).map_err(|e| agent_runtime::Error::io("create", dir, e))?;
    let record = AccountWall {
        config_dir: canon(&write.config_dir),
        resets_at: reset,
    };
    let temp = path.with_extension(format!("json.{}.tmp", std::process::id()));
    let text = serde_json::to_string(&record).map_err(|e| {
        agent_runtime::Error::refused("wall-record-unwritable", &[("cause", &e.to_string())])
    })?;
    std::fs::write(&temp, text).map_err(|e| agent_runtime::Error::io("write", &temp, e))?;
    if let Err(e) = std::fs::rename(&temp, &path) {
        let _ = std::fs::remove_file(&temp);
        return Err(agent_runtime::Error::io("replace", &path, e).into());
    }
    Ok(Some(path))
}

/// The marker the legacy watch reads a running wall relaunch by
/// (`oversee-watch:4651`, `wall_relaunch_marker`, `wall_relaunch_pending`,
/// `wall_relaunch_outcomes`): `wall-relaunch.<lane>` under the watch state
/// directory, `{item, since, log}`, with the launch's exit status landing
/// beside it as `.exit`. Written here before the relaunch starts, a value
/// the runtime mints for the legacy's reader (decision 94 (b)).
pub fn relaunch_marker_path(watch_state_dir: &Path, lane: &str) -> PathBuf {
    let safe: String = lane
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') {
                c
            } else {
                '_'
            }
        })
        .collect();
    watch_state_dir.join(format!("wall-relaunch.{safe}"))
}

/// Write the relaunch marker, any earlier exit status beside it removed.
#[allow(
    clippy::disallowed_methods,
    reason = "the wall relaunch marker, the watch's own file the legacy outcome reader follows, written before the detached relaunch starts (decision 94 (b))"
)]
pub fn write_relaunch_marker(marker: &Path, item: &str, since: u64, log: &Path) -> Result<()> {
    let exit = marker.with_extension(
        marker
            .extension()
            .map(|e| format!("{}.exit", e.to_string_lossy()))
            .unwrap_or_else(|| "exit".to_owned()),
    );
    match std::fs::remove_file(&exit) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(agent_runtime::Error::io("remove", &exit, e).into()),
    }
    let text = json!({"item": item, "since": since, "log": log.display().to_string()}).to_string();
    std::fs::write(marker, text).map_err(|e| agent_runtime::Error::io("write", marker, e))?;
    Ok(())
}

/// What one pass read of a lane's wall (`wall_pause`'s observation column).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "reading", rename_all = "kebab-case")]
pub enum WallReading {
    /// A wall judged current for the live identity, first seen at the
    /// epoch second.
    Walled { first_seen: u64 },
    /// The lane read with no wall standing, a gone window included.
    Clear,
    /// The pane or the rows could not be read: the record is left as it is.
    Unavailable,
}

/// One lane's wall observation, by the item and window its record names.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WallObservation {
    pub item: String,
    pub window: String,
    #[serde(flatten)]
    pub reading: WallReading,
}

/// Record the fleet's lane walls as this pass observed them: a wall opened
/// as `walled.at` on its first sighting, a standing wall that ended closed
/// into `pauses` with cause `walled`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RecordWallPauses {
    pub observations: Vec<WallObservation>,
}

/// Whether the transition moved any lane record.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WallPausesRecorded {
    pub changed: bool,
}

/// The legacy `wall_pause` transition over every running lane record
/// (`oversee-watch:3400-3416`): a lane observed `unavailable` keeps its
/// record; a standing `walled.at` at or before now that the observation
/// does not name again closes into `pauses` (where it is before now) and
/// goes; a walled observation at or before now opens `walled.at`. A lane
/// no observation names reads as clear.
pub fn record_wall_pauses(
    path: &Path,
    doc: &mut Document,
    r: &RecordWallPauses,
    env: &Env,
) -> Result<WallPausesRecorded> {
    let now = env.now_secs;
    let before = doc.clone();
    let Some(Value::Array(lanes)) = doc.get_mut("lanes") else {
        return Ok(WallPausesRecorded { changed: false });
    };
    for lane in lanes.iter_mut() {
        let Value::Object(lane) = lane else { continue };
        let running = lane.get("status").and_then(Value::as_str) == Some("running");
        let item = lane.get("item").and_then(Value::as_str).unwrap_or("");
        let window = lane.get("window").and_then(Value::as_str);
        let observed = r
            .observations
            .iter()
            .find(|o| o.item == item)
            .filter(|o| running && window == Some(o.window.as_str()))
            .map(|o| &o.reading);
        let from = match observed {
            Some(WallReading::Unavailable) => continue,
            Some(WallReading::Walled { first_seen }) => Some(*first_seen),
            Some(WallReading::Clear) | None => None,
        };
        let standing = match lane.get("walled") {
            None | Some(Value::Null) => None,
            Some(Value::Object(walled)) => {
                let at = walled.get("at").and_then(Value::as_str).unwrap_or("");
                match clock::epoch_secs(at) {
                    Some(epoch) => Some((epoch, at.to_owned())),
                    None => {
                        return Err(agent_runtime::Error::refused(
                            "wall-record-shape",
                            &[
                                ("path", &path.display().to_string()),
                                ("item", item),
                                ("field", "walled.at"),
                                ("value", at),
                            ],
                        )
                        .into());
                    }
                }
            }
            Some(Value::Bool(_) | Value::Number(_) | Value::String(_) | Value::Array(_)) => {
                return Err(agent_runtime::Error::refused(
                    "wall-record-shape",
                    &[
                        ("path", &path.display().to_string()),
                        ("item", item),
                        ("field", "walled"),
                    ],
                )
                .into());
            }
        };
        if let Some((at, stamp)) = standing
            && at <= now
            && from != Some(at)
        {
            if at < now {
                let pause = json!({"from": stamp, "to": clock::iso_utc(now), "cause": "walled"});
                state::array_mut(path, lane, "pauses")?.push(pause);
            }
            state::delete(lane, "walled");
        }
        if let Some(from) = from
            && from <= now
        {
            state::set(lane, "walled", json!({"at": clock::iso_utc(from)}));
        }
    }
    Ok(WallPausesRecorded {
        changed: *doc != before,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The checksum `lanes` names the record by, pinned to one run of the
    /// host's `cksum` over the fixture account (`printf '%s'
    /// '/home/me/.eclaude' | cksum` gives `2455569205 17`).
    #[test]
    fn the_record_name_is_the_posix_cksum_of_the_account() {
        assert_eq!(cksum(b"/home/me/.eclaude"), 2_455_569_205);
        assert_eq!(cksum(b""), 0xFFFF_FFFF);
        assert_eq!(
            account_wall_path(Path::new("/s/claims"), "/home/me/.eclaude/"),
            PathBuf::from("/s/walls/2455569205.json")
        );
    }

    /// Defect: a quoted banner, a session wall or a Pi row read through the
    /// pane's rule records a wall (`tests/oversee_watch_usage_limit.sh`
    /// `WALL_ROW_QUOTED`, `WALL_ROW_SESSION`; `tests/oversee_watch_pi_lanes.sh`).
    #[test]
    fn only_the_harness_s_own_weekly_report_is_a_wall() {
        let drawn = format!("{DRAWN}You've hit your weekly limit \u{b7} resets Oct 4, 6pm");
        assert!(harness_own_weekly(&drawn, WallChannel::Pane));
        assert!(!harness_own_weekly(
            &format!("  {drawn}"),
            WallChannel::Pane
        ));
        assert!(!harness_own_weekly(
            &format!("{DRAWN}You've hit your session limit \u{b7} resets 9:50am"),
            WallChannel::Pane
        ));
        assert!(harness_own_weekly(
            "429 You've hit your weekly limit \u{b7} resets Oct 4, 6pm (UTC)",
            WallChannel::Row
        ));
        assert!(!harness_own_weekly(
            "You've hit your weekly limit \u{b7} resets Oct 4, 6pm (UTC)",
            WallChannel::Pane
        ));
    }

    fn env(now_secs: u64) -> Env {
        Env {
            now_secs,
            now_nanos: u128::from(now_secs) * 1_000_000_000,
            nonce: 1,
            owner: None,
        }
    }

    fn fleet(lane: Value) -> Document {
        let Value::Object(doc) = json!({"lanes": [lane]}) else {
            unreachable!()
        };
        doc
    }

    fn observed(window: &str, reading: WallReading) -> RecordWallPauses {
        RecordWallPauses {
            observations: vec![WallObservation {
                item: "KEN-2".into(),
                window: window.into(),
                reading,
            }],
        }
    }

    /// The legacy transition on the bytes `tests/oversee_watch_wall_relaunch.sh`
    /// pins (`ITEM_PAUSE`, the `walled` and `reused` rows): a wall first
    /// seen at 16:00 opens `walled.at`; the pass that reads it clear at
    /// 16:10 closes it into `pauses`; a wall seen again opens a new
    /// `walled.at`; an unavailable read and a record the observation does
    /// not match keep their record.
    #[test]
    fn a_wall_opens_walled_at_and_closes_into_pauses_as_the_legacy_wrote_them() {
        let path = Path::new("/f/workflow-state-oversee.json");
        let at_1600 = 1_788_364_800;
        let mut doc = fleet(json!({"item": "KEN-2", "window": "gh-2", "status": "running"}));
        let opened = record_wall_pauses(
            path,
            &mut doc,
            &observed(
                "gh-2",
                WallReading::Walled {
                    first_seen: at_1600,
                },
            ),
            &env(at_1600 + 240),
        )
        .unwrap();
        assert!(opened.changed);
        assert_eq!(
            doc["lanes"][0]["walled"],
            json!({"at": "2026-09-02T16:00:00Z"})
        );
        let same = record_wall_pauses(
            path,
            &mut doc,
            &observed(
                "gh-2",
                WallReading::Walled {
                    first_seen: at_1600,
                },
            ),
            &env(at_1600 + 480),
        )
        .unwrap();
        assert!(!same.changed, "the standing wall is kept");
        let held = record_wall_pauses(
            path,
            &mut doc,
            &observed("gh-2", WallReading::Unavailable),
            &env(at_1600 + 600),
        )
        .unwrap();
        assert!(!held.changed, "an unavailable read settles nothing");
        let closed = record_wall_pauses(
            path,
            &mut doc,
            &observed("gh-2", WallReading::Clear),
            &env(at_1600 + 600),
        )
        .unwrap();
        assert!(closed.changed);
        assert_eq!(doc["lanes"][0].get("walled"), None);
        assert_eq!(
            doc["lanes"][0]["pauses"],
            json!([{"from": "2026-09-02T16:00:00Z", "to": "2026-09-02T16:10:00Z", "cause": "walled"}])
        );
        let again = record_wall_pauses(
            path,
            &mut doc,
            &observed(
                "gh-2",
                WallReading::Walled {
                    first_seen: at_1600 + 600,
                },
            ),
            &env(at_1600 + 840),
        )
        .unwrap();
        assert!(again.changed);
        assert_eq!(
            doc["lanes"][0]["walled"],
            json!({"at": "2026-09-02T16:10:00Z"})
        );
        // A record whose window is not the observed one is not its lane.
        let mut other = fleet(json!({"item": "KEN-2", "window": "gh-9", "status": "running"}));
        let unmatched = record_wall_pauses(
            path,
            &mut other,
            &observed(
                "gh-2",
                WallReading::Walled {
                    first_seen: at_1600,
                },
            ),
            &env(at_1600 + 240),
        )
        .unwrap();
        assert!(!unmatched.changed);
        // A stopped record's standing wall closes whatever is observed.
        let mut stopped = fleet(json!({
            "item": "KEN-2", "window": "gh-2", "status": "stopped",
            "walled": {"at": "2026-09-02T16:00:00Z"}
        }));
        record_wall_pauses(
            path,
            &mut stopped,
            &observed(
                "gh-2",
                WallReading::Walled {
                    first_seen: at_1600,
                },
            ),
            &env(at_1600 + 600),
        )
        .unwrap();
        assert_eq!(stopped["lanes"][0].get("walled"), None);
        assert_eq!(stopped["lanes"][0]["pauses"].as_array().unwrap().len(), 1);
    }
}
