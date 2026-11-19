//! The selected configuration package owns its render grammar. kendex
//! locates and runs that package after it changes a project, then carries the
//! package's reported output paths into the commit offer. Verification uses a
//! caller-supplied trusted checker and reads the installed doctrine as data.

use std::collections::BTreeSet;
use std::path::{Component, Path, PathBuf};

use crate::engine::{GeneratedPaths, InstalledDeclaration, Owns, Position};
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::Scope;
use crate::repo_effects::{ArmError, DeclaredEffects};

const PACKAGE: &str = "bot-instructions";
const CONFIGURATION_PACKAGE: &str = "github-repository-settings";

/// The configuration packages in selection order, the successor first.
const ORDER: [&str; 2] = [CONFIGURATION_PACKAGE, PACKAGE];

/// The configuration owner one selection chose, and the successor it was
/// chosen over.
pub(crate) struct Selection<T> {
    pub(crate) owner: T,
    /// A successor the scope carries only because another package requires
    /// it, not armed here, so the installed predecessor keeps the effect
    /// until the successor's setup moves it.
    pub(crate) pending: Option<T>,
}

/// The one configuration-owner selection every reader shares: rendering,
/// discovery, the one-run render, the commit offer and the lapse check.
///
/// Walk [`ORDER`]: an installed candidate is selected unless the scope
/// carries it only as a dependency, its own arming record stands neither
/// here nor in the main checkout of this linked work tree, and a later
/// candidate is installed. Installing a package to satisfy another's
/// requirement is not choosing it to own the repository's files, and the
/// lock's reasons are the only record of which it was. A setup in the main
/// checkout is the repository's choice, so a linked work tree keeps that
/// owner selected and is offered its setup beside the main checkout. Only
/// the yielding candidate's own record is read, so a refresh checkout,
/// which carries no records, renders what an unadopted consumer renders.
/// An unreadable declaration is a candidate, so it still prevents fallback
/// unless it yields.
pub(crate) fn select_installed(
    scope: &Scope,
    lock: &crate::lock::Lock,
    mut read: impl FnMut(&'static str) -> Result<Option<InstalledDeclaration>>,
) -> Result<Option<Selection<InstalledDeclaration>>> {
    let mut present = Vec::new();
    for name in ORDER {
        present.extend(read(name)?);
    }
    let mut pending = None;
    let mut rest = present.into_iter().peekable();
    while let Some(candidate) = rest.next() {
        if rest.peek().is_some() && yields(scope, lock, &candidate)? {
            pending.get_or_insert(candidate);
            continue;
        }
        return Ok(Some(Selection {
            owner: candidate,
            pending,
        }));
    }
    Ok(None)
}

fn yields(
    scope: &Scope,
    lock: &crate::lock::Lock,
    candidate: &InstalledDeclaration,
) -> Result<bool> {
    if !crate::lock::dependency_only(lock, candidate.name()) {
        return Ok(false);
    }
    let chosen = match (candidate, scope) {
        (InstalledDeclaration::Declared(declared), _) => {
            crate::repo_effects::armed_here(scope, declared)?
                || crate::repo_effects::set_up_in_main_checkout(scope, declared)?.is_some()
        }
        // Its reach is unreadable, so a record in either git directory
        // counts, as the lapse check reads one; the common one is the main
        // checkout's.
        (InstalledDeclaration::Unreadable { name, .. }, Scope::Project { root }) => {
            crate::repo_effects::setup::recorded_in_either(root, name)?
        }
        (InstalledDeclaration::Unreadable { .. }, Scope::Global) => false,
    };
    Ok(!chosen)
}

/// [`select_installed`] over this scope's installed packages, for a caller
/// about to run the owner: an owner whose declaration will not read is an
/// error. A pending successor whose declaration will not read names no
/// setup, so it is dropped.
pub(crate) fn configuration_selection(
    env: &Env,
    scope: &Scope,
) -> Result<Option<Selection<DeclaredEffects>>> {
    let lock = crate::lock::load(&crate::lock::lock_path(env, scope))?;
    let Some(selection) = select_installed(scope, &lock, |name| {
        crate::engine::installed_entry(env, scope, &lock, name)
    })?
    else {
        return Ok(None);
    };
    let pending = match selection.pending {
        Some(InstalledDeclaration::Declared(declared)) => Some(*declared),
        Some(InstalledDeclaration::Unreadable { .. }) | None => None,
    };
    Ok(Some(Selection {
        owner: selection.owner.into_declared()?,
        pending,
    }))
}

/// Select before checking consent: an unarmed new owner cannot license the
/// old owner's code. Only these configuration effects run automatically.
pub(crate) fn configuration_owner(env: &Env, scope: &Scope) -> Result<Option<DeclaredEffects>> {
    Ok(configuration_selection(env, scope)?.map(|selection| selection.owner))
}

/// Whether this package is one of the configuration candidates.
pub(crate) fn is_configuration_package(name: &str) -> bool {
    ORDER.contains(&name)
}

/// The configuration setup one action takes among the effects it brings.
pub struct ConfigurationSetup<'a> {
    /// The successor-most configuration package among them, the one set
    /// up.
    pub set_up: &'a DeclaredEffects,
    /// The predecessors that arrived beside it, never set up.
    pub superseded: Vec<&'a DeclaredEffects>,
}

