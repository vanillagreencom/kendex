//! The account wall record: one file per account under `walls/` in the
//! account records' root, written for a wall a reader judged current from
//! the harness's own weekly report, and read by the listing, which holds
//! the account walled until the reset the banner named.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::error::Result;
use crate::record::cksum;

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
/// under the account records' root.
pub fn account_wall_path(account_state: &Path, config_dir: &str) -> PathBuf {
    let canon = canon(config_dir);
    account_state
        .join("walls")
        .join(format!("{}.json", cksum(canon.as_bytes())))
}

/// The wall `lanes` reads: the account and the epoch second its weekly
/// window resets at.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountWall {
    pub config_dir: String,
    pub resets_at: u64,
    /// The latest first sighting of a banner naming this reset: a fall of
    /// the weekly figure from one read before it proves no reset after the
    /// wall. Absent where `lib/account-wall.sh` wrote the record, which no
    /// fall then frees.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seen_at: Option<u64>,
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
    /// When the lane's banner was first seen.
    pub first_seen: u64,
    pub banner: String,
    pub channel: WallChannel,
}

/// Record the wall where it is one (`account_wall_record`): a named
/// account, a reset ahead of `now`, the harness's own weekly report. The
/// path written, or `None` where nothing is. Renamed into place whole, so
/// `lanes` never reads half a record.
#[allow(
    clippy::disallowed_methods,
    reason = "the account wall record, under the account records' root, read for the sighting it holds and written whole and renamed into place, the bytes `lib/account-wall.sh` reads"
)]
pub fn record_account_wall(
    account_state: &Path,
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
    let path = account_wall_path(account_state, &write.config_dir);
    let dir = path.parent().unwrap_or(&path);
    std::fs::create_dir_all(dir).map_err(|e| crate::Error::io("create", dir, e))?;
    let config_dir = canon(&write.config_dir);
    // Every walled lane on the account renews one record each pass: the
    // latest sighting is kept while the reset stands, so a lane whose banner
    // stood before a second wall cannot write back a sighting that a fall
    // before that wall satisfies.
    let renewed = std::fs::read_to_string(&path)
        .ok()
        .and_then(|text| serde_json::from_str::<AccountWall>(&text).ok())
        .filter(|held| held.config_dir == config_dir && held.resets_at == reset)
        .and_then(|held| held.seen_at);
    let record = AccountWall {
        config_dir,
        resets_at: reset,
        seen_at: Some(renewed.map_or(write.first_seen, |seen| seen.max(write.first_seen))),
    };
    let temp = path.with_extension(format!("json.{}.tmp", std::process::id()));
    let text = serde_json::to_string(&record).map_err(|e| {
        crate::Error::refused("wall-record-unwritable", &[("cause", &e.to_string())])
    })?;
    std::fs::write(&temp, text).map_err(|e| crate::Error::io("write", &temp, e))?;
    if let Err(e) = std::fs::rename(&temp, &path) {
        let _ = std::fs::remove_file(&temp);
        return Err(crate::Error::io("replace", &path, e));
    }
    Ok(Some(path))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The checksum `lanes` names the record by, pinned to one run of the
    /// host's `cksum` over the fixture account (`printf '%s'
    /// '/home/me/.eclaude' | cksum` gives `2455569205 17`).
    #[test]
    fn the_record_name_is_the_posix_cksum_of_the_account() {
        use crate::record::cksum;
        assert_eq!(cksum(b"/home/me/.eclaude"), 2_455_569_205);
        assert_eq!(cksum(b""), 0xFFFF_FFFF);
        assert_eq!(
            account_wall_path(Path::new("/s"), "/home/me/.eclaude/"),
            PathBuf::from("/s/walls/2455569205.json")
        );
    }

    /// A quoted banner, a session wall or a Pi row read through the pane's
    /// rule must record no wall.
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

    /// Two walled lanes on one account renew one record: a lane whose
    /// banner stood before the other's must not write back its earlier
    /// sighting while the reset stands, and a banner naming another reset
    /// starts its own.
    #[test]
    fn a_renewal_keeps_the_latest_sighting_while_the_reset_stands() {
        let dir = tempfile::tempdir().unwrap();
        let claims = dir.path().join("claims");
        let renew = |reset: u64, first_seen: u64| {
            let path = record_account_wall(
                &claims,
                &AccountWallWrite {
                    config_dir: "/home/me/.eclaude".to_owned(),
                    reset: Some(reset),
                    now: 1_000,
                    first_seen,
                    banner: format!("{DRAWN}You've hit your weekly limit \u{b7} resets Oct 4, 6pm"),
                    channel: WallChannel::Pane,
                },
            )
            .unwrap()
            .unwrap();
            let held: AccountWall =
                serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
            held.seen_at
        };
        assert_eq!(renew(9_000, 100), Some(100));
        assert_eq!(renew(9_000, 500), Some(500));
        assert_eq!(renew(9_000, 100), Some(500), "the earlier lane's sighting");
        assert_eq!(renew(9_600, 300), Some(300), "another reset");
    }
}
