//! The installed bot-instructions package owns its render grammar. kendex
//! locates and runs that package after it changes a project, then carries the
//! package's reported output paths into the commit offer.

use std::collections::BTreeSet;
use std::path::{Component, Path, PathBuf};

use crate::engine::GeneratedPaths;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::Scope;
use crate::repo_effects::DeclaredEffects;

const PACKAGE: &str = "bot-instructions";

/// Re-render every enabled bot-instruction surface in this project.
///
/// An absent package is not an error. The scope does not use this package,
/// so there is no package-owned render to run.
pub fn render(env: &Env, scope: &Scope) -> Result<RenderedPaths> {
    run(env, scope, Mode::Write)
}

/// Add every enabled bot-instruction surface to the files a commit offer
/// covers. The package remains the one judge of which flags produce paths.
pub fn add_to_generated(env: &Env, scope: &Scope, generated: &mut GeneratedPaths) -> Result<()> {
    let paths = run(env, scope, Mode::Discover)?;
    generated.whole.extend(paths.paths);
    generated.regions.extend(paths.regions);
    Ok(())
}

/// Paths written by one successful render.
#[derive(Debug, Default, PartialEq)]
pub struct RenderedPaths {
    paths: BTreeSet<PathBuf>,
    regions: BTreeSet<crate::commit_offer::OwnedRegion>,
    skipped: Option<Skipped>,
}

impl RenderedPaths {
    /// Add these package-owned surfaces to a commit offer's generated paths.
    pub fn add_to(self, generated: &mut GeneratedPaths) {
        generated.whole.extend(self.paths);
        generated.regions.extend(self.regions);
    }

    /// Why no package code ran, for the surface that applied the project.
    pub fn skipped(&self) -> Option<&Skipped> {
        self.skipped.as_ref()
    }
}

/// The package is installed here and kendex ran none of its code, because
/// no record licenses it in this checkout.
#[derive(Debug, Clone, PartialEq)]
pub struct Skipped {
    /// The installed package, for a surface that offers to set it up.
    pub declared: DeclaredEffects,
    /// The main checkout, where this is a linked work tree of a repository
    /// that set the package up there:
    /// [`crate::repo_effects::set_up_in_main_checkout`].
    pub set_up_in: Option<PathBuf>,
}

impl Skipped {
    /// The line a surface prints for it.
    pub fn line(&self) -> String {
        match &self.set_up_in {
            None => "bot-instructions: render skipped; use Set up on the bot-instructions package page, or remove and add it with --allow-repo-effects, then apply again".to_owned(),
            Some(main) => format!(
                "bot-instructions: render skipped in this work tree; it is set up in the main checkout at {}, and each work tree is set up on its own: use Set up on the bot-instructions package page, then apply again",
                crate::paths::slashed(main)
            ),
        }
    }
}

#[derive(Clone, Copy)]
enum Mode {
    Write,
    Discover,
}

impl Mode {
    fn prefix(self) -> &'static str {
        match self {
            Self::Write => "wrote ",
            Self::Discover => "would write ",
        }
    }
}

fn run(env: &Env, scope: &Scope, mode: Mode) -> Result<RenderedPaths> {
    let Scope::Project { root } = scope.canonical() else {
        return Ok(RenderedPaths::default());
    };
    let Some(declared) = crate::engine::installed_declaration(env, scope, PACKAGE)? else {
        return Ok(RenderedPaths::default());
    };
    if !crate::repo_effects::armed_here(scope, &declared)? {
        let set_up_in = crate::repo_effects::set_up_in_main_checkout(scope, &declared)?;
        return Ok(skipped(declared, set_up_in));
    }
    let Some(installer) = declared.effects.installer.clone() else {
        return Ok(skipped(declared, None));
    };
    let installer = installer.as_str();
    let spec = match mode {
        Mode::Write => installer.to_owned(),
        Mode::Discover => format!("{installer} --dry-run"),
    };
    let command = declared.command(&root, installer);
    let report =
        crate::repo_effects::run_script(scope, &declared.root, &spec).map_err(|error| {
            CoreError::BotInstructionsRender {
                root: root.clone(),
                command: command.clone(),
                detail: error.to_string(),
            }
        })?;
    if report.code != 0 {
        return Err(CoreError::BotInstructionsRender {
            root,
            command,
            detail: said(&report.stdout, &report.stderr),
        });
    }
    let prefix = mode.prefix();
    let region_prefix = match mode {
        Mode::Write => "wrote region ",
        Mode::Discover => "would write region ",
    };
    let mut paths = BTreeSet::new();
    let mut regions = BTreeSet::new();
    for line in &report.stdout {
        if let Some(reported) = line.strip_prefix(region_prefix) {
            let Some((relative, heading)) = reported.split_once('\t') else {
                return Err(protocol_error(
                    &root,
                    &command,
                    line,
                    "a region needs a path and heading separated by a tab",
                ));
            };
            let path = reported_path(&root, &command, line, relative)?;
            let region = crate::commit_offer::OwnedRegion::new(
                path,
                heading.to_owned(),
                declared.root.clone(),
                installer.to_owned(),
            )
            .map_err(|detail| protocol_error(&root, &command, line, &detail))?;
            regions.insert(region);
            continue;
        }
        let Some(relative) = line.strip_prefix(prefix) else {
            continue;
        };
        paths.insert(reported_path(&root, &command, line, relative)?);
    }
    Ok(RenderedPaths {
        paths,
        regions,
        skipped: None,
    })
}

fn reported_path(root: &Path, command: &str, line: &str, relative: &str) -> Result<PathBuf> {
    let relative = Path::new(relative);
    if relative.as_os_str().is_empty()
        || relative.is_absolute()
        || relative.components().any(|part| {
            matches!(
                part,
                Component::ParentDir | Component::RootDir | Component::Prefix(_)
            )
        })
    {
        return Err(protocol_error(
            root,
            command,
            line,
            "the renderer reported a path outside its project",
        ));
    }
    Ok(root.join(relative))
}

fn protocol_error(root: &Path, command: &str, line: &str, detail: &str) -> CoreError {
    CoreError::BotInstructionsRender {
        root: root.to_owned(),
        command: command.to_owned(),
        detail: format!("{detail}: {line}"),
    }
}

fn skipped(declared: DeclaredEffects, set_up_in: Option<PathBuf>) -> RenderedPaths {
    RenderedPaths {
        paths: BTreeSet::new(),
        regions: BTreeSet::new(),
        skipped: Some(Skipped {
            declared,
            set_up_in,
        }),
    }
}

pub(crate) fn said(stdout: &[String], stderr: &[String]) -> String {
    let lines: Vec<&str> = stdout.iter().chain(stderr).map(String::as_str).collect();
    match lines.is_empty() {
        true => "the renderer exited without an explanation".to_owned(),
        false => lines.join("\n"),
    }
}