/// The configuration packages among `effects`: the successor-most is the
/// one set up. Its setup alone moves the effect, retiring a predecessor
/// armed here through [`superseded_configuration_owner`], so a predecessor
/// that arrives beside it is not set up: its setup would arm an owner the
/// successor's retires, and its render can refuse a file the successor's
/// settings leave alone.
pub fn configuration_setup(effects: &[DeclaredEffects]) -> Option<ConfigurationSetup<'_>> {
    let mut present = ORDER
        .iter()
        .filter_map(|name| effects.iter().find(|effect| effect.name == *name));
    let set_up = present.next()?;
    Some(ConfigurationSetup {
        set_up,
        superseded: present.collect(),
    })
}

/// The configuration successor among `installed`, the effects one action
/// installed, that selection passes over for an installed predecessor
/// until its own setup moves the files: [`Selection::pending`].
///
/// Read from the selection when asked, never from a render's
/// [`RenderedPaths::pending`]: a render through a predecessor not armed here
/// names no successor, and a setup the action takes after that render, in a
/// linked work tree or at its commit offer, can arm that predecessor before
/// the offer. Arming the predecessor does not change which successor
/// yields, so this reading still names it.
pub fn pending_successor(
    env: &Env,
    scope: &Scope,
    installed: &[DeclaredEffects],
) -> Result<Option<DeclaredEffects>> {
    let pending = configuration_selection(env, scope)?.and_then(|selection| selection.pending);
    Ok(pending.filter(|successor| installed.iter().any(|effect| effect.name == successor.name)))
}

/// The installed, locally armed predecessor whose licence this package's
/// explicit setup replaces: a later candidate in [`ORDER`]. The setup is
/// the consent that moves the effect, so a successor that yields to the
/// predecessor in selection still takes it over here.
pub(crate) fn superseded_configuration_owner(
    env: &Env,
    scope: &Scope,
    declared: &DeclaredEffects,
) -> Result<Option<DeclaredEffects>> {
    let Some(at) = ORDER.iter().position(|name| *name == declared.name) else {
        return Ok(None);
    };
    for name in &ORDER[at + 1..] {
        let Some(previous) = crate::engine::installed_declaration(env, scope, name)? else {
            continue;
        };
        if crate::repo_effects::armed_here(scope, &previous)? {
            return Ok(Some(previous));
        }
    }
    Ok(None)
}

/// The selected effect judges changes to every configuration candidate, so
/// a successor that yields never holds a commit on its own.
pub(crate) fn commit_owner(
    env: &Env,
    scope: &Scope,
    declared: &DeclaredEffects,
) -> Result<DeclaredEffects> {
    if !is_configuration_package(&declared.name) {
        return Ok(declared.clone());
    }
    Ok(configuration_owner(env, scope)?.unwrap_or_else(|| declared.clone()))
}

