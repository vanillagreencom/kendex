use kendex_core::engine::{PlanOptions, plan_apply};
use kendex_core::env::Env;
use kendex_core::manifest::{self, ManifestFile};

use super::engine_common::{confirm_and_apply, print_report, print_unmanaged};
use super::ledger::{Folded, Wrote, say_ledger, say_preview};
use super::{CliResult, fail_refusal, resolve_scopes_at, say, scope_label, warn};
use crate::scope::ScopeFilter;
use crate::ui;

/// Make disk match declaration — orphan cleanup included, plan shown first.
///
/// The two overrides say which bytes on disk a declaration outranks: ones
/// the user edited, and ones kendex never wrote at all. Both are refusals
/// by default and neither implies the other.
#[derive(clap::Args)]
pub struct ApplyArgs {
    /// Print the plan and change nothing
    #[arg(long)]
    plan: bool,
    /// Install into your personal setup
    #[arg(short = 'g', long)]
    global: bool,
    /// project | global | all (default project)
    #[arg(long)]
    scope: Option<String>,
    /// Skip the confirmation prompt
    #[arg(short = 'y', long)]
    yes: bool,
    /// Overwrite installed files edited on disk
    #[arg(long)]
    discard_edits: bool,
    /// Replace files kendex did not write, wherever a listed package
    /// installs in this place — the old files move to the trash
    #[arg(long)]
    replace_unmanaged: bool,
    /// Say yes to the repository changes a newly installed package asks for
    #[arg(long)]
    allow_repo_effects: bool,
    // The project this run writes, named rather than walked up to. The
    // help clap prints is the flag's own, on `flags::ProjectTargetFlag`;
    // a doc comment here would reach no output.
    #[command(flatten)]
    target: crate::flags::ProjectTargetFlag,
    /// Record matching installed files after moving an unreadable install record aside
    #[arg(
        long,
        conflicts_with_all = ["discard_edits", "replace_unmanaged", "allow_repo_effects"]
    )]
    record_existing: bool,
    // The commit offer's answer, without asking. Its help is
    // `commit_offer::CommitFlags`' own, for the same reason.
    #[command(flatten)]
    _commit: crate::commands::commit_offer::CommitFlags,
}

pub fn run(env: &Env, args: ApplyArgs) -> CliResult {
    let filter = ScopeFilter::resolve(args.scope.as_deref(), args.global, ScopeFilter::Project)?;
    // Every scope is planned before any of them is written: failing before
    // the first write beats a half-applied run.
    let mut planned = Vec::new();
    let scopes = resolve_scopes_at(env, filter, args.target.path())?;
    super::header("apply", &scopes);
    // The refusal that registration carries, asked before the first
    // write. A plan never reaches a write, so it is asked nothing;
    // `project::register_target` owns the rule itself.
    if !args.plan {
        super::project::target_registrable(env, &args.target, &scopes)?;
    }
    for scope in scopes {
        // Read the manifest as it sits on disk, through the same loader
        // the audit uses, so this verb refuses exactly what the audit
        // refused rather than planning against a normalized copy.
        let path = manifest::manifest_path(env, &scope);
        match manifest::load(&path) {
            Ok(ManifestFile::Current(_)) => {}
            Ok(ManifestFile::Absent) => {
                say(&format!(
                    "{}: nothing listed to install",
                    scope_label(&scope)
                ));
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
            match args.record_existing {
                true => kendex_core::engine::plan_record_existing(env, &scope)?,
                false => plan_apply(env, &scope, &options)?,
            }
        };
        planned.push((scope.clone(), report));
    }
    let scopes = planned.len();
    for (index, (scope, report)) in planned.into_iter().enumerate() {
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
        let walked = super::repo_effects::disclose_and_finish(
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
                    warn(&format!("warning: snapshot not derived ({})", error));
                }
                // The last scope's writes are the run's last, so the
                // trash is brought within its bounds here, before the
                // line the run closes on.
                if index + 1 == scopes {
                    super::engine_common::tidy_trash(env);
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
                    Folded::None,
                );
            },
        );
        // After the write, the way `add` registers what it installed
        // into: a project named by a command that never stood in it is
        // one the app sees. The temporary-path gate above already passed
        // for this path.
        //
        // `confirm_and_apply` has written by the time the effects step
        // runs, so registration is not that step's to skip: an installer
        // that failed, or a walkthrough nobody answered, leaves the
        // packages on disk in a folder the app would never show.
        // `add::write_and_close` closes on the same pair, and says the
        // registry's refusal beside the failure it did not cause.
        let listed = super::project::register_target(env, &args.target, &scope);
        match walked {
            Ok(()) => listed?,
            Err(error) => {
                if let Err(refused) = listed {
                    fail_refusal("warning: ", refused.as_ref());
                }
                return Err(error);
            }
        }
    }
    Ok(())
}
