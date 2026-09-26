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
    items(scored, |row| !row.advisory.findings.is_empty())
}

/// Items a rule that applies to could not read: a declared plugin, a tree
/// past the memory bound, an unreadable hook. Their score is not a clean
/// one, because nobody earned it.
fn unread(scored: &[ItemSafety]) -> usize {
    items(scored, |row| !row.advisory.skipped.is_empty())
}

fn items(scored: &[ItemSafety], has: impl Fn(&ItemSafety) -> bool) -> usize {
    scored
        .iter()
        .filter(|row| has(row))
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

/// Whether the report above the ledger left detail out, and the flag that
/// draws it. No count: what a verbose run adds is lines of several kinds,
/// and a number kept beside them would drift from the drawing.
pub enum Folded {
    /// Nothing the verb could draw more of: it drew every line, or it has
    /// no flag that draws more.
    None,
    /// Detail left out, which `--verbose` draws.
    BehindVerbose,
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
/// that are not there, and `safety: clean` over a scan nobody ran claims
/// one. A verb that printed neither passes both empty and closes on its
/// head alone.
pub fn say_ledger(
    scope: &Scope,
    wrote: Wrote<'_>,
    blocked: &[Blocked],
    scored: &[ItemSafety],
    folded: Folded,
) {
    let (line, steps) = ledger(scope, wrote, blocked, scored, folded);
    ui::ledger(&line, &steps);
}

/// The same outcomes, from a run that acted on none of them. A preview
/// carries no next step: the conflict lines above it are where the ways
/// out are printed, and a closing line naming one of them again is the
/// same sentence twice on one screen.
pub fn say_preview(scope: &Scope, wrote: Wrote<'_>, blocked: &[Blocked], scored: &[ItemSafety]) {
    let (line, _) = ledger(scope, wrote, blocked, scored, Folded::None);
    ui::ledger(&line, &[]);
}

fn ledger(
    scope: &Scope,
    said: Wrote<'_>,
    blocked: &[Blocked],
    scored: &[ItemSafety],
    folded: Folded,
) -> (String, Vec<ui::Step>) {
    let skipped = blocked.len();
    let flagged = flagged(scored);
    let unread = unread(scored);
    let mut parts = vec![wrote(said.verb, said.count, skipped)];
    let mut steps: Vec<ui::Step> = Vec::new();
    // What this run's commit offer did in this project, read back off the
    // run's own record rather than passed down by each verb: the part has
    // to name what actually ran, and only the offer knows that.
    parts.extend(super::commit_offer::answered(scope).part());
    if skipped > 0 {
        parts.push(format!(
            "skipped {skipped} item{} on conflict",
            plural(skipped)
        ));
        steps.push(ui::Step::Decision(format!(
            "skipped — {}",
            conflict_exit(scope, blocked)
        )));
    }
    // A scored run says what safety found either way: a clean scan and
    // a scan nobody ran would otherwise close on the same line. Clean is
    // claimed only when every rule read every item: an item some rule
    // had no bytes for scores with no findings, and closing clean under
    // its own `not fully checked` line is the confusion this part exists
    // to prevent.
    if flagged > 0 {
        parts.push(format!(
            "flagged {flagged} item{} on safety",
            plural(flagged)
        ));
        // No verb reads these back: every surface that writes prints its
        // own advisory block, and this run's is the one printed above.
        steps.push(ui::Step::Decision(
            "flagged — the safety lines above".to_owned(),
        ));
    }
    if unread > 0 {
        parts.push(format!(
            "not fully checked on safety: {unread} item{}",
            plural(unread)
        ));
    } else if flagged == 0 && !scored.is_empty() {
        parts.push("safety: clean".to_owned());
    }
    // Last: what the report above left out is not an outcome of the run,
    // and every part before it points at lines that are there. Its step is
    // a hint, not a decision: nothing waits on reading more.
    match folded {
        Folded::None => {}
        Folded::BehindVerbose => {
            parts.push("details folded".to_owned());
            steps.push(ui::Step::Hint("folded — --verbose draws them".to_owned()));
        }
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

#[cfg(test)]
mod tests {
    use kendex_core::engine::{ItemSafety, SafetyTarget};
    use kendex_core::model::{HarnessId, ItemKind, Scope};
    use kendex_core::quality::{AuditResult, Finding, SafetyScore, Severity, SkippedRule};

    use super::*;

    fn row(name: &str, findings: Vec<Finding>, skipped: Vec<SkippedRule>) -> ItemSafety {
        ItemSafety {
            kind: ItemKind::Skill,
            name: name.to_owned(),
            targets: vec![SafetyTarget {
                harness: HarnessId::Claude,
                location: format!("/home/one/.claude/skills/{name}"),
            }],
            scope: Scope::Global,
            source: None,
            advisory: AuditResult {
                safety: SafetyScore {
                    score: match findings.is_empty() {
                        true => 100,
                        false => 75,
                    },
                    deductions: Vec::new(),
                },
                findings,
                mentions: Vec::new(),
                accepted: Vec::new(),
                skipped,
                quality: None,
                ruleset: kendex_core::quality::RULESET_VERSION,
            },
        }
    }

    fn finding() -> Finding {
        Finding {
            rule: "rce".to_owned(),
            severity: Severity::Critical,
            location: "SKILL.md".to_owned(),
            line: Some(1),
            message: "pipes a download into a shell".to_owned(),
            remediation: "download it first".to_owned(),
        }
    }

    fn unread_rule() -> SkippedRule {
        SkippedRule {
            rule: "rce".to_owned(),
            reason: "the plugin's own files are not readable here".to_owned(),
        }
    }

    /// One row per scored set: what the safety part of the closing line
    /// says. Clean is claimed only when every item was read in full.
    #[test]
    fn the_safety_part_claims_clean_only_when_every_item_was_read() {
        let wrote = || Wrote {
            verb: "refreshed",
            count: Some(1),
        };
        let rows: &[(&str, Vec<ItemSafety>, &str)] = &[
            ("nothing scored", vec![], "refreshed 1 change"),
            (
                "clean",
                vec![row("a", vec![], vec![])],
                "refreshed 1 change · safety: clean",
            ),
            (
                "flagged",
                vec![row("a", vec![finding()], vec![])],
                "refreshed 1 change · flagged 1 item on safety",
            ),
            (
                "unread only",
                vec![row("a", vec![], vec![unread_rule()])],
                "refreshed 1 change · not fully checked on safety: 1 item",
            ),
            (
                "clean beside unread",
                vec![
                    row("a", vec![], vec![]),
                    row("b", vec![], vec![unread_rule()]),
                ],
                "refreshed 1 change · not fully checked on safety: 1 item",
            ),
            (
                "flagged beside unread",
                vec![
                    row("a", vec![finding()], vec![]),
                    row("b", vec![], vec![unread_rule()]),
                ],
                "refreshed 1 change · flagged 1 item on safety · not fully checked on safety: 1 item",
            ),
        ];
        for (case, scored, want) in rows {
            let (line, _) = ledger(&Scope::Global, wrote(), &[], scored, Folded::None);
            assert_eq!(line, format!("global: {want}"), "{case}");
        }
    }
}
