use clap::{Args, Subcommand};

use kendex_core::env::Env;
use kendex_core::model::ItemKind;

use super::engine_common::{confirm_and_execute, print_report};
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
    #[arg(short = 'y', long, global = true)]
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
            return apply_one(env, &scope, kind, name, yes);
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

/// Bring one package current: the single-package apply, reported and
/// confirmed the way every other writing verb is — the shared printer says
/// what the plan found and would do, the shared gate asks before any of it
/// is written, and this verb adds one line of its own about the package it
/// was asked for. Nothing here restates what the printer already says: a
/// diagnostic it gains is one this verb gains.
///
/// The scope's other followers stay at their installed commits (bar one
/// the lock cannot place, which resolves fresh either way); a hold on
/// the package itself still holds, and any conflict the plan raises for it
/// (a hand-edited copy, files in the way) is said instead of applied over.
fn apply_one(
    env: &Env,
    scope: &kendex_core::model::Scope,
    kind: String,
    name: String,
    yes: bool,
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
    let removed = kendex_core::package::removed(&report, kind, &name);
    let moving = kendex_core::package::moving(&report, kind, &name);
    let changed = !report.plan.ops.is_empty();
    // Notes, warnings, safety scores, the conflicts and their ways out, and
    // the plan itself — the same account `apply` and `pin` give.
    print_report(env, &report);
    // And the same gate they pass: a session with nobody to ask refuses
    // rather than writing on a mistyped or scripted run. An empty plan
    // falls straight through, so the line below is still what a run with
    // nothing to do says.
    confirm_and_execute(env, &report, yes)?;
    // The deep work just ran; write it down so the next session-start check
    // reads verdicts instead of guesses.
    if let Err(error) = kendex_core::drift::snapshot::record(env, scope) {
        say(&format!("warning: snapshot not derived ({error})"));
    }
    say(&outcome_line(
        kind, &name, &held, &removed, &moving, changed,
    ));
    Ok(())
}

/// What the run just did to the package it named, in one line. Conflicts
/// are per rendering, and a refused one is not one outcome: a copy with
/// the person's work in it is kept where it is, while one with nothing of
/// theirs goes to the trash with nothing written in its place. Calling
/// either "nothing moved" states a wrong fact — about work the same run
/// performed, or about a copy it just took away.
fn outcome_line(
    kind: ItemKind,
    name: &str,
    held: &[&kendex_core::engine::DriftRow],
    removed: &[&kendex_core::engine::DriftRow],
    moving: &[&kendex_core::engine::DriftRow],
    changed: bool,
) -> String {
    let tools = |rows: &[&kendex_core::engine::DriftRow]| {
        let mut names: Vec<&str> = rows.iter().map(|row| row.harness.name()).collect();
        names.sort_unstable();
        names.dedup();
        names.join(", ")
    };
    // Nothing of the package was refused: the two answers a run with
    // nothing standing in its way can give.
    if held.is_empty() && removed.is_empty() {
        return match changed {
            true => format!("applied — {} {name} is current here", kind.name()),
            false => format!("nothing to change for {} {name}", kind.name()),
        };
    }
    // Refused everywhere, with every copy kept: the run really did nothing.
    if removed.is_empty() && moving.is_empty() {
        return format!(
            "{} {name} is held back by the conflict above — nothing moved for it",
            kind.name()
        );
    }
    let mut said = Vec::new();
    if !moving.is_empty() {
        said.push(format!("moved in {}", tools(moving)));
    }
    if !removed.is_empty() {
        said.push(format!(
            "its copy in {} went to the trash with nothing written in its place",
            tools(removed)
        ));
    }
    if !held.is_empty() {
        said.push(format!(
            "its copy in {} is held back by the conflict above",
            tools(held)
        ));
    }
    format!("{} {name}: {}", kind.name(), said.join(" — "))
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
        let line = outcome_line(ItemKind::Skill, "gh", &[&held], &[], &[&moved], true);
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
        let line = outcome_line(ItemKind::Skill, "gh", &[&held], &[], &[], true);
        assert!(
            line.contains("is held back by the conflict above"),
            "{line}"
        );
        assert!(line.contains("nothing moved for it"), "{line}");
    }

    // A refusal with nothing of the person's in the files takes the old
    // copy to the trash and writes nothing back. Reported as a hold, the
    // run says nothing happened over the one outcome that took something
    // away.
    #[test]
    fn a_refused_copy_that_went_to_the_trash_is_never_reported_as_held() {
        let gone = row(HarnessId::Claude, DriftState::Conflict);
        let line = outcome_line(ItemKind::Skill, "gh", &[], &[&gone], &[], true);
        assert!(line.contains("went to the trash"), "{line}");
        assert!(
            !line.contains("nothing moved") && !line.contains("held back"),
            "a copy that was taken away is not a copy that stayed: {line}"
        );

        // And beside a copy that did move, both halves are said.
        let moved = row(HarnessId::Codex, DriftState::Stale);
        let both = outcome_line(ItemKind::Skill, "gh", &[], &[&gone], &[&moved], true);
        assert!(both.contains("moved in codex"), "{both}");
        assert!(both.contains("copy in claude went to the trash"), "{both}");
    }

    #[test]
    fn an_unheld_package_reports_what_the_plan_did() {
        let moved = row(HarnessId::Claude, DriftState::Stale);
        assert!(
            outcome_line(ItemKind::Skill, "gh", &[], &[], &[&moved], true).starts_with("applied"),
            "a plan with work to do applied it"
        );
        assert_eq!(
            outcome_line(ItemKind::Skill, "gh", &[], &[], &[], false),
            "nothing to change for skill gh"
        );
    }
}
