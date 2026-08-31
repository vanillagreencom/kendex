use kendex_core::engine::{PlanOptions, plan_apply};
use kendex_core::env::Env;
use kendex_core::manifest::{self, ManifestFile};
use kendex_core::names::shown;

use super::engine_common::{confirm_and_apply, print_report, print_unmanaged};
use super::ledger::{Wrote, say_ledger, say_preview};
use super::{CliResult, resolve_scopes, say, scope_label, warn};
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
    // A scope whose files this build cannot read is skipped and named, and
    // still fails the run at the end: the scopes after it are worth
    // applying, and an exit code of zero would say the apply happened
    // everywhere it was asked for. `refresh` walks its scopes the same way.
    let mut skipped: Vec<String> = Vec::new();
    for scope in resolve_scopes(env, filter)? {
        // Read the manifest as it sits on disk, through the same loader
        // the audit uses, so this verb refuses exactly what the audit
        // refused rather than planning against a normalized copy.
        let path = manifest::manifest_path(env, &scope);
        match manifest::load(&path) {
            Ok(ManifestFile::Current(_)) => {}
            Ok(ManifestFile::Absent) => {
                say(&format!("{}: no manifest", scope_label(&scope)));
                continue;
            }
            Err(error) if error.is_unreadable_record() => {
                warn(&format!(
                    "skipped {}: {}",
                    scope_label(&scope),
                    shown(&error.to_string())
                ));
                skipped.push(scope_label(&scope));
                continue;
            }
            Err(error) => return Err(error.into()),
        }
        let options = PlanOptions {
            remove_orphans: true,
            removal_filter: None,
            overwrite_edited: args.discard_edits,
            replace_unmanaged: args.replace_unmanaged,
            ..PlanOptions::default()
        };
        let report = {
            let _planning = ui::spinner(&format!("planning {}", scope_label(&scope)));
            match plan_apply(env, &scope, &options) {
                Ok(report) => report,
                Err(error) if error.is_unreadable_record() => {
                    warn(&format!(
                        "skipped {}: {}",
                        scope_label(&scope),
                        shown(&error.to_string())
                    ));
                    skipped.push(scope_label(&scope));
                    continue;
                }
                Err(error) => return Err(error.into()),
            }
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
        // same account and the same separate yes an `add` gives it —
        // asked after the write, so the scope is finalized whatever the
        // answer and before any error from it leaves this loop.
        super::repo_effects::disclose_and_finish(
            env,
            &scope,
            &report.repo_effects,
            args.allow_repo_effects,
            || {
                // The deep work just ran; record it for the session-start
                // check. Said before the ledger closes the scope: a
                // warning under the run's own closing line reads as a line
                // from the next one.
                if let Err(error) = kendex_core::drift::snapshot::record(env, &scope) {
                    warn(&format!(
                        "warning: snapshot not derived ({})",
                        shown(&error.to_string())
                    ));
                }
                // `None` where the plan had nothing to do: a scope that
                // wrote nothing because it had nothing to write is up to
                // date, and one that wrote nothing because every write was
                // refused is not.
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
            },
        )?;
    }
    if !skipped.is_empty() {
        return Err(format!(
            "could not read {} scope(s): {}",
            skipped.len(),
            skipped.join(", ")
        )
        .into());
    }
    Ok(())
}
