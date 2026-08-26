use std::path::PathBuf;

use clap::Subcommand;
use kendex_core::env::Env;
use kendex_core::error::CoreError;
use kendex_core::{discover, settings};

use super::{CliResult, out};

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

/// What a freshly registered project already holds that nothing manages.
/// Said at registration rather than left for a later visit: content nobody
/// knows is there is content nobody chooses about, and the offer names the
/// command that takes it.
fn offer_to_manage(env: &Env, root: &std::path::Path) {
    let scope = kendex_core::model::Scope::Project {
        root: root.to_path_buf(),
    };
    let rows = kendex_core::engine::unmanaged_here(env, &scope);
    if rows.is_empty() {
        return;
    }
    out(&format!(
        "{} item{} here {} not managed yet:",
        rows.len(),
        if rows.len() == 1 { "" } else { "s" },
        if rows.len() == 1 { "is" } else { "are" }
    ));
    for row in &rows {
        // Runnable as printed, from wherever this was typed: `adopt` acts on
        // the current project and defaults to Claude Code, and a row for
        // another tool followed as-is would refuse or take the wrong copy.
        out(&format!(
            "  - {} {} [{}]  (cd {} && kendex adopt {} {} --harness {})",
            row.kind.name(),
            kendex_core::names::shown(&row.name),
            row.harness.display_name(),
            kendex_core::names::shown(&root.display().to_string()),
            row.kind.name(),
            kendex_core::names::shown(&row.name),
            row.harness.name(),
        ));
    }
}
