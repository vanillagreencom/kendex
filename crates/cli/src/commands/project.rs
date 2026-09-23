use std::path::PathBuf;

use clap::{Args, Subcommand};
use kendex_core::env::Env;
use kendex_core::error::CoreError;
use kendex_core::model::Scope;
use kendex_core::{discover, settings};

use super::{CliResult, out};
use crate::ui::{Lines, escaped};

#[derive(Subcommand)]
pub enum ProjectCommand {
    /// Add a project folder to Projects
    Add {
        path: PathBuf,
        /// Also install package checks there, which run when a session starts
        #[arg(long)]
        drift_hook: bool,
        /// Install this saved template into the project once it is
        /// registered
        #[arg(long)]
        template: Option<String>,
        /// Skip confirmation prompts (with --drift-hook or --template)
        #[arg(short = 'y', long)]
        yes: bool,
        #[command(flatten)]
        throwaway: ThrowawayFlag,
    },
    /// Remove a project from Projects (nothing in its folder is deleted)
    Remove { path: PathBuf },
    /// Point a project on Projects at the folder it was moved to
    Reconnect {
        /// The folder Projects lists now
        #[arg(long)]
        from: PathBuf,
        /// The folder the project is in
        #[arg(long)]
        to: PathBuf,
        /// Join this project with the one Projects already lists at the destination
        #[arg(long)]
        consolidate: bool,
    },
    /// List the projects on Projects
    List,
    /// Walk a directory for harness-marked projects
    Discover {
        root: PathBuf,
        /// Add every project found to Projects
        #[arg(long)]
        register: bool,
        #[command(flatten)]
        throwaway: ThrowawayFlag,
    },
}

/// The one answer to the temporary-path refusal, flattened into every
/// verb that can put a folder on the projects list. Most of them register
/// the destination they settle on, and the flag answers for that. On
/// `refresh`, `apply` and `updates` it answers only for the project a
/// `--project-path` names: those register nothing otherwise, so without
/// that flag beside it the flag decides nothing.
#[derive(Args, Clone, Copy, Default)]
pub struct ThrowawayFlag {
    /// Add a throwaway project to Projects: a folder under a temporary
    /// path, which is otherwise refused
    #[arg(long)]
    pub throwaway: bool,
}

