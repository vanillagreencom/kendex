//! A recorded local lane's relaunch once its session ended, as after a
//! restart: the requests a recovery relaunch sends, composed from the lane's
//! record alone, so the caller names no field, picks no account and writes
//! no brief.

use std::path::{Path, PathBuf};

use agent_runtime::harness::Harness;
use serde_json::json;

use super::refused;
use crate::error::Result;
use crate::ops;
use crate::settings::Settings;
use crate::watch::lanes::{Composed, Composition, compose_relaunch};

/// The files a restart's relaunch keeps beside the fleet state, as a
/// relaunch names them: its brief and its two requests.
const STEM: &str = "restart-relaunch";

/// A composed restart relaunch: its close and launch requests, in the
/// order they apply, and the account the launch names.
pub struct Relaunch {
    pub close: PathBuf,
    pub launch: PathBuf,
    pub account: Option<String>,
}

/// The relaunch of `item`'s local lane from its record: the record's own
/// account judged first by the launch's own judge, with the lane's own
/// charge left out, so an account that cannot take the lane refuses with
/// the launch's own key before the close retires anything; then the
/// record's own relaunch on that account and the start brief, which
/// continues from the item's handoff, retiring the predecessor on the
/// `restart-recovery` ground. A record with no account is judged on none
/// and launches on none. A hosted lane runs where this machine's server is
/// not its own, and refuses `lane-hosted`.
pub fn composed(
    settings: &Settings,
    path: &Path,
    item: &str,
    host: &ops::Host,
    now: u64,
) -> Result<Relaunch> {
    let lane = super::lane_model::lane_of(path, item)?
        .ok_or_else(|| refused("lane-missing", &[("item", item)]))?;
    if let Some(at) = lane
        .host
        .as_deref()
        .filter(|h| !h.is_empty() && *h != "local")
    {
        return Err(refused("lane-hosted", &[("item", item), ("host", at)]));
    }
    let harness = lane
        .harness
        .as_deref()
        .and_then(Harness::parse)
        .ok_or_else(|| refused("harness-unrecorded", &[("item", item)]))?;
    let account = lane.account.clone().filter(|a| !a.is_empty());
    if let Some(account) = &account {
        ops::lane::named_account_room(
            settings,
            path,
            &ops::lane::NamedAccount {
                item,
                account,
                harness,
                model: lane.model.as_deref().filter(|m| !m.is_empty()),
                host: lane.host.as_deref(),
            },
            Some(item),
            host,
            now,
        )?;
    }
    let Composed { close, launch, .. } = compose_relaunch(
        &lane,
        harness,
        &Composition {
            stem: STEM,
            account: account.as_deref(),
            exclude: None,
            brief: super::launch::start_brief,
            ground: json!({"reason": "restart-recovery", "source": "overseer"}),
        },
        &settings.state_dir,
    )
    .map_err(|cause| refused("relaunch-unprepared", &[("item", item), ("cause", &cause)]))?;
    Ok(Relaunch {
        close,
        launch,
        account,
    })
}
