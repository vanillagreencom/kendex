//! A recorded local lane's relaunch once its session ended, as after a
//! restart: the requests a recovery relaunch sends, composed from the lane's
//! record alone, so the caller names no field, picks no account and writes
//! no brief.

use std::path::{Path, PathBuf};

use agent_runtime::accounts::{PickAnswer, PickRequest};
use agent_runtime::harness::Harness;
use serde_json::{Value, json};

use super::refused;
use crate::error::Result;
use crate::ops::{self, accounts};
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
/// account judged first as the launch's own judge reads it (`lane pick
/// --replaces`), so an account that cannot take the lane refuses before
/// the close retires anything; then the record's own relaunch on that
/// account and the start brief, which continues from the item's handoff,
/// retiring the predecessor on the `restart-recovery` ground. A record with
/// no account takes no pick and launches on none. A hosted lane runs where
/// this machine's server is not its own, and refuses `lane-hosted`.
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
        let request = PickRequest {
            model: lane.model.clone().filter(|m| !m.is_empty()),
            lane: Some(account.clone()),
            projected: true,
            ..PickRequest::new(harness)
        };
        let lane_host = lane.host.as_deref().filter(|h| !h.is_empty());
        let answer =
            accounts::pick_fleet(settings, path, host, lane_host, Some(item), &request, now);
        match &answer {
            // No listing row names the account: the launch's judge lets it
            // through, so a relaunch does too.
            PickAnswer::Lane(_) | PickAnswer::NoRecord => {}
            PickAnswer::None { .. }
            | PickAnswer::Walled(_)
            | PickAnswer::Reserved(_)
            | PickAnswer::Retired { .. }
            | PickAnswer::Excluded(_)
            | PickAnswer::Unmeasured(_)
            | PickAnswer::ProviderUnmeasured { .. }
            | PickAnswer::Unbilled { .. }
            | PickAnswer::CloudRepoUnset(_)
            | PickAnswer::Unjudged { .. } => {
                let reply = answer.reply();
                let word = reply["answer"].as_str().unwrap_or_default();
                let mut fields = vec![
                    ("item", item),
                    ("account", account.as_str()),
                    ("answer", word),
                ];
                if let Some(cause) = reply["record"].get("cause").and_then(Value::as_str) {
                    fields.push(("cause", cause));
                }
                return Err(refused("account-unready", &fields));
            }
        }
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
