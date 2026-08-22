use clap::Args;

use kendex_core::engine::{
    EditedHere, PlanOptions, edited_here, plan_scope, planned_declarations, plans_kind,
};
use kendex_core::env::Env;
use kendex_core::lock::{load as load_lock, lock_path};
use kendex_core::manifest::{load_for_mutation, manifest_path};

use super::pin::parse_kind;
use super::{CliResult, resolve_scopes, say};
use crate::scope::ScopeFilter;

/// Put one package's declared content back over the edits made to its
/// installed files — the other exit beside `fork`, and the narrow one.
///
/// `refresh --discard-edits` is the whole scope: run it to resolve one
/// package and every other hand-edited package in that scope loses its
/// edits in the same pass. That is why the drift report names this per
/// package, and why the app has only ever offered the targeted apply.
#[derive(Args)]
pub struct DiscardArgs {
    /// agent | skill | hook | command | mcp-server
    kind: String,
    name: String,
    #[arg(short = 'g', long)]
    global: bool,
    /// project | global (default project)
    #[arg(long)]
    scope: Option<String>,
}

pub fn run(env: &Env, args: DiscardArgs) -> CliResult {
    let kind = parse_kind(&args.kind)?;
    // Some kinds install through their own tool rather than through the
    // planner, so nothing here rendered them and nothing can put them
    // back. Saying so beats the clean line, which would report a discard
    // that never happened.
    if !plans_kind(kind) {
        return Err(format!(
            "kendex does not render {}s, so it cannot put one's files back — {} installs them",
            kind.name(),
            kind.name()
        )
        .into());
    }
    let filter = ScopeFilter::resolve(args.scope.as_deref(), args.global, ScopeFilter::Project)?;
    let scope = resolve_scopes(env, filter)?.remove(0);
    let manifest = load_for_mutation(&manifest_path(env, &scope))?.ok_or("no manifest")?;
    let lock = load_lock(&lock_path(env, &scope))?;
    // A name this scope has nothing by is a mistake worth saying out loud,
    // not a quiet success that ran a scope's pending work under it. What
    // counts is what this place installs, not what it declares by name: a
    // bundle member and a required dependency are installed here and can be
    // discarded here, and the app has always offered exactly that. A guard
    // reading declarations alone refuses the command for packages it should
    // do its work on.
    let installed_here = lock
        .entries
        .values()
        .any(|entry| entry.kind == kind && entry.name == args.name);
    let declared = manifest.declared(kind).contains_key(&args.name);
    if !declared && !installed_here {
        return Err(format!(
            "no {} named '{}' is installed in this scope",
            kind.name(),
            args.name
        )
        .into());
    }
    // Installed here is not the same as wanted here. A dependency whose
    // parent stopped requiring it, or a member a bundle dropped, keeps its
    // lock entry and its edited files while the closure holds nothing to
    // render over them — so the plan below would carry it forward untouched
    // and the line at the end would say its content was restored.
    let wanted = planned_declarations(env, &scope, &manifest)
        .iter()
        .any(|item| item.kind == kind && item.name == args.name);
    if !declared && !wanted {
        return Err(format!(
            "{} '{}' is installed here but nothing needs it any more — there is no declared content to put it back to; remove it with 'kendex remove {}'",
            kind.name(),
            args.name,
            args.name
        )
        .into());
    }
    // The plan below is the scope's, and the permission it carries is this
    // package's alone: with no edit to overwrite, the permission does
    // nothing and executing would apply whatever else the scope had
    // pending under a line saying this package was restored.
    match edited_here(env, &scope, kind, &args.name)? {
        EditedHere::Yes => {}
        EditedHere::No => {
            say(&format!(
                "{} '{}' has no edits to discard — nothing was applied",
                kind.name(),
                args.name
            ));
            return Ok(());
        }
        // Nothing was rendered to compare its files against, so whether
        // they were edited is not known. Reporting the clean line here
        // would tell someone their edits are gone while the bytes stand,
        // and the discard itself has nothing to put back either way.
        EditedHere::Unmeasured => {
            return Err(format!(
                "{} '{}' could not be read from its source, so there is nothing to put its files back to — fix the source, or remove it with 'kendex remove {}'",
                kind.name(),
                args.name,
                args.name
            )
            .into());
        }
    }
    let report = plan_scope(
        env,
        &scope,
        &manifest,
        &lock,
        &PlanOptions {
            // Two halves of one promise: permission to overwrite this
            // package's edited bytes, and writes planned for this package
            // alone. Without the second the plan is the scope's, and a
            // command naming one package installs and updates the rest.
            overwrite_edited_names: Some(vec![(kind, args.name.clone())]),
            only_names: Some(vec![(kind, args.name.clone())]),
            ..PlanOptions::default()
        },
    )?;
    // Everything this plan is about, asked of the plan rather than read off
    // its op list: a scope carries its own maintenance, so ops exist
    // whether or not the package named got one, and every reason a package
    // is skipped — refused, held, unmeasured — leaves the same silence
    // there. Not only the package named, either: a dependency its
    // declaration pulls in can be refused on its own account, and applying
    // anyway leaves the package there with what it needs missing.
    // Executing would report a restore nobody did.
    let missing = report.unrendered();
    if missing.iter().any(|(k, n)| *k == kind && n == &args.name) {
        return Err(format!(
            "{} '{}' was edited, and nothing here rendered its declared content to put back — 'kendex check' reports what is holding it",
            kind.name(),
            args.name
        )
        .into());
    }
    if let Some((needed, name)) = missing.first() {
        return Err(format!(
            "{} '{}' needs {} '{}', and nothing here rendered that to put back — 'kendex check' reports what is holding it",
            kind.name(),
            args.name,
            needed.name(),
            name
        )
        .into());
    }
    for op in &report.plan.ops {
        say(&format!("  - {}", op.description));
    }
    let outcome = kendex_core::apply::execute(env, &report.plan, None)?;
    say(&format!(
        "{} '{}': {} change(s) — its declared content is back",
        kind.name(),
        args.name,
        outcome.applied
    ));
    Ok(())
}
