//! Pi package installation, runtime registration, and ownership records.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Deserialize;
use serde_json::Value;

use crate::configedit::{ConfigEdit, remove_marker_block, upsert_marker_block};
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::fs::make_symlink;
use crate::fs::{atomic_write, read_if_exists};
use crate::process::Hardened;

pub mod carrier;
mod record;
pub(crate) use record::ensure_toggle_ready;
pub use record::{
    DeclaredPackage, SwitchPlan, check_origin, clear_install_completion, matching_lock_entry,
    paired_roots, record_matching_manifest, record_matching_name, resolve_declared, scope_root,
    session_roots,
};
mod files;
mod renames;
mod settings;
mod shadow;
mod state;
pub use state::{PackageState, RecordBasis, declared_state, installed_state};

use files::{copy_package, inside, read_dir};
pub(crate) use files::{owned_package_exact_hash, owned_package_hash, owned_package_identity};
pub use files::{package_hash, package_path};
pub use renames::{duplicate_elsewhere, family, installed_under, same_package};
pub(crate) use settings::extensions_enabled;
pub use settings::{list_npm_entries, package_enabled};
pub use shadow::{ShadowLines, ShadowPackage, ShadowScan, shadows};

const NPM_INSTALL_ARGS: &[&str] = &[
    "install",
    "--omit=dev",
    "--package-lock=false",
    "--legacy-peer-deps",
    "--no-audit",
    "--no-fund",
];

pub fn packages_dir(scope_root: &Path) -> PathBuf {
    scope_root.join("packages")
}

pub fn bin_dir(scope_root: &Path) -> PathBuf {
    scope_root.join("bin")
}

pub fn settings_path(scope_root: &Path) -> PathBuf {
    scope_root.join("settings.json")
}

pub fn append_system_path(scope_root: &Path) -> PathBuf {
    scope_root.join("APPEND_SYSTEM.md")
}

/// The `package.json` fields kendex acts on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PiPackage {
    pub name: String,
    pub description: Option<String>,
    pub version: Option<String>,
    /// `pi.extensions` — the entry points Pi loads.
    pub extensions: Vec<String>,
    /// `pi.appendSystem` — a package-relative markdown file.
    pub append_system: Option<String>,
    /// `bin`, normalized to (cli name, package-relative path) pairs.
    pub bins: Vec<(String, String)>,
}

#[derive(Debug, Deserialize)]
struct RawPackage {
    name: String,
    description: Option<String>,
    version: Option<String>,
    pi: Option<RawPi>,
    bin: Option<RawBin>,
}

