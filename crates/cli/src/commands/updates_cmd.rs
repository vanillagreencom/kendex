use clap::{Args, Subcommand};

use kendex_core::env::Env;
use kendex_core::model::ItemKind;

use super::pin::parse_kind;
use super::{CliResult, resolve_scopes, say};
use crate::scope::ScopeFilter;

#[derive(Subcommand)]
pub enum UpdatesCommand {
    /// Bring one package current, leaving the scope's other followers at
    /// their installed versions (`--apply` brings the whole scope current)
    Apply {
        /// agent | skill | hook | command | mcp-server (Pi extensions come
        /// current through `kendex update-pi`)
        kind: String,
        name: String,
    },
    /// Stop notifying about one package's updates
    Ignore {
        /// agent | skill | hook | command | mcp-server | pi-extension
        kind: String,
        name: String,
    },
    /// Notify about a previously ignored package again
    Unignore {
        /// agent | skill | hook | command | mcp-server | pi-extension
        kind: String,
        name: String,
    },
}

#[derive(Args)]
pub struct UpdatesArgs {
    #[command(subcommand)]
    command: Option<UpdatesCommand>,
    /// Fetch every source's mirror first, pinned ones included
    #[arg(long)]
    refresh: bool,
    /// Apply pending updates (a refresh apply)
    #[arg(long)]
    apply: bool,
    #[arg(short = 'g', long)]
    global: bool,
    /// project | global (default project)
    #[arg(long)]
    scope: Option<String>,
    /// Skip confirmation prompts
    #[arg(short = 'y', long)]
    yes: bool,
}

pub fn run(env: &Env, args: UpdatesArgs) -> CliResult {
    let UpdatesArgs {
        command,
        refresh,
        apply,
        global,
        scope,
        yes,
    } = args;
    let filter = ScopeFilter::resolve(scope.as_deref(), global, ScopeFilter::Project)?;
    let scope = resolve_scopes(env, filter)?.remove(0);
    match command {
        Some(UpdatesCommand::Apply { kind, name }) => {
            return apply_one(env, &scope, kind, name);
        }
        Some(UpdatesCommand::Ignore { kind, name }) => {
            return set_ignored(env, &scope, kind, name, true);
        }
        Some(UpdatesCommand::Unignore { kind, name }) => {
            return set_ignored(env, &scope, kind, name, false);
        }
        None => {}
    }
    if refresh {
        let path = kendex_core::manifest::manifest_path(env, &scope);
        if let Ok(kendex_core::manifest::ManifestFile::Current(manifest)) =
            kendex_core::manifest::load(&path)
        {
            for warning in kendex_core::remote::fetch_all(env, &manifest) {
                say(&format!("warning: {warning}"));
            }
        }
    }
    if apply {
        return super::refresh::run(env, filter, false, yes, false);
    }
    let report = kendex_core::package::updates::updates(env, &scope)?;
    let mut shown = 0;
    for row in &report.rows {
        // Mixed installs and packages gone upstream are standing facts worth
        // a line even when no newer version exists to move to.
        if !row.update_available && !row.mixed && !row.removed_upstream {
            continue;
        }
        shown += 1;
        let mut notes = Vec::new();
        if row.pinned {
            notes.push("held");
        }
        if row.ignored {
            notes.push("ignored");
        }
        if row.mixed {
            notes.push("mixed installs");
        }
        if row.removed_upstream {
            notes.push("no longer in its source");
        }
        let notes = if notes.is_empty() {
            String::new()
        } else {
            format!("  [{}]", notes.join(", "))
        };
        // The place leads the line: the same package can be out of date
        // in several projects, and a line that does not say which one
        // reads as a duplicate.
        say(&format!(
            "{}  {} {}  {} -> {}{notes}",
            row.scope.label(),
            row.kind.name(),
            row.name,
            row.current
                .as_ref()
                .map(show_version)
                .unwrap_or_else(|| "?".into()),
            row.latest
                .as_ref()
                .map(show_version)
                .unwrap_or_else(|| "?".into()),
        ));
    }
    for warning in &report.warnings {
        say(&format!(
            "warning: {} {}: {}",
            warning.kind.name(),
            warning.name,
            warning.message
        ));
    }
    if shown == 0 && report.warnings.is_empty() {
        say("everything is on its latest version");
    }
    // The deep work just ran; write it down so the next session-start check
    // reads verdicts instead of guesses.
    if let Err(error) = kendex_core::drift::snapshot::record(env, &scope) {
        say(&format!("warning: snapshot not derived ({error})"));
    }
    Ok(())
}

fn show_version(version: &kendex_core::package::updates::VersionRef) -> String {
    match &version.label {
        Some(label) => label.clone(),
        None => version.commit[..7.min(version.commit.len())].to_owned(),
    }
}