pub fn run(env: &Env, cmd: ProjectCommand) -> CliResult {
    match cmd {
        ProjectCommand::Add {
            path,
            drift_hook,
            template,
            yes,
            throwaway,
        } => {
            // With a template, registering and filling the project is
            // one path — the template lands before the hook offer rather
            // than as a second command somebody has to know about — and
            // the registration is the install's own, made on the strength
            // of what landed: a template nobody saved, one with an
            // unreachable member, a missing answer in a run with nobody to
            // ask, or a package no tool on this machine can take refuses
            // with the registry untouched. This crate's rule is that a
            // verb needing input fails naming the flag before its first
            // write.
            match &template {
                Some(name) => {
                    let planned =
                        super::template_cmd::plan_install(env, name, Some(&path), throwaway)?;
                    super::template_cmd::confirm_install(&planned, yes)?;
                    super::template_cmd::run_install(env, &planned)?;
                }
                None => {
                    registrable(env, &path, throwaway)?;
                    settings::register_project(env, &path)?;
                    out(&format!("registered {}", path.display()));
                }
            }
            offer_to_manage(env, &path);
            match drift_hook {
                true => {
                    let scope = kendex_core::model::Scope::Project { root: path.clone() };
                    super::drift_hook::install(env, &scope, yes)?;
                }
                // Registration is where the drift hook is offered: agents in
                // this project start blind until it is installed.
                false => out(
                    "tip: the drift-hook verb installs package checks, which run when a session starts",
                ),
            }
        }
        ProjectCommand::Remove { path } => {
            settings::unregister_project(env, &path)?;
            out(&format!("removed {}", path.display()));
        }
        ProjectCommand::Reconnect {
            from,
            to,
            consolidate,
        } => {
            let (plan, _, _) = settings::relocate_project(env, &from, &to, consolidate)?;
            out(&format!(
                "{} is now at {}{}",
                plan.from.display(),
                plan.to.display(),
                match plan.standing {
                    settings::Standing::Registered =>
                        "  (joined with the project already listed there)",
                    settings::Standing::NoRecord => "  (no packages recorded there)",
                    _ => "",
                }
            ));
        }
        ProjectCommand::List => list(env)?,
        ProjectCommand::Discover {
            root,
            register,
            throwaway,
        } => {
            let found_projects = discover::discover_projects(&root)?;
            // Every folder is judged before the first is registered, so a
            // refusal registers nothing rather than the ones sorted ahead
            // of it.
            if register {
                for found in &found_projects {
                    registrable(env, found, throwaway)?;
                }
            }
            for found in found_projects {
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

/// The projects this machine tracks, one per line, each with what is
/// wrong with it or what it is.
fn list(env: &Env) -> CliResult {
    for project in settings::load(env)?.projects {
        let missing = kendex_core::scan::missing_why(&project);
        out(&format!(
            "{}{}{}",
            project.display(),
            match &missing {
                None => "",
                Some(kendex_core::scan::MissingWhy::Gone) => "  (folder not found)",
                Some(kendex_core::scan::MissingWhy::NotAFolder) => "  (not a folder)",
                Some(kendex_core::scan::MissingWhy::Unreadable { .. }) =>
                    "  (folder could not be read)",
            },
            match missing {
                // A folder nobody could read answers no question about the
                // repository it might be in.
                Some(_) => String::new(),
                None => worktree_note(&project),
            }
        ));
    }
    Ok(())
}

/// What a listed project is, where it is one work tree of a repository
/// whose main checkout is somewhere else.
///
/// A linked git worktree carrying declarations of its own is a project in
/// its own right, and it sits on this list beside the checkout it was
/// added from — two entries, two manifests, two installs. Which is which
/// is not readable from the paths, so the line says it.
///
/// A git that cannot answer says nothing rather than guessing: this is a
/// listing, and an entry annotated from a failed read would claim a
/// repository relationship nobody established.
fn worktree_note(project: &std::path::Path) -> String {
    let Ok(Some(repo)) = kendex_core::guard::Repo::probe(project) else {
        return String::new();
    };
    if !repo.is_linked() {
        return String::new();
    }
    match repo.main_checkout() {
        Ok(main) => format!("  (worktree of {})", main.display()),
        Err(_) => "  (worktree)".to_owned(),
    }
}

/// Whether a folder may go on the projects list, asked by every
/// registering verb before its first write: a run that refused only once
/// it had installed would leave packages in a folder it then would not
/// register.
///
/// The rule is core's, `settings::refuse_temporary`; what is added here is
/// the flag that answers it and the line that names the flag.
pub fn registrable(env: &Env, root: &std::path::Path, flag: ThrowawayFlag) -> CliResult {
    if flag.throwaway {
        return Ok(());
    }
    match settings::refuse_temporary(env, root) {
        Ok(()) => Ok(()),
        // Core escaped the path where it composed the first line, so the
        // break between the two is the message's own.
        Err(refused @ CoreError::TemporaryProject { .. }) => Err(Lines(format!(
            "{refused}\npass --throwaway to add a throwaway project to Projects anyway"
        ))
        .into()),
        Err(error) => Err(error.into()),
    }
}

/// Whether the project a `--project-path` named may go on the projects
/// list, asked by the whole-scope writing verbs before their first write.
///
/// The registration itself comes after the write, under the rule
/// [`register_target`] owns — but the refusal cannot wait for it: a run
/// that installed and only then declined to register would leave packages
/// in a folder kendex does not track. So the rule every registering verb
/// asks is asked here too, on the root resolution already settled on, and
/// `--throwaway` beside `--project-path` is what answers it.
///
/// Asked on the resolved root alone, before any declaration is read, so a
/// run that would have found nothing to register is refused here too. The
/// alternative is reading a project to decide whether it may be read.
///
/// A run with no named project registers nothing and is asked nothing:
/// writing the project a command was typed in is what every release
/// before `--project-path` did, and it never touched the registry.
pub fn target_registrable(
    env: &Env,
    target: &crate::flags::ProjectTargetFlag,
    scopes: &[Scope],
) -> CliResult {
    if target.path().is_none() {
        return Ok(());
    }
    for scope in scopes {
        if let Scope::Project { root } = scope {
            registrable(env, root, target.throwaway)?;
        }
    }
    Ok(())
}

/// The project a `--project-path` named, on the projects list now that the
/// run has written it.
///
/// **The rule lives here, and every other surface stating it points at
/// this function.** A named run registers the project it resolved once it
/// has got through that project's write, whether the write had work to do
/// or the place was already up to date. A run that never reaches the
/// write leaves the list as it found it: `apply --plan` and a bare
/// `updates` listing, which write nothing by design; a scope that
/// declares nothing, which neither verb lists even where an old lock
/// still names installs in it; a plan that failed, reported
/// instead; and a confirmation the reader declined — except in `refresh`,
/// where a Pi settle before the final confirm has already written what
/// this then registers.
///
/// Called by `refresh`, `apply` and `updates --apply` after the write, and
/// only where the destination was named: a walked-up project is the one
/// the command was typed in, which those verbs have never registered.
pub fn register_target(
    env: &Env,
    target: &crate::flags::ProjectTargetFlag,
    scope: &Scope,
) -> CliResult {
    match target.path() {
        Some(_) => register_destination(env, scope),
        None => Ok(()),
    }
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
        "{} package{} here {} not managed by kendex yet:",
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
