//! How a run ends. A count of writes alone answers "did anything happen"
//! and nothing else: the installs the plan refused and the scores worth
//! reading are both outcomes of the same run, and a reader who has to run
//! a second command to learn they exist was not told.
//!
//! One line, one part per outcome, and under it the next step for each
//! outcome it carries. A completed write is not one of those: it needs no
//! next step, and the count says all there is to say about it.
//!
//! Every verb that writes closes on this. What differs between them is
//! the verb in the head — refreshed, applied, installed, removed — and
//! nothing else: the parts are outcomes of a plan, and every verb that
//! runs a plan can have them.

use std::collections::BTreeSet;

use kendex_core::engine::ItemSafety;
use kendex_core::model::{ItemKind, Scope};

use super::offers::{Blocked, scope_flag};
use super::scope_label;
use crate::ui;

/// Items the safety block above carries a finding against, counted by
/// item identity. The printer folds readings that would print alike into
/// one block and can print two blocks for one item, so a count over items
/// is the only one that matches what "flagged N items" claims.
fn flagged(scored: &[ItemSafety]) -> usize {
    scored
        .iter()
        .filter(|row| !row.advisory.findings.is_empty())
        .map(|row| (row.kind, row.name.clone()))
        .collect::<BTreeSet<(ItemKind, String)>>()
        .len()
}

/// What a run wrote, in its own verb. `None` where the plan had nothing
/// to do — which is a current scope only where nothing was refused
/// either, since a plan empty *because* every write was refused is not a
/// scope that is up to date.
fn wrote(verb: &str, count: Option<usize>, skipped: usize) -> String {
    match (count, skipped) {
        (None, 0) => "up to date".to_owned(),
        (None, _) => format!("{verb} 0 changes"),
        (Some(n), _) => format!("{verb} {n} change{}", plural(n)),
    }
}

/// What a run wrote, said in its own verb, for a verb whose count is
/// never in doubt.
pub struct Wrote<'a> {
    pub verb: &'a str,
    /// `None` where the plan had nothing to do.
    pub count: Option<usize>,
}

/// The closing line of one scope's run, and the next step for each
/// outcome it carries. Zero parts are left off: a clean run says what it
/// did and stops.
///
/// Both parts are read off blocks the caller has already printed and
/// point the reader back at them, so a caller passes only what it printed:
/// a flagged count over a block nobody printed sends the reader to lines
/// that are not there. A verb that printed neither passes both empty and
/// closes on its head alone.
pub fn say_ledger(scope: &Scope, wrote: Wrote<'_>, blocked: &[Blocked], scored: &[ItemSafety]) {
    let (line, steps) = ledger(scope, wrote, blocked, scored);
    ui::ledger(&line, &steps);
}

/// The same outcomes, from a run that acted on none of them. A preview
/// carries no next step: the conflict lines above it are where the ways
/// out are printed, and a closing line naming one of them again is the
/// same sentence twice on one screen.
pub fn say_preview(scope: &Scope, wrote: Wrote<'_>, blocked: &[Blocked], scored: &[ItemSafety]) {
    let (line, _) = ledger(scope, wrote, blocked, scored);
    ui::ledger(&line, &[]);
}

fn ledger(
    scope: &Scope,
    said: Wrote<'_>,
    blocked: &[Blocked],
    scored: &[ItemSafety],
) -> (String, Vec<String>) {
    let skipped = blocked.len();
    let flagged = flagged(scored);
    let mut parts = vec![wrote(said.verb, said.count, skipped)];
    let mut steps: Vec<String> = Vec::new();
    if skipped > 0 {
        parts.push(format!(
            "skipped {skipped} item{} on conflict",
            plural(skipped)
        ));
        steps.push(format!("skipped — {}", conflict_exit(scope, blocked)));
    }
    if flagged > 0 {
        parts.push(format!(
            "flagged {flagged} item{} on safety",
            plural(flagged)
        ));
        // No verb reads these back: every surface that writes prints its
        // own advisory block, and this run's is the one printed above.
        steps.push("flagged — the safety lines above".to_owned());
    }
    (
        format!("{}: {}", scope_label(scope), parts.join(" · ")),
        steps,
    )
}

/// The next step for the skipped part. A command is named only where it
/// settles EVERY skipped item: the count above covers all of them, so a
/// remedy that covers some of them and is printed as the answer to the
/// count is a claim the output does not support. Where the set is mixed —
/// or where the way out differs item by item — the conflict lines above
/// are what carry each one's own, and pointing there is the whole answer.
fn conflict_exit(scope: &Scope, blocked: &[Blocked]) -> String {
    let every = |has: fn(&Blocked) -> bool| !blocked.is_empty() && blocked.iter().all(has);
    if !every(|item| item.replace) {
        return "see each conflict line above".to_owned();
    }
    let adopt = match every(|item| item.offer.as_ref().is_some_and(|offer| offer.adopt)) {
        true => ", or the kendex adopt line under each conflict above",
        false => "",
    };
    format!(
        "kendex apply --replace-unmanaged{}{adopt}",
        scope_flag(scope)
    )
}

fn plural(n: usize) -> &'static str {
    match n {
        1 => "",
        _ => "s",
    }
}
