//! The model a rank on the tier ladder names on one harness.
//!
//! `kendex tier-model HARNESS RANK` prints the model id the tier table in
//! `kendex_core::harness::models` resolves rank RANK to on HARNESS, 1 being
//! the top tier. It refuses an unknown harness, a rank off the ladder, and a
//! tier that names no model on that harness.

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
