use kendex_core::engine::{EngineReport, PlanOptions, plan_apply};
use kendex_core::env::Env;
use kendex_core::lock::{load as load_lock, lock_path};

use super::engine_common::{
    apply_report, ask_before_writing, confirm_and_apply, print_conflicts, print_drift, print_notes,
    print_safety, print_synced, refresh_failures, require_yes_in_non_interactive,
};
use super::ledger::{Wrote, say_ledger};
use super::{CliResult, resolve_scopes, say, scope_label, warn};
use super::{commit_offer::after_writing, offers::Blocked};
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

fn print_changes_needing_consent(
    scope: &kendex_core::model::Scope,
    report: &EngineReport,
    pending: &[String],
) {
    print_set_changes(scope, report);
    for name in pending {
        say(&format!(
            "  - install pi-extension {name} for Pi — listed, not installed here yet"
        ));
    }
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

/// Final plan and known writes, including a stop after Pi settlement.
struct Written {
    report: kendex_core::engine::EngineReport,
    /// `None` is a scope with nothing to write, up to date.
    count: Option<usize>,
    stop: Option<Box<dyn std::error::Error>>,
}

/// A selected scope after every read needed to decide whether this run will
/// need consent. No scope writes until every preparation has finished.
struct PreparedScope {
    scope: kendex_core::model::Scope,
    synced: kendex_core::remote::Synced,
    options: PlanOptions,
    planned: Result<(EngineReport, Vec<String>), String>,
}

impl PreparedScope {
    fn needs_consent(&self) -> bool {
        match &self.planned {
            Ok((report, pending)) => !report.set_changes.is_empty() || !pending.is_empty(),
            Err(_) => false,
        }
    }
}

fn prepare_scope(
    env: &Env,
    scope: kendex_core::model::Scope,
    discard_edits: bool,
) -> PreparedScope {
    let synced = match kendex_core::engine::ops::manifest_for_reading(env, &scope) {
        Ok(manifest) => {
            let _reading =
                ui::spinner(&format!("reading marketplaces for {}", scope_label(&scope)));
            kendex_core::remote::sync_declared_sources(env, &manifest)
        }
        Err(_) => kendex_core::remote::Synced::default(),
    };
    let options = PlanOptions {
        sweep_unneeded: true,
        overwrite_edited: discard_edits,
        ..PlanOptions::default()
    };
    let report = {
        let _planning = ui::spinner(&format!("planning {}", scope_label(&scope)));
        plan_apply(env, &scope, &options)
    };
    let planned = match report {
        Ok(report) => super::update_pi::pending_settle(env, &scope)
            .map(|pending| (report, pending))
            .map_err(|error| error.to_string()),
        Err(error) => Err(error.to_string()),
    };
    PreparedScope {
        scope,
        synced,
        options,
        planned,
    }
}

fn prepare_scopes(
    env: &Env,
    filter: ScopeFilter,
    verbose: bool,
    yes: bool,
    discard_edits: bool,
) -> Result<Vec<PreparedScope>, Box<dyn std::error::Error>> {
    let scopes = resolve_scopes(env, filter)?;
    let prepared: Vec<_> = scopes
        .into_iter()
        .map(|scope| prepare_scope(env, scope, discard_edits))
        .collect();
    if prepared.iter().any(PreparedScope::needs_consent)
        && let Err(error) = require_yes_in_non_interactive(yes)
    {
        print_refusal_context(env, &prepared, verbose);
        return Err(error);
    }
    Ok(prepared)
}

fn print_diagnostics(env: &Env, report: &EngineReport, verbose: bool) -> Vec<Blocked> {
    print_notes(report);
    print_safety(report);
    match verbose {
        true => print_drift(env, report),
        false => print_conflicts(env, report),
    }
}

/// Print everything the read-only preparation can establish before a
/// non-interactive run refuses its missing consent. A pending Pi settlement
/// keeps its diagnostics for the plan derived after settlement.
fn print_refusal_context(env: &Env, prepared: &[PreparedScope], verbose: bool) {
    let mut failures = Vec::new();
    for scope in prepared {
        print_synced(&scope.synced);
        match &scope.planned {
            Ok((report, pending)) => {
                if pending.is_empty() {
                    print_diagnostics(env, report, verbose);
                    failures.extend(refresh_failures(report));
                }
            }
            Err(error) => failures.push(error.clone()),
        }
    }
    for failure in failures {
        super::fail(&format!("failed: {failure}"));
    }
    for scope in prepared {
        if let Ok((report, pending)) = &scope.planned
            && scope.needs_consent()
        {
            print_changes_needing_consent(&scope.scope, report, pending);
        }
    }
}

/// One scope's write: the yes it needs, the settle that yes covers, and
/// the plan applied after it.
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
    report_after_settle: impl FnOnce(&kendex_core::engine::EngineReport),
) -> Result<Written, Box<dyn std::error::Error>> {
    if pending.is_empty() {
        let count = match (report.plan.is_empty(), report.set_changes.is_empty()) {
            (true, _) => apply_report(env, &report).map(|_| None)?,
            (false, true) => apply_report(env, &report).map(Some)?,
            (false, false) => {
                print_changes_needing_consent(scope, &report, pending);
                confirm_and_apply(env, &report, yes).map(Some)?
            }
        };
        return Ok(Written {
            report,
            count,
            stop: None,
        });
    }
    print_changes_needing_consent(scope, &report, pending);
    let changes = report.plan.ops.len() + pending.len();
    ask_before_writing(
        &format!(
            "write {changes} change{}?",
            if changes == 1 { "" } else { "s" }
        ),
        yes,
    )?;
    let settled = super::update_pi::settle_scope(env, scope, pending)?;
    let after = {
        let _planning = ui::spinner(&format!("planning {}", scope_label(scope)));
        plan_apply(env, scope, options)?
    };
    // The carrier can make hooks enforceable. Show their diagnostics
    // before confirming the final writes, using this plan for the ledger.
    report_after_settle(&after);
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
    }
    let applied = confirm_and_apply(env, &after, yes);
    Ok(Written {
        report: after,
        count: Some(settled + applied.as_ref().map_or(0, |count| *count)),
        stop: applied.err(),
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
    let prepared = prepare_scopes(env, filter, verbose, yes, discard_edits)?;

    for prepared in prepared {
        let scope = prepared.scope;
        reached.push(scope.clone());
        // An unreachable catalog is reported, not fatal: what came from
        // every other catalog still refreshes.
        print_synced(&prepared.synced);
        let (report, pending) = match prepared.planned {
            Ok(planned) => planned,
            Err(error) => {
                failures.push(error);
                continue;
            }
        };
        // A declared Pi package installs outside the plan, through the
        // install `update-pi` owns, and its record is machine-local: a
        // clone carries the package and no record, and this plan reports
        // every such package as drift. What the settle would install is
        // read here, to be shown before the yes that lets it write. The
        // diagnostics come from the plan derived after settlement, so a
        // package this run settles never prints a stale update-pi remedy.
        // A package it would not settle stays drift and fails the run.
        // The record refusing to read is what stops the scope here.
        let mut blocked = Vec::new();
        let lock = load_lock(&lock_path(env, &scope))?;
        // A scope settling nothing is reported off this plan, and a run
        // that refused every install is not "nothing installed": a scope
        // carrying a refusal is never passed over. A scope that settles is
        // reported off the plan derived after its settle.
        if pending.is_empty() {
            blocked = print_diagnostics(env, &report, verbose);
            failures.extend(refresh_failures(&report));
            if lock.entries.is_empty() && report.plan.is_empty() && blocked.is_empty() {
                continue;
            }
        }
        refreshed_anything = true;
        match write_scope(
            env,
            &scope,
            report,
            &pending,
            &prepared.options,
            yes,
            |after| {
                blocked = print_diagnostics(env, after, verbose);
            },
        ) {
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
                if let Some(error) = written.stop {
                    if ui::cancelled(error.as_ref()) {
                        cancelled = Some(error);
                        break;
                    }
                    failures.push(error.to_string());
                    if let Err(error) = after_writing(env, &scope, &written.report.generated) {
                        failures.push(error.to_string());
                    }
                }
            }
            // A cancel is the reader stopping the run, not one scope
            // failing to refresh. Collected as a failure it would come out
            // as "refresh failed: 1 problem(s), listed above" and exit 1,
            // and the exit code a script keys a cancel on is 130.
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

    for failure in &failures {
        super::fail(&format!("failed: {}", failure));
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
        return Err(format!(
            "refresh failed: {} problem(s), listed above",
            failures.len()
        )
        .into());
    }
    Ok(())
}
