use kendex_core::engine::{PlanOptions, plan_apply};
use kendex_core::env::Env;
use kendex_core::error::CoreError;
use kendex_core::manifest::{self, ManifestFile};

use super::engine_common::{confirm_and_apply, print_report, print_unmanaged};
use super::ledger::{Wrote, say_ledger, say_preview};
use super::{CliResult, resolve_scopes, say, warn};
use crate::scope::ScopeFilter;
use crate::ui;

/// Make disk match declaration — orphan cleanup included, plan shown first.
/// (Repurposed from v1's theme-pack apply; extras are gone in v2.)
///
/// The two overrides say which bytes on disk a declaration outranks: ones
/// the user edited, and ones kendex never wrote at all. Both are refusals
/// by default and neither implies the other.
#[derive(clap::Args)]
pub struct ApplyArgs {
    /// Print the plan and change nothing
    #[arg(long)]
    plan: bool,
    /// Apply to the user-level scope
    #[arg(short = 'g', long)]
    global: bool,
    /// project | global | all (default project)
    #[arg(long)]
    scope: Option<String>,
    /// Skip the confirmation prompt
    #[arg(short = 'y', long)]
    yes: bool,
    /// Overwrite installations you edited by hand
    #[arg(long)]
    discard_edits: bool,
    /// Replace files kendex did not write, wherever a declared item
    /// installs in this scope — the old files move to the trash
    #[arg(long)]
    replace_unmanaged: bool,
    /// Say yes to the repository changes a newly installed package declares
    #[arg(long)]
    allow_repo_effects: bool,
}

pub fn run(env: &Env, args: ApplyArgs) -> CliResult {
    ui::intro("kendex apply");
    let filter = ScopeFilter::resolve(args.scope.as_deref(), args.global, ScopeFilter::Project)?;
    // Every scope is planned before any of them is written: failing before
    // the first write beats a half-applied run.
    let mut planned = Vec::new();
    for scope in resolve_scopes(env, filter)? {
        // Plan from the manifest as it sits on disk — the same loader the
        // audit uses — so a v0.1 scope gets the schema upgrade its plan
        // promises instead of a normalized copy that no longer looks old.
        let path = manifest::manifest_path(env, &scope);
        match manifest::load(&path)? {
            ManifestFile::Current(_) => {}
            ManifestFile::Absent => {
                say(&format!("{}: no manifest", scope.label()));
                continue;
            }
            ManifestFile::Legacy { .. } => return Err(CoreError::LegacyManifest { path }.into()),
        }
        let options = PlanOptions {
            remove_orphans: true,
            removal_filter: None,
            overwrite_edited: args.discard_edits,
            replace_unmanaged: args.replace_unmanaged,
            ..PlanOptions::default()
        };
        let report = {
            let _planning = ui::spinner(&format!("planning {}", scope.label()));
            plan_apply(env, &scope, &options)?
        };
        planned.push((scope.clone(), report));
    }
    for (scope, report) in planned {
        let blocked = print_report(env, &report);
        // Only here and in verify: a report is printed by add and pin too,
        // and an inventory of hand-made content is not what those were
        // asked for.
        print_unmanaged(&report.drift);
        // A preview closes on what it would do, in the shape the run that
        // does it closes on — the scope named there and nowhere else, so
        // a multi-scope run is read one ledger at a time.
        if args.plan {
            let planned = (!report.plan.is_empty()).then_some(report.plan.ops.len());
            say_preview(
                &scope,
                Wrote {
                    verb: "planned",
                    count: planned,
                },
                &blocked,
                &report.safety,
            );
            continue;
        }
        // The same close as refresh, for the same reason: what this run
        // wrote is one of its outcomes, and the installs it refused and
        // the scores it read are the others.
        let applied = confirm_and_apply(env, &report, args.yes)?;
        // A declaration written by hand installs here, and it gets the
        // same account and the same separate yes an `add` gives it.
        let shown_to_them = super::repo_effects::disclose(env, &scope, &report.repo_effects)?;
        super::repo_effects::walkthrough(&scope, &shown_to_them, args.allow_repo_effects)?;
        // `None` where the plan had nothing to do: a scope that wrote
        // nothing because it had nothing to write is up to date, and one
        // that wrote nothing because every write was refused is not.
        // The deep work just ran; record it for the session-start check.
        // Said before the ledger closes the scope: a warning under the
        // run's own closing line reads as a line from the next one.
        if let Err(error) = kendex_core::drift::snapshot::record(env, &scope) {
            warn(&format!("warning: snapshot not derived ({error})"));
        }
        let count = (!report.plan.is_empty()).then_some(applied);
        say_ledger(
            &scope,
            Wrote {
                verb: "applied",
                count,
            },
            &blocked,
            &report.safety,
        );
    }
    Ok(())
}
