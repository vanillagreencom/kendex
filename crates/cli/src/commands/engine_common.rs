use kendex_core::engine::{DriftRow, DriftState, EngineReport};
use kendex_core::env::Env;
use kendex_core::model::HarnessId;

use std::io::IsTerminal;

use super::advisory::Listing;
use super::{CliResult, note, say, warn};
use crate::ui;

pub fn parse_harnesses(values: &[String]) -> Result<Vec<HarnessId>, String> {
    values
        .iter()
        .flat_map(|v| v.split(','))
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(|v| HarnessId::parse(v).ok_or(format!("unknown harness '{v}'")))
        .collect()
}

/// What a pass over a scope's marketplaces has to say: one warning per
/// source it could not bring current or tidy after, and the count of
/// older snapshots that pass removed from the source cache. The count
/// covers the marketplace sync alone: a snapshot planning publishes for
/// an item pin judges its neighbours too, and reports nothing. A pass
/// that removed nothing prints no count.
pub fn print_synced(synced: &kendex_core::remote::Synced) {
    for line in &synced.notes {
        warn(&format!("warning: {line}"));
    }
    let removed = synced.removed_snapshots;
    if removed > 0 {
        note(&format!(
            "cache: removed {removed} older marketplace snapshot{}",
            if removed == 1 { "" } else { "s" }
        ));
    }
}

/// The pass a writing verb closes on; the call sites are the list and
/// `docs/architecture/trash.md` § Boundaries owns it. The trash is brought
/// within its bounds (`kendex_core::trash::retain`) once the verb's own
/// writes are done, and what went is said in the verb's own output, so a
/// person who never runs `kendex trash` still learns that kendex is
/// reclaiming. A pass that stopped is a warning, never a failure of the
/// verb: the writes are on disk, and the next of those verbs retries it.
pub fn tidy_trash(env: &Env) {
    match kendex_core::trash::retain(env) {
        Ok(removed) => print_trashed(removed),
        Err(kendex_core::trash::Stopped { removed, reason }) => {
            print_trashed(removed);
            warn(&format!("warning: trash: pass stopped ({reason})"));
        }
    }
}

/// A pass that removed nothing prints no count.
fn print_trashed(removed: usize) {
    if removed > 0 {
        note(&format!(
            "trash: removed {removed} older entr{}",
            if removed == 1 { "y" } else { "ies" }
        ));
    }
}

/// The whole plan on a terminal, and back to the caller the items it
/// refused — one derivation, so a closing count and the conflict lines it
/// sends the reader to are one reading of one set of rows.
///
/// A verb that closes on a ledger passes [`Listing::Attention`]; one that
/// closes on none passes [`Listing::Every`], so a clean package still says
/// it was scored.
pub fn print_report(
    env: &Env,
    report: &EngineReport,
    listing: Listing,
) -> Vec<super::offers::Blocked> {
    let blocked = super::attention::print_attention(env, report, listing).blocked;
    for warning in &report.warnings {
        let target = match warning.harness {
            Some(harness) => format!("{} ({})", warning.name, harness.display_name()),
            None => warning.name.clone(),
        };
        warn(&format!("warning: {target}: {}", warning.message));
        if let Some(fix) = &warning.remediation {
            say(&format!("  fix: {}", fix));
        }
    }
    if report.plan.is_empty() {
        // "nothing to do" directly under a conflict reads as "and nothing
        // you can do" — the run has plenty to do, once the reader picks.
        say(match blocked.is_empty() {
            false => "nothing to do until you settle the conflicts above",
            true => "nothing to do",
        });
        return blocked;
    }
    let ops = report.plan.ops.len();
    // The op list is what the confirm below is an answer to: a reader
    // asked to approve a count was never shown what it covers.
    say(&format!("plan: {} change{}", ops, plural(ops)));
    for op in &report.plan.ops {
        say(&format!("  - {}", op.line()));
    }
    blocked
}

fn plural(n: usize) -> &'static str {
    match n {
        1 => "",
        _ => "s",
    }
}

/// Content in a managed folder that no declaration and no lock claims.
/// apply leaves it exactly where it is (invariant 6) — which is why it has
/// to be said here: seen in `list` and nowhere else, it reads as checked
/// and passing rather than as never looked at.
pub fn print_unmanaged(drift: &[DriftRow]) {
    let rows: Vec<&DriftRow> = drift
        .iter()
        .filter(|row| row.state == DriftState::Unmanaged)
        .collect();
    if rows.is_empty() {
        return;
    }
    // A footnote, not one more verdict: said in its own voice so it does
    // not join the block of rows above it.
    note(&format!(
        "not managed: {} package{} kendex did not install and does not touch",
        rows.len(),
        if rows.len() == 1 { "" } else { "s" }
    ));
    for row in rows.iter().take(UNMANAGED_SHOWN) {
        say(&format!(
            "  - {} {} [{}] {}",
            row.kind.name(),
            row.name,
            row.harness.display_name(),
            row.detail
        ));
    }
    if rows.len() > UNMANAGED_SHOWN {
        say(&format!("  … and {} more", rows.len() - UNMANAGED_SHOWN));
    }
}

/// Enough to recognise what is there without burying the plan above it.
const UNMANAGED_SHOWN: usize = 10;

