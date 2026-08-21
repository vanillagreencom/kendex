use kendex_core::engine::{PlanOptions, plan_apply};
use kendex_core::env::Env;
use kendex_core::lock::{load as load_lock, lock_path};

use super::engine_common::{
    confirm_and_execute, conflict_detail, print_conflicts, print_exits, print_held_back,
    refresh_failures,
};
use super::{CliResult, resolve_scopes, say};
use crate::scope::ScopeFilter;

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

fn print_drift(report: &kendex_core::engine::EngineReport) {
    for row in &report.drift {
        say(&format!(
            "{} {} [{}]: {:?} — {}",
            row.kind.name(),
            row.name,
            row.harness.name(),
            row.state,
            conflict_detail(row)
        ));
    }
}

/// What this refresh would add to or drop from the installed set — the part
/// that needs an answer before it runs.
fn print_set_changes(
    scope: &kendex_core::model::Scope,
    report: &kendex_core::engine::EngineReport,
) {
    say(&format!(
        "{}: this changes what is installed",
        scope.label()
    ));
    for change in &report.set_changes {
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
            for note in kendex_core::remote::sync_declared_sources(env, &manifest) {
                say(&format!("warning: {note}"));
            }
        }
        let options = PlanOptions {
            sweep_unneeded: true,
            overwrite_edited: discard_edits,
            ..PlanOptions::default()
        };
        let report = match plan_apply(env, &scope, &options) {
            Ok(report) => report,
            Err(error) => {
                failures.push(error.to_string());
                continue;
            }
        };
        // What this refresh will not write comes first, and comes before
        // the shortcut below: a scope with nothing installed and nothing to
        // do is not worth a line, but a scope whose only reason for having
        // nothing to do is that the gate refused its content is.
        print_held_back(&report);
        match verbose {
            // Every row, and the ways out under the ones that have them:
            // asking for more detail must not cost the reader the way out.
            true => {
                print_drift(&report);
                print_exits(env, &report);
            }
            false => {
                print_conflicts(env, &report);
            }
        }
        let lock = load_lock(&lock_path(env, &scope))?;
        if lock.entries.is_empty() && report.plan.is_empty() {
            continue;
        }
        refreshed_anything = true;
        failures.extend(refresh_failures(&report));
        if report.plan.is_empty() {
            say(&format!("{}: up to date", scope.label()));
            continue;
        }
        if !report.set_changes.is_empty() {
            print_set_changes(&scope, &report);
            if let Err(error) = confirm_and_execute(env, &report, yes) {
                failures.push(error.to_string());
            }
            continue;
        }
        match kendex_core::apply::execute(env, &report.plan, None) {
            Ok(outcome) => say(&format!(
                "{}: refreshed {} change(s)",
                scope.label(),
                outcome.applied
            )),
            Err(error) => failures.push(error.to_string()),
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
            say(&format!("warning: snapshot not derived ({error})"));
        }
    }

    if !refreshed_anything && failures.is_empty() {
        say("nothing installed");
        return Ok(());
    }
    if !failures.is_empty() {
        for failure in &failures {
            say(&format!("failed: {failure}"));
        }
        return Err(format!("failed to refresh {} item/source(s)", failures.len()).into());
    }
    Ok(())
}
