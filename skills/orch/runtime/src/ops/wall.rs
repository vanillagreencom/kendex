//! The wall records the observation duty keeps: the account wall record
//! under `walls/` beside the claim store,
//! which `lanes` reads an account walled by until the reset its banner
//! named (`lib/account-wall.sh`), and the lane record's own wall,
//! `lanes[].walled` opened on the first sighting and closed into `pauses`
//! when the wall ends.
//!
//! The account record is written only for a wall the duty judged current
//! for the live identity (`watch/lanes.rs`, `wall`): a banner an earlier
//! process drew never reaches this writer, which is how the record is keyed
//! to the process identity while its bytes stay what `lanes` reads. The
//! lane wall is a fleet transition dispatched under its [`super::Request`]
//! variant, applied by the observation duty through
//! `ops::apply`.

// Every reading is matched variant by variant.
#![deny(clippy::wildcard_enum_match_arm)]

use agent_runtime::record::{self, Document};
use std::path::{Path, PathBuf};

use agent_runtime::clock;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::error::Result;
use agent_runtime::journal::Env;

/// The marker a running wall relaunch is read by, in the released watch's
/// shape (its `wall_relaunch_marker`, `wall_relaunch_pending`,
/// `wall_relaunch_outcomes`): `wall-relaunch.<lane>` under the watch state
/// directory, `{item, since, log}`, with the launch's exit status landing
/// beside it as `.exit`. Written here before the relaunch starts.
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
    reason = "the wall relaunch marker, the watch's own file the released outcome reader follows, written before the detached relaunch starts"
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

/// The wall-pause transition over every running lane record: a lane
/// observed `unavailable` keeps its
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
                record::array_mut(path, lane, "pauses")?.push(pause);
            }
            record::delete(lane, "walled");
        }
        if let Some(from) = from
            && from <= now
        {
            record::set(lane, "walled", json!({"at": clock::iso_utc(from)}));
        }
    }
    Ok(WallPausesRecorded {
        changed: *doc != before,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

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

    /// The transition on the released record's bytes: a wall first
    /// seen at 16:00 opens `walled.at`; the pass that reads it clear at
    /// 16:10 closes it into `pauses`; a wall seen again opens a new
    /// `walled.at`; an unavailable read and a record the observation does
    /// not match keep their record.
    #[test]
    fn a_wall_opens_walled_at_and_closes_into_pauses() {
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