#[derive(Debug, Default, Deserialize)]
struct RawPi {
    #[serde(default)]
    extensions: Vec<String>,
    #[serde(default, rename = "appendSystem")]
    append_system: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum RawBin {
    /// `"bin": "./cli.js"` — the cli takes the package name.
    Single(String),
    Named(BTreeMap<String, String>),
}

pub fn read(package_dir: &Path) -> Result<PiPackage> {
    let path = package_dir.join("package.json");
    let text = read_if_exists(&path)?
        .ok_or_else(|| CoreError::io(&path, std::io::Error::from(std::io::ErrorKind::NotFound)))?;
    let raw: RawPackage = serde_json::from_str(&text).map_err(|e| CoreError::JsonParse {
        path: path.clone(),
        message: e.to_string(),
    })?;
    let pi = raw.pi.unwrap_or_default();
    let bins = match raw.bin {
        Some(RawBin::Single(target)) => vec![(raw.name.clone(), target)],
        Some(RawBin::Named(map)) => map.into_iter().collect(),
        None => Vec::new(),
    };
    Ok(PiPackage {
        name: raw.name,
        description: raw.description,
        version: raw.version,
        extensions: pi.extensions,
        append_system: pi.append_system,
        bins,
    })
}

/// Where a package whose registered name differs from its directory
/// lives under a catalog's `pi-extensions/` folder — kendex's own catalog
/// shelves scoped names in short directories. `sealed` is the CATALOG
/// root, and the folder is traversed beneath it: sealing the folder
/// itself would canonicalize a symlinked `pi-extensions` into a trusted
/// root and launder an escape. Symlinked or oversized metadata is
/// skipped, never followed. One nested level covers npm-style
/// `@scope/name` layouts. Two directories registering the same name is
/// an error, not a coin toss over which bytes install.
pub fn find_by_package_name(
    sealed: &crate::source_read::SealedSource,
    name: &str,
) -> Result<Option<PathBuf>> {
    let base = sealed.root().join("pi-extensions");
    if !sealed.is_dir(&base) {
        return Ok(None);
    }
    // One aggregate budget across both levels: per-directory caps alone
    // would let thousands of @scope directories multiply into millions of
    // candidates.
    const MAX_CANDIDATES: usize = 4096;
    let mut candidates = sealed.entries(&base)?;
    for dir in std::mem::take(&mut candidates) {
        if dir
            .file_name()
            .is_some_and(|n| n.to_string_lossy().starts_with('@'))
        {
            candidates.extend(sealed.entries(&dir).unwrap_or_default());
        } else {
            candidates.push(dir);
        }
        if candidates.len() > MAX_CANDIDATES {
            return Err(CoreError::PiPackage {
                name: name.to_owned(),
                message: format!(
                    "more than {MAX_CANDIDATES} package directories under {} — refusing to scan them all",
                    base.display()
                ),
            });
        }
    }
    let mut matches = Vec::new();
    for dir in candidates {
        let manifest = dir.join("package.json");
        if !sealed.is_file(&manifest) {
            continue;
        }
        let Ok(text) = sealed.read_to_string(&manifest) else {
            continue;
        };
        if serde_json::from_str::<RawPackage>(&text).is_ok_and(|raw| raw.name == name) {
            matches.push(dir);
        }
    }
    match matches.len() {
        0 => Ok(None),
        1 => Ok(matches.pop()),
        _ => Err(CoreError::PiPackage {
            name: name.to_owned(),
            message: format!(
                "{} directories under {} register this package name — refusing to pick one",
                matches.len(),
                base.display()
            ),
        }),
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstallOutcome {
    pub name: String,
    pub version: Option<String>,
    pub dest: PathBuf,
    pub bins: Vec<PathBuf>,
    /// Declared `bin` entries whose target the package does not ship — the
    /// package still installs, but that cli is not linked.
    pub unbuilt_bins: Vec<String>,
}

/// Replace a package and register it without changing Pi's package order.
/// A disabled declaration loads no extensions, but refuses to erase a saved
/// nonempty selection. An enabled declaration keeps any existing native filter,
/// including a disable the user already set. The package's `APPEND_SYSTEM.md`
/// block follows [`append_system_block`].
pub fn install(
    env: &Env,
    scope_root: &Path,
    source_pkg_dir: &Path,
    enabled: bool,
) -> Result<InstallOutcome> {
    let package = read(source_pkg_dir)?;
    let dest = package_path(scope_root, &package.name)?;
    if dest.symlink_metadata().is_ok() {
        crate::trash::move_to_trash(env, &dest)?;
    }
    copy_package(source_pkg_dir, &dest)?;
    npm_install(&package.name, &dest)?;
    let (bins, unbuilt_bins) = link_bins(scope_root, &package, &dest)?;
    settings::upsert_package(&settings_path(scope_root), &package.name, enabled)?;
    write_append_system(env, scope_root, &package, &dest, enabled)?;
    Ok(InstallOutcome {
        name: package.name,
        version: package.version,
        dest,
        bins,
        unbuilt_bins,
    })
}

/// Unregister a package and move its installed copy to the trash.
pub fn remove(env: &Env, scope_root: &Path, name: &str) -> Result<()> {
    let dest = package_path(scope_root, name)?;
    settings::remove_package(&settings_path(scope_root), name)?;
    strip_append_system(&append_system_path(scope_root), name)?;
    unlink_bins(&bin_dir(scope_root), &dest)?;
    if dest.symlink_metadata().is_ok() {
        crate::trash::move_to_trash(env, &dest)?;
    }
    Ok(())
}

/// Whether the scope's settings register the package. The read a removal
/// plans against: a settings file this cannot parse is one `remove` could
/// not edit either, and the plan refuses it here rather than in the
/// transaction.
pub fn registered(scope_root: &Path, name: &str) -> Result<bool> {
    settings::references_package(&settings_path(scope_root), name)
}

/// Hash of the installed copy, comparable with `package_hash` of the source
/// it came from — `None` when nothing is installed under that name.
pub fn installed_hash(scope_root: &Path, name: &str) -> Result<Option<String>> {
    owned_package_hash(&package_path(scope_root, name)?)
}

/// Installed package names, with `@scope/name` reported whole.
pub fn list_installed(scope_root: &Path) -> Result<Vec<String>> {
    let mut names = Vec::new();
    for entry in read_dir(&packages_dir(scope_root))? {
        let name = entry.file_name().to_string_lossy().into_owned();
        if !entry.path().is_dir() {
            continue;
        }
        if !name.starts_with('@') {
            if entry.path().join("package.json").is_file() {
                names.push(name);
            }
            continue;
        }
        for scoped in read_dir(&entry.path())? {
            if scoped.path().join("package.json").is_file() {
                names.push(format!("{name}/{}", scoped.file_name().to_string_lossy()));
            }
        }
    }
    names.sort();
    Ok(names)
}

/// Whether installing this package runs `npm install`, and with it the
/// package's own lifecycle scripts: the one question a caller deciding
/// whether an install may run unasked has to put to the package.
pub fn declares_runtime_deps(package_dir: &Path) -> Result<bool> {
    let path = package_dir.join("package.json");
    let Some(text) = read_if_exists(&path)? else {
        return Ok(false);
    };
    let parsed: Value = serde_json::from_str(&text).map_err(|e| CoreError::JsonParse {
        path,
        message: e.to_string(),
    })?;
    Ok(["dependencies", "optionalDependencies"].iter().any(|key| {
        parsed
            .get(key)
            .and_then(Value::as_object)
            .is_some_and(|map| !map.is_empty())
    }))
}

/// Pi loads packages straight from disk, so a package with production
/// dependencies needs its `node_modules` built here at install time.
fn npm_install(name: &str, package_dir: &Path) -> Result<()> {
    if !declares_runtime_deps(package_dir)? {
        return Ok(());
    }
    let recovery = format!(
        "cd '{}' && npm {}",
        package_dir.display(),
        NPM_INSTALL_ARGS.join(" ")
    );
    let failed = |detail: String| CoreError::PiPackage {
        name: name.to_owned(),
        message: format!("{detail}. Recovery: `{recovery}`"),
    };
    // A cold install pulls its whole tree over the network; minutes is a
    // slow install, not a wedged one.
    let output = Hardened::npm(NPM_INSTALL_ARGS, Some(package_dir))
        .timeout(Duration::from_secs(600))
        .run()
        .map_err(|e| {
            failed(format!(
                "declares production dependencies, but npm could not run: {e}"
            ))
        })?;
    if output.status.success() {
        return Ok(());
    }
    let mut detail = String::from_utf8_lossy(&output.stderr).trim().to_owned();
    if detail.is_empty() {
        detail = output.status.to_string();
    }
    Err(failed(format!("`npm install` failed: {detail}")))
}

fn link_bins(
    scope_root: &Path,
    package: &PiPackage,
    dest: &Path,
) -> Result<(Vec<PathBuf>, Vec<String>)> {
    let mut links = Vec::new();
    let mut unbuilt = Vec::new();
    for (cli, relative) in &package.bins {
        let target = inside(dest, relative, &package.name)?;
        if !target.exists() {
            unbuilt.push(cli.clone());
            continue;
        }
        let link = inside(&bin_dir(scope_root), cli, &package.name)?;
        if let Some(parent) = link.parent() {
            std::fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e))?;
        }
        if link.is_symlink() {
            std::fs::remove_file(&link).map_err(|e| CoreError::io(&link, e))?;
        } else if link.exists() {
            return Err(CoreError::PiPackage {
                name: package.name.clone(),
                message: format!("{} exists and is not a link kendex owns", link.display()),
            });
        }
        make_symlink(&target, &link)?;
        links.push(link);
    }
    Ok((links, unbuilt))
}

/// Drop every link that resolves into the package, npm scope dirs included.
fn unlink_bins(dir: &Path, dest: &Path) -> Result<()> {
    // Containment uses canonicalize's single representation. Reducing the
    // ancestor and descendant separately can drop only one verbatim prefix
    // when their lengths differ (paths::reduced).
    let dest = match dest.canonicalize() {
        Ok(dest) => dest,
        // Repeated removal has no package left to own a bin link.
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(CoreError::io(dest, error)),
    };
    for entry in read_dir(dir)? {
        let link = entry.path();
        if link.is_symlink() {
            // Windows can reject a relative link's stored slash separators.
            // Resolve its text with platform components before containment.
            let target = std::fs::read_link(&link)
                .and_then(|target| {
                    dir.join(target.components().collect::<PathBuf>())
                        .canonicalize()
                })
                .map_err(|e| CoreError::io(&link, e))?;
            if target.starts_with(&dest) {
                std::fs::remove_file(&link).map_err(|e| CoreError::io(&link, e))?;
            }
        } else if link.is_dir() {
            unlink_bins(&link, &dest)?;
        }
    }
    Ok(())
}

/// The text a package adds to the scope's `APPEND_SYSTEM.md`, or `None`
/// where it adds none: it ships no `appendSystem` file or an empty one, its
/// declaration is disabled, or its own `enabled` setting is off. A package
/// that is off registers no tools, and its instructions would tell the model
/// to call tools it does not have.
fn append_system_block(
    env: &Env,
    scope_root: &Path,
    package: &PiPackage,
    dest: &Path,
    enabled: bool,
) -> Result<Option<String>> {
    if !enabled || !settings::config_enabled(&enabled_settings(env, scope_root)?, &package.name)? {
        return Ok(None);
    }
    let Some(relative) = &package.append_system else {
        return Ok(None);
    };
    let content = read_if_exists(&inside(dest, relative, &package.name)?)?;
    Ok(content
        .map(|text| text.trim().to_owned())
        .filter(|block| !block.is_empty()))
}

/// The settings files the package reads its `enabled` setting from, in
/// merge order: Pi's user settings, then a project scope's own. Pi loads one
/// `APPEND_SYSTEM.md`, a trusted project's own when it has one, else the
/// global one, so the global file serves every project without a trusted
/// file of its own and a global block follows the user settings alone.
fn enabled_settings(env: &Env, scope_root: &Path) -> Result<Vec<PathBuf>> {
    let user = record::scope_root(env, &crate::model::Scope::Global)?;
    let mut paths = vec![settings_path(&user)];
    if scope_root != user {
        paths.push(settings_path(scope_root));
    }
    Ok(paths)
}

/// The edit that brings an installed package's `APPEND_SYSTEM.md` block in
/// line with a declaration switched to `enabled`, for a plan that changes
/// the switch without reinstalling the package.
pub(crate) fn append_system_edit(
    env: &Env,
    scope_root: &Path,
    name: &str,
    enabled: bool,
) -> Result<(PathBuf, ConfigEdit)> {
    let dest = package_path(scope_root, name)?;
    let package = read(&dest)?;
    let edit = match append_system_block(env, scope_root, &package, &dest, enabled)? {
        Some(block) => ConfigEdit::UpsertMarkerBlock {
            name: package.name,
            block,
        },
        None => ConfigEdit::RemoveMarkerBlock { name: package.name },
    };
    Ok((append_system_path(scope_root), edit))
}

/// Mirror the package's [`append_system_block`] into the scope's
/// `APPEND_SYSTEM.md`, or strip the package's block where it has none.
fn write_append_system(
    env: &Env,
    scope_root: &Path,
    package: &PiPackage,
    dest: &Path,
    enabled: bool,
) -> Result<()> {
    let path = append_system_path(scope_root);
    let Some(block) = append_system_block(env, scope_root, package, dest, enabled)? else {
        return strip_append_system(&path, &package.name);
    };
    let current = read_if_exists(&path)?.unwrap_or_default();
    let next = upsert_marker_block(&current, &package.name, &block);
    if next == current {
        return Ok(());
    }
    atomic_write(&path, &next)
}

/// Drop the package's block; a file with nothing left in it is deleted
/// rather than left behind empty.
fn strip_append_system(path: &Path, name: &str) -> Result<()> {
    let Some(current) = read_if_exists(path)? else {
        return Ok(());
    };
    let next = remove_marker_block(&current, name);
    if next == current {
        return Ok(());
    }
    if next.trim().is_empty() {
        return std::fs::remove_file(path).map_err(|e| CoreError::io(path, e));
    }
    atomic_write(path, &next)
}

#[cfg(test)]
mod tests;