/// Compare bot files through a trusted package supplied for this invocation.
///
/// The installed package supplies doctrine as data through `--spec`. Its code
/// and its declared commands never run. The caller licenses only the supplied
/// checker, which must sit outside the project under judgement. A clean check
/// reports whole files from the package's own render; shared regions grant no
/// whole-file ownership here.
pub fn verify(env: &Env, scope: &Scope, trusted: &Path) -> Result<Option<Vec<Position>>> {
    let Scope::Project { root } = scope.canonical() else {
        return Ok(None);
    };
    let Some(installed) = crate::engine::installed_declaration(env, scope, PACKAGE)? else {
        return Ok(None);
    };
    let trusted =
        crate::paths::canonical(trusted).map_err(|error| CoreError::io(trusted, error))?;
    if trusted.starts_with(&root) || root.starts_with(&trusted) {
        return Err(verify_error(
            &root,
            "the trusted package overlaps the checked project",
        ));
    }
    let report = crate::repo_effects::run_trusted_script_program(
        scope,
        &trusted,
        "scripts/bot-instructions",
        vec![
            "check".into(),
            "--repo".into(),
            root.as_os_str().to_owned(),
            "--spec".into(),
            installed.root.as_os_str().to_owned(),
            "--json".into(),
        ],
    )?;
    if report.code == 2
        && report
            .stderr
            .first()
            .is_some_and(|line| line.starts_with("bot-instructions: unconfigured="))
    {
        return Ok(None);
    }
    if report.code != 0 {
        return Err(verify_error(&root, said(&report.stdout, &report.stderr)));
    }
    let checked: Checked = serde_json::from_str(&report.stdout.join("\n"))
        .map_err(|error| verify_error(&root, format!("invalid check report: {error}")))?;
    if checked.version != 1 {
        return Err(verify_error(&root, "unsupported check report version"));
    }
    let positions = checked
        .paths
        .into_iter()
        .map(|relative| {
            project_path(&root, &relative)
                .map(|path| Position {
                    path,
                    owns: Owns::File,
                })
                .ok_or_else(|| {
                    verify_error(&root, "the checker reported a path outside its project")
                })
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(Some(positions))
}

#[derive(serde::Deserialize)]
struct Checked {
    version: u32,
    paths: Vec<String>,
}

fn verify_error(root: &Path, detail: impl std::fmt::Display) -> CoreError {
    CoreError::Guard {
        check: PACKAGE.to_owned(),
        message: format!("verify-failed={}\n{detail}", crate::paths::slashed(root)),
    }
}

/// Re-render the selected configuration owner's outputs in this project.
///
/// An absent package is not an error. The scope does not use this package,
/// so there is no package-owned render to run.
pub fn render(env: &Env, scope: &Scope) -> Result<RenderedPaths> {
    run(env, scope, Mode::Write)
}

/// Add the selected configuration owner's outputs to the files a commit offer
/// covers. The package remains the one judge of which flags produce paths.
pub fn add_to_generated(env: &Env, scope: &Scope, generated: &mut GeneratedPaths) -> Result<()> {
    let paths = run(env, scope, Mode::Discover)?;
    generated.whole.extend(paths.paths);
    generated.regions.extend(paths.regions);
    Ok(())
}

/// Run the installed package's render once here, on the caller's own say-so.
///
/// No arming record licenses it and none is written: the invocation that
/// calls this is the licence, spent on this one run. A consumer refresh
/// calls it through a kendex verb with no credential in its environment,
/// in a checkout it discards. The package's report comes back whatever its
/// exit, because its verdict, including that the project never configured
/// it, is the caller's to read. `None` where the project does not install
/// the package.
pub fn render_once(
    env: &Env,
    scope: &Scope,
) -> std::result::Result<Option<crate::guard::GuardReport>, ArmError> {
    let Some(declared) = configuration_owner(env, scope)? else {
        return Ok(None);
    };
    let report = crate::repo_effects::run_script(scope, &declared.root, declared.installer()?)?;
    Ok(Some(report))
}

/// Paths written by one successful render.
#[derive(Debug, Default, PartialEq)]
pub struct RenderedPaths {
    paths: BTreeSet<PathBuf>,
    regions: BTreeSet<crate::commit_offer::OwnedRegion>,
    skipped: Option<Skipped>,
    pending: Option<Pending>,
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

    /// The successor whose setup would take this render over, where the
    /// armed owner rendered because the successor arrived as a dependency.
    pub fn pending(&self) -> Option<&Pending> {
        self.pending.as_ref()
    }
}

/// A configuration successor installed here only as another package's
/// dependency, while the armed predecessor keeps rendering. Its existing
/// setup is the step that moves the files.
#[derive(Debug, Clone, PartialEq)]
pub struct Pending {
    /// The installed successor, for a surface that runs its setup.
    pub successor: DeclaredEffects,
    /// The armed package that rendered.
    pub owner: String,
}

impl Pending {
    /// The line a surface prints for it.
    pub fn line(&self) -> String {
        let name = &self.successor.name;
        format!(
            "{name}: installed as a dependency; {owner} keeps rendering this repository's review files until {name} is set up here: use Set up on the {name} package page",
            owner = self.owner
        )
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
        let name = &self.declared.name;
        match &self.set_up_in {
            None => format!(
                "{name}: render skipped; use Set up on the {name} package page, or remove and add it with --allow-repo-effects, then apply again"
            ),
            Some(main) => format!(
                "{name}: render skipped in this work tree; it is set up in the main checkout at {}, and each work tree is set up on its own: use Set up on the {name} package page, then apply again",
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

    /// A file the package removes because its render no longer produces it.
    /// The deletion is the render's like a write, so the commit offer
    /// carries it.
    fn removal_prefix(self) -> &'static str {
        match self {
            Self::Write => "removed ",
            Self::Discover => "would remove ",
        }
    }
}

fn run(env: &Env, scope: &Scope, mode: Mode) -> Result<RenderedPaths> {
    let Scope::Project { root } = scope.canonical() else {
        return Ok(RenderedPaths::default());
    };
    let Some(Selection {
        owner: declared,
        pending,
    }) = configuration_selection(env, scope)?
    else {
        return Ok(RenderedPaths::default());
    };
    if !crate::repo_effects::armed_here(scope, &declared)? {
        let set_up_in = crate::repo_effects::set_up_in_main_checkout(scope, &declared)?;
        return Ok(skipped(declared, set_up_in));
    }
    // An armed package that declares no installer has nothing to render
    // with, which fails the render naming the package.
    let installer = declared
        .installer()
        .map_err(|error| crate::repo_effects::err(error.to_string()))?;
    let command = declared.command(&root, installer);
    let launch = |spec: &str| {
        crate::repo_effects::run_script(scope, &declared.root, spec).map_err(|error| {
            CoreError::BotInstructionsRender {
                root: root.clone(),
                command: command.clone(),
                detail: error.to_string(),
            }
        })
    };
    let report = match mode {
        Mode::Write => launch(installer)?,
        Mode::Discover => {
            let report = launch(&format!("{installer} --discover"))?;
            if predates_discover(&declared.name, &report) {
                launch(&format!("{installer} --dry-run"))?
            } else {
                report
            }
        }
    };
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
        let Some(relative) = line
            .strip_prefix(prefix)
            .or_else(|| line.strip_prefix(mode.removal_prefix()))
        else {
            continue;
        };
        paths.insert(reported_path(&root, &command, line, relative)?);
    }
    let pending = pending.map(|successor| Pending {
        successor,
        owner: declared.name.clone(),
    });
    Ok(RenderedPaths {
        paths,
        regions,
        skipped: None,
        pending,
    })
}

/// Whether the installed package refused `--discover` as an unknown flag,
/// so it was installed before the flag existed (KEN-3521; the catalog
/// package at 33dd66732 is such a producer) and its `--dry-run` is still
/// the owned-only listing discovery reads.
///
/// This discovery owns the fallback, for the installed packages kendex
/// wrote. A project keeps such a copy until an apply refreshes the package,
/// and the app's commit offer plans without applying before it runs
/// discovery, so a raised catalog `min_kendex` does not replace the copy
/// first. Without this, commit-offer discovery, commit and restore fail on
/// every such project.
///
/// The package's documented refusal protocol is a first stderr line
/// `<name>: usage=<argv>` and exit 2. kendex passes only the declared
/// installer and the flag, and the installer alone is what a write runs, so
/// a usage refusal here names the flag. This fallback retires at the next
/// major release, per the release standard in `changelog.d/README.md`. It
/// prints no warning: the old copy is the package kendex installed, and the
/// next apply that reaches a current catalog replaces it with no step of the
/// consumer's own.
fn predates_discover(package: &str, report: &crate::guard::GuardReport) -> bool {
    report.code == 2
        && report
            .stderr
            .first()
            .is_some_and(|line| line.starts_with(&format!("{package}: usage=")))
}

fn reported_path(root: &Path, command: &str, line: &str, relative: &str) -> Result<PathBuf> {
    project_path(root, relative).ok_or_else(|| {
        protocol_error(
            root,
            command,
            line,
            "the renderer reported a path outside its project",
        )
    })
}

fn project_path(root: &Path, relative: &str) -> Option<PathBuf> {
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
        return None;
    }
    Some(root.join(relative))
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
        pending: None,
    }
}

pub(crate) fn said(stdout: &[String], stderr: &[String]) -> String {
    let lines: Vec<&str> = stdout.iter().chain(stderr).map(String::as_str).collect();
    match lines.is_empty() {
        true => "the renderer exited without an explanation".to_owned(),
        false => lines.join("\n"),
    }
}
