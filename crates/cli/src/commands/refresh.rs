use kendex_core::engine::{PlanOptions, plan_apply};
use kendex_core::env::Env;
use kendex_core::lock::{load as load_lock, lock_path};

use super::engine_common::{
    apply_report, ask_before_writing, confirm_and_apply, print_conflicts, print_drift, print_notes,
    print_safety, refresh_failures,
};
use super::ledger::{Wrote, say_ledger};
use super::{CliResult, resolve_scopes, say, scope_label, warn};
use crate::scope::ScopeFilter;
use crate::ui;

/// Regenerate every declared installation, and re-derive what those
/// declarations pull in — a dependency that appeared upstream, one that went
/// away. Regenerating is automatic; changing *what is installed* is shown
/// first and needs an answer. Orphans nobody derived are left alone:
/// `remove` and `apply` clean those up.
#[derive(clap::Args)]
pub struct RefreshArgs {
    #[arg(short = 'g', long)]
    global: bool,
    /// project | global | all (default all)
    #[arg(long)]
    scope: Option<String>,
    /// Per-item detail instead of the compact summary
    #[arg(short = 'v', long)]
    verbose: bool,
    /// Accept changes to what is installed without asking
    #[arg(short = 'y', long)]
    yes: bool,
    /// Overwrite installations you edited by hand
    #[arg(long)]
    discard_edits: bool,
    /// The commit offer's answer, without asking
    #[command(flatten)]
    _commit: crate::commands::commit_offer::CommitFlags,
}

/// What this refresh would add to or drop from the installed set — the part
/// that needs an answer before it runs.
fn print_set_changes(
    scope: &kendex_core::model::Scope,
    report: &kendex_core::engine::EngineReport,
) {
    say(&format!(
        "{}: this changes what is installed",
        scope_label(scope)
    ));
    for change in &report.set_changes {
        say_set_change(change);
    }
}

fn say_set_change(change: &kendex_core::engine::SetChange) {
    let verb = match change.direction {
        kendex_core::engine::SetDirection::Add => "install",
        kendex_core::engine::SetDirection::Remove => "remove",
    };
    say(&format!(
        "  - {verb} {} {} for {} — {}",
        change.kind.name(),
        change.name,
        change.harness.display_name(),
        change.reason
    ));
}

fn refreshed(count: Option<usize>) -> Wrote<'static> {
    Wrote {
        verb: "refreshed",
        count,
    }
}

/// What a run owes the scopes it got through, whether it got through all
/// of them or stopped at a cancel: their snapshots derived, and the
/// closing line each one earned. Skipped on a cancel, writes are left on
/// disk the run said nothing about, and the next session-start check
/// reads a stale snapshot.
///
/// The snapshot warnings come first because a warning under a closing
/// line is a run that ended twice.
fn finish_scopes(env: &Env, reached: &[kendex_core::model::Scope], closing: Vec<Closing>) {
    record_snapshots(env, reached);
    for scope in closing {
        say_ledger(
            &scope.scope,
            refreshed(scope.count),
            &scope.blocked,
            &scope.scored,
        );
    }
}

/// The deep work just ran for every scope; the snapshot is what the next
/// session-start check reads instead of redoing it. A scope whose
/// snapshot will not derive is a line, never a failure: what was written
/// was written, and the next deep pass rewrites the file.
fn record_snapshots(env: &Env, scopes: &[kendex_core::model::Scope]) {
    for scope in scopes {
        if matches!(
            kendex_core::manifest::load(&kendex_core::manifest::manifest_path(env, scope)),
            Ok(kendex_core::manifest::ManifestFile::Current(_))
        ) && let Err(error) = kendex_core::drift::snapshot::record(env, scope)
        {
            warn(&format!("warning: snapshot not derived ({})", error));
        }
    }
}

/// One scope's outcome, held until the run has nothing left to say.
///
/// The snapshot pass runs after every scope is written and can warn, and
/// a warning under a closing line is a run that ended twice. Held here,
/// each scope still closes on its own ledger and every one of them is
/// genuinely last.
struct Closing {
    scope: kendex_core::model::Scope,
    count: Option<usize>,
    blocked: Vec<super::offers::Blocked>,
    scored: Vec<kendex_core::engine::ItemSafety>,
}

