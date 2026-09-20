//! The installed bot-instructions package owns its render grammar. kendex
//! locates and runs that package after it changes a project, then carries the
//! package's reported output paths into the commit offer.

use std::collections::BTreeSet;
use std::path::{Component, Path, PathBuf};

use crate::engine::GeneratedPaths;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::Scope;

const PACKAGE: &str = "bot-instructions";
const SKIPPED: &str = "bot-instructions: render skipped; use Set up on the bot-instructions package page, or remove and add it with --allow-repo-effects, then apply again";

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
    Ok(())
}

/// Paths written by one successful render.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct RenderedPaths {
    paths: BTreeSet<PathBuf>,
    skipped: Option<&'static str>,
}

impl RenderedPaths {
    /// Add these package-owned surfaces to a commit offer's generated paths.
    pub fn add_to(self, generated: &mut GeneratedPaths) {
        generated.whole.extend(self.paths);
    }

    /// Why no package code ran, for the surface that applied the project.
    pub fn skipped(&self) -> Option<&str> {
        self.skipped
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
        return Ok(skipped());
    }
    let Some(installer) = declared.effects.installer.as_deref() else {
        return Ok(skipped());
    };
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
    let mut paths = BTreeSet::new();
    for line in &report.stdout {
        let Some(relative) = line.strip_prefix(prefix) else {
            continue;
        };
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
            return Err(CoreError::BotInstructionsRender {
                root,
                command,
                detail: format!("the renderer reported a path outside its project: {line}"),
            });
        }
        paths.insert(root.join(relative));
    }
    Ok(RenderedPaths {
        paths,
        skipped: None,
    })
}

fn skipped() -> RenderedPaths {
    RenderedPaths {
        paths: BTreeSet::new(),
        skipped: Some(SKIPPED),
    }
}

fn said(stdout: &[String], stderr: &[String]) -> String {
    let lines: Vec<&str> = stdout.iter().chain(stderr).map(String::as_str).collect();
    match lines.is_empty() {
        true => "the renderer exited without an explanation".to_owned(),
        false => lines.join("\n"),
    }
}
