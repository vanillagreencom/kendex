use std::path::PathBuf;

use clap::Subcommand;
use kendex_core::env::Env;
use kendex_core::error::CoreError;
use kendex_core::model::Scope;
use kendex_core::{discover, settings};

use super::{CliResult, out};
use crate::ui::{Lines, escaped};

#[derive(Subcommand)]
pub enum ProjectCommand {
    /// Register a project directory
    Add {
        path: PathBuf,
        /// Also install the session-start drift report hook there
        #[arg(long)]
        drift_hook: bool,
        /// Skip confirmation prompts (with --drift-hook)
        #[arg(short = 'y', long)]
        yes: bool,
    },
    /// Drop a project from the registry (its files are untouched)
    Remove { path: PathBuf },
    /// List registered projects
    List,
    /// Walk a directory for harness-marked projects
    Discover {
        root: PathBuf,
        /// Register every project found
        #[arg(long)]
        register: bool,
    },
}

pub fn run(env: &Env, cmd: ProjectCommand) -> CliResult {
    match cmd {
        ProjectCommand::Add {
            path,
            drift_hook,
            yes,
        } => {
            settings::register_project(env, &path)?;
            out(&format!("registered {}", path.display()));
            offer_to_manage(env, &path);
            match drift_hook {
                true => {
                    let scope = kendex_core::model::Scope::Project { root: path.clone() };
                    super::drift_hook::install(env, &scope, yes)?;
                }
                // Registration is where the drift hook is offered: agents in
                // this project start blind until it is installed.
                false => out("tip: `kendex drift-hook` installs the session-start drift report"),
            }
        }
        ProjectCommand::Remove { path } => {
            settings::unregister_project(env, &path)?;
            out(&format!("removed {}", path.display()));
        }
        ProjectCommand::List => {
            for project in settings::load(env)?.projects {
                let missing = if project.is_dir() { "" } else { "  (missing)" };
                out(&format!("{}{missing}", project.display()));
            }
        }
        ProjectCommand::Discover { root, register } => {
            for found in discover::discover_projects(&root)? {
                if register {
                    match settings::register_project(env, &found) {
                        Ok(_) => out(&format!("registered {}", found.display())),
                        Err(CoreError::ProjectAlreadyRegistered { .. }) => {
                            out(&format!("already registered {}", found.display()));
                        }
                        Err(e) => return Err(e.into()),
                    }
                } else {
                    out(&format!("{}", found.display()));
                }
            }
        }
    }
    Ok(())
}

/// Put the folder an install has just written into on the list of projects
/// the app and `project list` read.
///
/// Called after the write by every verb that installs into a project
/// scope. Without it the CLI wrote packages into a folder the app had
/// never heard of, and the only way to see them was a second command
/// nobody was told about.
///
/// A global install reaches here and registers nothing: the personal scope
/// is not a project, and the folder the command was typed in is not where
/// the packages went.
///
/// A registry that refuses is not a failed install. The packages are on
/// disk, the run has already reported them, and what this returns names
/// the folder they are in — so the retry is the registration on its own.
/// Running the install again to repair the registry would mutate packages
/// a second time for a write that never touches them.
pub fn register_destination(env: &Env, scope: &Scope) -> CliResult {
    let Scope::Project { root } = scope else {
        return Ok(());
    };
    match settings::ensure_project_registered(env, root) {
        // Said only where there was something to say: a project kendex
        // already tracks is the ordinary case, and a line about it under
        // every install is a line nobody reads.
        Ok(registered) if registered.added => {
            out(&format!(
                "added {} to your projects",
                registered.root.display()
            ));
            Ok(())
        }
        Ok(_) => Ok(()),
        // Two facts and one next step, and the packages are the fact that
        // has to survive: a reader told only that something failed runs
        // the install again. The breaks are this message's own, so both
        // values are escaped where they are composed.
        Err(error) => Err(Lines(format!(
            "the packages are installed in {}, and the folder could not be put on your projects list: {}\nthe project add verb, given that path, is the retry — the packages are installed already, so do not run the install again",
            escaped(&root.display().to_string()),
            escaped(&error.to_string()),
        ))
        .into()),
    }
}

/// What a freshly registered project already holds that nothing manages.
/// Said at registration rather than left for a later visit: content nobody
/// knows is there is content nobody chooses about, and the offer names the
/// command that takes it.
///
/// One line per item, not per row: several tools reading one shared folder
/// produce a row each, and adoption takes that folder for all of them in a
/// single pass. A command per row would run the same move repeatedly, and
/// each run after the first would find nothing there.
fn offer_to_manage(env: &Env, root: &std::path::Path) {
    let scope = kendex_core::model::Scope::Project {
        root: root.to_path_buf(),
    };
    let rows = kendex_core::engine::unmanaged_here(env, &scope);
    let items = grouped(&rows);
    if items.is_empty() {
        return;
    }
    out(&format!(
        "{} item{} here {} not managed yet:",
        items.len(),
        if items.len() == 1 { "" } else { "s" },
        if items.len() == 1 { "is" } else { "are" }
    ));
    for item in &items {
        // Runnable as printed, from wherever this was typed: `adopt` acts on
        // the current project and defaults to Claude Code, so the line names
        // the project and every tool the item sits at.
        let tools: String = item
            .harnesses
            .iter()
            .map(|harness| format!(" --harness {harness}"))
            .collect();
        out(&format!(
            "  - {} {} [{}]  (cd {} && kendex adopt {} {}{tools})",
            item.kind.name(),
            item.name,
            item.tools.join(", "),
            kendex_core::names::quoted(&root.display().to_string()),
            item.kind.name(),
            item.name,
        ));
    }
}

/// One offer: an item, and every tool holding it at the same place.
struct Offer {
    kind: kendex_core::model::ItemKind,
    name: String,
    /// Tool ids, for the command; display names, for the line.
    harnesses: Vec<&'static str>,
    tools: Vec<&'static str>,
}

/// The rows folded onto the item each one is about. Rows sharing a kind,
/// a name and a path are one item several tools read, which adoption takes
/// in one pass; anything else is a separate item that happens to share a
/// name.
fn grouped(rows: &[kendex_core::engine::DriftRow]) -> Vec<Offer> {
    let mut items: Vec<(String, Offer)> = Vec::new();
    for row in rows {
        let key = format!("{}\u{1}{}\u{1}{}", row.kind.name(), row.name, row.detail);
        match items.iter_mut().find(|(held, _)| *held == key) {
            Some((_, offer)) => {
                if !offer.harnesses.contains(&row.harness.name()) {
                    offer.harnesses.push(row.harness.name());
                    offer.tools.push(row.harness.display_name());
                }
            }
            None => items.push((
                key,
                Offer {
                    kind: row.kind,
                    name: row.name.clone(),
                    harnesses: vec![row.harness.name()],
                    tools: vec![row.harness.display_name()],
                },
            )),
        }
    }
    items.into_iter().map(|(_, offer)| offer).collect()
}