/// What one scope's write came to: the plan it ended on, and what that
/// plan applied.
struct Written {
    report: kendex_core::engine::EngineReport,
    /// `None` is a scope with nothing to write, up to date.
    count: Option<usize>,
}

/// One scope's write: the yes it needs, the settle that yes covers, and
/// the plan applied after it.
///
/// One question per scope, asked before anything is written: what the
/// plan would add to or drop from the installed set, and what the settle
/// would install. A settle writes the package and its record, so the plan
/// is derived again after it, and that plan is the one applied and
/// reported; asking again for it would be asking twice about one change.
/// What that plan adds beyond the one the yes covered, a registration the
/// settled carrier made real, is shown and asked about once more before
/// it is written: a yes given to one list is no yes to a longer one. A
/// scope settling nothing keeps the plan it was shown.
///
/// One closing line for every path: a run that first asked about what it
/// installs still ends on the same ledger, since the outcomes it has to
/// report are the same either way. An empty plan closes on `None` — up to
/// date — and still reaches the commit offer, on whatever an earlier run
/// left uncommitted.
fn write_scope(
    env: &Env,
    scope: &kendex_core::model::Scope,
    report: kendex_core::engine::EngineReport,
    pending: &[String],
    options: &PlanOptions,
    yes: bool,
) -> Result<Written, Box<dyn std::error::Error>> {
    if pending.is_empty() {
        let count = match (report.plan.is_empty(), report.set_changes.is_empty()) {
            (true, _) => apply_report(env, &report).map(|_| None)?,
            (false, true) => apply_report(env, &report).map(Some)?,
            (false, false) => {
                print_set_changes(scope, &report);
                confirm_and_apply(env, &report, yes).map(Some)?
            }
        };
        return Ok(Written { report, count });
    }
    print_set_changes(scope, &report);
    for name in pending {
        say(&format!(
            "  - install pi-extension {name} for Pi — declared, not settled here"
        ));
    }
    let changes = report.plan.ops.len() + pending.len();
    ask_before_writing(
        &format!(
            "apply {changes} change{}?",
            if changes == 1 { "" } else { "s" }
        ),
        yes,
    )?;
    let settled = super::update_pi::settle_scope(env, scope, pending)?;
    let after = {
        let _planning = ui::spinner(&format!("planning {}", scope_label(scope)));
        plan_apply(env, scope, options)?
    };
    let approved: std::collections::BTreeSet<String> =
        report.plan.ops.iter().map(|op| op.line()).collect();
    let added_changes: Vec<_> = after
        .set_changes
        .iter()
        .filter(|change| !report.set_changes.contains(change))
        .collect();
    let added_ops: Vec<String> = after
        .plan
        .ops
        .iter()
        .map(|op| op.line())
        .filter(|line| !approved.contains(line))
        .collect();
    let added = added_changes.len() + added_ops.len();
    if added > 0 {
        say(&format!(
            "{}: settling added to what this run writes",
            scope_label(scope)
        ));
        for change in added_changes {
            say_set_change(change);
        }
        for line in &added_ops {
            say(&format!("  - {line}"));
        }
        ask_before_writing(
            &format!(
                "apply {added} more change{}?",
                if added == 1 { "" } else { "s" }
            ),
            yes,
        )?;
    }
    let applied = apply_report(env, &after)?;
    Ok(Written {
        report: after,
        count: Some(applied + settled),
    })
}

pub fn run_args(env: &Env, args: RefreshArgs) -> CliResult {
    let filter = ScopeFilter::resolve(args.scope.as_deref(), args.global, ScopeFilter::All)?;
    run(env, filter, args.verbose, args.yes, args.discard_edits)
}

