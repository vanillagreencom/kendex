//! How a refresh ends. A count of writes alone answers "did anything
//! happen" and nothing else: the installs the plan refused and the scores
//! worth reading are both outcomes of the same run, and a reader who has
//! to run a second command to learn they exist was not told.
//!
//! One line, one part per outcome, and under it the next step for each
//! outcome it carries. A completed write is not one of those: it needs no
//! next step, and the count says all there is to say about it.

use std::collections::BTreeSet;

use kendex_core::engine::EngineReport;
use kendex_core::model::{ItemKind, Scope};

use super::offers::{Blocked, scope_flag};
use super::say;

/// Items the safety block above carries a finding against. Counted from
/// the rows that block was printed from, so the number and the lines it
/// sends the reader to are one reading of one set of bytes.
fn flagged(report: &EngineReport) -> usize {
    report
        .safety
        .iter()
        .filter(|row| !row.advisory.findings.is_empty())
        .map(|row| (row.kind, row.name.clone()))
        .collect::<BTreeSet<(ItemKind, String)>>()
        .len()
}

/// The closing line of one scope's refresh, and the next step for each
/// outcome it carries. `wrote` is `None` where the plan had nothing to do.
/// Zero parts are left off: a clean run says what it did and stops.
pub fn say_ledger(scope: &Scope, wrote: Option<usize>, blocked: &[Blocked], report: &EngineReport) {
    let skipped = blocked.len();
    let flagged = flagged(report);
    let head = match (wrote, skipped) {
        // Nothing to write and nothing refused is a scope that is current.
        // Nothing to write *because* everything was refused is not.
        (None, 0) => "up to date".to_owned(),
        (None, _) => "refreshed 0 changes".to_owned(),
        (Some(n), _) => format!("refreshed {n} change{}", plural(n)),
    };
    let mut parts = vec![head];
    if skipped > 0 {
        parts.push(format!(
            "skipped {skipped} item{} on conflict",
            plural(skipped)
        ));
    }
    if flagged > 0 {
        parts.push(format!(
            "flagged {flagged} item{} on safety",
            plural(flagged)
        ));
    }
    say(&format!("{}: {}", scope.label(), parts.join(" · ")));
    if skipped > 0 {
        say(&format!("  skipped — {}", conflict_exit(scope, blocked)));
    }
    if flagged > 0 {
        // No verb reads these back: every surface that writes prints its
        // own advisory block, and this run's is the one printed above.
        say("  flagged — the safety lines above");
    }
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