/// Prompted apply: `--yes` skips the prompt; a non-tty without `--yes`
/// refuses rather than guessing.
pub fn confirm_and_execute(env: &Env, report: &EngineReport, yes: bool) -> CliResult {
    // Nothing to write is not a write of nothing: the caller has already
    // said "nothing to do", and a completion line under it reads as a run
    // that finished something.
    if report.plan.is_empty() {
        return Ok(());
    }
    let applied = confirm_and_apply(env, report, yes)?;
    say(&format!("wrote {applied} change(s)"));
    Ok(())
}

/// The same prompt and the same write, handing back what it wrote instead
/// of announcing it — for a verb that closes on a summary of its own.
pub fn confirm_and_apply(
    env: &Env,
    report: &EngineReport,
    yes: bool,
) -> Result<usize, Box<dyn std::error::Error>> {
    // The count is the consequence: an answer given to a bare "apply?" is
    // an answer to the verb's name rather than to what it writes. An empty
    // plan asks nothing and writes nothing, and still reaches the offer.
    if !report.plan.is_empty() {
        let ops = report.plan.ops.len();
        ask_before_writing(&format!("write {ops} change{}?", plural(ops)), yes)?;
    }
    apply_report(env, report)
}

/// Execute a report's plan — the one way a CLI verb holding an
/// `EngineReport` writes it, and where the commit offer is made.
///
/// A plan can take a package away whatever the verb — `remove`, a manifest
/// edited by hand and applied, a sweep, an unsubscribe that drops its
/// packages — and the package's declared uninstaller has to run while the
/// scripts it names are still on disk. Executing `report.plan` directly
/// skips that, so no verb does: every report goes through here, and only a
/// bare `Plan` with no report behind it, which by construction drops no
/// package, is executed on its own.
/// The offer rides here rather than in each verb: a write into a project
/// checkout is exactly what leaves files git can see, and a verb added
/// later cannot forget to ask. It is made at most once per project per
/// run, whichever verb reached it first, and `update-pi` — which writes
/// into a project's `.pi` directory without a plan — calls it itself.
///
/// It runs for every project scope the run reached, an empty plan
/// included: a scope with nothing left to write can still hold the files
/// an earlier run left uncommitted, and `run again with --commit` has to
/// mean something. The empty plan itself writes nothing.
pub fn apply_report(env: &Env, report: &EngineReport) -> Result<usize, Box<dyn std::error::Error>> {
    let applied = match report.plan.is_empty() {
        true => 0,
        false => {
            super::repo_effects::undo(&report.plan.scope, report)?;
            // The wait covers the write and nothing after it: the offer
            // asks a question, and a spinner still ticking under it would
            // draw over the answer.
            let _writing = ui::spinner("writing");
            kendex_core::apply::execute(env, &report.plan)?.applied
        }
    };
    let mut generated = report.generated.clone();
    let bot_instructions = kendex_core::bot_instructions::render(env, &report.plan.scope)?;
    if let Some(skipped) = bot_instructions.skipped() {
        say(&skipped.line());
        if super::repo_effects::set_up_beside_main(env, &report.plan.scope, skipped)? {
            kendex_core::bot_instructions::add_to_generated(
                env,
                &report.plan.scope,
                &mut generated,
            )?;
        }
    }
    bot_instructions.add_to(&mut generated);
    super::commit_offer::after_writing(env, &report.plan.scope, &generated)?;
    Ok(applied)
}

/// The answer every verb needs before it writes, asked one way. `--yes`
/// skips it; a run with nobody to ask refuses before its first write
/// rather than guessing, and says which flag would have answered it.
pub fn ask_before_writing(question: &str, yes: bool) -> CliResult {
    require_yes_in_non_interactive(yes)?;
    if yes {
        return Ok(());
    }
    match ui::confirm(question)? {
        true => Ok(()),
        false => Err("cancelled — these changes were not written".into()),
    }
}

/// Refuse a write that needs consent when no prompt can be shown.
///
/// A multi-scope verb calls this after it has planned every selected scope.
/// This keeps a later scope's missing answer from arriving after an earlier
/// scope has already written.
pub fn require_yes_in_non_interactive(yes: bool) -> CliResult {
    if yes || std::io::stdin().is_terminal() {
        return Ok(());
    }
    Err("no terminal to ask at — pass --yes to write without asking".into())
}

/// A refresh failure: any per-item failure or a locked item missing from
/// its source is a hard error. An orphaned Pi package is the one Pi row
/// that is not one: a refresh keeps every orphan and reports it, and
/// `apply` or `remove` takes it.
pub fn refresh_failures(report: &EngineReport) -> Vec<String> {
    report
        .notes
        .iter()
        .filter(|n| {
            n.contains("not found in source")
                || n.contains("missing at")
                || n.contains("not fetched yet")
                || n.contains("refused catalog read")
        })
        .cloned()
        .chain(
            report
                .drift
                .iter()
                .filter(|row| {
                    row.kind == kendex_core::model::ItemKind::PiExtension
                        && row.state != DriftState::Orphaned
                })
                .map(|row| format!("{}: {}", row.name, row.detail)),
        )
        .collect()
}