pub fn run(
    env: &Env,
    filter: ScopeFilter,
    verbose: bool,
    yes: bool,
    discard_edits: bool,
) -> CliResult {
    ui::intro("kendex refresh");
    let mut refreshed_anything = false;
    let mut failures: Vec<String> = Vec::new();
    let mut closing: Vec<Closing> = Vec::new();
    // The scopes this run got through, and the cancel that stopped it at
    // one of them. A cancel ends the run, but it does not unwrite what
    // the scopes before it already wrote.
    let mut reached: Vec<kendex_core::model::Scope> = Vec::new();
    let mut cancelled: Option<Box<dyn std::error::Error>> = None;
    let scopes = resolve_scopes(env, filter)?;

    for scope in &scopes {
        let scope = scope.clone();
        reached.push(scope.clone());
        // A scope with no manifest file yet reads as its first write would
        // create it; a file this build cannot read is skipped here and
        // refused by the plan below, in its own words.
        if let Ok(manifest) = kendex_core::engine::ops::manifest_for_reading(env, &scope) {
            // An unreachable catalog is reported, not fatal: what came from
            // every other catalog still refreshes.
            let notes = {
                let _reading = ui::spinner(&format!("reading sources for {}", scope_label(&scope)));
                kendex_core::remote::sync_declared_sources(env, &manifest)
            };
            for note in notes {
                warn(&format!("warning: {}", note));
            }
        }
        let options = PlanOptions {
            sweep_unneeded: true,
            overwrite_edited: discard_edits,
            ..PlanOptions::default()
        };
        let planned = {
            let _planning = ui::spinner(&format!("planning {}", scope_label(&scope)));
            plan_apply(env, &scope, &options)
        };
        let mut report = match planned {
            Ok(report) => report,
            Err(error) => {
                failures.push(error.to_string());
                continue;
            }
        };
        // A declared Pi package installs outside the plan, through the
        // install `update-pi` owns, and its record is machine-local: a
        // clone carries the package and no record, and this plan reports
        // every such package as drift. What the settle would install is
        // read here, to be shown before the yes that lets it write, and
        // its rows leave this plan's drift before that is printed: a row
        // naming update-pi for a package this run settles is a remedy the
        // reader would act on for nothing. A package it would not settle
        // stays drift in the plan derived after the settle, and that row
        // fails the run. The record refusing to read is what stops the
        // scope here.
        let pending = match super::update_pi::pending_settle(env, &scope) {
            Ok(pending) => pending,
            Err(error) => {
                failures.push(error.to_string());
                continue;
            }
        };
        report.drift.retain(|row| {
            row.kind != kendex_core::model::ItemKind::PiExtension || !pending.contains(&row.name)
        });
        print_notes(&report);
        // Refresh plans and writes like apply, so it says what the rules
        // found before the confirm, the way apply does.
        print_safety(&report);
        let blocked = match verbose {
            true => print_drift(env, &report),
            false => print_conflicts(env, &report),
        };
        let lock = load_lock(&lock_path(env, &scope))?;
        // A scope settling nothing is reported off this plan, and a run
        // that refused every install is not "nothing installed": a scope
        // carrying a refusal is never passed over. A scope that settles is
        // reported off the plan derived after its settle.
        if pending.is_empty() {
            failures.extend(refresh_failures(&report));
            if lock.entries.is_empty() && report.plan.is_empty() && blocked.is_empty() {
                continue;
            }
        }
        refreshed_anything = true;
        match write_scope(env, &scope, report, &pending, &options, yes) {
            Ok(written) => {
                if !pending.is_empty() {
                    failures.extend(refresh_failures(&written.report));
                }
                // What the scope's armed packages say now that it is
                // written. Said, never acted on: a refresh arms nothing,
                // and `commands::repo_effects` says why the record of an
                // earlier yes does not change that.
                super::repo_effects::say_lapsed(env, &scope, &[]);
                closing.push(Closing {
                    scope: scope.clone(),
                    count: written.count,
                    blocked,
                    scored: written.report.safety.clone(),
                });
            }
            // A cancel is the reader stopping the run, not one scope
            // failing to refresh. Collected as a failure it would come out
            // as "failed to refresh 1 item/source(s)" and exit 1, and the
            // exit code a script keys a cancel on is 130.
            //
            // It stops the scopes after this one, never the finishing of
            // the ones before it: the confirm asks before it writes, so
            // this scope wrote nothing and drops off the reached list,
            // while what earlier scopes wrote is on disk and owed both a
            // snapshot and a closing line.
            Err(error) if ui::cancelled(error.as_ref()) => {
                reached.pop();
                cancelled = Some(error);
                break;
            }
            Err(error) => failures.push(error.to_string()),
        }
    }

    finish_scopes(env, &reached, closing);
    if let Some(error) = cancelled {
        return Err(error);
    }

    if !refreshed_anything && failures.is_empty() {
        say("nothing installed");
        return Ok(());
    }
    if !failures.is_empty() {
        for failure in &failures {
            super::fail(&format!("failed: {}", failure));
        }
        return Err(format!("failed to refresh {} item/source(s)", failures.len()).into());
    }
    Ok(())
}
