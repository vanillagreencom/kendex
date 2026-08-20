use kendex_core::engine::{PlanOptions, plan_apply, refuse_unmatched_grants};
use kendex_core::env::Env;
use kendex_core::error::CoreError;
use kendex_core::manifest::{self, ManifestFile};

use super::engine_common::{confirm_and_execute, print_report};
use super::{CliResult, resolve_scopes, say};
use crate::scope::ScopeFilter;

/// Make disk match declaration — orphan cleanup included, plan shown first.
/// (Repurposed from v1's theme-pack apply; extras are gone in v2.)
///
/// `allow_unsafe` names items whose safety findings the user has read and
/// accepted. Nothing is granted in advance: the review is recorded against
/// the exact content and findings this run produced, by the same plan that
/// installs them, so it expires the moment either one changes.
pub fn run(
    env: &Env,
    filter: ScopeFilter,
    plan_only: bool,
    yes: bool,
    allow_unsafe: Vec<String>,
    discard_edits: bool,
) -> CliResult {
    // Every scope is planned before any of them is written. A grant is
    // judged against the whole run and not against one scope at a time:
    // with `--scope all` a flag for the project would otherwise be a hard
    // error the moment the personal scope, which never heard of the item,
    // is planned. Failing before the first write is the other half — a
    // half-applied run followed by that failure is the worst answer.
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
            allow_unsafe: allow_unsafe.clone(),
            overwrite_edited: discard_edits,
            ..PlanOptions::default()
        };
        planned.push((scope.clone(), plan_apply(env, &scope, &options)?));
    }
    let options = PlanOptions {
        allow_unsafe,
        ..PlanOptions::default()
    };
    let rows: Vec<&kendex_core::engine::ItemSafety> = planned
        .iter()
        .flat_map(|(_, report)| report.safety.iter())
        .collect();
    refuse_unmatched_grants(&options, &rows)?;

    for (scope, report) in planned {
        say(&format!("{}:", scope.label()));
        print_report(&report);
        if !plan_only {
            confirm_and_execute(env, &report, yes)?;
            // The deep work just ran; record it for the session-start check.
            if let Err(error) = kendex_core::drift::snapshot::record(env, &scope) {
                say(&format!("warning: snapshot not derived ({error})"));
            }
        }
    }
    Ok(())
}
