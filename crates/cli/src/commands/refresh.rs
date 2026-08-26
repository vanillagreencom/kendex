use kendex_core::engine::{PlanOptions, plan_apply};
use kendex_core::env::Env;
use kendex_core::lock::{load as load_lock, lock_path};

use super::engine_common::{
    apply_report, confirm_and_apply, print_conflicts, print_drift, print_notes, print_safety,
    refresh_failures,
};
use super::ledger::{Wrote, say_ledger};
use super::{CliResult, resolve_scopes, say, scope_label, warn};
use crate::scope::ScopeFilter;
use crate::ui;

/// Regenerate every declared installation, and re-derive what those
/// declarations pull in — a dependency that appeared upstream, one that went
/// away. Regenerating is automatic; changing *what is installed* is shown
/// first and needs an answer. Orphans nobody derived are left alone, as in
/// v1: `remove` and `apply` clean those up.
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
        let verb = match change.direction {
            kendex_core::engine::SetDirection::Add => "install",
            kendex_core::engine::SetDirection::Remove => "remove",
        };
        say(&format!(
            "  - {verb} {} {} for {} — {}",
            change.kind.name(),
            kendex_core::names::shown(&change.name),
            change.harness.display_name(),
            kendex_core::names::shown(&change.reason)
        ));
    }
}

fn refreshed(count: Option<usize>) -> Wrote<'static> {
    Wrote {
        verb: "refreshed",
        count,
    }
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
    let scopes = resolve_scopes(env, filter)?;

    for scope in &scopes {
        let scope = scope.clone();
        let manifest_path = kendex_core::manifest::manifest_path(env, &scope);
        if let Ok(kendex_core::manifest::ManifestFile::Current(manifest)) =
            kendex_core::manifest::load(&manifest_path)
        {
            // An unreachable catalog is reported, not fatal: what came from
            // every other catalog still refreshes.
            let notes = {
                let _reading = ui::spinner(&format!("reading sources for {}", scope_label(&scope)));
                kendex_core::remote::sync_declared_sources(env, &manifest)
            };
            for note in notes {
                warn(&format!("warning: {note}"));
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
        let report = match planned {
            Ok(report) => report,
            Err(error) => {
                failures.push(error.to_string());
                continue;
            }
        };
        print_notes(&report);
        // Refresh plans and writes like apply, so it says what the rules
        // found before the confirm, the way apply does.
        print_safety(&report);
        let blocked = match verbose {
            true => print_drift(env, &report),
            false => print_conflicts(env, &report),
        };
        let lock = load_lock(&lock_path(env, &scope))?;
        // A run that refused every install is not "nothing installed": a
        // scope carrying a refusal is never passed over.
        if lock.entries.is_empty() && report.plan.is_empty() && blocked.is_empty() {
            continue;
        }
        refreshed_anything = true;
        failures.extend(refresh_failures(&report));
        if report.plan.is_empty() {
            say_ledger(&scope, refreshed(None), &blocked, &report.safety);
            continue;
        }
        // One closing line for both paths: a run that first asked about
        // what it installs still ends on the same ledger, since the
        // outcomes it has to report are the same either way.
        let applied: Result<usize, String> = match report.set_changes.is_empty() {
            true => apply_report(env, &report).map_err(|error| error.to_string()),
            false => {
                print_set_changes(&scope, &report);
                confirm_and_apply(env, &report, yes).map_err(|error| error.to_string())
            }
        };
        match applied {
            Ok(applied) => say_ledger(&scope, refreshed(Some(applied)), &blocked, &report.safety),
            Err(error) => failures.push(error),
        }
    }

    // The deep work just ran for every scope; the snapshot is what the next
    // session-start check reads instead of redoing it.
    for scope in &scopes {
        if matches!(
            kendex_core::manifest::load(&kendex_core::manifest::manifest_path(env, scope)),
            Ok(kendex_core::manifest::ManifestFile::Current(_))
        ) && let Err(error) = kendex_core::drift::snapshot::record(env, scope)
        {
            warn(&format!("warning: snapshot not derived ({error})"));
        }
    }

    if !refreshed_anything && failures.is_empty() {
        say("nothing installed");
        return Ok(());
    }
    if !failures.is_empty() {
        for failure in &failures {
            super::fail(&format!("failed: {failure}"));
        }
        return Err(format!("failed to refresh {} item/source(s)", failures.len()).into());
    }
    Ok(())
}
