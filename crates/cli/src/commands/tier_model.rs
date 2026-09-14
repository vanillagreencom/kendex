//! The model a rank on the tier ladder names on one harness.
//!
//! The orch skill's `oversee-succeed` reads its overseer preference as
//! `harness:rank:effort` and asks this verb for the model, so the tier table
//! in `kendex_core::harness::models` stays the one owner of which model a
//! rank means.

use clap::Args;

use kendex_core::harness::models::{TIERS, resolve_model};
use kendex_core::model::HarnessId;

use super::{CliResult, answer};

#[derive(Args)]
pub struct TierModelArgs {
    /// The harness the model is named for
    harness: String,
    /// The position on the tier ladder, 1 for the top tier
    rank: usize,
}

pub fn run(args: TierModelArgs) -> CliResult {
    let harness = HarnessId::parse(&args.harness)
        .ok_or_else(|| format!("unknown harness '{}'", args.harness))?;
    let tier = args
        .rank
        .checked_sub(1)
        .and_then(|index| TIERS.get(index))
        .ok_or_else(|| {
            format!(
                "rank {} is not on the tier ladder (1-{})",
                args.rank,
                TIERS.len()
            )
        })?;
    let model = resolve_model(harness, tier).id.ok_or_else(|| {
        format!(
            "tier '{tier}' names no model on {}; it inherits the session's",
            harness.name()
        )
    })?;
    answer(&model);
    Ok(())
}