/// Bring one package current: the single-package apply, printed op by op.
/// The scope's other followers stay at their installed commits (bar one
/// the lock cannot place, which resolves fresh either way); a hold on
/// the package itself still holds, and any conflict the plan raises for it
/// (a hand-edited copy, files in the way) is said instead of applied over.
fn apply_one(
    env: &Env,
    scope: &kendex_core::model::Scope,
    kind: String,
    name: String,
) -> CliResult {
    let kind = parse_kind(&kind)?;
    // Refused before anything is planned: a kind the engine never derives
    // would come back with no ops, and this verb would answer "nothing to
    // change" for work it cannot do at all.
    if !kendex_core::engine::plans_per_package(kind) {
        return Err(format!(
            "{} '{name}' {}",
            kind.name(),
            kendex_core::engine::NO_PER_PACKAGE_UPDATE
        )
        .into());
    }
    let report = kendex_core::package::update_one(env, scope, kind, &name)?;
    let held = kendex_core::package::held_back(&report, kind, &name);
    let moving = kendex_core::package::moving(&report, kind, &name);
    for row in &held {
        say(&format!("{}: {}", row.harness.name(), row.detail));
    }
    let changed = !report.plan.ops.is_empty();
    for op in &report.plan.ops {
        say(&op.description);
    }
    kendex_core::apply::execute(env, &report.plan, None)?;
    // The deep work just ran; write it down so the next session-start check
    // reads verdicts instead of guesses.
    if let Err(error) = kendex_core::drift::snapshot::record(env, scope) {
        say(&format!("warning: snapshot not derived ({error})"));
    }
    say(&outcome_line(kind, &name, &held, &moving, changed));
    Ok(())
}

/// What the run just did to the package it named, in one line. Conflicts
/// are per rendering: a copy held back in one tool while another comes
/// current is a partial move, and calling that "nothing moved" states a
/// wrong fact about work the same run performed.
fn outcome_line(
    kind: ItemKind,
    name: &str,
    held: &[&kendex_core::engine::DriftRow],
    moving: &[&kendex_core::engine::DriftRow],
    changed: bool,
) -> String {
    let tools = |rows: &[&kendex_core::engine::DriftRow]| {
        let mut names: Vec<&str> = rows.iter().map(|row| row.harness.name()).collect();
        names.sort_unstable();
        names.dedup();
        names.join(", ")
    };
    match (held.is_empty(), moving.is_empty(), changed) {
        (false, false, _) => format!(
            "{} {name} moved in {} — its copy in {} is held back by the conflict above",
            kind.name(),
            tools(moving),
            tools(held)
        ),
        (false, true, _) => format!(
            "{} {name} is held back by the conflict above — nothing moved for it",
            kind.name()
        ),
        (true, _, true) => format!("applied — {} {name} is current here", kind.name()),
        (true, _, false) => format!("nothing to change for {} {name}", kind.name()),
    }
}

fn set_ignored(
    env: &Env,
    scope: &kendex_core::model::Scope,
    kind: String,
    name: String,
    ignored: bool,
) -> CliResult {
    let kind = parse_kind(&kind)?;
    // The ignore is keyed by repository too, so it needs the row's identity.
    let rows = kendex_core::package::updates::updates(env, scope)?.rows;
    let Some(row) = rows.iter().find(|row| row.kind == kind && row.name == name) else {
        return Err(format!(
            "no declared {} named '{name}' with a repo source here",
            kind.name()
        )
        .into());
    };
    kendex_core::package::updates::set_ignored(env, scope, kind, &name, &row.repo, ignored)?;
    match ignored {
        true => say(&format!(
            "updates for {name} are muted — `kendex updates unignore` brings them back"
        )),
        false => say(&format!("updates for {name} notify again")),
    }
    Ok(())
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use kendex_core::engine::{DriftRow, DriftState};
    use kendex_core::model::{HarnessId, ItemKind, Scope};

    use super::outcome_line;

    fn row(harness: HarnessId, state: DriftState) -> DriftRow {
        DriftRow {
            kind: ItemKind::Skill,
            name: "gh".to_owned(),
            harness,
            scope: Scope::Global,
            state,
            detail: "you changed this copy".to_owned(),
            cause: None,
        }
    }

    #[test]
    fn a_package_held_in_one_tool_and_current_in_another_says_both_halves() {
        let held = row(HarnessId::Claude, DriftState::Conflict);
        let moved = row(HarnessId::Codex, DriftState::Stale);
        let line = outcome_line(ItemKind::Skill, "gh", &[&held], &[&moved], true);
        assert!(line.contains("moved in codex"), "{line}");
        assert!(line.contains("copy in claude is held back"), "{line}");
        assert!(
            !line.contains("nothing moved"),
            "the run wrote one of the two copies: {line}"
        );
    }

    #[test]
    fn a_package_held_everywhere_says_nothing_moved() {
        let held = row(HarnessId::Claude, DriftState::Conflict);
        // The plan still carries ops — a sibling's lock entry, the manifest
        // — so the whole plan is the wrong thing to read this off.
        let line = outcome_line(ItemKind::Skill, "gh", &[&held], &[], true);
        assert!(
            line.contains("is held back by the conflict above"),
            "{line}"
        );
        assert!(line.contains("nothing moved for it"), "{line}");
    }

    #[test]
    fn an_unheld_package_reports_what_the_plan_did() {
        let moved = row(HarnessId::Claude, DriftState::Stale);
        assert!(
            outcome_line(ItemKind::Skill, "gh", &[], &[&moved], true).starts_with("applied"),
            "a plan with work to do applied it"
        );
        assert_eq!(
            outcome_line(ItemKind::Skill, "gh", &[], &[], false),
            "nothing to change for skill gh"
        );
    }
}
