//! Pi extensions are npm-shaped packages: a source ships
//! `pi-extensions/<name>/`, kendex copies it into a scope's `packages/` dir,
//! resolves its production dependencies, links its `bin` entries, registers
//! it in `settings.json`, and mirrors its `pi.appendSystem` file into the
//! scope's `APPEND_SYSTEM.md`.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Deserialize;
use serde_json::Value;

use crate::apply::journal::make_symlink;
use crate::configedit::{remove_marker_block, upsert_marker_block};
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::fs::{atomic_write, read_if_exists};
use crate::process::Hardened;

pub mod carrier;
mod files;
mod renames;
mod settings;

pub use files::package_hash;
use files::{copy_package, inside, package_path, read_dir, trash};
pub use renames::{duplicate_elsewhere, legacy_names};
pub use settings::list_npm_entries;

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
    let mut candidates = sealed.list_dir(&base)?;
    for dir in std::mem::take(&mut candidates) {
        if dir
            .file_name()
            .is_some_and(|n| n.to_string_lossy().starts_with('@'))
        {
            candidates.extend(sealed.list_dir(&dir).unwrap_or_default());
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

/// Copy a source package into the scope and register it with Pi. Re-running
/// replaces the installed copy, keeping its position in Pi's load order.
pub fn install(env: &Env, scope_root: &Path, source_pkg_dir: &Path) -> Result<InstallOutcome> {
    let package = read(source_pkg_dir)?;
    let dest = package_path(scope_root, &package.name)?;
    if dest.symlink_metadata().is_ok() {
        trash(env, &dest)?;
    }
    copy_package(source_pkg_dir, &dest)?;
    npm_install(&package.name, &dest)?;
    let (bins, unbuilt_bins) = link_bins(scope_root, &package, &dest)?;
    settings::upsert_package(&settings_path(scope_root), &package.name)?;
    write_append_system(scope_root, &package, &dest)?;
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
        trash(env, &dest)?;
    }
    Ok(())
}

/// Hash of the installed copy, comparable with `package_hash` of the source
/// it came from — `None` when nothing is installed under that name.
pub fn installed_hash(scope_root: &Path, name: &str) -> Result<Option<String>> {
    package_hash(&package_path(scope_root, name)?)
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

fn declares_runtime_deps(package_dir: &Path) -> Result<bool> {
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
    for entry in read_dir(dir)? {
        let link = entry.path();
        if link.is_symlink() {
            let target = std::fs::read_link(&link).map_err(|e| CoreError::io(&link, e))?;
            if target.starts_with(dest) {
                std::fs::remove_file(&link).map_err(|e| CoreError::io(&link, e))?;
            }
        } else if link.is_dir() {
            unlink_bins(&link, dest)?;
        }
    }
    Ok(())
}

/// Mirror the package's `appendSystem` file into the scope's
/// `APPEND_SYSTEM.md` block. A package that ships no such file gets no block.
fn write_append_system(scope_root: &Path, package: &PiPackage, dest: &Path) -> Result<()> {
    let path = append_system_path(scope_root);
    let content = match &package.append_system {
        Some(relative) => read_if_exists(&inside(dest, relative, &package.name)?)?,
        None => None,
    };
    let block = content.as_deref().map(str::trim).unwrap_or_default();
    if block.is_empty() {
        return strip_append_system(&path, &package.name);
    }
    let current = read_if_exists(&path)?.unwrap_or_default();
    let next = upsert_marker_block(&current, &package.name, block);
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
